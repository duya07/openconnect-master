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
  - Account information is stored **in plain text** in `/root/.vpn_accounts.env` (the script tightens it to mode `600`, root-only - anyone who can read that file can read the passwords, so protect it accordingly)
  - Quick selection and switching

- ✅ **Scheduled Tasks Support**
  - Daemon task: Default/ocproxy modes reconnect automatically after a drop; Netns mode stops and cleans up when the tunnel is really gone (it does not auto-reconnect)
  - Scheduled shutdown with your own cron expression (there is no "scheduled start")
  - Connection status monitoring: the main menu shows the mode, the SOCKS address and the egress IP

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

- **Operating System**: Debian/Ubuntu/CentOS/RHEL or other Linux distributions (**fully tested on Debian 12 only**; please verify on other distributions first)
- **Permissions**: Root access required
- **Network**: Internet access required
- **Dependencies**: Script will automatically detect and install necessary dependencies

### Auto-Installed Dependencies

- `openconnect` - OpenConnect VPN client
- `ocproxy` - Required for ocproxy mode
- `gost` - SOCKS5 server for Netns mode
- `socat` - Port forwarding for Netns mode (**preferred**)
- `iptables` - Port forwarding fallback (double NAT) and NAT rules
- `iproute2` - Network configuration tools
- `at` - schedules the 2-minute failsafe cleanup job at startup (if atd is not running the script says so honestly instead of pretending the job exists)
- `curl` - public IP lookups and downloading the gost installer

> The Netns **iptables double NAT** backend only supports an **IPv4 entry point**: kernel DNAT
> cannot cross address families, so IPv6 clients such as `[::1]:port` cannot connect. Use the
> **socat backend** (menu 3) when you need an IPv6 entry point.

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

1. After running the script, select `6) Manage VPN Accounts`
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
1) Start: 🛡️  Default Mode (Global VPN, protects SSH)
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
- Two port-forwarding backends, one menu entry each: **3) Netns Mode (SOCKS5, socat forwarding)** and **4) Netns Mode (SOCKS5, iptables double NAT)**; the former is a process-level relay (recommended, and it also provides an IPv6 entry point when listening remotely), the latter uses kernel DNAT + SNAT (**IPv4 entry point only**)
- Optional **SOCKS5 username/password**: asked at startup, empty means anonymous; once enabled the main menu shows the auth info

**Usage**:
```bash
# Select after running the script
3) Start: 🌐 Netns Mode (SOCKS5, socat forwarding)
# For kernel forwarding choose 4) Start: 🌐 Netns Mode (SOCKS5, iptables double NAT, IPv4 entry)
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
7) 🗓️  Cron / Daemon Jobs
1) Set up daemon task (check every 5 mins, auto-reconnect)
```

This adds the line below to crontab (the inline `PATH=...` is written by the script: cron's
default `PATH=/usr/bin:/bin` does not contain openconnect or gost, so without it the task
would fail with "command not found"):

```cron
*/5 * * * * PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /path/to/oc_master_en.sh _internal_check_health
```

⚠️ **Note**: In **Default** and **ocproxy** modes the daemon reconnects automatically after a drop; **Netns mode does not auto-reconnect** - when it detects that the tunnel is really gone (criterion: the egress seen inside the netns equals the host egress) it stops and cleans up so the status honestly reads "stopped", leaving the reconnect decision to you

#### Setup Scheduled Shutdown

```bash
# Example: Automatically shutdown VPN at 2 AM daily
7) 🗓️  Cron / Daemon Jobs
2) Add a scheduled stop task
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

### Uninstall

Select `10) 🗑️ Uninstall` in the main menu. It will, in order:

1. Stop the VPN and clean up netns / veth / iptables rules / policy routes / `/etc/netns/<name>/`; if it turned a kernel forwarding switch from 0 to 1, that is restored to 0
2. Remove every crontab entry this script added (the previous crontab is backed up to `/root/.oc_master-crontab.bak` first)
3. Ask about dependencies: `gost` / `socat` are asked about individually, distinguishing "installed by this script" (default: remove) from "already on the machine" (default: keep); `openconnect` and `ocproxy` get a **single combined question** and are **kept by default** (they are common packages other programs may use)
4. Delete the account file `/root/.vpn_accounts.env`, the dependency marker directory `/var/lib/oc-master` and the `/usr/local/bin/ocm` shortcut
5. Delete the script itself

> ⚠️ Steps 4 and 5 cannot be undone - the account file (with plain-text passwords) and the
> script itself are gone. Back them up first if you need them.

### ocm Shortcut Command

The script makes sure the shortcut exists on every start (it does not take up a menu entry): if `/usr/local/bin/ocm` is absent, or is a dangling link that used to point at this script, it creates a symlink to the script so you no longer have to remember the path:

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
9) 🧪 Test Netns IPv6 Connectivity
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
GOST_PID_FILE="/var/run/oc_gost.pid"
SOCAT_PID_FILE="/var/run/oc_socat.pid"           # the .v6 sibling holds the IPv6 socat PID
STATE_FILE="/var/run/oc_manager.state"
SYSCTL_STATE_FILE="/var/run/oc_manager.sysctl"   # netns mode: records the forwarding switch originals
ACCOUNTS_FILE="/root/.vpn_accounts.env"
SHORTCUT_PATH="/usr/local/bin/ocm"
DEPS_STATE_DIR="/var/lib/oc-master"              # records which dependencies this script installed
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
ip netns exec ocm_vpn_space curl https://api.ipify.org

# View SOCKS5 listening ports
ss -tlnp | grep socat                                  # the socat backend listens on the host
ip netns exec ocm_vpn_space ss -lntp                   # gost listens inside the netns (invisible on the host)
iptables -t nat -S | grep DNAT                         # the iptables double NAT backend has no listener, only rules

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
   - Check port forwarding: `ss -tlnp | grep socat` (socat backend) or `iptables -t nat -S | grep DNAT` (iptables double NAT backend, which has no listener process)

3. **IPv6 Not Working**
   - Confirm VPN server supports IPv6
   - Use Netns mode (Default and ocproxy modes have limited IPv6 support)
   - Run IPv6 connectivity test (menu option 9)

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
- ✨ **New**: Netns mode gained an **iptables double NAT** port-forwarding backend (DNAT into the netns + SNAT rewriting the source to the veth address). With DNAT alone all four access paths failed (gost replies never leave the netns); it now has its own menu entry (menu 4, IPv4 entry point only) and `OCM_FORWARDER=iptables` still overrides once
- 🔧 **Improved**: port forwarding is now a pluggable backend module (`_fwd_setup_<name>` / `_fwd_teardown_<name>`; the main flow only calls `_fwd_avail` / `_fwd_setup` / `_fwd_teardown`), so a new scheme touches only the module area
- 🔧 **Fix**: now that each backend has its own menu entry, picking socat in menu 3 and failing to install it refuses to start (it no longer switches backends silently); use menu 4 for the kernel path
- 🔧 **Fix**: with a `0.0.0.0` bind, reaching the port through the host's own LAN address failed - locally generated traffic never traverses PREROUTING, so the OUTPUT chain now matches it too
- 🔧 **Fix**: Uninstalling gost used `--remove`, which the official script does not support - it actually opened the interactive "pick a version" installer and aborted the uninstall; it now deletes the binary directly
- 🔧 **Fix**: Deleting a VPN account left the account file with mode 644 instead of 600
- 🔧 **Fix**: Stopping Netns mode left openconnect running for a long time (its logout path was torn down first, and the leftover process fought the next connection)
- 🔧 **Fix**: A failed start did not cancel the failsafe rollback job, which killed the connection the user had re-established 2 minutes later
- ✨ **New**: Menu 8 now scans dependency status and marks "installed by this script" vs "pre-existing"; on uninstall the latter is kept by default with a warning, so packages used elsewhere are not removed by accident
- 🔧 **Fix**: `cleanup_netns` never removed `/etc/netns/<name>/`, so every Netns run left a directory behind on the system (still there after uninstalling the script)
- 🔧 **Fix**: A wrong key or a bare Enter at the main menu quit the whole program - the trailing `[[ ]] && read` in `main_menu` returns 1, and "a function whose last statement returns non-zero" makes `set -e` terminate the script; it now returns explicitly and exits cleanly when stdin ends (otherwise it would spin on the menu)
- 🔧 **Fix**: The account and cron submenus reused the main menu's option variable (no `local`), so the "press any key" decision after returning used the submenu's value - after choosing 5/6 that produced a spurious extra "press any key to return to the main menu" that also swallowed the next input character
- 🔧 **Fix**: `stop` aborted halfway when the state file existed but lacked `MODE=`/`VPS4=`/`VPS6=` (the assignment is the last command of an `[ -f ] && ...` list, and `grep` returning 1 made `set -e` end the whole stop path: no process killed, no temp file removed, no safety-net job cancelled)
- 🔧 **Fix**: Account deletion now removes exactly the row at the given index of the filtered list. The old `grep -vF ... && mv` printed "Deleted" without changing the file when the last entry was removed (`grep` produced no output, returned 1, so `mv` never ran) and also removed two identical accounts at once
- 🔧 **Fix**: In the Netns stop path, a failing `eval iptables -D` (rule already removed elsewhere) aborted the whole stop flow via `set -e`, leaving processes and the netns behind
- 🔧 **Fix**: After a failed start, `stop_vpn` took the "not running" early exit and left the state file plus the policy routes (ip rule) behind; machines with the health cron installed would retry the bad account every 5 minutes
- 🔧 **Fix**: The ocproxy health reconnect never worked under cron - the reconnect logic starts with an interactive port prompt, and without a terminal `read` hits EOF and `set -e` kills the flow instantly. Reconnects now reuse the port saved in the state file; also removed the dead link to the deleted docs/FAQ.md
- ✨ **New**: Netns mode is split into two menu entries by forwarding backend - `3) Netns Mode (SOCKS5, socat forwarding)` and `4) Netns Mode (SOCKS5, iptables double NAT)`. Pick one directly; there is no separate "preference" step any more. If socat was chosen but cannot be installed, startup is refused instead of silently falling back; `OCM_FORWARDER` still overrides once for scripted calls
- ✨ **New**: Netns mode supports an optional **SOCKS5 username/password**, asked at startup (empty means anonymous); gost is started as `socks5://user:pass@host:port`. Both fields reject `/` quotes backslash and blanks (they break gost's URL parsing; `@` and `:` were measured to work and are now allowed); the state file is written with `%q` escaping and tightened to 600; the main menu shows the listening address and the auth info on the SOCKS line
- ✨ **New**: The daemon (menu 7, option 1) no longer does nothing for Netns mode. It used to print "does not support auto-reconnect yet" and skip - but once the tunnel drops while the interfaces and state file remain, gost falls back to the host egress and the menu says "running" while nothing goes through the VPN. A definite failure (same criterion as the startup check: the netns egress already equals the host egress) now triggers a stop and cleanup, so the status honestly becomes "stopped" and the user reconnects; auto-reconnect is still not attempted
- 🔧 **Fix**: **Netns mode occasionally reported "running" while nothing went through the VPN** (gost egressed through the machine's own public IP). The criterion is now "the egress seen inside the netns differs from the host egress", waiting up to ~50s and treating startup as failed with a rollback when it never does. Two earlier criteria were measured and rejected: (1) "ping works" - while the netns default route has not been taken over, ping still succeeds via veth -> host -> NAT; a netns with no VPN at all pinged fine and egressed through the host IP; (2) "default route points at tun" - openconnect creates tun0 and installs the route before the tunnel is negotiated, and removes tun0 again when the connection drops; that criterion held ("waited 0s") while traffic had already fallen back to the veth
- 🔧 **Fix**: **The iptables double NAT backend did not forward at all on some machines.** After the OUTPUT DNAT, host-generated traffic still carries `127.0.0.1` as its source; netfilter then re-routes the packet (`ip_route_me_harder`) and the kernel consults `route_localnet` to decide whether `127.0.0.0/8` may leave through that interface. The default `0` means it may not, so the packet is dropped as a martian and never reaches POSTROUTING (measured: the DNAT counter keeps climbing, the SNAT counter stays at 0, tcpdump on the veth sees nothing). It "worked" on the original test host only because that machine had the global `all=1` (the kernel uses `IN_DEV_ORCONF`, i.e. `all` OR the interface value). Startup now sets `route_localnet=1` on `veth_ocm_h` only - the script's own interface - and leaves the global `all` alone
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
