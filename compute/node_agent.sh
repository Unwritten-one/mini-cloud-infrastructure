#!/usr/bin/env bash
set -Eeuo pipefail

get_cpu_usage() {
    local total_before
    local idle_before
    local total_after
    local idle_after

    read -r total_before idle_before < <(
        awk '/^cpu / {
            total=0
            for (i=2; i<=NF; i++) total += $i
            print total, $5
        }' /proc/stat
    )

    [[ "$total_before" =~ ^[0-9]+$ &&
       "$idle_before" =~ ^[0-9]+$ ]] || return 1

    sleep 1

    read -r total_after idle_after < <(
        awk '/^cpu / {
            total=0
            for (i=2; i<=NF; i++) total += $i
            print total, $5
        }' /proc/stat
    )

    awk -v tb="$total_before" -v ib="$idle_before" \
        -v ta="$total_after" -v ia="$idle_after" \
        'BEGIN {
            total=ta-tb
            idle=ia-ib
            if (total <= 0) exit 1
            printf "%.2f", (total-idle)*100/total
        }'
}

get_memory_usage() {
    awk '
        /^MemTotal:/ { total=$2 }
        /^MemAvailable:/ { available=$2 }
        END {
            if (total <= 0 || available < 0 || available > total) exit 1
            used=total-available
            printf "%.2f|%d|%d", used*100/total, total/1024, available/1024
        }
    ' /proc/meminfo
}

get_disk_usage() {
    local disk

    disk="$(df -P -B1 / | awk 'NR==2 {
        if ($2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ ||
            $5 !~ /^[0-9]+%$/ || $2 <= 0 || $3 > $2) exit 1
        printf "%s|%s|%s", $2, $3, $5
    }')" || return 1

    [[ -n "$disk" ]] || return 1
    printf '%s' "$disk"
}

get_libvirt_status() {
    if ! command -v virsh >/dev/null 2>&1; then
        printf 'NOT_INSTALLED'
        return
    fi

    if virsh -c qemu:///system list --all >/dev/null 2>&1; then
        printf 'AVAILABLE'
    else
        printf 'UNAVAILABLE'
    fi
}

health_check() {
    local cpu
    local memory
    local disk
    local libvirt
    local hostname

    hostname="$(hostname)"
    cpu="$(get_cpu_usage)" || return 1
    memory="$(get_memory_usage)" || return 1
    disk="$(get_disk_usage)" || return 1
    libvirt="$(get_libvirt_status)"

    printf 'hostname=%s\n' "$hostname"
    printf 'cpu_percent=%s\n' "$cpu"
    printf 'memory_percent=%s\n' "${memory%%|*}"

    IFS='|' read -r _ total_mb available_mb <<< "$memory"
    printf 'memory_total_mb=%s\n' "$total_mb"
    printf 'memory_available_mb=%s\n' "$available_mb"

    IFS='|' read -r disk_total disk_used disk_percent <<< "$disk"
    printf 'disk_total_bytes=%s\n' "$disk_total"
    printf 'disk_used_bytes=%s\n' "$disk_used"
    printf 'disk_used_percent=%s\n' "$disk_percent"

    printf 'libvirt_status=%s\n' "$libvirt"
    printf 'status=ONLINE\n'
}

main() {
    local command="${1:-health}"

    case "$command" in
        health)
            health_check
            ;;
        hostname)
            hostname
            ;;
        libvirt)
            get_libvirt_status
            printf '\n'
            ;;
        *)
            printf 'Usage: %s {health|hostname|libvirt}\n' "$0" >&2
            exit 1
            ;;
    esac
}

main "$@"
