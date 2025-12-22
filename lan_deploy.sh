#!/bin/bash

# Load LAN Configuration
source ./lan_config.sh

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
        
        # 清理旧进程和旧视图
        pkill -f bftsmart
        rm -rf testbftsmart/config/currentView
    '

    # 2. 同步代码
    echo "    Syncing code..."
    rsync -avz -e "ssh -i $KEY -o StrictHostKeyChecking=no" \
        --exclude 'build' \
        --exclude '.git' \
        "${LOCAL_PROJECT_PATH}/" "$USER@$host:${REMOTE_PROJECT_PATH}/" > /dev/null

    # 3. 编译代码 (使用 Gradle)
    # 修改说明：
    # 1. 赋予 gradlew 执行权限
    # 2. 运行 installDist 生成构建产物
    # 3. 将生成的 jar 包 (依赖+项目本身) 复制到 lib/ 目录
    #    这样 runscripts/smartrun.sh (通常加载 lib/*.jar) 才能正常工作
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
    
    echo "    Node $i setup complete."
done

echo ">>> [Step 3] Starting Replicas (Nodes 0-3)..."
for i in {0..3}; do
    host=${NODES[$i]}
    echo "    Starting Replica $i on $host..."
    
    ssh -i "$KEY" "$USER@$host" "
        cd ${REMOTE_PROJECT_PATH}
        nohup ./runscripts/smartrun.sh bftsmart.demo.counter.CounterServer $i > server_$i.log 2>&1 &
    "
        # nohup ./runscripts/smartrun.sh bftsmart.demo.counter.CounterServer $i > server_$i.log 2>&1 &
        # nohup ./runscripts/smartrun.sh bftsmart.benchmark.ThroughputLatencyServer $i 1024 > server_$i.log 2>&1 &

done

echo "    Waiting 10 seconds for cluster to stabilize..."
sleep 10

echo ">>> [Step 4] Starting Client (Node 4)..."
client_host=${NODES[4]}
ssh -i "$KEY" "$USER@$client_host" "
    cd ${REMOTE_PROJECT_PATH}
    nohup ./runscripts/smartrun.sh bftsmart.demo.counter.CounterClient 1001 1 100000 > client.log 2>&1 &
"
    # nohup ./runscripts/smartrun.sh bftsmart.demo.counter.CounterClient 1001 1 100000 > client.log 2>&1 &
    # nohup ./runscripts/smartrun.sh bftsmart.benchmark.ThroughputLatencyClient 1001 1 1000 1024 4096 1024 true false true false > client.log 2>&1 &


echo "    Client started."

sleep 5

echo ">>> [Step 5] Triggering View Change (Killing Node 0)..."
node0_host=${NODES[0]}

ssh -i "$KEY" "$USER@$node0_host" "pkill -f 'CounterServer 0'"
# ssh -i "$KEY" "$USER@$node0_host" "pkill -f 'ThroughputLatencyServer 0'"

echo "    Node 0 killed!"

echo "    Waiting 20 seconds for View Change to complete..."
sleep 20

echo ">>> [Step 6] Collecting Results..."
mkdir -p results
for i in {1..3}; do
    host=${NODES[$i]}
    echo "    Fetching logs from Node $i..."
    scp -i "$KEY" "$USER@$host:${REMOTE_PROJECT_PATH}/server_$i.log" "./results/server_$i.log"
done

client_host=${NODES[4]}
echo "    Fetching logs from Client..."
scp -i "$KEY" "$USER@$client_host:${REMOTE_PROJECT_PATH}/client.log" "./results/client.log"

echo "================ ANALYSIS RESULT ================"
grep "METRICS" ./results/*.log
echo "================================================="
echo "Full logs are saved in ./results/"