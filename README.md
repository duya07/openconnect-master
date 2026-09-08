# 🚀 OpenConnect Master Manager

<div align="center">

**[English](README_EN.md) | 简体中文**

![Version](https://img.shields.io/badge/version-8.0.0-blue?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)
![Platform](https://img.shields.io/badge/platform-Linux-lightgrey?style=flat-square)
![Shell](https://img.shields.io/badge/shell-bash-89e051?style=flat-square)

**一站式 OpenConnect VPN 出口管理工具**

本地 SOCKS5 出口 | 整机全局 VPN | 入站回程保护 | systemd 稳定守护

[快速开始](#-快速开始) • [功能特性](#-功能特性) • [使用文档](#-使用文档) • [管理命令](#-管理命令)

</div>

---

## ✨ 功能特性

### 🎯 两种运行模式

| 模式 | 说明 | 宿主机默认路由 | 适用场景 |
|---|---|---|---|
| **本地 SOCKS5 模式** | 在 `127.0.0.1` 提供 OpenConnect 出口 | 不修改 | 单个程序、代理服务或指定端口按需使用 VPN，推荐 |
| **整机全局模式** | 让宿主机默认出站通过 VPN，并保护原公网地址的入站回程 | 修改 | 确实需要整台 VPS 使用 VPN 出口的场景 |

### 🔥 核心功能

- ✅ **稳定连接与自动恢复**
  - OpenConnect 由 systemd 前台监督并支持开机恢复
  - 长时间链路抖动后自动重连
  - 定期检查真实 HTTP 数据面，而不只检查进程或端口
  - 连续多次检查失败才重启，并设置认证失败冷却时间

- ✅ **低影响的按需出口**
  - SOCKS5 模式不修改宿主机默认路由、防火墙和 sysctl
  - 可由任何支持 SOCKS5 的程序单独使用 VPN 出口
  - 启动时验证监听端口和实际出口是否同时可用

- ✅ **全局模式入站保护**
  - 使用独立策略路由表保护 VPS 原公网地址的回程
  - 启动前检测路由表、规则优先级和其他 OpenConnect 进程冲突
  - 启动前武装独立的 3 分钟回滚任务
  - 必须从外部验证新连接并输入 `KEEP`，否则自动回滚
  - 检测常见 DDNS 任务并提示出口地址被误更新的风险

- ✅ **多账户与多协议管理**
  - 保存和切换多个 VPN 账户
  - 支持 `anyconnect`、`nc` 和 `pulse` 协议
  - 兼容旧版五字段账户记录
  - 列表中隐藏密码，账户文件固定为 root-only `0600`

- ✅ **安全管理与清理**
  - 所有管理操作使用独占锁，避免同时修改网络状态
  - 启动失败、停止和异常退出都会清理本项目创建的状态
  - 不覆盖不属于本项目的快捷命令、路由或 OpenConnect 进程
  - 提供简短的 `ocm` 管理命令

## 📦 系统要求

- **操作系统**：使用 systemd 的 Linux VPS
- **权限**：root 或 sudo
- **网络**：能够访问 VPN 网关和软件源
- **基础依赖**：`openconnect`、`curl`、`iproute2`、`procps`、`util-linux`
- **SOCKS5 模式依赖**：`ocproxy`

脚本会检测缺失依赖，并在列出范围、得到确认后使用 apt、dnf 或 yum 安装。当前版本不再依赖 GOST、socat、Network Namespace 或额外的 iptables NAT。

## 🚀 快速开始

### 方法一：使用 curl 安装（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/duya07/openconnect-master/main/oc_master.sh -o /tmp/oc_master.sh
sudo bash /tmp/oc_master.sh install
rm -f /tmp/oc_master.sh
sudo ocm
```

### 方法二：使用 wget 安装

```bash
wget -qO /tmp/oc_master.sh https://raw.githubusercontent.com/duya07/openconnect-master/main/oc_master.sh
sudo bash /tmp/oc_master.sh install
rm -f /tmp/oc_master.sh
sudo ocm
```

安装完成后会创建：

```text
/usr/local/sbin/oc-master
/usr/local/bin/ocm -> /usr/local/sbin/oc-master
```

`install` 只安装或更新脚本和快捷命令，不会立即连接 VPN，也不会在未确认时安装系统软件包。若 `ocm` 已被其他程序占用，安装会停止而不是覆盖。

### 更新脚本

重新执行任一安装方法即可。运行中的连接不会被安装命令直接替换，请先停止 VPN：

```bash
sudo ocm stop
```

## 📖 使用文档

### 首次运行

1. 执行 `sudo ocm` 打开主菜单。
2. 选择 `4) 管理账户`，添加 VPN 账户。
3. 根据需要选择本地 SOCKS5 模式或整机全局模式。
4. 启动完成后使用状态和数据面检查确认真实出口。

### 账户配置

账户信息存储在 `/root/.vpn_accounts.env`，格式如下：

```text
显示名|用户名|密码|VPN主机|认证组(可空)|协议(anyconnect/nc/pulse)
```

示例：

```text
学校 VPN|student001|password|https://vpn.example.edu|Students|nc
公司 VPN|employee|password|https://vpn.example.com||anyconnect
```

也可以参考 [examples/vpn_accounts.example](examples/vpn_accounts.example)。

账户文件是权限为 `0600` 的 root-only **明文文件**，不是加密保险箱。字段不能包含 `|`，密码不能包含换行。旧版五字段记录仍可读取，但每次启动时需要明确选择协议；建议通过菜单重新保存为六字段记录。

### 🔌 本地 SOCKS5 模式（推荐）

适合只让某个程序、代理服务或指定业务使用 VPN 出口：

1. 在主菜单选择 `1) 启动本地 SOCKS5 出口`。
2. 选择 VPN 账户并输入本地端口，例如 `1080`。
3. 将应用的 SOCKS5 地址设置为 `127.0.0.1:1080`。

验证出口：

```bash
curl --proxy socks5h://127.0.0.1:1080 https://api.ipify.org
```

应用接入示例：sing-box 可以把这个 SOCKS5 地址配置成一个 outbound，再按 inbound 或路由规则选择使用。示例片段见 [指定入站走 VPN](examples/sing-box-selected-inbound.json) 和 [全部 TCP 走 VPN](examples/sing-box-all-tcp.json)。SOCKS5 模式只承载 TCP/IPv4，UDP/QUIC 需要单独处理。

### 🛡️ 整机全局模式

适合让宿主机默认出站都使用 VPN。启动时脚本会：

1. 保存原默认路由，并为原 VPS 公网源地址建立回程策略。
2. 检查专用路由表、规则优先级、其他 OpenConnect 进程和常见 DDNS 任务。
3. 创建独立的 3 分钟安全回滚任务。
4. 启动固定接口 `ocm0` 并验证真实 HTTP 数据面。
5. 要求你从外部新建 SSH 或代理连接，并在 120 秒内输入 `KEEP`。

首次启用建议同时打开云厂商控制台。若外部新连接失败，不要输入 `KEEP`，脚本会自动停止并恢复本项目管理的路由状态。

全局出口可能让普通 DDNS 脚本把 VPN 地址误写成 VPS 公网地址。脚本只检测并警告，不会擅自暂停第三方任务；启用前应确认 DDNS 已停止，或已绑定原物理接口/源地址。

## 🎛️ 管理命令

### 交互菜单

```bash
sudo ocm
```

菜单提供：

```text
1) 启动本地 SOCKS5 出口
2) 启动整机全局 VPN
3) 停止 VPN
4) 管理账户
5) 查看日志
6) 卸载管理器
7) 安装/更新快捷命令 ocm
0) 退出
```

### 命令行入口

```bash
sudo ocm start-proxy   # 启动本地 SOCKS5 出口
sudo ocm start-global  # 启动整机全局 VPN
sudo ocm stop          # 停止连接并清理本项目路由
sudo ocm accounts      # 管理账户
sudo ocm status        # 查看服务、模式和出口状态
sudo ocm check         # 执行一次真实数据面检查
sudo ocm logs          # 查看最近的连接与健康检查日志
sudo ocm install       # 安装或更新快捷命令
sudo ocm uninstall     # 卸载管理器
```

`start-proxy` 和 `start-global` 会交互选择账户，避免无人值守时误用凭据或协议。

### 停止与卸载

停止 VPN：

```bash
sudo ocm stop
```

卸载管理器：

```bash
sudo ocm uninstall
```

卸载会停止 VPN，删除本项目的 systemd 单元、程序副本、快捷命令和活动配置；不会卸载共享软件包，账户文件 `/root/.vpn_accounts.env` 默认保留。

## 🐛 故障排除

### 查看当前状态

```bash
sudo ocm status
sudo ocm check
sudo ocm logs
systemctl status oc-master.service oc-master-health.timer
```

### 常见问题

1. **VPN 连接失败**
   - 检查账户、认证组和 VPN 地址。
   - 根据网关实际类型选择 `anyconnect`、`nc` 或 `pulse`，不要仅凭登录页品牌猜测。
   - 使用 `sudo ocm logs` 查看 OpenConnect 的明确错误。

2. **SOCKS5 端口存在但代理不通**
   - 运行 `sudo ocm check`，确认 HTTP 数据面而不只是监听端口。
   - 用 `curl --proxy socks5h://127.0.0.1:端口 https://api.ipify.org` 直接测试。
   - 检查端口是否被其他程序占用。

3. **全局模式后外部入站异常**
   - 不要输入 `KEEP`，等待或触发安全回滚。
   - 检查是否存在多网卡、多公网地址、第三方策略路由或其他 VPN。
   - 同时检查 DDNS 是否把域名更新成了 VPN 出口地址。

健康状态需要同时满足 OpenConnect 受 systemd 监督、预期监听或路由存在，以及真实 HTTP 请求成功。仅有 PID 或监听端口不能证明出口可用。

## 📊 版本历史

### v8.0.0 (2026-09-08)

- ✨ **新增**：`ocm` 快捷管理命令和非交互管理入口
- ✨ **新增**：账户可保存 OpenConnect 协议类型
- 🔧 **增强**：systemd 连接监督、真实数据面健康检查和失败冷却
- 🔧 **增强**：全局模式入站回程策略、DDNS 风险检测和独立安全回滚
- 🔧 **调整**：运行模式精简为本地 SOCKS5 与整机全局 VPN，不再依赖 GOST、socat 和 Netns

### v7.7.7 (2025-10-25) - Final

- ✨ **新增**：Netns 模式的 IPv6 连通性主动测试功能
- 🔧 **修复**：增强 `show_status` 中的 IPv6 检测
- 🔧 **优化**：简化 ocproxy 模式，默认监听本地地址
- ✨ **增强**：socat 转发支持 IPv4 和 IPv6 双栈监听
- 📝 **文档**：完善使用文档和故障排除指南

### v7.7.6 (2025-01-10)

- 🔧 **修复**：采用“服务内置（gost in netns），端口外挂（socat/DNAT）”架构
- ✨ **新增**：优先使用 socat 端口转发，并提供 iptables DNAT 备用
- 🔧 **增强**：增加 tun 接口和内部网络连通性检查

### v7.7.5 (Earlier)

- 初始版本发布
- 支持三种运行模式
- 实现策略路由保护
- 引入 Network Namespace 隔离

旧版本升级前请先停止旧连接。若旧版异常退出后留有 Netns、iptables 或进程状态，可参考 [迁移说明](docs/MIGRATION-v8.md)。

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

### 开发建议

- 保持代码风格一致
- 添加必要的注释
- 更新相关文档和示例
- 修改网络行为时同时验证启动、失败回滚、停止和重连路径

审查依据和实机验证记录保存在 [docs/REVIEW.md](docs/REVIEW.md)，不影响普通用户按本文档安装和管理。

## 📄 许可证

本项目采用 MIT 许可证，详见 [LICENSE](LICENSE) 文件。

## 🙏 致谢

- [OpenConnect](https://www.infradead.org/openconnect/)
- [ocproxy](https://github.com/cernekee/ocproxy)
- [wazum/openconnect-proxy](https://github.com/wazum/openconnect-proxy)
- 所有使用、测试和提供反馈的用户

---

<div align="center">

**如果这个项目对您有帮助，请给个 ⭐ Star 支持一下！**

Made with ❤️ by [duya07](https://github.com/duya07)

</div>
