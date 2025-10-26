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
- `socat` - Port forwarding for Netns mode (recommended)
- `iptables` - Firewall and NAT rules
- `iproute2` - Network configuration tools

## 🚀 Quick Start

### Method 1: One-Click Install (Recommended)

```bash
# Download and run directly
bash <(curl -fsSL https://raw.githubusercontent.com/duya07/openconnect-master/main/oc_master.sh)
```

### Method 2: Manual Install

```bash
# Download script
wget https://raw.githubusercontent.com/duya07/openconnect-master/main/oc_master.sh

# Add execute permission
chmod +x oc_master.sh

# Run script
./oc_master.sh
```

### Method 3: Clone Repository

```bash
# Clone repository
git clone https://github.com/duya07/openconnect-master.git
cd openconnect-master

# Run script
chmod +x oc_master.sh
./oc_master.sh
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

**Usage**:
```bash
# Select after running the script
3) Start: 🌐 Netns Mode (SOCKS5, IPv4+IPv6 Full Features)
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
My University VPN|student001|mypassword|vpn.university.edu|DefaultGroup
Company VPN|employee@company.com|companypass|vpn.company.com|
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
*/5 * * * * /path/to/oc_master.sh _internal_check_health
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
4) Stop VPN

# Method 2: Direct command line
./oc_master.sh stop
```

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

For more issues, refer to [FAQ Documentation](docs/FAQ.md)

## 📊 Version History

### v7.7.7 (2025-10-25) - Final

- ✨ **New**: Active IPv6 connectivity test feature for Netns mode
- 🔧 **Fix**: Enhanced IPv6 detection in show_status, improved detection success rate
- 🔧 **Optimization**: Simplified ocproxy mode, removed remote connection option, listen on localhost by default
- ✨ **Enhancement**: socat forwarding supports IPv4 and IPv6 dual-stack listening
- 📝 **Documentation**: Improved usage documentation and troubleshooting guide

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
