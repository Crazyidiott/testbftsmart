package bftsmart.demo.rlWrapper;

import java.util.concurrent.atomic.AtomicBoolean;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import bftsmart.demo.microbenchmarks.ThroughputLatencyServer;
import bftsmart.tom.ServiceProxy;
import bftsmart.tom.ServiceReplica;
import bftsmart.tom.core.TOMLayer;
import io.grpc.ManagedChannel;
import io.grpc.ManagedChannelBuilder;
import io.grpc.StatusRuntimeException;

/**
 * Connects a replica to the Python RL/Bayesian optimisation agent and applies
 * the resulting parameter recommendations.
 *
 * <h3>Parameter classification</h3>
 * <ul>
 *   <li><b>Local parameters</b> ({@code batchSize}, {@code batchTimeout}): each replica
 *       may apply these independently; inconsistency does not break the protocol.</li>
 *   <li><b>Consensus parameters</b> ({@code requestTimeout}): all replicas must agree
 *       on the same value so that they trigger a leader-change at the same moment.
 *       These are applied via {@link ConfigChangeRequest}: only the <em>current PBFT
 *       consensus leader</em> submits an {@code invokeOrdered} proposal; all replicas
 *       (including the leader) apply the value when the ordered request is delivered
 *       by the consensus engine.</li>
 * </ul>
 *
 * <h3>Config Proposer role follows the PBFT leader</h3>
 * <p>Every replica runs its own {@code RLAgentConnector} monitoring loop.
 * At each {@link #REQUEST_TIMEOUT_UPDATE_INTERVAL} tick, the loop checks whether
 * this replica is currently the consensus leader ({@code serviceReplica.getCurrentLeader()}).
 * Only the leader submits the {@code invokeOrdered} config-change request.
 * After a leader change, the new leader's monitoring loop will start proposing
 * on its next scheduled tick – no special coordination is required.
 * <p>The only edge case where requestTimeout updates pause is when the current leader
 * is genuinely faulty (crashed/Byzantine) and no new leader has yet been elected;
 * once the leader-change protocol completes and a new leader is established,
 * updates resume automatically.
 */
public class RLAgentConnector {

    private final Logger logger = LoggerFactory.getLogger(this.getClass());

    private final ServiceReplica serviceReplica;
    private final ThroughputLatencyServer serverInstance;

    /** Replica ID obtained from ServiceReplica. */
    private final int replicaId;

    private ManagedChannel channel;
    private MetricsServiceGrpc.MetricsServiceBlockingStub blockingStub;

    /**
     * Internal ServiceProxy used by whichever replica is currently the PBFT leader
     * to submit consensus-agreed config-change requests.  Initialised lazily when
     * this replica first becomes the leader.
     * Client ID 4999 is reserved for this purpose and must not be used by benchmark clients.
     */
    private ServiceProxy configProxy = null;
    private static final int CONFIG_PROXY_CLIENT_ID = 4999;

    /** Tracks the last requestTimeout value proposed via consensus to avoid duplicates. */
    private volatile int lastProposedRequestTimeout = -1;

    /**
     * Guards concurrent requestTimeout proposals.  Set to {@code true} when an
     * {@code invokeOrdered} call is in-flight; reset to {@code false} when it
     * completes (success or failure).  Prevents the monitoring loop thread from
     * being blocked by consensus I/O and avoids stacking duplicate proposals
     * during slow consensus rounds (e.g. leader-change recovery).
     */
    private final AtomicBoolean proposalInFlight = new AtomicBoolean(false);

    private boolean connected = false;

    // ── Timing constants ──────────────────────────────────────────────────────

    /** Warmup period before the first metrics transmission. */
    private static final int WARMUP_TIME_MS = 10000;       // 10 s

    /** Metrics collection and parameter-update interval. */
    private static final int MONITOR_INTERVAL_MS = 1000;   // 1 s

    /**
     * requestTimeout is updated every N monitoring intervals to avoid view-change
     * oscillation caused by rapidly changing the leader-failover timer.
     */
    private static final int REQUEST_TIMEOUT_UPDATE_INTERVAL = 10; // every 10 s

    private int monitorLoopCounter = 0;
    // ── Cumulative / smoothed state variables for tot_thr / tot_lat / tot_size ──────────
    /**
     * Exponentially-weighted moving average of per-window throughput (ops/s), α = 0.2.
     * Provides a smoothed / longer-horizon signal compared to the raw per-window value.
     * Sent as {@code tot_thr}; same unit (ops/s) as the {@code throughput} field,
     * normalised with THROUGHPUT_SCALE (60 000) on the Python side.
     */
    private double smoothedThroughputOps = 0.0;

    /**
     * Exponentially-weighted moving average of per-window latency (µs), α = 0.2.
     * Provides a smoothed / longer-horizon signal compared to the raw per-window value.
     * Sent as {@code tot_lat}; same unit (µs) as the {@code latency} field.
     */
    private double smoothedLatencyUs = 0.0;

    /**
     * Cumulative total message size since the monitoring loop started, in <em>kilobytes</em>
     * (divided by 1024 to avoid int32 overflow).
     * Sent as {@code tot_size} (normalised with 1e9 on the Python side).
     */
    private long cumulativeSizeKB = 0;    // ─────────────────────────────────────────────────────────────────────────

    public RLAgentConnector(ServiceReplica serviceReplica, ThroughputLatencyServer serverInstance) {
        this.serviceReplica = serviceReplica;
        this.serverInstance = serverInstance;
        this.replicaId = serviceReplica.getId();
    }

    /**
     * Attempts to connect to the RL Agent.
     * Retries for 5 seconds.
     * @param host Agent host
     * @param port Agent port
     * @return true if connected, false otherwise
     */
    public boolean connectToAgent(String host, int port) {
        logger.info("Attempting to connect to RL Agent at " + host + ":" + port);
        
        // Try for 5 seconds
        long deadline = System.currentTimeMillis() + 5000;
        
        while (System.currentTimeMillis() < deadline) {
            try {
                channel = ManagedChannelBuilder.forAddress(host, port)
                        .usePlaintext()
                        .build();
                blockingStub = MetricsServiceGrpc.newBlockingStub(channel);

                // Initial Handshake
                MonitorProto.Timestamp request = MonitorProto.Timestamp.newBuilder()
                        .setTimestamp(System.currentTimeMillis())
                        .build();
                
                MonitorProto.Timestamp response = blockingStub.connect(request);
                
                logger.info("Successfully connected to Agent. Server time: " + response.getTimestamp());
                connected = true;
                return true;

            } catch (Exception e) {
                logger.warn("Connection attempt failed: " + e.getMessage() + ". Retrying...");
                if (channel != null) {
                    channel.shutdownNow();
                }
                try {
                    Thread.sleep(1000);
                } catch (InterruptedException ignored) {}
            }
        }
        
        return false;
    }

    /**
     * Returns {@code true} if this replica is currently the PBFT consensus leader.
     *
     * <p>The Config Proposer role follows the leader: whichever replica is the
     * current leader is responsible for submitting {@code requestTimeout} updates
     * via consensus.  This ensures the role survives any number of leader changes.
     */
    private boolean isCurrentLeader() {
        return replicaId == serviceReplica.getCurrentLeader();
    }

    /**
     * Lazily initialises the internal {@link ServiceProxy} used for consensus-agreed
     * config changes.  Called the first time this replica becomes the leader.
     */
    private void ensureConfigProxyInitialised() {
        if (configProxy != null) return;
        try {
            configProxy = new ServiceProxy(CONFIG_PROXY_CLIENT_ID);
            logger.info("[ConfigProxy] Replica {} (now leader): internal ServiceProxy initialised "
                    + "(clientId={}) for consensus-agreed config changes.", replicaId, CONFIG_PROXY_CLIENT_ID);
        } catch (Exception e) {
            logger.error("[ConfigProxy] Replica {}: failed to initialise internal ServiceProxy – "
                    + "requestTimeout updates via consensus will be disabled.", replicaId, e);
        }
    }

    /**
     * Main loop for monitoring and tuning.
     *
     * <p>Every replica runs this loop.  At each tick the loop checks whether this
     * replica is the current consensus leader.
     * <ul>
     *   <li><b>Leader</b>: collects metrics and sends them to the Python agent via
     *       {@code SendMetrics}, which triggers the optimizer's training / update cycle.</li>
     *   <li><b>Non-leader</b>: calls {@code GetCurrentParams} to fetch the latest
     *       parameters <em>without</em> triggering any training.  This avoids sending
     *       duplicate / conflicting metrics to the same optimizer and reduces load
     *       (especially in single-machine deployment where all replicas share one agent).</li>
     * </ul>
     * Both leader and non-leader apply batch parameters locally; only the leader
     * submits requestTimeout updates via consensus.
     */
    public void startMonitoringLoop() {
        if (!connected) return;

        logger.info("[ConfigProxy] Replica {}: monitoring loop started. "
                + "Will act as Config Proposer whenever this replica is the consensus leader.", replicaId);

        logger.info("Starting RL Agent Monitoring Loop...");
        logger.info("Warming up for {} ms...", WARMUP_TIME_MS);

        try {
            Thread.sleep(WARMUP_TIME_MS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return;
        }

        logger.info("Warmup complete. Beginning metrics transmission.");

        // Clear any metrics accumulated during warmup
        serverInstance.getAndResetMetrics();

        while (!Thread.interrupted()) {
            try {
                // Sleep for interval
                Thread.sleep(MONITOR_INTERVAL_MS);

                MonitorProto.MetricsResponse response;

                if (isCurrentLeader()) {
                    // ── Leader path: send full metrics to trigger training ────────────
                    response = sendMetricsAsLeader();
                } else {
                    // ── Non-leader path: fetch current params without training ────────
                    response = fetchParamsAsFollower();
                }

                if (response == null) continue;

                // 4. Apply Tuning
                int newBatchSize    = response.getBatchSize();
                int newBatchTimeout = response.getBatchTimeout();
                int newRequestTimeout = response.getRequestTimeout();

                if (newBatchSize > 0 && newBatchTimeout >= -1) {
                    monitorLoopCounter++;

                    // ── Local parameters: apply directly, no consensus needed ─────────
                    logger.info("Updating local batch config: maxBatchSize={}, batchTimeout={}",
                            newBatchSize, newBatchTimeout);
                    serviceReplica.setDynamicConsensusConfig(newBatchSize, newBatchTimeout);

                    // ── Consensus parameter: requestTimeout ───────────────────────────
                    // Only the CURRENT consensus leader submits the proposal.
                    if (newRequestTimeout > 0
                            && monitorLoopCounter % REQUEST_TIMEOUT_UPDATE_INTERVAL == 0
                            && isCurrentLeader()) {
                        ensureConfigProxyInitialised();
                        if (!proposalInFlight.get()) {
                            final int timeoutToPropose = newRequestTimeout;
                            proposalInFlight.set(true);
                            Thread proposalThread = new Thread(
                                () -> proposeRequestTimeoutViaConsensus(timeoutToPropose));
                            proposalThread.setDaemon(true);
                            proposalThread.setName("ConfigProposal-RT-" + timeoutToPropose);
                            proposalThread.start();
                        } else {
                            logger.debug("[ConfigProxy] Replica {}: previous proposal still in-flight, "
                                    + "skipping requestTimeout={} this tick.",
                                    replicaId, newRequestTimeout);
                        }
                    }
                }

            } catch (StatusRuntimeException e) {
                logger.error("RPC failed: " + e.getStatus());
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            } catch (Exception e) {
                logger.error("Unexpected error in monitoring loop", e);
            }
        }
        
        if (channel != null) {
            channel.shutdown();
        }
        if (configProxy != null) {
            configProxy.close();
        }
    }

    /**
     * Leader path: collects local metrics, sends them to the Python agent via
     * {@code SendMetrics} (which triggers the optimizer's training cycle), and
     * returns the recommended parameters.
     */
    private MonitorProto.MetricsResponse sendMetricsAsLeader() {
        // 1. Collect Metrics
        ThroughputLatencyServer.MetricsSnapshot snapshot = serverInstance.getAndResetMetrics();

        // Calculate throughput (ops/sec) and Avg Latency (ns)
        double throughput = (double) snapshot.ops * 1000.0 / snapshot.timeWindow;
        double avgLatencyNs = snapshot.latencySamples > 0 ? (double) snapshot.latencySum / snapshot.latencySamples : 0;
        double avgLatencyUs = avgLatencyNs / 1000.0;
        double avgMessageSize = snapshot.sizeSamples > 0 ? (double) snapshot.totalSize / snapshot.sizeSamples : 0;
        double arrivalRate = (double) snapshot.arrivalCount * 1000.0 / snapshot.timeWindow;

        // Memory monitoring
        Runtime runtime = Runtime.getRuntime();
        long usedMemory = (runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024);
        long maxMemory = runtime.maxMemory() / (1024 * 1024);
        double memoryUsagePercent = (double) usedMemory / maxMemory * 100;

        logger.info(String.format("[Metrics-Leader] window=%dms, ops=%d, latSum=%d, latSamples=%d => thr=%.2f, lat=%.2f us | avgSize=%.0f bytes, arrivalRate=%.2f req/s | Memory: %dMB/%dMB (%.1f%%)",
            snapshot.timeWindow, snapshot.ops, snapshot.latencySum, snapshot.latencySamples,
            throughput, avgLatencyUs, avgMessageSize, arrivalRate, usedMemory, maxMemory, memoryUsagePercent));

        // ── DEBUG: Diagnose proposer stall when ops=0 ──────────────────────
        if (snapshot.ops == 0) {
            try {
                TOMLayer tom = serviceReplica.getReplicaContext()
                        .getSVController().getTOMLayer();
                if (tom != null) {
                    int inExec = tom.getInExec();
                    int lastExec = tom.getLastExec();
                    int leader = tom.execManager.getCurrentLeader();
                    boolean hasPending = tom.clientsManager.havePendingRequests();
                    boolean batchReady = tom.clientsManager.isNextBatchReady();
                    boolean stateTransfer = tom.isRetrievingState();
                    boolean leaderChanging = tom.isChangingLeader();
                    int numClients = tom.clientsManager.numClients();
                    long fcDrops = tom.clientsManager.getFlowControlDropCount();
                    long seqGaps = tom.clientsManager.getSeqGapRejectCount();
                    String clientSummary = tom.clientsManager.getPendingSummary();
                    logger.info(String.format(
                        "[DIAG] inExec=%d lastExec=%d leader=%d pending=%b batchReady=%b "
                        + "stateTransfer=%b leaderChanging=%b numClients=%d fcDrops=%d seqGaps=%d",
                        inExec, lastExec, leader, hasPending, batchReady,
                        stateTransfer, leaderChanging, numClients, fcDrops, seqGaps));
                    logger.info("[DIAG-CLIENTS] " + clientSummary);
                }
            } catch (Exception e) {
                logger.warn("[DIAG] Failed to read TOMLayer state: " + e.getMessage());
            }
        }
        // ───────────────────────────────────────────────────────────────────

        // EMA smoothing
        if (smoothedThroughputOps == 0.0) {
            smoothedThroughputOps = throughput;
        } else {
            smoothedThroughputOps = 0.8 * smoothedThroughputOps + 0.2 * throughput;
        }
        if (smoothedLatencyUs == 0.0) {
            smoothedLatencyUs = avgLatencyUs;
        } else {
            smoothedLatencyUs = 0.8 * smoothedLatencyUs + 0.2 * avgLatencyUs;
        }
        cumulativeSizeKB += snapshot.totalSize / 1024;

        // 2. Build and send request
        MonitorProto.MetricsRequest request = MonitorProto.MetricsRequest.newBuilder()
                .setThroughput((int) throughput)
                .setLatency((int) avgLatencyUs)
                .setSize((int) avgMessageSize)
                .setTotThr((int) smoothedThroughputOps)
                .setTotLat((int) smoothedLatencyUs)
                .setTotSize((int) Math.min(cumulativeSizeKB, Integer.MAX_VALUE))
                .setOption(1)
                .setArrivalRate(arrivalRate)
                .build();

        return blockingStub.sendMetrics(request);
    }

    /**
     * Non-leader path: fetches the current parameters from the Python agent
     * via {@code GetCurrentParams} <em>without</em> triggering any training
     * or optimizer state update.  Also drains any metrics accumulated since
     * the last tick so they don't pile up.
     */
    private MonitorProto.MetricsResponse fetchParamsAsFollower() {
        // Drain metrics accumulated during this interval so counters don't overflow
        ThroughputLatencyServer.MetricsSnapshot snapshot = serverInstance.getAndResetMetrics();

        double throughput = (double) snapshot.ops * 1000.0 / snapshot.timeWindow;
        double avgLatencyNs = snapshot.latencySamples > 0 ? (double) snapshot.latencySum / snapshot.latencySamples : 0;
        double avgLatencyUs = avgLatencyNs / 1000.0;

        Runtime runtime = Runtime.getRuntime();
        long usedMemory = (runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024);
        long maxMemory = runtime.maxMemory() / (1024 * 1024);
        double memoryUsagePercent = (double) usedMemory / maxMemory * 100;

        logger.info(String.format("[Metrics-Follower] window=%dms, ops=%d => thr=%.2f, lat=%.2f us | Memory: %dMB/%dMB (%.1f%%)",
            snapshot.timeWindow, snapshot.ops, throughput, avgLatencyUs, usedMemory, maxMemory, memoryUsagePercent));

        MonitorProto.ParamsRequest request = MonitorProto.ParamsRequest.newBuilder()
                .setReplicaId(replicaId)
                .build();

        return blockingStub.getCurrentParams(request);
    }

    /**
     * Submits a consensus-agreed {@code requestTimeout} update.
     *
     * <p>The request is encoded with a magic prefix (see {@link ConfigChangeRequest}) and
     * sent as a normal BFT-ordered request via the internal {@link ServiceProxy}.
     * All replicas – including replica 0 itself – will apply the new value when the
     * ordered request is delivered by the consensus engine (in
     * {@code ThroughputLatencyServer.appExecuteBatch}).
     *
     * @param newRequestTimeout Proposed new value in milliseconds.
     */
    private void proposeRequestTimeoutViaConsensus(int newRequestTimeout) {
        // proposalInFlight was set to true by the monitoring loop before starting
        // this thread; always reset it on exit so future proposals are not blocked.
        try {
            if (configProxy == null) {
                logger.warn("[ConfigProxy] configProxy is null – cannot propose requestTimeout={}", newRequestTimeout);
                return;
            }

            // Avoid re-proposing the same value that was already submitted
            if (newRequestTimeout == lastProposedRequestTimeout) {
                logger.debug("[ConfigProxy] requestTimeout={} already proposed, skipping duplicate.", newRequestTimeout);
                return;
            }

            logger.info("[ConfigProxy] Replica 0 proposing consensus config change: requestTimeout={}",
                    newRequestTimeout);

            byte[] payload = ConfigChangeRequest.encode(
                    ConfigChangeRequest.TYPE_REQUEST_TIMEOUT, newRequestTimeout);

            // invokeOrdered blocks until f+1 replicas have confirmed the result.
            // The request goes through BFT consensus, so ALL correct replicas deliver it.
            byte[] ack = configProxy.invokeOrdered(payload);

            lastProposedRequestTimeout = newRequestTimeout;
            logger.info("[ConfigProxy] Consensus proposal for requestTimeout={} submitted successfully "
                    + "(ACK length={}).", newRequestTimeout, ack != null ? ack.length : 0);

        } catch (Exception e) {
            logger.error("[ConfigProxy] Failed to submit requestTimeout={} via consensus: {}",
                    newRequestTimeout, e.getMessage(), e);
        } finally {
            proposalInFlight.set(false);
        }
    }}