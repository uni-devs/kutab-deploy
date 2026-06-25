#!/usr/bin/env bash
# Update a compose deployment: pull latest images, recreate, run migrations.
#   update.sh <name> [--skip-migrate]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../../../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"

NAME="${1:?usage: update.sh <name> [--skip-migrate]}"; shift || true
SKIP_MIGRATE=false; [[ "${1:-}" == "--skip-migrate" ]] && SKIP_MIGRATE=true

DATA_ROOT="$(provider_state_root "$(basename "$PROVIDER_ROOT")")"
DIR="$DATA_ROOT/envs/$NAME"
[[ -f "$DIR/.env" ]] || fail "No compose deployment '$NAME' at $DIR"
require_docker
compose=(docker compose -p "kutab-$NAME" --env-file "$DIR/.env" -f "$PROVIDER_ROOT/templates/single-stack.compose.yml")

log "Pulling latest images for $NAME"
"${compose[@]}" pull
"${compose[@]}" up -d
if [[ "$SKIP_MIGRATE" != true ]]; then
  log "Running migrations"
  "${compose[@]}" exec -T backend sh -lc 'php artisan migrate --force' || warn "Migration failed — run it once MySQL is ready."
fi
ok "Updated compose deployment $NAME"
