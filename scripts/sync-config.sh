#!/usr/bin/env bash
# Snapshot deployment config + secrets to a Git/GitHub remote, with secrets
# encrypted via SOPS + age. Plaintext secrets/envs live OFF the repo (the data
# dir, default /var/lib/kutab); only their encrypted *.sops copies are committed,
# under state/<provider>/. Use --restore to decrypt them back onto a new node.
#
#   sync-config.sh [--remote <git-url>] [--message <msg>] [--no-push]
#                  [--restore] [--dry-run]
#
# The age PRIVATE key lives off-repo at ~/.config/sops/age/keys.txt — back it up
# (a password manager). Without it the snapshot CANNOT be decrypted.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
REPO_ROOT="$KUTAB_ROOT"   # deployment/ (holds .git)
# shellcheck source=../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"
# shellcheck source=../lib/tui.sh
source "$KUTAB_ROOT/lib/tui.sh"

REMOTE=""; MESSAGE=""; DO_PUSH=true; DRY_RUN=false; RESTORE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote) REMOTE="$2"; shift 2 ;;
    --message) MESSAGE="$2"; shift 2 ;;
    --no-push) DO_PUSH=false; shift ;;
    --restore) RESTORE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

require_cmd git
require_cmd sops
have age-keygen || fail "age (age-keygen) is required. Run: kutab-deploy bootstrap-vm"

# ── age key (off-repo) ──────────────────────────────────────────────────────────
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
if [[ ! -f "$AGE_KEY_FILE" ]]; then
  mkdir -p "$(dirname "$AGE_KEY_FILE")"; chmod 700 "$(dirname "$AGE_KEY_FILE")"
  age-keygen -o "$AGE_KEY_FILE" >/dev/null 2>&1
  chmod 600 "$AGE_KEY_FILE"
  ui_warn "Generated a NEW age key at $AGE_KEY_FILE — BACK IT UP NOW. Without it the snapshot is unrecoverable."
fi
RECIPIENT="$(age-keygen -y "$AGE_KEY_FILE" 2>/dev/null)"
[[ "$RECIPIENT" == age1* ]] || fail "Could not derive the age public key from $AGE_KEY_FILE"
ui_note "age recipient: $RECIPIENT"
export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"   # needed for --restore (decrypt)

# Plaintext secrets/envs live OFF the code tree (data dir); the repo only ever
# holds their encrypted *.sops copies under state/<provider>/{secrets,envs}/.
DATA_DIR="$(kutab_data_dir)"
STATE_DIR="$REPO_ROOT/state"

# ── restore: decrypt state/*.sops back into the data dir (for a replacement node) ──
if [[ "$RESTORE" == true ]]; then
  [[ -d "$STATE_DIR" ]] || fail "No state/ to restore from (run a snapshot first, or git pull it)."
  log "Restoring plaintext secrets/envs: $STATE_DIR → $DATA_DIR/providers"
  while IFS= read -r -d '' s; do
    rel="${s#"$STATE_DIR"/}"; rel="${rel%.sops}"          # <provider>/<secrets|envs>/<path>
    out="$DATA_DIR/providers/$rel"
    [[ "$DRY_RUN" == true ]] && { log "[dry-run] decrypt $s -> $out"; continue; }
    mkdir -p "$(dirname "$out")"
    sops --decrypt --input-type binary --output-type binary "$s" > "$out" && chmod 600 "$out" \
      || warn "Failed to decrypt $s"
  done < <(find "$STATE_DIR" -type f -name '*.sops' -print0)
  ok "Restore complete. Plaintext is back under $DATA_DIR/providers."
  exit 0
fi

# ── .sops.yaml (documents the recipient for the encrypted state tree) ──
cat > "$KUTAB_ROOT/.sops.yaml" <<YAML
creation_rules:
  - path_regex: state/.*
    age: $RECIPIENT
YAML

# ── .gitignore (plaintext lives off-repo; commit only state/*.sops) ─────────────
GI="$REPO_ROOT/.gitignore"
if ! grep -q 'KUTAB-SYNC' "$GI" 2>/dev/null; then
  cat >> "$GI" <<'IGN'

# ── KUTAB-SYNC: plaintext secrets/envs live OFF-repo (the data dir). Commit only
# the encrypted state/*.sops copies; ignore any stray plaintext under state/.
state/**
!state/**/
!state/**/*.sops
IGN
fi

# ── encrypt every off-repo plaintext file into the repo's state/ as <file>.sops ──
encrypt_tree() { # encrypt_tree <plaintext-root> <state-root>
  local src="$1" dst="$2" f rel out
  [[ -d "$src" ]] || return 0
  while IFS= read -r -d '' f; do
    [[ "$f" == *.sops ]] && continue
    rel="${f#"$src"/}"; out="$dst/$rel.sops"
    if [[ "$DRY_RUN" == true ]]; then log "[dry-run] encrypt $f -> $out"; continue; fi
    mkdir -p "$(dirname "$out")"
    sops --age "$RECIPIENT" --encrypt --input-type binary --output-type binary "$f" > "$out" \
      && chmod 600 "$out" || warn "Failed to encrypt $f"
  done < <(find "$src" -type f -print0)
}
log "Encrypting every provider's secrets + envs from $DATA_DIR (SOPS/age)…"
for p in "$DATA_DIR"/providers/*/; do
  [[ -d "$p" ]] || continue
  name="$(basename "$p")"
  encrypt_tree "${p}secrets" "$STATE_DIR/$name/secrets"
  encrypt_tree "${p}envs"    "$STATE_DIR/$name/envs"
done

# ── git: identity, remote, commit, push ─────────────────────────────────────────
cd "$REPO_ROOT"
[[ -d .git ]] || { [[ "$DRY_RUN" == true ]] || git init -q; }
git config user.email >/dev/null 2>&1 || git config user.email "ops@kutab.local"
git config user.name  >/dev/null 2>&1 || git config user.name  "Kutab Operator"

if [[ -n "$REMOTE" ]]; then
  if git remote get-url origin >/dev/null 2>&1; then git remote set-url origin "$REMOTE"; else git remote add origin "$REMOTE"; fi
fi

MESSAGE="${MESSAGE:-config snapshot $(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
if [[ "$DRY_RUN" == true ]]; then
  log "[dry-run] git add -A && commit -m \"$MESSAGE\"$([[ "$DO_PUSH" == true ]] && echo ' && push')"
  ui_note "Would commit config + *.sops (plaintext secrets/envs stay local & git-ignored)."
  exit 0
fi

git add -A
if git diff --cached --quiet; then
  ui_note "No changes to snapshot."
else
  git commit -q -m "$MESSAGE"
  ok "Committed: $MESSAGE"
fi

if [[ "$DO_PUSH" == true ]]; then
  if git remote get-url origin >/dev/null 2>&1; then
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"; [[ "$branch" == HEAD ]] && { branch=main; git checkout -q -b main; }
    log "Pushing to $(git remote get-url origin) ($branch)…"
    git push -u origin "$branch" || warn "Push failed — check the remote URL and that your GitHub auth (PAT/SSH) is set up."
  else
    ui_warn "No 'origin' remote set. Re-run with --remote <git-url> to push."
  fi
fi
ok "Config sync complete (secrets encrypted with SOPS/age)."
