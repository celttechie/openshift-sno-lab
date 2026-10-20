#!/usr/bin/env bash
# ==============================================================================
# Helper-Bastion Service Verification Script
# Validates dnsmasq split-DNS, haproxy listeners, and OpenShift CLI tools
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

BASTION_IP="${BASTION_IP:-192.168.150.10}"
SNO_IP="${SNO_IP:-192.168.150.50}"
DOMAIN="${DOMAIN:-sno.lab.local}"
SSH_USER="${SSH_USER:-bjarrett}"
JUMP_HOST="${JUMP_HOST:-t5600}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KNOWN_HOSTS="${REPO_ROOT}/.keys/known_hosts"
SSH_KEY="${REPO_ROOT}/.keys/id_ed25519_operator"

echo -e "${BLUE}${BOLD}================================================================${NC}"
echo -e "${BLUE}${BOLD}        OpenShift Helper-Bastion Health & Service Verification   ${NC}"
echo -e "${BLUE}${BOLD}================================================================${NC}"
echo -e "Bastion Target:  ${BASTION_IP}"
echo -e "SNO Target:      ${SNO_IP}"
echo -e "Cluster Domain:  ${DOMAIN}"
echo ""

ALL_PASS=true

# Helper to execute command on bastion with strict host key checking
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
# 1. SSH Reachability
# ------------------------------------------------------------------------------
echo -e "${BOLD}[1/4] Checking Bastion SSH Connectivity...${NC}"
if bastion_exec "uptime" > /dev/null 2>&1; then
  UPTIME=$(bastion_exec "uptime -p")
  echo -e "  [${GREEN}PASS${NC}] Connected to Bastion successfully (${UPTIME})"
else
  echo -e "  [${RED}FAIL${NC}] Unable to connect to Bastion at ${BASTION_IP} via ${JUMP_HOST}."
  exit 1
fi

# ------------------------------------------------------------------------------
# 2. DNS Resolution Verification (dnsmasq)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[2/4] Testing dnsmasq Split-DNS Records...${NC}"

test_dns() {
  local record="$1"
  local expected="$2"
  local result
  result=$(bastion_exec "dig +short @127.0.0.1 ${record}" | tail -n 1)
  if [[ "${result}" == "${expected}" ]]; then
    echo -e "  [${GREEN}PASS${NC}] ${record} -> ${result}"
  else
    echo -e "  [${RED}FAIL${NC}] ${record} resolved to '${result}', expected '${expected}'"
    ALL_PASS=false
  fi
}

test_dns "api.${DOMAIN}" "${SNO_IP}"
test_dns "api-int.${DOMAIN}" "${SNO_IP}"
test_dns "canary-openshift-ingress-canary.apps.${DOMAIN}" "${SNO_IP}"
test_dns "console-openshift-console.apps.${DOMAIN}" "${SNO_IP}"

# Test upstream forwarding
echo -n "  Testing upstream forwarding (redhat.com)... "
UPSTREAM=$(bastion_exec "dig +short @127.0.0.1 redhat.com" | head -n 1 || true)
if [[ -n "${UPSTREAM}" ]]; then
  echo -e "[${GREEN}PASS${NC}] (${UPSTREAM})"
else
  echo -e "[${YELLOW}WARN${NC}] Upstream forwarder did not return IP. Check internet connection on host."
fi

# ------------------------------------------------------------------------------
# 3. HAProxy Listener Verification
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[3/4] Verifying HAProxy Listener Endpoints...${NC}"

test_port() {
  local port="$1"
  local name="$2"
  if bastion_exec "ss -tlnp | grep -q ':${port} '"; then
    echo -e "  [${GREEN}PASS${NC}] Port ${port} (${name}) is actively listening"
  else
    echo -e "  [${RED}FAIL${NC}] Port ${port} (${name}) is NOT listening"
    ALL_PASS=false
  fi
}

test_port 6443 "OpenShift API"
test_port 22623 "Machine Config Server"
test_port 80 "HTTP Ingress"
test_port 443 "HTTPS Ingress"
test_port 9000 "HAProxy Stats Dashboard"

# Test Stats HTTP endpoint
STATS_HTTP=$(bastion_exec "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9000/" || true)
if [[ "${STATS_HTTP}" == "200" ]]; then
  echo -e "  [${GREEN}PASS${NC}] HAProxy stats dashboard accessible at http://${BASTION_IP}:9000/"
else
  echo -e "  [${YELLOW}WARN${NC}] HAProxy stats returned HTTP ${STATS_HTTP}"
fi

# ------------------------------------------------------------------------------
# 4. OpenShift CLI Tooling Verification
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[4/4] Checking OpenShift CLI Binaries...${NC}"

for bin in oc kubectl openshift-install aicli; do
  if bastion_exec "command -v ${bin}" > /dev/null 2>&1; then
    VER=$(bastion_exec "${bin} version 2>/dev/null | head -n 1" || echo "installed")
    echo -e "  [${GREEN}PASS${NC}] Binary $(printf '%-18s' "${bin}") found (${VER})"
  else
    echo -e "  [${RED}FAIL${NC}] Binary $(printf '%-18s' "${bin}") is MISSING"
    ALL_PASS=false
  fi
done

echo ""
echo -e "${BLUE}${BOLD}================================================================${NC}"
if [ "${ALL_PASS}" = true ]; then
  echo -e "${GREEN}${BOLD}   >>> HELPER-BASTION SERVICES VERIFIED & HEALTHY <<<           ${NC}"
  echo -e "${BLUE}${BOLD}================================================================${NC}"
  exit 0
else
  echo -e "${RED}${BOLD}   >>> SOME BASTION VERIFICATIONS FAILED - REVIEW ABOVE <<<     ${NC}"
  echo -e "${BLUE}${BOLD}================================================================${NC}"
  exit 1
fi
