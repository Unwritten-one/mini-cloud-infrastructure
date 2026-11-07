
#!/bin/bash

# Install KVM and virtualization management packages.

set -e

echo "=================================="
echo "     Installing KVM Packages"
echo "=================================="

# Check root privileges.
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Run this script with sudo."
    exit 1
fi

# Update package lists.
echo "[1/4] Updating package lists..."
apt-get update

# Install KVM, QEMU, libvirt and related tools.
echo "[2/4] Installing virtualization packages..."
apt-get install -y \
    qemu-kvm \
    libvirt-daemon-system \
    libvirt-clients \
    virtinst \
    bridge-utils \
    cpu-checker

# Enable and start libvirt.
echo "[3/4] Enabling libvirt service..."
systemctl enable --now libvirtd

# Check virtualization support.
echo "[4/4] Checking KVM availability..."
if [ -e /dev/kvm ]; then
    echo "[OK] KVM device is available."
else
    echo "[WARNING] /dev/kvm is not available."
    echo "Check hardware virtualization and kernel support."
fi

echo "=================================="
echo "KVM installation process completed."
echo "=================================="
