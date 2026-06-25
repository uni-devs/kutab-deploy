#!/usr/bin/env bash
set -euo pipefail

# Deploys the shared WhatsApp gateway (wwebjs-api) for all tenants.
#   deploy-whatsapp.sh [--whatsapp-pool shared] [--image <ref>]
#                      [--cluster-domain <domain>] [--force-secrets] [--dry-run]
#
# Re-run is safe (preserves the API key, secret, sessions volume and env file).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../../../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"   # node_state_* (local helpers below still win)
DATA_ROOT="$(provider_state_root "$(basename "$PROVIDER_ROOT")")"

WHATSAPP_POOL="${WHATSAPP_POOL:-shared}"
WHATSAPP_IMAGE="${WHATSAPP_IMAGE:-avoylenko/wwebjs-api:latest}"
CLUSTER_DOMAIN=""
FORCE_SECRETS=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --whatsapp-pool) WHATSAPP_POOL="$2"; shift 2 ;;
    --image) WHATSAPP_IMAGE="$2"; shift 2 ;;
    --cluster-domain) CLUSTER_DOMAIN="$2"; shift 2 ;;
    --force-secrets) FORCE_SECRETS=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '3,8p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
done

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
password() { openssl rand -base64 36 | tr -d '/+=' | head -c 40; }

command -v docker >/dev/null || fail "docker is required"
command -v openssl >/dev/null || fail "openssl is required"
docker info --format '{{.Swarm.LocalNodeState}}' | grep -q active \
  || fail "Swarm is not active. Run bootstrap-cluster.sh first."
docker network inspect kutab-shared >/dev/null 2>&1 \
  || fail "The kutab-shared overlay network is missing. Run bootstrap-cluster.sh first."

SECRET_DIR="$DATA_ROOT/secrets/infrastructure"
ENV_DIR="$DATA_ROOT/envs/infrastructure"
mkdir -p "$SECRET_DIR" "$ENV_DIR"
API_KEY_FILE="$SECRET_DIR/wwebjs_api_key"
TOKEN_FILE="$SECRET_DIR/wwebjs_webhook_token"
ENV_FILE="$ENV_DIR/whatsapp.env"

# ── API key: Swarm secret (consumed by the container) + saved file (for backends)
if docker secret inspect wwebjs_api_key >/dev/null 2>&1 && [[ "$FORCE_SECRETS" != true ]]; then
  log "Keeping existing wwebjs_api_key secret"
  [[ -f "$API_KEY_FILE" ]] || warn "Secret exists but $API_KEY_FILE is missing — tenant backends need this value as WWEBJS_API_KEY."
else
  if docker secret inspect wwebjs_api_key >/dev/null 2>&1; then
    [[ "$DRY_RUN" == true ]] || docker secret rm wwebjs_api_key >/dev/null
  fi
  API_KEY="$(password)"
  if [[ "$DRY_RUN" != true ]]; then
    printf '%s' "$API_KEY" | docker secret create wwebjs_api_key - >/dev/null
    ( umask 077; printf '%s' "$API_KEY" > "$API_KEY_FILE" )
    chmod 600 "$API_KEY_FILE"
  fi
  log "Created wwebjs_api_key secret (saved to $API_KEY_FILE)"
fi

# ── webhook token: validated by the tenant BACKEND, embedded in per-session URLs
if [[ ! -f "$TOKEN_FILE" || "$FORCE_SECRETS" == true ]]; then
  ( umask 077; password > "$TOKEN_FILE" )
  chmod 600 "$TOKEN_FILE"
  log "Generated webhook token (saved to $TOKEN_FILE)"
fi
WEBHOOK_TOKEN="$(cat "$TOKEN_FILE" 2>/dev/null || true)"

# ── whatsapp.env (read at deploy time): global flags + per-session webhook lines
if [[ ! -f "$ENV_FILE" ]]; then
  cat > "$ENV_FILE" <<'ENV'
# wwebjs-api environment (read by docker stack deploy).
LOG_LEVEL=info
# Per-tenant inbound webhooks — add ONE line per linked session, then re-run this
# script. Use the sanitised session id (no hyphens) as the prefix:
#   <SESSIONID>_WEBHOOK_URL=https://api.<tenant-domain>/api/admin/whatsapp/webhook?token=<WEBHOOK_TOKEN>
ENV
  chmod 600 "$ENV_FILE"
  log "Created $ENV_FILE (append per-session webhook lines as tenants link)"
fi

export CONFIG_ROOT="$PROVIDER_ROOT/configs"
export PROVIDER_ROOT WHATSAPP_IMAGE WHATSAPP_POOL
export WHATSAPP_CPU_LIMIT="${WHATSAPP_CPU_LIMIT:-2.0}"
export WHATSAPP_MEM_LIMIT="${WHATSAPP_MEM_LIMIT:-4096M}"
export WHATSAPP_CPU_RES="${WHATSAPP_CPU_RES:-0.50}"
export WHATSAPP_MEM_RES="${WHATSAPP_MEM_RES:-1024M}"

if [[ "$DRY_RUN" == true ]]; then
  log "Dry run: docker stack deploy --with-registry-auth -c $PROVIDER_ROOT/templates/whatsapp-stack.yml kutab-whatsapp"
  exit 0
fi

log "Deploying WhatsApp gateway (kutab-whatsapp) onto whatsapp_pool '$WHATSAPP_POOL' using image $WHATSAPP_IMAGE"
docker stack deploy --with-registry-auth -c "$PROVIDER_ROOT/templates/whatsapp-stack.yml" kutab-whatsapp
node_state_set WHATSAPP 1

log "Waiting for the gateway to converge (1/1)..."
for _ in $(seq 1 60); do
  rep="$(docker service ls --filter name=kutab-whatsapp_wwebjs-api --format '{{.Replicas}}' 2>/dev/null || true)"
  if [[ "$rep" == "1/1" ]]; then
    log "WhatsApp gateway is running ($rep)."
    break
  fi
  sleep 5
done

cat <<TXT

────────────────────────────────────────────────────────────────────────────
Next steps — set these on EACH tenant backend (backend.env), then redeploy it:
  WWEBJS_API_URL=http://wwebjs-api:3000
  WWEBJS_API_KEY=$(cat "$API_KEY_FILE" 2>/dev/null)
  WWEBJS_WEBHOOK_TOKEN=$WEBHOOK_TOKEN
  WWEBJS_DEFAULT_SESSION=<tenant-session-id>
  WWEBJS_DEFAULT_COUNTRY_CODE=<e.g. 20 or 966 — optional>

For each linked tenant, add its inbound webhook to:
  $ENV_FILE
    <SESSIONID>_WEBHOOK_URL=https://api.<tenant-domain>/api/admin/whatsapp/webhook?token=$WEBHOOK_TOKEN
then re-run this script.

The gateway is INTERNAL ONLY (no public route) — reachable at
http://wwebjs-api:3000 on the kutab-shared overlay.
────────────────────────────────────────────────────────────────────────────
TXT
