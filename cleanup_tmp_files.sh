#!/bin/bash

source ./lan_connection.sh

echo ">>> Cleaning up /tmp/bft-* files on all nodes..."

for ip in "${REPLICA_NODES_RESOLVED[@]}"; do
    echo "    Cleaning on $ip..."
    remote_ssh "$ip" "rm -f /tmp/bft-*"
done

if [ "${CLIENT_IS_LOCAL}" = "true" ]; then
    echo "    Cleaning on local client..."
    rm -f /tmp/bft-*
else
    echo "    Cleaning on client host ${CLIENT_HOST}..."
    remote_ssh "${CLIENT_HOST}" "rm -f /tmp/bft-*"
fi

echo ">>> Cleanup complete."
