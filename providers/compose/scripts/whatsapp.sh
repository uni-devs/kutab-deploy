#!/usr/bin/env bash
# Bring up (or restart) the WhatsApp gateway profile on a compose deployment.
#   whatsapp.sh <name>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../../../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"

NAME="${1:?usage: whatsapp.sh <name>}"
DIR="$PROVIDER_ROOT/envs/$NAME"
[[ -f "$DIR/.env" ]] || fail "No compose deployment '$NAME' at $DIR"
require_docker
compose=(docker compose -p "kutab-$NAME" --env-file "$DIR/.env" -f "$PROVIDER_ROOT/templates/single-stack.compose.yml" --profile whatsapp)

log "Starting WhatsApp gateway for $NAME"
"${compose[@]}" up -d whatsapp
ok "WhatsApp gateway is up (internal). Wire each tenant backend to it as documented."
