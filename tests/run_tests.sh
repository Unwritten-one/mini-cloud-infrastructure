#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

pass() {
    echo "[PASS] $1"
    ((PASS += 1))
}

fail() {
    echo "[FAIL] $1"
    ((FAIL += 1))
}

echo "=================================="
echo " Mini Cloud Infrastructure Tests"
echo "=================================="

# Check required project files
required_files=(
    "config/cloud.conf"
    "config/nodes.conf"
    "controller/scheduler.sh"
    "controller/node_monitor.sh"
    "controller/cloud_manager.sh"
    "compute/node_agent.sh"
    "compute/resource_report.sh"
    "hypervisor/kvm_setup.sh"
    "hypervisor/libvirt_setup.sh"
    "hypervisor/storage_setup.sh"
    "hypervisor/vm_manager.sh"
    "networking/network_setup.sh"
    "networking/guest_network_setup.sh"
    "security/security_setup.sh"
    "deployment/aws_setup.sh"
    "deployment/bootstrap_nodes.sh"
    "deployment/create_infrastructure_vms.sh"
    "deployment/deploy_cloud.sh"
)

for file in "${required_files[@]}"; do
    if [[ -f "$PROJECT_ROOT/$file" ]]; then
        pass "File exists: $file"
    else
        fail "Missing file: $file"
    fi
done

# Check shell syntax
while IFS= read -r -d '' file; do
    if bash -n "$file"; then
        pass "Shell syntax: ${file#"$PROJECT_ROOT/"}"
    else
        fail "Shell syntax: ${file#"$PROJECT_ROOT/"}"
    fi
done < <(find "$PROJECT_ROOT" -type f -name '*.sh' -not -path '*/.git/*' -print0)

# Load project configuration
if source "$PROJECT_ROOT/config/cloud.conf" &&
   source "$PROJECT_ROOT/config/nodes.conf"; then
    pass "Configuration files load successfully"
else
    fail "Configuration files could not be loaded"
    exit 1
fi

# Check essential configuration
for variable in CLOUD_NAME CLOUD_USER CONTROLLER_IP \
    MGMT_NETWORK_CIDR GUEST_NETWORK_CIDR \
    GUEST_MEMORY_MB GUEST_VCPUS; do
    if [[ -n "${!variable:-}" ]]; then
        pass "Configuration: $variable"
    else
        fail "Configuration missing: $variable"
    fi
done

# Check compute node count
if [[ "${#COMPUTE_NODES[@]}" -ge 2 ]]; then
    pass "At least two compute nodes configured"
else
    fail "At least two compute nodes are required"
fi

# Check scheduler weights
if [[ "$((SCHEDULER_CPU_WEIGHT + SCHEDULER_MEMORY_WEIGHT))" -eq 100 ]]; then
    pass "Scheduler weights total 100"
else
    fail "Scheduler weights must total 100"
fi

echo "=================================="
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo "=================================="

if (( FAIL > 0 )); then
    exit 1
fi

echo "All checks passed."
