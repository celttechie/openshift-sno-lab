# ==============================================================================
# OpenShift SNO Lab OpenTofu Variables
# ==============================================================================

variable "libvirt_uri" {
  description = "Libvirt connection URI (e.g. qemu+ssh://bjarrett@t5600/system or qemu:///system)"
  type        = string
  default     = "qemu+ssh://bjarrett@t5600/system"
}

# ------------------------------------------------------------------------------
# Isolated Network Variables
# ------------------------------------------------------------------------------
variable "network_name" {
  description = "Name of the dedicated isolated libvirt network"
  type        = string
  default     = "ocp-lab-net"
}

variable "bridge_name" {
  description = "Dedicated internal bridge interface name (avoids collision with virbr0)"
  type        = string
  default     = "virbr-ocp"
}

variable "network_cidr" {
  description = "Dedicated CIDR for the isolated OCP lab subnet"
  type        = string
  default     = "192.168.150.0/24"
}

variable "network_gateway" {
  description = "Gateway IP address on the isolated network (host bridge IP)"
  type        = string
  default     = "192.168.150.1"
}

variable "network_domain" {
  description = "DNS search domain for the lab"
  type        = string
  default     = "sno.lab.local"
}

# ------------------------------------------------------------------------------
# NVMe Storage Variables
# ------------------------------------------------------------------------------
variable "nvme_storage_pool_name" {
  description = "Libvirt storage pool name on the NVMe PCIe adapter"
  type        = string
  default     = "ocp_nvme"
}

variable "nvme_storage_path" {
  description = "Host directory path on the NVMe mount for the storage pool"
  type        = string
  default     = "/mnt/nvme_data/ocp_storage"
}

# ------------------------------------------------------------------------------
# Helper-Bastion VM Variables
# ------------------------------------------------------------------------------
variable "bastion_vm_name" {
  description = "Hostname and VM domain name for the Helper-Bastion"
  type        = string
  default     = "sno-bastion"
}

variable "bastion_vcpu" {
  description = "Number of vCPUs for the Bastion VM"
  type        = number
  default     = 2
}

variable "bastion_memory_mb" {
  description = "Memory in MB for the Bastion VM"
  type        = number
  default     = 4096
}

variable "bastion_disk_size_bytes" {
  description = "Root disk size in bytes for the Bastion VM (default 30 GB)"
  type        = number
  default     = 32212254720 # 30 GB
}

variable "bastion_ip" {
  description = "Static IP reservation for the Bastion VM"
  type        = string
  default     = "192.168.150.10"
}

variable "bastion_mac" {
  description = "Static MAC address pinned to the Bastion VM"
  type        = string
  default     = "52:54:00:15:00:10"
}

variable "bastion_base_image_source" {
  description = "URL or local host path to the Rocky Linux 9 or RHEL cloud image"
  type        = string
  default     = "https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
}

variable "admin_username" {
  description = "Administrative user name for the Bastion VM"
  type        = string
  default     = "bjarrett"
}

variable "ssh_public_key_path" {
  description = "Path to local SSH public key to inject into Bastion"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

# ------------------------------------------------------------------------------
# Target SNO Node Variables
# ------------------------------------------------------------------------------
variable "sno_vm_name" {
  description = "Domain name for the Single Node OpenShift VM"
  type        = string
  default     = "sno-node"
}

variable "sno_vcpu" {
  description = "Number of vCPUs allocated to SNO (min 8)"
  type        = number
  default     = 8
}

variable "sno_memory_mb" {
  description = "Memory in MB allocated to SNO (min 32 GB)"
  type        = number
  default     = 32768 # 32 GB
}

variable "sno_disk_size_bytes" {
  description = "Root disk size in bytes for SNO node (min 120 GB)"
  type        = number
  default     = 128849018880 # 120 GB
}

variable "sno_ip" {
  description = "Pinned static IP for the SNO node"
  type        = string
  default     = "192.168.150.50"
}

variable "sno_mac" {
  description = "Pinned static MAC address for the SNO node"
  type        = string
  default     = "52:54:00:15:00:50"
}

variable "sno_discovery_iso_path" {
  description = "Path to the Red Hat Assisted Installer / live discovery ISO (on hypervisor host). Leave blank if attaching post-provisioning."
  type        = string
  default     = ""
}

variable "disk_cache" {
  description = "Disk caching policy for low-latency etcd fsync (none recommended)"
  type        = string
  default     = "none"
}

variable "disk_io" {
  description = "Asynchronous I/O mode (threads or native)"
  type        = string
  default     = "threads"
}

variable "sno_autostart" {
  description = "Whether to start SNO VM automatically upon apply (set false when ISO needs to be downloaded/attached first)"
  type        = bool
  default     = false
}
