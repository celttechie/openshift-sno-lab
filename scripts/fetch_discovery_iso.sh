#!/usr/bin/env bash
# ==============================================================================
# Declarative Red Hat Assisted Installer Discovery ISO Fetcher
# Communicates directly with api.openshift.com via Red Hat SSO API Token
# Bypasses web console ClickOps, registers SNO cluster, and streams Discovery ISO
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-sno}"
BASE_DOMAIN="${BASE_DOMAIN:-lab.local}"
OCP_VERSION="${OCP_VERSION:-4.22}"
DEST_PATH="${DEST_PATH:-/mnt/nvme_data/ocp_storage/discovery-image.iso}"
REMOTE_HOST="${REMOTE_HOST:-t5600}"
SSH_KEY_FILE="${SSH_KEY_FILE:-${REPO_ROOT}/.keys/id_ed25519_operator.pub}"
OFFLINE_TOKEN="${REDHAT_OFFLINE_TOKEN:-}"

# Parse command line options
while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)
      OFFLINE_TOKEN="$2"
      shift 2
      ;;
    --cluster)
      CLUSTER_NAME="$2"
      shift 2
      ;;
    --domain)
      BASE_DOMAIN="$2"
      shift 2
      ;;
    --version)
      OCP_VERSION="$2"
      shift 2
      ;;
    --dest)
      DEST_PATH="$2"
      shift 2
      ;;
    --remote)
      REMOTE_HOST="$2"
      shift 2
      ;;
    --ssh-key)
      SSH_KEY_FILE="$2"
      shift 2
      ;;
    --recreate)
      RECREATE="true"
      shift
      ;;
    -h|--help)
      echo "Usage: $0 --token <redhat_offline_token> [options]"
      echo "Options:"
      echo "  --token    Red Hat offline API token (from console.redhat.com/openshift/token)"
      echo "  --cluster  Cluster name (default: sno)"
      echo "  --domain   Base DNS domain (default: lab.local)"
      echo "  --version  OpenShift release version (default: 4.16)"
      echo "  --dest     Remote or local ISO path (default: /mnt/nvme_data/ocp_storage/discovery-image.iso)"
      echo "  --remote   SSH target host for destination storage (default: t5600)"
      echo "  --ssh-key  Public SSH key file to embed (default: .keys/id_ed25519_operator.pub)"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ -z "${OFFLINE_TOKEN}" ]]; then
  echo -e "${RED}Error: Red Hat offline token is required.${NC}"
  echo "Obtain your free token at: https://console.redhat.com/openshift/token"
  echo "Then run: $0 --token '<your_token>' or set REDHAT_OFFLINE_TOKEN"
  exit 1
fi

if [[ ! -f "${SSH_KEY_FILE}" ]]; then
  echo -e "${RED}Error: SSH public key file not found at ${SSH_KEY_FILE}.${NC}"
  echo "Run 'tofu apply -target=local_file.operator_public_key' first to generate keys."
  exit 1
fi

SSH_PUBLIC_KEY=$(tr -d '\r\n' < "${SSH_KEY_FILE}")

# If personal key exists on workstation, append it as second authorized key
PERSONAL_PUB_KEY="${HOME}/.ssh/id_ed25519.pub"
if [[ -f "${PERSONAL_PUB_KEY}" ]]; then
  SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY}"$'\n'"$(tr -d '\r\n' < "${PERSONAL_PUB_KEY}")"
fi

echo -e "${BLUE}${BOLD}================================================================${NC}"
echo -e "${BLUE}${BOLD}     Red Hat Assisted Installer Declarative API ISO Generator    ${NC}"
echo -e "${BLUE}${BOLD}================================================================${NC}"
echo -e "Cluster Name:      ${BOLD}${CLUSTER_NAME}.${BASE_DOMAIN}${NC}"
echo -e "OpenShift Version: ${BOLD}${OCP_VERSION}${NC} (SNO Mode)"
echo -e "Destination Path:  ${REMOTE_HOST}:${DEST_PATH}"
echo ""

# ------------------------------------------------------------------------------
# 1. Authenticate with Red Hat SSO
# ------------------------------------------------------------------------------
echo -e "${BOLD}[1/4] Authenticating with Red Hat SSO (sso.redhat.com)...${NC}"

TOKEN_RESPONSE=$(curl -s -f -X POST "https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token" \
  -d "grant_type=refresh_token" \
  -d "client_id=cloud-services" \
  -d "refresh_token=${OFFLINE_TOKEN}" || true)

ACCESS_TOKEN=$(echo "${TOKEN_RESPONSE}" | jq -r '.access_token // empty' 2>/dev/null || true)

if [[ -z "${ACCESS_TOKEN}" ]]; then
  ERROR_DESC=$(echo "${TOKEN_RESPONSE}" | jq -r '.error_description // .error // "Unknown error"' 2>/dev/null || echo "Authentication failed")
  echo -e "  [${RED}FAIL${NC}] Could not obtain access token from Red Hat SSO: ${ERROR_DESC}"
  exit 1
fi

echo -e "  [${GREEN}PASS${NC}] Successfully authenticated. Access token obtained."

API_AUTH_HEADER="Authorization: Bearer ${ACCESS_TOKEN}"
API_BASE="https://api.openshift.com/api/assisted-install/v2"

# ------------------------------------------------------------------------------
# 2. Retrieve Pull Secret automatically via Accounts Management API
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[2/5] Retrieving Container Registry Pull Secret via API...${NC}"
PULL_SECRET=$(curl -s -f -X POST -H "${API_AUTH_HEADER}" "https://api.openshift.com/api/accounts_mgmt/v1/access_token" || true)

if [[ -z "${PULL_SECRET}" || "${PULL_SECRET}" != *"auths"* ]]; then
  echo -e "  [${RED}FAIL${NC}] Could not retrieve pull secret from Red Hat Accounts API."
  exit 1
fi
echo -e "  [${GREEN}PASS${NC}] Retrieved authorized pull secret for quay.io and registry.redhat.io."

# ------------------------------------------------------------------------------
# 3. Get or Register Cluster Definition
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[3/5] Querying Assisted Installer API for Cluster '${CLUSTER_NAME}'...${NC}"

EXISTING_CLUSTERS=$(curl -s -f -H "${API_AUTH_HEADER}" "${API_BASE}/clusters" || echo "[]")
EXISTING_CLUSTER=$(echo "${EXISTING_CLUSTERS}" | jq -c ".[] | select(.name == \"${CLUSTER_NAME}\" and .base_dns_domain == \"${BASE_DOMAIN}\")" | head -n 1)

CLUSTER_ID=""
if [[ -n "${EXISTING_CLUSTER}" ]]; then
  CLUSTER_ID=$(echo "${EXISTING_CLUSTER}" | jq -r '.id')
  CLUSTER_STATUS=$(echo "${EXISTING_CLUSTER}" | jq -r '.status')

  if [[ "${CLUSTER_STATUS}" == "installed" || "${CLUSTER_STATUS}" == "finalizing" || "${CLUSTER_STATUS}" == "error" || "${RECREATE:-false}" == "true" ]]; then
    echo -e "  Found existing cluster '${CLUSTER_NAME}.${BASE_DOMAIN}' with status '${CLUSTER_STATUS}'."
    echo "  Deleting previous cluster record to initiate clean installation..."
    curl -s -f -X DELETE -H "${API_AUTH_HEADER}" "${API_BASE}/clusters/${CLUSTER_ID}" >/dev/null || true
    CLUSTER_ID=""
  else
    echo -e "  [${GREEN}FOUND${NC}] Existing cluster '${CLUSTER_NAME}.${BASE_DOMAIN}' found (ID: ${CLUSTER_ID}, Status: ${CLUSTER_STATUS})."
  fi
fi

if [[ -z "${CLUSTER_ID}" ]]; then
  echo "  Registering cluster '${CLUSTER_NAME}.${BASE_DOMAIN}' via API..."

  CLUSTER_PAYLOAD=$(jq -n \
    --arg name "${CLUSTER_NAME}" \
    --arg domain "${BASE_DOMAIN}" \
    --arg version "${OCP_VERSION}" \
    --arg sshkey "${SSH_PUBLIC_KEY}" \
    --arg pullsecret "${PULL_SECRET}" \
    '{
      name: $name,
      base_dns_domain: $domain,
      openshift_version: $version,
      high_availability_mode: "None",
      user_managed_networking: true,
      ssh_public_key: $sshkey,
      pull_secret: $pullsecret
    }')

  CREATE_RES=$(curl -s -f -X POST -H "${API_AUTH_HEADER}" -H "Content-Type: application/json" \
    "${API_BASE}/clusters" -d "${CLUSTER_PAYLOAD}" || true)

  CLUSTER_ID=$(echo "${CREATE_RES}" | jq -r '.id // empty')

  if [[ -z "${CLUSTER_ID}" ]]; then
    echo -e "  [${RED}FAIL${NC}] Failed to register cluster: ${CREATE_RES}"
    exit 1
  fi
  echo -e "  [${GREEN}CREATED${NC}] Registered SNO cluster '${CLUSTER_NAME}' (ID: ${CLUSTER_ID})."
fi

# ------------------------------------------------------------------------------
# 4. Create or Fetch Infra-Env (Discovery Environment)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[4/5] Resolving Infrastructure Discovery Environment (infra-env)...${NC}"

EXISTING_ENVS=$(curl -s -f -H "${API_AUTH_HEADER}" "${API_BASE}/infra-envs?cluster_id=${CLUSTER_ID}" || echo "[]")
INFRA_ENV_ID=$(echo "${EXISTING_ENVS}" | jq -r ".[0].id // empty" 2>/dev/null || true)

if [[ -z "${INFRA_ENV_ID}" ]]; then
  echo "  Creating infra-env for cluster ${CLUSTER_ID}..."
  
  INFRA_PAYLOAD=$(jq -n \
    --arg name "${CLUSTER_NAME}_infra_env" \
    --arg cluster_id "${CLUSTER_ID}" \
    --arg sshkey "${SSH_PUBLIC_KEY}" \
    --arg pullsecret "${PULL_SECRET}" \
    --arg version "${OCP_VERSION}" \
    '{
      name: $name,
      cluster_id: $cluster_id,
      image_type: "full-iso",
      ssh_authorized_key: $sshkey,
      pull_secret: $pullsecret,
      openshift_version: $version,
      cpu_architecture: "x86_64"
    }')

  CREATE_ENV_RES=$(curl -s -f -X POST -H "${API_AUTH_HEADER}" -H "Content-Type: application/json" \
    "${API_BASE}/infra-envs" -d "${INFRA_PAYLOAD}" || true)

  INFRA_ENV_ID=$(echo "${CREATE_ENV_RES}" | jq -r '.id // empty')

  if [[ -z "${INFRA_ENV_ID}" ]]; then
    echo -e "  [${RED}FAIL${NC}] Failed to create infra-env: ${CREATE_ENV_RES}"
    exit 1
  fi
fi

echo -e "  [${GREEN}RESOLVED${NC}] Infra-Env ID: ${INFRA_ENV_ID}"

# Retrieve ISO Download URL
echo -n "  Awaiting pre-authenticated ISO download link from backend..."
DOWNLOAD_URL=""
for i in {1..20}; do
  IMAGE_URL_RESPONSE=$(curl -s -f -H "${API_AUTH_HEADER}" "${API_BASE}/infra-envs/${INFRA_ENV_ID}/downloads/image-url" || true)
  DOWNLOAD_URL=$(echo "${IMAGE_URL_RESPONSE}" | jq -r '.url // empty')
  if [[ -n "${DOWNLOAD_URL}" ]]; then
    break
  fi
  echo -n "."
  sleep 3
done
echo ""

if [[ -z "${DOWNLOAD_URL}" ]]; then
  echo -e "  [${RED}FAIL${NC}] Could not retrieve ISO download URL: ${IMAGE_URL_RESPONSE}"
  exit 1
fi

echo -e "  [${GREEN}READY${NC}] Generated pre-authenticated ISO download link."

# ------------------------------------------------------------------------------
# 5. Stream ISO to Target Storage Pool
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[5/5] Streaming Discovery ISO to ${REMOTE_HOST}:${DEST_PATH}...${NC}"

VOL_NAME=$(basename "${DEST_PATH}")
DEST_DIR=$(dirname "${DEST_PATH}")

deploy_via_libvirt() {
  local target_host="$1"
  local virsh_cmd="virsh -c qemu:///system"
  local pool_name="ocp_nvme"

  if [[ "${target_host}" != "localhost" && "${target_host}" != "127.0.0.1" ]]; then
    echo "  Creating/recreating volume '${VOL_NAME}' in libvirt pool '${pool_name}'..."
    ssh "${target_host}" "${virsh_cmd} vol-delete --pool '${pool_name}' '${VOL_NAME}' 2>/dev/null || true"
    ssh "${target_host}" "${virsh_cmd} vol-create-as '${pool_name}' '${VOL_NAME}' 1500M --format raw"

    echo "  Streaming ISO directly from Red Hat CDN to hypervisor volume..."
    if ssh "${target_host}" "curl -s -L '${DOWNLOAD_URL}' | ${virsh_cmd} vol-upload --pool '${pool_name}' '${VOL_NAME}' /dev/stdin"; then
      echo -e "  [${GREEN}STREAMED${NC}] Streamed Discovery ISO to ${target_host}:${DEST_PATH} via virsh."
      return 0
    fi
  else
    virsh -c qemu:///system vol-delete --pool "${pool_name}" "${VOL_NAME}" 2>/dev/null || true
    virsh -c qemu:///system vol-create-as "${pool_name}" "${VOL_NAME}" 1500M --format raw
    curl -s -L "${DOWNLOAD_URL}" | virsh -c qemu:///system vol-upload --pool "${pool_name}" "${VOL_NAME}" /dev/stdin
    return 0
  fi
  return 1
}

if ! deploy_via_libvirt "${REMOTE_HOST}"; then
  echo "  Direct libvirt streaming fallback: downloading locally and pushing..."
  TEMP_ISO="/tmp/discovery-image-$$.iso"
  trap 'rm -f "${TEMP_ISO}"' EXIT
  curl -L --progress-bar -o "${TEMP_ISO}" "${DOWNLOAD_URL}"
  if [[ "${REMOTE_HOST}" == "localhost" || "${REMOTE_HOST}" == "127.0.0.1" ]]; then
    mkdir -p "$(dirname "${DEST_PATH}")"
    cp "${TEMP_ISO}" "${DEST_PATH}"
  else
    cat "${TEMP_ISO}" | ssh "${REMOTE_HOST}" "virsh -c qemu:///system vol-upload --pool ocp_nvme '${VOL_NAME}' /dev/stdin" || \
    scp -C "${TEMP_ISO}" "${REMOTE_HOST}:${DEST_PATH}"
  fi
fi

echo -e "\n${GREEN}${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}   >>> DISCOVERY ISO DEPLOYED SUCCESSFULLY TO NVME POOL <<<      ${NC}"
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo -e "Remote Location: ${REMOTE_HOST}:${DEST_PATH}"
echo -e "Next Step: Run 'make attach-iso' or let OpenTofu boot the domain."
