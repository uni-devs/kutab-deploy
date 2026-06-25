#!/usr/bin/env bash
# Update a running deployment to the latest image for its current tag, then run
# migrations. Works for Swarm stacks (re-resolves each service's image digest)
# and single-box compose projects (pull + up).
#
#   update-deployment.sh [--target <stack|single:name>] [--all] [--skip-migrate] [--dry-run]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../../../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"
# shellcheck source=../../../lib/tui.sh
source "$KUTAB_ROOT/lib/tui.sh"

DATA_ROOT="$(provider_state_root "$(basename "$PROVIDER_ROOT")")"

TARGET=""; ALL=false; SKIP_MIGRATE=false; DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --all) ALL=true; shift ;;
    --skip-migrate) SKIP_MIGRATE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done
require_docker

swarm_stacks() { swarm_active && docker stack ls --format '{{.Name}}' 2>/dev/null | grep '^kutab' || true; }
single_projects() { ls -1 "$DATA_ROOT/envs/single" 2>/dev/null || true; }

# update one Swarm stack: bump every service to its tag's current digest
update_swarm_stack() {
  local stack="$1" svc img base
  for svc in $(docker stack services "$stack" --format '{{.Name}}' 2>/dev/null); do
    img="$(docker service inspect "$svc" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null)"
    base="${img%@*}"   # strip @sha256:… so the tag is re-resolved (re-pulled)
    if [[ "$DRY_RUN" == true ]]; then log "[dry-run] $svc -> $base"; continue; fi
    log "Updating $svc -> $base"
    docker service update --with-registry-auth --image "$base" "$svc" >/dev/null \
      || warn "Failed to update $svc"
  done
  # tenant stacks: run migrations through a one-off CLI container
  local name="${stack#kutab-}" envf="$DATA_ROOT/envs/tenants/${stack#kutab-}/backend.env"
  if [[ "$SKIP_MIGRATE" != true && -f "$envf" && "$DRY_RUN" != true ]]; then
    local bimg; bimg="$(docker service inspect "${stack}_backend" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null || true)"; bimg="${bimg%@*}"
    if [[ -n "$bimg" ]]; then
      log "Running migrations for $name"
      docker run --rm --network "${stack}_tenant-internal" --env-file "$envf" -e CONTAINER_MODE=cli "$bimg" \
        sh -lc 'php artisan migrate --force' || warn "Migration failed for $name"
    fi
  fi
  ok "Updated stack $stack"
}

update_single() {
  local name="$1" dir="$DATA_ROOT/envs/single/$name"
  [[ -f "$dir/.env" ]] || fail "No single-box project at $dir"
  local compose=(docker compose -p "kutab-$name" --env-file "$dir/.env" -f "$PROVIDER_ROOT/templates/single-stack.compose.yml")
  if [[ "$DRY_RUN" == true ]]; then log "[dry-run] ${compose[*]} pull && up -d"; return; fi
  "${compose[@]}" pull
  "${compose[@]}" up -d
  [[ "$SKIP_MIGRATE" == true ]] || "${compose[@]}" exec -T backend sh -lc 'php artisan migrate --force' || warn "Migration failed"
  ok "Updated single-box project $name"
}

dispatch() { # dispatch <target>
  case "$1" in
    single:*) update_single "${1#single:}" ;;
    *) update_swarm_stack "$1" ;;
  esac
}

if [[ "$ALL" == true ]]; then
  for s in $(swarm_stacks); do dispatch "$s"; done
  for p in $(single_projects); do dispatch "single:$p"; done
  exit 0
fi

if [[ -z "$TARGET" ]]; then
  mapfile -t opts < <(swarm_stacks; single_projects | sed 's/^/single:/')
  (( ${#opts[@]} )) || fail "Nothing deployed to update."
  TARGET="$(ui_menu "Update which deployment?" "${opts[@]}")"
  [[ -n "$TARGET" ]] || fail "Cancelled."
fi
ui_confirm "Update '$TARGET' to the latest images now?" || { ui_note "Cancelled."; exit 0; }
dispatch "$TARGET"
