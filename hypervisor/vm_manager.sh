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

POOL_NAME="${LIBVIRT_POOL_NAME:-cloud-vms}"
POOL_PATH="${VM_STORAGE_PATH:-/mnt/cloud-vm-storage}"
MGMT_NETWORK="${MGMT_NETWORK_NAME:-cloud-management}"
GUEST_NETWORK="${GUEST_NETWORK_NAME:-cloud-guests}"

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Run with sudo."
    exit 1
fi

for command in virsh python3 realpath; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "[ERROR] Required command is missing: $command"
        exit 1
    fi
done

if ! virsh -c qemu:///system uri >/dev/null 2>&1; then
    echo "[ERROR] Cannot connect to system libvirt."
    exit 1
fi

validate_name() {
    if [[ ! "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,39}$ ]]; then
        echo "[ERROR] Invalid VM name: $1"
        exit 1
    fi
}

check_vm() {
    if ! virsh -c qemu:///system dominfo "$1" >/dev/null 2>&1; then
        echo "[ERROR] VM does not exist: $1"
        exit 1
    fi
}

get_vm_disk_paths() {
    virsh -c qemu:///system dumpxml "$1" |
        python3 -c '
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.stdin).getroot()

for disk in root.findall("./devices/disk"):
    if disk.get("device") != "disk":
        continue

    source = disk.find("source")

    if source is not None and source.get("file"):
        print(source.get("file"))
'
}

select_vm_network() {
    local name="$1"

    VM_NETWORK="$GUEST_NETWORK"
    VM_MAC=""

    case "$name" in
        controller)
            VM_NETWORK="$MGMT_NETWORK"
            VM_MAC="${CONTROLLER_MAC:-52:54:00:10:00:10}"
            ;;
        compute-1)
            VM_NETWORK="$MGMT_NETWORK"
            VM_MAC="${COMPUTE_1_MAC:-52:54:00:10:00:11}"
            ;;
        compute-2)
            VM_NETWORK="$MGMT_NETWORK"
            VM_MAC="${COMPUTE_2_MAC:-52:54:00:10:00:12}"
            ;;
    esac

    if [ -n "$VM_MAC" ] &&
        [[ ! "$VM_MAC" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]; then
        echo "[ERROR] Invalid MAC address for $name: $VM_MAC"
        exit 1
    fi
}

create_vm() {
    if [ "$#" -ne 6 ]; then
        echo "Usage: vm_manager.sh create NAME BASE_IMAGE MEMORY_MB VCPUS DATA_DISK_GB SSH_PUBLIC_KEY"
        exit 1
    fi

    local name="$1"
    local base_image="$2"
    local memory="${3:-1024}"
    local vcpus="${4:-1}"
    local data_disk_gb="${5:-0}"
    local system_disk_path
    local data_disk_path
    local base_format
    local network_state
    local pool_state
    local created_system=0
    local created_data=0
    local domain_defined=0
    local network_arg
    local seed_iso
    local seed_dir
    local public_key
    local guest_key_path="$6"
    local created_seed=0

    validate_name "$name"
    select_vm_network "$name"

    if [[ ! "$data_disk_gb" =~ ^[0-9]+$ ]] || [ "$data_disk_gb" -gt 1000 ]; then
        echo "[ERROR] Data disk size must be between 0 and 1000 GB."
        exit 1
    fi

    case "$name" in
        controller)
            if [ "$data_disk_gb" -ne 0 ]; then
                echo "[ERROR] Controller must use only its system disk."
                exit 1
            fi
            ;;
        compute-1|compute-2)
            if [ "$#" -lt 5 ]; then
                data_disk_gb=10
            fi

            if [ "$data_disk_gb" -lt 1 ]; then
                echo "[ERROR] Compute VMs require a separate data disk."
                exit 1
            fi
            ;;
    esac

    if [ ! -f "$base_image" ] || [ ! -r "$base_image" ]; then
        echo "[ERROR] Base image does not exist or is unreadable."
        exit 1
    fi

    if [[ -z "$guest_key_path" ||
        ! -f "$guest_key_path" ||
        ! -r "$guest_key_path" ]]; then
        echo "[ERROR] SSH public key file is missing or unreadable."
        exit 1
    fi

    public_key="$(<"$guest_key_path")"

    if [[ ! "$public_key" =~ ^ssh-ed25519[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]]; then
        echo "[ERROR] Invalid Ed25519 public key."
        exit 1
    fi

    if [[ ! "$memory" =~ ^[0-9]+$ ]] || [ "$memory" -lt 256 ] || [ "$memory" -gt 2048 ]; then
        echo "[ERROR] Memory must be between 256 and 2048 MB."
        exit 1
    fi

    if [[ ! "$vcpus" =~ ^[0-9]+$ ]] || [ "$vcpus" -lt 1 ] || [ "$vcpus" -gt 2 ]; then
        echo "[ERROR] VCPU count must be between 1 and 2."
        exit 1
    fi

    for command in virt-install qemu-img cloud-localds; do
        if ! command -v "$command" >/dev/null 2>&1; then
            echo "[ERROR] Required command is missing: $command"
            exit 1
        fi
    done

    if virsh -c qemu:///system dominfo "$name" >/dev/null 2>&1; then
        echo "[ERROR] A VM with this name already exists."
        exit 1
    fi

    if [ ! -d "$POOL_PATH" ] || [ ! -w "$POOL_PATH" ]; then
        echo "[ERROR] VM storage directory is missing or not writable."
        exit 1
    fi

    if ! virsh -c qemu:///system pool-info "$POOL_NAME" >/dev/null 2>&1; then
        echo "[ERROR] Storage pool does not exist: $POOL_NAME"
        exit 1
    fi

    pool_state="$(virsh -c qemu:///system pool-info "$POOL_NAME" |
        awk -F: '/^State:/ {gsub(/^[[:space:]]+/, "", $2); print $2}')"

    if [ "$pool_state" != "running" ]; then
        echo "[ERROR] Storage pool is not active."
        exit 1
    fi

    if ! virsh -c qemu:///system net-info "$VM_NETWORK" >/dev/null 2>&1; then
        echo "[ERROR] Required network does not exist: $VM_NETWORK"
        exit 1
    fi

    network_state="$(virsh -c qemu:///system net-info "$VM_NETWORK" |
        awk -F: '/^Active:/ {gsub(/[[:space:]]/, "", $2); print $2}')"

    if [ "$network_state" != "yes" ]; then
        echo "[ERROR] Required network is not active: $VM_NETWORK"
        exit 1
    fi

    if ! qemu-img info --output=json "$base_image" >/dev/null 2>&1; then
        echo "[ERROR] Base image is not a valid QEMU disk image."
        exit 1
    fi

    base_format="$(qemu-img info --output=json "$base_image" |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["format"])')"

    system_disk_path="$POOL_PATH/$name-system.qcow2"
    data_disk_path="$POOL_PATH/$name-data.qcow2"

    if [ -e "$system_disk_path" ]; then
        echo "[ERROR] System disk already exists: $system_disk_path"
        exit 1
    fi

    if [ "$data_disk_gb" -gt 0 ] && [ -e "$data_disk_path" ]; then
        echo "[ERROR] Data disk already exists: $data_disk_path"
        exit 1
    fi

    echo "[INFO] Creating system disk..."

    if ! qemu-img create -f qcow2 -F "$base_format" \
        -b "$base_image" "$system_disk_path"; then
        echo "[ERROR] Failed to create system disk."
        exit 1
    fi
    created_system=1

    if [ "$data_disk_gb" -gt 0 ]; then
        echo "[INFO] Creating ${data_disk_gb} GB data disk..."

        if ! qemu-img create -f qcow2 "$data_disk_path" "${data_disk_gb}G"; then
            echo "[ERROR] Failed to create data disk."
            rm -f -- "$system_disk_path"
            exit 1
        fi
        created_data=1
    fi

    
    seed_iso="$POOL_PATH/$name-cloud-init.iso"

    if [[ -e "$seed_iso" ]]; then
        echo "[ERROR] Cloud-init ISO already exists: $seed_iso"
        rm -f -- "$system_disk_path"
        if [[ "$created_data" -eq 1 ]]; then
            rm -f -- "$data_disk_path"
        fi
        exit 1
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
  - $public_key
EOF

    if [[ "$name" == compute-* ]]; then
        cat >> "$seed_dir/user-data" <<'EOF'
disk_setup:
  /dev/vdb:
    table_type: gpt
    layout: true
    overwrite: false
fs_setup:
  - label: cloud-data
    filesystem: ext4
    device: /dev/vdb
    partition: 1
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
        echo "[ERROR] Failed to create cloud-init ISO."
        rm -rf -- "$seed_dir"
        rm -f -- "$seed_iso"
        rm -f -- "$system_disk_path"
        if [[ "$created_data" -eq 1 ]]; then
            rm -f -- "$data_disk_path"
        fi
        exit 1
    fi

    rm -rf -- "$seed_dir"
    created_seed=1

    echo "[INFO] Cloud-init ISO created: $seed_iso"


    echo "[INFO] Defining and starting VM..."

    local -a install_args=(
        --connect qemu:///system
        --name "$name"
        --memory "$memory"
        --vcpus "$vcpus"
        --import
        --osinfo ubuntu24.04
        --disk "path=$system_disk_path,format=qcow2,bus=virtio,target.dev=vda"
    )

    if [ "$data_disk_gb" -gt 0 ]; then
        install_args+=(--disk "path=$data_disk_path,format=qcow2,bus=virtio,target.dev=vdb")
    fi

    network_arg="network=$VM_NETWORK,model=virtio"

    if [ -n "$VM_MAC" ]; then
        network_arg="$network_arg,mac=$VM_MAC"
    fi

    install_args+=(--network "$network_arg")
    install_args+=(--disk "path=$seed_iso,device=cdrom,readonly=on")
    install_args+=(--graphics none)
    install_args+=(--console "pty,target_type=serial")
    install_args+=(--noautoconsole)

    if ! virt-install "${install_args[@]}"; then
        echo "[ERROR] VM creation failed."

        if virsh -c qemu:///system dominfo "$name" >/dev/null 2>&1; then
            domain_defined=1
            virsh -c qemu:///system destroy "$name" >/dev/null 2>&1 || true

            if ! virsh -c qemu:///system undefine "$name" >/dev/null 2>&1; then
                echo "[WARNING] VM definition could not be removed."
                echo "[WARNING] Disk files have been preserved."
                rm -rf -- "$seed_dir"
                exit 1
            fi
        fi

        if [ "$domain_defined" -eq 0 ] ||
            ! virsh -c qemu:///system dominfo "$name" >/dev/null 2>&1; then
            [ "$created_system" -eq 0 ] || rm -f -- "$system_disk_path"
            [ "$created_data" -eq 0 ] || rm -f -- "$data_disk_path"
            [ "$created_seed" -eq 0 ] || rm -f -- "$seed_iso"
        fi

        exit 1
    fi

    echo "[OK] VM created successfully."
    echo "Name: $name"
    echo "Memory: ${memory} MB"
    echo "VCPUs: $vcpus"
    echo "System disk: $system_disk_path"

    if [ "$data_disk_gb" -gt 0 ]; then
        echo "Data disk: $data_disk_path (${data_disk_gb} GB virtual)"
    else
        echo "Data disk: None"
    fi

    echo "Network: $VM_NETWORK"

    if [ -n "$VM_MAC" ]; then
        echo "MAC: $VM_MAC"
        echo "[INFO] Expected DHCP address will be assigned by the management network."
    fi

}

list_vms() {
    virsh -c qemu:///system list --all
}

show_status() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: vm_manager.sh status NAME"
        exit 1
    fi

    validate_name "$1"
    check_vm "$1"
    virsh -c qemu:///system dominfo "$1"
    virsh -c qemu:///system domstate "$1"
    echo "Attached disk files:"
    get_vm_disk_paths "$1"
}

start_vm() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: vm_manager.sh start NAME"
        exit 1
    fi

    validate_name "$1"
    check_vm "$1"

    virsh -c qemu:///system start "$1"
    echo "[OK] VM start requested: $1"
}

stop_vm() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: vm_manager.sh stop NAME"
        exit 1
    fi

    validate_name "$1"
    check_vm "$1"

    virsh -c qemu:///system shutdown "$1"
    echo "[INFO] Graceful shutdown requested: $1"
}

delete_vm() {
    if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
        echo "Usage: vm_manager.sh delete NAME [--remove-disk]"
        exit 1
    fi

    local name="$1"
    local remove_disk="${2:-}"
    local state
    local disk_paths
    local disk_path
    local pool_real
    local disk_real
    local disk_base

    validate_name "$name"
    check_vm "$name"

    if [ -n "$remove_disk" ] && [ "$remove_disk" != "--remove-disk" ]; then
        echo "[ERROR] Unknown delete option: $remove_disk"
        exit 1
    fi

    state="$(virsh -c qemu:///system domstate "$name" | tr -d '\r')"

    if [ "$state" != "shut off" ]; then
        echo "[ERROR] VM must be shut off before deletion."
        echo "[INFO] Current state: $state"
        exit 1
    fi

    disk_paths="$(get_vm_disk_paths "$name")"

    if [ "$remove_disk" = "--remove-disk" ]; then
        if [ -z "$disk_paths" ]; then
            echo "[ERROR] No file-backed disks were found. Refusing disk removal."
            exit 1
        fi

        pool_real="$(realpath -e "$POOL_PATH")" || {
            echo "[ERROR] Storage pool path cannot be resolved."
            exit 1
        }

        while IFS= read -r disk_path; do
            [ -n "$disk_path" ] || continue

            if [ ! -f "$disk_path" ]; then
                echo "[ERROR] Attached disk file is missing: $disk_path"
                exit 1
            fi

            disk_real="$(realpath -e "$disk_path")" || exit 1
            disk_base="$(basename "$disk_real")"

            if [ "$(dirname "$disk_real")" != "$pool_real" ]; then
                echo "[ERROR] Disk is outside the configured storage pool."
                echo "[ERROR] Refusing to remove: $disk_real"
                exit 1
            fi

            if [ "$disk_base" != "$name-system.qcow2" ] &&
                [ "$disk_base" != "$name-data.qcow2" ]; then
                echo "[ERROR] Disk name does not match this VM's managed disk names."
                echo "[ERROR] Refusing to remove: $disk_real"
                exit 1
            fi
        done <<< "$disk_paths"
    fi

    if ! virsh -c qemu:///system undefine "$name"; then
        echo "[ERROR] Failed to undefine VM."
        exit 1
    fi

    echo "[OK] VM definition removed: $name"
    seed_iso="$POOL_PATH/$name-cloud-init.iso"

    if [[ -f "$seed_iso" ]]; then
        pool_real="$(realpath -e "$POOL_PATH")"
        seed_real="$(realpath -e "$seed_iso")"

        if [[ "$(dirname "$seed_real")" == "$pool_real" &&
            "$(basename "$seed_real")" == "$name-cloud-init.iso" ]]; then
            rm -f -- "$seed_real"
            echo "[OK] Cloud-init ISO removed: $seed_real"
        else
            echo "[WARNING] Cloud-init ISO is outside the expected storage pool."
            echo "[WARNING] Preserving: $seed_iso"
        fi
    fi

    if [ "$remove_disk" = "--remove-disk" ]; then
        while IFS= read -r disk_path; do
            [ -n "$disk_path" ] || continue
            rm -f -- "$disk_path"
            echo "[OK] VM disk removed: $disk_path"
        done <<< "$disk_paths"
    else
        echo "[INFO] VM disks preserved:"
        printf '%s\n' "$disk_paths"
    fi
}

case "${1:-}" in
    create)
        shift
        create_vm "$@"
        ;;
    list)
        list_vms
        ;;
    status)
        shift
        show_status "$@"
        ;;
    start)
        shift
        start_vm "$@"
        ;;
    stop)
        shift
        stop_vm "$@"
        ;;
    delete)
        shift
        delete_vm "$@"
        ;;
    *)
        echo "Usage:"
        echo "  vm_manager.sh create NAME BASE_IMAGE MEMORY_MB VCPUS DATA_DISK_GB SSH_PUBLIC_KEY"
        echo "  vm_manager.sh list"
        echo "  vm_manager.sh status NAME"
        echo "  vm_manager.sh start NAME"
        echo "  vm_manager.sh stop NAME"
        echo "  vm_manager.sh delete NAME [--remove-disk]"
        exit 1
        ;;
esac
