#!/bin/bash

# Load WAN Configuration
source ./wan_config.sh

echo ">>> [Step 6] Collecting Results..."
mkdir -p results
for i in {1..3}; do
    host=${NODES[$i]}
    current_key=${KEYS[$i]}
    echo "    Fetching logs from Node $i..."
    scp -i "$current_key" "$USER@$host:${REMOTE_PROJECT_PATH}/server_$i.log" "./results/server_$i.log"
done

client_host=${NODES[4]}
client_key=${KEYS[4]}
echo "    Fetching logs from Client..."
scp -i "$client_key" "$USER@$client_host:${REMOTE_PROJECT_PATH}/client.log" "./results/client.log"

echo "================ ANALYSIS RESULT ================"
grep "Consensus ID" ./results/*.log | head -n 5 
grep "METRICS" ./results/*.log
echo "================================================="
echo "Full logs are saved in ./results/"
