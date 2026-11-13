# OpenShift Single Node OpenShift (SNO) Lab

[![Status](https://img.shields.io/badge/Status-Alpha%20%7C%20Under%20Test-orange.svg)](RUNBOOK.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![OpenTofu](https://img.shields.io/badge/OpenTofu-%3E%3D1.6.0-blue.svg?logo=opentofu)](versions.tf)
[![Ansible](https://img.shields.io/badge/Ansible-2.16%2B-black.svg?logo=ansible)](ansible/playbook.yml)
[![OpenShift](https://img.shields.io/badge/OpenShift-SNO%204.16%2B-red.svg?logo=redhatopenshift)](https://console.redhat.com/openshift)
[![Hypervisor](https://img.shields.io/badge/Hypervisor-KVM%20%2F%20libvirt-informational.svg?logo=linux)](main.tf)
[![Host Target](https://img.shields.io/badge/Host-Dell%20Precision%20T5600-lightgrey.svg)](scripts/precheck.sh)
[![Storage](https://img.shields.io/badge/Storage-NVMe%20PCIe%20Adapter-success.svg)](storage.tf)
[![Network Isolation](https://img.shields.io/badge/Network-192.168.150.0%2F24%20(virbr--ocp)-blueviolet.svg)](network.tf)
[![Security: Native Ed25519 Keys](https://img.shields.io/badge/Security-Native%20Ed25519%20Keys-purple.svg)](keys.tf)

An automated, isolated Single Node OpenShift (SNO) lab deployment on a headless **Dell Precision T5600** KVM hypervisor host using the **Peer Bastion** architecture via KVM/libvirt, OpenTofu, and Ansible.

Designed to run **strictly alongside existing libvirt networks, storage pools, and sandbox VMs** without modifying or interfering with default host bridges (`virbr0`, `br0`, `virbr1`) or existing production/sandbox workloads.

---

## Architecture Overview

```
                                          +-------------------------------------------------------------+
                                          |                     Dell Precision T5600                    |
                                          |  Host OS: Ubuntu Linux (KVM/QEMU/libvirt stack)             |
                                          |  Fast Storage: /mnt/nvme_data (etcd fsync < 10ms)           |
                                          +-------------------------------------------------------------+
                                                                         |
                                                 [libvirt network: ocp-lab-net / virbr-ocp]
                                                 [CIDR: 192.168.150.0/24 (NAT Gateway: .1)]
                                                                 |
                                +--------------------------------+--------------------------------+
                                |                                                                 |
                                v                                                                 v
              +-----------------------------------+                             +-----------------------------------+
              |      Helper-Bastion VM            |                             |        Target SNO Node VM         |
              |  Hostname: sno-bastion            |                             |  Hostname: sno-node               |
              |  IP: 192.168.150.10               |                             |  IP: 192.168.150.50               |
              |  MAC: 52:54:00:15:00:10           |                             |  MAC: 52:54:00:15:00:50           |
              |  vCPU: 2 | RAM: 4 GB              |                             |  vCPU: 8 | RAM: 32 GB             |
              |  Disk: 30 GB (NVMe pool)          |                             |  Disk: 120 GB (NVMe, cache=none)  |
              |  OS: Rocky Linux 9                |                             |  OS: Red Hat Enterprise Linux     |
              |  Services:                        |                             |      CoreOS (RHCOS)               |
              |   - dnsmasq (split-DNS)           |                             |                                   |
              |   - haproxy (API/Ingress reverse) |                             |  Ports / Roles:                   |
              |   - oc, kubectl, aicli            |                             |   - 6443 (kube-apiserver)         |
              +-----------------------------------+                             |   - 22623 (machine-config)        |
                                                                                |   - 80/443 (router ingress)       |
                                                                                +-----------------------------------+
```

### Key Design Pillars
- **Flat Peer-VM Topology**: Bastion and SNO reside as peer virtual machines on the same dedicated libvirt network (`ocp-lab-net`), avoiding nested virtualization and CRC overhead.
- **NVMe Low-Latency Caching**: SNO root disk is allocated on the dedicated NVMe PCIe adapter pool (`/mnt/nvme_data`) with XSLT driver overrides (`cache=none`, `io=threads`) to satisfy etcd fsync latency (<10ms p99).
- **Declarative Cryptographic Security**: OpenTofu natively generates isolated Ed25519 keypairs for the operator and Bastion host (`tls_private_key`), pre-pinning `.keys/known_hosts` so `StrictHostKeyChecking=yes` is strictly enforced with zero MITM vulnerabilities, zero private keys stored in Git, and zero external Python dependencies.
- **Zero Collision Guarantee**: Uses custom bridge `virbr-ocp` and subnet `192.168.150.0/24`, completely isolated from `virbr0`, `br0`, or `virbr1`.
- **Automated Split-DNS & Reverse Proxy**: Bastion handles wildcard resolution (`*.apps.sno.lab.local`, `api.sno.lab.local`) and load balances ingress and control-plane traffic.

---

## Network & Resource Map

| Component | Hostname / Identifier | IP Address | MAC Address | Sizing | Role |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Hypervisor Host** | `t5600` | `192.168.9.110` / `192.168.150.1` | - | 24 vCPUs / 110 GB RAM | Bare-metal KVM host |
| **Isolated Bridge** | `virbr-ocp` | `192.168.150.1/24` | - | NAT Mode | Gateway for OCP lab |
| **Helper Bastion** | `sno-bastion` | `192.168.150.10` | `52:54:00:15:00:10` | 2 vCPU / 4 GB RAM / 30 GB | `dnsmasq`, `haproxy`, `oc` |
| **SNO Target Node** | `sno-node` | `192.168.150.50` | `52:54:00:15:00:50` | 8 vCPU / 32 GB RAM / 120 GB | Single Node OpenShift |

### Cluster DNS & Endpoints

| DNS Record | Target IP | Port(s) | Description |
| :--- | :--- | :--- | :--- |
| `api.sno.lab.local` | `192.168.150.50` | `6443/tcp` | Kubernetes / OpenShift API Server |
| `api-int.sno.lab.local` | `192.168.150.50` | `22623/tcp` | Machine Config Server |
| `*.apps.sno.lab.local` | `192.168.150.50` | `80/tcp`, `443/tcp` | OpenShift Ingress Router (Apps / Console) |
| `stats.sno.lab.local` | `192.168.150.10` | `9000/tcp` | HAProxy Health & Traffic Dashboard |

---

## Project Structure

```
openshift-sno-lab/
├── Makefile                                # Lifecycle automation targets
├── README.md                               # Project documentation & overview
├── RUNBOOK.md                              # Detailed step-by-step operational runbook
├── .gitignore                              # Git exclusion rules
├── versions.tf                             # OpenTofu provider configuration
├── variables.tf                            # Configurable parameters & sizing
├── main.tf                                 # Provider setup
├── keys.tf                                 # Native OpenTofu Ed25519 cryptographic key management
├── network.tf                              # ocp-lab-net isolated libvirt network
├── storage.tf                              # NVMe PCIe storage pool & volumes
├── bastion.tf                              # Helper-Bastion VM & cloud-init
├── sno.tf                                  # SNO target VM & disk cache tuning
├── outputs.tf                              # Useful output variables & endpoints
├── terraform.tfvars.example                # Example configuration values
├── docs/
│   └── adr/
│       └── 0001-deterministic-cryptographic-identities-and-ssh-key-management.md
├── templates/
│   ├── cloud_init_bastion.cfg              # Cloud-init user-data for Rocky 9
│   ├── network_config_bastion.cfg          # Cloud-init network configuration
│   └── disk_cache_tuning.xsl               # XSLT for cache=none & io=threads
├── scripts/
│   ├── precheck.sh                         # Host audit (RAM, NVMe, CIDR collision check)
│   ├── attach_iso.sh                       # Assisted Installer ISO attachment utility
│   ├── verify_bastion.sh                   # Split-DNS & HAProxy verification suite
│   └── wait_for_rendezvous.sh              # SNO boot & API rendezvous convergence monitor
└── ansible/
    ├── ansible.cfg                         # Ansible defaults & SSH pipelining
    ├── inventory.ini                       # Bastion inventory with ProxyJump
    ├── playbook.yml                        # Provisioning playbook
    └── roles/
        ├── common/                         # Base system packages & firewalld
        ├── dnsmasq/                        # Split-DNS daemon configuration
        ├── haproxy/                        # Ingress & API TCP proxy
        └── ocp_tools/                      # oc, kubectl, openshift-install, aicli
```

---

## Quickstart Guide

### 1. Pre-Flight Inspection
Audit hypervisor memory headroom, NVMe fast storage, and check for network CIDR collisions:
```bash
make precheck
```

### 2. OpenTofu Infrastructure Deployment
```bash
make init
make plan
make apply
```

### 3. Provision Helper-Bastion Services
Configure `dnsmasq`, `haproxy`, and download OpenShift client tools:
```bash
make provision-bastion
make verify-bastion
```

### 4. Boot SNO via Discovery ISO
Choose between zero-touch automated API provisioning or manual ISO attachment:

- **Automated (Zero-Touch via OpenTofu)**: Set `redhat_offline_token = "..."` and `sno_autostart = true` in `terraform.tfvars`. OpenTofu will automatically create the cluster in the Assisted Installer API, stream the ISO directly to the NVMe pool with your SSH keys embedded, and boot the VM.
- **Assisted Installer API Target**: Run `make fetch-iso TOKEN="<your_token>"` to stream the ISO directly to the hypervisor.
- **Manual Web Console**: Download from [console.redhat.com/openshift/assisted-installer/clusters](https://console.redhat.com/openshift/assisted-installer/clusters) (embedding `.keys/id_ed25519_operator.pub`), transfer to `t5600:/mnt/nvme_data/ocp_storage/discovery-image.iso`, and attach:
  ```bash
  make attach-iso ISO=/mnt/nvme_data/ocp_storage/discovery-image.iso
  make start-sno
  ```

### 5. Track Installation & Rendezvous
Launch the automated rendezvous monitor:
```bash
make wait-rendezvous
```
The monitor will automatically detect CoreOS disk installation, eject the ISO, reboot into NVMe, and sync the admin kubeconfig to `sno-bastion:~/.kube/config` and `./.kube/config`.

To open an SSH session directly into the SNO node:
```bash
make ssh-sno
```

For complete step-by-step guidance including web console access and post-installation operations, refer to the [RUNBOOK.md](file:///home/bjarrett/Projects/openshift-sno-lab/RUNBOOK.md).
