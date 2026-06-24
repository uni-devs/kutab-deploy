#!/usr/bin/env bash
# The compose stack already ships a RAM-tuned MySQL container, so a separate DB
# setup is optional. This installs MySQL 8.4 on the HOST instead (e.g. to share
# one DB across compose projects on the box). The host installer is host-level
# and provider-agnostic, so we reuse the shared one.
#   setup-db.sh [--buffer-pool-mb N] [--bind 127.0.0.1] [--dry-run]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../../../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"

ui_host_installer="$KUTAB_ROOT/providers/swarm/scripts/setup-db.sh"
[[ -f "$ui_host_installer" ]] || fail "Shared host installer not found at $ui_host_installer"
log "Installing host MySQL 8.4 (the compose stack otherwise ships its own MySQL)."
exec bash "$ui_host_installer" --mode host "$@"
