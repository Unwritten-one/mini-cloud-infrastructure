#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$PROJECT_ROOT/config/cloud.conf"
source "$PROJECT_ROOT/config/nodes.conf"

METRICS_FILE="$PROJECT_ROOT/$RESULTS_DIR/resource_metrics/node_metrics.csv"
SCHEDULER_DIR="$PROJECT_ROOT/$RESULTS_DIR/scheduler_results"
LOG_DIR_PATH="$PROJECT_ROOT/$LOG_DIR"
DECISIONS_FILE="$SCHEDULER_DIR/placement_decisions.csv"
LOG_FILE="$LOG_DIR_PATH/scheduler.log"

METRIC_MAX_AGE_SECONDS=300

log() {
    local message="$1"
    printf '[%s] %s\n' "$(date -Is)" "$message" | tee -a "$LOG_FILE"
}

validate_config() {
    [[ -f "$METRICS_FILE" ]] || {
        log "Metrics file not found: $METRICS_FILE"
        exit 1
    }

    for value in "$NODE_CPU_LIMIT" "$NODE_MEMORY_LIMIT" \
                 "$SCHEDULER_CPU_WEIGHT" "$SCHEDULER_MEMORY_WEIGHT"; do
        [[ "$value" =~ ^[0-9]+$ ]] || {
            log "Invalid scheduler configuration value: $value"
            exit 1
        }
    done

    if (( NODE_CPU_LIMIT < 1 || NODE_MEMORY_LIMIT < 1 ||
          NODE_CPU_LIMIT > 100 || NODE_MEMORY_LIMIT > 100 )); then
        log "CPU and memory limits must be between 1 and 100."
        exit 1
    fi

    if (( SCHEDULER_CPU_WEIGHT > 100 ||
          SCHEDULER_MEMORY_WEIGHT > 100 )); then
        log "Scheduler weights must not exceed 100."
        exit 1
    fi

    if (( SCHEDULER_CPU_WEIGHT + SCHEDULER_MEMORY_WEIGHT != 100 )); then
        log "CPU and memory weights must add up to 100."
        exit 1
    fi

    if (( ${#COMPUTE_NODES[@]} == 0 )); then
        log "No compute nodes are configured."
        exit 1
    fi

    local node
    local node_name
    local node_ip
    local extra
    local -A seen_names=()
    local -A seen_ips=()

    for node in "${COMPUTE_NODES[@]}"; do
        IFS='|' read -r node_name node_ip extra <<< "$node"

        if [[ -z "$node_name" || -z "$node_ip" || -n "${extra:-}" ]]; then
            log "Invalid compute node configuration: $node"
            exit 1
        fi

        if [[ -n "${seen_names[$node_name]+x}" ||
              -n "${seen_ips[$node_ip]+x}" ]]; then
            log "Duplicate compute node name or IP: $node"
            exit 1
        fi

        seen_names["$node_name"]=1
        seen_ips["$node_ip"]=1
    done

    command -v python3 >/dev/null 2>&1 || {
        log "Python 3 is required."
        exit 1
    }

    mkdir -p "$SCHEDULER_DIR" "$LOG_DIR_PATH"

    if [[ ! -f "$DECISIONS_FILE" ]]; then
        printf 'timestamp,status,node,ip,cpu_percent,memory_percent,score\n' \
            > "$DECISIONS_FILE"
    fi
}

select_node() {
    python3 - "$METRICS_FILE" "$NODE_CPU_LIMIT" "$NODE_MEMORY_LIMIT" \
        "$SCHEDULER_CPU_WEIGHT" "$SCHEDULER_MEMORY_WEIGHT" \
        "$METRIC_MAX_AGE_SECONDS" "${COMPUTE_NODES[@]}" <<'PY'
import csv
import sys
from datetime import datetime, timezone

metrics_file = sys.argv[1]
cpu_limit = float(sys.argv[2])
memory_limit = float(sys.argv[3])
cpu_weight = float(sys.argv[4])
memory_weight = float(sys.argv[5])
max_age = int(sys.argv[6])

allowed_nodes = {}

for entry in sys.argv[7:]:
    parts = entry.split("|")

    if len(parts) != 2 or not all(parts):
        print("[ERROR] Invalid configured compute node.", file=sys.stderr)
        sys.exit(1)

    name, ip = parts

    if name in allowed_nodes or ip in allowed_nodes.values():
        print("[ERROR] Duplicate configured compute node.", file=sys.stderr)
        sys.exit(1)

    allowed_nodes[name] = ip

now = datetime.now(timezone.utc)
latest = {}

try:
    with open(metrics_file, newline="", encoding="utf-8") as file:
        reader = csv.DictReader(file)

        required = {
            "timestamp", "node", "ip", "status",
            "cpu_percent", "memory_percent"
        }

        if not required.issubset(reader.fieldnames or []):
            raise ValueError("Metrics CSV is missing required columns.")

        for row in reader:
            node = row.get("node", "")

            if node not in allowed_nodes:
                print(
                    f"[SKIP] Unknown node in metrics: {node}",
                    file=sys.stderr
                )
                continue

            if row.get("ip") != allowed_nodes[node]:
                print(
                    f"[SKIP] IP mismatch for configured node: {node}",
                    file=sys.stderr
                )
                continue

            try:
                timestamp = datetime.fromisoformat(
                    row["timestamp"].replace("Z", "+00:00")
                )

                if timestamp.tzinfo is None:
                    timestamp = timestamp.replace(tzinfo=timezone.utc)

                timestamp = timestamp.astimezone(timezone.utc)

                if node not in latest or timestamp > latest[node]["timestamp"]:
                    latest[node] = {
                        "timestamp": timestamp,
                        "row": row
                    }

            except (ValueError, TypeError, KeyError):
                continue

except (OSError, csv.Error, ValueError) as error:
    print(f"[ERROR] {error}", file=sys.stderr)
    sys.exit(1)

eligible = []

for node in allowed_nodes:
    if node not in latest:
        print(f"[SKIP] {node}: no metrics available", file=sys.stderr)
        continue

    entry = latest[node]
    row = entry["row"]
    age = (now - entry["timestamp"].astimezone(timezone.utc)).total_seconds()

    if row["status"] != "ONLINE":
        print(f"[SKIP] {node}: node is not online", file=sys.stderr)
        continue

    if age < -60 or age > max_age:
        print(f"[SKIP] {node}: metrics are stale or future-dated", file=sys.stderr)
        continue

    try:
        cpu = float(row["cpu_percent"])
        memory = float(row["memory_percent"])
    except (ValueError, TypeError):
        print(f"[SKIP] {node}: invalid metrics", file=sys.stderr)
        continue

    if not (0 <= cpu <= 100 and 0 <= memory <= 100):
        print(f"[SKIP] {node}: metrics outside valid range", file=sys.stderr)
        continue

    if cpu >= cpu_limit or memory >= memory_limit:
        print(
            f"[SKIP] {node}: resource limit reached "
            f"(CPU={cpu}%, RAM={memory}%)",
            file=sys.stderr
        )
        continue

    score = (cpu * cpu_weight + memory * memory_weight) / 100

    eligible.append({
        "node": node,
        "ip": allowed_nodes[node],
        "cpu": cpu,
        "memory": memory,
        "score": score
    })

if not eligible:
    print("NONE")
    sys.exit(0)

eligible.sort(key=lambda item: (item["score"], item["node"]))
selected = eligible[0]

for item in eligible:
    print(
        f"[CANDIDATE] {item['node']}: "
        f"CPU={item['cpu']}% RAM={item['memory']}% "
        f"Score={item['score']:.2f}",
        file=sys.stderr
    )

print(
    f"{selected['node']}|{selected['ip']}|"
    f"{selected['cpu']:.2f}|{selected['memory']:.2f}|"
    f"{selected['score']:.2f}"
)
PY
}

main() {
    local selection
    local timestamp
    local node
    local ip
    local cpu
    local memory
    local score

    validate_config

    log "Starting compute node scheduling."

    if ! selection="$(select_node)"; then
        log "Scheduler failed while reading metrics."
        exit 1
    fi

    timestamp="$(date -Is)"

    if [[ "$selection" == "NONE" ]]; then
        printf '%s,NO_CAPACITY,,,,,\n' "$timestamp" >> "$DECISIONS_FILE"
        log "No eligible compute node available."
        exit 2
    fi

    IFS='|' read -r node ip cpu memory score <<< "$selection"

    printf '%s,SELECTED,%s,%s,%s,%s,%s\n' \
        "$timestamp" "$node" "$ip" "$cpu" "$memory" "$score" \
        >> "$DECISIONS_FILE"

    log "Selected node: $node ($ip)"
    log "CPU: ${cpu}% | RAM: ${memory}% | Weighted score: $score"
    log "Placement decision recorded."
}

main "$@"
