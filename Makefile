# ==============================================================================
# OpenShift Single Node OpenShift (SNO) Peer-Bastion Lab Makefile
# Platform: Dell Precision T5600 Headless Hypervisor
# ==============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

BASTION_IP   ?= 192.168.150.10
SNO_IP       ?= 192.168.150.50
JUMP_HOST    ?= t5600
LIBVIRT_URI  ?= qemu+ssh://bjarrett@t5600/system
VM_NAME      ?= sno-node

.PHONY: help
help: ## Display available make targets
	@echo "================================================================="
	@echo "      OpenShift SNO Lab - Automation & Lifecycle Targets         "
	@echo "================================================================="
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: precheck
precheck: ## Run pre-flight audit (memory headroom, NVMe pool, CIDR collisions)
	./scripts/precheck.sh --remote $(JUMP_HOST)

.PHONY: init
init: ## Initialize OpenTofu provider plugins
	tofu init

.PHONY: plan
plan: ## Generate OpenTofu execution plan
	tofu plan -out=tfplan

.PHONY: apply
apply: ## Apply OpenTofu infrastructure (network, storage pool, volumes, VMs)
	tofu apply tfplan

.PHONY: provision-bastion
provision-bastion: ## Run Ansible playbook to configure dnsmasq, haproxy, and OCP tools
	ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory.ini ansible/playbook.yml

.PHONY: verify-bastion
verify-bastion: ## Verify split-DNS resolution, HAProxy listeners, and CLI tools
	./scripts/verify_bastion.sh

.PHONY: ssh-bastion
ssh-bastion: ## Open interactive SSH session to Helper-Bastion with strict host key checking
	ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=.keys/known_hosts -i .keys/id_ed25519_operator -o ProxyJump=$(JUMP_HOST) bjarrett@$(BASTION_IP)

.PHONY: ssh-sno
ssh-sno: ## Open interactive SSH session to SNO node as core user via Jump Host
	ssh -o StrictHostKeyChecking=no -i .keys/id_ed25519_operator -o ProxyJump=$(JUMP_HOST) core@$(SNO_IP)

.PHONY: fetch-iso
fetch-iso: ## Fetch Discovery ISO via Assisted Installer API (Usage: make fetch-iso TOKEN=<offline_token>)
	./scripts/fetch_discovery_iso.sh $(if $(TOKEN),--token $(TOKEN),)

.PHONY: attach-iso
attach-iso: ## Attach Discovery ISO to SNO VM (Usage: make attach-iso ISO=/path/to/rhcos.iso)
	@if [ -z "$(ISO)" ]; then echo "Error: specify ISO path. Example: make attach-iso ISO=/mnt/nvme_data/ocp_storage/discovery.iso"; exit 1; fi
	./scripts/attach_iso.sh $(ISO) $(VM_NAME)

.PHONY: start-sno
start-sno: ## Power on the SNO VM shell
	virsh -c $(LIBVIRT_URI) start $(VM_NAME)

.PHONY: stop-sno
stop-sno: ## Gracefully shutdown the SNO VM
	virsh -c $(LIBVIRT_URI) shutdown $(VM_NAME)

.PHONY: console-sno
console-sno: ## Connect to serial console of SNO VM (Ctrl+] to exit)
	virsh -c $(LIBVIRT_URI) console $(VM_NAME)

.PHONY: wait-rendezvous
wait-rendezvous: ## Monitor SNO VM boot, discovery, API rendezvous, and operators
	./scripts/wait_for_rendezvous.sh

.PHONY: destroy
destroy: ## Tear down OpenTofu resources
	tofu destroy -auto-approve
