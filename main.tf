# ==============================================================================
# OpenShift SNO Lab OpenTofu Main Provider Definition
# ==============================================================================

provider "libvirt" {
  uri = var.libvirt_uri
}
