# ==============================================================================
# Single Node OpenShift (SNO) Target VM Shell
# Sized with 8 vCPUs, 32 GB RAM, and 120 GB NVMe disk with cache/io tuning
# Ready for Red Hat Assisted Installer Live Discovery ISO
# ==============================================================================

resource "libvirt_domain" "sno" {
  name    = var.sno_vm_name
  memory  = var.sno_memory_mb
  vcpu    = var.sno_vcpu
  running = var.sno_autostart

  cpu {
    mode = "host-passthrough"
  }

  boot_device {
    dev = ["cdrom", "hd"]
  }

  # Root disk volume on NVMe pool
  disk {
    volume_id = libvirt_volume.sno_root.id
  }

  # Optional Discovery ISO mount (attached when var.sno_discovery_iso_path is set)
  dynamic "disk" {
    for_each = var.sno_discovery_iso_path != "" ? [var.sno_discovery_iso_path] : []
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
}
