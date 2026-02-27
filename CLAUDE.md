# CLAUDE.md

## Project Overview

Xray VLESS + REALITY + XTLS-Vision automated installer for VPS servers. Single-file bash script (~1480 lines) that sets up a DPI-resistant proxy server with interactive configuration.

**License:** MIT

## Files

- `xray-setup.sh` — the installer script (the only code file)
- `README.md` — user documentation
- `v2rayNG-settings.md` — Android client setup guide
- `LICENSE` — MIT license

## Supported Platforms

| Distro | Init System | Package Manager |
|--------|-------------|-----------------|
| Debian / Ubuntu | systemd | apt |
| Alpine Linux | OpenRC | apk |

## Script Architecture

The script starts with a `#!/bin/sh` POSIX bootstrap that installs bash if missing (Alpine), then re-execs itself in bash. All code after the bootstrap uses bash features (arrays, `[[ ]]`, `${var,,}`, regex).

### Global Variables

Key globals set during execution (defined at top of file):

- `DISTRO` — `debian` | `alpine`
- `INIT_SYSTEM` — `systemd` | `openrc`
- `PKG_MANAGER` — `apt` | `apk`
- `SECURE_ENV` — `y` | `n` (controls credential display)
- `ENABLE_LOGS` — `y` | `n` (controls Xray logging)
- `BLOCK_TORRENTS` — `y` | `n` (controls BitTorrent routing rule)
- `SSH_DAEMON` — `openssh` | `dropbear`
- `SSH_PORT`, `XRAY_PORT`, `UUID`, `PRIVATE_KEY`, `PUBLIC_KEY`, `SHORT_ID_1`, `SHORT_ID_2`
- `DNS1_NAME`, `DNS1_URL`, `DNS2_NAME`, `DNS2_URL`
- `DEST_DOMAIN`, `SERVER_IP`, `VLESS_LINK`

### Function Map

```
main()
├── print_header()
├── check_root()
├── check_secure_environment()      # Security awareness prompt
├── confirm_proceed()                # Overwrite warning prompt
├── detect_environment()             # Distro, init system, pkg manager
├── prepare_system()                 # Update packages, install deps
├── install_xray()                   # Dispatches to official script or manual
│   ├── install_xray_manual()        # GitHub releases download (non-systemd)
│   └── create_init_script()         # OpenRC /etc/init.d/xray
├── choose_ssh_port()                # Detects and configures SSH
│   ├── detect_ssh_daemon()          # OpenSSH vs Dropbear
│   ├── get_openssh_port()           # Parses sshd_config
│   ├── get_dropbear_port()          # Parses /etc/conf.d/dropbear
│   ├── apply_openssh_port()         # Writes sshd_config + drop-ins
│   └── apply_dropbear_port()        # Writes DROPBEAR_OPTS
├── choose_xray_port()
├── choose_dns()                     # 6 DoH providers
├── choose_logging()                 # Logging preference prompt
├── choose_torrent_blocking()        # BitTorrent blocking prompt
├── generate_credentials()           # UUID, x25519 keypair, short IDs
├── choose_dest_site()               # Camouflage site with TLS 1.3 check
├── write_config()                   # Generates /usr/local/etc/xray/config.json
├── configure_firewall()             # iptables rules + persistence
├── configure_logrotate()            # Weekly rotation (skipped if logging off)
├── optimize_sysctl()                # BBR, TCP buffers
├── start_xray()                     # Validates config, enables service
│   └── create_init_script()         # Regenerated with final log settings
└── print_summary()                  # Interactive credential display + save
```

### Service Abstraction Layer

All init system differences are handled through wrapper functions:

- `svc_enable()`, `svc_restart()`, `svc_reload()`, `svc_is_active()`, `svc_disable()`
- Each dispatches on `$INIT_SYSTEM` (systemd/openrc)

### UI Frames

Interactive prompts use Unicode box-drawing frames. All framed content lines must be exactly **58 visual columns** between the `║` bars. Special character widths:

- Emoji with `east_asian_width` W/F (e.g., 🔒, 🚫) = 2 visual columns
- Emoji with `east_asian_width` N (e.g., ⚠) = 1 visual column
- Bullet `•` = 1 visual column
- ANSI color codes (`${CYAN}`, `${BOLD}`, etc.) = 0 visual columns

Use this Python snippet to verify:

```python
import re, unicodedata

def vis_width(s):
    return sum(2 if unicodedata.east_asian_width(ch) in ('W','F') else 1 for ch in s)

# Extract content between ║${NC} and ${COLOR}║${NC}"
# Remove ${BOLD}, ${NC}, etc. before measuring
# Target: vis_width == 58 for every line
```

Frame colors by section:
- **Header**: cyan
- **Security Check** (🔒): yellow
- **Overwrite Warning** (⚠): red
- **Logging Preference** (📋): cyan
- **BitTorrent Blocking** (🚫): cyan
- **Server Credentials**: cyan

### Xray Config Generation

The Xray JSON config is generated via a heredoc in `write_config()`. Some parts are conditional:

- **Log section**: `loglevel`, `access`, `error` paths depend on `$ENABLE_LOGS`
- **BitTorrent rule**: injected via `$BT_RULE` variable (empty string when disabled, comma-prefixed JSON block when enabled)

### Init Script Generation

OpenRC init scripts are generated in `create_init_script()` and the firewall section of `configure_firewall()`. Key details:

- Shebang (`#!/sbin/openrc-run` vs `#!/usr/sbin/openrc-run`) is detected dynamically
- Log paths (`output_log`, `error_log`) are set to `/dev/null` when logging disabled
- PATH is set locally inside `start()`/`stop()` functions (not top-level) to avoid breaking OpenRC initialization
- The xray init script is generated twice: once during install, regenerated before start with final log settings

## Key Design Decisions

- **Default-safe prompts**: Security-sensitive options default to N (don't show, don't log, don't save)
- **No sudo**: Script requires root directly — Alpine doesn't ship sudo
- **POSIX bootstrap**: `#!/bin/sh` ensures the script can self-install bash on minimal Alpine
- **No grep -P**: BusyBox grep doesn't support Perl regex; use `awk` instead
- **No ss -p**: BusyBox ss doesn't show process names; SSH port read from config files
- **Firewall backup**: Existing rules backed up with timestamp before overwrite

## Testing

The script is designed for fresh VPS instances. To test:

1. Spin up a Debian/Ubuntu or Alpine VPS
2. `scp xray-setup.sh root@vps:/root/`
3. `ssh root@vps 'sh /root/xray-setup.sh'`

For Alpine specifically, also test with Dropbear as the SSH daemon (default on some Alpine images).

To validate config without running: `xray run -test -c /usr/local/etc/xray/config.json`

## Common Modifications

- **Adding a new framed prompt**: Copy an existing frame section, adjust content, verify all lines are 58 visual columns
- **Adding a new routing rule**: Follow the `$BT_RULE` pattern — build conditional JSON in a variable before the heredoc
- **Adding a new distro**: Add case to `detect_environment()`, update `prepare_system()` for its package manager
- **Adding a new init system**: Add cases to all `svc_*()` functions, plus init script generation
