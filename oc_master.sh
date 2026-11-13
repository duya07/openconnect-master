#!/bin/bash
# =================================================================
#   OpenConnect Master Manager - v8.2.0
#   - 新增: systemd 托管（ocm.service）。openconnect 改为前台运行，退出后按原因自动重连
#     （服务器到期终止 / 网络错误 / 认证失败分别处理），netns 与代理在重连期间保持不动；
#     关闭 SSH 不再影响 VPN。
#   - 新增: 内置长期诊断日志（ocm-watch.service）：定时采样、事件、断线现场快照、报告。
#   - 新增: 🔧 设置菜单 + /etc/oc-master/settings.conf —— 每个可调参数都有说明与可选项，
#     启动前显示摘要，可直接启动 / 先改设置 / 只改本次。
#   - 新增: 命令行接口（ocm -h）：start / stop / restart / status / log / heal / config / accounts。
#   - 变更: netns 模式默认不再打开宿主 IPv6 全局转发（设置里可开）；VPN 密码不再 export
#     进子进程环境；账户列表与状态区不再明文显示密码。
#   - 保留: 默认全局 / ocproxy / Netns 三种模式；SSH 保护路由；socat / iptables 两种转发后端。
# =================================================================
set -euo pipefail

# --- 全局配置 ---
VERSION="8.2.0"
VR_TAG="OC-Master-v${VERSION}"
SCRIPT_PATH="$(readlink -f "$0")"
PID_FILE="/var/run/oc_manager.pid"
GOST_PID_FILE="/var/run/oc_gost.pid"
SOCAT_PID_FILE="/var/run/oc_socat.pid"
SOCAT_PID_FILE_V6="${SOCAT_PID_FILE}.v6"
STATE_FILE="/var/run/oc_manager.state"
# setup_netns 会打开内核转发开关；改动前的原值记在这里，cleanup_netns 据此还原
SYSCTL_STATE_FILE="/var/run/oc_manager.sysctl"
ACCOUNTS_FILE="/root/.vpn_accounts.env"
SHORTCUT_PATH="/usr/local/bin/ocm"
# 依赖标记：只记录"由本脚本安装"的依赖（卸载时据此区分默认删/默认留）
DEPS_STATE_DIR="/var/lib/oc-master"
DEPS_MARK_FILE="${DEPS_STATE_DIR}/installed-deps"

# --- v8: 设置 / 运行时 / 日志 ---
CONF_DIR="/etc/oc-master"
SETTINGS_FILE="${CONF_DIR}/settings.conf"
PROXIES_FILE="${CONF_DIR}/proxies.conf"  # 回落代理列表（600，含明文密码；断线保护 = proxy 时使用）
RUN_DIR="/run/oc-master"
RUN_PROFILE="${RUN_DIR}/run.conf"        # 本次启动的生效设置（600；不含 VPN 密码）
PHASE_FILE="${RUN_DIR}/phase"            # supervisor 阶段：starting/connecting/up/reconnecting/stopping/stopped/failed:<原因>
RESTART_REQ="${RUN_DIR}/restart-request" # 观察进程请求软重连
PLANNED_REQ="${RUN_DIR}/planned-restart" # supervisor 自己发起的定时重连（区分于服务器终止/软重连）
FB_STATE_FILE="${RUN_DIR}/fallback"          # 正在回落时存在：起始时间 IP:端口 显示名
FB_GOST_PID_FILE="${RUN_DIR}/fallback-gost.pid"
FB_YAML="${RUN_DIR}/fallback-gost.yaml"      # 回落 gost 的配置（600，含代理密码；gost 启动后即删除）
SESSION_LOG="${RUN_DIR}/oc-session.log"  # 当前这次 openconnect 的输出（判断退出原因用）
LOG_DIR="/var/log/oc-master"
EVENTS="${LOG_DIR}/events.log"
SAMPLES="${LOG_DIR}/samples.log"
OCLOG="${LOG_DIR}/openconnect.log"
INC_DIR="${LOG_DIR}/incidents"
LAUNCH_DIR="${LOG_DIR}/launch"
WATCH_LIB="${DEPS_STATE_DIR}/watch"
SVC_MAIN="ocm.service"
SVC_WATCH="ocm-watch.service"
UNIT_DIR="/etc/systemd/system"
START_TIMEOUT=90                         # ocm start 等待隧道就绪的最长时间（秒）
SESSION_RESTART_MIN=600                  # 定时重连的最短会话时长（秒），防止误填过小反复登录
OC_TUN_DEFAULT="ocmtun0"                 # 默认全局模式的隧道网卡名（netns 模式在命名空间里，仍是 tun0）

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
# 非终端（systemd / 管道）时不输出颜色码，日志文件保持干净
if [ ! -t 1 ]; then C_RESET=''; C_BOLD=''; C_GREY=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; fi
log()      { echo -e "${C_GREEN}✅ [$VR_TAG] $1${C_RESET}"; }
log_err()  { echo -e "${C_RED}❌ [$VR_TAG] $1${C_RESET}" >&2; }
log_info() { echo -e "${C_CYAN}ℹ️  [$VR_TAG] $1${C_RESET}"; }
log_warn() { echo -e "${C_YELLOW}⚠️  [$VR_TAG] $1${C_RESET}"; }
title()    { echo -e "${C_BOLD}$1${C_RESET}"; }
sep()      { echo -e "${C_GREY}--------------------------------------------------------${C_RESET}"; }
check_root(){ [ "$EUID" -eq 0 ] || { log_err "请用 root 运行"; exit 1; }; }

# 事件日志：一行一事件，纯内建取时间（停止时 SIGTERM 发给整个 cgroup，$(...) 有竞态）
ev() {
  local _t _e
  printf -v _t '%(%Y-%m-%dT%H:%M:%S%z)T' -1; printf -v _e '%(%s)T' -1
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '%s e=%s %s\n' "$_t" "$_e" "$*" >> "$EVENTS" 2>/dev/null || true
  return 0
}
now_s() { printf '%(%s)T' -1; }
fmt_dur() { # 秒 → 1d02h03m / 1h02m03s / 2m03s / 5s
  local s=${1:-0} d h m; [[ "$s" =~ ^[0-9]+$ ]] || { echo "$s"; return; }
  d=$((s/86400)); h=$((s%86400/3600)); m=$((s%3600/60)); s=$((s%60))
  if [ $d -gt 0 ]; then printf '%dd%02dh%02dm' $d $h $m
  elif [ $h -gt 0 ]; then printf '%dh%02dm%02ds' $h $m $s
  elif [ $m -gt 0 ]; then printf '%dm%02ds' $m $s
  else printf '%ds' $s; fi
}
# 脱敏：密码/口令/cookie/会话令牌一律替换（openconnect 的 HTTP 交互里可能出现 DSID 等）
redact() {
  sed -E 's/((pass(word|wd)?|cookie|DSID|DSFirstAccess|DSLastAccess|DSSignInURL|token|secret|authorization|SOCKS_PASS)[[:space:]]*[:=][[:space:]]*)[^[:space:];&]+/\1<redacted>/Ig'
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
  "socat|socat|Netns 模式的端口转发（首选，同时提供 IPv4/IPv6 入口；没有它菜单 3 无法启动，可改用菜单 4 的内核转发）"
)

# 菜单 8：先扫描现状，再决定装什么
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
  # 不能写成 `bash <(curl ...) --install || {...}`：进程替换里的失败不会被 `||` 捕获——
  # curl 因 DNS/网络/404 失败时 bash 只是读到空输入、正常退出 0，那个失败分支是死代码，
  # 真正的失败要等下面的 command -v 才发现（而且提示会指向 PATH 而非网络）。先落盘再执行。
  local _gi="/tmp/oc_gost_install.$$.sh"
  if ! "$CURL_CMD" -fsSL "https://github.com/go-gost/gost/raw/master/install.sh" -o "$_gi"; then
    log_err "下载 gost 安装脚本失败（网络/代理/404），请检查网络或手动安装。"
    rm -f "$_gi" 2>/dev/null || true
    return 1
  fi
  if ! bash "$_gi" --install; then
    log_err "gost 安装脚本执行失败，请检查脚本输出或手动安装。"
    rm -f "$_gi" 2>/dev/null || true
    return 1
  fi
  rm -f "$_gi" 2>/dev/null || true
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
  log_warn "Netns 模式推荐用 'socat' 做端口转发（菜单 3 需要它；没有就去装，或改选菜单 4 走内核转发）。"
  local yn=""
  read -rp "是否立即安装 socat? [Y/n]: " yn || yn=""
  [[ "$yn" =~ ^[nN]$ ]] && { log_info "已取消：菜单 3 需要 socat；想走内核转发请用菜单 4。"; return 1; }
  _pkg_install socat
  command -v socat &>/dev/null || { log_warn "socat 安装失败：菜单 3 无法启动，想走内核转发请用菜单 4。"; return 1; }
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

# 判断 netns 模式的 VPN 是否真的可用——判据是"netns 内的实际出口 ≠ 本机出口"，
# 而不是"tun0 在不在"或"ping 通不通"（那两个都会假阳性，原因见 _start_netns_logic）。
# 返回 0 = 可用；1 = 明确不可用；2 = 无法判断（连本机出口都查不到，例如网络受限）。
# 启动流程与守护任务共用同一个函数，避免两处判据日后漂移。
# 探针拿到的 netns 出口地址（供调用方打印真实信息；探针返回值仍是三态）
_NS_PROBE_IP=""
_netns_vpn_probe() {
  local host_ip ns_ip
  _NS_PROBE_IP=""
  host_ip="$(_pub_ip -4 2>/dev/null || true)"
  [ -n "$host_ip" ] || return 2
  ns_ip="$("$IP_CMD" netns exec "${NETNS_NAME}" "$CURL_CMD" -4 -s --max-time 6 "${_PUB_PROVIDERS4[0]}" 2>/dev/null | head -n1 || true)"
  if [ -n "$ns_ip" ] && [ "$ns_ip" != "$host_ip" ]; then _NS_PROBE_IP="$ns_ip"; return 0; fi
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
  # 三个值缺一不可：解析不到时，下面 `ip route replace default via '' dev ''` 与
  # `ip rule add from '' ...` 都会失败；而本函数是在 if 条件里被调用的，set -e 在那里被
  # 抑制 —— 失败不会中断，脚本会带着"没有 SSH 保护"的状态继续把全局 VPN 启起来，正好
  # 掐断用户用来操作的 SSH 连接。这里直接判失败，让上层走失败分支（stop_vpn + 撤保底任务）。
  [ -n "$gw_dev" ] && [ -n "$gw4" ] && [ -n "$vps4" ] || { log_err "无法解析默认路由/本机地址 (dev='$gw_dev' via='$gw4' addr='$vps4')，放弃启动以免失去 SSH 连接"; return 1; }

  check_rt_conflict "$RT4_ID" "$RT4_NAME"
  log "配置 IPv4 策略路由 (SSH保护)..."
  # 必须检查这一步：保护表里若没有默认路由，而下面照样加上 from 规则，来自本机地址的
  # 流量就会被送进空表而不可达（SSH 直接掉线）。宁可拒绝启动，也不要"只配了一半"。
  "$IP_CMD" route replace default via "$gw4" dev "$gw_dev" table "$RT4_ID" \
    || { log_err "写入 IPv4 保护路由失败 (table $RT4_ID)，放弃启动以免失去 SSH 连接"; return 1; }
  "$IP_CMD" rule del from "$vps4" table "$RT4_ID" priority 500 2>/dev/null || true
  "$IP_CMD" rule add from "$vps4" table "$RT4_ID" priority 500
  log "IPv4 OK (from $vps4)"

  default_ipv6_route=$("$IP_CMD" -6 route | awk '/^default/ && $0 !~ /tun/ {print; exit}' || true)
  vps6=$("$IP_CMD" -6 -o addr show dev "$gw_dev" scope global | awk '{print $4; exit}' | cut -d/ -f1 || true)
  # 默认路由可能是 multipath 形式：首行只有 "default proto static metric N pref medium"，
  # 网关与设备在随后缩进的 "nexthop via X dev Y" 行里。按固定列位置取 $3/$5 会拿到
  # "static"/"1024"，`ip -6 route replace` 报 inet6 address is expected 而失败——但脚本
  # 仍会继续加一条指向空表 101 的规则，该机的 IPv6 出向流量于是被丢进黑洞（走 IPv6 的
  # SSH 会断），还打印 "IPv6 OK"（在 IPv6 默认路由是多跳 nexthop 形式的主机上必然复现）。
  # 所以改为按 via/dev 关键字取字段（不依赖列位置），并在执行前校验；取不到就跳过。
  local v6line="" v6_ok=""
  v6line=$("$IP_CMD" -6 route | awk '
    /^default/ { inblk=1; if ($0 !~ /tun/ && $0 ~ / via /) { print; exit } ; next }
    inblk && /^[[:space:]]/ { if ($0 !~ /tun/ && $0 ~ / via /) { print; exit } ; next }
    { inblk=0 }' || true)
  if [ -n "$v6line" ]; then
    gw6_addr=$(printf '%s\n' "$v6line" | awk '{for(i=1;i<NF;i++) if($i=="via"){print $(i+1); exit}}')
    gw6_if=$(printf '%s\n' "$v6line" | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
    case "$v6line" in *" onlink "*|*" onlink") onlink_flag="onlink" ;; esac
  fi
  # 校验：网关要像 IPv6 地址（含冒号）、设备名要真实存在，且必须与 IPv4 默认路由同一个
  # 设备——保护表里的默认路由要经本机地址所在的那张网卡出去，否则源地址与出口设备对不上。
  [ -n "$gw6_addr" ] && [ -n "$gw6_if" ] && [ "${gw6_addr#*:}" != "$gw6_addr" ] \
    && [ "$gw6_if" = "$gw_dev" ] \
    && "$IP_CMD" link show dev "$gw6_if" >/dev/null 2>&1 && v6_ok=1
  if [ -n "$default_ipv6_route" ] && [ -n "$vps6" ] && [ -n "$v6_ok" ]; then
    check_rt_conflict "$RT6_ID" "$RT6_NAME"
    log "配置 IPv6 策略路由 (SSH保护)..."
    if "$IP_CMD" -6 route replace default via "$gw6_addr" dev "$gw6_if" $onlink_flag table "$RT6_ID"; then
      "$IP_CMD" -6 rule del from "$vps6" table "$RT6_ID" priority 500 2>/dev/null || true
      "$IP_CMD" -6 rule add from "$vps6" table "$RT6_ID" priority 500
      log "IPv6 OK (from $vps6)"
    else
      # 与 IPv4 同理：保护表写不进去就绝不能加规则（否则 IPv6 流量被导向空表）。
      log_warn "写入 IPv6 保护路由失败，跳过 IPv6 保护设置（IPv4 保护不受影响）"
    fi
  else
    if [ -n "$default_ipv6_route" ] && [ -n "$vps6" ]; then
      log_warn "IPv6 默认路由无法解析出可用网关（multipath/nexthop 形式？），跳过 IPv6 保护设置"
    else
      log_info "无可用 IPv6 默认路由或地址，跳过 IPv6 设置"
    fi
    vps6="" # 确保 vps6 为空
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
  
  # 先记下改动前的值：清理时只把"本来关着、被我们打开"的开关还原回去，避免影响机器上
  # 真正依赖 forwarding=1 的其它程序（容器运行时、转发服务等）。
  printf 'SYSCTL_IPFWD_ORIG=%s\nSYSCTL_V6FWD_ORIG=%s\n' \
    "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo unknown)" \
    "$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo unknown)" \
    > "$SYSCTL_STATE_FILE" 2>/dev/null || true
  log_info "启用内核 IP 转发..."
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  # v8：IPv6 转发默认不开（netns 没有 IPv6 出口时用不到，全局开启还可能影响宿主接受 RA）；设置 IPV6_FORWARD=on 才开
  if [ "${OCM_IPV6_FORWARD:-0}" = 1 ]; then sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null; fi

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
  # 还原转发开关：只有原值是 0（也就是被本脚本打开的）才恢复为 0，其它情况一律不动。
  if [ -f "$SYSCTL_STATE_FILE" ]; then
    local _ipfwd_orig="" _v6fwd_orig=""
    _ipfwd_orig=$(grep '^SYSCTL_IPFWD_ORIG=' "$SYSCTL_STATE_FILE" 2>/dev/null | cut -d'=' -f2 || true)
    _v6fwd_orig=$(grep '^SYSCTL_V6FWD_ORIG=' "$SYSCTL_STATE_FILE" 2>/dev/null | cut -d'=' -f2 || true)
    if [ "$_ipfwd_orig" = "0" ]; then
      sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
      log_info "已把 net.ipv4.ip_forward 还原为 0（脚本启动前它就是 0）"
    fi
    if [ "$_v6fwd_orig" = "0" ]; then
      sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null 2>&1 || true
      log_info "已把 net.ipv6.conf.all.forwarding 还原为 0（脚本启动前它就是 0）"
    fi
    rm -f "$SYSCTL_STATE_FILE" 2>/dev/null || true
  fi
  log "Netns 基础环境已清理。"
}

# --- 账户管理 ---
manage_accounts() {
  [ -f "$ACCOUNTS_FILE" ] || { tee "$ACCOUNTS_FILE" >/dev/null <<'EOT'
# 格式: 显示名|用户名|密码|VPN主机|认证组(可选)|协议(可选)
EOT
    chmod 600 "$ACCOUNTS_FILE" || true; }
  # c 必须是 local：否则子菜单会把主菜单的选项变量覆盖成自己的选择，返回主菜单后
  # "是否要按任意键"的判断（main_menu 末尾）就用错值，表现为凭空多出一次
  # "按任意键返回主菜单"的暂停——而且它恰好把后面要输入的选项吃掉一格。
  local c
  while true; do
    clear 2>/dev/null || true; title "🔐 管理 VPN 账户 ($ACCOUNTS_FILE)"; sep
    accounts_list   # v8：列表不再显示密码列
    sep; echo "  1) 添加  2) 删除  3) 返回"; read -rp "选择 [1-3]: " c || { echo; log_info "标准输入已结束，返回。"; return 0; }
    case "$c" in
      1) read -rp "显示名: " d; read -rp "用户: " u; read -sp "密码: " p; echo; read -rp "主机: " h; read -rp "认证组(可选): " g; read -rp "协议(可选，留空=用设置里的全局协议；anyconnect/pulse/nc/gp/fortinet/array): " pr
         case "${pr:-}" in ""|anyconnect|pulse|nc|gp|fortinet|array) ;; *) log_err "未知协议：$pr"; read -n1 -s -p "按任意键继续"; continue;; esac
         [ -z "$d" ] || [ -z "$u" ] || [ -z "$p" ] || [ -z "$h" ] && { log_err "必填项不能为空"; read -n1 -s -p "按任意键继续"; continue; }
         # 账户文件用 | 分字段（cut -d'|'），任一字段含 | 都会错位（密码 pa|ss 会被读成 pa）
         case "$d$u$p$h$g$pr" in *"|"*) log_err "任何字段都不能包含 | 字符"; read -n1 -s -p "按任意键继续"; continue;; esac
         echo "$d|$u|$p|$h|$g${pr:+|$pr}" >> "$ACCOUNTS_FILE"; chmod 600 "$ACCOUNTS_FILE" || true; log "已添加 $d"; read -n1 -s -p "按任意键继续";;
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

# ============================================================================
#  设置（/etc/oc-master/settings.conf，600）
# ----------------------------------------------------------------------------
#  注册表每行：KEY|类型|默认值|可选项|标题|分组
#    类型：choice（只能选可选项）、int（数字，可选项只是常用预设）、text（自由文本，
#          可选项为预设）、account（账户序号）、auth（SOCKS 用户名+密码）
#    可选项：逗号分隔的 值:说明
#  说明文字在 _set_help 里，菜单与 `ocm config list -v` 共用。
# ============================================================================
SET_REGISTRY=(
  "ACCOUNT|account|1||VPN 账户|连接"
  "MODE|choice|netns|netns:Netns 隔离代理（推荐）,default:默认全局模式,ocproxy:ocproxy 用户态代理|运行模式|连接"
  "PROTOCOL|choice|anyconnect|anyconnect:Cisco AnyConnect,pulse:Pulse / Ivanti Secure Access,nc:Juniper Network Connect,gp:Palo Alto GlobalProtect,fortinet:Fortinet SSL VPN,array:Array Networks|VPN 协议|连接"
  "DATA_CHANNEL|choice|dtls|dtls:ESP/DTLS（UDP，openconnect 默认）,tls:仅 TLS（--no-dtls）|数据通道|连接"
  "RECONNECT_TIMEOUT|int|300|60:1 分钟,300:5 分钟（openconnect 默认）,900:15 分钟|断网续连时长（秒）|连接"
  "MTU|text|auto|auto:自动,1400:1400,1300:1300,1200:1200|隧道 MTU|连接"
  "OC_EXTRA|text|||openconnect 附加参数|连接"
  "SOCKS_PORT|int|1080|1080:1080,8585:8585|SOCKS5 端口|代理"
  "LISTEN|choice|127.0.0.1|127.0.0.1:仅本机（经 SSH 隧道访问）,0.0.0.0:全部网卡（对外开放）|监听范围|代理"
  "SOCKS_AUTH|auth|||SOCKS5 认证|代理"
  "FORWARDER|choice|socat|socat:socat 进程转发（IPv4+IPv6 入口）,iptables:iptables 双 NAT（仅 IPv4 入口）|端口转发方式|代理"
  "KILL_SWITCH|choice|off|off:关（掉线期间代理改走 VPS 出口）,on:开（掉线期间代理直接失败）,proxy:回落代理（掉线期间改走指定代理，都不通则失败）|断线保护|安全"
  "FALLBACK_PROXY|text|auto|auto:自动（按顺序选第一个能连上的）|回落代理选择|安全"
  "DNS_FAST|choice|off|off:系统默认（每次等 5 秒）,on:快速重试（1 秒 × 3 次，轮换服务器）|DNS 超时策略|网络"
  "IPV6_FORWARD|choice|off|off:关,on:开|宿主 IPv6 转发|网络"
  "AUTO_RECONNECT|choice|on|on:开,off:关|自动重连|守护"
  "BACKOFF|text|5 30 60 120 300 600 900|5 30 60 120 300 600 900:默认,10 60 300 900:保守|重连退避（秒）|守护"
  "MAX_PER_HOUR|int|12|6:6 次,12:12 次,30:30 次|每小时最多重连|守护"
  "AUTH_FAIL_PAUSE|int|3|1:1 次,3:3 次,5:5 次|认证失败暂停阈值|守护"
  "DEGRADED_WAIT|int|90|30:30 秒,60:60 秒,90:90 秒,180:180 秒|隧道不通多久后软重连|守护"
  "SESSION_RESTART|text|off|off:关,110m:110 分钟（2 小时会话上限的学校推荐）,100m:100 分钟,90m:90 分钟|定时重连（会话满多久主动重连）|守护"
  "AUTOSTART|choice|off|off:关,on:开|开机自动连接|守护"
  "WATCH|choice|on|on:开,off:关|诊断日志|日志"
  "SAMPLE_INTERVAL|int|30|15:15 秒,30:30 秒,60:60 秒|采样间隔（秒）|日志"
  "LOG_MAX_MB|int|300|100:100 MB,300:300 MB,1000:1 GB|日志总量上限（MB）|日志"
  "EXTRA_PROBE_URL|text|||额外探测 URL|日志"
)
# 存储键（SOCKS_AUTH 是两项的组合，实际存 SOCKS_USER / SOCKS_PASS）
declare -A CFG=() SET_TYPE=() SET_DEF=() SET_CHOICES=() SET_TITLE=() SET_GROUP=()
SET_KEYS=()
for _e in "${SET_REGISTRY[@]}"; do
  IFS='|' read -r _k _t _d _c _ti _g <<<"$_e"
  SET_KEYS+=("$_k"); SET_TYPE[$_k]=$_t; SET_DEF[$_k]=$_d; SET_CHOICES[$_k]=$_c; SET_TITLE[$_k]=$_ti; SET_GROUP[$_k]=$_g
done
unset _e _k _t _d _c _ti _g
# 修改后需要重启 VPN 才生效的键（守护/日志类在运行中即时读取）
SET_NEEDS_RESTART=" ACCOUNT MODE PROTOCOL DATA_CHANNEL RECONNECT_TIMEOUT MTU OC_EXTRA SOCKS_PORT LISTEN SOCKS_AUTH FORWARDER KILL_SWITCH FALLBACK_PROXY DNS_FAST IPV6_FORWARD "

_set_help() {
  case "$1" in
    ACCOUNT) echo "使用账户文件（${ACCOUNTS_FILE}）里的第几个账户。账户的增删在主菜单「管理 VPN 账户」。";;
    MODE) cat <<'EOT'
netns   ：VPN 关在独立网络命名空间里，对外提供 SOCKS5 代理；本机 SSH 与其他服务完全不受影响。
          适合"只让部分程序走学校/公司网络"。需要 gost（SOCKS5 服务端）与 socat 或 iptables。
default ：整机流量走 VPN（自动配置 SSH 保护路由，避免失联）。会影响本机所有服务的出口，
          首次启动带 3 分钟保底自动回滚。
ocproxy ：用户态 SOCKS5（不建内核 tun），仅 IPv4、无认证、只监听本机；最轻量。
EOT
;;
    PROTOCOL) echo "VPN 服务器的类型，必须与服务器一致（不确定就看学校/公司的 VPN 说明页或客户端名称）。
单个账户可在账户文件第 6 列指定自己的协议，优先于这里的全局值。";;
    DATA_CHANNEL) echo "dtls：先用 TLS 建连，约 1 分钟后数据改走 UDP（ESP/DTLS），延迟低、吞吐高；
      但在丢包或限制 UDP 的网络里会更不稳定。
tls ：所有流量都走 TLS/TCP 隧道（--no-dtls）。稍多一点开销，丢包网络里通常更稳。
      实测：某 Juniper 网关白天 UDP 丢包严重时，改 tls 后代理失败率减半。";;
    RECONNECT_TIMEOUT) echo "网络闪断时 openconnect 自己尝试续连多久才放弃（--reconnect-timeout）。
注意：服务器主动结束会话（例如会话到期）时 openconnect 会直接退出，这个值管不到，由下面的「自动重连」负责。";;
    MTU) echo "隧道最大包长。auto 由 openconnect 与服务器协商；网页能开但大文件/某些站点卡住时可试 1400 或 1300。";;
    OC_EXTRA) echo "原样追加给 openconnect 的参数（空格分隔），例如 --useragent=xxx 或 --os=win。
留空即不加。高级选项：填错会导致连接失败。";;
    SOCKS_PORT) echo "SOCKS5 代理监听端口（netns / ocproxy 模式）。必须未被占用。";;
    LISTEN) echo "127.0.0.1：只有本机能连；从自己电脑使用时走 SSH 隧道：ssh -L 端口:127.0.0.1:端口 你的VPS。
0.0.0.0  ：任何人都能连到这个端口——务必同时开启 SOCKS5 认证，并用防火墙限制来源。
（ocproxy 模式始终只监听本机。）";;
    SOCKS_AUTH) echo "为 SOCKS5 设置用户名/密码（仅 netns 模式）。对外开放监听时强烈建议开启。
用户名不能含 @ : / 引号 反斜杠 空白；密码不能含 / 引号 反斜杠 空白（会破坏 URL 解析）。";;
    FORWARDER) echo "把宿主端口转进 netns 里的 SOCKS5：
socat   ：进程级中继，宿主侧 IPv4+IPv6 都可接入，最稳妥（默认）。
iptables：内核双 NAT，不多一个进程，但只有 IPv4 入口。";;
    KILL_SWITCH) echo "关      ：VPN 掉线/重连的那几秒里，代理仍有响应，但流量出口是 VPS 自己的 IP。
开      ：VPN 不通时代理直接失败（netns 内防火墙只放行隧道），保证流量绝不从 VPS 出口出去；
          代价是重连期间访问会报错。
回落代理：VPN 不通时，新连接自动改走「回落代理」列表里的代理（${PROXIES_FILE}），VPN 恢复后自动切回；
          回落期间建立的连接不会因切回而中断。代理都连不上时与「开」相同：直接失败，不走 VPS 出口。
          代理在主菜单 11「管理回落代理」或 ocm proxy add 添加，ocm proxy test 测试。
以上仅 netns 模式有效。";;
    FALLBACK_PROXY) echo "断线保护 = 回落代理 时用哪一个：
auto  ：每次掉线时按列表从上到下检测（TCP 连接测试），用第一个能连上的；正在用的代理断了会自动换下一个。
显示名：只用这一个；它连不上就直接失败。
列表：${PROXIES_FILE}（主菜单 11 或 ocm proxy list）。列表内容改了不用重启，下次掉线即按新内容。";;
    DNS_FAST) echo "VPN 下发的 DNS 若经常丢包，程序每丢一次查询要干等 5 秒，表现为网页时不时卡住。
on：在 netns 的 resolv.conf 加 options timeout:1 attempts:3 rotate，丢包后 1 秒就重试并轮换服务器。
仅 netns 模式；每次（重）连接后自动补上（vpnc-script 每次连接都会重写该文件）。";;
    IPV6_FORWARD) echo "netns 模式需要宿主开启 IPv4 转发（自动开、停止后按原值还原）。IPv6 转发只有在 VPN 下发了
IPv6 且你要经代理走 IPv6 时才需要；全局开启可能让宿主不再接受 IPv6 路由通告（RA）。不确定就保持关。";;
    AUTO_RECONNECT) echo "openconnect 退出后自动重新连接（服务器到期终止 → 约 2 秒后重连；网络错误 → 按退避间隔重试；
认证失败 → 计数，达到阈值即暂停，防止账号被锁）。关闭后掉线即停止并清理。";;
    BACKOFF) echo "网络类失败时的重试间隔序列（秒），第 N 次失败用第 N 个值，超出用最后一个。服务器到期终止不走退避。";;
    MAX_PER_HOUR) echo "1 小时内最多重连几次，超过则等到窗口滑出再试。防止异常时疯狂重试触发服务器风控。";;
    AUTH_FAIL_PAUSE) echo "连续几次认证失败（密码错误/账号被拒）后暂停自动重连，避免把账号锁掉。
首次启动就认证失败会立即停止。恢复：确认账号后 ocm heal on 或重新启动。";;
    DEGRADED_WAIT) echo "openconnect 进程还在、但经代理访问持续失败多少秒后，主动断开重连（软重连）。
太短会被 UDP 通道切换、短暂抖动误触发；太长则卡死的连接要更久才恢复。";;
    SESSION_RESTART) echo "会话满这个时长就主动重连一次：openconnect 先正常登出，约 1–2 秒后重新登录，代理中断几秒。
用途：服务器有固定会话时长（例如 2 小时就踢）时，赶在被踢之前、在自己定的时间点重连。
格式：110m / 110min / 1h50m / 2h / 纯数字＝分钟（不区分大小写）；最短 $((SESSION_RESTART_MIN / 60)) 分钟；off＝关闭。
时长从本次 openconnect 启动算起。改了立即生效（约 30 秒内），不用重启。
参考 ocm log report 里「会话结束时间轴」的会话时长来定，留几分钟余量。";;
    AUTOSTART) echo "开机后自动按当前设置连接（启用 systemd 单元 ocm.service）。";;
    WATCH) echo "后台诊断服务（ocm-watch.service）：定时采样隧道/代理/网关状态，记录状态变化与断线现场，
并负责「进程在但不通」时的软重连。日志在 ${LOG_DIR}，ocm log report 查看汇总。";;
    SAMPLE_INTERVAL) echo "诊断采样间隔。状态变化后会自动加密到 5 秒持续 3 分钟，平时用这个值。";;
    LOG_MAX_MB) echo "诊断日志目录总量上限，超出时从最旧的轮转文件开始删。磁盘剩余低于 400MB 时暂停写采样。";;
    EXTRA_PROBE_URL) echo "除公网探测外，额外经代理访问的 URL（例如图书馆数据库入口），用来确认校内资源可达。留空不测。";;
  esac
}

settings_defaults() { local k; for k in "${SET_KEYS[@]}"; do CFG[$k]=${SET_DEF[$k]}; done; CFG[SOCKS_USER]=""; CFG[SOCKS_PASS]=""; }
_is_cfg_key() { case " ${SET_KEYS[*]} SOCKS_USER SOCKS_PASS " in *" $1 "*) [ "$1" != SOCKS_AUTH ];; *) return 1;; esac; }

# 读取 KEY=<printf %q 值> 形式的文件到 CFG（只认白名单键；文件仅 root 可写）
_load_kv_file() {
  local f="$1" line k v
  [ -r "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
    k=${BASH_REMATCH[1]}; _is_cfg_key "$k" || continue
    eval "v=${BASH_REMATCH[2]}" 2>/dev/null || continue
    CFG[$k]=$v
  done < "$f"
}
settings_load() { settings_defaults; _load_kv_file "$SETTINGS_FILE"; }

settings_save() {
  local k tmp
  mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR" 2>/dev/null || true
  tmp=$(mktemp "${SETTINGS_FILE}.XXXXXX")
  {
    echo "# oc-master 设置（由 ocm 生成；可用 ocm 菜单「设置」或 ocm config set 修改）"
    for k in "${SET_KEYS[@]}" SOCKS_USER SOCKS_PASS; do
      [ "$k" = SOCKS_AUTH ] && continue
      printf '%s=%q\n' "$k" "${CFG[$k]:-}"
    done
  } > "$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$SETTINGS_FILE"
}

# 时长 → 秒：110m / 110min / 1h50m / 2h / 纯数字（分钟）；off、0、空 → 0；格式不对返回 1
_dur_to_s() {
  local v="${1,,}"; v=${v//[[:space:]]/}
  case "$v" in ""|off|0) echo 0; return 0 ;; esac
  if [[ "$v" =~ ^[0-9]{1,5}$ ]]; then echo $(( 10#$v * 60 )); return 0; fi
  [[ "$v" =~ ^(([0-9]{1,3})h)?(([0-9]{1,5})(m|min))?$ ]] || return 1
  [ -n "${BASH_REMATCH[2]}${BASH_REMATCH[4]}" ] || return 1
  echo $(( 10#${BASH_REMATCH[2]:-0} * 3600 + 10#${BASH_REMATCH[4]:-0} * 60 ))
}

# 校验：成功返回 0；失败打印原因返回 1
settings_validate() {
  local k="$1" v="$2" c ok=0 n
  case "$k" in
    SOCKS_PORT) [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] && [ "$v" -le 65535 ] || { log_err "端口应为 1-65535"; return 1; }; return 0;;
    MTU) [ "$v" = auto ] || { [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 576 ] && [ "$v" -le 9000 ]; } || { log_err "MTU 应为 auto 或 576-9000"; return 1; }; return 0;;
    BACKOFF) [[ "$v" =~ ^[0-9]+([[:space:]]+[0-9]+)*$ ]] || { log_err "退避序列应为空格分隔的秒数，例如 5 30 60"; return 1; }; return 0;;
    ACCOUNT) n=$(accounts_count); [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] && [ "$v" -le "${n:-0}" ] || { log_err "账户序号应为 1-${n:-0}"; return 1; }; return 0;;
    SOCKS_USER) [ -z "$v" ] && return 0
      case "$v" in *@*|*:*|*/*|*\"*|*\'*|*\\*|*[[:space:]]*) log_err "用户名不能含 @ : / 引号 反斜杠 空白"; return 1;; esac; return 0;;
    SOCKS_PASS) [ -z "$v" ] && return 0
      case "$v" in */*|*\"*|*\'*|*\\*|*[[:space:]]*) log_err "密码不能含 / 引号 反斜杠 空白"; return 1;; esac; return 0;;
    OC_EXTRA|EXTRA_PROBE_URL) case "$v" in *$'\n'*) log_err "不能含换行"; return 1;; esac; return 0;;
    FALLBACK_PROXY) [ -z "$v" ] || [ "$v" = auto ] || proxy_find "$v" >/dev/null || { log_err "回落代理选择应为 auto 或列表里某个代理的显示名（ocm proxy list）"; return 1; }; return 0;;
    SESSION_RESTART) local _s; _s=$(_dur_to_s "$v") || { log_err "定时重连格式：110m / 110min / 1h50m / 2h / 纯数字（分钟）/ off"; return 1; }
      [ "$_s" = 0 ] || [ "$_s" -ge "$SESSION_RESTART_MIN" ] || { log_err "定时重连最短 $((SESSION_RESTART_MIN / 60)) 分钟（或 off 关闭）"; return 1; }; return 0;;
  esac
  case "${SET_TYPE[$k]:-}" in
    choice) IFS=',' read -r -a _cs <<<"${SET_CHOICES[$k]}"
            for c in "${_cs[@]}"; do [ "${c%%:*}" = "$v" ] && ok=1; done
            [ $ok = 1 ] || { log_err "$k 只能是：$(for c in "${_cs[@]}"; do printf '%s ' "${c%%:*}"; done)"; return 1; } ;;
    int) [[ "$v" =~ ^[0-9]+$ ]] || { log_err "$k 应为整数"; return 1; } ;;
    "") log_err "未知设置项：$k"; return 1;;
  esac
  return 0
}

# 显示用：值 → 说明
cfg_label() {
  local k="$1" v="${2-${CFG[$1]:-}}" c
  case "$k" in
    SOCKS_AUTH) if [ -n "${CFG[SOCKS_USER]:-}" ]; then echo "${CFG[SOCKS_USER]}:****"; else echo "无"; fi; return;;
    ACCOUNT) echo "${v}) $(account_field "$v" 1 2>/dev/null || echo '?')"; return;;
    OC_EXTRA|EXTRA_PROBE_URL) echo "${v:-（空）}"; return;;
    FALLBACK_PROXY) if [ -z "$v" ] || [ "$v" = auto ]; then echo "自动（按顺序选第一个能连上的）"; else echo "固定：$v"; fi; return;;
    SESSION_RESTART) local _s; _s=$(_dur_to_s "$v" 2>/dev/null) || _s=""
      if [ -z "$_s" ]; then echo "${v}（格式无效，视为关）"; elif [ "$_s" = 0 ]; then echo "关"; else echo "会话满 $(fmt_dur "$_s") 主动重连（${v}）"; fi; return;;
  esac
  IFS=',' read -r -a _cs <<<"${SET_CHOICES[$k]:-}"
  for c in "${_cs[@]}"; do [ "${c%%:*}" = "$v" ] && { echo "${c#*:}"; return; }; done
  echo "$v"
}

# ============================================================================
#  账户（/root/.vpn_accounts.env）
#  格式：显示名|用户名|密码|VPN主机|认证组(可选)|协议(可选，覆盖全局 PROTOCOL)
#  密码只在 supervisor 里读取并经 stdin 交给 openconnect，不 export、不打印。
# ============================================================================
_accounts_lines() { grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$ACCOUNTS_FILE" 2>/dev/null || true; }
accounts_count() { _accounts_lines | wc -l; }
# account_field <序号> <列号>（只取需要的列，绝不取第 3 列给显示用）
account_field() { _accounts_lines | awk -F'|' -v n="$1" -v c="$2" 'NR==n{print $c; f=1} END{exit !f}'; }
# 按名称或序号解析为序号
account_resolve() {
  local a="$1"
  if [[ "$a" =~ ^[0-9]+$ ]]; then [ "$a" -ge 1 ] && [ "$a" -le "$(accounts_count)" ] && { echo "$a"; return 0; }; return 1; fi
  _accounts_lines | awk -F'|' -v a="$a" '$1==a{print NR; f=1; exit} END{exit !f}'
}
# 载入账户到全局变量（不 export）
account_load() {
  local line
  line=$(_accounts_lines | sed -n "${1}p")
  [ -n "$line" ] || { log_err "账户 #$1 不存在（${ACCOUNTS_FILE}）"; return 1; }
  IFS='|' read -r VPN_DESC VPN_USER VPN_PASS VPN_HOST VPN_GROUP VPN_ACC_PROTO <<<"$line"
  [ -n "$VPN_USER" ] && [ -n "$VPN_PASS" ] && [ -n "$VPN_HOST" ] || { log_err "账户 #$1 缺少用户名/密码/主机"; return 1; }
  return 0
}
accounts_list() {
  local n=0 name user host grp proto
  [ -f "$ACCOUNTS_FILE" ] || { echo "  （账户文件不存在：$ACCOUNTS_FILE）"; return 0; }
  while IFS='|' read -r name user _ host grp proto; do
    n=$((n+1)); printf '  %d) %s  用户:%s  主机:%s%s%s\n' "$n" "$name" "$user" "$host" \
      "${grp:+  认证组:$grp}" "${proto:+  协议:$proto}"
  done < <(_accounts_lines)
  [ $n -gt 0 ] || echo "  （无账户）"
}
gw_host_of() { local h; h=$(account_field "$1" 4 2>/dev/null || true); h=${h#https://}; h=${h#http://}; h=${h%%/*}; h=${h%%:*}; printf '%s' "$h"; }

# ============================================================================
#  回落代理（断线保护 = proxy：VPN 不通期间，SOCKS5 的新连接改走这里的代理）
#  文件：/etc/oc-master/proxies.conf（600，含明文密码）；格式见 _proxies_template（新建文件时写入文件头）。
#  每行先归一成 gost 的代理 URL，再交给 gost 本身解析（gost -F URL -O yaml），保证与 gost 行为一致。
# ============================================================================
_proxies_template() { cat <<'EOT'
# ocm 回落代理列表（设置「断线保护」= 回落代理 时使用）
# 本文件含明文密码，权限必须是 600：chmod 600 /etc/oc-master/proxies.conf
#
# VPN 掉线 / 重连期间，SOCKS5 代理的新连接改走这里的代理；VPN 恢复后新连接自动切回 VPN，
# 回落期间已建立的连接不受影响。代理都连不上时直接失败，绝不改走 VPS 自己的出口。
# 设置「回落代理选择」= auto（默认）时按从上到下的顺序，用第一个能连上的；也可以固定为某个显示名。
# 改完本文件不用重启：下一次掉线时自动按新内容生效。测试：ocm proxy test
#
# 每行一个代理，两种写法任选（# 开头为注释，空行忽略）：
#
# 写法一：竖线分列（推荐）
#   显示名|类型|地址|端口|用户名(可选)|密码(可选)
#   - 用户名、密码里有 @ : / % # ? 等字符直接照写，不用转义；密码在最后一列，里面有 | 也可以
#   - 没有认证就省略最后两列
#
# 写法二：URL
#   显示名|类型://用户名:密码@地址:端口[?参数]
#   - 第 2 列里有 :// 就按 URL 读取
#   - 用户名、密码里的特殊字符要按 URL 规则编码：@ → %40   : → %3A   / → %2F   % → %25   # → %23
#
# 类型（不区分大小写）：
#   socks5      SOCKS5。别名 s5、s5h、socks5h、socks 都按它处理；目标域名一律交给上游代理解析（即 s5h 的效果）
#   socks4      SOCKS4（没有密码，用户名可选）        socks4a   SOCKS4a
#   http        HTTP 代理（CONNECT）。别名 h
#   https       走 TLS 的 HTTP 代理（等同 http+tls）
#   ss          Shadowsocks：「用户名」填加密方式（如 aes-256-gcm、chacha20-ietf-poly1305），「密码」填密码
#   socks5+tls  套 TLS 的 SOCKS5
#   socks5+ws / socks5+wss   套 WebSocket（wss 带 TLS）的 SOCKS5；路径用 URL 写法加 ?path=/ws
#   不支持 vmess / vless / trojan / hysteria：先在本机用对应客户端开一个 socks5 端口，再把它填进来
#
# 地址：域名或 IPv4（暂不支持 IPv6 地址）。域名在宿主上解析（断线期间 netns 里不能做 DNS）。
#   代理就跑在这台 VPS 上时写 127.0.0.1 或 localhost：脚本会换成 192.168.200.1（netns 看到的宿主地址），
#   所以那个代理必须监听 0.0.0.0 或 192.168.200.1，只监听 127.0.0.1 是连不上的。
#
# 示例（去掉行首的 # 即可启用）：
# 香港备用|socks5|203.0.113.20|1080|user|p@ss:word
# 无认证S5|s5h|203.0.113.21|1080
# 公司HTTP|http|proxy.example.com|3128|alice|secret
# 日本SS|ss|203.0.113.30|8388|aes-256-gcm|ss-password
# TLS代理|https://bob:pa%40ss@proxy.example.com:443
# WS代理|socks5+wss://carol:pw@proxy.example.com:443?path=/ws
# 本机代理|socks5|127.0.0.1|7890
EOT
}
_proxies_ensure_file() {
  mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR" 2>/dev/null || true
  [ -f "$PROXIES_FILE" ] || ( umask 077; _proxies_template > "$PROXIES_FILE" )
  chmod 600 "$PROXIES_FILE" 2>/dev/null || true
}
_proxies_lines() { { tr -d '\r' < "$PROXIES_FILE" | grep -vE '^[[:space:]]*#|^[[:space:]]*$'; } 2>/dev/null || true; }
proxies_count() { _proxies_lines | wc -l; }
proxy_line() { _proxies_lines | sed -n "${1}p"; }
proxy_find() { _proxies_lines | awk -F'|' -v a="$1" '$1==a{print NR; f=1; exit} END{exit !f}'; }
# 序号或显示名 → 序号
proxy_resolve_ref() {
  local a="$1" n; n=$(proxies_count)
  if [[ "$a" =~ ^[0-9]+$ ]]; then [ "$a" -ge 1 ] && [ "$a" -le "$n" ] && { echo "$a"; return 0; }; return 1; fi
  proxy_find "$a"
}
# 类型别名 → gost 协议名。白名单之外一律拒绝：gost 遇到不认识的协议名会静默当成 http（实测 socks5h:// 即如此）
_proxy_norm_type() {
  case "${1,,}" in
    s5|s5h|socks|socks5|socks5h) echo socks5 ;;
    s4|socks4) echo socks4 ;;
    socks4a)   echo socks4a ;;
    h|http)    echo http ;;
    https|http+tls) echo http+tls ;;
    ss|shadowsocks) echo ss ;;
    socks5+tls|socks5+ws|socks5+wss) echo "${1,,}" ;;
    *) return 1 ;;
  esac
}
# URL 百分号编码（按字节，只保留 RFC 3986 的非保留字符）
_pct_enc() {
  local LC_ALL=C s="$1" i c o=""
  for ((i=0; i<${#s}; i++)); do
    c=${s:i:1}
    case "$c" in [A-Za-z0-9._~-]) o+=$c ;; *) printf -v c '%%%02X' "'$c"; o+=$c ;; esac
  done
  printf '%s' "$o"
}
# 解析一行 → P_NAME P_TYPE P_HOST P_PORT P_AUTH，P_URL（gost 用，含认证，只留在内存）；失败时设 P_ERR 并返回 1
proxy_parse() {
  local line="${1%$'\r'}" rest
  P_NAME=""; P_TYPE=""; P_HOST=""; P_PORT=""; P_URL=""; P_AUTH=0; P_ERR=""
  case "$line" in *"|"*) ;; *) P_ERR="缺少 | 分隔（应为 显示名|类型|地址|端口… 或 显示名|URL）"; return 1 ;; esac
  P_NAME=${line%%|*}; rest=${line#*|}
  [ -n "$P_NAME" ] || { P_ERR="显示名为空"; return 1; }
  if [[ "$rest" == *"://"* ]]; then
    local re='^([A-Za-z0-9+]+)://(([^@/?#]*)@)?([A-Za-z0-9.-]+):([0-9]{1,5})/?(\?[^#[:space:]]*)?$'
    [[ "$rest" =~ $re ]] || { P_ERR="URL 格式不对（类型://[用户名:密码@]地址:端口[?参数]；密码里的 @ : / 要写成 %40 %3A %2F）"; return 1; }
    local sch=${BASH_REMATCH[1]} ui=${BASH_REMATCH[3]} q=${BASH_REMATCH[6]}
    P_HOST=${BASH_REMATCH[4]}; P_PORT=${BASH_REMATCH[5]}
    P_TYPE=$(_proxy_norm_type "$sch") || { P_ERR="不支持的类型：$sch"; return 1; }
    [ -n "$ui" ] && P_AUTH=1
    P_URL="${P_TYPE}://${ui:+${ui}@}${P_HOST}:${P_PORT}${q}"
  else
    local t h p u pw ui="" r="$rest"
    # 逐列切出前 4 列，剩下的全部是密码（密码里可以有 |，结尾是 | 也保留；read 会吞掉结尾的 |）
    t=${r%%|*}; r=${r#"$t"}; r=${r#|}
    h=${r%%|*}; r=${r#"$h"}; r=${r#|}
    p=${r%%|*}; r=${r#"$p"}; r=${r#|}
    u=${r%%|*}; r=${r#"$u"}; r=${r#|}
    pw=$r
    P_TYPE=$(_proxy_norm_type "$t") || { P_ERR="不支持的类型：${t:-（空）}"; return 1; }
    P_HOST=$h; P_PORT=$p
    [[ "$P_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || { P_ERR="地址只能是域名或 IPv4：${P_HOST:-（空）}"; return 1; }
    [[ "$P_PORT" =~ ^[0-9]{1,5}$ ]] || { P_ERR="端口应为数字：${P_PORT:-（空）}"; return 1; }
    if [ -n "$u" ] || [ -n "$pw" ]; then
      ui=$(_pct_enc "$u"); [ -n "$pw" ] && ui+=":$(_pct_enc "$pw")"; P_AUTH=1
    fi
    P_URL="${P_TYPE}://${ui:+${ui}@}${P_HOST}:${P_PORT}"
  fi
  [ "$P_PORT" -ge 1 ] && [ "$P_PORT" -le 65535 ] || { P_ERR="端口应为 1-65535"; return 1; }
  [ "$P_TYPE" = ss ] && [ "$P_AUTH" = 0 ] && { P_ERR="ss 需要填加密方式（用户名列）和密码"; return 1; }
  return 0
}
# 代理地址 → IPv4。$2=ns：从 netns 看（本机代理换成 veth 宿主地址）；host：从宿主看
_proxy_ip() {
  local h="$1" ip=""
  if [[ "$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then ip=$h
  elif [ "${h,,}" = localhost ]; then ip=127.0.0.1
  else ip=$(timeout 5 getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}' || true); fi
  [ -n "$ip" ] || return 1
  [ "${2:-ns}" = ns ] && [[ "$ip" == 127.* ]] && ip=$VETH_HOST_IP
  printf '%s' "$ip"
}
_tcp_probe() { timeout 3 bash -c ">/dev/tcp/$1/$2" 2>/dev/null; }
# 生成 gost 配置：$1=URL $2=原地址 $3=实际 IP $4=代理端口 $5=监听（地址:端口）$6=监听是否带 SOCKS5 认证 $7=输出文件
_proxy_gen_yaml() {
  local url="$1" host="$2" ip="$3" port="$4" listen="$5" auth="$6" out="$7" gl tmp
  gl="socks5://${listen}"
  [ "$auth" = 1 ] && [ -n "${CFG[SOCKS_USER]:-}" ] && gl="socks5://${CFG[SOCKS_USER]}:${CFG[SOCKS_PASS]}@${listen}"
  tmp=$(umask 077; mktemp "${out}.XXXXXX") || return 1
  # gost -O 只打印解析后的配置就退出、不监听；URL（含密码）只在这一瞬间出现在 root 进程的参数里
  if ! timeout 10 gost -L "$gl" -F "$url" -O yaml > "$tmp" 2>/dev/null || ! grep -q '^chains:' "$tmp"; then rm -f "$tmp"; return 1; fi
  if [ "$host" != "$ip" ]; then
    # 节点地址换成已解析的 IP（断线期间 netns 里做不了 DNS）；TLS 的 serverName 仍保留原域名
    ( umask 077; awk -v from="addr: ${host}:${port}" -v to="addr: ${ip}:${port}" '
        /^chains:/ {c=1}
        c && !n && (i=index($0, from)) { $0=substr($0,1,i-1) to substr($0,i+length(from)); n=1 }
        {print} END{exit !n}' "$tmp" > "$tmp.2" ) || { rm -f "$tmp" "$tmp.2"; return 1; }
    mv -f "$tmp.2" "$tmp"
  fi
  chmod 600 "$tmp"; mv -f "$tmp" "$out"
}
proxies_list() {
  local n=0 line
  [ -f "$PROXIES_FILE" ] || { echo "  （代理文件不存在：$PROXIES_FILE）"; return 0; }
  while IFS= read -r line; do
    n=$((n+1))
    if proxy_parse "$line"; then
      printf '  %d) %s  %s  %s:%s%s\n' "$n" "$P_NAME" "$P_TYPE" "$P_HOST" "$P_PORT" "$( [ "$P_AUTH" = 1 ] && echo '  （有认证）')"
    else
      echo -e "  ${n}) ${C_RED}${line%%|*}  格式错误：${P_ERR}（这一行会被跳过）${C_RESET}"
    fi
  done < <(_proxies_lines)
  [ $n -gt 0 ] || echo "  （还没有回落代理）"
  return 0
}
# 从本机经该代理访问一次 https://api.ipify.org，打印出口 IP（即回落时网站看到的 IP）
proxy_test_one() {
  local line ip t0 t1 dir port pid eg i
  line=$(proxy_line "$1")
  proxy_parse "$line" || { printf '  %s) %s：格式错误：%s\n' "$1" "${line%%|*}" "$P_ERR"; return 1; }
  printf '  %s) %s（%s %s:%s）' "$1" "$P_NAME" "$P_TYPE" "$P_HOST" "$P_PORT"
  ip=$(_proxy_ip "$P_HOST" host) || { echo " → 域名解析失败 ❌"; return 1; }
  t0=$(ms_now)
  _tcp_probe "$ip" "$P_PORT" || { echo " → ${ip}:${P_PORT} TCP 连不上 ❌"; return 1; }
  t1=$(ms_now); printf ' → %s TCP %sms' "$ip" "$((t1 - t0))"
  command -v gost >/dev/null 2>&1 || { echo "，未安装 gost，跳过出口测试"; return 0; }
  dir=$(mktemp -d)
  for i in 1 2 3 4 5 6 7 8 9 10; do port=$(( RANDOM % 20000 + 30000 )); ss -Hlnt "sport = :$port" 2>/dev/null | grep -q . || break; done
  _proxy_gen_yaml "$P_URL" "$P_HOST" "$ip" "$P_PORT" "127.0.0.1:${port}" 0 "$dir/t.yaml" \
    || { echo "，gost 解析不了这个代理 ❌"; rm -rf "$dir"; return 1; }
  gost -C "$dir/t.yaml" >/dev/null 2>&1 & pid=$!
  for i in 1 2 3 4 5 6; do ss -Hlnt "sport = :$port" 2>/dev/null | grep -q . && break; sleep 0.5; done
  rm -f "$dir/t.yaml"
  eg=$("$CURL_CMD" -4 -s --connect-timeout 8 --max-time 15 -x "socks5h://127.0.0.1:${port}" https://api.ipify.org 2>/dev/null || true)
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -rf "$dir"
  if [[ "$eg" =~ ^[0-9.]+$ ]]; then echo "，经代理出口 ${eg} ✅"; return 0; fi
  echo "，经代理访问失败（认证 / 协议 / 代理自身网络？）❌"; return 1
}
proxy_test_all() {
  local n i; n=$(proxies_count)
  [ "$n" -gt 0 ] || { echo "  （还没有回落代理）"; return 0; }
  echo "从本机经各代理访问 https://api.ipify.org（显示的出口 IP 就是回落时网站看到的 IP）："
  for ((i=1; i<=n; i++)); do proxy_test_one "$i" || true; done
  return 0
}
_proxy_name_ok() {
  local d="$1"
  [ -n "$d" ] || { log_err "显示名不能为空"; return 1; }
  case "$d" in *"|"*) log_err "显示名不能含 |"; return 1 ;; esac
  [ "$d" = auto ] && { log_err "auto 是保留字，换一个显示名"; return 1; }
  proxy_find "$d" >/dev/null && { log_err "已有同名代理：$d"; return 1; }
  return 0
}
# 校验后追加一行（竖线或 URL 写法）
proxy_add_line() {
  local line="${1%$'\r'}"
  proxy_parse "$line" || { log_err "格式错误：$P_ERR（格式说明：ocm proxy format）"; return 1; }
  _proxy_name_ok "$P_NAME" || return 1
  _proxies_ensure_file
  printf '%s\n' "$line" >> "$PROXIES_FILE"; chmod 600 "$PROXIES_FILE"
  ev "CONFIG proxy add name=${P_NAME// /_} type=$P_TYPE addr=${P_HOST}:${P_PORT}"
  log "已添加回落代理：${P_NAME}（${P_TYPE} ${P_HOST}:${P_PORT}$( [ "$P_AUTH" = 1 ] && echo '，有认证')）"
  return 0
}
proxy_add_interactive() {
  local d t h p u="" pw="" path line yn ui=""
  echo "类型：socks5（s5 / s5h） socks4  socks4a  http  https  ss  socks5+tls  socks5+ws  socks5+wss"
  read -rp "显示名: " d || return 1; _proxy_name_ok "$d" || return 1
  read -rp "类型 [socks5]: " t || return 1
  t=$(_proxy_norm_type "${t:-socks5}") || { log_err "不支持的类型"; return 1; }
  read -rp "地址（域名或 IPv4；代理在本机就填 127.0.0.1）: " h || return 1
  read -rp "端口: " p || return 1
  case "$t" in
    ss) read -rp "加密方式 [aes-256-gcm]: " u || return 1; u=${u:-aes-256-gcm}
        read -rsp "密码: " pw || return 1; echo ;;
    socks4|socks4a) read -rp "用户名（可选，回车跳过）: " u || return 1 ;;
    *) read -rp "用户名（可选，回车跳过）: " u || return 1
       if [ -n "$u" ]; then read -rsp "密码: " pw || return 1; echo; fi ;;
  esac
  if [[ "$t" == *+ws || "$t" == *+wss ]]; then
    read -rp "WebSocket 路径 [/ws]: " path || return 1; path=${path:-/ws}; [[ "$path" == /* ]] || path="/$path"
    if [ -n "$u$pw" ]; then ui=$(_pct_enc "$u"); [ -n "$pw" ] && ui+=":$(_pct_enc "$pw")"; ui+="@"; fi
    line="${d}|${t}://${ui}${h}:${p}?path=$(_pct_enc "$path")"
  else
    line="${d}|${t}|${h}|${p}"
    [ -n "$u$pw" ] && line+="|${u}"
    [ -n "$pw" ] && line+="|${pw}"
  fi
  proxy_add_line "$line" || return 1
  read -rp "现在测试这个代理? [Y/n]: " yn || yn=n
  [[ "$yn" =~ ^[nN]$ ]] || proxy_test_one "$(proxy_find "$d")" || true
  return 0
}
proxy_del() {
  local i name
  i=$(proxy_resolve_ref "$1") || { log_err "找不到代理：$1"; return 1; }
  name=$(proxy_line "$i" | cut -d'|' -f1)
  ( umask 077; awk -v n="$i" '/^[[:space:]]*#/ || /^[[:space:]]*$/ {print; next} {k++; if (k!=n) print}' "$PROXIES_FILE" > "${PROXIES_FILE}.tmp" ) \
    || { log_err "删除失败：无法写入临时文件"; rm -f "${PROXIES_FILE}.tmp"; return 1; }
  mv -f "${PROXIES_FILE}.tmp" "$PROXIES_FILE"; chmod 600 "$PROXIES_FILE"
  ev "CONFIG proxy del name=${name// /_}"; log "已删除：$name"
  settings_load
  if [ "${CFG[FALLBACK_PROXY]}" = "$name" ]; then
    CFG[FALLBACK_PROXY]=auto; settings_save; ev "CONFIG FALLBACK_PROXY: ${name// /_} -> auto"
    log_warn "「回落代理选择」原来固定为它，已改回 auto（VPN 正在运行的话重启后生效）。"
  fi
  return 0
}
proxy_choose() {
  local a v i old
  proxies_list
  read -rp "输入序号或显示名 = 固定只用它；a = 改回自动（回车取消）: " a || return 0
  [ -z "$a" ] && return 0
  if [ "$a" = a ] || [ "$a" = auto ]; then v=auto
  else i=$(proxy_resolve_ref "$a") || { log_err "找不到代理：$a"; return 1; }; v=$(proxy_line "$i" | cut -d'|' -f1); fi
  settings_load; old=${CFG[FALLBACK_PROXY]}; CFG[FALLBACK_PROXY]=$v; settings_save
  ev "CONFIG FALLBACK_PROXY: ${old// /_} -> ${v// /_}"; log "回落代理选择：$(cfg_label FALLBACK_PROXY)"
  _settings_restart_note FALLBACK_PROXY cfg
  return 0
}
manage_proxies() {
  _proxies_ensure_file
  local c a fs fa fn
  while true; do
    clear 2>/dev/null || true; settings_load
    title "🔀 管理回落代理 (${PROXIES_FILE})"; sep
    echo -e "  断线保护：${C_CYAN}$(cfg_label KILL_SWITCH)${C_RESET}   回落代理选择：${C_CYAN}$(cfg_label FALLBACK_PROXY)${C_RESET}"
    [ "${CFG[KILL_SWITCH]}" = proxy ] || echo -e "  ${C_GREY}（「断线保护」设为「回落代理」后才会用这里的代理：主菜单 5 → 断线保护）${C_RESET}"
    if [ -r "$FB_STATE_FILE" ]; then read -r fs fa fn < "$FB_STATE_FILE"; echo -e "  ${C_YELLOW}正在使用：${fn}（${fa}）${C_RESET}"; fi
    sep; proxies_list; sep
    echo "  1) 添加（逐项填写）     2) 添加（粘贴一行：竖线或 URL 写法）     3) 删除"
    echo "  4) 测试全部（显示出口 IP）  5) 设置用哪一个（自动 / 固定）     6) 格式说明"
    echo "  0) 返回                 也可以直接编辑 ${PROXIES_FILE}（改完无需重启）"
    read -rp "选择: " c || return 0
    case "$c" in
      1) proxy_add_interactive || true; _pause ;;
      2) read -rsp "粘贴一行后回车（输入不回显）: " a || a=""; echo
         if [ -n "$a" ]; then proxy_add_line "$a" || true; fi; _pause ;;
      3) read -rp "要删除的序号或显示名: " a || a=""
         if [ -n "$a" ]; then proxy_del "$a" || true; fi; _pause ;;
      4) proxy_test_all; _pause ;;
      5) proxy_choose || true; _pause ;;
      6) _proxies_template | less -R -F -X || true ;;
      0|"") return 0 ;;
      *) log_err "无效选项"; sleep 1 ;;
    esac
  done
}
cmd_proxy() {
  check_root; settings_load
  local sub="${1:-list}" i; shift || true
  case "$sub" in
    list|ls) echo "回落代理（${PROXIES_FILE}）  断线保护：$(cfg_label KILL_SWITCH)  选择：$(cfg_label FALLBACK_PROXY)"; proxies_list ;;
    add)     if [ $# -ge 1 ]; then proxy_add_line "$1" || return 2; else proxy_add_interactive || return 1; fi ;;
    del|rm)  [ $# -ge 1 ] || { log_err "用法：ocm proxy del <序号|显示名>"; return 2; }; proxy_del "$1" || return 1 ;;
    test)    if [ $# -ge 1 ]; then i=$(proxy_resolve_ref "$1") || { log_err "找不到代理：$1"; return 2; }; proxy_test_one "$i" || return 1
             else proxy_test_all; fi ;;
    format)  _proxies_template ;;
    path)    echo "$PROXIES_FILE" ;;
    *) log_err "用法：ocm proxy list | add ['一行'] | del <序号|名称> | test [序号|名称] | format | path"; return 2 ;;
  esac
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
  # 清一次旧版本遗留的 OUTPUT 规则：旧版"对全网开放"那条没有 addrtype 限制，如果 state 文件
  # 丢了（/var/run 被清、或跨模式异常），它既删不掉也发现不了——而它会排在新规则前面，
  # 于是本机发往外部主机同端口的流量仍被劫持，表现为"升级了却没变化"。
  "$IPTABLES_CMD" -t nat -D OUTPUT -p tcp --dport "${socks_port}" -j DNAT --to-destination "${dst}" 2>/dev/null || true
  if [ "$listen_addr" = "0.0.0.0" ] || [ "$listen_addr" = "::" ]; then
    # 对全网开放：本机产生的流量走 OUTPUT、外部来的走 PREROUTING，两条都要有。
    # OUTPUT 这条用 addrtype 限定"目标是本机地址"：既覆盖 127.0.0.1 与本机的内网 IP
    # （后者实测只加 PREROUTING 是连不上的——本机流量根本不经过 PREROUTING），又不会把
    # 本机主动发往外部主机同一端口的流量也劫持进来。addrtype 实测可用：目标是本机地址
    # 时计数增加、目标是 1.1.1.1 时计数不变。
    R_OUT="-p tcp -m addrtype --dst-type LOCAL --dport ${socks_port} -j DNAT --to-destination ${dst}"
    R_PRE="-p tcp --dport ${socks_port} -j DNAT --to-destination ${dst}"
  else
    # 只监听本地：限定目标为 127.0.0.1，且不加 PREROUTING —— 语义与 socat bind 127.0.0.1 一致
    R_OUT="-p tcp -d 127.0.0.1 --dport ${socks_port} -j DNAT --to-destination ${dst}"
  fi
  # 关键前提：本机产生的流量经 OUTPUT DNAT 后，源地址仍然是 127.0.0.1。DNAT 之后
  # netfilter 会重新做一次路由（ip_route_me_harder），内核按 route_localnet 判断
  # 127.0.0.0/8 能不能从"这个接口"出去；默认 0 = 不能，包被当 martian 丢弃，
  # 连 POSTROUTING 都到不了（实测：DNAT 计数一路涨、SNAT 计数恒为 0、veth 抓不到包）。
  # 内核取值是 IN_DEV_ORCONF —— all 与接口值取 OR，所以只放开这个 veth 就够，
  # 不必动全局 all；影响面限于本脚本自己建的接口，veth 删除后设置随之消失。
  sysctl -w "net.ipv4.conf.${VETH_HOST}.route_localnet=1" >/dev/null 2>&1 || true

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

# v7 的 stop_vpn 原样保留为底层清理函数（按 state 拆除各模式的进程、路由、netns）。
_teardown_session() {
  # state 文件在时不能早退：失败的启动已写 state 并配好策略路由，早退会跳过
  # cleanup_ssh_protect_routes 和 rm —— 残留 ip rule 和 state（实测 iprule 4 行残留；
  # 装了守护任务还会每 5 分钟拿坏账户重连一次）。
  if ! is_vpn_running && ! [ -f "$GOST_PID_FILE" ] && ! [ -f "$SOCAT_PID_FILE" ] && ! [ -f "$STATE_FILE" ] && ! [ -f "$SYSCTL_STATE_FILE" ]; then log_info "VPN 未运行"; return; fi
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
      [ -f "$FB_GOST_PID_FILE" ] && kill "$(cat "$FB_GOST_PID_FILE")" 2>/dev/null || true
      if [ -f "$PID_FILE" ]; then
        local oc_pid; oc_pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
        # 同 default|ocproxy：pid 文件可能是过期记录，先确认身份再发信号
        if [ -n "$oc_pid" ] && [ "$(cat /proc/${oc_pid}/comm 2>/dev/null)" = "openconnect" ]; then
          kill "$oc_pid" 2>/dev/null || true
          # 必须等 openconnect 自己退出再拆 netns/veth：它要先向网关登出，
          # 而登出走的就是 veth→NAT 这条路（先拆掉就会卡在 TLS 超时上，见 _wait_pid_gone）。
          _wait_pid_gone "$oc_pid"
        fi
      fi
      cleanup_netns
      ;;
    default|ocproxy)
      log_info "正在停止 ${MODE} 模式..."
      # 与 netns 分支同理：kill 之后立刻收尾会留下"还在登出"的 openconnect（实测 stop 后
      # 1 秒仍能看到该进程，约 2-3 秒后才自行退出）；用户紧接着重新启动就会和它打架。
      # default 模式的登出走 eth0，而策略路由此刻还在，所以先等它退出、再清路由。
      local oc_pid=""
      [ -f "$PID_FILE" ] && oc_pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
      # 发信号前先确认这个 pid 真的是 openconnect：pid 文件可能是过期记录（例如上一条连接
      # 被 kill -9、来不及 unlink），而那个 pid 早已被内核复用给别的进程——照原样 kill 并
      # 等待会误伤它（_wait_pid_gone 到最后还会升级成 SIGKILL）。
      if [ -n "$oc_pid" ] && [ "$(cat /proc/${oc_pid}/comm 2>/dev/null)" = "openconnect" ]; then
        kill "$oc_pid" 2>/dev/null || true
        _wait_pid_gone "$oc_pid"
      fi
      [ "$MODE" = "default" ] && cleanup_ssh_protect_routes
      ;;
    *)
      log_warn "状态文件不存在或模式未知，执行通用清理..."
      # netns 模式"写 state 之前"就失败时正好落到这里（state 里没有 MODE）：同样要先等
      # openconnect 退出再拆 netns/veth，否则它会卡在登出上（见 _wait_pid_gone）。
      local oc_pid=""; [ -f "$PID_FILE" ] && oc_pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
      if [ -n "$oc_pid" ] && [ "$(cat /proc/${oc_pid}/comm 2>/dev/null)" = "openconnect" ]; then
        kill "$oc_pid" 2>/dev/null || true
        _wait_pid_gone "$oc_pid"
      fi
      [ -f "$GOST_PID_FILE" ] && kill "$(cat "$GOST_PID_FILE")" 2>/dev/null || true
      [ -f "$FB_GOST_PID_FILE" ] && kill "$(cat "$FB_GOST_PID_FILE")" 2>/dev/null || true
      [ -f "$SOCAT_PID_FILE" ] && kill "$(cat "$SOCAT_PID_FILE")" 2>/dev/null || true
      [ -f "$SOCAT_PID_FILE_V6" ] && kill "$(cat "$SOCAT_PID_FILE_V6")" 2>/dev/null || true
      cleanup_ssh_protect_routes
      cleanup_netns
      ;;
  esac
  
  # SYSCTL_STATE_FILE 不在这里无条件删除：它是"把转发开关还原回去"的唯一依据，只由
  # cleanup_netns 在还原之后删。否则一旦出现"netns 会话被 kill -9 → 用户改用 default
  # 模式 → 这次 stop 走 default 分支（不调 cleanup_netns）"这种跨模式序列，记录会被删掉
  # 而 ip_forward 已经变成 1，就再也没有还原依据了。
  rm -f "$PID_FILE" "$STATE_FILE" "$GOST_PID_FILE" "$SOCAT_PID_FILE" "$SOCAT_PID_FILE_V6" "$FB_GOST_PID_FILE" "$FB_STATE_FILE" "$FB_YAML"; log "所有临时文件已清理，操作完成。"
}

# ============================================================================
#  systemd 托管
# ----------------------------------------------------------------------------
#  ocm.service       → `ocm _supervise`：建 netns/路由 → 前台运行 openconnect → 退出后按原因重连。
#                      KillMode=mixed：停止时只给 supervisor 发 SIGTERM，由它先让 openconnect
#                      登出、再拆代理与 netns（顺序反了 openconnect 会卡在登出上）。
#  ocm-watch.service → `ocm _watch`：只读诊断采样 + 「进程在但不通」时请求软重连。
#  VPN 进程属于 systemd，与登录会话无关：关掉 SSH 不会连带杀掉 gost/socat/openconnect。
# ============================================================================
svc_active() { systemctl is-active --quiet "$SVC_MAIN" 2>/dev/null; }
set_phase() { mkdir -p "$RUN_DIR"; printf '%s %s\n' "$1" "$(now_s)" > "$PHASE_FILE.tmp" && mv -f "$PHASE_FILE.tmp" "$PHASE_FILE"; }
get_phase() { awk '{print $1; exit}' "$PHASE_FILE" 2>/dev/null || true; }
get_phase_since() { awk '{print $2; exit}' "$PHASE_FILE" 2>/dev/null || true; }

_unit_main() { cat <<EOF
[Unit]
Description=OpenConnect Master (ocm) VPN supervisor
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
Type=simple
ExecStart=${SCRIPT_PATH} _supervise
KillMode=mixed
TimeoutStopSec=45
Restart=on-failure
RestartSec=10
RestartPreventExitStatus=3

[Install]
WantedBy=multi-user.target
EOF
}
_unit_watch() { cat <<EOF
[Unit]
Description=OpenConnect Master (ocm) diagnostic logger
After=network-online.target

[Service]
Type=simple
ExecStart=${SCRIPT_PATH} _watch
Restart=always
RestartSec=5
Nice=10
IOSchedulingClass=idle
MemoryMax=96M
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF
}

install_units() {
  case "$SCRIPT_PATH" in /tmp/*|/var/tmp/*) log_err "脚本位于临时目录（$SCRIPT_PATH），先移到固定位置（如 /root/oc_master.sh）再使用 systemd 托管。"; return 1;; esac
  command -v systemctl >/dev/null 2>&1 || { log_err "本系统没有 systemd，v8 的托管模式不可用。"; return 1; }
  local changed=0 u content
  for u in main watch; do
    local path="$UNIT_DIR/$SVC_MAIN"; [ $u = watch ] && path="$UNIT_DIR/$SVC_WATCH"
    content="$(_unit_$u)"
    if [ "$(cat "$path" 2>/dev/null)" != "$content" ]; then printf '%s\n' "$content" > "$path"; changed=1; fi
  done
  [ $changed = 1 ] && systemctl daemon-reload
  apply_service_prefs
  return 0
}
uninstall_units() {
  systemctl disable --now "$SVC_WATCH" >/dev/null 2>&1 || true
  systemctl stop "$SVC_MAIN" >/dev/null 2>&1 || true
  systemctl disable "$SVC_MAIN" >/dev/null 2>&1 || true
  rm -f "$UNIT_DIR/$SVC_MAIN" "$UNIT_DIR/$SVC_WATCH"
  systemctl daemon-reload 2>/dev/null || true
}
# 诊断服务与开机自启按设置同步（只在状态不一致时动作）
apply_service_prefs() {
  [ -f "$UNIT_DIR/$SVC_WATCH" ] || return 0
  if [ "${CFG[WATCH]:-on}" = on ]; then
    systemctl is-enabled --quiet "$SVC_WATCH" 2>/dev/null || systemctl enable "$SVC_WATCH" >/dev/null 2>&1 || true
    systemctl is-active --quiet "$SVC_WATCH" 2>/dev/null || systemctl start "$SVC_WATCH" >/dev/null 2>&1 || true
  else
    systemctl disable --now "$SVC_WATCH" >/dev/null 2>&1 || true
  fi
  if [ "${CFG[AUTOSTART]:-off}" = on ]; then
    systemctl is-enabled --quiet "$SVC_MAIN" 2>/dev/null || systemctl enable "$SVC_MAIN" >/dev/null 2>&1 || true
  else
    systemctl is-enabled --quiet "$SVC_MAIN" 2>/dev/null && systemctl disable "$SVC_MAIN" >/dev/null 2>&1 || true
  fi
  return 0
}

# ============================================================================
#  supervisor（由 systemd 以 `ocm _supervise` 运行，不要手动调用）
# ============================================================================
SUP_STOP=0; OC_PID=""; GOST_PID=""; SESSION_N=0; EVER_UP=0; OC_START=0; PAUSED_REASON=""
GW_NAME=""; GW_IP=""; LAUNCH_LOG=""
declare -A LIVE=()
OC_ARGS=(); OC_PREFIX=()
OC_KEY_RE='dead peer|DPD|reconnect|terminat|closed|fail|error|expired|exiting|cancel|establish|unexpected|time ?out|rekey|lost|disconnect|logout|refused|unauthor|denied|ESP|DTLS|keepalive|idle|session|killed|signal|Configured as'

sup_log() {
  local t; printf -v t '%(%F %T)T' -1
  printf '[%s] %s\n' "$t" "$*"
  [ -n "$LAUNCH_LOG" ] && printf '[%s] %s\n' "$t" "$*" >> "$LAUNCH_LOG" 2>/dev/null
  return 0
}
# 守护类设置在运行中即时生效：每轮从设置文件重读，不影响本次连接参数
live_reload() {
  local k; local -A bak=()
  for k in "${!CFG[@]}"; do bak[$k]=${CFG[$k]}; done
  settings_load
  for k in AUTO_RECONNECT BACKOFF MAX_PER_HOUR AUTH_FAIL_PAUSE SESSION_RESTART; do LIVE[$k]=${CFG[$k]}; done
  for k in "${!bak[@]}"; do CFG[$k]=${bak[$k]}; done
}
sup_proto() { echo "${VPN_ACC_PROTO:-${CFG[PROTOCOL]}}"; }

sup_build_oc() {
  OC_ARGS=(openconnect "$VPN_HOST" "--protocol=$(sup_proto)" "--user=$VPN_USER" --passwd-on-stdin --non-inter)
  [ -n "${VPN_GROUP:-}" ] && OC_ARGS+=("--authgroup=$VPN_GROUP")
  [ "${CFG[DATA_CHANNEL]}" = tls ] && OC_ARGS+=(--no-dtls)
  [[ "${CFG[RECONNECT_TIMEOUT]}" =~ ^[0-9]+$ ]] && OC_ARGS+=("--reconnect-timeout=${CFG[RECONNECT_TIMEOUT]}")
  [ "${CFG[MTU]}" != auto ] && OC_ARGS+=("--mtu=${CFG[MTU]}")
  [ "${CFG[MODE]}" = ocproxy ] && OC_ARGS+=(--script-tun --script "ocproxy -k 30 -D ${CFG[SOCKS_PORT]}")
  # 默认全局模式用固定网卡名：宿主上可能已有别的 tun0（组网/其他 VPN），不能靠"任意 tun"判断
  [ "${CFG[MODE]}" = default ] && OC_ARGS+=("--interface=$OC_TUN_DEFAULT")
  [ "${CFG[MODE]}" = netns ] && [[ "${CFG[KILL_SWITCH]}" =~ ^(on|proxy)$ ]] && [ -n "$GW_IP" ] && OC_ARGS+=("--resolve=${GW_NAME}:${GW_IP}")
  if [ -n "${CFG[OC_EXTRA]}" ]; then local -a _x; read -r -a _x <<<"${CFG[OC_EXTRA]}"; OC_ARGS+=("${_x[@]}"); fi
  OC_PREFIX=(); [ "${CFG[MODE]}" = netns ] && OC_PREFIX=("$IP_CMD" netns exec "$NETNS_NAME")
  return 0
}

# openconnect 输出 → openconnect.log（带时间）、当前会话文件、journald；关键句进 events.log
oc_log_pipe() { # $1=会话号 $2=是否写入启动日志
  local line t e
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | redact)
    printf -v t '%(%Y-%m-%dT%H:%M:%S%z)T' -1; printf -v e '%(%s)T' -1
    printf '%s openconnect[s%s] %s\n' "$t" "$1" "$line" >> "$OCLOG" 2>/dev/null
    printf '%s\n' "$line" >> "$SESSION_LOG" 2>/dev/null
    printf 'openconnect: %s\n' "$line"
    [ "$2" = 1 ] && [ -n "$LAUNCH_LOG" ] && printf '    %s\n' "$line" >> "$LAUNCH_LOG" 2>/dev/null
    [[ "$line" =~ $OC_KEY_RE ]] && printf '%s e=%s OC s=%s msg=%s\n' "$t" "$e" "$1" "$line" >> "$EVENTS" 2>/dev/null
  done
  return 0
}

sup_launch_oc() {
  SESSION_N=$((SESSION_N+1)); : > "$SESSION_LOG"
  local first=0; [ "$EVER_UP" = 0 ] && first=1
  # 密码只经 stdin 交给 openconnect；$! 是管线最后一个进程（openconnect 本身；ip netns exec 会 exec 成它）
  printf '%s\n' "$VPN_PASS" | "${OC_PREFIX[@]}" "${OC_ARGS[@]}" > >(oc_log_pipe "$SESSION_N" "$first") 2>&1 &
  OC_PID=$!; OC_START=$(now_s)
  echo "$OC_PID" > "$PID_FILE"
}

sup_tunnel_up() {
  case "${CFG[MODE]}" in
    netns)   "$IP_CMD" -n "$NETNS_NAME" route show default 2>/dev/null | _gq 'dev tun' && "$IP_CMD" -n "$NETNS_NAME" link show 2>/dev/null | _gq 'tun.*UP' ;;
    default) "$IP_CMD" link show dev "$OC_TUN_DEFAULT" 2>/dev/null | _gq 'UP' ;;
    ocproxy) ss -Hlnt "sport = :${CFG[SOCKS_PORT]}" 2>/dev/null | _gq . ;;
  esac
}

sup_write_state() {
  local vps; vps=$(grep -E '^VPS[46]=' "$STATE_FILE" 2>/dev/null || true)
  {
    [ -n "$vps" ] && printf '%s\n' "$vps"
    echo "MODE=${CFG[MODE]}"; echo "ACCOUNT_INDEX=$(( CFG[ACCOUNT] - 1 ))"; echo "VPN_PROTOCOL=$(sup_proto)"
    if [ "${CFG[MODE]}" != default ]; then
      echo "SOCKS_PORT=${CFG[SOCKS_PORT]}"
      if [ "${CFG[MODE]}" = netns ]; then echo "LISTEN_ADDR=${CFG[LISTEN]}"; else echo "LISTEN_ADDR=127.0.0.1"; fi
    fi
    if [ "${CFG[MODE]}" = netns ]; then
      echo "GOST_PID=${GOST_PID:-}"; echo "FORWARDER=${_FWD_DESC:-}"
      [ -n "${CFG[SOCKS_USER]}" ] && printf 'SOCKS_USER=%q\nSOCKS_PASS=%q\n' "${CFG[SOCKS_USER]}" "${CFG[SOCKS_PASS]}"
      [ -n "${_FWD_STATE:-}" ] && printf '%s\n' "$_FWD_STATE"
    fi
    echo "KILL_SWITCH=${CFG[KILL_SWITCH]}"
  } > "$STATE_FILE.tmp"
  chmod 600 "$STATE_FILE.tmp"; mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

# netns 里的 SOCKS5（gost）+ 宿主转发：首次隧道就绪后启动，之后重连期间保持不动
sup_start_proxy() {
  local port="${CFG[SOCKS_PORT]}" gl="socks5://${VETH_NS_IP}:${CFG[SOCKS_PORT]}" _r
  [ -n "${CFG[SOCKS_USER]}" ] && gl="socks5://${CFG[SOCKS_USER]}:${CFG[SOCKS_PASS]}@${VETH_NS_IP}:${port}"
  # 只监听 veth 地址：宿主转发（socat / iptables）都连这里。不写地址会连 tun0 也监听，而 tun0 的地址是
  # VPN 分配的公网地址——外部经 VPN 网关就能直连，变成无认证的开放代理（v8.1.0 及以前的实测问题）。
  "$IP_CMD" netns exec "$NETNS_NAME" gost -L="$gl" >/dev/null 2>&1 &
  # 保险：再拒绝从隧道网卡进来的这个端口（IPv4/IPv6）；规则随 netns 删除而消失
  for _r in iptables ip6tables; do "$IP_CMD" netns exec "$NETNS_NAME" "$_r" -w -C INPUT -i tun+ -p tcp --dport "$port" -j DROP 2>/dev/null || "$IP_CMD" netns exec "$NETNS_NAME" "$_r" -w -I INPUT 1 -i tun+ -p tcp --dport "$port" -j DROP 2>/dev/null || true; done
  GOST_PID=$!; echo "$GOST_PID" > "$GOST_PID_FILE"
  sleep 1; kill -0 "$GOST_PID" 2>/dev/null || { sup_log "gost 在 netns 中启动失败"; return 1; }
  if [ -z "${_FWD_DESC:-}" ]; then
    _FWD_DESC=""; _FWD_STATE=""
    _fwd_setup "${CFG[FORWARDER]}" "$port" "${CFG[LISTEN]}" >/dev/null || { sup_log "端口转发（${CFG[FORWARDER]}）配置失败"; return 1; }
  fi
  sup_write_state
  sup_log "SOCKS5 已就绪：${CFG[LISTEN]}:${port}（gost pid $GOST_PID，转发 ${_FWD_DESC}）"
  return 0
}
# gost / socat 意外退出时就地拉起
sup_check_children() {
  [ "${CFG[MODE]}" = netns ] || return 0
  if [ -n "$GOST_PID" ] && ! kill -0 "$GOST_PID" 2>/dev/null; then
    ev "SUP child-died gost pid=$GOST_PID → restart"; sup_log "gost 已退出，重新启动"; sup_start_proxy || true
  fi
  if [ "${_FWD_DESC:-}" = socat ]; then
    local sp; sp=$(cat "$SOCAT_PID_FILE" 2>/dev/null || true)
    if [[ "$sp" =~ ^[0-9]+$ ]] && ! kill -0 "$sp" 2>/dev/null; then
      ev "SUP child-died socat pid=$sp → restart"; sup_log "socat 已退出，重新配置转发"
      _FWD_STATE=""; _fwd_setup socat "${CFG[SOCKS_PORT]}" "${CFG[LISTEN]}" >/dev/null && sup_write_state
    fi
  fi
  [ "${CFG[DNS_FAST]}" = on ] && dns_fast_apply
  return 0
}

# DNS 快速重试（仅 netns）：vpnc-script 每次连接都会重写 resolv.conf，所以每次就绪后补一行
dns_fast_apply() {
  local f="/etc/netns/${NETNS_NAME}/resolv.conf"
  [ -f "$f" ] && grep -q 'VPNC_GENERATED' "$f" 2>/dev/null || return 0
  grep -q '^options .*timeout:1' "$f" 2>/dev/null || { printf 'options timeout:1 attempts:3 rotate\n' >> "$f"; ev "SUP dns-fast applied"; }
  return 0
}

# 断线保护（仅 netns）：netns 内只允许走隧道；VPN 网关本身与 veth 回包例外
ks_apply() {
  local NSX=("$IP_CMD" netns exec "$NETNS_NAME")
  GW_IP=$(getent ahostsv4 "$GW_NAME" 2>/dev/null | awk 'NR==1{print $1}')
  [ -n "$GW_IP" ] || { sup_log "断线保护：解析不到网关 $GW_NAME"; return 1; }
  "${NSX[@]}" iptables -w -A OUTPUT -o lo -j ACCEPT &&
  "${NSX[@]}" iptables -w -A OUTPUT -o tun+ -j ACCEPT &&
  "${NSX[@]}" iptables -w -A OUTPUT -o "$VETH_NS" -d "$VETH_SUBNET" -j ACCEPT &&
  "${NSX[@]}" iptables -w -A OUTPUT -d "$GW_IP" -j ACCEPT &&
  "${NSX[@]}" iptables -w -A OUTPUT -j REJECT || { sup_log "断线保护：netns 内 iptables 规则写入失败"; return 1; }
  if command -v ip6tables >/dev/null 2>&1; then
    "${NSX[@]}" ip6tables -w -A OUTPUT -o lo -j ACCEPT 2>/dev/null
    "${NSX[@]}" ip6tables -w -A OUTPUT -o tun+ -j ACCEPT 2>/dev/null
    "${NSX[@]}" ip6tables -w -A OUTPUT -j REJECT 2>/dev/null
  fi
  sup_log "断线保护已开启（网关 $GW_NAME → $GW_IP）"
  return 0
}

# ---------------------------------------------------------------------------
#  回落代理（KILL_SWITCH=proxy，仅 netns）
#  netns 里第二个 gost（只监听 veth 地址，链路指向选中的代理）。VPN 不通时在 netns 的 nat PREROUTING
#  加一条 REDIRECT，把从宿主转发进来的新连接改送到它；VPN 恢复后删掉这条规则。conntrack 让已建立的
#  连接保持原去向，所以切回时回落期间的连接不断——为此给代理 IP 加了经 veth 的 /32 路由（隧道恢复后
#  默认路由走 tun，不加的话这些连接会被拐进隧道）。断线保护的防火墙同时生效，只额外放行选中代理的
#  IP:端口；代理都连不上就直接失败，不走 VPS 出口。
#  注意：netns 的连接跟踪是按需启用的——如果 REDIRECT 是唯一依赖 conntrack 的规则，删掉它时内核会
#  撤掉该 netns 的 conntrack 钩子，回落期间建立的连接随即被重置（实测：只删 REDIRECT，下载就停）。
#  所以 fb_prepare 先放一条常驻的、语义上不改变任何行为的 conntrack 规则把它"钉住"。
# ---------------------------------------------------------------------------
FB_MODE=0; FB_ACTIVE=0; FB_KEY=""; FB_NAME=""; FB_ADDR=""; FB_SINCE=0; FB_NEXT=0; FB_FAIL_NOTED=0; FB_GOST_PID=""
FB_C_NAME=""; FB_C_HOST=""; FB_C_IP=""; FB_C_PORT=""; FB_C_URL=""
fb_inner_port() { if [ "${CFG[SOCKS_PORT]}" = 10800 ]; then echo 10801; else echo 10800; fi; }
fb_prepare() {
  # INPUT 默认就是 ACCEPT，这条只为让 netns 一直启用 conntrack（见上方注释）
  "$IP_CMD" netns exec "$NETNS_NAME" iptables -w -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
    || sup_log "回落代理：conntrack 常驻规则写入失败，VPN 恢复时回落期间的连接可能会断"
  return 0
}
_fb_redirect() { # add|del
  local -a NSX=("$IP_CMD" netns exec "$NETNS_NAME")
  local -a r=(PREROUTING -i "$VETH_NS" -p tcp --dport "${CFG[SOCKS_PORT]}" -j REDIRECT --to-ports "$(fb_inner_port)")
  if [ "$1" = add ]; then
    "${NSX[@]}" iptables -w -t nat -C "${r[@]}" 2>/dev/null || "${NSX[@]}" iptables -w -t nat -A "${r[@]}"
  else
    while "${NSX[@]}" iptables -w -t nat -D "${r[@]}" 2>/dev/null; do :; done
    return 0
  fi
}
_fb_stop_gost() {
  local p="${FB_GOST_PID:-}"; [ -n "$p" ] || p=$(cat "$FB_GOST_PID_FILE" 2>/dev/null || true)
  [[ "$p" =~ ^[0-9]+$ ]] && kill "$p" 2>/dev/null
  FB_GOST_PID=""; FB_KEY=""; rm -f "$FB_GOST_PID_FILE" "$FB_YAML"
  return 0
}
# 按设置选代理：auto＝按文件顺序第一个 TCP 连得上的；固定名称＝只认它。结果放在 FB_C_*
fb_select() {
  local want="${CFG[FALLBACK_PROXY]:-auto}" line ip
  FB_C_NAME=""; FB_C_HOST=""; FB_C_IP=""; FB_C_PORT=""; FB_C_URL=""
  while IFS= read -r line; do
    proxy_parse "$line" || continue
    [ "$want" = auto ] || [ "$P_NAME" = "$want" ] || continue
    ip=$(_proxy_ip "$P_HOST" ns) || continue
    _tcp_probe "$ip" "$P_PORT" || continue
    FB_C_NAME=$P_NAME; FB_C_HOST=$P_HOST; FB_C_IP=$ip; FB_C_PORT=$P_PORT; FB_C_URL=$P_URL
    return 0
  done < <(_proxies_lines)
  return 1
}
_fb_disengage() { # 原因
  _fb_redirect del
  if [ "$FB_ACTIVE" = 1 ]; then
    local d=$(( $(now_s) - FB_SINCE ))
    ev "SUP fallback off reason=$1 proxy=${FB_NAME// /_} dur=$d dur_h=$(fmt_dur $d)"
    sup_log "回落代理已停用（${1}，用了 $(fmt_dur $d)）"
  fi
  FB_ACTIVE=0; FB_NAME=""; FB_ADDR=""; rm -f "$FB_STATE_FILE"
  return 0
}
fb_engage() {
  local -a NSX=("$IP_CMD" netns exec "$NETNS_NAME")
  local key
  if ! fb_select; then
    if [ "$FB_FAIL_NOTED" = 0 ]; then
      ev "SUP fallback unavailable want=${CFG[FALLBACK_PROXY]:-auto}"
      sup_log "回落代理都连不上：VPN 恢复前代理暂时不可用（不会改走 VPS 出口）"; FB_FAIL_NOTED=1
    fi
    [ "$FB_ACTIVE" = 1 ] && _fb_disengage proxy-unreachable
    return 1
  fi
  FB_FAIL_NOTED=0
  key=$(printf '%s|%s|%s' "$FB_C_URL" "$FB_C_IP" "$(fb_inner_port)" | sha256sum | cut -c1-16)
  if [ "$key" != "$FB_KEY" ] || ! kill -0 "${FB_GOST_PID:-0}" 2>/dev/null; then
    _fb_stop_gost
    _proxy_gen_yaml "$FB_C_URL" "$FB_C_HOST" "$FB_C_IP" "$FB_C_PORT" "${VETH_NS_IP}:$(fb_inner_port)" 1 "$FB_YAML" \
      || { ev "SUP fallback config-failed proxy=${FB_C_NAME// /_}"; sup_log "回落代理「${FB_C_NAME}」：gost 生成配置失败"; return 1; }
    "${NSX[@]}" gost -C "$FB_YAML" >/dev/null 2>&1 &
    FB_GOST_PID=$!; echo "$FB_GOST_PID" > "$FB_GOST_PID_FILE"
    sleep 1; rm -f "$FB_YAML"
    kill -0 "$FB_GOST_PID" 2>/dev/null || { ev "SUP fallback gost-failed proxy=${FB_C_NAME// /_}"; FB_GOST_PID=""; FB_KEY=""; return 1; }
    FB_KEY=$key
  fi
  [ "$FB_C_IP" = "$VETH_HOST_IP" ] || "$IP_CMD" -n "$NETNS_NAME" route replace "${FB_C_IP}/32" via "$VETH_HOST_IP" dev "$VETH_NS" 2>/dev/null
  "${NSX[@]}" iptables -w -C OUTPUT -d "$FB_C_IP" -p tcp --dport "$FB_C_PORT" -j ACCEPT 2>/dev/null \
    || "${NSX[@]}" iptables -w -I OUTPUT 1 -d "$FB_C_IP" -p tcp --dport "$FB_C_PORT" -j ACCEPT
  _fb_redirect add || { ev "SUP fallback redirect-failed"; return 1; }
  if [ "$FB_ACTIVE" = 0 ] || [ "$FB_NAME" != "$FB_C_NAME" ]; then
    [ "$FB_ACTIVE" = 0 ] && FB_SINCE=$(now_s)
    ev "SUP fallback on proxy=${FB_C_NAME// /_} addr=${FB_C_IP}:${FB_C_PORT}"
    sup_log "VPN 不可用：新连接改走回落代理「${FB_C_NAME}」（${FB_C_IP}:${FB_C_PORT}）"
  fi
  FB_ACTIVE=1; FB_NAME=$FB_C_NAME; FB_ADDR="${FB_C_IP}:${FB_C_PORT}"
  printf '%s %s %s\n' "$FB_SINCE" "$FB_ADDR" "$FB_NAME" > "$FB_STATE_FILE"
  return 0
}
# VPN 不通期间每 10 秒看一次：没回落就尝试回落；正在用的代理断了就重选
fb_tick() {
  [ "$FB_MODE" = 1 ] && [ "$EVER_UP" = 1 ] || return 0
  local now; now=$(now_s); [ "$now" -ge "$FB_NEXT" ] || return 0
  FB_NEXT=$((now + 10))
  if [ "$FB_ACTIVE" = 1 ] && kill -0 "${FB_GOST_PID:-0}" 2>/dev/null && _tcp_probe "${FB_ADDR%:*}" "${FB_ADDR##*:}"; then return 0; fi
  [ "$FB_ACTIVE" = 1 ] && ev "SUP fallback check-failed proxy=${FB_NAME// /_} → reselect"
  fb_engage || true
  return 0
}

# 重连前恢复网络基线。openconnect 被 kill -9 / 崩溃时来不及运行 vpnc-script 的 disconnect：
# netns 里默认路由还指向已消失的 tun、resolv.conf 还是 VPN 的 DNS，下一次连接连网关域名都解析不了
# （实测 kill -9 后重连报 getaddrinfo failed）。正常退出时 vpnc-script 自己会还原，这里幂等补一次。
sup_reset_net() {
  case "${CFG[MODE]}" in
    netns)
      "$IP_CMD" -n "$NETNS_NAME" route show default 2>/dev/null | _gq "via ${VETH_HOST_IP}" \
        || { "$IP_CMD" -n "$NETNS_NAME" route replace default via "$VETH_HOST_IP" dev "$VETH_NS" 2>/dev/null && ev "SUP net-reset netns default route"; }
      local rf="/etc/netns/${NETNS_NAME}/resolv.conf"
      if grep -q 'VPNC_GENERATED' "$rf" 2>/dev/null; then
        { [ -r /etc/resolv.conf ] && cp /etc/resolv.conf "$rf"; } || echo "nameserver 8.8.8.8" > "$rf"
        ev "SUP net-reset netns resolv.conf"
      fi ;;
    default)
      if [ -n "${ORIG_DEF4:-}" ] && ! "$IP_CMD" -4 route show default 2>/dev/null | _gq .; then
        # shellcheck disable=SC2086
        "$IP_CMD" route replace $ORIG_DEF4 2>/dev/null && ev "SUP net-reset host default route"
      fi ;;
  esac
  return 0
}

# 根据退出码与本次输出判断 openconnect 为什么退出
# （openconnect 源码 main.c：2=cookie/认证被拒，1=服务器终止或网络错误，0=收到 SIGTERM/SIGHUP）
sup_classify() {
  local rc="$1" up="$2" req=0
  [ -f "$RESTART_REQ" ] && { req=1; rm -f "$RESTART_REQ"; }
  # 先看 openconnect 自己说了什么（服务器终止优先于软重连标志，避免过期标志误判）
  if grep -qiE 'Server terminated connection|Session terminated by server|session expired|session timed out' "$SESSION_LOG" 2>/dev/null; then echo server-terminated; return; fi
  if [ -f "$PLANNED_REQ" ]; then rm -f "$PLANNED_REQ"; case "$rc" in 0|137|143) echo planned; return ;; esac; fi
  if [ $req = 1 ]; then echo watch-request; return; fi
  if [ "$rc" = 2 ] || grep -qiE 'login failed|authentication failed|invalid (user|pass|cred)|incorrect (user|pass)|password (has )?expired|account (is )?(locked|disabled)|cookie was rejected|failed to authenticate' "$SESSION_LOG" 2>/dev/null; then echo auth; return; fi
  if grep -qiE 'frmConfirmation|already (logged|signed) in|maximum number of (open )?(sessions|users)|session limit' "$SESSION_LOG" 2>/dev/null; then echo session-confirm; return; fi
  if [ "$up" = 0 ] && [ "$(grep -c frmLogin "$SESSION_LOG" 2>/dev/null)" -ge 4 ]; then echo auth; return; fi
  echo network
}

# 可被 SIGTERM 打断的 sleep
sup_sleep() { local end=$(( $(now_s) + $1 )); while [ "$(now_s)" -lt "$end" ] && [ "$SUP_STOP" = 0 ]; do fb_tick; sleep 1 & wait $! 2>/dev/null; done; }

# 定时重连：会话（自 openconnect 启动）满 SESSION_RESTART 就让它正常登出，随后由主循环立即重连。
# 设置每 30 秒重读一次，所以改了即时生效；TERM 后 20 秒还没退出就 KILL。
PLANNED_SENT=0; LR_AT=0
sup_planned_check() {
  local now lim; now=$(now_s)
  if [ $((now - LR_AT)) -ge 30 ]; then live_reload; LR_AT=$now; fi
  if [ "$PLANNED_SENT" -gt 0 ]; then
    if [ $((now - PLANNED_SENT)) -ge 20 ] && kill -0 "$OC_PID" 2>/dev/null; then
      ev "SUP planned-restart kill pid=$OC_PID (still running 20s after TERM)"; kill -KILL "$OC_PID" 2>/dev/null; PLANNED_SENT=$now
    fi
    return 0
  fi
  [ "${LIVE[AUTO_RECONNECT]:-on}" = on ] || return 0
  lim=$(_dur_to_s "${LIVE[SESSION_RESTART]:-off}" 2>/dev/null) || return 0
  [ "$lim" -ge "$SESSION_RESTART_MIN" ] && [ $((now - OC_START)) -ge "$lim" ] || return 0
  kill -0 "$OC_PID" 2>/dev/null || return 0
  PLANNED_SENT=$now; touch "$PLANNED_REQ"
  ev "SUP planned-restart session=$SESSION_N age=$((now - OC_START)) limit=$lim limit_h=$(fmt_dur "$lim") pid=$OC_PID"
  sup_log "会话已满 $(fmt_dur "$lim")（定时重连），正常登出后立即重连"
  kill -TERM "$OC_PID" 2>/dev/null
  return 0
}

sup_on_up() {
  local first=0 took=$(( $(now_s) - OC_START )); [ "$EVER_UP" = 0 ] && first=1
  EVER_UP=1
  if [ "${CFG[MODE]}" = netns ]; then
    [ "${CFG[DNS_FAST]}" = on ] && dns_fast_apply
    if [ $first = 1 ] || ! kill -0 "${GOST_PID:-0}" 2>/dev/null; then
      sup_start_proxy || { ev "SUP proxy-failed"; SUP_STOP=1; PAUSED_REASON="failed:proxy"; return 1; }
    fi
  fi
  [ "$FB_MODE" = 1 ] && _fb_disengage vpn-up
  set_phase up
  ev "SUP up session=$SESSION_N took=${took}s pid=$OC_PID"
  sup_log "隧道已就绪（第 $SESSION_N 次连接，用时 ${took}s）"
  return 0
}

_supervise() {
  check_root
  set +e   # 守护循环里单次探测失败不能让整个 supervisor 退出
  mkdir -p "$RUN_DIR" "$LOG_DIR" "$LAUNCH_DIR"; chmod 700 "$RUN_DIR" 2>/dev/null; chmod 750 "$LOG_DIR" 2>/dev/null
  settings_load; _load_kv_file "$RUN_PROFILE"
  LAUNCH_LOG=$(sed -n 's/^#LAUNCH_LOG=//p' "$RUN_PROFILE" 2>/dev/null | head -n1)
  [ -n "$LAUNCH_LOG" ] || LAUNCH_LOG="$LAUNCH_DIR/$(date +%Y%m%d-%H%M%S)-autostart.log"
  live_reload
  trap 'SUP_STOP=1' TERM INT HUP
  set_phase starting
  ev "SUP start v$VERSION mode=${CFG[MODE]} account=${CFG[ACCOUNT]} channel=${CFG[DATA_CHANNEL]} port=${CFG[SOCKS_PORT]} kill_switch=${CFG[KILL_SWITCH]}"

  # 上次异常退出（崩溃、kill -9、断电）留下的残留先清掉，否则端口/netns 冲突
  if [ -f "$STATE_FILE" ] || is_vpn_running || [ -e "/run/netns/$NETNS_NAME" ]; then
    sup_log "发现上次会话的残留，先清理"; _teardown_session >/dev/null 2>&1
  fi
  GOST_PID=""; _FWD_DESC=""; _FWD_STATE=""   # 清理时 source 过旧 state，避免沿用旧值
  FB_MODE=0; FB_ACTIVE=0; FB_KEY=""; FB_GOST_PID=""; rm -f "$FB_STATE_FILE"
  if ! account_load "${CFG[ACCOUNT]}"; then set_phase failed:account; ev "SUP fail reason=account"; exit 3; fi
  GW_NAME=$(gw_host_of "${CFG[ACCOUNT]}")
  sup_log "账户：${VPN_DESC}（协议 $(sup_proto)）  模式：${CFG[MODE]}  数据通道：${CFG[DATA_CHANNEL]}"

  case "${CFG[MODE]}" in
    netns)
      if [ "${CFG[IPV6_FORWARD]}" = on ]; then OCM_IPV6_FORWARD=1; else OCM_IPV6_FORWARD=0; fi
      setup_netns >/dev/null || { set_phase failed:netns; ev "SUP fail reason=netns"; _teardown_session >/dev/null 2>&1; exit 3; }
      sup_log "Netns ${NETNS_NAME} 已就绪"
      if [ "${CFG[KILL_SWITCH]}" = on ] || [ "${CFG[KILL_SWITCH]}" = proxy ]; then ks_apply || { set_phase failed:kill-switch; _teardown_session >/dev/null 2>&1; exit 3; }; fi
      [ "${CFG[KILL_SWITCH]}" = proxy ] && { FB_MODE=1; fb_prepare; } ;;
    default)
      ORIG_DEF4=$("$IP_CMD" -4 route show default 2>/dev/null | grep -v ' dev tun\| dev ocmtun' | head -n1)
      setup_ssh_protect_routes >/dev/null || { set_phase failed:routes; ev "SUP fail reason=ssh-protect-routes"; _teardown_session >/dev/null 2>&1; exit 3; }
      sup_log "SSH 保护路由已配置" ;;
    ocproxy) : ;;
  esac
  _FWD_DESC=""; _FWD_STATE=""
  sup_write_state
  sup_build_oc

  local fails=0 authfails=0 rc kind age delay idx up t0 interval
  local -a attempts=() B=()
  while [ "$SUP_STOP" = 0 ]; do
    live_reload
    read -r -a B <<<"${LIVE[BACKOFF]}"; [ ${#B[@]} -gt 0 ] || B=(30)
    if [ "$EVER_UP" = 1 ]; then set_phase reconnecting; else set_phase connecting; fi
    [ "${kind:-}" = planned ] || attempts+=("$(now_s)")
    [ "$SESSION_N" -gt 0 ] && sup_reset_net
    sup_launch_oc
    sup_log "启动 openconnect（第 $SESSION_N 次，pid $OC_PID）"
    up=0; t0=$(now_s); PLANNED_SENT=0; rm -f "$PLANNED_REQ"
    while kill -0 "$OC_PID" 2>/dev/null && [ "$SUP_STOP" = 0 ]; do
      if [ $up = 0 ]; then
        if sup_tunnel_up; then up=1; sup_on_up || break
        elif [ $(( $(now_s) - t0 )) -ge 75 ]; then sup_log "75 秒内隧道未就绪，结束本次尝试"; kill -TERM "$OC_PID" 2>/dev/null; fi
        [ $up = 0 ] && fb_tick
        interval=1
      else
        sup_check_children; sup_planned_check; interval=3; [ "$PLANNED_SENT" -gt 0 ] && interval=1
      fi
      sleep "$interval" & wait $! 2>/dev/null
    done
    [ "$SUP_STOP" = 1 ] && break
    wait "$OC_PID" 2>/dev/null; rc=$?
    [ "$SUP_STOP" = 1 ] && break
    set_phase reconnecting   # 立刻反映掉线，不要在判断原因的这几秒里仍显示 up
    rm -f "$PID_FILE"
    [ "$FB_MODE" = 1 ] && { FB_NEXT=0; fb_tick; }   # 立刻回落，不等判断原因与退避
    sleep 1   # 让日志管道把 openconnect 最后几行写完，再判断退出原因
    age=$(( $(now_s) - OC_START )); kind=$(sup_classify "$rc" "$up")
    ev "SUP exit session=$SESSION_N rc=$rc kind=$kind session_age=$age session_age_h=$(fmt_dur $age) was_up=$up"
    sup_log "openconnect 已退出（rc=$rc，原因：$kind，本次会话 $(fmt_dur $age)）"
    tail -n 4 "$SESSION_LOG" 2>/dev/null | while IFS= read -r l; do ev "OCLAST $l"; done

    case "$kind" in
      server-terminated|watch-request) delay=2; fails=0 ;;
      planned) delay=1; fails=0 ;;
      auth) authfails=$((authfails+1)); fails=$((fails+1)) ;;
      *) fails=$((fails+1)) ;;
    esac
    [ "$up" = 1 ] && [ "$kind" != auth ] && authfails=0
    case "$kind" in
      server-terminated|watch-request|planned) : ;;
      *) idx=$((fails-1)); [ $idx -ge ${#B[@]} ] && idx=$(( ${#B[@]} - 1 )); [ $idx -lt 0 ] && idx=0; delay=${B[$idx]} ;;
    esac

    if [ "${LIVE[AUTO_RECONNECT]}" != on ] && [ "$kind" != planned ]; then sup_log "自动重连已关闭，停止"; ev "SUP no-reconnect (AUTO_RECONNECT=off)"; PAUSED_REASON="stopped:no-reconnect"; break; fi
    if [ "$kind" = auth ] && { [ "$EVER_UP" = 0 ] || [ "$authfails" -ge "${LIVE[AUTH_FAIL_PAUSE]}" ]; }; then
      sup_log "认证失败（连续 $authfails 次），为防止账号被锁已停止。确认账号密码后重新启动。"
      ev "SUP paused reason=auth authfails=$authfails"; PAUSED_REASON="failed:auth"; break
    fi
    # 每小时上限
    local -a recent=(); local t
    for t in "${attempts[@]}"; do [ $(( $(now_s) - t )) -lt 3600 ] && recent+=("$t"); done
    attempts=("${recent[@]}")
    if [ "$kind" != planned ] && [ "${#attempts[@]}" -ge "${LIVE[MAX_PER_HOUR]}" ]; then
      local w=$(( attempts[0] + 3600 - $(now_s) )); [ $w -lt $delay ] || delay=$w
      ev "SUP rate-limited attempts_last_hour=${#attempts[@]} wait=${delay}s"; sup_log "1 小时内已重连 ${#attempts[@]} 次，等待 ${delay}s"
    fi
    ev "SUP retry kind=$kind delay=${delay}s fails=$fails"
    sup_log "${delay}s 后重连"
    set_phase reconnecting
    sup_sleep "$delay"
  done

  # --- 停止：先让 openconnect 登出，再拆代理与网络 ---
  set_phase stopping
  if [ -n "$OC_PID" ] && kill -0 "$OC_PID" 2>/dev/null; then
    sup_log "正在登出 openconnect..."; kill -TERM "$OC_PID" 2>/dev/null; _wait_pid_gone "$OC_PID"
  fi
  [ "$FB_MODE" = 1 ] && { _fb_disengage stop; _fb_stop_gost; }
  _teardown_session >/dev/null 2>&1
  rm -f "$RESTART_REQ" "$PLANNED_REQ" "$PID_FILE"
  ev "SUP stop reason=${PAUSED_REASON:-requested} sessions=$SESSION_N"
  set_phase "${PAUSED_REASON:-stopped}"
  sup_log "已停止（${PAUSED_REASON:-requested}）"
  exit 0
}

# ============================================================================
#  启动 / 停止（前端）
# ============================================================================
declare -A OVR=()     # 命令行或「只改本次」的临时覆盖
OPT_SAVE=0

show_summary() {
  local k
  title "📋 本次启动设置"
  for k in ACCOUNT MODE PROTOCOL DATA_CHANNEL; do printf '    %-14s %s\n' "${SET_TITLE[$k]}" "$(cfg_label "$k")"; done
  local acc_proto; acc_proto=$(account_field "${CFG[ACCOUNT]}" 6 2>/dev/null || true)
  [ -n "$acc_proto" ] && printf '    %-14s %s\n' "" "（账户自带协议 ${acc_proto}，优先于上一行）"
  case "${CFG[MODE]}" in
    netns) for k in SOCKS_PORT LISTEN SOCKS_AUTH FORWARDER KILL_SWITCH DNS_FAST; do printf '    %-14s %s\n' "${SET_TITLE[$k]}" "$(cfg_label "$k")"; done
           [ "${CFG[KILL_SWITCH]}" = proxy ] && printf '    %-14s %s（列表 %s 个）\n' "${SET_TITLE[FALLBACK_PROXY]}" "$(cfg_label FALLBACK_PROXY)" "$(proxies_count)" ;;
    ocproxy) printf '    %-14s %s\n' "${SET_TITLE[SOCKS_PORT]}" "127.0.0.1:${CFG[SOCKS_PORT]}" ;;
  esac
  printf '    %-14s %s\n' "${SET_TITLE[AUTO_RECONNECT]}" "$(cfg_label AUTO_RECONNECT)"
  printf '    %-14s %s\n' "${SET_TITLE[SESSION_RESTART]}" "$(cfg_label SESSION_RESTART)"
  [ "${CFG[MTU]}" != auto ] && printf '    %-14s %s\n' "MTU" "${CFG[MTU]}"
  [ -n "${CFG[OC_EXTRA]}" ] && printf '    %-14s %s\n' "附加参数" "${CFG[OC_EXTRA]}"
  return 0
}

start_preflight() {
  local n; n=$(accounts_count)
  [ "${n:-0}" -gt 0 ] || { log_err "还没有 VPN 账户，先在菜单「管理 VPN 账户」添加。"; return 1; }
  settings_validate ACCOUNT "${CFG[ACCOUNT]}" || return 1
  ensure_pkg_openconnect
  case "${CFG[MODE]}" in
    netns)
      ensure_pkg_iptables
      ensure_cmd_gost || return 1
      if [ "${CFG[FORWARDER]}" = socat ]; then ensure_cmd_socat || return 1; fi
      _check_port_free "${CFG[SOCKS_PORT]}" || { log_err "端口 ${CFG[SOCKS_PORT]} 已被占用，换一个（设置 → SOCKS5 端口）。"; return 1; }
      [ "${CFG[LISTEN]}" = 0.0.0.0 ] && [ -z "${CFG[SOCKS_USER]}" ] && log_warn "SOCKS5 对全部网卡开放且没有认证——任何人都能用你的代理。建议设置认证。"
      if [ "${CFG[KILL_SWITCH]}" = proxy ]; then
        [ "$(proxies_count)" -gt 0 ] || { log_err "断线保护设为「回落代理」，但还没有回落代理：先在主菜单 11 或用 ocm proxy add 添加。"; return 1; }
        local fp="${CFG[FALLBACK_PROXY]:-auto}" _l
        [ "$fp" = auto ] || proxy_find "$fp" >/dev/null || { log_err "回落代理「$fp」不在列表里（ocm proxy list）。"; return 1; }
        while IFS= read -r _l; do proxy_parse "$_l" || log_warn "回落代理列表有一行格式错误，会被跳过：${_l%%|*}（$P_ERR）"; done < <(_proxies_lines)
      fi
      ;;
    ocproxy)
      ensure_pkg_ocproxy
      _check_port_free "${CFG[SOCKS_PORT]}" || { log_err "端口 ${CFG[SOCKS_PORT]} 已被占用。"; return 1; } ;;
    default) check_atd ;;
  esac
  return 0
}

run_profile_write() {
  local k
  mkdir -p "$RUN_DIR"; chmod 700 "$RUN_DIR"
  ( umask 077
    { printf '#LAUNCH_LOG=%s\n' "$LAUNCH_LOG"
      for k in "${SET_KEYS[@]}" SOCKS_USER SOCKS_PASS; do [ "$k" = SOCKS_AUTH ] && continue; printf '%s=%q\n' "$k" "${CFG[$k]:-}"; done
    } > "$RUN_PROFILE" )
}

# 把 OVR 合入 CFG（已在解析时校验）
apply_overrides() { local k; for k in "${!OVR[@]}"; do CFG[$k]=${OVR[$k]}; done; }

# 交互确认：直接启动 / 改设置 / 只改本次 / 取消
start_confirm() {
  local a
  while true; do
    echo; show_summary; sep
    read -rp "回车=启动   s=修改并保存设置   t=只改本次   q=取消 : " a || { echo; return 1; }
    case "$a" in
      "") return 0 ;;
      s|S) settings_menu; settings_load; apply_overrides ;;
      t|T) settings_menu ovr; apply_overrides ;;
      q|Q) log_info "已取消"; return 1 ;;
    esac
  done
}

cmd_start() { # $1=1 交互确认
  local interactive="${1:-0}" rc=0
  check_root
  if svc_active; then log_err "VPN 已在运行（阶段：$(get_phase)）。要换设置请用 ocm restart。"; return 3; fi
  if is_vpn_running; then log_err "检测到不受 systemd 托管的 openconnect（pid $(cat "$PID_FILE" 2>/dev/null)，可能是旧版启动的）。先 ocm stop 清理。"; return 3; fi
  settings_load; apply_overrides
  if [ "$interactive" = 1 ]; then start_confirm || return 1; fi
  start_preflight || return 1
  if [ "$OPT_SAVE" = 1 ]; then settings_save; log "已把本次设置保存为默认。"; fi
  mkdir -p "$LAUNCH_DIR"
  LAUNCH_LOG="$LAUNCH_DIR/$(date +%Y%m%d-%H%M%S)-start.log"; : > "$LAUNCH_LOG"; chmod 640 "$LAUNCH_LOG"
  run_profile_write
  install_units || return 1
  rm -f "$PHASE_FILE" "$RESTART_REQ"
  ev "MARK ocm start mode=${CFG[MODE]} account=${CFG[ACCOUNT]} channel=${CFG[DATA_CHANNEL]} port=${CFG[SOCKS_PORT]} by=${SUDO_USER:-$(id -un)}"

  # 默认全局模式：保底回滚（路由出错导致 SSH 失联时，3 分钟后自动 stop）
  local job="none"
  if [ "${CFG[MODE]}" = default ]; then
    job=$(echo "$SCRIPT_PATH stop" | at now + 3 minutes 2>&1 | awk '/job/{print $2}' || true)
    [[ "${job:-}" =~ ^[0-9]+$ ]] || job="none"
    if [ "$job" != none ]; then log_warn "已设保底任务（at Job $job）：3 分钟内未确认成功将自动停止。"; else log_warn "未能排上保底任务（at/atd 不可用）。"; fi
  fi

  log_info "交给 systemd 启动（${SVC_MAIN}）..."
  systemctl reset-failed "$SVC_MAIN" >/dev/null 2>&1 || true
  systemctl start "$SVC_MAIN" || { log_err "systemctl start 失败：journalctl -u $SVC_MAIN -n 50"; return 1; }
  start_follow || rc=$?
  sep
  case $rc in
    0) [ "$job" != none ] && atrm "$job" 2>/dev/null && log "连接稳定，已取消保底任务"
       start_result; return 0 ;;
    2) log_warn "${START_TIMEOUT} 秒内还没连上，后台仍在按退避策略重试。查看：ocm status / ocm log tail；放弃：ocm stop"
       [ "$job" != none ] && atrm "$job" 2>/dev/null; return 1 ;;
    *) log_err "启动失败（$(get_phase)）。完整输出：$LAUNCH_LOG"
       [ "$job" != none ] && atrm "$job" 2>/dev/null; return 1 ;;
  esac
}

# 跟随启动日志直到 up / 失败 / 超时
start_follow() {
  local off=0 t0 ph sz
  t0=$(now_s)
  while :; do
    sz=$(stat -c%s "$LAUNCH_LOG" 2>/dev/null || echo 0)
    if [ "$sz" -gt "$off" ]; then tail -c +$((off+1)) "$LAUNCH_LOG" | head -c $((sz-off)); off=$sz; fi
    ph=$(get_phase)
    case "$ph" in up) return 0;; failed:*|stopped*) return 1;; esac
    if ! svc_active && [ $(( $(now_s) - t0 )) -gt 5 ]; then return 1; fi
    [ $(( $(now_s) - t0 )) -ge "$START_TIMEOUT" ] && return 2
    sleep 1
  done
}

start_result() {
  local proxy code eg
  case "${CFG[MODE]}" in
    netns|ocproxy)
      proxy="socks5h://127.0.0.1:${CFG[SOCKS_PORT]}"
      [ "${CFG[MODE]}" = netns ] && [ -n "${CFG[SOCKS_USER]}" ] && proxy="socks5h://${CFG[SOCKS_USER]}:${CFG[SOCKS_PASS]}@127.0.0.1:${CFG[SOCKS_PORT]}"
      code=$("$CURL_CMD" -s -o /dev/null -w '%{http_code}' --max-time 10 -x "$proxy" http://www.gstatic.com/generate_204 2>/dev/null || true)
      eg=$(_pub_ip -4 "$proxy" 2>/dev/null || echo "查询失败")
      log "VPN 已连接：SOCKS5 ${CFG[LISTEN]}:${CFG[SOCKS_PORT]}  探针 ${code:-无}  VPN 出口 ${eg}"
      [ "${CFG[LISTEN]}" = 127.0.0.1 ] && log_info "从自己电脑使用：ssh -N -L ${CFG[SOCKS_PORT]}:127.0.0.1:${CFG[SOCKS_PORT]} <你的VPS>，再把浏览器代理设为 SOCKS5 127.0.0.1:${CFG[SOCKS_PORT]}"
      ;;
    default) log "VPN 已连接（全局模式），本机出口：$(_pub_ip -4 2>/dev/null || echo 查询失败)" ;;
  esac
  ev "MARK ocm start result=ok egress=${eg:-?}"
}

cmd_stop() {
  check_root
  ev "MARK ocm stop: 人工停止 by=${SUDO_USER:-$(id -un)}"
  if svc_active || [ "$(get_phase)" = reconnecting ]; then
    log_info "正在停止（openconnect 登出可能需要几秒）..."
    systemctl stop "$SVC_MAIN" 2>/dev/null || true
  fi
  # 兜底：旧版（非托管）启动的会话或异常残留
  if is_vpn_running || [ -f "$STATE_FILE" ] || [ -f "$GOST_PID_FILE" ] || [ -f "$SOCAT_PID_FILE" ] || [ -e "/run/netns/$NETNS_NAME" ]; then
    _teardown_session
  fi
  rm -f "$RESTART_REQ"
  log "VPN 已停止。"
}
stop_vpn() { cmd_stop; }   # 兼容旧调用名（卸载流程等）

# ============================================================================
#  诊断日志（ocm-watch.service → `ocm _watch`）
# ----------------------------------------------------------------------------
#  只读采样：不启停 VPN、不改路由/iptables/sysctl；唯一的「动作」是在 openconnect 还活着
#  但代理持续不通（DEGRADED ≥ DEGRADED_WAIT）或出口回落宿主（FALLBACK ≥ 20s）时，写
#  restart-request 并 TERM openconnect，交给 supervisor 重连。
#  文件（${LOG_DIR}）：
#    samples.log      每 SAMPLE_INTERVAL 秒一行客观指标（状态变化后加密到 5 秒，持续 3 分钟）
#    events.log       只记变化：STATUS 迁移、CHANGE 字段变化、SUP（supervisor）、OC（openconnect 关键句）、MARK
#    openconnect.log  openconnect 全部输出（supervisor 写入）
#    incidents/       每次离开 UP / 进入异常时的现场快照
#    launch/          每次 ocm start 的完整启动输出
#  全部按大小轮转并 gzip，总量受 LOG_MAX_MB 限制；分区剩余 < 400MB 时暂停写采样。
# ============================================================================
INTERVAL=30; FAST_INTERVAL=5; FAST_WINDOW=180; IDLE_INTERVAL=120; WATCH_STEP=5
STARTUP_GRACE=90; BAD_CONFIRM=2
PROBE_URL=http://www.gstatic.com/generate_204; EXTRA_PROBE_URL=""
TUN_PING_TARGET=1.1.1.1; EGRESS_EVERY=10; HOST_EGRESS_TTL=1800; HEARTBEAT_EVERY=21600
ROTATE_BYTES=2097152; KEEP_SAMPLES=150; KEEP_EVENTS=60; KEEP_OCLOG=60; KEEP_INCIDENTS=400
MAX_TOTAL_MB=300; MIN_FREE_MB=400
NAT_SUBNET="$VETH_SUBNET"
# 会话时间轴：会话年龄跨过这些秒数时记 SESSION 里程碑；[FROM,TO] 区间强制 5 秒采样；
# 报告把落在 [LO,HI] 的非人工会话结束标为「≈2h」（不少学校/企业 VPN 有固定会话时长）
AGE_MARKS="3600 6600 7080 7200 7320 7800 10800"
AGE_WATCH_FROM=7080; AGE_WATCH_TO=7500; AGE_SUSPECT_LO=6900; AGE_SUSPECT_HI=7500
LAST_KICK=0

now_ts() { printf '%(%Y-%m-%dT%H:%M:%S%z)T' -1; }
ms_now() { local n; n=$(date +%s%N); echo $(( n / 1000000 )); }
watch_dirs() { mkdir -p "$LOG_DIR" "$INC_DIR" "$LAUNCH_DIR" "$WATCH_LIB" 2>/dev/null; chmod 750 "$LOG_DIR" 2>/dev/null || true; }
watch_reload_cfg() {
  settings_load
  [[ "${CFG[SAMPLE_INTERVAL]}" =~ ^[0-9]+$ ]] && [ "${CFG[SAMPLE_INTERVAL]}" -ge 5 ] && INTERVAL=${CFG[SAMPLE_INTERVAL]}
  [[ "${CFG[LOG_MAX_MB]}" =~ ^[0-9]+$ ]] && MAX_TOTAL_MB=${CFG[LOG_MAX_MB]}
  EXTRA_PROBE_URL=${CFG[EXTRA_PROBE_URL]}
  return 0
}
_watch() {
  check_root
  set +e
  watch_reload_cfg
  _watch_loop
}

# ---------------- 状态 ----------------
cmd_status() {
  local verbose="${1:-}" ph since st wsince rest
  [ "$EUID" -eq 0 ] || { log_err "请用 root 运行"; return 1; }
  settings_load
  title "== OpenConnect Master v${VERSION} =="
  ph=$(get_phase); since=$(get_phase_since)
  printf 'VPN 服务  : %s' "$(systemctl is-active "$SVC_MAIN" 2>/dev/null || true)"
  [ -n "$ph" ] && printf '   阶段 %s（%s）' "$ph" "$( [[ "$since" =~ ^[0-9]+$ ]] && fmt_dur $(( $(now_s) - since )) || echo ?)"
  local en; en=$(systemctl is-enabled "$SVC_MAIN" 2>/dev/null || true)
  printf '   开机自启 %s\n' "${en:-未安装}"
  printf '诊断日志  : %s   自动重连 %s\n' "$(systemctl is-active "$SVC_WATCH" 2>/dev/null || true)" "$(cfg_label AUTO_RECONNECT)"
  local _sr _ag=""; _sr=$(_dur_to_s "${CFG[SESSION_RESTART]:-off}" 2>/dev/null || echo 0)
  if [ "${_sr:-0}" -gt 0 ]; then
    if is_vpn_running; then _ag=$(ps -o etimes= -p "$(cat "$PID_FILE")" 2>/dev/null | tr -d ' ') || true; fi
    printf '定时重连  : 会话满 %s 主动重连%s\n' "$(fmt_dur "$_sr")" "$( [[ "$_ag" =~ ^[0-9]+$ ]] && [ "$_ag" -lt "$_sr" ] && echo "（本次还剩 $(fmt_dur $((_sr - _ag)))）")"
  fi
  if [ -f "$STATE_FILE" ]; then
    local MODE="" ACCOUNT_INDEX="" VPN_PROTOCOL="" SOCKS_PORT="" LISTEN_ADDR="" FORWARDER="" SOCKS_USER="" SOCKS_PASS="" KILL_SWITCH=""
    # shellcheck disable=SC1090
    . "$STATE_FILE" 2>/dev/null || true
    printf '当前会话  : 账户 %s  模式 %s  协议 %s' "$(account_field $(( ${ACCOUNT_INDEX:-0} + 1 )) 1 2>/dev/null || echo '?')" "${MODE:-?}" "${VPN_PROTOCOL:-?}"
    [ -n "$SOCKS_PORT" ] && printf '  SOCKS5 %s:%s%s' "${LISTEN_ADDR:-127.0.0.1}" "$SOCKS_PORT" "${SOCKS_USER:+（认证 ${SOCKS_USER}:****）}"
    [ -n "$FORWARDER" ] && printf '  转发 %s' "$FORWARDER"
    echo
    is_vpn_running && printf 'openconnect: pid %s，已运行 %s\n' "$(cat "$PID_FILE")" "$(fmt_dur "$(ps -o etimes= -p "$(cat "$PID_FILE")" 2>/dev/null | tr -d ' ')")"
    if [ "${KILL_SWITCH:-}" = proxy ]; then
      if [ -r "$FB_STATE_FILE" ]; then
        local fs fa fn; read -r fs fa fn < "$FB_STATE_FILE"
        printf '回落代理  : 使用中「%s」%s（已 %s，VPN 恢复后自动切回）\n' "$fn" "$fa" "$( [[ "$fs" =~ ^[0-9]+$ ]] && fmt_dur $(( $(now_s) - fs )) || echo '?')"
      else
        printf '回落代理  : 待命（VPN 掉线时启用；%s）\n' "$(cfg_label FALLBACK_PROXY)"
      fi
    fi
  else
    echo "当前会话  : 无"
  fi
  if [ -r "$WATCH_LIB/current" ]; then
    read -r st wsince rest < "$WATCH_LIB/current"
    printf '诊断判定  : %s（已持续 %s）\n' "$st" "$(fmt_dur $(( $(now_s) - wsince )))"
    local eg; eg=$(grep -o ' eg=[0-9.]*' "$SAMPLES" 2>/dev/null | tail -n1 | cut -d= -f2 || true)
    [ -n "$eg" ] && printf '最近测得出口: %s\n' "$eg"
    [ "$verbose" = -v ] && printf '最新采样  : %s\n' "$rest"
  fi
  printf '日志目录  : %s（%s）\n' "$LOG_DIR" "$(du -sh "$LOG_DIR" 2>/dev/null | cut -f1)"
  echo "最近事件："
  grep -aE ' (STATUS|SUP|WATCH restart|MARK|RECOVERED) ' "$EVENTS" 2>/dev/null | grep -v ' HEARTBEAT ' | tail -n "$([ "$verbose" = -v ] && echo 25 || echo 8)" | cut -c1-200 | sed 's/^/  /' || true
  return 0
}

cmd_log() {
  local sub="${1:-report}"; shift || true
  case "$sub" in
    report)   cmd_report "${1:-7}" ;;
    tail)     exec tail -n 40 -F "$EVENTS" "$OCLOG" ;;
    snapshot) check_root; watch_dirs; settings_load; read_state; local f; f=$(snapshot "${1:-manual}"); ev "INCIDENT saved $f (manual)"; echo "$f" ;;
    mark)     check_root; [ $# -gt 0 ] || { log_err "用法：ocm log mark <文字>"; return 2; }; ev "MARK $*"; echo "已记录" ;;
    dir)      echo "$LOG_DIR" ;;
    *) log_err "未知子命令：log $sub（可用 report|tail|snapshot|mark|dir）"; return 2 ;;
  esac
}

rotate_file() { # 文件 保留份数
  local f="$1" keep="$2" sz dst
  sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
  [ "$sz" -ge "$ROTATE_BYTES" ] || return 0
  dst="$f.$(printf '%(%Y%m%d-%H%M%S)T' -1)"
  mv -f "$f" "$dst" 2>/dev/null || return 0
  nice -n 19 gzip -f "$dst" 2>/dev/null || true
  ls -1 "$f".*.gz 2>/dev/null | sort | head -n -"$keep" | xargs -r rm -f
}

# 磁盘保护：分区余量 + 目录总量上限
LOW_DISK=0
disk_guard() {
  local free used
  free=$(df -Pm "$LOG_DIR" 2>/dev/null | awk 'NR==2{print $4}')
  if [[ "${free:-}" =~ ^[0-9]+$ ]] && [ "$free" -lt "$MIN_FREE_MB" ]; then
    [ "$LOW_DISK" = 0 ] && ev "DISK low free=${free}MB min=${MIN_FREE_MB}MB -> 暂停写 samples"
    LOW_DISK=1
  else
    [ "$LOW_DISK" = 1 ] && ev "DISK ok free=${free:-?}MB -> 恢复写 samples"
    LOW_DISK=0
  fi
  used=$(du -sm "$LOG_DIR" 2>/dev/null | awk '{print $1}')
  local guard=0
  while [[ "${used:-0}" =~ ^[0-9]+$ ]] && [ "$used" -gt "$MAX_TOTAL_MB" ] && [ $guard -lt 50 ]; do
    local victim
    victim=$(ls -1tr "$SAMPLES".*.gz "$OCLOG".*.gz 2>/dev/null | head -n1)
    [ -z "$victim" ] && victim=$(ls -1tr "$INC_DIR"/* 2>/dev/null | head -n1)
    [ -z "$victim" ] && break
    rm -f "$victim"; guard=$((guard+1))
    used=$(du -sm "$LOG_DIR" 2>/dev/null | awk '{print $1}')
  done
  [ $guard -gt 0 ] && ev "DISK cap ${MAX_TOTAL_MB}MB 超限，删除最旧轮转文件 ${guard} 个"
  return 0
}

gw_host() { # 当前会话所用账户的网关主机（无会话时用设置里的账户）
  local idx
  idx=$(grep -a '^ACCOUNT_INDEX=' "$STATE_FILE" 2>/dev/null | cut -d= -f2)
  if [[ "$idx" =~ ^[0-9]+$ ]]; then idx=$((idx+1)); else idx=${CFG[ACCOUNT]:-1}; fi
  gw_host_of "$idx"
}

# ping 解析：输出 "loss%/avg_ms"
ping_stat() { # 原始 ping -q 输出
  local out="$1" loss rtt
  loss=$(sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p' <<<"$out" | head -n1)
  rtt=$(sed -n 's/.*= [0-9.]*\/\([0-9.]*\)\/.*/\1/p' <<<"$out" | head -n1)
  printf '%s%%/%sms' "${loss:-?}" "${rtt:--}"
}

# ---------------- 读取 ocm 状态 ----------------
read_state() {
  ST_HAVE=0; ST_MODE=""; ST_PROTO=""; ST_PORT=""; ST_FWD=""; ST_USER=""; ST_PASS=""; ST_LISTEN=""
  [ -r "$STATE_FILE" ] || return 0
  ST_HAVE=1
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      MODE) ST_MODE=$v ;; VPN_PROTOCOL) ST_PROTO=$v ;; SOCKS_PORT) ST_PORT=$v ;;
      FORWARDER) ST_FWD=$v ;; LISTEN_ADDR) ST_LISTEN=$v ;;
    esac
  done < <(grep -aE '^(MODE|VPN_PROTOCOL|SOCKS_PORT|FORWARDER|LISTEN_ADDR)=' "$STATE_FILE" 2>/dev/null)
  if grep -aq '^SOCKS_USER=' "$STATE_FILE" 2>/dev/null; then
    # 值经 %q 转义，ocm 自己就是 source 这个文件的；在子 shell 里 source，只取这两项
    ST_USER=$( . "$STATE_FILE" >/dev/null 2>&1; printf '%s' "${SOCKS_USER:-}" )
    ST_PASS=$( . "$STATE_FILE" >/dev/null 2>&1; printf '%s' "${SOCKS_PASS:-}" )
  fi
  [[ "$ST_PORT" =~ ^[0-9]+$ ]] || ST_PORT=""
}

# ---------------- 采样 ----------------
declare -A PREV=()
TICK=0
OC_START=0; OC_START_PID=""; S_SESS="-"
HOST_EG="-"; HOST_EG_AT=0
LAST_SOCKS_EG="-"; FALLBACK=0
BAD_STREAK=0
GW_HOST=""

# 采一次样：设置 S_* 变量与 LINE、CAND（候选状态）、REASON
sample() {
  TICK=$((TICK+1))
  S_TS=$(now_ts); S_E=$(now_s)
  read_state

  # --- openconnect 进程 ---
  S_OCPID="-"; S_OCAGE="-"
  local p; p=$(cat "$PID_FILE" 2>/dev/null || true)
  if [[ "$p" =~ ^[0-9]+$ ]] && [ "$(cat /proc/$p/comm 2>/dev/null)" = openconnect ]; then
    S_OCPID=$p; S_OCAGE=$(ps -o etimes= -p "$p" 2>/dev/null | tr -d ' ')
  fi
  # 记住会话起点（≈认证时刻）：进程退出后仍能算出"断开时会话已持续多久"
  if [ "$S_OCPID" != "-" ] && [[ "$S_OCAGE" =~ ^[0-9]+$ ]]; then OC_START=$((S_E - S_OCAGE)); OC_START_PID=$S_OCPID; fi
  if [ "${OC_START:-0}" -gt 0 ]; then S_SESS=$((S_E - OC_START)); else S_SESS="-"; fi
  S_OCN=$(pgrep -c -x openconnect 2>/dev/null || true); S_OCN=${S_OCN:-0}
  S_GOST=$(pgrep -c -x gost 2>/dev/null || true); S_GOST=${S_GOST:-0}
  S_SOCAT=$(pgrep -c -x socat 2>/dev/null || true); S_SOCAT=${S_SOCAT:-0}

  # --- 隧道接口（netns 模式在命名空间里，default 模式在宿主上） ---
  local IPN=(ip); S_NS=0 want_tun=1
  if [ -e "/run/netns/$NETNS_NAME" ]; then S_NS=1; fi
  if [ "$ST_MODE" = netns ] || { [ -z "$ST_MODE" ] && [ $S_NS = 1 ]; }; then IPN=(ip -n "$NETNS_NAME"); fi
  # ocproxy 不建内核 tun；宿主上别的程序的 tun（组网等）不能算成 VPN 的
  case "$ST_MODE" in ocproxy|"") [ $S_NS = 1 ] || want_tun=0 ;; esac
  S_TUN="-"; S_TUNST="-"; S_TUNIP="-"; S_RX="-"; S_TX="-"; S_DEFTUN=0
  if [ $want_tun = 1 ] && { [ "${IPN[1]:-}" != "-n" ] || [ $S_NS = 1 ]; }; then
    local links; links=$(timeout 3 "${IPN[@]}" -o link show 2>/dev/null)
    if [ "$ST_MODE" = default ]; then S_TUN=$(grep -o "$OC_TUN_DEFAULT" <<<"$links" | head -n1)
    else S_TUN=$(grep -o 'tun[0-9]\+' <<<"$links" | head -n1); fi
    S_TUN=${S_TUN:--}
    if [ "$S_TUN" != "-" ]; then
      if grep -m1 " $S_TUN:" <<<"$links" | grep -q 'LOWER_UP'; then S_TUNST=UP; else S_TUNST=DOWN; fi
      S_TUNIP=$(timeout 3 "${IPN[@]}" -4 -o addr show dev "$S_TUN" 2>/dev/null | awk '{print $4; exit}'); S_TUNIP=${S_TUNIP:--}
      local rx tx
      read -r rx tx < <(timeout 3 "${IPN[@]}" -s link show dev "$S_TUN" 2>/dev/null | awk '/RX:/{getline; r=$1} /TX:/{getline; t=$1} END{print r+0, t+0}')
      if [[ "${rx:-}" =~ ^[0-9]+$ ]] && [[ "${PREV[rx]:-}" =~ ^[0-9]+$ ]] && [ "$rx" -ge "${PREV[rx]}" ]; then
        S_RX="+$((rx - PREV[rx]))"; S_TX="+$((tx - PREV[tx]))"
      else S_RX="new"; S_TX="new"; fi
      PREV[rx]=${rx:-}; PREV[tx]=${tx:-}
    else
      PREV[rx]=""; PREV[tx]=""
    fi
    timeout 3 "${IPN[@]}" route show default 2>/dev/null | grep -q 'dev tun' && S_DEFTUN=1
  fi

  # --- SOCKS 可用性（经代理真实发起一次 HTTP） ---
  S_LISTEN="-"; S_SOCKS="-"; S_SOCKSMS="-"; S_XPROBE="-"
  local proxy=""
  if [ -n "$ST_PORT" ]; then
    S_LISTEN=$(ss -Hlnt "sport = :$ST_PORT" 2>/dev/null | wc -l)
    local auth=""; [ -n "$ST_USER" ] && auth="${ST_USER}:${ST_PASS}@"
    proxy="socks5h://${auth}127.0.0.1:${ST_PORT}"
    local out
    out=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --connect-timeout 5 --max-time 10 -x "$proxy" "$PROBE_URL" 2>/dev/null)
    S_SOCKS=${out%% *}; S_SOCKS=${S_SOCKS:-000}
    S_SOCKSMS=$(awk -v t="${out##* }" 'BEGIN{printf "%d", t*1000}')
    if [ -n "$EXTRA_PROBE_URL" ]; then
      S_XPROBE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 12 -x "$proxy" "$EXTRA_PROBE_URL" 2>/dev/null); S_XPROBE=${S_XPROBE:-000}
    fi
  fi

  # --- 隧道内 ping（netns 内默认路由走 tun） ---
  S_TPING="-"
  if [ "$S_OCPID" != "-" ] && [ $S_NS = 1 ] && [ "$ST_MODE" = netns ]; then
    S_TPING=$(ping_stat "$(timeout 6 ip netns exec "$NETNS_NAME" ping -n -q -c 3 -i 0.3 -w 4 "$TUN_PING_TARGET" 2>/dev/null)")
  fi

  # --- 宿主侧：到 VPN 网关的 DNS / TCP 握手 / ping，宿主自身出网 ---
  { [ -z "$GW_HOST" ] || [ $((TICK % 120)) -eq 0 ]; } && GW_HOST=$(gw_host)
  S_GWIP="-"; S_GWTCP="-"; S_GWPING="-"; S_HPING="-"
  if [ -n "$GW_HOST" ]; then
    S_GWIP=$(timeout 4 getent ahostsv4 "$GW_HOST" 2>/dev/null | awk 'NR==1{print $1}'); S_GWIP=${S_GWIP:-DNSFAIL}
    if [ "$S_GWIP" != DNSFAIL ]; then
      local a b; a=$(ms_now)
      if timeout 4 bash -c ">/dev/tcp/$S_GWIP/443" 2>/dev/null; then b=$(ms_now); S_GWTCP="$((b-a))ms"; else S_GWTCP=FAIL; fi
      S_GWPING=$(ping_stat "$(ping -n -q -c 3 -i 0.3 -w 4 "$S_GWIP" 2>/dev/null)")
    fi
  fi
  S_HPING=$(ping_stat "$(ping -n -q -c 2 -i 0.3 -w 3 1.1.1.1 2>/dev/null)")

  # --- netns 出网依赖：MASQUERADE 规则、ip_forward、veth ---
  S_NAT=$(timeout 4 iptables -w 2 -t nat -S POSTROUTING 2>/dev/null | grep -c -- "-s $NAT_SUBNET")
  S_FWD=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "?")
  S_VETH=0; ip link show veth_ocm_h >/dev/null 2>&1 && S_VETH=1

  # --- netns 内 TCP 重传/超时增量（代理流量的实际质量） ---
  S_RETR="-"; S_TMO="-"
  if [ $S_NS = 1 ]; then
    local r t
    read -r r t < <(timeout 4 ip netns exec "$NETNS_NAME" nstat -asz 2>/dev/null | awk '$1=="TcpRetransSegs"{r=$2} $1=="TcpExtTCPTimeouts"{t=$2} END{print r+0, t+0}')
    if [[ "${PREV[retr]:-}" =~ ^[0-9]+$ ]] && [ "${r:-0}" -ge "${PREV[retr]}" ]; then
      S_RETR="+$((r - PREV[retr]))"; S_TMO="+$((t - PREV[tmo]))"
    fi
    PREV[retr]=${r:-0}; PREV[tmo]=${t:-0}
  else PREV[retr]=""; PREV[tmo]=""; fi

  S_MEM=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)

  # --- 出口 IP（低频）：经 SOCKS 的出口 vs 宿主出口；相同 = 代理没走 VPN ---
  S_EG="-"; S_NSDNS="-"
  if [ -n "$proxy" ] && { [ $((TICK % EGRESS_EVERY)) -eq 1 ] || [ "${FORCE_EGRESS:-0}" = 1 ]; }; then
    if [ "$HOST_EG" = "-" ] || [ $((S_E - HOST_EG_AT)) -ge "$HOST_EGRESS_TTL" ]; then
      local h; h=$(curl -4 -s --max-time 6 https://api.ipify.org 2>/dev/null || true)
      [ -z "$h" ] && h=$(curl -4 -s --max-time 6 https://ifconfig.me/ip 2>/dev/null || true)
      if [[ "$h" =~ ^[0-9.]+$ ]]; then HOST_EG=$h; HOST_EG_AT=$S_E; fi
    fi
    S_EG=$(curl -4 -s --connect-timeout 5 --max-time 10 -x "$proxy" https://api.ipify.org 2>/dev/null || true)
    [[ "$S_EG" =~ ^[0-9.]+$ ]] || S_EG="FAIL"
    if [ "$S_EG" != FAIL ]; then
      LAST_SOCKS_EG=$S_EG
      if [ "$HOST_EG" != "-" ] && [ "$S_EG" = "$HOST_EG" ]; then FALLBACK=1; else FALLBACK=0; fi
    fi
    if [ $S_NS = 1 ]; then
      if timeout 5 ip netns exec "$NETNS_NAME" getent ahostsv4 www.gstatic.com >/dev/null 2>&1; then S_NSDNS=ok; else S_NSDNS=FAIL; fi
    fi
  fi
  [ -z "$proxy" ] && FALLBACK=0
  S_FB="-"
  if [ -r "$FB_STATE_FILE" ]; then local _fa _fn; read -r _ _fa _fn < "$FB_STATE_FILE"; S_FB="${_fn// /_}@${_fa}"; fi

  # --- 判定候选状态 ---
  REASON=""
  if [ "$ST_HAVE" = 0 ]; then
    if [ "$S_OCN" -gt 0 ]; then
      # ocm 的 netns 启动流程在最后才写 state：刚起的 openconnect 先算 STARTING
      local young; young=$(ps -o etimes= -p "$(pgrep -n -x openconnect)" 2>/dev/null | tr -d ' ')
      if [[ "$young" =~ ^[0-9]+$ ]] && [ "$young" -lt "$STARTUP_GRACE" ]; then
        CAND=STARTING; REASON="openconnect-up-${young}s-waiting-for-ocm-state"
      else
        CAND=UNMANAGED; REASON="openconnect-running-without-ocm-state"
      fi
    else CAND=STOPPED; fi
  elif [ "$S_OCPID" = "-" ]; then
    CAND=DOWN; REASON="openconnect-gone(state-file-still-present)"
  else
    local pr=""
    if [ "$ST_MODE" = netns ]; then
      [ $S_NS = 1 ] || pr="${pr}netns-missing,"
      [ "$S_TUN" = "-" ] && pr="${pr}tun-missing,"
      [ "$S_TUN" != "-" ] && [ "$S_TUNST" != UP ] && pr="${pr}tun-down,"
      [ $S_DEFTUN = 1 ] || pr="${pr}no-default-via-tun,"
      [ "$S_NAT" -ge 1 ] 2>/dev/null || pr="${pr}masquerade-missing,"
      [ "$S_FWD" = 1 ] || pr="${pr}ip_forward-off,"
    fi
    if [ -n "$ST_PORT" ]; then
      [ "$S_LISTEN" -ge 1 ] 2>/dev/null || pr="${pr}socks-not-listening,"
      [[ "$S_SOCKS" =~ ^[23] ]] || pr="${pr}socks-probe-fail(${S_SOCKS}),"
    fi
    if [ -n "$pr" ]; then
      REASON=${pr%,}
      if [[ "$S_OCAGE" =~ ^[0-9]+$ ]] && [ "$S_OCAGE" -lt "$STARTUP_GRACE" ]; then CAND=STARTING; else CAND=DEGRADED; fi
    elif [ "$FALLBACK" = 1 ]; then
      CAND=FALLBACK; REASON="socks-egress==host-egress(${HOST_EG})"
    else
      CAND=UP
    fi
  fi

  LINE=$(printf '%s st=%s mode=%s proto=%s oc=%s age=%s sess=%s ocn=%s gost=%s socat=%s tun=%s/%s ip=%s deftun=%s rx=%s tx=%s listen=%s socks=%s/%sms xprobe=%s tping=%s gw=%s gwtcp=%s gwping=%s hping=%s nat=%s fwd=%s veth=%s retr=%s tmo=%s eg=%s nsdns=%s fb=%s mem=%sMB%s' \
    "$S_TS" "$CAND" "${ST_MODE:--}" "${ST_PROTO:--}" "$S_OCPID" "$S_OCAGE" "$S_SESS" "$S_OCN" "$S_GOST" "$S_SOCAT" \
    "$S_TUN" "$S_TUNST" "$S_TUNIP" "$S_DEFTUN" "$S_RX" "$S_TX" "$S_LISTEN" "$S_SOCKS" "$S_SOCKSMS" "$S_XPROBE" \
    "$S_TPING" "$S_GWIP" "$S_GWTCP" "$S_GWPING" "$S_HPING" "$S_NAT" "$S_FWD" "$S_VETH" "$S_RETR" "$S_TMO" \
    "$S_EG" "$S_NSDNS" "$S_FB" "$S_MEM" "$([ -n "$REASON" ] && printf ' why=%s' "$REASON")")
}

# ---------------- 现场快照 ----------------
LAST_SNAP=0
snapshot() { # 标签
  local tag="${1:-manual}" f
  watch_dirs
  f="$INC_DIR/$(printf '%(%Y%m%d-%H%M%S)T' -1)-${tag//[^A-Za-z0-9_.-]/_}.txt"
  {
    sec() { printf '\n===== %s =====\n' "$1"; }
    printf 'oc-master %s incident snapshot  tag=%s  time=%s  host=%s\n' "$VERSION" "$tag" "$(now_ts)" "$(hostname)"
    sec "最近 12 条采样"; tail -n 12 "$SAMPLES" 2>/dev/null
    sec "最近 15 条事件"; tail -n 15 "$EVENTS" 2>/dev/null
    sec "openconnect 输出（最近 150 行）"; tail -n 150 "$OCLOG" 2>/dev/null
    sec "supervisor 阶段 / 服务状态"; cat "$PHASE_FILE" 2>/dev/null; systemctl --no-pager --lines=0 status "$SVC_MAIN" 2>/dev/null | head -n 6
    sec "ocm state 文件（已脱敏）"; sed -E 's/^(SOCKS_PASS)=.*/\1=<redacted>/' "$STATE_FILE" 2>/dev/null || echo "(不存在)"
    sec "相关进程"; ps -eo pid,ppid,etimes,stat,rss,args 2>/dev/null | grep -E 'openconnect|gost|socat|ocproxy|oc_master|ocm' | grep -v grep
    sec "at 队列（ocm 的保底 stop 任务）"; atq 2>/dev/null
    sec "netns: link/addr/route"
    timeout 4 ip -n "$NETNS_NAME" -s link 2>/dev/null; timeout 4 ip -n "$NETNS_NAME" addr 2>/dev/null; timeout 4 ip -n "$NETNS_NAME" route 2>/dev/null
    sec "netns: resolv.conf / TCP 概况"
    cat "/etc/netns/$NETNS_NAME/resolv.conf" 2>/dev/null; timeout 4 ip netns exec "$NETNS_NAME" ss -s 2>/dev/null
    timeout 4 ip netns exec "$NETNS_NAME" ss -tnp 2>/dev/null | head -n 40
    sec "宿主: ip rule / route / veth"
    ip rule 2>/dev/null; ip route 2>/dev/null; ip -s link show veth_ocm_h 2>/dev/null
    sec "宿主: iptables nat（与 netns/端口相关）"
    timeout 5 iptables -w 2 -t nat -S 2>/dev/null | grep -E "192\.168\.200|MASQUERADE|${ST_PORT:-8585}" 
    sec "宿主: sysctl"
    sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding "net.ipv4.conf.veth_ocm_h.route_localnet" 2>/dev/null
    sec "宿主: 监听端口"; ss -lntp 2>/dev/null | grep -E ":${ST_PORT:-8585}\b" 
    sec "连通性复测"
    local gw; gw=$(gw_host)
    echo "gw_host=$gw"; timeout 4 getent ahostsv4 "$gw" 2>/dev/null | head -n 3
    ping -n -c 4 -i 0.3 -w 5 "$gw" 2>&1 | tail -n 3
    timeout 8 curl -s -o /dev/null -w 'gw https: code=%{http_code} connect=%{time_connect}s tls=%{time_appconnect}s total=%{time_total}s\n' "https://$gw/" 2>&1
    ping -n -c 3 -w 4 1.1.1.1 2>&1 | tail -n 2
    timeout 6 ip netns exec "$NETNS_NAME" ping -n -c 3 -w 4 "$TUN_PING_TARGET" 2>&1 | tail -n 2
    timeout 6 ip netns exec "$NETNS_NAME" getent ahostsv4 www.gstatic.com 2>&1 | head -n 2
    [ -n "${ST_PORT:-}" ] && curl -s -o /dev/null -w "socks probe: code=%{http_code} total=%{time_total}s\n" --max-time 10 -x "socks5h://127.0.0.1:${ST_PORT}" "$PROBE_URL" 2>&1
    sec "内存 / OOM / 内核消息（最近 30 分钟）"
    free -m; ps -eo pid,rss,comm --sort=-rss | head -n 8
    timeout 10 journalctl -k --since "-30min" --no-pager -o short-iso 2>/dev/null | tail -n 60
    sec "系统 warning 以上日志（最近 15 分钟）"
    timeout 15 journalctl -p warning --since "-15min" --no-pager -o short-iso 2>/dev/null | grep -vE 'ocm-sentinel' | tail -n 60 | redact
    sec "TCP 计数（宿主）"; nstat -asz 2>/dev/null | grep -E 'TcpRetransSegs|TCPTimeouts|TCPAbortOn|TcpExtListenDrops' 
  } > "$f" 2>&1
  chmod 640 "$f" 2>/dev/null || true
  ls -1 "$INC_DIR"/*.txt 2>/dev/null | sort | head -n -"$KEEP_INCIDENTS" | xargs -r rm -f
  printf '%s' "$f"
}

# ---------------- 主循环 ----------------
_watch_loop() {
  watch_dirs
  trap 'ev "WATCH stop pid=$$ (signal)"; exit 0' TERM INT
  ev "WATCH start v$VERSION pid=$$ interval=${INTERVAL}s fast=${FAST_INTERVAL}s/${FAST_WINDOW}s probe=$PROBE_URL"

  local status="" since=0 fast_until=0 last_hb=0 t0 dt nap now bad_start=0 bad_since=0 bad_from=""
  status="INIT"; since=$(now_s); last_hb=$since
  FORCE_EGRESS=1
  while :; do
    t0=$(now_s)
    sample
    FORCE_EGRESS=0
    now=$S_E

    # --- 会话时间轴里程碑：会话年龄跨过 AGE_MARKS 时记一笔（同一 openconnect 进程内） ---
    if [ "$S_OCPID" != "-" ] && [[ "$S_OCAGE" =~ ^[0-9]+$ ]]; then
      local pa=${PREV[ocage]:-} m
      if [ "${PREV[ocagepid]:-}" = "$S_OCPID" ] && [[ "$pa" =~ ^[0-9]+$ ]]; then
        for m in $AGE_MARKS; do
          if [ "$pa" -lt "$m" ] && [ "$S_OCAGE" -ge "$m" ]; then
            ev "SESSION age_mark=$(fmt_dur $m) age=$S_OCAGE pid=$S_OCPID status=$status cand=$CAND socks=$S_SOCKS/${S_SOCKSMS}ms tping=$S_TPING rx=$S_RX tx=$S_TX started=$(date -d "@$OC_START" '+%F %T')"
          fi
        done
      fi
      PREV[ocage]=$S_OCAGE; PREV[ocagepid]=$S_OCPID
    fi

    # --- 字段变化事件（不必等状态迁移） ---
    local chg="" k v
    for k in OCPID:"$S_OCPID" TUNIP:"$S_TUNIP" GWIP:"$S_GWIP" NAT:"$S_NAT" FWD:"$S_FWD" VETH:"$S_VETH" MODE:"${ST_MODE:--}" PROTO:"${ST_PROTO:--}"; do
      v=${k#*:}; k=${k%%:*}
      if [ -n "${PREV[$k]+x}" ] && [ "${PREV[$k]}" != "$v" ]; then chg="${chg} ${k}:${PREV[$k]}->${v}"; fi
      PREV[$k]=$v
    done
    if [ "$S_EG" != "-" ] && [ "$S_EG" != FAIL ]; then
      [ -n "${PREV[EG]+x}" ] && [ "${PREV[EG]}" != "$S_EG" ] && chg="${chg} EGRESS:${PREV[EG]}->${S_EG}"
      PREV[EG]=$S_EG
    fi
    # 网关可达性翻转也单独记（区分"学校网关挂了/路由断了" 与 "本机问题"）
    local gwok=1; [ "$S_GWTCP" = FAIL ] && gwok=0; [ "$S_GWIP" = DNSFAIL ] && gwok=0
    [ -n "${PREV[GWOK]+x}" ] && [ "${PREV[GWOK]}" != "$gwok" ] && chg="${chg} GW_REACH:${PREV[GWOK]}->${gwok}(tcp=${S_GWTCP},ping=${S_GWPING})"
    PREV[GWOK]=$gwok
    [ -n "$chg" ] && ev "CHANGE${chg}"

    # --- 状态迁移（UP→DEGRADED 需连续确认，其它立即生效） ---
    local new=$CAND
    # 已经 UP 过的会话再出问题就是"运行中异常"，不能因为进程年轻就归为 STARTING
    [ "$new" = STARTING ] && [ "$status" = UP ] && [ "$ST_HAVE" = 1 ] && new=DEGRADED
    if [ "$new" = DEGRADED ] && [ "$status" = UP ]; then
      BAD_STREAK=$((BAD_STREAK+1))
      if [ $BAD_STREAK -lt "$BAD_CONFIRM" ]; then
        new=UP
        fast_until=$((now + FAST_WINDOW))
        ev "WARN 单次异常待确认 (${BAD_STREAK}/${BAD_CONFIRM}): ${REASON}"
        [ $BAD_STREAK -eq 1 ] && bad_start=$now
      fi
    else
      [ "$new" = UP ] && BAD_STREAK=0
    fi

    if [ "$new" != "$status" ]; then
      local held=$((now - since)) heal=0
      # supervisor 正在重连期间的状态变化不算人工停止
      case "$(get_phase)" in reconnecting|connecting) heal=1;; esac
      ev "STATUS from=$status to=$new heal=$heal held=$held held_h=$(fmt_dur $held) session_age=$S_SESS session_age_h=$(fmt_dur "$S_SESS") session_pid=${OC_START_PID:--} reason=${REASON:-ok} oc=$S_OCPID tun=$S_TUN/$S_TUNST socks=$S_SOCKS gwtcp=$S_GWTCP"
      case "$new" in
        DOWN|DEGRADED|FALLBACK|UNMANAGED)
          fast_until=$((now + FAST_WINDOW)); FORCE_EGRESS=1
          # 把 openconnect 最后几行话直接放进事件，事后不翻文件也能一眼看到原因
          tail -n 6 "$OCLOG" 2>/dev/null | while IFS= read -r l; do ev "OCLAST $l"; done
          ;;
      esac
      # 断线计时：从"最初进入异常"算起，中间经过 STARTING 等过渡状态不打断
      if [[ "$new" =~ ^(DOWN|DEGRADED|FALLBACK|UNMANAGED)$ ]] && [ "$bad_since" = 0 ]; then bad_since=$now; bad_from=$status; fi
      if [ "$new" = UP ] && [ "$bad_since" != 0 ]; then
        ev "RECOVERED outage=$((now - bad_since)) outage_h=$(fmt_dur $((now - bad_since))) (since leaving $bad_from)"
        bad_since=0
      fi
      [ "$new" = STOPPED ] && { [ "$heal" = 1 ] || bad_since=0; OC_START=0; OC_START_PID=""; }
      # 离开 UP 或进入异常：保存现场（后台进行，不拖慢采样；同一分钟内最多一份，DOWN 除外）
      if { [ "$status" = UP ] || [[ "$new" =~ ^(DOWN|DEGRADED|FALLBACK|UNMANAGED)$ ]]; } && [ "$status" != INIT ]; then
        if [ "$new" = DOWN ] || [ $((now - LAST_SNAP)) -ge 60 ]; then
          LAST_SNAP=$now
          ( sleep 2; f=$(snapshot "${status}-to-${new}"); ev "INCIDENT saved $f" ) &
        fi
      fi
      status=$new; since=$now
    fi

    # --- 软重连：openconnect 还在，但代理持续不通 / 出口回落到宿主 ---
    if [ "${CFG[AUTO_RECONNECT]}" = on ] && [ "$S_OCPID" != "-" ] && [ "$(get_phase)" = up ] && svc_active; then
      local want=""
      [ "$status" = DEGRADED ] && [ $((now - since)) -ge "${CFG[DEGRADED_WAIT]}" ] && want="degraded-$((now - since))s:${REASON}"
      [ "$status" = FALLBACK ] && [ $((now - since)) -ge 20 ] && want="fallback:${REASON}"
      if [ -n "$want" ] && [ $((now - LAST_KICK)) -ge 120 ]; then
        LAST_KICK=$now; touch "$RESTART_REQ"; kill -TERM "$S_OCPID" 2>/dev/null
        ev "WATCH restart-request reason=$want pid=$S_OCPID"
      fi
    fi

    # --- 写采样 ---
    [ "$LOW_DISK" = 0 ] && printf '%s\n' "$LINE" >> "$SAMPLES" 2>/dev/null
    printf '%s %s %s\n' "$status" "$since" "$LINE" > "$WATCH_LIB/current" 2>/dev/null

    # --- 心跳、轮转、磁盘、跟随进程看护 ---
    if [ $((now - last_hb)) -ge "$HEARTBEAT_EVERY" ]; then
      ev "HEARTBEAT status=$status for=$(fmt_dur $((now - since))) samples=$(stat -c%s "$SAMPLES" 2>/dev/null)B"
      last_hb=$now
    fi
    rotate_file "$SAMPLES" "$KEEP_SAMPLES"
    rotate_file "$EVENTS" "$KEEP_EVENTS"
    rotate_file "$OCLOG" "$KEEP_OCLOG"
    [ $((TICK % 10)) -eq 1 ] && disk_guard
    [ $((TICK % 20)) -eq 0 ] && watch_reload_cfg

    local inwin=0
    [[ "$S_OCAGE" =~ ^[0-9]+$ ]] && [ "$S_OCAGE" -ge "$AGE_WATCH_FROM" ] && [ "$S_OCAGE" -le "$AGE_WATCH_TO" ] && inwin=1
    if [ "$now" -lt "$fast_until" ] || [ $inwin = 1 ]; then nap=$FAST_INTERVAL
    elif [ "$status" = STOPPED ]; then nap=$IDLE_INTERVAL
    else nap=$INTERVAL; fi
    dt=$(( $(now_s) - t0 )); nap=$((nap - dt)); [ $nap -lt 1 ] && nap=1
    # 两次采样之间每 WATCH_STEP 秒做一次极轻量存活检查（不发网络请求）：
    #   会话出现/消失、openconnect 进程退出 → 立即提前采样，断线时刻精确到约 5 秒。
    local end=$(( $(now_s) + nap )) left step
    while :; do
      left=$(( end - $(now_s) )); [ $left -le 0 ] && break
      step=$WATCH_STEP; [ $left -lt $step ] && step=$left
      sleep "$step" & wait $!
      if [ "$status" = STOPPED ]; then
        { [ -f "$STATE_FILE" ] || pgrep -x openconnect >/dev/null 2>&1; } && break
      else
        [ -f "$STATE_FILE" ] || break
        [ "$S_OCPID" != "-" ] && ! kill -0 "$S_OCPID" 2>/dev/null && break
        [ "$S_OCPID" = "-" ] && [ -r "$PID_FILE" ] && break
      fi
    done
  done
}

# ---------------- 报告 ----------------
cmd_report() {
  local days="${1:-7}"; [[ "$days" =~ ^[0-9]+$ ]] || days=7
  local cutoff=$(( $(now_s) - days*86400 ))
  echo "== ocm 诊断报告：最近 ${days} 天（$(date -d "@$cutoff" '+%F %T') 起）=="
  # 每一段都要 || true：前台是 set -e + pipefail，没有轮转文件时 ls 失败会让整个子 shell 提前退出、后面的 cat 不执行
  { { ls -1 "$EVENTS".*.gz 2>/dev/null | sort | xargs -r zcat 2>/dev/null; } || true; cat "$EVENTS" 2>/dev/null || true; } \
  | awk -v cut="$cutoff" -v nowe="$(now_s)" -v slo="$AGE_SUSPECT_LO" -v shi="$AGE_SUSPECT_HI" '
    function kv(k,   i,a){ for(i=2;i<=NF;i++){ if(index($i,k"=")==1){ return substr($i,length(k)+2) } } return "" }
    function dur(s,  d,h,m){ d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60); if(d>0) return sprintf("%dd%02dh%02dm",d,h,m); if(h>0) return sprintf("%dh%02dm",h,m); if(m>0) return sprintf("%dm%02ds",m,s%60); return sprintf("%ds",s) }
    { e=kv("e")+0 }
    $3=="STATUS" {
      from=kv("from"); to=kv("to"); held=kv("held")+0
      if (e>=cut) {
        st=(e-held<cut)? cut : e-held
        if (from!="INIT") tm[from]+= (e-st)
        # 连续的异常状态（DOWN→STARTING→DEGRADED…）合并成一次断线，原因依次拼接
        if (to ~ /^(DOWN|DEGRADED|FALLBACK|UNMANAGED)$/) {
          if (open>0) { why[open]=why[open] " ; " to ":" kv("reason") }
          else { n++; ts[n]=$1; fr[n]=from; tt[n]=to; why[n]=kv("reason") ((plpid!="" && kv("session_pid")==plpid) ? " [定时重连]" : ""); hf[n]=held; be[n]=e; sa[n]=kv("session_age"); open=n }
        }
        if (to=="UP" && open>0) { rec[open]=e-be[open]; open=0 }
        if (to=="STOPPED" && open>0 && kv("heal")!="1") { rec[open]=-1; open=0 }
        # 会话结束时间轴：离开 UP 的那一刻会话已持续多久（人工停止单独标注）
        # 只有会话真正结束（进程退出/出口回落/被停止）才算；DEGRADED 是会话内的短暂故障，另行统计
        if (from=="UP" && to=="DEGRADED") blips++
        if (from=="UP" && to!="UP" && to!="DEGRADED") {
          a=kv("session_age")
          if (a ~ /^[0-9]+$/) {
            se++; se_ts[se]=$1; se_to[se]=to; se_age[se]=a+0; se_why[se]=kv("reason")
            se_man[se]=(md>0 && e-md<=60) ? 1 : 0
            se_pl[se]=(!se_man[se] && plpid!="" && kv("session_pid")==plpid) ? 1 : 0
            if (!se_man[se] && !se_pl[se] && a+0>=slo && a+0<=shi) near2h++
            if (!se_man[se] && !se_pl[se]) unplanned++
          }
        }
      }
      last_to=to; last_e=e
    }
    # 记录器自身停机期间状态未知：正常停止时结算到停止时刻，异常退出（无 stop 行）则不计
    ($3=="SENTINEL" || $3=="WATCH") && $4=="stop" { if (last_to!="" && e>=cut) { st=(last_e<cut)?cut:last_e; if (last_to!="INIT") tm[last_to]+=e-st } ; last_to=""; last_e=0 }
    ($3=="SENTINEL" || $3=="WATCH") && $4=="start" { last_to=""; last_e=0 }
    $3=="OC" && e>=cut {
      m=tolower($0)
      if (m ~ /dead peer|dpd/) c["DPD/对端失联"]++
      if (m ~ /reconnect/) c["重连"]++
      if (m ~ /terminat|session.*(end|expir)|expired/) c["会话被终止/过期"]++
      if (m ~ /esp/) c["ESP 相关"]++
      if (m ~ /fail|error|refused|denied|unauthor/) c["失败/错误"]++
      if (m ~ /cancel|sigint|sigterm/) c["人工/信号退出"]++
      if (m ~ /establish/) c["隧道建立"]++
    }
    $3=="SUP" && e>=cut {
      if ($4=="exit") { sx++; sk[kv("kind")]++ }
      if ($4=="up") sup++
      if ($4=="paused" || $4=="rate-limited") ahP++
      if ($4=="fallback") { if ($5=="on") fbn++; else if ($5=="off") fbd+=kv("dur")+0; else if ($5=="unavailable") fbu++ }
      if ($4=="planned-restart" && $5 ~ /^session=/) { plc++; plpid=kv("pid") }
      if ($4 ~ /^(exit|up|paused|rate-limited|start|stop|child-died|fail|no-reconnect|fallback|planned-restart)$/) { ah++; ahs[ah]=$0 }
      next
    }
    $3=="WATCH" && $4=="restart-request" && e>=cut { wr++; ah++; ahs[ah]=$0; next }
    $3=="MARK" && $4=="AUTOHEAL" && e>=cut {
      ah++; ahs[ah]=$0
      if ($5=="trigger") ahT++
      if ($5 ~ /^result=ok/) ahOK++
      if ($5 ~ /^result=FAIL/) ahF++
      if ($5=="paused:" || $5=="rate-limited:") ahP++
      next
    }
    $3=="MARK" && e>=cut {
      if ($0 ~ /\[autoheal\]/) next
      mk++; mks[mk]=$0; if ($0 ~ /ocm-nc down|ocm stop|TEST:|启动前清理/) md=e
    }
    $3=="SESSION" && e>=cut { sm++; sms[sm]=$0 }
    $3=="CHANGE" && e>=cut { ch++; chs[ch]=$0 }
    END {
      if (last_to!="" && last_e>0) { st=(last_e<cut)?cut:last_e; tm[last_to]+= nowe-st }
      tot=0; for (k in tm) if (k!="STOPPED") tot+=tm[k]
      printf "当前状态：%s（已持续 %s）\n", (last_to==""?"未知":last_to), (last_e>0?dur(nowe-last_e):"-")
      printf "状态时长："
      for (k in tm) printf " %s=%s", k, dur(tm[k])
      if (tot>0 && ("UP" in tm)) printf "  | 可用率（不计 STOPPED）%.2f%%", 100*tm["UP"]/tot
      printf "\n\n异常/断线次数：%d\n", n
      for (i=1;i<=n;i++) printf "  %s  %s→%s  会话已持续 %-10s 恢复用时 %-12s 原因 %s\n", ts[i], fr[i], tt[i], (sa[i] ~ /^[0-9]+$/ ? dur(sa[i]+0) : "?"), (i in rec ? (rec[i]<0?"被停止":dur(rec[i])) : "尚未恢复"), why[i]
      printf "\n会话结束时间轴（离开 UP 时距认证多久；≈2h = %s–%s）：\n", dur(slo), dur(shi)
      if (!se) print "  （暂无会话结束记录）"
      for (i=1;i<=se;i++) printf "  %s  →%-9s 会话时长 %-10s %s%s%s  %s\n", se_ts[i], se_to[i], dur(se_age[i]), (se_man[i]?"[人工] ":""), (se_pl[i]?"[计划] ":""), (!se_man[i] && !se_pl[i] && se_age[i]>=slo && se_age[i]<=shi ? "[≈2h!] " : ""), se_why[i]
      if (unplanned>0) printf "  非人工结束 %d 次，其中落在 ≈2h 区间 %d 次\n", unplanned, near2h
      if (plc>0) printf "  定时重连（主动登出后重连）%d 次\n", plc
      printf "  会话内短暂故障（DEGRADED，未断开）%d 次\n", blips
      printf "\n自动重连：openconnect 退出 %d 次", sx
      if (sx) { printf "（"; sep=""; for (k in sk) { printf "%s%s=%d", sep, k, sk[k]; sep=" " } printf "）" }
      printf "，重新就绪 %d 次，软重连请求 %d 次，暂停或限速 %d 次", sup, wr, ahP
      if (ahT) printf "；旧版 autoheal 触发 %d 次（成功 %d / 失败 %d）", ahT, ahOK, ahF
      printf "（最近 15 条）：\n"
      if (!ah) print "  （无）"
      for (i=(ah>15?ah-14:1); i<=ah; i++) print "  " ahs[i]
      if (fbn || fbu) printf "回落代理：启用 / 切换 %d 次，累计使用 %s；回落代理全部不可用 %d 次\n", fbn, dur(fbd), fbu
      printf "\n会话里程碑（最近 12 条，共 %d）：\n", sm
      for (i=(sm>12?sm-11:1); i<=sm; i++) print "  " sms[i]
      printf "\nopenconnect 关键消息统计：\n"; nc=0
      for (k in c) { printf "  %-16s %d\n", k, c[k]; nc++ }
      if (!nc) print "  （无）"
      printf "\n字段变化（最近 15 条，共 %d）：\n", ch
      for (i=(ch>15?ch-14:1); i<=ch; i++) print "  " chs[i]
      printf "\n人工标记（最近 10 条，共 %d）：\n", mk
      for (i=(mk>10?mk-9:1); i<=mk; i++) print "  " mks[i]
    }'
  echo
  echo "最近的现场快照："; ls -1t "$INC_DIR"/*.txt 2>/dev/null | head -n 8 | sed 's/^/  /' || true
  echo
  echo "细查：grep -E 'STATUS|OC |CHANGE|INCIDENT' $EVENTS | tail -n 50"
  echo "      less $OCLOG    zcat -f $SAMPLES* | grep -v 'st=UP'"
}


# --- 定时与卸载 ---
# 写 crontab 前先留一份副本：下面几处都是 `... | crontab -` 的写法，一旦 `crontab -l`
# 因故返回空（权限、并发写、命令异常），整份 crontab 就会被空内容覆盖——生产机上那可能
# 是几十条任务。备份只在 crontab 非空时做，写不进去也不阻断后续操作。
_CRON_BAK="/root/.oc_master-crontab.bak"
_backup_crontab() {
  local cur=""
  cur="$(crontab -l 2>/dev/null || true)"
  [ -n "$cur" ] || return 0
  # crontab 里常有口令/token：备份文件用 600，不要用默认 umask 落成 644
  if ( umask 077; printf '%s\n' "$cur" > "$_CRON_BAK" ) 2>/dev/null; then
    log_info "已备份当前 crontab 到 ${_CRON_BAK}"
  else
    log_warn "备份 crontab 失败（${_CRON_BAK} 不可写），继续操作。"
  fi
  return 0
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
  uninstall_units; log "systemd 单元已移除"
  local yl=""; read -rp "是否同时删除设置与诊断日志（${CONF_DIR}、${LOG_DIR}）? [y/N]: " yl || yl=""
  if [[ "$yl" =~ ^[yY]$ ]]; then rm -rf "$CONF_DIR" "$LOG_DIR" "$WATCH_LIB" "$RUN_DIR"; log "设置与日志已删除"; else log_info "已保留 ${CONF_DIR} 与 ${LOG_DIR}"; fi
  _backup_crontab
  crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab - 2>/dev/null || true; log "定时任务已清理"
  
  if command -v gost &>/dev/null; then
    if _ask_uninstall_dep gost "Netns 模式的 SOCKS5 服务端"; then
      # 官方 install.sh 只认 --install 一个参数，没有卸载分支：传 --remove 之类的参数
      # 会掉进"选择版本"的安装菜单（交互选一次就真的把它装回去/升级），
      # 而 select 在非交互下失败后旧代码仍打印"已尝试卸载"——是句假话。
      # gost 是单个二进制、无包管理器记录，所以直接删文件。
      log_info "正在卸载 gost..."
      # 优先按 PID 文件停掉"本脚本启动的"那一个：pkill -x gost 是进程名全局匹配，会把
      # 机器上别的用途的 gost 一起杀掉。所以只在没有本脚本的 PID 记录、且确实还有
      # gost 在跑时才询问，由用户决定要不要按名字全杀。
      local _gp=""
      if [ -f "$GOST_PID_FILE" ]; then
        _gp="$(cat "$GOST_PID_FILE" 2>/dev/null || echo "")"
        if [ -n "$_gp" ] && [ "$(cat /proc/${_gp}/comm 2>/dev/null)" = "gost" ]; then
          kill "$_gp" 2>/dev/null || true
        else
          _gp=""
        fi
      fi
      if [ -z "$_gp" ] && command -v pgrep &>/dev/null && pgrep -x gost >/dev/null 2>&1; then
        log_warn "检测到仍在运行的 gost 进程（不是本脚本记录的那个），可能属于别的用途。"
        local _gk=""
        read -rp "是否按进程名结束全部 gost? [y/N]: " _gk || _gk=""
        [[ "$_gk" =~ ^[yY]$ ]] && { pkill -x gost 2>/dev/null || true; }
      fi
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

# ============================================================================
#  设置菜单
# ----------------------------------------------------------------------------
#  target=cfg：修改并保存到 settings.conf；target=ovr：只改本次（启动前「t」），不保存。
#  choice 类型用数字选；int/text 类型的常用预设用字母选，也可以直接输入值。
# ============================================================================
_pause() { read -n1 -s -rp "${1:-按任意键返回...}" || true; echo; }

settings_edit_item() {
  local k="$1" target="${2:-cfg}" t="${SET_TYPE[$1]}" v="" a old j c
  local -a cs=()
  clear 2>/dev/null || true
  title "🔧 ${SET_TITLE[$k]}   ${C_GREY}($k)${C_RESET}"; sep
  _set_help "$k"; sep
  echo -e "当前：${C_CYAN}$(cfg_label "$k")${C_RESET}"
  [ -n "${SET_CHOICES[$k]}" ] && IFS=',' read -r -a cs <<<"${SET_CHOICES[$k]}"
  case "$t" in
    choice)
      j=0; for c in "${cs[@]}"; do j=$((j+1)); printf '  %d) %s  %s\n' "$j" "${c#*:}" "$(echo -e "${C_GREY}[${c%%:*}]${C_RESET}")"; done
      read -rp "选择编号（回车保持不变）: " a || return 0
      [ -z "$a" ] && return 0
      [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le ${#cs[@]} ] || { log_err "无效编号"; _pause; return 0; }
      v=${cs[$((a-1))]%%:*} ;;
    int|text)
      local letters=abcdefghij
      j=0; for c in "${cs[@]}"; do printf '  %s) %s  %s\n' "${letters:$j:1}" "${c#*:}" "$(echo -e "${C_GREY}[${c%%:*}]${C_RESET}")"; j=$((j+1)); done
      if [ "$t" = text ]; then read -rp "选字母预设、直接输入新值，或输入 - 清空（回车保持不变）: " a || return 0
      else read -rp "选字母预设或直接输入数字（回车保持不变）: " a || return 0; fi
      [ -z "$a" ] && return 0
      if [[ "$a" =~ ^[a-j]$ ]]; then
        j=$(( $(printf '%d' "'$a") - 97 )); [ $j -lt ${#cs[@]} ] || { log_err "无效预设"; _pause; return 0; }
        v=${cs[$j]%%:*}
      elif [ "$t" = text ] && [ "$a" = - ]; then v=""
      else v="$a"; fi ;;
    account)
      accounts_list
      read -rp "选择账户序号（回车保持不变）: " a || return 0
      [ -z "$a" ] && return 0
      v="$a" ;;
    auth)
      local u="" p="" yn=""
      read -rp "启用 SOCKS5 认证? [y/N]: " yn || return 0
      if [[ "$yn" =~ ^[yY]$ ]]; then
        read -rp "  用户名: " u || return 0
        settings_validate SOCKS_USER "$u" && [ -n "$u" ] || { log_err "用户名无效"; _pause; return 0; }
        read -rsp "  密码: " p || return 0; echo
        settings_validate SOCKS_PASS "$p" && [ -n "$p" ] || { log_err "密码无效"; _pause; return 0; }
      fi
      CFG[SOCKS_USER]=$u; CFG[SOCKS_PASS]=$p
      if [ "$target" = ovr ]; then OVR[SOCKS_USER]=$u; OVR[SOCKS_PASS]=$p
      else settings_save; ev "CONFIG SOCKS_AUTH -> ${u:+on(user=$u)}${u:-off}"; fi
      log "已设置：$(cfg_label SOCKS_AUTH)"; _settings_restart_note "$k" "$target"; _pause; return 0 ;;
  esac
  settings_validate "$k" "$v" || { _pause; return 0; }
  old=${CFG[$k]}; CFG[$k]=$v
  if [ "$target" = ovr ]; then
    OVR[$k]=$v; log "本次使用：$(cfg_label "$k")"
  else
    settings_save; ev "CONFIG $k: ${old} -> ${v}"; log "已保存：$(cfg_label "$k")"
    case "$k" in WATCH|AUTOSTART) apply_service_prefs ;; esac
  fi
  _settings_restart_note "$k" "$target"
  _pause
}
_settings_restart_note() {
  [ "$2" = cfg ] || return 0
  case "$SET_NEEDS_RESTART" in *" $1 "*) svc_active && log_warn "VPN 正在运行：这项要重启后才生效（菜单 2 或 ocm restart）。";; esac
  return 0
}

settings_menu() {
  local target="${1:-cfg}" n i k g lastg mark
  while true; do
    clear 2>/dev/null || true
    if [ "$target" = ovr ]; then title "⏳ 只改本次（不保存，仅对这次启动生效）"; else title "🔧 设置   ${C_GREY}${SETTINGS_FILE}${C_RESET}"; fi
    sep
    i=0; lastg=""
    for k in "${SET_KEYS[@]}"; do
      i=$((i+1)); g=${SET_GROUP[$k]}
      [ "$g" != "$lastg" ] && { echo -e "  ${C_GREY}── ${g} ──${C_RESET}"; lastg=$g; }
      mark=""; [ "$target" = ovr ] && [ -n "${OVR[$k]+x}" ] && mark=" ${C_YELLOW}(本次)${C_RESET}"
      echo -e "  $(printf '%2d' $i)) ${SET_TITLE[$k]}：${C_CYAN}$(cfg_label "$k")${C_RESET}${mark}"
    done
    sep
    echo "  选编号查看说明并修改；0 返回"
    read -rp "选择: " n || return 0
    case "$n" in
      0|"") return 0 ;;
      *) [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#SET_KEYS[@]} ] || continue
         settings_edit_item "${SET_KEYS[$((n-1))]}" "$target" || true ;;
    esac
  done
}

# ============================================================================
#  定时任务（v8：断线自动重连已由 systemd supervisor 负责，这里只管定时启停）
# ============================================================================
manage_cron() {
  local c exp act cron_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  if ! command -v crontab &>/dev/null; then
    clear 2>/dev/null || true; title "📅 定时任务"; sep
    log_err "系统未安装 cron/crontab，定时任务不可用。可先执行： apt-get install -y cron"; sep; _pause "按任意键返回主菜单..."; return 0
  fi
  while true; do
    clear 2>/dev/null || true; title "📅 定时任务"; sep
    crontab -l 2>/dev/null | grep -F "$SCRIPT_PATH" || log_info "  当前无此脚本的定时任务。"
    crontab -l 2>/dev/null | grep -q "_internal_check_health" && log_warn "  有旧版守护任务（_internal_check_health）：v8 已由 systemd 自动重连取代，建议选 3 清除。"
    sep
    echo "  1) 添加定时启动（按保存的设置 ocm start）"
    echo "  2) 添加定时关闭（ocm stop）"
    echo "  3) 清除所有此脚本相关的定时任务（含旧版守护任务）"
    echo "  4) 返回主菜单"
    read -rp "请选择 [1-4]: " c || return 0
    case "$c" in
      1|2) act=start; [ "$c" = 2 ] && act=stop
           read -rp "cron 表达式（分 时 日 月 周，例如 '0 8 * * 1-5' = 工作日 8 点）: " exp || continue
           [ "$(wc -w <<<"$exp")" -eq 5 ] || { log_err "需要 5 个字段"; _pause; continue; }
           _backup_crontab
           { crontab -l 2>/dev/null || true; echo "$exp PATH=$cron_path $SCRIPT_PATH $act >/dev/null 2>&1"; } | crontab -
           log "已添加：$exp → ocm $act"; _pause ;;
      3) _backup_crontab
         { crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH" || true; } | crontab - 2>/dev/null || true
         log "已清除。"; _pause ;;
      4) return 0 ;;
      *) log_err "无效选项"; sleep 1 ;;
    esac
  done
}

# ============================================================================
#  主菜单状态区（只读本地状态，不发网络请求，保证菜单秒开）
# ============================================================================
show_status() {
  sep
  local ph; ph=$(get_phase)
  if svc_active; then
    case "$ph" in
      up)           title "  VPN 状态: ${C_GREEN}🟢 运行中${C_RESET}  ${C_GREY}(systemd 托管)${C_RESET}" ;;
      reconnecting) title "  VPN 状态: ${C_YELLOW}🟡 重连中${C_RESET}" ;;
      *)            title "  VPN 状态: ${C_YELLOW}🟡 ${ph:-启动中}${C_RESET}" ;;
    esac
    if [ -f "$STATE_FILE" ]; then
      local MODE="" ACCOUNT_INDEX="" VPN_PROTOCOL="" SOCKS_PORT="" LISTEN_ADDR="" FORWARDER="" SOCKS_USER="" SOCKS_PASS="" KILL_SWITCH=""
      # shellcheck disable=SC1090
      . "$STATE_FILE" 2>/dev/null || true
      echo -e "    ${C_BOLD}账户:${C_RESET} $(account_field $(( ${ACCOUNT_INDEX:-0} + 1 )) 1 2>/dev/null || echo '?')   ${C_BOLD}模式:${C_RESET} ${MODE:-?}   ${C_BOLD}协议:${C_RESET} ${VPN_PROTOCOL:-?}"
      [ -n "$SOCKS_PORT" ] && echo -e "    ${C_BOLD}SOCKS5:${C_RESET} ${LISTEN_ADDR:-127.0.0.1}:${SOCKS_PORT}${SOCKS_USER:+ （认证 ${SOCKS_USER}:****）}${FORWARDER:+ ${C_GREY}by ${FORWARDER}${C_RESET}}"
    fi
    if is_vpn_running; then
      local _ag _sr; _ag=$(ps -o etimes= -p "$(cat "$PID_FILE")" 2>/dev/null | tr -d ' ') || true; _sr=$(_dur_to_s "${CFG[SESSION_RESTART]:-off}" 2>/dev/null || echo 0)
      echo -e "    ${C_BOLD}本次会话:${C_RESET} 已连接 $(fmt_dur "$_ag")$( [[ "$_ag" =~ ^[0-9]+$ ]] && [ "${_sr:-0}" -gt 0 ] && [ "$_ag" -lt "$_sr" ] && echo "   ${C_GREY}定时重连还剩 $(fmt_dur $((_sr - _ag)))${C_RESET}")"
    fi
    if [ -r "$FB_STATE_FILE" ]; then
      local fs fa fn; read -r fs fa fn < "$FB_STATE_FILE"
      echo -e "    ${C_YELLOW}回落代理:${C_RESET} 使用中「${fn}」${fa}（VPN 恢复后自动切回）"
    fi
    if [ -r "$WATCH_LIB/current" ]; then
      local st ws eg; read -r st ws _ < "$WATCH_LIB/current"
      eg=$(grep -o ' eg=[0-9.]*' "$SAMPLES" 2>/dev/null | tail -n1 | cut -d= -f2 || true)
      echo -e "    ${C_BOLD}诊断:${C_RESET} ${st}（$(fmt_dur $(( $(now_s) - ws )))）${eg:+   最近出口 ${eg}}"
    fi
  else
    case "$ph" in
      failed:*) title "  VPN 状态: ${C_RED}🔴 已停止（${ph#failed:}）${C_RESET}  ${C_GREY}详情：菜单 4${C_RESET}" ;;
      *)        title "  VPN 状态: ${C_RED}🔴 停止${C_RESET}" ;;
    esac
    if is_vpn_running; then
      echo -e "    ${C_YELLOW}检测到不受 systemd 托管的 openconnect（旧版启动？）。选 3 停止后再用 1 启动。${C_RESET}"
    fi
    echo -e "    ${C_BOLD}将使用:${C_RESET} $(cfg_label ACCOUNT)  /  ${CFG[MODE]}  /  $(account_field "${CFG[ACCOUNT]}" 6 2>/dev/null || true)${CFG[PROTOCOL]}  /  $(cfg_label DATA_CHANNEL)"
  fi
  echo -e "    ${C_BOLD}快捷命令:${C_RESET} $(_shortcut_state)   ${C_GREY}ocm -h 查看命令行用法${C_RESET}"
  sep
}

status_menu() {
  local c
  while true; do
    clear 2>/dev/null || true; cmd_status -v || true; sep
    echo "  1) 诊断报告（最近 1 天）   2) 最近 7 天   3) 最近 30 天"
    echo "  4) 最近 60 行 openconnect 输出   5) 立即保存一份现场快照   0) 返回"
    read -rp "选择: " c || return 0
    case "$c" in
      1) cmd_report 1 | less -R -F -X || true ;;
      2) cmd_report 7 | less -R -F -X || true ;;
      3) cmd_report 30 | less -R -F -X || true ;;
      4) tail -n 60 "$OCLOG" 2>/dev/null || echo "（暂无）"; _pause ;;
      5) cmd_log snapshot menu || true; _pause ;;
      *) return 0 ;;
    esac
  done
}

main_menu() {
  local c
  clear 2>/dev/null || true
  echo -e "${C_BOLD}========================================================${C_RESET}"
  echo -e "${C_BOLD}  🚀 OpenConnect Master Manager v${VERSION} 🚀${C_RESET}"
  echo -e "${C_BOLD}========================================================${C_RESET}"
  settings_load
  show_status || true
  title "主菜单:"
  echo -e "  ${C_GREEN}1) 🚀 启动 VPN（按当前设置，启动前确认）${C_RESET}"
  echo -e "  ${C_GREEN}2) 🔁 重启 VPN（应用新设置）${C_RESET}"
  echo -e "  ${C_RED}3) 🛑 停止 VPN${C_RESET}"
  echo -e "  4) 📊 状态详情与诊断报告"
  sep
  echo -e "  5) 🔧 设置（模式 / 协议 / 数据通道 / 代理 / 重连 / 日志…）"
  echo -e "  6) 🔐 管理 VPN 账户"
  echo -e "  7) 📅 定时启动 / 关闭"
  echo -e "  8) 📦 检查/安装依赖"
  echo -e "  9) 🧪 ${C_CYAN}测试 Netns IPv6 连通性${C_RESET}"
  echo -e " 10) 🧹 卸载"
  echo -e " 11) 🔀 管理回落代理（断线保护的备用出口）"
  echo -e "  0) 🚪 退出"
  echo
  read -rp "请选择 [0-11]: " c || { echo; log_info "标准输入已结束，退出。"; exit 0; }
  case "$c" in
    1) OVR=(); cmd_start 1 || true ;;
    2) if svc_active; then OVR=(); cmd_stop || true; sleep 2; fi; cmd_start 1 || true ;;
    3) cmd_stop || true ;;
    4) status_menu ;;
    5) settings_menu ;;
    6) manage_accounts ;;
    7) manage_cron ;;
    8) manage_deps || true ;;
    9) if [ -f "$STATE_FILE" ] && grep -q "MODE=netns" "$STATE_FILE"; then test_netns_ipv6 || true; else log_err "Netns 模式未运行，无法测试"; fi ;;
    10) uninstall; exit 0 ;;
    11) manage_proxies ;;
    0) exit 0 ;;
    *) log_err "无效选项 '$c'" ;;
  esac
  [[ "$c" =~ ^([1-3]|8|9)$ ]] && _pause "按任意键返回主菜单..."
  return 0
}

# ============================================================================
#  命令行
# ============================================================================
usage() { cat <<EOF
OpenConnect Master Manager v${VERSION}

用法：ocm [命令] [选项]
  （不带参数）             打开交互菜单
  start [选项]             按保存的设置启动（交给 systemd 托管）；选项只影响本次
      -a, --account N|名称     使用第 N 个 / 指定名称的账户
      -m, --mode MODE          netns | default | ocproxy
      -p, --proto PROTO        anyconnect | pulse | nc | gp | fortinet | array
      -P, --port N             SOCKS5 端口
          --listen ADDR        127.0.0.1 | 0.0.0.0
          --tls-only | --dtls  数据通道：仅 TLS（--no-dtls）/ ESP·DTLS
          --fwd socat|iptables 端口转发方式
          --kill-switch on|off|proxy  断线保护（proxy = 掉线期间改走回落代理）
          --fallback 名称|auto 回落代理选择（配合 --kill-switch proxy）
          --dns fast|system    DNS 超时策略
          --mtu N|auto         隧道 MTU
          --oc-args "..."      附加给 openconnect 的参数
          --save               把本次选项保存为默认
      -i, --interactive        启动前显示摘要并确认（菜单启动即此行为）
  stop                     停止 VPN（openconnect 正常登出后清理）
  restart [选项]           停止后按（新）设置启动
  status [-v]              运行状态、诊断判定、最近事件
  log report [天数]        断线统计 / 会话时间轴 / 自动重连记录（默认 7 天）
  log tail                 实时跟踪事件与 openconnect 输出
  log snapshot [标签]      立即保存一份现场快照
  log mark <文字>          在事件日志里打标记
  heal on|off|status       自动重连开关
  config list [-v]         列出全部设置（-v 附说明）
  config get KEY           读取一项
  config set KEY VALUE     修改一项（SOCKS5 认证用 SOCKS_USER / SOCKS_PASS）
  accounts                 列出账户（不显示密码）
  proxy list               列出回落代理（不显示密码）
  proxy add ['一行']       添加回落代理：不带参数逐项提问；带参数按文件格式（竖线或 URL 写法）
  proxy del 序号|名称      删除回落代理
  proxy test [序号|名称]   从本机经代理访问一次，显示出口 IP（不带参数测全部）
  proxy format             回落代理文件的格式说明
  install-service          安装/刷新 systemd 单元（启动时会自动做）
  uninstall-service        移除 systemd 单元（不删设置与日志）
  -V, --version            版本
  -h, --help               本帮助

文件：设置 ${SETTINGS_FILE}   账户 ${ACCOUNTS_FILE}   回落代理 ${PROXIES_FILE}   日志 ${LOG_DIR}
退出码：0 成功  1 失败  2 用法错误  3 已在运行 / 状态冲突
示例：
  ocm start -m netns -p nc -P 8585 --tls-only --save
  ocm log report 7
  ocm config set DEGRADED_WAIT 60
  ocm config set SESSION_RESTART 110m     # 会话满 110 分钟主动重连（赶在 2 小时上限之前）
  ocm proxy add '香港备用|socks5|203.0.113.20|1080|user|pass' && ocm config set KILL_SWITCH proxy
EOF
}

INTERACTIVE=0
_ovr() { settings_validate "$1" "$2" || exit 2; OVR[$1]=$2; }
parse_start_opts() {
  local idx
  while [ $# -gt 0 ]; do
    case "$1" in
      -a|--account) [ $# -ge 2 ] || { log_err "$1 需要参数"; exit 2; }
                    idx=$(account_resolve "$2") || { log_err "找不到账户：$2"; exit 2; }; OVR[ACCOUNT]=$idx; shift 2 ;;
      -m|--mode) [ $# -ge 2 ] || exit 2; _ovr MODE "$2"; shift 2 ;;
      -p|--proto|--protocol) [ $# -ge 2 ] || exit 2; _ovr PROTOCOL "$2"; shift 2 ;;
      -P|--port) [ $# -ge 2 ] || exit 2; _ovr SOCKS_PORT "$2"; shift 2 ;;
      --listen) [ $# -ge 2 ] || exit 2; _ovr LISTEN "$2"; shift 2 ;;
      --tls-only|--no-dtls) OVR[DATA_CHANNEL]=tls; shift ;;
      --dtls) OVR[DATA_CHANNEL]=dtls; shift ;;
      --fwd|--forwarder) [ $# -ge 2 ] || exit 2; _ovr FORWARDER "$2"; shift 2 ;;
      --kill-switch) [ $# -ge 2 ] || exit 2; _ovr KILL_SWITCH "$2"; shift 2 ;;
      --fallback) [ $# -ge 2 ] || exit 2; _ovr FALLBACK_PROXY "$2"; shift 2 ;;
      --dns) [ $# -ge 2 ] || exit 2
             case "$2" in fast|on) OVR[DNS_FAST]=on ;; system|off) OVR[DNS_FAST]=off ;; *) log_err "--dns 只能是 fast|system"; exit 2;; esac; shift 2 ;;
      --mtu) [ $# -ge 2 ] || exit 2; _ovr MTU "$2"; shift 2 ;;
      --oc-args) [ $# -ge 2 ] || exit 2; _ovr OC_EXTRA "$2"; shift 2 ;;
      --save) OPT_SAVE=1; shift ;;
      -i|--interactive) INTERACTIVE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) log_err "未知选项：$1"; echo "用 ocm -h 查看用法" >&2; exit 2 ;;
    esac
  done
}

cmd_heal() {
  check_root; settings_load
  case "${1:-status}" in
    on|off) CFG[AUTO_RECONNECT]=$1; settings_save; ev "CONFIG AUTO_RECONNECT -> $1"
            log "自动重连：$(cfg_label AUTO_RECONNECT)（运行中的 supervisor 下一次掉线时即按新值处理）"
            [ "$1" = on ] && ! svc_active && [[ "$(get_phase)" == failed:* ]] && log_info "上次因 $(get_phase) 停止，确认原因后用 ocm start 重新启动。" ;;
    status) echo "自动重连：$(cfg_label AUTO_RECONNECT)   VPN 服务：$(systemctl is-active "$SVC_MAIN" 2>/dev/null || true)   阶段：$(get_phase)"
            grep -aE ' SUP (exit|paused|rate-limited|retry) | WATCH restart-request ' "$EVENTS" 2>/dev/null | tail -n 10 | cut -c1-200 | sed 's/^/  /' || true ;;
    *) log_err "用法：ocm heal on|off|status"; return 2 ;;
  esac
}

cmd_config() {
  check_root; settings_load
  local sub="${1:-list}" k
  case "$sub" in
    list)
      for k in "${SET_KEYS[@]}"; do
        [ "$k" = SOCKS_AUTH ] && { printf '%-18s = %s\n' "SOCKS_USER" "${CFG[SOCKS_USER]}"; printf '%-18s = %s\n' "SOCKS_PASS" "$( [ -n "${CFG[SOCKS_PASS]}" ] && echo '****')"; continue; }
        printf '%-18s = %-24s # %s：%s\n' "$k" "${CFG[$k]}" "${SET_TITLE[$k]}" "$(cfg_label "$k")"
        [ "${2:-}" = -v ] && _set_help "$k" | sed 's/^/      /'
      done; return 0 ;;
    get) [ -n "${2:-}" ] && _is_cfg_key "$2" || { log_err "未知设置项：${2:-}"; return 2; }; printf '%s\n' "${CFG[$2]}" ;;
    set) [ $# -ge 3 ] || { log_err "用法：ocm config set KEY VALUE"; return 2; }
         _is_cfg_key "$2" || { log_err "未知设置项：$2（ocm config list 查看）"; return 2; }
         local v="$3"; [ "$2" = ACCOUNT ] && { v=$(account_resolve "$3") || { log_err "找不到账户：$3"; return 2; }; }
         settings_validate "$2" "$v" || return 2
         local old=${CFG[$2]}; CFG[$2]=$v; settings_save
         if [ "$2" = SOCKS_PASS ]; then ev "CONFIG SOCKS_PASS changed"; else ev "CONFIG $2: $old -> $v"; fi
         log "$2 = $( [ "$2" = SOCKS_PASS ] && echo '****' || cfg_label "$2")"
         case "$2" in WATCH|AUTOSTART) apply_service_prefs ;; esac
         case "$SET_NEEDS_RESTART" in *" $2 "*) svc_active && log_warn "VPN 正在运行：重启后生效（ocm restart）。";; esac
         [[ "$2" =~ ^SOCKS_(USER|PASS)$ ]] && svc_active && log_warn "VPN 正在运行：重启后生效（ocm restart）。"
         return 0 ;;
    *) log_err "用法：ocm config list [-v] | get KEY | set KEY VALUE"; return 2 ;;
  esac
}

# --- 脚本入口 ---
main_entry() {
  case "${1:-}" in
    "")            check_root; _ensure_shortcut; while true; do main_menu; done ;;
    -h|--help|help) usage ;;
    -V|--version|version) echo "OpenConnect Master Manager v${VERSION}" ;;
    start)         shift; parse_start_opts "$@"; cmd_start "$INTERACTIVE" ;;
    restart)       shift; parse_start_opts "$@"; check_root; cmd_stop; sleep 2; cmd_start "$INTERACTIVE" ;;
    stop)          cmd_stop ;;
    status)        shift; cmd_status "${1:-}" ;;
    log|logs)      shift; cmd_log "$@" ;;
    heal)          shift; cmd_heal "$@" ;;
    config)        shift; cmd_config "$@" ;;
    accounts)      check_root; accounts_list ;;
    proxy|proxies) shift; cmd_proxy "$@" ;;
    install-service)   check_root; settings_load; install_units && log "systemd 单元已就绪：$SVC_MAIN / $SVC_WATCH" ;;
    uninstall-service) check_root; uninstall_units; log "已移除 systemd 单元（设置与日志保留）" ;;
    _supervise)    _supervise ;;
    _watch)        _watch ;;
    _internal_*)   echo "[$VR_TAG] 旧版 cron 守护已由 systemd 自动重连取代；请在菜单 7 清除该定时任务。" >&2; exit 0 ;;
    *)             log_err "未知命令：$1"; echo "用 ocm -h 查看用法" >&2; exit 2 ;;
  esac
}
main_entry "$@"
