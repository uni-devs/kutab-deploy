#!/usr/bin/env bash
set -euo pipefail

# Drops a tenant's database + user from the SHARED MySQL instance.
# DESTRUCTIVE — requires --yes to actually run.
#
#   deprovision-tenant-db.sh <tenant-slug> --yes [--image mysql:8.4.8]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../../../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"   # provider_state_root (local helpers below still win)
DATA_ROOT="$(provider_state_root "$(basename "$PROVIDER_ROOT")")"

SLUG="${1:-}"; shift || true
CONFIRM=false
DB_HOST_ALIAS="${DB_HOST_ALIAS:-kutab-db}"
SHARED_DB_IMAGE="${SHARED_DB_IMAGE:-mysql:8.4.8}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) CONFIRM=true; shift ;;
    --image) SHARED_DB_IMAGE="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
done

log() { printf '[INFO] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

[[ -n "$SLUG" ]] || fail "Usage: $0 <tenant-slug> --yes"
[[ "$CONFIRM" == true ]] || fail "Refusing to drop data without --yes."
command -v docker >/dev/null || fail "docker is required"

ROOT_PW_FILE="$DATA_ROOT/secrets/infrastructure/shared_db_root_password"
[[ -f "$ROOT_PW_FILE" ]] || fail "Root password file not found ($ROOT_PW_FILE)."
ROOT_PW="$(cat "$ROOT_PW_FILE")"

safe="$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g; s/__*/_/g; s/^_//; s/_$//')"
[[ -n "$safe" ]] || fail "Slug '$SLUG' contains no valid identifier characters."
DB_NAME="kutab_${safe}"
DB_USER="$(printf 'kutab_%s' "$safe" | cut -c1-32)"

SQL="$(cat <<SQL
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
DROP USER IF EXISTS '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL
)"

log "Dropping database '$DB_NAME' and user '$DB_USER'..."
printf '%s\n' "$SQL" | docker run -i --rm --network kutab-shared \
  -e MYSQL_PWD="$ROOT_PW" "$SHARED_DB_IMAGE" \
  mysql --connect-timeout=5 -h "$DB_HOST_ALIAS" -uroot \
  || fail "Could not reach the shared DB at '$DB_HOST_ALIAS'."

rm -f "$DATA_ROOT/envs/tenants/$SLUG/db.env"
log "Done. Removed database, user, and the tenant db.env"
