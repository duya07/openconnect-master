# OpenConnect Master Manager

[English](README_EN.md) | 简体中文

面向 Linux VPS 的 OpenConnect 出口管理器。v8 的首要目标是：**远程入站连接保持走 VPS 原网关，只有明确选择的出站流量进入 VPN**。

## 推荐架构

| 模式 | 宿主机默认路由 | 系统防火墙/sysctl | 出口能力 | 推荐度 |
|---|---:|---:|---|---:|
| 本地 SOCKS5 | 不修改 | 不修改 | TCP、IPv4 | **推荐** |
| 整机全局 VPN | 修改 | 不修改 | 由 VPN 网关决定 | 高级用途 |

对 sing-box，通常不需要让整台 VPS 进入 VPN。让 OpenConnect 在 `127.0.0.1` 提供 SOCKS5，再由 sing-box 决定全部 TCP 或某个 inbound 走该出口，入站回程就不会被 VPN 默认路由接管。

v8 不再提供旧 Netns 模式。它同时依赖 network namespace、iptables、IP forwarding、gost/socat，故障面更大，而且旧实现没有可靠重连和完整回滚；这不符合“对系统破坏最低”的目标。

## v8 修复了什么

- OpenConnect 由 systemd 前台监督，不再依赖 PID 文件加 5 分钟 cron 猜测状态。
- 使用 `--reconnect-timeout=86400` 处理长时间链路抖动。
- OpenConnect 版本支持时启用 30 秒 TCP keepalive，降低 ESP/DTLS 活跃但底层 TLS 被 NAT/防火墙回收的概率。
- 每 30 秒检查真实 HTTP 数据面；连续 3 次失败才重启，并有 15 分钟认证冷却，避免错误密码导致锁号。
- SOCKS 模式启动成功的判据是“监听存在且请求确实从 VPN 出口完成”，不是“OpenConnect 进程存在”。
- 全局模式使用专用策略表保护原 VPS 地址的回程，不写 `/etc/iproute2/rt_tables`。
- 全局启动前创建独立的 3 分钟 systemd 回滚；必须从外部新建连接并输入 `KEEP` 才会取消。
- 全局启动前检查常见 cron/systemd DDNS 任务；发现后要求额外确认，避免把 VPN 出口写回公网域名。
- 停止和异常退出都会执行幂等清理；即使 OpenConnect 已经退出，也不会跳过残留路由。
- 管理操作使用独占锁；systemd 启动链任一步失败都会立即停止、禁用并清理，而不是等待残留状态自行消失。
- 账户列表不显示密码。账户文件是 root-only 的 `0600` **明文文件**，不再错误宣称为“加密存储”。
- 协议成为账户配置的一部分，不再在无人值守重连时退回错误默认协议。

完整的旧版缺陷、因果边界和实机证据见 [审查报告](docs/REVIEW.md)。

## 要求

- 使用 systemd 的 Linux VPS
- root
- `openconnect`、`curl`、`iproute2`、`util-linux`（`flock`）
- SOCKS 模式另需 `ocproxy`

脚本可以通过 apt、dnf 或 yum 安装缺失的系统包，但只会在展示包名并得到确认后执行。

## 安装与运行

建议先下载并检查，再执行：

```bash
git clone https://github.com/duya07/openconnect-master.git
cd openconnect-master
chmod +x oc_master.sh
sudo ./oc_master.sh install
sudo ocm
```

`install` 只安装/更新受控程序副本和快捷命令，不启动 VPN、不安装软件包，也不创建 systemd 服务：

```text
/usr/local/sbin/oc-master
/usr/local/bin/ocm -> /usr/local/sbin/oc-master
```

若 `/usr/local/bin/ocm` 已被其他程序占用，脚本会拒绝覆盖。即使跳过 `install`，首次启动连接也会安装同一受控副本和快捷命令，并创建：

```text
/etc/systemd/system/oc-master.service
/etc/systemd/system/oc-master-health.service
/etc/systemd/system/oc-master-health.timer
/etc/oc-master/profile.conf
```

停止命令会同时停止连接、清理本项目路由并禁用开机自启：

```bash
sudo ocm stop
```

其他非交互入口：

```bash
sudo ocm status
sudo ocm check
sudo ocm logs
```

`start-proxy` 和 `start-global` 仍会交互选择账户，以免无意重试错误凭据。

## 账户文件

路径仍兼容旧版：`/root/.vpn_accounts.env`。

```text
显示名|用户名|密码|VPN主机|认证组(可空)|协议(anyconnect/nc/pulse)
```

示例：

```text
学校 VPN|student001|password|https://vpn.example.edu|Students|nc
```

限制：字段不能包含 `|`，密码不能包含换行。旧的五字段记录仍可读取，但启动时必须明确选择协议。建议通过菜单重新保存为六字段记录。

不同品牌页面不等于同一种协议。若网关跳转到 Juniper/Pulse 的 `/dana-na/` 页面，`pulse` 也不一定可用；应分别验证 `pulse` 与兼容的 `nc`，不要让脚本静默猜测。

## 与 sing-box 搭配

先用菜单启动本地 SOCKS5，例如 `127.0.0.1:1080`。然后在 sing-box 的 `outbounds` 中加入：

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

### 只让某个入站走 VPN

假设对应入站 tag 是 `vpn-only-in`：

```json
{
  "inbound": ["vpn-only-in"],
  "network": ["tcp"],
  "action": "route",
  "outbound": "openconnect-out"
}
```

把这条规则放进现有 `route.rules`。完整片段见 [sing-box-selected-inbound.json](examples/sing-box-selected-inbound.json)。

### 让全部 sing-box TCP 出站走 VPN

将 `route.final` 设为：

```json
{
  "final": "openconnect-out"
}
```

完整片段见 [sing-box-all-tcp.json](examples/sing-box-all-tcp.json)。由于 ocproxy 只承载 TCP/IPv4，必须为 UDP 明确保留 direct/block 规则，不能把 UDP/QUIC 误宣称为已代理。

修改生产配置前先检查，再重启：

```bash
sing-box check -c /etc/sing-box/config.json -C /etc/sing-box/conf
systemctl restart sing-box
```

具体参数按你的安装路径调整。

## 全局模式的安全确认

全局模式会改变默认出站路由，风险明显高于 SOCKS 模式。流程是：

1. 保存原默认路由，并为原 VPS 源地址建立专用回程表。
2. 检查常见 cron/systemd DDNS 任务；若命中，必须先处理风险并输入 `GLOBAL-DDNS-RISK`。
3. 武装独立的 3 分钟回滚任务。
4. 启动固定接口 `ocm0` 并验证真实 HTTP 数据面。
5. 操作者从外部新建 SSH 或代理连接。
6. 只有输入 `KEEP` 才保留；掉线或超时会自动停止并禁用服务。

即使如此，首次仍应在云厂商控制台可用时进行。多网卡、多个公网地址、策略路由或第三方 VPN 共存环境尚未声明支持；脚本检测到专用表冲突或其他 OpenConnect 进程会拒绝启动，而不是覆盖。

回程策略只能保护“已经使用原 VPS 源地址”的连接，不能阻止普通出站程序看到 VPN 公网地址。常见 DDNS 脚本会因此把域名更新到 VPN 出口，导致端口转发和中转失联。推荐直接使用 SOCKS 模式；确需全局模式时，应先暂停 DDNS，或让 DDNS 的公网 IP 查询和 API 请求显式绑定原物理接口/源地址。oc-master 只检测并警告，不会擅自停用第三方任务。

## 诊断

```bash
sudo ocm status
sudo ocm check
sudo ocm logs
systemctl status oc-master.service oc-master-health.timer
```

判断连接是否正常时至少同时看：

- systemd 中 OpenConnect 主进程是否存在；
- SOCKS 监听或 `ocm0` 默认路由是否存在；
- HTTP 探测是否真正成功；
- 实际出口 IP 是否符合预期。

仅有 PID 或端口监听不能证明代理可用。

如果客户端节点前还有端口转发或中转，必须分层检查：

1. `inbound connection` 后立即出现 `read header: EOF`，只说明 TCP 已到服务端、对端未发送合法代理头；端口探活也会产生这种日志。
2. 用与客户端完全相同的方法和密钥做一次真实 Shadowsocks/HTTP 请求。纯 TCP connect 不能证明加密、认证和转发可用。
3. 中转节点测试失败且最终 sing-box 没有新增对应入站时，故障位于中转入口或其转发目标，不应重启 OpenConnect 或修改宿主机路由。
4. 若 sing-box 的 `log.output` 指向文件，应使用 `tail -F /path/to/access.log` 实时观察；此时 `journalctl -f` 或面板轮询可能看不到即时 access log。

Shadowsocks 2022 的 `method` 和密钥必须逐字一致。排查时只比较长度或安全指纹，不要把明文密钥写进命令历史、日志或 Issue。

## 迁移

从 v7 升级前先用旧脚本停止连接，并确认没有遗留 namespace、iptables 或策略路由。v8 不会主动删除它无法确认归属的规则，也不会抢占其他 OpenConnect 进程。

```bash
sudo ./oc_master.sh stop
ip rule show
ip route show table all
pgrep -a openconnect || true
```

如果旧版异常退出留下了资源，请先参考 [迁移说明](docs/MIGRATION-v8.md)，不要直接复制通用删除命令到生产机。

## 参考实现

- [OpenConnect](https://gitlab.com/openconnect/openconnect)
- [ocproxy](https://github.com/cernekee/ocproxy)
- [wazum/openconnect-proxy](https://github.com/wazum/openconnect-proxy)
- [vpn-slice](https://github.com/dlenski/vpn-slice)
- [vopono](https://github.com/jamesmcm/vopono)
- [sing-box](https://github.com/SagerNet/sing-box)

## License

[MIT](LICENSE)
