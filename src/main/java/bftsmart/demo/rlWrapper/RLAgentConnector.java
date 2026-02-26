package bftsmart.demo.rlWrapper;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import bftsmart.demo.microbenchmarks.ThroughputLatencyServer;
import bftsmart.tom.ServiceProxy;
import bftsmart.tom.ServiceReplica;
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

    // ─────────────────────────────────────────────────────────────────────────

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
     * replica is the current consensus leader; only the leader submits consensus-agreed
     * config-change requests.  After a leader change the new leader picks up the role
     * automatically on its next scheduled tick.
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

                // 1. Collect Metrics
                ThroughputLatencyServer.MetricsSnapshot snapshot = serverInstance.getAndResetMetrics();
                
                // Calculate throughput (ops/sec) and Avg Latency (ns)
                double throughput = (double) snapshot.ops * 1000.0 / snapshot.timeWindow;
                double avgLatencyNs = snapshot.latencySamples > 0 ? (double) snapshot.latencySum / snapshot.latencySamples : 0;
                // Convert to microseconds for the agent (matches scaling factor of 100,000 in trainer.py)
                double avgLatencyUs = avgLatencyNs / 1000.0;

                // 新增：计算平均消息大小（字节）
                double avgMessageSize = snapshot.sizeSamples > 0 ? (double) snapshot.totalSize / snapshot.sizeSamples : 0;

                // 新增：计算到达率（请求/秒）
                double arrivalRate = (double) snapshot.arrivalCount * 1000.0 / snapshot.timeWindow;

                // Memory monitoring
                Runtime runtime = Runtime.getRuntime();
                long usedMemory = (runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024); // MB
                long maxMemory = runtime.maxMemory() / (1024 * 1024); // MB
                long totalMemory = runtime.totalMemory() / (1024 * 1024); // MB
                double memoryUsagePercent = (double) usedMemory / maxMemory * 100;

                // Debug logging with memory info (updated with new metrics)
                logger.info(String.format("[Metrics] window=%dms, ops=%d, latSum=%d, latSamples=%d => thr=%.2f, lat=%.2f us | avgSize=%.0f bytes, arrivalRate=%.2f req/s | Memory: %dMB/%dMB (%.1f%%)",
                    snapshot.timeWindow, snapshot.ops, snapshot.latencySum, snapshot.latencySamples,
                    throughput, avgLatencyUs, avgMessageSize, arrivalRate, usedMemory, maxMemory, memoryUsagePercent));

                // 2. Build Request (updated with size and arrival_rate)
                MonitorProto.MetricsRequest request = MonitorProto.MetricsRequest.newBuilder()
                        .setThroughput((int) throughput)
                        .setLatency((int) avgLatencyUs) 
                        .setSize((int) avgMessageSize) // 新增：平均消息大小（字节）
                        .setTotThr((int) throughput) // Simplified mapping
                        .setTotLat((int) avgLatencyUs) 
                        .setOption(1) // Option 1 for Batch Tuning
                        .setArrivalRate(arrivalRate) // 新增：到达率（请求/秒）
                        .build();

                // 3. Send RPC
                MonitorProto.MetricsResponse response = blockingStub.sendMetrics(request);

                // 4. Apply Tuning
                int newBatchSize    = response.getBatchSize();
                int newBatchTimeout = response.getBatchTimeout();
                int newRequestTimeout = response.getRequestTimeout();

                if (newBatchSize > 0 && newBatchTimeout >= -1) {
                    monitorLoopCounter++;

                    // ── Local parameters: apply directly, no consensus needed ─────────
                    serviceReplica.setDynamicConsensusConfig(newBatchSize, newBatchTimeout);

                    // ── Consensus parameter: requestTimeout ───────────────────────────
                    // Only the CURRENT consensus leader submits the proposal.
                    // After a leader change, the new leader takes over automatically.
                    // All replicas (including the proposer) apply the value when the
                    // ordered request is delivered via appExecuteBatch().
                    if (newRequestTimeout > 0
                            && monitorLoopCounter % REQUEST_TIMEOUT_UPDATE_INTERVAL == 0) {

                        if (isCurrentLeader()) {
                            ensureConfigProxyInitialised();
                            proposeRequestTimeoutViaConsensus(newRequestTimeout);
                        } else {
                            logger.debug("[ConfigProxy] Replica {} is not the leader (leader={}); "
                                    + "skipping requestTimeout proposal.",
                                    replicaId, serviceReplica.getCurrentLeader());
                        }
                        // Non-leader replicas receive the update through the consensus
                        // delivery path in appExecuteBatch() – no action needed here.
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
     * Submits a consensus-agreed {@code requestTimeout} update (replica 0 only).
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
        if (configProxy == null) {
            logger.warn("[ConfigProxy] configProxy is null – cannot propose requestTimeout={}", newRequestTimeout);
            return;
        }

        // Avoid re-proposing the same value that was already submitted
        if (newRequestTimeout == lastProposedRequestTimeout) {
            logger.debug("[ConfigProxy] requestTimeout={} already proposed, skipping duplicate.", newRequestTimeout);
            return;
        }

        try {
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
        }
    }}