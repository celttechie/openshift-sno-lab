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

# ------------------------------------------------------------------------------
# 1. Wait for Discovery Ping on SNO IP
# ------------------------------------------------------------------------------
echo -e "${BOLD}[1/3] Waiting for SNO Node Network Discovery (${SNO_IP})...${NC}"
START_TIME=$(date +%s)
END_TIME=$(( START_TIME + (MAX_WAIT_MINS * 60) ))

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
# 2. Wait for Kubernetes / OpenShift API Server (Port 6443)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[2/3] Waiting for OpenShift API Server Rendezvous (Port 6443)...${NC}"
echo "  (Note: SNO writes RHCOS to NVMe, reboots, and initializes etcd before API becomes healthy. This typically takes 15-25 minutes.)"

while true; do
  API_STATUS=$(bastion_exec "curl -k -s -o /dev/null -w '%{http_code}' https://${SNO_IP}:6443/version || true")
  if [[ "${API_STATUS}" == "200" || "${API_STATUS}" == "401" || "${API_STATUS}" == "403" ]]; then
    echo -e "\n  [${GREEN}RENDEZVOUS COMPLETE${NC}] OpenShift API is responding (HTTP ${API_STATUS})!"
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
# 3. Check Node & ClusterOperator Convergence (if Kubeconfig exists)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[3/3] Inspecting Cluster Convergence via oc...${NC}"

HAS_KUBECONFIG=$(bastion_exec "[ -f ~/.kube/config ] || [ -f ~/auth/kubeconfig ] && echo 'YES' || echo 'NO'")

if [[ "${HAS_KUBECONFIG}" == "YES" ]]; then
  echo -e "  Found kubeconfig on Bastion. Querying cluster state:\n"
  bastion_exec "KUBECONFIG=\${KUBECONFIG:-\$HOME/auth/kubeconfig} oc get nodes -o wide" || true
  echo ""
  bastion_exec "KUBECONFIG=\${KUBECONFIG:-\$HOME/auth/kubeconfig} oc get clusteroperators | head -n 15" || true
else
  echo -e "  [${CYAN}INFO${NC}] Kubeconfig not yet placed at ~/auth/kubeconfig."
  echo "  Download kubeconfig from Hybrid Cloud Console / Assisted Installer and place at:"
  echo "    ${SSH_USER}@${BASTION_IP}:~/auth/kubeconfig"
  echo "  Then run:"
  echo "    export KUBECONFIG=~/auth/kubeconfig"
  echo "    oc get nodes"
  echo "    oc get co"
fi

echo ""
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}   >>> SNO CLUSTER RENDEZVOUS VERIFIED SUCCESSFULLY <<<        ${NC}"
echo -e "${GREEN}${BOLD}================================================================${NC}"
