#!/usr/bin/env bash
# The compose stack already ships a RAM-tuned MySQL container, so a separate DB
# setup is optional. This installs MariaDB on the HOST instead (e.g. to share one
# DB across compose projects, or to avoid the bundled container) — then deploy
# with `--host-db`. The host installer is provider-agnostic, so we reuse it.
# Tip: for a compose box, bind to the docker gateway so containers can reach it:
#   setup-db.sh --bind 172.17.0.1 [--buffer-pool-mb N] [--dry-run]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../../../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"

ui_host_installer="$KUTAB_ROOT/providers/swarm/scripts/setup-db.sh"
[[ -f "$ui_host_installer" ]] || fail "Shared host installer not found at $ui_host_installer"
log "Installing host MariaDB (the compose stack otherwise ships its own MySQL container)."
exec bash "$ui_host_installer" --mode host "$@"
