#!/usr/bin/env bash
# Swarm provider — shared pooled cluster (manager + optional client workers).
# Sourced by bin/kutab-deploy; relies on common.sh + tui.sh being loaded and on
# $PROVIDER_SCRIPTS (set by load_provider).
PROVIDER_NAME="swarm"
PROVIDER_DESC="Docker Swarm — shared pooled cluster + per-client worker nodes"

provider_actions() {
  cat <<'ACT'
Cluster (init / join)
Infrastructure (Traefik · monitoring)
Database (shared MySQL)
Deploy a tenant
WhatsApp gateway
Update a deployment
Status
ACT
}

# echoes "--role X [--client-name Y]"
_sw_node_role() {
  local r name
  r="$(ui_menu 'Node role' 'Shared pool' 'Client node')"
  if [[ "$r" == 'Client node' ]]; then
    name="$(ui_input 'Client name (slug)')"; require_slug "$name"
    printf -- '--role client --client-name %s' "$name"
  else printf -- '--role shared'; fi
}

# echoes the chosen pool (shared or <client>); availability notes -> stderr
_sw_choose_pool() {
  local clients opts pick c n oknode=false
  mapfile -t clients < <(cluster_clients)
  opts=("Shared cluster"); for c in "${clients[@]}"; do opts+=("Client node: $c"); done
  pick="$(ui_menu 'Deploy where?' "${opts[@]}")"; [[ -n "$pick" ]] || return 1
  [[ "$pick" == "Shared cluster" ]] && { printf 'shared'; return 0; }
  c="${pick#Client node: }"
  for n in $(docker node ls -q 2>/dev/null); do
    [[ "$(node_client "$n")" == "$c" ]] && node_ready "$n" && { oknode=true; break; }
  done
  [[ "$oknode" == true ]] && ui_ok "Client node '$c' is Ready/Active." >&2 \
    || ui_warn "No Ready node labelled client=$c — services stay pending until one joins." >&2
  printf '%s' "$c"
}

provider_flow() {
  local S="$PROVIDER_SCRIPTS"
  case "$1" in
    Cluster*)
      local what; what="$(ui_menu 'Cluster' 'Initialize a new Swarm (this node = manager)' 'Join an existing Swarm')"
      case "$what" in
        Initialize*)
          local addr role; addr="$(ui_input 'Advertise address (this node IP)' "$(public_ip)")"
          role="$(_sw_node_role)" || return
          # shellcheck disable=SC2086
          bash "$S/bootstrap-cluster.sh" --advertise-addr "$addr" $role
          ui_ok 'Worker join token (use it when joining client/worker nodes):'
          docker swarm join-token worker 2>/dev/null | sed -n '3p' || true
          ;;
        Join*)
          local mgr tok role adv
          mgr="$(ui_input 'Manager address (ip:2377)')"
          tok="$(ui_password 'Swarm join token (manager: docker swarm join-token worker -q)')"
          adv="$(ui_input 'This node advertise IP (blank = auto)')"
          role="$(_sw_node_role)" || return
          # shellcheck disable=SC2086
          bash "$S/join-swarm.sh" --manager "$mgr" --token "$tok" ${adv:+--advertise-addr "$adv"} $role
          ;;
      esac
      ;;
    Infrastructure*)
      require_swarm
      local domain email; domain="$(ui_input 'Cluster base domain (e.g. kutab.app)')"; email="$(ui_input "ACME / Let's Encrypt email")"
      bash "$S/deploy-infra.sh" "$domain" "$email"
      ;;
    Database*) bash "$S/setup-db.sh" ;;
    'Deploy a tenant')
      require_swarm; require_shared_network
      ghcr_login_flow || return
      local name base custom pool
      name="$(ui_input 'Tenant name (slug)')"; require_slug "$name"
      base="$(ui_input 'Platform base domain (tenant = <name>.<base>)')"
      custom="$(ui_input 'Custom domain (optional)')"
      pool="$(_sw_choose_pool)" || return
      local shared_db=()
      if [[ "$pool" == shared ]] && ui_confirm 'Use the cluster shared MySQL? (No = a dedicated DB container for this tenant)'; then
        shared_db=(--shared-db)
      fi
      ui_confirm "Deploy tenant '$name' on pool '$pool'${shared_db:+ (shared DB)}?" || return
      # shellcheck disable=SC2086
      bash "$S/deploy-tenant.sh" "$name" --platform-base-domain "$base" \
        ${custom:+--custom-domain "$custom"} --app-pool "$pool" --db-pool "$pool" --cache-pool "$pool" "${shared_db[@]}"
      show_dns "$name.$base" "$custom" "$(public_ip)"
      if [[ "$pool" != shared ]] && ui_confirm "Enable the CPU autoscaler for $name on this client node?"; then
        bash "$S/autoscaler.sh" add "kutab-${name}_backend" --min 1 --max 4 --up 75 --down 20
        bash "$S/autoscaler.sh" add "kutab-${name}_worker"  --min 1 --max 4 --up 75 --down 20
        is_manager && bash "$S/autoscaler.sh" install || ui_note 'Run "kutab-deploy swarm autoscaler install" on a manager.'
      fi
      ;;
    'WhatsApp gateway')
      require_swarm; local d; d="$(ui_input 'Cluster domain (optional)')"
      # shellcheck disable=SC2086
      bash "$S/deploy-whatsapp.sh" ${d:+--cluster-domain "$d"}
      ;;
    'Update a deployment') bash "$S/update-deployment.sh" ;;
    Status)
      ui_title 'Swarm status'
      if swarm_active; then docker node ls 2>/dev/null; printf '\n'; docker stack ls 2>/dev/null; else ui_note 'Swarm inactive.'; fi
      ;;
  esac
}
