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
    echo "[ERROR] Run with sudo: sudo bash hypervisor/kvm_setup.sh"
    exit 1
fi

if [ ! -f /etc/os-release ]; then
    echo "[ERROR] Cannot identify the operating system."
    exit 1
fi

source /etc/os-release

if [ "${ID:-}" != "ubuntu" ]; then
    echo "[ERROR] This script supports Ubuntu only."
    exit 1
fi

for command in apt-get grep modprobe systemctl virsh; do
    if ! command -v "$command" >/dev/null 2>&1; then
        if [ "$command" != "virsh" ]; then
            echo "[ERROR] Required command is missing: $command"
            exit 1
        fi
    fi
done

echo "=================================="
echo "       KVM Installation Setup"
echo "=================================="

if ! grep -Eq 'vmx|svm' /proc/cpuinfo; then
    echo "[ERROR] CPU virtualization flags are unavailable."
    echo "[INFO] Check host CPU virtualization and nested-virtualization support."
    exit 1
fi

echo "[OK] CPU virtualization flags detected."

echo "[1/5] Updating package lists..."

if ! apt-get update; then
    echo "[ERROR] Package list update failed."
    exit 1
fi

echo "[2/5] Installing virtualization packages..."

PACKAGES=(
    qemu-system-x86
    qemu-utils
    libvirt-daemon-system
    libvirt-clients
    virtinst
    bridge-utils
    cpu-checker
    cloud-image-utils
    curl
    openssh-client
)

if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${PACKAGES[@]}"; then
    echo "[ERROR] Package installation failed."
    exit 1
fi


echo "[3/5] Loading KVM kernel modules..."

if grep -q 'vmx' /proc/cpuinfo; then
    KVM_MODULE="kvm_intel"
elif grep -q 'svm' /proc/cpuinfo; then
    KVM_MODULE="kvm_amd"
else
    echo "[ERROR] Unsupported CPU virtualization type."
    exit 1
fi

if ! modprobe kvm; then
    echo "[ERROR] Unable to load the KVM kernel module."
    exit 1
fi

if ! modprobe "$KVM_MODULE"; then
    echo "[ERROR] Unable to load $KVM_MODULE."
    exit 1
fi

if [ ! -c /dev/kvm ]; then
    echo "[ERROR] /dev/kvm is unavailable."
    echo "[INFO] Nested virtualization may not be exposed by the host."
    exit 1
fi

if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    echo "[ERROR] Root cannot read and write /dev/kvm."
    exit 1
fi

NESTED_FILE="/sys/module/$KVM_MODULE/parameters/nested"

if [ -r "$NESTED_FILE" ]; then
    NESTED_VALUE="$(tr '[:upper:]' '[:lower:]' < "$NESTED_FILE")"

    if [ "$NESTED_VALUE" = "n" ] || [ "$NESTED_VALUE" = "0" ]; then
        echo "[ERROR] Nested virtualization is disabled in $KVM_MODULE."
        exit 1
    fi

    echo "[OK] Nested virtualization module setting: $NESTED_VALUE"
else
    echo "[WARNING] Nested virtualization module setting is unavailable."
    echo "[INFO] Actual nested guest support must be tested on this host."
fi

if command -v kvm-ok >/dev/null 2>&1; then
    if ! kvm-ok; then
        echo "[ERROR] KVM acceleration check failed."
        exit 1
    fi
else
    echo "[WARNING] kvm-ok is unavailable; device checks were used."
fi

echo "[OK] KVM device and acceleration checks passed."

echo "[4/5] Configuring libvirt..."

has_unit() {
    local unit_type="$1"
    local unit_name="$2"

    systemctl list-unit-files --type="$unit_type" --no-legend |
        awk -v unit="$unit_name" '$1 == unit { found=1 } END { exit !found }'
}

if has_unit service libvirtd.service; then
    if ! systemctl enable --now libvirtd.service; then
        echo "[ERROR] Failed to start libvirtd."
        systemctl status libvirtd.service --no-pager || true
        exit 1
    fi
elif has_unit socket virtqemud.socket; then
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
    exit 1
fi

echo "[5/5] Verifying libvirt..."

if ! command -v virsh >/dev/null 2>&1; then
    echo "[ERROR] virsh is unavailable after installation."
    exit 1
fi

if ! virsh -c qemu:///system list --all; then
    echo "[ERROR] Cannot connect to system libvirt."
    exit 1
fi

echo "=================================="
echo "KVM installation completed."
echo "Ubuntu: ${VERSION_ID:-unknown}"
echo "KVM module: $KVM_MODULE"
echo "Libvirt: $(virsh --version)"
echo "=================================="
