/**
 * Copyright (c) 2007-2013 Alysson Bessani, Eduardo Alchieri, Paulo Sousa, and the authors indicated in the @author tags
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package bftsmart.demo.microbenchmarks;

import java.io.BufferedReader;
import java.io.FileReader;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.security.InvalidKeyException;
import java.security.KeyFactory;
import java.security.NoSuchAlgorithmException;
import java.security.NoSuchProviderException;
import java.security.Security;
import java.security.Signature;
import java.security.SignatureException;
import java.security.spec.InvalidKeySpecException;
import java.security.spec.PKCS8EncodedKeySpec;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.Collection;
import java.util.LinkedList;
import java.util.List;
import java.util.Random;
import java.util.Timer;
import java.util.TimerTask;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicLong;

import bftsmart.communication.client.ReplyListener;
import bftsmart.tom.AsynchServiceProxy;
import bftsmart.tom.RequestContext;
import bftsmart.tom.core.messages.TOMMessage;
import bftsmart.tom.core.messages.TOMMessageType;
import bftsmart.tom.util.Storage;
import bftsmart.tom.util.TOMUtil;

/**
 *
 * @author anogueira
 *
 */
public class AsyncDynamicClient {

    static int initId;
    // Global counter for total throughput monitoring
    static AtomicLong globalOpsCounter = new AtomicLong(0);
    
    // ============ 有效发送统计（排除重传） ============
    // 首次发送的请求数（不含重传）
    static AtomicLong totalSentRequests = new AtomicLong(0);
    // 实验开始时间
    static long clientExperimentStartTime = 0;
    // ================================================

    // New: Workload Phase definition
    static class WorkloadPhase {
        long durationMs;
        double rate;
        int payloadSize;

        public WorkloadPhase(long durationMs, double rate, int payloadSize) {
            this.durationMs = durationMs;
            this.rate = rate;
            this.payloadSize = payloadSize;
        }
    }
    
    public static void main(String[] args) throws IOException {
        if (args.length < 8) {
            System.out.println("Usage: ... AsyncDynamicClient <initId> <numThreads> <numberOfOps> <requestSize> <interval> <readOnly> <verbose> <sign> [targetRate] [workloadConfig]");
            System.exit(-1);
        }

        initId = Integer.parseInt(args[0]);
        int numThreads = Integer.parseInt(args[1]);
        int numberOfOps = Integer.parseInt(args[2]);
        int requestSize = Integer.parseInt(args[3]);
        int interval = Integer.parseInt(args[4]);
        boolean readOnly = Boolean.parseBoolean(args[5]);
        boolean verbose = Boolean.parseBoolean(args[6]);
        String sign = args[7];

        double targetRate = -1; // Default -1 means no rate limit (full speed)
        if (args.length > 8) {
             targetRate = Double.parseDouble(args[8]);
             System.out.println("Rate limit enabled: " + targetRate + " ops/sec per client");
        }

        // New: Load dynamic workload config if provided
        List<WorkloadPhase> phases = null;
        if (args.length > 9) {
            String configPath = args[9];
            phases = loadWorkloadConfig(configPath);
            if (phases != null && !phases.isEmpty()) {
                System.out.println("Loaded " + phases.size() + " phases from " + configPath);
                System.out.println("Running in DYNAMIC WORKLOAD mode (Ignoring numberOfOps for duration)");
            }
        }
        
        int s = 0;
        if (!sign.equalsIgnoreCase("nosig")) s++;
        if (sign.equalsIgnoreCase("ecdsa")) s++;
        
        if (s == 2 && Security.getProvider("SunEC") == null) {
            
            System.out.println("Option 'ecdsa' requires SunEC provider to be available.");
            System.exit(0);
        }
        
        // Start global rate monitoring timer
        Timer globalRateTimer = new Timer(true);
        globalRateTimer.scheduleAtFixedRate(new TimerTask() {
            long lastOps = 0;
            @Override
            public void run() {
                long currentOps = globalOpsCounter.get();
                long delta = currentOps - lastOps;
                lastOps = currentOps;
                if (delta > 0 || currentOps > 0) {
                    System.out.println("[Total Client Throughput] " + delta + " ops/sec");
                }
            }
        }, 1000, 1000);

        Client[] clients = new Client[numThreads];

        for (int i = 0; i < numThreads; i++) {
            try {
                Thread.sleep(100);
            } catch (InterruptedException ex) {
                ex.printStackTrace();
            }

            System.out.println("Launching client " + (initId + i));
            clients[i] = new AsyncDynamicClient.Client(initId + i, numberOfOps, requestSize, interval, readOnly, verbose, s, targetRate, phases);
        }
        
        ExecutorService exec = Executors.newFixedThreadPool(clients.length);
        Collection<Future<?>> tasks = new LinkedList<>();
        
        for (Client c : clients) {
            tasks.add(exec.submit(c));
        }
        
        // wait for tasks completion
        for (Future<?> currTask : tasks) {
            try {
                currTask.get();
            } catch (Exception ex) {
                ex.printStackTrace();
            }

        }
    
        exec.shutdown();
        
        // ============ 输出有效发送统计 ============
        long totalSent = totalSentRequests.get();
        long durationMs = System.currentTimeMillis() - clientExperimentStartTime;
        double durationSec = durationMs / 1000.0;
        double avgRate = durationSec > 0 ? totalSent / durationSec : 0;
        
        System.out.println("========================================");
        System.out.println("[Client Workload] FINAL STATISTICS");
        System.out.println("========================================");
        System.out.println("[Client Workload] Total requests sent (excluding retransmissions): " + totalSent);
        System.out.println("[Client Workload] Experiment duration: " + String.format("%.2f", durationSec) + " seconds");
        System.out.println("[Client Workload] Average send rate: " + String.format("%.2f", avgRate) + " ops/sec");
        System.out.println("========================================");
        // ==========================================

        System.out.println("All clients done.");

    }
    
    private static List<WorkloadPhase> loadWorkloadConfig(String path) {
        List<WorkloadPhase> list = new ArrayList<>();
        try (BufferedReader br = new BufferedReader(new FileReader(path))) {
            String line;
            while ((line = br.readLine()) != null) {
                line = line.trim();
                // Skip empty lines or comments
                if (line.isEmpty() || line.startsWith("#")) continue;
                
                String[] parts = line.split(",");
                if (parts.length >= 3) {
                    try {
                        long duration = Long.parseLong(parts[0].trim()) * 1000; // Config is in seconds, store as ms
                        double rate = Double.parseDouble(parts[1].trim());
                        int size = Integer.parseInt(parts[2].trim());
                        list.add(new WorkloadPhase(duration, rate, size));
                    } catch (NumberFormatException e) {
                        System.err.println("Skipping invalid config line: " + line);
                    }
                }
            }
        } catch (Exception e) {
            e.printStackTrace();
            return null;
        }
        return list;
    }

    static class Client extends Thread {

        int id;
        AsynchServiceProxy serviceProxy;
        int numberOfOps;
        int interval;
        TOMMessageType reqType;
        boolean verbose;
        Random rand;
        int rampup = 3000;
        int signMode;
        
        // Static mode params
        int initialRequestSize;
        double initialTargetRate;
        
        // Dynamic mode params
        List<WorkloadPhase> phases;

        // Current buffer (regenerated for each phase)
        byte[] requestBuffer;
        
        // Added for rate monitoring
        private final double targetRate; // Kept for backward compat in static mode logic

        public Client(int id, int numberOfOps, int requestSize, int interval, boolean readOnly, boolean verbose, int sign, double targetRate, List<WorkloadPhase> phases) {

            this.id = id;
            this.serviceProxy = new AsynchServiceProxy(id);
            this.targetRate = targetRate; // For static mode logic
            
            this.numberOfOps = numberOfOps;
            this.initialRequestSize = requestSize;
            this.interval = interval;
            this.reqType = (readOnly ? TOMMessageType.UNORDERED_REQUEST : TOMMessageType.ORDERED_REQUEST);
            this.verbose = verbose;
            this.signMode = sign;
            this.phases = phases;

            this.rand = new Random(System.nanoTime() + this.id);
            
            // Generate initial request buffer based on static config (default)
            // If dynamic phases exist, this might be overwritten immediately in runDynamic()
            generateRequestBuffer(requestSize);
        }
        
        private void generateRequestBuffer(int size) {
            byte[] payload = new byte[size];
            rand.nextBytes(payload);
            
            byte[] signature = new byte[0];
            Signature eng;
            
            try {
                if (signMode > 0) {
                    if (signMode == 1) {
                        eng = TOMUtil.getSigEngine();
                        eng.initSign(serviceProxy.getViewManager().getStaticConf().getPrivateKey());
                    } else {
                        eng = Signature.getInstance("SHA256withECDSA", "SunEC");
                        KeyFactory kf = KeyFactory.getInstance("EC", "SunEC");
                        Base64.Decoder b64 = Base64.getDecoder();
                        PKCS8EncodedKeySpec spec = new PKCS8EncodedKeySpec(b64.decode(ThroughputLatencyClient.privKey));
                        eng.initSign(kf.generatePrivate(spec));
                    }
                    eng.update(payload);
                    signature = eng.sign();
                }

                ByteBuffer buffer = ByteBuffer.allocate(payload.length + signature.length + (Integer.BYTES * 2));
                buffer.putInt(payload.length);
                buffer.put(payload);
                buffer.putInt(signature.length);
                buffer.put(signature);
                this.requestBuffer = buffer.array();
                
            } catch (NoSuchAlgorithmException | SignatureException | NoSuchProviderException | InvalidKeyException | InvalidKeySpecException ex) {
                ex.printStackTrace();
                System.exit(0);
            }
        }

        public void run() {

            try {
                if (this.verbose) System.out.println("Executing experiment.");

                // 记录全局实验开始时间（只设置一次）
                synchronized (AsyncDynamicClient.class) {
                    if (AsyncDynamicClient.clientExperimentStartTime == 0) {
                        AsyncDynamicClient.clientExperimentStartTime = System.currentTimeMillis();
                        System.out.println("[Client Workload] Experiment started at " + AsyncDynamicClient.clientExperimentStartTime);
                    }
                }
                
                if (this.phases != null && !this.phases.isEmpty()) {
                    runDynamic();
                } else {
                    runStatic();
                }

            } catch (Exception e) {
                e.printStackTrace();
            } finally {
                this.serviceProxy.close();
            }
        }
        
        private void runDynamic() {
            int phaseIdx = 0;
            // Iterate through phases
            for (WorkloadPhase phase : phases) {
                phaseIdx++;
                long phaseDurationNs = phase.durationMs * 1_000_000L;
                double currentRate = phase.rate;
                
                if (verbose || id == initId) {
                    System.out.println(String.format("[Client %d] Starting Phase %d: Duration=%ds, Rate=%.1f ops/s, Size=%d bytes", 
                            id, phaseIdx, phase.durationMs/1000, currentRate, phase.payloadSize));
                }
                
                // 1. Regenerate buffer if needed (or just always regenerate to be safe)
                generateRequestBuffer(phase.payloadSize);
                
                // 2. Loop for the duration
                long phaseStartTime = System.nanoTime();
                long phaseEndTime = phaseStartTime + phaseDurationNs;
                
                long phaseOpsCount = 0;
                
                while (System.nanoTime() < phaseEndTime) {
                    // Rate Limiting specific to this phase
                    long[] result = performRateLimiting(phaseOpsCount, phaseStartTime, currentRate);
                    phaseStartTime = result[0];
                    phaseOpsCount = result[1];
                    
                    // Send
                    sendRequest();
                    
                    phaseOpsCount++;
                }
            }
        }
        
        private void runStatic() throws InterruptedException {
            Storage st = new Storage(this.numberOfOps / 2);
            long startExperimentTime = System.nanoTime();
            long opsCount = 0;

            for (int i = 0; i < this.numberOfOps; i++) {
                
                // --- Rate Limiting Logic (Legacy) ---
                long[] result = performRateLimiting(opsCount, startExperimentTime, this.targetRate);
                startExperimentTime = result[0];
                opsCount = result[1];
                // ---------------------------

                long last_send_instant = System.nanoTime();
                sendRequest();
                opsCount++;

                if (i > (this.numberOfOps / 2)) st.store(System.nanoTime() - last_send_instant);

                // Original "interval" based limiting (Poisson/Random Sleep)
                // If targetRate is set, we disable the original interval logic to avoid conflict
                if (this.targetRate <= 0 && (this.interval > 0 || this.rampup > 0)) {
                    int randomInterval = this.interval > 0 ? rand.nextInt(this.interval) : 0;
                    Thread.sleep(Math.max(randomInterval + 1, this.rampup));
                    if (this.rampup > 0) this.rampup -= 100;
                }
                
                if (this.verbose) System.out.println("Sending " + (i + 1) + "th op");
            }
            
            Thread.sleep(100); // Wait for replies
            
            if(this.id == initId) {
               System.out.println(this.id + " // Average time for " + numberOfOps / 2 + " executions (-10%) = " + st.getAverage(true) / 1000 + " us ");
               System.out.println(this.id + " // Standard desviation for " + numberOfOps / 2 + " executions (-10%) = " + st.getDP(true) / 1000 + " us ");
            }
        }
        
        /**
         * @return [adjustedStartTime, adjustedOpsCount] - baseline may be reset if too far behind
         */
        private long[] performRateLimiting(long opsCount, long startTime, double rate) {
            if (rate > 0) {
                double expectedTimeSinceStartSec = (opsCount) / rate;
                long expectedTimeSinceStartNano = (long) (expectedTimeSinceStartSec * 1_000_000_000L);
                long now = System.nanoTime();
                long actualTimeSinceStartNano = now - startTime;
                
                long sleepNano = expectedTimeSinceStartNano - actualTimeSinceStartNano;
                
                if (sleepNano > 0) {
                    long sleepMillis = sleepNano / 1_000_000L;
                    int sleepNanos = (int) (sleepNano % 1_000_000L);
                    try {
                        Thread.sleep(sleepMillis, sleepNanos);
                    } catch (InterruptedException e) {
                        // Ignore
                    }
                } else if (-sleepNano > 1_000_000_000L) {
                    // More than 1 second behind schedule - reset baseline instead of
                    // trying to catch up, which would cause uncontrolled bursting
                    startTime = now - (long)(1.0 / rate * 1_000_000_000L);
                    opsCount = 1;
                }
            }
            return new long[]{startTime, opsCount};
        }
        
        private void sendRequest() {
            // ============ 统计有效发送（首次发送，不含重传） ============
            AsyncDynamicClient.totalSentRequests.incrementAndGet();
            // ==========================================================
            
            this.serviceProxy.invokeAsynchRequest(this.requestBuffer, new ReplyListener() {

                private int replies = 0;

                @Override
                public void reset() {

                    if (verbose) System.out.println("[RequestContext] The proxy is re-issuing the request to the replicas");
                    replies = 0;
                }

                @Override
                public void replyReceived(RequestContext context, TOMMessage reply) {
                    // Verbose check removed for brevity, relies on flag
                    if (verbose) {
                        StringBuilder builder = new StringBuilder();
                        builder.append("[RequestContext] id: " + context.getReqId() + " type: " + context.getRequestType());
                        builder.append("[TOMMessage reply] sender id: " + reply.getSender() + " Hash content: " + Arrays.toString(reply.getContent()));
                        System.out.println(builder.toString());
                    }

                    replies++;

                    double q = Math.ceil((double) (serviceProxy.getViewManager().getCurrentViewN() + serviceProxy.getViewManager().getCurrentViewF() + 1) / 2.0);

                    if (replies >= q) {
                        if (verbose) System.out.println("[RequestContext] clean request context id: " + context.getReqId());
                        serviceProxy.cleanAsynchRequest(context.getOperationId());
                    }
                }
            }, this.reqType);
            
            // Increment global counter for rate monitoring
            AsyncDynamicClient.globalOpsCounter.incrementAndGet();
        }

    }
}
