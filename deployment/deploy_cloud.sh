#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$PROJECT_ROOT/config/cloud.conf"

HYPERVISOR_DIR="$PROJECT_ROOT/hypervisor"
NETWORK_SCRIPT="$PROJECT_ROOT/networking/network_setup.sh"

LOG_DIR_PATH="$PROJECT_ROOT/$LOG_DIR"
LOG_FILE="$LOG_DIR_PATH/deployment.log"

log() {
    mkdir -p "$LOG_DIR_PATH"
    printf '[%s] %s\n' "$(date -Is)" "$1" | tee -a "$LOG_FILE"
}

fail() {
    log "ERROR: $1"
    exit 1
}

require_root() {
    [[ "$EUID" -eq 0 ]] || fail "Run deployment with sudo."
}

check_scripts() {
    local script

    for script in \
        "$HYPERVISOR_DIR/kvm_setup.sh" \
        "$HYPERVISOR_DIR/libvirt_setup.sh" \
        "$NETWORK_SCRIPT"; do

        [[ -f "$script" ]] ||
            fail "Required script not found: $script"
    done
}

run_script() {
    local script="$1"

    log "Running $(basename "$script")"

    if bash "$script"; then
        log "$(basename "$script") completed successfully."
    else
        fail "$(basename "$script") failed."
    fi
}

setup_host() {
    log "Starting hypervisor setup."

    run_script "$HYPERVISOR_DIR/kvm_setup.sh"
    run_script "$HYPERVISOR_DIR/libvirt_setup.sh"

    log "Hypervisor setup completed."
}


setup_network() {
    if [[ "${NETWORK_OVERLAP_CONFIRMED:-no}" != "yes" ]]; then
        fail "Confirm that the management subnet does not overlap with existing WSL or Windows networks by setting NETWORK_OVERLAP_CONFIRMED=yes."
    fi

    log "Starting management network setup."

    run_script "$NETWORK_SCRIPT"

    log "Management network setup completed."
}

setup_security() {
    fail "Local security configuration is disabled. Security is applied remotely to infrastructure VMs by bootstrap_nodes.sh."
}

show_status() {
    printf '\n========== DEPLOYMENT STATUS ==========\n'

    if command -v virsh >/dev/null 2>&1; then
        virsh -c qemu:///system list --all
    else
        printf 'Libvirt is not installed.\n'
    fi

    if command -v ufw >/dev/null 2>&1; then
        ufw status
    else
        printf 'UFW is not installed.\n'
    fi

    if [[ -n "${INFRA_VM_STORAGE_PATH:-}" && -d "$INFRA_VM_STORAGE_PATH" ]]; then
        printf '\nInfrastructure VM storage:\n'
        df -h "$INFRA_VM_STORAGE_PATH"
    else
        printf '\nInfrastructure VM storage directory is not available.\n'
    fi

    printf '=======================================\n'
}

main() {
    local command="${1:-}"

    require_root
    check_scripts

    case "$command" in
        check)
            log "Deployment scripts and configuration files are present."
            ;;
        host)
            setup_host
            ;;
        network)
            setup_network
            ;;
        security)
            setup_security
            ;;
        prepare)
            setup_host
            setup_network
            log "Infrastructure host preparation completed."
            log "Infrastructure storage will be verified during VM provisioning."
            log "Security configuration remains a separate stage."
            ;;
        status)
            show_status
            ;;
        *)
            printf 'Usage: %s {check|host|network|security|prepare|status}\n' "$0"
            exit 1
            ;;
    esac
}

main "$@"
