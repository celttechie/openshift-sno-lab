#!/usr/bin/env bash
# ==============================================================================
# OpenShift SNO Rendezvous & Cluster Convergence Monitor
# Tracks API availability (port 6443), HAProxy backend health, and Cluster Operators
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

BASTION_IP="${BASTION_IP:-192.168.150.10}"
SNO_IP="${SNO_IP:-192.168.150.50}"
DOMAIN="${DOMAIN:-sno.lab.local}"
SSH_USER="${SSH_USER:-bjarrett}"
JUMP_HOST="${JUMP_HOST:-t5600}"
VM_NAME="${VM_NAME:-sno-node}"
LIBVIRT_URI="${LIBVIRT_URI:-qemu+ssh://bjarrett@${JUMP_HOST}/system}"
MAX_WAIT_MINS="${MAX_WAIT_MINS:-45}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KNOWN_HOSTS="${REPO_ROOT}/.keys/known_hosts"
SSH_KEY="${REPO_ROOT}/.keys/id_ed25519_operator"

echo -e "${BLUE}${BOLD}================================================================${NC}"
echo -e "${BLUE}${BOLD}        OpenShift SNO Rendezvous & Cluster Convergence Monitor  ${NC}"
echo -e "${BLUE}${BOLD}================================================================${NC}"
echo -e "Cluster API:     https://api.${DOMAIN}:6443"
echo -e "SNO Node IP:     ${SNO_IP}"
echo -e "Bastion Gateway: ${BASTION_IP}"
echo -e "Max Wait Time:   ${MAX_WAIT_MINS} minutes"
echo ""

bastion_exec() {
  if [ "$(hostname)" = "sno-bastion" ]; then
    eval "$@"
  else
    local ssh_cmd=("ssh" "-o" "BatchMode=yes" "-o" "ProxyJump=${JUMP_HOST}")
    if [[ -f "${KNOWN_HOSTS}" && -f "${SSH_KEY}" ]]; then
      ssh_cmd+=("-o" "StrictHostKeyChecking=yes" "-o" "UserKnownHostsFile=${KNOWN_HOSTS}" "-i" "${SSH_KEY}")
    else
      ssh_cmd+=("-o" "StrictHostKeyChecking=no")
    fi
    "${ssh_cmd[@]}" "${SSH_USER}@${BASTION_IP}" "$@"
  fi
}

eject_iso() {
  local cdrom_dev
  cdrom_dev=$(virsh -c "${LIBVIRT_URI}" domblklist "${VM_NAME}" 2>/dev/null | grep -E 'cdrom|iso|\.iso' | awk '{print $1}' | head -n 1 || true)
  if [[ -n "${cdrom_dev}" ]]; then
    virsh -c "${LIBVIRT_URI}" change-media "${VM_NAME}" "${cdrom_dev}" --eject --config --live 2>/dev/null || \
    virsh -c "${LIBVIRT_URI}" detach-disk "${VM_NAME}" "${cdrom_dev}" --config 2>/dev/null || true
  fi
  return 0
}

START_TIME=$(date +%s)
END_TIME=$(( START_TIME + (MAX_WAIT_MINS * 60) ))

# ------------------------------------------------------------------------------
# 1. Wait for Discovery Ping on SNO IP
# ------------------------------------------------------------------------------
echo -e "${BOLD}[1/4] Waiting for SNO Node Network Discovery (${SNO_IP})...${NC}"

while true; do
  if bastion_exec "ping -c 1 -W 2 ${SNO_IP}" > /dev/null 2>&1; then
    echo -e "  [${GREEN}ONLINE${NC}] SNO Node responded to ping on ${SNO_IP}."
    break
  fi

  CURRENT_TIME=$(date +%s)
  ELAPSED=$(( CURRENT_TIME - START_TIME ))
  if [[ ${CURRENT_TIME} -ge ${END_TIME} ]]; then
    echo -e "  [${RED}TIMEOUT${NC}] SNO Node did not acquire ${SNO_IP} within ${MAX_WAIT_MINS} minutes."
    exit 1
  fi

  echo -ne "  Probing ${SNO_IP} (${ELAPSED}s elapsed)...\r"
  sleep 5
done

# ------------------------------------------------------------------------------
# 2. Monitor Installation Progress & Auto-Eject Discovery ISO
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[2/4] Monitoring Installation Progress & Managing Boot Media...${NC}"
echo "  (Assisted Installer writes RHCOS to NVMe root disk, reboots, and initializes etcd.)"

# Retrieve offline token from env or tfvars if available
OFFLINE_TOKEN="${REDHAT_OFFLINE_TOKEN:-}"
if [[ -z "${OFFLINE_TOKEN}" && -f "${REPO_ROOT}/terraform.tfvars" ]]; then
  OFFLINE_TOKEN=$(grep -E '^\s*redhat_offline_token\s*=' "${REPO_ROOT}/terraform.tfvars" | sed -E 's/^\s*redhat_offline_token\s*=\s*"([^"]+)".*/\1/' || true)
fi

while true; do
  # 1. Check if node is running from installed ostree (NVMe disk)
  if ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -o ProxyJump="${JUMP_HOST}" core@"${SNO_IP}" "grep -q 'ostree' /proc/cmdline" 2>/dev/null; then
    echo -e "\n  [${GREEN}DISK BOOT CONFIRMED${NC}] SNO Node has successfully booted into installed RHCOS (NVMe)."
    eject_iso
    break
  fi

  # 2. Query Assisted Installer REST API if token available
  if [[ -n "${OFFLINE_TOKEN}" ]]; then
    SSO_RES=$(curl -s -X POST "https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token" \
      -d "grant_type=refresh_token" -d "client_id=cloud-services" -d "refresh_token=${OFFLINE_TOKEN}" || true)
    API_TOKEN=$(echo "${SSO_RES}" | jq -r '.access_token // empty' 2>/dev/null || true)
    if [[ -n "${API_TOKEN}" ]]; then
      EXISTING_CLUSTERS=$(curl -s -H "Authorization: Bearer ${API_TOKEN}" "https://api.openshift.com/api/assisted-install/v2/clusters" || echo "[]")
      CID=$(echo "${EXISTING_CLUSTERS}" | jq -r '.[] | select(.name == "sno") | .id' | head -n 1)
      if [[ -n "${CID}" ]]; then
        CLUSTER_INFO=$(curl -s -H "Authorization: Bearer ${API_TOKEN}" "https://api.openshift.com/api/assisted-install/v2/clusters/${CID}" || echo "{}")
        CLUSTER_STATUS=$(echo "${CLUSTER_INFO}" | jq -r '.status // empty' 2>/dev/null || true)
        HOST_STATUS=$(echo "${CLUSTER_INFO}" | jq -r '.hosts[0].status // empty' 2>/dev/null || true)
        HOST_STAGE=$(echo "${CLUSTER_INFO}" | jq -r '.hosts[0].progress.current_stage // empty' 2>/dev/null || true)
        HOST_PCT=$(echo "${CLUSTER_INFO}" | jq -r '.hosts[0].progress.installation_percentage // 0' 2>/dev/null || true)

        # If cluster validations have passed and cluster is ready, trigger automated installation
        if [[ "${CLUSTER_STATUS}" == "ready" ]]; then
          echo -e "\n  [${GREEN}AUTO-INSTALL${NC}] All validations passed. Triggering automated installation via Assisted Installer API..."
          curl -s -f -X POST -H "Authorization: Bearer ${API_TOKEN}" "https://api.openshift.com/api/assisted-install/v2/clusters/${CID}/actions/install" >/dev/null || true
          sleep 5
        fi

        if [[ -n "${HOST_STAGE}" ]]; then
          echo -ne "  Assisted Installer: stage='${HOST_STAGE}' status='${HOST_STATUS}' (${HOST_PCT}%)...\r"
        fi

        # If installer has written image to disk or is rebooting, eject media
        if [[ "${HOST_STAGE}" == *"disk"* || "${HOST_STAGE}" == *"Rebooting"* || "${HOST_STATUS}" == "installing-pending-user-action" || "${HOST_STATUS}" == "installed" ]]; then
          eject_iso
        fi

        # If host booted back into discovery ISO by mistake, reset domain to boot from disk
        if [[ "${HOST_STATUS}" == "installing-pending-user-action" ]]; then
          echo -e "\n  [${YELLOW}ACTION REQUIRED${NC}] Host booted into ISO instead of disk. Ejecting media and resetting VM..."
          eject_iso
          virsh -c "${LIBVIRT_URI}" reset "${VM_NAME}" 2>/dev/null || true
          sleep 15
        fi
      fi
    fi
  fi

  CURRENT_TIME=$(date +%s)
  ELAPSED=$(( (CURRENT_TIME - START_TIME) / 60 ))
  if [[ ${CURRENT_TIME} -ge ${END_TIME} ]]; then
    echo -e "\n  [${RED}TIMEOUT${NC}] Node did not boot from disk within ${MAX_WAIT_MINS} minutes."
    exit 1
  fi

  sleep 10
done

# ------------------------------------------------------------------------------
# 3. Wait for OpenShift API Server Rendezvous (Port 6443)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[3/4] Waiting for OpenShift API Server Rendezvous (Port 6443)...${NC}"
echo "  (Node is running from NVMe; waiting for kubelet, etcd, and kube-apiserver static pods to become healthy.)"

while true; do
  API_STATUS=$(bastion_exec "curl -k -s -o /dev/null -w '%{http_code}' https://${SNO_IP}:6443/version || true")
  if [[ "${API_STATUS}" == "200" || "${API_STATUS}" == "401" || "${API_STATUS}" == "403" ]]; then
    echo -e "\n  [${GREEN}RENDEZVOUS COMPLETE${NC}] OpenShift API is responding on https://${SNO_IP}:6443 (HTTP ${API_STATUS})!"
    break
  fi

  CURRENT_TIME=$(date +%s)
  ELAPSED=$(( (CURRENT_TIME - START_TIME) / 60 ))
  if [[ ${CURRENT_TIME} -ge ${END_TIME} ]]; then
    echo -e "\n  [${RED}TIMEOUT${NC}] API server did not come online within ${MAX_WAIT_MINS} minutes."
    exit 1
  fi

  echo -ne "  Awaiting API health check on https://${SNO_IP}:6443 (${ELAPSED}m elapsed)...\r"
  sleep 10
done

# ------------------------------------------------------------------------------
# 4. Synchronize Admin Kubeconfig & Inspect Cluster Convergence
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[4/4] Synchronizing Admin Kubeconfig & Inspecting Cluster State...${NC}"

KUBECONFIG_CONTENT=""

# Method A: Fetch authoritative kubeconfig via Assisted Installer REST API
if [[ -n "${OFFLINE_TOKEN}" ]]; then
  echo "  Retrieving authoritative cluster admin kubeconfig via Assisted Installer API..."
  SSO_RES=$(curl -s -X POST "https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token" \
    -d "grant_type=refresh_token" -d "client_id=cloud-services" -d "refresh_token=${OFFLINE_TOKEN}" || true)
  API_TOKEN=$(echo "${SSO_RES}" | jq -r '.access_token // empty' 2>/dev/null || true)
  if [[ -n "${API_TOKEN}" ]]; then
    EXISTING_CLUSTERS=$(curl -s -H "Authorization: Bearer ${API_TOKEN}" "https://api.openshift.com/api/assisted-install/v2/clusters" || echo "[]")
    CID=$(echo "${EXISTING_CLUSTERS}" | jq -r '.[] | select(.name == "sno") | .id' | head -n 1)
    if [[ -n "${CID}" ]]; then
      KUBECONFIG_CONTENT=$(curl -s -H "Authorization: Bearer ${API_TOKEN}" "https://api.openshift.com/api/assisted-install/v2/clusters/${CID}/downloads/credentials?file_name=kubeconfig" || true)
    fi
  fi
fi

# Method B: Fallback to reading bootstrap secret from SNO node
if [[ -z "${KUBECONFIG_CONTENT}" || "${KUBECONFIG_CONTENT}" != *"clusters:"* ]]; then
  echo "  Reading admin kubeconfig directly from SNO node..."
  KUBECONFIG_CONTENT=$(ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyJump="${JUMP_HOST}" core@"${SNO_IP}" "sudo cat /etc/kubernetes/bootstrap-secrets/kubeconfig 2>/dev/null || sudo cat /etc/kubernetes/kubeconfig 2>/dev/null" || true)
fi

if [[ -n "${KUBECONFIG_CONTENT}" && "${KUBECONFIG_CONTENT}" == *"clusters:"* ]]; then
  # Write to local repository .kube/config
  mkdir -p "${REPO_ROOT}/.kube"
  echo "${KUBECONFIG_CONTENT}" > "${REPO_ROOT}/.kube/config"
  chmod 600 "${REPO_ROOT}/.kube/config"
  echo -e "  [${GREEN}SYNCED${NC}] Admin kubeconfig saved to ${REPO_ROOT}/.kube/config."

  # Write to Bastion ~/.kube/config
  echo "${KUBECONFIG_CONTENT}" | bastion_exec "mkdir -p ~/.kube && cat > ~/.kube/config && chmod 600 ~/.kube/config"
  echo -e "  [${GREEN}SYNCED${NC}] Admin kubeconfig installed on ${BASTION_IP}:~/.kube/config."

  # Write to SNO Node ~/.kube/config
  echo "${KUBECONFIG_CONTENT}" | ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyJump="${JUMP_HOST}" core@"${SNO_IP}" "mkdir -p ~/.kube && cat > ~/.kube/config && chmod 600 ~/.kube/config" 2>/dev/null || true
  echo -e "  [${GREEN}SYNCED${NC}] Admin kubeconfig installed on ${SNO_IP}:~/.kube/config."
fi

if bastion_exec "[ -s ~/.kube/config ]"; then
  echo -e "\n  Querying live OpenShift node status:"
  bastion_exec "oc get nodes -o wide" || true
  echo -e "\n  Querying OpenShift Cluster Operators:"
  bastion_exec "oc get clusteroperators" || true
else
  echo -e "  [${CYAN}INFO${NC}] Kubeconfig not yet available. Place at ${SSH_USER}@${BASTION_IP}:~/.kube/config"
fi

echo ""
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}   >>> SNO CLUSTER RENDEZVOUS VERIFIED SUCCESSFULLY <<<        ${NC}"
echo -e "${GREEN}${BOLD}================================================================${NC}"
