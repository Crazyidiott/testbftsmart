#!/bin/bash

# 加载 LAN 配置
source lan_config.sh

echo ">>> Cleaning up /tmp/bft-* files on all nodes..."

# 遍历所有节点 (Replica + Client)
for ip in "${NODES[@]}"; do
    echo "    Cleaning on $ip..."
    ssh -o StrictHostKeyChecking=no -i "$KEY" "$USER@$ip" "rm -f /tmp/bft-*"
done

echo ">>> Cleanup complete."
