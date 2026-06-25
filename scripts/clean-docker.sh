#!/usr/bin/env bash
# Tear down Kutab's Docker resources on this host. Scoped to Kutab by default
# (compose projects kutab-*, swarm stacks kutab*, their secrets + kutab networks).
# --volumes also deletes Kutab volumes (DATABASES + cert stores — data loss).
# --all additionally runs a FULL `docker system prune` (everything on the host,
# not just Kutab). --data also deletes the local data dir (plaintext secrets/envs).
# Every destructive step asks first unless --yes.
#
#   clean-docker.sh [--volumes] [--all] [--data] [--yes] [--dry-run]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"
# shellcheck source=../lib/tui.sh
source "$KUTAB_ROOT/lib/tui.sh"

WIPE_VOLUMES=false; ALL=false; WIPE_DATA=false; YES=false; DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --volumes) WIPE_VOLUMES=true; shift ;;
    --all) ALL=true; shift ;;
    --data) WIPE_DATA=true; shift ;;
    --yes|-y) YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done
require_docker

run() { if [[ "$DRY_RUN" == true ]]; then log "[dry-run] $*"; else "$@"; fi; }
ask() { [[ "$YES" == true ]] && return 0; ui_confirm "$1"; }
vsfx=""; [[ "$WIPE_VOLUMES" == true ]] && vsfx=" (incl. volumes)"

# ── 1) compose projects named kutab-* ───────────────────────────────────────────
mapfile -t projects < <(docker compose ls -a --format '{{.Name}}' 2>/dev/null | grep '^kutab-' || true)
if (( ${#projects[@]} )); then
  ui_title "Compose projects"
  for p in "${projects[@]}"; do
    ask "Remove compose project '$p'$vsfx?" || continue
    if [[ "$WIPE_VOLUMES" == true ]]; then run docker compose -p "$p" down -v --remove-orphans
    else run docker compose -p "$p" down --remove-orphans; fi
  done
else
  log "No kutab-* compose projects found."
fi

# ── 2) swarm stacks named kutab* + their secrets ────────────────────────────────
if docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active; then
  mapfile -t stacks < <(docker stack ls --format '{{.Name}}' 2>/dev/null | grep '^kutab' || true)
  if (( ${#stacks[@]} )); then
    ui_title "Swarm stacks"
    for s in "${stacks[@]}"; do ask "Remove swarm stack '$s'?" || continue; run docker stack rm "$s"; done
    log "Waiting for swarm tasks to stop…"; [[ "$DRY_RUN" == true ]] || sleep 8
  fi
  mapfile -t secs < <(docker secret ls --format '{{.Name}}' 2>/dev/null | grep -Ei 'kutab|wwebjs|mysql' || true)
  if (( ${#secs[@]} )) && ask "Remove ${#secs[@]} Kutab Docker secret(s)?"; then
    for s in "${secs[@]}"; do run docker secret rm "$s" >/dev/null 2>&1 || warn "secret $s still in use"; done
  fi
fi

# ── 3) leftover kutab networks ──────────────────────────────────────────────────
mapfile -t nets < <(docker network ls --format '{{.Name}}' 2>/dev/null | grep -E '^kutab' || true)
if (( ${#nets[@]} )) && ask "Remove ${#nets[@]} Kutab network(s)?"; then
  for n in "${nets[@]}"; do run docker network rm "$n" >/dev/null 2>&1 || warn "network $n still in use"; done
fi

# ── 4) kutab volumes (DATA LOSS — only with --volumes) ──────────────────────────
if [[ "$WIPE_VOLUMES" == true ]]; then
  mapfile -t vols < <(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E '^kutab' || true)
  if (( ${#vols[@]} )) && ask "DELETE ${#vols[@]} Kutab volume(s)? This destroys databases + cert stores."; then
    for v in "${vols[@]}"; do run docker volume rm "$v" >/dev/null 2>&1 || warn "volume $v still in use (retry after stacks fully stop)"; done
  fi
fi

# ── 5) --all: full host prune (NOT just Kutab) ──────────────────────────────────
if [[ "$ALL" == true ]]; then
  ui_warn "FULL prune removes ALL stopped containers, unused images + networks and the build cache on THIS HOST — not only Kutab."
  if ask "Run a full 'docker system prune' now?"; then
    if [[ "$WIPE_VOLUMES" == true ]]; then run docker system prune -af --volumes
    else run docker system prune -af; fi
  fi
fi

# ── 6) --data: wipe the local data dir (plaintext secrets + envs) ───────────────
if [[ "$WIPE_DATA" == true ]]; then
  d="$(kutab_data_dir)"
  if [[ -d "$d" ]] && ask "Delete the local data dir $d (plaintext secrets + generated envs)?"; then
    run rm -rf "$d"
  fi
fi

[[ "$DRY_RUN" == true ]] && ok "Docker cleanup dry run complete (nothing changed)." || ok "Docker cleanup complete."