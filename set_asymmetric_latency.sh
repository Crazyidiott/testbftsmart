#!/bin/bash
# ==============================================================================
# set_asymmetric_latency.sh - 为各节点设置不同的网络延迟
# ==============================================================================
#
# 与 set_latency.sh 的区别：
#   set_latency.sh      对所有节点设置相同延迟（对称）
#   set_asymmetric_latency.sh  对每个 replica 节点设置不同延迟（非对称）
#
# 使用方式：
#   # 为每个 replica 分别指定延迟（ms），不影响 client 节点
#   ./set_asymmetric_latency.sh <delay_node0> <delay_node1> <delay_node2> <delay_node3>
#
#   # 只对 leader (Node 0) 注入 200ms 延迟，其他节点无延迟
#   ./set_asymmetric_latency.sh 200 0 0 0
#
#   # 清除所有延迟
#   ./set_asymmetric_latency.sh 0 0 0 0
#
# ==============================================================================

source ./lan_connection.sh

NUM_REPLICAS=${#REPLICA_NODES_RESOLVED[@]}
INTERFACE="ens5"

if [ "$#" -lt "$NUM_REPLICAS" ]; then
    echo "Usage: ./set_asymmetric_latency.sh <delay_node0> <delay_node1> <delay_node2> <delay_node3>"
    echo ""
    echo "Each delay is in milliseconds. Use 0 to remove delay for that node."
    echo ""
    echo "Examples:"
    echo "  ./set_asymmetric_latency.sh 200 0 0 0    # Only leader (Node 0) gets 200ms delay"
    echo "  ./set_asymmetric_latency.sh 0 0 0 0      # Clear all delays"
    echo "  ./set_asymmetric_latency.sh 100 0 0 50   # Node 0: 100ms, Node 3: 50ms"
    exit 1
fi

echo "=========================================================="
echo "ACTION: Setting ASYMMETRIC latency on replica nodes."
echo "=========================================================="

delays=("$@")

for i in $(seq 0 $((NUM_REPLICAS - 1))); do
    delay=${delays[$i]}
    host=${REPLICA_NODES_RESOLVED[$i]}

    if [ "$delay" -eq 0 ]; then
        echo "Node $i ($host): CLEARING delay"
    else
        echo "Node $i ($host): Setting ${delay}ms delay"
    fi

    remote_ssh "$host" "
        sudo tc qdisc del dev $INTERFACE root > /dev/null 2>&1

        if [ \"$delay\" -gt 0 ]; then
            sudo tc qdisc add dev $INTERFACE root netem delay ${delay}ms
            CHECK=\$(tc qdisc show dev $INTERFACE | grep netem)
            echo \"    Applied: \$CHECK\"
        else
            echo \"    Cleared.\"
        fi
    "
done

echo "=========================================================="
echo "Asymmetric latency configuration complete."
echo "  Node 0: $1 ms"
echo "  Node 1: $2 ms"
echo "  Node 2: $3 ms"
echo "  Node 3: $4 ms"
echo "=========================================================="
