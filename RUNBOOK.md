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

The SNO node requires a live discovery image generated by the Red Hat Assisted Installer to boot and bootstrap the cluster. In OpenShift CoreOS (RHCOS), SSH public keys must be injected into the Discovery ISO at generation time so that the immutable OS authorizes the `core` user upon first boot.

### Option 1 (Gold Standard): Zero-Touch Declarative via OpenTofu

OpenTofu can manage the entire Assisted Installer lifecycle declaratively via its REST API:

1. Obtain your offline API token at **[console.redhat.com/openshift/token](https://console.redhat.com/openshift/token)**.
2. Add your token to `terraform.tfvars`:
   ```hcl
   redhat_offline_token = "ey..."
   sno_autostart        = true
   ```
3. Run:
   ```bash
   tofu apply
   ```
   OpenTofu will:
   - Generate native Ed25519 operator SSH keypairs (`.keys/id_ed25519_operator`).
   - Authenticate against Red Hat SSO and the Assisted Installer API.
   - Register the `sno.lab.local` cluster with the embedded SSH public keys.
   - Stream the Discovery ISO directly to `/mnt/nvme_data/ocp_storage/discovery-image.iso` on `t5600`.
   - Mount the ISO onto the VirtIO-SCSI controller and power on the VM.

### Option 2: Standalone API Script / Make Target

If you prefer to generate and download the ISO without embedding the token into OpenTofu:
```bash
make fetch-iso TOKEN="<your_offline_token>"
make attach-iso ISO=/mnt/nvme_data/ocp_storage/discovery-image.iso
make start-sno
```
*(This script automatically bundles both `.keys/id_ed25519_operator.pub` and your local `~/.ssh/id_ed25519.pub` so both keys work for the `core` user).*

### Option 3: Via Red Hat Hybrid Cloud Console (Assisted Installer Web UI)

If generating manually via the web browser:

1. Open **[console.redhat.com/openshift/assisted-installer/clusters](https://console.redhat.com/openshift/assisted-installer/clusters)** in your browser (free with any Red Hat account).
2. Click **Create Cluster**:
   - **Cluster Name**: `sno`
   - **Base Domain**: `lab.local`
   - **OpenShift Version**: Select desired version (e.g., `4.16` or latest stable).
   - **CPU Architecture**: `x86_64`
   - Check the box: **Install single node OpenShift (SNO)**.
   - Leave "Integrate with your virtualization platform" **unchecked** (User-Managed / KVM).
   - Click **Next**.
3. Under **Host Discovery**, click **Add Host**:
   - **Provisioning Type**: Select **Full image** (recommended for homelabs; embeds the live rootfs directly into the ISO, avoiding internet download bottlenecks during initial boot).
   - **SSH Public Key**: Provide the deterministic operator key generated during OpenTofu initialization:
     ```bash
     cat .keys/id_ed25519_operator.pub
     ```
     > [!IMPORTANT]
     > **Why did SSH key authentication fail for the `core` user previously?**
     > RHCOS does not use passwords. Public keys MUST be supplied during ISO generation so Ignition places them into `/var/home/core/.ssh/authorized_keys.d/`. You can paste multiple keys separated by newlines:
     > ```bash
     > cat .keys/id_ed25519_operator.pub
     > cat ~/.ssh/id_ed25519.pub
     > ```
   - Click **Generate Discovery ISO**, then click **Download Discovery ISO**.
4. Once downloaded to your workstation (e.g., `~/Downloads/*-discovery.iso`), copy it to the hypervisor NVMe pool:
   ```bash
   scp ~/Downloads/*-discovery.iso t5600:/mnt/nvme_data/ocp_storage/discovery-image.iso
   ```
5. Attach the ISO to the VM:
   ```bash
   make attach-iso ISO=/mnt/nvme_data/ocp_storage/discovery-image.iso
   ```

### Option 4: Via Assisted Installer CLI (`aicli`) from the Bastion
Connect to the Bastion:
```bash
make ssh-bastion
```
Run `aicli` to create and fetch the discovery ISO:
```bash
# Provide Red Hat offline API token (from console.redhat.com/openshift/token)
export AI_OFFLINE_TOKEN="<your_offline_token>"
aicli create cluster sno -P sno=true -P base_dns_domain=lab.local -P openshift_version=4.16 -P ssh_public_key="$(cat /home/bjarrett/.ssh/authorized_keys)"
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
Launch the automated convergence monitor:
```bash
make wait-rendezvous
```

The rendezvous monitor executes three automated stages:
1. **Network Discovery**: Detects when SNO boots live ISO and grabs `192.168.150.50`.
2. **RHCOS Disk Write & Auto-Ejection**: Detects when CoreOS finishes writing to NVMe (`/dev/vda`), automatically detaches/ejects the discovery ISO, and resets the VM so it boots cleanly from disk.
3. **API Rendezvous & Kubeconfig Sync**: Detects when `kube-apiserver` on `https://192.168.150.50:6443` responds, automatically pulls the admin kubeconfig to `sno-bastion:~/.kube/config` and local `./.kube/config`, and queries `oc get nodes` and `oc get clusteroperators`.

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

### Step 6.4: Direct SSH Access to SNO Node (`core` User)
The SNO node runs Red Hat Enterprise Linux CoreOS (RHCOS) with an immutable root filesystem. The default administrative user is `core`.

Because `sno-node` (`192.168.150.50`) is on the isolated private KVM network on `t5600`, SSH access from your workstation requires using the `t5600` jump host.

From the repository root on your workstation:
```bash
# Using the convenience Makefile target (uses .keys/id_ed25519_operator):
make ssh-sno

# Or directly via SSH:
ssh -i .keys/id_ed25519_operator -o ProxyJump=t5600 core@192.168.150.50
```
*(Note: If you pasted your personal `~/.ssh/id_ed25519.pub` into the Assisted Installer ISO alongside the operator key, `ssh -o ProxyJump=t5600 core@192.168.150.50` will also authenticate directly with your default workstation key).*

---

## 8. Teardown / Clean Up

When you are finished with the lab and want to release resources:
```bash
make destroy
```
OpenTofu will gracefully delete VMs, volumes, and the isolated libvirt network without affecting any preexisting VMs or networks on the hypervisor host.
