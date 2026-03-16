#!/bin/bash

# ./lan_deploy.sh [BatchSize] [Timeout] [ClientRate] [SkipBuild] [ALGORITHM] [WorkloadConfig]
# Examples:
#   ./lan_deploy.sh 500 100 -1 false BAYESIAN
#   LAN_CONFIG_FILE=./lan_config_local.sh ./lan_deploy.sh 500 100 -1 false STATIC

source ./lan_connection.sh

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

echo ">>> [Step 0] Configuring Batch Size to ${MAX_BATCH_SIZE}, Timeout to ${TIMEOUT_VAL}..."
echo "             Algorithm selected: ${ALG_NAME}"
echo "             Config file: ${LAN_CONFIG_FILE}"
if [ "${CLIENT_IS_LOCAL}" = "true" ]; then
    echo "             Client mode: local (${CLIENT_PROJECT_PATH})"
else
    echo "             Client host: ${CLIENT_HOST}"
fi

CONFIG_FILE="${LOCAL_PROJECT_PATH}/config/system.config"

if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/system.totalordermulticast.maxbatchsize = [0-9]*/system.totalordermulticast.maxbatchsize = ${MAX_BATCH_SIZE}/g" "$CONFIG_FILE"
    sed -i '' "s/system.totalordermulticast.batchtimeout = .*/system.totalordermulticast.batchtimeout = ${TIMEOUT_VAL}/g" "$CONFIG_FILE"
else
    sed -i "s/system.totalordermulticast.maxbatchsize = [0-9]*/system.totalordermulticast.maxbatchsize = ${MAX_BATCH_SIZE}/g" "$CONFIG_FILE"
    sed -i "s/system.totalordermulticast.batchtimeout = .*/system.totalordermulticast.batchtimeout = ${TIMEOUT_VAL}/g" "$CONFIG_FILE"
fi

echo "    Updated system.config: maxbatchsize=${MAX_BATCH_SIZE}, batchtimeout=${TIMEOUT_VAL}"

echo ">>> [Step 1] Generating hosts.config locally..."
rm -f hosts.config.temp
for i in "${!REPLICA_NODES_RESOLVED[@]}"; do
    host=${REPLICA_NODES_RESOLVED[$i]}
    port1=$((11000 + i * 10))
    port2=$((11001 + i * 10))
    echo "$i $host $port1 $port2" >> hosts.config.temp
done
mv hosts.config.temp "${LOCAL_PROJECT_PATH}/config/hosts.config"
echo "    hosts.config generated."

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

SAN_STRING=""
for ip in "${REPLICA_NODES_RESOLVED[@]}"; do
    if [ -z "$SAN_STRING" ]; then
        SAN_STRING="IP:$ip"
    else
        SAN_STRING="$SAN_STRING,IP:$ip"
    fi
done

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

if [ "${CLIENT_IS_LOCAL}" = "true" ]; then
    echo ">>> [Step 1.6] Preparing local client environment..."
    echo "    [Cleanup] Removing local currentView..."
    rm -rf "${CLIENT_PROJECT_PATH}/config/currentView"*
    pkill -f 'AsyncLatencyClient|AsyncDynamicClient' 2>/dev/null || true

    if [ "$SKIP_BUILD" == "true" ]; then
        echo "    [Fast Mode] Skipping local client compilation..."
    else
        echo "    Building local client runtime..."
        (
            cd "${CLIENT_PROJECT_PATH}" || exit 1
            chmod +x gradlew
            ./gradlew installDist > /dev/null 2>&1
        )

        if [ $? -eq 0 ]; then
            mkdir -p "${CLIENT_PROJECT_PATH}/lib"
            cp -r "${CLIENT_PROJECT_PATH}/build/install/library/lib/"* "${CLIENT_PROJECT_PATH}/lib/"
            echo "    Local client runtime prepared."
        else
            echo "    Local client compilation FAILED!"
            exit 1
        fi
    fi
fi

echo ">>> [Step 2] Syncing and Setting up Remote Replicas..."

for i in "${!REPLICA_NODES_RESOLVED[@]}"; do
    host=${REPLICA_NODES_RESOLVED[$i]}
    echo "--- Processing Node $i ($host) ---"

    remote_ssh "$host" "
        if ! type java > /dev/null 2>&1; then
            echo \"    Installing Java...\"
            ${SUDO_CMD} apt-get update -qq
            ${SUDO_CMD} apt-get install -y openjdk-11-jdk -qq
        else
            echo \"    Java already installed.\"
        fi

        echo \"    [Cleanup] Killing existing processes...\"
        ps -ef | grep \"java\" | grep \"bftsmart\" | grep -v \"grep\" | grep -v \"bash -c\" | awk \"{print \\\$2}\" | xargs -r kill -9
        ps -ef | grep \"smartrun.sh\" | grep -v \"grep\" | grep -v \"bash -c\" | awk \"{print \\\$2}\" | xargs -r kill -9
        sleep 2

        echo \"    [Cleanup] Removing currentView...\"
        rm -rf ${REMOTE_PROJECT_PATH}/config/currentView*

        echo \"    [Verify] Checking for remaining processes...\"
        REMAINING_PROCS=\$(ps aux | grep -E \"bftsmart|CounterServer|ThroughputLatencyServer|CounterClient|ThroughputLatencyClient\" | grep -v grep)
        if [ -n \"\$REMAINING_PROCS\" ]; then
            echo \"    WARNING: Processes still running:\"
            echo \"\$REMAINING_PROCS\"
        else
            echo \"    OK: No relevant processes found.\"
        fi

        echo \"    [Verify] Checking for currentView files...\"
        if ls ${REMOTE_PROJECT_PATH}/config/currentView* 1> /dev/null 2>&1; then
            echo \"    WARNING: currentView files still exist:\"
            ls -l ${REMOTE_PROJECT_PATH}/config/currentView*
        else
            echo \"    OK: currentView files deleted.\"
        fi
    "

    if [ "$SKIP_BUILD" == "true" ]; then
        echo "    [Fast Mode] Syncing ONLY configuration files (skipping full code sync)..."
        remote_rsync_to "${LOCAL_PROJECT_PATH}/config/" "$host" "${REMOTE_PROJECT_PATH}/config/" > /dev/null
    else
        echo "    Syncing code..."
        remote_rsync_to "${LOCAL_PROJECT_PATH}/" "$host" "${REMOTE_PROJECT_PATH}/" \
            --exclude 'build' \
            --exclude '.git' \
            --exclude 'config/currentView' > /dev/null
    fi

    if [ "$SKIP_BUILD" == "true" ]; then
        echo "    [Fast Mode] Skipping compilation..."
    else
        remote_ssh "$host" "
            cd ${REMOTE_PROJECT_PATH}
            chmod +x gradlew
            echo \"    Compiling with Gradle, this may take a moment...\"
            ./gradlew installDist > /dev/null 2>&1

            if [ \$? -eq 0 ]; then
                echo \"    Compilation successful.\"
                mkdir -p lib
                cp -r build/install/library/lib/* lib/
            else
                echo \"    Compilation FAILED!\"
                exit 1
            fi
        "
    fi

    echo "    Node $i setup complete."
done

echo ">>> [Step 3] Starting Replicas (Nodes 0-3)..."
for i in "${!REPLICA_NODES_RESOLVED[@]}"; do
    host=${REPLICA_NODES_RESOLVED[$i]}
    echo "    Starting Replica $i on $host..."

    remote_ssh "$host" "
        cd ${REMOTE_PROJECT_PATH}/server_agent
        ps -ef | grep 'python3.*trainer.py\\|python3.*mock_agent.py' | grep -v grep | grep -v bash | awk '{print \$2}' | xargs -r kill -9

        if [ \"${ALG_NAME}\" == \"NONE\" ]; then
            echo '    [NONE MODE] No Python Agent - using system.config parameters directly'
            echo '    BatchSize=${MAX_BATCH_SIZE}, Timeout=${TIMEOUT_VAL} (from system.config)'
        elif [ \"${ALG_NAME}\" == \"STATIC\" ]; then
            echo '    [STATIC MODE] Starting Python Agent with STATIC algorithm for metrics output...'
            echo '    Using BatchSize=${MAX_BATCH_SIZE}, BatchTimeout=${TIMEOUT_VAL}'
            if [ -f rlenv/bin/python3 ]; then
                nohup env OPT_ALGORITHM=STATIC STATIC_BATCH_SIZE=${MAX_BATCH_SIZE} STATIC_BATCH_TIMEOUT=${TIMEOUT_VAL} ./rlenv/bin/python3 -u trainer.py > agent_${i}.log 2>&1 &
                echo '    Python Agent started with STATIC algorithm (fixed parameters, metrics enabled)'
            else
                echo '    ERROR: rlenv/bin/python3 NOT FOUND. Agent cannot start.'
                exit 1
            fi
        elif [ \"${ALG_NAME}\" == \"MOCK\" ]; then
            echo '    [Remote] Launching Mock Agent...'
            if [ -f rlenv/bin/python3 ]; then
                nohup ./rlenv/bin/python3 -u mock_agent.py --mode fixed > agent_${i}.log 2>&1 &
                echo '    Mock Agent started (fixed mode)'
            else
                echo '    ERROR: rlenv/bin/python3 NOT FOUND. Agent cannot start.'
                exit 1
            fi
        else
            echo '    [Remote] Launching Python Agent...'
            if [ -f rlenv/bin/python3 ]; then
                nohup env OPT_ALGORITHM=${ALG_NAME} ./rlenv/bin/python3 -u trainer.py > agent_${i}.log 2>&1 &
                echo '    Python Agent started with algorithm: ${ALG_NAME}'
            else
                echo '    ERROR: rlenv/bin/python3 NOT FOUND. Agent cannot start.'
                exit 1
            fi
        fi
    "

    remote_ssh "$host" "
        cd ${REMOTE_PROJECT_PATH}
        export ENABLE_GC_LOG=${ENABLE_GC_LOG:-false}
        nohup ./runscripts/smartrun.sh bftsmart.demo.microbenchmarks.ThroughputLatencyServer $i 1000 1024 1024 false nosig 0 > server_${i}.log 2>&1 &
    "
done

echo "    Waiting 10 seconds for cluster to stabilize..."
sleep 10

echo ">>> [Step 4] Starting Client..."
if [ "${CLIENT_IS_LOCAL}" = "true" ]; then
    cd "${CLIENT_PROJECT_PATH}" || exit 1
    if [ -n "${WORKLOAD_CONFIG_NAME}" ]; then
        nohup ./runscripts/smartrun.sh bftsmart.demo.microbenchmarks.AsyncDynamicClient 1001 10 200000 1024 0 false false nosig ${CLIENT_RATE_PER_THREAD} "config/workloads/${WORKLOAD_CONFIG_NAME}" > client.log 2>&1 &
        echo "    [Info] Using local AsyncDynamicClient with config: ${WORKLOAD_CONFIG_NAME}"
    else
        nohup ./runscripts/smartrun.sh bftsmart.demo.microbenchmarks.AsyncLatencyClient 1001 10 200000 1024 0 false false nosig ${CLIENT_RATE_PER_THREAD} > client.log 2>&1 &
        echo "    [Info] Using local Standard AsyncLatencyClient"
    fi
else
    remote_ssh "${CLIENT_HOST}" "
        cd ${REMOTE_PROJECT_PATH}
        if [ -n \"${WORKLOAD_CONFIG_NAME}\" ]; then
            WORKLOAD_ARGS=\"config/workloads/${WORKLOAD_CONFIG_NAME}\"
            nohup ./runscripts/smartrun.sh bftsmart.demo.microbenchmarks.AsyncDynamicClient 1001 10 200000 1024 0 false false nosig ${CLIENT_RATE_PER_THREAD} \${WORKLOAD_ARGS} > client.log 2>&1 &
            echo \"    [Info] Using AsyncDynamicClient with config: ${WORKLOAD_CONFIG_NAME}\"
        else
            nohup ./runscripts/smartrun.sh bftsmart.demo.microbenchmarks.AsyncLatencyClient 1001 10 200000 1024 0 false false nosig ${CLIENT_RATE_PER_THREAD} > client.log 2>&1 &
            echo \"    [Info] Using Standard AsyncLatencyClient\"
        fi
    "
fi

echo "    Client started."
echo "    Waiting for Client to finish..."

MAX_RETRIES=500
COUNT=0

if [ -n "${WORKLOAD_CONFIG_NAME}" ]; then
    CLIENT_PROCESS_NAME="AsyncDynamicClient"
else
    CLIENT_PROCESS_NAME="AsyncLatencyClient"
fi

while [ $COUNT -lt $MAX_RETRIES ]; do
    sleep 3
    if [ "${CLIENT_IS_LOCAL}" = "true" ]; then
        if pgrep -f "${CLIENT_PROCESS_NAME}" > /dev/null 2>&1; then
            echo -n "."
            ((COUNT++))
        else
            echo ""
            echo "    Client process finished."
            break
        fi
    elif remote_ssh "${CLIENT_HOST}" "pgrep -f ${CLIENT_PROCESS_NAME}" > /dev/null 2>&1; then
        echo -n "."
        ((COUNT++))
    else
        echo ""
        echo "    Client process finished."
        break
    fi
done

if [ $COUNT -ge $MAX_RETRIES ]; then
    echo "    WARNING: Client timed out (running longer than 120s). Force killing..."
    if [ "${CLIENT_IS_LOCAL}" = "true" ]; then
        pkill -f "${CLIENT_PROCESS_NAME}" || true
    else
        remote_ssh "${CLIENT_HOST}" "pkill -f ${CLIENT_PROCESS_NAME}" || true
    fi
fi

echo ">>> [Step 5] Stopping Servers..."
echo "    Waiting 10 seconds for servers to flush logs..."
sleep 10

for i in "${!REPLICA_NODES_RESOLVED[@]}"; do
    host=${REPLICA_NODES_RESOLVED[$i]}
    echo "    Stopping processes on Node $i..."
    remote_ssh "$host" "
        JAVA_PIDS=\$(ps -ef | grep 'java' | grep 'bftsmart' | grep -v 'grep' | grep -v 'bash -c' | awk '{print \$2}')
        if [ -n \"\$JAVA_PIDS\" ]; then
            echo \$JAVA_PIDS | xargs -r kill -15
            sleep 5
            JAVA_PIDS_REMAINING=\$(ps -ef | grep 'java' | grep 'bftsmart' | grep -v 'grep' | grep -v 'bash -c' | awk '{print \$2}')
            if [ -n \"\$JAVA_PIDS_REMAINING\" ]; then
                echo \$JAVA_PIDS_REMAINING | xargs -r kill -9
            fi
        fi

        ps -ef | grep 'smartrun.sh' | grep -v 'grep' | grep -v 'bash -c' | awk '{print \$2}' | xargs -r kill -9
        ps -ef | grep 'python3.*trainer.py\\|python3.*mock_agent.py' | grep -v 'grep' | grep -v 'bash' | awk '{print \$2}' | xargs -r kill -9
    " 2>/dev/null || true
done

echo "    All servers and agents stopped."

echo ">>> [Step 6] Collecting Results..."
mkdir -p results
for i in "${!REPLICA_NODES_RESOLVED[@]}"; do
    host=${REPLICA_NODES_RESOLVED[$i]}
    echo "    Fetching logs from Node $i..."
    remote_scp_from "$host" "${REMOTE_PROJECT_PATH}/server_${i}.log" "./results/server_${i}.log"
    remote_scp_from "$host" "${REMOTE_PROJECT_PATH}/server_agent/agent_${i}.log" "./results/agent_${i}.log"
    remote_scp_from "$host" "${REMOTE_PROJECT_PATH}/gc_${i}.log" "./results/gc_${i}.log" 2>/dev/null || true
done

echo "    Cleaning temporary files..."
./cleanup_tmp_files.sh

echo "    Fetching logs from Client..."
if [ "${CLIENT_IS_LOCAL}" = "true" ]; then
    cp -f "${CLIENT_PROJECT_PATH}/client.log" "./results/client.log" 2>/dev/null || true
else
    remote_scp_from "${CLIENT_HOST}" "${REMOTE_PROJECT_PATH}/client.log" "./results/client.log"
fi

echo "================ ANALYSIS RESULT ================"
grep "Consensus ID" ./results/*.log | head -n 5
grep "METRICS" ./results/*.log
echo "================================================="
echo "Full logs are saved in ./results/"