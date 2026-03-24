#!/usr/bin/env bash
# =============================================================================
# HomeLab Stack -- Authentik SSO Setup Script
# Creates OIDC providers for all integrated services
# Creates user groups: homelab-admins, homelab-users, media-users
# Creates Traefik ForwardAuth middleware
# Requires: curl, jq
# Usage: ./scripts/setup-authentik.sh [--dry-run]
# =============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

# Load .env
if [ -f "$ROOT_DIR/.env" ]; then
  set -a; source "$ROOT_DIR/.env"; set +a
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${RESET} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_step()  { echo; echo -e "${BOLD}${CYAN}==> $*${RESET}"; }
log_dry()   { echo -e "${YELLOW}[DRY-RUN]${RESET} $*"; }

AUTHENTIK_URL="https://${AUTHENTIK_DOMAIN:-auth.${DOMAIN}}"
API_URL="$AUTHENTIK_URL/api/v3"
TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN:-}"

if [ -z "$TOKEN" ]; then
  log_error "AUTHENTIK_BOOTSTRAP_TOKEN is not set in .env"
  exit 1
fi

AUTH_HEADER="Authorization: Bearer $TOKEN"

# -------------------------------------------------------------------------------
# Helper functions
# -------------------------------------------------------------------------------

api_get() {
  local path="$1"
  curl -sf "${API_URL}${path}" -H "$AUTH_HEADER"
}

api_post() {
  local path="$1"; shift
  curl -sf -X POST "${API_URL}${path}" -H "$AUTH_HEADER" -H "Content-Type: application/json" "$@"
}

get_default_flow() {
  local designation="$1"
  api_get "/flows/instances/?designation=${designation}&ordering=slug" | jq -r '.results[0].pk'
}

get_signing_key() {
  api_get "/crypto/certificatekeypairs/?has_key=true&ordering=name" | jq -r '.results[0].pk'
}

write_env() {
  local var="$1"; local val="$2"
  if $DRY_RUN; then
    log_dry "Would write $var=<hidden> to .env"
  else
    if grep -q "^${var}=" "$ROOT_DIR/.env" 2>/dev/null; then
      sed -i "s|^${var}=.*|${var}=${val}|" "$ROOT_DIR/.env"
    else
      echo "${var}=${val}" >> "$ROOT_DIR/.env"
    fi
  fi
}

# -------------------------------------------------------------------------------
# Wait for Authentik to be ready
# -------------------------------------------------------------------------------
log_step "Waiting for Authentik API..."
for i in $(seq 1 30); do
  if curl -sf "$AUTHENTIK_URL/-/health/ready/" -o /dev/null; then
    log_info "Authentik is ready"
    break
  fi
  if [ "$i" -eq 30 ]; then
    log_error "Authentik did not become ready in 150s"
    exit 1
  fi
  echo -n "."
  sleep 5
done

# -------------------------------------------------------------------------------
# Create user groups
# -------------------------------------------------------------------------------
log_step "Creating user groups..."

create_group() {
  local name="$1"; local slug="$2"
  if $DRY_RUN; then
    log_dry "Would create group: $name (slug: $slug)"
    return
  fi

  local existing
  existing=$(api_get "/core/groups/?slug=${slug}" | jq -r '.results[0].pk // empty')
  if [ -n "$existing" ]; then
    log_info "  Group '$name' already exists (pk: $existing)"
    return
  fi

  local payload
  payload=$(jq -n --arg name "$name" --arg slug "$slug" '{name: $name, slug: $slug}')
  local result
  result=$(api_post "/core/groups/" -d "$payload")
  local pk
  pk=$(echo "$result" | jq -r '.pk')
  log_info "  Created group '$name' (pk: $pk)"
}

create_group "homelab-admins" "homelab-admins"
create_group "homelab-users" "homelab-users"
create_group "media-users" "media-users"

# -------------------------------------------------------------------------------
# Create OIDC provider + application
# -------------------------------------------------------------------------------
log_step "Creating OIDC providers..."

create_oidc_provider() {
  local name="$1"; local redirect_uri="$2"
  local client_id_var="$3"; local client_secret_var="$4"

  if $DRY_RUN; then
    log_dry "Would create provider: $name -> $redirect_uri"
    return
  fi

  log_info "  Creating provider: $name"

  local flow_pk signing_key slug
  flow_pk=$(get_default_flow authorize)
  signing_key=$(get_signing_key)
  slug=$(echo "$name" | tr '[:upper:]' '[:lower:]')

  local payload
  payload=$(jq -n \
    --arg name "${name} Provider" \
    --arg flow "$flow_pk" \
    --arg uri "$redirect_uri" \
    --arg key "$signing_key" \
    '{
      name: $name,
      authorization_flow: $flow,
      client_type: "confidential",
      redirect_uris: $uri,
      sub_mode: "hashed_user_id",
      include_claims_in_id_token: true,
      signing_key: $key
    }')

  local response
  response=$(api_post "/providers/oauth2/" -d "$payload")
  local provider_pk client_id client_secret
  provider_pk=$(echo "$response" | jq -r '.pk')
  client_id=$(echo "$response" | jq -r '.client_id')
  client_secret=$(echo "$response" | jq -r '.client_secret')

  log_info "    Provider PK:  $provider_pk"
  log_info "    Client ID:    $client_id"
  write_env "$client_id_var" "$client_id"
  write_env "$client_secret_var" "$client_secret"

  # Create application linking to this provider
  local app_payload
  app_payload=$(jq -n \
    --arg name "$name" \
    --arg slug "$slug" \
    --argjson pk "$provider_pk" \
    '{name: $name, slug: $slug, provider: $pk}')

  api_post "/core/applications/" -d "$app_payload" > /dev/null
  log_info "    Application '$name' created"
  echo -e "    ${GREEN}[OK]${RESET} Created provider: $name"
  echo -e "         Client ID: $client_id"
  echo -e "         Client Secret: $client_secret"
  echo -e "         Redirect URI: $redirect_uri"
  echo
}

# Grafana — OIDC
create_oidc_provider \
  "Grafana" \
  "https://grafana.${DOMAIN}/login/generic_oauth" \
  "GRAFANA_OAUTH_CLIENT_ID" \
  "GRAFANA_OAUTH_CLIENT_SECRET"

# Gitea — OIDC
create_oidc_provider \
  "Gitea" \
  "https://git.${DOMAIN}/user/oauth2/Authentik/callback" \
  "GITEA_OAUTH_CLIENT_ID" \
  "GITEA_OAUTH_CLIENT_SECRET"

# Outline — OIDC
create_oidc_provider \
  "Outline" \
  "https://outline.${DOMAIN}/auth/oidc.callback" \
  "OUTLINE_OAUTH_CLIENT_ID" \
  "OUTLINE_OAUTH_CLIENT_SECRET"

# Portainer — OAuth
create_oidc_provider \
  "Portainer" \
  "https://portainer.${DOMAIN}/" \
  "PORTAINER_OAUTH_CLIENT_ID" \
  "PORTAINER_OAUTH_CLIENT_SECRET"

# Nextcloud — OIDC (social login)
create_oidc_provider \
  "Nextcloud" \
  "https://nextcloud.${DOMAIN}/apps/sociallogin/custom_oidc/Authentik" \
  "NEXTCLOUD_OIDC_CLIENT_ID" \
  "NEXTCLOUD_OIDC_CLIENT_SECRET"

# Open WebUI — OIDC (accessible at ai.DOMAIN)
create_oidc_provider \
  "Open WebUI" \
  "https://ai.${DOMAIN}/auth" \
  "OPEN_WEBUI_OIDC_CLIENT_ID" \
  "OPEN_WEBUI_OIDC_CLIENT_SECRET"

# BookStack — OIDC
create_oidc_provider \
  "BookStack" \
  "https://wiki.${DOMAIN}/oidc2/Authentik/callback" \
  "BOOKSTACK_OIDC_CLIENT_ID" \
  "BOOKSTACK_OIDC_CLIENT_SECRET"

# -------------------------------------------------------------------------------
# ForwardAuth middleware for non-OIDC services
# -------------------------------------------------------------------------------
log_step "Creating Traefik ForwardAuth middleware..."

MIDDLEWARE_DIR="$ROOT_DIR/config/traefik/dynamic"
mkdir -p "$MIDDLEWARE_DIR"

if $DRY_RUN; then
  log_dry "Would create ForwardAuth middleware at $MIDDLEWARE_DIR/middlewares.yml"
else
  cat > "$MIDDLEWARE_DIR/middlewares.yml <<'EOF'
# =============================================================================
# Dynamic Traefik Middleware Configuration
# Auto-generated by setup-authentik.sh
# =============================================================================
http:
  middlewares:
    authentik-forwardauth:
      forwardAuth:
        address: "http://authentik-server:9000/outpost.goauthentik.io/auth/traefik"
        trustForwardHeader: true
        authResponseHeaders:
          - X-authentik-username
          - X-authentik-groups
          - X-authentik-email
          - X-authentik-name
          - X-authentik-meta-outpost
          - X-authentik-meta-jwt
EOF
  log_info "  ForwardAuth middleware written to $MIDDLEWARE_DIR/middlewares.yml"
  log_info "  Note: Add 'authentik-forwardauth@file' to any service's middleware list"
fi

# -------------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------------
log_step "SSO Setup Complete!"
log_info "All OIDC providers created and credentials written to .env"
echo
echo -e "${BOLD}Summary of created providers:${RESET}"
echo "  1. Grafana    → https://grafana.${DOMAIN}/login/generic_oauth"
echo "  2. Gitea      → https://git.${DOMAIN}/user/oauth2/Authentik/callback"
echo "  3. Outline    → https://outline.${DOMAIN}/auth/oidc.callback"
echo "  4. Portainer  → https://portainer.${DOMAIN}/"
echo "  5. Nextcloud  → https://nextcloud.${DOMAIN}/apps/sociallogin/custom_oidc/Authentik"
echo "  6. Open WebUI → https://webui.${DOMAIN}/auth"
echo "  7. BookStack  → https://wiki.${DOMAIN}/oidc2/Authentik/callback"
echo
echo -e "${BOLD}User groups created:${RESET}"
echo "  • homelab-admins  → Full admin access to all services"
echo "  • homelab-users   → Standard access to all services"
echo "  • media-users     → Access to media services only (Jellyfin, Jellyseerr)"
echo
echo -e "${BOLD}ForwardAuth middleware:${RESET}"
echo "  • File: $MIDDLEWARE_DIR/middlewares.yml"
echo "  • Usage: Add 'authentik-forwardauth@file' to service traefik labels"
echo
echo "Restart affected services to pick up new .env credentials."
if $DRY_RUN; then
  echo -e "${YELLOW}This was a dry run. No changes were actually made.${RESET}"
fi
