#!/bin/bash

# Load LAN Configuration
source ./lan_config.sh

echo ">>> [Step 6] Collecting Results..."
mkdir -p results
for i in {0..3}; do
    host=${NODES[$i]}
    echo "    Fetching logs from Node $i..."
    scp -i "$KEY" "$USER@$host:${REMOTE_PROJECT_PATH}/server_$i.log" "./results/server_$i.log"
    # Added agent logs and experiments data collection
    scp -i "$KEY" "$USER@$host:${REMOTE_PROJECT_PATH}/server_agent/agent_$i.log" "./results/agent_$i.log"
    
    # Fetch GC logs if they exist (optional, generated when ENABLE_GC_LOG=true)
    scp -i "$KEY" "$USER@$host:${REMOTE_PROJECT_PATH}/gc_$i.log" "./results/gc_$i.log" 2>/dev/null || true
    
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