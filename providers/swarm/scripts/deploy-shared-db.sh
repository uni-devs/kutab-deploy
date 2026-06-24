#!/usr/bin/env bash
set -euo pipefail

# Deploys the single SHARED MySQL instance that all tenants share.
# Run once on the cluster (re-run is safe; it preserves data and the secret).
#
#   deploy-shared-db.sh [--db-pool shared] [--image mysql:8.4.8]
#                       [--force-secrets] [--dry-run]
#
# After this, provision each tenant's database+user with provision-tenant-db.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DB_POOL="${DB_POOL:-shared}"
SHARED_DB_IMAGE="${SHARED_DB_IMAGE:-mysql:8.4.8}"
SHARED_DB_BUFFER_POOL="${SHARED_DB_BUFFER_POOL:-1G}"   # tune to ~60% of DB-node RAM
FORCE_SECRETS=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db-pool) DB_POOL="$2"; shift 2 ;;
    --image) SHARED_DB_IMAGE="$2"; shift 2 ;;
    --force-secrets) FORCE_SECRETS=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '3,11p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
done

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
password() { openssl rand -base64 36 | tr -d '/+=' | head -c 32; }

command -v docker >/dev/null || fail "docker is required"
command -v openssl >/dev/null || fail "openssl is required"
docker info --format '{{.Swarm.LocalNodeState}}' | grep -q active \
  || fail "Swarm is not active. Run bootstrap-cluster.sh first."
docker network inspect kutab-shared >/dev/null 2>&1 \
  || fail "The kutab-shared overlay network is missing. Run bootstrap-cluster.sh first."

SECRET_DIR="$PROVIDER_ROOT/secrets/infrastructure"
ROOT_PW_FILE="$SECRET_DIR/shared_db_root_password"
mkdir -p "$SECRET_DIR" "$PROVIDER_ROOT/configs/mysql"
chmod 700 "$PROVIDER_ROOT/secrets" 2>/dev/null || true

# ── root password secret ─────────────────────────────────────────────────────
# Stored both as a Docker secret (consumed by the container) and as a 0600 file
# on the manager (consumed by provision-tenant-db.sh). Keep them in sync.
if docker secret inspect shared_db_root_password >/dev/null 2>&1 && [[ "$FORCE_SECRETS" != true ]]; then
  log "Keeping existing shared_db_root_password secret"
  [[ -f "$ROOT_PW_FILE" ]] || warn "Secret exists but $ROOT_PW_FILE is missing — provisioning will fail until you restore the root password there."
else
  if docker secret inspect shared_db_root_password >/dev/null 2>&1; then
    warn "Removing old secret. NOTE: swapping the Docker secret does NOT change the password inside an already-initialised MySQL — rotate it in SQL too if the data volume already exists."
    [[ "$DRY_RUN" == true ]] || docker secret rm shared_db_root_password >/dev/null
  fi
  ROOT_PW="$(password)"
  if [[ "$DRY_RUN" != true ]]; then
    printf '%s' "$ROOT_PW" | docker secret create shared_db_root_password - >/dev/null
    ( umask 077; printf '%s' "$ROOT_PW" > "$ROOT_PW_FILE" )
    chmod 600 "$ROOT_PW_FILE"
  fi
  log "Created shared_db_root_password secret (saved to $ROOT_PW_FILE)"
fi

# ── tuned my.cnf (source of truth = this heredoc) ────────────────────────────
cat > "$PROVIDER_ROOT/configs/mysql/shared-db.cnf" <<CNF
[mysqld]
character-set-server = utf8mb4
collation-server     = utf8mb4_unicode_ci
skip_name_resolve    = 1
max_connections      = 200
max_allowed_packet   = 64M
innodb_file_per_table = 1
innodb_flush_log_at_trx_commit = 1
innodb_flush_method  = O_DIRECT
innodb_log_file_size = 256M
# Sized to ~60% of the DB node's RAM (override with SHARED_DB_BUFFER_POOL).
innodb_buffer_pool_size = ${SHARED_DB_BUFFER_POOL}
CNF
log "Wrote tuned config -> configs/mysql/shared-db.cnf (tune innodb_buffer_pool_size to your node RAM)"

export CONFIG_ROOT="$PROVIDER_ROOT/configs"
export DB_POOL SHARED_DB_IMAGE
export SHARED_DB_CPU_LIMIT="${SHARED_DB_CPU_LIMIT:-2.0}"
export SHARED_DB_MEM_LIMIT="${SHARED_DB_MEM_LIMIT:-4096M}"
export SHARED_DB_CPU_RES="${SHARED_DB_CPU_RES:-0.50}"
export SHARED_DB_MEM_RES="${SHARED_DB_MEM_RES:-1024M}"

if [[ "$DRY_RUN" == true ]]; then
  log "Dry run: docker stack deploy --with-registry-auth -c $PROVIDER_ROOT/templates/shared-db-stack.yml kutab-shared-db"
  exit 0
fi

log "Deploying shared DB (kutab-shared-db) onto db_pool '$DB_POOL' using image $SHARED_DB_IMAGE"
docker stack deploy --with-registry-auth -c "$PROVIDER_ROOT/templates/shared-db-stack.yml" kutab-shared-db

log "Waiting for the shared DB service to converge (1/1)..."
for _ in $(seq 1 60); do
  rep="$(docker service ls --filter name=kutab-shared-db_db --format '{{.Replicas}}' 2>/dev/null || true)"
  if [[ "$rep" == "1/1" ]]; then
    log "Shared DB is running ($rep). First-boot init can take ~1-2 min; provision-tenant-db.sh retries until it is reachable."
    exit 0
  fi
  sleep 5
done
warn "Shared DB did not reach 1/1 in time. Check: docker service ps kutab-shared-db_db"
