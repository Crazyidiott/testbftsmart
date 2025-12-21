#!/bin/bash

# ================= WAN Configuration =================


NODE_EUC1="3.73.100.30"
NODE_EUW1="3.255.86.73"
NODE_EUW2="3.10.233.57"
NODE_EUN1="51.21.200.215"
NODE_APNE1="43.207.183.154"

# SSH Key Paths
KEY_APNE1="/home/ubuntu/.ssh/dahui.pem"
KEY_EUC1="/home/ubuntu/.ssh/dahuieuc1.pem"
KEY_EUW1="/home/ubuntu/.ssh/dahuieuw1.pem"
KEY_EUW2="/home/ubuntu/.ssh/dahuieuw2.pem"
KEY_EUN1="/home/ubuntu/.ssh/dahuieun1.pem"

# AWS Public IP List (First 4 are Replicas, 5th is Client)
NODES=("$NODE_EUC1"  "$NODE_EUW1" "$NODE_EUW2" "$NODE_EUN1" "$NODE_APNE1")
KEYS=("$KEY_EUC1"  "$KEY_EUW1" "$KEY_EUW2" "$KEY_EUN1" "$KEY_APNE1")

# Local Project Path (Your workspace path)
LOCAL_PROJECT_PATH="/home/ubuntu/work/testbftsmart"

# Remote Target Directory
REMOTE_BASE="/home/ubuntu/"
REMOTE_PROJECT_PATH="${REMOTE_BASE}/testbftsmart"

# SSH Username
USER="ubuntu"
# ===================================================
