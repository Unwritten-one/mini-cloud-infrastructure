# Local WSL2 Deployment Architecture

```mermaid
flowchart TB
    LAP["Windows 11 Laptop"]

    subgraph WSL["WSL2 - Ubuntu 24.04"]
        HV["KVM / QEMU / libvirt"]

        subgraph INFRA["Infrastructure VMs"]
            C["Controller VM"]
            N1["Compute VM 1"]
            N2["Compute VM 2"]
        end

        HV --> C
        HV --> N1
        HV --> N2

        N1 --> VM1["Guest VMs"]
        N2 --> VM2["Guest VMs"]
    end

    LAP <-->|"Local access"| WSL
    LAP <-->|"Git Push / Pull"| GH["GitHub Repository"]
    GH -.->|"Code deployment"| C
```

## Deployment Notes

- Windows 11 runs WSL2 with Ubuntu 24.04.
- KVM, QEMU and libvirt provide host-level virtualization.
- One Controller VM manages two Compute VMs.
- The Controller monitors Compute resources and schedules guest VM placement.
- Compute VMs create and manage guest VMs using KVM and libvirt.
- GitHub stores the project source code.
- Nested KVM virtualization is enabled on Compute VMs, with local SSH port forwarding (`2221`–`2299`) providing direct guest access.
