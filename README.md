# Mini Cloud Infrastructure

**A Miniature Multi-Node Cloud Computing Environment**

A lightweight cloud infrastructure built using Linux, KVM/QEMU, libvirt, Bash scripting, and a custom resource-aware scheduler.

## 1. Project Overview

Mini Cloud Infrastructure is an educational implementation of a small-scale cloud computing environment.

The project aims to demonstrate how multiple compute nodes can work together to provide virtual machine provisioning, resource allocation, workload scheduling, network isolation, security, and monitoring.

The system uses a centralized Controller Node to manage multiple Compute Nodes. A custom scheduler evaluates available resources and selects a suitable compute node whenever a new virtual machine is requested.

## 2. Problem Statement

Modern cloud platforms such as AWS, Microsoft Azure, and Google Cloud use distributed infrastructure to provide computing resources on demand.

Understanding how these platforms manage virtualization, workload placement, resource utilization, and security requires knowledge of their underlying components.

This project addresses that learning objective by developing a miniature multi-node cloud environment with automated workload placement and basic security controls.

## 3. Project Objectives

- Build a multi-node cloud infrastructure.
- Configure a centralized Controller Node and multiple Compute Nodes.
- Implement virtualization using KVM/QEMU and libvirt.
- Automate virtual machine provisioning using Bash scripts.
- Develop a custom scheduler using CPU utilization and available RAM.
- Establish secure SSH key-based communication.
- Implement firewall rules and guest workload isolation.
- Monitor resource utilization and security events.
- Maintain logs of workload placement and system activities.

## 4. Proposed System Architecture

The system consists of the following components:

### Controller Node
- Receives virtual machine creation requests.
- Collects resource information from compute nodes.
- Executes the custom scheduling algorithm.
- Selects an appropriate compute node.
- Maintains management and monitoring logs.

### Compute Nodes
- Execute virtual machine workloads.
- Run KVM/QEMU virtualization.
- Manage virtual machines through libvirt.
- Report CPU and memory availability to the controller.

### Custom Scheduler
The scheduler evaluates compute nodes using at least two resource metrics:

1. CPU utilization.
2. Available RAM.

It selects a suitable node based on resource availability and workload requirements.

### Security and Monitoring
- SSH key-based authentication.
- Firewall configuration.
- Guest network isolation.
- Unauthorized login monitoring.
- Resource exhaustion detection.
- Centralized activity logging.

## 5. Technology Stack

| Component | Technology |
|---|---|
| Hosting environment | AWS EC2 (proposed) |
| Operating system | Ubuntu Server |
| Virtualization | KVM/QEMU |
| VM management | libvirt / virsh |
| Automation | Bash |
| Scheduler | Custom Bash-based scheduler |
| Communication | SSH |
| Networking | Linux bridges / virtual networks |
| Security | Linux firewall rules |
| Monitoring | Linux system utilities and custom scripts |
| Version control | Git / GitHub |

## 6. Proposed Deployment Topology

The proposed deployment uses nested virtualization on an AWS EC2 host, subject to compatibility and cost verification.

- One Controller Node.
- Two Compute Nodes.
- A management network for node communication.
- An isolated guest network for virtual machine workloads.

The Controller Node manages the Compute Nodes through secure SSH communication.

Each Compute Node runs its own hypervisor and executes assigned virtual machines.

**Note:** The deployment architecture is proposed and will be updated after infrastructure validation.

## 7. Project Workflow

1. A user submits a virtual machine creation request.
2. The Controller Node receives the request.
3. The Controller collects CPU and RAM information from available Compute Nodes.
4. The Scheduler evaluates the available resources.
5. The Scheduler selects a suitable Compute Node.
6. The selected node creates the virtual machine using libvirt.
7. The system records the scheduling decision.
8. Monitoring and security mechanisms observe system activity.

## 8. Repository Structure

```text
mini-cloud-infrastructure/
├── architecture/
├── deployment/
├── controller/
├── compute/
├── hypervisor/
├── networking/
├── security/
├── monitoring/
├── config/
├── tests/
├── logs/
├── results/
├── docs/
├── demo/
├── .gitignore
└── README.md
```

## 9. Implementation Roadmap

- [ ] Project architecture and infrastructure setup
- [ ] Controller and Compute Node configuration
- [ ] Secure node communication
- [ ] KVM/QEMU and libvirt configuration
- [ ] Automated VM provisioning
- [ ] CPU/RAM-based custom scheduling
- [ ] Network configuration and guest isolation
- [ ] Security monitoring and audit logging
- [ ] Integration and testing
- [ ] Final documentation and demonstration

## 10. Testing and Evaluation

The project will be evaluated through:

- Successful communication between nodes.
- Successful virtual machine creation and execution.
- Correct scheduler decisions based on resource metrics.
- Verification of SSH authentication.
- Verification of network isolation.
- Monitoring and detection of security events.
- Scheduler and workload placement logs.

## 11. Deliverables

- Source code and automation scripts.
- System and network architecture diagrams.
- Project report.
- Testing results and logs.
- Live project demonstration.

## 12. Project Information

**Project:** Mini Cloud Infrastructure  
**Implementation Track:** Track A  
**Primary Language:** Bash  
**Virtualization:** KVM/QEMU  
**VM Management:** libvirt/virsh  
**Version Control:** GitHub

---

*This project is developed for academic learning and demonstration of fundamental cloud computing concepts.*