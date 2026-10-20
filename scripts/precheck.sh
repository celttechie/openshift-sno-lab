#!/usr/bin/env bash
# ==============================================================================
# OpenShift SNO Peer-Bastion Pre-Flight Audit Script
# Validates host context on Dell Precision T5600 (or specified hypervisor target)
# ==============================================================================

set -euo pipefail

# ANSI Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Sizing Requirements
REQ_MEM_GB=36          # 32 GB SNO + 4 GB Bastion
REQ_VCPU=10            # 8 vCPU SNO + 2 vCPU Bastion
REQ_DISK_GB=160        # 120 GB SNO + 30 GB Bastion + ISO buffer
TARGET_SUBNET="192.168.150"
TARGET_CIDR="192.168.150.0/24"
TARGET_BRIDGE="virbr-ocp"
NVME_MOUNT_POINT="/mnt/nvme_data"

REMOTE_HOST="${REMOTE_HOST:-t5600}"
CURRENT_HOST="$(hostname)"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote)
      REMOTE_HOST="$2"
      shift 2
      ;;
    --local)
      REMOTE_HOST="local"
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--remote <ssh_alias_or_ip>] [--local]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ "${CURRENT_HOST,,}" == *"t5600"* ]]; then
  REMOTE_HOST="local"
fi

run_cmd() {
  if [[ "${REMOTE_HOST}" == "local" ]]; then
    eval "$@"
  else
    ssh -o BatchMode=yes -o ConnectTimeout=5 "${REMOTE_HOST}" "$@"
  fi
}

echo -e "${BLUE}${BOLD}================================================================${NC}"
echo -e "${BLUE}${BOLD}   OpenShift SNO Lab Pre-Flight Audit & Environment Check      ${NC}"
echo -e "${BLUE}${BOLD}================================================================${NC}"
echo -e "Target Host:        ${CYAN}${REMOTE_HOST}${NC}"
echo -e "Requested Subnet:   ${CYAN}${TARGET_CIDR}${NC}"
echo -e "Target Bridge:      ${CYAN}${TARGET_BRIDGE}${NC}"
echo -e "NVMe Fast Storage:  ${CYAN}${NVME_MOUNT_POINT}${NC}"
echo -e "Requirements:       ${CYAN}${REQ_MEM_GB} GB RAM, ${REQ_VCPU} vCPUs, ${REQ_DISK_GB} GB NVMe storage${NC}"
echo ""

OVERALL_PASS=true

# ------------------------------------------------------------------------------
# 1. Connectivity & Hypervisor Host Detection
# ------------------------------------------------------------------------------
echo -e "${BOLD}[1/6] Validating Target Hypervisor Access...${NC}"
if ! run_cmd "uname -a" > /dev/null 2>&1; then
  echo -e "  [${RED}FAIL${NC}] Unable to connect to target host '${REMOTE_HOST}' via SSH."
  echo "         Verify SSH key authentication and network reachability."
  exit 1
fi
HOST_INFO=$(run_cmd "uname -sr; hostname")
echo -e "  [${GREEN}PASS${NC}] Connected to host: ${HOST_INFO}"

# Check KVM acceleration
if run_cmd "[ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]"; then
  echo -e "  [${GREEN}PASS${NC}] Hardware KVM device (/dev/kvm) is accessible."
else
  echo -e "  [${YELLOW}WARN${NC}] /dev/kvm not directly accessible or missing user permissions."
  OVERALL_PASS=false
fi

# ------------------------------------------------------------------------------
# 2. Host Memory Headroom Check
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[2/6] Checking Host Memory Headroom...${NC}"
MEM_AVAIL_KB=$(run_cmd "grep MemAvailable /proc/meminfo | awk '{print \$2}'")
MEM_TOTAL_KB=$(run_cmd "grep MemTotal /proc/meminfo | awk '{print \$2}'")

MEM_AVAIL_GB=$(( MEM_AVAIL_KB / 1024 / 1024 ))
MEM_TOTAL_GB=$(( MEM_TOTAL_KB / 1024 / 1024 ))

echo -e "  Total System RAM:     ${MEM_TOTAL_GB} GB"
echo -e "  Available Memory:     ${MEM_AVAIL_GB} GB"
echo -e "  Required Memory:      ${REQ_MEM_GB} GB"

if [[ ${MEM_AVAIL_GB} -ge ${REQ_MEM_GB} ]]; then
  echo -e "  [${GREEN}PASS${NC}] Host has sufficient available RAM (${MEM_AVAIL_GB} GB >= ${REQ_MEM_GB} GB)."
else
  echo -e "  [${RED}FAIL${NC}] Host does not have enough available RAM (${MEM_AVAIL_GB} GB available, need ${REQ_MEM_GB} GB)."
  OVERALL_PASS=false
fi

# ------------------------------------------------------------------------------
# 3. CPU Core / Thread Allocation Check
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[3/6] Checking CPU Headroom...${NC}"
CPU_CORES=$(run_cmd "nproc")
CPU_MODEL=$(run_cmd "lscpu | grep 'Model name' | sed 's/Model name:[[:space:]]*//' | head -n 1")

echo -e "  CPU Model:            ${CPU_MODEL}"
echo -e "  Total Logical Cores:  ${CPU_CORES}"
echo -e "  Required vCPUs:       ${REQ_VCPU} (8 SNO + 2 Bastion)"

if [[ ${CPU_CORES} -ge ${REQ_VCPU} ]]; then
  echo -e "  [${GREEN}PASS${NC}] CPU capacity is sufficient (${CPU_CORES} logical cores >= ${REQ_VCPU})."
else
  echo -e "  [${YELLOW}WARN${NC}] System has only ${CPU_CORES} cores; overcommit will occur."
fi

# ------------------------------------------------------------------------------
# 4. NVMe PCIe Storage Pool & Latency Check
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[4/6] Verifying NVMe Storage Mount & Fsync Capability...${NC}"
if run_cmd "df -BG '${NVME_MOUNT_POINT}'" > /dev/null 2>&1; then
  NVME_AVAIL_GB=$(run_cmd "df -BG '${NVME_MOUNT_POINT}' | tail -n 1 | awk '{print \$4}' | tr -d 'G'")
  NVME_DEV=$(run_cmd "df -P '${NVME_MOUNT_POINT}' | tail -n 1 | awk '{print \$1}'")
  echo -e "  NVMe Mount Point:     ${NVME_MOUNT_POINT} (${NVME_DEV})"
  echo -e "  Available Space:      ${NVME_AVAIL_GB} GB"
  echo -e "  Required Space:       ${REQ_DISK_GB} GB"

  if [[ ${NVME_AVAIL_GB} -ge ${REQ_DISK_GB} ]]; then
    echo -e "  [${GREEN}PASS${NC}] Storage space satisfies etcd & SNO footprint (${NVME_AVAIL_GB} GB >= ${REQ_DISK_GB} GB)."
  else
    echo -e "  [${RED}FAIL${NC}] Insufficient space on NVMe volume (${NVME_AVAIL_GB} GB available, need ${REQ_DISK_GB} GB)."
    OVERALL_PASS=false
  fi

  # Quick fsync latency write test
  echo -n "  Running disk fsync write probe... "
  TEST_DIR="${NVME_MOUNT_POINT}/.sno_fsync_probe"
  FSYNC_RESULT=$(run_cmd "
    mkdir -p '${TEST_DIR}' 2>/dev/null && \
    dd if=/dev/zero of='${TEST_DIR}/test.img' bs=4k count=1000 oflag=dsync 2>&1 | grep -o '[0-9.]* [kMGTP]*B/s' | tail -n 1 || echo 'FS_TEST_FAIL'
    rm -rf '${TEST_DIR}' 2>/dev/null || true
  ")
  if [[ "${FSYNC_RESULT}" != *"FAIL"* && -n "${FSYNC_RESULT}" ]]; then
    echo -e "[${GREEN}PASS${NC}] (${FSYNC_RESULT})"
  else
    echo -e "[${YELLOW}WARN${NC}] (Permission or non-destructive probe warning; pool will be provisioned via libvirtd)"
  fi
else
  echo -e "  [${RED}FAIL${NC}] NVMe mount point '${NVME_MOUNT_POINT}' does not exist or is not mounted on target host."
  OVERALL_PASS=false
fi

# ------------------------------------------------------------------------------
# 5. Libvirt Subnet & Bridge Collision Check
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[5/6] Auditing Libvirt Networks & Route Collisions...${NC}"
EXISTING_NETS=$(run_cmd "virsh -c qemu:///system net-list --all --name" 2>/dev/null || true)
echo "  Configured libvirt networks: $(echo $EXISTING_NETS | tr '\n' ' ')"

COLLISION_DETECTED=false

# Check libvirt network definitions
for net in $EXISTING_NETS; do
  [[ -z "$net" ]] && continue
  NET_XML=$(run_cmd "virsh -c qemu:///system net-dumpxml '$net'" 2>/dev/null || true)
  
  if echo "$NET_XML" | grep -q "${TARGET_SUBNET}"; then
    echo -e "  [${RED}CONFLICT${NC}] Subnet collision: Libvirt network '$net' is already using ${TARGET_SUBNET}.0/24"
    COLLISION_DETECTED=true
  fi
  if echo "$NET_XML" | grep -q "${TARGET_BRIDGE}"; then
    echo -e "  [${RED}CONFLICT${NC}] Bridge collision: Libvirt network '$net' is already using bridge ${TARGET_BRIDGE}"
    COLLISION_DETECTED=true
  fi
done

# Check host interfaces and routing tables
HOST_ROUTES=$(run_cmd "ip route; ip -4 addr show")
if echo "$HOST_ROUTES" | grep -q "${TARGET_SUBNET}"; then
  echo -e "  [${RED}CONFLICT${NC}] Host routing table or interface is already using subnet ${TARGET_SUBNET}.x"
  COLLISION_DETECTED=true
fi
if echo "$HOST_ROUTES" | grep -q "${TARGET_BRIDGE}"; then
  echo -e "  [${RED}CONFLICT${NC}] Host bridge interface ${TARGET_BRIDGE} already exists"
  COLLISION_DETECTED=true
fi

if [ "$COLLISION_DETECTED" = false ]; then
  echo -e "  [${GREEN}PASS${NC}] Zero collisions detected for CIDR ${TARGET_CIDR} and bridge ${TARGET_BRIDGE}."
else
  echo -e "  [${RED}FAIL${NC}] Collisions detected. Choose an alternative subnet or clean up conflicting network."
  OVERALL_PASS=false
fi

# ------------------------------------------------------------------------------
# 6. Local Tooling Check
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[6/6] Checking Required Local Tooling...${NC}"
for tool in tofu ansible-playbook virsh ssh; do
  if command -v "$tool" > /dev/null 2>&1; then
    echo -e "  Tool: $(printf '%-18s' "$tool") [${GREEN}INSTALLED${NC}] ($(which "$tool"))"
  elif [[ "$tool" == "tofu" ]] && command -v terraform > /dev/null 2>&1; then
    echo -e "  Tool: $(printf '%-18s' "tofu (terraform)") [${GREEN}INSTALLED${NC}] ($(which terraform))"
  else
    echo -e "  Tool: $(printf '%-18s' "$tool") [${RED}MISSING${NC}]"
    OVERALL_PASS=false
  fi
done

echo ""
echo -e "${BLUE}${BOLD}================================================================${NC}"
if [ "$OVERALL_PASS" = true ]; then
  echo -e "${GREEN}${BOLD}   >>> PRE-FLIGHT AUDIT PASSED: Environment Ready for SNO <<<   ${NC}"
  echo -e "${BLUE}${BOLD}================================================================${NC}"
  exit 0
else
  echo -e "${RED}${BOLD}   >>> PRE-FLIGHT AUDIT FAILED: Resolve issues above before proceeding <<<   ${NC}"
  echo -e "${BLUE}${BOLD}================================================================${NC}"
  exit 1
fi
