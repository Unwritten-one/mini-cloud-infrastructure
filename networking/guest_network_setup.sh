#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PROJECT_DIR/config/cloud.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERROR] Configuration file not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

if [[ "$EUID" -ne 0 ]]; then
    echo "[ERROR] Run with sudo."
    exit 1
fi

for command in virsh python3 ip systemctl nft; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "[ERROR] Required command is missing: $command"
        exit 1
    fi
done

NETWORK_NAME="${GUEST_NETWORK_NAME:-cloud-guests}"
NETWORK_CIDR="${GUEST_NETWORK_CIDR:-192.168.200.0/24}"
GATEWAY="${GUEST_GATEWAY:-192.168.200.1}"
MGMT_CIDR="${MGMT_NETWORK_CIDR:-192.168.100.0/24}"
BRIDGE="${GUEST_BRIDGE_NAME:-virbr20}"

if [[ ! "$NETWORK_NAME" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo "[ERROR] Invalid guest network name."
    exit 1
fi

if [[ ! "$BRIDGE" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo "[ERROR] Invalid guest bridge name."
    exit 1
fi

NETWORK_VALUES="$(python3 - "$NETWORK_CIDR" "$GATEWAY" "$MGMT_CIDR" <<'PY'
import ipaddress
import sys

try:
    guest = ipaddress.ip_network(sys.argv[1], strict=True)
    gateway = ipaddress.ip_address(sys.argv[2])
    management = ipaddress.ip_network(sys.argv[3], strict=True)

    if guest.version != 4 or guest.prefixlen != 24:
        raise ValueError("Guest network must be an IPv4 /24 subnet")

    if management.version != 4:
        raise ValueError("Management network must use IPv4")

    if guest.overlaps(management):
        raise ValueError("Guest and management networks must not overlap")

    if gateway not in guest:
        raise ValueError("Guest gateway must be inside the guest subnet")

    if gateway in (guest.network_address, guest.broadcast_address):
        raise ValueError("Invalid guest gateway address")

    start = guest.network_address + 100
    end = guest.network_address + 200

    if end >= guest.broadcast_address:
        raise ValueError("DHCP range exceeds guest subnet")

    if start <= gateway <= end:
        raise ValueError("Gateway overlaps the DHCP range")

    print(f"{guest.netmask}|{start}|{end}")

except ValueError as error:
    print(f"[ERROR] {error}", file=sys.stderr)
    sys.exit(1)
PY
)" || exit 1

IFS='|' read -r NETMASK DHCP_START DHCP_END <<< "$NETWORK_VALUES"

if ! virsh -c qemu:///system uri >/dev/null 2>&1; then
    echo "[ERROR] Cannot connect to system libvirt."
    exit 1
fi

TEMP_XML="$(mktemp)"
trap 'rm -f "$TEMP_XML"' EXIT

cat > "$TEMP_XML" <<EOF
<network>
  <name>$NETWORK_NAME</name>
  <forward mode='nat'/>
  <bridge name='$BRIDGE' stp='on' delay='0'/>
  <port isolated='yes'/>
  <ip address='$GATEWAY' netmask='$NETMASK'>
    <dhcp>
      <range start='$DHCP_START' end='$DHCP_END'/>
    </dhcp>
  </ip>
</network>
EOF

echo "=================================="
echo "     Guest Network Setup"
echo "=================================="

if virsh -c qemu:///system net-info "$NETWORK_NAME" >/dev/null 2>&1; then
    echo "[INFO] Existing guest network detected."

    if ! virsh -c qemu:///system net-dumpxml "$NETWORK_NAME" |
        python3 -c '
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.stdin).getroot()
ip = root.find("./ip")
dhcp = root.find("./ip/dhcp")
bridge = root.find("./bridge")
forward = root.find("./forward")
port = root.find("./port")
ranges = dhcp.findall("./range") if dhcp is not None else []

valid = (
    root.findtext("name") == sys.argv[1]
    and bridge is not None
    and bridge.get("name") == sys.argv[2]
    and forward is not None
    and forward.get("mode") == "nat"
    and port is not None
    and port.get("isolated") == "yes"
    and ip is not None
    and ip.get("address") == sys.argv[3]
    and ip.get("netmask") == sys.argv[4]
    and len(ranges) == 1
    and ranges[0].get("start") == sys.argv[5]
    and ranges[0].get("end") == sys.argv[6]
)

sys.exit(0 if valid else 1)
' "$NETWORK_NAME" "$BRIDGE" "$GATEWAY" "$NETMASK" \
        "$DHCP_START" "$DHCP_END"; then
        echo "[ERROR] Existing guest network configuration does not match."
        echo "[INFO] Refusing to overwrite it."
        exit 1
    fi

else
    if ip link show dev "$BRIDGE" >/dev/null 2>&1; then
        echo "[ERROR] Bridge already exists: $BRIDGE"
        exit 1
    fi

    echo "[INFO] Defining guest network."

    virsh -c qemu:///system net-define "$TEMP_XML"
fi

echo "[INFO] Enabling guest network autostart."

virsh -c qemu:///system net-autostart "$NETWORK_NAME"

NETWORK_STATE="$(virsh -c qemu:///system net-info "$NETWORK_NAME" |
    awk -F: '/^Active:/ {gsub(/[[:space:]]/, "", $2); print $2}')"

if [[ "$NETWORK_STATE" != "yes" ]]; then
    virsh -c qemu:///system net-start "$NETWORK_NAME"
fi

NETWORK_STATE="$(virsh -c qemu:///system net-info "$NETWORK_NAME" |
    awk -F: '/^Active:/ {gsub(/[[:space:]]/, "", $2); print $2}')"

if [[ "$NETWORK_STATE" != "yes" ]]; then
    echo "[ERROR] Guest network is not active."
    exit 1
fi

echo "[INFO] Configuring guest-to-management isolation."

NFT_BIN="$(command -v nft)"
RULE_FILE="/etc/nftables.d/mini-cloud-guest-guard.nft"
SERVICE_FILE="/etc/systemd/system/mini-cloud-guest-guard.service"

mkdir -p /etc/nftables.d

cat > "$RULE_FILE" <<EOF
table inet mini_cloud_guest_guard {
    chain input {
        type filter hook input priority -5; policy accept;
        iifname "$BRIDGE" ip daddr $MGMT_CIDR drop
        iifname "$BRIDGE" meta nfproto ipv6 drop
        iifname "$BRIDGE" tcp dport { 22, 16509, 9090 } drop
    }

    chain forward {
        type filter hook forward priority -5; policy accept;
        iifname "$BRIDGE" ip daddr $MGMT_CIDR drop
        iifname "$BRIDGE" meta nfproto ipv6 drop
    }
}
EOF

chmod 600 "$RULE_FILE"

if nft list table inet mini_cloud_guest_guard >/dev/null 2>&1; then
    nft delete table inet mini_cloud_guest_guard
fi

nft -f "$RULE_FILE"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Mini Cloud Guest Network Isolation Firewall
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'if $NFT_BIN list table inet mini_cloud_guest_guard >/dev/null 2>&1; then $NFT_BIN delete table inet mini_cloud_guest_guard; fi; $NFT_BIN -f $RULE_FILE'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mini-cloud-guest-guard.service
systemctl restart mini-cloud-guest-guard.service

if ! nft list table inet mini_cloud_guest_guard >/dev/null 2>&1; then
    echo "[ERROR] Guest isolation firewall verification failed."
    exit 1
fi

echo "=================================="
echo "[OK] Guest network is ready."
echo "Network: $NETWORK_NAME"
echo "Bridge: $BRIDGE"
echo "Subnet: $NETWORK_CIDR"
echo "Gateway: $GATEWAY"
echo "DHCP: $DHCP_START - $DHCP_END"
echo "Guest port isolation: Enabled"
echo "Management subnet protection: Enabled"
echo "Firewall persistence: Enabled"
echo "=================================="
