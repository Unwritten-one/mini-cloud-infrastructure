#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$PROJECT_ROOT/config/cloud.conf"
source "$PROJECT_ROOT/config/nodes.conf"

MONITOR_SCRIPT="$SCRIPT_DIR/node_monitor.sh"
SCHEDULER_SCRIPT="$SCRIPT_DIR/scheduler.sh"
VM_MANAGER="$PROJECT_ROOT/hypervisor/vm_manager.sh"

METRICS_FILE="$PROJECT_ROOT/$RESULTS_DIR/resource_metrics/node_metrics.csv"
DECISIONS_FILE="$PROJECT_ROOT/$RESULTS_DIR/scheduler_results/placement_decisions.csv"
LOG_DIR_PATH="$PROJECT_ROOT/$LOG_DIR"
LOG_FILE="$LOG_DIR_PATH/cloud_manager.log"

REMOTE_VM_MANAGER="$REMOTE_DEPLOY_DIR/hypervisor/vm_manager.sh"

log() {
    local message="$1"
    mkdir -p "$LOG_DIR_PATH"
    printf '[%s] %s\n' "$(date -Is)" "$message" | tee -a "$LOG_FILE"
}

check_scripts() {
    local command="$1"
    local script

    case "$command" in
        monitor|watch)
            script="$MONITOR_SCRIPT"
            ;;
        schedule)
            script="$SCHEDULER_SCRIPT"
            ;;
        delete)
            if [[ ! -f "$CONTROLLER_SSH_KEY_PATH" || ! -r "$CONTROLLER_SSH_KEY_PATH" ]]; then
                log "Controller SSH private key is missing or unreadable."
                return 1
            fi
            if [[ -z "${REMOTE_DEPLOY_DIR:-}" || "$REMOTE_DEPLOY_DIR" != /* ]]; then
                log "REMOTE_DEPLOY_DIR must be an absolute path."
                return 1
            fi
            command -v ssh >/dev/null 2>&1 || {
                log "Required command is not installed: ssh"
                return 1
            }
            return 0
            ;;
        deploy)
            for script in "$MONITOR_SCRIPT" "$SCHEDULER_SCRIPT" "$VM_MANAGER"; do
                if [[ ! -f "$script" ]]; then
                    log "Required script not found: $script"
                    return 1
                fi
            done

            if [[ ! -f "$CONTROLLER_SSH_KEY_PATH" ||
                  ! -r "$CONTROLLER_SSH_KEY_PATH" ]]; then
                log "Controller SSH private key is missing or unreadable."
                return 1
            fi

            if [[ -z "${REMOTE_DEPLOY_DIR:-}" ||
                  "$REMOTE_DEPLOY_DIR" != /* ]]; then
                log "REMOTE_DEPLOY_DIR must be an absolute path."
                return 1
            fi

            if [[ ! "$GUEST_MEMORY_MB" =~ ^[0-9]+$ ||
                  ! "$GUEST_VCPUS" =~ ^[0-9]+$ ||
                  ! "$GUEST_DATA_DISK_GB" =~ ^[0-9]+$ ]]; then
                log "Guest VM resource configuration is invalid."
                return 1
            fi

            if (( GUEST_MEMORY_MB < 256 || GUEST_VCPUS < 1 )); then
                log "Guest memory must be at least 256 MB and vCPUs at least 1."
                return 1
            fi

            if [[ -z "${GUEST_BASE_IMAGE:-}" ||
                  "$GUEST_BASE_IMAGE" != /* ]]; then
                log "GUEST_BASE_IMAGE must be an absolute path."
                return 1
            fi

            if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] ||
               (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
                log "Invalid SSH_PORT."
                return 1
            fi

            if ! [[ "$SSH_CONNECT_TIMEOUT" =~ ^[0-9]+$ ]] ||
               (( SSH_CONNECT_TIMEOUT <= 0 )); then
                log "Invalid SSH_CONNECT_TIMEOUT."
                return 1
            fi

            for script in ssh scp python3; do
                if ! command -v "$script" >/dev/null 2>&1; then
                    log "Required command is not installed: $script"
                    return 1
                fi
            done
            return 0
            ;;
        status)
            if [[ ! -f "$METRICS_FILE" ]]; then
                log "No resource metrics available."
                return 1
            fi
            command -v python3 >/dev/null 2>&1 || {
                log "Python 3 is required."
                return 1
            }
            return 0
            ;;
        *)
            log "Unknown validation command: $command"
            return 1
            ;;
    esac

    if [[ ! -f "$script" ]]; then
        log "Required script not found: $script"
        return 1
    fi
}

ssh_options() {
    printf '%s\n' \
        -i "$CONTROLLER_SSH_KEY_PATH" \
        -p "$SSH_PORT" \
        -o IdentitiesOnly=yes \
        -o BatchMode=yes \
        -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
        -o StrictHostKeyChecking=yes
}

run_monitor() {
    log "Collecting compute node metrics."

    if ! bash "$MONITOR_SCRIPT"; then
        log "Monitoring completed with one or more node failures."
    fi
}

watch_monitor() {
    local interval="${1:-15}"

    if [[ ! "$interval" =~ ^[0-9]+$ ]] || (( interval < 2 )); then
        log "Watch interval must be an integer >= 2 seconds."
        return 1
    fi

    log "Starting continuous monitoring loop every ${interval}s (Press Ctrl+C to stop)."
    while true; do
        run_monitor
        show_status || true
        sleep "$interval"
    done
}

run_scheduler() {
    local status

    log "Starting scheduler."

    if bash "$SCHEDULER_SCRIPT"; then
        return 0
    else
        status=$?
    fi

    if (( status == 2 )); then
        log "No compute node has sufficient available capacity."
    else
        log "Scheduler failed with exit status $status."
    fi

    return "$status"
}

show_status() {
    if [[ ! -f "$METRICS_FILE" ]]; then
        log "No resource metrics available."
        return 1
    fi

    printf '\nLatest compute node metrics:\n'

    python3 - "$METRICS_FILE" <<'PY'
import csv
import sys

latest = {}

with open(sys.argv[1], newline="", encoding="utf-8") as file:
    for row in csv.DictReader(file):
        node = row.get("node", "")
        if node:
            latest[node] = row

print(f"{'NODE':<15} {'STATUS':<13} {'CPU':<12} {'RAM':<12}")

for node, row in sorted(latest.items()):
    cpu = row.get("cpu_percent") or "-"
    memory = row.get("memory_percent") or "-"
    print(f"{node:<15} {row.get('status', '-'):<13} {cpu:<12} {memory:<12}")
PY
}

get_current_decision() {
    python3 - "$DECISIONS_FILE" "${COMPUTE_NODES[@]}" <<'PY'
import csv
import sys

allowed = {}

for entry in sys.argv[2:]:
    parts = entry.split("|")
    if len(parts) != 2:
        sys.exit(1)
    allowed[parts[0]] = parts[1]

try:
    with open(sys.argv[1], newline="", encoding="utf-8") as file:
        rows = list(csv.DictReader(file))

    if not rows:
        sys.exit(1)

    row = rows[-1]

    if row.get("status") != "SELECTED":
        sys.exit(1)

    node = row.get("node", "")
    ip = row.get("ip", "")

    if node not in allowed or allowed[node] != ip:
        sys.exit(1)

    print(
        f"{node}|{ip}|{row['cpu_percent']}|"
        f"{row['memory_percent']}|{row['score']}"
    )

except (OSError, csv.Error, KeyError, ValueError):
    sys.exit(1)
PY
}

generate_remote_config() {
    local destination="$1"

    {
        printf 'CLOUD_NAME=%q\n' "$CLOUD_NAME"
        printf 'CLOUD_USER=%q\n' "$CLOUD_USER"
        printf 'LIBVIRT_POOL_NAME=%q\n' "$LIBVIRT_POOL_NAME"
        printf 'VM_STORAGE_PATH=%q\n' "$VM_STORAGE_PATH"
        printf 'MGMT_NETWORK_NAME=%q\n' "$MGMT_NETWORK_NAME"
        printf 'GUEST_NETWORK_NAME=%q\n' "$GUEST_NETWORK_NAME"
        printf 'CONTROLLER_MAC=%q\n' "$CONTROLLER_MAC"
        printf 'COMPUTE_1_MAC=%q\n' "$COMPUTE_1_MAC"
        printf 'COMPUTE_2_MAC=%q\n' "$COMPUTE_2_MAC"
    } > "$destination"
}

deploy_remote() (
    local node_ip="$1"
    local vm_name="$2"
    local guest_key_path="$3"
    local ip_out_file="$4"
    local temp_dir remote_config_file remote_deploy_script remote_stage remote_output
    local guest_ip="UNKNOWN"
    local ssh_args=() scp_args=() option status=0
    local quoted_stage quoted_deploy_dir quoted_vm_name quoted_base_image
    local quoted_memory quoted_vcpus quoted_data_disk quoted_vm_manager

    temp_dir="$(mktemp -d)" || return 1
    trap 'rm -rf -- "$temp_dir"' EXIT
    remote_config_file="$temp_dir/cloud.conf"
    remote_deploy_script="$temp_dir/deploy.sh"

    generate_remote_config "$remote_config_file"

    while IFS= read -r option; do
        ssh_args+=("$option")
    done < <(ssh_options)

    scp_args=(
        -P "$SSH_PORT"
        -i "$CONTROLLER_SSH_KEY_PATH"
        -o IdentitiesOnly=yes
        -o BatchMode=yes
        -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
        -o StrictHostKeyChecking=yes
    )

    log "Preparing deployment files for $node_ip."

    if ! remote_stage="$(
        ssh "${ssh_args[@]}" "$CLOUD_USER@$node_ip" bash -s <<'REMOTE'
set -Eeuo pipefail
stage="$(mktemp -d /tmp/mini-cloud-deploy.XXXXXX)"
chmod 700 "$stage"
printf '%s\n' "$stage"
REMOTE
    )"; then
        log "Could not create remote staging directory."
        return 1
    fi

    if [[ ! "$remote_stage" =~ ^/tmp/mini-cloud-deploy\.[A-Za-z0-9]+$ ]]; then
        log "Remote staging directory path is invalid."
        return 1
    fi

    printf -v quoted_stage '%q' "$remote_stage"
    printf -v quoted_deploy_dir '%q' "$REMOTE_DEPLOY_DIR"
    printf -v quoted_vm_name '%q' "$vm_name"
    printf -v quoted_base_image '%q' "$GUEST_BASE_IMAGE"
    printf -v quoted_memory '%q' "$GUEST_MEMORY_MB"
    printf -v quoted_vcpus '%q' "$GUEST_VCPUS"
    printf -v quoted_data_disk '%q' "$GUEST_DATA_DISK_GB"
    printf -v quoted_vm_manager '%q' "$REMOTE_VM_MANAGER"

    cat > "$remote_deploy_script" <<EOF
set -Eeuo pipefail

remote_stage=$quoted_stage
deploy_dir=$quoted_deploy_dir
vm_manager=$quoted_vm_manager
guest_key="\$remote_stage/guest-key.pub"

cleanup() {
    sudo rm -rf -- "\$remote_stage"
}
trap cleanup EXIT

sudo install -d -m 0755 "\$deploy_dir/hypervisor" "\$deploy_dir/config"
sudo install -m 0755 "\$remote_stage/vm_manager.sh" "\$vm_manager"
sudo install -m 0644 "\$remote_stage/cloud.conf" "\$deploy_dir/config/cloud.conf"

sudo bash "\$vm_manager" create \
    $quoted_vm_name \
    $quoted_base_image \
    $quoted_memory \
    $quoted_vcpus \
    $quoted_data_disk \
    "\$guest_key"

guest_ip=""
for _ in \$(seq 1 30); do
    guest_ip="\$(sudo virsh -c qemu:///system domifaddr $quoted_vm_name 2>/dev/null | awk '/ipv4/ {split(\$4, a, "/"); print a[1]; exit}')"
    if [[ -n "\$guest_ip" ]]; then
        break
    fi
    sleep 2
done
printf 'GUEST_IP=%s\n' "\${guest_ip:-UNKNOWN}"
EOF

    if ! scp "${scp_args[@]}" \
        "$VM_MANAGER" \
        "$remote_config_file" \
        "$remote_deploy_script" \
        "$CLOUD_USER@$node_ip:$remote_stage/" ||
       ! scp "${scp_args[@]}" \
        "$guest_key_path" \
        "$CLOUD_USER@$node_ip:$remote_stage/guest-key.pub"; then
        log "File transfer to $node_ip failed."
        status=1
    else
        log "Files transferred. Creating guest VM $vm_name on $node_ip."

        if remote_output="$(
            ssh "${ssh_args[@]}" "$CLOUD_USER@$node_ip" \
                bash -s -- "$remote_stage/deploy.sh" <<'REMOTE'
set -Eeuo pipefail
sudo bash "$1"
REMOTE
        )"; then
            printf '%s\n' "$remote_output"
            guest_ip="$(printf '%s\n' "$remote_output" | awk -F= '/^GUEST_IP=/ {print $2; exit}')"
            printf '%s\n' "${guest_ip:-UNKNOWN}" > "$ip_out_file"
            status=0
        else
            status=$?
        fi
    fi

    if (( status != 0 )); then
        printf 'rm -rf -- %q\n' "$remote_stage" |
            ssh "${ssh_args[@]}" "$CLOUD_USER@$node_ip" bash -s || true
        log "Remote deployment failed with exit status $status."
        return "$status"
    fi

    log "Guest VM $vm_name created successfully on $node_ip (Guest IP: ${guest_ip:-UNKNOWN})."
    return 0
)

check_vm_name_available() {
    local vm_name="$1"
    local entry
    local node
    local node_ip
    local status
    local option
    local ssh_args=()

    while IFS= read -r option; do
        ssh_args+=("$option")
    done < <(ssh_options)

    for entry in "${COMPUTE_NODES[@]}"; do
        IFS='|' read -r node node_ip <<< "$entry"

        if ssh "${ssh_args[@]}" "$CLOUD_USER@$node_ip" \
            bash -s -- "$vm_name" <<'REMOTE'
set -u

if ! virsh -c qemu:///system list --all >/dev/null 2>&1; then
    exit 20
fi

if virsh -c qemu:///system dominfo "$1" >/dev/null 2>&1; then
    exit 0
else
    exit 10
fi
REMOTE
        then
            log "A VM named $vm_name already exists on $node ($node_ip)."
            return 1
        else
            status=$?
        fi

        if (( status != 10 )); then
            log "Could not verify VM names on $node ($node_ip). Exit status: $status."
            return 1
        fi
    done

    return 0
}

deploy_vm() {
    local vm_name="${1:-}"
    local guest_key_path="${2:-}"
    local selection
    local node
    local node_ip
    local cpu
    local memory
    local score
    local ip_out_file
    local guest_ip="UNKNOWN"

    if [[ ! "$vm_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        log "Invalid VM name. Use letters, numbers, dots, underscores or hyphens."
        return 1
    fi

    if [[ -z "$guest_key_path" || ! -f "$guest_key_path" || ! -r "$guest_key_path" ]]; then
        log "Guest SSH public key is missing or unreadable."
        return 1
    fi

    if ! check_vm_name_available "$vm_name"; then
        return 1
    fi

    run_monitor

    if run_scheduler; then
        :
    else
        return $?
    fi

    if [[ ! -f "$DECISIONS_FILE" ]]; then
        log "Scheduler decision file not found."
        return 1
    fi

    if ! selection="$(get_current_decision)"; then
        log "No valid current placement decision found."
        return 1
    fi

    IFS='|' read -r node node_ip cpu memory score <<< "$selection"

    log "Placement decision: $vm_name -> $node ($node_ip)"
    log "Load: CPU=${cpu}% RAM=${memory}% Score=${score}"

    ip_out_file="$(mktemp)"
    if ! deploy_remote "$node_ip" "$vm_name" "$guest_key_path" "$ip_out_file"; then
        rm -f -- "$ip_out_file"
        return 1
    fi

    guest_ip="$(<"$ip_out_file")"
    rm -f -- "$ip_out_file"

    printf 'DEPLOYED|%s|%s|%s|%s\n' "$vm_name" "$node" "$node_ip" "${guest_ip:-UNKNOWN}"
}

delete_vm() {
    local vm_name="${1:-}"
    local entry
    local node
    local node_ip
    local found=0
    local option
    local ssh_args=()

    if [[ ! "$vm_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        log "Invalid VM name."
        return 1
    fi

    while IFS= read -r option; do
        ssh_args+=("$option")
    done < <(ssh_options)

    for entry in "${COMPUTE_NODES[@]}"; do
        IFS='|' read -r node node_ip <<< "$entry"

        if ssh "${ssh_args[@]}" "$CLOUD_USER@$node_ip" \
            "virsh -c qemu:///system dominfo '$vm_name' >/dev/null 2>&1"; then
            found=1
            log "Found guest VM $vm_name on $node ($node_ip). Deleting..."

            if ssh "${ssh_args[@]}" "$CLOUD_USER@$node_ip" \
                bash -s -- "$vm_name" "$REMOTE_VM_MANAGER" <<'REMOTE'
set -Eeuo pipefail
vm_name="$1"
vm_manager="$2"

state="$(sudo virsh -c qemu:///system domstate "$vm_name" | tr -d '\r')"
if [[ "$state" != "shut off" ]]; then
    sudo virsh -c qemu:///system shutdown "$vm_name" >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
        state="$(sudo virsh -c qemu:///system domstate "$vm_name" | tr -d '\r')"
        [[ "$state" == "shut off" ]] && break
        sleep 1
    done
fi

state="$(sudo virsh -c qemu:///system domstate "$vm_name" | tr -d '\r')"
if [[ "$state" != "shut off" ]]; then
    sudo virsh -c qemu:///system destroy "$vm_name" >/dev/null 2>&1 || true
fi

sudo bash "$vm_manager" delete "$vm_name" --remove-disk
REMOTE
            then
                log "Guest VM $vm_name deleted from $node ($node_ip)."
                printf 'DELETED|%s|%s|%s\n' "$vm_name" "$node" "$node_ip"
                return 0
            else
                log "Failed to delete guest VM $vm_name on $node ($node_ip)."
                return 1
            fi
        fi
    done

    if (( found == 0 )); then
        log "Guest VM $vm_name was not found on any compute node."
        return 1
    fi
}

main() {
    local command="${1:-}"

    if ! check_scripts "$command"; then
        exit 1
    fi

    case "$command" in
        monitor)
            run_monitor
            ;;
        watch)
            watch_monitor "${2:-15}"
            ;;
        schedule)
            run_scheduler
            ;;
        status)
            show_status
            ;;
        deploy)
            deploy_vm "${2:-}" "${3:-}"
            ;;
        delete)
            delete_vm "${2:-}"
            ;;
        *)
            printf 'Usage: %s {monitor|watch [SEC]|schedule|status|deploy VM_NAME SSH_PUBLIC_KEY|delete VM_NAME}\n' "$0"
            exit 1
            ;;
    esac
}

main "$@"
