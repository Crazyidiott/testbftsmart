#!/bin/bash

# Load LAN Configuration
source ./lan_config.sh

echo ">>> [Debug Tool] Setting up Python Agent Environment on Replicas..."

# Loop only through replicas (0-3)
for i in {0..3}; do
    host=${NODES[$i]}
    echo "--- Processing Replica $i ($host) ---"

    # Sync server_agent first to ensure requirements.txt is there
    echo "    Syncing server_agent directory..."
    # Ensure remote directory exists
    ssh -i "$KEY" "$USER@$host" "mkdir -p ${REMOTE_PROJECT_PATH}/server_agent"
    
    rsync -avz -e "ssh -i $KEY -o StrictHostKeyChecking=no" \
            "${LOCAL_PROJECT_PATH}/server_agent/" "$USER@$host:${REMOTE_PROJECT_PATH}/server_agent/" > /dev/null

    ssh -i "$KEY" "$USER@$host" "
        # Run commands in a subshell to isolate errors and ensure continuation
        (
        cd ${REMOTE_PROJECT_PATH}/server_agent

        echo '    [System] Installing python3-venv...'
        
        # DEBUG: Check sudo availability
        if command -v sudo >/dev/null; then
            echo '        DEBUG: sudo found. Attempting update...'
             # Removed quiet flags to see errors
            sudo apt-get update
            echo '        DEBUG: Update done. Installing packages...'
            sudo apt-get install -y python3-venv python3-pip
        else
            echo '        WARNING: sudo not found, skipping system install. Hoping dependencies exist.'
        fi
        
        echo '    [System] System packages handling complete.'
        
        # Kill any existing trainer process that might be holding files
        # Modified to match only python processes to avoid killing the SSH session script itself
        # pkill -f "python3.*trainer.py" || true
        # Commenting out pkill entirely to isolate if it's the culprit causing session disconnects
        
        echo '    [Venv] Checking virtual environment...'
        # Check if python3 works in the venv
        if [ ! -f 'rlenv/bin/python3' ] || ! ./rlenv/bin/python3 --version > /dev/null 2>&1; then
            echo '        Creating new venv (rlenv)...'
            rm -rf rlenv
            python3 -m venv rlenv
        else
            echo '        Existing venv found.'
        fi
        
        echo '    [Pip] Installing requirements...'
        if [ -f requirements.txt ]; then
             ./rlenv/bin/pip install -q --upgrade pip
             ./rlenv/bin/pip install -q -r requirements.txt
        else
             echo '        ERROR: requirements.txt missing!'
             exit 1
        fi
        
        # Debug Test
        echo '    [TEST] Verifying installation...'
        VER=\$(./rlenv/bin/python3 --version)
        echo \"        Python Version: \$VER\"
        if ./rlenv/bin/python3 -c \"import grpc; import torch; import numpy; print('        Success: All modules imported')\" 2>/tmp/test_err; then
            echo \"        Environment OK.\"
        else
            echo \"        FAILURE: Module import failed.\"
            cat /tmp/test_err
        fi
        )
    "
done

echo ">>> Setup & Test Complete."
