#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config/cloud.conf"
REGISTRY_DIR="$PROJECT_DIR/results"
REGISTRY_FILE="$REGISTRY_DIR/active_guests.csv"
TUNNEL_DIR="/tmp/mini-cloud-tunnels"

usage() {
    printf 'Usage:\n  %s VM_NAME SSH_PUBLIC_KEY\n  %s deploy SSH_PUBLIC_KEY VM_NAME [VM_NAME ...]\n  %s delete VM_NAME [VM_NAME ...]\n  %s list\n' "$0" "$0" "$0" "$0"
    exit 1
}

[[ $# -ge 1 ]] || usage
[[ -f "$CONFIG_FILE" ]] || { echo "[ERROR] Missing config: $CONFIG_FILE"; exit 1; }
source "$CONFIG_FILE"

CLOUD_USER="${CLOUD_USER:-ubuntu}"
CONTROLLER_IP="${CONTROLLER_IP:-}"
REMOTE_DIR="${REMOTE_DEPLOY_DIR:-/opt/mini-cloud}"
PRIVATE_KEY="${NODE_SSH_PRIVATE_KEY_PATH:-}"
SSH_PORT="${SSH_PORT:-22}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"

[[ -f "$PRIVATE_KEY" && -r "$PRIVATE_KEY" ]] || { echo "[ERROR] Missing key: $PRIVATE_KEY"; exit 1; }
[[ "$CONTROLLER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$REMOTE_DIR" =~ ^/[a-zA-Z0-9_./-]+$ ]] || { echo "[ERROR] Invalid Controller config."; exit 1; }

SSH_OPTS=(-i "$PRIVATE_KEY" -p "$SSH_PORT" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" -o StrictHostKeyChecking=accept-new)
SCP_OPTS=(-i "$PRIVATE_KEY" -P "$SSH_PORT" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" -o StrictHostKeyChecking=accept-new)
CONTROLLER="${CLOUD_USER}@${CONTROLLER_IP}"

init_registry() {
    mkdir -p "$REGISTRY_DIR" "$TUNNEL_DIR"
    [[ -f "$REGISTRY_FILE" ]] || printf 'vm_name,node,node_ip,guest_ip,local_port,created_at\n' > "$REGISTRY_FILE"
}

allocate_port() {
    local port
    for port in $(seq 2221 2299); do
        if awk -F, -v p="$port" 'NR>1 && $5 == p { f=1 } END { exit !f }' "$REGISTRY_FILE" 2>/dev/null; then
            continue
        fi
        if command -v ss >/dev/null 2>&1 && ss -tln | awk '{print $4}' | grep -Eq "(:|\.)${port}$"; then
            continue
        fi
        printf '%s\n' "$port"
        return 0
    done
    return 1
}

stop_tunnel() {
    local vm_name="$1" local_port="${2:-}" pid_file="$TUNNEL_DIR/${vm_name}.pid"
    if [[ -f "$pid_file" ]]; then
        local pid="$(<"$pid_file")"
        [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null || true
        rm -f -- "$pid_file"
    fi
    [[ -n "$local_port" ]] && pkill -f "0.0.0.0:${local_port}:" 2>/dev/null || true
}

start_tunnel() {
    local vm_name="$1" node_ip="$2" guest_ip="$3" local_port="$4"
    stop_tunnel "$vm_name" "$local_port"
    ssh -f -N "${SSH_OPTS[@]}" -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        -L "0.0.0.0:${local_port}:${guest_ip}:22" "${CLOUD_USER}@${node_ip}"
    local pid="$(pgrep -fn "0.0.0.0:${local_port}:${guest_ip}:22" || true)"
    [[ -n "$pid" ]] && printf '%s\n' "$pid" > "$TUNNEL_DIR/${vm_name}.pid"
}

record_guest() {
    local tmp_file="$(mktemp)"
    awk -F, -v vm="$1" 'NR==1 || $1 != vm' "$REGISTRY_FILE" > "$tmp_file"
    printf '%s,%s,%s,%s,%s,%s\n' "$1" "$2" "$3" "$4" "$5" "$(date -Is)" >> "$tmp_file"
    mv "$tmp_file" "$REGISTRY_FILE"
}

remove_guest_record() {
    [[ -f "$REGISTRY_FILE" ]] || return 0
    local tmp_file="$(mktemp)"
    awk -F, -v vm="$1" 'NR==1 || $1 != vm' "$REGISTRY_FILE" > "$tmp_file"
    mv "$tmp_file" "$REGISTRY_FILE"
}

deploy_single_vm() {
    local vm_name="$1" guest_key="$2"
    local remote_key="/home/$CLOUD_USER/.ssh/guest-${vm_name}-request.pub"
    local out line node node_ip guest_ip local_port

    [[ "$vm_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo "[ERROR] Invalid VM name: $vm_name"; return 1; }
    echo "--------------------------------------"
    echo "[INFO] Requesting VM: $vm_name"
    ssh "${SSH_OPTS[@]}" "$CONTROLLER" "umask 077; test ! -e '$remote_key'"
    scp "${SCP_OPTS[@]}" "$guest_key" "$CONTROLLER:$remote_key"

    if ! out="$(ssh "${SSH_OPTS[@]}" "$CONTROLLER" "trap 'rm -f -- \"$remote_key\"' EXIT; bash '$REMOTE_DIR/controller/cloud_manager.sh' deploy '$vm_name' '$remote_key'")"; then
        echo "[ERROR] Deployment failed for $vm_name."
        return 1
    fi
    printf '%s\n' "$out"

    line="$(printf '%s\n' "$out" | awk -F'|' '/^DEPLOYED\|/ {print $0; exit}')"
    [[ -n "$line" ]] || { echo "[ERROR] Missing placement metadata for $vm_name."; return 1; }
    IFS='|' read -r _ _ node node_ip guest_ip <<< "$line"

    if [[ -z "$guest_ip" || "$guest_ip" == "UNKNOWN" ]]; then
        echo "[WARNING] $vm_name deployed on $node ($node_ip), DHCP IP not ready yet."
        record_guest "$vm_name" "$node" "$node_ip" "UNKNOWN" "-"
        return 0
    fi

    local_port="$(allocate_port)" || { echo "[ERROR] No free ports (2221-2299)."; return 1; }
    if start_tunnel "$vm_name" "$node_ip" "$guest_ip" "$local_port"; then
        record_guest "$vm_name" "$node" "$node_ip" "$guest_ip" "$local_port"
        echo "[OK] VM '$vm_name' ready on $node ($node_ip) -> Guest IP: $guest_ip"
        echo "[OK] Windows SSH: ssh -i <private-key> -p $local_port ubuntu@localhost"
    else
        echo "[WARNING] VM '$vm_name' deployed ($guest_ip), tunnel failed."
        record_guest "$vm_name" "$node" "$node_ip" "$guest_ip" "-"
    fi
}

delete_single_vm() {
    local vm_name="$1" saved_port=""
    [[ "$vm_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo "[ERROR] Invalid VM name: $vm_name"; return 1; }
    [[ -f "$REGISTRY_FILE" ]] && saved_port="$(awk -F, -v vm="$vm_name" 'NR>1 && $1 == vm {print $5; exit}' "$REGISTRY_FILE")"
    echo "--------------------------------------"
    echo "[INFO] Deleting VM: $vm_name"
    if ssh "${SSH_OPTS[@]}" "$CONTROLLER" "bash '$REMOTE_DIR/controller/cloud_manager.sh' delete '$vm_name'"; then
        stop_tunnel "$vm_name" "$saved_port"
        remove_guest_record "$vm_name"
        echo "[OK] VM '$vm_name' deleted (port ${saved_port:-none} released)."
    else
        echo "[ERROR] Failed to delete VM '$vm_name'."
        return 1
    fi
}

list_guests() {
    init_registry
    printf '\n%-16s %-12s %-16s %-16s %-10s\n' "VM_NAME" "NODE" "NODE_IP" "GUEST_IP" "WIN_PORT"
    awk -F, 'NR>1 {printf "%-16s %-12s %-16s %-16s %-10s\n", $1, $2, $3, $4, $5}' "$REGISTRY_FILE"
    printf '\n'
}

validate_key() {
    [[ -f "$1" && -r "$1" ]] && ssh-keygen -l -f "$1" >/dev/null 2>&1 || { echo "[ERROR] Invalid SSH public key: $1"; exit 1; }
}

main() {
    init_registry
    case "${1:-}" in
        deploy)
            [[ $# -ge 3 ]] || usage
            local key="$2" vm failures=0; shift 2; validate_key "$key"
            for vm in "$@"; do deploy_single_vm "$vm" "$key" || failures=$((failures + 1)); done
            (( failures == 0 ))
            ;;
        delete)
            [[ $# -ge 2 ]] || usage
            local vm failures=0; shift
            for vm in "$@"; do delete_single_vm "$vm" || failures=$((failures + 1)); done
            (( failures == 0 ))
            ;;
        list) list_guests ;;
        *)
            [[ $# -eq 2 ]] || usage
            validate_key "$2"
            deploy_single_vm "$1" "$2"
            ;;
    esac
}

main "$@"
