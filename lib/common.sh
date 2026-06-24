#!/usr/bin/env bash
# Shared helpers for the kutab-deploy scripts. Source this file; do not execute it.
# Callers are expected to `set -euo pipefail` themselves.

# ── colours ───────────────────────────────────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_DIM=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
fi
export C_RESET C_DIM C_BOLD C_RED C_GREEN C_YELLOW C_BLUE C_CYAN

log()  { printf '%s[INFO]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail() { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# ── generic prerequisites ─────────────────────────────────────────────────────
have()        { command -v "$1" >/dev/null 2>&1; }
require_cmd()  { have "$1" || fail "'$1' is required but not installed. Run: kutab-deploy bootstrap-vm"; }

password()    { openssl rand -base64 36 | tr -d '/+=' | head -c "${1:-32}"; }

is_slug()      { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; }
require_slug() { is_slug "$1" || fail "Invalid name '$1' (lowercase letters, digits, hyphens only)."; }

# ── docker / swarm ─────────────────────────────────────────────────────────────
require_docker()  { have docker || fail "docker is required. Run: kutab-deploy bootstrap-vm"; }
swarm_state()     { docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo inactive; }
swarm_active()    { [[ "$(swarm_state)" == active ]]; }
require_swarm()   { swarm_active || fail "Swarm is not active. Initialize or join a cluster first."; }
is_manager()      { [[ "$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null)" == true ]]; }
this_node_id()    { docker info --format '{{.Swarm.NodeID}}' 2>/dev/null; }

require_shared_network() {
  docker network inspect kutab-shared >/dev/null 2>&1 \
    || fail "kutab-shared overlay network missing. Initialize the cluster first (Cluster ▸ Initialize)."
}

# node_ready <node> -> 0 when Status=ready and Availability=active
node_ready() {
  local n="$1" s a
  s="$(docker node inspect "$n" --format '{{.Status.State}}' 2>/dev/null || true)"
  a="$(docker node inspect "$n" --format '{{.Spec.Availability}}' 2>/dev/null || true)"
  [[ "$s" == ready && "$a" == active ]]
}

node_hostnames() { docker node ls --format '{{.Hostname}}' 2>/dev/null; }

# kutab.client label of a node ("" for shared/unlabelled)
node_client() { docker node inspect "$1" --format '{{ index .Spec.Labels "kutab.client" }}' 2>/dev/null || true; }

# distinct client names present in the cluster
cluster_clients() {
  local id
  for id in $(docker node ls -q 2>/dev/null); do
    docker node inspect "$id" --format '{{ index .Spec.Labels "kutab.client" }}' 2>/dev/null
  done | grep -v '^$' | sort -u
}

# ── registry login ─────────────────────────────────────────────────────────────
ghcr_login() { # ghcr_login <user> <token>
  local user="$1" token="$2"
  [[ -n "$user" && -n "$token" ]] || fail "GitHub username and token are required for ghcr.io."
  if printf '%s' "$token" | docker login ghcr.io -u "$user" --password-stdin >/dev/null 2>&1; then
    ok "Logged in to ghcr.io as $user"
  else
    fail "ghcr.io login failed for '$user' (check the username and that the token has read:packages)."
  fi
}

# ── host facts ──────────────────────────────────────────────────────────────────
detect_ram_mb() { awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 2048; }
detect_cpus()   { nproc 2>/dev/null || echo 1; }

# ~60% of RAM in MB (min 256) — used to size innodb_buffer_pool_size
suggested_buffer_pool_mb() {
  local ram v; ram="$(detect_ram_mb)"; v=$(( ram * 60 / 100 ))
  (( v < 256 )) && v=256
  printf '%d' "$v"
}

public_ip() {
  local ip=""
  ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '%s' "$ip"
}
