# 🚀 OpenConnect Master Manager

<div align="center">

**English | [简体中文](README.md)**

![Version](https://img.shields.io/badge/version-8.1.1-blue?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)
![Platform](https://img.shields.io/badge/platform-Linux%20%2B%20systemd-lightgrey?style=flat-square)
![Shell](https://img.shields.io/badge/shell-bash-89e051?style=flat-square)

**All-in-One OpenConnect VPN Management Tool**

Three Running Modes | systemd-managed + Auto-Reconnect | Built-in Diagnostic Logs | Settings Menu + CLI

[Quick Start](#-quick-start) • [Features](#-features) • [Documentation](#-documentation) • [Upgrading from Older Versions](#upgrade)

</div>

---

## ✨ Features

### 🎯 Three Running Modes

| Mode | Icon | Description | IPv4 | IPv6 | Use Case |
|------|------|------|------|------|----------|
| **Default Mode** | 🛡️ | Global VPN + SSH Protection | ✅ | ✅ | The whole machine needs to go through the VPN |
| **ocproxy Mode** | 🔌 | User-space SOCKS5 (no tun device) | ✅ | ❌ | Lightweight proxy needs |
| **Netns Mode** | 🌐 | Network Namespace Isolation + SOCKS5 | ✅ | ✅ | **Recommended**! Only the programs that need it go through the VPN; the host is completely unaffected |

### 🔥 Core Features

- ✅ **systemd-managed, auto-reconnect after drops** (new in v8)
  - openconnect runs in the foreground inside `ocm.service`, so closing SSH no longer takes it down
  - Exits are handled by cause: server terminated the session (expired) → reconnect after ~2 seconds; network error → retry with backoff intervals; authentication failure → counted, and paused once the threshold is reached, **to keep the account from being locked**
  - The netns and the proxy stay in place during a reconnect; clients only notice a few seconds of interruption
  - "Process still running but no connectivity" is detected too: if connectivity stays down beyond a threshold, a soft reconnect is triggered

- ✅ **Built-in long-term diagnostic logs** (new in v8, `ocm-watch.service`)
  - Periodically samples the tunnel / proxy / gateway / egress IP, records every state change and an incident snapshot at each drop
  - `ocm log report` shows in one command the number of drops, **how long the session had lasted at each drop**, and the auto-reconnect record
  - Well suited to troubleshooting "it drops every so often" problems (for example, many school / corporate VPNs have a fixed session length)

- ✅ **⚙️ Settings menu + CLI** (new in v8)
  - Every tunable parameter is listed in the menu with its current value, purpose, options and trade-offs — no need to read the source to guess defaults
  - A settings summary is shown before starting: start directly / change settings and save / change for this run only
  - `ocm -h`: `start / stop / restart / status / log / heal / config / accounts / proxy`, scriptable

- ✅ **Intelligent policy routing** (Default Mode)
  - Automatically protects SSH connections from the global VPN, supports IPv4 and IPv6
  - The first start comes with a 3-minute failsafe automatic rollback

- ✅ **Network Namespace isolation** (Netns Mode)
  - A completely independent network environment, accessed through a SOCKS5 proxy (optional username/password)
  - Two port-forwarding backends: socat (IPv4+IPv6 entry) / iptables double NAT (IPv4 entry only)
  - Optional **kill switch**: when the VPN is down the proxy simply fails; traffic never leaves through the VPS's own egress
  - Or a **fallback proxy** (new in v8.1): while the VPN is down, new connections automatically go through a backup proxy you specify (socks5 / http / https / ss, etc.); they switch back once the VPN recovers, and connections made during fallback are not cut

- ✅ **Multi-account management**
  - Account information is stored **in plain text** in `/root/.vpn_accounts.env` (permissions tightened to `600`, readable by root only; protect it yourself as needed)
  - Each account can specify its own protocol; passwords are not shown in the list or the status area

- ✅ **Safe cleanup mechanism**
  - On stop, openconnect is first allowed to log out normally, then the proxy / netns / routes are torn down
  - Only the kernel forwarding switches this script turned on are restored; uninstall distinguishes "dependencies installed by this script" from "dependencies that were already there"

## 📦 System Requirements

- **Operating System**: Debian/Ubuntu/CentOS/RHEL and other Linux distributions using **systemd** (**currently fully tested on Debian 12 only**; please verify other distributions yourself first)
- **Permissions**: root privileges required
- **Network**: Internet access required
- **Dependencies**: The script automatically detects and installs the required dependencies

### Automatically Installed Dependencies

- `openconnect` - OpenConnect VPN client
- `ocproxy` - Required for ocproxy mode
- `gost` - SOCKS5 server for Netns mode
- `socat` - Port forwarding for Netns mode (**preferred**)
- `iptables` - Fallback port forwarding (double NAT), netns egress NAT, kill switch
- `iproute2` - Network configuration tools
- `at` - 3-minute failsafe rollback on the first start in Default Mode
- `curl` - Public IP lookup, downloading the gost install script

## 🚀 Quick Start

### Method 1: One-Click Download and Run

```bash
wget -O /root/oc_master.sh https://raw.githubusercontent.com/duya07/openconnect-master/main/oc_master_en.sh
chmod +x /root/oc_master.sh
/root/oc_master.sh
```

> v8 is managed by systemd, so **the script must live in a fixed location** (e.g. `/root/oc_master.sh`) — the systemd unit remembers this path.
> Do not run it directly with `bash <(curl …)`.
> `oc_master_en.sh` is the English-UI build; `oc_master.sh` in the repo is the Chinese-UI build with identical functions and settings.

### Method 2: Clone the Repository

```bash
git clone https://github.com/duya07/openconnect-master.git
cd openconnect-master
chmod +x oc_master_en.sh
./oc_master_en.sh
```

The first run automatically creates the shortcut command `ocm`; after that, just type `ocm`.

## 📖 Documentation

### First Run (Three Steps)

1. `6) Manage VPN Accounts` → add an account: display name, username, password, VPN server address, auth group (optional), protocol (optional)
2. `5) Settings` → at least confirm **Running mode**, **VPN protocol** (must match the gateway) and **SOCKS5 port**
3. `1) Start VPN` → check the summary, press Enter to start

Command-line equivalent:

```bash
ocm config set PROTOCOL nc          # protocol: anyconnect / pulse / nc / gp / fortinet / array
ocm config set MODE netns
ocm config set SOCKS_PORT 8585
ocm start
```

After a successful start, the SOCKS5 address and the VPN egress IP are shown. To use it from your own computer (when listening on localhost only):

```bash
ssh -N -L 8585:127.0.0.1:8585 root@your-VPS
# then set the browser / application proxy to SOCKS5 127.0.0.1:8585
```

### ⚙️ Settings Overview

Settings are stored in `/etc/oc-master/settings.conf` (`600`). Every item has a detailed description in menu `5) Settings`; you can also view them with `ocm config list -v`.

| Group | Item (KEY) | Values | Description |
|---|---|---|---|
| Connection | Running mode `MODE` | `netns` / `default` / `ocproxy` | See the mode table above |
| Connection | VPN protocol `PROTOCOL` | `anyconnect` `pulse` `nc` `gp` `fortinet` `array` | Must match the gateway; column 6 of an account can override it |
| Connection | Data channel `DATA_CHANNEL` | `dtls` / `tls` | `dtls`: data switches to UDP after ~1 minute, fast but less stable on lossy networks; `tls`: TLS/TCP throughout (`--no-dtls`), usually more stable on lossy networks |
| Connection | Reconnect-on-outage duration `RECONNECT_TIMEOUT` | 60 / 300 / 900 seconds | How long openconnect keeps reconnecting by itself after a brief network outage; has no effect when the server terminates the session |
| Connection | Tunnel MTU `MTU` | `auto` / 1400 / 1300 / … | Lower it when large files or certain sites stall |
| Connection | Extra arguments `OC_EXTRA` | Free text | Appended verbatim to openconnect, e.g. `--useragent=…` |
| Proxy | SOCKS5 port `SOCKS_PORT` | Number | netns / ocproxy modes |
| Proxy | Listen scope `LISTEN` | `127.0.0.1` / `0.0.0.0` | Always set authentication when exposing it externally |
| Proxy | SOCKS5 authentication `SOCKS_USER`/`SOCKS_PASS` | — | netns mode only |
| Proxy | Port forwarder `FORWARDER` | `socat` / `iptables` | socat has an IPv4+IPv6 entry; iptables has an IPv4 entry only |
| Security | Kill switch `KILL_SWITCH` | `off` / `on` / `proxy` | `on`: when the VPN is down the proxy simply fails and never falls back to the VPS egress; `proxy`: use the [fallback proxies](#fallback-proxy), and behave like `on` if none is reachable (netns only) |
| Security | Fallback proxy choice `FALLBACK_PROXY` | `auto` / display name | `auto`: the first reachable one in list order; a display name: only that one |
| Network | DNS timeout policy `DNS_FAST` | `off` / `on` | `on`: when DNS inside the VPN drops packets, retry after 1 second and rotate servers, reducing "5-second stalls" (netns only) |
| Network | Host IPv6 forwarding `IPV6_FORWARD` | `off` / `on` | Turn on only if you need IPv6 through the proxy |
| Daemon | Auto-reconnect `AUTO_RECONNECT` | `on` / `off` | When off, a drop stops and cleans up |
| Daemon | Reconnect backoff `BACKOFF` | e.g. `5 30 60 120 300 600 900` | Retry interval sequence for network-type failures |
| Daemon | Max reconnects per hour `MAX_PER_HOUR` | Number | Prevents frantic retrying when something goes wrong |
| Daemon | Auth-failure pause threshold `AUTH_FAIL_PAUSE` | Number | Pause after this many consecutive authentication failures (a failure on the very first start stops immediately) |
| Daemon | Soft-reconnect wait `DEGRADED_WAIT` | 30 / 60 / 90 / 180 seconds | How long the process may be running while the proxy stays unreachable before a reconnect is triggered |
| Daemon | Connect at boot `AUTOSTART` | `off` / `on` | Enables `ocm.service` to start at boot |
| Logs | Diagnostic logs `WATCH` | `on` / `off` | `ocm-watch.service` |
| Logs | Sampling interval `SAMPLE_INTERVAL` | 15 / 30 / 60 seconds | Automatically tightens to 5 seconds for 3 minutes after a state change |
| Logs | Total log size cap `LOG_MAX_MB` | 100 / 300 / 1000 | The oldest rotated files are deleted when exceeded |
| Logs | Extra probe URL `EXTRA_PROBE_URL` | URL | E.g. an on-campus resource entry point, to confirm it is reachable |

### ⌨️ Command Line

```text
ocm                      Open the interactive menu
ocm start [options]      Start with the saved settings; options affect this run only, add --save to make them the default
    -a/--account N|name  -m/--mode netns|default|ocproxy  -p/--proto nc|pulse|anyconnect|…
    -P/--port N  --listen 127.0.0.1|0.0.0.0  --tls-only|--dtls  --fwd socat|iptables
    --kill-switch on|off|proxy  --fallback NAME|auto  --dns fast|system  --mtu N|auto  --oc-args "…"  --save  -i
ocm stop | restart [options] | status [-v]
ocm log report [days] | log tail | log snapshot [label] | log mark <text>
ocm heal on|off|status
ocm config list [-v] | get KEY | set KEY VALUE
ocm accounts
ocm proxy list | add ['line'] | del index|name | test [index|name] | format
ocm install-service | uninstall-service
ocm -V | -h
```

Exit codes: `0` success, `1` failure, `2` usage error, `3` already running / state conflict.

### 🔁 How Auto-Reconnect Works

`ocm start` hands the session over to `ocm.service` (the supervisor). Each time openconnect exits, the supervisor determines the cause from the exit code and the output:

| Verdict | Basis | Action |
|---|---|---|
| `server-terminated` | Output contains `Server terminated connection` / `Session terminated by server` | Reconnect after ~2 seconds (no backoff) |
| `watch-request` | The diagnostic service found "process running but no connectivity" and requested a soft reconnect | Reconnect after ~2 seconds |
| `auth` | Exit code 2 (cookie/authentication rejected) or login-failure wording | Counted; failure on the very first start or reaching the consecutive threshold → pause |
| `session-confirm` | The server demands an interactive page, such as confirming an existing session | Retry with backoff |
| `network` | Everything else (DNS, TCP, TLS failures, process crash, etc.) | Retry with `BACKOFF`, limited by `MAX_PER_HOUR` |

> When openconnect receives a termination notice from the server (e.g. session expiry) it **exits immediately**; `--reconnect-timeout` does not cover this case — which is exactly why an external reconnect is needed.
> Before reconnecting, the supervisor restores the netns default route and resolv.conf to the baseline, so it can reconnect even if openconnect was force-killed and never got to clean up.

### 📊 Diagnostic Logs and Reports

Log directory `/var/log/oc-master/`:

| File | Contents |
|---|---|
| `events.log` | Changes only: state transitions, supervisor events (start / exit cause / reconnect), key openconnect lines, manual marks |
| `samples.log` | Periodic samples: process, tun, default route, SOCKS probe, in-tunnel ping, gateway TCP/ping, egress IP, TCP retransmits… |
| `openconnect.log` | All openconnect output (sanitized) |
| `incidents/` | An on-the-spot snapshot each time the normal state is left (routes, NAT, processes, kernel messages…) |
| `launch/` | The full startup output of each `ocm start` |

Everything is rotated by size and gzipped, the total is capped by `LOG_MAX_MB`, and writing samples is paused when free disk space drops below 400MB.

```bash
ocm log report 7
```

Report example (excerpt):

```text
Session end timeline (time since auth when leaving UP; ≈2h = 1h55m–2h05m):
  2026-01-01T19:34:13+0800  →DOWN      session length 2h00m      [≈2h!]   openconnect-gone(state-file-still-present)
  2026-01-01T21:34:47+0800  →DOWN      session length 2h00m      [≈2h!]   openconnect-gone(state-file-still-present)
  Non-manual endings 2, of which in the ≈2h window: 2

Auto-reconnect: openconnect exited 2 times (server-terminated=2), ready again 2 times, soft-reconnect requests 0, paused or rate-limited 0
```

If the drops all fall at the same session length, it is the server's fixed session length, not a network problem.

### Account Configuration File Format

Account information is stored in `/root/.vpn_accounts.env`:

```
DisplayName|Username|Password|VPNHost|AuthGroup(optional)|Protocol(optional)
```

Example:
```
ExampleGatewayA|user001|your_password|vpn.example.com|DefaultGroup
ExampleGatewayB|user002|your_password|vpn2.example.com||nc
```

No field may contain `|`. See also [examples/vpn_accounts.example](examples/vpn_accounts.example).

<a id="fallback-proxy"></a>

### 🛟 Fallback Proxy (Backup Egress for the Kill Switch)

With the kill switch set to `proxy`, **new connections** to the SOCKS5 proxy go through a proxy you specify while the VPN is down or reconnecting; as soon as the VPN recovers, new connections switch back to the VPN. Connections established during fallback are not cut by the switch back.
If no proxy is reachable it behaves like `on`: connections fail outright and **never** use the VPS's own egress. Netns mode only.

```bash
ocm proxy add                     # add one field by field (password not echoed); or main menu 11 [Manage fallback proxies]
ocm proxy test                    # access once through every proxy from this host and show the egress IP
ocm config set KILL_SWITCH proxy  # then ocm restart
```

The list lives in `/etc/oc-master/proxies.conf` (`600`, plaintext passwords), one proxy per line, in either of two notations. The file header documents the format in full (`ocm proxy format` shows it any time; see also [examples/proxies.example](examples/proxies.example)):

```text
# Notation 1: pipe-separated columns (recommended). Write @ : / % etc. in usernames and passwords as-is, no escaping
name|type|address|port|username(optional)|password(optional)
HK-backup|socks5|203.0.113.20|1080|user|p@ss:word
JP-SS|ss|203.0.113.30|8388|aes-256-gcm|ss-password

# Notation 2: URL (read as a URL when column 2 contains ://; percent-encode special characters, @ → %40)
name|type://username:password@address:port[?params]
TLS-proxy|https://bob:pa%40ss@proxy.example.com:443
WS-proxy|socks5+wss://carol:pw@proxy.example.com:443?path=/ws
```

| Type | Notes |
|---|---|
| `socks5` | SOCKS5; `s5` / `s5h` / `socks5h` / `socks` are all treated as this. Target hostnames are always resolved by the upstream proxy (i.e. s5h behaviour) |
| `socks4` / `socks4a` | SOCKS4 / 4a |
| `http` | HTTP proxy (CONNECT) |
| `https` | HTTP proxy over TLS (`http+tls`) |
| `ss` | Shadowsocks: put the cipher (e.g. `aes-256-gcm`) in the username column and the password in the password column |
| `socks5+tls` / `socks5+ws` / `socks5+wss` | SOCKS5 over TLS / WebSocket (path via URL notation `?path=/ws`) |

- vmess / vless / trojan / hysteria are not supported: run the matching client locally, expose a socks5 port, and add that.
- The address must be a hostname or IPv4 (IPv6 addresses are not supported yet). For a proxy on this host write `127.0.0.1`; the script swaps it for `192.168.200.1`, the host address as seen from the netns, so that proxy must listen on `0.0.0.0` or `192.168.200.1`.
- Choice: with `FALLBACK_PROXY=auto` (default) the list is checked top to bottom on each disconnect and the first reachable proxy is used; if the proxy in use goes down, the next one takes over. It can also be fixed to one display name.
- Editing the list needs no restart (the next disconnect uses it); changing `KILL_SWITCH` / `FALLBACK_PROXY` needs `ocm restart`.
- Test coverage: socks5, http and ss were tested end to end (including a long-lived connection surviving the VPN recovery); for https and socks5+tls/ws/wss only gost's parsing was verified, not a live connection.

<details>
<summary>How it works</summary>

A second gost runs inside the netns (listening only on the veth address, chained to the selected proxy, configured from a temporary YAML with mode 600 that is deleted once gost starts, so the proxy password never appears in a long-running process's arguments). While the VPN is down, a `REDIRECT` rule in the netns `nat PREROUTING` chain sends new connections forwarded from the host to it; the rule is removed once the VPN recovers. Established connections keep their path through conntrack; for that the script adds a `/32` route to the proxy IP via the veth and keeps a permanent conntrack rule in the netns (otherwise deleting the REDIRECT makes the kernel drop connection tracking in that netns, and connections made during fallback are reset).

</details>

### Scheduled Tasks

Menu `7) Scheduled Start / Stop`: add `ocm start` or `ocm stop` with a cron expression.
Reconnecting after drops is now handled by the systemd supervisor; **the old cron daemon task is no longer needed**.

### Stopping the VPN

```bash
ocm stop            # or menu 3
```

### Uninstall

Menu `10) 🗑️ Uninstall`: stop the VPN and clean up → remove the systemd units → ask whether to delete the settings and diagnostic logs → remove this script's crontab entries (backed up first to `/root/.oc_master-crontab.bak`) → ask about each dependency individually → delete the account file, the shortcut command and the script itself.

> ⚠️ The account file (with plain-text passwords) and the script itself will be deleted; back them up yourself first if you want to keep them.

### IPv6 Connectivity Test

While Netns mode is running, choose menu `9) 🧪 Test Netns IPv6 Connectivity`: checks for a global IPv6 address, pings Google's IPv6 DNS, and tests HTTP access over IPv6.

<a id="upgrade"></a>

## ⬆️ Upgrading from v7

1. Stop the VPN with the old version first (or run `ocm stop` directly after upgrading; v8 cleans up sessions started by the old version)
2. Overwrite the original file with the new script (the path the `ocm` shortcut points to stays the same)
3. `ocm` → `5) Settings`: confirm the mode, protocol and port (what v7 asked on every start is now saved in the settings)
4. If you configured the old daemon task (`_internal_check_health`), remove it with option `3` in menu `7`; it has been replaced by systemd auto-reconnect
5. `ocm start`

Behavior change: netns mode **no longer** turns on the host's `net.ipv6.conf.all.forwarding` by default (set `IPV6_FORWARD=on` if you need it).

## 🔧 Advanced Configuration

### File Locations

```bash
/etc/oc-master/settings.conf          # settings (600)
/root/.vpn_accounts.env               # accounts (600, plain text)
/etc/oc-master/proxies.conf           # fallback proxies (600, plain text)
/var/log/oc-master/                   # diagnostic logs
/run/oc-master/                       # runtime (stage, settings in effect for this run)
/etc/systemd/system/ocm.service       # supervisor
/etc/systemd/system/ocm-watch.service # diagnostic logs
/var/run/oc_manager.state             # current session state (v7-compatible format)
/var/lib/oc-master/                   # dependency markers, diagnostic service state
```

Network constants in the script (edit the top of the script directly if you need to change them):

```bash
NETNS_NAME="ocm_vpn_space"; VETH_HOST="veth_ocm_h"; VETH_NS="veth_ocm_ns"
VETH_HOST_IP="192.168.200.1"; VETH_NS_IP="192.168.200.2"
RT4_ID=100; RT6_ID=101          # Default Mode SSH protection routing tables
OC_TUN_DEFAULT="ocmtun0"        # tunnel interface name in Default Mode
```

### Manual Debug Commands

```bash
ocm status -v                                   # running status + latest sample
journalctl -u ocm -n 100                        # supervisor output
ocm log tail                                    # live events + openconnect output
ip netns exec ocm_vpn_space ip route            # routes inside the netns
ip netns exec ocm_vpn_space curl https://api.ipify.org
ss -tlnp | grep socat                           # the socat backend listens on the host
ip netns exec ocm_vpn_space ss -lntp            # gost listens inside the netns
```

## 🐛 Troubleshooting

1. **VPN Connection Failed**
   - Check the stage with `ocm status -v`; the full startup output is in `/var/log/oc-master/launch/`
   - Stage shows `failed:auth`: wrong or rejected username/password; after verifying, run `ocm start` again (auto-reconnect has been paused to keep the account from being locked)
   - Check that the protocol matches the gateway (Settings → VPN protocol)

2. **Drops at a fixed interval**
   - Check the "session end timeline" in `ocm log report 7`. If the drops all fall at the same session length, it is usually the server's session limit, which the client cannot extend; auto-reconnect will reconnect within a few seconds

3. **SOCKS5 proxy works intermittently** (Netns Mode)
   - Look at "brief in-session failures" in the report and the `tping` (in-tunnel packet loss) and `socks` fields in the samples
   - On lossy networks try `DATA_CHANNEL=tls`; for "5-second stalls" caused by DNS packet loss inside the VPN try `DNS_FAST=on`

4. **Fallback proxy does not kick in** (`KILL_SWITCH=proxy`)
   - `ocm proxy test` shows whether each proxy is reachable and its egress IP; `ocm status` shows the fallback proxy as standby / in use
   - `SUP fallback …` events in `ocm log report 1`: `unavailable` means no proxy in the list was reachable at that moment
   - A local proxy that listens only on `127.0.0.1` cannot be reached from the netns; make it listen on `0.0.0.0` or `192.168.200.1`

5. **SSH Connection Interrupted** (Default Mode)
   - The script automatically protects SSH connections; if success is not confirmed within 3 minutes of the first start, it rolls back automatically

## 📊 Version History

### v8.1.1 (2026-11-12)

- 🔒 **Security fix**: in Netns mode, gost inside the netns used to listen on every interface (`socks5://:PORT`), including the VPN tunnel interface tun0. tun0 carries the public address assigned by the VPN, so outsiders could reach that port through the VPN gateway; without SOCKS5 auth this was an **open proxy using your VPN identity**. "Listen = localhost only" only restricted the forwarding entry on the host. gost now listens only on the veth address `192.168.200.2`, and the netns additionally drops that port arriving on `tun+` (IPv4/IPv6). **Netns mode users on v8.1.0 or earlier should upgrade and restart the VPN**

### v8.1.0 (2026-11-12)

- ✨ **New**: a third kill switch option, "fallback proxy" (`KILL_SWITCH=proxy`): while the VPN is down, new connections go through a specified proxy and switch back automatically when it recovers, without cutting connections made during fallback; if no proxy is reachable, connections fail outright
- ✨ **New**: fallback proxy list `/etc/oc-master/proxies.conf` in pipe-column or URL notation; supports socks5 (including the s5 / s5h aliases), socks4/4a, http, https, ss, socks5+tls/ws/wss; main menu 11 and `ocm proxy list|add|del|test|format`
- ✨ **New**: setting `FALLBACK_PROXY` (auto = first reachable in list order / fixed to one); `ocm start --kill-switch proxy --fallback NAME`
- ✨ **New**: diagnostic samples gain an `fb=` field, the report counts fallback episodes and total time, and the status page shows whether the fallback proxy is in use

### v8.0.0 (2026-11-12)

- ✨ **New**: systemd management (`ocm.service`). openconnect now runs in the foreground and reconnects automatically by exit cause (server termination / network error / authentication failure handled separately); the netns and proxy stay in place during reconnects; closing SSH no longer affects the VPN
- ✨ **New**: built-in long-term diagnostic logs (`ocm-watch.service`): samples, events, incident snapshots at drops, `ocm log report` (session end timeline, auto-reconnect statistics); proactive soft reconnect on "process running but no connectivity"
- ✨ **New**: ⚙️ settings menu and `/etc/oc-master/settings.conf`, with a description and options for every parameter; a summary is shown before starting, and changes can apply to this run only
- ✨ **New**: command-line interface `ocm -h` (start / stop / restart / status / log / heal / config / accounts)
- ✨ **New**: data channel selection (`--no-dtls`), MTU, reconnect-on-outage duration, extra arguments, kill switch, fast DNS retry, connect at boot
- ✨ **New**: column 6 of an account can specify the protocol; GlobalProtect / Fortinet / Array added as protocol options
- 🔧 **Fix**: after openconnect was force-killed, the netns default route and resolv.conf were not restored, so reconnecting failed — the network baseline is now restored before reconnecting
- 🔧 **Change**: netns mode no longer turns on host-wide IPv6 forwarding by default; the VPN password is no longer `export`ed into child process environments; the account list and status area no longer show plain-text passwords; the main menu status area no longer makes network requests and opens instantly
- 🔧 **Change**: the old cron daemon task is replaced by systemd auto-reconnect (old entries only print a notice when they run and take no action)
- 📝 **Research references**: openconnect source (exit codes and server termination reasons), wazum/openconnect-proxy (foreground run + retry loop), telekom-mms/oc-daemon, f3flight/openconnect-ns (systemd management)

### v7.7.7 (2025-10-25) - Final

- ✨ **New**: Active IPv6 connectivity test feature for Netns mode
- 🔧 **Fix**: Enhanced IPv6 detection in show_status, improved detection success rate
- 🔧 **Optimization**: Simplified ocproxy mode, removed remote connection option, listen on localhost by default
- ✨ **Enhancement**: socat forwarding supports IPv4 and IPv6 dual-stack listening
- 📝 **Documentation**: Improved usage documentation and troubleshooting guide

**Follow-up fixes (still v7.7.7)**

- 🔧 **Fix**: Netns mode intermittently reported a startup failure right after "TUN is ready" — under `set -o pipefail`, `grep -q` exits early and `ip` gets SIGPIPE, so a successful match was treated as a failure (measured non-zero rate ~17%)
- ✨ **New**: Netns mode gained an **iptables double NAT** port-forwarding backend (DNAT into the netns + SNAT rewriting the source to the veth address). With DNAT alone, all four access paths failed (gost's reply source is not on the directly connected veth subnet, so replies cannot leave the netns); it is now a separate entry in menu 4 (IPv4 entry only), and `OCM_FORWARDER=iptables` can also override it once
- 🔧 **Improved**: port forwarding is now a pluggable backend module (`_fwd_setup_<name>` / `_fwd_teardown_<name>`; the main flow only calls `_fwd_avail` / `_fwd_setup` / `_fwd_teardown`), so adding a forwarding scheme later only touches the module area, not the main flow
- 🔧 **Fix**: now that the forwarding backends are separate menu items, choosing socat in menu 3 when socat cannot be installed explicitly refuses to start (it no longer silently switches to another backend); use menu 4 for kernel forwarding
- 🔧 **Fix**: with a `0.0.0.0` bind, access from the host itself via its LAN IP failed — locally generated traffic does not pass through PREROUTING, so the OUTPUT chain now allows it too
- 🔧 **Fix**: uninstalling gost called `--remove`, which the official script does not have at all; it actually popped up the "choose version" install menu and aborted the uninstall; it now deletes the binary directly
- 🔧 **Fix**: deleting a VPN account changed the account file permissions from 600 to 644
- 🔧 **Fix**: when stopping Netns mode, openconnect took a long time to exit (its logout path was torn down too early, and the leftover process would fight the next connection)
- 🔧 **Fix**: a failed start did not cancel the failsafe rollback job, which 2 minutes later would wrongly kill the connection the user had re-established
- ✨ **New**: menu 8 now first scans dependency status and marks "installed by this script / installed by you"; on uninstall it warns about the latter and keeps them by default, to avoid removing packages that have other uses
- 🔧 **Fix**: `cleanup_netns` did not clean up `/etc/netns/<name>/`, so every Netns mode run left a directory on the system (still present after uninstalling the script)
- 🔧 **Fix**: a wrong key or a bare Enter at the main menu quit the whole program — the trailing `[[ ]] && read` in `main_menu` returns 1, and "the last statement of a function returning non-zero" is treated by `set -e` as an error that ends the script; it now explicitly does `return 0` and exits cleanly when standard input ends (otherwise it would spin redrawing the menu)
- 🔧 **Fix**: the account / scheduled-task submenus reused the main menu's option variable (not `local`), so after returning, the "press any key needed?" check used the submenu's choice — showing up as a spurious extra "press any key to return to the main menu" after choosing 5/6, which also swallowed the next input
- 🔧 **Fix**: `stop` aborted halfway when the state file existed but lacked the `MODE=`/`VPS4=`/`VPS6=` keys (the assignment is the last command of `[ -f ] && …`, and `grep` returning 1 makes `set -e` end the whole stop flow: process not killed, temp files not deleted, failsafe job not cancelled)
- 🔧 **Fix**: account deletion now removes exactly one row by "index in the filtered list". Previously `grep -vF … && mv`, when deleting the last entry, had `grep` produce no output and return 1, so `mv` did not run — the file was left untouched yet "deleted" was still printed, and a `.tmp` was left behind; two accounts with identical content would also be deleted together
- 🔧 **Fix**: when stopping Netns, a failing `eval iptables -D` in the iptables cleanup branch (rule already removed externally) was interrupted by `set -e`, ending the whole stop flow so processes and the netns were no longer cleaned up
- 🔧 **Fix**: after a failed start, `stop_vpn` exited early due to "no pid file", leaving the state file and the configured policy routes (ip rule) behind; machines with the daemon task installed would retry the failed account every 5 minutes
- 🔧 **Fix**: the ocproxy mode daemon reconnect was completely unusable under cron — the first step of the reconnect logic is an interactive port prompt, and without a terminal `read` hits EOF immediately and is terminated by `set -e`. The daemon reconnect now reuses the port saved in the state file; removed the dead link to the deleted docs/FAQ.md
- ✨ **New**: Netns mode is split into two start entries by forwarding backend — `3) Netns Mode (socat forwarding)` and `4) Netns Mode (iptables double NAT)` — chosen directly, without first switching a "preference". If socat is chosen but cannot be installed, startup is explicitly refused rather than silently downgraded; the `OCM_FORWARDER` environment variable can still override once, for scripted calls
- ✨ **New**: Netns mode supports an optional **SOCKS5 username/password**. It is asked at startup (leave empty for anonymous), and gost is started as `socks5://user:pass@host:port`; the username/password reject `/`, quotes, backslash and whitespace (these break gost's URL parsing; `@` and `:` were measured to work and are now allowed); the state file is written with `%q` escaping and tightened to 600; the main menu shows the listening address and auth info on the SOCKS line
- ✨ **New**: the daemon task (menu 7, option 1) no longer "does nothing" for Netns mode. Previously on a drop it only printed "auto-reconnect not supported yet" and skipped, yet after the tunnel went down the interfaces and state remained, and gost fell back to the host egress — the main menu showed "running" while nothing went through the VPN. Now when unavailability is definitely detected (same criterion as the startup check: the actual egress inside the netns already equals the host egress) it stops and cleans up, so the status honestly becomes "stopped" and the user reconnects manually; it still does not auto-reconnect
- 🔧 **Fix**: **Netns mode occasionally "connected but not going through the VPN"** (gost actually egressed with the host's public IP). The criterion is now "the actual egress seen inside the netns ≠ the host egress", waiting up to ~50 seconds; if it never holds, startup is judged failed and rolled back (stop + cancel the failsafe job). Two insufficiently reliable criteria were ruled out along the way: ① `ping works` — when the netns has not taken over the default route, ping still works via veth→host→NAT; measured: a netns with no VPN connected pinged fine and its egress was exactly the host IP; ② `default route points at tun` — openconnect first creates tun0 and configures routes, and only then completes tunnel negotiation, and a connection interrupted midway deletes tun0 again; measured: this criterion held ("waited 0 seconds" passed) while the netns had already fallen back to the veth
- 🔧 **Fix**: **the iptables double NAT backend did not forward at all on some machines**. After OUTPUT DNAT, locally generated traffic still has source address `127.0.0.1`; netfilter then re-routes it (`ip_route_me_harder`), and the kernel uses `route_localnet` to decide whether `127.0.0.0/8` may leave through that interface — the default `0` means no, so the packet is dropped as a martian and never even reaches POSTROUTING (measured: the DNAT counter kept rising, the SNAT counter stayed at 0, nothing was captured on the veth). It "worked" on the test machine before only because that machine had the global `all=1` (the kernel uses `IN_DEV_ORCONF`, ORing `all` with the interface value) — an environmental coincidence. Startup now sets `route_localnet` to 1 on `veth_ocm_h`, opening only the interface the script itself created, without touching the global `all`
- 🔧 **Fix**: in `_fwd_setup_iptables`, `dst` and `socks_port` were declared in the same `local` statement, so the port got no value (it only worked by luck because bash's dynamic scoping picked up the caller's variable of the same name); split into two `local` statements

### v7.7.6 (2025-01-10)

- 🔧 **Fix**: Adopted the correct architecture of "service built in (gost in netns), port attached outside (socat/DNAT)"
- ✨ **New**: Prefer socat for port forwarding, with iptables DNAT as a fallback
- 🔧 **Enhancement**: Added checks for the tun interface and internal network connectivity

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
- Test all three modes (at least netns), and run `bash -n` and shellcheck once

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details

## 🙏 Acknowledgments

- [OpenConnect](https://www.infradead.org/openconnect/)
- [GOST](https://github.com/go-gost/gost)
- [ocproxy](https://github.com/cernekee/ocproxy)
- Design references: [openconnect-proxy](https://github.com/wazum/openconnect-proxy), [oc-daemon](https://github.com/telekom-mms/oc-daemon), [openconnect-ns](https://github.com/f3flight/openconnect-ns)
- All users who use and provide feedback

---

<div align="center">

**If this project helps you, please give it a ⭐ Star!**

Made with ❤️ by [duya07](https://github.com/duya07)

</div>
