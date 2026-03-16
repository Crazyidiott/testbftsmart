#!/bin/bash

# ================= LAN Configuration =================
# First 4 nodes are remote replicas. Client runs on the local machine.
REPLICA_NODES=("10.16.109.129" "10.16.28.219" "10.16.109.163" "10.16.12.175")
REPLICA_COUNT=4

# Keep NODES for compatibility with older scripts that still read it directly.
NODES=("${REPLICA_NODES[@]}")

# SSH authentication mode: key | password
SSH_AUTH_MODE="password"

# Password file for ssh
PASS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lan_ssh_password.txt"

# Client runs on the local machine.
CLIENT_IS_LOCAL="true"

# Local Project Path (current workspace path)
LOCAL_PROJECT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_PROJECT_PATH="${LOCAL_PROJECT_PATH}"

# Remote Target Directory
REMOTE_BASE="/home/teecert/"
REMOTE_PROJECT_PATH="${REMOTE_BASE}/testbftsmart"

# SSH Username
USER="teecert"

# ===================================================
