#!/usr/bin/env bash
# Set up MySQL for Kutab — dockerized shared instance (Swarm) or a tuned host
# install (single dedicated node). MySQL 8.4 LTS; buffer pool auto-sized to RAM.
#
#   setup-db.sh [--mode docker|host] [--image mysql:8.4.8] [--buffer-pool-mb N]
#               [--bind 127.0.0.1] [--dry-run]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../../../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"
# shellcheck source=../../../lib/tui.sh
source "$KUTAB_ROOT/lib/tui.sh"

MODE=""; IMAGE="mysql:8.4.8"; BUFFER_POOL_MB=""; BIND="127.0.0.1"; DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --buffer-pool-mb) BUFFER_POOL_MB="$2"; shift 2 ;;
    --bind) BIND="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

BP_MB="${BUFFER_POOL_MB:-$(suggested_buffer_pool_mb)}"

# Recommend based on context: dockerized for an active Swarm, host for a bare box.
if [[ -z "$MODE" ]]; then
  local_reco="Dockerized shared MySQL (recommended)"
  swarm_active || local_reco="Host-installed MySQL 8.4 (recommended)"
  ui_title "Database setup"
  ui_note "Detected: $(detect_cpus) vCPU · $(detect_ram_mb) MB RAM → buffer pool ≈ ${BP_MB} MB"
  ui_note "Dockerized  = portable, Swarm-scheduled, simple backups (best for the shared cluster)."
  ui_note "Host MySQL  = lowest overhead / best IO on a single dedicated node."
  choice="$(ui_menu "How should MySQL run?  [reco: ${local_reco%% (*}]" \
    "Dockerized shared MySQL (recommended)" "Host-installed MySQL 8.4 (single node)")"
  case "$choice" in
    Dockerized*) MODE=docker ;;
    Host*) MODE=host ;;
    *) fail "Cancelled." ;;
  esac
fi

# ── dockerized path: delegate to the existing shared-db deployer ───────────────
if [[ "$MODE" == docker ]]; then
  require_docker; require_swarm
  export SHARED_DB_BUFFER_POOL="${BP_MB}M"
  args=(--image "$IMAGE")
  [[ "$DRY_RUN" == true ]] && args+=(--dry-run)
  log "Dockerized MySQL ($IMAGE), innodb_buffer_pool_size=${BP_MB}M"
  exec "$SCRIPT_DIR/deploy-shared-db.sh" "${args[@]}"
fi

[[ "$MODE" == host ]] || fail "Unknown --mode: $MODE (use docker|host)"

# ── host path: install + tune MySQL 8.4 on this machine ────────────────────────
command -v apt-get >/dev/null || fail "Host install targets Debian/Ubuntu (apt)."
SUDO=""; [[ "$(id -u)" -ne 0 ]] && { have sudo || fail "Run as root or install sudo."; SUDO="sudo"; }
SECRET_DIR="$PROVIDER_ROOT/secrets/infrastructure"; mkdir -p "$SECRET_DIR"; chmod 700 "$PROVIDER_ROOT/secrets" 2>/dev/null || true
ROOT_PW_FILE="$SECRET_DIR/host_db_root_password"

if [[ "$DRY_RUN" == true ]]; then
  log "Dry run: would install MySQL 8.4 (apt), tune innodb_buffer_pool_size=${BP_MB}M, bind=$BIND, store root pw at $ROOT_PW_FILE"
  exit 0
fi

ROOT_PW="$( [[ -f "$ROOT_PW_FILE" ]] && cat "$ROOT_PW_FILE" || password )"
export DEBIAN_FRONTEND=noninteractive

install_mysql_84() {
  if have mysqld || dpkg -s mysql-server >/dev/null 2>&1; then ok "MySQL already installed"; return; fi
  log "Adding MySQL APT repo (8.4 LTS) and installing mysql-server"
  local deb=/tmp/mysql-apt-config.deb
  if curl -fsSL -o "$deb" https://dev.mysql.com/get/mysql-apt-config_0.8.34-1_all.deb; then
    $SUDO debconf-set-selections <<< "mysql-apt-config mysql-apt-config/select-server select mysql-8.4-lts"
    $SUDO dpkg -i "$deb" >/dev/null 2>&1 || true
    $SUDO apt-get update -qq || true
  else
    warn "Could not fetch the MySQL APT repo; falling back to the distro mysql-server (may be 8.0, not 8.4)."
  fi
  # preseed root password so the install is non-interactive
  $SUDO debconf-set-selections <<< "mysql-server mysql-server/root_password password $ROOT_PW"
  $SUDO debconf-set-selections <<< "mysql-server mysql-server/root_password_again password $ROOT_PW"
  $SUDO apt-get install -y -qq mysql-server >/dev/null || fail "mysql-server install failed"
  ( umask 077; printf '%s' "$ROOT_PW" > "$ROOT_PW_FILE" ); chmod 600 "$ROOT_PW_FILE"
  ok "MySQL installed; root password saved to $ROOT_PW_FILE"
}
install_mysql_84

CNF_DIR=/etc/mysql/mysql.conf.d; [[ -d "$CNF_DIR" ]] || CNF_DIR=/etc/mysql/conf.d
log "Writing tuned config -> $CNF_DIR/zz-kutab.cnf (buffer pool ${BP_MB}M, bind $BIND)"
$SUDO tee "$CNF_DIR/zz-kutab.cnf" >/dev/null <<CNF
[mysqld]
bind-address              = $BIND
character-set-server      = utf8mb4
collation-server          = utf8mb4_unicode_ci
skip_name_resolve         = 1
max_connections           = 200
max_allowed_packet        = 64M
innodb_file_per_table     = 1
innodb_flush_log_at_trx_commit = 1
innodb_flush_method       = O_DIRECT
innodb_log_file_size      = 256M
innodb_buffer_pool_size   = ${BP_MB}M
CNF

$SUDO systemctl restart mysql 2>/dev/null || $SUDO systemctl restart mysqld 2>/dev/null || warn "Could not restart MySQL — restart it manually."
ok "Host MySQL 8.4 ready (bind=$BIND, buffer pool ${BP_MB}M)"

cat <<TXT

────────────────────────────────────────────────────────────────────────────
Host MySQL is up. Point a tenant/single-box backend at it with:
  DB_HOST=$( [[ "$BIND" == 0.0.0.0 ]] && public_ip || echo "$BIND" )
  DB_PORT=3306    root password: $ROOT_PW_FILE
Create a tenant DB + user (run as root):
  mysql -uroot -p < <(printf "CREATE DATABASE kutab_x; CREATE USER 'kutab_x'@'%%' IDENTIFIED BY '<pw>'; GRANT ALL ON kutab_x.* TO 'kutab_x'@'%%'; FLUSH PRIVILEGES;")
If tenants connect over the network, set --bind to the private IP and open 3306 to that subnet only.
────────────────────────────────────────────────────────────────────────────
TXT
