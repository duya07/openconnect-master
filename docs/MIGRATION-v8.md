# 从 v7 迁移到 v8

v8 删除了 Netns 模式和 cron 守护，改由 systemd 监督两种明确模式。迁移重点是先识别旧版残留，不是盲目删除网络状态。

## 1. 使用旧脚本正常停止

```bash
sudo /path/to/old/oc_master.sh stop
```

如果旧脚本显示“VPN 未运行”，不能据此认定已清理；v7 的早退缺陷可能跳过残留状态。

## 2. 只读盘点

```bash
pgrep -a openconnect || true
ip netns list
ip link show veth_ocm_h 2>/dev/null || true
ip -4 rule show
ip -6 rule show
ip -4 route show table 100 2>/dev/null || true
ip -6 route show table 101 2>/dev/null || true
iptables-save | grep -E '192\.168\.200\.0/24|veth_ocm|ocm_vpn_space' || true
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
```

同时检查旧状态文件是否存在：

```bash
sudo ls -l /var/run/oc_manager.state /var/run/oc_manager.pid \
  /var/run/oc_gost.pid /var/run/oc_socat.pid /var/run/oc_socat.pid.v6 2>/dev/null
```

## 3. 判断归属后再清理

只有当 namespace、veth、表 100/101 和 iptables 规则能与旧状态文件对应时，才应使用旧项目的清理逻辑。若这些对象也被其他 VPN、容器或策略路由使用，先备份完整输出并人工拆分归属。

v8 故意不会清理表 100/101、`ocm_vpn_space` 或旧 iptables 规则，因为它无法安全证明这些对象仍只属于 v7。

## 4. 更新账户记录

v8 继续读取 `/root/.vpn_accounts.env`。旧五字段记录可用，但需在每次交互启动时选择协议。推荐改为：

```text
显示名|用户名|密码|VPN主机|认证组(可空)|协议(anyconnect/nc/pulse)
```

文件必须由 root 拥有且权限为 `0600`。它是明文凭据，不应进入 Git、备份日志或聊天记录。

## 5. 先验证 SOCKS 模式

```bash
sudo ./oc_master.sh install
sudo ocm start-proxy
sudo ocm status
```

确认宿主机默认路由未变化，再把 sing-box 的某个测试 inbound 指向 SOCKS outbound。通过新建外部连接验证后，再扩大到全部 TCP。

## 6. 全局模式最后验证

只有确实需要整机出站走 VPN 时才使用全局模式。首次测试应保证云厂商串口/VNC 控制台可用，并在三分钟回滚窗口内从外部新建连接；不要仅依赖启动全局模式前已经建立的 SSH 会话。

先盘点 cron 和 systemd 中的 DDNS 更新器。全局模式会让普通公网 IP 查询看到 VPN 出口，必须暂停 DDNS，或确保其检测与 API 请求绑定原物理接口/源地址。v8 检测到常见 DDNS 任务时会要求 `GLOBAL-DDNS-RISK`，但不会替你修改其他项目。
