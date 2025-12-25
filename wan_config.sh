#!/bin/bash

# ================= WAN Configuration =================


NODE_EUC1="3.70.20.130"
NODE_EUW1="52.51.97.119"
NODE_EUW2="52.56.71.212"
NODE_EUN1="16.171.169.103"
NODE_APNE1="18.183.29.171"

# SSH Key Paths
KEY_APNE1="/home/ubuntu/.ssh/dahui.pem"
KEY_EUC1="/home/ubuntu/.ssh/dahuieuc1.pem"
KEY_EUW1="/home/ubuntu/.ssh/dahuieuw1.pem"
KEY_EUW2="/home/ubuntu/.ssh/dahuieuw2.pem"
KEY_EUN1="/home/ubuntu/.ssh/dahuieun1.pem"

# AWS Public IP List (First 4 are Replicas, 5th is Client)
NODES=("$NODE_EUC1" "$NODE_EUW2" "$NODE_EUN1" "$NODE_APNE1" "$NODE_EUW1")
KEYS=("$KEY_EUC1" "$KEY_EUW2" "$KEY_EUN1" "$KEY_APNE1" "$KEY_EUW1")

# Local Project Path (Your workspace path)
LOCAL_PROJECT_PATH="/home/ubuntu/work/testbftsmart"

# Remote Target Directory
REMOTE_BASE="/home/ubuntu/"
REMOTE_PROJECT_PATH="${REMOTE_BASE}/testbftsmart"

# SSH Username
USER="ubuntu"
# ===================================================
