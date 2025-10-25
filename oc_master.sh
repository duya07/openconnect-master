#!/bin/bash
# =================================================================
#   OpenConnect Master Manager - v7.7.7 (Final)
#   - 定稿: 简化 ocproxy 模式，移除远程连接选项，默认监听本地。
#   - 修复(Netns): 增强 show_status 中的 IPv6 检测，通过多种方式(增加超时、
#     备用检测点、netns内部直连)提高检测成功率。
#   - 增强(Netns): socat 转发支持 IPv4 和 IPv6 双栈监听。
#   - 新增(Netns): 启动时和菜单中增加 IPv6 连通性主动测试功能。
# =================================================================
set -euo pipefail

# --- 全局配置 ---
VR_TAG="OC-Master-v7.7.7-Final"
SCRIPT_PATH="$(readlink -f "$0")"
PID_FILE="/var/run/oc_manager.pid"
GOST_PID_FILE="/var/run/oc_gost.pid"
SOCAT_PID_FILE="/var/run/oc_socat.pid"
SOCAT_PID_FILE_V6="${SOCAT_PID_FILE}.v6"
STATE_FILE="/var/run/oc_manager.state"
ACCOUNTS_FILE="/root/.vpn_accounts.env"

# --- 路由与网络配置 ---
RT4_ID=100; RT4_NAME="vps_return4"
RT6_ID=101; RT6_NAME="vps_return6"
NETNS_NAME="ocm_vpn_space"
VETH_HOST="veth_ocm_h"
VETH_NS="veth_ocm_ns"
VETH_HOST_IP="192.168.200.1"
VETH_NS_IP="192.168.200.2"
VETH_SUBNET="192.168.200.0/24"

# --- 命令路径 ---
IP_CMD="$(command -v ip || echo /sbin/ip)"
IPTABLES_CMD="$(command -v iptables || echo /sbin/iptables)"
CURL_CMD="$(command -v curl || echo /usr/bin/curl)"

# --- 样式与日志 ---
C_RESET='\033[0m'; C_BOLD='\033[1m'; C_GREY='\033[90m'
C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_CYAN='\033[36m'
log()      { echo -e "${C_GREEN}✅ [$VR_TAG] $1${C_RESET}"; }
log_err()  { echo -e "${C_RED}❌ [$VR_TAG] $1${C_RESET}" >&2; }
log_info() { echo -e "${C_CYAN}ℹ️  [$VR_TAG] $1${C_RESET}"; }
log_warn() { echo -e "${C_YELLOW}⚠️  [$VR_TAG] $1${C_RESET}"; }
title()    { echo -e "${C_BOLD}$1${C_RESET}"; }
sep()      { echo -e "${C_GREY}--------------------------------------------------------${C_RESET}"; }
check_root(){ [ "$EUID" -eq 0 ] || { log_err "请用 root 运行"; exit 1; }; }

# --- 中断处理 ---
cleanup_on_interrupt() {
  log_err "\n操作被用户中断 (Ctrl+C)。正在紧急清理..."
  stop_vpn
  exit 1
}

# --- 依赖检查 ---
_pkg_install() {
  local pkg="$1"
  log_info "安装 $pkg..."
  if command -v apt-get &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -yq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -yq "$pkg" >/dev/null || true
  elif command -v yum &>/dev/null; then
    yum install -y "$pkg" >/dev/null || true
  elif command -v dnf &>/dev/null; then
    dnf install -y "$pkg" >/dev/null || true
  fi
}
ensure_pkg_openconnect() { command -v openconnect &>/dev/null || { _pkg_install openconnect; command -v openconnect &>/dev/null || { log_err "安装 openconnect 失败"; exit 1; }; log "OpenConnect 就绪"; }; }
ensure_pkg_ocproxy()     { command -v ocproxy     &>/dev/null || { _pkg_install ocproxy; command -v ocproxy &>/dev/null || { log_err "安装 ocproxy 失败"; exit 1; }; log "ocproxy 就绪"; }; }
ensure_pkg_iptables()    { command -v iptables    &>/dev/null || { _pkg_install iptables; command -v iptables &>/dev/null || { log_err "安装 iptables 失败"; exit 1; }; log "iptables 就绪"; }; }
ensure_cmd_ss()          { command -v ss &>/dev/null || { _pkg_install iproute2 || _pkg_install iproute; log "iproute2 就绪"; }; }
ensure_cmd_gost() {
  command -v gost &>/dev/null && return 0
  log_warn "Netns 模式需要 'gost' 作为 SOCKS5 服务器。"
  read -rp "是否立即使用官方脚本自动安装 gost? [Y/n]: " yn
  [[ "$yn" =~ ^[nN]$ ]] && { log_err "用户取消安装，Netns 模式无法启动。"; return 1; }
  
  log_info "正在使用官方脚本安装 gost..."
  if ! command -v curl &>/dev/null; then _pkg_install curl; fi
  bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install || {
    log_err "gost 安装脚本执行失败。请检查网络或尝试手动安装。"
    return 1
  }
  if ! command -v gost &>/dev/null; then
    log_err "gost 安装后仍未找到命令，请检查 PATH 环境变量或脚本输出。"
    return 1
  fi
  log "gost 已成功安装。"
  return 0
}
ensure_cmd_socat() {
  command -v socat &>/dev/null && return 0
  log_warn "Netns 模式推荐使用 'socat' 进行端口转发。"
  read -rp "是否立即安装 socat? [Y/n]: " yn
  [[ "$yn" =~ ^[nN]$ ]] && { log_info "将使用 iptables 作为备用方案。"; return 1; }
  _pkg_install socat
  command -v socat &>/dev/null || { log_warn "socat 安装失败，将使用 iptables。"; return 1; }
  log "socat 已安装。"
  return 0
}
check_atd() { if ! command -v at &>/dev/null || ! systemctl is-active --quiet atd; then log_warn "at/atd 缺失或未运行, 尝试安装并启动..."; _pkg_install at; systemctl enable --now atd 2>/dev/null || log_err "自动启动 atd 失败"; fi; }

# --- IPv6 连通性测试 ---
test_netns_ipv6() {
  local test_passed=0
  log_info "正在测试 Netns 内的 IPv6 连通性..."
  if ! "$IP_CMD" netns list | grep -q "${NETNS_NAME}"; then log_err "Netns ${NETNS_NAME} 不存在，无法测试。"; return 1; fi
  
  # 测试1: 检查是否有 IPv6 地址
  if "$IP_CMD" netns exec "${NETNS_NAME}" ip -6 addr show 2>/dev/null | grep -q "inet6.*scope global"; then
    log "✓ Netns 内存在全局 IPv6 地址"
    test_passed=$((test_passed + 1))
  else
    log_warn "✗ Netns 内未发现全局 IPv6 地址"
  fi
  
  # 测试2: Ping IPv6 DNS
  if "$IP_CMD" netns exec "${NETNS_NAME}" ping -6 -c 1 -W 3 2001:4860:4860::8888 >/dev/null 2>&1; then
    log "✓ Netns 内可 ping 通 Google IPv6 DNS"
    test_passed=$((test_passed + 1))
  else
    log_warn "✗ Netns 内无法 ping 通 IPv6 地址"
  fi
  
  # 测试3: HTTP IPv6 请求
  if "$IP_CMD" netns exec "${NETNS_NAME}" curl -6 -s --connect-timeout 5 --max-time 10 https://ipv6.google.com >/dev/null 2>&1; then
    log "✓ Netns 内可通过 IPv6 访问互联网"
    test_passed=$((test_passed + 1))
  else
    log_warn "✗ Netns 内无法通过 IPv6 访问互联网"
  fi
  
  if [ $test_passed -ge 2 ]; then
    log "IPv6 功能测试通过 ($test_passed/3)"
    return 0
  else
    log_warn "IPv6 功能测试部分失败 ($test_passed/3)，但不影响 IPv4 功能"
    return 1
  fi
}

# --- 网络核心功能 ---
check_rt_conflict() {
  local id="$1" name="$2"
  [ -d /etc/iproute2 ] || mkdir -p /etc/iproute2
  [ -f /etc/iproute2/rt_tables ] || touch /etc/iproute2/rt_tables
  if grep -qsE "^\s*$id\s" /etc/iproute2/rt_tables && ! grep -qsE "^\s*$id\s+$name\s*$" /etc/iproute2/rt_tables; then
    log_err "路由表冲突: ID $id 已被占用但名称不是 $name"; exit 1
  fi
  grep -qxF "$id $name" /etc/iproute2/rt_tables || echo "$id $name" >> /etc/iproute2/rt_tables
}
is_vpn_running() { [ -f "$PID_FILE" ] || return 1; local pid; pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"; [[ "$pid" =~ ^[0-9]+$ ]] || { rm -f "$PID_FILE"; return 1; }; ps -p "$pid" -o comm= 2>/dev/null | grep -q "^openconnect$"; }
_check_port_free() { local port="$1"; ensure_cmd_ss || true; if command -v ss &>/dev/null && ss -lntup 2>/dev/null | grep -q ":${port} "; then return 1; fi; return 0; }

# --- SSH 保护路由 (默认模式使用) ---
setup_ssh_protect_routes() {
  local gw_dev="" gw4="" vps4="" default_ipv6_route="" vps6="" gw6_addr="" gw6_if="" onlink_flag=""
  gw_dev=$("$IP_CMD" route | awk '/^default/ {print $5; exit}')
  gw4=$("$IP_CMD" route | awk '/^default/ {print $3; exit}')
  vps4=$("$IP_CMD" -4 -o addr show dev "$gw_dev" | awk '{print $4}' | cut -d/ -f1 | head -n1)

  check_rt_conflict "$RT4_ID" "$RT4_NAME"
  log "配置 IPv4 策略路由 (SSH保护)..."
  "$IP_CMD" route replace default via "$gw4" dev "$gw_dev" table "$RT4_ID"
  "$IP_CMD" rule del from "$vps4" table "$RT4_ID" priority 500 2>/dev/null || true
  "$IP_CMD" rule add from "$vps4" table "$RT4_ID" priority 500
  log "IPv4 OK (from $vps4)"

  default_ipv6_route=$("$IP_CMD" -6 route | awk '/^default/ && $0 !~ /tun/ {print; exit}' || true)
  vps6=$("$IP_CMD" -6 -o addr show dev "$gw_dev" scope global | awk '{print $4; exit}' | cut -d/ -f1 || true)
  if [ -n "$default_ipv6_route" ] && [ -n "$vps6" ]; then
    gw6_addr=$(echo "$default_ipv6_route" | awk '{print $3}')
    gw6_if=$(echo "$default_ipv6_route" | awk '{print $5}')
    echo "$default_ipv6_route" | grep -q " onlink " && onlink_flag="onlink" || onlink_flag=""
    check_rt_conflict "$RT6_ID" "$RT6_NAME"
    log "配置 IPv6 策略路由 (SSH保护)..."
    "$IP_CMD" -6 route replace default via "$gw6_addr" dev "$gw6_if" $onlink_flag table "$RT6_ID"
    "$IP_CMD" -6 rule del from "$vps6" table "$RT6_ID" priority 500 2>/dev/null || true
    "$IP_CMD" -6 rule add from "$vps6" table "$RT6_ID" priority 500
    log "IPv6 OK (from $vps6)"
  else
    log_info "无可用 IPv6 默认路由或地址，跳过 IPv6 设置"
    vps6="" # 确报 vps6 为空
  fi

  { echo "VPS4=${vps4:-}"; echo "VPS6=${vps6:-}"; } > "$STATE_FILE"
}

# --- Network Namespace 管理 ---
setup_netns() {
  ensure_pkg_iptables
  log_info "正在配置 Network Namespace: ${NETNS_NAME}..."
  
  "$IP_CMD" link del "${VETH_HOST}" 2>/dev/null || true
  "$IP_CMD" netns del "${NETNS_NAME}" 2>/dev/null || true
  
  "$IP_CMD" netns add "${NETNS_NAME}"
  
  log_info "为 Netns 配置 DNS..."
  local netns_dir="/etc/netns/${NETNS_NAME}"
  mkdir -p "$netns_dir"
  [ -r /etc/resolv.conf ] && cp /etc/resolv.conf "$netns_dir/resolv.conf" || echo "nameserver 8.8.8.8" > "$netns_dir/resolv.conf"
  
  "$IP_CMD" link add "${VETH_HOST}" type veth peer name "${VETH_NS}"
  "$IP_CMD" link set "${VETH_HOST}" up
  "$IP_CMD" link set "${VETH_NS}" netns "${NETNS_NAME}"
  "$IP_CMD" addr add "${VETH_HOST_IP}/24" dev "${VETH_HOST}"
  
  "$IP_CMD" netns exec "${NETNS_NAME}" "$IP_CMD" link set lo up
  "$IP_CMD" netns exec "${NETNS_NAME}" "$IP_CMD" link set "${VETH_NS}" up
  "$IP_CMD" netns exec "${NETNS_NAME}" "$IP_CMD" addr add "${VETH_NS_IP}/24" dev "${VETH_NS}"
  "$IP_CMD" netns exec "${NETNS_NAME}" "$IP_CMD" route add default via "${VETH_HOST_IP}"
  
  log_info "启用内核 IP 转发..."
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null

  log_info "为 Netns 出口流量配置 MASQUERADE..."
  local gw_dev; gw_dev=$("$IP_CMD" route | awk '/^default/ {print $5; exit}')
  if [ -n "$gw_dev" ]; then
    local MASQUERADE_RULE="-s ${VETH_SUBNET} ! -o ${VETH_HOST} -j MASQUERADE"
    "$IPTABLES_CMD" -t nat -D POSTROUTING ${MASQUERADE_RULE} 2>/dev/null || true
    "$IPTABLES_CMD" -t nat -A POSTROUTING ${MASQUERADE_RULE}
  else
    log_warn "无法找到默认网关设备，可能无法为 Netns 配置出口 NAT"
  fi
  
  log "Netns 环境已就绪。"
}
cleanup_netns() {
  log_info "正在清理 Network Namespace 的基础设置..."
  
  local MASQUERADE_RULE="-s ${VETH_SUBNET} ! -o ${VETH_HOST} -j MASQUERADE"
  "$IPTABLES_CMD" -t nat -D POSTROUTING ${MASQUERADE_RULE} 2>/dev/null || true
  
  "$IP_CMD" netns del "${NETNS_NAME}" 2>/dev/null || true
  "$IP_CMD" link del "${VETH_HOST}" 2>/dev/null || true
  log "Netns 基础环境已清理。"
}

# --- 账户管理 ---
manage_accounts() {
  [ -f "$ACCOUNTS_FILE" ] || { tee "$ACCOUNTS_FILE" >/dev/null <<'EOT'
# 格式: 显示名|用户名|密码|VPN主机|认证组(可选)
EOT
    chmod 600 "$ACCOUNTS_FILE" || true; }
  while true; do
    clear; title "🔐 管理 VPN 账户 ($ACCOUNTS_FILE)"; sep
    grep -vE '^\s*#|^\s*$' "$ACCOUNTS_FILE" | nl -ba || log_info "  文件为空。"
    sep; echo "  1) 添加  2) 删除  3) 返回"; read -rp "选择 [1-3]: " c
    case "$c" in
      1) read -rp "显示名: " d; read -rp "用户: " u; read -sp "密码: " p; echo; read -rp "主机: " h; read -rp "认证组(可选): " g
         [ -z "$d" ] || [ -z "$u" ] || [ -z "$p" ] || [ -z "$h" ] && { log_err "必填项不能为空"; read -n1 -s -p "按任意键继续"; continue; }
         echo "$d|$u|$p|$h|$g" >> "$ACCOUNTS_FILE"; chmod 600 "$ACCOUNTS_FILE" || true; log "已添加 $d"; read -n1 -s -p "按任意键继续";;
      2) mapfile -t A < <(grep -vE '^\s*#|^\s*$' "$ACCOUNTS_FILE"); [ ${#A[@]} -eq 0 ] && { log_info "无账户"; sleep 1; continue; }
         read -rp "输入要删除的序号: " i; [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] && [ "$i" -le "${#A[@]}" ] || { log_err "无效序号"; continue; }
         grep -vF "${A[$((i-1))]}" "$ACCOUNTS_FILE" > "${ACCOUNTS_FILE}.tmp" && mv "${ACCOUNTS_FILE}.tmp" "$ACCOUNTS_FILE"; log "已删除"; read -n1 -s -p "按任意键继续";;
      3) break;;
      *) log_err "无效选项"; sleep 1;;
    esac
  done
}
select_account() {
  mapfile -t ACC < <(grep -vE '^\s*#|^\s*$' "$ACCOUNTS_FILE")
  [ ${#ACC[@]} -gt 0 ] || { log_err "账户文件为空或无效"; manage_accounts; return 1; }
  log_info "请选择VPN账号："; local i=0; for a in "${ACC[@]}"; do i=$((i+1)); echo "  $i) $(echo "$a" | cut -d'|' -f1)"; done; echo "  99) 返回"
  read -rp "输入序号: " idx; [ "$idx" = "99" ] && return 1
  [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#ACC[@]}" ] || { log_err "无效选择"; return 1; }
  local choice="${ACC[$((idx-1))]}"; export ACCOUNT_INDEX="$((idx-1))"
  export VPN_DESC=$(echo "$choice" | cut -d'|' -f1)
  export VPN_USER=$(echo "$choice" | cut -d'|' -f2)
  export VPN_PASS=$(echo "$choice" | cut -d'|' -f3)
  export VPN_HOST=$(echo "$choice" | cut -d'|' -f4)
  export VPN_GROUP=$(echo "$choice" | cut -d'|' -f5)
  log_info "已加载: $VPN_DESC"
}
_load_account_by_index() {
  local idx="$1"; mapfile -t ACC < <(grep -vE '^\s*#|^\s*$' "$ACCOUNTS_FILE")
  [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -lt "${#ACC[@]}" ] || { log_err "无效账户索引: $idx"; exit 1; }
  local choice="${ACC[$idx]}"; export ACCOUNT_INDEX="$idx"
  export VPN_DESC=$(echo "$choice" | cut -d'|' -f1); export VPN_USER=$(echo "$choice" | cut -d'|' -f2);
  export VPN_PASS=$(echo "$choice" | cut -d'|' -f3); export VPN_HOST=$(echo "$choice" | cut -d'|' -f4);
  export VPN_GROUP=$(echo "$choice" | cut -d'|' -f5);
}

# --- 启动/停止核心逻辑 ---
_execute_with_safety_net() {
  local func_to_run="$1"
  trap cleanup_on_interrupt SIGINT
  check_atd
  local job; job=$(echo "$SCRIPT_PATH stop" | at now + 2 分钟之前 2>&1 | awk '/job/{print $2}' || echo "none")
  [ "$job" != "none" ] && log_warn "已设保底清理任务 (Job $job), 2分钟内连接失败将自动回滚。"

  if "$func_to_run"; then
    trap - SIGINT # 成功后解除陷阱
    [ "$job" != "none" ] && atrm "$job" && log "连接稳定, 已取消保底任务"
    show_status
  else
    trap - SIGINT # 失败后解除陷阱
    log_err "启动过程失败，请检查日志。"
    stop_vpn # 确保在函数内部失败时也执行清理
  fi
}

start_default() { is_vpn_running && { log_err "VPN 已在运行"; return; }; ensure_pkg_openconnect; select_account || return; _execute_with_safety_net "_start_default_logic"; }
_start_default_logic() {
  setup_ssh_protect_routes
  { echo "MODE=default"; echo "ACCOUNT_INDEX=$ACCOUNT_INDEX"; } | tee -a "$STATE_FILE" >/dev/null
  log_info "连接VPN [默认模式]: $VPN_HOST ..."
  local oc_cmd=("openconnect" "$VPN_HOST" --protocol=anyconnect --user="$VPN_USER" --passwd-on-stdin -b --pid-file="$PID_FILE")
  [ -n "$VPN_GROUP" ] && oc_cmd+=("--authgroup=$VPN_GROUP")
  echo "$VPN_PASS" | "${oc_cmd[@]}"
  log_info "等待 TUN 接口就绪..."; for ((i=0;i<15;i++)); do if is_vpn_running && ip link show 2>/dev/null | grep -q 'tun.*UP'; then log "VPN 连接成功 (PID=$(cat "$PID_FILE"))"; return 0; fi; sleep 1; done
  log_err "VPN 连接失败或超时"; return 1
}

start_ocproxy_mode() { is_vpn_running && { log_err "VPN 已在运行"; return; }; ensure_pkg_ocproxy; select_account || return; _execute_with_safety_net "_start_ocproxy_logic"; }
_start_ocproxy_logic() {
  local socks_port
  local listen_addr="127.0.0.1" # [Final] 简化: 默认且仅监听本地，移除远程选项
  while true;do read -rp "请输入SOCKS5监听端口 (e.g. 1080): " socks_port; [[ "$socks_port" =~ ^[0-9]+$ ]]&&[ "$socks_port" -ge 1 ]&&[ "$socks_port" -le 65535 ]||{ log_err "端口无效";continue; }; _check_port_free "$socks_port"||{ log_err "端口已被占用";continue; }; break; done
  
  log_info "正在启动 ocproxy 模式 (监听地址: $listen_addr)...";
  # [Final] 简化: 移除了无效的 allow_arg 变量
  local oc_cmd=("openconnect" "$VPN_HOST" --protocol=anyconnect --user="$VPN_USER" --passwd-on-stdin --script-tun --script "ocproxy -k 30 -D $socks_port" -b --pid-file="$PID_FILE")
  [ -n "$VPN_GROUP" ] && oc_cmd+=("--authgroup=$VPN_GROUP")
  echo "$VPN_PASS" | "${oc_cmd[@]}"
  
  log_info "等待 ocproxy 启动..."; for ((i=0;i<10;i++)); do if is_vpn_running; then log "ocproxy 连接成功 (PID=$(cat "$PID_FILE"))"; echo "MODE=ocproxy">"$STATE_FILE";echo "ACCOUNT_INDEX=$ACCOUNT_INDEX" >> "$STATE_FILE";echo "SOCKS_PORT=$socks_port" >> "$STATE_FILE";echo "LISTEN_ADDR=$listen_addr" >> "$STATE_FILE"; return 0; fi; sleep 1; done
  log_err "ocproxy 连接失败或超时"; return 1
}

start_netns_mode() {
  is_vpn_running && { log_err "VPN 已在运行"; return; }
  ensure_cmd_gost || return
  ensure_cmd_socat || true # 即使 socat 安装失败也继续，使用 iptables
  select_account || return
  _execute_with_safety_net "_start_netns_logic"
}
_start_netns_logic() {
  local socks_port
  while true;do read -rp "请输入SOCKS5监听端口 (e.g. 8585): " socks_port; [[ "$socks_port" =~ ^[0-9]+$ ]]&&[ "$socks_port" -ge 1 ]&&[ "$socks_port" -le 65535 ]||{ log_err "端口无效";continue; }; _check_port_free "$socks_port" || { log_err "端口已被占用"; continue; }; break; done
  
  local listen_addr="127.0.0.1"
  read -rp "是否允许远程连接 (监听 0.0.0.0)? [y/N]: " yn
  if [[ "$yn" =~ ^[yY]$ ]]; then
    listen_addr="0.0.0.0"
  fi
  
  setup_netns
  
  log_info "正在 Netns 中启动 OpenConnect...";
  local oc_cmd=("openconnect" "$VPN_HOST" --protocol=anyconnect --user="$VPN_USER" --passwd-on-stdin -b --pid-file="$PID_FILE")
  [ -n "$VPN_GROUP" ] && oc_cmd+=("--authgroup=$VPN_GROUP")
  echo "$VPN_PASS" | "$IP_CMD" netns exec "${NETNS_NAME}" "${oc_cmd[@]}"
  
  log_info "等待 OpenConnect 建立 TUN 接口...";
  for ((i=0; i<20; i++)); do
    if [ -f "$PID_FILE" ] && "$IP_CMD" netns pids "${NETNS_NAME}" | grep -qF "$(cat "$PID_FILE")" && \
       "$IP_CMD" netns exec "${NETNS_NAME}" ip link show 2>/dev/null | grep -q 'tun.*UP'; then
      log "OpenConnect TUN 接口已就绪 (PID=$(cat "$PID_FILE"))"; sleep 2; break
    fi
    sleep 1
  done
  
  if ! "$IP_CMD" netns exec "${NETNS_NAME}" ip link show 2>/dev/null | grep -q 'tun.*UP'; then
    log_err "OpenConnect 在 Netns 中启动失败或 TUN 接口未能正常启动"; return 1
  fi

  log_info "测试 Netns 内通过 VPN 的 IPv4 网络连通性...";
  if "$IP_CMD" netns exec "${NETNS_NAME}" ping -c 1 -W 4 8.8.8.8 >/dev/null 2>&1; then
    log "Netns 内 VPN IPv4 网络连通性正常"
  else
    log_warn "Netns 内 VPN IPv4 网络连通性测试失败，但仍将继续..."
  fi
  
  test_netns_ipv6 || true

  log_info "正在 Netns 中启动 SOCKS5 服务 (gost)..."
  "$IP_CMD" netns exec "${NETNS_NAME}" gost -L="socks5://0.0.0.0:${socks_port}" >/dev/null 2>&1 &
  local gost_pid=$!; echo "$gost_pid" > "$GOST_PID_FILE"
  sleep 1; if ! kill -0 "$gost_pid" 2>/dev/null; then log_err "gost 在 Netns 中启动失败"; return 1; fi
  log "SOCKS5 服务 (gost) 已在 Netns 中启动 (PID: $gost_pid)"
  
  log_info "配置主机到 Netns 的端口转发..."
  local forwarder_mode="" RULE_DNAT_PREROUTING="" RULE_DNAT_OUTPUT="" RULE_FORWARD="" socat_pid_v4="" socat_pid_v6=""
  if command -v socat &>/dev/null; then
    socat TCP4-LISTEN:"${socks_port}",bind="${listen_addr}",fork,reuseaddr TCP4:"${VETH_NS_IP}:${socks_port}" >/dev/null 2>&1 &
    socat_pid_v4=$!; echo "$socat_pid_v4" > "$SOCAT_PID_FILE"
    
    if [[ "$listen_addr" == "0.0.0.0" ]] || [[ "$listen_addr" == "::" ]]; then
      socat TCP6-LISTEN:"${socks_port}",ipv6only=1,fork,reuseaddr TCP4:"${VETH_NS_IP}:${socks_port}" >/dev/null 2>&1 &
      socat_pid_v6=$!; echo "$socat_pid_v6" > "$SOCAT_PID_FILE_V6"
      log "使用 socat 完成端口转发 (IPv4 PID: $socat_pid_v4, IPv6 PID: $socat_pid_v6)"
    else
      log "使用 socat 完成端口转发 (PID: $socat_pid_v4)"
    fi
    forwarder_mode="socat"
  else
    log_info "socat 未找到, 使用 iptables DNAT 作为备用方案。"
    RULE_DNAT_PREROUTING="-p tcp --dport ${socks_port} -j DNAT --to-destination ${VETH_NS_IP}:${socks_port}"
    [ "$listen_addr" != "0.0.0.0" ] && RULE_DNAT_PREROUTING="-p tcp -d ${listen_addr} --dport ${socks_port} -j DNAT --to-destination ${VETH_NS_IP}:${socks_port}"
    RULE_DNAT_OUTPUT="-p tcp -o lo --dport ${socks_port} -j DNAT --to-destination ${VETH_NS_IP}:${socks_port}"
    RULE_FORWARD="-i ${VETH_HOST} -d ${VETH_NS_IP} -p tcp --dport ${socks_port} -j ACCEPT"
    
    "$IPTABLES_CMD" -t nat -A PREROUTING ${RULE_DNAT_PREROUTING}
    "$IPTABLES_CMD" -t nat -A OUTPUT ${RULE_DNAT_OUTPUT}
    "$IPTABLES_CMD" -A FORWARD ${RULE_FORWARD}
    log "使用 iptables 完成端口转发"
    forwarder_mode="iptables"
  fi
  
  {
    echo "MODE=netns"; echo "ACCOUNT_INDEX=$ACCOUNT_INDEX"; echo "SOCKS_PORT=$socks_port";
    echo "LISTEN_ADDR=$listen_addr"; echo "GOST_PID=$gost_pid"; echo "FORWARDER=${forwarder_mode}";
    [ -n "$socat_pid_v4" ] && echo "SOCAT_PID=${socat_pid_v4}";
    [ -n "$socat_pid_v6" ] && echo "SOCAT_PID_V6=${socat_pid_v6}";
    [ "$forwarder_mode" = "iptables" ] && {
      echo "RULE_DNAT_PREROUTING='${RULE_DNAT_PREROUTING}'"
      echo "RULE_DNAT_OUTPUT='${RULE_DNAT_OUTPUT}'"
      echo "RULE_FORWARD='${RULE_FORWARD}'"
    }
  } > "$STATE_FILE"
  
  return 0
}

# --- 停止与清理 ---
cleanup_ssh_protect_routes() {
  local vps4="" vps6=""
  if [ -f "$STATE_FILE" ]; then
    log_info "🔍 从状态文件加载路由信息进行精确清理..."
    vps4=$(grep '^VPS4=' "$STATE_FILE" | cut -d'=' -f2)
    vps6=$(grep '^VPS6=' "$STATE_FILE" | cut -d'=' -f2)
  else
    log_warn "未找到状态文件，将尝试通用清理。"
  fi

  [ -n "$vps4" ] && { "$IP_CMD" rule del from "$vps4" table "$RT4_NAME" priority 500 2>/dev/null || true; log "已尝试清理 IPv4 规则 (from $vps4)"; }
  [ -n "$vps6" ] && { "$IP_CMD" -6 rule del from "$vps6" table "$RT6_NAME" priority 500 2>/dev/null || true; log "已尝试清理 IPv6 规则 (from $vps6)"; }
  
  log_info "🧹 正在清理所有指向 $RT4_NAME 和 $RT6_NAME 的残留规则..."
  while "$IP_CMD" rule del table "$RT4_NAME" 2>/dev/null; do log "  -> 清理了一条孤立 IPv4 规则"; done
  while "$IP_CMD" -6 rule del table "$RT6_NAME" 2>/dev/null; do log "  -> 清理了一条孤立 IPv6 规则"; done

  "$IP_CMD" route flush table "$RT4_ID" 2>/dev/null || true
  "$IP_CMD" -6 route flush table "$RT6_ID" 2>/dev/null || true
  log "✅ 策略路由已彻底清理"
}

stop_vpn() {
  if ! is_vpn_running && ! [ -f "$GOST_PID_FILE" ] && ! [ -f "$SOCAT_PID_FILE" ]; then log_info "VPN 未运行"; return; fi
  log_info "正在停止VPN并清理环境...";
  local MODE; [ -f "$STATE_FILE" ] && MODE=$(grep '^MODE=' "$STATE_FILE" | cut -d'=' -f2)

  case "${MODE:-unknown}" in
    netns)
      log_info "正在停止 netns 模式..."
      if [ -f "$STATE_FILE" ]; then
        . "$STATE_FILE" 2>/dev/null || true
        if [ "${FORWARDER:-}" = "socat" ]; then
          [ -f "$SOCAT_PID_FILE" ] && kill "$(cat "$SOCAT_PID_FILE")" 2>/dev/null || true
          [ -f "$SOCAT_PID_FILE_V6" ] && kill "$(cat "$SOCAT_PID_FILE_V6")" 2>/dev/null || true
        elif [ "${FORWARDER:-}" = "iptables" ]; then
          log_info "清理 Netns 的 iptables 转发规则..."
          [ -n "${RULE_DNAT_PREROUTING:-}" ] && eval "\$IPTABLES_CMD -t nat -D PREROUTING ${RULE_DNAT_PREROUTING}" 2>/dev/null
          [ -n "${RULE_DNAT_OUTPUT:-}" ]   && eval "\$IPTABLES_CMD -t nat -D OUTPUT ${RULE_DNAT_OUTPUT}" 2>/dev/null
          [ -n "${RULE_FORWARD:-}" ]       && eval "\$IPTABLES_CMD -D FORWARD ${RULE_FORWARD}" 2>/dev/null
        fi
      fi
      [ -f "$GOST_PID_FILE" ] && kill "$(cat "$GOST_PID_FILE")" 2>/dev/null || true
      [ -f "$PID_FILE" ] && kill "$(cat "$PID_FILE")" 2>/dev/null || true
      cleanup_netns
      ;;
    default|ocproxy)
      log_info "正在停止 ${MODE} 模式..."
      if [ -f "$PID_FILE" ]; then kill "$(cat "$PID_FILE")" 2>/dev/null || true; fi
      [ "$MODE" = "default" ] && cleanup_ssh_protect_routes
      ;;
    *)
      log_warn "状态文件不存在或模式未知，执行通用清理..."
      [ -f "$PID_FILE" ] && kill "$(cat "$PID_FILE")" 2>/dev/null || true
      [ -f "$GOST_PID_FILE" ] && kill "$(cat "$GOST_PID_FILE")" 2>/dev/null || true
      [ -f "$SOCAT_PID_FILE" ] && kill "$(cat "$SOCAT_PID_FILE")" 2>/dev/null || true
      [ -f "$SOCAT_PID_FILE_V6" ] && kill "$(cat "$SOCAT_PID_FILE_V6")" 2>/dev/null || true
      cleanup_ssh_protect_routes
      cleanup_netns
      ;;
  esac
  
  rm -f "$PID_FILE" "$STATE_FILE" "$GOST_PID_FILE" "$SOCAT_PID_FILE" "$SOCAT_PID_FILE_V6"; log "所有临时文件已清理，操作完成。"
}

# --- 状态显示 ---
show_status() {
  local ip_provider="ip.p3terx.com"; local curl_opts=(-s -A "Mozilla/5.0" --connect-timeout 4 --max-time 8)
  sep
  if ! is_vpn_running && ! [ -f "$GOST_PID_FILE" ] && ! [ -f "$SOCAT_PID_FILE" ]; then
    title "  VPN 状态: ${C_RED}🔴 停止${C_RESET}"
    echo -e "    ${C_BOLD}本机公网 IPv4:${C_RESET} $($CURL_CMD -4 "${curl_opts[@]}" "$ip_provider" | head -n1 || echo "查询失败")"
    echo -e "    ${C_BOLD}本机公网 IPv6:${C_RESET} $($CURL_CMD -6 "${curl_opts[@]}" "$ip_provider" | head -n1 || echo "无/查询失败")"
  else
    local ACCOUNT_INDEX MODE SOCKS_PORT LISTEN_ADDR; [ -f "$STATE_FILE" ] && . "$STATE_FILE" 2>/dev/null || true
    title "  VPN 状态: ${C_GREEN}🟢 运行中${C_RESET} (OpenConnect PID: $(cat "$PID_FILE" 2>/dev/null || echo N/A))"
    if [ -n "${ACCOUNT_INDEX:-}" ]; then mapfile -t A < <(grep -vE '^\s*#|^\s*$' "$ACCOUNTS_FILE"); [ "$ACCOUNT_INDEX" -lt "${#A[@]}" ] && echo -e "    ${C_BOLD}使用账户:${C_RESET} $(echo "${A[$ACCOUNT_INDEX]}" | cut -d'|' -f1)"; fi
    
    case "${MODE:-}" in
      default)
        echo -e "    ${C_BOLD}运行模式:${C_RESET} 🛡️  默认全局模式"
        echo -e "    ${C_BOLD}VPN 出口 IPv4:${C_RESET} ${C_YELLOW}$($CURL_CMD -4 "${curl_opts[@]}" "$ip_provider"|head -n1||echo 失败)${C_RESET}"
        echo -e "    ${C_BOLD}VPN 出口 IPv6:${C_RESET} ${C_YELLOW}$($CURL_CMD -6 "${curl_opts[@]}" "$ip_provider"|head -n1||echo 无/失败)${C_RESET}"
      ;;
      ocproxy)
        echo -e "    ${C_BOLD}运行模式:${C_RESET} 🔌 ocproxy 代理 ${C_GREY}(仅 IPv4)${C_RESET}"
        echo -e "    ${C_BOLD}SOCKS 地址:${C_RESET} ${LISTEN_ADDR:-127.0.0.1}:${SOCKS_PORT}"
        local sip4; sip4=$($CURL_CMD -x "socks5h://127.0.0.1:${SOCKS_PORT}" -4 "${curl_opts[@]}" "$ip_provider"|head -n1||echo "查询失败")
        echo -e "    ${C_BOLD}SOCKS 出口 IPv4:${C_RESET} ${C_YELLOW}${sip4}${C_RESET}"
        echo -e "    ${C_BOLD}本机公网 IPv4:${C_RESET} $($CURL_CMD -4 "${curl_opts[@]}" "$ip_provider"|head -n1||echo 失败)"
      ;;
      netns)
        echo -e "    ${C_BOLD}运行模式:${C_RESET} 🌐 Network Namespace 代理 ${C_GREEN}(IPv4+IPv6)${C_RESET}"
        local f_info; if [[ "${FORWARDER:-}" == "socat" ]]; then f_info="socat"; else f_info="iptables"; fi
        echo -e "    ${C_BOLD}SOCKS 地址:${C_RESET} ${LISTEN_ADDR}:${SOCKS_PORT} ${C_GREY}(gost PID: $(cat "$GOST_PID_FILE" 2>/dev/null), by ${f_info})${C_RESET}"
        
        local socks_proxy="socks5h://127.0.0.1:${SOCKS_PORT}"
        local curl_opts_socks=(-s -A "Mozilla/5.0" --connect-timeout 8 --max-time 15)
        
        local sip4; sip4=$($CURL_CMD -x "$socks_proxy" -4 "${curl_opts_socks[@]}" "$ip_provider" 2>/dev/null | head -n1 || echo "查询失败")
        echo -e "    ${C_BOLD}SOCKS 出口 IPv4:${C_RESET} ${C_YELLOW}${sip4}${C_RESET}"
        
        local sip6="";
        sip6=$($CURL_CMD -x "$socks_proxy" -6 "${curl_opts_socks[@]}" "$ip_provider" 2>/dev/null | head -n1 || echo "")
        
        if [ -z "$sip6" ] || [[ "$sip6" == *"查询失败"* ]]; then
          sip6=$($CURL_CMD -x "$socks_proxy" -6 "${curl_opts_socks[@]}" "https://api64.ipify.org" 2>/dev/null || echo "")
        fi
        
        if [ -z "$sip6" ] && [ -n "${NETNS_NAME:-}" ]; then
          sip6=$("$IP_CMD" netns exec "${NETNS_NAME}" curl -6 -s --connect-timeout 5 --max-time 10 "$ip_provider" 2>/dev/null | head -n1 || echo "")
          [ -n "$sip6" ] && sip6="${sip6} ${C_GREY}(Netns内检测)${C_RESET}"
        fi
        
        if [ -n "$sip6" ] && [[ "$sip6" != *"查询失败"* ]]; then
          echo -e "    ${C_BOLD}SOCKS 出口 IPv6:${C_RESET} ${C_YELLOW}${sip6}${C_RESET}"
        else
          echo -e "    ${C_BOLD}SOCKS 出口 IPv6:${C_RESET} ${C_YELLOW}检测超时或不可用${C_RESET}"
        fi
        
        echo -e "    ${C_BOLD}本机公网 IPv4:${C_RESET} $($CURL_CMD -4 "${curl_opts[@]}" "$ip_provider" 2>/dev/null | head -n1 || echo 失败)"
      ;;
      *) echo "    ${C_BOLD}运行模式:${C_RESET} 未知";;
    esac
  fi
  sep
}

# --- 定时与卸载 ---
manage_cron() {
  while true; do
    clear; title "🗓️ 定时/守护任务"; sep
    crontab -l 2>/dev/null | grep "$SCRIPT_PATH" || log_info "  当前无此脚本的定时任务。"
    sep
    echo -e "  1) 设置守护任务 (每5分钟检查，断线重连)"
    echo -e "  2) 添加定时关闭任务"
    echo -e "  3) 清除所有此脚本相关的定时任务"
    echo -e "  4) 返回主菜单"
    read -rp "请选择 [1-4]: " c
    case "$c" in
      1) log_warn "守护任务目前仅支持 [默认] 和 [ocproxy] 模式。"
         (crontab -l 2>/dev/null | grep -v "_internal_check_health" || true) | { cat; echo "*/5 * * * * $SCRIPT_PATH _internal_check_health"; } | crontab -
         log "已设置守护任务。";;
      2) read -rp "请输入 cron 表达式 (例如 '0 2 * * *' 代表每天凌晨2点): " exp
         [ -z "$exp" ] && { log_err "表达式不能为空"; } || { (crontab -l 2>/dev/null || true; echo "$exp $SCRIPT_PATH stop") | crontab -; log "已添加定时关闭任务。"; };;
      3) crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab - 2>/dev/null || true; log "已清除所有相关定时任务。";;
      4) break;;
      *) log_err "无效选项";;
    esac; read -n1 -s -p $'\n'"按任意键返回..."
  done
}

uninstall() {
  read -rp "⚠️  确认要卸载此脚本及其所有相关配置吗？[y/N]: " y; [[ "$y" =~ ^[yY]$ ]] || { log_info "已取消"; exit 0; }
  log_info "开始卸载..."; stop_vpn
  crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab - 2>/dev/null || true; log "定时任务已清理"
  
  if command -v gost &>/dev/null; then
    read -rp "是否卸载 gost? (由 Netns 模式自动安装) [Y/n]: " yn_gost
    if [[ ! "$yn_gost" =~ ^[nN]$ ]]; then
      log_info "正在尝试使用官方脚本卸载 gost..."
      if command -v curl &>/dev/null; then
         bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --remove || log_warn "gost 卸载脚本执行失败。"
      else
         log_warn "curl 命令不存在，尝试直接删除 gost 文件..."; rm -f /usr/local/bin/gost
      fi; log "gost 已尝试卸载。"
    fi
  fi
  
  if command -v socat &>/dev/null; then
    read -rp "是否卸载 socat? (由 Netns 模式自动安装) [Y/n]: " yn_socat
    if [[ ! "$yn_socat" =~ ^[nN]$ ]]; then
      if command -v apt-get &>/dev/null; then apt-get purge -y socat >/dev/null || true
      elif command -v yum &>/dev/null; then yum remove -y socat >/dev/null || true
      elif command -v dnf &>/dev/null; then dnf remove -y socat >/dev/null || true; fi
      log "socat 已尝试卸载。"
    fi
  fi

  read -rp "是否卸载 OpenConnect 和 ocproxy 软件包? [y/N]: " yn_oc
  if [[ "$yn_oc" =~ ^[yY]$ ]]; then
    if command -v apt-get &>/dev/null; then apt-get purge -y openconnect ocproxy >/dev/null || true
    elif command -v yum &>/dev/null; then yum remove -y openconnect ocproxy >/dev/null || true
    elif command -v dnf &>/dev/null; then dnf remove -y openconnect ocproxy >/dev/null || true; fi
    log "OpenConnect/ocproxy 已尝试卸载。"
  fi
  
  rm -f "$ACCOUNTS_FILE"; log "账户文件已删除"
  log_info "正在删除脚本文件: $SCRIPT_PATH"; rm -f "$SCRIPT_PATH"; log "卸载完成，再见！"
}

_internal_cron_handler() {
  local a="$1"; shift; check_root
  case "$a" in
    _internal_check_health)
      if ! is_vpn_running && [ -f "$STATE_FILE" ]; then
        log_info "守护进程: 检测到连接断开, 正在尝试自动重连..."; 
        . "$STATE_FILE"; _load_account_by_index "${ACCOUNT_INDEX}"
        case "${MODE:-}" in
          default) _start_default_logic ;;
          ocproxy) _start_ocproxy_logic ;;
          netns) log_err "守护进程: Netns 模式尚不支持自动重连，已跳过。";;
          *) log_err "守护进程: 未知的恢复模式, 无法重连";;
        esac
      fi;;
    *) log_err "内部 cron 调用错误: '$a'";;
  esac
}

# --- 主菜单 ---
main_menu() {
  clear
  echo -e "${C_BOLD}========================================================${C_RESET}"
  echo -e "${C_BOLD}  🚀 OpenConnect Master Manager v7.7.7 (Final) 🚀${C_RESET}"
  echo -e "${C_BOLD}========================================================${C_RESET}"
  show_status
  title "主菜单:"
  echo -e "  ${C_GREEN}1) 启动: 🛡️  默认模式 (全局VPN, 保护SSH)${C_RESET}"
  echo -e "  ${C_GREEN}2) 启动: 🔌 ocproxy 模式 (SOCKS5, 仅IPv4)${C_RESET}"
  echo -e "  ${C_GREEN}3) 启动: 🌐 Netns 模式 (SOCKS5, IPv4+IPv6 全功能)${C_RESET}"
  echo -e "  ${C_RED}4) 停止 VPN${C_RESET}"
  sep
  echo -e "  5) ⚙️  管理 VPN 账户"
  echo -e "  6) 🗓️  设置定时/守护任务"
  echo -e "  7) 📦 检查/安装依赖"
  echo -e "  8) 🧪 ${C_CYAN}测试 Netns IPv6 连通性${C_RESET}"
  echo -e "  9) 🗑️  卸载"
  echo -e "  0) 🚪 退出"
  echo
  read -rp "请选择 [0-9]: " c
  case "$c" in
    1) start_default || true;;
    2) start_ocproxy_mode || true;;
    3) start_netns_mode || true;;
    4) stop_vpn || true;;
    5) manage_accounts;;
    6) manage_cron;;
    7) ensure_pkg_openconnect; ensure_pkg_ocproxy; ensure_cmd_gost || true; ensure_cmd_socat || true;;
    8) if [ -f "$STATE_FILE" ] && grep -q "MODE=netns" "$STATE_FILE"; then
         test_netns_ipv6 || true
       else
         log_err "Netns 模式未运行，无法测试"
       fi;;
    9) uninstall; exit 0;;
    0) exit 0;;
    *) log_err "无效选项 '$c'";;
  esac
  [[ "$c" =~ ^[1-4,7,8]$ ]] && read -n1 -s -p $'\n'"按任意键返回主菜单..."
}

# --- 脚本入口 ---
case "${1:-main}" in
  _internal_*) _internal_cron_handler "$@"; exit 0 ;;
  stop) check_root; stop_vpn; exit 0 ;;
  main|*) check_root; while true; do main_menu; done ;;
esac
