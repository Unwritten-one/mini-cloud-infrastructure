
#!/bin/bash

# Check whether the system supports KVM virtualization.

echo "=================================="
echo "      KVM Virtualization Check"
echo "=================================="

# Check whether the CPU supports hardware virtualization.
if grep -E -q 'vmx|svm' /proc/cpuinfo; then
    echo "[OK] CPU virtualization support detected."
else
    echo "[ERROR] CPU virtualization support not detected."
    exit 1
fi

# Check whether KVM kernel modules are loaded.
if lsmod | grep -q '^kvm'; then
    echo "[OK] KVM kernel module is loaded."
else
    echo "[WARNING] KVM kernel module is not loaded."
fi

# Check whether the KVM device exists.
if [ -e /dev/kvm ]; then
    echo "[OK] /dev/kvm device is available."
else
    echo "[ERROR] /dev/kvm device is not available."
    exit 1
fi

echo "=================================="
echo "KVM environment check completed."
echo "=================================="
