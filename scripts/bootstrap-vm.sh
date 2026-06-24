#!/usr/bin/env bash
# Bootstrap a fresh Ubuntu/Debian VM: packages, Docker, gum/sops/age, and a
# sensible security baseline (firewall, fail2ban, auto-updates). Idempotent.
#
#   bootstrap-vm.sh [--yes] [--swarm-subnet <cidr>] [--harden-ssh] [--skip-docker]
#
#   --yes            non-interactive; safe defaults, skips SSH hardening.
#   --swarm-subnet   restrict Swarm ports (2377/7946/4789) to this CIDR (e.g. 10.0.0.0/24).
#   --harden-ssh     disable SSH root login + password auth (confirm first).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUTAB_ROOT="$SCRIPT_DIR"; while [[ "$KUTAB_ROOT" != / && ! -e "$KUTAB_ROOT/lib/common.sh" ]]; do KUTAB_ROOT="$(dirname "$KUTAB_ROOT")"; done
# shellcheck source=../lib/common.sh
source "$KUTAB_ROOT/lib/common.sh"
# shellcheck source=../lib/tui.sh
source "$KUTAB_ROOT/lib/tui.sh"

ASSUME_YES=false; SWARM_SUBNET=""; HARDEN_SSH=false; SKIP_DOCKER=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) ASSUME_YES=true; shift ;;
    --swarm-subnet) SWARM_SUBNET="$2"; shift 2 ;;
    --harden-ssh) HARDEN_SSH=true; shift ;;
    --skip-docker) SKIP_DOCKER=true; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

confirm() { [[ "$ASSUME_YES" == true ]] && return 0; ui_confirm "$1"; }

# root / sudo
SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then have sudo || fail "Run as root or install sudo."; SUDO="sudo"; fi
export DEBIAN_FRONTEND=noninteractive

command -v apt-get >/dev/null || fail "This bootstrap targets Debian/Ubuntu (apt). For other distros, install Docker + gum/sops/age manually."

ui_banner "Bootstrap VM — packages, Docker, security baseline"

# ── base packages ─────────────────────────────────────────────────────────────
log "Updating apt and installing base packages"
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq \
  ca-certificates curl gnupg lsb-release git jq openssl apache2-utils \
  ufw fail2ban unattended-upgrades chrony >/dev/null
ok "Base packages installed"

# ── Docker CE + compose plugin ────────────────────────────────────────────────
install_docker() {
  if have docker && docker compose version >/dev/null 2>&1; then ok "Docker already installed"; return; fi
  log "Installing Docker CE + compose plugin"
  $SUDO install -m 0755 -d /etc/apt/keyrings
  local id; id="$( (. /etc/os-release && echo "$ID") )"
  curl -fsSL "https://download.docker.com/linux/${id}/gpg" | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${id} $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
  # let the invoking non-root user run docker
  [[ -n "$SUDO" && -n "${SUDO_USER:-$USER}" ]] && $SUDO usermod -aG docker "${SUDO_USER:-$USER}" 2>/dev/null || true
  ok "Docker installed (re-login for group membership to take effect)"
}
[[ "$SKIP_DOCKER" == true ]] || install_docker

# ── gum (charm apt repo) ───────────────────────────────────────────────────────
install_gum() {
  have gum && { ok "gum already installed"; return; }
  log "Installing gum"
  curl -fsSL https://repo.charm.sh/apt/gpg.key | $SUDO gpg --dearmor -o /etc/apt/keyrings/charm.gpg
  echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | $SUDO tee /etc/apt/sources.list.d/charm.list >/dev/null
  $SUDO apt-get update -qq && $SUDO apt-get install -y -qq gum >/dev/null && ok "gum installed" \
    || warn "gum install failed — the console will fall back to whiptail/plain."
}
install_gum

# ── age + sops (for encrypted config sync) ─────────────────────────────────────
install_age_sops() {
  have age || { log "Installing age"; $SUDO apt-get install -y -qq age >/dev/null 2>&1 || warn "age apt install failed"; }
  if ! have sops; then
    local ver="${SOPS_VERSION:-v3.9.4}" arch; arch="$(dpkg --print-architecture)"
    log "Installing sops $ver"
    if curl -fsSL -o /tmp/sops "https://github.com/getsops/sops/releases/download/${ver}/sops-${ver}.linux.${arch}"; then
      $SUDO install -m 0755 /tmp/sops /usr/local/bin/sops && rm -f /tmp/sops && ok "sops installed"
    else
      warn "sops download failed — install it before using config sync."
    fi
  else ok "sops already installed"; fi
}
install_age_sops

# ── unattended security upgrades ────────────────────────────────────────────────
log "Enabling unattended security upgrades"
echo 'Unattended-Upgrade::Automatic-Reboot "false";' | $SUDO tee /etc/apt/apt.conf.d/51kutab-unattended >/dev/null
$SUDO dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
ok "unattended-upgrades enabled"

# ── firewall (ufw) ──────────────────────────────────────────────────────────────
configure_firewall() {
  log "Configuring firewall (ufw)"
  $SUDO ufw --force default deny incoming >/dev/null
  $SUDO ufw --force default allow outgoing >/dev/null
  $SUDO ufw allow OpenSSH >/dev/null 2>&1 || $SUDO ufw allow 22/tcp >/dev/null
  $SUDO ufw allow 80/tcp >/dev/null
  $SUDO ufw allow 443/tcp >/dev/null
  if [[ -n "$SWARM_SUBNET" ]]; then
    for p in 2377/tcp 7946/tcp 7946/udp 4789/udp; do $SUDO ufw allow from "$SWARM_SUBNET" to any port "${p%/*}" proto "${p#*/}" >/dev/null; done
    ok "Swarm ports restricted to $SWARM_SUBNET"
  else
    ui_warn "No --swarm-subnet given: Swarm ports (2377/7946/4789) are NOT opened. Single-node clusters are fine; for multi-node, re-run with --swarm-subnet <private-cidr>."
  fi
  if confirm "Enable the firewall now? (OpenSSH/80/443 are allowed)"; then
    $SUDO ufw --force enable >/dev/null && ok "Firewall enabled"
  else
    ui_note "Firewall configured but left disabled. Enable later: sudo ufw enable"
  fi
}
configure_firewall

# ── fail2ban ────────────────────────────────────────────────────────────────────
$SUDO systemctl enable --now fail2ban >/dev/null 2>&1 && ok "fail2ban enabled" || warn "fail2ban could not be enabled"

# ── sysctl hardening ────────────────────────────────────────────────────────────
cat <<'SYSCTL' | $SUDO tee /etc/sysctl.d/99-kutab.conf >/dev/null
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
vm.swappiness = 10
SYSCTL
$SUDO sysctl --system >/dev/null 2>&1 || true
ok "Applied sysctl hardening"

# ── optional SSH hardening (lockout risk) ───────────────────────────────────────
if [[ "$HARDEN_SSH" == true ]]; then
  if [[ "$ASSUME_YES" == true ]] || ui_confirm "Disable SSH root login AND password auth? Ensure you have a working SSH KEY first — this can lock you out."; then
    sshd_drop=/etc/ssh/sshd_config.d/99-kutab.conf
    printf 'PermitRootLogin no\nPasswordAuthentication no\nChallengeResponseAuthentication no\n' | $SUDO tee "$sshd_drop" >/dev/null
    $SUDO systemctl reload ssh 2>/dev/null || $SUDO systemctl reload sshd 2>/dev/null || true
    ok "SSH hardened (key-only, no root)"
  else
    ui_note "Skipped SSH hardening."
  fi
fi

printf '\n'
ok "VM bootstrap complete."
ui_note "If your user was just added to the 'docker' group, log out and back in (or run: newgrp docker)."
