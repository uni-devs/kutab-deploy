#!/usr/bin/env bash
# Snapshot deployment config + secrets to a Git/GitHub remote, with secrets
# encrypted via SOPS + age. Plaintext secrets/ + envs/ are git-ignored; only
# their *.sops (encrypted) copies are committed alongside the plaintext config.
#
#   sync-config.sh [--remote <git-url>] [--message <msg>] [--no-push] [--dry-run]
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

REMOTE=""; MESSAGE=""; DO_PUSH=true; DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote) REMOTE="$2"; shift 2 ;;
    --message) MESSAGE="$2"; shift 2 ;;
    --no-push) DO_PUSH=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
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

# ── .sops.yaml (documents the recipient for every provider's secret/env trees) ──
cat > "$KUTAB_ROOT/.sops.yaml" <<YAML
creation_rules:
  - path_regex: providers/.*/(secrets|envs)/.*
    age: $RECIPIENT
YAML

# ── .gitignore (plaintext secrets/envs out; keep their .sops copies) ────────────
GI="$REPO_ROOT/.gitignore"
if ! grep -q 'KUTAB-SYNC' "$GI" 2>/dev/null; then
  cat >> "$GI" <<'IGN'

# ── KUTAB-SYNC: never commit plaintext secrets/envs; only their *.sops copies ──
providers/*/secrets/**
!providers/*/secrets/**/
!providers/*/secrets/**/*.sops
providers/*/envs/**
!providers/*/envs/**/
!providers/*/envs/**/*.sops
**/.mysql_root
IGN
fi

# ── encrypt every plaintext secret/env file to <file>.sops ──────────────────────
encrypt_tree() { # encrypt_tree <dir>
  local dir="$1" f
  [[ -d "$dir" ]] || return 0
  while IFS= read -r -d '' f; do
    [[ "$f" == *.sops ]] && continue
    [[ "$(basename "$f")" == .mysql_root ]] && continue
    if [[ "$DRY_RUN" == true ]]; then log "[dry-run] encrypt $f -> $f.sops"; continue; fi
    sops --age "$RECIPIENT" --encrypt --input-type binary --output-type binary "$f" > "$f.sops" \
      && chmod 600 "$f.sops" || warn "Failed to encrypt $f"
  done < <(find "$dir" -type f -print0)
}
log "Encrypting every provider's secrets + envs (SOPS/age)…"
for p in "$KUTAB_ROOT"/providers/*/; do
  [[ -d "$p" ]] || continue
  encrypt_tree "${p}secrets"
  encrypt_tree "${p}envs"
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
