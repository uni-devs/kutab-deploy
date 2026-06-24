#!/usr/bin/env bash
# Compose provider — one dedicated box per client, no Swarm. Scaling is just
# `docker compose up --scale` behind the bundled Traefik. Best for a single
# client node where Swarm orchestration is overkill.
PROVIDER_NAME="compose"
PROVIDER_DESC="Docker Compose — dedicated single box per client (simple scaling)"

provider_actions() {
  cat <<'ACT'
Deploy (one box)
Scale services
Update deployment
WhatsApp gateway
Host database (optional)
Status
ACT
}

_compose_projects() { ls -1 "$PROVIDER_DIR/envs" 2>/dev/null; }
_compose_pick() {
  local opts; mapfile -t opts < <(_compose_projects)
  (( ${#opts[@]} )) || { ui_warn 'No compose deployments yet.'; return 1; }
  ui_menu 'Which deployment?' "${opts[@]}"
}

provider_flow() {
  local S="$PROVIDER_SCRIPTS"
  case "$1" in
    'Deploy (one box)')
      ghcr_login_flow || return
      local name domain custom email wa=()
      name="$(ui_input 'Name (slug)')"; require_slug "$name"
      domain="$(ui_input 'Tenant domain (e.g. acme.com)')"
      custom="$(ui_input 'Extra/custom domain (optional)')"
      email="$(ui_input "ACME / Let's Encrypt email")"
      ui_confirm 'Also run the WhatsApp gateway on this box?' && wa=(--with-whatsapp)
      # shellcheck disable=SC2086
      bash "$S/deploy.sh" "$name" --tenant-domain "$domain" --acme-email "$email" ${custom:+--custom-domain "$custom"} "${wa[@]}"
      show_dns "$domain" "$custom" "$(public_ip)"
      ;;
    'Scale services')
      local name be wk; name="$(_compose_pick)" || return
      be="$(ui_input 'backend replicas' '2')"; wk="$(ui_input 'worker replicas' '2')"
      bash "$S/scale.sh" "$name" --backend "$be" --worker "$wk"
      ;;
    'Update deployment')
      local name; name="$(_compose_pick)" || return
      bash "$S/update.sh" "$name"
      ;;
    'WhatsApp gateway')
      local name; name="$(_compose_pick)" || return
      bash "$S/whatsapp.sh" "$name"
      ;;
    'Host database'*) bash "$S/setup-db.sh" ;;
    Status)
      ui_title 'Compose deployments'
      local p; for p in $(_compose_projects); do printf '  • %s\n' "$p"; done
      [[ -z "$(_compose_projects)" ]] && ui_note 'none yet'
      ;;
  esac
}
