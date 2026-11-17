# Implementation Details

## 1. Project Overview

Mini Cloud Infrastructure is a Bash-based mini-cloud system built using KVM, QEMU and libvirt. It uses a Controller VM to monitor Compute Nodes and schedule guest virtual machines according to available CPU and memory resources.

The current deployment target is Ubuntu 24.04 running inside WSL2 on a Windows 11 host.

## 2. Infrastructure Architecture

The planned infrastructure contains:

- One Controller VM for management and scheduling.
- Two Compute VMs for hosting guest virtual machines.
- KVM/QEMU as the virtualization technology.
- Libvirt for virtual machine and network management.

The Controller communicates with Compute Nodes over SSH.

## 3. Main Components

### Hypervisor

The `hypervisor/` directory contains scripts for:

- Checking and installing KVM-related packages.
- Configuring libvirt services.
- Creating and managing VM storage pools.
- Creating and deleting virtual machines.

### Controller

The `controller/` directory contains:

- `node_monitor.sh`: Collects CPU and memory metrics from Compute Nodes.
- `scheduler.sh`: Evaluates available resources and selects a suitable Compute Node.
- `cloud_manager.sh`: Coordinates monitoring, scheduling and remote guest VM deployment.

### Compute Nodes

The `compute/` directory contains:

- `node_agent.sh`: Provides node health and resource information.
- `resource_report.sh`: Displays CPU, memory, disk and libvirt status.

### Networking

The `networking/` directory configures separate management and guest networks using libvirt NAT networks.

Guest-to-management traffic is restricted using firewall rules.

### Security

The `security/` directory contains SSH hardening and firewall configuration for infrastructure VMs.

### Deployment

The `deployment/` directory contains scripts for:

- AWS environment setup from the earlier deployment plan.
- Creating Controller and Compute infrastructure VMs.
- Bootstrapping and configuring infrastructure nodes.
- Coordinating cloud deployment.

## 4. Resource-Aware Scheduling

The custom scheduler uses CPU and memory utilization metrics.

The configured weights are:

- CPU weight: 50%
- Memory weight: 50%

The scheduler evaluates eligible Compute Nodes against configured resource limits and selects a suitable node.

Metrics are collected by the Controller and stored in CSV files under `results/resource_metrics/`. Scheduling decisions are recorded under `results/scheduler_results/`.

## 5. Network Configuration

The system uses two separate virtual networks:

| Network | Subnet | Purpose |
|---|---|---|
| Management | 192.168.100.0/24 | Controller and Compute communication |
| Guest | 192.168.200.0/24 | Guest virtual machine networking |

The Controller uses `192.168.100.10`, while the Compute Nodes use `192.168.100.11` and `192.168.100.12`.

## 6. Configuration

Central configuration is maintained in:

- `config/cloud.conf`: Cloud, VM, storage and network settings.
- `config/nodes.conf`: Compute Node addresses, SSH settings and scheduler parameters.

## 7. Current Implementation Status

The project scripts and configuration have been prepared for the local WSL2 deployment target.

Host-level KVM availability has been checked. Infrastructure VM deployment, guest VM creation, end-to-end scheduling and nested KVM operation inside Compute VMs still require practical verification.

These features will be marked complete only after successful testing.
