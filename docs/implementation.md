# Implementation Details

## 1. Overview & Configuration

Mini Cloud Infrastructure is a Bash- and Python-orchestrated private cloud built on **KVM/QEMU** and **libvirt** inside Windows 11 WSL2 (Ubuntu 24.04). It operates a three-node virtualized cluster (`controller` at `192.168.100.10`, `compute-1` at `192.168.100.11`, `compute-2` at `192.168.100.12`) with nested KVM enabled on compute nodes to host tenant guest VMs.

- **`config/cloud.conf`**: Centralizes cloud naming, SSH key paths, remote deployment directory (`/opt/mini-cloud`), guest defaults (`1024` MB RAM, `1` vCPU), Ubuntu 24.04 cloud image paths, storage pools (`infrastructure-vms`, `cloud-vms`), and subnets (`192.168.100.0/24`, `192.168.200.0/24`).
- **`config/nodes.conf`**: Declares the dynamic `COMPUTE_NODES` array, SSH parameters, resource limits (`NODE_CPU_LIMIT=80`, `NODE_MEMORY_LIMIT=80`), and scheduler weights (`SCHEDULER_CPU_WEIGHT=50`, `SCHEDULER_MEMORY_WEIGHT=50`).

---

## 2. Component Architecture

- **`hypervisor/`**:
  - `kvm_setup.sh`: Verifies hardware virtualization (`vmx`/`svm`), `/dev/kvm` permissions, and required KVM/QEMU packages.
  - `libvirt_setup.sh`: Enables and validates `libvirtd` and `qemu:///system`.
  - `storage_setup.sh`: Creates and activates directory-backed libvirt storage pools (`infrastructure-vms` on the host; `cloud-vms` on compute nodes).
  - `vm_manager.sh`: Provisions and deletes libvirt domains using `qcow2` backing images and `cloud-localds` cloud-init ISOs (configuring hostname, SSH authorized keys, and disabling password/root SSH login).
- **`networking/`**:
  - `network_setup.sh`: Provisions `cloud-management` (`virbr10`, `192.168.100.0/24`) with static DHCP MAC bindings for `controller` (`.10`), `compute-1` (`.11`), and `compute-2` (`.12`).
  - `guest_network_setup.sh`: Provisions `cloud-guests` (`virbr20`, `192.168.200.0/24`) on compute nodes and applies `nftables` (`mini_cloud_guest_guard`) rules blocking guest-to-management subnet traffic.
- **`controller/`**:
  - `node_monitor.sh`: Iterates over `COMPUTE_NODES` via SSH, samples `/proc/stat` and `/proc/meminfo`, logs threshold warnings, and appends records to `results/resource_metrics/node_metrics.csv`.
  - `scheduler.sh`: Validates metric freshness (`<= 300s`), excludes offline or over-threshold nodes (`>= 80%` CPU or RAM), computes a weighted score `(100 - CPU%) * 0.5 + (100 - RAM%) * 0.5`, and records decisions in `results/scheduler_results/placement_decisions.csv`.
  - `cloud_manager.sh`: Orchestrates `monitor`, `schedule`, `deploy`, `delete`, `status`, and `watch`, polling `virsh domifaddr` until newly deployed guests receive a `192.168.200.x` DHCP address.
- **`compute/`**:
  - `node_agent.sh` & `resource_report.sh`: Collect and format local compute node CPU, memory, root filesystem disk usage, and libvirt daemon status.
- **`deployment/`**:
  - `deploy_cloud.sh`, `create_infrastructure_vms.sh`, & `bootstrap_nodes.sh`: Prepare the WSL2 host, launch the three infrastructure VMs, and configure packages, storage, networks, firewall rules, and `/opt/mini-cloud` files.
  - `request_vm.sh`: Client CLI supporting single and batch `deploy`, `delete`, and `list` operations, automatic local SSH port forwarding (`2221`–`2299` via the Controller jump host), state persistence in `results/active_guests.csv`, and tunnel cleanup on deletion.
- **`security/` & `tests/`**:
  - `security_setup.sh`: Applies UFW default-deny inbound policies and hardens `sshd_config`.
  - `audit_monitor.sh`: Scans `journalctl` across `controller`, `compute-1`, and `compute-2` for `sshd` failures and `UFW BLOCK` events, writing alerts to `logs/security_audit.log`.
  - `tests/run_tests.sh`: Validates required files, `bash -n` syntax across all scripts, configuration variables, node count, and scheduler weight totals.

---

## 3. Verification Status

- Infrastructure VMs (`controller`, `compute-1`, `compute-2`) and virtual networks (`cloud-management`, `cloud-guests`) are active with nested KVM enabled.
- End-to-end single and batch guest VM provisioning, weighted scheduling, local SSH port forwarding (`2221`–`2299`), guest-to-management network isolation, and batch teardown are verified.
- `tests/run_tests.sh` passes 45/45 automated checks.