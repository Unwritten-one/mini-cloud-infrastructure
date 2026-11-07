
#!/bin/bash

# Configure and verify the libvirt virtualization service.

set -e

echo "=================================="
echo "       Libvirt Configuration"
echo "=================================="

# Check root privileges.
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Run this script with sudo."
    exit 1
fi

# Check whether libvirt is installed.
if ! command -v virsh >/dev/null 2>&1; then
    echo "[ERROR] virsh is not installed."
    echo "Run install_kvm.sh first."
    exit 1
fi

# Enable and start libvirt.
echo "[1/3] Starting libvirt service..."

if systemctl list-unit-files | grep -q '^libvirtd.service'; then
    systemctl enable --now libvirtd
elif systemctl list-unit-files | grep -q '^virtqemud.service'; then
    systemctl enable --now virtqemud
else
    echo "[ERROR] No supported libvirt service found."
    exit 1
fi

# Check libvirt connectivity.
echo "[2/3] Checking libvirt connection..."

if virsh -c qemu:///system list --all; then
    echo "[OK] Libvirt connection successful."
else
    echo "[ERROR] Unable to connect to libvirt."
    exit 1
fi

# Display libvirt version.
echo "[3/3] Checking libvirt version..."
virsh --version

echo "=================================="
echo "Libvirt configuration completed."
echo "=================================="
