#!/usr/bin/env bash
# Provider registry — discover/load deployment providers. Source me (needs KUTAB_ROOT).
#
# Each providers/<name>/provider.sh defines:
#   PROVIDER_NAME, PROVIDER_DESC
#   provider_actions   -> echoes one interactive menu label per line
#   provider_flow <label>  -> runs the interactive flow for that label
# Non-interactive actions map directly to providers/<name>/scripts/<action>.sh.

# names of providers that have a provider.sh
list_providers() {
  local d
  for d in "$KUTAB_ROOT"/providers/*/; do
    [[ -f "${d}provider.sh" ]] && basename "$d"
  done
}

# one-line description, read without polluting the current shell
provider_desc() {
  [[ -f "$KUTAB_ROOT/providers/$1/provider.sh" ]] || { printf ''; return; }
  bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${PROVIDER_DESC:-}"' _ "$KUTAB_ROOT/providers/$1/provider.sh"
}

# source a provider into the current shell; sets PROVIDER_DIR / PROVIDER_SCRIPTS
load_provider() {
  local name="$1" f="$KUTAB_ROOT/providers/$1/provider.sh"
  [[ -f "$f" ]] || fail "Unknown provider '$name'. Available: $(list_providers | tr '\n' ' ')"
  PROVIDER_DIR="$KUTAB_ROOT/providers/$name"
  PROVIDER_SCRIPTS="$PROVIDER_DIR/scripts"
  export PROVIDER_DIR PROVIDER_SCRIPTS
  # shellcheck disable=SC1090
  source "$f"
}

# non-interactive: run providers/<name>/scripts/<action>.sh with the rest of args
run_provider_script() {
  local name="$1" action="$2"; shift 2 || true
  local script="$KUTAB_ROOT/providers/$name/scripts/$action.sh"
  [[ -f "$script" ]] || fail "Provider '$name' has no action '$action' ($script not found)."
  exec bash "$script" "$@"
}
