#!/usr/bin/env bash
set -euo pipefail

# Creates (idempotently) a tenant's database + user inside the SHARED MySQL
# instance, and writes the connection details to
#   envs/tenants/<slug>/db.env
# which deploy-tenant.sh sources to build the tenant's backend.env.
#
#   provision-tenant-db.sh <tenant-slug> [--rotate-password] [--image mysql:8.4.8]
#
# Safe to re-run: the database/user are created IF NOT EXISTS; the password is
# reused unless --rotate-password is given.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SLUG="${1:-}"; shift || true
ROTATE=false
DB_HOST_ALIAS="${DB_HOST_ALIAS:-kutab-db}"
SHARED_DB_IMAGE="${SHARED_DB_IMAGE:-mysql:8.4.8}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rotate-password) ROTATE=true; shift ;;
    --image) SHARED_DB_IMAGE="$2"; shift 2 ;;
    -h|--help) sed -n '3,12p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
done

log() { printf '[INFO] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
password() { openssl rand -base64 36 | tr -d '/+=' | head -c 32; }

[[ -n "$SLUG" ]] || fail "Usage: $0 <tenant-slug> [--rotate-password]"
command -v docker >/dev/null || fail "docker is required"

ROOT_PW_FILE="$PROVIDER_ROOT/secrets/infrastructure/shared_db_root_password"
[[ -f "$ROOT_PW_FILE" ]] || fail "Root password file not found ($ROOT_PW_FILE). Run deploy-shared-db.sh first."
ROOT_PW="$(cat "$ROOT_PW_FILE")"

# ── derive safe MySQL identifiers from the slug ──────────────────────────────
safe="$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g; s/__*/_/g; s/^_//; s/_$//')"
[[ -n "$safe" ]] || fail "Slug '$SLUG' contains no valid identifier characters."
DB_NAME="kutab_${safe}"
DB_USER="$(printf 'kutab_%s' "$safe" | cut -c1-32)"   # MySQL usernames are capped at 32 chars

CRED_DIR="$PROVIDER_ROOT/envs/tenants/$SLUG"
CRED_FILE="$CRED_DIR/db.env"
mkdir -p "$CRED_DIR"

if [[ -f "$CRED_FILE" && "$ROTATE" != true ]]; then
  DB_PASS="$(grep -E '^DB_PASSWORD=' "$CRED_FILE" | cut -d= -f2- || true)"
  [[ -n "$DB_PASS" ]] || DB_PASS="$(password)"
  log "Reusing existing DB credentials for '$SLUG' (pass --rotate-password to change them)."
else
  DB_PASS="$(password)"
fi

# ── SQL (idempotent). Backticks escaped so bash keeps them literal. ──────────
SQL="$(cat <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL
)"

# ── apply against the shared instance over the overlay, retrying until ready ─
log "Provisioning database '$DB_NAME' / user '$DB_USER' on the shared instance..."
ok=false
for _ in $(seq 1 30); do
  if printf '%s\n' "$SQL" | docker run -i --rm --network kutab-shared \
        -e MYSQL_PWD="$ROOT_PW" "$SHARED_DB_IMAGE" \
        mysql --connect-timeout=5 -h "$DB_HOST_ALIAS" -uroot 2>/dev/null; then
    ok=true; break
  fi
  sleep 4
done
[[ "$ok" == true ]] || fail "Could not reach the shared DB at '$DB_HOST_ALIAS' on kutab-shared. Is kutab-shared-db deployed and healthy? (docker service ps kutab-shared-db_db)"

# ── write the creds file consumed by deploy-tenant.sh ────────────────────────
( umask 077; cat > "$CRED_FILE" <<ENV
DB_CONNECTION=mysql
DB_HOST=${DB_HOST_ALIAS}
DB_PORT=3306
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASS}
ENV
)
chmod 600 "$CRED_FILE"

log "Done. Wrote $CRED_FILE"
log "  DB_HOST=${DB_HOST_ALIAS}  DB_DATABASE=${DB_NAME}  DB_USERNAME=${DB_USER}"
