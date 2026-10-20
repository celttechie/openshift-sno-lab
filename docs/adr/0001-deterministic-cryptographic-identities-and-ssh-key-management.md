# 1. Native Declarative Cryptographic Identities & Strict SSH Verification

Date: 2026-10-20

## Status
Accepted (Supersedes external script derivation)

## Context
In virtualized test environments and automated lab deployments, peer VMs (such as the Helper-Bastion) are frequently created, destroyed, and rebuilt from scratch.

When SSH host keys are generated randomly on each boot, operators encounter `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!`. This routinely induces dangerous engineering anti-patterns, such as setting `StrictHostKeyChecking no` and `UserKnownHostsFile /dev/null` in Ansible automation, Makefile shortcuts, and verification scripts. This compromises transport security and leaves systems vulnerable to man-in-the-middle (MITM) attacks.

Conversely, checking static private keys into Git repositories introduces serious credential leakage risks.

Furthermore, introducing external scripting languages (such as Python with third-party cryptography libraries) into an Infrastructure-as-Code repository introduces runtime fragility (virtual environment setup, pip dependencies, PEP 668 externally-managed environment blocks).

## Decision
1. **Native OpenTofu Key Generation**: Use OpenTofu's native `hashicorp/tls` provider (`resource "tls_private_key"`) to declaratively generate Ed25519 keypairs for:
   - **Operator Client Identity (`tls_private_key.operator`)**: Injected into Bastion cloud-init `ssh_authorized_keys` and used by Ansible and the operator.
   - **Bastion Host Key (`tls_private_key.bastion_host`)**: Injected into Bastion cloud-init (`ssh_keys`) prior to first boot.
2. **Local Key Persistence & Known-Hosts Pinning**: Use OpenTofu's native `hashicorp/local` provider (`resource "local_file"`) to persist:
   - `.keys/id_ed25519_operator` (permissions `0600`)
   - `.keys/id_ed25519_operator.pub` (permissions `0644`)
   - `.keys/known_hosts` (permissions `0644`) pre-pinned with the Bastion's IP, short hostname, and FQDN.
3. **Strict Host Verification Everywhere**: Enforce `StrictHostKeyChecking=yes` and `host_key_checking = True` across Ansible (`ansible.cfg`, `inventory.ini`), the Makefile, and all verification scripts.
4. **Zero Python Dependencies**: Eliminate external Python scripts and virtual environments from the deployment pipeline. Key generation is 100% self-contained within `tofu apply`.
5. **Git Safety**: Strictly ignore `.keys/` and private key patterns in `.gitignore`.

## Consequences
- **Zero External Prerequisites**: Works out of the box on any system with OpenTofu; no Python, pip, or virtual environment required.
- **Zero MITM Risk**: Strict host key validation is enforced without manual prompt bypasses.
- **Zero Secrets in Git**: All private keys are generated dynamically and stored locally in `.keys/` (gitignored).
- **Declarative Lifecycle**: OpenTofu tracks the keys in state and cleans them up cleanly during `tofu destroy`.
