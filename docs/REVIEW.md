# v7.7.7 稳定性审查与 v8 设计证据

- 审查日期：2026-09-07
- 全局模式补充验证：2026-09-08
- 被审查版本：`b3c9551`
方法：define-prove（观察、因果主张、反证、残余未知分开记录）

## 目标与验收边界

目标不是“让 OpenConnect 进程长时间存在”，而是：

1. VPS 的既有 SSH、sing-box 等入站连接始终从原网关正确回程。
2. 全部 sing-box TCP 或指定 inbound 的 TCP 可以使用 VPN 出口。
3. 首选方案不修改宿主机默认路由、iptables、转发 sysctl 或 DNS。
4. 链路短暂中断后自动恢复；认证失败不能无限重试。
5. 停止、启动失败和进程异常退出都能清理本项目拥有的状态。

## v7.7.7 的已观察缺陷

| 观察 | 可直接推出的影响 |
|---|---|
| 中文脚本使用无效的 `at now + 2 分钟之前` | 所宣称的两分钟安全回滚没有被可靠创建。 |
| `stop_vpn` 在 OpenConnect/gost/socat 都不存活时提前返回 | 启动中途失败或进程先退出时，状态文件、策略路由、namespace 和 NAT 可能残留。 |
| 健康判断只检查 PID 与进程名 | 半开连接、代理监听消失、路由错误和实际请求失败都可能被误报为健康。 |
| ocproxy 启动只等待 OpenConnect PID | “VPN 进程存在”被错误地当成“SOCKS 数据面可用”。 |
| cron 重连 ocproxy 时再次进入端口交互 | 无人值守 cron 可能阻塞，无法完成恢复。 |
| Netns 模式明确不支持自动重连 | 与 README 中“最佳稳定性”的定位冲突。 |
| Netns 设置全局 IPv4/IPv6 forwarding，停止时不恢复原值 | 对宿主机产生超出代理需求的持久副作用。 |
| iptables 备用 FORWARD 规则使用 `-i veth` | 主机或外部到 namespace 的 DNAT 流量实际从 veth 发出，方向不匹配。 |
| 账户管理直接打印整行记录 | 明文密码会出现在终端和可能的录屏/日志中。 |
| README 声称“加密存储”，代码只是 `chmod 600` 的明文 | 安全承诺与实现不一致。 |
| 中英文脚本协议能力不一致 | 相同项目入口会产生不同网络行为。 |

这些是静态代码能够证明的问题；它们足以否定旧版的回滚、健康检查和无人值守稳定性声明。

## 授权实机验证

测试环境为一台 Debian 12 VPS，内核 6.10，OpenConnect 9.01，sing-box 1.14.0。敏感主机名、账号、地址和认证内容不记录在仓库。

### 协议判定

所有协议测试均使用临时本地端口，不改默认路由：

| 客户端/协议 | 结果 | 证据边界 |
|---|---|---|
| OpenConnect `anyconnect` | 认证前失败 | 网关返回 Juniper/Pulse 风格 HTML，而非 AnyConnect XML。 |
| OpenConnect `pulse` | 认证前失败 | IF-T/TLS challenge 的 client capabilities 不被网关接受。 |
| OpenConnect `nc` + ocproxy | 成功 | 约 3 秒建立；VPN 出口与宿主机直连出口不同。 |
| sing-box 1.14 原生 OpenConnect `anyconnect` | 失败 | HTML 根节点不符合 AnyConnect 认证格式。 |
| sing-box 1.14 原生 OpenConnect `nc` | 失败 | 60 秒停留在 waiting for authentication，endpoint 始终未 ready。 |

因此，对该网关可以肯定的是 `nc`；不能根据登录页面品牌盲选 `pulse`，也不能把 sing-box 新增的原生 endpoint 当作已证明可替代系统 OpenConnect。

### 稳定性与故障注入

系统 OpenConnect `--protocol=nc` + ocproxy 的隔离测试：

- 10 分钟内 40/40 次定期新建 HTTPS 连接成功。
- 期间 OpenConnect/ocproxy 持续存在，ESP DPD 持续运行。
- 宿主机默认路由始终保持原接口。
- 一条刻意限速的长下载在约 3.5 分钟后被对端 reset，但之后所有新连接继续成功；该现象不能证明 VPN 断线，故只记为未归因残余。

v8 候选实现的 systemd 隔离测试：

- SOCKS VPN 出口与宿主机直连出口不同。
- 主动终止 OpenConnect 后，systemd 产生新 PID，SOCKS 数据面自动恢复。
- 恢复后 20/20 次连续 HTTPS 探测成功。
- 测试前后的主路由与 IPv4 rule 完全一致。
- 停止后临时监听、OpenConnect 进程、测试文件均为零残留。

### 全局模式与回程保护

在同一台 VPS 上另行授权了短时默认路由测试，测试脚本与当前工作树的 SHA-256 一致，文件、profile 和 systemd transient unit 均限制在 `/run`：

- 切换前建立的 SSH 每 5 秒发送一次心跳，48/48 次连续到测试结束，没有断开。
- 全局模式生效后，从测试机新建 SSH 连接 6/6 成功。
- 普通出站路由选择 `ocm0`，出口地址变为 VPN 地址；原 VPS 地址命中专用策略表 51888，并继续从原 `eth0` 默认网关回程。
- 生产 sing-box 的进程 PID 和 4 个 TCP 监听在切换、回滚前后保持不变。
- 首轮 180 秒定时器按时执行时，发现 `systemctl disable --now` 对 transient 测试服务没有真正执行 stop；随后显式清理完整恢复。这暴露了停止动作不应依赖单元能否被 disable。
- 修复为“先 `systemctl stop`，再单独 `systemctl disable`”后，以 45 秒独立定时器复验：VPN 服务自动停止，OpenConnect 和 `ocm0` 消失，表 51888 清空，默认路由、IPv4 rule、原直连出口全部恢复；回滚后的新 SSH 仍可建立。

公网 sing-box 端口从测试机连接时在启用 VPN **之前**就被拒绝，因此不能把该现象归因于全局路由，也不能据此宣称完成了协议级端到端代理验证。该 VPS 的外部 SSH 端口与 sshd 内部监听端口不同，证明上游存在端口转换；复验 sing-box 必须使用客户端实际配置的公网映射端口。此次只能证明 sing-box 服务与监听没有被路由切换破坏。

生产 sing-box 自当前进程启动以来 `NRestarts=0`，最近 24 小时的 systemd journal 未出现 timeout、reset、fatal 或 OOM 类记录，故没有证据支持“sing-box 进程在数分钟后崩溃”。主机另有 Port Traffic Dog 的 3011 quota/drop 规则，但当前用量远低于配额，不能解释眼下断连；同一计数和 quota 规则在 nftables 链中重复出现，会造成重复累计，是独立项目应单独修复的问题，v8 不越权改动它。

### 前置中转链路

取得客户端实际公网映射后又做了分层验证，敏感地址与密钥不记录在仓库：

- 测试机到最终公网映射端口约百毫秒完成 TCP 握手，最终 sing-box 立即记录入站；关闭纯 TCP 后出现 `read header: EOF`，这是预期的无代理头行为。
- 使用服务端现有密钥，在 VPS 本机经 3011 完成 Shadowsocks 2022、DNS 和 HTTPS 请求，证明最终 sing-box 的加密、认证与 direct 出站完整可用。
- 客户端节点的方法和密钥安全指纹与最终 3011 配置完全相同。
- 点名测试客户端中的前置中转节点约 5 秒后失败；中转端口本身可建立 TCP，但最终 sing-box 没有收到该次合法请求。
- 中转配置使用 DDNS 域名作为最终映射目标。该域名解析到本轮全局 VPN 测试观察到的 VPN 出口地址，域名目标端口超时；改用 VPS 当前真实公网地址后，目标端口可连接。
- VPS 上 DDNS 脚本当前检测值与本地缓存都已恢复为真实公网地址，但线上 DNS 仍保留 VPN 出口。脚本只比较“当前检测值与本地缓存”，输出 `WAN IP Unchanged` 后提前退出，并不核对线上记录，因此不会自动修复这种漂移。

因此，当前实时故障已经收敛到“中转的 DDNS 目标错误”，不支持“最终 sing-box 崩溃”“3011 密钥错误”或“最终公网映射不可达”。全局模式确实能让普通公网 IP 检测看到 VPN 出口，并具备污染 DDNS 的完整机制；但仅凭现有日志还不能证明具体是哪一次进程/API 调用改写了线上记录。

## 因果账本

### 已支持

- 错误协议会导致本环境认证前失败；正确协议为 `nc`。
- 旧版 PID-only 健康判据不能证明代理可用。
- 旧版回滚命令错误、清理早退和 ocproxy cron 交互会让自动恢复不可靠。
- OpenConnect+ocproxy 可以在完全不改宿主机路由时，为 sing-box 提供稳定 TCP 出口。
- systemd 监督能够在 OpenConnect 进程退出后恢复该出口。
- 在已测的单网卡、单 IPv4 VPS 上，按原地址建立的独立源策略表可同时保持既有 SSH 和新建 SSH，并让普通出站进入 VPN。
- 显式 stop 与独立定时器组合可以在无人确认时自动停止隧道并恢复本项目拥有的路由状态。
- 源策略回程只能保护使用原 VPS 源地址的入站回复，不能保护普通 DDNS 公网 IP 检测；全局模式必须显式提示并拦截常见 DDNS 自动任务。

### 已反证或不采用

- “VPN 网关必然在几分钟后断开”：10 分钟连续新连接测试不支持该说法。
- “必须用 Netns 才不影响入站”：ocproxy/script-tun 已在零路由变化条件下满足隔离目标。
- “sing-box 原生 OpenConnect 更简单所以应优先”：当前版本在该网关上无法完成认证。
- “无限重启更稳定”：它可能反复提交错误凭据，因此 v8 同时设置 systemd 启动限速和健康重启冷却。

### 尚未证明

- 用户历史故障当时采用的确切模式、协议和 sing-box 路由，因为旧日志与运行状态已不存在。
- 多网卡、多公网地址或第三方策略路由共存时的全局回程正确性。
- DDNS 线上记录究竟由哪一次调用改写；已证明故障机制和记录漂移，尚未取得 Cloudflare 变更审计来归属具体写入者。
- DDNS 修复后的“中转 WSS → 公网映射 → 3011 Shadowsocks → HTTPS”完整复验；用户选择先自行修复并测试 DNS。
- ocproxy 不提供 UDP/IPv6；这不是 v8 声称解决的范围。

## 为什么选择当前设计

- OpenConnect 自身负责协议、DPD 与会话重连；systemd 只监督进程生命周期。
- 数据面健康检查借鉴成熟代理容器“隧道未 ready 就不能报健康”的做法，但不把容器、iptables gate 和额外代理进程引入宿主机。
- 默认使用 ocproxy/script-tun，把 VPN 限制在用户态 TCP 代理，不接触主路由。
- 全局模式只保留需求所必需的策略回程表，并使用 owner marker；遇到表冲突直接失败。
- 全局模式只检测并警告常见 DDNS 任务，不擅自暂停、修改或接管其他项目；命中时要求 `GLOBAL-DDNS-RISK` 二次确认。
- 取消旧 Netns 路径，避免维护 namespace、veth、NAT、双栈转发和 gost/socat 四组独立状态。

## 最小复验

最终候选版本另外执行了以下不接触生产配置的检查：

- Bash 语法、ShellCheck warning 级、JSON 解析和 CRLF 检查全部通过。
- 在 Debian 12 的 `/run` 随机临时目录通过纯函数测试：DDNS cron/systemd 识别、策略规则优先级冲突、TCP 监听判定、systemd 启动失败传播、停止状态 fail-closed、管理锁，以及快捷链接归属/冲突保护。
- 使用 sing-box 1.14 对两个示例配置执行 `sing-box check`，均通过；临时目录随后删除。

这些检查证明新增管理边界按预期工作，不代替特定 VPN 网关的长期运行验证。隧道核心路径沿用上文已做的代理模式、故障注入和全局回滚实测；最终新增的 DDNS 防护只在拨号前检测并确认，不改数据面。

仓库复验命令：

```bash
bash -n oc_master.sh oc_master_en.sh tests/static.sh tests/functions.sh
shellcheck -x -S warning oc_master.sh oc_master_en.sh tests/static.sh tests/functions.sh
bash tests/static.sh
```

生产机代理模式：

```bash
sudo ocm start-proxy
sudo ocm status
curl --proxy socks5h://127.0.0.1:1080 https://api.ipify.org
sudo ocm logs
```

不要只检查 PID。出口请求、监听、systemd 状态和停止后的残留需要一起成立。
