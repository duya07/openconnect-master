#!/usr/bin/env bash
# OpenConnect Master Manager v8.0.0
# 面向 Linux VPS：优先使用本地 SOCKS 出口，按需启用带回滚保护的整机全局模式。

set -Eeuo pipefail
umask 077

readonly VERSION="8.0.0"
readonly TAG="oc-master"
readonly DISPLAY_TAG="OC-Master-v${VERSION}"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
readonly INSTALL_PATH="${OCM_INSTALL_PATH:-/usr/local/sbin/oc-master}"
readonly SHORTCUT_PATH="${OCM_SHORTCUT_PATH:-/usr/local/bin/ocm}"
readonly CONFIG_DIR="${OCM_CONFIG_DIR:-/etc/oc-master}"
readonly PROFILE_FILE="${OCM_PROFILE_FILE:-${CONFIG_DIR}/profile.conf}"
readonly ACCOUNTS_FILE="${OCM_ACCOUNTS_FILE:-/root/.vpn_accounts.env}"
readonly RUNTIME_DIR="${OCM_RUNTIME_DIR:-/run/oc-master}"
readonly LOCK_FILE="${OCM_LOCK_FILE:-/run/lock/oc-master.lock}"
readonly DDNS_SCAN_ROOT="${OCM_DDNS_SCAN_ROOT:-/}"
readonly HEALTH_FAILURE_FILE="${RUNTIME_DIR}/health.failures"
readonly HEALTH_RESTART_FILE="${RUNTIME_DIR}/health.last_restart"
readonly ROUTE_OWNER_FILE="${OCM_ROUTE_OWNER_FILE:-${CONFIG_DIR}/owns-return-routing}"
readonly SERVICE_NAME="${OCM_SERVICE_NAME:-oc-master.service}"
readonly HEALTH_SERVICE_NAME="${OCM_HEALTH_SERVICE_NAME:-oc-master-health.service}"
readonly HEALTH_TIMER_NAME="${OCM_HEALTH_TIMER_NAME:-oc-master-health.timer}"
readonly ROLLBACK_UNIT="${OCM_ROLLBACK_UNIT:-oc-master-rollback}"
readonly VPN_INTERFACE="ocm0"
readonly RETURN4_TABLE="51888"
readonly RETURN6_TABLE="51889"
readonly RETURN4_PRIORITY="10000"
readonly RETURN6_PRIORITY="10001"

if [ -t 1 ]; then
  C_RESET='\033[0m'; C_BOLD='\033[1m'
  C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_CYAN='\033[36m'; C_GREY='\033[90m'
else
  C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_GREY=''
fi

log()      { printf '%b%s%b\n' "${C_GREEN}✅ [$DISPLAY_TAG] " "$*" "$C_RESET"; }
log_info() { printf '%b%s%b\n' "${C_CYAN}ℹ️  [$DISPLAY_TAG] " "$*" "$C_RESET"; }
log_warn() { printf '%b%s%b\n' "${C_YELLOW}⚠️  [$DISPLAY_TAG] " "$*" "$C_RESET" >&2; }
log_err()  { printf '%b%s%b\n' "${C_RED}❌ [$DISPLAY_TAG] " "$*" "$C_RESET" >&2; }
die()      { log_err "$*"; return 1; }
system_log() { logger -t "$TAG" "$*" 2>/dev/null || true; }
check_root() { [ "${EUID}" -eq 0 ] || { log_err "请使用 root 运行。"; exit 1; }; }
title() { printf '%b%s%b\n' "$C_BOLD" "$*" "$C_RESET"; }
sep() { printf '%b%s%b\n' "$C_GREY" '--------------------------------------------------------' "$C_RESET"; }
clear_screen() {
  [ -t 1 ] || return 0
  command -v clear >/dev/null 2>&1 && clear 2>/dev/null || true
}
pause_menu() {
  [ -t 0 ] || return 0
  printf '\n'
  read -r -n 1 -s -p "按任意键返回主菜单..." _ || true
  printf '\n'
}

ensure_dirs() {
  install -d -o 0 -g 0 -m 0700 "$CONFIG_DIR" "$RUNTIME_DIR"
}

acquire_manager_lock() {
  command -v flock >/dev/null 2>&1 || { die "缺少 flock（util-linux），无法安全串行化网络变更。"; return 1; }
  install -d -m 0755 "$(dirname "$LOCK_FILE")"
  exec {MANAGER_LOCK_FD}>"$LOCK_FILE"
  flock -n "$MANAGER_LOCK_FD" || { die "另一个 oc-master 管理操作正在进行，请稍后重试。"; return 1; }
}

is_systemd_host() {
  command -v systemctl >/dev/null 2>&1 && [ "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" = "systemd" ]
}

package_install() {
  local mode="$1"
  local -a packages=(openconnect curl procps util-linux)
  if command -v apt-get >/dev/null 2>&1; then
    packages+=(iproute2)
    [ "$mode" != "proxy" ] || packages+=(ocproxy)
    DEBIAN_FRONTEND=noninteractive apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    packages+=(iproute)
    [ "$mode" != "proxy" ] || packages+=(ocproxy)
    dnf install -y "${packages[@]}"
  elif command -v yum >/dev/null 2>&1; then
    packages+=(iproute)
    [ "$mode" != "proxy" ] || packages+=(ocproxy)
    yum install -y "${packages[@]}"
  else
    die "无法识别包管理器，请手动安装：openconnect、ocproxy、curl、iproute2。"
  fi
}

ensure_dependencies() {
  local mode="$1" missing=() cmd
  for cmd in openconnect curl ip ss pgrep logger flock; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  [ "$mode" != "proxy" ] || command -v ocproxy >/dev/null 2>&1 || missing+=("ocproxy")
  is_systemd_host || { die "v8 需要以 systemd 作为连接监督器；当前系统未运行 systemd。"; return 1; }
  if [ "$mode" = "global" ] && ! command -v systemd-run >/dev/null 2>&1; then
    die "全局模式需要 systemd-run 创建独立回滚任务；当前系统缺少该命令。"
    return 1
  fi
  [ "${#missing[@]}" -eq 0 ] && return 0

  log_warn "缺少依赖：${missing[*]}"
  local answer=""
  read -r -p "是否现在用系统包管理器安装上述依赖？[y/N]: " answer
  [[ "$answer" =~ ^[yY]$ ]] || return 1
  package_install "$mode" || return 1

  for cmd in openconnect curl ip ss pgrep logger flock; do
    command -v "$cmd" >/dev/null 2>&1 || { die "依赖安装后仍找不到：$cmd"; return 1; }
  done
  [ "$mode" != "proxy" ] || command -v ocproxy >/dev/null 2>&1 || { die "依赖安装后仍找不到：ocproxy"; return 1; }
}

check_all_dependencies() {
  ensure_dependencies proxy || return 1
  command -v systemd-run >/dev/null 2>&1 \
    || { die "缺少 systemd-run；整机全局模式无法创建独立安全回滚。"; return 1; }
  log "全部运行依赖检查通过。"
}

ensure_accounts_file() {
  ensure_dirs
  if [ ! -e "$ACCOUNTS_FILE" ]; then
    printf '%s\n' '# 显示名|用户名|密码|VPN主机|认证组(可空)|协议(anyconnect/nc/pulse)' > "$ACCOUNTS_FILE"
  fi
  chown 0:0 "$ACCOUNTS_FILE"
  chmod 600 "$ACCOUNTS_FILE"
}

read_accounts() {
  ensure_accounts_file
  mapfile -t ACCOUNTS < <(grep -vE '^[[:space:]]*(#|$)' "$ACCOUNTS_FILE" || true)
}

valid_protocol() {
  case "$1" in anyconnect|nc|pulse) return 0 ;; *) return 1 ;; esac
}

choose_protocol() {
  local default_protocol="${1:-}" choice=""
  if valid_protocol "$default_protocol"; then
    log_info "账户已绑定协议：$default_protocol"
    VPN_PROTOCOL="$default_protocol"
    return 0
  fi

  printf '%s\n' "  1) anyconnect  - Cisco AnyConnect" \
                "  2) nc          - Juniper Network Connect" \
                "  3) pulse       - Pulse / Ivanti"
  read -r -p "请选择协议 [1-3，不允许盲选默认值]: " choice
  case "$choice" in
    1) VPN_PROTOCOL="anyconnect" ;;
    2) VPN_PROTOCOL="nc" ;;
    3) VPN_PROTOCOL="pulse" ;;
    *) die "无效协议。请按 VPN 网关实际类型选择，错误协议可能在认证前失败。" ;;
  esac
}

parse_account_line() {
  local line="$1" extra=""
  IFS='|' read -r VPN_DESC VPN_USER VPN_PASS VPN_HOST VPN_GROUP VPN_ACCOUNT_PROTOCOL extra <<< "$line"
  [ -z "$extra" ] || { die "账户字段过多；字段内容不能包含竖线字符 |。"; return 1; }
  [ -n "${VPN_DESC:-}" ] && [ -n "${VPN_USER:-}" ] && [ -n "${VPN_PASS:-}" ] && [ -n "${VPN_HOST:-}" ] \
    || { die "账户记录缺少显示名、用户名、密码或主机。"; return 1; }
  [[ "$VPN_HOST" != -* ]] || { die "VPN 主机不能以连字符开头，避免被 OpenConnect 解释为命令选项。"; return 1; }
  if [ -n "${VPN_ACCOUNT_PROTOCOL:-}" ] && ! valid_protocol "$VPN_ACCOUNT_PROTOCOL"; then
    die "账户 ${VPN_DESC} 的协议无效：${VPN_ACCOUNT_PROTOCOL}"
    return 1
  fi
}

load_account_by_index() {
  local index="$1"
  read_accounts
  [[ "$index" =~ ^[0-9]+$ ]] && [ "$index" -lt "${#ACCOUNTS[@]}" ] || { die "账户索引无效：$index"; return 1; }
  ACCOUNT_INDEX="$index"
  parse_account_line "${ACCOUNTS[$index]}" || return 1
}

select_account() {
  read_accounts
  [ "${#ACCOUNTS[@]}" -gt 0 ] || die "尚未配置 VPN 账户，请先进入账户管理。"
  log_info "请选择 VPN 账户："
  local i line desc user _password host group protocol extra choice=""
  for i in "${!ACCOUNTS[@]}"; do
    line="${ACCOUNTS[$i]}"
    IFS='|' read -r desc user _password host group protocol extra <<< "$line"
    printf '  %d) %s  [%s @ %s, protocol=%s]\n' "$((i + 1))" "$desc" "$user" "$host" "${protocol:-未设置}"
  done
  read -r -p "输入序号: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#ACCOUNTS[@]}" ] || die "无效账户序号。"
  load_account_by_index "$((choice - 1))"
  choose_protocol "${VPN_ACCOUNT_PROTOCOL:-}"
}

manage_accounts() {
  ensure_accounts_file
  while true; do
    clear_screen
    printf '\n%b⚙️  VPN 账户管理%b\n' "$C_BOLD" "$C_RESET"
    sep
    printf '  密码始终隐藏；账户文件权限为 0600。\n\n'
    read_accounts
    local i line desc user _password host group protocol extra
    if [ "${#ACCOUNTS[@]}" -eq 0 ]; then
      printf '  （空）\n'
    else
      for i in "${!ACCOUNTS[@]}"; do
        line="${ACCOUNTS[$i]}"
        IFS='|' read -r desc user _password host group protocol extra <<< "$line"
        printf '  %d) %s | %s | %s | group=%s | protocol=%s\n' \
          "$((i + 1))" "$desc" "$user" "$host" "${group:--}" "${protocol:-未设置}"
      done
    fi
    sep
    printf '%s\n' "  1) ➕ 添加账户" "  2) 🗑️  删除账户" "  0) ↩️  返回主菜单"
    local action=""
    read -r -p "请选择 [0-2]: " action
    case "$action" in
      1)
        local new_desc="" new_user="" new_pass="" new_host="" new_group=""
        read -r -p "显示名: " new_desc
        read -r -p "用户名: " new_user
        read -r -s -p "密码: " new_pass; printf '\n'
        read -r -p "VPN 主机/URL: " new_host
        read -r -p "认证组（可空）: " new_group
        [ -n "$new_desc" ] && [ -n "$new_user" ] && [ -n "$new_pass" ] && [ -n "$new_host" ] \
          || { log_err "必填字段不能为空。"; continue; }
        [[ "$new_desc$new_user$new_pass$new_host$new_group" != *'|'* ]] \
          || { log_err "字段内容不能包含竖线字符 |。"; continue; }
        choose_protocol "" || continue
        printf '%s|%s|%s|%s|%s|%s\n' "$new_desc" "$new_user" "$new_pass" "$new_host" "$new_group" "$VPN_PROTOCOL" >> "$ACCOUNTS_FILE"
        chmod 600 "$ACCOUNTS_FILE"
        log "已添加账户：$new_desc"
        ;;
      2)
        [ "${#ACCOUNTS[@]}" -gt 0 ] || { log_warn "没有可删除的账户。"; continue; }
        local delete_index="" tmp=""
        read -r -p "输入要删除的序号: " delete_index
        [[ "$delete_index" =~ ^[0-9]+$ ]] && [ "$delete_index" -ge 1 ] && [ "$delete_index" -le "${#ACCOUNTS[@]}" ] \
          || { log_err "无效序号。"; continue; }
        tmp="$(mktemp "${CONFIG_DIR}/accounts.XXXXXX")"
        awk -v target="$delete_index" '
          /^[[:space:]]*(#|$)/ { print; next }
          { n++; if (n != target) print }
        ' "$ACCOUNTS_FILE" > "$tmp"
        install -m 0600 "$tmp" "$ACCOUNTS_FILE"
        rm -f "$tmp"
        log "账户已删除。"
        ;;
      0) return 0 ;;
      *) log_err "无效选择。" ;;
    esac
  done
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

tcp_port_is_listening() {
  local port="$1" listeners
  listeners="$(ss -H -ltn 2>/dev/null || true)"
  awk -v port="$port" '$4 ~ (":" port "$") { found=1 } END { exit(found ? 0 : 1) }' <<< "$listeners"
}

port_is_free() {
  local port="$1"
  ! tcp_port_is_listening "$port"
}

profile_value() {
  local key="$1"
  [ -r "$PROFILE_FILE" ] || return 1
  sed -n "s/^${key}=//p" "$PROFILE_FILE" | tail -n 1
}

write_profile() {
  local mode="$1" account_index="$2" protocol="$3" socks_port="${4:-}" tmp
  [ "$mode" = "proxy" ] || [ "$mode" = "global" ] || { die "内部模式无效：$mode"; return 1; }
  [[ "$account_index" =~ ^[0-9]+$ ]] || { die "内部账户索引无效。"; return 1; }
  valid_protocol "$protocol" || { die "内部协议无效。"; return 1; }
  if [ "$mode" = "proxy" ]; then valid_port "$socks_port" || { die "内部 SOCKS 端口无效。"; return 1; }; fi

  ensure_dirs
  tmp="$(mktemp "${CONFIG_DIR}/profile.XXXXXX")"
  {
    printf 'MODE=%s\n' "$mode"
    printf 'ACCOUNT_INDEX=%s\n' "$account_index"
    printf 'VPN_PROTOCOL=%s\n' "$protocol"
    printf 'SOCKS_PORT=%s\n' "$socks_port"
  } > "$tmp"
  install -m 0600 "$tmp" "$PROFILE_FILE"
  rm -f "$tmp"
}

load_profile() {
  [ -r "$PROFILE_FILE" ] || { die "未找到活动配置：$PROFILE_FILE"; return 1; }
  PROFILE_MODE="$(profile_value MODE || true)"
  PROFILE_ACCOUNT_INDEX="$(profile_value ACCOUNT_INDEX || true)"
  PROFILE_PROTOCOL="$(profile_value VPN_PROTOCOL || true)"
  PROFILE_SOCKS_PORT="$(profile_value SOCKS_PORT || true)"
  [ "$PROFILE_MODE" = "proxy" ] || [ "$PROFILE_MODE" = "global" ] || { die "活动配置中的 MODE 无效。"; return 1; }
  [[ "$PROFILE_ACCOUNT_INDEX" =~ ^[0-9]+$ ]] || { die "活动配置中的账户索引无效。"; return 1; }
  valid_protocol "$PROFILE_PROTOCOL" || { die "活动配置中的协议无效。"; return 1; }
  if [ "$PROFILE_MODE" = "proxy" ]; then valid_port "$PROFILE_SOCKS_PORT" || { die "活动配置中的 SOCKS 端口无效。"; return 1; }; fi
  load_account_by_index "$PROFILE_ACCOUNT_INDEX" || return 1
}

shortcut_is_ours() {
  [ "$SHORTCUT_PATH" = "$INSTALL_PATH" ] && return 0
  [ -L "$SHORTCUT_PATH" ] && [ "$(readlink "$SHORTCUT_PATH" 2>/dev/null || true)" = "$INSTALL_PATH" ]
}

install_managed_copy() {
  if [ "$SHORTCUT_PATH" != "$INSTALL_PATH" ] && { [ -e "$SHORTCUT_PATH" ] || [ -L "$SHORTCUT_PATH" ]; } && ! shortcut_is_ours; then
    die "快捷命令路径已被其他文件占用：$SHORTCUT_PATH；为避免覆盖，拒绝安装。"
    return 1
  fi

  install -d -m 0755 "$(dirname "$INSTALL_PATH")" "$(dirname "$SHORTCUT_PATH")"
  if [ "$SCRIPT_PATH" != "$INSTALL_PATH" ] || ! cmp -s "$SCRIPT_PATH" "$INSTALL_PATH" 2>/dev/null; then
    install -m 0755 "$SCRIPT_PATH" "$INSTALL_PATH"
  fi
  if [ "$SHORTCUT_PATH" != "$INSTALL_PATH" ] && ! shortcut_is_ours; then
    ln -s -- "$INSTALL_PATH" "$SHORTCUT_PATH"
  fi
}

remove_managed_shortcut() {
  [ "$SHORTCUT_PATH" != "$INSTALL_PATH" ] || return 0
  if shortcut_is_ours; then
    rm -f -- "$SHORTCUT_PATH"
  elif [ -e "$SHORTCUT_PATH" ] || [ -L "$SHORTCUT_PATH" ]; then
    log_warn "保留非本项目拥有的快捷命令：$SHORTCUT_PATH"
  fi
}

install_command() {
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    die "连接运行期间拒绝替换受控脚本；请先执行 sudo ocm stop。"
    return 1
  fi
  install_managed_copy
  log "快捷命令已安装：sudo ocm"
}

install_self_and_units() {
  ensure_dirs
  install_managed_copy

  cat > "/etc/systemd/system/${SERVICE_NAME}" <<EOF
[Unit]
Description=OpenConnect Master managed tunnel
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
Type=simple
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${INSTALL_PATH} _service_run
ExecStopPost=-${INSTALL_PATH} _service_cleanup
Restart=always
RestartSec=15s
TimeoutStopSec=30s
KillMode=control-group
UMask=0077

[Install]
WantedBy=multi-user.target
EOF

  cat > "/etc/systemd/system/${HEALTH_SERVICE_NAME}" <<EOF
[Unit]
Description=OpenConnect Master data-plane health check
After=${SERVICE_NAME}

[Service]
Type=oneshot
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${INSTALL_PATH} _service_health
EOF

  cat > "/etc/systemd/system/${HEALTH_TIMER_NAME}" <<EOF
[Unit]
Description=Run OpenConnect Master health checks

[Timer]
OnBootSec=45s
OnUnitInactiveSec=30s
AccuracySec=5s
Unit=${HEALTH_SERVICE_NAME}

[Install]
WantedBy=timers.target
EOF

  chmod 0644 "/etc/systemd/system/${SERVICE_NAME}" "/etc/systemd/system/${HEALTH_SERVICE_NAME}" "/etc/systemd/system/${HEALTH_TIMER_NAME}"
  systemctl daemon-reload
}

ddns_automation_detected() {
  local scan_root="${DDNS_SCAN_ROOT%/}" candidate
  local -a candidates=(
    "${scan_root}/etc/crontab"
    "${scan_root}/etc/anacrontab"
    "${scan_root}/var/spool/cron/root"
    "${scan_root}/var/spool/cron/"*
    "${scan_root}/var/spool/cron/crontabs/root"
    "${scan_root}/var/spool/cron/crontabs/"*
    "${scan_root}/etc/cron.d/"*
    "${scan_root}/etc/cron.hourly/"*
    "${scan_root}/etc/cron.daily/"*
    "${scan_root}/etc/cron.weekly/"*
    "${scan_root}/etc/cron.monthly/"*
    "${scan_root}/etc/systemd/system/"*.service
    "${scan_root}/etc/systemd/system/"*.timer
  )
  for candidate in "${candidates[@]}"; do
    [ -f "$candidate" ] && [ -r "$candidate" ] || continue
    grep -Eiq '(ddns|ddclient|inadyn|duckdns|no-?ip|cloudflare-api-v4)' "$candidate" && return 0
  done
  if [ "$DDNS_SCAN_ROOT" = "/" ] && command -v systemctl >/dev/null 2>&1; then
    local loaded_units
    loaded_units="$(systemctl list-units --all --no-legend --plain 2>/dev/null || true)"
    grep -Eiq '(ddns|ddclient|inadyn|duckdns|no-?ip|cloudflare-api-v4)' <<< "$loaded_units" && return 0
  fi
  return 1
}

confirm_global_risk() {
  local answer=""
  printf '%b\n' "${C_YELLOW}全局模式会改变默认出站路由；启动后请另开一个 SSH/外部代理连接进行验证。${C_RESET}"
  log_warn "常规 DDNS 会把 VPN 出口误当成 VPS 公网地址；本脚本不会暂停或修改第三方 DDNS。"
  if ddns_automation_detected; then
    log_warn "检测到可能的 DDNS cron/systemd 任务。请先停用它，或确认它已绑定原物理接口/源地址。"
    read -r -p "确认已处理 DDNS 风险后，输入 GLOBAL-DDNS-RISK 继续: " answer
    [ "$answer" = "GLOBAL-DDNS-RISK" ] || { log_info "已取消。"; return 1; }
  else
    read -r -p "输入 GLOBAL 继续: " answer
    [ "$answer" = "GLOBAL" ] || { log_info "已取消。"; return 1; }
  fi
}

route_state_conflicts() {
  local rules4 rules6 routes4 routes6
  rules4="$(ip -4 rule show 2>/dev/null || true)"
  rules6="$(ip -6 rule show 2>/dev/null || true)"
  routes4="$(ip -4 route show table "$RETURN4_TABLE" 2>/dev/null || true)"
  routes6="$(ip -6 route show table "$RETURN6_TABLE" 2>/dev/null || true)"
  grep -Eq "^[[:space:]]*${RETURN4_PRIORITY}:" <<< "$rules4" && return 0
  grep -Eq "^[[:space:]]*${RETURN6_PRIORITY}:" <<< "$rules6" && return 0
  grep -Eq "lookup ${RETURN4_TABLE}([[:space:]]|$)" <<< "$rules4" && return 0
  grep -Eq "lookup ${RETURN6_TABLE}([[:space:]]|$)" <<< "$rules6" && return 0
  [ -n "$routes4" ] && return 0
  [ -n "$routes6" ] && return 0
  return 1
}

cleanup_return_routes() {
  [ -e "$ROUTE_OWNER_FILE" ] || return 0
  local _ saved_default4="" saved_default6="" current_default=""
  saved_default4="$(sed -n 's/^DEFAULT4=//p' "$ROUTE_OWNER_FILE" | tail -n 1)"
  saved_default6="$(sed -n 's/^DEFAULT6=//p' "$ROUTE_OWNER_FILE" | tail -n 1)"
  for _ in {1..32}; do
    ip -4 rule del priority "$RETURN4_PRIORITY" lookup "$RETURN4_TABLE" 2>/dev/null || break
  done
  for _ in {1..32}; do
    ip -6 rule del priority "$RETURN6_PRIORITY" lookup "$RETURN6_TABLE" 2>/dev/null || break
  done
  ip -4 route flush table "$RETURN4_TABLE" 2>/dev/null || true
  ip -6 route flush table "$RETURN6_TABLE" 2>/dev/null || true
  if ip link show dev "$VPN_INTERFACE" >/dev/null 2>&1; then
    ip link del dev "$VPN_INTERFACE" 2>/dev/null || true
  fi

  current_default="$(ip -4 route show default | awk -v vpn="$VPN_INTERFACE" '$0 !~ ("dev " vpn "([[:space:]]|$)") && !found { print; found=1 }')"
  if [ -z "$current_default" ] && [ -n "$saved_default4" ]; then
    local -a restore_args4
    read -r -a restore_args4 <<< "$saved_default4"
    ip -4 route replace "${restore_args4[@]}" 2>/dev/null || true
  fi
  current_default="$(ip -6 route show default | awk -v vpn="$VPN_INTERFACE" '$0 !~ ("dev " vpn "([[:space:]]|$)") && !found { print; found=1 }')"
  if [ -z "$current_default" ] && [ -n "$saved_default6" ]; then
    local -a restore_args6
    read -r -a restore_args6 <<< "$saved_default6"
    ip -6 route replace "${restore_args6[@]}" 2>/dev/null || true
  fi
  rm -f "$ROUTE_OWNER_FILE"
}

setup_return_routes() {
  if [ -e "$ROUTE_OWNER_FILE" ]; then
    cleanup_return_routes
  elif ip link show dev "$VPN_INTERFACE" >/dev/null 2>&1 || route_state_conflicts; then
    die "接口 ${VPN_INTERFACE}、策略表 ${RETURN4_TABLE}/${RETURN6_TABLE} 或规则优先级 ${RETURN4_PRIORITY}/${RETURN6_PRIORITY} 已被占用；为避免破坏现有网络，拒绝启动。"
    return 1
  fi

  local default4 default6="" dev4 dev6="" address cidr
  default4="$(ip -4 route show default | awk -v vpn="$VPN_INTERFACE" '$0 !~ ("dev " vpn "([[:space:]]|$)") && !found { print; found=1 }')"
  [ -n "$default4" ] || { die "找不到 VPN 之外的 IPv4 默认路由，无法建立安全回程表。"; return 1; }
  dev4="$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<< "$default4")"
  [ -n "$dev4" ] || { die "无法从默认路由识别出口接口。"; return 1; }
  mapfile -t RETURN4_ADDRESSES < <(ip -4 -o addr show dev "$dev4" scope global | awk '{print $4}')
  [ "${#RETURN4_ADDRESSES[@]}" -gt 0 ] || { die "接口 $dev4 没有全局 IPv4 地址。"; return 1; }

  default6="$(ip -6 route show default | awk -v vpn="$VPN_INTERFACE" '$0 !~ ("dev " vpn "([[:space:]]|$)") && !found { print; found=1 }')"

  {
    printf 'DEFAULT4=%s\n' "$default4"
    printf 'DEFAULT6=%s\n' "$default6"
  } > "$ROUTE_OWNER_FILE"
  chmod 600 "$ROUTE_OWNER_FILE"
  local -a route_args4
  read -r -a route_args4 <<< "$default4"
  ip -4 route replace table "$RETURN4_TABLE" "${route_args4[@]}"
  for cidr in "${RETURN4_ADDRESSES[@]}"; do
    address="${cidr%/*}"
    ip -4 rule add priority "$RETURN4_PRIORITY" from "${address}/32" lookup "$RETURN4_TABLE"
  done

  if [ -n "$default6" ]; then
    dev6="$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<< "$default6")"
    if [ -n "$dev6" ]; then
      mapfile -t RETURN6_ADDRESSES < <(ip -6 -o addr show dev "$dev6" scope global | awk '{print $4}')
      local -a route_args6
      read -r -a route_args6 <<< "$default6"
      ip -6 route replace table "$RETURN6_TABLE" "${route_args6[@]}"
      for cidr in "${RETURN6_ADDRESSES[@]}"; do
        address="${cidr%/*}"
        ip -6 rule add priority "$RETURN6_PRIORITY" from "${address}/128" lookup "$RETURN6_TABLE"
      done
    fi
  fi
}

service_main_pid() {
  systemctl show -p MainPID --value "$SERVICE_NAME" 2>/dev/null || printf '0\n'
}

openconnect_process_is_alive() {
  local pid
  pid="$(service_main_pid)"
  [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 0 ] && [ -r "/proc/${pid}/comm" ] && [ "$(cat "/proc/${pid}/comm")" = "openconnect" ]
}

openconnect_option_supported() {
  local option="$1" help_text
  help_text="$(openconnect --help 2>&1 || true)"
  grep -Fq -- "$option" <<< "$help_text"
}

http_data_probe() {
  local proxy="${1:-}" url curl_args=(-4 -fsS -o /dev/null --connect-timeout 4 --max-time 8)
  if [ -n "$proxy" ]; then curl_args+=(--proxy "$proxy"); else curl_args+=(--noproxy '*'); fi
  for url in \
    "https://cp.cloudflare.com/generate_204" \
    "https://www.gstatic.com/generate_204" \
    "https://api.ipify.org"; do
    curl "${curl_args[@]}" "$url" 2>/dev/null && return 0
  done
  return 1
}

health_once() {
  load_profile >/dev/null 2>&1 || return 1
  openconnect_process_is_alive || return 1
  case "$PROFILE_MODE" in
    proxy)
      tcp_port_is_listening "$PROFILE_SOCKS_PORT" || return 1
      http_data_probe "socks5h://127.0.0.1:${PROFILE_SOCKS_PORT}"
      ;;
    global)
      local global_route
      global_route="$(ip -4 route get 1.1.1.1 2>/dev/null || true)"
      grep -Eq "dev ${VPN_INTERFACE}([[:space:]]|$)" <<< "$global_route" || return 1
      http_data_probe ""
      ;;
  esac
}

wait_until_healthy() {
  local deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if health_once; then return 0; fi
    sleep 2
  done
  return 1
}

service_run() {
  check_root
  ensure_dirs
  load_profile
  if [ "$PROFILE_MODE" = "global" ]; then setup_return_routes; fi

  local -a command=(
    openconnect "$VPN_HOST"
    "--protocol=${PROFILE_PROTOCOL}"
    "--user=${VPN_USER}"
    --passwd-on-stdin
    --non-inter
    --timestamp
    --reconnect-timeout=86400
  )
  if openconnect_option_supported "--tcp-keepalive"; then
    command+=(--tcp-keepalive=30)
  fi
  [ -z "${VPN_GROUP:-}" ] || command+=("--authgroup=${VPN_GROUP}")
  case "$PROFILE_MODE" in
    proxy)
      command+=(--script-tun --script "ocproxy -k 30 -D ${PROFILE_SOCKS_PORT}")
      ;;
    global)
      command+=("--interface=${VPN_INTERFACE}")
      ;;
  esac

  log_info "启动 OpenConnect：mode=${PROFILE_MODE}, protocol=${PROFILE_PROTOCOL}, account=${VPN_DESC}"
  exec "${command[@]}" <<< "$VPN_PASS"
}

service_cleanup() {
  check_root
  cleanup_return_routes || true
  rm -f "$HEALTH_FAILURE_FILE"
}

service_health() {
  check_root
  ensure_dirs
  systemctl is-active --quiet "$SERVICE_NAME" || exit 0
  if health_once; then
    rm -f "$HEALTH_FAILURE_FILE"
    exit 0
  fi

  local failures=0 now last_restart=0
  [ ! -r "$HEALTH_FAILURE_FILE" ] || failures="$(cat "$HEALTH_FAILURE_FILE" 2>/dev/null || printf '0')"
  [[ "$failures" =~ ^[0-9]+$ ]] || failures=0
  failures=$((failures + 1))
  printf '%s\n' "$failures" > "$HEALTH_FAILURE_FILE"
  system_log "data-plane health check failed (${failures}/3)"
  [ "$failures" -ge 3 ] || exit 0

  now="$(date +%s)"
  [ ! -r "$HEALTH_RESTART_FILE" ] || last_restart="$(cat "$HEALTH_RESTART_FILE" 2>/dev/null || printf '0')"
  [[ "$last_restart" =~ ^[0-9]+$ ]] || last_restart=0
  if [ $((now - last_restart)) -lt 900 ]; then
    system_log "health restart suppressed by 15-minute authentication safety cooldown"
    exit 0
  fi

  printf '%s\n' "$now" > "$HEALTH_RESTART_FILE"
  rm -f "$HEALTH_FAILURE_FILE"
  system_log "restarting tunnel after three consecutive data-plane failures"
  systemctl restart "$SERVICE_NAME"
}

cancel_rollback() {
  systemctl stop "${ROLLBACK_UNIT}.timer" "${ROLLBACK_UNIT}.service" 2>/dev/null || true
  systemctl reset-failed "${ROLLBACK_UNIT}.service" 2>/dev/null || true
}

stop_and_disable_managed_units() {
  # stop 必须独立执行：即使单元未启用或不可 disable，也必须先终止隧道。
  local managed_pid stop_rc=0 state=""
  managed_pid="$(service_main_pid)"
  systemctl stop "$HEALTH_TIMER_NAME" "$SERVICE_NAME" >/dev/null 2>&1 || stop_rc=$?
  state="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
  case "$state" in
    active|activating|deactivating|reloading)
      die "systemd 未能停止 $SERVICE_NAME（当前状态：$state）；为避免破坏仍在运行的隧道，拒绝清理路由。"
      return 1
      ;;
  esac
  if [[ "$managed_pid" =~ ^[0-9]+$ ]] && [ "$managed_pid" -gt 0 ] && [ -r "/proc/${managed_pid}/comm" ] && [ "$(cat "/proc/${managed_pid}/comm")" = "openconnect" ]; then
    die "受管 OpenConnect 进程 $managed_pid 仍在运行；拒绝清理路由。"
    return 1
  fi
  if [ "$stop_rc" -ne 0 ] && [ -z "$state" ]; then
    die "无法确认 $SERVICE_NAME 已停止；拒绝清理路由。"
    return 1
  fi
  systemctl disable "$HEALTH_TIMER_NAME" "$SERVICE_NAME" >/dev/null 2>&1 || log_warn "服务已停止，但禁用开机自启失败；请检查 systemctl 状态。"
}

cleanup_start_attempt() {
  if ! stop_and_disable_managed_units; then
    log_err "无法确认隧道已经停止；为保护现有连接，保留受管状态和已武装的回滚任务。"
    return 1
  fi
  service_cleanup || { log_err "隧道已停止，但本项目网络状态未能完整清理。"; return 1; }
  cancel_rollback
}

clear_start_signal_traps() {
  trap - INT TERM HUP
}

handle_interrupted_start() {
  local signal_name="$1"
  clear_start_signal_traps
  log_warn "启动过程收到 ${signal_name}，正在停止受管隧道并清理本项目状态..."
  cleanup_start_attempt || true
  exit 130
}

start_managed_units() {
  systemctl reset-failed "$SERVICE_NAME" &&
    systemctl enable "$SERVICE_NAME" "$HEALTH_TIMER_NAME" >/dev/null &&
    systemctl start "$SERVICE_NAME" &&
    systemctl start "$HEALTH_TIMER_NAME"
}

arm_rollback() {
  cancel_rollback
  systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active=3m -- "$INSTALL_PATH" _rollback
  log_warn "已武装独立回滚：3 分钟内未确认，将停止并禁用全局 VPN。"
}

rollback_now() {
  check_root
  system_log "global-mode safety rollback triggered"
  stop_and_disable_managed_units
  service_cleanup
}

prepare_service_replacement() {
  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    local answer=""
    log_warn "已有 oc-master 连接正在运行，继续会先停止它。"
    read -r -p "确认替换？[y/N]: " answer
    [[ "$answer" =~ ^[yY]$ ]] || return 1
    systemctl stop "$SERVICE_NAME"
  fi

  local foreign_pids
  foreign_pids="$(pgrep -x openconnect 2>/dev/null || true)"
  [ -z "$foreign_pids" ] || die "检测到不属于 oc-master 的 OpenConnect 进程（PID: ${foreign_pids//$'\n'/,}），拒绝抢占。"
}

start_mode() {
  local mode="$1" socks_port="" answer=""
  ensure_dependencies "$mode"
  select_account
  if [ "$mode" = "proxy" ]; then
    read -r -p "本地 SOCKS5 端口 [1080]: " socks_port
    socks_port="${socks_port:-1080}"
    valid_port "$socks_port" || { die "端口无效。"; return 1; }
  else
    confirm_global_risk || return 0
  fi

  prepare_service_replacement
  [ "$mode" != "proxy" ] || port_is_free "$socks_port" || { die "端口 $socks_port 已被占用。"; return 1; }
  install_self_and_units
  write_profile "$mode" "$ACCOUNT_INDEX" "$VPN_PROTOCOL" "$socks_port"
  rm -f "$HEALTH_FAILURE_FILE" "$HEALTH_RESTART_FILE"

  trap 'handle_interrupted_start SIGINT' INT
  trap 'handle_interrupted_start SIGTERM' TERM
  trap 'handle_interrupted_start SIGHUP' HUP

  if [ "$mode" = "global" ] && ! arm_rollback; then
    log_err "无法创建独立安全回滚，拒绝启动整机全局 VPN。"
    cleanup_start_attempt || true
    clear_start_signal_traps
    return 1
  fi
  if ! start_managed_units; then
    log_err "systemd 启动链失败，正在立即停止、禁用并清理本项目状态。"
    cleanup_start_attempt || true
    clear_start_signal_traps
    return 1
  fi

  log_info "等待真实数据面可用（最长 60 秒）..."
  if ! wait_until_healthy; then
    log_err "连接没有通过数据面检查，正在停止并清理。"
    cleanup_start_attempt || true
    clear_start_signal_traps
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
    return 1
  fi

  if [ "$mode" = "proxy" ]; then
    clear_start_signal_traps
    log "SOCKS5 已可用：127.0.0.1:${socks_port}；宿主机默认路由未修改。"
    return 0
  fi

  log "全局 VPN 数据面已可用。"
  printf '%s\n' "请现在从外部新建一次 SSH 或其他入站连接，确认回程正常。"
  read -r -t 120 -p "确认无误后在 120 秒内输入 KEEP: " answer || answer=""
  printf '\n'
  if [ "$answer" = "KEEP" ]; then
    cancel_rollback
    clear_start_signal_traps
    log "已确认入站正常，取消独立回滚。"
  else
    log_warn "未收到 KEEP，立即执行安全回滚。"
    cleanup_start_attempt || true
    clear_start_signal_traps
    return 1
  fi
}

stop_vpn() {
  check_root
  stop_and_disable_managed_units
  service_cleanup
  cancel_rollback
  log "VPN 已停止，oc-master 的策略路由已清理。"
}

public_ip() {
  local proxy="${1:-}" args=(-4 -sS --connect-timeout 4 --max-time 8)
  if [ -n "$proxy" ]; then args+=(--proxy "$proxy"); else args+=(--noproxy '*'); fi
  local value=""
  value="$(curl "${args[@]}" https://api.ipify.org 2>/dev/null || true)"
  [ -n "$value" ] && printf '%s' "$value" || printf '查询失败'
}

public_ipv6() {
  local value=""
  value="$(curl -6 -sS --connect-timeout 2 --max-time 4 --noproxy '*' https://api64.ipify.org 2>/dev/null || true)"
  [ -n "$value" ] && printf '%s' "$value" || printf '无/查询失败'
}

show_status() {
  printf '\n%b%s%b\n' "$C_BOLD" '========================================================' "$C_RESET"
  printf '%b  🚀 OpenConnect Master Manager v%s 🚀%b\n' "$C_BOLD" "$VERSION" "$C_RESET"
  printf '%b%s%b\n' "$C_BOLD" '========================================================' "$C_RESET"
  sep
  if [ ! -r "$PROFILE_FILE" ]; then
    printf '  %bVPN 状态:%b %b🔴 停止%b\n' "$C_BOLD" "$C_RESET" "$C_RED" "$C_RESET"
    printf '    %b运行模式:%b 未配置\n' "$C_BOLD" "$C_RESET"
    printf '    %b自动守护:%b 未启用（首次启动后自动配置）\n' "$C_BOLD" "$C_RESET"
    printf '    %b本机公网 IPv4:%b %s\n' "$C_BOLD" "$C_RESET" "$(public_ip)"
    printf '    %b本机公网 IPv6:%b %s\n' "$C_BOLD" "$C_RESET" "$(public_ipv6)"
    sep
    return 0
  fi

  if ! load_profile; then return 1; fi
  local active="否" healthy="否" exit_ip="未检测" mode_name="未知" main_pid="-" guard="未启用"
  local host_ipv4 host_ipv6 status_color="$C_RED" status_icon="🔴" status_label="停止"
  systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && active="是"
  systemctl is-active --quiet "$HEALTH_TIMER_NAME" 2>/dev/null && guard="已启用"
  if [ "$active" = "是" ] && health_once; then healthy="是"; fi
  host_ipv4="$(public_ip)"
  host_ipv6="$(public_ipv6)"
  if [ "$PROFILE_MODE" = "proxy" ]; then
    mode_name="🔌 本地 SOCKS5 模式（宿主机路由不变）"
    [ "$healthy" != "是" ] || exit_ip="$(public_ip "socks5h://127.0.0.1:${PROFILE_SOCKS_PORT}")"
  else
    mode_name="🛡️  整机全局 VPN（入站回程保护）"
    [ "$healthy" != "是" ] || exit_ip="$host_ipv4"
  fi
  if [ "$active" = "是" ]; then
    status_color="$C_YELLOW"; status_icon="🟡"; status_label="运行中，数据面异常"
    if [ "$healthy" = "是" ]; then
      status_color="$C_GREEN"; status_icon="🟢"; status_label="运行中"
    fi
  fi
  main_pid="$(service_main_pid)"
  [[ "$main_pid" =~ ^[0-9]+$ ]] && [ "$main_pid" -gt 0 ] || main_pid="-"

  printf '  %bVPN 状态:%b %b%s %s%b' "$C_BOLD" "$C_RESET" "$status_color" "$status_icon" "$status_label" "$C_RESET"
  [ "$main_pid" = "-" ] || printf ' (OpenConnect PID: %s)' "$main_pid"
  printf '\n'
  printf '    %b运行模式:%b %s\n' "$C_BOLD" "$C_RESET" "$mode_name"
  printf '    %b使用账户:%b %s\n' "$C_BOLD" "$C_RESET" "$VPN_DESC"
  printf '    %bVPN 协议:%b %s\n' "$C_BOLD" "$C_RESET" "$PROFILE_PROTOCOL"
  [ "$PROFILE_MODE" != "proxy" ] || printf '    %bSOCKS 地址:%b 127.0.0.1:%s\n' "$C_BOLD" "$C_RESET" "$PROFILE_SOCKS_PORT"
  printf '    %b数据面健康:%b %s\n' "$C_BOLD" "$C_RESET" "$healthy"
  printf '    %b自动守护:%b %s\n' "$C_BOLD" "$C_RESET" "$guard"
  printf '    %bVPN 出口 IPv4:%b %b%s%b\n' "$C_BOLD" "$C_RESET" "$C_YELLOW" "$exit_ip" "$C_RESET"
  printf '    %b本机公网 IPv4:%b %s\n' "$C_BOLD" "$C_RESET" "$host_ipv4"
  printf '    %b本机公网 IPv6:%b %s\n' "$C_BOLD" "$C_RESET" "$host_ipv6"
  sep
}

show_logs() {
  journalctl -u "$SERVICE_NAME" -u "$HEALTH_SERVICE_NAME" -n 100 --no-pager
}

check_data_plane() {
  if health_once; then
    log "数据面检查通过。"
    return 0
  fi
  log_err "数据面检查失败。"
  return 1
}

uninstall_manager() {
  local answer=""
  read -r -p "将停止 VPN，并删除 oc-master 的 systemd 单元、程序副本和活动配置；账户文件默认保留。输入 REMOVE 确认: " answer
  [ "$answer" = "REMOVE" ] || { log_info "已取消。"; return 0; }
  stop_vpn
  rm -f "/etc/systemd/system/${SERVICE_NAME}" "/etc/systemd/system/${HEALTH_SERVICE_NAME}" "/etc/systemd/system/${HEALTH_TIMER_NAME}"
  remove_managed_shortcut
  rm -f "$INSTALL_PATH" "$PROFILE_FILE" "$ROUTE_OWNER_FILE"
  rmdir "$CONFIG_DIR" 2>/dev/null || true
  systemctl daemon-reload
  log "管理器已卸载；未卸载软件包，账户文件仍保留在 $ACCOUNTS_FILE。"
}

main_menu() {
  while true; do
    clear_screen
    show_status || true
    title "主菜单:"
    printf '  %b1) 启动: 🔌 本地 SOCKS5 模式（推荐，不改宿主机路由）%b\n' "$C_GREEN" "$C_RESET"
    printf '  %b2) 启动: 🛡️  整机全局 VPN（保护入站，带安全回滚）%b\n' "$C_GREEN" "$C_RESET"
    printf '  %b3) ⏹️  停止 VPN%b\n' "$C_RED" "$C_RESET"
    sep
    printf '%s\n' \
      "  4) ⚙️  管理 VPN 账户" \
      "  5) 🧪 立即检查 VPN 数据面" \
      "  6) 📜 查看运行日志" \
      "  7) 📦 检查/安装依赖" \
      "  8) 🔗 安装/更新快捷命令 ocm" \
      "  9) 🗑️  卸载管理器" \
      "  0) 🚪 退出"
    printf '\n'
    local choice=""
    read -r -p "请选择 [0-9]: " choice
    case "$choice" in
      1) "$SCRIPT_PATH" start-proxy || true; pause_menu ;;
      2) "$SCRIPT_PATH" start-global || true; pause_menu ;;
      3) "$SCRIPT_PATH" stop || true; pause_menu ;;
      4) "$SCRIPT_PATH" accounts || true ;;
      5) "$SCRIPT_PATH" check || true; pause_menu ;;
      6) show_logs || true; pause_menu ;;
      7) "$SCRIPT_PATH" deps || true; pause_menu ;;
      8) "$SCRIPT_PATH" install || true; pause_menu ;;
      9)
        "$SCRIPT_PATH" uninstall || true
        [ -e "$INSTALL_PATH" ] || return 0
        pause_menu
        ;;
      0) return 0 ;;
      *) log_err "无效选择：${choice:-空}"; pause_menu ;;
    esac
  done
}

run_main() {
  case "${1:-main}" in
    _service_run) service_run ;;
    _service_health) service_health ;;
    _service_cleanup) service_cleanup ;;
    _rollback) rollback_now ;;
    start-proxy) check_root; acquire_manager_lock; start_mode proxy ;;
    start-global) check_root; acquire_manager_lock; start_mode global ;;
    stop) check_root; acquire_manager_lock; stop_vpn ;;
    accounts) check_root; acquire_manager_lock; manage_accounts ;;
    deps) check_root; acquire_manager_lock; check_all_dependencies ;;
    install) check_root; acquire_manager_lock; install_command ;;
    uninstall) check_root; acquire_manager_lock; uninstall_manager ;;
    status) check_root; show_status ;;
    check) check_root; check_data_plane ;;
    logs) check_root; show_logs ;;
    main) check_root; main_menu ;;
    *) log_err "用法：$0 [start-proxy|start-global|stop|accounts|deps|install|uninstall|status|check|logs]"; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run_main "$@"
fi
