# 🚀 OpenConnect Master Manager

<div align="center">

**English | [简体中文](README.md)**

![Version](https://img.shields.io/badge/version-8.0.0-blue?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)
![Platform](https://img.shields.io/badge/platform-Linux-lightgrey?style=flat-square)
![Shell](https://img.shields.io/badge/shell-bash-89e051?style=flat-square)

**All-in-one OpenConnect VPN egress manager**

Local SOCKS5 Egress | Host-global VPN | Inbound Return Protection | systemd Supervision

[Quick Start](#-quick-start) • [Features](#-features) • [Documentation](#-documentation) • [Management Commands](#-management-commands)

</div>

---

## ✨ Features

### 🎯 Two Running Modes

| Mode | Description | Host Default Route | Use Case |
|---|---|---|---|
| **Local SOCKS5** | Exposes an OpenConnect egress at `127.0.0.1` | Unchanged | Selected applications, proxy services, or ports; recommended |
| **Host-global VPN** | Sends host default egress through the VPN while protecting inbound return traffic for original public addresses | Changed | Hosts that genuinely need all outbound traffic through the VPN |

### 🔥 Core Features

- ✅ **Stable Connections and Recovery**
  - systemd supervises OpenConnect in the foreground and restores it after boot
  - OpenConnect reconnects after extended link interruptions
  - Real HTTP data-plane checks verify more than a PID or listening port
  - Restarts require repeated failures and authentication retries have a cooldown

- ✅ **Low-impact Selective Egress**
  - SOCKS5 mode does not change the host default route, firewall, or sysctl
  - Any SOCKS5-capable application can independently use the VPN
  - Startup verifies both the listener and the actual egress

- ✅ **Inbound Protection in Global Mode**
  - Dedicated policy tables preserve return paths for original VPS public addresses
  - Route tables, rule priorities, and foreign OpenConnect processes are checked before startup
  - An independent three-minute rollback is armed before changing the default route
  - A new external connection must be verified before entering `KEEP`
  - Common DDNS jobs are detected so they do not accidentally publish the VPN egress

- ✅ **Multiple Accounts and Protocols**
  - Store and switch between multiple VPN accounts
  - Supports `anyconnect`, `nc`, and `pulse`
  - Reads legacy five-field account records
  - Passwords stay hidden in listings and the account file is root-only `0600`

- ✅ **Safe Management and Cleanup**
  - An exclusive lock serializes all network-changing operations
  - Startup failure, stop, and abnormal exit clean project-owned state
  - Foreign shortcuts, routes, and OpenConnect processes are not overwritten
  - A short `ocm` management command is installed

## 📦 System Requirements

- **Operating system**: a Linux VPS running systemd
- **Permissions**: root or sudo
- **Network**: access to the VPN gateway and package repositories
- **Base dependencies**: `openconnect`, `curl`, `iproute2`, `procps`, and `util-linux`
- **SOCKS5 dependency**: `ocproxy`

The script detects missing dependencies and uses apt, dnf, or yum only after showing the package scope and receiving confirmation. The current version does not require GOST, socat, Network Namespace, or additional iptables NAT.

## 🚀 Quick Start

### Method 1: Install with curl (Recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/duya07/openconnect-master/main/oc_master.sh -o /tmp/oc_master.sh
sudo bash /tmp/oc_master.sh install
rm -f /tmp/oc_master.sh
sudo ocm
```

### Method 2: Install with wget

```bash
wget -qO /tmp/oc_master.sh https://raw.githubusercontent.com/duya07/openconnect-master/main/oc_master.sh
sudo bash /tmp/oc_master.sh install
rm -f /tmp/oc_master.sh
sudo ocm
```

Installation creates:

```text
/usr/local/sbin/oc-master
/usr/local/bin/ocm -> /usr/local/sbin/oc-master
```

`install` only installs or updates the script and shortcut. It does not connect the VPN or install system packages without confirmation. If another program owns `ocm`, installation stops instead of overwriting it.

### Update

Run either installation method again. The installer will not replace the managed script while a connection is active, so stop it first:

```bash
sudo ocm stop
```

## 📖 Documentation

### First Run

1. Run `sudo ocm` to open the menu.
2. Select `4) 管理账户` to add a VPN account.
3. Start either local SOCKS5 or host-global mode.
4. Check status and the real data plane after startup.

The English launcher shares the same networking implementation as the Chinese launcher. Interactive prompts are currently Chinese; command names and configuration fields remain language-neutral.

### Account Configuration

Accounts are stored in `/root/.vpn_accounts.env`:

```text
Display name|Username|Password|VPN host|Auth group (optional)|Protocol(anyconnect/nc/pulse)
```

Example:

```text
University VPN|student001|password|https://vpn.example.edu|Students|nc
Company VPN|employee|password|https://vpn.example.com||anyconnect
```

See [examples/vpn_accounts.example](examples/vpn_accounts.example).

The account file is root-only `0600` **plaintext**, not an encrypted vault. Fields cannot contain `|` and passwords cannot contain newlines. Legacy five-field records remain readable but require an explicit protocol choice on each start.

### 🔌 Local SOCKS5 Mode (Recommended)

Use this mode when only selected applications or services need the VPN egress:

1. Select `1) 启动本地 SOCKS5 出口`.
2. Choose an account and a local port such as `1080`.
3. Configure the application to use `127.0.0.1:1080`.

Verify the egress:

```bash
curl --proxy socks5h://127.0.0.1:1080 https://api.ipify.org
```

Application example: sing-box can use this address as an outbound and select it with an inbound or route rule. See [selected inbound through VPN](examples/sing-box-selected-inbound.json) and [all TCP through VPN](examples/sing-box-all-tcp.json). SOCKS5 mode carries TCP/IPv4 only; handle UDP/QUIC separately.

### 🛡️ Host-global Mode

Use this mode when the host's default outbound traffic must use the VPN. During startup the manager:

1. Saves the original default route and builds return policies for original VPS public source addresses.
2. Checks policy-table conflicts, rule priorities, foreign OpenConnect processes, and common DDNS jobs.
3. Arms an independent three-minute rollback.
4. Starts the fixed `ocm0` interface and validates the HTTP data plane.
5. Asks you to establish a new external SSH or proxy connection and enter `KEEP` within 120 seconds.

Keep the provider console available on first use. If a new inbound connection fails, do not enter `KEEP`; the manager stops and restores its routing state.

A global VPN can cause ordinary DDNS jobs to publish the VPN egress instead of the VPS address. The manager only detects and warns; it never disables third-party jobs. Pause DDNS first or bind its IP lookup and API request to the original interface/source address.

## 🎛️ Management Commands

### Interactive Menu

```bash
sudo ocm
```

The menu provides:

```text
1) Start local SOCKS5 egress
2) Start host-global VPN
3) Stop VPN
4) Manage accounts
5) Check the VPN data plane now
6) View runtime logs
7) Check/install dependencies
8) Install/update the ocm shortcut
9) Uninstall manager
0) Exit
```

### Command-line Entry Points

```bash
sudo ocm start-proxy   # Start local SOCKS5 egress
sudo ocm start-global  # Start host-global VPN
sudo ocm stop          # Stop and clean project-owned routes
sudo ocm accounts      # Manage accounts
sudo ocm deps          # Check or install all runtime dependencies
sudo ocm status        # Show service, mode, and egress state
sudo ocm check         # Run one real data-plane check
sudo ocm logs          # Show recent connection and health logs
sudo ocm install       # Install or update the shortcut
sudo ocm uninstall     # Uninstall the manager
```

`start-proxy` and `start-global` keep account selection interactive to prevent unattended retries with the wrong credentials or protocol.

### Stop and Uninstall

```bash
sudo ocm stop
sudo ocm uninstall
```

Uninstall stops the VPN and removes project-owned systemd units, executable, shortcut, and active profile. It does not uninstall shared packages, and `/root/.vpn_accounts.env` is preserved by default.

## 🐛 Troubleshooting

```bash
sudo ocm status
sudo ocm check
sudo ocm logs
systemctl status oc-master.service oc-master-health.timer
```

Common checks:

1. **VPN connection fails**
   - Check the account, authentication group, and VPN address.
   - Select `anyconnect`, `nc`, or `pulse` based on the real gateway protocol.
   - Read the explicit OpenConnect error with `sudo ocm logs`.

2. **SOCKS5 listens but does not proxy**
   - Run `sudo ocm check` to verify the HTTP data plane.
   - Test directly with `curl --proxy socks5h://127.0.0.1:PORT https://api.ipify.org`.
   - Check whether another process owns the selected port.

3. **Inbound access fails after global startup**
   - Do not enter `KEEP`; allow the safety rollback to run.
   - Check for multiple interfaces, public addresses, third-party policy routing, or another VPN.
   - Verify that DDNS did not publish the VPN egress.

A healthy result requires a systemd-supervised OpenConnect process, the expected listener or route, and a successful real HTTP request. A PID or listening socket alone is not proof.

## 📊 Version History

### v8.0.0 (2026-09-08)

- ✨ **New**: `ocm` shortcut and non-interactive management commands
- ✨ **New**: OpenConnect protocol stored with each account
- 🔧 **Enhanced**: systemd supervision, real data-plane checks, and retry cooldown
- 🔧 **Enhanced**: global return policy, DDNS risk detection, and independent rollback
- 🔧 **Changed**: two focused modes without GOST, socat, or Netns dependencies

### v7.7.7 (2025-10-25) - Final

- ✨ **New**: Active IPv6 connectivity test for Netns mode
- 🔧 **Fixed**: Improved IPv6 detection in `show_status`
- 🔧 **Optimized**: Simplified ocproxy mode with localhost listening by default
- ✨ **Enhanced**: IPv4 and IPv6 dual-stack socat forwarding
- 📝 **Documentation**: Expanded usage and troubleshooting guidance

### v7.7.6 (2025-01-10)

- 🔧 **Fixed**: Used “service inside Netns, forwarding outside” architecture
- ✨ **New**: Preferred socat forwarding with iptables DNAT fallback
- 🔧 **Enhanced**: Added tun-interface and internal connectivity checks

### v7.7.5 (Earlier)

- Initial release
- Three running modes
- Policy-routing protection
- Network Namespace isolation

Stop an old connection before upgrading. For resources left by an abnormal legacy exit, see [migration guidance](docs/MIGRATION-v8.md).

## 🤝 Contributing

Issues and Pull Requests are welcome!

- Keep the existing code style
- Add comments only where needed
- Update related documentation and examples
- Verify startup, failure rollback, stop, and reconnect paths when changing networking behavior

Audit evidence and live verification notes are kept in [docs/REVIEW.md](docs/REVIEW.md) without replacing this user guide.

## 📄 License

This project is licensed under the MIT License. See [LICENSE](LICENSE).

## 🙏 Acknowledgments

- [OpenConnect](https://www.infradead.org/openconnect/)
- [ocproxy](https://github.com/cernekee/ocproxy)
- [wazum/openconnect-proxy](https://github.com/wazum/openconnect-proxy)
- Everyone who has used, tested, and improved the project

---

<div align="center">

**If this project helps you, please give it a ⭐ Star!**

Made with ❤️ by [duya07](https://github.com/duya07)

</div>
