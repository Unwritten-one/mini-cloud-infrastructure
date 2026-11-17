#!/usr/bin/env bash

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
    echo "[ERROR] Run with sudo: sudo bash hypervisor/libvirt_setup.sh"
    exit 1
fi

for command in virsh systemctl grep awk; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "[ERROR] Required command is missing: $command"
        exit 1
    fi
done

echo "=================================="
echo "       Libvirt Configuration"
echo "=================================="

has_unit() {
    local unit_type="$1"
    local unit_name="$2"

    systemctl list-unit-files --type="$unit_type" --no-legend |
        awk -v unit="$unit_name" '$1 == unit { found=1 } END { exit !found }'
}

echo "[1/4] Detecting libvirt services..."

if has_unit service libvirtd.service; then
    echo "[INFO] Using traditional libvirtd service."

    if ! systemctl enable --now libvirtd.service; then
        echo "[ERROR] Failed to start libvirtd."
        systemctl status libvirtd.service --no-pager || true
        exit 1
    fi

elif has_unit socket virtqemud.socket; then
    echo "[INFO] Using modular virtqemud service."

    if ! systemctl enable --now virtqemud.socket; then
        echo "[ERROR] Failed to start virtqemud socket."
        exit 1
    fi

    if has_unit socket virtlogd.socket; then
        if ! systemctl enable --now virtlogd.socket; then
            echo "[ERROR] Failed to start virtlogd socket."
            exit 1
        fi
    fi

    if has_unit socket virtlockd.socket; then
        if ! systemctl enable --now virtlockd.socket; then
            echo "[ERROR] Failed to start virtlockd socket."
            exit 1
        fi
    fi

else
    echo "[ERROR] No supported libvirt service or socket found."
    echo "[INFO] Check the libvirt package installation."
    exit 1
fi

echo "[2/4] Checking KVM device..."

if [ ! -c /dev/kvm ]; then
    echo "[ERROR] /dev/kvm is unavailable."
    exit 1
fi

if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    echo "[ERROR] Root cannot read and write /dev/kvm."
    exit 1
fi

echo "[OK] KVM device is accessible."

echo "[3/4] Verifying system libvirt connection..."

if ! virsh -c qemu:///system list --all; then
    echo "[ERROR] Unable to connect to qemu:///system."
    echo "[INFO] Check libvirt service status and daemon logs."
    exit 1
fi

echo "[4/4] Checking libvirt version..."

LIBVIRT_VERSION="$(virsh --version)"

if [ -z "$LIBVIRT_VERSION" ]; then
    echo "[ERROR] Could not determine libvirt version."
    exit 1
fi

echo "=================================="
echo "Libvirt configuration completed."
echo "Version: $LIBVIRT_VERSION"
echo "Connection: qemu:///system"
echo "=================================="
