#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$PROJECT_ROOT/config/cloud.conf"
source "$PROJECT_ROOT/config/nodes.conf"

METRICS_DIR="$PROJECT_ROOT/$RESULTS_DIR/resource_metrics"
LOG_DIR_PATH="$PROJECT_ROOT/$LOG_DIR"
METRICS_FILE="$METRICS_DIR/node_metrics.csv"
LOG_FILE="$LOG_DIR_PATH/node_monitor.log"

[[ -n "${CLOUD_USER:-}" ]] || {
    printf '[ERROR] CLOUD_USER is not configured.\n' >&2
    exit 1
}

[[ -n "${CONTROLLER_SSH_KEY_PATH:-}" ]] || {
    printf '[ERROR] CONTROLLER_SSH_KEY_PATH is not configured.\n' >&2
    exit 1
}

[[ -f "$CONTROLLER_SSH_KEY_PATH" && -r "$CONTROLLER_SSH_KEY_PATH" ]] || {
    printf '[ERROR] Controller SSH key not found or unreadable: %s\n' "$CONTROLLER_SSH_KEY_PATH" >&2
    exit 1
}

if [[ ! "${SSH_PORT:-}" =~ ^[0-9]+$ ]]; then
    printf '[ERROR] Invalid SSH_PORT.\n' >&2
    exit 1
fi

if (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
    printf '[ERROR] Invalid SSH_PORT.\n' >&2
    exit 1
fi

if [[ ! "${SSH_CONNECT_TIMEOUT:-}" =~ ^[0-9]+$ ]]; then
    printf '[ERROR] Invalid SSH_CONNECT_TIMEOUT.\n' >&2
    exit 1
fi

if (( SSH_CONNECT_TIMEOUT <= 0 )); then
    printf '[ERROR] Invalid SSH_CONNECT_TIMEOUT.\n' >&2
    exit 1
fi

command -v ssh >/dev/null 2>&1 || {
    printf '[ERROR] SSH client is not installed.\n' >&2
    exit 1
}

command -v python3 >/dev/null 2>&1 || {
    printf '[ERROR] Python 3 is not installed.\n' >&2
    exit 1
}

SSH_OPTIONS=(
    -p "$SSH_PORT"
    -i "$CONTROLLER_SSH_KEY_PATH"
    -o IdentitiesOnly=yes
    -o BatchMode=yes
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
    -o StrictHostKeyChecking=yes
)

mkdir -p "$METRICS_DIR" "$LOG_DIR_PATH"

if [[ ! -f "$METRICS_FILE" ]]; then
    printf 'timestamp,node,ip,status,cpu_percent,memory_percent,memory_total_mb,memory_available_mb\n' > "$METRICS_FILE"
fi

log() {
    local message="$1"
    printf '[%s] %s\n' "$(date -Is)" "$message" | tee -a "$LOG_FILE"
}

write_failure() {
    local timestamp="$1"
    local node_name="$2"
    local node_ip="$3"
    local status="$4"

    printf '%s,%s,%s,%s,,,,\n' \
        "$timestamp" "$node_name" "$node_ip" "$status" >> "$METRICS_FILE"
}

valid_percent() {
    awk -v value="$1" '
        BEGIN {
            if (value !~ /^[0-9]+([.][0-9]+)?$/) exit 1
            if (value < 0 || value > 100) exit 1
        }
    '
}

collect_metrics() {
    local node_name="$1"
    local node_ip="$2"
    local output
    local cpu
    local memory
    local total
    local available
    local extra
    local timestamp

    timestamp="$(date -Is)"

    if ! output="$(
        ssh "${SSH_OPTIONS[@]}" "$CLOUD_USER@$node_ip" 'bash -s' <<'REMOTE'
set -Eeuo pipefail

read_cpu() {
    awk '/^cpu / {
        total=0
        for (i=2; i<=NF; i++) total += $i
        idle=$5+$6
        print total, idle
    }' /proc/stat
}

read -r total_before idle_before < <(read_cpu)
sleep 1
read -r total_after idle_after < <(read_cpu)

total_diff=$((total_after - total_before))
idle_diff=$((idle_after - idle_before))

if (( total_diff <= 0 )); then
    exit 1
fi

cpu=$(awk -v total="$total_diff" -v idle="$idle_diff" \
    'BEGIN { printf "%.2f", (total-idle)*100/total }')

read -r total_kb available_kb < <(
    awk '
        /^MemTotal:/ { total=$2 }
        /^MemAvailable:/ { available=$2 }
        END { print total, available }
    ' /proc/meminfo
)

if [[ ! "$total_kb" =~ ^[0-9]+$ ||
      ! "$available_kb" =~ ^[0-9]+$ ]] ||
   (( total_kb <= 0 || available_kb > total_kb )); then
    exit 1
fi

memory=$(awk -v total="$total_kb" -v available="$available_kb" \
    'BEGIN { printf "%.2f", (total-available)*100/total }')

total_mb=$((total_kb / 1024))
available_mb=$((available_kb / 1024))

printf '%s|%s|%s|%s\n' "$cpu" "$memory" "$total_mb" "$available_mb"
REMOTE
    )"; then
        log "UNREACHABLE: $node_name ($node_ip)"
        write_failure "$timestamp" "$node_name" "$node_ip" "UNREACHABLE"
        return 1
    fi

    IFS='|' read -r cpu memory total available extra <<< "$output"

    if [[ -n "${extra:-}" ||
          ! "$total" =~ ^[0-9]+$ ||
          ! "$available" =~ ^[0-9]+$ ]] ||
       ! valid_percent "$cpu" ||
       ! valid_percent "$memory" ||
       (( total <= 0 || available > total )); then
        log "INVALID METRICS: $node_name ($node_ip)"
        write_failure "$timestamp" "$node_name" "$node_ip" "INVALID"
        return 1
    fi

    printf '%s,%s,%s,ONLINE,%s,%s,%s,%s\n' \
        "$timestamp" "$node_name" "$node_ip" \
        "$cpu" "$memory" "$total" "$available" >> "$METRICS_FILE"

    log "ONLINE: $node_name CPU=${cpu}% RAM=${memory}%"

    if awk -v cpu="$cpu" -v memory="$memory" \
        -v cpu_limit="$NODE_CPU_LIMIT" \
        -v memory_limit="$NODE_MEMORY_LIMIT" \
        'BEGIN { exit !(cpu >= cpu_limit || memory >= memory_limit) }'; then
        log "RESOURCE ALERT: $node_name CPU=${cpu}% (limit ${NODE_CPU_LIMIT}%) RAM=${memory}% (limit ${NODE_MEMORY_LIMIT}%)"
    fi

    return 0
}

main() {
    local node
    local node_name
    local node_ip
    local extra
    local failures=0
    local -A seen_names=()
    local -A seen_ips=()

    log "Starting compute node monitoring."

    for node in "${COMPUTE_NODES[@]}"; do
        IFS='|' read -r node_name node_ip extra <<< "$node"

        if [[ ! "$node_name" =~ ^compute-[0-9]+$ ||
              -n "${extra:-}" ]] ||
           ! python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$node_ip" 2>/dev/null; then
            log "INVALID NODE CONFIGURATION: $node"
            exit 1
        fi

        if [[ -n "${seen_names[$node_name]+x}" ||
              -n "${seen_ips[$node_ip]+x}" ]]; then
            log "DUPLICATE NODE CONFIGURATION: $node"
            exit 1
        fi

        seen_names["$node_name"]=1
        seen_ips["$node_ip"]=1
    done

    for node in "${COMPUTE_NODES[@]}"; do
        IFS='|' read -r node_name node_ip <<< "$node"

        if ! collect_metrics "$node_name" "$node_ip"; then
            failures=$((failures + 1))
        fi
    done

    log "Monitoring completed. Failed nodes: $failures"

    (( failures == 0 ))
}

main "$@"
