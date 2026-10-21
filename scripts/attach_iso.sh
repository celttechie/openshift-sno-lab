#!/usr/bin/env bash
# ==============================================================================
# SNO Live Discovery ISO Attachment Script
# Attaches / changes the Red Hat Assisted Installer Discovery ISO on the SNO VM
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

VM_NAME="${VM_NAME:-sno-node}"
LIBVIRT_URI="${LIBVIRT_URI:-qemu+ssh://bjarrett@t5600/system}"
REMOTE_HOST="${REMOTE_HOST:-t5600}"

if [[ $# -lt 1 ]]; then
  echo -e "${RED}Usage: $0 <path_to_iso_file> [vm_name]${NC}"
  echo "Example: $0 /mnt/nvme_data/ocp_storage/discovery-image.iso sno-node"
  exit 1
fi

ISO_PATH="$1"
if [[ $# -ge 2 ]]; then
  VM_NAME="$2"
fi

echo -e "${BLUE}${BOLD}================================================================${NC}"
echo -e "${BLUE}${BOLD}         Attaching Discovery ISO to SNO Virtual Machine         ${NC}"
echo -e "${BLUE}${BOLD}================================================================${NC}"
echo -e "VM Domain:    ${VM_NAME}"
echo -e "ISO Target:   ${ISO_PATH}"
echo -e "Libvirt URI:  ${LIBVIRT_URI}"
echo ""

# Verify ISO file exists on host if remote
if [[ "${LIBVIRT_URI}" == *"ssh://"* ]]; then
  echo -n "Checking ISO path on remote host (${REMOTE_HOST})... "
  if ssh -q "${REMOTE_HOST}" "[ -f '${ISO_PATH}' ]"; then
    echo -e "[${GREEN}FOUND${NC}]"
  else
    echo -e "[${RED}NOT FOUND${NC}]"
    echo -e "Error: File '${ISO_PATH}' does not exist on remote host ${REMOTE_HOST}."
    echo "Copy your Assisted Installer discovery ISO to ${REMOTE_HOST}:${ISO_PATH} first."
    exit 1
  fi
else
  if [[ ! -f "${ISO_PATH}" ]]; then
    echo -e "Error: Local file '${ISO_PATH}' does not exist."
    exit 1
  fi
fi

# Determine CDROM target device
CDROM_DEV=$(virsh -c "${LIBVIRT_URI}" domblklist "${VM_NAME}" | grep -E 'cdrom|iso|\.iso' | awk '{print $1}' | head -n 1 || true)

if [[ -z "${CDROM_DEV}" ]]; then
  # No existing cdrom device found in blklist; attach disk device using virtio-scsi bus
  echo "No active CD-ROM block target detected; attaching disk as virtio-scsi cdrom..."
  virsh -c "${LIBVIRT_URI}" attach-disk "${VM_NAME}" "${ISO_PATH}" sdb --type cdrom --mode readonly --targetbus scsi --config || \
  virsh -c "${LIBVIRT_URI}" attach-disk "${VM_NAME}" "${ISO_PATH}" sdb --type cdrom --mode readonly --config || true
  CDROM_DEV="sdb"
else
  echo "Found CD-ROM device: ${CDROM_DEV}"
  virsh -c "${LIBVIRT_URI}" change-media "${VM_NAME}" "${CDROM_DEV}" "${ISO_PATH}" --insert --config || \
  virsh -c "${LIBVIRT_URI}" change-media "${VM_NAME}" "${CDROM_DEV}" "${ISO_PATH}" --insert || true
fi

echo -e "\n${BOLD}Current Block Devices for ${VM_NAME}:${NC}"
virsh -c "${LIBVIRT_URI}" domblklist "${VM_NAME}"

echo ""
echo -e "${GREEN}${BOLD}Discovery ISO successfully configured on ${VM_NAME}.${NC}"
echo -e "To start the SNO VM:"
echo -e "  virsh -c ${LIBVIRT_URI} start ${VM_NAME}"
echo -e "To monitor boot console:"
echo -e "  virsh -c ${LIBVIRT_URI} console ${VM_NAME}"
