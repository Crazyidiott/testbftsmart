#!/bin/bash

# Load configuration
source ./lan_config.sh

DELAY=$1

if [ -z "$DELAY" ]; then
    echo "Usage: ./set_latency.sh <delay_in_ms>"
    echo "Example: ./set_latency.sh 50   (Adds 50ms delay)"
    echo "Example: ./set_latency.sh 0    (Removes delay)"
    exit 1
fi

# Detected interface on AWS is usually ens5. 
# If some machines differ, we might need to detect it dynamically, 
# but ens5 is standard for current gen AWS instances.
INTERFACE="ens5"

echo "=========================================================="
if [ "$DELAY" -eq 0 ]; then
    echo "ACTION: REMOVING artificial latency from all nodes."
else
    echo "ACTION: SETTING ${DELAY}ms latency on all nodes."
fi
echo "=========================================================="

for i in "${!NODES[@]}"; do
    host=${NODES[$i]}
    echo "Processing Node $i ($host)..."

    ssh -o StrictHostKeyChecking=no -i "$KEY" "$USER@$host" "
        # 1. Clear existing qdisc (queueing discipline) rules
        # We suppress stderr in case there are no rules to delete
        sudo tc qdisc del dev $INTERFACE root > /dev/null 2>&1

        # 2. If delay > 0, add new netem rule
        if [ \"$DELAY\" -gt 0 ]; then
            echo \"    Applying ${DELAY}ms delay...\"
            sudo tc qdisc add dev $INTERFACE root netem delay ${DELAY}ms
            
            # Verify
            CHECK=\$(tc qdisc show dev $INTERFACE | grep netem)
            echo \"    Current Config: \$CHECK\"
        else
            echo \"    Latency cleared.\"
        fi
    "
done

echo "=========================================================="
echo "Network configuration update complete."
