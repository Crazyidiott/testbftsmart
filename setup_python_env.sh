#!/bin/bash

source ./lan_connection.sh

echo ">>> [Debug Tool] Setting up Python Agent Environment on Replicas..."

for i in "${!REPLICA_NODES_RESOLVED[@]}"; do
    host=${REPLICA_NODES_RESOLVED[$i]}
    echo "--- Processing Replica $i ($host) ---"

    echo "    Syncing server_agent directory..."
    remote_ssh "$host" "mkdir -p ${REMOTE_PROJECT_PATH}/server_agent"
    remote_rsync_to \
        "${LOCAL_PROJECT_PATH}/server_agent/" \
        "$host" \
        "${REMOTE_PROJECT_PATH}/server_agent/" \
        --exclude 'rlenv/' \
        --exclude '__pycache__/' \
        > /dev/null

    remote_ssh "$host" "
        (
        cd ${REMOTE_PROJECT_PATH}/server_agent

        echo '    [System] Installing python3-venv...'
        if command -v sudo >/dev/null; then
            echo '        DEBUG: sudo found. Attempting update...'
            ${SUDO_CMD} apt-get update
            echo '        DEBUG: Update done. Installing packages...'
            ${SUDO_CMD} apt-get install -y python3-venv python3-pip
        else
            echo '        WARNING: sudo not found, skipping system install. Hoping dependencies exist.'
        fi

        echo '    [System] System packages handling complete.'
        echo '    [Venv] Checking virtual environment...'

        if [ ! -f 'rlenv/bin/python3' ] \
            || ! ./rlenv/bin/python3 --version > /dev/null 2>&1 \
            || ! ./rlenv/bin/python3 -m pip --version > /dev/null 2>&1; then
            echo '        Creating new venv (rlenv)...'
            rm -rf rlenv
            python3 -m venv rlenv
        else
            echo '        Existing venv found.'
        fi

        echo '    [Pip] Installing requirements...'
        if [ -f requirements.txt ]; then
            ./rlenv/bin/python3 -m pip install -q --upgrade pip
            ./rlenv/bin/python3 -m pip install -q -r requirements.txt
        else
            echo '        ERROR: requirements.txt missing!'
            exit 1
        fi

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
