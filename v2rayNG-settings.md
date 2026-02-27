# v2rayNG Optimal Settings for VLESS + Reality

## Connection Profile Settings

These should match your server (filled automatically via share link/QR):

| Setting | Value |
|---|---|
| Protocol | VLESS |
| Address | Your server IP |
| Port | Your Xray port |
| UUID | From setup |
| Flow | `xtls-rprx-vision` |
| Encryption | `none` |
| Network | `tcp` |
| Security | `reality` |
| SNI | Your dest domain (e.g., `www.microsoft.com`) |
| Fingerprint | `chrome` |
| Public Key | From setup |
| Short ID | From setup |
| Spider X | `/` |

---

## App-Level Settings (Settings → gear icon)

These are the ones that matter for stability and speed.

### Routing

| Setting | Value | Why |
|---|---|---|
| Domain Strategy | `IPIfNonMatch` | Best balance — uses DNS only when routing rules don't match directly |
| Routing mode | `Bypass LAN` (or `Bypass LAN & mainland` if in China) | Avoids sending local traffic through proxy |

### DNS

| Setting | Value | Why |
|---|---|---|
| Remote DNS | `https://doh.dns.sb/dns-query` | Matches server config, encrypted, zero logs |
| Direct DNS | `https://doh.dns.sb/dns-query` | Or a local DoH if you need split DNS |
| Enable local DNS | **Off** | Avoids DNS leaks to your ISP |
| Enable DNS routing | **On** | Ensures DNS queries follow routing rules |

### Core Settings

| Setting | Value | Why |
|---|---|---|
| Sniffing | **Off** | With Reality, sniffing can replace destinations and break sites. Server already handles it with `routeOnly: true` |
| Enable Mux | **Off** | Mux multiplexes connections into one detectable stream. Also incompatible with XTLS-Vision |
| Fragment | **Off** | Only enable if experiencing throttling (try `tlshello`, length `100-200`, interval `10-20`) |
| Enable TUN mode (VPN) | **On** | For system-wide proxy. Off if you only need per-app routing |

### Speed & Stability

| Setting | Value | Why |
|---|---|---|
| Concurrent connections | `1` (default) | Multiple TLS handshakes to the same IP draws attention |
| Connection test URL | `https://www.google.com/generate_204` | Fast, lightweight connectivity check |

---

## Things to Avoid

| Don't | Why |
|---|---|
| Enable Mux | Breaks XTLS-Vision flow and creates fingerprint-able multiplexed traffic |
| Enable client-side sniffing | Server-side `routeOnly` is sufficient and safer |
| Use `allowInsecure` | Reality doesn't need it; enabling it signals a non-genuine TLS client |
| Change fingerprint to `random` | Stick with `chrome` for consistency; random fingerprints can mismatch actual behavior patterns |
| Use WebSocket/gRPC transport | You're on TCP+Reality which is the cleanest; mixing transports would override your server config |
