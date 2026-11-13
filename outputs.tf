# ==============================================================================
# OpenShift SNO Lab Infrastructure Outputs
# ==============================================================================

output "network_name" {
  description = "Dedicated isolated libvirt network name"
  value       = libvirt_network.ocp_net.name
}

output "bridge_interface" {
  description = "Dedicated bridge interface name on host"
  value       = var.bridge_name
}

output "network_cidr" {
  description = "CIDR range of the isolated lab network"
  value       = var.network_cidr
}

output "storage_pool_name" {
  description = "NVMe libvirt storage pool name"
  value       = libvirt_pool.nvme_pool.name
}

output "storage_pool_path" {
  description = "NVMe filesystem mount path"
  value       = var.nvme_storage_path
}

output "bastion_vm_name" {
  description = "Name of the Helper-Bastion VM"
  value       = libvirt_domain.bastion.name
}

output "bastion_ip" {
  description = "Static IP of the Helper-Bastion VM"
  value       = var.bastion_ip
}

output "bastion_ssh_command" {
  description = "Secure SSH command with strict host key verification using pre-pinned known_hosts"
  value       = "ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${path.module}/.keys/known_hosts -i ${path.module}/.keys/id_ed25519_operator -o ProxyJump=t5600 ${var.admin_username}@${var.bastion_ip}"
}

output "ssh_identity_assets" {
  description = "Native OpenTofu Ed25519 cryptographic key assets"
  value = {
    operator_public_key     = tls_private_key.operator.public_key_openssh
    operator_private_key    = local_file.operator_private_key.filename
    bastion_host_public_key = tls_private_key.bastion_host.public_key_openssh
    known_hosts_file        = local_file.known_hosts.filename
  }
}

output "sno_vm_name" {
  description = "Name of the SNO Target VM"
  value       = libvirt_domain.sno.name
}

output "sno_ip" {
  description = "Pinned static IP of the SNO node"
  value       = var.sno_ip
}

output "sno_mac" {
  description = "Pinned static MAC address of the SNO node"
  value       = var.sno_mac
}

output "cluster_endpoints" {
  description = "Key cluster endpoints handled by dnsmasq and haproxy"
  value = {
    api     = "https://api.${var.network_domain}:6443"
    api_int = "https://api-int.${var.network_domain}:22623"
    apps    = "*.apps.${var.network_domain}"
    stats   = "http://${var.bastion_ip}:9000"
  }
}

output "discovery_iso_path" {
  description = "Resolved path to the Assisted Installer Discovery ISO"
  value       = local.effective_discovery_iso_path
}

output "next_steps" {
  description = "Next operational actions to proceed with deployment"
  value       = <<-EOT
    1. Provision Bastion Services:
       ansible-playbook -i ansible/inventory.ini ansible/playbook.yml

    2. Verify Bastion Split DNS & HAProxy:
       ./scripts/verify_bastion.sh

    3. Boot & Rendezvous SNO:
       # If redhat_offline_token was provided, ISO was fetched and attached automatically.
       # If manual, run: make attach-iso ISO=/mnt/nvme_data/ocp_storage/discovery-image.iso
       make start-sno
       make wait-rendezvous

    4. Direct Access to SNO:
       make ssh-sno
  EOT
}
