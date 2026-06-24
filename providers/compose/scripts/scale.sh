#!/usr/bin/env bash
# Scale a compose deployment's app tier (no Swarm needed). Traefik load-balances
# across frontend replicas; nginx fastcgi round-robins across backend replicas
# via the `app` network alias.
#   scale.sh <name> [--backend N] [--worker M] [--frontend K]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../../../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"

NAME="${1:?usage: scale.sh <name> [--backend N] [--worker M] [--frontend K]}"; shift
BE=""; WK=""; FE=""
while [[ $# -gt 0 ]]; do case "$1" in
  --backend) BE="$2"; shift 2;; --worker) WK="$2"; shift 2;; --frontend) FE="$2"; shift 2;;
  *) fail "Unknown option: $1";; esac; done

DIR="$PROVIDER_ROOT/envs/$NAME"
[[ -f "$DIR/.env" ]] || fail "No compose deployment '$NAME' at $DIR"
require_docker
compose=(docker compose -p "kutab-$NAME" --env-file "$DIR/.env" -f "$PROVIDER_ROOT/templates/single-stack.compose.yml")

scales=()
[[ -n "$BE" ]] && scales+=(--scale "backend=$BE")
[[ -n "$WK" ]] && scales+=(--scale "worker=$WK")
[[ -n "$FE" ]] && scales+=(--scale "frontend=$FE")
(( ${#scales[@]} )) || fail "Nothing to scale — pass --backend/--worker/--frontend"

log "Scaling $NAME: ${scales[*]}"
"${compose[@]}" up -d --no-recreate "${scales[@]}"
ok "Scaled. Current services:"
"${compose[@]}" ps
