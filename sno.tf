# ==============================================================================
# Single Node OpenShift (SNO) Target VM Shell
# Sized with 8 vCPUs, 32 GB RAM, and 120 GB NVMe disk with cache/io tuning
# Ready for Red Hat Assisted Installer Live Discovery ISO
# ==============================================================================

locals {
  effective_discovery_iso_path = var.sno_discovery_iso_path != "" ? var.sno_discovery_iso_path : (
    try(nonsensitive(var.redhat_offline_token), "") != "" ? "${var.nvme_storage_path}/discovery-image.iso" : ""
  )
  hypervisor_host = can(regex("@([^/:]+)", var.libvirt_uri)) ? regex("@([^/:]+)", var.libvirt_uri)[0] : "localhost"
}

# Declarative Assisted Installer ISO retrieval via OpenTofu lifecycle management
resource "terraform_data" "fetch_discovery_iso" {
  count = var.redhat_offline_token != "" ? 1 : 0

  triggers_replace = [
    var.redhat_offline_token,
    var.ocp_version,
    local.effective_discovery_iso_path,
    local_file.operator_public_key.content,
  ]

  provisioner "local-exec" {
    command = "${path.module}/scripts/fetch_discovery_iso.sh --token '${var.redhat_offline_token}' --version '${var.ocp_version}' --dest '${local.effective_discovery_iso_path}' --cluster '${var.cluster_name}' --domain '${var.base_domain}' --remote '${local.hypervisor_host}' --ssh-key '${local_file.operator_public_key.filename}'"
  }

  depends_on = [
    local_file.operator_public_key,
    libvirt_pool.nvme_pool
  ]
}

resource "libvirt_domain" "sno" {
  name    = var.sno_vm_name
  memory  = var.sno_memory_mb
  vcpu    = var.sno_vcpu
  running = var.sno_autostart

  cpu {
    mode = "host-passthrough"
  }

  boot_device {
    dev = ["hd", "cdrom"]
  }

  # Root disk volume on NVMe pool
  disk {
    volume_id = libvirt_volume.sno_root.id
  }

  # Optional Discovery ISO mount (attached when var.sno_discovery_iso_path is set or generated via API)
  dynamic "disk" {
    for_each = local.effective_discovery_iso_path != "" ? [local.effective_discovery_iso_path] : []
    content {
      file = disk.value
    }
  }

  network_interface {
    network_id     = libvirt_network.ocp_net.id
    mac            = var.sno_mac
    addresses      = [var.sno_ip]
    wait_for_lease = false
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

  # Apply low-latency caching and asynchronous I/O tuning via XSLT
  xml {
    xslt = file("${path.module}/templates/disk_cache_tuning.xsl")
  }

  depends_on = [
    terraform_data.fetch_discovery_iso
  ]
}
