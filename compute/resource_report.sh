#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AGENT_SCRIPT="$SCRIPT_DIR/node_agent.sh"

if [[ ! -f "$AGENT_SCRIPT" ]]; then
    printf '[ERROR] Node agent script not found.\n' >&2
    exit 1
fi

if ! command -v awk >/dev/null 2>&1; then
    printf '[ERROR] awk is required.\n' >&2
    exit 1
fi

report="$(bash "$AGENT_SCRIPT" health)" || {
    printf '[ERROR] Failed to collect resource information.\n' >&2
    exit 1
}

printf '\n====================================\n'
printf '       COMPUTE NODE REPORT\n'
printf '====================================\n'

printf '%s\n' "$report" | awk -F= '
    $1 == "hostname" {
        printf "Hostname:             %s\n", $2
    }
    $1 == "status" {
        printf "Node status:          %s\n", $2
    }
    $1 == "cpu_percent" {
        printf "CPU usage:            %s%%\n", $2
    }
    $1 == "memory_percent" {
        printf "Memory usage:         %s%%\n", $2
    }
    $1 == "memory_total_mb" {
        printf "Total memory:         %s MB\n", $2
    }
    $1 == "memory_available_mb" {
        printf "Available memory:     %s MB\n", $2
    }
    $1 == "disk_total_bytes" {
        printf "Disk capacity:        %.2f GB\n", $2 / 1073741824
    }
    $1 == "disk_used_bytes" {
        printf "Disk used:            %.2f GB\n", $2 / 1073741824
    }
    $1 == "disk_used_percent" {
        printf "Disk usage:           %s\n", $2
    }
    $1 == "libvirt_status" {
        printf "Libvirt status:       %s\n", $2
    }
'

printf '====================================\n'
