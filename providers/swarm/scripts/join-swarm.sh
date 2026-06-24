#!/usr/bin/env bash
# Join this machine to an existing Swarm, then print the manager-side command to
# label it (workers cannot label themselves in Swarm).
#
#   join-swarm.sh --manager <ip:2377> --token <join-token>
#                 [--role shared|client] [--client-name <slug>] [--advertise-addr <ip>]
#
# On a MANAGER, get the worker token with:  docker swarm join-token worker -q
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../../../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"

MANAGER=""; TOKEN=""; NODE_ROLE="shared"; CLIENT_NAME=""; ADVERTISE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --manager) MANAGER="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --role) NODE_ROLE="$2"; shift 2 ;;
    --client-name) CLIENT_NAME="$2"; shift 2 ;;
    --advertise-addr) ADVERTISE="$2"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

require_docker
[[ "$(swarm_state)" != active ]] || fail "This node is already in a Swarm. Run 'docker swarm leave' first."
[[ -n "$MANAGER" ]] || fail "--manager <ip:2377> is required"
[[ -n "$TOKEN" ]] || fail "--token is required (get it on a manager: docker swarm join-token worker -q)"
[[ "$NODE_ROLE" == shared || "$NODE_ROLE" == client ]] || fail "--role must be shared|client"
if [[ "$NODE_ROLE" == client ]]; then
  [[ -n "$CLIENT_NAME" ]] || fail "--client-name is required for --role client"
  require_slug "$CLIENT_NAME"
fi
[[ "$MANAGER" == *:* ]] || MANAGER="$MANAGER:2377"

join=(docker swarm join --token "$TOKEN")
[[ -n "$ADVERTISE" ]] && join+=(--advertise-addr "$ADVERTISE")
join+=("$MANAGER")

log "Joining Swarm at $MANAGER ..."
"${join[@]}"
ok "Joined the Swarm."

HOST="$(hostname)"
label_cmd="kutab-deploy bootstrap-swarm --node $HOST --role $NODE_ROLE"
[[ "$NODE_ROLE" == client ]] && label_cmd+=" --client-name $CLIENT_NAME"

cat <<TXT

────────────────────────────────────────────────────────────────────────────
This node joined as a worker. Swarm labels can only be applied from a MANAGER.
Run this ON A MANAGER node to label it (role=$NODE_ROLE${CLIENT_NAME:+, client=$CLIENT_NAME}):

  $label_cmd

Verify afterwards:  docker node ls
────────────────────────────────────────────────────────────────────────────
TXT
