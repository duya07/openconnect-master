# 🚀 OpenConnect Master Manager

<div align="center">

**English | [简体中文](README.md)**

![Version](https://img.shields.io/badge/version-7.7.7-blue?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)
![Platform](https://img.shields.io/badge/platform-Linux-lightgrey?style=flat-square)
![Shell](https://img.shields.io/badge/shell-bash-89e051?style=flat-square)

**All-in-One OpenConnect VPN Management Tool**

Three Running Modes | Policy Routing Protection | Network Namespace Isolation | IPv4+IPv6 Dual Stack

[Quick Start](#-quick-start) • [Features](#-features) • [Documentation](#-documentation)

</div>

---

## ✨ Features

### 🎯 Three Running Modes

| Mode | Icon | Description | IPv4 | IPv6 | Use Case |
|------|------|-------------|------|------|----------|
| **Default Mode** | 🛡️ | Global VPN + SSH Protection | ✅ | ✅ | Scenarios requiring global proxy |
| **ocproxy Mode** | 🔌 | SOCKS5 Proxy (Simplified) | ✅ | ❌ | Lightweight proxy needs |
| **Netns Mode** | 🌐 | Network Namespace Isolation | ✅ | ✅ | **Recommended**! Complete isolation, dual-stack support |

### 🔥 Core Features

- ✅ **Intelligent Policy Routing**
  - Automatically protects SSH connections from VPN interference
  - Supports IPv4 and IPv6 dual-stack routing
  - Precise routing table management and cleanup

- ✅ **Multi-Account Management**
  - Support for multiple VPN account switching
  - Encrypted storage of account information
  - Quick selection and switching

- ✅ **Scheduled Tasks Support**
  - Automatic reconnection daemon
  - Scheduled start/stop
  - Connection status monitoring

- ✅ **Safe Cleanup Mechanism**
  - Complete environment cleanup
  - Automatic rollback protection
  - Graceful interrupt handling

- ✅ **Network Namespace Isolation** (Netns Mode)
  - Completely independent network environment
  - Does not affect host network
  - Supports IPv4 and IPv6 dual stack
  - Access via SOCKS5 proxy

## 📦 System Requirements

- **Operating System**: Debian/Ubuntu/CentOS/RHEL or other Linux distributions
- **Permissions**: Root access required
- **Network**: Internet access required
- **Dependencies**: Script will automatically detect and install necessary dependencies

### Auto-Installed Dependencies

- `openconnect` - OpenConnect VPN client
- `ocproxy` - Required for ocproxy mode
- `gost` - SOCKS5 server for Netns mode
- `socat` - Port forwarding for Netns mode (required)
- `iptables` - Firewall and NAT rules
- `iproute2` - Network configuration tools

## 🚀 Quick Start

### Method 1: One-Click Install (Recommended)

```bash
# Download and run directly
bash <(curl -fsSL https://raw.githubusercontent.com/duya07/openconnect-master/main/oc_master_en.sh)
```

### Method 2: Manual Install

```bash
# Download script
wget https://raw.githubusercontent.com/duya07/openconnect-master/main/oc_master_en.sh

# Add execute permission
chmod +x oc_master_en.sh

# Run script
./oc_master_en.sh
```

### Method 3: Clone Repository

```bash
# Clone repository
git clone https://github.com/duya07/openconnect-master.git
cd openconnect-master

# Run script
chmod +x oc_master_en.sh
./oc_master_en.sh
```

## 📖 Documentation

### First Run

1. After running the script, select `5) Manage VPN Accounts`
2. Add your VPN account information:
   - Display name (for easy identification)
   - VPN username
   - VPN password
   - VPN server address
   - Authentication group (optional)

### Protocol Selection

When starting any mode, you are asked which protocol to use right after choosing an account. **It must match your VPN gateway type** — choosing the wrong one fails at the authentication stage (the script cannot tell which type of gateway yours is):

| Option | Value passed to `openconnect` | Applicable Gateways |
|---|---|---|
| 1 | `anyconnect` | Cisco AnyConnect, ocserv (default) |
| 2 | `pulse` | Pulse Secure / Ivanti Secure Access |
| 3 | `nc` | Juniper Network Connect |

### Mode Selection Guide

#### 🛡️ Default Mode

**Use Cases**:
- Global VPN proxy needed
- All traffic through VPN
- Access to internal network resources

**Features**:
- All traffic through VPN
- Automatic SSH connection protection
- IPv4 and IPv6 support

**Usage**:
```bash
# Select after running the script
1) Start: 🛡️  Default Mode (Global VPN, SSH Protection)
```

#### 🔌 ocproxy Mode

**Use Cases**:
- Only need SOCKS5 proxy
- No IPv6 support needed
- Lightweight usage

**Features**:
- Provides SOCKS5 proxy interface
- IPv4 only
- Listens on localhost 127.0.0.1 by default

**Usage**:
```bash
# Select after running the script
2) Start: 🔌 ocproxy Mode (SOCKS5, IPv4 only)
# Enter listening port (e.g. 1080)
```

#### 🌐 Netns Mode (Recommended)

**Use Cases**:
- Need completely isolated network environment
- Need both IPv4 and IPv6 support
- Seeking best stability and compatibility

**Features**:
- Complete isolation using Network Namespace
- Does not affect host network
- IPv4 and IPv6 dual-stack support
- Access via SOCKS5 proxy
- Option for local or remote listening
- Two port-forwarding backends, one menu entry each: **3) Netns Mode (SOCKS5, socat forwarding)** and **4) Netns Mode (SOCKS5, iptables double NAT)**; the former is a process-level relay (recommended), the latter uses kernel DNAT + SNAT
- Optional **SOCKS5 username/password**: asked at startup, empty means anonymous; once enabled the main menu shows the auth info

**Usage**:
```bash
# Select after running the script
3) Start: 🌐 Netns Mode (SOCKS5, socat forwarding)
# For kernel forwarding choose 4) Start: 🌐 Netns Mode (SOCKS5, iptables double NAT)
# Enter listening port (e.g. 8585)
# Choose whether to allow remote connections
```

### Account Configuration File Format

Account information is stored in `/root/.vpn_accounts.env`, format:

```
DisplayName|Username|Password|VPNHost|AuthGroup(optional)
```

Example:
```
Example Gateway A|user001|your_password|vpn.example.com|DefaultGroup
Example Gateway B|user002|your_password|vpn2.example.com|
```

See also [examples/vpn_accounts.example](examples/vpn_accounts.example)

### Scheduled Tasks

#### Setup Daemon (Auto-Reconnect)

```bash
# In script main menu select
6) Setup Scheduled/Daemon Tasks
1) Setup Daemon Task (Check every 5 minutes, reconnect on disconnect)
```

This adds to crontab:
```cron
*/5 * * * * /path/to/oc_master_en.sh _internal_check_health
```

⚠️ **Note**: Daemon tasks currently only support **Default Mode** and **ocproxy Mode**

#### Setup Scheduled Shutdown

```bash
# Example: Automatically shutdown VPN at 2 AM daily
6) Setup Scheduled/Daemon Tasks
2) Add Scheduled Shutdown Task
# Enter: 0 2 * * *
```

### Stop VPN

```bash
# Method 1: In script menu
5) Stop VPN

# Method 2: Direct command line
./oc_master_en.sh stop

# Method 3: After installing the shortcut command
ocm stop
```

### ocm Shortcut Command

Select `10) 🔗 Install ocm shortcut command` in the main menu and the script creates a symlink at `/usr/local/bin/ocm` pointing to itself, so you no longer have to remember the script path:

```bash
ocm          # open the main menu
ocm stop     # stop the VPN
```

- It only takes over a link that already points at this script; if that path is occupied by another real file, it refuses to overwrite and tells you.
- If the script itself has no execute permission, it is added automatically (otherwise the symlink could not be run).
- The shortcut command is removed along with the script when you uninstall.

### IPv6 Connectivity Test

For Netns mode, you can test IPv6 connectivity:

```bash
# In script main menu select
8) 🧪 Test Netns IPv6 Connectivity
```

Test items include:
1. ✓ Check global IPv6 address in Netns
2. ✓ Ping Google IPv6 DNS (2001:4860:4860::8888)
3. ✓ HTTP IPv6 connection test

## 🔧 Advanced Configuration

### Custom Configuration Parameters

Key configuration variables in the script (modify as needed):

```bash
# Network Namespace Configuration
NETNS_NAME="ocm_vpn_space"
VETH_HOST="veth_ocm_h"
VETH_NS="veth_ocm_ns"
VETH_HOST_IP="192.168.200.1"
VETH_NS_IP="192.168.200.2"

# Routing Table IDs
RT4_ID=100  # IPv4 routing table
RT6_ID=101  # IPv6 routing table

# File Locations
PID_FILE="/var/run/oc_manager.pid"
STATE_FILE="/var/run/oc_manager.state"
ACCOUNTS_FILE="/root/.vpn_accounts.env"
```

### Manual Debug Commands

```bash
# View Network Namespaces
ip netns list

# View network configuration inside Netns
ip netns exec ocm_vpn_space ip addr
ip netns exec ocm_vpn_space ip route

# Test connection inside Netns
ip netns exec ocm_vpn_space ping 8.8.8.8
ip netns exec ocm_vpn_space curl https://ip.p3terx.com

# View SOCKS5 listening port
ss -tlnp | grep gost

# View OpenConnect process
ps aux | grep openconnect
```

## 🐛 Troubleshooting

### Common Issues

1. **VPN Connection Failed**
   - Check if account information is correct
   - Verify VPN server address is accessible
   - Check OpenConnect logs

2. **SOCKS5 Proxy Not Working** (Netns Mode)
   - Test network connectivity in Netns: `ip netns exec ocm_vpn_space ping 8.8.8.8`
   - Check if gost process is running: `ps aux | grep gost`
   - Check port forwarding: `ss -tlnp | grep 8585`

3. **IPv6 Not Working**
   - Confirm VPN server supports IPv6
   - Use Netns mode (Default and ocproxy modes have limited IPv6 support)
   - Run IPv6 connectivity test (menu option 8)

4. **SSH Connection Interrupted** (Default Mode)
   - Script automatically protects SSH connections
   - If still interrupted, check policy routing configuration

## 📊 Version History

### v7.7.7 (2025-10-25) - Final

- ✨ **New**: Active IPv6 connectivity test feature for Netns mode
- 🔧 **Fix**: Enhanced IPv6 detection in show_status, improved detection success rate
- 🔧 **Optimization**: Simplified ocproxy mode, removed remote connection option, listen on localhost by default
- ✨ **Enhancement**: socat forwarding supports IPv4 and IPv6 dual-stack listening
- 📝 **Documentation**: Improved usage documentation and troubleshooting guide

**Follow-up fixes (still v7.7.7)**

- 🔧 **Fix**: Netns mode intermittently reported a startup failure right after "TUN interface is ready" - under `set -o pipefail`, `grep -q` exits early and `ip` dies from SIGPIPE, so a successful match was treated as a failure (measured ~17% of runs)
- ✨ **New**: Netns mode gained an **iptables double NAT** port-forwarding backend (DNAT into the netns + SNAT rewriting the source to the veth address). With DNAT alone all four access paths failed (gost replies never leave the netns); without socat it is now used automatically, and `OCM_FORWARDER=iptables` forces it
- 🔧 **Improved**: port forwarding is now a pluggable backend module (`_fwd_setup_<name>` / `_fwd_teardown_<name>`; the main flow only calls `_fwd_pick` / `_fwd_setup` / `_fwd_teardown`), so a new scheme touches only the module area
- 🔧 **Fix**: a missing or failed socat no longer aborts startup (the caller used `|| return`; it now falls back to the iptables backend)
- 🔧 **Fix**: with a `0.0.0.0` bind, reaching the port through the host's own LAN address failed - locally generated traffic never traverses PREROUTING, so the OUTPUT chain now matches it too
- 🔧 **Fix**: Uninstalling gost used `--remove`, which the official script does not support - it actually opened the interactive "pick a version" installer and aborted the uninstall; it now deletes the binary directly
- 🔧 **Fix**: Deleting a VPN account left the account file with mode 644 instead of 600
- 🔧 **Fix**: Stopping Netns mode left openconnect running for a long time (its logout path was torn down first, and the leftover process fought the next connection)
- 🔧 **Fix**: A failed start did not cancel the failsafe rollback job, which killed the connection the user had re-established 2 minutes later
- ✨ **New**: Menu 7 now scans dependency status and marks "installed by this script" vs "pre-existing"; on uninstall the latter is kept by default with a warning, so packages used elsewhere are not removed by accident
- 🔧 **Fix**: `cleanup_netns` never removed `/etc/netns/<name>/`, so every Netns run left a directory behind on the system (still there after uninstalling the script)
- 🔧 **Fix**: A wrong key or a bare Enter at the main menu quit the whole program - the trailing `[[ ]] && read` in `main_menu` returns 1, and "a function whose last statement returns non-zero" makes `set -e` terminate the script; it now returns explicitly and exits cleanly when stdin ends (otherwise it would spin on the menu)
- 🔧 **Fix**: The account and cron submenus reused the main menu's option variable (no `local`), so the "press any key" decision after returning used the submenu's value - after choosing 5/6 that produced a spurious extra "press any key to return to the main menu" that also swallowed the next input character
- 🔧 **Fix**: `stop` aborted halfway when the state file existed but lacked `MODE=`/`VPS4=`/`VPS6=` (the assignment is the last command of an `[ -f ] && ...` list, and `grep` returning 1 made `set -e` end the whole stop path: no process killed, no temp file removed, no safety-net job cancelled)
- 🔧 **Fix**: Account deletion now removes exactly the row at the given index of the filtered list. The old `grep -vF ... && mv` printed "Deleted" without changing the file when the last entry was removed (`grep` produced no output, returned 1, so `mv` never ran) and also removed two identical accounts at once
- 🔧 **Fix**: In the Netns stop path, a failing `eval iptables -D` (rule already removed elsewhere) aborted the whole stop flow via `set -e`, leaving processes and the netns behind
- 🔧 **Fix**: After a failed start, `stop_vpn` took the "not running" early exit and left the state file plus the policy routes (ip rule) behind; machines with the health cron installed would retry the bad account every 5 minutes
- 🔧 **Fix**: The ocproxy health reconnect never worked under cron - the reconnect logic starts with an interactive port prompt, and without a terminal `read` hits EOF and `set -e` kills the flow instantly. Reconnects now reuse the port saved in the state file; also removed the dead link to the deleted docs/FAQ.md
- ✨ **New**: Menu `10) Port forwarding backend` switches between **auto / socat / iptables double NAT**. The preference is stored in `/var/lib/oc-master/forwarder` and applied the next time Netns mode starts; precedence is the `OCM_FORWARDER` env var > menu setting > auto (socat first)
- ✨ **New**: Netns mode supports an optional **SOCKS5 username/password**, asked at startup (empty means anonymous); gost is started as `socks5://user:pass@host:port`. Both fields reject `@ : /` quotes backslash and blanks (they break gost's URL parsing); the state file is written with `%q` escaping and tightened to 600; the main menu shows the listening address and the auth info on the SOCKS line
- 🔧 **Fix**: In `_fwd_setup_iptables`, `dst` and `socks_port` were assigned in the same `local` statement, so the port never took effect (it only worked because bash's dynamic scope happened to find a variable of that name in the caller); split into two `local` statements

### v7.7.6 (2025-01-10)

- 🔧 **Fix**: Adopted correct architecture of "service built-in (gost in netns), port external (socat/DNAT)"
- ✨ **New**: Prioritize socat for port forwarding, with iptables DNAT as backup
- 🔧 **Enhancement**: Added checks for tun interface and internal network connectivity

### v7.7.5 (Earlier)

- Initial version release
- Support for three running modes
- Implemented policy routing protection
- Network Namespace isolation

## 🤝 Contributing

Issues and Pull Requests are welcome!

### Development Guidelines

- Maintain consistent code style
- Add necessary comments
- Update related documentation
- Test all three modes

## 📄 License

This project is licensed under the MIT License - see [LICENSE](LICENSE) file for details

## 🙏 Acknowledgments

- [OpenConnect](https://www.infradead.org/openconnect/)
- [GOST](https://github.com/go-gost/gost)
- [ocproxy](https://github.com/cernekee/ocproxy)
- All users who use and provide feedback

---

<div align="center">

**If this project helps you, please give it a ⭐ Star!**

Made with ❤️ by [duya07](https://github.com/duya07)

</div>
