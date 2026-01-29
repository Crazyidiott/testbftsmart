#!/bin/bash



# ./lan_deploy.sh [BatchSize] [Timeout] [ClientRate] [SkipBuild] [ALGORITHM]
# Load LAN Configuration
source ./lan_config.sh

# EXPERIMENT CONFIGURATION
# -----------------------------
# Allow passing arguments.
if [ -n "$1" ]; then
    MAX_BATCH_SIZE=$1
else
    MAX_BATCH_SIZE=1000
fi

if [ -n "$2" ]; then
    TIMEOUT_VAL=$2
else
    # Default behavior if not provided
    TIMEOUT_VAL=50
fi

if [ -n "$3" ]; then
    CLIENT_RATE_PER_THREAD=$3
else
    # Default to unlimited/high
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
    ALG_NAME="BAYESIAN"  # Default algorithm
fi
# -----------------------------

echo ">>> [Step 0] Configuring Batch Size to ${MAX_BATCH_SIZE}, Timeout to ${TIMEOUT_VAL}..."
echo "             Algorithm selected: ${ALG_NAME}"
# Use sed to update system.config locally before syncing
CONFIG_FILE="${LOCAL_PROJECT_PATH}/config/system.config"

# Update maxbatchsize
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/system.totalordermulticast.maxbatchsize = [0-9]*/system.totalordermulticast.maxbatchsize = ${MAX_BATCH_SIZE}/g" "$CONFIG_FILE"
else
    sed -i "s/system.totalordermulticast.maxbatchsize = [0-9]*/system.totalordermulticast.maxbatchsize = ${MAX_BATCH_SIZE}/g" "$CONFIG_FILE"
fi

# Update batchtimeout
# For small batches, we want aggressive timeout (wait less). For big batches, we can wait a bit or use -1 (ondemand).
# Here we set a general strategy: if batch size is small, timeout is small to encourage frequent blocks.
if [ "$MAX_BATCH_SIZE" -le 20 ]; then
     TIMEOUT_VAL=-1
else
     TIMEOUT_VAL=50
fi

if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/system.totalordermulticast.batchtimeout = .*/system.totalordermulticast.batchtimeout = ${TIMEOUT_VAL}/g" "$CONFIG_FILE"
else
    sed -i "s/system.totalordermulticast.batchtimeout = .*/system.totalordermulticast.batchtimeout = ${TIMEOUT_VAL}/g" "$CONFIG_FILE"
fi

echo "    Updated system.config: maxbatchsize=${MAX_BATCH_SIZE}, batchtimeout=${TIMEOUT_VAL}"


echo ">>> [Step 1] Generating hosts.config locally..."
# 自动生成 hosts.config
rm -f hosts.config.temp
for i in {0..3}; do
    host=${NODES[$i]}
    port1=$((11000 + i * 10))
    port2=$((11001 + i * 10))
    echo "$i $host $port1 $port2" >> hosts.config.temp
done
mv hosts.config.temp "${LOCAL_PROJECT_PATH}/config/hosts.config"
echo "    hosts.config generated."

echo ">>> [Step 1.5] Generating SSL Keystore..."

# 检查本地是否安装了 keytool (通常包含在 openjdk-11-jdk-headless 或 openjdk-11-jre-headless 中)
if ! type keytool > /dev/null 2>&1; then
    echo "    keytool not found. Installing openjdk-11-jdk-headless..."
    sudo apt-get update -qq
    sudo apt-get install -y openjdk-11-jdk-headless -qq
    
    if ! type keytool > /dev/null 2>&1; then
        echo "    Failed to install keytool. Please install Java manually."
        exit 1
    fi
fi

# 确保目录存在
mkdir -p "${LOCAL_PROJECT_PATH}/config/keysSSL_TLS"
KEYSTORE_PATH="${LOCAL_PROJECT_PATH}/config/keysSSL_TLS/EC_KeyPair_256.pkcs12"
rm -f "$KEYSTORE_PATH"

# 构建 SAN 字符串 (包含所有节点 IP)
SAN_STRING=""
for ip in "${NODES[@]}"; do
    if [ -z "$SAN_STRING" ]; then
        SAN_STRING="IP:$ip"
    else
        SAN_STRING="$SAN_STRING,IP:$ip"
    fi
done

echo "    SAN: $SAN_STRING"

# 生成 Keystore
# 密码必须是 MySeCreT_2hMOygBwY (源码硬编码)
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

# 只需要做一次
# echo ">>> [Step 1.6] Setting up Python Environment..."
# chmod +x setup_python_env.sh
# ./setup_python_env.sh

echo ">>> [Step 2] Syncing and Setting up Environment..."

for i in "${!NODES[@]}"; do
    host=${NODES[$i]}
    echo "--- Processing Node $i ($host) ---"

    # 1. 安装依赖 (Java) - Gradle 不需要 Ant
    ssh -o StrictHostKeyChecking=no -i "$KEY" "$USER@$host" '
        if ! type java > /dev/null 2>&1; then
            echo "    Installing Java..."
            sudo apt-get update -qq
            sudo apt-get install -y openjdk-11-jdk -qq
        else
            echo "    Java already installed."
        fi
        
        echo "    [Cleanup] Killing existing processes..."
        # Kill Java processes (Server/Client)
        # We filter for 'java' AND 'bftsmart' to be specific.
        # We exclude 'grep' and 'bash -c' (which might be this script itself).
        ps -ef | grep "java" | grep "bftsmart" | grep -v "grep" | grep -v "bash -c" | awk "{print \$2}" | xargs -r kill -9
        
        # Kill wrapper scripts (smartrun.sh)
        ps -ef | grep "smartrun.sh" | grep -v "grep" | grep -v "bash -c" | awk "{print \$2}" | xargs -r kill -9
        
        # Wait for ports to be released
        sleep 2
        
        echo "    [Cleanup] Removing currentView..."
        rm -rf testbftsmart/config/currentView*
        
        # --- Verification Step ---
        echo "    [Verify] Checking for remaining processes..."
        REMAINING_PROCS=$(ps aux | grep -E "bftsmart|CounterServer|ThroughputLatencyServer|CounterClient|ThroughputLatencyClient" | grep -v grep)
        if [ -n "$REMAINING_PROCS" ]; then
            echo "    WARNING: Processes still running:"
            echo "$REMAINING_PROCS"
        else
            echo "    OK: No relevant processes found."
        fi

        echo "    [Verify] Checking for currentView files..."
        if ls testbftsmart/config/currentView* 1> /dev/null 2>&1; then
            echo "    WARNING: currentView files still exist:"
            ls -l testbftsmart/config/currentView*
        else
            echo "    OK: currentView files deleted."
        fi
        # -------------------------
    '

    # 2. 同步代码
    if [ "$SKIP_BUILD" == "true" ]; then
        echo "    [Fast Mode] Syncing ONLY configuration files (skipping full code sync)..."
        # Only sync the config directory to ensure system.config updates are pushed
        rsync -avz -e "ssh -i $KEY -o StrictHostKeyChecking=no" \
            "${LOCAL_PROJECT_PATH}/config/" "$USER@$host:${REMOTE_PROJECT_PATH}/config/" > /dev/null
    else
        echo "    Syncing code..."
        # Add server_agent to sync
        rsync -avz -e "ssh -i $KEY -o StrictHostKeyChecking=no" \
            --exclude 'build' \
            --exclude '.git' \
            --exclude 'config/currentView' \
            "${LOCAL_PROJECT_PATH}/" "$USER@$host:${REMOTE_PROJECT_PATH}/" > /dev/null
    fi

    # 3. 编译代码 (使用 Gradle)
    if [ "$SKIP_BUILD" == "true" ]; then
        echo "    [Fast Mode] Skipping compilation..."
    else
        # Modification:
        # 1. Grant gradlew execution permissions
        # 2. Run installDist to generate build artifacts
        # 3. Copy the generated jar packages (dependencies + project itself) to lib/ directory
        #    This way runscripts/smartrun.sh (usually loads lib/*.jar) can work properly
        ssh -i "$KEY" "$USER@$host" "
            cd ${REMOTE_PROJECT_PATH}
            chmod +x gradlew
            echo "    Compiling with Gradle, this may take a moment..."
            ./gradlew installDist > /dev/null 2>&1
            
            if [ \$? -eq 0 ]; then
                echo "    Compilation successful."
                # 关键步骤：把 Gradle 构建好的 jar 包复制到根目录的 lib/ 下
                # 这样 smartrun.sh 脚本才能找到类
                mkdir -p lib
                cp -r build/install/library/lib/* lib/
            else
                echo "    Compilation FAILED!"
                exit 1
            fi
        "
    fi
    
    echo "    Node $i setup complete."
done

echo ">>> [Step 3] Starting Replicas (Nodes 0-3)..."
for i in {0..3}; do
    host=${NODES[$i]}
    echo "    Starting Replica $i on $host..."
    
    # Start the Python Agent FIRST
    ssh -i "$KEY" "$USER@$host" "
        cd ${REMOTE_PROJECT_PATH}/server_agent
        
        # Safety: Kill only the EXACT python process running trainer.py or mock_agent.py.
        # We MUST exclude 'bash' because this SSH command itself runs in bash and contains the string
        ps -ef | grep 'python3.*trainer.py\|python3.*mock_agent.py' | grep -v grep | grep -v bash | awk '{print \$2}' | xargs -r kill -9
        
        # Force activation of virtual environment
        # source rlenv/bin/activate  <-- NOT NEEDED if we use explicit path below, and can cause issues in non-interactive shell
        
        # Use the python executable from the virtual environment explicitly
        # Run in background with selected algorithm
        # We wrap in a subshell or ensure 'nohup' doesn't hang the SSH connection
        
        echo '    [Remote] Launching Python Agent...'
        if [ -f rlenv/bin/python3 ]; then
             # === MOCK AGENT MODE (for testing dynamic tuning) ===
             # Use mock_agent.py for testing, trainer.py for production
             # Options: --mode random|fixed|incremental
             # Use 'fixed' mode first to verify the communication works correctly
             nohup ./rlenv/bin/python3 mock_agent.py --mode fixed > agent_$i.log 2>&1 &
             echo '    Mock Agent started (fixed mode) for testing dynamic tuning.'
             
             # === PRODUCTION MODE (uncomment below, comment above) ===
             # nohup env OPT_ALGORITHM=${ALG_NAME} ./rlenv/bin/python3 trainer.py > agent_$i.log 2>&1 &
             # echo '    Python Agent started with algorithm: ${ALG_NAME}'
        else
             echo '    ERROR: rlenv/bin/python3 NOT FOUND. Agent cannot start.'
             exit 1
        fi
    "

    # Then start the Java Server
    ssh -i "$KEY" "$USER@$host" "
        cd ${REMOTE_PROJECT_PATH}
        nohup ./runscripts/smartrun.sh bftsmart.demo.microbenchmarks.ThroughputLatencyServer $i 1000 1024 1024 false nosig 0 > server_$i.log 2>&1 &
    "
        # nohup ./runscripts/smartrun.sh bftsmart.demo.counter.CounterServer $i > server_$i.log 2>&1 &
        # nohup ./runscripts/smartrun.sh bftsmart.benchmark.ThroughputLatencyServer $i 1024 > server_$i.log 2>&1 &

done

echo "    Waiting 10 seconds for cluster to stabilize..."
sleep 10

echo ">>> [Step 4] Starting Client (Node 4)..."
client_host=${NODES[4]}

# Choose client type based on DURATION_SECONDS environment variable
# If DURATION_SECONDS is set, use TimedLatencyClient; otherwise use AsyncLatencyClient
if [ -n "$DURATION_SECONDS" ]; then
    echo "    Using TimedLatencyClient for ${DURATION_SECONDS} seconds..."
    ssh -i "$KEY" "$USER@$client_host" "
        cd ${REMOTE_PROJECT_PATH}
        nohup ./runscripts/smartrun.sh bftsmart.demo.microbenchmarks.TimedLatencyClient 1001 10 ${DURATION_SECONDS} 1024 false false nosig ${CLIENT_RATE_PER_THREAD} > client.log 2>&1 &
    "
else
    echo "    Using AsyncLatencyClient (200000 ops per client)..."
    # The last argument is CLIENT_RATE_PER_THREAD
    ssh -i "$KEY" "$USER@$client_host" "
        cd ${REMOTE_PROJECT_PATH}
        nohup ./runscripts/smartrun.sh bftsmart.demo.microbenchmarks.AsyncLatencyClient 1001 10 200000 1024 0 false false nosig ${CLIENT_RATE_PER_THREAD} > client.log 2>&1 &
    "
fi
    # nohup ./runscripts/smartrun.sh bftsmart.demo.counter.CounterClient 1001 1 100000 > client.log 2>&1 &
    # nohup ./runscripts/smartrun.sh bftsmart.benchmark.ThroughputLatencyClient 1001 1 1000 1024 true false true > client.log 2>&1 &


echo "    Client started."

# Replace fixed sleep with dynamic wait
echo "    Waiting for Client to finish..."

# Calculate max wait time based on client type
if [ -n "$DURATION_SECONDS" ]; then
    # For TimedLatencyClient, wait for duration + 60s buffer
    MAX_WAIT=$((DURATION_SECONDS + 60))
    CLIENT_PATTERN="TimedLatencyClient\|AsyncLatencyClient"
else
    # For AsyncLatencyClient, use original timeout
    MAX_WAIT=120
    CLIENT_PATTERN="AsyncLatencyClient"
fi

MAX_RETRIES=$((MAX_WAIT / 3))
COUNT=0
client_host=${NODES[4]}

echo "    Max wait time: ${MAX_WAIT}s (checking every 3s)"

while [ $COUNT -lt $MAX_RETRIES ]; do
    sleep 3
    # Check if client is running
    if ssh -i "$KEY" "$USER@$client_host" "pgrep -f '${CLIENT_PATTERN}'" > /dev/null 2>&1; then
        # Print progress every 10 checks (~30s)
        if [ $((COUNT % 10)) -eq 0 ]; then
            echo "    Still running... ($((COUNT * 3))s elapsed)"
        else
            echo -n "."
        fi
        ((COUNT++))
    else
        echo ""
        echo "    Client process finished."
        break
    fi
done

if [ $COUNT -ge $MAX_RETRIES ]; then
    echo "    WARNING: Client timed out (running longer than ${MAX_WAIT}s). Force killing..."
    ssh -i "$KEY" "$USER@$client_host" "pkill -f 'TimedLatencyClient\|AsyncLatencyClient'"
fi

# COMMENTED OUT STEP 5 FOR STABLE BENCHMARKING
# echo ">>> [Step 5] Triggering View Change (Killing Node 0)..."
# node0_host=${NODES[0]}

# ssh -i "$KEY" "$USER@$node0_host" "pkill -f 'CounterServer 0'"
# ssh -i "$KEY" "$USER@$node0_host" "pkill -f 'ThroughputLatencyServer 0'"

# echo "    Node 0 killed!"

# echo "    Waiting 60 seconds for View Change to complete..."
# sleep 60

echo ">>> [Step 6] Collecting Results..."
mkdir -p results
for i in {0..3}; do
    host=${NODES[$i]}
    echo "    Fetching logs from Node $i..."
    scp -i "$KEY" "$USER@$host:${REMOTE_PROJECT_PATH}/server_$i.log" "./results/server_$i.log"
    # Added agent logs and experiments data collection
    scp -i "$KEY" "$USER@$host:${REMOTE_PROJECT_PATH}/server_agent/agent_$i.log" "./results/agent_$i.log"
    
    # Create local directory for experiments data
    mkdir -p "./results/node_$i_experiments"
    # Sync experiments directory (CSV/JSON data)
    rsync -avz -e "ssh -i $KEY" "$USER@$host:${REMOTE_PROJECT_PATH}/server_agent/experiments/" "./results/node_$i_experiments/"
done

client_host=${NODES[4]}
echo "    Fetching logs from Client..."
scp -i "$KEY" "$USER@$client_host:${REMOTE_PROJECT_PATH}/client.log" "./results/client.log"

echo "================ ANALYSIS RESULT ================"
grep "Consensus ID" ./results/*.log | head -n 5 
grep "METRICS" ./results/*.log
echo "================================================="
echo "Full logs are saved in ./results/"