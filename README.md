# Mini Cloud Infrastructure

A lightweight multi-node Infrastructure-as-a-Service (IaaS) cloud platform built from scratch on Linux using **KVM/QEMU**, **libvirt**, **Bash**, and a **custom resource-aware VM scheduler**.

---

## 1. Overview

Mini Cloud Infrastructure implements core private cloud orchestration concepts on a Windows 11 / WSL2 (Ubuntu 24.04) host using nested virtualization:

- **Centralized Control Plane:** A dedicated Controller VM monitors compute node telemetry, evaluates weighted placement scores, and orchestrates guest VM provisioning and teardown over SSH.
- **Resource-Aware Scheduling:** Collects live CPU and RAM utilization across compute nodes, enforces safety utilization thresholds (`80%`), and schedules workloads onto the highest-scoring compute node.
- **Automated Guest Lifecycle & Access:** Supports single and batch guest VM deployment and deletion (`request_vm.sh`), dynamic DHCP IP discovery, and automatic local SSH port forwarding (`2221`–`2299`).
- **Network Isolation & Security Auditing:** Separates management and tenant traffic across dedicated virtual bridges (`virbr10` and `virbr20`), blocks guest-to-management access via `nftables` and UFW, and collects SSH/firewall audit logs.

---

## 2. System Architecture & Topology

Architecture diagrams are maintained in:
- [`architecture/system_architecture.md`](architecture/system_architecture.md)
- [`architecture/network_architecture.md`](architecture/network_architecture.md)
- [`architecture/deployment_architecture.md`](architecture/deployment_architecture.md)

### Infrastructure Nodes

| Node | Role | Management IP | vCPUs | RAM | Storage |
| :--- | :--- | :--- | :---: | :---: | :--- |
| **`controller`** | Orchestration, telemetry collection, scheduling, audit logs | `192.168.100.10` | 1 | 1024 MB | System disk (`/opt/mini-cloud`) |
| **`compute-1`** | Nested KVM hypervisor hosting guest VMs | `192.168.100.11` | 2 | 2048 MB | System disk + 10 GB data disk (`/mnt/cloud-vm-storage`) |
| **`compute-2`** | Nested KVM hypervisor hosting guest VMs | `192.168.100.12` | 2 | 2048 MB | System disk + 10 GB data disk (`/mnt/cloud-vm-storage`) |

### Virtual Networks & Storage Pools

| Resource | Name | Configuration |
| :--- | :--- | :--- |
| **Management Network** | `cloud-management` (`virbr10`) | `192.168.100.0/24` (Gateway `192.168.100.1`) — Controller-to-Compute SSH & metrics |
| **Guest Network** | `cloud-guests` (`virbr20`) | `192.168.200.0/24` (Gateway `192.168.200.1`, DHCP `.100`–`.200`) — Isolated guest subnet |
| **Host Storage Pool** | `infrastructure-vms` | `/var/lib/mini-cloud/infrastructure-vms` (WSL2 host) |
| **Guest Storage Pool** | `cloud-vms` | `/mnt/cloud-vm-storage` (Compute nodes, Ubuntu 24.04 cloud image) |

---

## 3. End-to-End Workflow

1. **Request Submission:** A user runs `deployment/request_vm.sh deploy <ssh-pubkey> <vm-name...>` from WSL2.
2. **Telemetry Collection:** The Controller executes `controller/node_monitor.sh` over SSH to sample CPU and RAM utilization on every node listed in `config/nodes.conf`, appending records to `results/resource_metrics/node_metrics.csv`.
3. **Workload Placement:** `controller/scheduler.sh` verifies metric freshness (`<= 300s`), filters out unreachable nodes or nodes exceeding the `80%` CPU/RAM ceiling, computes a weighted availability score (`50%` CPU + `50%` RAM), and logs the placement decision to `results/scheduler_results/placement_decisions.csv`.
4. **Provisioning & Cloud-Init:** `controller/cloud_manager.sh` invokes `hypervisor/vm_manager.sh` on the selected compute node to create a `qcow2` overlay image and `cloud-localds` ISO, injecting the user's SSH public key and booting the guest VM.
5. **IP Discovery & Port Forwarding:** The Controller polls `virsh domifaddr` until the guest acquires a `192.168.200.x` DHCP lease, and `request_vm.sh` opens a local SSH tunnel (`127.0.0.1:2221`–`2299`) persisted in `results/active_guests.csv`.
6. **Teardown:** Running `deployment/request_vm.sh delete <vm-name...>` destroys the guest VMs, deletes their virtual disks, removes CSV entries, and terminates the local SSH port forwards.

---

## 4. Technology Stack

| Layer | Technology |
| :--- | :--- |
| **Host Environment** | Windows 11 with WSL2 (Ubuntu 24.04) |
| **Hypervisor & VM Lifecycle** | KVM / QEMU, `libvirt`, `virsh`, `virt-install`, `cloud-localds` |
| **Orchestration & Tooling** | Bash (`set -Eeuo pipefail`), Python 3 (CSV & telemetry parsing) |
| **Networking & Isolation** | `libvirt` NAT bridges (`virbr10`, `virbr20`), `nftables`, UFW |
| **Access & Security** | Key-based SSH, local SSH port forwarding (`-L`), `journalctl` audit collector |

---

## 5. Repository Structure

```text
mini-cloud-infrastructure/
├── architecture/
│   ├── deployment_architecture.md
│   ├── network_architecture.md
│   └── system_architecture.md
├── compute/
│   ├── node_agent.sh
│   └── resource_report.sh
├── config/
│   ├── cloud.conf
│   └── nodes.conf
├── controller/
│   ├── cloud_manager.sh
│   ├── node_monitor.sh
│   └── scheduler.sh
├── deployment/
│   ├── bootstrap_nodes.sh
│   ├── create_infrastructure_vms.sh
│   ├── deploy_cloud.sh
│   └── request_vm.sh
├── docs/
│   └── implementation.md
├── hypervisor/
│   ├── kvm_setup.sh
│   ├── libvirt_setup.sh
│   ├── storage_setup.sh
│   └── vm_manager.sh
├── logs/
├── networking/
│   ├── guest_network_setup.sh
│   └── network_setup.sh
├── results/
│   ├── active_guests.csv
│   ├── resource_metrics/
│   └── scheduler_results/
├── security/
│   ├── audit_monitor.sh
│   └── security_setup.sh
├── tests/
│   └── run_tests.sh
├── LICENSE
└── README.md
```

---

## 6. Usage

### 6.1 Initial Infrastructure Setup (WSL2 Host)

```bash
# 1. Prepare host KVM, libvirt, and virtual networks
sudo bash deployment/deploy_cloud.sh prepare

# 2. Provision controller, compute-1, and compute-2 VMs
sudo bash deployment/create_infrastructure_vms.sh

# 3. Bootstrap hypervisor, storage, networking, security, and controller scripts
bash deployment/bootstrap_nodes.sh
```

### 6.2 Guest VM Lifecycle Management

```bash
# Deploy one or multiple guest VMs (automatically assigns local SSH ports 2221+)
bash deployment/request_vm.sh deploy ~/.ssh/guest-demo-access.pub web-1 web-2

# List active guest VMs, host nodes, guest IPs, and local SSH ports
bash deployment/request_vm.sh list

# Connect to a guest VM via its forwarded local SSH port
ssh -i ~/.ssh/guest-demo-access -p 2221 ubuntu@127.0.0.1

# Delete one or multiple guest VMs and release their local SSH tunnels
bash deployment/request_vm.sh delete web-1 web-2
```

### 6.3 Monitoring, Security Audit & Validation

```bash
# Stream live cluster telemetry from the Controller (refreshes every 5 seconds)
ssh -i ~/.ssh/infrastructure-node-access ubuntu@192.168.100.10 \
    "bash /opt/mini-cloud/controller/cloud_manager.sh watch 5"

# Collect SSH authentication failures and UFW block events across all nodes
ssh -i ~/.ssh/infrastructure-node-access ubuntu@192.168.100.10 \
    "bash /opt/mini-cloud/security/audit_monitor.sh"

# Run automated syntax, configuration, and structure validation checks
bash tests/run_tests.sh
```

---

## 7. Configuration

- **`config/cloud.conf`**: Defines network CIDRs and gateways (`192.168.100.0/24`, `192.168.200.0/24`), MAC-to-IP bindings, libvirt storage pools, base cloud image paths, and default guest VM sizing (`1` vCPU, `1024` MB RAM).
- **`config/nodes.conf`**: Defines the `COMPUTE_NODES` array (`compute-1|192.168.100.11`, `compute-2|192.168.100.12`), SSH connection parameters, CPU/RAM utilization limits (`80%`), and scheduler weights (`50%` CPU / `50%` RAM).

---

## 8. Security Controls

- **SSH Hardening:** Enforces key-based authentication across all infrastructure and guest VMs; password authentication and root SSH login are disabled.
- **Host Firewall (UFW):** Applies default-deny inbound rules on infrastructure nodes, permitting only required management SSH traffic.
- **Guest Network Isolation (`nftables`):** Enforces the `mini_cloud_guest_guard` ruleset on compute nodes so guest VMs on `192.168.200.0/24` cannot reach the `192.168.100.0/24` management network.
- **Audit Logging:** `security/audit_monitor.sh` aggregates `sshd` authentication failures and `UFW BLOCK` events from `controller`, `compute-1`, and `compute-2` into `logs/security_audit.log`.

---

## 9. Project Information

- **Documentation:** See [`docs/implementation.md`](docs/implementation.md)
- **License:** See [`LICENSE`](LICENSE)
