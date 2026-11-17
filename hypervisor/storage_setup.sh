#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PROJECT_DIR/config/cloud.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] Configuration file not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Run with sudo: sudo bash hypervisor/storage_setup.sh"
    exit 1
fi

for command in virsh findmnt mountpoint df python3; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "[ERROR] Required command is missing: $command"
        exit 1
    fi
done

POOL_NAME="${LIBVIRT_POOL_NAME:-cloud-vms}"
POOL_PATH="${VM_STORAGE_PATH:-/mnt/cloud-vm-storage}"
MIN_FREE_GB="${MIN_FREE_GB:-5}"

if [[ ! "$POOL_NAME" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo "[ERROR] Invalid storage pool name."
    exit 1
fi

if [[ "$POOL_PATH" != /* || "$POOL_PATH" == "/" ]]; then
    echo "[ERROR] Storage path must be an absolute non-root path."
    exit 1
fi

if [[ ! "$MIN_FREE_GB" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] MIN_FREE_GB must be a non-negative integer."
    exit 1
fi

echo "=================================="
echo "       VM Storage Setup"
echo "=================================="

if ! virsh -c qemu:///system uri >/dev/null 2>&1; then
    echo "[ERROR] Cannot connect to system libvirt."
    echo "[INFO] Configure libvirt before storage setup."
    exit 1
fi

echo "[1/5] Checking dedicated VM data-disk mount..."

if [ ! -d "$POOL_PATH" ]; then
    echo "[ERROR] Storage directory does not exist: $POOL_PATH"
    echo "[INFO] Attach and mount the dedicated data disk before continuing."
    exit 1
fi

if ! mountpoint -q "$POOL_PATH"; then
    echo "[ERROR] $POOL_PATH is not a mount point."
    echo "[INFO] Refusing to use the Compute VM root filesystem."
    exit 1
fi

MOUNT_TARGET="$(findmnt -n -o TARGET --target "$POOL_PATH")"
MOUNT_SOURCE="$(findmnt -n -o SOURCE --target "$POOL_PATH")"
MOUNT_TYPE="$(findmnt -n -o FSTYPE --target "$POOL_PATH")"

if [ "$MOUNT_TARGET" != "$POOL_PATH" ]; then
    echo "[ERROR] Storage path is not mounted as a separate filesystem."
    exit 1
fi

if [ -z "$MOUNT_SOURCE" ] || [ -z "$MOUNT_TYPE" ]; then
    echo "[ERROR] Unable to identify the mounted storage device."
    exit 1
fi

if [ ! -w "$POOL_PATH" ]; then
    echo "[ERROR] Storage directory is not writable by root."
    exit 1
fi

echo "[OK] Storage mount detected: $MOUNT_SOURCE"
echo "[INFO] Filesystem: $MOUNT_TYPE"

echo "[2/5] Checking available storage..."

AVAILABLE_BYTES="$(df -PB1 "$POOL_PATH" | awk 'NR==2 {print $4}')"
REQUIRED_BYTES=$((MIN_FREE_GB * 1024 * 1024 * 1024))

if [[ ! "$AVAILABLE_BYTES" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] Could not determine available storage."
    exit 1
fi

if [ "$AVAILABLE_BYTES" -lt "$REQUIRED_BYTES" ]; then
    echo "[ERROR] Insufficient free storage."
    echo "[INFO] Required: ${MIN_FREE_GB} GB"
    echo "[INFO] Available: $((AVAILABLE_BYTES / 1024 / 1024 / 1024)) GB"
    exit 1
fi

TEST_FILE="$(mktemp "$POOL_PATH/.storage-test.XXXXXX")" || {
    echo "[ERROR] Storage write test failed."
    exit 1
}

rm -f "$TEST_FILE"

echo "[OK] Storage is writable and has sufficient free space."

echo "[3/5] Checking existing storage pool..."

if virsh -c qemu:///system pool-info "$POOL_NAME" >/dev/null 2>&1; then
    echo "[INFO] Storage pool already exists."

    POOL_XML="$(virsh -c qemu:///system pool-dumpxml "$POOL_NAME")"

    POOL_DETAILS="$(printf '%s' "$POOL_XML" | python3 -c '
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.stdin).getroot()
target = root.find("./target/path")
print(root.get("type", "") + "|" + (target.text.strip() if target is not None and target.text else ""))
')"

    EXISTING_TYPE="${POOL_DETAILS%%|*}"
    EXISTING_PATH="${POOL_DETAILS#*|}"

    if [ "$EXISTING_TYPE" != "dir" ] || [ "$EXISTING_PATH" != "$POOL_PATH" ]; then
        echo "[ERROR] Existing pool configuration does not match."
        echo "[INFO] Existing type: $EXISTING_TYPE"
        echo "[INFO] Existing path: $EXISTING_PATH"
        echo "[INFO] Expected path: $POOL_PATH"
        exit 1
    fi
else
    echo "[INFO] Defining new storage pool..."

    virsh -c qemu:///system pool-define-as \
        "$POOL_NAME" dir --target "$POOL_PATH" || {
        echo "[ERROR] Failed to define storage pool."
        exit 1
    }
fi

echo "[4/5] Activating storage pool..."

virsh -c qemu:///system pool-autostart "$POOL_NAME" || {
    echo "[ERROR] Failed to enable pool autostart."
    exit 1
}

POOL_STATE="$(virsh -c qemu:///system pool-info "$POOL_NAME" |
    awk -F: '/^State:/ {gsub(/^[[:space:]]+/, "", $2); print $2}')"

if [ "$POOL_STATE" != "running" ]; then
    virsh -c qemu:///system pool-start "$POOL_NAME" || {
        echo "[ERROR] Failed to start storage pool."
        exit 1
    }
fi

echo "[5/5] Verifying storage pool..."

virsh -c qemu:///system pool-info "$POOL_NAME" || {
    echo "[ERROR] Storage pool verification failed."
    exit 1
}

echo "=================================="
echo "Storage setup completed."
echo "Pool: $POOL_NAME"
echo "Path: $POOL_PATH"
echo "Mount: $MOUNT_SOURCE"
echo "=================================="
