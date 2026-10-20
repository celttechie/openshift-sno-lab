# ==============================================================================
# Helper-Bastion VM Domain & Cloud-Init Definition
# Provides DNS (dnsmasq), Ingress/API reverse-proxy (haproxy), and OCP tooling
# ==============================================================================

resource "libvirt_cloudinit_disk" "bastion_cloudinit" {
  name = "${var.bastion_vm_name}-cloudinit.iso"
  pool = libvirt_pool.nvme_pool.name

  user_data = templatefile("${path.module}/templates/cloud_init_bastion.cfg", {
    hostname       = var.bastion_vm_name
    domain         = var.network_domain
    admin_username = var.admin_username
    ssh_public_key = file(pathexpand(var.ssh_public_key_path))
  })

  network_config = templatefile("${path.module}/templates/network_config_bastion.cfg", {
    mac_address     = var.bastion_mac
    ip_address      = var.bastion_ip
    cidr_prefix     = split("/", var.network_cidr)[1]
    gateway_address = var.network_gateway
    domain          = var.network_domain
  })
}

resource "libvirt_domain" "bastion" {
  name      = var.bastion_vm_name
  memory    = var.bastion_memory_mb
  vcpu      = var.bastion_vcpu
  autostart = true

  cpu {
    mode = "host-passthrough"
  }

  cloudinit = libvirt_cloudinit_disk.bastion_cloudinit.id

  network_interface {
    network_id     = libvirt_network.ocp_net.id
    mac            = var.bastion_mac
    addresses      = [var.bastion_ip]
    wait_for_lease = false
  }

  disk {
    volume_id = libvirt_volume.bastion_root.id
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  graphics {
    type        = "spice"
    listen_type = "address"
    autoport    = true
  }
}
