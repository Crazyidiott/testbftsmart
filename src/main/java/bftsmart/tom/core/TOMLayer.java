/*
 * Copyright (c) 2007-2013 Alysson Bessani, Eduardo Alchieri, Paulo Sousa, and
 * the authors indicated in the @author tags
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */
package bftsmart.tom.core;

import java.io.Serializable;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.PublicKey;
import java.security.Signature;
import java.security.SignedObject;
import java.util.HashMap;
import java.util.Timer;
import java.util.TimerTask;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.locks.Condition;
import java.util.concurrent.locks.ReentrantLock;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import bftsmart.clientsmanagement.ClientsManager;
import bftsmart.clientsmanagement.RequestList;
import bftsmart.communication.ServerCommunicationSystem;
import bftsmart.communication.client.RequestReceiver;
import bftsmart.consensus.Consensus;
import bftsmart.consensus.Decision;
import bftsmart.consensus.Epoch;
import bftsmart.consensus.roles.Acceptor;
import bftsmart.reconfiguration.ServerViewController;
import bftsmart.statemanagement.StateManager;
import bftsmart.tom.ServiceReplica;
import bftsmart.tom.core.messages.ForwardedMessage;
import bftsmart.tom.core.messages.TOMMessage;
import bftsmart.tom.core.messages.TOMMessageType;
import bftsmart.tom.leaderchange.RequestsTimer;
import bftsmart.tom.server.Recoverable;
import bftsmart.tom.server.RequestVerifier;
import bftsmart.tom.util.BatchBuilder;
import bftsmart.tom.util.BatchReader;
import bftsmart.tom.util.TOMUtil;

/**
 * This class implements the state machine replication protocol described in
 * Joao Sousa's 'From Byzantine Consensus to BFT state machine replication: a latency-optimal transformation' (May 2012)
 *
 * The synchronization phase described in the paper is implemented in the Synchronizer class
 */
public final class TOMLayer extends Thread implements RequestReceiver {
    private final Logger logger = LoggerFactory.getLogger(this.getClass());

    // 添加这个公共变量用于统计
    public long lcStartTime = 0; 

    private boolean doWork = true;
    private CountDownLatch latch = new CountDownLatch(1);
    private Timer batchTimer = null;
    
    //other components used by the TOMLayer (they are never changed)
    public ExecutionManager execManager; // Execution manager
    public Acceptor acceptor; // Acceptor role of the PaW algorithm
    private final ServerCommunicationSystem communication; // Communication system between replicas
    //private OutOfContextMessageThread ot; // Thread which manages messages that do not belong to the current consensus
    private final DeliveryThread dt; // Thread which delivers total ordered messages to the appication
    public StateManager stateManager; // object which deals with the state transfer protocol

    //thread pool used to paralelise verification of requests contained in a batch
    private final ExecutorService verifierExecutor;

    /**
     * Manage timers for pending requests
     */
    public RequestsTimer requestsTimer;

    private long lastRequest = -1;

    /**
     * Store requests received but still not ordered
     */
    public ClientsManager clientsManager;
    /**
     * The id of the consensus being executed (or -1 if there is none)
     */
    private int inExecution = -1;
    private int lastExecuted = -1;

    public MessageDigest md;
    private Signature engine;

    private final ReentrantLock hashLock = new ReentrantLock();

    //the next two are used to generate non-deterministic data in a deterministic way (by the leader)
    public BatchBuilder bb = new BatchBuilder(System.nanoTime());

    /* The locks and conditions used to wait upon creating a propose */
    private final ReentrantLock leaderLock = new ReentrantLock();
    private final Condition iAmLeader = leaderLock.newCondition();
    private final ReentrantLock messagesLock = new ReentrantLock();
    private final Condition haveMessages = messagesLock.newCondition();
    private final ReentrantLock proposeLock = new ReentrantLock();
    private final Condition canPropose = proposeLock.newCondition();

    private final PrivateKey privateKey;
    private final HashMap<Integer, PublicKey> publicKey;

    public ServerViewController controller;

    private final Synchronizer syncher;

    /**
     * Creates a new instance of TOMulticastLayer
     *
     * @param manager Execution manager
     * @param receiver Object that receives requests from clients
     * @param recoverer Object of a class implementing Recoverable interface for the state management
     * @param a Acceptor role of the PaW algorithm
     * @param cs Communication system between replicas
     * @param controller Reconfiguration Manager
     * @param verifier Implementation of predicate used to verify client requests
     */
    public TOMLayer(ExecutionManager manager,
                    ServiceReplica receiver,
                    Recoverable recoverer,
                    Acceptor a,
                    ServerCommunicationSystem cs,
                    ServerViewController controller,
                    RequestVerifier verifier) {

        super("TOM Layer");

        this.execManager = manager;
        this.acceptor = a;
        this.communication = cs;
        this.controller = controller;

        /*Tulio Ribeiro*/
        this.privateKey = this.controller.getStaticConf().getPrivateKey();
        this.publicKey = new HashMap<>();
        int [] targets  = this.controller.getCurrentViewAcceptors();
        for (int target : targets) {
            publicKey.put(target, controller.getStaticConf().getPublicKey(target));
        }
        // use either the same number of Netty workers threads if specified in the configuration
        // or use a many as the number of cores available
        int nWorkers = this.controller.getStaticConf().getNumNettyWorkers();
        nWorkers = nWorkers > 0 ? nWorkers : Runtime.getRuntime().availableProcessors();
        this.verifierExecutor = Executors.newWorkStealingPool(nWorkers);

        //do not create a timer manager if the timeout is 0
        if (this.controller.getStaticConf().getRequestTimeout() == 0) {
            this.requestsTimer = null;
        } else {
            this.requestsTimer = new RequestsTimer(this, communication, this.controller); // Create requests timers manager (a thread)
        }

        try {
            this.md = TOMUtil.getHashEngine();
        } catch (Exception e) {
            logger.error("Failed to get message digest engine",e);
        }

        try {
            this.engine = TOMUtil.getSigEngine();
        } catch (Exception e) {
            logger.error("Failed to get signature engine",e);
        }

        RequestVerifier verifier1 = (verifier != null) ? verifier : ((request) -> true); // By default, never validate requests

        // I have a verifier, now create clients manager
        this.clientsManager = new ClientsManager(this.controller, requestsTimer, verifier1, cs);


        // If recoverer should use lastReplies of clients to recover, it needs reference to clientsManager
        recoverer.setClientsManager(clientsManager);

        this.dt = new DeliveryThread(this, receiver, recoverer, this.controller); // Create delivery thread
        this.stateManager = recoverer.getStateManager();
        stateManager.init(this, dt);
        this.dt.start();


        this.syncher = new Synchronizer(this); // create synchronizer

        if (controller.getStaticConf().getBatchTimeout() > -1) {
            startBatchTimer();
        }
    }

    public void forwardRequestToLeader(TOMMessage request) {
        int leaderId = execManager.getCurrentLeader();
        if (this.controller.isCurrentViewMember(leaderId)) {
            logger.debug("Forwarding " + request + " to " + leaderId);
            communication.send(new int[]{leaderId},
                    new ForwardedMessage(this.controller.getStaticConf().getProcessId(), request));
        }
    }

    public boolean isBatchTimerEnabled() {
        return batchTimer != null;
    }

    public void onConfigurationChanged() {
        // 1. Handle batchTimer update
        if (controller.getStaticConf().getBatchTimeout() > -1) {
            startBatchTimer();
        } else if (batchTimer != null) {
            batchTimer.cancel();
            batchTimer = null;
        }

        // 2. Handle requestTimeout update (view change timeout)
        if (requestsTimer != null) {
            long newTimeout = controller.getStaticConf().getRequestTimeout();
            requestsTimer.setTimeout(newTimeout);
            logger.info("Request timeout updated to {} ms", newTimeout);
        }
    }

    private void startBatchTimer() {
        if (batchTimer != null) {
            batchTimer.cancel();
        }
        batchTimer = new Timer();
        batchTimer.scheduleAtFixedRate(new TimerTask() {
            @Override
            public void run() {
                if (clientsManager.havePendingRequests() &&
                        (System.currentTimeMillis() - lastRequest) >= controller.getStaticConf().getBatchTimeout()) {

                    logger.debug("Signaling proposer thread!!");
                    haveMessages();
                }
            }
        }, 0, controller.getStaticConf().getBatchTimeout());
    }

    /**
     * Computes an hash for a TOM message
     *
     * @param data Data from which to generate the hash
     * @return Hash for the specified TOM message
     */
    public byte[] computeHash(byte[] data) {
        byte[] ret;
        hashLock.lock();
        ret = md.digest(data);
        hashLock.unlock();

        return ret;
    }

    public SignedObject sign(Serializable obj) {
        try {
            return new SignedObject(obj, privateKey, engine);
        } catch (Exception e) {
            logger.error("Failed to sign object",e);
            return null;
        }
    }

    public void loadPublicKey(int target){
        publicKey.computeIfAbsent(target, v -> controller.getStaticConf().getPublicKey(target));
    }

    /**
     * Verifies the signature of a signed object
     *
     * @param so Signed object to be verified
     * @param sender Replica id that supposedly signed this object
     * @return True if the signature is valid, false otherwise
     */
    public boolean verifySignature(SignedObject so, int sender) {
        try {
            return so.verify(publicKey.get(sender), engine);
        } catch (Exception e) {
            logger.error("Failed to verify object signature",e);
        }
        return false;
    }

    /**
     * Retrieve Communication system between replicas
     *
     * @return Communication system between replicas
     */
    public ServerCommunicationSystem getCommunication() {
        return this.communication;
    }

    public void imAmTheLeader() {
        leaderLock.lock();
        iAmLeader.signal();
        leaderLock.unlock();
    }

    /**
     * Sets which consensus was the last to be executed
     *
     * @param last ID of the consensus which was last to be executed
     */
    public void setLastExec(int last) {
        logger.debug("Setting last exec to " + last);
        this.lastExecuted = last;
    }

    /**
     * Gets the ID of the consensus which was established as the last executed
     *
     * @return ID of the consensus which was established as the last executed
     */
    public int getLastExec() {
        return this.lastExecuted;
    }

    /**
     * Sets which consensus is being executed at the moment
     *
     * @param inEx ID of the consensus being executed at the moment
     */
    public void setInExec(int inEx) {
        proposeLock.lock();
        logger.debug("Modifying inExec from " + this.inExecution + " to " + inEx);
        this.inExecution = inEx;
        if (inEx == -1 && !isRetrievingState()) {
            canPropose.signalAll();
        }
        proposeLock.unlock();
    }

    /**
     * This method blocks until the PaW algorithm is finished
     */
    public void waitForPaxosToFinish() {
        proposeLock.lock();
        canPropose.awaitUninterruptibly();
        proposeLock.unlock();
    }

    /**
     * Gets the ID of the consensus currently beign executed
     *
     * @return ID of the consensus currently beign executed (if no consensus ir
     * executing, -1 is returned)
     */
    public int getInExec() {
        return this.inExecution;
    }

    /**
     * This method is invoked by the communication system to deliver a request.
     * It assumes that the communication system delivers the message in FIFO
     * order.
     *
     * @param msg The request being received
     * @param fromClient Whether the request was received from a client or was part of a forwarded message
     */
    @Override
    public void requestReceived(TOMMessage msg, boolean fromClient) {

        if (!doWork) return;

        switch(msg.getReqType()) {
		case ASK_STATUS:
		case REPLY:
		case STATUS_REPLY:
			// These kind of messages should never enter the replica
			return;
		case RECONFIG:
		case ORDERED_REQUEST:
		case UNORDERED_HASHED_REQUEST:
		case UNORDERED_REQUEST:
			// These messages should be processed
			break;
        }


        // check if this request is valid and add it to the client' pending requests list
        boolean readOnly = (msg.getReqType() == TOMMessageType.UNORDERED_REQUEST
                || msg.getReqType() == TOMMessageType.UNORDERED_HASHED_REQUEST);
        if (readOnly) {
            logger.debug("Received read-only TOMMessage from client " + msg.getSender() + " with sequence number " + msg.getSequence() + " for session " + msg.getSession());

            if (!controller.getStaticConf().useReadOnlyRequests()) {
                logger.warn("!! Received unsupported read request from client " + msg.getSender()  + " with sequence number "
                        + msg.getSequence() + " => I will not deliver this request");
                logger.warn("Please enable the read-only optimization in system.config to support execution of unordered requests");
                return;
            }
            dt.deliverUnordered(msg, syncher.getLCManager().getLastReg());
        } else {
            logger.debug("Received TOMMessage from client " + msg.getSender() + " with sequence number " + msg.getSequence() + " for session " + msg.getSession());

            if (clientsManager.requestReceived(msg, fromClient, communication)) {

                if(controller.getStaticConf().getBatchTimeout() == -1) {
                    haveMessages();
                } else {

                    if (!clientsManager.isNextBatchReady()) {

                        lastRequest = System.currentTimeMillis();

                    } else {

                        haveMessages();
                    }

                }
            } else {
                // [DIAG] Always log at INFO for visibility
                logger.info("[DISCARD] TOMMessage from client {} seq={} session={} was discarded",
                    msg.getSender(), msg.getSequence(), msg.getSession());
            }
        }
    }

    /**
     * Creates a value to be proposed to the acceptors. Invoked if this replica
     * is the leader
     *
     * @param dec Object that will eventually hold the decided value
     * @return A value to be proposed to the acceptors
     */
    public byte[] createPropose(Decision dec) {
        // 1. 安全获取 Pending Requests
        RequestList pendingRequests = clientsManager.getPendingRequests();
        
        // 如果 pendingRequests 为 null，使用空列表代替，防止后续空指针
        if (pendingRequests == null) {
            pendingRequests = new RequestList();
        }

        int numberOfMessages = pendingRequests.size();
        int numberOfNonces = this.controller.getStaticConf().getNumberOfNonces();

        // 2. 填充 Decision 元数据 (如果 dec 不为 null)
        if (dec != null) {
            dec.batchSize = numberOfMessages;
            
            if (dec.getConsensusId() > -1 && numberOfMessages > 0) {
                dec.firstMessageProposed = pendingRequests.getFirst();
                // 再次检查 firstMessageProposed 是否为 null
                if (dec.firstMessageProposed != null) {
                    dec.firstMessageProposed.consensusStartTime = System.nanoTime();
                }
            }
        } else {
            // 如果 dec 为 null，仅打印警告，但继续执行以生成合法的空 Batch
            logger.warn("createPropose received null Decision, creating empty batch.");
        }

        logger.debug("Creating a PROPOSE with " + numberOfMessages + " msgs");

        // 3. [关键修复] 始终返回由 BatchBuilder 生成的合法 Batch
        // 即使 requests 为空，makeBatch 也会生成包含正确头部信息的字节数组
        return bb.makeBatch(pendingRequests, numberOfNonces, System.currentTimeMillis(), controller.getStaticConf().getUseSignatures() == 1);
    }

    /**
     * This is the main code for this thread. It basically waits until this
     * replica becomes the leader, and when so, proposes a value to the other
     * acceptors
     */
    @Override
    public void run() {
        logger.debug("Running."); // TODO: can't this be outside of the loop?
        while (doWork) {

            // blocks until this replica learns to be the leader for the current epoch of the current consensus
            leaderLock.lock();
            logger.debug("Next leader for CID=" + (getLastExec() + 1) + ": " + execManager.getCurrentLeader());

            //******* EDUARDO BEGIN **************//
            if (execManager.getCurrentLeader() != this.controller.getStaticConf().getProcessId()) {
                iAmLeader.awaitUninterruptibly();
                //waitForPaxosToFinish();
            }
            //******* EDUARDO END **************//
            leaderLock.unlock();

            if (!doWork) break;

            // blocks until the current consensus finishes
            proposeLock.lock();

            if (getInExec() != -1) { //there is some consensus running
                logger.debug("Waiting for consensus " + getInExec() + " termination.");
                canPropose.awaitUninterruptibly();
            }
            proposeLock.unlock();

            if (!doWork) break;

            logger.debug("I'm the leader.");

            // blocks until there are requests to be processed/ordered
            messagesLock.lock();
            if (!clientsManager.havePendingRequests() ||
                    (controller.getStaticConf().getBatchTimeout() > -1
                            && !clientsManager.isNextBatchReady())) {

                logger.debug("Waiting for enough requests");
                haveMessages.awaitUninterruptibly();
                logger.debug("Got enough requests");
            }
            messagesLock.unlock();

            if (!doWork) break;

            logger.debug("There are requests to be ordered. I will propose.");


            if ((execManager.getCurrentLeader() == this.controller.getStaticConf().getProcessId()) && //I'm the leader
                    (clientsManager.havePendingRequests()) && //there are messages to be ordered
                    (getInExec() == -1)) { //there is no consensus in execution

                // Sets the current consensus
                int execId = getLastExec() + 1;
                setInExec(execId);

                Decision dec = execManager.getConsensus(execId).getDecision();

                // Bypass protocol if service is not replicated
                if (controller.getCurrentViewN() == 1) {

                    logger.debug("Only one replica, bypassing consensus.");

                    byte[] value = createPropose(dec);

                    Consensus consensus = execManager.getConsensus(dec.getConsensusId());
                    Epoch epoch = consensus.getEpoch(0, controller);
                    epoch.propValue = value;
                    epoch.propValueHash = computeHash(value);
                    epoch.getConsensus().addWritten(value);
                    epoch.deserializedPropValue = checkProposedValue(value, true);
                    epoch.getConsensus().getDecision().firstMessageProposed = epoch.deserializedPropValue[0];
                    dec.setDecisionEpoch(epoch);

                    //System.out.println("ESTOU AQUI!");
                    dt.delivery(dec);
                    continue;

                }
                execManager.getProposer().startConsensus(execId, createPropose(dec));
            }
        }
        logger.info("TOMLayer stopped.");
    }

    /**
     * Called by the current consensus instance, to notify the TOM layer that
     * a value was decided
     *
     * @param dec The decision of the consensus
     */
    public void decided(Decision dec) {

        dec.setRegency(syncher.getLCManager().getLastReg());
        dec.setLeader(execManager.getCurrentLeader());

        this.dt.delivery(dec); // Sends the decision to the delivery thread
    }

    /**
     * Verify if the value being proposed for a epoch is valid. It verifies the
     * client signature of all batch requests.
     *
     * TODO: verify timestamps and nonces
     *
     * @param proposedValue the value being proposed
     * @param addToClientManager add the requests to the client manager
     * @return Valid messages contained in the proposed value
     */
    public TOMMessage[] checkProposedValue(byte[] proposedValue, boolean addToClientManager) {

        try{

            logger.debug("Checking proposed value");

            BatchReader batchReader = new BatchReader(proposedValue,
                    this.controller.getStaticConf().getUseSignatures() == 1);

            TOMMessage[] requests;

            //deserialize the message
            //TODO: verify Timestamps and Nonces
            requests = batchReader.deserialiseRequests(this.controller);

            if (addToClientManager) {

                //use parallelization to validate the request
                final CountDownLatch latch = new CountDownLatch(requests.length);

                for (TOMMessage request : requests) {

                    verifierExecutor.submit(() -> {
                        try {

                            //notifies the client manager that this request was received and get
                            //the result of its validation
                            request.isValid = clientsManager.requestReceived(request, false);
                            if (Thread.holdsLock(clientsManager.getClientsLock())) clientsManager.getClientsLock().unlock();

                        }
                        catch (Exception e) {

                            logger.error("Error while validating requests", e);
                            if (Thread.holdsLock(clientsManager.getClientsLock())) clientsManager.getClientsLock().unlock();

                        }

                        latch.countDown();
                    });
                }

                latch.await();

                for (TOMMessage request : requests) {
                    if (!request.isValid) {
                        logger.warn("Request {} could not be added to the pending messages queue of its respective client", request);
                        return null;
                    }
                }
            }

            logger.debug("Successfully deserialized batch");

            return requests;

        } catch (Exception e) {
            logger.error("Failed to check proposed value",e);
            if (Thread.holdsLock(clientsManager.getClientsLock())) clientsManager.getClientsLock().unlock();

            return null;
        }
    }

    public boolean isRetrievingState() {
        return stateManager != null && stateManager.isRetrievingState();
    }

    public boolean isChangingLeader() {

        return !requestsTimer.isEnabled();

    }

    public void setNoExec() {
        logger.debug("Modifying inExec from " + this.inExecution + " to " + -1);

        proposeLock.lock();
        this.inExecution = -1;
        //ot.addUpdate();
        canPropose.signalAll();
        proposeLock.unlock();
    }

    public void processOutOfContext() {
        for (int nextConsensus = getLastExec() + 1;
            // DECISION_FORWARDING: process aut of context decisions
                execManager.receivedOutOfContextPropose(nextConsensus) || execManager.receivedOutOfContextDecision(nextConsensus);
                nextConsensus = getLastExec() + 1) {

            // DECISION_FORWARDING: process out of context decisions if available
            if (execManager.receivedOutOfContextDecision(nextConsensus)) {
                execManager.processOutOfContextDecision(execManager.getConsensus(nextConsensus));
            } else {
                execManager.processOutOfContextPropose(execManager.getConsensus(nextConsensus));
            }
        }
    }

    public StateManager getStateManager() {
        return stateManager;
    }

    public Synchronizer getSynchronizer() {
        return syncher;
    }

    private void haveMessages() {
        messagesLock.lock();
        haveMessages.signal();
        messagesLock.unlock();
    }

    public DeliveryThread getDeliveryThread() {
        return dt;
    }

    public void shutdown() {
        this.doWork = false;
        imAmTheLeader();
        haveMessages();
        setNoExec();

        if (this.requestsTimer != null) this.requestsTimer.shutdown();
        if (this.clientsManager != null) {
            this.clientsManager.clear();
            this.clientsManager.getPendingRequests().clear();
        }
        if (this.dt != null) this.dt.shutdown();
        if (this.communication != null) this.communication.shutdown();

    }
}
