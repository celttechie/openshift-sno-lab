# OpenShift Single Node OpenShift (SNO) Deployment Runbook

This runbook guides operators step-by-step through deploying an isolated Single Node OpenShift (SNO) lab on a bare-metal Dell Precision T5600 KVM host using the **Peer Bastion Architecture**.

---

## 1. Architecture & Network Topology

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

---

## 2. Phase 1: Host Inspection & Pre-Flight Audit

Before deploying any virtualization assets, verify that the Dell Precision T5600 host satisfies all RAM, CPU, NVMe latency, and subnet requirements.

Run the audit script:

```bash
make precheck
# Or directly:
./scripts/precheck.sh --remote t5600
```

The script verifies:
1. **SSH & KVM Access**: Confirms key-based authentication and `/dev/kvm` hardware virtualization flags.
2. **Host RAM Headroom**: Ensures `>= 36 GB` available RAM (SNO 32 GB + Bastion 4 GB).
3. **CPU Allocation**: Ensures `>= 10 vCPUs` are available across physical cores.
4. **NVMe Storage Pool**: Verifies `/mnt/nvme_data` exists and has `>= 160 GB` free disk space.
5. **Network Collisions**: Audits `virsh net-list --all` and host routes to guarantee `192.168.150.0/24` and `virbr-ocp` do not conflict with existing networks (`default`, `host-bridge`, `airgap-sandbox-net`).
6. **Local Tooling**: Confirms `tofu`, `ansible-playbook`, `virsh`, and `ssh`.

---

## 3. Phase 2: OpenTofu Infrastructure Deployment

### Step 2.1: Initialize OpenTofu
```bash
make init
```

### Step 2.2: Review & Apply Execution Plan
```bash
make plan
make apply
```

During `apply`, OpenTofu executes the following:
1. Defines the `ocp_nvme` storage pool pointing to `/mnt/nvme_data/ocp_storage`.
2. Creates the `ocp-lab-net` libvirt network with bridge `virbr-ocp` (192.168.150.0/24) and static DHCP reservations.
3. Downloads the Rocky Linux 9 cloud image and creates the 30 GB Bastion root volume.
4. Provisions the 120 GB SNO root volume on NVMe.
5. Deploys `sno-bastion` with cloud-init (network config + SSH keys) and boots it.
6. Defines the `sno-node` domain shell with XSLT disk cache tuning (`cache=none`, `io=threads`). The SNO VM remains powered off pending ISO attachment.

---

## 4. Phase 3: Bastion Provisioning via Ansible

Once `sno-bastion` is booted, configure split-DNS, HAProxy reverse proxy, and OpenShift CLI tools:

```bash
make provision-bastion
```

The playbook executes three roles:
1. **`dnsmasq`**:
   - Resolves `api.sno.lab.local` -> `192.168.150.50`
   - Resolves `api-int.sno.lab.local` -> `192.168.150.50`
   - Resolves `*.apps.sno.lab.local` -> `192.168.150.50`
   - Forwards external queries upstream to host gateway (`192.168.150.1`) and `1.1.1.1`.
2. **`haproxy`**:
   - Proxies Port 6443 (API), 22623 (Machine Config), 80 (HTTP), 443 (HTTPS) to `192.168.150.50`.
   - Exposes stats dashboard at `http://192.168.150.10:9000/`.
3. **`ocp_tools`**:
   - Downloads `oc`, `kubectl`, and `openshift-install` into `/usr/local/bin/`.
   - Installs `aicli` (Assisted Installer CLI) via pip.
   - Configures tab autocompletion.

### Step 3.2: Verify Bastion Services
```bash
make verify-bastion
```

Output should show `[PASS]` for all DNS lookups, open ports, and installed CLI tools.

---

## 5. Phase 4: Generate Discovery ISO & Attach to SNO VM

### Option A: Via Red Hat Hybrid Cloud Console (Assisted Installer)
1. Go to [console.redhat.com/openshift/assisted-installer/clusters](https://console.redhat.com/openshift/assisted-installer/clusters).
2. Click **Create Cluster**.
3. Fill in cluster metadata:
   - **Cluster Name**: `sno`
   - **Base Domain**: `lab.local`
   - Select: **Install single node OpenShift (SNO)**.
4. Click **Add Host** -> **Generate Discovery ISO**:
   - Select **Minimal image** or **Full image**.
   - Paste your SSH public key (`~/.ssh/id_ed25519.pub`).
5. Download the ISO and copy it to the hypervisor host:
   ```bash
   scp ~/Downloads/discovery-image.iso t5600:/mnt/nvme_data/ocp_storage/discovery-image.iso
   ```

### Option B: Via Assisted Installer CLI (`aicli`) from the Bastion
Connect to the Bastion:
```bash
make ssh-bastion
```
Run `aicli` to create and fetch the discovery ISO:
```bash
# Provide Red Hat API token
export AI_OFFLINE_TOKEN="<your_offline_token_from_cloud.redhat.com>"
aicli create cluster sno -P sno=true -P base_dns_domain=lab.local -P openshift_version=4.16
aicli download iso sno --path /mnt/nvme_data/ocp_storage/discovery-image.iso
```

### Attach ISO to the SNO VM:
```bash
make attach-iso ISO=/mnt/nvme_data/ocp_storage/discovery-image.iso
```

---

## 6. Phase 5: Power On SNO & Monitor Rendezvous

### Step 5.1: Start the SNO VM
```bash
make start-sno
```

To watch the live boot and discovery process via serial console:
```bash
make console-sno
# (Press Ctrl + ] to exit the console)
```

### Step 5.2: Track Installation & Cluster Rendezvous
Launch the convergence monitor:
```bash
make wait-rendezvous
```

The rendezvous monitor executes three stages:
1. **Network Discovery**: Detects when SNO boots live ISO and grabs `192.168.150.50`.
2. **RHCOS Disk Write & Reboot**: SNO downloads the CoreOS image and writes it to `/dev/vda` (on NVMe).
3. **API Rendezvous**: Detects when `kube-apiserver` on `https://192.168.150.50:6443` responds.

---

## 7. Phase 6: Post-Installation Validation & Day-2

### Step 6.1: Access the Cluster
Connect to the Bastion:
```bash
make ssh-bastion
```

Download `kubeconfig` and set environment:
```bash
mkdir -p ~/.kube
# If using aicli:
aicli download kubeconfig sno --path ~/.kube/config
# Or copy kubeconfig downloaded from console.redhat.com to ~/.kube/config

export KUBECONFIG=~/.kube/config
```

### Step 6.2: Verify Cluster Health
```bash
# Check single node status
oc get nodes -o wide

# Check ClusterOperators (all should reach AVAILABLE=True, PROGRESSING=False)
oc get co

# Check cluster version
oc get clusterversion
```

### Step 6.3: Web Console Access
Access the OpenShift web console from your workstation browser:
- URL: `https://console-openshift-console.apps.sno.lab.local`
- Workstation `/etc/hosts` entry (or configure DNS forwarder):
  ```
  192.168.150.10  api.sno.lab.local console-openshift-console.apps.sno.lab.local oauth-openshift.apps.sno.lab.local
  ```
- Or route traffic through the bastion jump host via SSH SOCKS proxy:
  ```bash
  ssh -D 1080 -q -C -N -o ProxyJump=t5600 bjarrett@192.168.150.10
  ```

---

## 8. Teardown / Clean Up

When you are finished with the lab and want to release resources:
```bash
make destroy
```
OpenTofu will gracefully delete VMs, volumes, and the isolated libvirt network without affecting any preexisting VMs or networks on the hypervisor host.
