/**
Copyright (c) 2007-2013 Alysson Bessani, Eduardo Alchieri, Paulo Sousa, and the authors indicated in the @author tags

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package bftsmart.demo.microbenchmarks;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.ObjectOutputStream;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.security.InvalidKeyException;
import java.security.NoSuchAlgorithmException;
import java.security.NoSuchProviderException;
import java.security.Security;
import java.security.Signature;
import java.security.SignatureException;
import java.security.cert.CertificateException;
import java.security.cert.CertificateFactory;
import java.util.Base64;
import java.util.concurrent.atomic.AtomicLong;
import java.util.logging.Level;
import java.util.logging.Logger;

import bftsmart.demo.rlWrapper.ConfigChangeRequest;
import bftsmart.demo.rlWrapper.RLAgentConnector;
import bftsmart.tom.MessageContext;
import bftsmart.tom.ServiceReplica;
import bftsmart.tom.core.messages.TOMMessage;
import bftsmart.tom.server.defaultservices.CommandsInfo;
import bftsmart.tom.server.defaultservices.DefaultRecoverable;
import bftsmart.tom.util.Storage;
import bftsmart.tom.util.TOMUtil;

/**
 * Simple server that just acknowledge the reception of a request.
 */
public final class ThroughputLatencyServer extends DefaultRecoverable{
    
    private int interval;
    private byte[] reply;
    private float maxTp = -1;
    private boolean context;
    private int signed;
    
    private byte[] state;
    
    private int iterations = 0;
    private long throughputMeasurementStartTime = System.currentTimeMillis();
            
    private Storage totalLatency = null;
    private Storage consensusLatency = null;
    private Storage preConsLatency = null;
    private Storage posConsLatency = null;
    private Storage proposeLatency = null;
    private Storage writeLatency = null;
    private Storage acceptLatency = null;
    
    private Storage batchSize = null;
    
    private ServiceReplica replica;
    
    private RandomAccessFile randomAccessFile = null;
    private FileChannel channel = null;

    private AtomicLong timeBasedOpsCount = new AtomicLong(0);
    private AtomicLong timeBasedTotalLatency = new AtomicLong(0);
    private AtomicLong timeBasedLatSamples = new AtomicLong(0);

    // ============ 新增：消息大小统计 ============
    private AtomicLong timeBasedTotalSize = new AtomicLong(0);      // 累计消息大小（字节）
    private AtomicLong timeBasedSizeSamples = new AtomicLong(0);    // 消息数量（用于计算平均大小）
    // =============================================

    // ============ 共识轮延迟统计 ============
    private AtomicLong timeBasedConsensusLatency = new AtomicLong(0);   // 累计共识延迟 (ns)
    private AtomicLong timeBasedConsensusLatSamples = new AtomicLong(0); // 共识延迟样本数
    // =============================================

    // ============ Goodput 统计器 ============
    // 总处理消息数（不含重复，用于计算 Goodput）
    private AtomicLong totalGoodputOps = new AtomicLong(0);
    // 实验开始时间
    private long experimentStartTime = 0;
    // ========================================

    // RL Connector
    private RLAgentConnector rlConnector;
    private Thread rlThread;

    public class MetricsSnapshot {
        public long ops;
        public long latencySum;
        public long latencySamples;
        public long timeWindow; // in ms
        
        // 新增字段
        public long totalSize;       // 累计消息大小（字节）
        public long sizeSamples;     // 消息数量
        public long consensusLatencySum;   // 累计共识延迟 (ns)
        public long consensusLatSamples;   // 共识延迟样本数

        public MetricsSnapshot(long ops, long latencySum, long latencySamples, long timeWindow,
                               long totalSize, long sizeSamples,
                               long consensusLatencySum, long consensusLatSamples) {
            this.ops = ops;
            this.latencySum = latencySum;
            this.latencySamples = latencySamples;
            this.timeWindow = timeWindow;
            this.totalSize = totalSize;
            this.sizeSamples = sizeSamples;
            this.consensusLatencySum = consensusLatencySum;
            this.consensusLatSamples = consensusLatSamples;
        }
    }

    private long lastMetricsResetTime = System.currentTimeMillis();

    public synchronized MetricsSnapshot getAndResetMetrics() {
        long now = System.currentTimeMillis();
        long window = now - lastMetricsResetTime;
        if (window <= 0) window = 1;

        long ops = timeBasedOpsCount.getAndSet(0);
        long latSum = timeBasedTotalLatency.getAndSet(0);
        long latSamp = timeBasedLatSamples.getAndSet(0);
        
        // 新增：重置 size 统计
        long totalSize = timeBasedTotalSize.getAndSet(0);
        long sizeSamp = timeBasedSizeSamples.getAndSet(0);

        // 新增：重置共识延迟统计
        long consLatSum = timeBasedConsensusLatency.getAndSet(0);
        long consLatSamp = timeBasedConsensusLatSamples.getAndSet(0);

        lastMetricsResetTime = now;

        return new MetricsSnapshot(ops, latSum, latSamp, window, totalSize, sizeSamp, consLatSum, consLatSamp);
    }

    // ============ Goodput 统计方法 ============
    /**
     * 获取当前 Goodput 统计
     * @return 总处理请求数
     */
    public long getTotalGoodput() {
        return totalGoodputOps.get();
    }

    /**
     * 获取实验运行时间（毫秒）
     */
    public long getExperimentDurationMs() {
        if (experimentStartTime == 0) return 0;
        return System.currentTimeMillis() - experimentStartTime;
    }

    /**
     * 打印最终 Goodput 统计
     */
    public void printFinalGoodputStats() {
        long totalOps = totalGoodputOps.get();
        long durationMs = getExperimentDurationMs();
        double durationSec = durationMs / 1000.0;
        double avgThroughput = durationSec > 0 ? totalOps / durationSec : 0;

        System.out.println("========================================");
        System.out.println("[Goodput] FINAL STATISTICS");
        System.out.println("========================================");
        System.out.println("[Goodput] Total requests processed: " + totalOps);
        System.out.println("[Goodput] Experiment duration: " + durationSec + " seconds");
        System.out.println("[Goodput] Average throughput: " + String.format("%.2f", avgThroughput) + " ops/sec");
        System.out.println("========================================");
    }
    // ==========================================

    public ThroughputLatencyServer(int id, int interval, int replySize, int stateSize, boolean context,  int signed, int write) {

        this.interval = interval;
        this.context = context;
        this.signed = signed;
        
        this.reply = new byte[replySize];
        
        for (int i = 0; i < replySize ;i++)
            reply[i] = (byte) i;
        
        this.state = new byte[stateSize];
        
        for (int i = 0; i < stateSize ;i++)
            state[i] = (byte) i;

        totalLatency = new Storage(interval);
        consensusLatency = new Storage(interval);
        preConsLatency = new Storage(interval);
        posConsLatency = new Storage(interval);
        proposeLatency = new Storage(interval);
        writeLatency = new Storage(interval);
        acceptLatency = new Storage(interval);
        
        batchSize = new Storage(interval);
        
        if (write > 0) {
            
            try {
                final File f = File.createTempFile("bft-"+id+"-", Long.toString(System.nanoTime()));
                randomAccessFile = new RandomAccessFile(f, (write > 1 ? "rwd" : "rw"));
                channel = randomAccessFile.getChannel();
                
                Runtime.getRuntime().addShutdownHook(new Thread() {
                    
                    @Override
                    public void run() {
                        
                        f.delete();
                    }
                });
            } catch (IOException ex) {
                ex.printStackTrace();
                System.exit(0);
            }
        }

        // Start Time-based statistics timer
        // Commented out to avoid conflict with RLAgentConnector
        /*
        Timer timer = new Timer(true);
        timer.scheduleAtFixedRate(new TimerTask() {
            @Override
            public void run() {
                long ops = timeBasedOpsCount.getAndSet(0);
                long latSum = timeBasedTotalLatency.getAndSet(0);
                long latCount = timeBasedLatSamples.getAndSet(0);

                double tps = (double) ops; // Loop is 1 sec
                double avgLat = latCount > 0 ? (double) latSum / latCount : 0;

                System.out.println(String.format("[Time-Based 1s] TPS: %.2f | Avg Latency: %.2f us", tps, avgLat / 1000));
            }
        }, 1000, 1000);
        */

        replica = new ServiceReplica(id, this, this);

        // Initialize and start RL Agent Connector
        rlConnector = new RLAgentConnector(replica, this);
        // Read agent port from system property (default 45678), supports per-replica ports in local deployment
        int agentPort = Integer.parseInt(System.getProperty("agent.port", "45678"));
        if (rlConnector.connectToAgent("localhost", agentPort)) {
           rlThread = new Thread(rlConnector::startMonitoringLoop);
           rlThread.setName("RL-Agent-Connector");
           rlThread.setDaemon(true);
           rlThread.start(); 
        } else {
            System.out.println("--- Failed to connect to RL Agent. Running in static mode. ---");
        }
    }
    
    // Logger for appExecuteBatch (re-uses the class-level java.util.logging.Logger already imported)
    private static final org.slf4j.Logger batchLogger =
            org.slf4j.LoggerFactory.getLogger(ThroughputLatencyServer.class);

    @Override
    public byte[][] appExecuteBatch(byte[][] commands, MessageContext[] msgCtxs, boolean fromConsensus) {
        
        batchSize.store(commands.length);
                
        byte[][] replies = new byte[commands.length][];
        
        for (int i = 0; i < commands.length; i++) {

            // ── Consensus-agreed config change ───────────────────────────────
            // A ConfigChangeRequest payload is submitted via invokeOrdered by replica 0
            // and delivered here on ALL replicas at the same consensus point, guaranteeing
            // that every correct replica applies the new parameter simultaneously.
            if (ConfigChangeRequest.isConfigChange(commands[i])) {
                try {
                    int[] decoded = ConfigChangeRequest.decode(commands[i]);
                    if (decoded[0] == ConfigChangeRequest.TYPE_REQUEST_TIMEOUT) {
                        batchLogger.info("[ConsensusConfig] Delivering requestTimeout={} on replica {}",
                                decoded[1], replica.getId());
                        replica.applyConsensusRequestTimeout(decoded[1]);
                    } else {
                        batchLogger.warn("[ConsensusConfig] Unknown config type {} – ignored.", decoded[0]);
                    }
                } catch (Exception e) {
                    batchLogger.error("[ConsensusConfig] Error processing config-change payload", e);
                }
                replies[i] = new byte[0]; // empty ACK to satisfy the proposer's invokeOrdered
                continue;
            }
            // ────────────────────────────────────────────────────────────────

            replies[i] = execute(commands[i],msgCtxs[i]);
            
        }
        
        if (randomAccessFile != null) {
                
            ObjectOutputStream oos = null;
            try {
                CommandsInfo cmd = new CommandsInfo(commands,msgCtxs);
                ByteArrayOutputStream bos = new ByteArrayOutputStream();
                oos = new ObjectOutputStream(bos);
                oos.writeObject(cmd);
                oos.flush();
                byte[] bytes = bos.toByteArray();
                oos.close();
                bos.close();
                
                ByteBuffer bb = ByteBuffer.allocate(bytes.length);
                bb.put(bytes);
                bb.flip();
                
                channel.write(bb);
                channel.force(false);
            } catch (IOException ex) {
                Logger.getLogger(ThroughputLatencyServer.class.getName()).log(Level.SEVERE, null, ex);
                
            } finally {
                try {
                    oos.close();
                } catch (IOException ex) {
                    Logger.getLogger(ThroughputLatencyServer.class.getName()).log(Level.SEVERE, null, ex);
                }
            }
        }
                    
        return replies;
    }
    
    @Override
    public byte[] appExecuteUnordered(byte[] command, MessageContext msgCtx) {
        return execute(command,msgCtx);
    }
    
    public byte[] execute(byte[] command, MessageContext msgCtx) {
        
        // ============ 消息大小统计 ============
        int messageSize = command.length;
        timeBasedTotalSize.addAndGet(messageSize);
        timeBasedSizeSamples.incrementAndGet();
        // =============================================
        
        ByteBuffer buffer = ByteBuffer.wrap(command);
        int l = buffer.getInt();
        byte[] request = new byte[l];
        buffer.get(request);
        l = buffer.getInt();
        byte[] signature = new byte[l];
        
        buffer.get(signature);
        Signature eng;
        
        try {
            
            if (signed > 0) {
                
                if (signed == 1) {
                    
                    eng = TOMUtil.getSigEngine();
                    eng.initVerify(replica.getReplicaContext().getStaticConfiguration().getPublicKey());
                } else {
                
                    eng = Signature.getInstance("SHA256withECDSA", "SunEC");
                    Base64.Decoder b64 = Base64.getDecoder();
                    CertificateFactory kf = CertificateFactory.getInstance("X.509");
                
                    byte[] cert = b64.decode(ThroughputLatencyClient.pubKey);
                    InputStream certstream = new ByteArrayInputStream (cert);
                
                    eng.initVerify(kf.generateCertificate(certstream));
                    
                }
                eng.update(request);
                if (!eng.verify(signature)) {
                    
                    System.out.println("Client sent invalid signature!");
                    System.exit(0);
                }
            }
            
        } catch (NoSuchAlgorithmException | InvalidKeyException | SignatureException | CertificateException ex) {
            ex.printStackTrace();
            System.exit(0);
        } catch (NoSuchProviderException ex) {
            ex.printStackTrace();
            System.exit(0);
        }
        
        boolean readOnly = false;
        
        iterations++;
        timeBasedOpsCount.incrementAndGet();
        
        // ============ Goodput 统计 ============
        long currentGoodput = totalGoodputOps.incrementAndGet();
        // 记录实验开始时间（第一个请求到达时）
        if (currentGoodput == 1) {
            experimentStartTime = System.currentTimeMillis();
            System.out.println("[Goodput] Experiment started at " + experimentStartTime);
        }
        // 每 10000 个请求输出一次进度
        if (currentGoodput % 10000 == 0) {
            long elapsedSec = (System.currentTimeMillis() - experimentStartTime) / 1000;
            System.out.println("[Goodput] Processed " + currentGoodput + " requests in " + elapsedSec + " seconds");
        }
        // ======================================

        if (msgCtx != null && msgCtx.getFirstInBatch() != null) {
            

            readOnly = msgCtx.readOnly;

            // Use the individual request's receptionTime for per-request latency.
            // This ensures that re-admitted (previously flow-control-dropped) requests
            // contribute their full waiting time to the latency statistics.
            TOMMessage currentReq = msgCtx.getCurrentRequest();
            TOMMessage firstReq = msgCtx.getFirstInBatch();
            long executedTimeNow = System.nanoTime();
            firstReq.executedTime = executedTimeNow;

            long latency;
            if (currentReq != null && currentReq.receptionTime > 0) {
                latency = executedTimeNow - currentReq.receptionTime;
            } else {
                latency = executedTimeNow - firstReq.receptionTime;
            }
            totalLatency.store(latency);
            timeBasedTotalLatency.addAndGet(latency);
            timeBasedLatSamples.incrementAndGet();

            if (readOnly == false) {

                long consLat = msgCtx.getFirstInBatch().decisionTime - msgCtx.getFirstInBatch().consensusStartTime;
                consensusLatency.store(consLat);
                timeBasedConsensusLatency.addAndGet(consLat);
                timeBasedConsensusLatSamples.incrementAndGet();
                long temp = msgCtx.getFirstInBatch().consensusStartTime - msgCtx.getFirstInBatch().receptionTime;
                preConsLatency.store(temp > 0 ? temp : 0);
                posConsLatency.store(msgCtx.getFirstInBatch().executedTime - msgCtx.getFirstInBatch().decisionTime);            
                proposeLatency.store(msgCtx.getFirstInBatch().writeSentTime - msgCtx.getFirstInBatch().consensusStartTime);
                writeLatency.store(msgCtx.getFirstInBatch().acceptSentTime - msgCtx.getFirstInBatch().writeSentTime);
                acceptLatency.store(msgCtx.getFirstInBatch().decisionTime - msgCtx.getFirstInBatch().acceptSentTime);
                

            } else {
            
           
                consensusLatency.store(0);
                preConsLatency.store(0);
                posConsLatency.store(0);            
                proposeLatency.store(0);
                writeLatency.store(0);
                acceptLatency.store(0);
                
                
            }
            
        } else {
            
            
                consensusLatency.store(0);
                preConsLatency.store(0);
                posConsLatency.store(0);            
                proposeLatency.store(0);
                writeLatency.store(0);
                acceptLatency.store(0);
                
               
        }
        
        float tp = -1;
        if(iterations % interval == 0) {
            if (context) System.out.println("--- (Context)  iterations: "+ iterations + " // regency: " + msgCtx.getRegency() + " // consensus: " + msgCtx.getConsensusId() + " ---");
            
            System.out.println("--- Measurements after "+ iterations+" ops ("+interval+" samples) ---");
            
            tp = (float)(interval*1000/(float)(System.currentTimeMillis()-throughputMeasurementStartTime));
            
            if (tp > maxTp) maxTp = tp;
            
            System.out.println("Throughput = " + tp +" operations/sec (Maximum observed: " + maxTp + " ops/sec)");            
            
            System.out.println("Total latency = " + totalLatency.getAverage(false) / 1000 + " (+/- "+ (long)totalLatency.getDP(false) / 1000 +") us ");
            totalLatency.reset();
            System.out.println("Consensus latency = " + consensusLatency.getAverage(false) / 1000 + " (+/- "+ (long)consensusLatency.getDP(false) / 1000 +") us ");
            consensusLatency.reset();
            System.out.println("Pre-consensus latency = " + preConsLatency.getAverage(false) / 1000 + " (+/- "+ (long)preConsLatency.getDP(false) / 1000 +") us ");
            preConsLatency.reset();
            System.out.println("Pos-consensus latency = " + posConsLatency.getAverage(false) / 1000 + " (+/- "+ (long)posConsLatency.getDP(false) / 1000 +") us ");
            posConsLatency.reset();
            System.out.println("Propose latency = " + proposeLatency.getAverage(false) / 1000 + " (+/- "+ (long)proposeLatency.getDP(false) / 1000 +") us ");
            proposeLatency.reset();
            System.out.println("Write latency = " + writeLatency.getAverage(false) / 1000 + " (+/- "+ (long)writeLatency.getDP(false) / 1000 +") us ");
            writeLatency.reset();
            System.out.println("Accept latency = " + acceptLatency.getAverage(false) / 1000 + " (+/- "+ (long)acceptLatency.getDP(false) / 1000 +") us ");
            acceptLatency.reset();
            
            System.out.println("Batch average size = " + batchSize.getAverage(false) + " (+/- "+ (long)batchSize.getDP(false) +") requests");
            batchSize.reset();
            
            throughputMeasurementStartTime = System.currentTimeMillis();
        }

        return reply;
    }

    public static void main(String[] args){
        if(args.length < 6) {
            System.out.println("Usage: ... ThroughputLatencyServer <processId> <measurement interval> <reply size> <state size> <context?> <nosig | default | ecdsa> [rwd | rw]");
            System.exit(-1);
        }

        int processId = Integer.parseInt(args[0]);
        int interval = Integer.parseInt(args[1]);
        int replySize = Integer.parseInt(args[2]);
        int stateSize = Integer.parseInt(args[3]);
        boolean context = Boolean.parseBoolean(args[4]);
        String signed = args[5];
        String write = args.length > 6 ? args[6] : "";
        
        int s = 0;
        
        if (!signed.equalsIgnoreCase("nosig")) s++;
        if (signed.equalsIgnoreCase("ecdsa")) s++;
        
        if (s == 2 && Security.getProvider("SunEC") == null) {
            
            System.out.println("Option 'ecdsa' requires SunEC provider to be available.");
            System.exit(0);
        }
        
        int w = 0;
        
        if (!write.equalsIgnoreCase("")) w++;
        if (write.equalsIgnoreCase("rwd")) w++;

        ThroughputLatencyServer server = new ThroughputLatencyServer(processId,interval,replySize, stateSize, context, s, w);
        
        // 添加 shutdown hook，在程序退出时输出 Goodput 统计
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            System.out.println("\n[Shutdown] Server shutting down...");
            server.printFinalGoodputStats();
        }));
    }

    @Override
    public void installSnapshot(byte[] state) {
        //nothing
    }

    @Override
    public byte[] getSnapshot() {
        return this.state;
    }

   
}
