#!/usr/bin/env bash
# =============================================================================
# HomeLab Stack -- Nextcloud OIDC Setup
# Enables Authentik as social login provider for Nextcloud
# Requires: curl, jq
# Usage: ./scripts/nextcloud-oidc-setup.sh [--dry-run]
# =============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

if [ -f "$ROOT_DIR/.env" ]; then
  set -a; source "$ROOT_DIR/.env"; set +a
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${RESET} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_step()  { echo; echo -e "${BOLD}${CYAN}==> $*${RESET}"; }

AUTHENTIK_URL="https://${AUTHENTIK_DOMAIN:-auth.${DOMAIN}}"
TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN:-}"

if [ -z "$TOKEN" ]; then
  log_error "AUTHENTIK_BOOTSTRAP_TOKEN is not set in .env"
  exit 1
fi

# Check if Nextcloud is running
log_step "Checking Nextcloud availability..."
if curl -sf "https://nextcloud.${DOMAIN}/status.php" -o /dev/null 2>/dev/null; then
  log_info "Nextcloud is accessible"
else
  log_warn "Nextcloud is not accessible. Ensure it is running and reachable at https://nextcloud.${DOMAIN}"
fi

# Check if social login app is installed
log_step "Checking Nextcloud Social Login app..."
NC_CONTAINER="nextcloud"
if docker exec "$NC_CONTAINER" occ app:list 2>/dev/null | grep -q "sociallogin"; then
  log_info "Social Login app is installed"
else
  log_info "Installing social login app..."
  if ! $DRY_RUN; then
    docker exec "$NC_CONTAINER" occ app:install sociallogin 2>/dev/null || \
      log_warn "Could not install sociallogin app automatically"
  fi
fi

# Enable the app
if ! $DRY_RUN; then
  docker exec "$NC_CONTAINER" occ app:enable sociallogin 2>/dev/null || true
fi

# Configure Nextcloud OIDC settings via occ
log_step "Configuring Authentik OIDC for Nextcloud..."

if $DRY_RUN; then
  echo "[DRY-RUN] Would configure Nextcloud OIDC with:"
  echo "  OIDC Issuer: ${AUTHENTIK_URL}/application/o/nextcloud/"
  echo "  Client ID:   \${NEXTCLOUD_OIDC_CLIENT_ID} from .env"
  echo "  Secret:      \${NEXTCLOUD_OIDC_CLIENT_SECRET} from .env"
  return
fi

AUTH_HEADER="Authorization: Bearer $TOKEN"
API_URL="${AUTHENTIK_URL}/api/v3"

# Get provider details from Authentik API
get_provider_pk() {
  api_get "/providers/oauth2/" | jq -r ".results[] | select(.name == \"Nextcloud\") | .pk"
}

api_get() {
  curl -sf "${API_URL}${1}" -H "$AUTH_HEADER"
}

# Check if Nextcloud provider already exists
PROVIDER_PK=$(get_provider_pk)
if [ -z "$PROVIDER_PK" ] || [ "$PROVIDER_PK" = "null" ]; then
  log_error "Nextcloud OIDC provider not found in Authentik."
  log_error "Run ./scripts/setup-authentik.sh first to create all providers."
  exit 1
fi

# Configure Nextcloud using occ
NC_CONTAINER="nextcloud"

log_info "Configuring Nextcloud OIDC provider..."
docker exec "$NC_CONTAINER" occ config:system:set \
  social_login_auto_redirect --value="0" --type=bool 2>/dev/null || true

docker exec "$NC_CONTAINER" occ config:system:set \
  social_login.prevent_create_email_exists --value="1" --type=bool 2>/dev/null || true

# Set the custom OIDC provider configuration
# Nextcloud's social_login uses a "custom_oidc" provider
docker exec "$NC_CONTAINER" occ config:app:set social_login \
  custom_oidc_Authentik \
  --value="{\"issuer\":\"${AUTHENTIK_URL}/application/o/nextcloud/\",\"client_id\":\"${NEXTCLOUD_OIDC_CLIENT_ID}\",\"client_secret\":\"${NEXTCLOUD_OIDC_CLIENT_SECRET}\"}" 2>/dev/null || true

# Disable default Nextcloud account registration
docker exec "$NC_CONTAINER" occ config:system:set \
  allowregistrations --value="false" --type=bool 2>/dev/null || true

log_info "Nextcloud OIDC configured successfully!"
log_info ""
log_info "To complete setup:"
log_info "  1. Log into Nextcloud as admin"
log_info "  2. Go to Settings > Social Login"
log_info "  3. You should see 'Authentik' as an available provider"
log_info "  4. Click the connect button for Authentik"
log_info ""
log_info "Provider details from Authentik:"
log_info "  Issuer: ${AUTHENTIK_URL}/application/o/nextcloud/"
log_info "  Client ID: ${NEXTCLOUD_OIDC_CLIENT_ID}"
