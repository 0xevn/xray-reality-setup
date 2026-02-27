# Xray VLESS + REALITY + XTLS-Vision — Full Setup

## Why This Config Is DPI-Resistant

This configuration uses the **most advanced anti-censorship stack** available in Xray-core:

| Layer | Technology | Purpose |
|-------|-----------|---------|
| Protocol | **VLESS** | Lightweight, no detectable encryption pattern (unlike VMess) |
| TLS | **REALITY** | Steals a real website's TLS fingerprint — no certificates needed, immune to active probing |
| Flow | **XTLS-Vision** | Eliminates double-encryption fingerprints, adds random padding to inner handshakes |
| Fingerprint | **uTLS (chrome)** | Client mimics a real Chrome browser's TLS ClientHello |
| Transport | **TCP** | Most natural, avoids WebSocket/gRPC overhead and patterns |
| DNS | **DNS.SB + Mullvad** | Zero-log DoH providers outside Five Eyes, no PII stored |

**How REALITY works:** When a censor probes your server, Xray forwards the probe to the real camouflage website (e.g., `www.microsoft.com`). The censor sees a legitimate Microsoft response — indistinguishable from a real visit.

---

## Quick Start

```bash
# On a fresh VPS (Debian/Ubuntu or Alpine Linux):
# Install git if not present: apt install git (Debian/Ubuntu) or apk add git (Alpine)
git clone https://github.com/0xevn/xray-reality-setup.git
cd xray-reality-setup

# Run as root (use su/doas/sudo to get a root shell first)
chmod +x xray-setup.sh
sh xray-setup.sh
```

> The script starts with `#!/bin/sh` and auto-installs `bash` if missing (e.g., on Alpine), then re-executes itself in bash. Bash is required for arrays, regex matching, and other features used throughout the script.

### Supported Distributions

| Distro | Package Manager | Init System | Tested |
|--------|----------------|-------------|--------|
| Debian / Ubuntu | apt | systemd | ✔ |
| Alpine Linux | apk | OpenRC | ✔ |

The script auto-detects your distro, init system, and package manager, then adapts accordingly.

> **Installation method:** On systemd distros (Debian/Ubuntu), Xray is installed via the [official install script](https://github.com/XTLS/Xray-install). On Alpine (OpenRC), the official script refuses to run, so the setup downloads the Xray binary directly from GitHub releases, installs geodata files, and creates an OpenRC-compatible init script.

---

## What the Script Does

On launch, the script asks two preliminary questions before making any changes:

1. **Security check** — asks if you're in a secure environment (no shared screens, cameras, or bystanders). This determines whether credentials are shown during setup or hidden entirely.

2. **Overwrite confirmation** — warns that existing Xray config, firewall rules, and sysctl settings will be overwritten (firewall rules are backed up first), and asks you to confirm.

Then the setup proceeds:

1. Detect distro & init system, update packages & install dependencies
2. Install the latest Xray-core (official script on systemd, manual install on OpenRC)
3. Choose a custom SSH port (auto-detects OpenSSH or Dropbear)
4. Choose a custom Xray inbound port
5. Choose primary & secondary DNS providers (DoH)
6. Choose [logging preference](#logging) (disabled by default)
7. Choose [BitTorrent blocking](#bittorrent-blocking) preference (allowed by default)
8. Generate UUID, x25519 key pair, and short IDs
9. Choose a camouflage site (with TLS 1.3 verification)
10. Write the server config to `/usr/local/etc/xray/config.json`
11. Configure iptables firewall (backs up existing rules, writes atomically, SSH brute-force protection)
12. Set up weekly log rotation (skipped if logging disabled)
13. Enable BBR congestion control and TCP optimizations
14. Start Xray service
15. Interactive summary with credential display and save options

### Secure Mode vs Safe Mode

| Behavior | Secure (answered Y) | Safe (answered N / Enter) |
|----------|---------------------|---------------------------|
| Step 6: credentials in terminal | Shown | Hidden |
| Show credentials? | Asked, default **Y** | Auto-skipped |
| Show VLESS share link? | Asked, default **Y** | Auto-skipped |
| Show QR code? | Asked, default **Y** | Auto-skipped |
| Save to file? | Asked, default **N** | Asked, default **Y** (recommended) |

> In safe mode, saving to `/root/xray-credentials.txt` is the recommended way to retrieve your credentials later from a private session.

### Logging

The script asks whether to enable Xray access and error logs. **Default: disabled (N).**

| Choice | Xray loglevel | Log files | Logrotate | Privacy |
|--------|--------------|-----------|-----------|---------|
| Disabled (default) | `none` | None created | Skipped | No connection metadata stored |
| Enabled | `warning` | `/var/log/xray/access.log`, `error.log` | Weekly, 12 weeks retention | Timestamps, IPs, traffic volume recorded |

To re-enable logging later, edit `/usr/local/etc/xray/config.json`:

```json
"log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
}
```

Then create the log directory and restart: `mkdir -p /var/log/xray && <restart command>`

### BitTorrent Blocking

The script asks whether to block BitTorrent protocol traffic. **Default: allowed (N).**

Running torrents through a proxy can get your VPS IP flagged or banned by the hosting provider. Torrent traffic also generates high-volume patterns that are easy for censors to detect. If you only use this proxy for web browsing, blocking BitTorrent is recommended.

When enabled, Xray adds a routing rule that drops any connection using the BitTorrent protocol:

```json
{
    "type": "field",
    "protocol": ["bittorrent"],
    "outboundTag": "block"
}
```

To toggle later, add or remove this rule from the `routing.rules` array in `/usr/local/etc/xray/config.json` and restart Xray.

---

## DNS Servers

During setup, you choose a primary and secondary DNS-over-HTTPS provider from this list:

| # | Provider | Jurisdiction | Logging | DoH URL |
|---|----------|-------------|---------|---------|
| 1 | **DNS.SB** | Germany | No logging | `doh.dns.sb/dns-query` |
| 2 | **Mullvad DNS** | Sweden | Zero logs, audited | `dns.mullvad.net/dns-query` |
| 3 | **Quad9** | Switzerland | No IP logging, threat blocking | `dns.quad9.net/dns-query` |
| 4 | **Quad9 Unfiltered** | Switzerland | No IP logging, no filtering | `dns11.quad9.net/dns-query` |
| 5 | **Cloudflare** | USA | Logs purged 24h, KPMG-audited | `1.1.1.1/dns-query` |
| 6 | **AdGuard DNS** | Cyprus | Aggregated anon stats, ad blocking | `dns.adguard-dns.com/dns-query` |

Defaults: DNS.SB (primary) + Mullvad (secondary). A `localhost` fallback is always appended.

---

## Client Configuration

### Option A: QR Code (fastest for mobile)

During setup (secure mode), choose "Show QR code" and scan it directly with your phone's client app. All connection details are embedded in the QR.

To regenerate a QR code later:

```bash
qrencode -t ANSIUTF8 'vless://UUID@IP:PORT?type=tcp&security=reality&...'
```

Or if you saved credentials to file:

```bash
qrencode -t ANSIUTF8 "$(grep -A1 'VLESS Share' /root/xray-credentials.txt | tail -1)"
```

### Option B: Share Link

The setup script generates a `vless://` link. Paste it into any compatible client:

| Platform | Recommended App |
|----------|----------------|
| Android  | v2rayNG, NekoBox, Hiddify |
| iOS      | Streisand, V2Box, FoXray |
| Windows  | v2rayN, Hiddify, NekoRay |
| macOS    | V2Box, FoXray, NekoRay |
| Linux    | NekoRay, v2rayA, Hiddify |

### Option C: Manual Client Config

Use this template in your client, replacing all `<...>` values with output from the setup script:

```json
{
    "log": {
        "loglevel": "warning"
    },
    "dns": {
        "servers": [
            {
                "address": "https://doh.dns.sb/dns-query",
                "domains": ["geosite:geolocation-!cn"]
            },
            "localhost"
        ],
        "queryStrategy": "UseIP"
    },
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "domain": ["geosite:category-ads-all"],
                "outboundTag": "block"
            },
            {
                "type": "field",
                "ip": ["geoip:private"],
                "outboundTag": "direct"
            }
        ]
    },
    "inbounds": [
        {
            "tag": "socks-in",
            "listen": "127.0.0.1",
            "port": 10808,
            "protocol": "socks",
            "settings": { "udp": true }
        },
        {
            "tag": "http-in",
            "listen": "127.0.0.1",
            "port": 10809,
            "protocol": "http"
        }
    ],
    "outbounds": [
        {
            "tag": "proxy",
            "protocol": "vless",
            "settings": {
                "vnext": [
                    {
                        "address": "<SERVER_IP>",
                        "port": <XRAY_PORT>,
                        "users": [
                            {
                                "id": "<UUID>",
                                "encryption": "none",
                                "flow": "xtls-rprx-vision"
                            }
                        ]
                    }
                ]
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "fingerprint": "chrome",
                    "serverName": "<DEST_DOMAIN>",
                    "publicKey": "<PUBLIC_KEY>",
                    "shortId": "<SHORT_ID>",
                    "spiderX": "/"
                }
            }
        },
        { "tag": "direct", "protocol": "freedom" },
        { "tag": "block", "protocol": "blackhole" }
    ]
}
```

Client-specific settings:
- **fingerprint**: `chrome` (recommended), `firefox`, `safari`, `random`
- **spiderX**: `/` or any path — used for web crawling differentiation per client

---

## Adding More Users

Each user needs a unique UUID:

```bash
xray uuid
```

Add to the `clients` array in `/usr/local/etc/xray/config.json`:

```json
{
    "id": "NEW-UUID-HERE",
    "email": "user2@xray",
    "flow": "xtls-rprx-vision"
}
```

Then restart Xray using the command for your init system (see Management Commands below).

---

## Management Commands

The setup summary prints commands tailored to your init system. Here's a reference:

| Task | systemd (Debian/Ubuntu) | OpenRC (Alpine) |
|------|-------------------------|-----------------|
| Xray status | `systemctl status xray` | `rc-service xray status` |
| Restart Xray | `systemctl restart xray` | `rc-service xray restart` |
| Live logs | `journalctl -u xray -f` | `tail -f /var/log/xray/error.log` |
| Edit config | `nano /usr/local/etc/xray/config.json` | ← same |
| Validate config | `xray run -test -c /usr/local/etc/xray/config.json` | ← same |
| View firewall | `iptables -L -n --line-numbers` | ← same |
| Reload firewall | `netfilter-persistent reload` | `rc-service iptables-xray restart` |
| Update Xray | `bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install` | Re-run `sh xray-setup.sh` |
| Generate QR code | `qrencode -t ANSIUTF8 'YOUR_VLESS_LINK'` | ← same |

---

## Security Best Practices

1. **Use a non-standard SSH port** (the script offers this during setup)
2. **Disable password SSH** — use key-based auth only (OpenSSH: `PasswordAuthentication no` in `sshd_config`; Dropbear: `-s` flag in `/etc/conf.d/dropbear`)
3. **Don't run other services** on the Xray port
4. **Use unique shortIds** per client for identification
5. **Keep Xray updated** using the update command above
6. **Block BitTorrent traffic** if you only use the proxy for web browsing (the script offers this during setup)
7. **Never share your private key** — only share the public key with clients
8. **Run the script in safe mode** if you're in a public place — credentials won't appear on screen
9. **Keep logging disabled** (the default) for maximum privacy — no connection metadata is stored

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Xray won't start | `xray run -test -c /usr/local/etc/xray/config.json` |
| Connection refused | `iptables -L -n` — check that your port is open |
| TLS handshake fails | `xray tls ping <domain>` — verify camouflage site |
| Slow speed | `sysctl net.ipv4.tcp_congestion_control` — should show `bbr` |
| Client can't connect | Ensure UUID, publicKey, serverName, shortId all match |
| Locked out of SSH | Connect via VPS console. OpenSSH: check `/etc/ssh/sshd_config`. Dropbear: check `/etc/conf.d/dropbear` |
| Restore old firewall | `cp /etc/iptables/rules.v4.bak.TIMESTAMP /etc/iptables/rules.v4 && iptables-restore < /etc/iptables/rules.v4` |
| Alpine: Xray not starting | Check `/etc/init.d/xray` exists and `rc-update show` lists it |
| Alpine: iptables not loading on boot | Verify `/etc/init.d/iptables-xray` exists and is in `rc-update show` |
| Alpine: `qrencode` not found | Ensure community repo is enabled: check `/etc/apk/repositories` |

---

## File Locations

| File | Path |
|------|------|
| Xray binary | `/usr/local/bin/xray` |
| Server config | `/usr/local/etc/xray/config.json` |
| Access log | `/var/log/xray/access.log` (if logging enabled) |
| Error log | `/var/log/xray/error.log` (if logging enabled) |
| Log rotation | `/etc/logrotate.d/xray` (if logging enabled) |
| Credentials backup | `/root/xray-credentials.txt` (optional) |
| Firewall rules (v4) | `/etc/iptables/rules.v4` |
| Firewall rules (v6) | `/etc/iptables/rules.v6` |
| Firewall backup | `/etc/iptables/rules.v4.bak.*` (timestamped) |
| Sysctl tuning | `/etc/sysctl.d/99-xray-optimize.conf` |
| Xray init script | `/etc/init.d/xray` (OpenRC only) |
| Firewall init script | `/etc/init.d/iptables-xray` (OpenRC only) |
| Systemd unit | `/etc/systemd/system/xray.service` (systemd only) |
| GeoIP database | `/usr/local/share/xray/geoip.dat` |
| GeoSite database | `/usr/local/share/xray/geosite.dat` |
| OpenSSH config | `/etc/ssh/sshd_config` (if OpenSSH) |
| Dropbear config | `/etc/conf.d/dropbear` (if Dropbear) |

---

## Alpine Linux Notes

Alpine requires a few adaptations that the script handles automatically:

- **Bash**: Not installed by default — the script's POSIX shell bootstrap installs it, then re-executes in bash
- **QR codes**: Package is `libqrencode-tools` (not `qrencode`), requires the `community` repository — auto-enabled if missing
- **Xray install**: Official install script refuses non-systemd — binary is downloaded directly from GitHub releases
- **Init scripts**: OpenRC `openrc-run` path varies by Alpine version (`/sbin/` or `/usr/sbin/`) — auto-detected
- **Firewall persistence**: Custom `/etc/init.d/iptables-xray` OpenRC service restores rules on boot
- **Logrotate**: Cron job created in `/etc/periodic/daily/` since Alpine uses periodic cron, not systemd timers
- **SSH daemon**: Auto-detects OpenSSH or Dropbear — port detection and configuration works with both. Dropbear port is managed via `-p` flag in `/etc/conf.d/dropbear`
- **SSH port detection**: OpenSSH reads from `sshd_config`; Dropbear parses `DROPBEAR_OPTS` in `/etc/conf.d/dropbear` (BusyBox `ss` doesn't support `-p` flag for process names)
- **No `sudo`**: Alpine doesn't ship with `sudo` — run the script as root directly (`su`, `doas`, or root login)

---

## References

- [Xray-core GitHub](https://github.com/XTLS/Xray-core)
- [Official REALITY example](https://github.com/XTLS/Xray-examples/tree/main/VLESS-TCP-XTLS-Vision-REALITY)
- [Project X Documentation](https://xtls.github.io/en/)
- [VLESS protocol docs](https://xtls.github.io/en/config/outbounds/vless.html)
- [Transport/REALITY docs](https://xtls.github.io/en/config/transport.html)
- [DNS.SB](https://dns.sb/)
- [Mullvad DNS](https://mullvad.net/en/help/dns-over-https-and-dns-over-tls)
- [Quad9](https://www.quad9.net/)
- [Cloudflare 1.1.1.1](https://developers.cloudflare.com/1.1.1.1/)
- [AdGuard DNS](https://adguard-dns.io/)

---

## License

This project is licensed under the [MIT License](https://opensource.org/licenses/MIT).
