#!/usr/bin/env bash
# Single-box (no Swarm) Kutab deployment via docker compose. Brings its own
# Traefik + MySQL + Valkey + app tier for one tenant on one VM.
#
#   single-deploy.sh <name> --tenant-domain <d> --acme-email <e>
#                    [--custom-domain <d>] [--backend-image ..] [--frontend-image ..]
#                    [--nginx-image ..] [--with-whatsapp] [--skip-migrate] [--dry-run]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../../../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"

NAME="${1:-}"; [[ $# -gt 0 ]] && shift
TENANT_DOMAIN=""; CUSTOM_DOMAIN=""; ACME_EMAIL=""; PLATFORM_BASE_DOMAIN=""
BACKEND_IMAGE="${BACKEND_IMAGE:-ghcr.io/uni-devs/kutab-api:latest}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-ghcr.io/uni-devs/kutab-front:latest}"
NGINX_IMAGE="${NGINX_IMAGE:-ghcr.io/uni-devs/kutab-api-nginx:latest}"
WITH_WHATSAPP=false; SKIP_MIGRATE=false; DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant-domain) TENANT_DOMAIN="$2"; shift 2 ;;
    --platform-base-domain) PLATFORM_BASE_DOMAIN="$2"; shift 2 ;;
    --custom-domain) CUSTOM_DOMAIN="$2"; shift 2 ;;
    --acme-email) ACME_EMAIL="$2"; shift 2 ;;
    --backend-image) BACKEND_IMAGE="$2"; shift 2 ;;
    --frontend-image) FRONTEND_IMAGE="$2"; shift 2 ;;
    --nginx-image) NGINX_IMAGE="$2"; shift 2 ;;
    --with-whatsapp) WITH_WHATSAPP=true; shift ;;
    --skip-migrate) SKIP_MIGRATE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

require_slug "$NAME"
require_docker
docker compose version >/dev/null 2>&1 || fail "docker compose plugin is required. Run: kutab-deploy bootstrap-vm"
[[ -z "$TENANT_DOMAIN" && -n "$PLATFORM_BASE_DOMAIN" ]] && TENANT_DOMAIN="$NAME.$PLATFORM_BASE_DOMAIN"
[[ -n "$TENANT_DOMAIN" ]] || fail "--tenant-domain (or --platform-base-domain) is required"
[[ -n "$ACME_EMAIL" ]] || fail "--acme-email is required (Let's Encrypt registration)"

API_DOMAIN="api.$TENANT_DOMAIN"; WS_DOMAIN="ws.$TENANT_DOMAIN"
SQL_SLUG="$(printf '%s' "$NAME" | tr '-' '_' | tr -cd '[:alnum:]_')"
DEPLOY_DIR="$PROVIDER_ROOT/envs/$NAME"
COMPOSE="$PROVIDER_ROOT/templates/single-stack.compose.yml"
BP_MB="$(suggested_buffer_pool_mb)"

host_rule() { local r=""; for h in "$@"; do [[ -n "$h" ]] || continue; if [[ -z "$r" ]]; then r="Host(\`$h\`)"; else r="$r || Host(\`$h\`)"; fi; done; printf '%s' "$r"; }

mkdir -p "$DEPLOY_DIR"; chmod 700 "$DEPLOY_DIR"

# ── generate env files once (idempotent) ───────────────────────────────────────
if [[ ! -f "$DEPLOY_DIR/backend.env" ]]; then
  APP_KEY="base64:$(openssl rand -base64 32)"
  JWT_SECRET="$(password)"; DB_PASSWORD="$(password)"; MYSQL_ROOT_PASSWORD="$(password)"; REDIS_PASSWORD="$(password)"
  REVERB_APP_ID="$(password)"; REVERB_APP_KEY="$(password)"; REVERB_APP_SECRET="$(password)"
  cat > "$DEPLOY_DIR/backend.env" <<EOF
APP_NAME="$NAME"
APP_ENV=production
APP_KEY=$APP_KEY
APP_DEBUG=false
KUTAB_TENANT_NAME=$NAME
METRICS_ENABLED=true
APP_URL=https://$TENANT_DOMAIN
APP_FRONTEND_URL=https://$TENANT_DOMAIN
JWT_SECRET=$JWT_SECRET
DB_CONNECTION=mysql
DB_HOST=mysql
DB_PORT=3306
DB_DATABASE=kutab_$SQL_SLUG
DB_USERNAME=kutab_$SQL_SLUG
DB_PASSWORD=$DB_PASSWORD
REDIS_HOST=valkey
REDIS_PORT=6379
REDIS_PASSWORD=$REDIS_PASSWORD
QUEUE_CONNECTION=redis
CACHE_STORE=redis
SESSION_DRIVER=redis
REVERB_APP_ID=$REVERB_APP_ID
REVERB_APP_KEY=$REVERB_APP_KEY
REVERB_APP_SECRET=$REVERB_APP_SECRET
REVERB_HOST=$WS_DOMAIN
REVERB_PORT=443
REVERB_SCHEME=https
LOG_CHANNEL=stderr
LOG_LEVEL=info
EOF
  cat > "$DEPLOY_DIR/frontend.env" <<EOF
NUXT_PUBLIC_APP_URL=https://$TENANT_DOMAIN
NUXT_PUBLIC_API_BASE=https://$API_DOMAIN/api
NUXT_PUBLIC_REVERB_HOST=$WS_DOMAIN
NUXT_PUBLIC_REVERB_PORT=443
NUXT_PUBLIC_REVERB_SCHEME=https
NUXT_PUBLIC_REVERB_APP_KEY=$REVERB_APP_KEY
EOF
  chmod 600 "$DEPLOY_DIR/backend.env" "$DEPLOY_DIR/frontend.env"
  log "Generated env files in $DEPLOY_DIR"
else
  log "Using existing env files in $DEPLOY_DIR"
fi

# pull DB creds + redis pw back out of backend.env for the compose .env
DB_DATABASE="$(grep -E '^DB_DATABASE=' "$DEPLOY_DIR/backend.env" | cut -d= -f2-)"
DB_USERNAME="$(grep -E '^DB_USERNAME=' "$DEPLOY_DIR/backend.env" | cut -d= -f2-)"
DB_PASSWORD="$(grep -E '^DB_PASSWORD=' "$DEPLOY_DIR/backend.env" | cut -d= -f2-)"
MYSQL_ROOT_PASSWORD="$( [[ -f "$DEPLOY_DIR/.mysql_root" ]] && cat "$DEPLOY_DIR/.mysql_root" || password )"
( umask 077; printf '%s' "$MYSQL_ROOT_PASSWORD" > "$DEPLOY_DIR/.mysql_root" )

# ── compose interpolation env ──────────────────────────────────────────────────
cat > "$DEPLOY_DIR/.env" <<EOF
TENANT_NAME=$NAME
KUTAB_ENV_DIR=$DEPLOY_DIR
ACME_EMAIL=$ACME_EMAIL
BACKEND_IMAGE=$BACKEND_IMAGE
FRONTEND_IMAGE=$FRONTEND_IMAGE
NGINX_IMAGE=$NGINX_IMAGE
DB_DATABASE=$DB_DATABASE
DB_USERNAME=$DB_USERNAME
DB_PASSWORD=$DB_PASSWORD
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
DB_BUFFER_POOL=${BP_MB}M
API_HOST_RULE=$(host_rule "$API_DOMAIN")
WS_HOST_RULE=$(host_rule "$WS_DOMAIN")
FRONTEND_HOST_RULE=$(host_rule "$TENANT_DOMAIN" "$CUSTOM_DOMAIN")
EOF
chmod 600 "$DEPLOY_DIR/.env"

compose=(docker compose -p "kutab-$NAME" --env-file "$DEPLOY_DIR/.env" -f "$COMPOSE")
[[ "$WITH_WHATSAPP" == true ]] && compose+=(--profile whatsapp)

if [[ "$DRY_RUN" == true ]]; then
  log "Dry run — validating compose config:"
  "${compose[@]}" config >/dev/null && ok "compose config is valid" || fail "compose config invalid"
  exit 0
fi

log "Starting single-box stack for '$NAME' ($TENANT_DOMAIN)"
"${compose[@]}" pull --quiet 2>/dev/null || true
"${compose[@]}" up -d

if [[ "$SKIP_MIGRATE" != true ]]; then
  log "Waiting for the database, then migrating…"
  sleep 25
  "${compose[@]}" exec -T backend sh -lc 'php artisan migrate --force && php artisan db:seed --force' \
    || warn "Migration step failed — run it manually once MySQL is ready: ${compose[*]} exec backend php artisan migrate --force"
fi
ok "Single-box deployment is up. Configure DNS (see the DNS step) and browse https://$TENANT_DOMAIN"
