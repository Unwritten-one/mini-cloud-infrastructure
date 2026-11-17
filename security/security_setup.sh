#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_ROOT/config/cloud.conf"
SSH_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSH_DROPIN="$SSH_DROPIN_DIR/00-cloud-security.conf"
BACKUP_DIR="/etc/ssh/cloud-security-backup"
SSH_SERVICE=""

log() {
    printf '[INFO] %s\n' "$1"
}

fail() {
    printf '[ERROR] %s\n' "$1" >&2
    exit 1
}

require_root() {
    [[ "$EUID" -eq 0 ]] || fail "Run this script with sudo."
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || fail "Missing config/cloud.conf"
    source "$CONFIG_FILE"

    : "${MGMT_NETWORK_CIDR:?Management network CIDR is missing}"
}

check_prerequisites() {
    for cmd in apt-get systemctl ufw sshd awk grep python3 id getent cut ip; do
        command -v "$cmd" >/dev/null 2>&1 || {
            if [[ "$cmd" == "ufw" ]]; then
                log "Installing UFW..."
                apt-get update
                DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
            else
                fail "Required command not found: $cmd"
            fi
        }
    done

    if systemctl list-unit-files ssh.service --no-legend 2>/dev/null | awk '$1 == "ssh.service" { found=1 } END { exit !found }'; then
        SSH_SERVICE="ssh"
    elif systemctl list-unit-files sshd.service --no-legend 2>/dev/null | awk '$1 == "sshd.service" { found=1 } END { exit !found }'; then
        SSH_SERVICE="sshd"
    else
        fail "Could not find the SSH service."
    fi

    systemctl is-active --quiet "$SSH_SERVICE" ||
        fail "SSH service is not active. Refusing to change firewall rules."
}

get_ssh_port() {
    SSH_PORT="$(sshd -T | awk '$1 == "port" && !found {port=$2; found=1} END {if (found) print port}')"
    [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || fail "Could not determine SSH port."
}

get_allowed_ssh_source() {
    SSH_SOURCE="${SSH_ALLOWED_CIDR:-}"

    if [[ -z "$SSH_SOURCE" && -n "${SSH_CONNECTION:-}" ]]; then
        SSH_SOURCE="${SSH_CONNECTION%% *}"
    fi

    if [[ -z "$SSH_SOURCE" && -n "${SSH_CLIENT:-}" ]]; then
        SSH_SOURCE="${SSH_CLIENT%% *}"
    fi

    [[ -n "$SSH_SOURCE" ]] ||
        fail "Cannot identify your SSH client IP. Set SSH_ALLOWED_CIDR before running."

    python3 - "$SSH_SOURCE" <<'PY'
import ipaddress
import sys

try:
    ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError:
    raise SystemExit("Invalid SSH_ALLOWED_CIDR or SSH client IP.")
PY
}

verify_authorized_key() {
    local login_user
    local home_dir
    local key_file

    login_user="${SUDO_USER:-}"

    [[ -n "$login_user" ]] || login_user="${CLOUD_USER:-ubuntu}"

    id "$login_user" >/dev/null 2>&1 ||
        fail "SSH login user does not exist: $login_user"

    home_dir="$(getent passwd "$login_user" | cut -d: -f6)"
    key_file="$home_dir/.ssh/authorized_keys"

    [[ -s "$key_file" ]] ||
        fail "No authorized_keys found for $login_user. SSH hardening cancelled."

    if ! sshd -T -C "user=$login_user,host=localhost,addr=127.0.0.1" |
        awk '$1 == "pubkeyauthentication" && $2 == "yes" { found=1 } END { exit !found }'; then
        fail "Public-key authentication is not enabled."
    fi

}

configure_ssh() {
    log "Preparing SSH hardening..."

    mkdir -p "$SSH_DROPIN_DIR" "$BACKUP_DIR"

    if [[ -f "$SSH_DROPIN" ]]; then
        cp -a "$SSH_DROPIN" "$BACKUP_DIR/00-cloud-security.conf.previous"
    else
        rm -f "$BACKUP_DIR/00-cloud-security.conf.previous"
    fi

    cat > "$SSH_DROPIN" <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF

    if ! sshd -t || ! systemctl reload "$SSH_SERVICE"; then
        log "SSH hardening failed. Restoring previous configuration."

        if [[ -f "$BACKUP_DIR/00-cloud-security.conf.previous" ]]; then
            cp -a "$BACKUP_DIR/00-cloud-security.conf.previous" "$SSH_DROPIN"
        else
            rm -f "$SSH_DROPIN"
        fi

        if ! sshd -t || ! systemctl reload "$SSH_SERVICE"; then
            fail "CRITICAL: SSH recovery failed. Manual intervention is required."
        fi

        fail "SSH hardening failed. Previous configuration restored."
    fi

    log "SSH hardening applied."
}

configure_firewall() {
    log "Configuring UFW..."

    ufw allow from "$SSH_SOURCE" to any port "$SSH_PORT" proto tcp
    ufw allow from "$MGMT_NETWORK_CIDR" to any port "$SSH_PORT" proto tcp

    ufw default deny incoming
    ufw default allow outgoing
    ufw default deny routed

    GUEST_BRIDGE="${GUEST_BRIDGE_NAME:-virbr20}"
    GUEST_CIDR="${GUEST_NETWORK_CIDR:-192.168.200.0/24}"
    GUEST_GATEWAY="${GUEST_GATEWAY:-192.168.200.1}"

    if [[ -d "/sys/class/net/$GUEST_BRIDGE" ]]; then
        log "Configuring guest network firewall rules..."

        ufw allow in on "$GUEST_BRIDGE" to any port 67 proto udp
        ufw allow in on "$GUEST_BRIDGE" to "$GUEST_GATEWAY" port 53 proto udp
        ufw allow in on "$GUEST_BRIDGE" to "$GUEST_GATEWAY" port 53 proto tcp
        if ! command -v ip >/dev/null 2>&1; then
            log "[ERROR] The ip command is required for guest forwarding."
            exit 1
        fi

        UPLINK_INTERFACE="$(
            ip -4 route get 1.1.1.1 |
                awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}'
        )"

        if [[ -z "$UPLINK_INTERFACE" ]]; then
            log "[ERROR] Unable to detect the management uplink interface."
            exit 1
        fi

        ufw route allow in on "$GUEST_BRIDGE" out on "$UPLINK_INTERFACE" from "$GUEST_CIDR"

        log "Guest DHCP, DNS and outbound forwarding rules added via $UPLINK_INTERFACE."
    else
        log "Guest bridge not present. Skipping guest-specific firewall rules."
    fi

    ufw --force enable

    ufw status verbose
}

run_audit() {
    local failed=0

    log "Running security audit..."

    if sshd -T | awk '$1 == "pubkeyauthentication" && $2 == "yes" { found=1 } END { exit !found }'; then
        echo "[PASS] SSH public-key authentication enabled"
    else
        echo "[FAIL] SSH public-key authentication disabled"
        failed=1
    fi

    if sshd -T | awk '$1 == "passwordauthentication" && $2 == "no" { found=1 } END { exit !found }'; then
        echo "[PASS] SSH password authentication disabled"
    else
        echo "[FAIL] SSH password authentication enabled"
        failed=1
    fi

    if ufw status | awk '/^Status: active$/ { found=1 } END { exit !found }'; then
        echo "[PASS] UFW firewall active"
    else
        echo "[FAIL] UFW firewall inactive"
        failed=1
    fi

    if systemctl is-active --quiet "$SSH_SERVICE"; then
        echo "[PASS] SSH service active"
    else
        echo "[FAIL] SSH service inactive"
        failed=1
    fi

    if ufw show added |
        awk -v rule="ufw allow from $SSH_SOURCE to any port $SSH_PORT proto tcp" 'index($0, rule) { found=1 } END { exit !found }'; then
        echo "[PASS] SSH client source and port have an explicit allow rule"
    else
        echo "[FAIL] Expected SSH client firewall rule not found"
        failed=1
    fi

    if grep -Eq '^DEFAULT_FORWARD_POLICY="DROP"$' /etc/default/ufw &&
        ufw show raw | awk '$1 == "Chain" && $2 == "FORWARD" && $3 == "(policy" && $4 == "DROP" { found=1 } END { exit !found }'; then
        echo "[PASS] Routed traffic defaults to deny"
    else
        echo "[FAIL] Routed traffic default policy is not deny"
        failed=1
    fi

    [[ "$failed" -eq 0 ]] || fail "Security audit found failures."

    log "Security audit completed successfully."
}

main() {
    require_root
    load_config
    check_prerequisites
    get_ssh_port
    get_allowed_ssh_source
    verify_authorized_key
    configure_ssh
    configure_firewall
    run_audit
}

main "$@"
