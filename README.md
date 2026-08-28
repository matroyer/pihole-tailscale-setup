# Pi-hole + Tailscale Raspberry Pi setup

`install.sh` turns a fresh Raspberry Pi OS install into a Pi-hole DNS server
reachable network-wide, with SSH/mosh access locked down to your Tailscale
tailnet only.

## What it does

1. Updates the system (`apt update` + `apt full-upgrade`).
2. Installs [Tailscale](https://tailscale.com) and brings the connection up.
3. Installs `mosh`, `htop`, `fastfetch`, `fail2ban`, and `ufw`.
4. Locks down the firewall:
   - Default deny all incoming connections.
   - SSH and mosh are reachable **only** over the `tailscale0` interface.
   - DNS (port 53) and the Pi-hole admin UI (80/443) stay open to your LAN,
     since that's the whole point of running Pi-hole.
   - Enables a `fail2ban` jail for `sshd`.
5. Installs [Pi-hole](https://pi-hole.net) (unattended by default).
6. Configures Pi-hole to listen on all interfaces, so it can also serve DNS
   to devices connecting over Tailscale.
7. Prints a summary: LAN IP, Tailscale IP, admin URL, and next steps.

## Prerequisites

- A Raspberry Pi running Raspberry Pi OS (or another Debian-based distro),
  with internet access and a fresh boot is ideal.
- A [Tailscale account](https://tailscale.com) (free tier is fine).
- Run everything as root (`sudo`).

## Usage

Copy `install.sh` onto the Pi and run it:

```bash
sudo ./install.sh
```

By default this runs fully unattended except for two things you may need to
handle interactively:

- **Tailscale login**: if you don't pass `--authkey`, the script prints a
  login URL — open it in a browser to authorize the device.
- **Firewall confirmation**: if the script detects you're SSH'd in from an
  address that isn't part of your tailnet, it asks you to confirm before
  locking SSH down (see [Avoiding a lockout](#avoiding-a-lockout) below).

### Recommended: fully unattended run

Generate a reusable/ephemeral [auth key](https://login.tailscale.com/admin/settings/keys)
from the Tailscale admin console, then:

```bash
sudo ./install.sh \
  --authkey tskey-auth-xxxxxxxxxxxx-xxxxxxxxxxxxxxxxxxxxxxxxxxxx \
  --pihole-password 'a-strong-password' \
  --yes
```

## Options

| Flag | Description |
|---|---|
| `--hostname NAME` | Tailscale device hostname (default: system hostname). |
| `--authkey KEY` | Tailscale auth key for unattended login (or set `TS_AUTHKEY` env var). |
| `--pihole-password PASS` | Set the Pi-hole admin password (or set `PIHOLE_PASSWORD` env var). If omitted, the script generates a random one and prints it in the summary at the end. |
| `--dns1 IP` | Primary upstream DNS for Pi-hole (default `1.1.1.1`). |
| `--dns2 IP` | Secondary upstream DNS for Pi-hole (default `1.0.0.1`). |
| `--interactive` | Run the official Pi-hole installer's interactive wizard instead of the unattended flow. |
| `--accept-dns` | Let Tailscale override this device's own resolver settings (default: off — this box *is* the DNS server, so it keeps its own upstream config). |
| `--skip-apt-upgrade` | Skip `apt full-upgrade` (still runs `apt update`). |
| `--skip-firewall` | Don't touch `ufw`/`fail2ban` at all — SSH stays reachable however it's currently configured. |
| `-y`, `--yes` | Don't prompt before locking SSH to Tailscale-only, even if the current session isn't connected over Tailscale. |
| `-h`, `--help` | Show usage. |

## Avoiding a lockout

Once the firewall is enabled, **SSH and mosh only work through the
`tailscale0` interface** — plain LAN/WAN SSH access is blocked. If you're
running the script over a direct SSH session (not through Tailscale) when
this happens, you'd disconnect and lose access.

To prevent that, the script checks where your current SSH session is coming
from before enabling the firewall:

- If you're connected over Tailscale already (or running the script from the
  local console, e.g. a keyboard/monitor, or Raspberry Pi Imager's first-boot
  setup), it proceeds automatically.
- If you're connected over a non-Tailscale address, it warns you and asks for
  explicit confirmation (`yes`) before locking SSH down. Declining just skips
  the firewall step — nothing else is affected.
- Pass `-y`/`--yes` to skip this prompt (e.g. for unattended/scripted runs),
  but only do so once you're sure you can already reach the device over
  Tailscale, or you're comfortable finishing setup from the local console.

If you ever do get locked out, connect a keyboard/monitor (or use the
Raspberry Pi Imager's console) and run:

```bash
sudo ufw disable
```

## After it finishes

- **Connect over Tailscale from now on**: `ssh user@<tailscale-ip-or-hostname>`
  instead of the LAN IP.
- **Set Pi-hole as your tailnet's DNS server**: go to the
  [Tailscale DNS admin page](https://login.tailscale.com/admin/dns), add this
  device's Tailscale IP as a global nameserver, and enable
  "Override local DNS" so every device on your tailnet uses Pi-hole.
- **Pi-hole admin UI**: `http://<lan-ip>/admin` or `http://<tailscale-ip>/admin`.
- **Change the admin password anytime** with: `pihole setpassword`.
- Useful checks:
  ```bash
  tailscale status       # tailnet connectivity / peers
  sudo ufw status verbose  # firewall rules
  sudo fail2ban-client status sshd  # banned IPs
  ```

## Re-running the script

The script is safe to run again — it skips installing Tailscale/Pi-hole if
already present, and firewall/package steps are idempotent. Use it to apply
config changes (e.g. a new `--pihole-password`) without a full reinstall.
