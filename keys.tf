# ==============================================================================
# Native OpenTofu Cryptographic Key Management (Zero Python Dependencies)
# Generates Ed25519 keypairs for Operator Client and Bastion Host
# Pre-pins .keys/known_hosts to enforce StrictHostKeyChecking=yes
# ==============================================================================

# 1. Operator Client Keypair (used by OpenTofu & Ansible to access Bastion & SNO)
resource "tls_private_key" "operator" {
  algorithm = "ED25519"
}

# 2. Bastion SSH Host Keypair (injected into cloud-init prior to first boot)
resource "tls_private_key" "bastion_host" {
  algorithm = "ED25519"
}

# 3. Persist Operator Private Key locally (mode 0600)
resource "local_file" "operator_private_key" {
  content         = tls_private_key.operator.private_key_openssh
  filename        = "${path.module}/.keys/id_ed25519_operator"
  file_permission = "0600"
}

# 4. Persist Operator Public Key locally (mode 0644)
resource "local_file" "operator_public_key" {
  content         = "${trimspace(tls_private_key.operator.public_key_openssh)} sno-operator-client-admin\n"
  filename        = "${path.module}/.keys/id_ed25519_operator.pub"
  file_permission = "0644"
}

# 5. Persist Bastion Host Public Key locally (mode 0644)
resource "local_file" "bastion_host_public_key" {
  content         = "${trimspace(tls_private_key.bastion_host.public_key_openssh)} sno-bastion-ssh-host-key\n"
  filename        = "${path.module}/.keys/ssh_host_ed25519_key.pub"
  file_permission = "0644"
}

# 6. Pre-pin known_hosts file for strict host key verification without prompt bypass
resource "local_file" "known_hosts" {
  content = join("\n", [
    "${var.bastion_ip} ${trimspace(tls_private_key.bastion_host.public_key_openssh)}",
    "sno-bastion ${trimspace(tls_private_key.bastion_host.public_key_openssh)}",
    "sno-bastion.${var.network_domain} ${trimspace(tls_private_key.bastion_host.public_key_openssh)}",
    "${var.bastion_ip},sno-bastion,sno-bastion.${var.network_domain} ${trimspace(tls_private_key.bastion_host.public_key_openssh)}",
    ""
  ])
  filename        = "${path.module}/.keys/known_hosts"
  file_permission = "0644"
}
