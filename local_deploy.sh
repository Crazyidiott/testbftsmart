#!/bin/bash

# ============================================================================
# local_deploy.sh - Single-machine deployment script for BFT-SMaRt
# Mirrors the logic of lan_deploy.sh but runs all 4 replicas + 1 client
# locally on the same machine using different ports (127.0.0.1).
# ============================================================================
# Usage:
#   ./local_deploy.sh [BatchSize] [Timeout] [ClientRate] [SkipBuild] [ALGORITHM] [WorkloadConfig]
#   Example: ./local_deploy.sh 500 100 -1 false NONE
#   Example: ./local_deploy.sh 500 100 -1 false STATIC
#   Example: ./local_deploy.sh 500 100 -1 false BAYESIAN
#   Example: ./local_deploy.sh 500 100 5000 false NONE workload_burst.yaml
# ============================================================================

# LOCAL CONFIGURATION (replaces lan_config.sh)
LOCAL_PROJECT_PATH="$(cd "$(dirname "$0")" && pwd)"

# Python virtual environment path (auto-detect)
# Priority: server_agent/rlenv > py-resdb > system python3
if [ -f "${LOCAL_PROJECT_PATH}/server_agent/rlenv/bin/python3" ]; then
    PYTHON_BIN="${LOCAL_PROJECT_PATH}/server_agent/rlenv/bin/python3"
elif [ -f "${LOCAL_PROJECT_PATH}/py-resdb/bin/python3" ]; then
    PYTHON_BIN="${LOCAL_PROJECT_PATH}/py-resdb/bin/python3"
else
    PYTHON_BIN="python3"
fi

# EXPERIMENT CONFIGURATION
# -----------------------------
if [ -n "$1" ]; then
    MAX_BATCH_SIZE=$1
else
    MAX_BATCH_SIZE=1000
fi

if [ -n "$2" ]; then
    TIMEOUT_VAL=$2
else
    TIMEOUT_VAL=50
fi

if [ -n "$3" ]; then
    CLIENT_RATE_PER_THREAD=$3
else
    CLIENT_RATE_PER_THREAD=-1
fi

if [ -n "$4" ]; then
    SKIP_BUILD=$4
else
    SKIP_BUILD="false"
fi

if [ -n "$5" ]; then
    ALG_NAME=$5
else
    ALG_NAME="BAYESIAN"
fi

if [ -n "$6" ]; then
    WORKLOAD_CONFIG_NAME=$6
else
    WORKLOAD_CONFIG_NAME=""
fi
# Supported algorithms:
#   NONE     - No agent at all, uses system.config parameters directly (pure BFT-SMaRt)
#   STATIC   - Fixed parameters (uses BatchSize and Timeout from script arguments, with metrics)
#   MOCK     - Use mock_agent.py (for testing communication)
#   BAYESIAN - Bayesian Optimization (trainer.py)
#   PPO      - Proximal Policy Optimization (trainer.py)
#   SA       - Simulated Annealing (trainer.py)
# -----------------------------

echo ">>> [Step 0] Configuring Batch Size to ${MAX_BATCH_SIZE}, Timeout to ${TIMEOUT_VAL}..."
echo "             Algorithm selected: ${ALG_NAME}"
echo "             Python binary: ${PYTHON_BIN}"
CONFIG_FILE="${LOCAL_PROJECT_PATH}/config/system.config"

# Update maxbatchsize
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/system.totalordermulticast.maxbatchsize = [0-9]*/system.totalordermulticast.maxbatchsize = ${MAX_BATCH_SIZE}/g" "$CONFIG_FILE"
else
    sed -i "s/system.totalordermulticast.maxbatchsize = [0-9]*/system.totalordermulticast.maxbatchsize = ${MAX_BATCH_SIZE}/g" "$CONFIG_FILE"
fi

# Update batchtimeout
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/system.totalordermulticast.batchtimeout = .*/system.totalordermulticast.batchtimeout = ${TIMEOUT_VAL}/g" "$CONFIG_FILE"
else
    sed -i "s/system.totalordermulticast.batchtimeout = .*/system.totalordermulticast.batchtimeout = ${TIMEOUT_VAL}/g" "$CONFIG_FILE"
fi

echo "    Updated system.config: maxbatchsize=${MAX_BATCH_SIZE}, batchtimeout=${TIMEOUT_VAL}"


echo ">>> [Step 1] Generating hosts.config locally..."
# All nodes on 127.0.0.1 with different ports
rm -f hosts.config.temp
for i in {0..3}; do
    port1=$((11000 + i * 10))
    port2=$((11001 + i * 10))
    echo "$i 127.0.0.1 $port1 $port2" >> hosts.config.temp
done
# Client entry
echo "7001 127.0.0.1 11100" >> hosts.config.temp
mv hosts.config.temp "${LOCAL_PROJECT_PATH}/config/hosts.config"
echo "    hosts.config generated (all on 127.0.0.1)."

echo ">>> [Step 1.5] Generating SSL Keystore..."

if ! type keytool > /dev/null 2>&1; then
    echo "    keytool not found. Installing openjdk-11-jdk-headless..."
    sudo apt-get update -qq
    sudo apt-get install -y openjdk-11-jdk-headless -qq

    if ! type keytool > /dev/null 2>&1; then
        echo "    Failed to install keytool. Please install Java manually."
        exit 1
    fi
fi

mkdir -p "${LOCAL_PROJECT_PATH}/config/keysSSL_TLS"
KEYSTORE_PATH="${LOCAL_PROJECT_PATH}/config/keysSSL_TLS/EC_KeyPair_256.pkcs12"
rm -f "$KEYSTORE_PATH"

# For local deployment, SAN only needs 127.0.0.1
SAN_STRING="IP:127.0.0.1"
echo "    SAN: $SAN_STRING"

keytool -genkeypair \
  -keyalg EC \
  -keysize 256 \
  -alias bftsmartEC \
  -keystore "$KEYSTORE_PATH" \
  -storetype pkcs12 \
  -storepass MySeCreT_2hMOygBwY \
  -keypass MySeCreT_2hMOygBwY \
  -dname "CN=BFT-SMaRT" \
  -ext "SAN=$SAN_STRING" > /dev/null 2>&1

if [ $? -eq 0 ]; then
    echo "    Keystore generated successfully."
else
    echo "    Keystore generation FAILED! Please check if keytool is installed."
    exit 1
fi


echo ">>> [Step 2] Local Environment Setup..."

# --- Cleanup: Kill existing processes ---
echo "    [Cleanup] Killing existing BFT-SMaRt processes..."
ps -ef | grep "java" | grep "bftsmart" | grep -v "grep" | grep -v "bash -c" | awk '{print $2}' | xargs -r kill -9 2>/dev/null
ps -ef | grep "smartrun.sh" | grep -v "grep" | grep -v "bash -c" | awk '{print $2}' | xargs -r kill -9 2>/dev/null
ps -ef | grep 'python3.*trainer.py\|python3.*mock_agent.py' | grep -v grep | grep -v "bash -c" | awk '{print $2}' | xargs -r kill -9 2>/dev/null

sleep 2

# Verify agent port is free (critical: leftover processes cause silent startup failure)
SHARED_AGENT_PORT=45678
for _retry in $(seq 1 5); do
    if ss -tlnp | grep -q ":${SHARED_AGENT_PORT} "; then
        echo "    [Cleanup] Port ${SHARED_AGENT_PORT} still in use, waiting..."
        pkill -9 -f 'python3.*trainer.py' 2>/dev/null
        pkill -9 -f 'python3.*mock_agent.py' 2>/dev/null
        sleep 2
    else
        break
    fi
done
if ss -tlnp | grep -q ":${SHARED_AGENT_PORT} "; then
    echo "    ERROR: Port ${SHARED_AGENT_PORT} is still occupied after cleanup! Aborting."
    ss -tlnp | grep ":${SHARED_AGENT_PORT} "
    exit 1
fi
echo "    [Cleanup] Port ${SHARED_AGENT_PORT} is free."

echo "    [Cleanup] Removing currentView..."
rm -rf "${LOCAL_PROJECT_PATH}/config/currentView"*

# --- Verification ---
echo "    [Verify] Checking for remaining processes..."
REMAINING_PROCS=$(ps aux | grep -E "bftsmart|CounterServer|ThroughputLatencyServer|CounterClient|ThroughputLatencyClient" | grep -v grep)
if [ -n "$REMAINING_PROCS" ]; then
    echo "    WARNING: Processes still running:"
    echo "$REMAINING_PROCS"
else
    echo "    OK: No relevant processes found."
fi

echo "    [Verify] Checking for currentView files..."
if ls "${LOCAL_PROJECT_PATH}/config/currentView"* 1> /dev/null 2>&1; then
    echo "    WARNING: currentView files still exist."
else
    echo "    OK: currentView files deleted."
fi

# --- Build ---
if [ "$SKIP_BUILD" == "true" ]; then
    echo "    [Fast Mode] Skipping compilation..."
else
    echo "    Compiling with Gradle, this may take a moment..."
    cd "${LOCAL_PROJECT_PATH}"
    chmod +x gradlew
    ./gradlew installDist > /dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo "    Compilation successful."
        mkdir -p lib
        cp -r build/install/library/lib/* lib/
    else
        echo "    Compilation FAILED!"
        exit 1
    fi
fi

echo "    Environment setup complete."


echo ">>> [Step 3] Starting Replicas (Nodes 0-3)..."
cd "${LOCAL_PROJECT_PATH}"

# ── Single-machine deployment: start ONE shared Python agent ──────────────
# All 4 replicas connect to the same agent on port 45678.
# Only the leader sends metrics (triggers training); followers call GetCurrentParams.
SHARED_AGENT_PORT=45678

if [ "${ALG_NAME}" == "NONE" ]; then
    echo "    [NONE MODE] No Python Agent - using system.config parameters directly"
    echo "    BatchSize=${MAX_BATCH_SIZE}, Timeout=${TIMEOUT_VAL} (from system.config)"
elif [ "${ALG_NAME}" == "STATIC" ]; then
    echo "    [STATIC MODE] Starting SINGLE shared Python Agent (port: $SHARED_AGENT_PORT)..."
    echo "    Using BatchSize=${MAX_BATCH_SIZE}, BatchTimeout=${TIMEOUT_VAL}"
    (cd "${LOCAL_PROJECT_PATH}/server_agent" && \
    nohup env OPT_ALGORITHM=STATIC STATIC_BATCH_SIZE=${MAX_BATCH_SIZE} STATIC_BATCH_TIMEOUT=${TIMEOUT_VAL} AGENT_PORT=${SHARED_AGENT_PORT} PYTHONUNBUFFERED=1 \
        "${PYTHON_BIN}" trainer.py \
        > "${LOCAL_PROJECT_PATH}/server_agent/agent_shared.log" 2>&1 &)
    echo "    Python Agent started with STATIC algorithm (port: $SHARED_AGENT_PORT)"
elif [ "${ALG_NAME}" == "MOCK" ]; then
    echo "    [MOCK MODE] Launching SINGLE shared Mock Agent (port: $SHARED_AGENT_PORT)..."
    (cd "${LOCAL_PROJECT_PATH}/server_agent" && \
    nohup "${PYTHON_BIN}" mock_agent.py --mode fixed --port ${SHARED_AGENT_PORT} \
        > "${LOCAL_PROJECT_PATH}/server_agent/agent_shared.log" 2>&1 &)
    echo "    Mock Agent started (port: $SHARED_AGENT_PORT)"
else
    echo "    [DYNAMIC MODE] Launching SINGLE shared Python Agent with algorithm: ${ALG_NAME} (port: $SHARED_AGENT_PORT)..."
    (cd "${LOCAL_PROJECT_PATH}/server_agent" && \
    nohup env OPT_ALGORITHM=${ALG_NAME} AGENT_PORT=${SHARED_AGENT_PORT} PYTHONUNBUFFERED=1 \
        "${PYTHON_BIN}" trainer.py \
        > "${LOCAL_PROJECT_PATH}/server_agent/agent_shared.log" 2>&1 &)
    echo "    Python Agent started (port: $SHARED_AGENT_PORT)"
fi

# Wait for the agent to be ready before starting servers
if [ "${ALG_NAME}" != "NONE" ]; then
    echo "    Waiting for Python Agent to start on port ${SHARED_AGENT_PORT}..."
    _agent_ready=false
    for _wait in $(seq 1 30); do
        if ss -tlnp | grep -q ":${SHARED_AGENT_PORT} "; then
            _agent_ready=true
            echo "    Python Agent is listening on port ${SHARED_AGENT_PORT} (took ${_wait}s)"
            break
        fi
        sleep 1
    done
    if [ "$_agent_ready" != "true" ]; then
        echo "    ERROR: Python Agent failed to start! Check agent_shared.log:"
        cat "${LOCAL_PROJECT_PATH}/server_agent/agent_shared.log" 2>/dev/null || echo "    (log file empty or missing)"
        exit 1
    fi
fi

for i in {0..3}; do
    echo "    Starting Replica $i on 127.0.0.1 (Agent port: $SHARED_AGENT_PORT)..."

    # Start the Java Server (all replicas connect to the same shared agent)
    cd "${LOCAL_PROJECT_PATH}"
    export ENABLE_GC_LOG=${ENABLE_GC_LOG:-false}
    export AGENT_PORT=${SHARED_AGENT_PORT}
    nohup ./runscripts/smartrun.sh bftsmart.demo.microbenchmarks.ThroughputLatencyServer $i 1000 1024 1024 false nosig 0 \
        > "server_$i.log" 2>&1 &
    echo "    Replica $i started (PID: $!)"
done

echo "    Waiting 10 seconds for cluster to stabilize..."
sleep 10

echo ">>> [Step 4] Starting Client..."
cd "${LOCAL_PROJECT_PATH}"

if [ -n "${WORKLOAD_CONFIG_NAME}" ]; then
    CLIENT_PROCESS_NAME="AsyncDynamicClient"
    WORKLOAD_ARGS="config/workloads/${WORKLOAD_CONFIG_NAME}"
    nohup ./runscripts/smartrun.sh bftsmart.demo.microbenchmarks.AsyncDynamicClient 1001 10 200000 1024 0 false false nosig ${CLIENT_RATE_PER_THREAD} ${WORKLOAD_ARGS} \
        > client.log 2>&1 &
    echo "    [Info] Using AsyncDynamicClient with config: ${WORKLOAD_CONFIG_NAME} (PID: $!)"
else
    CLIENT_PROCESS_NAME="AsyncLatencyClient"
    nohup ./runscripts/smartrun.sh bftsmart.demo.microbenchmarks.AsyncLatencyClient 1001 10 200000 1024 0 false false nosig ${CLIENT_RATE_PER_THREAD} \
        > client.log 2>&1 &
    echo "    [Info] Using Standard AsyncLatencyClient (PID: $!)"
fi
    # nohup ./runscripts/smartrun.sh bftsmart.demo.counter.CounterClient 1001 1 100000 > client.log 2>&1 &
    # nohup ./runscripts/smartrun.sh bftsmart.benchmark.ThroughputLatencyClient 1001 1 1000 1024 true false true > client.log 2>&1 &

echo "    Client started."

# Replace fixed sleep with dynamic wait
echo "    Waiting for Client to finish..."
MAX_RETRIES=500 # 500 * 3s = ~1500s max
COUNT=0

while [ $COUNT -lt $MAX_RETRIES ]; do
    sleep 3
    if pgrep -f "${CLIENT_PROCESS_NAME}" > /dev/null 2>&1; then
        echo -n "."
        ((COUNT++))
    else
        echo ""
        echo "    Client process finished."
        break
    fi
done

if [ $COUNT -ge $MAX_RETRIES ]; then
    echo "    WARNING: Client timed out. Force killing..."
    pkill -f "${CLIENT_PROCESS_NAME}"
fi

# COMMENTED OUT STEP 4.5 view change FOR STABLE BENCHMARKING
# echo ">>> [Step 4.5] Triggering View Change (Killing Node 0)..."
# pkill -f 'ThroughputLatencyServer 0'
# echo "    Node 0 killed!"
# echo "    Waiting 60 seconds for View Change to complete..."
# sleep 60

echo ">>> [Step 5] Stopping Servers..."
echo "    Waiting 10 seconds for servers to flush logs..."
sleep 10

echo "    Stopping all BFT-SMaRt processes..."
# Gracefully stop Java processes (SIGTERM) to allow shutdown hooks to run
JAVA_PIDS=$(ps -ef | grep 'java' | grep 'bftsmart' | grep -v 'grep' | grep -v 'bash -c' | awk '{print $2}')
if [ -n "$JAVA_PIDS" ]; then
    echo $JAVA_PIDS | xargs -r kill -15
    sleep 5
    # Force kill any remaining Java processes
    JAVA_PIDS_REMAINING=$(ps -ef | grep 'java' | grep 'bftsmart' | grep -v 'grep' | grep -v 'bash -c' | awk '{print $2}')
    if [ -n "$JAVA_PIDS_REMAINING" ]; then
        echo $JAVA_PIDS_REMAINING | xargs -r kill -9
    fi
fi

# Kill wrapper scripts (smartrun.sh)
ps -ef | grep 'smartrun.sh' | grep -v 'grep' | grep -v 'bash -c' | awk '{print $2}' | xargs -r kill -9 2>/dev/null

# Kill RL agents
ps -ef | grep 'python3.*trainer.py\|python3.*mock_agent.py' | grep -v 'grep' | grep -v 'bash -c' | awk '{print $2}' | xargs -r kill -9 2>/dev/null
# Suppress bash "Killed" job notification for background processes
wait 2>/dev/null

echo "    All servers and agents stopped."

echo ">>> [Step 6] Collecting Results..."
mkdir -p results

for i in {0..3}; do
    echo "    Collecting logs from Replica $i..."
    cp -f "${LOCAL_PROJECT_PATH}/server_$i.log" "./results/server_$i.log" 2>/dev/null || true
    # GC logs (optional, generated when ENABLE_GC_LOG=true)
    cp -f "${LOCAL_PROJECT_PATH}/gc_$i.log" "./results/gc_$i.log" 2>/dev/null || true
done
# Copy shared agent log (single agent for local deployment)
cp -f "${LOCAL_PROJECT_PATH}/server_agent/agent_shared.log" "./results/agent_shared.log" 2>/dev/null || true

echo "    Cleaning temporary files..."
rm -f /tmp/bft-*

echo "    Collecting client log..."
cp -f "${LOCAL_PROJECT_PATH}/client.log" "./results/client.log" 2>/dev/null || true

echo "================ ANALYSIS RESULT ================"
grep "Consensus ID" ./results/*.log | head -n 5
grep "METRICS" ./results/*.log
echo "================================================="
echo "Full logs are saved in ./results/"
