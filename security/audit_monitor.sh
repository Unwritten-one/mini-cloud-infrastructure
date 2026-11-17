#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$PROJECT_ROOT/config/cloud.conf"
source "$PROJECT_ROOT/config/nodes.conf"

AUDIT_LOG="$PROJECT_ROOT/$LOG_DIR/security_audit.log"
STATE_DIR="$PROJECT_ROOT/$LOG_DIR/.audit_state"

mkdir -p "$PROJECT_ROOT/$LOG_DIR" "$STATE_DIR"
touch "$AUDIT_LOG"

collect_node() {
    local node_name="$1"
    local node_ip="$2"
    local node_type="$3"
    local state_file="$STATE_DIR/${node_name}.last_check"
    local since until journal_output events

    if [[ -f "$state_file" ]]; then
        since="$(<"$state_file")"
    else
        since="24 hours ago"
    fi

    until="$(date --iso-8601=seconds)"

    printf '[INFO] Checking %s (%s)...\n' "$node_name" "$node_ip"

    if [[ "$node_type" == "local" ]]; then
        if ! journal_output="$(sudo -n journalctl \
            --since "$since" --until "$until" \
            --no-pager -o short-iso)"; then
            printf '[ERROR] Could not read journal on %s.\n' "$node_name"
            return 1
        fi
    else
        if ! journal_output="$(ssh \
            -i "$CONTROLLER_SSH_KEY_PATH" \
            -p "$SSH_PORT" \
            -o BatchMode=yes \
            -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
            "$CLOUD_USER@$node_ip" \
            "sudo -n journalctl --since '$since' --until '$until' --no-pager -o short-iso")"; then
            printf '[ERROR] Could not read journal on %s.\n' "$node_name"
            return 1
        fi
    fi

    events="$(printf '%s\n' "$journal_output" | grep -E \
        'sshd\[[0-9]+\]: (Failed password|Failed publickey|Invalid user|authentication failure)|UFW BLOCK' || true)"

    if [[ -n "$events" ]]; then
        while IFS= read -r event; do
            printf '%s [%s %s] %s\n' \
                "$(date --iso-8601=seconds)" \
                "$node_name" "$node_ip" "$event" >> "$AUDIT_LOG"
        done <<< "$events"

        printf '[ALERT] New security events found on %s.\n' "$node_name"
    else
        printf '[INFO] No new matching events on %s.\n' "$node_name"
    fi

    printf '%s\n' "$until" > "$state_file"
}

collect_node "$CONTROLLER_NAME" "$CONTROLLER_IP" local

for node in "${COMPUTE_NODES[@]}"; do
    IFS='|' read -r node_name node_ip <<< "$node"
    collect_node "$node_name" "$node_ip" remote
done

printf '[INFO] Audit collection completed. Log: %s\n' "$AUDIT_LOG"
