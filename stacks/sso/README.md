# SSO Stack — Authentik Unified Identity

Provides OIDC/SAML single sign-on for all HomeLab services via [Authentik](https://goauthentik.io/).

## Architecture

```
Browser
  │
  ▼
Traefik (443)
  │  ForwardAuth middleware → authentik-server:9000
  │
  ├── auth.DOMAIN     → Authentik UI (login, admin, user portal)
  ├── grafana.DOMAIN  → Grafana (OIDC)
  ├── git.DOMAIN      → Gitea (OIDC)
  ├── outline.DOMAIN  → Outline (OIDC)
  ├── nextcloud.DOMAIN → Nextcloud (OIDC via social login)
  ├── ai.DOMAIN        → Open WebUI (OIDC)
  ├── wiki.DOMAIN      → BookStack (OIDC)
  └── portainer.DOMAIN → Portainer (OAuth)

Internal:
  authentik-server ─┐
                    ├── postgresql:5432
  authentik-worker ─┘
                    └── redis:6379
```

## Services

| Service | Image | Port | Purpose |
|---------|-------|------|---------|
| authentik-server | `ghcr.io/goauthentik/server:2024.8.3` | 9000/9443 | Web UI + API + OIDC endpoints |
| authentik-worker | `ghcr.io/goauthentik/server:2024.8.3` | — | Background tasks (email, notifications) |
| postgresql | `postgres:16-alpine` | 5432 (internal) | Authentik database |
| redis | `redis:7-alpine` | 6379 (internal) | Session cache + task queue |

## Quick Start

```bash
# 1. Copy and fill environment variables
cd stacks/sso
cp .env.example .env
nano .env  # Fill ALL values marked REQUIRED

# 2. Generate secrets
export AUTHENTIK_SECRET_KEY=$(openssl rand -base64 32)
export AUTHENTIK_POSTGRES_PASSWORD=$(openssl rand -hex 16)
export AUTHENTIK_REDIS_PASSWORD=$(openssl rand -hex 16)
export AUTHENTIK_BOOTSTRAP_TOKEN=$(openssl rand -hex 32)

# Update .env with generated values
sed -i "s|^AUTHENTIK_SECRET_KEY=.*|AUTHENTIK_SECRET_KEY=$AUTHENTIK_SECRET_KEY|" .env
sed -i "s|^AUTHENTIK_POSTGRES_PASSWORD=.*|AUTHENTIK_POSTGRES_PASSWORD=$AUTHENTIK_POSTGRES_PASSWORD|" .env
sed -i "s|^AUTHENTIK_REDIS_PASSWORD=.*|AUTHENTIK_REDIS_PASSWORD=$AUTHENTIK_REDIS_PASSWORD|" .env
sed -i "s|^AUTHENTIK_BOOTSTRAP_TOKEN=.*|AUTHENTIK_BOOTSTRAP_TOKEN=$AUTHENTIK_BOOTSTRAP_TOKEN|" .env

# 3. Start the stack
docker compose up -d

# 4. Wait for healthy (takes ~60s on first run)
docker compose ps

# 5. Create OIDC providers for all services
../../scripts/setup-authentik.sh
```

## Auto-Setup Script

Run `../../scripts/setup-authentik.sh` — it automatically:

1. Waits for Authentik to be ready
2. Creates user groups: `homelab-admins`, `homelab-users`, `media-users`
3. Creates OIDC providers for all integrated services:
   - Grafana → `https://grafana.DOMAIN/login/generic_oauth`
   - Gitea → `https://git.DOMAIN/user/oauth2/Authentik/callback`
   - Outline → `https://outline.DOMAIN/auth/oidc.callback`
   - Portainer → `https://portainer.DOMAIN/`
   - Nextcloud → `https://nextcloud.DOMAIN/apps/sociallogin/custom_oidc/Authentik`
   - Open WebUI → `https://ai.DOMAIN/auth`
   - BookStack → `https://wiki.DOMAIN/oidc2/Authentik/callback`
4. Writes credentials to `.env`
5. Creates Traefik ForwardAuth middleware at `config/traefik/dynamic/authentik.yml`

### Dry Run

```bash
./scripts/setup-authentik.sh --dry-run
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `AUTHENTIK_SECRET_KEY` | YES | Random secret — `openssl rand -base64 32` |
| `AUTHENTIK_POSTGRES_PASSWORD` | YES | PostgreSQL password |
| `AUTHENTIK_REDIS_PASSWORD` | YES | Redis password |
| `AUTHENTIK_BOOTSTRAP_EMAIL` | YES | Initial admin email |
| `AUTHENTIK_BOOTSTRAP_PASSWORD` | YES | Initial admin password |
| `AUTHENTIK_BOOTSTRAP_TOKEN` | YES | API token for setup script |
| `AUTHENTIK_DOMAIN` | YES | e.g. `auth.yourdomain.com` |

## User Groups

Three groups are automatically created by `setup-authentik.sh`:

| Group | Access |
|-------|--------|
| `homelab-admins` | Full admin access to all services (Grafana Admin, Gitea admin, etc.) |
| `homelab-users` | Standard user access to all services |
| `media-users` | Access to media services only (Jellyfin, Jellyseerr) |

## Integrating New Services

### Option A: OIDC (for services with native OAuth2 support)

1. **Create provider in Authentik** (manually or add to `setup-authentik.sh`):

```bash
# Via Authentik admin UI:
# Applications > Create > OAuth2/OIDC Provider
#   Name: <ServiceName>
#   Client type: Confidential
#   Redirect URIs: <service-callback-url>
# Copy Client ID and Secret
```

2. **Add to your service's docker-compose.yml**:

```yaml
services:
  myservice:
    environment:
      OAUTH2_CLIENT_ID: ${MY_SERVICE_CLIENT_ID}
      OAUTH2_CLIENT_SECRET: ${MY_SERVICE_CLIENT_SECRET}
      OAUTH2_ISSUER: https://auth.DOMAIN/application/o/<slug>/
```

3. **Add environment variables to root `.env`**:

```bash
MY_SERVICE_CLIENT_ID=<from authentik>
MY_SERVICE_CLIENT_SECRET=<from authentik>
```

### Option B: Traefik ForwardAuth (for services without OAuth2)

For services that don't support OIDC natively, use the Traefik ForwardAuth middleware:

1. Add middleware to your service's traefik labels:

```yaml
labels:
  - "traefik.http.routers.<name>.middlewares=authentik@file"
```

2. The service will redirect to Authentik login page for unauthenticated requests.

3. After login, Authentik headers are passed to the service:
   - `X-authentik-username` — authenticated username
   - `X-authentik-groups` — comma-separated groups
   - `X-authentik-email` — user email

## ForwardAuth Middleware

The `config/traefik/dynamic/authentik.yml` provides two middlewares:

| Middleware | Use Case |
|------------|----------|
| `authentik` | Full SSO redirect — unauthenticated users go to login page |
| `authentik-basic` | Lightweight 401 check — returns 401 instead of redirect |

Usage:

```yaml
# docker-compose.yml labels
traefik.http.routers.<name>.middlewares: authentik@file
```

## CN Mirror

If `ghcr.io` is inaccessible, edit `docker-compose.yml` and uncomment the CN mirror lines:

```yaml
# image: swr.cn-north-4.myhuaweicloud.com/ddn-k8s/ghcr.io/goauthentik/server:2024.8.3
```

## Health Check

```bash
# All containers healthy
docker compose ps

# Authentik API responding
curl -sf https://auth.DOMAIN/-/health/ready/ && echo OK

# Check admin UI accessible
curl -sf https://auth.DOMAIN/if/admin/ -o /dev/null && echo OK
```

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Container exits immediately | Check `AUTHENTIK_SECRET_KEY` is set and non-empty |
| DB connection refused | Wait 30s for PostgreSQL to initialize; check `AUTHENTIK_POSTGRES_PASSWORD` matches |
| OIDC redirect mismatch | Ensure `redirect_uris` in Authentik provider matches exact callback URL |
| ForwardAuth loop | Ensure authentik outpost URL uses internal hostname `authentik-server:9000` not public domain |
| `ghcr.io` pull timeout | Switch to CN mirror in docker-compose.yml |
| Provider not found | Run `./scripts/setup-authentik.sh` to create all OIDC providers |
