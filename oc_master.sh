#!/bin/bash
# =================================================================
#   OpenConnect Master Manager - v7.7.7 (Final)
#   - 定稿: 简化 ocproxy 模式，移除远程连接选项，默认监听本地。
#   - 修复(Netns): 增强 show_status 中的 IPv6 检测，通过多种方式(增加超时、
#     备用检测点、netns内部直连)提高检测成功率。
#   - 增强(Netns): socat 转发支持 IPv4 和 IPv6 双栈监听。
#   - 新增(Netns): 启动时和菜单中增加 IPv6 连通性主动测试功能。
#   - 新增: OpenConnect 协议选择，支持 AnyConnect / Pulse(Ivanti) / NC(Juniper)。
#   - 移除(Netns): iptables DNAT 备用转发（实测在 netns 全局 VPN 下回包被吸进 tun、
#     数据面不通），socat 改为必需；旧 state 的规则清理保留兼容。
#   - 改进: ocm 快捷命令改为启动时自动安装、状态区显示（不再占一个菜单项）；
#     主菜单改为两列紧凑排版，状态区合并为紧凑行。
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
SHORTCUT_PATH="/usr/local/bin/ocm"
# 依赖标记：只记录"由本脚本安装"的依赖。卸载时据此区分——脚本装的默认删，
# 用户自己装的默认保留并提醒，避免顺手删掉别的用途在用的东西。
# 老版本升上来的机器没有这个文件，于是所有依赖都算"用户自己的"（偏保守）。
DEPS_STATE_DIR="/var/lib/oc-master"
DEPS_MARK_FILE="${DEPS_STATE_DIR}/installed-deps"

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

# 终端显示宽度：非 ASCII（中文等）按 2 列计，用于两列菜单对齐。
# 显式指定 UTF-8 locale——脚本可能被 cron 或没有 LANG 的环境调用，
# 那时 wc -m 会退化成字节数，宽度算错、菜单就会歪。
_disp_w() {
  local s="$1" c b
  c=$(printf '%s' "$s" | LC_ALL=C.UTF-8 wc -m)
  b=$(printf '%s' "$s" | LC_ALL=C wc -c)
  echo $(( c + (b - c) / 2 ))
}
_pad() { # 左对齐补空格到 N 列（末尾必须 return 0：本函数会作为 AND 列表的末尾被调用）
  local s="$1" w="$2" cur
  cur=$(_disp_w "$s")
  printf '%s' "$s"
  [ "$cur" -lt "$w" ] && printf '%*s' "$(( w - cur ))" ''
  return 0
}

# --- ocm 快捷命令 ---
# 用符号链接而不是拷贝：脚本自身用 readlink -f "$0" 解析真实路径，所以从
# /usr/local/bin/ocm 调用时行为完全一致（菜单、ocm stop、_internal_* 都照常）。
# 只接管"已经指向本脚本"的链接；同名真实文件一律不覆盖。
install_shortcut() {
  local quiet="${1:-}"
  local current=""
  if [ -L "$SHORTCUT_PATH" ]; then
    current="$(readlink -f "$SHORTCUT_PATH" 2>/dev/null || true)"
    if [ "$current" = "$SCRIPT_PATH" ]; then
      [ -n "$quiet" ] || log "快捷命令已就绪：${SHORTCUT_PATH}"
      return 0
    fi
    log_err "${SHORTCUT_PATH} 已是指向别处的符号链接（${current:-未知}），拒绝覆盖。"
    return 1
  fi
  if [ -e "$SHORTCUT_PATH" ]; then
    log_err "${SHORTCUT_PATH} 已存在且不是符号链接，拒绝覆盖。"
    return 1
  fi
  # 符号链接要求目标本身可执行。正常安装流程里已经 chmod +x，但若脚本是被人用
  # `bash oc_master.sh` 跑起来的，执行位可能还没加上，这里补一次。
  [ -x "$SCRIPT_PATH" ] || chmod +x "$SCRIPT_PATH" 2>/dev/null || true
  if [ ! -x "$SCRIPT_PATH" ]; then
    log_err "脚本没有执行权限，快捷命令不会生效：${SCRIPT_PATH}"
    return 1
  fi
  ln -s "$SCRIPT_PATH" "$SHORTCUT_PATH" || { log_err "创建快捷命令失败：${SHORTCUT_PATH}"; return 1; }
  log "已安装快捷命令：${SHORTCUT_PATH} -> ${SCRIPT_PATH}"
  log_info "以后可直接使用： ocm   或   ocm stop"
}

remove_shortcut() {
  local current=""
  [ -L "$SHORTCUT_PATH" ] || return 0
  current="$(readlink -f "$SHORTCUT_PATH" 2>/dev/null || true)"
  [ "$current" = "$SCRIPT_PATH" ] && { rm -f "$SHORTCUT_PATH"; log "已移除快捷命令 ${SHORTCUT_PATH}"; }
  return 0
}

# 脚本启动时自动确保快捷命令就绪（不再占用一个菜单项）。三种情况不动：
#   - 脚本本身在 /tmp 等临时目录（下载后还没移动、或正在测试）→ 不建指向临时文件的链接
#   - 同名实体文件、或指向别处的符号链接 → 可能是别的程序的，绝不覆盖
# 只有"悬空链接"会被接管：那是本脚本被移动/删除后留下的残骸。
_ensure_shortcut() {
  local tgt=""
  case "$SCRIPT_PATH" in /tmp/*|/var/tmp/*) return 0 ;; esac
  if [ -L "$SHORTCUT_PATH" ]; then
    tgt="$(readlink -f "$SHORTCUT_PATH" 2>/dev/null || true)"
    [ -n "$tgt" ] && return 0
    rm -f "$SHORTCUT_PATH" 2>/dev/null || return 0
  elif [ -e "$SHORTCUT_PATH" ]; then
    return 0
  fi
  install_shortcut quiet >/dev/null 2>&1 || true
  return 0
}

# 主菜单状态区用的一行摘要（纯文本，颜色由调用处套）
_shortcut_state() {
  local tgt="" base=""
  if [ -L "$SHORTCUT_PATH" ]; then
    tgt="$(readlink -f "$SHORTCUT_PATH" 2>/dev/null || true)"
    if [ "$tgt" = "$SCRIPT_PATH" ]; then echo "ocm ✓"
    elif [ -n "$tgt" ]; then base="$(basename "$tgt")"; echo "ocm → ${base}"
    else echo "ocm 悬空链接"; fi
  elif [ -e "$SHORTCUT_PATH" ]; then
    echo "ocm 非本脚本链接"
  else
    echo "ocm 未安装"
  fi
  return 0
}

# --- 中断处理 ---
cleanup_on_interrupt() {
  log_err "\n操作被用户中断 (Ctrl+C)。正在紧急清理..."
  stop_vpn
  exit 1
}

# --- 依赖检查 ---
_mark_dep_installed() {
  local name="$1"
  mkdir -p "$DEPS_STATE_DIR" 2>/dev/null || return 0
  if ! grep -qxF "$name" "$DEPS_MARK_FILE" 2>/dev/null; then
    echo "$name" >> "$DEPS_MARK_FILE" 2>/dev/null || true
  fi
  return 0
}
# 0 = 这个依赖是本脚本装的；非 0 = 本来就有（或标记文件不存在）
_dep_installed_by_us() { grep -qxF "$1" "$DEPS_MARK_FILE" 2>/dev/null; }

# 可卸载的依赖：标记名|命令|用途。iptables/iproute2 属于系统基础件，不列入。
_DEPS_LIST=(
  "openconnect|openconnect|VPN 客户端（三种模式都要）"
  "ocproxy|ocproxy|ocproxy 模式"
  "gost|gost|Netns 模式的 SOCKS5 服务端"
  "socat|socat|Netns 模式的端口转发（首选；缺失时自动改用 iptables 双 NAT）"
)

# 菜单 7：先扫描现状，再决定装什么
show_deps() {
  local entry name cmd desc state
  title "📦 依赖状态:"
  for entry in "${_DEPS_LIST[@]}"; do
    IFS='|' read -r name cmd desc <<< "$entry"
    if command -v "$cmd" &>/dev/null; then
      if _dep_installed_by_us "$name"; then
        state="${C_GREEN}✔ 已安装${C_RESET} ${C_GREY}(本脚本安装，卸载时可安全删除)${C_RESET}"
      else
        state="${C_GREEN}✔ 已安装${C_RESET} ${C_YELLOW}(你自己装的，卸载时默认保留)${C_RESET}"
      fi
    else
      state="${C_RED}✘ 缺失${C_RESET}"
    fi
    # 注意用 echo -e：颜色变量里存的是字面 \033[...m，printf 的 %s 不会解释转义
    printf '  %-12s ' "$name"
    echo -e "${desc}  ${state}"
  done
  sep
}
manage_deps() {
  show_deps
  local entry name cmd desc todo=() ans
  for entry in "${_DEPS_LIST[@]}"; do
    IFS='|' read -r name cmd desc <<< "$entry"
    command -v "$cmd" &>/dev/null || todo+=("$entry")
  done
  if [ ${#todo[@]} -eq 0 ]; then log "全部依赖已就绪，无需安装。"; return 0; fi
  log_warn "有 ${#todo[@]} 项依赖缺失。"
  read -rp "是否立即安装缺失的依赖? [Y/n]: " ans || ans=""
  [[ "$ans" =~ ^[nN]$ ]] && { log_info "已跳过安装。"; return 0; }
  for entry in "${todo[@]}"; do
    IFS='|' read -r name cmd desc <<< "$entry"
    if [ "$name" = "gost" ]; then
      _install_gost_now || true
    else
      _pkg_install "$name"
      if command -v "$cmd" &>/dev/null; then _mark_dep_installed "$name"; log "$name 已安装。"
      else log_err "$name 安装失败，请手动安装。"; fi
    fi
  done
  sep; show_deps
}

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
ensure_pkg_openconnect() { command -v openconnect &>/dev/null || { _pkg_install openconnect; command -v openconnect &>/dev/null || { log_err "安装 openconnect 失败"; exit 1; }; _mark_dep_installed openconnect; log "OpenConnect 已安装（记为本脚本安装）"; }; }
ensure_pkg_ocproxy()     { command -v ocproxy     &>/dev/null || { _pkg_install ocproxy; command -v ocproxy &>/dev/null || { log_err "安装 ocproxy 失败"; exit 1; }; _mark_dep_installed ocproxy; log "ocproxy 已安装（记为本脚本安装）"; }; }
ensure_pkg_iptables()    { command -v iptables    &>/dev/null || { _pkg_install iptables; command -v iptables &>/dev/null || { log_err "安装 iptables 失败"; exit 1; }; log "iptables 就绪"; }; }
ensure_cmd_ss()          { command -v ss &>/dev/null || { _pkg_install iproute2 || _pkg_install iproute; log "iproute2 就绪"; }; }
_install_gost_now() { # 只负责装，不询问（询问交给调用方，避免重复提问）
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
  _mark_dep_installed gost
  log "gost 已成功安装。"
  return 0
}
ensure_cmd_gost() {
  command -v gost &>/dev/null && return 0
  log_warn "Netns 模式需要 'gost' 作为 SOCKS5 服务器。"
  local yn=""
  read -rp "是否立即使用官方脚本自动安装 gost? [Y/n]: " yn || yn=""
  [[ "$yn" =~ ^[nN]$ ]] && { log_err "用户取消安装，Netns 模式无法启动。"; return 1; }
  _install_gost_now
}
ensure_cmd_socat() {
  command -v socat &>/dev/null && return 0
  log_warn "Netns 模式推荐用 'socat' 做端口转发（若没有，会自动改用 iptables 双 NAT）。"
  local yn=""
  read -rp "是否立即安装 socat? [Y/n]: " yn || yn=""
  [[ "$yn" =~ ^[nN]$ ]] && { log_info "将改用 iptables 双 NAT 作为端口转发后端。"; return 1; }
  _pkg_install socat
  command -v socat &>/dev/null || { log_warn "socat 安装失败，将改用 iptables 双 NAT。"; return 1; }
  _mark_dep_installed socat
  log "socat 已安装。"
  return 0
}
check_atd() { if ! command -v at &>/dev/null || ! systemctl is-active --quiet atd; then log_warn "at/atd 缺失或未运行, 尝试安装并启动..."; _pkg_install at; systemctl enable --now atd 2>/dev/null || log_err "自动启动 atd 失败"; fi; }

# 用法与 `grep -q` 相同，但可以安全地放在 `set -o pipefail` 的管线末尾。
# 坑：`cmd | grep -q PAT` 里 grep 一命中就退出，cmd 剩下的输出会撞上 SIGPIPE(退出码 141)，
# pipefail 于是把整条管线判为失败——明明匹配上了却当成"没匹配"。
# 实测 `ip netns exec NS ip link show | grep -q 'tun.*UP'` 非 0 率 262/1500 ≈ 17%：
# Netns 模式因此偶发"TUN 已就绪"紧接着"启动失败"（隧道其实是好的）。
# `grep -c` 必须读完全部输入才输出，不会打断上游，判定语义与 -q 一致。
_gq() { grep -c "$@" >/dev/null; }

# 等进程退出，最多 10 秒，仍未退出才 SIGKILL。
# 用于 netns 模式：先 kill openconnect 再立刻 cleanup_netns 会拆掉它登出用的
# veth→NAT 路径，openconnect 只能卡在 TLS 超时上（实测滞留 80 秒以上），
# 上一会话没走干净，下一次连接就会与它打架。
_wait_pid_gone() {
  local pid="$1" i=0
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  while [ "$i" -lt 20 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.5; i=$((i + 1))
  done
  kill -9 "$pid" 2>/dev/null || true
}

# --- 公网 IP 查询 ---
# 只用单一 provider（原 ip.p3terx.com）时，那家一挂整个状态区就只剩"查询失败"——
# 实测 ip.p3terx.com 已完全连不上（80/443 均 Failed to connect，连续 10 次 0 成功），
# 因此改为按顺序回退多个 provider，首个是实测最稳的。
_PUB_PROVIDERS4=("https://api.ipify.org" "https://ifconfig.me/ip" "https://ip.p3terx.com")
# IPv6 通常不可用，失败要快：候选少、超时短，避免状态区卡十几秒。
_PUB_PROVIDERS6=("https://api64.ipify.org" "https://ifconfig.me/ip")
# $1=-4/-6；$2=可选 socks5h 代理。成功打印地址并返回 0，全部失败返回 1。
_pub_ip() {
  local fam="$1" proxy="${2:-}" url out
  local list=("${_PUB_PROVIDERS4[@]}")
  local tmo=(-s -A "Mozilla/5.0" --connect-timeout 4 --max-time 8)
  if [ "$fam" = "-6" ]; then
    list=("${_PUB_PROVIDERS6[@]}")
    tmo=(-s -A "Mozilla/5.0" --connect-timeout 3 --max-time 5)
  fi
  [ -n "$proxy" ] && tmo=(-s -A "Mozilla/5.0" --connect-timeout 6 --max-time 12 -x "$proxy")
  for url in "${list[@]}"; do
    out=$("$CURL_CMD" "$fam" "${tmo[@]}" "$url" 2>/dev/null | head -n1 | tr -d '\r\n[:space:]')
    [ -n "$out" ] && { echo "$out"; return 0; }
  done
  return 1
}

# --- IPv6 连通性测试 ---
test_netns_ipv6() {
  local test_passed=0
  log_info "正在测试 Netns 内的 IPv6 连通性..."
  if ! "$IP_CMD" netns list | _gq "${NETNS_NAME}"; then log_err "Netns ${NETNS_NAME} 不存在，无法测试。"; return 1; fi
  
  # 测试1: 检查是否有 IPv6 地址
  if "$IP_CMD" netns exec "${NETNS_NAME}" ip -6 addr show 2>/dev/null | _gq "inet6.*scope global"; then
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
_check_port_free() { local port="$1"; ensure_cmd_ss || true; if command -v ss &>/dev/null && ss -lntup 2>/dev/null | _gq ":${port} "; then return 1; fi; return 0; }

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
  # setup_netns 会往 /etc/netns/<名字>/ 放一份 resolv.conf（ip netns exec 会把它
  # bind-mount 到 /etc/resolv.conf）。这里一并删掉，否则每跑一次 Netns 模式就在系统里
  # 留一个目录，脚本卸载之后也还在。
  rm -rf "/etc/netns/${NETNS_NAME}" 2>/dev/null || true
  log "Netns 基础环境已清理。"
}

# --- 账户管理 ---
manage_accounts() {
  [ -f "$ACCOUNTS_FILE" ] || { tee "$ACCOUNTS_FILE" >/dev/null <<'EOT'
# 格式: 显示名|用户名|密码|VPN主机|认证组(可选)
EOT
    chmod 600 "$ACCOUNTS_FILE" || true; }
  # c 必须是 local：否则子菜单会把主菜单的选项变量覆盖成自己的选择，返回主菜单后
  # "是否要按任意键"的判断（main_menu 末尾）就用错值，表现为凭空多出一次
  # "按任意键返回主菜单"的暂停——而且它恰好把后面要输入的选项吃掉一格。
  local c
  while true; do
    clear; title "🔐 管理 VPN 账户 ($ACCOUNTS_FILE)"; sep
    grep -vE '^\s*#|^\s*$' "$ACCOUNTS_FILE" | nl -ba || log_info "  文件为空。"
    sep; echo "  1) 添加  2) 删除  3) 返回"; read -rp "选择 [1-3]: " c || { echo; log_info "标准输入已结束，返回。"; return 0; }
    case "$c" in
      1) read -rp "显示名: " d; read -rp "用户: " u; read -sp "密码: " p; echo; read -rp "主机: " h; read -rp "认证组(可选): " g
         [ -z "$d" ] || [ -z "$u" ] || [ -z "$p" ] || [ -z "$h" ] && { log_err "必填项不能为空"; read -n1 -s -p "按任意键继续"; continue; }
         echo "$d|$u|$p|$h|$g" >> "$ACCOUNTS_FILE"; chmod 600 "$ACCOUNTS_FILE" || true; log "已添加 $d"; read -n1 -s -p "按任意键继续";;
      2) mapfile -t A < <(grep -vE '^\s*#|^\s*$' "$ACCOUNTS_FILE"); [ ${#A[@]} -eq 0 ] && { log_info "无账户"; sleep 1; continue; }
         read -rp "输入要删除的序号: " i; [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] && [ "$i" -le "${#A[@]}" ] || { log_err "无效序号"; continue; }
         # 按"过滤后列表里的第 i 条"精确删除一行。原先用 grep -vF 删整行字符串有两个坑：
         # ① 删最后一条时 grep 没有输出、返回 1，`&& mv` 于是不执行——文件原样没动却照样
         #    打印"已删除"（假成功），还留下一个 .tmp；② 两条账户内容完全相同时会被一起删掉。
         if ! awk -v n="$i" 'BEGIN{k=0} /^[[:space:]]*#/ || /^[[:space:]]*$/ {print; next} {k++; if (k!=n) print}' "$ACCOUNTS_FILE" > "${ACCOUNTS_FILE}.tmp"; then
           log_err "删除失败：无法写入临时文件。"; rm -f "${ACCOUNTS_FILE}.tmp"; read -n1 -s -p "按任意键继续"; continue
         fi
         mv "${ACCOUNTS_FILE}.tmp" "$ACCOUNTS_FILE"; chmod 600 "$ACCOUNTS_FILE" || true; log "已删除"; read -n1 -s -p "按任意键继续";;
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

select_protocol() {
  local p=""
  echo
  title "🔌 请选择 OpenConnect 协议："
  echo "  1) AnyConnect  - Cisco AnyConnect（默认）"
  echo "  2) Pulse       - Pulse Secure / Ivanti Secure Access"
  echo "  3) NC          - Juniper Network Connect"
  echo "  99) 返回"
  read -rp "选择 [1-3，默认 1]: " p
  case "${p:-1}" in
    1) export VPN_PROTOCOL="anyconnect"; export VPN_PROTOCOL_DESC="Cisco AnyConnect" ;;
    2) export VPN_PROTOCOL="pulse";      export VPN_PROTOCOL_DESC="Pulse / Ivanti" ;;
    3) export VPN_PROTOCOL="nc";         export VPN_PROTOCOL_DESC="Juniper NC" ;;
    99) return 1 ;;
    *) log_err "无效协议选择"; return 1 ;;
  esac
  log_info "已选择协议: ${VPN_PROTOCOL_DESC} (--protocol=${VPN_PROTOCOL})"
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
  local func_to_run="$1"; shift   # 其余参数原样透传给被调函数（菜单 3/4 用它传转发后端）
  trap cleanup_on_interrupt SIGINT
  check_atd
  # 保底回滚：先排一个 2 分钟后执行的 stop，连接稳定后再取消它（见下方 atrm）。
  # 注意 at 的时间表达式必须是英文单位：原写成 `at now + 2 分钟之前`，at 会以
  # "Garbled time" 拒绝，job 取到空值后整条保底机制静默失效（README 承诺的
  # "自动回滚保护" 因此从未生效过）。这里用标准写法。
  local job; job=$(echo "$SCRIPT_PATH stop" | at now + 2 minutes 2>&1 | awk '/job/{print $2}' || echo "none")
  [ "$job" != "none" ] && log_warn "已设保底清理任务 (Job $job), 2分钟内连接失败将自动回滚。"

  if "$func_to_run" "$@"; then
    trap - SIGINT # 成功后解除陷阱
    [ "$job" != "none" ] && atrm "$job" && log "连接稳定, 已取消保底任务"
    show_status || true
  else
    trap - SIGINT # 失败后解除陷阱
    log_err "启动过程失败，请检查日志。"
    stop_vpn # 确保在函数内部失败时也执行清理
    # 清理已经做过了，必须把保底任务撤掉：否则它 2 分钟后会准时执行一次 stop，
    # 而那时用户很可能已经重新连上了——于是"上一次失败"把"这一次成功"的连接杀掉
    # （实测连续启动时就是这样互相打架的）。
    [ "$job" != "none" ] && atrm "$job" 2>/dev/null || true
  fi
}

start_default() { is_vpn_running && { log_err "VPN 已在运行"; return; }; ensure_pkg_openconnect; select_account || return; select_protocol || return; _execute_with_safety_net "_start_default_logic"; }
_start_default_logic() {
  setup_ssh_protect_routes
  { echo "MODE=default"; echo "ACCOUNT_INDEX=$ACCOUNT_INDEX"; echo "VPN_PROTOCOL=${VPN_PROTOCOL:-anyconnect}"; } | tee -a "$STATE_FILE" >/dev/null
  log_info "连接VPN [默认模式 / 协议: ${VPN_PROTOCOL:-anyconnect}]: $VPN_HOST ..."
  local oc_cmd=("openconnect" "$VPN_HOST" --protocol="${VPN_PROTOCOL:-anyconnect}" --user="$VPN_USER" --passwd-on-stdin -b --pid-file="$PID_FILE")
  [ -n "$VPN_GROUP" ] && oc_cmd+=("--authgroup=$VPN_GROUP")
  echo "$VPN_PASS" | "${oc_cmd[@]}"
  log_info "等待 TUN 接口就绪..."; for ((i=0;i<15;i++)); do if is_vpn_running && ip link show 2>/dev/null | _gq 'tun.*UP'; then log "VPN 连接成功 (PID=$(cat "$PID_FILE"))"; return 0; fi; sleep 1; done
  log_err "VPN 连接失败或超时"; return 1
}

start_ocproxy_mode() { is_vpn_running && { log_err "VPN 已在运行"; return; }; ensure_pkg_openconnect; ensure_pkg_ocproxy; select_account || return; select_protocol || return; _execute_with_safety_net "_start_ocproxy_logic"; }
_start_ocproxy_logic() {
  local socks_port
  local listen_addr="127.0.0.1" # [Final] 简化: 默认且仅监听本地，移除远程选项
  # 守护重连没有终端（cron 的 stdin 是关的）：read 会 EOF 并被 set -e 杀掉整个
  # 重连流程（实测 rc=1、0 秒退出，菜单 6 声称的 ocproxy 守护因此完全不可用）。
  # 调用方传 reconnect 时改用 state 里保存的 SOCKS_PORT：跳过交互；端口被占就
  # 放弃本次（下个周期再试），不能掉进交互循环。
  if [ "${1:-}" = "reconnect" ] && [[ "${SOCKS_PORT:-}" =~ ^[0-9]+$ ]]; then
    socks_port="$SOCKS_PORT"
    _check_port_free "$socks_port" || { log_err "重连端口 ${socks_port} 当前被占用，本次放弃重连"; return 1; }
  else
    while true;do read -rp "请输入SOCKS5监听端口 (e.g. 1080): " socks_port || { echo; log_err "标准输入已结束，取消启动。"; return 1; }; [[ "$socks_port" =~ ^[0-9]+$ ]]&&[ "$socks_port" -ge 1 ]&&[ "$socks_port" -le 65535 ]||{ log_err "端口无效";continue; }; _check_port_free "$socks_port"||{ log_err "端口已被占用";continue; }; break; done
  fi
  
  log_info "正在启动 ocproxy 模式 (协议: ${VPN_PROTOCOL:-anyconnect}, 监听地址: $listen_addr)...";
  # ocproxy 的 -D 只接受端口，本身没有认证选项，所以这个模式加不了用户名/密码
  log_info "提示: ocproxy 模式不支持用户名/密码认证，需要认证请用 Netns 模式。";
  # [Final] 简化: 移除了无效的 allow_arg 变量
  local oc_cmd=("openconnect" "$VPN_HOST" --protocol="${VPN_PROTOCOL:-anyconnect}" --user="$VPN_USER" --passwd-on-stdin --script-tun --script "ocproxy -k 30 -D $socks_port" -b --pid-file="$PID_FILE")
  [ -n "$VPN_GROUP" ] && oc_cmd+=("--authgroup=$VPN_GROUP")
  echo "$VPN_PASS" | "${oc_cmd[@]}"
  
  log_info "等待 ocproxy 启动..."; for ((i=0;i<10;i++)); do if is_vpn_running; then log "ocproxy 连接成功 (PID=$(cat "$PID_FILE"))"; echo "MODE=ocproxy">"$STATE_FILE";echo "ACCOUNT_INDEX=$ACCOUNT_INDEX" >> "$STATE_FILE";echo "VPN_PROTOCOL=${VPN_PROTOCOL:-anyconnect}" >> "$STATE_FILE";echo "SOCKS_PORT=$socks_port" >> "$STATE_FILE";echo "LISTEN_ADDR=$listen_addr" >> "$STATE_FILE"; return 0; fi; sleep 1; done
  log_err "ocproxy 连接失败或超时"; return 1
}

# 菜单 3/4：Netns 模式，转发后端由菜单项直接指定（不再有"切换偏好"这一步）。
# $1 = socat 或 iptables
start_netns_mode() {
  local want_fwd="${1:-socat}"
  is_vpn_running && { log_err "VPN 已在运行"; return; }
  ensure_pkg_openconnect
  ensure_cmd_gost || return
  if [ "$want_fwd" = "socat" ]; then
    # 选了 socat 就必须有 socat：装不上就明确拒绝，不悄悄换成别的后端
    ensure_cmd_socat || { log_err "socat 不可用，Netns(socat) 无法启动。想走内核转发请用菜单 4。"; return; }
  fi
  select_account || return
  select_protocol || return
  _execute_with_safety_net "_start_netns_logic" "$want_fwd"
}
_start_netns_logic() {
  local want_fwd="${1:-socat}"
  local socks_port
  while true;do read -rp "请输入SOCKS5监听端口 (e.g. 8585): " socks_port || { echo; log_err "标准输入已结束，取消启动。"; return 1; }; [[ "$socks_port" =~ ^[0-9]+$ ]]&&[ "$socks_port" -ge 1 ]&&[ "$socks_port" -le 65535 ]||{ log_err "端口无效";continue; }; _check_port_free "$socks_port" || { log_err "端口已被占用"; continue; }; break; done
  
  local listen_addr="127.0.0.1"
  # || yn=""：非交互调用（管道/无终端）时 read 会 EOF 并返回非 0，裸 read 会被 set -e
  # 直接杀掉整个启动流程；统一按"不住默认值"处理。
  local yn=""
  read -rp "是否允许远程连接 (监听 0.0.0.0)? [y/N]: " yn || yn=""
  if [[ "$yn" =~ ^[yY]$ ]]; then
    listen_addr="0.0.0.0"
  fi

  # SOCKS5 用户名/密码（可选）。gost 的形式是 socks5://user:pass@host:port；
  # 留空即匿名。密码用隐藏输入（与 VPN 账户密码一致），但会明文写进 state
  # 文件并按设置在主菜单里显示——这是使用方明确要求的行为。
  local socks_user="" socks_pass="" need_auth=""
  read -rp "是否为 SOCKS5 设置用户名/密码? [y/N]: " need_auth || need_auth=""
  if [[ "$need_auth" =~ ^[yY]$ ]]; then
    # gost 是按 socks5://user:pass@host:port 解析的，用户名/密码里出现 @ : / 会把
    # URL 拆错（实测这类写法直接导致 gost 起不来或认证形同虚设），所以这里先拦住。
    while true; do
      read -rp "  用户名: " socks_user || socks_user=""
      [ -n "$socks_user" ] || { log_err "  用户名不能为空（不启用认证就直接回车跳过上一个问题）"; continue; }
      case "$socks_user" in *@*|*:*|*/*|*\"*|*\'*|*\\*|*[[:space:]]*) log_err "  用户名不能含 @ : / 引号 反斜杠 空白（会破坏 gost 的 URL），换个写法"; continue ;; esac
      break
    done
    while true; do
      read -rsp "  密码: " socks_pass || socks_pass=""; echo
      [ -n "$socks_pass" ] || { log_warn "  密码为空，本次不启用认证。"; socks_user=""; break; }
      case "$socks_pass" in *@*|*:*|*/*|*\"*|*\'*|*\\*|*[[:space:]]*) log_err "  密码不能含 @ : / 引号 反斜杠 空白（会破坏 gost 的 URL），换个写法"; continue ;; esac
      log_info "  已启用 SOCKS5 认证（用户名: ${socks_user}）"
      break
    done
  fi

  setup_netns
  
  log_info "正在 Netns 中启动 OpenConnect (协议: ${VPN_PROTOCOL:-anyconnect})...";
  local oc_cmd=("openconnect" "$VPN_HOST" --protocol="${VPN_PROTOCOL:-anyconnect}" --user="$VPN_USER" --passwd-on-stdin -b --pid-file="$PID_FILE")
  [ -n "$VPN_GROUP" ] && oc_cmd+=("--authgroup=$VPN_GROUP")
  echo "$VPN_PASS" | "$IP_CMD" netns exec "${NETNS_NAME}" "${oc_cmd[@]}"
  
  log_info "等待 OpenConnect 建立 TUN 接口...";
  for ((i=0; i<20; i++)); do
    if [ -f "$PID_FILE" ] && "$IP_CMD" netns pids "${NETNS_NAME}" | _gq -F "$(cat "$PID_FILE")" && \
       "$IP_CMD" netns exec "${NETNS_NAME}" ip link show 2>/dev/null | _gq 'tun.*UP'; then
      log "OpenConnect TUN 接口已就绪 (PID=$(cat "$PID_FILE"))"; sleep 2; break
    fi
    sleep 1
  done
  
  if ! "$IP_CMD" netns exec "${NETNS_NAME}" ip link show 2>/dev/null | _gq 'tun.*UP'; then
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
  local gost_listen="socks5://0.0.0.0:${socks_port}"
  [ -n "$socks_user" ] && gost_listen="socks5://${socks_user}:${socks_pass}@0.0.0.0:${socks_port}"
  "$IP_CMD" netns exec "${NETNS_NAME}" gost -L="${gost_listen}" >/dev/null 2>&1 &
  local gost_pid=$!; echo "$gost_pid" > "$GOST_PID_FILE"
  sleep 1; if ! kill -0 "$gost_pid" 2>/dev/null; then log_err "gost 在 Netns 中启动失败"; return 1; fi
  log "SOCKS5 服务 (gost) 已在 Netns 中启动 (PID: $gost_pid)"
  
  log_info "配置主机到 Netns 的端口转发 (后端: ${want_fwd})..."
  # 后端由菜单项指定（3=socat / 4=iptables）；OCM_FORWARDER 仍可一次性覆盖，供脚本化调用
  local fwd="$want_fwd"
  if [ -n "${OCM_FORWARDER:-}" ] && _fwd_avail "$OCM_FORWARDER"; then fwd="$OCM_FORWARDER"; fi
  _fwd_avail "$fwd" || { log_err "转发后端 '$fwd' 不可用，Netns 模式无法启动。"; return 1; }
  _FWD_DESC=""; _FWD_STATE=""
  _fwd_setup "$fwd" "$socks_port" "$listen_addr" || return 1

  {
    echo "MODE=netns"; echo "ACCOUNT_INDEX=$ACCOUNT_INDEX"; echo "VPN_PROTOCOL=${VPN_PROTOCOL:-anyconnect}"; echo "SOCKS_PORT=$socks_port";
    echo "LISTEN_ADDR=$listen_addr"; echo "GOST_PID=$gost_pid"; echo "FORWARDER=${_FWD_DESC}";
    # %q 转义：这两行会被 . "$STATE_FILE" 读回来，值里若含空格/引号，不转义的话
    # source 会把它当命令执行（实测 state 里出现 `SOCKS_PASS=p@ss word` 就报
    # "word: command not found"，密码直接读坏）。
    if [ -n "$socks_user" ]; then printf 'SOCKS_USER=%q\nSOCKS_PASS=%q\n' "$socks_user" "$socks_pass"; fi
    if [ -n "$_FWD_STATE" ]; then printf '%s\n' "$_FWD_STATE"; fi
  } > "$STATE_FILE"
  # state 里现在可能含 SOCKS 密码，默认 umask 会落成 644，收紧一次
  if [ -n "$socks_user" ]; then chmod 600 "$STATE_FILE" 2>/dev/null || true; fi
  
  return 0
}

# --- 停止与清理 ---
cleanup_ssh_protect_routes() {
  local vps4="" vps6=""
  if [ -f "$STATE_FILE" ]; then
    log_info "🔍 从状态文件加载路由信息进行精确清理..."
    # || true：状态文件存在、但缺这个键时 grep 返回 1，赋值随之失败，set -e 会直接
    # 终止整个清理流程（实测：一个字段都没清理就退出，策略路由全留着）。
    vps4=$(grep '^VPS4=' "$STATE_FILE" | cut -d'=' -f2 || true)
    vps6=$(grep '^VPS6=' "$STATE_FILE" | cut -d'=' -f2 || true)
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

# ============================================================================
#  端口转发后端（独立模块区 —— 新增方案只需动这一段）
# ----------------------------------------------------------------------------
#  netns 内是全局 VPN（默认路由 default dev tun0），所以"把主机端口转发进 netns
#  的 gost"只有两条可行路线，各自实现成自包含后端，主流程只按名字调用：
#
#    socat    —— 进程级中继（首选）。客户端↔socat、socat↔gost 是两段独立连接，
#                主机↔netns 那段两端地址都在 veth 直连网段内，不依赖回包路由。
#    iptables —— 双 NAT（兜底）。DNAT 把包送进 netns，SNAT 把源改成主机 veth 地址。
#                缺 SNAT 就是死的：gost 回包的目标地址若不在 veth 直连段，127.0.0.1
#                会走 lo 出不了 netns、其它地址会被 tun0 吞掉，客户端永远收不到回包。
#                本机实测：仅 DNAT 时四种访问方式全灭；补一条 SNAT 后立即全通。
#
#  统一入口（主流程只认这三个）：
#     _fwd_avail <名>                    → 该后端当前可用吗
#     _fwd_setup <后端> <端口> <监听地址> → 0=成功，并填好 _FWD_DESC / _FWD_STATE
#     _fwd_teardown <后端>             → 按 state 里的规则串拆除，可重复调用
#  后端由菜单项直接决定（3=socat / 4=iptables），不再有"选偏好"这一步。
#  新增后端：写 _fwd_setup_<名> 与 _fwd_teardown_<名>，在 _fwd_avail 与各分发处
#            各加一行、菜单里加一项即可；主流程、停止流程、状态显示都不用改。
# ============================================================================
_FWD_DESC=""    # 实际使用的后端名（写进 state 的 FORWARDER）
_FWD_STATE=""   # 需要额外写进 state 文件的行

_fwd_avail() {
  case "$1" in
    socat)    command -v socat &>/dev/null ;;
    iptables) command -v iptables &>/dev/null || [ -x "$IPTABLES_CMD" ] ;;
    *)        return 1 ;;
  esac
}

_fwd_setup() {
  case "$1" in
    socat|iptables) "_fwd_setup_$1" "$2" "$3" ;;
    *) log_err "未知的转发后端: $1"; return 1 ;;
  esac
}
_fwd_teardown() {
  case "${1:-}" in
    socat|iptables) "_fwd_teardown_$1" ;;
    *)
      # 更早版本的 state 可能没有 FORWARDER 键、却留下 RULE_* 规则串，兜底清一次
      if [ -n "${RULE_DNAT_OUTPUT:-}" ] || [ -n "${RULE_DNAT_PREROUTING:-}" ] || [ -n "${RULE_SNAT:-}" ] || [ -n "${RULE_FORWARD:-}" ]; then
        _fwd_teardown_iptables
      fi
      return 0 ;;
  esac
}

# --- 后端 1: socat（进程级中继，默认首选）---
_fwd_setup_socat() {
  local socks_port="$1" listen_addr="$2" pid_v4="" pid_v6=""
  socat TCP4-LISTEN:"${socks_port}",bind="${listen_addr}",fork,reuseaddr TCP4:"${VETH_NS_IP}:${socks_port}" >/dev/null 2>&1 &
  pid_v4=$!; echo "$pid_v4" > "$SOCAT_PID_FILE"
  sleep 1; if ! kill -0 "$pid_v4" 2>/dev/null; then log_err "socat 端口转发启动失败"; return 1; fi
  if [[ "$listen_addr" == "0.0.0.0" ]] || [[ "$listen_addr" == "::" ]]; then
    socat TCP6-LISTEN:"${socks_port}",ipv6only=1,fork,reuseaddr TCP4:"${VETH_NS_IP}:${socks_port}" >/dev/null 2>&1 &
    pid_v6=$!; echo "$pid_v6" > "$SOCAT_PID_FILE_V6"
    log "使用 socat 完成端口转发 (IPv4 PID: $pid_v4, IPv6 PID: $pid_v6)"
  else
    log "使用 socat 完成端口转发 (PID: $pid_v4)"
  fi
  _FWD_DESC="socat"; _FWD_STATE="SOCAT_PID=${pid_v4}"
  [ -n "$pid_v6" ] && _FWD_STATE="${_FWD_STATE}"$'\n'"SOCAT_PID_V6=${pid_v6}"
  return 0
}
_fwd_teardown_socat() {
  [ -f "$SOCAT_PID_FILE" ] && kill "$(cat "$SOCAT_PID_FILE")" 2>/dev/null || true
  [ -f "$SOCAT_PID_FILE_V6" ] && kill "$(cat "$SOCAT_PID_FILE_V6")" 2>/dev/null || true
  return 0
}

# --- 后端 2: iptables 双 NAT（没有 socat 时的兜底）---
_fwd_setup_iptables() {
  # 必须拆成两条 local：同一条 local 语句里的 ${socks_port} 在展开时还没生效，
  # bash 会去调用链上层找同名变量（动态作用域）。现在恰好因为 _start_netns_logic
  # 里有同名局部变量才碰巧正确，换一处调用 dst 就会变成 "192.168.200.2:"（端口空）。
  local socks_port="$1" listen_addr="$2"
  local dst="${VETH_NS_IP}:${socks_port}"
  local R_OUT R_PRE="" R_SNAT
  R_SNAT="-p tcp -d ${VETH_NS_IP} --dport ${socks_port} -j SNAT --to-source ${VETH_HOST_IP}"
  if [ "$listen_addr" = "0.0.0.0" ] || [ "$listen_addr" = "::" ]; then
    # 对全网开放：本机产生的流量走 OUTPUT、外部来的走 PREROUTING，两条都要有。
    # OUTPUT 这里不限定目标地址：本机既可能连 127.0.0.1，也可能连自己的内网 IP
    # （后者实测只加 PREROUTING 是连不上的——本机流量根本不经过 PREROUTING）。
    R_OUT="-p tcp --dport ${socks_port} -j DNAT --to-destination ${dst}"
    R_PRE="$R_OUT"
  else
    # 只监听本地：限定目标为 127.0.0.1，且不加 PREROUTING —— 语义与 socat bind 127.0.0.1 一致
    R_OUT="-p tcp -d 127.0.0.1 --dport ${socks_port} -j DNAT --to-destination ${dst}"
  fi
  # 先 -C 再 -A：重复运行不会叠加规则
  "$IPTABLES_CMD" -t nat -C OUTPUT $R_OUT 2>/dev/null || "$IPTABLES_CMD" -t nat -A OUTPUT $R_OUT \
    || { log_err "iptables DNAT(本机) 添加失败"; return 1; }
  "$IPTABLES_CMD" -t nat -C POSTROUTING $R_SNAT 2>/dev/null || "$IPTABLES_CMD" -t nat -A POSTROUTING $R_SNAT \
    || { log_err "iptables SNAT 添加失败"; return 1; }
  if [ -n "$R_PRE" ]; then
    "$IPTABLES_CMD" -t nat -C PREROUTING $R_PRE 2>/dev/null || "$IPTABLES_CMD" -t nat -A PREROUTING $R_PRE \
      || { log_err "iptables DNAT(外部) 添加失败"; return 1; }
  fi
  _FWD_DESC="iptables"
  _FWD_STATE="RULE_DNAT_OUTPUT='${R_OUT}'"
  [ -n "$R_PRE" ] && _FWD_STATE="${_FWD_STATE}"$'\n'"RULE_DNAT_PREROUTING='${R_PRE}'"
  _FWD_STATE="${_FWD_STATE}"$'\n'"RULE_SNAT='${R_SNAT}'"
  log "已用 iptables 双 NAT 完成端口转发 (DNAT → ${dst}，SNAT → ${VETH_HOST_IP})"
  return 0
}
_fwd_teardown_iptables() {
  # 同时覆盖本版本(RULE_DNAT_*/RULE_SNAT)与更早版本留下的 RULE_FORWARD
  local k="" r=""
  for k in RULE_DNAT_OUTPUT RULE_DNAT_PREROUTING RULE_SNAT RULE_FORWARD; do
    r="${!k:-}"
    [ -n "$r" ] || continue
    case "$k" in
      RULE_DNAT_OUTPUT)     eval "\$IPTABLES_CMD -t nat -D OUTPUT ${r}" 2>/dev/null || true ;;
      RULE_DNAT_PREROUTING) eval "\$IPTABLES_CMD -t nat -D PREROUTING ${r}" 2>/dev/null || true ;;
      RULE_SNAT)            eval "\$IPTABLES_CMD -t nat -D POSTROUTING ${r}" 2>/dev/null || true ;;
      RULE_FORWARD)         eval "\$IPTABLES_CMD -D FORWARD ${r}" 2>/dev/null || true ;;
    esac
  done
  return 0
}

stop_vpn() {
  # state 文件在时不能早退：失败的启动已写 state 并配好策略路由，早退会跳过
  # cleanup_ssh_protect_routes 和 rm —— 残留 ip rule 和 state（实测 iprule 4 行残留；
  # 装了守护任务还会每 5 分钟拿坏账户重连一次）。
  if ! is_vpn_running && ! [ -f "$GOST_PID_FILE" ] && ! [ -f "$SOCAT_PID_FILE" ] && ! [ -f "$STATE_FILE" ]; then log_info "VPN 未运行"; return; fi
  log_info "正在停止VPN并清理环境...";
  # || true：这一行尤其危险——赋值是 `[ -f ] && ...` 的最后一条命令，失败会直接终止
  # 整个 stop_vpn：进程没杀、临时文件没删、保底任务也没撤（实测 rc=1 且什么都没清）。
  local MODE; [ -f "$STATE_FILE" ] && MODE=$(grep '^MODE=' "$STATE_FILE" | cut -d'=' -f2 || true)

  case "${MODE:-unknown}" in
    netns)
      log_info "正在停止 netns 模式..."
      if [ -f "$STATE_FILE" ]; then
        . "$STATE_FILE" 2>/dev/null || true
        # 拆除交给后端模块自己处理：socat 杀进程、iptables 删规则，主流程不认规则形状。
        # 旧版本留下的 FORWARDER=iptables（只存 RULE_DNAT_*/RULE_FORWARD）同样走这里。
        _fwd_teardown "${FORWARDER:-}"
      fi
      [ -f "$GOST_PID_FILE" ] && kill "$(cat "$GOST_PID_FILE")" 2>/dev/null || true
      if [ -f "$PID_FILE" ]; then
        local oc_pid; oc_pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
        kill "$oc_pid" 2>/dev/null || true
        # 必须等 openconnect 自己退出再拆 netns/veth：它要先向网关登出，
        # 而登出走的就是 veth→NAT 这条路（先拆掉就会卡在 TLS 超时上，见 _wait_pid_gone）。
        _wait_pid_gone "$oc_pid"
      fi
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
  sep
  if ! is_vpn_running && ! [ -f "$GOST_PID_FILE" ] && ! [ -f "$SOCAT_PID_FILE" ]; then
    title "  VPN 状态: ${C_RED}🔴 停止${C_RESET}"
    echo -e "    ${C_BOLD}本机公网 IPv4:${C_RESET} $(_pub_ip -4 || echo "查询失败")"
    echo -e "    ${C_BOLD}本机公网 IPv6:${C_RESET} $(_pub_ip -6 || echo "无/查询失败")"
    echo -e "    ${C_BOLD}快捷命令:${C_RESET} $(_shortcut_state)"
  else
    local ACCOUNT_INDEX MODE SOCKS_PORT LISTEN_ADDR VPN_PROTOCOL SOCKS_USER SOCKS_PASS; [ -f "$STATE_FILE" ] && . "$STATE_FILE" 2>/dev/null || true
    title "  VPN 状态: ${C_GREEN}🟢 运行中${C_RESET} (OpenConnect PID: $(cat "$PID_FILE" 2>/dev/null || echo N/A))"
    if [ -n "${ACCOUNT_INDEX:-}" ]; then mapfile -t A < <(grep -vE '^\s*#|^\s*$' "$ACCOUNTS_FILE"); [ "$ACCOUNT_INDEX" -lt "${#A[@]}" ] && echo -e "    ${C_BOLD}使用账户:${C_RESET} $(echo "${A[$ACCOUNT_INDEX]}" | cut -d'|' -f1)"; fi
    echo -e "    ${C_BOLD}VPN 协议:${C_RESET} ${C_CYAN}${VPN_PROTOCOL:-anyconnect}${C_RESET}"
    
    case "${MODE:-}" in
      default)
        echo -e "    ${C_BOLD}运行模式:${C_RESET} 🛡️  默认全局模式"
        echo -e "    ${C_BOLD}VPN 出口 IPv4:${C_RESET} ${C_YELLOW}$(_pub_ip -4 || echo 失败)${C_RESET}"
        echo -e "    ${C_BOLD}VPN 出口 IPv6:${C_RESET} ${C_YELLOW}$(_pub_ip -6 || echo 无/失败)${C_RESET}"
      ;;
      ocproxy)
        echo -e "    ${C_BOLD}运行模式:${C_RESET} 🔌 ocproxy 代理 ${C_GREY}(仅 IPv4)${C_RESET}"
        echo -e "    ${C_BOLD}SOCKS 地址:${C_RESET} ${LISTEN_ADDR:-127.0.0.1}:${SOCKS_PORT}"
        local sip4; sip4=$(_pub_ip -4 "socks5h://127.0.0.1:${SOCKS_PORT}" || echo "查询失败")
        echo -e "    ${C_BOLD}SOCKS 出口 IPv4:${C_RESET} ${C_YELLOW}${sip4}${C_RESET}"
        echo -e "    ${C_BOLD}本机公网 IPv4:${C_RESET} $(_pub_ip -4 || echo 失败)"
      ;;
      netns)
        echo -e "    ${C_BOLD}运行模式:${C_RESET} 🌐 Network Namespace 代理 ${C_GREEN}(IPv4+IPv6)${C_RESET}"
        local f_info; if [[ "${FORWARDER:-}" == "socat" ]]; then f_info="socat"; else f_info="iptables"; fi
        local auth_txt=""
        [ -n "${SOCKS_USER:-}" ] && auth_txt=" ${C_YELLOW}认证 ${SOCKS_USER}:${SOCKS_PASS:-}${C_RESET}"
        echo -e "    ${C_BOLD}SOCKS 地址:${C_RESET} ${LISTEN_ADDR}:${SOCKS_PORT}${auth_txt} ${C_GREY}(gost PID: $(cat "$GOST_PID_FILE" 2>/dev/null), by ${f_info})${C_RESET}"
        
        local socks_proxy="socks5h://127.0.0.1:${SOCKS_PORT}"
        [ -n "${SOCKS_USER:-}" ] && socks_proxy="socks5h://${SOCKS_USER}:${SOCKS_PASS:-}@127.0.0.1:${SOCKS_PORT}"
        
        local sip4; sip4=$(_pub_ip -4 "$socks_proxy" || echo "查询失败")
        echo -e "    ${C_BOLD}SOCKS 出口 IPv4:${C_RESET} ${C_YELLOW}${sip4}${C_RESET}"
        
        local sip6=""
        # 必须有 || true：_pub_ip 在无 IPv6 时返回非 0，裸赋值失败会触发 set -e
        # 把整个脚本杀掉（表现为菜单渲染到"出口"就没了、返回码 1）。
        sip6="$(_pub_ip -6 "$socks_proxy" || true)"
        
        if [ -z "$sip6" ] && [ -n "${NETNS_NAME:-}" ]; then
          sip6=$("$IP_CMD" netns exec "${NETNS_NAME}" curl -6 -s --connect-timeout 5 --max-time 10 "${_PUB_PROVIDERS6[0]}" 2>/dev/null | head -n1 | tr -d '\r\n[:space:]' || echo "")
          [ -n "$sip6" ] && sip6="${sip6} ${C_GREY}(Netns内检测)${C_RESET}"
        fi
        
        if [ -n "$sip6" ]; then
          echo -e "    ${C_BOLD}SOCKS 出口 IPv6:${C_RESET} ${C_YELLOW}${sip6}${C_RESET}"
        else
          echo -e "    ${C_BOLD}SOCKS 出口 IPv6:${C_RESET} ${C_YELLOW}检测超时或不可用${C_RESET}"
        fi
        
        echo -e "    ${C_BOLD}本机公网 IPv4:${C_RESET} $(_pub_ip -4 2>/dev/null || echo 失败)"
      ;;
      *) echo -e "    ${C_BOLD}运行模式:${C_RESET} 未知";;
    esac
    echo -e "    ${C_BOLD}快捷命令:${C_RESET} $(_shortcut_state)"
  fi
  sep
}

# --- 定时与卸载 ---
manage_cron() {
  # 同 manage_accounts：c 必须 local，否则会覆盖主菜单的选项变量。
  local c
  while true; do
    clear; title "🗓️ 定时/守护任务"; sep
    crontab -l 2>/dev/null | grep "$SCRIPT_PATH" || log_info "  当前无此脚本的定时任务。"
    sep
    echo -e "  1) 设置守护任务 (每5分钟检查，断线重连)"
    echo -e "  2) 添加定时关闭任务"
    echo -e "  3) 清除所有此脚本相关的定时任务"
    echo -e "  4) 返回主菜单"
    read -rp "请选择 [1-4]: " c || { echo; log_info "标准输入已结束，返回。"; return 0; }
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

# 卸载依赖前的询问。核心区别：
#   本脚本装的      → 默认 Y（用户装它就是为了这个脚本）
#   本来就在机器上   → 提醒 + 默认 N，避免删掉别的用途在用的东西
# 返回 0 = 用户确认删除。
_ask_uninstall_dep() {
  local name="$1" desc="$2" ans=""
  if _dep_installed_by_us "$name"; then
    read -rp "是否卸载 $name? ($desc，由本脚本安装) [Y/n]: " ans || ans=""
    [[ "$ans" =~ ^[nN]$ ]] && { log_info "已保留 $name。"; return 1; }
    return 0
  fi
  log_warn "$name 不是本脚本安装的（可能是你自己装的，或还有别的用途）。"
  read -rp "确定要卸载 $name 吗? [y/N]: " ans || ans=""
  if [[ "$ans" =~ ^[yY]$ ]]; then return 0; fi
  log_info "已保留 $name。"
  return 1
}

uninstall() {
  local y=""
  read -rp "⚠️  确认要卸载此脚本及其所有相关配置吗？[y/N]: " y || y=""
  [[ "$y" =~ ^[yY]$ ]] || { log_info "已取消"; exit 0; }
  log_info "开始卸载..."; stop_vpn
  crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab - 2>/dev/null || true; log "定时任务已清理"
  
  if command -v gost &>/dev/null; then
    if _ask_uninstall_dep gost "Netns 模式的 SOCKS5 服务端"; then
      # 官方 install.sh 只认 --install 一个参数，没有卸载分支：传 --remove 之类的参数
      # 会掉进"选择版本"的安装菜单（交互选一次就真的把它装回去/升级），
      # 而 select 在非交互下失败后旧代码仍打印"已尝试卸载"——是句假话。
      # gost 是单个二进制、无包管理器记录，所以直接删文件。
      log_info "正在卸载 gost..."
      command -v pkill &>/dev/null && pkill -x gost 2>/dev/null || true
      rm -f "$(command -v gost 2>/dev/null)" 2>/dev/null || true
      if command -v gost &>/dev/null; then log_warn "gost 卸载失败，请手动删除。"
      else log "gost 已卸载。"; fi
    fi
  fi
  
  if command -v socat &>/dev/null; then
    if _ask_uninstall_dep socat "Netns 模式的端口转发"; then
      if command -v apt-get &>/dev/null; then apt-get purge -y socat >/dev/null || true
      elif command -v yum &>/dev/null; then yum remove -y socat >/dev/null || true
      elif command -v dnf &>/dev/null; then dnf remove -y socat >/dev/null || true; fi
      if command -v socat &>/dev/null; then log_warn "socat 卸载失败，请手动删除。"
      else log "socat 已卸载。"; fi
    fi
  fi

  log_warn "OpenConnect / ocproxy 是常用软件包，其它程序也可能在用；不确定就选 N 保留。"
  read -rp "是否卸载 OpenConnect 和 ocproxy 软件包? [y/N]: " yn_oc || yn_oc=""
  if [[ "$yn_oc" =~ ^[yY]$ ]]; then
    if command -v apt-get &>/dev/null; then apt-get purge -y openconnect ocproxy >/dev/null || true
    elif command -v yum &>/dev/null; then yum remove -y openconnect ocproxy >/dev/null || true
    elif command -v dnf &>/dev/null; then dnf remove -y openconnect ocproxy >/dev/null || true; fi
    log "OpenConnect/ocproxy 已尝试卸载。"
  fi
  
  rm -f "$ACCOUNTS_FILE"; log "账户文件已删除"
  # 老版本（菜单 10 那套）可能在 /var/lib/oc-master 下留过一个 forwarder 偏好文件，一并清掉
  rm -f "$DEPS_MARK_FILE" "${DEPS_STATE_DIR}/forwarder"; rmdir "$DEPS_STATE_DIR" 2>/dev/null || true
  remove_shortcut
  log_info "正在删除脚本文件: $SCRIPT_PATH"; rm -f "$SCRIPT_PATH"; log "卸载完成，再见！"
}

_internal_cron_handler() {
  local a="$1"; shift; check_root
  case "$a" in
    _internal_check_health)
      if ! is_vpn_running && [ -f "$STATE_FILE" ]; then
        log_info "守护进程: 检测到连接断开, 正在尝试自动重连..."; 
        . "$STATE_FILE"; _load_account_by_index "${ACCOUNT_INDEX:-}"
        case "${MODE:-}" in
          default) _start_default_logic ;;
          ocproxy) _start_ocproxy_logic reconnect ;;
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
  # 状态显示只是展示：它内部任何查询失败都不该中断主菜单（见 _pub_ip 的 set -e 陷阱）
  show_status || true
  title "主菜单:"
  echo -e "  ${C_GREEN}1) 启动: 🛡️  默认模式 (全局VPN, 保护SSH)${C_RESET}"
  echo -e "  ${C_GREEN}2) 启动: 🔌 ocproxy 模式 (SOCKS5, 仅IPv4)${C_RESET}"
  echo -e "  ${C_GREEN}3) 启动: 🌐 Netns 模式 (SOCKS5, socat 转发)${C_RESET}"
  echo -e "  ${C_GREEN}4) 启动: 🌐 Netns 模式 (SOCKS5, iptables 双 NAT)${C_RESET}"
  echo -e "  ${C_RED}5) 停止 VPN${C_RESET}"
  sep
  echo -e "  6) ⚙️  管理 VPN 账户"
  echo -e "  7) 🗓️  设置定时/守护任务"
  echo -e "  8) 📦 检查/安装依赖"
  echo -e "  9) 🧪 ${C_CYAN}测试 Netns IPv6 连通性${C_RESET}"
  echo -e "  10) 🗑️  卸载"
  echo -e "  0) 🚪 退出"
  echo
  # 标准输入结束（管道/重定向）时直接退出：否则末尾的 return 0 会让菜单无限循环，
  # 每轮还会发两次公网 IP 查询。read 失败正是 EOF 的情形。
  read -rp "请选择 [0-9] 或 10: " c || { echo; log_info "标准输入已结束，退出。"; exit 0; }
  case "$c" in
    1) start_default || true;;
    2) start_ocproxy_mode || true;;
    3) start_netns_mode socat || true;;
    4) start_netns_mode iptables || true;;
    5) stop_vpn || true;;
    6) manage_accounts;;
    7) manage_cron;;
    8) manage_deps;;
    9) if [ -f "$STATE_FILE" ] && grep -q "MODE=netns" "$STATE_FILE"; then
         test_netns_ipv6 || true
       else
         log_err "Netns 模式未运行，无法测试"
       fi;;
    10) uninstall; exit 0;;
    0) exit 0;;
    *) log_err "无效选项 '$c'";;
  esac
  # 选项 6/7、直接回车或输错键时，上面那条 AND 列表返回 1；而"函数最后一条语句返回
  # 非 0"会让 set -e 结束整个脚本（实测：在主菜单按一下回车程序就退出了）。
  # 显式 return 0，保证任何输入都回到菜单循环里。
  [[ "$c" =~ ^([1-5]|8|9)$ ]] && read -n1 -s -p $'\n'"按任意键返回主菜单..."
  return 0
}

# --- 脚本入口 ---
case "${1:-main}" in
  _internal_*) _internal_cron_handler "$@"; exit 0 ;;
  stop) check_root; stop_vpn; exit 0 ;;
  main|*) check_root; _ensure_shortcut; while true; do main_menu; done ;;
esac
