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
Set custom domain
Set TLS / cert mode
WhatsApp gateway
Host database (optional)
Status
ACT
}

_compose_projects() { ls -1 "$(provider_state_root compose)/envs" 2>/dev/null; }
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
      local name domain custom email wa=() dbflag=()
      name="$(ui_input 'Name (slug)')"; require_slug "$name"
      domain="$(ui_input 'Tenant domain (e.g. acme.com)')"
      custom="$(ui_input 'Extra/custom domain (optional)')"
      email="$(ui_input "ACME / Let's Encrypt email")"
      local chal=(--tls-mode le)
      if ui_confirm 'Is this domain proxied through Cloudflare (orange cloud)?'; then
        chal=(--tls-mode cloudflare)
        ui_note "Origin will serve a self-signed cert — set this domain's Cloudflare SSL/TLS mode to \"Full\". No token needed."
      fi
      if [[ "$(node_state_get DB_MODE)" == host ]]; then
        ui_confirm 'A host database is installed — use it instead of a bundled DB container?' \
          && dbflag=(--host-db) || dbflag=(--bundled-db)
      fi
      ui_confirm 'Also run the WhatsApp gateway on this box?' && wa=(--with-whatsapp)
      # shellcheck disable=SC2086
      bash "$S/deploy.sh" "$name" --tenant-domain "$domain" --acme-email "$email" ${custom:+--custom-domain "$custom"} "${chal[@]}" "${dbflag[@]}" "${wa[@]}"
      show_dns "$domain" "$custom" "$(public_ip)"
      ;;
    'Scale services')
      local name be hz; name="$(_compose_pick)" || return
      be="$(ui_input 'backend (php-fpm) replicas' '2')"; hz="$(ui_input 'horizon (queue) replicas' '1')"
      bash "$S/scale.sh" "$name" --backend "$be" --horizon "$hz"
      ;;
    'Update deployment')
      local name; name="$(_compose_pick)" || return
      bash "$S/update.sh" "$name"
      ;;
    'Set custom domain')
      local name d; name="$(_compose_pick)" || return
      d="$(ui_input 'Custom domain to add (leave blank to remove the current one)')"
      if [[ -n "$d" ]]; then bash "$S/set-domain.sh" "$name" --custom-domain "$d"; show_dns "$d" "" "$(public_ip)"
      else bash "$S/set-domain.sh" "$name" --remove; fi
      ;;
    'Set TLS / cert mode')
      local name m tok=(); name="$(_compose_pick)" || return
      m="$(ui_menu 'Certificate mode' 'cloudflare — behind Cloudflare proxy (self-signed origin)' 'le — direct domain, Lets Encrypt HTTP-01' 'le-dns-cloudflare — LE DNS-01 (needs token)')" || return
      case "$m" in
        cloudflare*) m=cloudflare ;;
        le-dns*) m=le-dns-cloudflare; tok=(--cf-dns-token "$(ui_input 'Cloudflare API token (Zone:DNS:Edit + Zone:Read)')") ;;
        le*) m=le ;;
        *) return ;;
      esac
      bash "$S/set-tls.sh" "$name" --tls-mode "$m" "${tok[@]}"
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
