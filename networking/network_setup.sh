#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PROJECT_DIR/config/cloud.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] Configuration file not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Run with sudo."
    exit 1
fi

for command in virsh python3 ip systemctl; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "[ERROR] Required command is missing: $command"
        exit 1
    fi
done

NETWORK_NAME="${MGMT_NETWORK_NAME:-cloud-management}"
NETWORK_CIDR="${MGMT_NETWORK_CIDR:-192.168.100.0/24}"
GATEWAY="${MGMT_GATEWAY:-192.168.100.1}"
BRIDGE="${MGMT_BRIDGE_NAME:-virbr10}"

CONTROLLER_IP="${CONTROLLER_IP:-192.168.100.10}"
COMPUTE_1_IP="192.168.100.11"
COMPUTE_2_IP="192.168.100.12"

CONTROLLER_MAC="${CONTROLLER_MAC:-52:54:00:10:00:10}"
COMPUTE_1_MAC="${COMPUTE_1_MAC:-52:54:00:10:00:11}"
COMPUTE_2_MAC="${COMPUTE_2_MAC:-52:54:00:10:00:12}"

if [[ ! "$NETWORK_NAME" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo "[ERROR] Invalid network name."
    exit 1
fi

if [[ ! "$BRIDGE" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo "[ERROR] Invalid bridge name."
    exit 1
fi

for mac in "$CONTROLLER_MAC" "$COMPUTE_1_MAC" "$COMPUTE_2_MAC"; do
    if [[ ! "$mac" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]; then
        echo "[ERROR] Invalid MAC address: $mac"
        exit 1
    fi
done

if [ "$CONTROLLER_MAC" = "$COMPUTE_1_MAC" ] ||
    [ "$CONTROLLER_MAC" = "$COMPUTE_2_MAC" ] ||
    [ "$COMPUTE_1_MAC" = "$COMPUTE_2_MAC" ]; then
    echo "[ERROR] Infrastructure MAC addresses must be unique."
    exit 1
fi

if ! virsh -c qemu:///system uri >/dev/null 2>&1; then
    echo "[ERROR] Cannot connect to system libvirt."
    exit 1
fi

NETWORK_VALUES="$(python3 - "$NETWORK_CIDR" "$GATEWAY" \
    "$CONTROLLER_IP" "$COMPUTE_1_IP" "$COMPUTE_2_IP" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.ip_network(sys.argv[1], strict=True)
    gateway = ipaddress.ip_address(sys.argv[2])
    reserved = [ipaddress.ip_address(value) for value in sys.argv[3:]]

    if network.version != 4 or network.prefixlen != 24:
        raise ValueError("Management network must be an IPv4 /24 subnet")

    if gateway not in network or gateway in (network.network_address, network.broadcast_address):
        raise ValueError("Gateway must be inside the management subnet")

    if len(set(reserved)) != len(reserved):
        raise ValueError("Reserved IP addresses must be unique")

    for address in reserved:
        if address not in network or address in (network.network_address, network.broadcast_address, gateway):
            raise ValueError(f"Reserved IP is invalid: {address}")

    start = network.network_address + 100
    end = network.network_address + 200

    if start not in network or end not in network:
        raise ValueError("DHCP range does not fit inside the subnet")

    if any(start <= address <= end for address in reserved):
        raise ValueError("Reserved IP overlaps the DHCP range")

    print(f"{network.netmask}|{start}|{end}")

except ValueError as error:
    print(f"[ERROR] {error}", file=sys.stderr)
    sys.exit(1)
PY
)" || exit 1

IFS='|' read -r NETMASK DHCP_START DHCP_END <<< "$NETWORK_VALUES"

echo "[INFO] Checking for overlapping host networks..."

if ! python3 - "$NETWORK_CIDR" <<'PYROUTES'
import ipaddress
import subprocess
import sys

target = ipaddress.ip_network(sys.argv[1])

try:
    result = subprocess.run(
        ["ip", "-4", "-o", "route", "show"],
        capture_output=True,
        text=True,
        check=True,
    )
except (subprocess.CalledProcessError, FileNotFoundError) as error:
    print(f"[ERROR] Unable to inspect host routes: {error}", file=sys.stderr)
    sys.exit(1)

for line in result.stdout.splitlines():
    destination = line.split()[0]

    if destination == "default":
        continue

    try:
        route = ipaddress.ip_network(destination, strict=False)
    except ValueError:
        continue

    if target.overlaps(route):
        print(
            f"[ERROR] Management subnet {target} overlaps host route {route}.",
            file=sys.stderr,
        )
        sys.exit(1)

print(f"[OK] No overlap found in visible WSL IPv4 routes for {target}.")
PYROUTES
then
    echo "[ERROR] Resolve the network overlap before continuing."
    exit 1
fi

TEMP_XML="$(mktemp)"
trap 'rm -f "$TEMP_XML"' EXIT

cat > "$TEMP_XML" <<EOF
<network>
  <name>$NETWORK_NAME</name>
  <forward mode='nat'/>
  <bridge name='$BRIDGE' stp='on' delay='0'/>
  <ip address='$GATEWAY' netmask='$NETMASK'>
    <dhcp>
      <range start='$DHCP_START' end='$DHCP_END'/>
      <host mac='$CONTROLLER_MAC' name='controller' ip='$CONTROLLER_IP'/>
      <host mac='$COMPUTE_1_MAC' name='compute-1' ip='$COMPUTE_1_IP'/>
      <host mac='$COMPUTE_2_MAC' name='compute-2' ip='$COMPUTE_2_IP'/>
    </dhcp>
  </ip>
</network>
EOF

echo "=================================="
echo "    Management Network Setup"
echo "=================================="

if virsh -c qemu:///system net-info "$NETWORK_NAME" >/dev/null 2>&1; then
    echo "[INFO] Existing network detected."

    if ! virsh -c qemu:///system net-dumpxml "$NETWORK_NAME" |
        python3 -c '
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.stdin).getroot()
ip = root.find("./ip")
dhcp = root.find("./ip/dhcp")
bridge = root.find("./bridge")
forward = root.find("./forward")

expected = {
    "name": sys.argv[1],
    "bridge": sys.argv[2],
    "gateway": sys.argv[3],
    "netmask": sys.argv[4],
    "start": sys.argv[5],
    "end": sys.argv[6],
    "controller_mac": sys.argv[7],
    "controller_ip": sys.argv[8],
    "compute1_mac": sys.argv[9],
    "compute1_ip": sys.argv[10],
    "compute2_mac": sys.argv[11],
    "compute2_ip": sys.argv[12],
}

hosts = {
    host.get("mac"): host.get("ip")
    for host in dhcp.findall("./host")
} if dhcp is not None else {}

ranges = dhcp.findall("./range") if dhcp is not None else []

valid = (
    root.findtext("name") == expected["name"]
    and bridge is not None
    and bridge.get("name") == expected["bridge"]
    and forward is not None
    and forward.get("mode") == "nat"
    and ip is not None
    and ip.get("address") == expected["gateway"]
    and ip.get("netmask") == expected["netmask"]
    and len(ranges) == 1
    and ranges[0].get("start") == expected["start"]
    and ranges[0].get("end") == expected["end"]
    and hosts.get(expected["controller_mac"]) == expected["controller_ip"]
    and hosts.get(expected["compute1_mac"]) == expected["compute1_ip"]
    and hosts.get(expected["compute2_mac"]) == expected["compute2_ip"]
)

sys.exit(0 if valid else 1)
' "$NETWORK_NAME" "$BRIDGE" "$GATEWAY" "$NETMASK" \
        "$DHCP_START" "$DHCP_END" "$CONTROLLER_MAC" "$CONTROLLER_IP" \
        "$COMPUTE_1_MAC" "$COMPUTE_1_IP" "$COMPUTE_2_MAC" "$COMPUTE_2_IP"; then
        echo "[ERROR] Existing network configuration does not match."
        echo "[INFO] Refusing to overwrite it."
        exit 1
    fi

else
    if ip link show dev "$BRIDGE" >/dev/null 2>&1; then
        echo "[ERROR] Bridge interface already exists: $BRIDGE"
        echo "[INFO] Check its owner before creating the network."
        exit 1
    fi

    echo "[INFO] Defining management network..."

    if ! virsh -c qemu:///system net-define "$TEMP_XML"; then
        echo "[ERROR] Failed to define management network."
        exit 1
    fi
fi

echo "[INFO] Enabling network autostart..."

if ! virsh -c qemu:///system net-autostart "$NETWORK_NAME"; then
    echo "[ERROR] Failed to enable network autostart."
    exit 1
fi

NETWORK_STATE="$(virsh -c qemu:///system net-info "$NETWORK_NAME" |
    awk -F: '/^Active:/ {gsub(/[[:space:]]/, "", $2); print $2}')"

if [ "$NETWORK_STATE" != "yes" ]; then
    if ! virsh -c qemu:///system net-start "$NETWORK_NAME"; then
        echo "[ERROR] Failed to start management network."
        exit 1
    fi
fi

NETWORK_STATE="$(virsh -c qemu:///system net-info "$NETWORK_NAME" |
    awk -F: '/^Active:/ {gsub(/[[:space:]]/, "", $2); print $2}')"

if [ "$NETWORK_STATE" != "yes" ]; then
    echo "[ERROR] Management network is not active."
    exit 1
fi

echo "=================================="
echo "Management network is ready."
echo "Network: $NETWORK_NAME"
echo "Bridge: $BRIDGE"
echo "Subnet: $NETWORK_CIDR"
echo "Gateway: $GATEWAY"
echo "DHCP: $DHCP_START - $DHCP_END"
echo "Controller: $CONTROLLER_IP"
echo "Compute 1: $COMPUTE_1_IP"
echo "Compute 2: $COMPUTE_2_IP"
echo "=================================="
