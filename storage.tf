# ==============================================================================
# NVMe Fast Storage Pool & Volume Definitions
# Satisfies OpenShift etcd fsync latency requirements (<10ms p99)
# ==============================================================================

resource "libvirt_pool" "nvme_pool" {
  name = var.nvme_storage_pool_name
  type = "dir"
  path = var.nvme_storage_path
}

# 1. Base OS Image for Helper-Bastion (Rocky Linux 9 / RHEL GenericCloud)
resource "libvirt_volume" "bastion_base_image" {
  name   = "${var.bastion_vm_name}-base.qcow2"
  pool   = libvirt_pool.nvme_pool.name
  source = var.bastion_base_image_source
  format = "qcow2"
}

# 2. Copy-on-Write Root Disk Volume for Helper-Bastion (30 GB)
resource "libvirt_volume" "bastion_root" {
  name           = "${var.bastion_vm_name}-root.qcow2"
  pool           = libvirt_pool.nvme_pool.name
  base_volume_id = libvirt_volume.bastion_base_image.id
  format         = "qcow2"
  size           = var.bastion_disk_size_bytes
}

# 3. High-Performance Root Disk Volume for SNO Node (120 GB)
resource "libvirt_volume" "sno_root" {
  name   = "${var.sno_vm_name}-root.qcow2"
  pool   = libvirt_pool.nvme_pool.name
  format = "qcow2"
  size   = var.sno_disk_size_bytes
}
