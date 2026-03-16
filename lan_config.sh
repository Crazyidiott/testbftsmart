#!/bin/bash

# ================= LAN Configuration =================
# AWS Private IP List (First 4 are Replicas, 5th is Client)
NODES=("172.31.15.219" "172.31.4.11" "172.31.10.49" "172.31.10.254" "172.31.13.125")

# SSH authentication mode: key | password
SSH_AUTH_MODE="key"

# SSH Key Path
KEY="/home/ubuntu/.ssh/dahui.pem"

# Local Project Path (Your workspace path)
LOCAL_PROJECT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Remote Target Directory
REMOTE_BASE="/home/ubuntu/"
REMOTE_PROJECT_PATH="${REMOTE_BASE}/testbftsmart"

# SSH Username
USER="ubuntu"
# ===================================================
