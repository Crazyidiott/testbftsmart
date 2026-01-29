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
    private static final int WARMUP_TIME_MS = 10000; // 10s warmup
    private static final int MONITOR_INTERVAL_MS = 1000; // 1s interval

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

                // Debug logging
                logger.info(String.format("[Metrics] window=%dms, ops=%d, latSum=%d, latSamples=%d => thr=%.2f, lat=%.2f us",
                    snapshot.timeWindow, snapshot.ops, snapshot.latencySum, snapshot.latencySamples,
                    throughput, avgLatencyUs));

                // 2. Build Request
                MonitorProto.MetricsRequest request = MonitorProto.MetricsRequest.newBuilder()
                        .setThroughput((int) throughput)
                        .setLatency((int) avgLatencyUs) 
                        .setSize(0) // Not currently tracking size individually here
                        .setTotThr((int) throughput) // Simplified mapping
                        .setTotLat((int) avgLatencyUs) 
                        .setOption(1) // Option 1 for Batch Tuning
                        .setArrivalRate(0.0)
                        .build();

                // 3. Send RPC
                MonitorProto.MetricsResponse response = blockingStub.sendMetrics(request);

                // 4. Apply Tuning (if response is valid)
                int newBatchSize = response.getBatchSize();
                int newBatchTimeout = response.getBatchTimeout();
                
                if (newBatchSize > 0 && newBatchTimeout >= -1) {
                    // Check if different from current config to avoid spamming logs? 
                    // ServiceReplica/TOMConfiguration logic handles updates efficiently.
                    
                    serviceReplica.setDynamicConsensusConfig(newBatchSize, newBatchTimeout);
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
