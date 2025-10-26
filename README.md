# 🚀 OpenConnect Master Manager

<div align="center">

![Version](https://img.shields.io/badge/version-7.7.7-blue?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)
![Platform](https://img.shields.io/badge/platform-Linux-lightgrey?style=flat-square)
![Shell](https://img.shields.io/badge/shell-bash-89e051?style=flat-square)

**一站式 OpenConnect VPN 管理工具**

支持三种运行模式 | 策略路由保护 | Network Namespace 隔离 | IPv4+IPv6 双栈

[快速开始](#-快速开始) • [功能特性](#-功能特性) • [使用文档](#-使用文档)

</div>

---

## ✨ 功能特性

### 🎯 三种运行模式

| 模式 | 图标 | 说明 | IPv4 | IPv6 | 适用场景 |
|------|------|------|------|------|----------|
| **默认模式** | 🛡️ | 全局 VPN + SSH 保护 | ✅ | ✅ | 需要全局代理的场景 |
| **ocproxy 模式** | 🔌 | SOCKS5 代理（简化） | ✅ | ❌ | 轻量级代理需求 |
| **Netns 模式** | 🌐 | Network Namespace 隔离 | ✅ | ✅ | **推荐**！完全隔离、双栈支持 |

### 🔥 核心功能

- ✅ **智能策略路由**
  - 自动保护 SSH 连接不受 VPN 影响
  - 支持 IPv4 和 IPv6 双栈路由
  - 精确的路由表管理和清理

- ✅ **多账户管理**
  - 支持多个 VPN 账户切换
  - 账户信息加密存储
  - 快速选择和切换

- ✅ **定时任务支持**
  - 自动重连守护进程
  - 定时启动/关闭
  - 连接状态监控

- ✅ **安全清理机制**
  - 完整的环境清理
  - 自动回滚保护
  - 优雅的中断处理

- ✅ **Network Namespace 隔离**（Netns 模式）
  - 完全独立的网络环境
  - 不影响宿主机网络
  - 支持 IPv4 和 IPv6 双栈
  - 通过 SOCKS5 代理访问

## 📦 系统要求

- **操作系统**: Debian/Ubuntu/CentOS/RHEL 或其他 Linux 发行版
- **权限**: 需要 root 权限
- **网络**: 需要能访问外网
- **依赖**: 脚本会自动检测并安装必要依赖

### 自动安装的依赖

- `openconnect` - OpenConnect VPN 客户端
- `ocproxy` - ocproxy 模式所需
- `gost` - Netns 模式的 SOCKS5 服务器
- `socat` - Netns 模式的端口转发（推荐）
- `iptables` - 防火墙和 NAT 规则
- `iproute2` - 网络配置工具

## 🚀 快速开始

### 方法一：一键安装（推荐）

```bash
# 下载并直接运行
bash <(curl -fsSL https://raw.githubusercontent.com/duya07/openconnect-master/main/oc_master.sh)
```

### 方法二：手动安装

```bash
# 下载脚本
wget https://raw.githubusercontent.com/duya07/openconnect-master/main/oc_master.sh

# 添加执行权限
chmod +x oc_master.sh

# 运行脚本
./oc_master.sh
```

### 方法三：克隆仓库

```bash
# 克隆仓库
git clone https://github.com/duya07/openconnect-master.git
cd openconnect-master

# 运行脚本
chmod +x oc_master.sh
./oc_master.sh
```

## 📖 使用文档

### 首次运行

1. 运行脚本后，选择 `5) 管理 VPN 账户`
2. 添加您的 VPN 账户信息：
   - 显示名称（方便识别）
   - VPN 用户名
   - VPN 密码
   - VPN 服务器地址
   - 认证组（可选）

### 模式选择指南

#### 🛡️ 默认模式

**适用场景**：
- 需要全局 VPN 代理
- 所有流量都要通过 VPN
- 需要访问内网资源

**特点**：
- 所有流量通过 VPN
- 自动保护 SSH 连接
- 支持 IPv4 和 IPv6

**使用方法**：
```bash
# 运行脚本后选择
1) 启动: 🛡️  默认模式 (全局VPN, 保护SSH)
```

#### 🔌 ocproxy 模式

**适用场景**：
- 只需要 SOCKS5 代理
- 不需要 IPv6 支持
- 轻量级使用

**特点**：
- 提供 SOCKS5 代理接口
- 仅支持 IPv4
- 默认监听本地 127.0.0.1

**使用方法**：
```bash
# 运行脚本后选择
2) 启动: 🔌 ocproxy 模式 (SOCKS5, 仅IPv4)
# 输入监听端口（例如 1080）
```

#### 🌐 Netns 模式（推荐）

**适用场景**：
- 需要完全隔离的网络环境
- 需要同时支持 IPv4 和 IPv6
- 追求最佳的稳定性和兼容性

**特点**：
- 使用 Network Namespace 完全隔离
- 不影响宿主机网络
- 支持 IPv4 和 IPv6 双栈
- 通过 SOCKS5 代理访问
- 可选择本地或远程监听

**使用方法**：
```bash
# 运行脚本后选择
3) 启动: 🌐 Netns 模式 (SOCKS5, IPv4+IPv6 全功能)
# 输入监听端口（例如 8585）
# 选择是否允许远程连接
```

### 账户配置文件格式

账户信息存储在 `/root/.vpn_accounts.env`，格式如下：

```
显示名|用户名|密码|VPN主机|认证组(可选)
```

示例：
```
我的大学VPN|student001|mypassword|vpn.university.edu|DefaultGroup
公司VPN|employee@company.com|companypass|vpn.company.com|
```

也可以参考 [examples/vpn_accounts.example](examples/vpn_accounts.example)

### 定时任务

#### 设置守护进程（自动重连）

```bash
# 在脚本主菜单选择
6) 设置定时/守护任务
1) 设置守护任务 (每5分钟检查，断线重连)
```

这会在 crontab 中添加：
```cron
*/5 * * * * /path/to/oc_master.sh _internal_check_health
```

⚠️ **注意**：守护任务目前仅支持**默认模式**和 **ocproxy 模式**

#### 设置定时关闭

```bash
# 例如：每天凌晨 2 点自动关闭 VPN
6) 设置定时/守护任务
2) 添加定时关闭任务
# 输入: 0 2 * * *
```

### 停止 VPN

```bash
# 方法1: 在脚本菜单中
4) 停止 VPN

# 方法2: 直接命令行
./oc_master.sh stop
```

### IPv6 连通性测试

对于 Netns 模式，可以测试 IPv6 连通性：

```bash
# 在脚本主菜单选择
8) 🧪 测试 Netns IPv6 连通性
```

测试项目包括：
1. ✓ 检查 Netns 内的全局 IPv6 地址
2. ✓ Ping Google IPv6 DNS (2001:4860:4860::8888)
3. ✓ HTTP IPv6 连接测试

## 🔧 高级配置

### 自定义配置参数

脚本内的关键配置变量（可根据需要修改）：

```bash
# Network Namespace 配置
NETNS_NAME="ocm_vpn_space"
VETH_HOST="veth_ocm_h"
VETH_NS="veth_ocm_ns"
VETH_HOST_IP="192.168.200.1"
VETH_NS_IP="192.168.200.2"

# 路由表 ID
RT4_ID=100  # IPv4 路由表
RT6_ID=101  # IPv6 路由表

# 文件位置
PID_FILE="/var/run/oc_manager.pid"
STATE_FILE="/var/run/oc_manager.state"
ACCOUNTS_FILE="/root/.vpn_accounts.env"
```

### 手动调试命令

```bash
# 查看 Network Namespace
ip netns list

# 查看 Netns 内的网络配置
ip netns exec ocm_vpn_space ip addr
ip netns exec ocm_vpn_space ip route

# 在 Netns 内测试连接
ip netns exec ocm_vpn_space ping 8.8.8.8
ip netns exec ocm_vpn_space curl https://ip.p3terx.com

# 查看 SOCKS5 监听端口
ss -tlnp | grep gost

# 查看 OpenConnect 进程
ps aux | grep openconnect
```

## 🐛 故障排除

### 常见问题

1. **VPN 连接失败**
   - 检查账户信息是否正确
   - 确认 VPN 服务器地址可访问
   - 查看 OpenConnect 日志

2. **SOCKS5 代理不工作**（Netns 模式）
   - 测试 Netns 内网络连通性：`ip netns exec ocm_vpn_space ping 8.8.8.8`
   - 检查 gost 进程是否运行：`ps aux | grep gost`
   - 检查端口转发：`ss -tlnp | grep 8585`

3. **IPv6 不工作**
   - 确认 VPN 服务器支持 IPv6
   - 使用 Netns 模式（默认和 ocproxy 模式对 IPv6 支持有限）
   - 运行 IPv6 连通性测试（菜单选项 8）

4. **SSH 连接中断**（默认模式）
   - 脚本会自动保护 SSH 连接
   - 如果仍然中断，检查策略路由配置

更多问题请参考 [常见问题文档](docs/FAQ.md)

## 📊 版本历史

### v7.7.7 (2025-10-25) - Final

- ✨ **新增**：Netns 模式的 IPv6 连通性主动测试功能
- 🔧 **修复**：增强 show_status 中的 IPv6 检测，提高检测成功率
- 🔧 **优化**：简化 ocproxy 模式，移除远程连接选项，默认监听本地
- ✨ **增强**：socat 转发支持 IPv4 和 IPv6 双栈监听
- 📝 **文档**：完善使用文档和故障排除指南

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
- 测试所有三种模式

## 📄 许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件

## 🙏 致谢

- [OpenConnect](https://www.infradead.org/openconnect/)
- [GOST](https://github.com/go-gost/gost)
- [ocproxy](https://github.com/cernekee/ocproxy)
- 所有使用和反馈的用户

---

<div align="center">

**如果这个项目对您有帮助，请给个 ⭐ Star 支持一下！**

Made with ❤️ by [duya07](https://github.com/duya07)

</div>
