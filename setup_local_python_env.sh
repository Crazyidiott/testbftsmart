#!/bin/bash

# Local Python Agent Environment Setup
# Mirrors setup_python_env.sh but runs entirely on the local machine.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="${SCRIPT_DIR}/server_agent"

echo ">>> [Local Setup] Setting up Python Agent Environment locally..."
echo "--- Agent directory: ${AGENT_DIR} ---"

cd "${AGENT_DIR}" || { echo "ERROR: Cannot find server_agent directory at ${AGENT_DIR}"; exit 1; }

echo "    [System] Installing python3-venv and python3-pip..."
if command -v sudo >/dev/null; then
    echo "        DEBUG: sudo found. Waiting for dpkg lock..."
    while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        echo "        Waiting for other package manager to finish..."
        sleep 5
    done
    echo "        Attempting update..."
    sudo apt-get update
    echo "        Update done. Installing packages..."
    sudo apt-get install -y python3-venv python3-pip
else
    echo "        WARNING: sudo not found, skipping system install. Hoping dependencies exist."
fi

echo "    [System] System packages handling complete."

echo "    [Venv] Checking virtual environment..."
if [ ! -f 'rlenv/bin/python3' ] || ! ./rlenv/bin/python3 --version > /dev/null 2>&1; then
    echo "        Creating new venv (rlenv)..."
    rm -rf rlenv
    python3 -m venv rlenv
else
    echo "        Existing venv found."
fi

echo "    [Pip] Installing requirements..."
if [ -f requirements.txt ]; then
    ./rlenv/bin/pip install -q --upgrade pip
    ./rlenv/bin/pip install -q -r requirements.txt
else
    echo "        ERROR: requirements.txt missing!"
    exit 1
fi

echo "    [TEST] Verifying installation..."
VER=$(./rlenv/bin/python3 --version)
echo "        Python Version: $VER"
if ./rlenv/bin/python3 -c "import grpc; import torch; import numpy; print('        Success: All modules imported')" 2>/tmp/test_err; then
    echo "        Environment OK."
else
    echo "        FAILURE: Module import failed."
    cat /tmp/test_err
    exit 1
fi

echo ">>> Local Setup & Test Complete."
