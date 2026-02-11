package bftsmart.demo.rlWrapper;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import bftsmart.demo.microbenchmarks.ThroughputLatencyServer;
import bftsmart.tom.ServiceReplica;
import io.grpc.ManagedChannel;
import io.grpc.ManagedChannelBuilder;
import io.grpc.StatusRuntimeException;

public class RLAgentConnector {

    private final Logger logger = LoggerFactory.getLogger(this.getClass());

    private final ServiceReplica serviceReplica;
    private final ThroughputLatencyServer serverInstance;
    
    private ManagedChannel channel;
    private MetricsServiceGrpc.MetricsServiceBlockingStub blockingStub;
    
    private boolean connected = false;

    // Configuration
    // Warmup should be longer than:
    // 1. lan_deploy.sh's "sleep 10" before client starts (10s)
    // 2. Client's rampup phase (3000ms / 100ms per request = ~30 requests * 10 clients)
    // Total: ~40-45 seconds for system to reach steady state
    private static final int WARMUP_TIME_MS = 10000; // 10s warmup
    private static final int MONITOR_INTERVAL_MS = 1000; // 1s interval
    // Request timeout is adjusted less frequently than batch params to avoid system oscillation.
    // Update every 10 monitoring intervals = every 10 seconds.
    private static final int REQUEST_TIMEOUT_UPDATE_INTERVAL = 10;
    private int monitorLoopCounter = 0;

    public RLAgentConnector(ServiceReplica serviceReplica, ThroughputLatencyServer serverInstance) {
        this.serviceReplica = serviceReplica;
        this.serverInstance = serverInstance;
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
     * Main loop for monitoring and tuning.
     */
    public void startMonitoringLoop() {
        if (!connected) return;

        logger.info("Starting RL Agent Monitoring Loop...");
        logger.info("Warming up for " + WARMUP_TIME_MS + "ms...");

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

                // 4. Apply Tuning (if response is valid)
                int newBatchSize = response.getBatchSize();
                int newBatchTimeout = response.getBatchTimeout();
                int newRequestTimeout = response.getRequestTimeout();
                
                if (newBatchSize > 0 && newBatchTimeout >= -1) {
                    monitorLoopCounter++;
                    // Request timeout is updated less frequently to avoid oscillation
                    if (newRequestTimeout > 0 && (monitorLoopCounter % REQUEST_TIMEOUT_UPDATE_INTERVAL == 0)) {
                        serviceReplica.setDynamicConsensusConfig(newBatchSize, newBatchTimeout, newRequestTimeout);
                    } else {
                        serviceReplica.setDynamicConsensusConfig(newBatchSize, newBatchTimeout);
                    }
                }

            } catch (StatusRuntimeException e) {
                logger.error("RPC failed: " + e.getStatus());
                // Decide whether to break or retry. For now, we continue but might need re-connection logic.
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
    }
}
