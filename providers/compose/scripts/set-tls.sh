#!/usr/bin/env bash
# Regenerate a compose deployment's traefik.env (switch the TLS / certificate
# strategy) and restart Traefik to apply it — without a full redeploy.
#   set-tls.sh <name> --tls-mode le|cloudflare|le-dns-cloudflare [--cf-dns-token <t>]
#
#   le               Let's Encrypt HTTP-01 (domain pointed directly at this box)
#   cloudflare       self-signed origin cert; set the domain's Cloudflare SSL = Full
#   le-dns-cloudflare  Let's Encrypt DNS-01 (needs --cf-dns-token for that zone)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../../../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"
# shellcheck source=../../../lib/tui.sh
source "$KUTAB_ROOT/lib/tui.sh"
DATA_ROOT="$(provider_state_root "$(basename "$PROVIDER_ROOT")")"

NAME="${1:?usage: set-tls.sh <name> --tls-mode <le|cloudflare|le-dns-cloudflare> [--cf-dns-token <t>]}"; shift
MODE=""; TOKEN=""
while [[ $# -gt 0 ]]; do case "$1" in
  --tls-mode) MODE="$2"; shift 2 ;;
  --cf-dns-token) TOKEN="$2"; shift 2 ;;
  -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
  *) fail "Unknown option: $1" ;;
esac; done
[[ -n "$MODE" ]] || fail "Pass --tls-mode le|cloudflare|le-dns-cloudflare"

DIR="$DATA_ROOT/envs/$NAME"; ENVF="$DIR/.env"
[[ -f "$ENVF" ]] || fail "No compose deployment '$NAME' at $DIR"
require_docker

EMAIL="$(grep -E '^ACME_EMAIL=' "$ENVF" | cut -d= -f2-)"
write_traefik_env "$DIR" "$EMAIL" "$MODE" "$TOKEN"

COMPOSE="$PROVIDER_ROOT/templates/single-stack.compose.yml"
compose=(docker compose -p "kutab-$NAME" --env-file "$ENVF" -f "$COMPOSE")
log "Switching $NAME to TLS mode '$MODE' and restarting Traefik"
"${compose[@]}" up -d traefik

[[ "$MODE" == cloudflare ]] && ui_note "Self-signed origin cert in use — set this domain's Cloudflare SSL/TLS mode to \"Full\"."
ok "Traefik TLS mode is now '$MODE' for $NAME (traefik.env regenerated)."
