/**
 * TimedLatencyClient - A client that runs for a specified duration instead of a fixed number of operations.
 * Suitable for long-running RL training experiments.
 * 
 * Usage: TimedLatencyClient <initial_id> <num_clients> <duration_seconds> <request_size> <read_only> <verbose> <nosig|default|ecdsa> [target_rate]
 */
package bftsmart.demo.microbenchmarks;

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
import java.util.Base64;
import java.util.Collection;
import java.util.LinkedList;
import java.util.Random;
import java.util.Timer;
import java.util.TimerTask;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

import bftsmart.communication.client.ReplyListener;
import bftsmart.tom.AsynchServiceProxy;
import bftsmart.tom.RequestContext;
import bftsmart.tom.core.messages.TOMMessage;
import bftsmart.tom.core.messages.TOMMessageType;
import bftsmart.tom.util.TOMUtil;

public class TimedLatencyClient {

    static int initId;
    static AtomicLong globalOpsCounter = new AtomicLong(0);
    static AtomicLong globalLatencySum = new AtomicLong(0);
    static AtomicLong globalLatencyCount = new AtomicLong(0);
    
    // Shared stop signal for all clients
    static AtomicBoolean stopSignal = new AtomicBoolean(false);
    
    public static void main(String[] args) throws IOException {
        if (args.length < 7) {
            System.out.println("Usage: TimedLatencyClient <initial_id> <num_clients> <duration_seconds> <request_size> <read_only> <verbose> <nosig|default|ecdsa> [target_rate_per_client]");
            System.out.println("Example: TimedLatencyClient 1001 10 300 1024 false false nosig -1");
            System.out.println("  This runs 10 clients for 300 seconds (5 minutes) with 1KB requests at full speed.");
            System.exit(-1);
        }

        initId = Integer.parseInt(args[0]);
        int numThreads = Integer.parseInt(args[1]);
        int durationSeconds = Integer.parseInt(args[2]);
        int requestSize = Integer.parseInt(args[3]);
        boolean readOnly = Boolean.parseBoolean(args[4]);
        boolean verbose = Boolean.parseBoolean(args[5]);
        String sign = args[6];

        double targetRate = -1;
        if (args.length > 7) {
            targetRate = Double.parseDouble(args[7]);
            if (targetRate > 0) {
                System.out.println("Rate limit enabled: " + targetRate + " ops/sec per client");
            }
        }
        
        int s = 0;
        if (!sign.equalsIgnoreCase("nosig")) s++;
        if (sign.equalsIgnoreCase("ecdsa")) s++;
        
        if (s == 2 && Security.getProvider("SunEC") == null) {
            System.out.println("Option 'ecdsa' requires SunEC provider to be available.");
            System.exit(0);
        }

        System.out.println("=".repeat(60));
        System.out.println("TimedLatencyClient Configuration:");
        System.out.println("  Clients: " + numThreads);
        System.out.println("  Duration: " + durationSeconds + " seconds (" + (durationSeconds / 60.0) + " minutes)");
        System.out.println("  Request Size: " + requestSize + " bytes");
        System.out.println("  Read Only: " + readOnly);
        System.out.println("  Rate Limit: " + (targetRate > 0 ? targetRate + " ops/s/client" : "unlimited"));
        System.out.println("=".repeat(60));
        
        // Schedule stop signal
        Timer stopTimer = new Timer();
        stopTimer.schedule(new TimerTask() {
            @Override
            public void run() {
                System.out.println("\n[TimedClient] Duration reached. Signaling clients to stop...");
                stopSignal.set(true);
            }
        }, durationSeconds * 1000L);
        
        // Start throughput monitoring
        Timer monitorTimer = new Timer(true);
        monitorTimer.scheduleAtFixedRate(new TimerTask() {
            long lastOps = 0;
            long lastLatSum = 0;
            long lastLatCount = 0;
            
            @Override
            public void run() {
                long currentOps = globalOpsCounter.get();
                long currentLatSum = globalLatencySum.get();
                long currentLatCount = globalLatencyCount.get();
                
                long deltaOps = currentOps - lastOps;
                long deltaLatSum = currentLatSum - lastLatSum;
                long deltaLatCount = currentLatCount - lastLatCount;
                
                double avgLat = deltaLatCount > 0 ? (deltaLatSum / (double) deltaLatCount) / 1000.0 : 0;
                
                System.out.println(String.format("[Throughput] %d ops/sec | Avg Latency: %.2f us | Total: %d ops",
                    deltaOps, avgLat, currentOps));
                
                lastOps = currentOps;
                lastLatSum = currentLatSum;
                lastLatCount = currentLatCount;
            }
        }, 1000, 1000);

        // Create and start clients
        Client[] clients = new Client[numThreads];
        for (int i = 0; i < numThreads; i++) {
            try {
                Thread.sleep(100);
            } catch (InterruptedException ex) {
                ex.printStackTrace();
            }
            System.out.println("Launching client " + (initId + i));
            clients[i] = new Client(initId + i, requestSize, readOnly, verbose, s, targetRate);
        }
        
        ExecutorService exec = Executors.newFixedThreadPool(clients.length);
        Collection<Future<?>> tasks = new LinkedList<>();
        
        for (Client c : clients) {
            tasks.add(exec.submit(c));
        }
        
        // Wait for all clients to finish
        for (Future<?> currTask : tasks) {
            try {
                currTask.get();
            } catch (Exception ex) {
                ex.printStackTrace();
            }
        }
        
        exec.shutdown();
        stopTimer.cancel();
        monitorTimer.cancel();
        
        // Print final statistics
        System.out.println("\n" + "=".repeat(60));
        System.out.println("Final Statistics:");
        System.out.println("  Total Operations: " + globalOpsCounter.get());
        System.out.println("  Duration: " + durationSeconds + " seconds");
        System.out.println("  Average Throughput: " + (globalOpsCounter.get() / durationSeconds) + " ops/sec");
        if (globalLatencyCount.get() > 0) {
            System.out.println("  Average Latency: " + (globalLatencySum.get() / globalLatencyCount.get() / 1000.0) + " us");
        }
        System.out.println("=".repeat(60));
        System.out.println("All clients done.");
        
        System.exit(0);
    }

    static class Client extends Thread {
        int id;
        AsynchServiceProxy serviceProxy;
        byte[] request;
        TOMMessageType reqType;
        boolean verbose;
        Random rand;
        int rampup = 3000;
        double targetRate;

        public Client(int id, int requestSize, boolean readOnly, boolean verbose, int sign, double targetRate) {
            this.id = id;
            this.serviceProxy = new AsynchServiceProxy(id);
            this.targetRate = targetRate;
            this.reqType = readOnly ? TOMMessageType.UNORDERED_REQUEST : TOMMessageType.ORDERED_REQUEST;
            this.verbose = verbose;
            this.request = new byte[requestSize];
            
            rand = new Random(System.nanoTime() + this.id);
            rand.nextBytes(request);
            
            byte[] signature = new byte[0];
            Signature eng;
            
            try {
                if (sign > 0) {
                    if (sign == 1) {
                        eng = TOMUtil.getSigEngine();
                        eng.initSign(serviceProxy.getViewManager().getStaticConf().getPrivateKey());
                    } else {
                        eng = Signature.getInstance("SHA256withECDSA", "SunEC");
                        KeyFactory kf = KeyFactory.getInstance("EC", "SunEC");
                        Base64.Decoder b64 = Base64.getDecoder();
                        PKCS8EncodedKeySpec spec = new PKCS8EncodedKeySpec(b64.decode(ThroughputLatencyClient.privKey));
                        eng.initSign(kf.generatePrivate(spec));
                    }
                    eng.update(request);
                    signature = eng.sign();
                }

                ByteBuffer buffer = ByteBuffer.allocate(request.length + signature.length + (Integer.BYTES * 2));
                buffer.putInt(request.length);
                buffer.put(request);
                buffer.putInt(signature.length);
                buffer.put(signature);
                this.request = buffer.array();

            } catch (NoSuchAlgorithmException | SignatureException | NoSuchProviderException | InvalidKeyException | InvalidKeySpecException ex) {
                ex.printStackTrace();
                System.exit(0);
            }
        }

        @Override
        public void run() {
            long startTime = System.nanoTime();
            long opCount = 0;
            
            // Rampup phase
            while (!stopSignal.get() && rampup > 0) {
                final long sendTime = System.nanoTime();
                
                serviceProxy.invokeAsynchRequest(this.request, new ReplyListener() {
                    private int replies = 0;
                    
                    @Override
                    public void reset() {
                        replies = 0;
                    }

                    @Override
                    public void replyReceived(RequestContext context, TOMMessage reply) {
                        replies++;
                        double q = Math.ceil((double) (serviceProxy.getViewManager().getCurrentViewN() 
                                + serviceProxy.getViewManager().getCurrentViewF() + 1) / 2.0);
                        
                        if (replies >= q) {
                            long latency = System.nanoTime() - sendTime;
                            globalOpsCounter.incrementAndGet();
                            globalLatencySum.addAndGet(latency);
                            globalLatencyCount.incrementAndGet();
                            serviceProxy.cleanAsynchRequest(context.getOperationId());
                        }
                    }
                }, reqType);
                
                opCount++;
                
                try {
                    Thread.sleep(rampup);
                    rampup -= 100;
                } catch (InterruptedException e) {
                    break;
                }
            }
            
            // Main phase - run until stop signal
            while (!stopSignal.get()) {
                // Rate limiting
                if (targetRate > 0) {
                    double expectedTimeSec = opCount / targetRate;
                    long expectedTimeNano = (long) (expectedTimeSec * 1_000_000_000L);
                    long actualTimeNano = System.nanoTime() - startTime;
                    long sleepNano = expectedTimeNano - actualTimeNano;
                    
                    if (sleepNano > 0) {
                        try {
                            Thread.sleep(sleepNano / 1_000_000L, (int) (sleepNano % 1_000_000L));
                        } catch (InterruptedException e) {
                            break;
                        }
                    }
                }
                
                final long sendTime = System.nanoTime();
                
                serviceProxy.invokeAsynchRequest(this.request, new ReplyListener() {
                    private int replies = 0;
                    
                    @Override
                    public void reset() {
                        replies = 0;
                    }

                    @Override
                    public void replyReceived(RequestContext context, TOMMessage reply) {
                        replies++;
                        double q = Math.ceil((double) (serviceProxy.getViewManager().getCurrentViewN() 
                                + serviceProxy.getViewManager().getCurrentViewF() + 1) / 2.0);
                        
                        if (replies >= q) {
                            long latency = System.nanoTime() - sendTime;
                            globalOpsCounter.incrementAndGet();
                            globalLatencySum.addAndGet(latency);
                            globalLatencyCount.incrementAndGet();
                            serviceProxy.cleanAsynchRequest(context.getOperationId());
                        }
                    }
                }, reqType);
                
                opCount++;
                
                if (verbose && opCount % 10000 == 0) {
                    System.out.println("Client " + id + ": " + opCount + " operations sent");
                }
            }
            
            // Wait a bit for pending replies
            try {
                Thread.sleep(500);
            } catch (InterruptedException e) {
                // ignore
            }
            
            serviceProxy.close();
            System.out.println("Client " + id + " finished. Total ops: " + opCount);
        }
    }
}
