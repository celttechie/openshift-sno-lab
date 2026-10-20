# ==============================================================================
# Isolated Libvirt Network Definition (ocp-lab-net)
# Dedicated subnet, NAT egress, custom bridge virbr-ocp, DNS & DHCP configuration
# ==============================================================================

resource "libvirt_network" "ocp_net" {
  name      = var.network_name
  mode      = "nat"
  bridge    = var.bridge_name
  domain    = var.network_domain
  addresses = [var.network_cidr]
  autostart = true

  dhcp {
    enabled = true
  }

  dns {
    enabled    = true
    local_only = false

    hosts {
      ip       = var.bastion_ip
      hostname = "bastion"
    }
    hosts {
      ip       = var.bastion_ip
      hostname = "bastion.${var.network_domain}"
    }
    hosts {
      ip       = var.sno_ip
      hostname = "sno-node"
    }
    hosts {
      ip       = var.sno_ip
      hostname = "sno-node.${var.network_domain}"
    }
    hosts {
      ip       = var.sno_ip
      hostname = "api.${var.network_domain}"
    }
    hosts {
      ip       = var.sno_ip
      hostname = "api-int.${var.network_domain}"
    }
  }

  dnsmasq_options {
    options {
      option_name  = "dhcp-option"
      option_value = "6,${var.bastion_ip},${var.network_gateway}"
    }
    options {
      option_name  = "dhcp-host"
      option_value = "${var.bastion_mac},${var.bastion_ip},bastion"
    }
    options {
      option_name  = "dhcp-host"
      option_value = "${var.sno_mac},${var.sno_ip},sno-node"
    }
  }
}
