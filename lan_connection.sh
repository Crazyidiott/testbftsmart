#!/bin/bash

if [ -n "${LAN_CONNECTION_HELPERS_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
LAN_CONNECTION_HELPERS_LOADED=1

if [ -z "${LAN_CONFIG_FILE:-}" ]; then
    if [ -f "./lan_config_local.sh" ]; then
        LAN_CONFIG_FILE="./lan_config_local.sh"
    else
        LAN_CONFIG_FILE="./lan_config.sh"
    fi
fi

if [ ! -f "${LAN_CONFIG_FILE}" ]; then
    echo "ERROR: LAN config file not found: ${LAN_CONFIG_FILE}" >&2
    return 1 2>/dev/null || exit 1
fi

source "${LAN_CONFIG_FILE}"

SSH_AUTH_MODE="${SSH_AUTH_MODE:-key}"
SSH_STRICT_HOST_KEY_CHECKING="${SSH_STRICT_HOST_KEY_CHECKING:-no}"
CLIENT_IS_LOCAL="${CLIENT_IS_LOCAL:-false}"
CLIENT_PROJECT_PATH="${CLIENT_PROJECT_PATH:-${LOCAL_PROJECT_PATH}}"

if [ -n "${PASS_FILE:-}" ] && [ -z "${PASS:-}" ]; then
    if [ ! -f "${PASS_FILE}" ]; then
        echo "ERROR: PASS_FILE does not exist: ${PASS_FILE}" >&2
        return 1 2>/dev/null || exit 1
    fi

    PASS=$(tr -d '\r\n' < "${PASS_FILE}")
fi

if [ -n "${SUDO_PASS_FILE:-}" ] && [ -z "${SUDO_PASS:-}" ]; then
    if [ ! -f "${SUDO_PASS_FILE}" ]; then
        echo "ERROR: SUDO_PASS_FILE does not exist: ${SUDO_PASS_FILE}" >&2
        return 1 2>/dev/null || exit 1
    fi

    SUDO_PASS=$(tr -d '\r\n' < "${SUDO_PASS_FILE}")
fi

# Fall back to SSH password for sudo when not set explicitly.
SUDO_PASS="${SUDO_PASS:-${PASS:-}}"
SUDO_PASS_ESCAPED=${SUDO_PASS//\'/\'\\\'\'}
SUDO_CMD="sudo -n"
if [ -n "${SUDO_PASS:-}" ]; then
    SUDO_CMD="printf '%s\\n' '${SUDO_PASS_ESCAPED}' | sudo -S -p ''"
fi

if [ ${#REPLICA_NODES[@]} -gt 0 ]; then
    REPLICA_NODES_RESOLVED=("${REPLICA_NODES[@]}")
elif [ ${#NODES[@]} -gt 0 ]; then
    if [ "${CLIENT_IS_LOCAL}" = "true" ]; then
        REPLICA_NODES_RESOLVED=("${NODES[@]}")
    else
        REPLICA_NODES_RESOLVED=("${NODES[@]:0:4}")
    fi
else
    echo "ERROR: No replica nodes defined in ${LAN_CONFIG_FILE}" >&2
    return 1 2>/dev/null || exit 1
fi

REPLICA_COUNT="${REPLICA_COUNT:-${#REPLICA_NODES_RESOLVED[@]}}"
if [ "${REPLICA_COUNT}" -le 0 ]; then
    echo "ERROR: REPLICA_COUNT must be positive" >&2
    return 1 2>/dev/null || exit 1
fi

if [ ${#REPLICA_NODES_RESOLVED[@]} -gt "${REPLICA_COUNT}" ]; then
    REPLICA_NODES_RESOLVED=("${REPLICA_NODES_RESOLVED[@]:0:${REPLICA_COUNT}}")
fi

if [ -z "${LOCAL_PROJECT_PATH:-}" ]; then
    echo "ERROR: LOCAL_PROJECT_PATH is not set in ${LAN_CONFIG_FILE}" >&2
    return 1 2>/dev/null || exit 1
fi

if [ -z "${REMOTE_PROJECT_PATH:-}" ]; then
    echo "ERROR: REMOTE_PROJECT_PATH is not set in ${LAN_CONFIG_FILE}" >&2
    return 1 2>/dev/null || exit 1
fi

if [ -z "${USER:-}" ]; then
    echo "ERROR: USER is not set in ${LAN_CONFIG_FILE}" >&2
    return 1 2>/dev/null || exit 1
fi

if [ "${SSH_AUTH_MODE}" = "key" ]; then
    if [ -z "${KEY:-}" ]; then
        echo "ERROR: KEY is required when SSH_AUTH_MODE=key" >&2
        return 1 2>/dev/null || exit 1
    fi
elif [ "${SSH_AUTH_MODE}" = "password" ]; then
    if [ -z "${PASS:-}" ]; then
        echo "ERROR: PASS is required when SSH_AUTH_MODE=password" >&2
        return 1 2>/dev/null || exit 1
    fi
    if ! command -v sshpass > /dev/null 2>&1; then
        echo "ERROR: sshpass is required when SSH_AUTH_MODE=password" >&2
        echo "Install it with: sudo apt-get install -y sshpass" >&2
        return 1 2>/dev/null || exit 1
    fi
else
    echo "ERROR: Unsupported SSH_AUTH_MODE=${SSH_AUTH_MODE}" >&2
    return 1 2>/dev/null || exit 1
fi

if [ "${CLIENT_IS_LOCAL}" != "true" ] && [ -z "${CLIENT_HOST:-}" ]; then
    if [ ${#NODES[@]} -gt "${REPLICA_COUNT}" ]; then
        CLIENT_HOST="${NODES[${REPLICA_COUNT}]}"
    else
        echo "ERROR: CLIENT_HOST is not set and no remote client node is available in NODES" >&2
        return 1 2>/dev/null || exit 1
    fi
fi

_lan_build_ssh_args() {
    local -n lan_args_ref=$1
    lan_args_ref=(-o "StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING}")
    if [ -n "${SSH_PORT:-}" ]; then
        lan_args_ref+=(-p "${SSH_PORT}")
    fi
    if [ "${SSH_AUTH_MODE}" = "key" ]; then
        lan_args_ref+=(-i "${KEY}")
    fi
}

remote_ssh() {
    local host=$1
    shift
    local -a ssh_args
    _lan_build_ssh_args ssh_args

    if [ "${SSH_AUTH_MODE}" = "password" ]; then
        SSHPASS="${PASS}" sshpass -e ssh "${ssh_args[@]}" "${USER}@${host}" "$@"
    else
        ssh "${ssh_args[@]}" "${USER}@${host}" "$@"
    fi
}

remote_scp_from() {
    local host=$1
    local remote_path=$2
    local local_path=$3
    local -a scp_args
    _lan_build_ssh_args scp_args

    if [ "${SSH_AUTH_MODE}" = "password" ]; then
        SSHPASS="${PASS}" sshpass -e scp "${scp_args[@]}" "${USER}@${host}:${remote_path}" "${local_path}"
    else
        scp "${scp_args[@]}" "${USER}@${host}:${remote_path}" "${local_path}"
    fi
}

remote_rsync_to() {
    local source_path=$1
    local host=$2
    local destination_path=$3
    shift 3

    local remote_shell="ssh -o StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING}"
    if [ -n "${SSH_PORT:-}" ]; then
        remote_shell+=" -p ${SSH_PORT}"
    fi
    if [ "${SSH_AUTH_MODE}" = "key" ]; then
        remote_shell+=" -i ${KEY}"
    fi

    if [ "${SSH_AUTH_MODE}" = "password" ]; then
        SSHPASS="${PASS}" rsync -avz -e "sshpass -e ${remote_shell}" "$@" "${source_path}" "${USER}@${host}:${destination_path}"
    else
        rsync -avz -e "${remote_shell}" "$@" "${source_path}" "${USER}@${host}:${destination_path}"
    fi
}

remote_rsync_from() {
    local host=$1
    local source_path=$2
    local destination_path=$3
    shift 3

    local remote_shell="ssh -o StrictHostKeyChecking=${SSH_STRICT_HOST_KEY_CHECKING}"
    if [ -n "${SSH_PORT:-}" ]; then
        remote_shell+=" -p ${SSH_PORT}"
    fi
    if [ "${SSH_AUTH_MODE}" = "key" ]; then
        remote_shell+=" -i ${KEY}"
    fi

    if [ "${SSH_AUTH_MODE}" = "password" ]; then
        SSHPASS="${PASS}" rsync -avz -e "sshpass -e ${remote_shell}" "$@" "${USER}@${host}:${source_path}" "${destination_path}"
    else
        rsync -avz -e "${remote_shell}" "$@" "${USER}@${host}:${source_path}" "${destination_path}"
    fi
}

remote_file_exists() {
    local host=$1
    local remote_path=$2
    remote_ssh "${host}" "test -f ${remote_path}"
}