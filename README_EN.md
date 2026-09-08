# OpenConnect Master Manager

English | [简体中文](README.md)

An OpenConnect egress manager for Linux VPS hosts. v8 prioritizes one invariant: **existing SSH, sing-box, and other inbound connections must continue to return through the VPS's original gateway; only explicitly selected outbound traffic enters the VPN**.

> The v8 English launcher uses the same audited implementation as the Chinese launcher to prevent networking behavior from drifting. Interactive prompts are currently Chinese; command names and configuration fields are language-neutral.

## Recommended architecture

| Mode | Host default route | Firewall/sysctl changes | Egress capability | Recommendation |
|---|---:|---:|---|---:|
| Local SOCKS5 | Unchanged | None | TCP, IPv4 | **Recommended** |
| Host-global VPN | Changed | None | Depends on VPN gateway | Advanced |

For sing-box, the safest design is normally not to put the whole VPS behind the VPN. OpenConnect exposes a SOCKS5 listener on `127.0.0.1`; sing-box then selects either all TCP connections or one inbound tag for that outbound. VPN routing therefore cannot capture the server's inbound return path.

v8 removes the old Netns mode. It combined network namespaces, iptables, global forwarding sysctls, gost/socat, and incomplete reconnection logic. That failure surface did not fit the minimum-impact goal.

## What v8 fixes

- systemd supervises foreground OpenConnect instead of a PID-file-only five-minute cron check.
- `--reconnect-timeout=86400` lets OpenConnect recover from extended link interruptions.
- A 30-second TCP keepalive is enabled when supported, reducing the chance that NAT or firewalls discard an otherwise idle control TLS connection while ESP/DTLS carries data.
- A real HTTP data-plane check runs every 30 seconds. Three consecutive failures are required before restart, with a 15-minute authentication cooldown to reduce account-lockout risk.
- SOCKS startup succeeds only when the listener and a request through the VPN both work.
- Global mode protects the original VPS source addresses with dedicated policy tables and does not edit `/etc/iproute2/rt_tables`.
- A separate three-minute systemd rollback is armed before global mode. A newly established external connection must be verified before entering `KEEP`.
- Global startup scans common cron/systemd DDNS jobs and requires an extra acknowledgement when one is detected, reducing the risk of publishing the VPN egress as the VPS address.
- Cleanup is idempotent and still runs when OpenConnect has already exited.
- Manager mutations are serialized. A failure anywhere in the systemd start chain triggers immediate stop, disable, and cleanup.
- Account listings never print passwords. The `0600` account file is explicitly documented as **plaintext**, not encrypted storage.
- The VPN protocol is persisted with the account/profile and never silently falls back during unattended recovery.

See the [evidence-led review](docs/REVIEW.md) for the v7 defects, causal boundaries, rejected hypotheses, and live verification results.

## Requirements

- A Linux VPS running systemd
- root access
- `openconnect`, `curl`, `iproute2`, and `util-linux` (`flock`)
- `ocproxy` for SOCKS mode

The script can install missing packages with apt, dnf, or yum only after it shows the scope and receives confirmation.

## Install and run

Download, inspect, then run the repository copy:

```bash
git clone https://github.com/duya07/openconnect-master.git
cd openconnect-master
chmod +x oc_master.sh
sudo ./oc_master.sh install
sudo ocm
```

`install` only installs or updates the managed executable and shortcut. It does not start the VPN, install packages, or create systemd units:

```text
/usr/local/sbin/oc-master
/usr/local/bin/ocm -> /usr/local/sbin/oc-master
```

If another program already owns `/usr/local/bin/ocm`, the script fails closed instead of overwriting it. Starting a connection also installs the same managed copy and shortcut, then creates:

```text
/etc/systemd/system/oc-master.service
/etc/systemd/system/oc-master-health.service
/etc/systemd/system/oc-master-health.timer
/etc/oc-master/profile.conf
```

Stop, clean project-owned routing state, and disable autostart:

```bash
sudo ocm stop
```

Other command entry points:

```bash
sudo ocm status
sudo ocm check
sudo ocm logs
```

`start-proxy` and `start-global` remain interactive so an incorrect credential is not retried accidentally.

## Account file

v8 keeps the legacy path `/root/.vpn_accounts.env`:

```text
display name|username|password|VPN URL|auth group (optional)|protocol(anyconnect/nc/pulse)
```

Example:

```text
University VPN|student001|password|https://vpn.example.edu|Students|nc
```

Fields cannot contain `|`, and passwords cannot contain a newline. Legacy five-field records are readable, but the operator must explicitly choose a protocol at each interactive start.

A vendor-branded login page does not prove a protocol. A gateway redirecting to a Juniper/Pulse `/dana-na/` page may still require the older compatible `nc` protocol rather than `pulse`; test explicitly instead of guessing.

## sing-box integration

Start the local SOCKS service first, for example at `127.0.0.1:1080`, then add this outbound to sing-box:

```json
{
  "type": "socks",
  "tag": "openconnect-out",
  "server": "127.0.0.1",
  "server_port": 1080,
  "version": "5",
  "network": "tcp"
}
```

To route one inbound tag through the VPN, add this to `route.rules`:

```json
{
  "inbound": ["vpn-only-in"],
  "network": ["tcp"],
  "action": "route",
  "outbound": "openconnect-out"
}
```

See [sing-box-selected-inbound.json](examples/sing-box-selected-inbound.json) for a complete merge fragment.

To route all sing-box TCP traffic through the VPN, set:

```json
{
  "final": "openconnect-out"
}
```

See [sing-box-all-tcp.json](examples/sing-box-all-tcp.json). ocproxy is TCP/IPv4 only, so keep an explicit direct/block rule for UDP. UDP/QUIC is not claimed to be tunneled by this mode.

Validate before restarting production:

```bash
sing-box check -c /etc/sing-box/config.json -C /etc/sing-box/conf
systemctl restart sing-box
```

Adjust paths for your installation.

## Global-mode safety confirmation

Global mode has a materially larger blast radius than SOCKS mode:

1. Copy the original default route into dedicated return tables for the VPS source addresses.
2. Scan common cron/systemd DDNS jobs; if one is detected, address the risk and enter `GLOBAL-DDNS-RISK`.
3. Arm an independent three-minute rollback.
4. Start the fixed `ocm0` interface and verify the real HTTP data plane.
5. Establish a new SSH or proxy connection from outside the VPS.
6. Enter `KEEP` only after that new connection succeeds; timeout or disconnect stops and disables the service.

Use it for the first time only when the hosting console is available. Multi-interface, multi-public-address, third-party policy-routing, and concurrent-VPN configurations are not declared supported. A policy-table collision or foreign OpenConnect process causes a fail-closed error.

Return-policy routing protects connections that already use the VPS's original source address; it cannot stop ordinary outbound programs from observing the VPN's public address. A typical DDNS updater may therefore publish the VPN egress and break port forwards or relays. Prefer SOCKS mode. Before using global mode, pause DDNS or bind both its public-IP lookup and API request to the original interface/source address. oc-master detects and warns, but never disables third-party jobs itself.

## Diagnostics

```bash
sudo ocm status
sudo ocm check
sudo ocm logs
systemctl status oc-master.service oc-master-health.timer
```

A healthy result requires all of the following: a supervised OpenConnect process, the expected SOCKS listener or `ocm0` route, a successful HTTP request, and the expected egress address. A PID or listening socket alone is not proof.

## Migration

Stop v7 with the old script and inventory any remaining namespace, iptables, sysctl, and policy-routing state before installing v8. v8 intentionally refuses to delete objects it cannot prove it owns. See [MIGRATION-v8.md](docs/MIGRATION-v8.md).

## Referenced projects

- [OpenConnect](https://gitlab.com/openconnect/openconnect)
- [ocproxy](https://github.com/cernekee/ocproxy)
- [wazum/openconnect-proxy](https://github.com/wazum/openconnect-proxy)
- [vpn-slice](https://github.com/dlenski/vpn-slice)
- [vopono](https://github.com/jamesmcm/vopono)
- [sing-box](https://github.com/SagerNet/sing-box)

## License

[MIT](LICENSE)
