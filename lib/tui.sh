#!/usr/bin/env bash
# TUI helpers — gum preferred, whiptail fallback, plain text last. Source me.
# Depends on colour vars from common.sh (with safe defaults below).

: "${C_BOLD:=}"; : "${C_RESET:=}"; : "${C_DIM:=}"; : "${C_CYAN:=}"; : "${C_YELLOW:=}"

if command -v gum >/dev/null 2>&1;       then UI_BACKEND=gum
elif command -v whiptail >/dev/null 2>&1; then UI_BACKEND=whiptail
else                                          UI_BACKEND=plain; fi
export UI_BACKEND

APP_TITLE="${APP_TITLE:-Kutab Deploy}"
GUM_ACCENT="${GUM_ACCENT:-39}"     # blue-cyan (kutab brand-ish)

# Tasteful palette for the whiptail fallback (replaces the default magenta).
export NEWT_COLORS="${NEWT_COLORS:-root=,black
border=brightcyan,black
title=brightcyan,black
button=black,cyan
actbutton=black,brightcyan
listbox=white,black
actlistbox=black,cyan
sellistbox=black,cyan
actsellistbox=black,brightcyan
textbox=white,black
entry=white,black
actcheckbox=black,cyan}"

# Offer to install gum (the cool TUI). Returns 0 if gum is usable afterwards.
ensure_gum() {
  command -v gum >/dev/null 2>&1 && { UI_BACKEND=gum; return 0; }
  printf 'This console looks best with gum (charmbracelet). Install it now? [Y/n] ' >&2
  local a; read -r a
  [[ "$a" =~ ^[Nn] ]] && return 1
  command -v apt-get >/dev/null 2>&1 || { printf 'Auto-install needs apt (Debian/Ubuntu); install gum manually.\n' >&2; return 1; }
  local SUDO=""; [[ "$(id -u)" -ne 0 ]] && SUDO="sudo"
  $SUDO install -m 0755 -d /etc/apt/keyrings 2>/dev/null || true
  curl -fsSL https://repo.charm.sh/apt/gpg.key 2>/dev/null | $SUDO gpg --dearmor -o /etc/apt/keyrings/charm.gpg 2>/dev/null || true
  echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | $SUDO tee /etc/apt/sources.list.d/charm.list >/dev/null 2>&1 || true
  $SUDO apt-get update -qq >/dev/null 2>&1 && $SUDO apt-get install -y -qq gum >/dev/null 2>&1 || true
  command -v gum >/dev/null 2>&1 && { UI_BACKEND=gum; return 0; }
  return 1
}

ui_banner() { # ui_banner "subtitle line"
  local sub="${1:-}"
  case "$UI_BACKEND" in
    gum)
      gum style --border double --margin "1 0" --padding "1 4" --border-foreground "$GUM_ACCENT" \
        "$(gum style --foreground "$GUM_ACCENT" --bold 'KUTAB · DEPLOY')" "$sub"
      ;;
    *) printf '\n%s┌─ %s ─┐%s\n%s\n\n' "$C_BOLD" "$APP_TITLE" "$C_RESET" "$sub" ;;
  esac
}

ui_title() { case "$UI_BACKEND" in gum) gum style --bold --foreground "$GUM_ACCENT" "$*";; *) printf '%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET";; esac; }
ui_note()  { case "$UI_BACKEND" in gum) gum style --foreground 244 "$*";; *) printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET";; esac; }
ui_ok()    { case "$UI_BACKEND" in gum) gum style --foreground 42 "✓ $*";; *) printf '%s✓ %s%s\n' "$C_CYAN" "$*" "$C_RESET";; esac; }
ui_warn()  { case "$UI_BACKEND" in gum) gum style --foreground 214 "! $*";; *) printf '%s! %s%s\n' "$C_YELLOW" "$*" "$C_RESET";; esac >&2; }

# ui_menu "Header" "item1" "item2" ...  -> prints the chosen item to stdout
ui_menu() {
  local header="$1"; shift
  case "$UI_BACKEND" in
    gum) gum choose --header "$header" "$@" ;;
    whiptail)
      # tag = visible label, item = "" (no --notags, or the rows render blank)
      local args=() it; for it in "$@"; do args+=("$it" ""); done
      whiptail --title "$APP_TITLE" --menu "$header" 22 78 14 "${args[@]}" 3>&1 1>&2 2>&3
      ;;
    plain)
      local opts=("$@") i=1 it choice
      printf '%s%s%s\n' "$C_BOLD" "$header" "$C_RESET" >&2
      for it in "${opts[@]}"; do printf '  %2d) %s\n' "$i" "$it" >&2; ((i++)); done
      read -rp '  select> ' choice
      [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#opts[@]} )) && printf '%s' "${opts[choice-1]}"
      ;;
  esac
}

# ui_input "prompt" ["default"]
ui_input() {
  local prompt="$1" def="${2:-}"
  case "$UI_BACKEND" in
    gum) gum input --prompt "$prompt ❯ " ${def:+--value "$def"} ;;
    whiptail) whiptail --title "$APP_TITLE" --inputbox "$prompt" 10 72 "$def" 3>&1 1>&2 2>&3 ;;
    plain) local v; read -rp "$prompt${def:+ [$def]}: " v; printf '%s' "${v:-$def}" ;;
  esac
}

# ui_password "prompt"  -> prints the entered secret to stdout (masked input)
ui_password() {
  local prompt="$1"
  case "$UI_BACKEND" in
    gum) gum input --password --prompt "$prompt ❯ " ;;
    whiptail) whiptail --title "$APP_TITLE" --passwordbox "$prompt" 10 72 3>&1 1>&2 2>&3 ;;
    plain) local v; read -rsp "$prompt: " v; printf '\n' >&2; printf '%s' "$v" ;;
  esac
}

# ui_confirm "prompt"  -> exit 0 = yes, 1 = no
ui_confirm() {
  local prompt="$1"
  case "$UI_BACKEND" in
    gum) gum confirm "$prompt" ;;
    whiptail) whiptail --title "$APP_TITLE" --yesno "$prompt" 10 72 ;;
    plain) local v; read -rp "$prompt [y/N]: " v; [[ "$v" =~ ^[Yy] ]] ;;
  esac
}

# ui_box "title"  < content   -> bordered block (gum) or fenced text
ui_box() {
  local title="${1:-}"
  if [[ "$UI_BACKEND" == gum ]]; then
    gum style --border rounded --padding "0 2" --margin "1 0" --border-foreground 244 "$(cat)"
  else
    printf -- '%s┌─ %s\n' "$C_DIM" "$title"; sed 's/^/│ /'; printf -- '└─%s\n' "$C_RESET"
  fi
}

# ui_spin "title" -- cmd...   (gum spinner for quiet ops; plain runs inline)
ui_spin() {
  local title="$1"; shift; [[ "${1:-}" == "--" ]] && shift
  if [[ "$UI_BACKEND" == gum ]]; then
    gum spin --spinner dot --title "$title" -- "$@"
  else
    printf '%s … ' "$title"; if "$@"; then printf 'done\n'; else printf 'FAILED\n'; return 1; fi
  fi
}

# ── shared higher-level flows (used by multiple providers) ──────────────────────
ghcr_login_flow() {
  local u t
  u="$(ui_input 'GitHub username (ghcr.io)')"; [[ -n "$u" ]] || { ui_warn 'Cancelled.'; return 1; }
  t="$(ui_password 'GitHub token (PAT, read:packages)')"; [[ -n "$t" ]] || { ui_warn 'Cancelled.'; return 1; }
  ghcr_login "$u" "$t"
}

show_dns() { # show_dns <tenant-domain> <custom|""> <ip>
  local d="$1" c="$2" ip="$3"
  { printf 'TYPE\tNAME\tVALUE\tTTL\n'
    printf 'A\t%s\t%s\t300\n' "$d" "$ip"
    printf 'A\tapi.%s\t%s\t300\n' "$d" "$ip"
    printf 'A\tws.%s\t%s\t300\n' "$d" "$ip"
    [[ -n "$c" ]] && printf 'A\t%s\t%s\t300\n' "$c" "$ip"
  } | column -t -s $'\t' | ui_box 'DNS records to create at your registrar'
  ui_note "Point these at the public IP. Certs issue once DNS resolves."
}
