#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config/cloud.conf"

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 VM_NAME SSH_PUBLIC_KEY"
    exit 1
fi

VM_NAME="$1"
GUEST_PUBLIC_KEY="$2"

if [[ ! "$VM_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    echo "[ERROR] Invalid VM name."
    exit 1
fi

if [[ ! -f "$CONFIG_FILE" || ! -f "$GUEST_PUBLIC_KEY" ||
      ! -r "$GUEST_PUBLIC_KEY" ]]; then
    echo "[ERROR] Configuration or public key file is missing."
    exit 1
fi

source "$CONFIG_FILE"

CLOUD_USER="${CLOUD_USER:-ubuntu}"
CONTROLLER_IP="${CONTROLLER_IP:-}"
REMOTE_DIR="${REMOTE_DEPLOY_DIR:-/opt/mini-cloud}"
PRIVATE_KEY="${NODE_SSH_PRIVATE_KEY_PATH:-}"
SSH_PORT="${SSH_PORT:-22}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"

if [[ ! -f "$PRIVATE_KEY" || ! -r "$PRIVATE_KEY" ]]; then
    echo "[ERROR] Infrastructure SSH private key is unavailable."
    exit 1
fi

if [[ ! "$CONTROLLER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ||
      ! "$REMOTE_DIR" =~ ^/[a-zA-Z0-9_./-]+$ ]]; then
    echo "[ERROR] Invalid Controller configuration."
    exit 1
fi

if ! ssh-keygen -l -f "$GUEST_PUBLIC_KEY" >/dev/null 2>&1; then
    echo "[ERROR] Invalid SSH public key."
    exit 1
fi

SSH_OPTIONS=(
    -i "$PRIVATE_KEY"
    -p "$SSH_PORT"
    -o IdentitiesOnly=yes
    -o BatchMode=yes
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
    -o StrictHostKeyChecking=accept-new
)

SCP_OPTIONS=(
    -i "$PRIVATE_KEY"
    -P "$SSH_PORT"
    -o IdentitiesOnly=yes
    -o BatchMode=yes
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
    -o StrictHostKeyChecking=accept-new
)

CONTROLLER="${CLOUD_USER}@${CONTROLLER_IP}"
REMOTE_KEY="/home/$CLOUD_USER/.ssh/guest-${VM_NAME}-request.pub"

echo "[INFO] Transferring requester public key to Controller."

ssh "${SSH_OPTIONS[@]}" "$CONTROLLER" \
    "umask 077; test ! -e '$REMOTE_KEY'"

scp "${SCP_OPTIONS[@]}" "$GUEST_PUBLIC_KEY" \
    "$CONTROLLER:$REMOTE_KEY"

echo "[INFO] Starting guest deployment."

if ssh "${SSH_OPTIONS[@]}" "$CONTROLLER" \
    "trap 'rm -f -- \"$REMOTE_KEY\"' EXIT;
     bash '$REMOTE_DIR/controller/cloud_manager.sh' deploy '$VM_NAME' '$REMOTE_KEY'"; then
    echo "[OK] Deployment command completed."
else
    status=$?
    echo "[ERROR] Guest deployment failed (exit status $status)."
    exit "$status"
fi
