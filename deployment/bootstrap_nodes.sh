#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PROJECT_DIR/config/cloud.conf"
NODES_FILE="$PROJECT_DIR/config/nodes.conf"

if [[ ! -f "$CONFIG_FILE" || ! -f "$NODES_FILE" ]]; then
    echo "[ERROR] Required configuration files are missing."
    exit 1
fi

source "$CONFIG_FILE"
source "$NODES_FILE"

if [[ "$EUID" -ne 0 ]]; then
    echo "[ERROR] Run with sudo on the WSL Ubuntu host."
    exit 1
fi

for command in ssh scp tar ssh-keygen mktemp; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "[ERROR] Required command is missing: $command"
        exit 1
    fi
done

PRIVATE_KEY="${NODE_SSH_PRIVATE_KEY_PATH:-}"
PUBLIC_KEY="${NODE_SSH_PUBLIC_KEY_PATH:-}"
CONTROLLER_IP="${CONTROLLER_IP:-}"
REMOTE_DIR="${REMOTE_DEPLOY_DIR:-/opt/mini-cloud}"
CLOUD_USER="${CLOUD_USER:-ubuntu}"

if [[ -z "$PRIVATE_KEY" || ! -f "$PRIVATE_KEY" ]]; then
    echo "[ERROR] Infrastructure private key is missing: $PRIVATE_KEY"
    exit 1
fi

if [[ -z "$PUBLIC_KEY" || ! -f "$PUBLIC_KEY" ]]; then
    echo "[ERROR] Infrastructure public key is missing: $PUBLIC_KEY"
    exit 1
fi

if [[ ! "$CONTROLLER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "[ERROR] Invalid Controller IP address."
    exit 1
fi

if [[ ! "$REMOTE_DIR" =~ ^/[a-zA-Z0-9_./-]+$ ]]; then
    echo "[ERROR] Invalid remote deployment directory."
    exit 1
fi

SSH_PORT="${SSH_PORT:-22}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"

python3 - "$CONTROLLER_IP" "$SSH_PORT" "$SSH_CONNECT_TIMEOUT" \
    "${COMPUTE_NODES[@]}" <<'PYVALIDATE'
import ipaddress
import sys

controller_ip, ssh_port, timeout, *nodes = sys.argv[1:]

try:
    ipaddress.IPv4Address(controller_ip)

    if not ssh_port.isdigit() or not 1 <= int(ssh_port) <= 65535:
        raise ValueError("SSH port must be between 1 and 65535")

    if not timeout.isdigit() or int(timeout) < 1:
        raise ValueError("SSH timeout must be a positive integer")

    for node in nodes:
        name, address = node.split("|", 1)
        ipaddress.IPv4Address(address)

except (ValueError, TypeError) as error:
    print(f"[ERROR] Invalid infrastructure configuration: {error}", file=sys.stderr)
    sys.exit(1)
PYVALIDATE

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
COMPUTE_TARGETS=()

for node in "${COMPUTE_NODES[@]}"; do
    IFS='|' read -r node_name node_ip <<< "$node"

    if [[ ! "$node_name" =~ ^compute-[0-9]+$ ||
        ! "$node_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "[ERROR] Invalid compute node entry: $node"
        exit 1
    fi

    COMPUTE_TARGETS+=("${CLOUD_USER}@${node_ip}")
done

if [[ "${#COMPUTE_TARGETS[@]}" -lt 1 ]]; then
    echo "[ERROR] No compute nodes are configured."
    exit 1
fi

TEMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf -- "$TEMP_DIR"
}

trap cleanup EXIT

ARCHIVE="$TEMP_DIR/mini-cloud.tar.gz"

echo "======================================"
echo " Mini Cloud Node Bootstrap"
echo "======================================"

echo "[1/8] Checking infrastructure SSH access."

for target in "$CONTROLLER" "${COMPUTE_TARGETS[@]}"; do
    echo "[INFO] Checking $target"

    if ! ssh "${SSH_OPTIONS[@]}" "$target" "true"; then
        echo "[ERROR] Cannot connect to $target."
        echo "[INFO] Check VM state, IP address, SSH key and network."
        exit 1
    fi

    echo "[OK] SSH connection verified: $target"
done

echo "[2/8] Creating project archive."

tar -czf "$ARCHIVE" \
    -C "$PROJECT_DIR" \
    README.md LICENSE config architecture controller compute \
    deployment hypervisor networking security tests docs demo

echo "[OK] Project archive created."

echo "[3/8] Preparing infrastructure nodes."

for target in "$CONTROLLER" "${COMPUTE_TARGETS[@]}"; do
    echo "[INFO] Preparing $target"

    ssh "${SSH_OPTIONS[@]}" "$target" \
        "sudo apt-get update &&
         sudo apt-get install -y \
         openssh-server \
         openssh-client \
         python3 \
         curl \
         tar \
         ca-certificates \
         nftables \
         dnsmasq-base \
         qemu-utils &&
         sudo mkdir -p '$REMOTE_DIR' &&
         sudo chown '$CLOUD_USER:$CLOUD_USER' '$REMOTE_DIR'"
done


echo "[4/8] Deploying project files."

for target in "$CONTROLLER" "${COMPUTE_TARGETS[@]}"; do
    echo "[INFO] Deploying to $target"

    scp "${SCP_OPTIONS[@]}" "$ARCHIVE" "$target:/tmp/mini-cloud.tar.gz"

    ssh "${SSH_OPTIONS[@]}" "$target" \
        "sudo tar -xzf /tmp/mini-cloud.tar.gz -C '$REMOTE_DIR' &&
         sudo find '$REMOTE_DIR' -type d -exec chmod 755 {} + &&
         sudo find '$REMOTE_DIR' -type f -exec chmod 644 {} + &&
         sudo find '$REMOTE_DIR' -type f -name '*.sh' -exec chmod 755 {} + &&
         sudo chown -R '$CLOUD_USER:$CLOUD_USER' '$REMOTE_DIR' &&
         rm -f /tmp/mini-cloud.tar.gz &&
         mkdir -p '$REMOTE_DIR/logs' '$REMOTE_DIR/results'"
done


echo "[5/8] Configuring compute nodes."

for target in "${COMPUTE_TARGETS[@]}"; do
    echo "[INFO] Preparing compute node: $target"

    ssh "${SSH_OPTIONS[@]}" "$target" \
        "sudo cloud-init status --wait &&
         sudo bash '$REMOTE_DIR/hypervisor/kvm_setup.sh' &&
         sudo bash '$REMOTE_DIR/hypervisor/libvirt_setup.sh' &&
         sudo bash '$REMOTE_DIR/hypervisor/storage_setup.sh' &&
         sudo bash '$REMOTE_DIR/networking/guest_network_setup.sh'"

    ssh "${SSH_OPTIONS[@]}" "$target" \
        "sudo install -d '$(dirname "$GUEST_BASE_IMAGE")' &&
         if ! sudo test -s '$GUEST_BASE_IMAGE'; then
             sudo curl -fL --retry 3 '$GUEST_BASE_IMAGE_URL' -o '$GUEST_BASE_IMAGE';
         fi &&
         sudo qemu-img info '$GUEST_BASE_IMAGE' >/dev/null"
done

echo "[6/8] Configuring Controller-to-Compute SSH access."

ssh "${SSH_OPTIONS[@]}" "$CONTROLLER" \
    "mkdir -p ~/.ssh &&
     chmod 700 ~/.ssh &&
     if [[ ! -f '$CONTROLLER_SSH_KEY_PATH' ]]; then
         ssh-keygen -t ed25519 -N '' -f '$CONTROLLER_SSH_KEY_PATH' -C mini-cloud-controller;
     elif [[ ! -f '$CONTROLLER_SSH_KEY_PATH.pub' ]]; then
         ssh-keygen -y -f '$CONTROLLER_SSH_KEY_PATH' > '$CONTROLLER_SSH_KEY_PATH.pub';
     fi &&
     chmod 600 '$CONTROLLER_SSH_KEY_PATH' &&
     chmod 644 '$CONTROLLER_SSH_KEY_PATH.pub'"

CONTROLLER_PUBLIC_KEY="$(
    ssh "${SSH_OPTIONS[@]}" "$CONTROLLER" \
        "cat '$CONTROLLER_SSH_KEY_PATH.pub'"
)"

if [[ ! "$CONTROLLER_PUBLIC_KEY" =~ ^ssh-ed25519[[:space:]]+[A-Za-z0-9+/=]+ ]]; then
    echo "[ERROR] Controller public key is invalid."
    exit 1
fi

echo "[INFO] Registering Compute host keys on Controller."

for node in "${COMPUTE_NODES[@]}"; do
    IFS='|' read -r node_name node_ip <<< "$node"

    ssh "${SSH_OPTIONS[@]}" "$CONTROLLER" \
        "ssh-keygen -R '$node_ip' -f ~/.ssh/known_hosts >/dev/null 2>&1 || true;
         ssh-keyscan -H -p '$SSH_PORT' '$node_ip' >> ~/.ssh/known_hosts &&
         chmod 600 ~/.ssh/known_hosts"
done

for target in "${COMPUTE_TARGETS[@]}"; do
    echo "[INFO] Authorizing Controller on $target"

    ssh "${SSH_OPTIONS[@]}" "$target" \
        "mkdir -p ~/.ssh &&
         chmod 700 ~/.ssh &&
         touch ~/.ssh/authorized_keys &&
         chmod 600 ~/.ssh/authorized_keys &&
         if ! grep -qxF '$CONTROLLER_PUBLIC_KEY' ~/.ssh/authorized_keys; then
             printf '%s\n' '$CONTROLLER_PUBLIC_KEY' >> ~/.ssh/authorized_keys;
         fi"
done

echo "[7/8] Applying security configuration to infrastructure nodes."

if [[ -z "${MGMT_NETWORK_CIDR:-}" ]]; then
    echo "[ERROR] Management network CIDR is not configured."
    exit 1
fi

for target in "$CONTROLLER" "${COMPUTE_TARGETS[@]}"; do
    echo "[INFO] Securing $target"

    ssh "${SSH_OPTIONS[@]}" "$target" \
        "sudo env SSH_ALLOWED_CIDR='$MGMT_NETWORK_CIDR' \
         bash '$REMOTE_DIR/security/security_setup.sh'"
done

echo "[8/8] Verifying KVM acceleration on compute nodes."

for target in "${COMPUTE_TARGETS[@]}"; do
    echo "[INFO] Checking KVM acceleration on $target"

    if ! ssh "${SSH_OPTIONS[@]}" "$target" \
        "sudo kvm-ok"; then
        echo "[ERROR] KVM acceleration is unavailable on $target."
        echo "[INFO] Check nested virtualization and CPU passthrough."
        exit 1
    fi

    echo "[OK] KVM acceleration check passed on $target."
done

echo
echo "======================================"
echo " Node Bootstrap Summary"
echo "======================================"
echo "Controller: $CONTROLLER"
printf 'Compute nodes: %s\n' "${#COMPUTE_TARGETS[@]}"
echo "Project directory: $REMOTE_DIR"
echo "Controller-to-Compute SSH key: configured"
echo
echo "[OK] Node bootstrap completed."
