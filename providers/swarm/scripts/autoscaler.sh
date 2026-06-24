#!/usr/bin/env bash
# Lightweight CPU autoscaler for Swarm services (Swarm has no native HPA).
# Runs on a MANAGER, queries Prometheus for per-service CPU, and scales replicas
# within [min,max]. Static right-sizing (limits/reservations) lives in the stack;
# this adds *optional* live scaling, enabled per client node from the tenant flow.
#
#   autoscaler.sh run                         evaluate + scale once (timer target)
#   autoscaler.sh add <service> [--min N] [--max N] [--up PCT] [--down PCT]
#   autoscaler.sh remove <service>
#   autoscaler.sh status
#   autoscaler.sh install                     install + enable the systemd timer (root)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../../../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"

CONF_DIR="$PROVIDER_ROOT/configs/autoscaler"
CONF="$CONF_DIR/services.conf"          # lines: SERVICE MIN MAX UP_CPU DOWN_CPU
PROM_URL="${PROM_URL:-http://localhost:9090}"
# PromQL: avg CPU (percent of one core) of a swarm service's tasks. Tune for your
# Prometheus/cadvisor labels via PROM_QUERY ('%S%' is replaced by the service name).
PROM_QUERY="${PROM_QUERY:-avg(rate(container_cpu_usage_seconds_total{container_label_com_docker_swarm_service_name=\"%S%\"}[3m]))*100}"

mkdir -p "$CONF_DIR"; touch "$CONF"

cmd="${1:-run}"; [[ $# -gt 0 ]] && shift

query_cpu() { # query_cpu <service> -> integer percent (or empty)
  local svc="$1" q out
  q="${PROM_QUERY//%S%/$svc}"
  out="$(curl -fsS --max-time 5 --data-urlencode "query=$q" "$PROM_URL/api/v1/query" 2>/dev/null || true)"
  [[ -n "$out" ]] || return 0
  if have jq; then printf '%s' "$out" | jq -r '.data.result[0].value[1] // empty' | awk '{printf "%d", $1}'
  else printf '%s' "$out" | grep -oE '"[0-9.]+"\]' | head -1 | tr -dc '0-9.' | awk '{printf "%d", $1}'; fi
}

replicas() { docker service inspect "$1" --format '{{.Spec.Mode.Replicated.Replicas}}' 2>/dev/null; }

case "$cmd" in
  add)
    svc="${1:?service required}"; shift || true
    min=1; max=4; up=75; down=20
    while [[ $# -gt 0 ]]; do case "$1" in
      --min) min="$2"; shift 2;; --max) max="$2"; shift 2;;
      --up) up="$2"; shift 2;; --down) down="$2"; shift 2;; *) fail "bad arg $1";; esac; done
    grep -vE "^${svc} " "$CONF" > "$CONF.tmp" 2>/dev/null || true; mv "$CONF.tmp" "$CONF" 2>/dev/null || true
    printf '%s %s %s %s %s\n' "$svc" "$min" "$max" "$up" "$down" >> "$CONF"
    ok "Autoscaling $svc: replicas [$min..$max], up>${up}%, down<${down}%"
    ;;
  remove)
    svc="${1:?service required}"
    grep -vE "^${svc} " "$CONF" > "$CONF.tmp" 2>/dev/null || true; mv "$CONF.tmp" "$CONF"
    ok "Removed $svc from autoscaler"
    ;;
  status)
    printf 'Prometheus: %s\nConfig: %s\n\n%-34s %-6s %-6s %-6s %-6s %-8s\n' "$PROM_URL" "$CONF" SERVICE MIN MAX "UP%" "DOWN%" "NOW"
    while read -r svc min max up down; do
      [[ -z "${svc:-}" || "$svc" == \#* ]] && continue
      printf '%-34s %-6s %-6s %-6s %-6s %-8s\n' "$svc" "$min" "$max" "$up" "$down" "$(replicas "$svc" || echo '-')"
    done < "$CONF"
    ;;
  install)
    SUDO=""; [[ "$(id -u)" -ne 0 ]] && SUDO="sudo"
    $SUDO cp "$SCRIPT_DIR/lib/kutab-autoscaler.service" /etc/systemd/system/kutab-autoscaler.service
    $SUDO cp "$SCRIPT_DIR/lib/kutab-autoscaler.timer"   /etc/systemd/system/kutab-autoscaler.timer
    $SUDO sed -i "s#__AUTOSCALER__#$SCRIPT_DIR/autoscaler.sh#g" /etc/systemd/system/kutab-autoscaler.service
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now kutab-autoscaler.timer
    ok "Autoscaler timer installed (runs every 2 min). Check: systemctl status kutab-autoscaler.timer"
    ;;
  run)
    require_docker
    is_manager || fail "autoscaler must run on a Swarm manager (it calls 'docker service scale')."
    while read -r svc min max up down; do
      [[ -z "${svc:-}" || "$svc" == \#* ]] && continue
      docker service inspect "$svc" >/dev/null 2>&1 || { log "skip $svc (not found)"; continue; }
      cpu="$(query_cpu "$svc")"; [[ -n "$cpu" ]] || { log "skip $svc (no metric)"; continue; }
      cur="$(replicas "$svc")"; [[ "$cur" =~ ^[0-9]+$ ]] || continue
      target="$cur"
      if (( cpu > up && cur < max )); then target=$((cur+1));
      elif (( cpu < down && cur > min )); then target=$((cur-1)); fi
      if (( target != cur )); then
        log "$svc cpu=${cpu}% replicas ${cur}->${target}"
        docker service scale "$svc=$target" >/dev/null 2>&1 || warn "scale $svc failed"
      else
        log "$svc cpu=${cpu}% replicas=${cur} (steady)"
      fi
    done < "$CONF"
    ;;
  -h|--help) sed -n '2,11p' "$0" ;;
  *) fail "Unknown command: $cmd" ;;
esac
