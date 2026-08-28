#!/usr/bin/env bash
#
# install.sh - Set up Pi-hole + Tailscale on a fresh Raspberry Pi OS install.
#
# Usage:
#   sudo ./install.sh [options]
#
# Options:
#   --hostname NAME        Tailscale device hostname (default: system hostname)
#   --authkey KEY           Tailscale auth key for unattended `tailscale up`
#                            (or set TS_AUTHKEY env var). If omitted, you'll
#                            need to authenticate via the printed login URL.
#   --pihole-password PASS  Set the Pi-hole admin web password (or set
#                            PIHOLE_PASSWORD env var). If omitted, Pi-hole
#                            generates a random one and prints it.
#   --dns1 IP               Primary upstream DNS for Pi-hole (default: 1.1.1.1)
#   --dns2 IP               Secondary upstream DNS for Pi-hole (default: 1.0.0.1)
#   --interactive           Run the official Pi-hole installer interactively
#                            instead of unattended mode.
#   --accept-dns            Let Tailscale override this device's resolver
#                            (default: off, since this box IS the DNS server).
#   --skip-apt-upgrade      Skip `apt full-upgrade` (still runs `apt update`).
#   --skip-firewall         Don't touch ufw/fail2ban at all.
#   -y, --yes               Don't prompt before locking SSH to Tailscale-only,
#                            even if the current session isn't over Tailscale.
#   -h, --help              Show this help text.
#
# What it does:
#   1. Updates the system.
#   2. Installs Tailscale and brings the tailnet connection up.
#   3. Installs mosh, htop, fastfetch, fail2ban and ufw.
#   4. Locks the firewall down: default deny incoming, SSH/mosh reachable
#      only over the tailscale0 interface, DNS/HTTP(S) left open for LAN
#      clients to use Pi-hole. Enables a fail2ban jail for sshd.
#   5. Installs Pi-hole (unattended by default).
#   6. Configures Pi-hole's DNS resolver to listen on all interfaces so
#      other devices on your tailnet can query it.
#   7. Prints a summary with the LAN IP, Tailscale IP, and admin URL.

set -euo pipefail

# ---------- defaults ----------
TS_HOSTNAME="$(hostname)"
TS_AUTHKEY="${TS_AUTHKEY:-}"
PIHOLE_PASSWORD="${PIHOLE_PASSWORD:-}"
PIHOLE_DNS1="1.1.1.1"
PIHOLE_DNS2="1.0.0.1"
UNATTENDED_PIHOLE=true
ACCEPT_DNS=false
SKIP_APT_UPGRADE=false
SKIP_FIREWALL=false
ASSUME_YES=false
GENERATED_PASSWORD=false

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\n\033[1;33m==> WARNING:\033[0m %s\n' "$1"; }
die()  { printf '\n\033[1;31m==> ERROR:\033[0m %s\n' "$1" >&2; exit 1; }

usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------- arg parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname) TS_HOSTNAME="$2"; shift 2 ;;
    --authkey) TS_AUTHKEY="$2"; shift 2 ;;
    --pihole-password) PIHOLE_PASSWORD="$2"; shift 2 ;;
    --dns1) PIHOLE_DNS1="$2"; shift 2 ;;
    --dns2) PIHOLE_DNS2="$2"; shift 2 ;;
    --interactive) UNATTENDED_PIHOLE=false; shift ;;
    --accept-dns) ACCEPT_DNS=true; shift ;;
    --skip-apt-upgrade) SKIP_APT_UPGRADE=true; shift ;;
    --skip-firewall) SKIP_FIREWALL=true; shift ;;
    -y|--yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help for usage)" ;;
  esac
done

# ---------- preflight ----------
[[ $EUID -eq 0 ]] || die "Please run as root (e.g. sudo ./install.sh)."

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  case "${ID:-}:${ID_LIKE:-}" in
    *debian*|*raspbian*) ;;
    *) warn "This doesn't look like Raspberry Pi OS / Debian (ID=${ID:-unknown}). Continuing anyway." ;;
  esac
else
  warn "Could not detect OS; continuing anyway."
fi

command -v curl >/dev/null 2>&1 || { log "Installing curl..."; apt-get update -y && apt-get install -y curl; }

# ---------- system update ----------
log "Updating package lists..."
apt-get update -y

if [[ "$SKIP_APT_UPGRADE" == false ]]; then
  log "Upgrading installed packages (this may take a while)..."
  DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y
else
  log "Skipping apt full-upgrade (--skip-apt-upgrade set)."
fi

# ---------- Tailscale ----------
if command -v tailscale >/dev/null 2>&1; then
  log "Tailscale is already installed, skipping install step."
else
  log "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
fi

log "Bringing up the Tailscale connection..."
TS_UP_ARGS=(--hostname="$TS_HOSTNAME")
[[ "$ACCEPT_DNS" == true ]] || TS_UP_ARGS+=(--accept-dns=false)
if [[ -n "$TS_AUTHKEY" ]]; then
  TS_UP_ARGS+=(--authkey="$TS_AUTHKEY")
  tailscale up "${TS_UP_ARGS[@]}"
else
  warn "No auth key provided — follow the login link below to authenticate this device."
  tailscale up "${TS_UP_ARGS[@]}"
fi

TAILSCALE_IP="$(tailscale ip -4 2>/dev/null || true)"

# ---------- extra packages ----------
log "Installing mosh, htop, fail2ban and ufw..."
DEBIAN_FRONTEND=noninteractive apt-get install -y mosh htop fail2ban ufw

install_fastfetch() {
  if apt-get install -y fastfetch 2>/dev/null; then
    return
  fi
  warn "fastfetch isn't in the apt repos on this OS release, fetching the latest release from GitHub instead..."

  local machine deb_arch url tmp_deb
  machine="$(uname -m)"
  case "$machine" in
    aarch64) deb_arch="aarch64" ;;
    armv7l)  deb_arch="armv7" ;;
    armv6l)  deb_arch="armv6" ;;
    x86_64)  deb_arch="amd64" ;;
    *) warn "Unsupported architecture '$machine' for the fastfetch fallback download, skipping fastfetch."; return ;;
  esac

  url="$(curl -fsSL https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest \
    | grep -o "\"browser_download_url\": *\"[^\"]*linux-${deb_arch}\.deb\"" \
    | head -n1 | cut -d'"' -f4)"
  if [[ -z "$url" ]]; then
    warn "Couldn't find a matching fastfetch .deb for arch '$deb_arch', skipping fastfetch."
    return
  fi

  tmp_deb="$(mktemp --suffix=.deb)"
  curl -fsSL "$url" -o "$tmp_deb"
  dpkg -i "$tmp_deb" || apt-get install -f -y
  rm -f "$tmp_deb"
}
install_fastfetch

# ---------- fail2ban ----------
log "Configuring fail2ban to guard sshd..."
cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
port = ssh
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
systemctl enable --now fail2ban >/dev/null 2>&1
systemctl restart fail2ban

# ---------- firewall ----------
if [[ "$SKIP_FIREWALL" == true ]]; then
  warn "Skipping firewall setup (--skip-firewall set). SSH remains reachable however it is currently configured."
else
  # Guard against locking ourselves out: if this shell is a remote session
  # that didn't come in over the tailnet, confirm before restricting SSH/mosh
  # to it. $SSH_CONNECTION only exists for SSH sessions -- mosh hands off
  # from sshd to its own UDP session and does not set it, so a bare "was this
  # SSH_CONNECTION not set" check would wrongly treat a non-Tailscale mosh
  # session as safe. Treat any pseudo-terminal session with no SSH_CONNECTION
  # as unverified rather than assuming it's safe.
  ON_TAILSCALE_SESSION=true
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    CLIENT_IP="$(awk '{print $1}' <<< "$SSH_CONNECTION")"
    if [[ "$CLIENT_IP" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]; then
      ON_TAILSCALE_SESSION=true
    else
      ON_TAILSCALE_SESSION=false
    fi
  elif [[ -t 0 ]] && [[ "$(tty 2>/dev/null)" == /dev/pts/* ]]; then
    CLIENT_IP="unknown (non-SSH remote session, e.g. mosh)"
    ON_TAILSCALE_SESSION=false
  fi

  if [[ "$ON_TAILSCALE_SESSION" == false && "$ASSUME_YES" == false ]]; then
    warn "This SSH session is connecting from ${CLIENT_IP:-unknown}, which is NOT a Tailscale address."
    warn "Enabling the firewall now will restrict SSH/mosh to the tailscale0 interface and DROP this session."
    read -r -p "Type 'yes' to proceed anyway, or anything else to skip firewall setup: " CONFIRM
    [[ "$CONFIRM" == "yes" ]] || { warn "Skipping firewall setup. Re-run with --yes once connected over Tailscale."; SKIP_FIREWALL=true; }
  fi
fi

if [[ "$SKIP_FIREWALL" == false ]]; then
  log "Locking down the firewall (SSH/mosh only via Tailscale)..."
  ufw default deny incoming
  ufw default allow outgoing

  # Trust the whole tailnet interface: SSH, mosh and anything else added later.
  ufw allow in on tailscale0 comment 'Tailscale (trusted)'

  # Tailscale's own NAT-traversal port, so direct (non-relayed) connections work.
  ufw allow 41641/udp comment 'Tailscale'

  # Pi-hole needs to keep serving DNS/admin UI to plain LAN clients.
  ufw allow 53/tcp comment 'Pi-hole DNS'
  ufw allow 53/udp comment 'Pi-hole DNS'
  ufw allow 80/tcp comment 'Pi-hole admin'
  ufw allow 443/tcp comment 'Pi-hole admin'

  ufw --force enable
  ufw reload
fi

# ---------- Pi-hole ----------
if command -v pihole >/dev/null 2>&1; then
  log "Pi-hole is already installed, skipping install step."
else
  if [[ "$UNATTENDED_PIHOLE" == true ]]; then
    log "Installing Pi-hole (unattended)..."

    PIHOLE_INTERFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1)"
    IPV4_ADDRESS="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -n1)/24"

    [[ -n "$PIHOLE_INTERFACE" ]] || die "Could not auto-detect the default network interface for Pi-hole. Run with --interactive instead."
    [[ -n "$IPV4_ADDRESS" ]] || die "Could not auto-detect the LAN IPv4 address for Pi-hole. Run with --interactive instead."

    mkdir -p /etc/pihole
    cat > /etc/pihole/setupVars.conf <<EOF
PIHOLE_INTERFACE=${PIHOLE_INTERFACE}
IPV4_ADDRESS=${IPV4_ADDRESS}
IPV6_ADDRESS=
PIHOLE_DNS_1=${PIHOLE_DNS1}
PIHOLE_DNS_2=${PIHOLE_DNS2}
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
CACHE_SIZE=10000
DNS_FQDN_REQUIRED=true
DNS_BOGUS_PRIV=true
DNSMASQ_LISTENING=all
DNSSEC=false
REV_SERVER=false
BLOCKING_ENABLED=true
EOF

    curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended
  else
    log "Launching the official interactive Pi-hole installer..."
    curl -sSL https://install.pi-hole.net | bash
  fi
fi

# Make sure Pi-hole's DNS resolver accepts queries from the Tailscale
# interface too, not just the LAN subnet it was installed against.
# (Pi-hole v6 dropped the `pihole -a` admin subcommands; config is now
# read/written directly through pihole-FTL.)
log "Configuring Pi-hole to listen on all interfaces (needed for tailnet clients)..."
pihole-FTL --config dns.listeningMode all >/dev/null

# Pre-seeding setupVars.conf above makes the installer treat this as a
# migration rather than a fresh install, which skips the wizard that would
# normally generate a random admin password — so nothing sets one unless we
# do it here ourselves.
if [[ -z "$PIHOLE_PASSWORD" ]]; then
  PIHOLE_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)"
  GENERATED_PASSWORD=true
fi
log "Setting the Pi-hole admin password..."
pihole setpassword "$PIHOLE_PASSWORD" >/dev/null

pihole reloadlists >/dev/null 2>&1 || true

# ---------- summary ----------
LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -n1)"

log "Done!"
cat <<EOF

  LAN IP:        ${LAN_IP:-unknown}
  Tailscale IP:  ${TAILSCALE_IP:-unknown (check 'tailscale status')}
  Admin UI:      http://${LAN_IP:-<device-ip>}/admin
                 http://${TAILSCALE_IP:-<tailscale-ip>}/admin
  Admin password:$([[ "$GENERATED_PASSWORD" == true ]] && echo " ${PIHOLE_PASSWORD}  (auto-generated — save it, or change it with: pihole setpassword)" || echo " (set to the value you passed via --pihole-password)")
  Firewall:      $([[ "$SKIP_FIREWALL" == true ]] && echo "NOT configured (--skip-firewall or declined)" || echo "enabled — SSH/mosh reachable only via tailscale0")
  fail2ban:      $(systemctl is-active fail2ban 2>/dev/null || echo unknown)

Next steps:
  * Change the Pi-hole admin password anytime with: pihole setpassword
  * To make every device on your tailnet use this Pi-hole automatically,
    go to the Tailscale admin console (https://login.tailscale.com/admin/dns)
    and add ${TAILSCALE_IP:-<this device's tailscale IP>} as a global
    nameserver, then enable "Override local DNS".
  * SSH and mosh are now only reachable over your tailnet (tailscale0) —
    connect using this device's Tailscale IP/hostname, not its LAN IP.
  * Check tailnet connectivity anytime with: tailscale status
  * Check firewall rules anytime with: ufw status verbose

EOF
