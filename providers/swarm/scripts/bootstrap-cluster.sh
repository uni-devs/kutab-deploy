#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../../../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"   # node_state_* + helpers (local log/fail below still win)

# bootstrap-cluster.sh [advertise-addr] [--advertise-addr X] [--role shared|client]
#                      [--client-name <slug>] [--node <hostname|id>]
# Inits the Swarm (if needed) and labels a node. --node lets a MANAGER label an
# already-joined worker; default target is the local node.
CLUSTER_ADVERTISE_ADDR=""
NODE_ROLE="shared"
CLIENT_NAME=""
TARGET_NODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --advertise-addr) CLUSTER_ADVERTISE_ADDR="$2"; shift 2 ;;
    --role) NODE_ROLE="$2"; shift 2 ;;
    --client-name) CLIENT_NAME="$2"; shift 2 ;;
    --node) TARGET_NODE="$2"; shift 2 ;;
    -h|--help) sed -n '1,6p' "$0"; exit 0 ;;
    --*) printf '[ERROR] Unknown option: %s\n' "$1" >&2; exit 64 ;;
    *) CLUSTER_ADVERTISE_ADDR="$1"; shift ;;
  esac
done

[[ "$NODE_ROLE" == shared || "$NODE_ROLE" == client ]] || { printf '[ERROR] --role must be shared|client\n' >&2; exit 64; }
POOL="shared"
if [[ "$NODE_ROLE" == client ]]; then
  [[ -n "$CLIENT_NAME" ]] || { printf '[ERROR] --client-name is required for --role client\n' >&2; exit 64; }
  [[ "$CLIENT_NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { printf '[ERROR] invalid client name: %s\n' "$CLIENT_NAME" >&2; exit 64; }
  POOL="$CLIENT_NAME"
fi

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || fail "docker is required"

# secrets + generated env files live OFF the code tree (data dir); only the
# config templates below stay in the repo.
DATA_ROOT="$(provider_state_root "$(basename "$PROVIDER_ROOT")")"
mkdir -p \
  "$DATA_ROOT/envs/infrastructure" \
  "$DATA_ROOT/envs/tenants" \
  "$DATA_ROOT/secrets/infrastructure" \
  "$DATA_ROOT/secrets/tenants" \
  "$PROVIDER_ROOT/configs/traefik/dynamic" \
  "$PROVIDER_ROOT/configs/traefik/auth" \
  "$PROVIDER_ROOT/configs/prometheus" \
  "$PROVIDER_ROOT/configs/prometheus/rules" \
  "$PROVIDER_ROOT/configs/alertmanager" \
  "$PROVIDER_ROOT/configs/loki" \
  "$PROVIDER_ROOT/configs/promtail" \
  "$PROVIDER_ROOT/configs/grafana/provisioning/datasources" \
  "$PROVIDER_ROOT/configs/grafana/provisioning/dashboards" \
  "$PROVIDER_ROOT/configs/grafana/dashboards"

chmod 700 "$DATA_ROOT" "$DATA_ROOT/envs" "$DATA_ROOT/secrets" 2>/dev/null || true

state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)"
if [[ "$state" != "active" ]]; then
  if [[ -n "$CLUSTER_ADVERTISE_ADDR" ]]; then
    log "Initializing Swarm with advertise address $CLUSTER_ADVERTISE_ADDR"
    docker swarm init --advertise-addr "$CLUSTER_ADVERTISE_ADDR"
  else
    log "Initializing Swarm"
    docker swarm init
  fi
else
  log "Swarm is already active"
fi

node_id="${TARGET_NODE:-$(docker info --format '{{.Swarm.NodeID}}')}"
log "Labelling node '$node_id' as role=$NODE_ROLE pool=$POOL"
label_args=(
  --label-add kutab.app=true
  --label-add kutab.db=true
  --label-add kutab.cache=true
  --label-add kutab.whatsapp=true
  --label-add kutab.role="$NODE_ROLE"
  --label-add kutab.app_pool="$POOL"
  --label-add kutab.db_pool="$POOL"
  --label-add kutab.cache_pool="$POOL"
  --label-add kutab.whatsapp_pool="$POOL"
)
# Keep central monitoring singletons on shared nodes; client boxes only run agents.
if [[ "$NODE_ROLE" == client ]]; then
  label_args+=( --label-add kutab.client="$CLIENT_NAME" --label-add kutab.monitoring=false )
else
  label_args+=( --label-add kutab.monitoring=true )
fi
docker node update "${label_args[@]}" "$node_id" >/dev/null

if docker network inspect kutab-shared >/dev/null 2>&1; then
  driver="$(docker network inspect kutab-shared --format '{{.Driver}}')"
  scope="$(docker network inspect kutab-shared --format '{{.Scope}}')"
  attachable="$(docker network inspect kutab-shared --format '{{.Attachable}}')"
  [[ "$driver" == "overlay" && "$scope" == "swarm" && "$attachable" == "true" ]] \
    || fail "kutab-shared exists but is not an attachable swarm overlay network"
  log "Shared overlay network already exists"
else
  log "Creating shared overlay network kutab-shared"
  docker network create --driver overlay --attachable kutab-shared >/dev/null
fi

docker swarm update --task-history-limit 2 >/dev/null || warn "Could not update task history limit"

# record what this node is, so the console can reason about it
node_state_set PROVIDER swarm
node_state_set SWARM_ROLE "$(is_manager && echo manager || echo worker)"
node_state_set NODE_KIND "$NODE_ROLE"
[[ "$NODE_ROLE" == client ]] && node_state_set CLIENT_NAME "$CLIENT_NAME"

log "Swarm bootstrap is ready"
