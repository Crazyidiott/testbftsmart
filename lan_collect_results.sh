#!/bin/bash

source ./lan_connection.sh

echo ">>> [Step 6] Collecting Results..."
mkdir -p results

for i in "${!REPLICA_NODES_RESOLVED[@]}"; do
    host=${REPLICA_NODES_RESOLVED[$i]}
    echo "    Fetching logs from Node $i..."
    remote_scp_from "$host" "${REMOTE_PROJECT_PATH}/server_${i}.log" "./results/server_${i}.log"
    remote_scp_from "$host" "${REMOTE_PROJECT_PATH}/server_agent/agent_${i}.log" "./results/agent_${i}.log"
    remote_scp_from "$host" "${REMOTE_PROJECT_PATH}/gc_${i}.log" "./results/gc_${i}.log" 2>/dev/null || true

    mkdir -p "./results/node_${i}_experiments"
    remote_rsync_from "$host" "${REMOTE_PROJECT_PATH}/server_agent/experiments/" "./results/node_${i}_experiments/"
done

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