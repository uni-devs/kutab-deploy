#!/usr/bin/env bash
# Single-box (no Swarm) Kutab deployment via docker compose. Brings its own
# Traefik + MySQL + Valkey + app tier for one tenant on one VM.
#
#   deploy.sh <name> --tenant-domain <d> --acme-email <e>
#            [--custom-domain <d>] [--host-db|--bundled-db] [--with-whatsapp]
#            [--tls-mode le|cloudflare|le-dns-cloudflare] [--cf-dns-token <t>]
#            [--backend-image ..] [--frontend-image ..] [--nginx-image ..]
#            [--skip-migrate] [--dry-run]
#
# --host-db points the app at a MariaDB already installed on the host (see
# setup-db --mode host) instead of the bundled mysql container; it defaults to
# the node's recorded DB_MODE.
# --tls-mode picks how the origin gets its certificate:
#   le               Let's Encrypt via HTTP-01 (default) — for a domain pointed
#                    DIRECTLY at this box (no proxy in front).
#   cloudflare       origin serves a self-signed cert; the client's Cloudflare
#                    presents the real cert at its edge (set SSL/TLS = Full). No
#                    token, scales to any number of clients — use behind Cloudflare.
#   le-dns-cloudflare  Let's Encrypt via DNS-01 (needs --cf-dns-token for THAT
#                    zone). Optional/advanced; one token per Cloudflare zone.
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
WITH_WHATSAPP=false; SKIP_MIGRATE=false; DRY_RUN=false; HOST_DB=""
TLS_MODE="le"; CF_DNS_TOKEN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant-domain) TENANT_DOMAIN="$2"; shift 2 ;;
    --platform-base-domain) PLATFORM_BASE_DOMAIN="$2"; shift 2 ;;
    --custom-domain) CUSTOM_DOMAIN="$2"; shift 2 ;;
    --acme-email) ACME_EMAIL="$2"; shift 2 ;;
    --tls-mode) TLS_MODE="$2"; shift 2 ;;
    --cf-dns-token) CF_DNS_TOKEN="$2"; shift 2 ;;
    --backend-image) BACKEND_IMAGE="$2"; shift 2 ;;
    --frontend-image) FRONTEND_IMAGE="$2"; shift 2 ;;
    --nginx-image) NGINX_IMAGE="$2"; shift 2 ;;
    --with-whatsapp) WITH_WHATSAPP=true; shift ;;
    --host-db) HOST_DB=true; shift ;;
    --bundled-db) HOST_DB=false; shift ;;
    --skip-migrate) SKIP_MIGRATE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

require_slug "$NAME"
require_docker
docker compose version >/dev/null 2>&1 || fail "docker compose plugin is required. Run: kutab-deploy bootstrap-vm"
[[ -z "$TENANT_DOMAIN" && -n "$PLATFORM_BASE_DOMAIN" ]] && TENANT_DOMAIN="$NAME.$PLATFORM_BASE_DOMAIN"
[[ -n "$TENANT_DOMAIN" ]] || fail "--tenant-domain (or --platform-base-domain) is required"
[[ -n "$ACME_EMAIL" ]] || fail "--acme-email is required (Let's Encrypt registration)"

# default DB mode from what this node has (a host install → use the host DB)
if [[ -z "$HOST_DB" ]]; then
  [[ "$(node_state_get DB_MODE)" == host ]] && HOST_DB=true || HOST_DB=false
fi
DB_HOST_VALUE="mysql"; [[ "$HOST_DB" == true ]] && DB_HOST_VALUE="host.docker.internal"
HOST_DB_ROOT_PW_FILE="$(kutab_data_dir)/providers/swarm/secrets/infrastructure/host_db_root_password"

API_DOMAIN="api.$TENANT_DOMAIN"; WS_DOMAIN="ws.$TENANT_DOMAIN"
SQL_SLUG="$(printf '%s' "$NAME" | tr '-' '_' | tr -cd '[:alnum:]_')"
DATA_ROOT="$(provider_state_root "$(basename "$PROVIDER_ROOT")")"
DEPLOY_DIR="$DATA_ROOT/envs/$NAME"
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
DB_HOST=$DB_HOST_VALUE
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
REVERB_SCALING_ENABLED=true
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

# ── host DB: ensure the tenant DB + user exist on the host's MariaDB ────────────
if [[ "$HOST_DB" == true ]]; then
  log "Host DB mode: provisioning '$DB_DATABASE' on the host MariaDB (host.docker.internal)"
  have mariadb || have mysql || fail "--host-db needs the mariadb/mysql client on the host. Run: kutab-deploy swarm setup-db --mode host"
  [[ -f "$HOST_DB_ROOT_PW_FILE" ]] || fail "Host DB root password not found ($HOST_DB_ROOT_PW_FILE). Install it: kutab-deploy swarm setup-db --mode host --bind 172.17.0.1"
  host_root_pw="$(cat "$HOST_DB_ROOT_PW_FILE")"; db_cli=mariadb; have mariadb || db_cli=mysql
  if [[ "$DRY_RUN" != true ]]; then
    "$db_cli" -uroot -p"$host_root_pw" <<SQL || warn "Host DB provisioning failed — create $DB_DATABASE manually."
CREATE DATABASE IF NOT EXISTS \`$DB_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USERNAME'@'%' IDENTIFIED BY '$DB_PASSWORD';
ALTER USER '$DB_USERNAME'@'%' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`$DB_DATABASE\`.* TO '$DB_USERNAME'@'%';
FLUSH PRIVILEGES;
SQL
  fi
fi

# ── compose interpolation env ──────────────────────────────────────────────────
cat > "$DEPLOY_DIR/.env" <<EOF
TENANT_NAME=$NAME
KUTAB_ENV_DIR=$DEPLOY_DIR
TENANT_DOMAIN=$TENANT_DOMAIN
CUSTOM_DOMAIN=$CUSTOM_DOMAIN
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

# ── Traefik TLS strategy → traefik.env (regenerated every deploy; re-run to switch).
# 'cloudflare' = origin self-signed cert + the client's Cloudflare in "Full" mode
# (no token, scales to any number of clients). 'le'/'le-dns-cloudflare' = a real LE
# cert at the origin. Routers just set tls=true; the resolver (when any) is the
# websecure entrypoint default below, loaded by the traefik service via env_file.
case "$TLS_MODE" in le|cloudflare|le-dns-cloudflare) ;; *) fail "Unknown --tls-mode '$TLS_MODE' (use le|cloudflare|le-dns-cloudflare)";; esac
if [[ "$TLS_MODE" == le-dns-cloudflare ]]; then
  [[ -n "$CF_DNS_TOKEN" || ! -f "$DEPLOY_DIR/.cf_dns_token" ]] || CF_DNS_TOKEN="$(cat "$DEPLOY_DIR/.cf_dns_token")"
  [[ -n "$CF_DNS_TOKEN" ]] || fail "--tls-mode le-dns-cloudflare needs --cf-dns-token <token> for this zone (Zone:DNS:Edit + Zone:Read)."
fi
{
  if [[ "$TLS_MODE" == cloudflare ]]; then
    echo "# Cloudflare Full mode: origin serves Traefik's default self-signed cert."
    echo "# Cloudflare presents the real public cert at its edge — no ACME, no token."
  else
    echo "TRAEFIK_ENTRYPOINTS_WEBSECURE_HTTP_TLS_CERTRESOLVER=le"
    echo "TRAEFIK_CERTIFICATESRESOLVERS_LE_ACME_EMAIL=$ACME_EMAIL"
    echo "TRAEFIK_CERTIFICATESRESOLVERS_LE_ACME_STORAGE=/acme/acme.json"
    if [[ "$TLS_MODE" == le-dns-cloudflare ]]; then
      echo "TRAEFIK_CERTIFICATESRESOLVERS_LE_ACME_DNSCHALLENGE=true"
      echo "TRAEFIK_CERTIFICATESRESOLVERS_LE_ACME_DNSCHALLENGE_PROVIDER=cloudflare"
      echo "TRAEFIK_CERTIFICATESRESOLVERS_LE_ACME_DNSCHALLENGE_RESOLVERS=1.1.1.1:53,1.0.0.1:53"
      echo "CF_DNS_API_TOKEN=$CF_DNS_TOKEN"
    else
      echo "TRAEFIK_CERTIFICATESRESOLVERS_LE_ACME_HTTPCHALLENGE=true"
      echo "TRAEFIK_CERTIFICATESRESOLVERS_LE_ACME_HTTPCHALLENGE_ENTRYPOINT=web"
    fi
  fi
} > "$DEPLOY_DIR/traefik.env"
chmod 600 "$DEPLOY_DIR/traefik.env"
[[ "$TLS_MODE" == le-dns-cloudflare && "$DRY_RUN" != true ]] && { ( umask 077; printf '%s' "$CF_DNS_TOKEN" > "$DEPLOY_DIR/.cf_dns_token" ); chmod 600 "$DEPLOY_DIR/.cf_dns_token"; }
log "Traefik TLS mode: $TLS_MODE"

compose=(docker compose -p "kutab-$NAME" --env-file "$DEPLOY_DIR/.env" -f "$COMPOSE")
[[ "$HOST_DB" != true ]] && compose+=(--profile bundled-db)   # bundled mysql unless --host-db
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
node_state_set PROVIDER compose
node_state_append TENANTS "$NAME"
ok "Single-box deployment is up. Configure DNS (see the DNS step) and browse https://$TENANT_DOMAIN"
