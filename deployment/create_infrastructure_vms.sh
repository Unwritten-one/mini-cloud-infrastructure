#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PROJECT_DIR/config/cloud.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERROR] Configuration file not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

POOL_NAME="${INFRA_LIBVIRT_POOL_NAME:-infrastructure-vms}"
POOL_PATH="${INFRA_VM_STORAGE_PATH:-/mnt/infrastructure-vm-storage}"
NETWORK="${MGMT_NETWORK_NAME:-cloud-management}"
BASE_IMAGE="${INFRA_BASE_IMAGE:-}"
PRIVATE_KEY="${NODE_SSH_PRIVATE_KEY_PATH:-}"
PUBLIC_KEY="${NODE_SSH_PUBLIC_KEY_PATH:-}"

if [[ "$EUID" -ne 0 ]]; then
    echo "[ERROR] Run with sudo."
    exit 1
fi

for command in virsh virt-install qemu-img cloud-localds ssh-keygen python3 awk curl install; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "[ERROR] Missing command: $command"
        exit 1
    fi
done

if [[ ! -e /dev/kvm ]]; then
    echo "[ERROR] /dev/kvm is unavailable. Check nested virtualization."
    exit 1
fi

BASE_IMAGE_URL="${GUEST_BASE_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"

install -d -m 0755 "$(dirname "$BASE_IMAGE")"

if [[ ! -s "$BASE_IMAGE" ]]; then
    echo "[INFO] Downloading Ubuntu infrastructure base image."
    TEMP_IMAGE="${BASE_IMAGE}.tmp.$$"

    if ! curl -fL --retry 3 "$BASE_IMAGE_URL" -o "$TEMP_IMAGE"; then
        rm -f "$TEMP_IMAGE"
        echo "[ERROR] Failed to download infrastructure base image."
        exit 1
    fi

    mv "$TEMP_IMAGE" "$BASE_IMAGE"
    chmod 0644 "$BASE_IMAGE"
fi

if [[ ! -f "$BASE_IMAGE" || ! -r "$BASE_IMAGE" ]]; then
    echo "[ERROR] Infrastructure base image is unavailable: $BASE_IMAGE"
    exit 1
fi

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    echo "[ERROR] Infrastructure SSH key paths are not configured."
    exit 1
fi

if ! virsh -c qemu:///system uri >/dev/null 2>&1; then
    echo "[ERROR] Cannot connect to system libvirt."
    exit 1
fi

if ! virsh -c qemu:///system net-info "$NETWORK" >/dev/null 2>&1; then
    echo "[ERROR] Management network does not exist: $NETWORK"
    echo "[INFO] Run networking/network_setup.sh first."
    exit 1
fi

NETWORK_STATE="$(virsh -c qemu:///system net-info "$NETWORK" |
    awk -F: '/^Active:/ {gsub(/[[:space:]]/, "", $2); print $2}')"

if [[ "$NETWORK_STATE" != "yes" ]]; then
    echo "[ERROR] Management network is not active."
    exit 1
fi

BASE_FORMAT="$(qemu-img info --output=json "$BASE_IMAGE" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["format"])')"

if [[ "$BASE_FORMAT" != "qcow2" && "$BASE_FORMAT" != "raw" ]]; then
    echo "[ERROR] Unsupported base image format: $BASE_FORMAT"
    exit 1
fi

if [[ -e "$PRIVATE_KEY" && ! -e "$PUBLIC_KEY" ]]; then
    echo "[INFO] Recreating missing public key."
    ssh-keygen -y -f "$PRIVATE_KEY" > "$PUBLIC_KEY"
elif [[ ! -e "$PRIVATE_KEY" && -e "$PUBLIC_KEY" ]]; then
    echo "[ERROR] Public key exists but private key is missing."
    exit 1
elif [[ ! -e "$PRIVATE_KEY" && ! -e "$PUBLIC_KEY" ]]; then
    echo "[INFO] Generating infrastructure SSH key pair."
    mkdir -p "$(dirname "$PRIVATE_KEY")"
    chmod 700 "$(dirname "$PRIVATE_KEY")"
    ssh-keygen -t ed25519 -N "" -f "$PRIVATE_KEY" -C "mini-cloud-infrastructure"
fi

chmod 600 "$PRIVATE_KEY"
chmod 644 "$PUBLIC_KEY"

PUBLIC_KEY_CONTENT="$(<"$PUBLIC_KEY")"

if [[ ! "$PUBLIC_KEY_CONTENT" =~ ^ssh-ed25519[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]]; then
    echo "[ERROR] Invalid Ed25519 public key."
    exit 1
fi

for command in df install; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "[ERROR] Missing storage verification command: $command"
        exit 1
    fi
done

if [[ "$POOL_PATH" != /var/lib/mini-cloud/infrastructure-vms ]]; then
    echo "[ERROR] Unexpected infrastructure storage path: $POOL_PATH"
    exit 1
fi

install -d -o root -g kvm -m 0770 "$POOL_PATH"

if [[ ! -d "$POOL_PATH" || ! -w "$POOL_PATH" ]]; then
    echo "[ERROR] Infrastructure storage directory is not writable: $POOL_PATH"
    exit 1
fi

AVAILABLE_GB="$(df -BG --output=avail "$POOL_PATH" | tail -n 1 | tr -dc '0-9')"

if [[ ! "$AVAILABLE_GB" =~ ^[0-9]+$ ]] || [[ "$AVAILABLE_GB" -lt 15 ]]; then
    echo "[ERROR] Infrastructure storage requires at least 15 GB free."
    exit 1
fi

echo "[OK] Local infrastructure storage verified."
echo "[INFO] Available storage: ${AVAILABLE_GB} GB"

if ! virsh -c qemu:///system pool-info "$POOL_NAME" >/dev/null 2>&1; then
    echo "[INFO] Creating infrastructure storage pool."
    virsh -c qemu:///system pool-define-as "$POOL_NAME" dir --target "$POOL_PATH"
fi

POOL_STATE="$(virsh -c qemu:///system pool-info "$POOL_NAME" |
    awk -F: '/^State:/ {gsub(/^[[:space:]]+/, "", $2); print $2}')"

if [[ "$POOL_STATE" != "running" ]]; then
    virsh -c qemu:///system pool-build "$POOL_NAME" >/dev/null 2>&1 || true
    virsh -c qemu:///system pool-start "$POOL_NAME"
fi

virsh -c qemu:///system pool-autostart "$POOL_NAME"

POOL_TARGET="$(virsh -c qemu:///system pool-dumpxml "$POOL_NAME" |
    python3 -c 'import sys,xml.etree.ElementTree as E; print(E.parse(sys.stdin).findtext("./target/path"))')"

if [[ "$(realpath -e "$POOL_TARGET")" != "$(realpath -e "$POOL_PATH")" ]]; then
    echo "[ERROR] Infrastructure storage pool points to an unexpected directory."
    exit 1
fi

create_infrastructure_vm() {
    local name="$1"
    local memory="$2"
    local vcpus="$3"
    local mac="$4"
    local data_disk_gb="$5"

    local system_disk="$POOL_PATH/$name-system.qcow2"
    local data_disk="$POOL_PATH/$name-data.qcow2"
    local seed_iso="$POOL_PATH/$name-cloud-init.iso"
    local seed_dir
    local network_arg

    if virsh -c qemu:///system dominfo "$name" >/dev/null 2>&1; then
        echo "[SKIP] $name already exists. Preserving existing VM."
        return 0
    fi

    for path in "$system_disk" "$seed_iso"; do
        if [[ -e "$path" ]]; then
            echo "[ERROR] Existing file found: $path"
            echo "[ERROR] Inspect it before attempting to recreate $name."
            return 1
        fi
    done

    if [[ "$data_disk_gb" -gt 0 && -e "$data_disk" ]]; then
        echo "[ERROR] Existing data disk found: $data_disk"
        return 1
    fi

    echo "[INFO] Creating $name system disk."

    qemu-img create -f qcow2 -F "$BASE_FORMAT" \
        -b "$BASE_IMAGE" "$system_disk"

    if [[ "$data_disk_gb" -gt 0 ]]; then
        echo "[INFO] Creating $name data disk."
        qemu-img create -f qcow2 "$data_disk" "${data_disk_gb}G"
    fi

    seed_dir="$(mktemp -d)"

    cat > "$seed_dir/user-data" <<EOF
#cloud-config
hostname: $name
manage_etc_hosts: true
ssh_pwauth: false
disable_root: true
users:
  - default
ssh_authorized_keys:
  - $PUBLIC_KEY_CONTENT
EOF

    if [[ "$data_disk_gb" -gt 0 ]]; then
        cat >> "$seed_dir/user-data" <<'EOF'
disk_setup:
  /dev/vdb:
    table_type: gpt
    layout: true
    overwrite: false
fs_setup:
  - label: cloud-data
    filesystem: ext4
    device: /dev/vdb1
    overwrite: false
mounts:
  - [ "LABEL=cloud-data", "/mnt/cloud-vm-storage", "ext4", "defaults,nofail", "0", "2" ]
EOF
    fi

    cat > "$seed_dir/meta-data" <<EOF
instance-id: $name
local-hostname: $name
EOF

    if ! cloud-localds "$seed_iso" "$seed_dir/user-data" "$seed_dir/meta-data"; then
        rm -rf "$seed_dir"
        echo "[ERROR] Failed to create cloud-init image for $name."
        return 1
    fi

    rm -rf "$seed_dir"

    network_arg="network=$NETWORK,model=virtio,mac=$mac"

    local -a install_args=(
        --connect qemu:///system
        --name "$name"
        --memory "$memory"
        --vcpus "$vcpus"
        --import
        --osinfo ubuntu24.04
        --disk "path=$system_disk,format=qcow2,bus=virtio,target.dev=vda"
    )

    if [[ "$name" == compute-* ]]; then
        install_args+=(--cpu host-passthrough)
    fi

    if [[ "$data_disk_gb" -gt 0 ]]; then
        install_args+=(--disk "path=$data_disk,format=qcow2,bus=virtio,target.dev=vdb")
    fi

    install_args+=(--network "$network_arg")
    install_args+=(--disk "path=$seed_iso,device=cdrom,readonly=on")
    install_args+=(--graphics none)
    install_args+=(--console "pty,target_type=serial")
    install_args+=(--noautoconsole)

    echo "[INFO] Defining and starting $name."

    if ! virt-install "${install_args[@]}"; then
        echo "[ERROR] Creation failed for $name."
        echo "[WARNING] Any created disk files have been preserved for inspection."
        return 1
    fi

    if ! virsh -c qemu:///system autostart "$name"; then
        echo "[WARNING] VM created, but autostart could not be enabled: $name"
        return 1
    fi

    echo "[OK] $name created successfully."
}

echo "======================================"
echo " Mini Cloud Infrastructure Provisioner"
echo "======================================"

if virsh -c qemu:///system dominfo "${CONTROLLER_NAME:-controller}" >/dev/null 2>&1; then
    echo "[INFO] Existing Controller detected; leaving it unchanged."
else
    create_infrastructure_vm \
        "${CONTROLLER_NAME:-controller}" \
        "${INFRA_CONTROLLER_MEMORY_MB:-1024}" \
        "${INFRA_CONTROLLER_VCPUS:-1}" \
        "${CONTROLLER_MAC:-52:54:00:10:00:10}" \
        0
fi

create_infrastructure_vm \
    "compute-1" \
    "${INFRA_COMPUTE_MEMORY_MB:-2048}" \
    "${INFRA_COMPUTE_VCPUS:-2}" \
    "${COMPUTE_1_MAC:-52:54:00:10:00:11}" \
    "${INFRA_COMPUTE_DATA_DISK_GB:-10}"

create_infrastructure_vm \
    "compute-2" \
    "${INFRA_COMPUTE_MEMORY_MB:-2048}" \
    "${INFRA_COMPUTE_VCPUS:-2}" \
    "${COMPUTE_2_MAC:-52:54:00:10:00:12}" \
    "${INFRA_COMPUTE_DATA_DISK_GB:-10}"

echo
echo "======================================"
echo " Infrastructure VM Status"
echo "======================================"

virsh -c qemu:///system list --all

echo
echo "[OK] Infrastructure provisioning completed."
