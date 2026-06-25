#!/usr/bin/env bash
# Scale a compose deployment's app tier (no Swarm needed). nginx fastcgi
# round-robins across backend replicas via the `app` alias; Horizon spreads queue
# work; Traefik load-balances frontend/reverb (reverb uses a sticky cookie).
#   scale.sh <name> [--backend N] [--horizon M] [--frontend K] [--reverb R]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../../../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"

NAME="${1:?usage: scale.sh <name> [--backend N] [--horizon M] [--frontend K] [--reverb R]}"; shift
BE=""; HZ=""; FE=""; RV=""
while [[ $# -gt 0 ]]; do case "$1" in
  --backend) BE="$2"; shift 2;; --horizon) HZ="$2"; shift 2;;
  --frontend) FE="$2"; shift 2;; --reverb) RV="$2"; shift 2;;
  *) fail "Unknown option: $1";; esac; done

DATA_ROOT="$(provider_state_root "$(basename "$PROVIDER_ROOT")")"
DIR="$DATA_ROOT/envs/$NAME"
[[ -f "$DIR/.env" ]] || fail "No compose deployment '$NAME' at $DIR"
require_docker
compose=(docker compose -p "kutab-$NAME" --env-file "$DIR/.env" -f "$PROVIDER_ROOT/templates/single-stack.compose.yml")

scales=()
[[ -n "$BE" ]] && scales+=(--scale "backend=$BE")
[[ -n "$HZ" ]] && scales+=(--scale "horizon=$HZ")
[[ -n "$FE" ]] && scales+=(--scale "frontend=$FE")
[[ -n "$RV" ]] && scales+=(--scale "reverb=$RV")
(( ${#scales[@]} )) || fail "Nothing to scale — pass --backend/--horizon/--frontend/--reverb"

log "Scaling $NAME: ${scales[*]}"
"${compose[@]}" up -d --no-recreate "${scales[@]}"
ok "Scaled. Current services:"
"${compose[@]}" ps
