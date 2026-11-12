# 🚀 OpenConnect Master Manager

<div align="center">

**[English](README_EN.md) | 简体中文**

![Version](https://img.shields.io/badge/version-8.1.1-blue?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)
![Platform](https://img.shields.io/badge/platform-Linux%20%2B%20systemd-lightgrey?style=flat-square)
![Shell](https://img.shields.io/badge/shell-bash-89e051?style=flat-square)

**一站式 OpenConnect VPN 管理工具**

三种运行模式 | systemd 托管 + 断线自动重连 | 内置诊断日志 | 设置菜单 + 命令行

[快速开始](#-快速开始) • [功能特性](#-功能特性) • [使用文档](#-使用文档) • [从旧版升级](#upgrade)

</div>

---

## ✨ 功能特性

### 🎯 三种运行模式

| 模式 | 图标 | 说明 | IPv4 | IPv6 | 适用场景 |
|------|------|------|------|------|----------|
| **默认模式** | 🛡️ | 全局 VPN + SSH 保护 | ✅ | ✅ | 需要整机走 VPN |
| **ocproxy 模式** | 🔌 | 用户态 SOCKS5（不建 tun） | ✅ | ❌ | 轻量级代理需求 |
| **Netns 模式** | 🌐 | Network Namespace 隔离 + SOCKS5 | ✅ | ✅ | **推荐**！只让需要的程序走 VPN，宿主完全不受影响 |

### 🔥 核心功能

- ✅ **systemd 托管，断线自动重连**（v8 新增）
  - openconnect 前台运行在 `ocm.service` 里，关掉 SSH 也不会连带断开
  - 退出后按原因处理：服务器到期终止 → 约 2 秒后重连；网络错误 → 按退避间隔重试；认证失败 → 计数，达到阈值即暂停，**防止账号被锁**
  - 重连期间 netns 与代理保持不动，客户端只感到几秒中断
  - 「进程还在但不通」也能发现：持续不通超过阈值会主动软重连

- ✅ **内置长期诊断日志**（v8 新增，`ocm-watch.service`）
  - 定时采样隧道 / 代理 / 网关 / 出口 IP，记录每次状态变化与断线现场快照
  - `ocm log report` 一条命令看断线次数、**每次断开时会话已持续多久**、自动重连记录
  - 适合排查「隔一阵就断」这类问题（例如很多学校 / 企业 VPN 有固定会话时长）

- ✅ **⚙️ 设置菜单 + 命令行**（v8 新增）
  - 每个可调参数都在菜单里列出：当前值、作用、可选项与代价，不用读源码猜默认值
  - 启动前显示设置摘要：直接启动 / 改设置并保存 / 只改本次
  - `ocm -h`：`start / stop / restart / status / log / heal / config / accounts / proxy`，可脚本化

- ✅ **智能策略路由**（默认模式）
  - 自动保护 SSH 连接不受全局 VPN 影响，支持 IPv4 和 IPv6
  - 首次启动带 3 分钟保底自动回滚

- ✅ **Network Namespace 隔离**（Netns 模式）
  - 完全独立的网络环境，通过 SOCKS5 代理访问（可选用户名/密码）
  - 两种端口转发后端：socat（IPv4+IPv6 入口）/ iptables 双 NAT（仅 IPv4 入口）
  - 可选**断线保护**：VPN 不通时代理直接失败，流量绝不从 VPS 自己的出口出去
  - 或者**回落代理**（v8.1 新增）：VPN 不通时新连接自动改走你指定的备用代理（socks5 / http / https / ss 等），VPN 恢复后自动切回，回落期间的连接不断

- ✅ **多账户管理**
  - 账户信息以**明文**保存在 `/root/.vpn_accounts.env`（权限收紧为 `600`，仅 root 可读；请自行按需保护）
  - 每个账户可以指定自己的协议；列表与状态区不显示密码

- ✅ **安全清理机制**
  - 停止时先让 openconnect 正常登出，再拆代理 / netns / 路由
  - 只还原被本脚本打开过的内核转发开关；卸载时区分「本脚本装的依赖」与「本来就有的依赖」

## 📦 系统要求

- **操作系统**: Debian/Ubuntu/CentOS/RHEL 等使用 **systemd** 的 Linux 发行版（**目前只在 Debian 12 上做过完整测试**，其他发行版请先自行验证）
- **权限**: 需要 root 权限
- **网络**: 需要能访问外网
- **依赖**: 脚本会自动检测并安装必要依赖

### 自动安装的依赖

- `openconnect` - OpenConnect VPN 客户端
- `ocproxy` - ocproxy 模式所需
- `gost` - Netns 模式的 SOCKS5 服务器
- `socat` - Netns 模式的端口转发（**首选**）
- `iptables` - 端口转发兜底方案（双 NAT）、netns 出口 NAT、断线保护
- `iproute2` - 网络配置工具
- `at` - 默认模式首次启动的 3 分钟保底回滚
- `curl` - 查询公网 IP、下载 gost 安装脚本

## 🚀 快速开始

### 方法一：一键下载运行

```bash
wget -O /root/oc_master.sh https://raw.githubusercontent.com/duya07/openconnect-master/main/oc_master.sh
chmod +x /root/oc_master.sh
/root/oc_master.sh
```

> v8 由 systemd 托管，**脚本需要放在固定位置**（例如 `/root/oc_master.sh`）——systemd 单元会记住这个路径。
> 不要用 `bash <(curl …)` 直接运行。

### 方法二：克隆仓库

```bash
git clone https://github.com/duya07/openconnect-master.git
cd openconnect-master
chmod +x oc_master.sh
./oc_master.sh
```

首次运行会自动创建快捷命令 `ocm`，之后直接输入 `ocm` 即可。

## 📖 使用文档

### 首次运行（三步）

1. `6) 管理 VPN 账户` → 添加账户：显示名、用户名、密码、VPN 服务器地址、认证组（可选）、协议（可选）
2. `5) 设置` → 至少确认 **运行模式**、**VPN 协议**（必须与网关一致）、**SOCKS5 端口**
3. `1) 启动 VPN` → 检查摘要，回车启动

命令行等价写法：

```bash
ocm config set PROTOCOL nc          # 协议：anyconnect / pulse / nc / gp / fortinet / array
ocm config set MODE netns
ocm config set SOCKS_PORT 8585
ocm start
```

启动成功后会显示 SOCKS5 地址与 VPN 出口 IP。在自己电脑上使用（监听仅本机时）：

```bash
ssh -N -L 8585:127.0.0.1:8585 root@你的VPS
# 然后把浏览器 / 应用的代理设为 SOCKS5 127.0.0.1:8585
```

### ⚙️ 设置项一览

设置保存在 `/etc/oc-master/settings.conf`（`600`）。菜单 `5) 设置` 里每一项都有详细说明；也可用 `ocm config list -v` 查看。

| 分组 | 项（KEY） | 可选值 | 说明 |
|---|---|---|---|
| 连接 | 运行模式 `MODE` | `netns` / `default` / `ocproxy` | 见上方模式表 |
| 连接 | VPN 协议 `PROTOCOL` | `anyconnect` `pulse` `nc` `gp` `fortinet` `array` | 必须与网关一致；账户第 6 列可单独覆盖 |
| 连接 | 数据通道 `DATA_CHANNEL` | `dtls` / `tls` | `dtls`：约 1 分钟后数据改走 UDP，快但丢包网络更不稳；`tls`：全程 TLS/TCP（`--no-dtls`），丢包网络里通常更稳 |
| 连接 | 断网续连时长 `RECONNECT_TIMEOUT` | 60 / 300 / 900 秒 | 网络闪断时 openconnect 自己续连多久；对服务器主动终止无效 |
| 连接 | 隧道 MTU `MTU` | `auto` / 1400 / 1300 / … | 大文件或个别站点卡住时调小 |
| 连接 | 附加参数 `OC_EXTRA` | 自由文本 | 原样追加给 openconnect，例如 `--useragent=…` |
| 代理 | SOCKS5 端口 `SOCKS_PORT` | 数字 | netns / ocproxy 模式 |
| 代理 | 监听范围 `LISTEN` | `127.0.0.1` / `0.0.0.0` | 对外开放时务必设置认证 |
| 代理 | SOCKS5 认证 `SOCKS_USER`/`SOCKS_PASS` | — | 仅 netns 模式 |
| 代理 | 端口转发方式 `FORWARDER` | `socat` / `iptables` | socat 有 IPv4+IPv6 入口；iptables 仅 IPv4 入口 |
| 安全 | 断线保护 `KILL_SWITCH` | `off` / `on` / `proxy` | `on`：VPN 不通时代理直接失败，绝不改走 VPS 出口；`proxy`：改走[回落代理](#fallback-proxy)，都不通则同 `on`（仅 netns） |
| 安全 | 回落代理选择 `FALLBACK_PROXY` | `auto` / 显示名 | `auto`：按列表顺序用第一个能连上的；显示名：只用它 |
| 网络 | DNS 超时策略 `DNS_FAST` | `off` / `on` | `on`：VPN 内 DNS 丢包后 1 秒重试并轮换服务器，减少「卡 5 秒」（仅 netns） |
| 网络 | 宿主 IPv6 转发 `IPV6_FORWARD` | `off` / `on` | 只有需要经代理走 IPv6 时才开 |
| 守护 | 自动重连 `AUTO_RECONNECT` | `on` / `off` | 关闭后掉线即停止并清理 |
| 守护 | 重连退避 `BACKOFF` | 例如 `5 30 60 120 300 600 900` | 网络类失败的重试间隔序列 |
| 守护 | 每小时最多重连 `MAX_PER_HOUR` | 数字 | 防止异常时疯狂重试 |
| 守护 | 认证失败暂停阈值 `AUTH_FAIL_PAUSE` | 数字 | 连续认证失败达到此数即暂停（首次启动就失败会立即停止） |
| 守护 | 软重连等待 `DEGRADED_WAIT` | 30 / 60 / 90 / 180 秒 | 进程在但代理持续不通多久后主动重连 |
| 守护 | 开机自动连接 `AUTOSTART` | `off` / `on` | 启用 `ocm.service` 开机自启 |
| 日志 | 诊断日志 `WATCH` | `on` / `off` | `ocm-watch.service` |
| 日志 | 采样间隔 `SAMPLE_INTERVAL` | 15 / 30 / 60 秒 | 状态变化后自动加密到 5 秒，持续 3 分钟 |
| 日志 | 日志总量上限 `LOG_MAX_MB` | 100 / 300 / 1000 | 超出时删最旧的轮转文件 |
| 日志 | 额外探测 URL `EXTRA_PROBE_URL` | URL | 例如校内资源入口，确认其可达 |

### ⌨️ 命令行

```text
ocm                      打开交互菜单
ocm start [选项]         按保存的设置启动；选项只影响本次，加 --save 保存为默认
    -a/--account N|名称  -m/--mode netns|default|ocproxy  -p/--proto nc|pulse|anyconnect|…
    -P/--port N  --listen 127.0.0.1|0.0.0.0  --tls-only|--dtls  --fwd socat|iptables
    --kill-switch on|off|proxy  --fallback 名称|auto  --dns fast|system  --mtu N|auto  --oc-args "…"  --save  -i
ocm stop | restart [选项] | status [-v]
ocm log report [天数] | log tail | log snapshot [标签] | log mark <文字>
ocm heal on|off|status
ocm config list [-v] | get KEY | set KEY VALUE
ocm accounts
ocm proxy list | add ['一行'] | del 序号|名称 | test [序号|名称] | format
ocm install-service | uninstall-service
ocm -V | -h
```

退出码：`0` 成功、`1` 失败、`2` 用法错误、`3` 已在运行 / 状态冲突。

### 🔁 自动重连是怎么工作的

`ocm start` 把会话交给 `ocm.service`（supervisor）。openconnect 每次退出，supervisor 根据退出码和输出判断原因：

| 判定 | 依据 | 处理 |
|---|---|---|
| `server-terminated` | 输出含 `Server terminated connection` / `Session terminated by server` | 约 2 秒后重连（不走退避） |
| `watch-request` | 诊断服务发现「进程在但不通」并请求软重连 | 约 2 秒后重连 |
| `auth` | 退出码 2（cookie/认证被拒）或登录失败字样 | 计数；首次启动即失败或连续达到阈值 → 暂停 |
| `session-confirm` | 服务器要求确认已有会话等交互页面 | 按退避重试 |
| `network` | 其他（DNS、TCP、TLS 失败，进程崩溃等） | 按 `BACKOFF` 退避重试，受 `MAX_PER_HOUR` 限制 |

> openconnect 收到服务器的终止通知（例如会话到期）时会**直接退出**，`--reconnect-timeout` 管不到这种情况——这正是需要外部重连的原因。
> 重连前 supervisor 会把 netns 的默认路由和 resolv.conf 恢复到基线，即使 openconnect 是被强杀、没来得及清理也能连回来。

### 📊 诊断日志与报告

日志目录 `/var/log/oc-master/`：

| 文件 | 内容 |
|---|---|
| `events.log` | 只记变化：状态迁移、supervisor 事件（启动/退出原因/重连）、openconnect 关键句、人工标记 |
| `samples.log` | 定时采样：进程、tun、默认路由、SOCKS 探针、隧道内 ping、网关 TCP/ping、出口 IP、TCP 重传… |
| `openconnect.log` | openconnect 全部输出（已脱敏） |
| `incidents/` | 每次离开正常状态时的现场快照（路由、NAT、进程、内核消息…） |
| `launch/` | 每次 `ocm start` 的完整启动输出 |

全部按大小轮转并 gzip，总量受 `LOG_MAX_MB` 限制，磁盘余量低于 400MB 时暂停写采样。

```bash
ocm log report 7
```

报告示例（节选）：

```text
会话结束时间轴（离开 UP 时距认证多久；≈2h = 1h55m–2h05m）：
  2026-01-01T19:34:13+0800  →DOWN      会话时长 2h00m      [≈2h!]   openconnect-gone(state-file-still-present)
  2026-01-01T21:34:47+0800  →DOWN      会话时长 2h00m      [≈2h!]   openconnect-gone(state-file-still-present)
  非人工结束 2 次，其中落在 ≈2h 区间 2 次

自动重连：openconnect 退出 2 次（server-terminated=2），重新就绪 2 次，软重连请求 0 次，暂停或限速 0 次
```

断开时刻都落在同一个会话时长上，就说明是服务器的固定会话时长，而不是网络问题。

### 账户配置文件格式

账户信息存储在 `/root/.vpn_accounts.env`：

```
显示名|用户名|密码|VPN主机|认证组(可选)|协议(可选)
```

示例：
```
示例网关A|user001|your_password|vpn.example.com|DefaultGroup
示例网关B|user002|your_password|vpn2.example.com||nc
```

任何字段都不能包含 `|`。也可以参考 [examples/vpn_accounts.example](examples/vpn_accounts.example)。

<a id="fallback-proxy"></a>

### 🛟 回落代理（断线保护的备用出口）

把「断线保护」设为 `proxy` 后，VPN 掉线 / 重连期间，SOCKS5 代理的**新连接**自动改走你指定的代理；VPN 一恢复，新连接马上切回 VPN。回落期间已经建立的连接不会因为切回而中断。
代理都连不上时与 `on` 相同：直接失败，**绝不**改走 VPS 自己的出口。仅 netns 模式。

```bash
ocm proxy add                     # 逐项提问添加（密码不回显）；也可在主菜单 11「管理回落代理」
ocm proxy test                    # 从本机经每个代理访问一次，显示出口 IP
ocm config set KILL_SWITCH proxy  # 然后 ocm restart 生效
```

代理列表在 `/etc/oc-master/proxies.conf`（`600`，含明文密码），每行一个，两种写法任选，文件头自带完整说明（`ocm proxy format` 随时查看，或参考 [examples/proxies.example](examples/proxies.example)）：

```text
# 写法一：竖线分列（推荐）。用户名、密码里有 @ : / % 等字符直接照写，不用转义
显示名|类型|地址|端口|用户名(可选)|密码(可选)
香港备用|socks5|203.0.113.20|1080|user|p@ss:word
日本SS|ss|203.0.113.30|8388|aes-256-gcm|ss-password

# 写法二：URL（第 2 列含 :// 即按 URL 读取；特殊字符按 URL 规则编码，@ → %40）
显示名|类型://用户名:密码@地址:端口[?参数]
TLS代理|https://bob:pa%40ss@proxy.example.com:443
WS代理|socks5+wss://carol:pw@proxy.example.com:443?path=/ws
```

| 类型 | 说明 |
|---|---|
| `socks5` | SOCKS5；`s5` / `s5h` / `socks5h` / `socks` 都按它处理。目标域名一律交给上游代理解析（即 s5h 的效果） |
| `socks4` / `socks4a` | SOCKS4 / 4a |
| `http` | HTTP 代理（CONNECT） |
| `https` | 走 TLS 的 HTTP 代理（`http+tls`） |
| `ss` | Shadowsocks：用户名列填加密方式（如 `aes-256-gcm`），密码列填密码 |
| `socks5+tls` / `socks5+ws` / `socks5+wss` | 套 TLS / WebSocket 的 SOCKS5（路径用 URL 写法 `?path=/ws`） |

- vmess / vless / trojan / hysteria 不支持：先在本机用对应客户端开一个 socks5 端口，再把它填进来。
- 地址填域名或 IPv4（暂不支持 IPv6 地址）。代理就在本机时写 `127.0.0.1`，脚本会换成 netns 看到的宿主地址 `192.168.200.1`，所以那个代理要监听 `0.0.0.0` 或 `192.168.200.1`。
- 选择方式：`FALLBACK_PROXY=auto`（默认）每次掉线时按列表顺序检测，用第一个能连上的；正在用的代理断了会自动换下一个。也可以固定为某个显示名。
- 改列表不用重启，下次掉线即按新内容生效；改 `KILL_SWITCH` / `FALLBACK_PROXY` 需要 `ocm restart`。
- 实测范围：socks5、http、ss 已端到端实测（含长连接跨越 VPN 恢复不断）；https、socks5+tls/ws/wss 已验证 gost 能正确解析，未实连。

<details>
<summary>实现方式</summary>

netns 里常驻第二个 gost（只监听 veth 地址，链路指向选中的代理，配置来自权限 600 的临时 YAML，启动后即删除，代理密码不出现在常驻进程的参数里）。VPN 不通时，在 netns 的 `nat PREROUTING` 加一条 `REDIRECT`，把从宿主转发进来的新连接改送到它；VPN 恢复后删掉这条规则。已建立的连接由 conntrack 保持原去向；为此会给代理 IP 加一条经 veth 的 `/32` 路由，并在 netns 里常驻一条 conntrack 规则（否则删掉 REDIRECT 时内核会撤销该 netns 的连接跟踪，回落期间的连接会被重置）。

</details>

### 定时任务

菜单 `7) 定时启动 / 关闭`：按 cron 表达式添加 `ocm start` 或 `ocm stop`。
断线重连已由 systemd supervisor 负责，**不再需要旧版的 cron 守护任务**。

### 停止 VPN

```bash
ocm stop            # 或菜单 3
```

### 卸载

菜单 `10) 🗑️ 卸载`：停止 VPN 并清理 → 移除 systemd 单元 → 询问是否删除设置与诊断日志 → 清理本脚本的 crontab 条目（先备份到 `/root/.oc_master-crontab.bak`）→ 逐个询问是否删除依赖 → 删除账户文件、快捷命令与脚本自身。

> ⚠️ 账户文件（含明文密码）与脚本本体会被删除，需要保留请先自行备份。

### IPv6 连通性测试

Netns 模式运行中可选菜单 `9) 🧪 测试 Netns IPv6 连通性`：检查全局 IPv6 地址、ping Google IPv6 DNS、HTTP IPv6 访问。

<a id="upgrade"></a>

## ⬆️ 从 v7 升级

1. 先用旧版停止 VPN（或升级后直接 `ocm stop`，v8 会清理旧版启动的会话）
2. 用新脚本覆盖原文件（快捷命令 `ocm` 指向的路径不变）
3. `ocm` → `5) 设置` 确认模式、协议、端口（v7 每次启动时询问的内容，现在保存在设置里）
4. 如果配置过旧版守护任务（`_internal_check_health`），在菜单 `7` 选 `3` 清除；它已被 systemd 自动重连取代
5. `ocm start`

行为变化：netns 模式默认**不再**打开宿主 `net.ipv6.conf.all.forwarding`（需要时设置 `IPV6_FORWARD=on`）。

## 🔧 高级配置

### 文件位置

```bash
/etc/oc-master/settings.conf          # 设置（600）
/root/.vpn_accounts.env               # 账户（600，明文）
/etc/oc-master/proxies.conf           # 回落代理（600，明文）
/var/log/oc-master/                   # 诊断日志
/run/oc-master/                       # 运行时（阶段、本次生效设置）
/etc/systemd/system/ocm.service       # supervisor
/etc/systemd/system/ocm-watch.service # 诊断日志
/var/run/oc_manager.state             # 当前会话状态（v7 兼容格式）
/var/lib/oc-master/                   # 依赖标记、诊断服务状态
```

脚本内的网络常量（如需修改请直接编辑脚本顶部）：

```bash
NETNS_NAME="ocm_vpn_space"; VETH_HOST="veth_ocm_h"; VETH_NS="veth_ocm_ns"
VETH_HOST_IP="192.168.200.1"; VETH_NS_IP="192.168.200.2"
RT4_ID=100; RT6_ID=101          # 默认模式 SSH 保护路由表
OC_TUN_DEFAULT="ocmtun0"        # 默认模式的隧道网卡名
```

### 手动调试命令

```bash
ocm status -v                                   # 运行状态 + 最新采样
journalctl -u ocm -n 100                        # supervisor 输出
ocm log tail                                    # 实时事件 + openconnect 输出
ip netns exec ocm_vpn_space ip route            # netns 内路由
ip netns exec ocm_vpn_space curl https://api.ipify.org
ss -tlnp | grep socat                           # socat 后端在宿主上监听
ip netns exec ocm_vpn_space ss -lntp            # gost 在 netns 内监听
```

## 🐛 故障排除

1. **VPN 连接失败**
   - `ocm status -v` 看阶段；完整启动输出在 `/var/log/oc-master/launch/`
   - 阶段显示 `failed:auth`：账号或密码错误 / 被拒，确认后重新 `ocm start`（自动重连已暂停，防止账号被锁）
   - 协议是否与网关一致（设置 → VPN 协议）

2. **每隔固定时间就断一次**
   - `ocm log report 7` 看「会话结束时间轴」。断开时刻都落在同一会话时长上，通常是服务器的会话上限，客户端无法延长；自动重连会在几秒内接上

3. **SOCKS5 代理时好时坏**（Netns 模式）
   - 看报告里的「会话内短暂故障」与采样里的 `tping`（隧道内丢包）、`socks` 字段
   - 丢包网络可试 `DATA_CHANNEL=tls`；VPN 内 DNS 丢包导致的「卡 5 秒」可试 `DNS_FAST=on`

4. **回落代理没有生效**（`KILL_SWITCH=proxy`）
   - `ocm proxy test` 看每个代理能否连上、出口 IP 是什么；`ocm status` 显示「回落代理：待命 / 使用中」
   - `ocm log report 1` 里的 `SUP fallback …` 事件：`unavailable` 表示当时列表里没有能连上的代理
   - 本机代理只监听 `127.0.0.1` 时 netns 连不到它，改为监听 `0.0.0.0` 或 `192.168.200.1`

5. **SSH 连接中断**（默认模式）
   - 脚本会自动保护 SSH 连接；首次启动 3 分钟内若未确认成功会自动回滚

## 📊 版本历史

### v8.1.1 (2026-11-12)

- 🔒 **安全修复**：Netns 模式下 netns 里的 gost 原先监听全部网卡（`socks5://:端口`），其中包括 VPN 隧道网卡 tun0。tun0 的地址是 VPN 分配的公网地址，外部经 VPN 网关就能直连这个端口，在未开 SOCKS5 认证时等于一个**以你的 VPN 身份上网的开放代理**——「监听范围 = 仅本机」只限制了宿主上的转发入口。现在 gost 只监听 veth 地址 `192.168.200.2`，并在 netns 里额外拒绝从 `tun+` 进来的该端口（IPv4/IPv6）。**v8.1.0 及以前的 Netns 模式用户请尽快升级并重启 VPN**

### v8.1.0 (2026-11-12)

- ✨ **新增**：断线保护增加第三种选择「回落代理」（`KILL_SWITCH=proxy`）：VPN 不通时新连接改走指定代理，恢复后自动切回，回落期间的连接不断；代理都连不上则直接失败
- ✨ **新增**：回落代理列表 `/etc/oc-master/proxies.conf`，竖线分列与 URL 两种写法；支持 socks5（含 s5 / s5h 别名）、socks4/4a、http、https、ss、socks5+tls/ws/wss；主菜单 11 与 `ocm proxy list|add|del|test|format`
- ✨ **新增**：设置 `FALLBACK_PROXY`（auto 按顺序选第一个能连上的 / 固定某一个）；`ocm start --kill-switch proxy --fallback 名称`
- ✨ **新增**：诊断采样增加 `fb=` 字段，报告统计回落次数与累计时长，状态页显示回落代理是否在用

### v8.0.0 (2026-11-12)

- ✨ **新增**：systemd 托管（`ocm.service`）。openconnect 改为前台运行，退出后按原因自动重连（服务器终止 / 网络错误 / 认证失败分别处理），重连期间 netns 与代理保持不动；关闭 SSH 不再影响 VPN
- ✨ **新增**：内置长期诊断日志（`ocm-watch.service`）：采样、事件、断线现场快照、`ocm log report`（会话结束时间轴、自动重连统计）；「进程在但不通」时主动软重连
- ✨ **新增**：⚙️ 设置菜单与 `/etc/oc-master/settings.conf`，每个参数都有说明与可选项；启动前显示摘要，可只改本次
- ✨ **新增**：命令行接口 `ocm -h`（start / stop / restart / status / log / heal / config / accounts）
- ✨ **新增**：数据通道选择（`--no-dtls`）、MTU、断网续连时长、附加参数、断线保护（kill switch）、DNS 快速重试、开机自动连接
- ✨ **新增**：账户第 6 列可指定协议；协议新增 GlobalProtect / Fortinet / Array 选项
- 🔧 **修复**：openconnect 被强杀后 netns 默认路由与 resolv.conf 未还原导致无法重连——重连前恢复网络基线
- 🔧 **变更**：netns 模式默认不再打开宿主 IPv6 全局转发；VPN 密码不再 `export` 进子进程环境；账户列表与状态区不再显示明文密码；主菜单状态区不再发网络请求，秒开
- 🔧 **变更**：旧版 cron 守护任务由 systemd 自动重连取代（旧条目运行时只提示，不再动作）
- 📝 **调研参考**：openconnect 源码（退出码与服务器终止原因）、wazum/openconnect-proxy（前台运行 + 重试循环）、telekom-mms/oc-daemon、f3flight/openconnect-ns（systemd 托管）

### v7.7.7 (2025-10-25) - Final

- ✨ **新增**：Netns 模式的 IPv6 连通性主动测试功能
- 🔧 **修复**：增强 show_status 中的 IPv6 检测，提高检测成功率
- 🔧 **优化**：简化 ocproxy 模式，移除远程连接选项，默认监听本地
- ✨ **增强**：socat 转发支持 IPv4 和 IPv6 双栈监听
- 📝 **文档**：完善使用文档和故障排除指南

**后续修复（仍是 v7.7.7）**

- 🔧 **修复**：Netns 模式偶发"TUN 已就绪"后立刻报启动失败——`set -o pipefail` 下 `grep -q` 提前退出会让 `ip` 吃到 SIGPIPE，匹配成功却被判成失败（实测非 0 率约 17%）
- ✨ **新增**：Netns 模式新增 **iptables 双 NAT** 端口转发后端（DNAT 进 netns + SNAT 把源改成 veth 地址）。此前只有 DNAT 时四种访问方式全部不通（gost 的回包源不在 veth 直连段，出不了 netns）；它现在是菜单 4 的独立入口（只支持 IPv4 入口），也可用 `OCM_FORWARDER=iptables` 一次性覆盖
- 🔧 **优化**：端口转发改为可插拔后端模块（`_fwd_setup_<名>` / `_fwd_teardown_<名>`，主流程只调用 `_fwd_avail` / `_fwd_setup` / `_fwd_teardown`），以后新增转发方案只动模块区、不碰主流程
- 🔧 **修复**：转发后端拆成独立菜单项后，菜单 3 选了 socat 而 socat 装不上时会明确拒绝启动（不再静默换成别的后端）；想走内核转发请用菜单 4
- 🔧 **修复**：`0.0.0.0` 监听时本机经内网 IP 访问不通——本机产生的流量不经过 PREROUTING，改为 OUTPUT 链也放行
- 🔧 **修复**：卸载 gost 时调用了官方脚本根本不存在的 `--remove`，实际会弹出"选择版本"的安装菜单并中断卸载；改为直接删除二进制
- 🔧 **修复**：删除 VPN 账户后账户文件权限由 600 变成 644
- 🔧 **修复**：停止 Netns 模式时 openconnect 长时间不退出（登出路径被提前拆掉，残留进程会与下一次连接打架）
- 🔧 **修复**：启动失败后未撤销保底回滚任务，2 分钟后会误杀用户已重新建立的连接
- ✨ **新增**：菜单 8 改为先扫描依赖状态并标记"由本脚本安装 / 你自己装的"，卸载时对后者给出提醒并默认保留，避免误删还有别的用途的软件包
- 🔧 **修复**：`cleanup_netns` 未清理 `/etc/netns/<名字>/`，每跑一次 Netns 模式就在系统里留下一个目录（脚本卸载后依然存在）
- 🔧 **修复**：主菜单输错键或直接按回车会让整个程序退出——`main_menu` 末尾的 `[[ ]] && read` 返回 1，"函数最后一条语句返回非 0"被 `set -e` 当成错误结束脚本；现在显式 `return 0`，并在标准输入结束时干净退出（否则会空转刷菜单）
- 🔧 **修复**：账户/定时子菜单复用了主菜单的选项变量（未 `local`），返回后"是否需要按任意键"的判定用的是子菜单的选择值——表现为选完 5/6 后凭空多出一次"按任意键返回主菜单"，还会吃掉下一格输入
- 🔧 **修复**：`stop` 在状态文件存在但缺少 `MODE=`/`VPS4=`/`VPS6=` 键时中途终止（赋值是 `[ -f ] && …` 的最后一条命令，`grep` 返回 1 会让 `set -e` 结束整个停止流程：进程没杀、临时文件没删、保底任务也没撤）
- 🔧 **修复**：删除账户改为按"过滤后列表的序号"精确删一行。原先 `grep -vF … && mv` 在删最后一条时 `grep` 无输出、返回 1，`mv` 不执行——文件原样没动却照样打印"已删除"，还留下一个 `.tmp`；两条内容完全相同的账户也会被一起删掉
- 🔧 **修复**：停止 Netns 时 iptables 清理分支的 `eval iptables -D` 失败（规则已被外部清掉）会被 `set -e` 中断整个停止流程，进程与 netns 不再清理
- 🔧 **修复**：启动失败后 `stop_vpn` 因"无 pid 文件"早退，状态文件与已配置的策略路由（ip rule）残留；装了守护任务的机器会每 5 分钟拿失败账户重连一次
- 🔧 **修复**：ocproxy 模式的守护重连在 cron 环境下完全不可用——重连逻辑第一步是交互式端口输入，无终端时 `read` 立即 EOF 并被 `set -e` 终止。守护重连现复用状态文件里保存的端口；移除了指向已删除的 docs/FAQ.md 的失效链接
- ✨ **新增**：Netns 模式按转发后端拆成两个启动项——`3) Netns 模式 (socat 转发)` 与 `4) Netns 模式 (iptables 双 NAT)`，直接选，不再需要先切"偏好"。选 socat 时若 socat 装不上会明确拒绝启动，不会悄悄降级；`OCM_FORWARDER` 环境变量仍可一次性覆盖，供脚本化调用
- ✨ **新增**：Netns 模式支持可选 **SOCKS5 用户名/密码**。启动时询问（留空即匿名），gost 以 `socks5://user:pass@host:port` 启动；用户名/密码拒绝含 `/` 引号 反斜杠 空白（这些会破坏 gost 的 URL 解析；`@` 与 `:` 实测可用，已放开）；状态文件用 `%q` 转义写入并收紧为 600；主菜单会在 SOCKS 行显示监听地址与认证信息
- ✨ **新增**：守护任务（菜单 7 选项 1）对 Netns 模式不再"什么都不做"。此前掉线时只打印"尚不支持自动重连"就跳过，而隧道断掉后接口和 state 还在，gost 会回落走宿主出口——主菜单显示"运行中"却完全没走 VPN。现在明确探测到不可用（判据与启动检查同一套：netns 内的实际出口已等于本机出口）时就停止并清理，让状态如实变成"停止"，用户看到后自己重连；仍不自动重连
- 🔧 **修复**：**Netns 模式偶发"连着但没走 VPN"**（gost 实际以本机公网 IP 对外）。现在的判据是"netns 内查到的实际出口 ≠ 本机出口"，最多等约 50 秒，等不到就判定启动失败并回滚（停止 + 撤销保底任务）。排查中先后否掉了两个不够可靠的判据：① `ping 通`——netns 没接管默认路由时经 veth→宿主→NAT 照样能通，实测在未连 VPN 的 netns 里就 ping 得通且出口正是本机 IP；② `默认路由指向 tun`——openconnect 是先建 tun0、配路由，之后才完成隧道协商，中途连接中断还会把 tun0 删掉，实测该判据成立（"等待 0 秒"通过）但 netns 已回落成走 veth
- 🔧 **修复**：**iptables 双 NAT 后端在部分机器上完全不转发**。本机产生的流量经 OUTPUT DNAT 后源地址仍是 `127.0.0.1`，netfilter 会随后重新路由（`ip_route_me_harder`），内核按 `route_localnet` 判断 `127.0.0.0/8` 能否从这个接口出去——默认 `0` 表示不能，包被当 martian 丢弃，连 POSTROUTING 都到不了（实测：DNAT 计数一路涨、SNAT 计数恒为 0、veth 抓不到任何包）。此前在测试机上"能用"只是因为那台机器的全局 `all=1`（内核用 `IN_DEV_ORCONF`，`all` 与接口值取 OR），属于环境巧合。现在启动时会把 `veth_ocm_h` 的 `route_localnet` 置 1，只放开脚本自己建的这个接口，不碰全局 `all`
- 🔧 **修复**：`_fwd_setup_iptables` 里 `dst` 与 `socks_port` 写在同一条 `local` 语句上，导致端口取不到值（靠 bash 动态作用域偶然拿到调用方的同名变量才没出错），拆成两条 `local`

### v7.7.6 (2025-01-10)

- 🔧 **修复**：采用"服务内置(gost in netns), 端口外挂(socat/DNAT)"的正确架构
- ✨ **新增**：优先使用 socat 进行端口转发，并提供 iptables DNAT 备用
- 🔧 **增强**：增加对 tun 接口和内部网络连通性的检查

### v7.7.5 (Earlier)

- 初始版本发布
- 支持三种运行模式
- 实现策略路由保护
- Network Namespace 隔离

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

### 开发建议

- 保持代码风格一致
- 添加必要的注释
- 更新相关文档
- 测试所有三种模式（至少 netns），并跑一次 `bash -n` 与 shellcheck

## 📄 许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件

## 🙏 致谢

- [OpenConnect](https://www.infradead.org/openconnect/)
- [GOST](https://github.com/go-gost/gost)
- [ocproxy](https://github.com/cernekee/ocproxy)
- 设计参考：[openconnect-proxy](https://github.com/wazum/openconnect-proxy)、[oc-daemon](https://github.com/telekom-mms/oc-daemon)、[openconnect-ns](https://github.com/f3flight/openconnect-ns)
- 所有使用和反馈的用户

---

<div align="center">

**如果这个项目对您有帮助，请给个 ⭐ Star 支持一下！**

Made with ❤️ by [duya07](https://github.com/duya07)

</div>
