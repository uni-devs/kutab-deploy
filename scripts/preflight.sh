#!/usr/bin/env bash
# Prerequisite checklist for the kutab-deploy console.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"
# shellcheck source=../lib/tui.sh
source "$KUTAB_ROOT/lib/tui.sh"

declare -a MISSING_REQUIRED=() MISSING_OPTIONAL=()

row_present() { printf '  %s✓%s %-10s %s\n' "$C_GREEN" "$C_RESET" "$1" "${2:-}"; }
row_missing() {
  if [[ "$2" == yes ]]; then
    printf '  %s✗%s %-10s %srequired%s — %s\n' "$C_RED" "$C_RESET" "$1" "$C_RED" "$C_RESET" "${3:-}"
    MISSING_REQUIRED+=("$1")
  else
    printf '  %s•%s %-10s %soptional%s — %s\n' "$C_YELLOW" "$C_RESET" "$1" "$C_YELLOW" "$C_RESET" "${3:-}"
    MISSING_OPTIONAL+=("$1")
  fi
}

check() { # check <cmd> <yes|no> <hint>
  if have "$1"; then row_present "$1" "$(command -v "$1")"; else row_missing "$1" "$2" "${3:-}"; fi
}

ui_title "Prerequisite check"
os="$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || uname -s)"
printf '  host : %s · %s vCPU · %s MB RAM\n\n' "$os" "$(detect_cpus)" "$(detect_ram_mb)"

check docker  yes "container runtime"
check openssl yes "secret generation"
check curl    yes "downloads / public IP"
check git     yes "config sync"
if docker compose version >/dev/null 2>&1; then
  row_present compose "docker compose plugin"
else
  row_missing compose no "needed for single-box deploy"
fi
check htpasswd no "apache2-utils — Traefik dashboard auth (deploy-infra)"
check jq       no "JSON parsing"
check gum      no "rich TUI (falls back to whiptail/plain)"
check sops     no "encrypted config sync"
check age      no "encryption key for sops"

printf '\n'
if swarm_active; then ui_ok "Swarm: active ($(is_manager && echo manager || echo worker))"; else ui_note "Swarm: inactive"; fi

printf '\n'
if (( ${#MISSING_REQUIRED[@]} )); then
  warn "Missing required tools: ${MISSING_REQUIRED[*]}"
  if [[ -t 0 ]] && ui_confirm "Run VM bootstrap now to install everything?"; then
    exec "$SCRIPT_DIR/bootstrap-vm.sh"
  fi
  exit 1
fi
(( ${#MISSING_OPTIONAL[@]} )) && ui_note "Optional missing: ${MISSING_OPTIONAL[*]} — 'Bootstrap this VM' installs these."
ok "All required prerequisites are present."
