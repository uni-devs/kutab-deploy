#!/usr/bin/env bash
# Set up the Kutab database — a dockerized shared MySQL instance (Swarm) or a
# tuned host install. Host uses MariaDB (distro repo: no third-party APT signing
# key, so none of the NO_PUBKEY/EXPKEYSIG errors); containers use mysql:8.4.8.
# Buffer pool auto-sized to RAM.
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

DATA_ROOT="$(provider_state_root "$(basename "$PROVIDER_ROOT")")"

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
  swarm_active || local_reco="Host-installed MariaDB (recommended)"
  ui_title "Database setup"
  ui_note "Detected: $(detect_cpus) vCPU · $(detect_ram_mb) MB RAM → buffer pool ≈ ${BP_MB} MB"
  ui_note "Dockerized   = portable, Swarm-scheduled, simple backups (best for the shared cluster)."
  ui_note "Host MariaDB = lowest overhead / best IO + no third-party APT key (distro repo)."
  choice="$(ui_menu "How should the database run?  [reco: ${local_reco%% (*}]" \
    "Dockerized shared MySQL (recommended)" "Host-installed MariaDB (single node)")"
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
  [[ "$DRY_RUN" == true ]] || { node_state_set DB_MODE docker; node_state_set SHARED_DB 1; }
  exec "$SCRIPT_DIR/deploy-shared-db.sh" "${args[@]}"
fi

[[ "$MODE" == host ]] || fail "Unknown --mode: $MODE (use docker|host)"

# ── host path: install + tune MySQL 8.4 on this machine ────────────────────────
command -v apt-get >/dev/null || fail "Host install targets Debian/Ubuntu (apt)."
SUDO=""; [[ "$(id -u)" -ne 0 ]] && { have sudo || fail "Run as root or install sudo."; SUDO="sudo"; }
SECRET_DIR="$DATA_ROOT/secrets/infrastructure"; mkdir -p "$SECRET_DIR"; chmod 700 "$DATA_ROOT/secrets" "$DATA_ROOT" 2>/dev/null || true
ROOT_PW_FILE="$SECRET_DIR/host_db_root_password"

if [[ "$DRY_RUN" == true ]]; then
  log "Dry run: would install MySQL 8.4 (apt), tune innodb_buffer_pool_size=${BP_MB}M, bind=$BIND, store root pw at $ROOT_PW_FILE"
  exit 0
fi

ROOT_PW="$( [[ -f "$ROOT_PW_FILE" ]] && cat "$ROOT_PW_FILE" || password )"
export DEBIAN_FRONTEND=noninteractive

install_host_db() {
  if have mariadbd || have mysqld || dpkg -s mariadb-server >/dev/null 2>&1; then ok "MariaDB/MySQL already installed"; return; fi
  # MariaDB ships in the Ubuntu/Debian base repos, so there is NO third-party APT
  # repo or signing key — which is exactly what threw NO_PUBKEY/EXPKEYSIG on the
  # MySQL APT repo in production. MariaDB is wire-compatible with MySQL for Laravel.
  log "Installing MariaDB from the distro repo (no third-party signing key)"
  $SUDO apt-get update -qq || warn "apt update reported warnings"
  $SUDO apt-get install -y -qq mariadb-server mariadb-client >/dev/null || fail "mariadb-server install failed"
  # Local root authenticates via unix_socket; also set a password (network/admin use)
  # and record it. Generated passwords are alnum-only, so no SQL quoting needed.
  $SUDO mariadb -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$ROOT_PW'; FLUSH PRIVILEGES;" 2>/dev/null \
    || $SUDO mysql -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$ROOT_PW'); FLUSH PRIVILEGES;" 2>/dev/null \
    || warn "Could not set a root password (root still works via the local socket)."
  ( umask 077; printf '%s' "$ROOT_PW" > "$ROOT_PW_FILE" ); chmod 600 "$ROOT_PW_FILE"
  ok "MariaDB installed; root password saved to $ROOT_PW_FILE"
}
install_host_db

CNF_DIR=/etc/mysql/mariadb.conf.d; [[ -d "$CNF_DIR" ]] || CNF_DIR=/etc/mysql/conf.d; [[ -d "$CNF_DIR" ]] || CNF_DIR=/etc/mysql/mysql.conf.d
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

$SUDO systemctl restart mariadb 2>/dev/null || $SUDO systemctl restart mysql 2>/dev/null || warn "Could not restart MariaDB — restart it manually."
node_state_set DB_MODE host
node_state_set DB_ENGINE mariadb
ok "Host MariaDB ready (bind=$BIND, buffer pool ${BP_MB}M)"

cat <<TXT

────────────────────────────────────────────────────────────────────────────
Host MariaDB is up. Point a tenant/single-box backend at it with:
  DB_HOST=$( [[ "$BIND" == 0.0.0.0 ]] && public_ip || echo "$BIND" )
  DB_PORT=3306    root password: $ROOT_PW_FILE
Create a tenant DB + user (run as root):
  mariadb < <(printf "CREATE DATABASE kutab_x; CREATE USER 'kutab_x'@'%%' IDENTIFIED BY '<pw>'; GRANT ALL ON kutab_x.* TO 'kutab_x'@'%%'; FLUSH PRIVILEGES;")
For a compose single box that should use THIS host DB, install with
  kutab-deploy swarm setup-db --mode host --bind 172.17.0.1   # docker bridge gateway
then deploy with:  kutab-deploy compose deploy <name> ... --host-db
If tenants connect over the network, set --bind to the private IP and open 3306 to that subnet only.
────────────────────────────────────────────────────────────────────────────
TXT
