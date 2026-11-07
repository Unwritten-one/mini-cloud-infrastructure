
#!/bin/bash

# Create and configure the libvirt default storage pool.

set -e

POOL_NAME="default"
POOL_PATH="/var/lib/libvirt/images"

echo "=================================="
echo "     Libvirt Storage Setup"
echo "=================================="

# Check root privileges.
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Run this script with sudo."
    exit 1
fi

# Check whether virsh is installed.
if ! command -v virsh >/dev/null 2>&1; then
    echo "[ERROR] libvirt client is not installed."
    exit 1
fi

# Create the storage directory.
echo "[1/4] Creating storage directory..."
mkdir -p "$POOL_PATH"

# Check whether the storage pool already exists.
if virsh -c qemu:///system pool-info "$POOL_NAME" >/dev/null 2>&1; then
    echo "[INFO] Storage pool already exists."
else
    echo "[2/4] Creating storage pool..."
    virsh -c qemu:///system pool-define-as \
        "$POOL_NAME" dir --target "$POOL_PATH"
fi

# Enable and start the storage pool.
echo "[3/4] Activating storage pool..."

virsh -c qemu:///system pool-autostart "$POOL_NAME"
POOL_STATE=$(virsh -c qemu:///system pool-info "$POOL_NAME" | grep "^State:" | awk '{print $2}')

if [ "$POOL_STATE" = "running" ]; then
    echo "[INFO] Storage pool is already active."
else
    virsh -c qemu:///system pool-start "$POOL_NAME"
    echo "[OK] Storage pool started."
fi

# Display storage pool information.
echo "[4/4] Verifying storage pool..."
virsh -c qemu:///system pool-info "$POOL_NAME"

echo "=================================="
echo "Storage setup completed."
echo "=================================="
