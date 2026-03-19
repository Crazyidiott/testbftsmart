#!/bin/bash
# Load configuration
source ./lan_connection.sh

DELAY=$1

if [ -z "$DELAY" ]; then
    echo "Usage: ./set_latency.sh <delay_in_ms>"
    echo "Example: ./set_latency.sh 50   (Adds 50ms delay)"
    echo "Example: ./set_latency.sh 0    (Removes delay)"
    exit 1
fi

# Optional override:
#   LATENCY_INTERFACE=<iface> ./set_latency.sh <delay_ms>
INTERFACE_OVERRIDE="${LATENCY_INTERFACE:-}"

echo "=========================================================="
if [ "$DELAY" -eq 0 ]; then
    echo "ACTION: REMOVING artificial latency from all nodes."
else
    echo "ACTION: SETTING ${DELAY}ms latency on all nodes."
fi
echo "=========================================================="

for i in "${!REPLICA_NODES_RESOLVED[@]}"; do
    host=${REPLICA_NODES_RESOLVED[$i]}
    echo "Processing Node $i ($host)..."

    remote_ssh "$host" "
        IFACE=\"${INTERFACE_OVERRIDE}\"
        if [ -z \"\$IFACE\" ]; then
            IFACE=\$(ip route show default 2>/dev/null | awk '/default/ {print \$5; exit}')
        fi
        if [ -z \"\$IFACE\" ]; then
            IFACE=\$(ip -o link show | awk -F': ' '\$2 !~ /lo/ {print \$2; exit}')
        fi
        if [ -z \"\$IFACE\" ]; then
            echo \"    ERROR: Cannot detect network interface on host\"
            exit 1
        fi
        echo \"    Interface: \$IFACE\"

        # 1. Clear existing qdisc (queueing discipline) rules
        # We suppress stderr in case there are no rules to delete
        ${SUDO_CMD} tc qdisc del dev \$IFACE root > /dev/null 2>&1

        # 2. If delay > 0, add new netem rule
        if [ \"$DELAY\" -gt 0 ]; then
            echo \"    Applying ${DELAY}ms delay...\"
            ${SUDO_CMD} tc qdisc add dev \$IFACE root netem delay ${DELAY}ms
            
            # Verify
            CHECK=\$(tc qdisc show dev \$IFACE | grep netem)
            echo \"    Current Config: \$CHECK\"
        else
            echo \"    Latency cleared.\"
        fi
    "
done

if [ "${CLIENT_IS_LOCAL}" != "true" ]; then
    echo "Processing Client (${CLIENT_HOST})..."
    remote_ssh "${CLIENT_HOST}" "
        IFACE=\"${INTERFACE_OVERRIDE}\"
        if [ -z \"\$IFACE\" ]; then
            IFACE=\$(ip route show default 2>/dev/null | awk '/default/ {print \$5; exit}')
        fi
        if [ -z \"\$IFACE\" ]; then
            IFACE=\$(ip -o link show | awk -F': ' '\$2 !~ /lo/ {print \$2; exit}')
        fi
        if [ -z \"\$IFACE\" ]; then
            echo \"    ERROR: Cannot detect network interface on client host\"
            exit 1
        fi
        echo \"    Interface: \$IFACE\"

        ${SUDO_CMD} tc qdisc del dev \$IFACE root > /dev/null 2>&1

        if [ \"$DELAY\" -gt 0 ]; then
            echo \"    Applying ${DELAY}ms delay...\"
            ${SUDO_CMD} tc qdisc add dev \$IFACE root netem delay ${DELAY}ms
            CHECK=\$(tc qdisc show dev \$IFACE | grep netem)
            echo \"    Current Config: \$CHECK\"
        else
            echo \"    Latency cleared.\"
        fi
    "
else
    echo "Skipping local client latency injection."
fi

echo "=========================================================="
echo "Network configuration update complete."
