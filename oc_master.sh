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
readonly SYSTEMD_DIR="${OCM_SYSTEMD_DIR:-/etc/systemd/system}"
readonly CONFIG_DIR="${OCM_CONFIG_DIR:-/etc/oc-master}"
readonly PROFILE_FILE="${OCM_PROFILE_FILE:-${CONFIG_DIR}/profile.conf}"
readonly ACCOUNTS_FILE="${OCM_ACCOUNTS_FILE:-/root/.vpn_accounts.env}"
readonly RUNTIME_DIR="${OCM_RUNTIME_DIR:-/run/oc-master}"
readonly LOCK_FILE="${OCM_LOCK_FILE:-/run/lock/oc-master.lock}"
readonly ACTIVE_RUN_FILE="${OCM_ACTIVE_RUN_FILE:-${CONFIG_DIR}/active-run.conf}"
readonly RUN_STATE_FILE="${OCM_RUN_STATE_FILE:-${CONFIG_DIR}/run-state.conf}"
# shellcheck disable=SC2034  # 后续事务路由任务消费。
readonly ROUTE_PLAN_FILE="${OCM_ROUTE_PLAN_FILE:-${CONFIG_DIR}/route-plan.conf}"
readonly STATE_LOCK_FILE="${OCM_STATE_LOCK_FILE:-/run/lock/oc-master-state.lock}"
# shellcheck disable=SC2034  # 后续 service-operation lock 任务消费。
readonly SERVICE_LOCK_FILE="${OCM_SERVICE_LOCK_FILE:-/run/lock/oc-master-service.lock}"
# shellcheck disable=SC2034  # 后续服务代际任务消费。
readonly SERVICE_RUN_ID_FILE="${OCM_SERVICE_RUN_ID_FILE:-${RUNTIME_DIR}/service.run-id}"
readonly PROC_ROOT="${OCM_PROC_ROOT:-/proc}"
readonly BOOT_ID_FILE="${OCM_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
readonly UUID_FILE="${OCM_UUID_FILE:-/proc/sys/kernel/random/uuid}"
# shellcheck disable=SC2034  # 后续 systemd restart 策略任务消费。
readonly NON_RESTARTABLE_EXIT=78
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

acquire_service_operation_lock() {
  [ "$#" -eq 1 ] || return 1
  local mode="$1"

  case "$mode" in wait|try) ;; *) return 1 ;; esac
  [ -z "${SERVICE_OPERATION_LOCK_FD:-}" ] || return 0
  command -v flock >/dev/null 2>&1 || { die "缺少 flock（util-linux），无法安全串行化服务操作。"; return 1; }
  install -d -m 0755 "$(dirname -- "$SERVICE_LOCK_FILE")" || return 1
  exec {SERVICE_OPERATION_LOCK_FD}>"$SERVICE_LOCK_FILE" || return 1
  if [ "$mode" = try ]; then
    flock -n "$SERVICE_OPERATION_LOCK_FD" || {
      exec {SERVICE_OPERATION_LOCK_FD}>&-
      unset SERVICE_OPERATION_LOCK_FD
      return 1
    }
  elif ! flock "$SERVICE_OPERATION_LOCK_FD"; then
    exec {SERVICE_OPERATION_LOCK_FD}>&-
    unset SERVICE_OPERATION_LOCK_FD
    return 1
  fi
}

release_service_operation_lock() {
  [ -n "${SERVICE_OPERATION_LOCK_FD:-}" ] || return 0
  flock -u "$SERVICE_OPERATION_LOCK_FD" >/dev/null 2>&1 || true
  exec {SERVICE_OPERATION_LOCK_FD}>&-
  unset SERVICE_OPERATION_LOCK_FD
}

acquire_state_lock() {
  [ -z "${STATE_LOCK_FD:-}" ] || return 1
  command -v flock >/dev/null 2>&1 || return 1
  install -d -m 0755 "$(dirname -- "$STATE_LOCK_FILE")" || return 1
  exec {STATE_LOCK_FD}>"$STATE_LOCK_FILE" || return 1
  if ! flock "$STATE_LOCK_FD"; then
    exec {STATE_LOCK_FD}>&-
    unset STATE_LOCK_FD
    return 1
  fi
}

release_state_lock() {
  [ -n "${STATE_LOCK_FD:-}" ] || return 0
  flock -u "$STATE_LOCK_FD" >/dev/null 2>&1 || true
  exec {STATE_LOCK_FD}>&-
  unset STATE_LOCK_FD
}

valid_uuid() {
  [[ "${1:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]
}

read_single_uuid_file() {
  local path="$1"
  local -a lines=()

  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  mapfile -t lines < "$path" || return 1
  [ "${#lines[@]}" -eq 1 ] && valid_uuid "${lines[0]}" || return 1
  printf '%s\n' "${lines[0]}"
}

new_run_id() {
  read_single_uuid_file "$UUID_FILE"
}

current_boot_id() {
  read_single_uuid_file "$BOOT_ID_FILE"
}

atomic_replace_from_stdin() (
  [ "$#" -eq 2 ] || return 1
  local target="$1" mode="$2" target_dir target_base temporary_file=""

  target_dir="$(dirname -- "$target")" || return 1
  target_base="$(basename -- "$target")" || return 1
  [ -d "$target_dir" ] || return 1
  [ ! -d "$target" ] || return 1
  trap '[ -z "$temporary_file" ] || rm -f -- "$temporary_file"' EXIT HUP INT TERM
  temporary_file="$(mktemp "${target_dir}/.${target_base}.XXXXXX")" || return 1
  cat > "$temporary_file" || return 1
  chown 0:0 "$temporary_file" || return 1
  chmod "$mode" "$temporary_file" || return 1
  [ -f "$temporary_file" ] && [ ! -L "$temporary_file" ] || return 1
  mv -T -f -- "$temporary_file" "$target" || return 1
  temporary_file=""
)

valid_state_phase() {
  case "${1:-}" in
    PREPARING|STARTING|RUNNING|AWAITING_CONFIRMATION|CONFIRMED|ROLLBACK_CLAIMED|STOPPING|CLEANUP_FAILED|CLEANED) return 0 ;;
    *) return 1 ;;
  esac
}

valid_account_record() {
  local record="${1:-}" pipes desc user password host group protocol

  case "$record" in *$'\n'*|*$'\r'*) return 1 ;; esac
  pipes="${record//[^|]/}"
  case "${#pipes}" in 4|5) ;; *) return 1 ;; esac
  IFS='|' read -r desc user password host group protocol <<< "$record"
  [ -n "$desc" ] && [ -n "$user" ] && [ -n "$password" ] && [ -n "$host" ] || return 1
  [[ "$host" != -* ]] || return 1
  [ -z "$protocol" ] || valid_protocol "$protocol"
}

valid_active_run_values() {
  [ "$#" -eq 7 ] || return 1
  local run_id="$1" boot_id="$2" mode="$3" account_index="$4" protocol="$5" socks_port="$6" account_record="$7"

  valid_uuid "$run_id" && valid_uuid "$boot_id" || return 1
  case "$mode" in proxy|global) ;; *) return 1 ;; esac
  [[ "$account_index" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  valid_protocol "$protocol" || return 1
  case "$mode" in
    proxy) valid_port "$socks_port" || return 1 ;;
    global) [ -z "$socks_port" ] || return 1 ;;
  esac
  valid_account_record "$account_record"
}

valid_run_state_values() {
  [ "$#" -eq 4 ] || return 1
  local run_id="$1" phase="$2" desired_active="$3" rollback_deadline="$4"

  valid_uuid "$run_id" && valid_state_phase "$phase" || return 1
  case "$desired_active" in 0|1) ;; *) return 1 ;; esac
  [[ "$rollback_deadline" =~ ^(0|[1-9][0-9]*)$ ]]
}

write_active_run() {
  [ "$#" -eq 7 ] || return 1
  valid_active_run_values "$@" || return 1
  printf '%s\n' \
    'FORMAT_VERSION=1' \
    "RUN_ID=$1" \
    "CREATED_BOOT_ID=$2" \
    "MODE=$3" \
    "ACCOUNT_INDEX=$4" \
    "VPN_PROTOCOL=$5" \
    "SOCKS_PORT=$6" \
    "ACCOUNT_RECORD=$7" \
    | atomic_replace_from_stdin "$ACTIVE_RUN_FILE" 0600
}

load_active_run() {
  local line key value
  local parsed_format="" parsed_run_id="" parsed_boot_id="" parsed_mode=""
  local parsed_account_index="" parsed_protocol="" parsed_socks_port="" parsed_account_record=""
  local seen_format=0 seen_run_id=0 seen_boot_id=0 seen_mode=0
  local seen_account_index=0 seen_protocol=0 seen_socks_port=0 seen_account_record=0

  [ -f "$ACTIVE_RUN_FILE" ] && [ ! -L "$ACTIVE_RUN_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" == *=* ]] || return 1
    IFS='=' read -r key value <<< "$line"
    case "$key" in
      FORMAT_VERSION)
        [ "$seen_format" -eq 0 ] || return 1
        seen_format=1; parsed_format="$value"
        ;;
      RUN_ID)
        [ "$seen_run_id" -eq 0 ] || return 1
        seen_run_id=1; parsed_run_id="$value"
        ;;
      CREATED_BOOT_ID)
        [ "$seen_boot_id" -eq 0 ] || return 1
        seen_boot_id=1; parsed_boot_id="$value"
        ;;
      MODE)
        [ "$seen_mode" -eq 0 ] || return 1
        seen_mode=1; parsed_mode="$value"
        ;;
      ACCOUNT_INDEX)
        [ "$seen_account_index" -eq 0 ] || return 1
        seen_account_index=1; parsed_account_index="$value"
        ;;
      VPN_PROTOCOL)
        [ "$seen_protocol" -eq 0 ] || return 1
        seen_protocol=1; parsed_protocol="$value"
        ;;
      SOCKS_PORT)
        [ "$seen_socks_port" -eq 0 ] || return 1
        seen_socks_port=1; parsed_socks_port="$value"
        ;;
      ACCOUNT_RECORD)
        [ "$seen_account_record" -eq 0 ] || return 1
        seen_account_record=1; parsed_account_record="$value"
        ;;
      *) return 1 ;;
    esac
  done < "$ACTIVE_RUN_FILE"

  [ "$seen_format" -eq 1 ] && [ "$seen_run_id" -eq 1 ] && [ "$seen_boot_id" -eq 1 ] \
    && [ "$seen_mode" -eq 1 ] && [ "$seen_account_index" -eq 1 ] && [ "$seen_protocol" -eq 1 ] \
    && [ "$seen_socks_port" -eq 1 ] && [ "$seen_account_record" -eq 1 ] || return 1
  [ "$parsed_format" = 1 ] || return 1
  valid_active_run_values "$parsed_run_id" "$parsed_boot_id" "$parsed_mode" "$parsed_account_index" \
    "$parsed_protocol" "$parsed_socks_port" "$parsed_account_record" || return 1

  RUN_ID="$parsed_run_id"
  # shellcheck disable=SC2034  # load_active_run 的公开输出。
  CREATED_BOOT_ID="$parsed_boot_id"
  # shellcheck disable=SC2034  # load_active_run 的公开输出。
  MODE="$parsed_mode"
  ACCOUNT_INDEX="$parsed_account_index"
  VPN_PROTOCOL="$parsed_protocol"
  # shellcheck disable=SC2034  # load_active_run 的公开输出。
  SOCKS_PORT="$parsed_socks_port"
  # shellcheck disable=SC2034  # load_active_run 的公开输出。
  ACCOUNT_RECORD="$parsed_account_record"
}

write_run_state() {
  [ "$#" -eq 4 ] || return 1
  valid_run_state_values "$@" || return 1
  printf '%s\n' \
    'FORMAT_VERSION=1' \
    "RUN_ID=$1" \
    "PHASE=$2" \
    "DESIRED_ACTIVE=$3" \
    "ROLLBACK_DEADLINE=$4" \
    | atomic_replace_from_stdin "$RUN_STATE_FILE" 0600
}

load_run_state() {
  local line key value
  local parsed_format="" parsed_run_id="" parsed_phase="" parsed_desired_active="" parsed_rollback_deadline=""
  local seen_format=0 seen_run_id=0 seen_phase=0 seen_desired_active=0 seen_rollback_deadline=0

  [ -f "$RUN_STATE_FILE" ] && [ ! -L "$RUN_STATE_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" == *=* ]] || return 1
    IFS='=' read -r key value <<< "$line"
    case "$key" in
      FORMAT_VERSION)
        [ "$seen_format" -eq 0 ] || return 1
        seen_format=1; parsed_format="$value"
        ;;
      RUN_ID)
        [ "$seen_run_id" -eq 0 ] || return 1
        seen_run_id=1; parsed_run_id="$value"
        ;;
      PHASE)
        [ "$seen_phase" -eq 0 ] || return 1
        seen_phase=1; parsed_phase="$value"
        ;;
      DESIRED_ACTIVE)
        [ "$seen_desired_active" -eq 0 ] || return 1
        seen_desired_active=1; parsed_desired_active="$value"
        ;;
      ROLLBACK_DEADLINE)
        [ "$seen_rollback_deadline" -eq 0 ] || return 1
        seen_rollback_deadline=1; parsed_rollback_deadline="$value"
        ;;
      *) return 1 ;;
    esac
  done < "$RUN_STATE_FILE"

  [ "$seen_format" -eq 1 ] && [ "$seen_run_id" -eq 1 ] && [ "$seen_phase" -eq 1 ] \
    && [ "$seen_desired_active" -eq 1 ] && [ "$seen_rollback_deadline" -eq 1 ] || return 1
  [ "$parsed_format" = 1 ] || return 1
  valid_run_state_values "$parsed_run_id" "$parsed_phase" "$parsed_desired_active" \
    "$parsed_rollback_deadline" || return 1

  RUN_ID="$parsed_run_id"
  PHASE="$parsed_phase"
  # shellcheck disable=SC2034  # load_run_state 的公开输出。
  DESIRED_ACTIVE="$parsed_desired_active"
  # shellcheck disable=SC2034  # load_run_state 的公开输出。
  ROLLBACK_DEADLINE="$parsed_rollback_deadline"
}

load_runtime_state() {
  local active_run_id

  load_active_run || return 1
  active_run_id="$RUN_ID"
  load_run_state || return 1
  [ "$RUN_ID" = "$active_run_id" ]
}

loaded_state_allows_service_run() {
  [ "$#" -eq 1 ] || return 1
  local expected_run_id="$1" boot_id

  [ "$RUN_ID" = "$expected_run_id" ] && [ "$DESIRED_ACTIVE" = 1 ] || return 1
  case "$PHASE" in
    STARTING|RUNNING|AWAITING_CONFIRMATION|CONFIRMED) ;;
    *) return 1 ;;
  esac
  if [ "$MODE" = global ]; then
    boot_id="$(current_boot_id)" || return 1
    if [ "$CREATED_BOOT_ID" != "$boot_id" ]; then
      case "$PHASE" in
        PREPARING|STARTING|AWAITING_CONFIRMATION|ROLLBACK_CLAIMED) return 1 ;;
      esac
    fi
  fi
}

state_allows_service_run() {
  [ "$#" -eq 1 ] || return 1
  local expected_run_id="$1" allowed=1

  acquire_state_lock || return 1
  if load_runtime_state && loaded_state_allows_service_run "$expected_run_id"; then
    allowed=0
  fi
  release_state_lock
  return "$allowed"
}

state_matches_run() {
  [ "$#" -eq 1 ] || return 1
  local expected_run_id="$1" matches=1

  acquire_state_lock || return 1
  if load_runtime_state && [ "$RUN_ID" = "$expected_run_id" ]; then matches=0; fi
  release_state_lock
  return "$matches"
}

transition_run_state() (
  [ "$#" -eq 5 ] || return 1
  local expected_run_id="$1" allowed_old_phases="$2" new_phase="$3"
  local desired_active="$4" rollback_deadline="$5" phase transition_result=0
  local -a allowed_phase_list=()

  valid_run_state_values "$expected_run_id" "$new_phase" "$desired_active" "$rollback_deadline" || return 1
  IFS=',' read -r -a allowed_phase_list <<< "$allowed_old_phases"
  [ "${#allowed_phase_list[@]}" -gt 0 ] || return 1
  for phase in "${allowed_phase_list[@]}"; do
    valid_state_phase "$phase" || return 1
  done

  acquire_state_lock || return 1
  if ! load_runtime_state || [ "$RUN_ID" != "$expected_run_id" ]; then
    release_state_lock
    return 1
  fi
  case ",$allowed_old_phases," in
    *",$PHASE,"*) ;;
    *) release_state_lock; return 1 ;;
  esac
  if write_run_state "$expected_run_id" "$new_phase" "$desired_active" "$rollback_deadline"; then
    transition_result=0
  else
    transition_result=$?
  fi
  release_state_lock
  return "$transition_result"
)

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
    printf '%s\n' '# 显示名|用户名|密码|VPN主机|认证组(可空)|协议(anyconnect/nc/pulse)' \
      | replace_accounts_from_stdin
  fi
  chown 0:0 "$ACCOUNTS_FILE"
  chmod 600 "$ACCOUNTS_FILE"
}

replace_accounts_from_stdin() {
  [ -d "$(dirname -- "$ACCOUNTS_FILE")" ] || return 1
  atomic_replace_from_stdin "$ACCOUNTS_FILE" 0600
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
  ACCOUNT_RECORD="${ACCOUNTS[$index]}"
  parse_account_line "$ACCOUNT_RECORD" || return 1
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
        {
          cat -- "$ACCOUNTS_FILE"
          if [ -s "$ACCOUNTS_FILE" ] && [ "$(tail -c 1 -- "$ACCOUNTS_FILE" | wc -l | tr -d '[:space:]')" -eq 0 ]; then
            printf '\n'
          fi
          printf '%s|%s|%s|%s|%s|%s\n' "$new_desc" "$new_user" "$new_pass" "$new_host" "$new_group" "$VPN_PROTOCOL"
        } | replace_accounts_from_stdin \
          || { log_err "账户文件写入失败。"; return 1; }
        log "已添加账户：$new_desc"
        ;;
      2)
        [ "${#ACCOUNTS[@]}" -gt 0 ] || { log_warn "没有可删除的账户。"; continue; }
        local delete_index=""
        read -r -p "输入要删除的序号: " delete_index
        [[ "$delete_index" =~ ^[0-9]+$ ]] && [ "$delete_index" -ge 1 ] && [ "$delete_index" -le "${#ACCOUNTS[@]}" ] \
          || { log_err "无效序号。"; continue; }
        awk -v target="$delete_index" '
          /^[[:space:]]*(#|$)/ { print; next }
          { n++; if (n != target) print }
        ' "$ACCOUNTS_FILE" | replace_accounts_from_stdin \
          || { log_err "账户文件写入失败。"; return 1; }
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

service_control_group() {
  local control_group=""

  control_group="$(systemctl show "$SERVICE_NAME" --property=ControlGroup --value 2>/dev/null)" || return 1
  [[ "$control_group" == /* ]] && [ "$control_group" != / ] && [[ "$control_group" != *$'\n'* ]] || return 1
  printf '%s\n' "$control_group"
}

listener_pids_for_tcp_port() {
  [ "$#" -eq 1 ] && valid_port "$1" || return 1
  local port="$1" listeners=""

  listeners="$(ss -H -ltnp 2>/dev/null)" || return 1
  awk -v port="$port" '
    $4 ~ (":" port "$") {
      line=$0
      while (match(line, /pid=[0-9]+/)) {
        print substr(line, RSTART + 4, RLENGTH - 4)
        line=substr(line, RSTART + RLENGTH)
      }
    }
  ' <<< "$listeners"
}

pid_belongs_to_service_cgroup() {
  [ "$#" -eq 2 ] || return 1
  local pid="$1" control_group="$2" line="" process_group=""

  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$control_group" == /* ]] && [ "$control_group" != / ] || return 1
  [ -r "$PROC_ROOT/$pid/cgroup" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    process_group="${line##*:}"
    case "$process_group" in
      "$control_group"|"$control_group"/*) return 0 ;;
    esac
  done < "$PROC_ROOT/$pid/cgroup"
  return 1
}

managed_tcp_listener_is_ready() {
  [ "$#" -eq 1 ] && valid_port "$1" || return 1
  local port="$1" control_group="" pid=""

  control_group="$(service_control_group)" || return 1
  while IFS= read -r pid; do
    pid_belongs_to_service_cgroup "$pid" "$control_group" && return 0
  done < <(listener_pids_for_tcp_port "$port")
  return 1
}

port_is_free() {
  local port="$1"
  ! tcp_port_is_listening "$port"
}

write_profile() {
  local mode="$1" account_index="$2" protocol="$3" socks_port="${4:-}"
  [ "$mode" = "proxy" ] || [ "$mode" = "global" ] || { die "内部模式无效：$mode"; return 1; }
  [[ "$account_index" =~ ^[0-9]+$ ]] || { die "内部账户索引无效。"; return 1; }
  valid_protocol "$protocol" || { die "内部协议无效。"; return 1; }
  if [ "$mode" = "proxy" ]; then valid_port "$socks_port" || { die "内部 SOCKS 端口无效。"; return 1; }; fi
  if [ "$mode" = "global" ]; then [ -z "$socks_port" ] || { die "全局模式不应设置 SOCKS 端口。"; return 1; }; fi

  ensure_dirs
  printf '%s\n' \
    "MODE=$mode" \
    "ACCOUNT_INDEX=$account_index" \
    "VPN_PROTOCOL=$protocol" \
    "SOCKS_PORT=$socks_port" \
    | atomic_replace_from_stdin "$PROFILE_FILE" 0600
}

load_profile_values() {
  local line key value
  local parsed_mode="" parsed_account_index="" parsed_protocol="" parsed_socks_port=""
  local seen_mode=0 seen_account_index=0 seen_protocol=0 seen_socks_port=0

  [ -f "$PROFILE_FILE" ] && [ ! -L "$PROFILE_FILE" ] || { die "未找到活动配置：$PROFILE_FILE"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" == *=* ]] || { die "活动配置格式无效。"; return 1; }
    IFS='=' read -r key value <<< "$line"
    case "$key" in
      MODE)
        [ "$seen_mode" -eq 0 ] || { die "活动配置包含重复字段。"; return 1; }
        seen_mode=1; parsed_mode="$value"
        ;;
      ACCOUNT_INDEX)
        [ "$seen_account_index" -eq 0 ] || { die "活动配置包含重复字段。"; return 1; }
        seen_account_index=1; parsed_account_index="$value"
        ;;
      VPN_PROTOCOL)
        [ "$seen_protocol" -eq 0 ] || { die "活动配置包含重复字段。"; return 1; }
        seen_protocol=1; parsed_protocol="$value"
        ;;
      SOCKS_PORT)
        [ "$seen_socks_port" -eq 0 ] || { die "活动配置包含重复字段。"; return 1; }
        seen_socks_port=1; parsed_socks_port="$value"
        ;;
      *) die "活动配置包含未知字段。"; return 1 ;;
    esac
  done < "$PROFILE_FILE"
  [ "$seen_mode" -eq 1 ] && [ "$seen_account_index" -eq 1 ] && [ "$seen_protocol" -eq 1 ] \
    && [ "$seen_socks_port" -eq 1 ] || { die "活动配置缺少必需字段。"; return 1; }

  PROFILE_MODE="$parsed_mode"
  PROFILE_ACCOUNT_INDEX="$parsed_account_index"
  PROFILE_PROTOCOL="$parsed_protocol"
  PROFILE_SOCKS_PORT="$parsed_socks_port"
  [ "$PROFILE_MODE" = "proxy" ] || [ "$PROFILE_MODE" = "global" ] || { die "活动配置中的 MODE 无效。"; return 1; }
  [[ "$PROFILE_ACCOUNT_INDEX" =~ ^[0-9]+$ ]] || { die "活动配置中的账户索引无效。"; return 1; }
  valid_protocol "$PROFILE_PROTOCOL" || { die "活动配置中的协议无效。"; return 1; }
  if [ "$PROFILE_MODE" = "proxy" ]; then valid_port "$PROFILE_SOCKS_PORT" || { die "活动配置中的 SOCKS 端口无效。"; return 1; }; fi
  if [ "$PROFILE_MODE" = "global" ]; then [ -z "$PROFILE_SOCKS_PORT" ] || { die "全局活动配置不应设置 SOCKS 端口。"; return 1; }; fi
}

load_legacy_profile_account() {
  load_profile_values || return 1
  load_account_by_index "$PROFILE_ACCOUNT_INDEX" || return 1
}

load_runtime_configuration() {
  load_runtime_state || { die "运行快照或代际状态缺失、损坏或不匹配。"; return 1; }
  PROFILE_MODE="$MODE"
  PROFILE_ACCOUNT_INDEX="$ACCOUNT_INDEX"
  PROFILE_PROTOCOL="$VPN_PROTOCOL"
  PROFILE_SOCKS_PORT="$SOCKS_PORT"
  parse_account_line "$ACCOUNT_RECORD" || return 1
}

load_profile() {
  load_runtime_configuration
}

create_run_snapshot() {
  [ "$#" -eq 5 ] || return 1
  local mode="$1" account_index="$2" protocol="$3" socks_port="$4" account_line="$5"
  local run_id boot_id

  run_id="$(new_run_id)" || { die "无法读取新的运行代际标识。"; return 1; }
  boot_id="$(current_boot_id)" || { die "无法读取当前启动标识。"; return 1; }
  valid_active_run_values "$run_id" "$boot_id" "$mode" "$account_index" "$protocol" "$socks_port" "$account_line" \
    || { die "拒绝创建无效的运行快照。"; return 1; }

  ensure_dirs
  write_run_state "$run_id" PREPARING 1 0 || return 1
  write_active_run "$run_id" "$boot_id" "$mode" "$account_index" "$protocol" "$socks_port" "$account_line" || return 1
  write_profile "$mode" "$account_index" "$protocol" "$socks_port" || return 1
  load_profile_values || return 1
  [ "$PROFILE_MODE" = "$mode" ] \
    && [ "$PROFILE_ACCOUNT_INDEX" = "$account_index" ] \
    && [ "$PROFILE_PROTOCOL" = "$protocol" ] \
    && [ "$PROFILE_SOCKS_PORT" = "$socks_port" ] \
    || { die "兼容活动配置写入后校验失败。"; return 1; }
  load_runtime_configuration || return 1
  [ "$RUN_ID" = "$run_id" ] \
    && [ "$CREATED_BOOT_ID" = "$boot_id" ] \
    && [ "$MODE" = "$mode" ] \
    && [ "$ACCOUNT_INDEX" = "$account_index" ] \
    && [ "$VPN_PROTOCOL" = "$protocol" ] \
    && [ "$SOCKS_PORT" = "$socks_port" ] \
    && [ "$ACCOUNT_RECORD" = "$account_line" ] \
    && [ "$PHASE" = PREPARING ] \
    && [ "$DESIRED_ACTIVE" = 1 ] \
    && [ "$ROLLBACK_DEADLINE" = 0 ] \
    || { die "运行快照写入后校验失败。"; return 1; }
  printf '%s\n' "$RUN_ID"
}

migrate_legacy_profile() {
  local account_line

  if [ -e "$ACTIVE_RUN_FILE" ] || [ -L "$ACTIVE_RUN_FILE" ] \
    || [ -e "$RUN_STATE_FILE" ] || [ -L "$RUN_STATE_FILE" ]; then
    return 1
  fi
  load_legacy_profile_account || return 1
  account_line="$ACCOUNT_RECORD"
  create_run_snapshot "$PROFILE_MODE" "$PROFILE_ACCOUNT_INDEX" "$PROFILE_PROTOCOL" "$PROFILE_SOCKS_PORT" "$account_line"
}

managed_persistent_units_are_quiescent() {
  local unit state

  for unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    case "$state" in inactive|failed) ;; *) return 1 ;; esac
  done
}

load_uncommitted_preparing_state() {
  local expected_run_id="${1:-}"

  if [ -e "$ACTIVE_RUN_FILE" ] || [ -L "$ACTIVE_RUN_FILE" ] \
    || [ -e "$ROUTE_PLAN_FILE" ] || [ -L "$ROUTE_PLAN_FILE" ] \
    || [ -e "$ROUTE_OWNER_FILE" ] || [ -L "$ROUTE_OWNER_FILE" ] \
    || [ -e "$SERVICE_RUN_ID_FILE" ] || [ -L "$SERVICE_RUN_ID_FILE" ] \
    || [ -e "$HEALTH_FAILURE_FILE" ] || [ -L "$HEALTH_FAILURE_FILE" ] \
    || [ -e "$HEALTH_RESTART_FILE" ] || [ -L "$HEALTH_RESTART_FILE" ]; then
    return 1
  fi
  if ! load_run_state \
    || [ "$PHASE" != PREPARING ] \
    || [ "$DESIRED_ACTIVE" != 1 ] \
    || [ "$ROLLBACK_DEADLINE" != 0 ]; then
    return 1
  fi
  [ -z "$expected_run_id" ] || [ "$RUN_ID" = "$expected_run_id" ]
}

recover_uncommitted_preparing_state() {
  [ -n "${SERVICE_OPERATION_LOCK_FD:-}" ] || return 1
  local candidate_run_id=""

  acquire_state_lock || return 1
  if ! load_uncommitted_preparing_state; then
    release_state_lock
    return 1
  fi
  candidate_run_id="$RUN_ID"
  release_state_lock

  managed_persistent_units_are_quiescent || return 1

  acquire_state_lock || return 1
  if ! load_uncommitted_preparing_state "$candidate_run_id"; then
    release_state_lock
    return 1
  fi
  if ! rm -f -- "$RUN_STATE_FILE" \
    || [ -e "$RUN_STATE_FILE" ] || [ -L "$RUN_STATE_FILE" ]; then
    release_state_lock
    return 1
  fi
  release_state_lock
}

prepare_runtime_configuration_for_start() {
  if [ -e "$ACTIVE_RUN_FILE" ] || [ -L "$ACTIVE_RUN_FILE" ] \
    || [ -e "$RUN_STATE_FILE" ] || [ -L "$RUN_STATE_FILE" ]; then
    if load_runtime_configuration >/dev/null 2>&1; then return 0; fi
    recover_uncommitted_preparing_state \
      || { die "检测到不完整或非法的新运行状态，拒绝按旧账户索引回退。"; return 1; }
    return 0
  fi
  recover_legacy_installation || { die "旧版安装未能完整停止和清理，拒绝创建新的运行快照。"; return 1; }
  [ ! -e "$PROFILE_FILE" ] && [ ! -L "$PROFILE_FILE" ] && return 0
  migrate_legacy_profile >/dev/null \
    || { die "旧活动配置迁移失败。"; return 1; }
}

new_runtime_artifact_exists() {
  [ -e "$ACTIVE_RUN_FILE" ] || [ -L "$ACTIVE_RUN_FILE" ] \
    || [ -e "$RUN_STATE_FILE" ] || [ -L "$RUN_STATE_FILE" ] \
    || [ -e "$ROUTE_PLAN_FILE" ] || [ -L "$ROUTE_PLAN_FILE" ] \
    || [ -e "$SERVICE_RUN_ID_FILE" ] || [ -L "$SERVICE_RUN_ID_FILE" ] \
    || [ -e "$HEALTH_FAILURE_FILE" ] || [ -L "$HEALTH_FAILURE_FILE" ] \
    || [ -e "$HEALTH_RESTART_FILE" ] || [ -L "$HEALTH_RESTART_FILE" ]
}

legacy_installation_exists() {
  local unit path

  if [ -e "$PROFILE_FILE" ] || [ -L "$PROFILE_FILE" ] \
    || [ -e "$ROUTE_OWNER_FILE" ] || [ -L "$ROUTE_OWNER_FILE" ]; then
    return 0
  fi
  for unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
    path="$(unit_path "$unit")" || return 1
    unit_is_ours "$path" "$unit" && return 0
  done
  return 1
}

recover_legacy_installation() {
  new_runtime_artifact_exists && return 1
  legacy_installation_exists || return 0

  preflight_managed_units_ownership || return 1
  stop_and_disable_managed_units || return 1
  if [ -e "$ROUTE_OWNER_FILE" ] || [ -L "$ROUTE_OWNER_FILE" ]; then
    cleanup_legacy_return_routes || return 1
  fi
  [ ! -e "$ROUTE_OWNER_FILE" ] && [ ! -L "$ROUTE_OWNER_FILE" ]
}

shortcut_is_ours() {
  [ "$SHORTCUT_PATH" = "$INSTALL_PATH" ] && return 0
  [ -L "$SHORTCUT_PATH" ] && [ "$(readlink "$SHORTCUT_PATH" 2>/dev/null || true)" = "$INSTALL_PATH" ]
}

unit_path() {
  [ "$#" -eq 1 ] || return 1
  printf '%s/%s\n' "$SYSTEMD_DIR" "$1"
}

unit_is_ours() {
  [ "$#" -eq 2 ] || return 1
  local file="$1" kind="$2"

  # 这里仅判定可迁移/可清理的历史所有权；启动和健康重启必须另行
  # 通过 current 模板及 systemd 已加载契约的完整校验。
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  head -n 1 -- "$file" 2>/dev/null | grep -Fx '# Managed by oc-master' >/dev/null && return 0
  case "$kind" in
    "$SERVICE_NAME")
      grep -Fx 'Description=OpenConnect Master managed tunnel' "$file" >/dev/null \
        && grep -Fx "ExecStart=${INSTALL_PATH} _service_run" "$file" >/dev/null \
        && grep -Fx "ExecStopPost=-${INSTALL_PATH} _service_cleanup" "$file" >/dev/null
      ;;
    "$HEALTH_SERVICE_NAME")
      grep -Fx 'Description=OpenConnect Master data-plane health check' "$file" >/dev/null \
        && grep -Fx "ExecStart=${INSTALL_PATH} _service_health" "$file" >/dev/null
      ;;
    "$HEALTH_TIMER_NAME")
      grep -Fx 'Description=Run OpenConnect Master health checks' "$file" >/dev/null \
        && grep -Fx "Unit=${HEALTH_SERVICE_NAME}" "$file" >/dev/null
      ;;
    *) return 1 ;;
  esac
}

managed_unit_has_owned_source() {
  [ "$#" -eq 1 ] || return 1
  local unit="$1" path load_state fragment_path dropin_paths

  path="$(unit_path "$unit")" || return 1
  if ! load_state="$(systemctl show "$unit" --property=LoadState --value 2>/dev/null)" \
    || [ "$load_state" != loaded ]; then
    return 1
  fi
  if ! fragment_path="$(systemctl show "$unit" --property=FragmentPath --value 2>/dev/null)" \
    || [ "$fragment_path" != "$path" ]; then
    return 1
  fi
  if ! dropin_paths="$(systemctl show "$unit" --all --property=DropInPaths 2>/dev/null)" \
    || [ "$dropin_paths" != 'DropInPaths=' ]; then
    return 1
  fi
  unit_is_ours "$path" "$unit"
}

managed_unit_file_is_current() {
  [ "$#" -eq 1 ] || return 1
  local unit="$1" path

  path="$(unit_path "$unit")" || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  render_unit_file "$unit" | cmp -s -- "$path" -
}

systemd_exec_value_matches() {
  [ "$#" -eq 4 ] || return 1
  local value="$1" expected_path="$2" expected_argv="$3" expected_ignore="$4"
  local path_tail argv_tail ignore_tail actual_path actual_argv actual_ignore remainder

  [ -n "$value" ] && [[ "$value" != *$'\n'* ]] || return 1
  [[ "${value#*path=}" != *'path='* ]] \
    && [[ "${value#*argv[]=}" != *'argv[]='* ]] \
    && [[ "${value#*ignore_errors=}" != *'ignore_errors='* ]] || return 1
  path_tail="${value#*path=}"
  [ "$path_tail" != "$value" ] && [[ "$path_tail" == *' ;'* ]] || return 1
  actual_path="${path_tail%% ;*}"
  argv_tail="${path_tail#*argv[]=}"
  [ "$argv_tail" != "$path_tail" ] && [[ "$argv_tail" == *' ;'* ]] || return 1
  actual_argv="${argv_tail%% ;*}"
  ignore_tail="${argv_tail#*ignore_errors=}"
  [ "$ignore_tail" != "$argv_tail" ] || return 1
  actual_ignore="${ignore_tail%% *}"
  if [[ "$ignore_tail" == *' '* ]]; then remainder="${ignore_tail#* }"; else remainder=""; fi

  [ "$actual_path" = "$expected_path" ] \
    && [ "$actual_argv" = "$expected_argv" ] \
    && [ "$actual_ignore" = "$expected_ignore" ] \
    && [[ "$remainder" != *'path='* ]] \
    && [[ "$remainder" != *'argv[]='* ]]
}

managed_main_unit_contract_is_exact() {
  local exec_start exec_stop restart restart_prevent

  exec_start="$(systemctl show "$SERVICE_NAME" --property=ExecStart --value 2>/dev/null)" || return 1
  exec_stop="$(systemctl show "$SERVICE_NAME" --property=ExecStopPost --value 2>/dev/null)" || return 1
  restart="$(systemctl show "$SERVICE_NAME" --property=Restart --value 2>/dev/null)" || return 1
  restart_prevent="$(systemctl show "$SERVICE_NAME" --property=RestartPreventExitStatus --value 2>/dev/null)" || return 1

  systemd_exec_value_matches "$exec_start" "$INSTALL_PATH" "${INSTALL_PATH} _service_run" no \
    && systemd_exec_value_matches "$exec_stop" "$INSTALL_PATH" "${INSTALL_PATH} _service_cleanup" yes \
    && [ "$restart" = always ] \
    && [ "$restart_prevent" = 78 ]
}

managed_health_unit_contract_is_exact() {
  local exec_start

  exec_start="$(systemctl show "$HEALTH_SERVICE_NAME" --property=ExecStart --value 2>/dev/null)" || return 1
  systemd_exec_value_matches "$exec_start" "$INSTALL_PATH" "${INSTALL_PATH} _service_health" no
}

managed_health_timer_contract_is_exact() {
  local triggers

  triggers="$(systemctl show "$HEALTH_TIMER_NAME" --property=Triggers --value 2>/dev/null)" || return 1
  [ "$triggers" = "$HEALTH_SERVICE_NAME" ]
}

managed_unit_is_current() {
  [ "$#" -eq 1 ] || return 1
  local unit="$1" needs_reload

  managed_unit_has_owned_source "$unit" \
    && managed_unit_file_is_current "$unit" \
    || return 1
  needs_reload="$(systemctl show "$unit" --property=NeedDaemonReload --value 2>/dev/null)" \
    || return 1
  [ "$needs_reload" = no ] || return 1
  case "$unit" in
    "$SERVICE_NAME") managed_main_unit_contract_is_exact ;;
    "$HEALTH_SERVICE_NAME") managed_health_unit_contract_is_exact ;;
    "$HEALTH_TIMER_NAME") managed_health_timer_contract_is_exact ;;
    *) return 1 ;;
  esac
}

managed_main_unit_is_exact() {
  managed_unit_is_current "$SERVICE_NAME"
}

verify_installed_units() {
  managed_unit_is_current "$SERVICE_NAME" \
    && managed_unit_is_current "$HEALTH_SERVICE_NAME" \
    && managed_unit_is_current "$HEALTH_TIMER_NAME"
}

preflight_managed_units_ownership() {
  local unit path load_state

  for unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
    path="$(unit_path "$unit")" || return 1
    if { [ -e "$path" ] || [ -L "$path" ]; } && ! unit_is_ours "$path" "$unit"; then
      die "检测到不属于 oc-master 的同名单元 $unit；为避免停止或禁用 foreign unit，拒绝继续。"
      return 1
    fi
    if ! load_state="$(systemctl show "$unit" --property=LoadState --value 2>/dev/null)"; then
      die "无法核验 systemd 单元 $unit 的加载状态；为避免操作 foreign unit，拒绝继续。"
      return 1
    fi
    case "$load_state" in
      not-found) continue ;;
      loaded)
        if ! managed_unit_has_owned_source "$unit"; then
          die "systemd 单元 $unit 的实际来源不属于 oc-master；拒绝停止或禁用。"
          return 1
        fi
        ;;
      *)
        die "systemd 单元 $unit 的加载状态不可证明安全（${load_state:-空}）；拒绝停止或禁用。"
        return 1
        ;;
    esac
  done
}

preflight_managed_shortcut() {
  if [ "$SHORTCUT_PATH" != "$INSTALL_PATH" ] && { [ -e "$SHORTCUT_PATH" ] || [ -L "$SHORTCUT_PATH" ]; } && ! shortcut_is_ours; then
    die "快捷命令路径已被其他文件占用：$SHORTCUT_PATH；为避免覆盖，拒绝安装。"
    return 1
  fi
}

preflight_install_targets() {
  preflight_managed_shortcut || return 1
  preflight_managed_units_ownership
}

# shellcheck disable=SC2120 # 不接受参数，调用点与部署目标固定。
stage_managed_program() {
  [ "$#" -eq 0 ] || return 1
  local directory temporary
  directory="$(dirname -- "$INSTALL_PATH")"
  install -d -m 0755 -- "$directory" || return 1
  temporary="$(mktemp "${directory}/.${TAG}.program.XXXXXX")" || return 1
  if ! install -m 0755 -- "$SCRIPT_PATH" "$temporary" \
    || ! "${BASH}" -n -- "$temporary" \
    || ! [ -x "$temporary" ]; then
    rm -f -- "$temporary"
    return 1
  fi
  printf '%s\n' "$temporary"
}

# shellcheck disable=SC2120 # 不接受参数，调用点与部署目标固定。
stage_shortcut() {
  [ "$#" -eq 0 ] || return 1
  [ "$SHORTCUT_PATH" != "$INSTALL_PATH" ] || return 0
  shortcut_is_ours && return 0
  local directory temporary
  directory="$(dirname -- "$SHORTCUT_PATH")"
  install -d -m 0755 -- "$directory" || return 1
  temporary="$(mktemp "${directory}/.${TAG}.shortcut.XXXXXX")" || return 1
  rm -f -- "$temporary"
  if ! ln -s -- "$INSTALL_PATH" "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  printf '%s\n' "$temporary"
}

install_managed_copy() {
  local program_tmp shortcut_tmp="" program_backup="" had_program=0 program_installed=0 shortcut_installed=0 cleanup_failed=0
  preflight_managed_shortcut || return 1
  program_tmp="$(stage_managed_program)" || return 1
  shortcut_tmp="$(stage_shortcut)" || {
    rm -f -- "$program_tmp" || { log_err "安装暂存清理失败，保留文件：$program_tmp"; return 1; }
    return 1
  }

  if [ -e "$INSTALL_PATH" ] || [ -L "$INSTALL_PATH" ]; then
    had_program=1
    program_backup="${program_tmp}.backup"
    if ! mv -f -- "$INSTALL_PATH" "$program_backup"; then
      for temporary in "$program_tmp" "$shortcut_tmp"; do
        [ -n "$temporary" ] || continue
        if { [ -e "$temporary" ] || [ -L "$temporary" ]; } && ! rm -f -- "$temporary"; then
          cleanup_failed=1
        fi
      done
      [ "$cleanup_failed" -eq 0 ] || log_err "安装暂存清理失败，保留可诊断文件。"
      return 1
    fi
  fi
  if ! mv -f -- "$program_tmp" "$INSTALL_PATH"; then
    if ! restore_managed_copy_transaction "$had_program" "$program_installed" "$shortcut_installed" "$program_backup" "$program_tmp" "$shortcut_tmp"; then
      log_err "安装事务回滚未完成；请使用保留的备份恢复。"
    fi
    return 1
  fi
  program_installed=1
  if [ -n "$shortcut_tmp" ] && ! mv -f -- "$shortcut_tmp" "$SHORTCUT_PATH"; then
    if ! restore_managed_copy_transaction "$had_program" "$program_installed" "$shortcut_installed" "$program_backup" "$program_tmp" "$shortcut_tmp"; then
      log_err "安装事务回滚未完成；请使用保留的备份恢复。"
    fi
    return 1
  fi
  [ -n "$shortcut_tmp" ] && shortcut_installed=1
  if [ -n "$program_backup" ] && { [ -e "$program_backup" ] || [ -L "$program_backup" ]; } && ! rm -f -- "$program_backup"; then
    log_err "安装备份清理失败，保留旧程序备份：$program_backup"
    if ! restore_managed_copy_transaction "$had_program" "$program_installed" "$shortcut_installed" "$program_backup" "$program_tmp" "$shortcut_tmp"; then
      log_err "安装事务回滚未完成；请使用保留的备份恢复。"
    fi
    return 1
  fi
}

restore_managed_copy_transaction() {
  [ "$#" -eq 6 ] || return 1
  local had_program="$1" program_installed="$2" shortcut_installed="$3" program_backup="$4" program_tmp="$5" shortcut_tmp="$6" failed=0
  if [ "$program_installed" = 1 ] && { [ -e "$INSTALL_PATH" ] || [ -L "$INSTALL_PATH" ]; } && ! rm -f -- "$INSTALL_PATH"; then
    log_err "安装回滚失败，无法删除新程序：$INSTALL_PATH"
    failed=1
  fi
  if [ "$shortcut_installed" = 1 ] && { [ -e "$SHORTCUT_PATH" ] || [ -L "$SHORTCUT_PATH" ]; } && ! rm -f -- "$SHORTCUT_PATH"; then
    log_err "安装回滚失败，无法删除新快捷命令：$SHORTCUT_PATH"
    failed=1
  fi
  if [ "$had_program" = 1 ]; then
    if [ ! -e "$program_backup" ] && [ ! -L "$program_backup" ]; then
      log_err "安装回滚失败，旧程序备份丢失：$program_backup"
      failed=1
    elif [ -e "$INSTALL_PATH" ] || [ -L "$INSTALL_PATH" ]; then
      log_err "安装回滚失败，目标仍存在；保留旧程序备份：$program_backup"
      failed=1
    elif ! mv -f -- "$program_backup" "$INSTALL_PATH"; then
      log_err "安装回滚失败，保留旧程序备份：$program_backup"
      failed=1
    fi
  fi
  for temporary in "$program_tmp" "$shortcut_tmp"; do
    [ -n "$temporary" ] || continue
    if { [ -e "$temporary" ] || [ -L "$temporary" ]; } && ! rm -f -- "$temporary"; then
      log_err "安装回滚暂存清理失败，保留文件：$temporary"
      failed=1
    fi
  done
  [ "$failed" -eq 0 ] || log_err "安装事务回滚失败；已保留可恢复证据。"
  return "$failed"
}

service_state_allows_install() {
  local state load_state
  command -v systemctl >/dev/null 2>&1 || return 0
  state="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
  case "$state" in inactive|failed) return 0 ;; esac
  load_state="$(systemctl show "$SERVICE_NAME" --property=LoadState --value 2>/dev/null || true)"
  [ "$load_state" = not-found ] && return 0
  die "连接运行期间拒绝替换受控脚本；请先执行 sudo ocm stop。"
  return 1
}

render_unit_file() {
  [ "$#" -eq 1 ] || return 1
  local unit="$1"
  case "$unit" in
    "$SERVICE_NAME")
      cat <<EOF
# Managed by oc-master
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
RestartPreventExitStatus=78
RestartSec=15s
TimeoutStopSec=30s
KillMode=control-group
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
      ;;
    "$HEALTH_SERVICE_NAME")
      cat <<EOF
# Managed by oc-master
[Unit]
Description=OpenConnect Master data-plane health check
After=${SERVICE_NAME}

[Service]
Type=oneshot
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${INSTALL_PATH} _service_health
EOF
      ;;
    "$HEALTH_TIMER_NAME")
      cat <<EOF
# Managed by oc-master
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
      ;;
    *) return 1 ;;
  esac
}

write_unit_file() {
  [ "$#" -eq 2 ] || return 1
  local unit="$1" temporary="$2"

  if ! render_unit_file "$unit" > "$temporary"; then
    return 1
  fi
  chmod 0644 -- "$temporary" && [ -r "$temporary" ]
}

stage_unit_file() {
  [ "$#" -eq 1 ] || return 1
  local unit="$1" temporary
  install -d -m 0755 -- "$SYSTEMD_DIR" || return 1
  temporary="$(mktemp "${SYSTEMD_DIR}/.${unit}.${TAG}.XXXXXX")" || return 1
  if ! write_unit_file "$unit" "$temporary"; then
    if ! rm -f -- "$temporary"; then
      log_err "安装暂存清理失败，保留文件：$temporary"
    fi
    return 1
  fi
  printf '%s\n' "$temporary"
}

cleanup_install_stages() {
  local temporary failed=0

  for temporary in "$@"; do
    [ -n "$temporary" ] || continue
    if { [ -e "$temporary" ] || [ -L "$temporary" ]; } && ! rm -f -- "$temporary"; then
      log_err "安装暂存清理失败，保留文件：$temporary"
      failed=1
    fi
  done
  [ "$failed" -eq 0 ] || log_err "安装事务暂存失败；已保留可诊断文件。"
  return "$failed"
}

restore_install_transaction() {
  local index target backup stage failed=0 restored=0
  for ((index = ${#INSTALL_TX_TARGETS[@]} - 1; index >= 0; index--)); do
    target="${INSTALL_TX_TARGETS[index]}"
    backup="${INSTALL_TX_BACKUPS[index]:-}"
    stage="${INSTALL_TX_STAGES[index]:-}"
    restored=0
    if [ "${INSTALL_TX_INSTALLED[index]:-0}" = 1 ] && { [ -e "$target" ] || [ -L "$target" ]; } && ! rm -f -- "$target"; then
      log_err "安装回滚失败，无法删除新文件：$target"
      failed=1
    fi
    if [ "${INSTALL_TX_HAD_OLD[index]:-0}" = 1 ]; then
      if [ ! -e "$backup" ] && [ ! -L "$backup" ]; then
        log_err "安装回滚失败，旧文件备份丢失：$backup"
        failed=1
      elif [ -e "$target" ] || [ -L "$target" ]; then
        log_err "安装回滚失败，目标仍存在；保留旧文件备份：$backup"
        failed=1
      elif ! mv -f -- "$backup" "$target"; then
        log_err "安装回滚失败，保留旧文件备份：$backup"
        failed=1
      else
        restored=1
      fi
    fi
    if [ -n "$stage" ] && { [ -e "$stage" ] || [ -L "$stage" ]; } && ! rm -f -- "$stage"; then
      log_err "安装回滚暂存清理失败，保留文件：$stage"
      failed=1
    fi
    if [ -n "$backup" ] && { [ -e "$backup" ] || [ -L "$backup" ]; } && [ "$restored" -eq 1 ]; then
      log_err "安装回滚失败，旧文件备份仍存在：$backup"
      failed=1
    fi
  done
  if ! systemctl daemon-reload; then
    log_err "安装回滚失败，systemd daemon-reload 未成功；请在保留的备份旁手动恢复后重试。"
    failed=1
  fi
  [ "$failed" -eq 0 ] || log_err "安装事务回滚失败；已保留可恢复证据。"
  return "$failed"
}

cleanup_committed_install_backups() {
  local index backup failed=0

  for ((index = 0; index < ${#INSTALL_TX_BACKUPS[@]}; index++)); do
    backup="${INSTALL_TX_BACKUPS[index]:-}"
    [ -n "$backup" ] || continue
    if [ -e "$backup" ] || [ -L "$backup" ]; then
      if ! rm -f -- "$backup" || [ -e "$backup" ] || [ -L "$backup" ]; then
        log_err "安装备份清理失败，保留文件：$backup"
        failed=1
      fi
    fi
  done
  if [ "$failed" -ne 0 ]; then
    log_err "安装已提交并验证，但备份清理未完成；不会执行不完整回滚。"
  fi
  return "$failed"
}

install_self_and_units() {
  local unit index target stage
  local -a INSTALL_TX_TARGETS INSTALL_TX_STAGES INSTALL_TX_BACKUPS INSTALL_TX_HAD_OLD INSTALL_TX_INSTALLED
  preflight_install_targets || return 1
  ensure_dirs || return 1

  INSTALL_TX_TARGETS=( "$INSTALL_PATH" "$(unit_path "$SERVICE_NAME")" "$(unit_path "$HEALTH_SERVICE_NAME")" "$(unit_path "$HEALTH_TIMER_NAME")" )
  stage="$(stage_managed_program)" || return 1
  INSTALL_TX_STAGES+=( "$stage" )
  for unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
    if ! stage="$(stage_unit_file "$unit")"; then
      cleanup_install_stages "${INSTALL_TX_STAGES[@]}" || true
      return 1
    fi
    INSTALL_TX_STAGES+=( "$stage" )
  done
  if [ "$SHORTCUT_PATH" != "$INSTALL_PATH" ] && ! shortcut_is_ours; then
    INSTALL_TX_TARGETS+=( "$SHORTCUT_PATH" )
    if ! stage="$(stage_shortcut)"; then
      cleanup_install_stages "${INSTALL_TX_STAGES[@]}" || true
      return 1
    fi
    INSTALL_TX_STAGES+=( "$stage" )
  fi
  if ! preflight_install_targets; then
    cleanup_install_stages "${INSTALL_TX_STAGES[@]}" || true
    return 1
  fi
  for ((index = 0; index < ${#INSTALL_TX_TARGETS[@]}; index++)); do
    INSTALL_TX_BACKUPS[index]="${INSTALL_TX_STAGES[index]}.backup"
    INSTALL_TX_HAD_OLD[index]=0
    INSTALL_TX_INSTALLED[index]=0
    target="${INSTALL_TX_TARGETS[index]}"
    if [ -e "$target" ] || [ -L "$target" ]; then
      INSTALL_TX_HAD_OLD[index]=1
      if ! mv -f -- "$target" "${INSTALL_TX_BACKUPS[index]}"; then
        restore_install_transaction || log_err "安装事务回滚未完成；请使用保留的备份恢复。"
        return 1
      fi
    fi
    if ! mv -f -- "${INSTALL_TX_STAGES[index]}" "$target"; then
      restore_install_transaction || log_err "安装事务回滚未完成；请使用保留的备份恢复。"
      return 1
    fi
    INSTALL_TX_INSTALLED[index]=1
  done
  if ! systemctl daemon-reload || ! verify_installed_units; then
    restore_install_transaction || log_err "安装事务回滚未完成；请使用保留的备份恢复。"
    return 1
  fi
  cleanup_committed_install_backups
}

remove_managed_shortcut() {
  [ "$SHORTCUT_PATH" != "$INSTALL_PATH" ] || return 0
  if shortcut_is_ours; then
    rm -f -- "$SHORTCUT_PATH"
  elif [ -e "$SHORTCUT_PATH" ] || [ -L "$SHORTCUT_PATH" ]; then
    log_warn "保留非本项目拥有的快捷命令：$SHORTCUT_PATH"
  fi
}

remove_managed_units() {
  local unit path
  for unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
    path="$(unit_path "$unit")" || return 1
    if unit_is_ours "$path" "$unit"; then
      if ! rm -f -- "$path" || [ -e "$path" ] || [ -L "$path" ]; then
        log_err "删除 systemd 单元失败，保留其余安装和恢复证据：$path"
        return 1
      fi
    elif [ -e "$path" ] || [ -L "$path" ]; then
      log_warn "保留非本项目拥有的 systemd 单元：$path"
    fi
  done
}

install_command() {
  service_state_allows_install || return 1
  install_managed_copy || return 1
  log "快捷命令已安装：sudo ocm"
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

valid_ipv4_address() {
  local address="${1:-}" octet
  local -a octets=()

  [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS='.' read -r -a octets <<< "$address"
  [ "${#octets[@]}" -eq 4 ] || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] && [ "$octet" -le 255 ] || return 1
  done
}

valid_ipv6_address() {
  local address="${1:-}" prefix suffix part group compressed=0 group_count=0
  local -a groups=()

  [[ "$address" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "$address" == *:* ]] || return 1
  [[ "$address" != *:::* ]] || return 1
  if [[ "$address" == *::* ]]; then
    compressed=1
    prefix="${address%%::*}"
    suffix="${address#*::}"
    [[ "$suffix" != *::* ]] || return 1
    for part in "$prefix" "$suffix"; do
      [ -z "$part" ] && continue
      IFS=':' read -r -a groups <<< "$part"
      for group in "${groups[@]}"; do
        [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        group_count=$((group_count + 1))
      done
    done
    [ "$group_count" -lt 8 ]
    return
  fi

  IFS=':' read -r -a groups <<< "$address"
  [ "${#groups[@]}" -eq 8 ] || return 1
  for group in "${groups[@]}"; do
    [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
  done
  [ "$compressed" -eq 0 ]
}

valid_route_plan_address() {
  [ "$#" -eq 2 ] || return 1
  case "$1" in
    -4) valid_ipv4_address "$2" ;;
    -6) valid_ipv6_address "$2" ;;
    *) return 1 ;;
  esac
}

route_default_device() {
  [ "$#" -eq 1 ] || return 1
  local route_line="$1" token device="" dev_count=0
  local -a route_tokens=()

  [ -n "$route_line" ] && [[ "$route_line" != *$'\r'* ]] && [[ "$route_line" != *$'\n'* ]] || return 1
  read -r -a route_tokens <<< "$route_line"
  [ "${#route_tokens[@]}" -gt 1 ] && [ "${route_tokens[0]}" = default ] || return 1
  for ((token = 0; token < ${#route_tokens[@]}; token++)); do
    case "${route_tokens[$token]}" in
      nexthop|blackhole|unreachable|prohibit) return 1 ;;
      dev)
        token=$((token + 1))
        [ "$token" -lt "${#route_tokens[@]}" ] || return 1
        device="${route_tokens[$token]}"
        dev_count=$((dev_count + 1))
        ;;
    esac
  done
  [ "$dev_count" -eq 1 ] && [[ "$device" =~ ^[[:alnum:]_.:@-]+$ ]] || return 1
  printf '%s\n' "$device"
}

policy_rule_output_is_parseable() {
  local rules="$1" line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    [[ "$line" =~ ^[[:space:]]*[0-9]+:[[:space:]]+ ]] || return 1
  done <<< "$rules"
}

policy_rule_output_is_safe_for_preflight() {
  local rules="$1" line

  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    [[ "$line" =~ ^[[:space:]]*(0:[[:space:]]+from[[:space:]]+all[[:space:]]+lookup[[:space:]]+local|32766:[[:space:]]+from[[:space:]]+all[[:space:]]+lookup[[:space:]]+main|32767:[[:space:]]+from[[:space:]]+all[[:space:]]+lookup[[:space:]]+default)[[:space:]]*$ ]] \
      || return 1
  done <<< "$rules"
}

route_resources_are_available() {
  local rules4 rules6 routes4 routes6 links
  rules4="$(ip -4 rule show 2>/dev/null)" || return 1
  rules6="$(ip -6 rule show 2>/dev/null)" || return 1
  policy_rule_output_is_safe_for_preflight "$rules4" \
    && policy_rule_output_is_safe_for_preflight "$rules6" || return 1
  routes4="$(read_route_table_or_empty -4 "$RETURN4_TABLE")" || return 1
  routes6="$(read_route_table_or_empty -6 "$RETURN6_TABLE")" || return 1
  links="$(ip -o link show 2>/dev/null)" || return 1

  ! grep -Eq "^[[:space:]]*${RETURN4_PRIORITY}:" <<< "$rules4" || return 1
  ! grep -Eq "^[[:space:]]*${RETURN6_PRIORITY}:" <<< "$rules6" || return 1
  ! grep -Eq "lookup ${RETURN4_TABLE}([[:space:]]|$)" <<< "$rules4" || return 1
  ! grep -Eq "lookup ${RETURN6_TABLE}([[:space:]]|$)" <<< "$rules6" || return 1
  [ -z "$routes4" ] && [ -z "$routes6" ] || return 1
  ! grep -Eq "^[[:space:]]*[0-9]+:[[:space:]]+${VPN_INTERFACE}(:|@)" <<< "$links"
}

collect_route_plan_addresses() {
  [ "$#" -eq 3 ] || return 1
  local family="$1" expected_device="$2"
  local -n output_addresses="$3"
  local address_output line index device address_family cidr address normalized_device
  local -a collected_addresses=()
  local -A seen_addresses=()

  address_output="$(ip "$family" -o addr show scope global 2>/dev/null)" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    read -r index device address_family cidr _ <<< "$line"
    [[ "$index" =~ ^[0-9]+:$ ]] && [ -n "$device" ] && [ -n "$cidr" ] || return 1
    case "$family:$address_family" in -4:inet|-6:inet6) ;; *) return 1 ;; esac
    normalized_device="${device%%@*}"
    [ "$normalized_device" = "${expected_device%%@*}" ] || return 1
    address="${cidr%/*}"
    [ "$address" != "$cidr" ] && valid_route_plan_address "$family" "$address" || return 1
    if [ -z "${seen_addresses[$address]+x}" ]; then
      seen_addresses[$address]=1
      collected_addresses+=("$address")
    fi
  done <<< "$address_output"
  # shellcheck disable=SC2034  # nameref 将结果写回调用方数组。
  output_addresses=("${collected_addresses[@]}")
}

route_plan_values_are_valid() {
  local run_id="$1" default4="$2" dev4="$3" default6="$4" dev6="$5"
  local address parsed_device
  shift 5

  valid_uuid "$run_id" && [ -n "$default4" ] && [ -n "$dev4" ] || return 1
  parsed_device="$(route_default_device "$default4")" || return 1
  [ "$parsed_device" = "$dev4" ] && [ "$dev4" != "$VPN_INTERFACE" ] || return 1
  [ "${#ROUTE_PLAN_RETURN4_ADDRESSES[@]}" -gt 0 ] || return 1
  for address in "${ROUTE_PLAN_RETURN4_ADDRESSES[@]}"; do valid_ipv4_address "$address" || return 1; done
  if [ -n "$default6" ] || [ -n "$dev6" ]; then
    [ -n "$default6" ] && [ -n "$dev6" ] || return 1
    parsed_device="$(route_default_device "$default6")" || return 1
    [ "$parsed_device" = "$dev6" ] && [ "$dev6" != "$VPN_INTERFACE" ] || return 1
  elif [ "${#ROUTE_PLAN_RETURN6_ADDRESSES[@]}" -gt 0 ]; then
    return 1
  fi
  for address in "${ROUTE_PLAN_RETURN6_ADDRESSES[@]}"; do valid_ipv6_address "$address" || return 1; done
  [ "$#" -eq 0 ]
}

build_route_plan() {
  [ "$#" -eq 1 ] && valid_uuid "$1" || return 1
  local expected_run_id="$1" runtime_mode runtime_phase runtime_desired
  local default_output ipv6_address_output line device="" default4="" default6="" count=0
  local -a return4_addresses=() return6_addresses=()

  acquire_state_lock || return 1
  if ! load_runtime_state || [ "$RUN_ID" != "$expected_run_id" ]; then
    release_state_lock
    return 1
  fi
  runtime_mode="$MODE"; runtime_phase="$PHASE"; runtime_desired="$DESIRED_ACTIVE"
  release_state_lock
  [ "$runtime_mode" = global ] && [ "$runtime_phase" = PREPARING ] && [ "$runtime_desired" = 1 ] || return 1
  route_resources_are_available || return 1

  default_output="$(ip -4 route show default 2>/dev/null)" || return 1
  count=0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    case "$line" in
      blackhole\ default*|unreachable\ default*|prohibit\ default*) return 1 ;;
    esac
    device="$(route_default_device "$line")" || return 1
    [ "$device" = "$VPN_INTERFACE" ] && continue
    count=$((count + 1))
    [ "$count" -eq 1 ] || return 1
    default4="$line"
    ROUTE_PLAN_BUILD_DEV4="$device"
  done <<< "$default_output"
  [ "$count" -eq 1 ] || return 1
  collect_route_plan_addresses -4 "$ROUTE_PLAN_BUILD_DEV4" return4_addresses || return 1
  [ "${#return4_addresses[@]}" -gt 0 ] || return 1

  default_output="$(ip -6 route show default 2>/dev/null)" || return 1
  count=0
  ROUTE_PLAN_BUILD_DEV6=""
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    case "$line" in
      blackhole\ default*|unreachable\ default*|prohibit\ default*) return 1 ;;
    esac
    device="$(route_default_device "$line")" || return 1
    [ "$device" = "$VPN_INTERFACE" ] && continue
    count=$((count + 1))
    [ "$count" -eq 1 ] || return 1
    default6="$line"
    ROUTE_PLAN_BUILD_DEV6="$device"
  done <<< "$default_output"
  if [ "$count" -eq 1 ]; then
    collect_route_plan_addresses -6 "$ROUTE_PLAN_BUILD_DEV6" return6_addresses || return 1
  else
    # 没有 IPv6 default 时只接受已确认不存在 global IPv6 地址的主机。
    ipv6_address_output="$(ip -6 -o addr show scope global 2>/dev/null)" || return 1
    [ -z "$ipv6_address_output" ] || return 1
    return6_addresses=()
  fi

  ROUTE_PLAN_BUILD_RUN_ID="$expected_run_id"
  ROUTE_PLAN_BUILD_DEFAULT4="$default4"
  ROUTE_PLAN_BUILD_DEFAULT6="$default6"
  ROUTE_PLAN_BUILD_RETURN4_ADDRESSES=("${return4_addresses[@]}")
  ROUTE_PLAN_BUILD_RETURN6_ADDRESSES=("${return6_addresses[@]}")
}

write_route_plan() {
  [ "$#" -eq 1 ] && valid_uuid "$1" || return 1
  local expected_run_id="$1" address
  [ "${ROUTE_PLAN_BUILD_RUN_ID:-}" = "$expected_run_id" ] || return 1
  ROUTE_PLAN_RETURN4_ADDRESSES=("${ROUTE_PLAN_BUILD_RETURN4_ADDRESSES[@]}")
  ROUTE_PLAN_RETURN6_ADDRESSES=("${ROUTE_PLAN_BUILD_RETURN6_ADDRESSES[@]}")
  route_plan_values_are_valid "$expected_run_id" "$ROUTE_PLAN_BUILD_DEFAULT4" "$ROUTE_PLAN_BUILD_DEV4" \
    "$ROUTE_PLAN_BUILD_DEFAULT6" "$ROUTE_PLAN_BUILD_DEV6" || return 1
  ensure_dirs
  {
    printf '%s\n' 'FORMAT_VERSION=1' "RUN_ID=$expected_run_id" \
      "DEFAULT4=$ROUTE_PLAN_BUILD_DEFAULT4" "DEV4=$ROUTE_PLAN_BUILD_DEV4"
    for address in "${ROUTE_PLAN_BUILD_RETURN4_ADDRESSES[@]}"; do printf 'RETURN4_ADDRESS=%s\n' "$address"; done
    printf '%s\n' "DEFAULT6=$ROUTE_PLAN_BUILD_DEFAULT6" "DEV6=$ROUTE_PLAN_BUILD_DEV6"
    for address in "${ROUTE_PLAN_BUILD_RETURN6_ADDRESSES[@]}"; do printf 'RETURN6_ADDRESS=%s\n' "$address"; done
  } | atomic_replace_from_stdin "$ROUTE_PLAN_FILE" 0600 || return 1
  load_route_plan "$expected_run_id"
}

load_route_plan() {
  [ "$#" -eq 1 ] && valid_uuid "$1" || return 1
  local expected_run_id="$1" line key value address
  local parsed_format="" parsed_run_id="" parsed_default4="" parsed_dev4="" parsed_default6="" parsed_dev6=""
  local seen_format=0 seen_run_id=0 seen_default4=0 seen_dev4=0 seen_default6=0 seen_dev6=0
  local -a parsed_return4=() parsed_return6=()
  local -A seen_return4=() seen_return6=()

  [ -f "$ROUTE_PLAN_FILE" ] && [ ! -L "$ROUTE_PLAN_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" == *=* ]] || return 1
    IFS='=' read -r key value <<< "$line"
    case "$key" in
      FORMAT_VERSION) [ "$seen_format" -eq 0 ] || return 1; seen_format=1; parsed_format="$value" ;;
      RUN_ID) [ "$seen_run_id" -eq 0 ] || return 1; seen_run_id=1; parsed_run_id="$value" ;;
      DEFAULT4) [ "$seen_default4" -eq 0 ] || return 1; seen_default4=1; parsed_default4="$value" ;;
      DEV4) [ "$seen_dev4" -eq 0 ] || return 1; seen_dev4=1; parsed_dev4="$value" ;;
      DEFAULT6) [ "$seen_default6" -eq 0 ] || return 1; seen_default6=1; parsed_default6="$value" ;;
      DEV6) [ "$seen_dev6" -eq 0 ] || return 1; seen_dev6=1; parsed_dev6="$value" ;;
      RETURN4_ADDRESS)
        valid_ipv4_address "$value" || return 1
        if [ -z "${seen_return4[$value]+x}" ]; then seen_return4[$value]=1; parsed_return4+=("$value"); fi
        ;;
      RETURN6_ADDRESS)
        valid_ipv6_address "$value" || return 1
        if [ -z "${seen_return6[$value]+x}" ]; then seen_return6[$value]=1; parsed_return6+=("$value"); fi
        ;;
      *) return 1 ;;
    esac
  done < "$ROUTE_PLAN_FILE"
  [ "$seen_format" -eq 1 ] && [ "$seen_run_id" -eq 1 ] && [ "$seen_default4" -eq 1 ] \
    && [ "$seen_dev4" -eq 1 ] && [ "$seen_default6" -eq 1 ] && [ "$seen_dev6" -eq 1 ] || return 1
  [ "$parsed_format" = 1 ] && [ "$parsed_run_id" = "$expected_run_id" ] || return 1

  ROUTE_PLAN_RETURN4_ADDRESSES=("${parsed_return4[@]}")
  ROUTE_PLAN_RETURN6_ADDRESSES=("${parsed_return6[@]}")
  route_plan_values_are_valid "$parsed_run_id" "$parsed_default4" "$parsed_dev4" "$parsed_default6" "$parsed_dev6" || return 1
  ROUTE_PLAN_RUN_ID="$parsed_run_id"
  ROUTE_PLAN_DEFAULT4="$parsed_default4"
  ROUTE_PLAN_DEV4="$parsed_dev4"
  ROUTE_PLAN_DEFAULT6="$parsed_default6"
  ROUTE_PLAN_DEV6="$parsed_dev6"
}

validate_route_plan_against_snapshot() {
  [ "$#" -eq 1 ] && valid_uuid "$1" || return 1
  local expected_run_id="$1" valid=1

  load_route_plan "$expected_run_id" || return 1
  acquire_state_lock || return 1
  if load_runtime_state && [ "$RUN_ID" = "$expected_run_id" ] && [ "$MODE" = global ]; then valid=0; fi
  release_state_lock
  return "$valid"
}

write_route_owner_from_loaded_plan() {
  [ "${ROUTE_PLAN_RUN_ID:-}" = "${1:-}" ] || return 1
  printf '%s\n' \
    "DEFAULT4=$ROUTE_PLAN_DEFAULT4" \
    "DEFAULT6=$ROUTE_PLAN_DEFAULT6" \
    | atomic_replace_from_stdin "$ROUTE_OWNER_FILE" 0600
}

route_get_uses_device() {
  [ "$#" -eq 4 ] || return 1
  local family="$1" destination="$2" source_address="$3" expected_device="$4"
  local route_result line token device="" dev_count=0
  local -a route_tokens=()

  route_result="$(ip "$family" route get "$destination" from "$source_address" 2>/dev/null)" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    read -r -a route_tokens <<< "$line"
    for ((token = 0; token < ${#route_tokens[@]}; token++)); do
      [ "${route_tokens[$token]}" = dev ] || continue
      token=$((token + 1))
      [ "$token" -lt "${#route_tokens[@]}" ] || return 1
      device="${route_tokens[$token]}"
      dev_count=$((dev_count + 1))
    done
  done <<< "$route_result"
  [ "$dev_count" -eq 1 ] && [ "$device" = "$expected_device" ]
}

apply_route_plan() {
  [ "$#" -eq 1 ] && valid_uuid "$1" || return 1
  local expected_run_id="$1" address
  local -a route_args4=() route_args6=()

  validate_route_plan_against_snapshot "$expected_run_id" || return 1
  state_allows_service_run "$expected_run_id" || return 1
  route_resources_are_available || return 1
  write_route_owner_from_loaded_plan "$expected_run_id" || return 1

  read -r -a route_args4 <<< "$ROUTE_PLAN_DEFAULT4"
  ip -4 route replace table "$RETURN4_TABLE" "${route_args4[@]}" || return 1
  if [ -n "$ROUTE_PLAN_DEFAULT6" ]; then
    read -r -a route_args6 <<< "$ROUTE_PLAN_DEFAULT6"
    ip -6 route replace table "$RETURN6_TABLE" "${route_args6[@]}" || return 1
  fi

  for address in "${ROUTE_PLAN_RETURN4_ADDRESSES[@]}"; do
    ip -4 rule add priority "$RETURN4_PRIORITY" from "${address}/32" lookup "$RETURN4_TABLE" || return 1
  done
  for address in "${ROUTE_PLAN_RETURN6_ADDRESSES[@]}"; do
    ip -6 rule add priority "$RETURN6_PRIORITY" from "${address}/128" lookup "$RETURN6_TABLE" || return 1
  done
  for address in "${ROUTE_PLAN_RETURN4_ADDRESSES[@]}"; do
    route_get_uses_device -4 1.1.1.1 "$address" "$ROUTE_PLAN_DEV4" || return 1
  done
  for address in "${ROUTE_PLAN_RETURN6_ADDRESSES[@]}"; do
    route_get_uses_device -6 2606:4700:4700::1111 "$address" "$ROUTE_PLAN_DEV6" || return 1
  done
}

route_state_conflicts() {
  ! route_resources_are_available
}

read_route_table_or_empty() {
  local family="$1" table="$2" output=""
  if output="$(LC_ALL=C ip "$family" route show table "$table" 2>&1)"; then
    printf '%s' "$output"
    return 0
  fi
  case "$output" in
    *'FIB table does not exist.'*) return 0 ;;
    *) return 1 ;;
  esac
}

first_usable_non_vpn_default() {
  awk -v vpn="$VPN_INTERFACE" '
    $1 == "default" && $0 !~ ("dev " vpn "([[:space:]]|$)") {
      for (i = 1; i < NF; i++) {
        if ($i == "dev" && $(i + 1) != "") {
          print
          exit
        }
      }
    }
  '
}

return_route_state_is_clean() {
  local rules4 rules6 routes4 routes6 links
  rules4="$(ip -4 rule show 2>/dev/null)" || return 1
  rules6="$(ip -6 rule show 2>/dev/null)" || return 1
  routes4="$(read_route_table_or_empty -4 "$RETURN4_TABLE")" || return 1
  routes6="$(read_route_table_or_empty -6 "$RETURN6_TABLE")" || return 1
  links="$(ip -o link show 2>/dev/null)" || return 1

  ! grep -Eq "^[[:space:]]*${RETURN4_PRIORITY}:" <<< "$rules4" || return 1
  ! grep -Eq "^[[:space:]]*${RETURN6_PRIORITY}:" <<< "$rules6" || return 1
  ! grep -Eq "lookup ${RETURN4_TABLE}([[:space:]]|$)" <<< "$rules4" || return 1
  ! grep -Eq "lookup ${RETURN6_TABLE}([[:space:]]|$)" <<< "$rules6" || return 1
  [ -z "$routes4" ] || return 1
  [ -z "$routes6" ] || return 1
  ! grep -Eq "^[[:space:]]*[0-9]+:[[:space:]]+${VPN_INTERFACE}(:|@)" <<< "$links" || return 1
}

exact_route_rule_exists() {
  [ "$#" -eq 5 ] || return 2
  local family="$1" priority="$2" address="$3" prefix="$4" table="$5" rules
  rules="$(ip "$family" rule show 2>/dev/null)" || return 2
  awk -v priority="$priority" -v address="$address" -v cidr="${address}/${prefix}" -v table="$table" '
    $1 == priority ":" {
      from_matches=0; table_matches=0
      for (i = 2; i <= NF; i++) {
        if ($i == "from" && (($(i + 1) == address) || ($(i + 1) == cidr))) from_matches=1
        if ($i == "lookup" && $(i + 1) == table) table_matches=1
      }
      if (from_matches && table_matches) found=1
    }
    END { exit(found ? 0 : 1) }
  ' <<< "$rules"
}

legacy_route_rule_exists() {
  [ "$#" -eq 3 ] || return 2
  local family="$1" priority="$2" table="$3" rules
  rules="$(ip "$family" rule show 2>/dev/null)" || return 2
  policy_rule_output_is_parseable "$rules" || return 2
  awk -v priority="$priority" -v table="$table" '
    $1 == priority ":" {
      for (i = 2; i <= NF; i++) {
        if ($i == "lookup" && $(i + 1) == table) found=1
      }
    }
    END { exit(found ? 0 : 1) }
  ' <<< "$rules"
}

delete_legacy_route_rules() {
  [ "$#" -eq 3 ] || return 1
  local family="$1" priority="$2" table="$3" probe_status=0 _

  for _ in {1..32}; do
    if legacy_route_rule_exists "$family" "$priority" "$table"; then
      :
    else
      probe_status=$?
      [ "$probe_status" -eq 1 ] && return 0
      return 1
    fi
    if ip "$family" rule del priority "$priority" lookup "$table" 2>/dev/null; then
      continue
    fi
    if legacy_route_rule_exists "$family" "$priority" "$table"; then
      return 1
    else
      probe_status=$?
      [ "$probe_status" -eq 1 ] || return 1
    fi
  done

  if legacy_route_rule_exists "$family" "$priority" "$table"; then
    return 1
  else
    probe_status=$?
    [ "$probe_status" -eq 1 ]
  fi
}

delete_exact_route_rule() {
  [ "$#" -eq 5 ] || return 1
  local family="$1" priority="$2" address="$3" prefix="$4" table="$5"
  if ip "$family" rule del priority "$priority" from "${address}/${prefix}" lookup "$table"; then
    return 0
  fi
  if exact_route_rule_exists "$family" "$priority" "$address" "$prefix" "$table"; then
    return 1
  else
    [ "$?" -eq 1 ]
  fi
}

flush_managed_route_table() {
  [ "$#" -eq 2 ] || return 1
  local family="$1" table="$2" remaining
  if ip "$family" route flush table "$table" 2>/dev/null; then return 0; fi
  remaining="$(read_route_table_or_empty "$family" "$table")" || return 1
  [ -z "$remaining" ]
}

delete_managed_vpn_link() {
  local links
  links="$(ip -o link show 2>/dev/null)" || return 1
  if ! grep -Eq "^[[:space:]]*[0-9]+:[[:space:]]+${VPN_INTERFACE}(:|@)" <<< "$links"; then return 0; fi
  if ip link del dev "$VPN_INTERFACE" 2>/dev/null; then return 0; fi
  links="$(ip -o link show 2>/dev/null)" || return 1
  ! grep -Eq "^[[:space:]]*[0-9]+:[[:space:]]+${VPN_INTERFACE}(:|@)" <<< "$links"
}

ensure_saved_default_if_needed() {
  [ "$#" -eq 2 ] || return 1
  local family="$1" saved_default="$2" default_routes current_default
  local -a restore_args=()
  [ -n "$saved_default" ] || return 0

  default_routes="$(ip "$family" route show default 2>/dev/null)" || return 1
  current_default="$(first_usable_non_vpn_default <<< "$default_routes")"
  if [ -z "$current_default" ]; then
    read -r -a restore_args <<< "$saved_default"
    if ! ip "$family" route replace "${restore_args[@]}" 2>/dev/null; then
      default_routes="$(ip "$family" route show default 2>/dev/null)" || return 1
      current_default="$(first_usable_non_vpn_default <<< "$default_routes")"
      [ -n "$current_default" ] || return 1
      return 0
    fi
  fi
  default_routes="$(ip "$family" route show default 2>/dev/null)" || return 1
  current_default="$(first_usable_non_vpn_default <<< "$default_routes")"
  [ -n "$current_default" ]
}

loaded_route_plan_baseline_is_available() {
  local default_routes current_default address
  default_routes="$(ip -4 route show default 2>/dev/null)" || return 1
  current_default="$(first_usable_non_vpn_default <<< "$default_routes")"
  [ -n "$current_default" ] || return 1
  if [ -n "$ROUTE_PLAN_DEFAULT6" ]; then
    default_routes="$(ip -6 route show default 2>/dev/null)" || return 1
    current_default="$(first_usable_non_vpn_default <<< "$default_routes")"
    [ -n "$current_default" ] || return 1
  fi
  for address in "${ROUTE_PLAN_RETURN4_ADDRESSES[@]}"; do
    route_get_uses_device -4 1.1.1.1 "$address" "$ROUTE_PLAN_DEV4" || return 1
  done
  for address in "${ROUTE_PLAN_RETURN6_ADDRESSES[@]}"; do
    route_get_uses_device -6 2606:4700:4700::1111 "$address" "$ROUTE_PLAN_DEV6" || return 1
  done
}

remove_route_cleanup_evidence() {
  [ "$#" -eq 1 ] || return 1
  case "$1" in 0|1) ;; *) return 1 ;; esac

  rm -f -- "$ROUTE_OWNER_FILE" || return 1
  [ ! -e "$ROUTE_OWNER_FILE" ] && [ ! -L "$ROUTE_OWNER_FILE" ] || return 1
  [ "$1" = 1 ] && return 0
  rm -f -- "$ROUTE_PLAN_FILE" || return 1
  [ ! -e "$ROUTE_PLAN_FILE" ] && [ ! -L "$ROUTE_PLAN_FILE" ]
}

cleanup_route_plan() {
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] && valid_uuid "$1" || return 1
  local expected_run_id="$1" retain_plan="${2:-0}" address

  case "$retain_plan" in 0|1) ;; *) return 1 ;; esac

  if [ ! -e "$ROUTE_PLAN_FILE" ] && [ ! -L "$ROUTE_PLAN_FILE" ]; then
    cleanup_legacy_return_routes
    return
  fi
  validate_route_plan_against_snapshot "$expected_run_id" || return 1
  if [ ! -e "$ROUTE_OWNER_FILE" ] && [ ! -L "$ROUTE_OWNER_FILE" ]; then
    route_resources_are_available || return 1
    loaded_route_plan_baseline_is_available || return 1
    remove_route_cleanup_evidence "$retain_plan"
    return $?
  fi
  [ -f "$ROUTE_OWNER_FILE" ] && [ ! -L "$ROUTE_OWNER_FILE" ] || return 1

  for address in "${ROUTE_PLAN_RETURN4_ADDRESSES[@]}"; do
    delete_exact_route_rule -4 "$RETURN4_PRIORITY" "$address" 32 "$RETURN4_TABLE" || return 1
  done
  for address in "${ROUTE_PLAN_RETURN6_ADDRESSES[@]}"; do
    delete_exact_route_rule -6 "$RETURN6_PRIORITY" "$address" 128 "$RETURN6_TABLE" || return 1
  done
  flush_managed_route_table -4 "$RETURN4_TABLE" || return 1
  flush_managed_route_table -6 "$RETURN6_TABLE" || return 1
  delete_managed_vpn_link || return 1
  ensure_saved_default_if_needed -4 "$ROUTE_PLAN_DEFAULT4" || return 1
  ensure_saved_default_if_needed -6 "$ROUTE_PLAN_DEFAULT6" || return 1
  return_route_state_is_clean || return 1
  for address in "${ROUTE_PLAN_RETURN4_ADDRESSES[@]}"; do
    route_get_uses_device -4 1.1.1.1 "$address" "$ROUTE_PLAN_DEV4" || return 1
  done
  for address in "${ROUTE_PLAN_RETURN6_ADDRESSES[@]}"; do
    route_get_uses_device -6 2606:4700:4700::1111 "$address" "$ROUTE_PLAN_DEV6" || return 1
  done
  remove_route_cleanup_evidence "$retain_plan"
}

cleanup_legacy_return_routes() {
  if [ ! -e "$ROUTE_OWNER_FILE" ] && [ ! -L "$ROUTE_OWNER_FILE" ]; then return 0; fi
  [ -f "$ROUTE_OWNER_FILE" ] && [ ! -L "$ROUTE_OWNER_FILE" ] \
    || { log_err "旧版路由所有权证据不是普通文件；拒绝修改网络。"; return 1; }
  local saved_default4="" saved_default6="" current_default="" default_routes=""
  saved_default4="$(sed -n 's/^DEFAULT4=//p' "$ROUTE_OWNER_FILE" | tail -n 1)"
  saved_default6="$(sed -n 's/^DEFAULT6=//p' "$ROUTE_OWNER_FILE" | tail -n 1)"
  [ -n "$saved_default4" ] || { log_err "路由所有权文件缺少原 IPv4 默认路由；为避免断开入站，拒绝自动清理。"; return 1; }
  delete_legacy_route_rules -4 "$RETURN4_PRIORITY" "$RETURN4_TABLE" \
    || { log_err "无法删除旧版 IPv4 回程规则，保留路由所有权标记。"; return 1; }
  delete_legacy_route_rules -6 "$RETURN6_PRIORITY" "$RETURN6_TABLE" \
    || { log_err "无法删除旧版 IPv6 回程规则，保留路由所有权标记。"; return 1; }
  flush_managed_route_table -4 "$RETURN4_TABLE" \
    || { log_err "无法清空旧版 IPv4 回程表，保留路由所有权标记。"; return 1; }
  flush_managed_route_table -6 "$RETURN6_TABLE" \
    || { log_err "无法清空旧版 IPv6 回程表，保留路由所有权标记。"; return 1; }
  delete_managed_vpn_link \
    || { log_err "无法删除旧版 $VPN_INTERFACE 接口，保留路由所有权标记。"; return 1; }

  default_routes="$(ip -4 route show default 2>/dev/null)" || { log_err "无法读取 IPv4 默认路由，保留路由所有权标记。"; return 1; }
  current_default="$(first_usable_non_vpn_default <<< "$default_routes")"
  if [ -z "$current_default" ] && [ -n "$saved_default4" ]; then
    ensure_saved_default_if_needed -4 "$saved_default4" \
      || { log_err "IPv4 默认路由未恢复，保留路由所有权标记。"; return 1; }
  fi
  default_routes="$(ip -6 route show default 2>/dev/null)" || { log_err "无法读取 IPv6 默认路由，保留路由所有权标记。"; return 1; }
  current_default="$(first_usable_non_vpn_default <<< "$default_routes")"
  if [ -z "$current_default" ] && [ -n "$saved_default6" ]; then
    ensure_saved_default_if_needed -6 "$saved_default6" \
      || { log_err "IPv6 默认路由未恢复，保留路由所有权标记。"; return 1; }
  fi

  if [ -n "$saved_default4" ]; then
    default_routes="$(ip -4 route show default 2>/dev/null)" || { log_err "无法验证 IPv4 默认路由，保留路由所有权标记。"; return 1; }
    current_default="$(first_usable_non_vpn_default <<< "$default_routes")"
    [ -n "$current_default" ] || { log_err "IPv4 默认路由未恢复，保留路由所有权标记。"; return 1; }
  fi
  if [ -n "$saved_default6" ]; then
    default_routes="$(ip -6 route show default 2>/dev/null)" || { log_err "无法验证 IPv6 默认路由，保留路由所有权标记。"; return 1; }
    current_default="$(first_usable_non_vpn_default <<< "$default_routes")"
    [ -n "$current_default" ] || { log_err "IPv6 默认路由未恢复，保留路由所有权标记。"; return 1; }
  fi
  return_route_state_is_clean || { log_err "策略规则、专用路由表或 $VPN_INTERFACE 仍有残留，保留路由所有权标记。"; return 1; }
  rm -f -- "$ROUTE_OWNER_FILE"
}

cleanup_return_routes() {
  [ "$#" -le 2 ] || return 1
  if [ -e "$ROUTE_PLAN_FILE" ] || [ -L "$ROUTE_PLAN_FILE" ]; then
    cleanup_route_plan "${1:-}" "${2:-0}"
  else
    cleanup_legacy_return_routes
  fi
}

setup_return_routes() {
  if [ -e "$ROUTE_OWNER_FILE" ]; then
    cleanup_return_routes
  elif ip link show dev "$VPN_INTERFACE" >/dev/null 2>&1 || route_state_conflicts; then
    die "接口 ${VPN_INTERFACE}、策略表 ${RETURN4_TABLE}/${RETURN6_TABLE} 或规则优先级 ${RETURN4_PRIORITY}/${RETURN6_PRIORITY} 已被占用；为避免破坏现有网络，拒绝启动。"
    return 1
  fi

  local default4 default6="" dev4 dev6="" address cidr
  default4="$(ip -4 route show default | first_usable_non_vpn_default)"
  [ -n "$default4" ] || { die "找不到 VPN 之外的 IPv4 默认路由，无法建立安全回程表。"; return 1; }
  dev4="$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<< "$default4")"
  [ -n "$dev4" ] || { die "无法从默认路由识别出口接口。"; return 1; }
  mapfile -t RETURN4_ADDRESSES < <(ip -4 -o addr show dev "$dev4" scope global | awk '{print $4}')
  [ "${#RETURN4_ADDRESSES[@]}" -gt 0 ] || { die "接口 $dev4 没有全局 IPv4 地址。"; return 1; }

  default6="$(ip -6 route show default | first_usable_non_vpn_default)"

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
  [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 0 ] && [ -r "$PROC_ROOT/${pid}/comm" ] && [ "$(cat "$PROC_ROOT/${pid}/comm")" = "openconnect" ]
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
  acquire_state_lock || return 1
  if ! load_runtime_configuration >/dev/null 2>&1; then
    release_state_lock
    return 1
  fi
  release_state_lock
  openconnect_process_is_alive || return 1
  case "$PROFILE_MODE" in
    proxy)
      managed_tcp_listener_is_ready "$PROFILE_SOCKS_PORT" || return 1
      http_data_probe "socks5h://127.0.0.1:${PROFILE_SOCKS_PORT}"
      ;;
    global)
      local global_route
      validate_route_plan_against_snapshot "$RUN_ID" || return 1
      global_route="$(ip -4 route get 1.1.1.1 2>/dev/null || true)"
      grep -Eq "dev ${VPN_INTERFACE}([[:space:]]|$)" <<< "$global_route" || return 1
      local address
      for address in "${ROUTE_PLAN_RETURN4_ADDRESSES[@]}"; do
        route_get_uses_device -4 1.1.1.1 "$address" "$ROUTE_PLAN_DEV4" || return 1
      done
      for address in "${ROUTE_PLAN_RETURN6_ADDRESSES[@]}"; do
        route_get_uses_device -6 2606:4700:4700::1111 "$address" "$ROUTE_PLAN_DEV6" || return 1
      done
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
  local service_run_id=""

  acquire_state_lock || return "$NON_RESTARTABLE_EXIT"
  if [ -e "$SERVICE_RUN_ID_FILE" ] || [ -L "$SERVICE_RUN_ID_FILE" ]; then
    release_state_lock
    return "$NON_RESTARTABLE_EXIT"
  fi
  if ! load_runtime_configuration >/dev/null 2>&1; then
    release_state_lock
    return "$NON_RESTARTABLE_EXIT"
  fi
  service_run_id="$RUN_ID"
  if ! loaded_state_allows_service_run "$service_run_id"; then
    release_state_lock
    return "$NON_RESTARTABLE_EXIT"
  fi
  if ! printf '%s\n' "$service_run_id" | atomic_replace_from_stdin "$SERVICE_RUN_ID_FILE" 0600; then
    release_state_lock
    return 1
  fi
  release_state_lock

  if [ "$PROFILE_MODE" = "global" ] && ! apply_route_plan "$service_run_id"; then
    return 1
  fi

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

remove_service_run_id_if_matches() {
  [ "$#" -eq 1 ] || return 1
  local expected_run_id="$1" recorded_run_id=""

  recorded_run_id="$(read_single_uuid_file "$SERVICE_RUN_ID_FILE" 2>/dev/null || true)"
  [ "$recorded_run_id" = "$expected_run_id" ] || return 0
  rm -f -- "$SERVICE_RUN_ID_FILE"
}

cleanup_run_generation() {
  [ "$#" -eq 1 ] || return 1
  local expected_run_id="$1" cleanup_mode=""
  local cleanup_result=0 remove_plan=0

  acquire_state_lock || return 1
  if ! load_runtime_state || [ "$RUN_ID" != "$expected_run_id" ]; then
    release_state_lock
    return 0
  fi
  cleanup_mode="$MODE"
  release_state_lock

  if [ "$cleanup_mode" = global ] && ! cleanup_return_routes "$expected_run_id" 1; then cleanup_result=1; fi

  if [ "$cleanup_result" -ne 0 ]; then
    acquire_state_lock || return 1
    if ! load_runtime_state || [ "$RUN_ID" != "$expected_run_id" ]; then
      release_state_lock
      return 1
    fi
    if ! write_run_state "$expected_run_id" CLEANUP_FAILED "$DESIRED_ACTIVE" 0; then
      release_state_lock
      log_err "路由清理失败，且无法提交 CLEANUP_FAILED 状态；保留服务代际证据并禁止自动重启。"
      return 1
    fi
    release_state_lock
    return 1
  fi

  acquire_state_lock || return 1
  if ! load_runtime_state || [ "$RUN_ID" != "$expected_run_id" ]; then
    release_state_lock
    return 1
  fi
  if [ "$DESIRED_ACTIVE" = 0 ] && [ "$PHASE" != CLEANED ]; then
    case "$PHASE" in
      ROLLBACK_CLAIMED|STOPPING|CLEANUP_FAILED) ;;
      *) release_state_lock; return 1 ;;
    esac
    if ! write_run_state "$expected_run_id" CLEANED 0 0; then
      release_state_lock
      log_err "路由清理完成，但无法提交 CLEANED 状态；保留服务代际证据并禁止自动重启。"
      return 1
    fi
  fi
  [ "$cleanup_mode" = global ] && [ "$DESIRED_ACTIVE" = 0 ] && remove_plan=1
  if [ "$remove_plan" -eq 1 ] && ! remove_route_cleanup_evidence 0; then
    release_state_lock
    return 1
  fi
  remove_service_run_id_if_matches "$expected_run_id" || { release_state_lock; return 1; }
  release_state_lock
  rm -f -- "$HEALTH_FAILURE_FILE"
}

service_cleanup() {
  check_root
  local service_run_id=""

  service_run_id="$(read_single_uuid_file "$SERVICE_RUN_ID_FILE" 2>/dev/null || true)"
  [ -n "$service_run_id" ] || return 0
  cleanup_run_generation "$service_run_id"
}

read_generation_value() {
  [ "$#" -eq 2 ] || return 1
  local path="$1" expected_run_id="$2" line=""
  local -a lines=()

  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  mapfile -t lines < "$path" || return 1
  [ "${#lines[@]}" -eq 1 ] || return 1
  line="${lines[0]}"
  case "$line" in
    "${expected_run_id}="*) ;;
    *) return 1 ;;
  esac
  line="${line#*=}"
  [[ "$line" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  printf '%s\n' "$line"
}

record_health_result() {
  [ "$#" -eq 2 ] || return 1
  local expected_run_id="$1" result="$2" failures=0

  acquire_state_lock || return 1
  if ! load_runtime_state || ! loaded_state_allows_service_run "$expected_run_id"; then
    release_state_lock
    return 1
  fi
  if [ "$result" = healthy ]; then
    rm -f -- "$HEALTH_FAILURE_FILE"
    release_state_lock
    printf '0\n'
    return 0
  fi
  failures="$(read_generation_value "$HEALTH_FAILURE_FILE" "$expected_run_id" 2>/dev/null || printf '0')"
  failures=$((failures + 1))
  if ! printf '%s=%s\n' "$expected_run_id" "$failures" \
    | atomic_replace_from_stdin "$HEALTH_FAILURE_FILE" 0600; then
    release_state_lock
    return 1
  fi
  release_state_lock
  printf '%s\n' "$failures"
}

claim_health_restart() {
  [ "$#" -eq 2 ] || return 1
  local expected_run_id="$1" now="$2" last_restart=0

  acquire_state_lock || return 1
  if ! load_runtime_state || ! loaded_state_allows_service_run "$expected_run_id"; then
    release_state_lock
    return 1
  fi
  last_restart="$(read_generation_value "$HEALTH_RESTART_FILE" "$expected_run_id" 2>/dev/null || printf '0')"
  if [ $((now - last_restart)) -lt 900 ]; then
    release_state_lock
    return 2
  fi
  if ! printf '%s=%s\n' "$expected_run_id" "$now" \
    | atomic_replace_from_stdin "$HEALTH_RESTART_FILE" 0600; then
    release_state_lock
    return 1
  fi
  rm -f -- "$HEALTH_FAILURE_FILE"
  release_state_lock
}

service_health() {
  check_root
  ensure_dirs
  local health_run_id="" failures=0 now=0 restart_claim_rc=0

  acquire_state_lock || exit 0
  if load_runtime_state && loaded_state_allows_service_run "$RUN_ID"; then health_run_id="$RUN_ID"; fi
  release_state_lock
  [ -n "$health_run_id" ] || exit 0

  acquire_service_operation_lock try || exit 0
  if ! state_allows_service_run "$health_run_id"; then
    release_service_operation_lock
    exit 0
  fi
  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    release_service_operation_lock
    exit 0
  fi
  if health_once; then
    record_health_result "$health_run_id" healthy >/dev/null || true
    release_service_operation_lock
    exit 0
  fi

  failures="$(record_health_result "$health_run_id" failed 2>/dev/null || true)"
  [[ "$failures" =~ ^[0-9]+$ ]] || {
    release_service_operation_lock
    exit 0
  }
  system_log "data-plane health check failed (${failures}/3)"
  if [ "$failures" -lt 3 ]; then
    release_service_operation_lock
    exit 0
  fi

  if ! managed_main_unit_is_exact; then
    system_log "health restart skipped: managed main unit source or contract could not be verified"
    release_service_operation_lock
    exit 0
  fi
  now="$(date +%s)"
  if claim_health_restart "$health_run_id" "$now"; then
    restart_claim_rc=0
  else
    restart_claim_rc=$?
  fi
  if [ "$restart_claim_rc" -eq 2 ]; then
    system_log "health restart suppressed by 15-minute authentication safety cooldown"
    release_service_operation_lock
    exit 0
  fi
  if [ "$restart_claim_rc" -ne 0 ] || ! state_allows_service_run "$health_run_id"; then
    release_service_operation_lock
    exit 0
  fi
  system_log "restarting tunnel after three consecutive data-plane failures"
  if systemctl restart "$SERVICE_NAME"; then restart_claim_rc=0; else restart_claim_rc=$?; fi
  release_service_operation_lock
  return "$restart_claim_rc"
}

rollback_unit_probe() {
  [ "$#" -eq 2 ] && valid_uuid "$1" || return 1
  local expected_run_id="$1" unit="$2"
  local load_state transient fragment_path contract_value

  case "$unit" in
    "${ROLLBACK_UNIT}.timer"|"${ROLLBACK_UNIT}.service") ;;
    *) return 1 ;;
  esac
  if ! load_state="$(systemctl show "$unit" --property=LoadState --value 2>/dev/null)"; then
    return 1
  fi
  case "$load_state" in
    not-found) return 3 ;;
    loaded) ;;
    *) return 1 ;;
  esac
  if ! transient="$(systemctl show "$unit" --property=Transient --value 2>/dev/null)" \
    || [ "$transient" != yes ]; then
    return 1
  fi
  if ! fragment_path="$(systemctl show "$unit" --property=FragmentPath --value 2>/dev/null)" \
    || [ "$fragment_path" != "/run/systemd/transient/${unit}" ]; then
    return 1
  fi

  case "$unit" in
    "${ROLLBACK_UNIT}.service")
      contract_value="$(systemctl show "$unit" --property=ExecStart --value 2>/dev/null)" \
        || return 1
      systemd_exec_value_matches "$contract_value" "$INSTALL_PATH" \
        "${INSTALL_PATH} _rollback ${expected_run_id}" no
      ;;
    "${ROLLBACK_UNIT}.timer")
      contract_value="$(systemctl show "$unit" --property=Triggers --value 2>/dev/null)" \
        || return 1
      [ "$contract_value" = "${ROLLBACK_UNIT}.service" ]
      ;;
  esac
}

rollback_unit_is_inactive_or_absent() {
  [ "$#" -eq 2 ] || return 1
  local expected_run_id="$1" unit="$2" probe_status active_state

  if rollback_unit_probe "$expected_run_id" "$unit"; then
    probe_status=0
  else
    probe_status=$?
  fi
  [ "$probe_status" -ne 3 ] || return 0
  [ "$probe_status" -eq 0 ] || return 1
  active_state="$(systemctl show "$unit" --property=ActiveState --value 2>/dev/null)" \
    || return 1
  [ "$active_state" = inactive ]
}

rollback_pair_is_owned() {
  [ "$#" -eq 1 ] && valid_uuid "$1" || return 1
  local expected_run_id="$1" timer_status service_status

  if rollback_unit_probe "$expected_run_id" "${ROLLBACK_UNIT}.timer"; then
    timer_status=0
  else
    timer_status=$?
  fi
  if rollback_unit_probe "$expected_run_id" "${ROLLBACK_UNIT}.service"; then
    service_status=0
  else
    service_status=$?
  fi
  [ "$timer_status" -eq 0 ] && [ "$service_status" -eq 0 ]
}

cancel_rollback() {
  [ "$#" -eq 1 ] && valid_uuid "$1" || return 1
  local expected_run_id="$1" timer_status service_status

  state_matches_run "$expected_run_id" || return 1
  if rollback_unit_probe "$expected_run_id" "${ROLLBACK_UNIT}.timer"; then
    timer_status=0
  else
    timer_status=$?
  fi
  if rollback_unit_probe "$expected_run_id" "${ROLLBACK_UNIT}.service"; then
    service_status=0
  else
    service_status=$?
  fi
  case "$timer_status" in 0|3) ;; *) return 1 ;; esac
  case "$service_status" in 0|3) ;; *) return 1 ;; esac

  if [ "$timer_status" -eq 0 ]; then
    systemctl stop "${ROLLBACK_UNIT}.timer" >/dev/null 2>&1 || true
  fi
  if [ "$service_status" -eq 0 ]; then
    systemctl stop "${ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
    systemctl reset-failed "${ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
  fi

  rollback_unit_is_inactive_or_absent "$expected_run_id" "${ROLLBACK_UNIT}.timer" \
    && rollback_unit_is_inactive_or_absent "$expected_run_id" "${ROLLBACK_UNIT}.service"
}

stop_and_disable_managed_units() {
  # stop 必须独立执行：即使单元未启用或不可 disable，也必须先终止隧道。
  local managed_pid timer_state="" health_state="" state=""

  preflight_managed_units_ownership || return 1
  managed_pid="$(service_main_pid)"

  systemctl stop "$HEALTH_TIMER_NAME" >/dev/null 2>&1 || true
  timer_state="$(systemctl is-active "$HEALTH_TIMER_NAME" 2>/dev/null || true)"
  case "$timer_state" in
    inactive|failed) ;;
    *)
      die "systemd 未能确认 $HEALTH_TIMER_NAME 已停止（当前状态：${timer_state:-无法读取}）；拒绝继续停止隧道。"
      return 1
      ;;
  esac

  systemctl stop "$HEALTH_SERVICE_NAME" >/dev/null 2>&1 || true
  health_state="$(systemctl is-active "$HEALTH_SERVICE_NAME" 2>/dev/null || true)"
  case "$health_state" in
    inactive|failed) ;;
    *)
      die "systemd 未能确认 $HEALTH_SERVICE_NAME 已停止（当前状态：${health_state:-无法读取}）；拒绝继续停止隧道。"
      return 1
      ;;
  esac

  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  state="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
  case "$state" in
    inactive|failed) ;;
    *)
      die "systemd 未能确认 $SERVICE_NAME 已停止（当前状态：${state:-无法读取}）；为避免破坏仍在运行的隧道，拒绝清理路由。"
      return 1
      ;;
  esac
  if [[ "$managed_pid" =~ ^[0-9]+$ ]] && [ "$managed_pid" -gt 0 ] && [ -r "/proc/${managed_pid}/comm" ] && [ "$(cat "/proc/${managed_pid}/comm")" = "openconnect" ]; then
    die "受管 OpenConnect 进程 $managed_pid 仍在运行；拒绝清理路由。"
    return 1
  fi

  health_state="$(systemctl is-active "$HEALTH_SERVICE_NAME" 2>/dev/null || true)"
  case "$health_state" in
    inactive|failed) ;;
    *)
      die "$HEALTH_SERVICE_NAME 在主隧道停止后未能确认停稳（当前状态：${health_state:-无法读取}）；拒绝清理路由。"
      return 1
      ;;
  esac
  state="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
  case "$state" in
    inactive|failed) ;;
    *)
      die "$SERVICE_NAME 在停止流程末尾未能确认停稳（当前状态：${state:-无法读取}）；拒绝清理路由。"
      return 1
      ;;
  esac
  systemctl disable "$HEALTH_TIMER_NAME" "$SERVICE_NAME" >/dev/null 2>&1 || log_warn "服务已停止，但禁用开机自启失败；请检查 systemctl 状态。"
}

claim_run_stop() {
  [ "$#" -eq 1 ] && valid_uuid "$1" || return 1
  local expected_run_id="$1"

  acquire_state_lock || return 1
  if ! load_runtime_state || [ "$RUN_ID" != "$expected_run_id" ]; then
    release_state_lock
    return 1
  fi
  if [ "$PHASE" = CLEANED ] && [ "$DESIRED_ACTIVE" = 0 ]; then
    release_state_lock
    return 0
  fi
  case "$PHASE" in
    PREPARING|STARTING|RUNNING|AWAITING_CONFIRMATION|CONFIRMED|ROLLBACK_CLAIMED|STOPPING|CLEANUP_FAILED) ;;
    *) release_state_lock; return 1 ;;
  esac
  if ! write_run_state "$expected_run_id" STOPPING 0 0; then
    release_state_lock
    return 1
  fi
  release_state_lock
}

stop_run_transaction() {
  [ "$#" -eq 1 ] && valid_uuid "$1" || return 1
  local expected_run_id="$1"

  claim_run_stop "$expected_run_id" || return 1
  stop_and_disable_managed_units || return 1
  cleanup_run_generation "$expected_run_id" || return 1

  acquire_state_lock || return 1
  if ! load_runtime_state || [ "$RUN_ID" != "$expected_run_id" ] \
    || [ "$PHASE" != CLEANED ] || [ "$DESIRED_ACTIVE" != 0 ]; then
    release_state_lock
    return 1
  fi
  release_state_lock
  cancel_rollback "$expected_run_id" \
    || log_warn "连接已停止并完成清理，但独立回滚单元未能完全移除。"
}

cleanup_start_attempt() {
  local expected_run_id="${1:-}"

  if valid_uuid "$expected_run_id" && state_matches_run "$expected_run_id"; then
    if ! claim_run_stop "$expected_run_id"; then return 1; fi
    if ! stop_and_disable_managed_units; then
      log_err "无法确认隧道已经停止；为保护现有连接，保留受管状态和清理证据。"
      return 1
    fi
    cleanup_run_generation "$expected_run_id" \
      || { log_err "隧道已停止，但本项目网络状态未能完整清理。"; return 1; }
    cancel_rollback "$expected_run_id" \
      || log_warn "连接已停止并完成清理，但独立回滚单元未能完全移除。"
    return 0
  fi

  if ! stop_and_disable_managed_units; then
    log_err "无法确认隧道已经停止；为保护现有连接，保留受管状态和已武装的回滚任务。"
    return 1
  fi
  service_cleanup || { log_err "隧道已停止，但本项目网络状态未能完整清理。"; return 1; }
}

clear_start_signal_traps() {
  trap - INT TERM HUP
}

handle_interrupted_start() {
  local signal_name="$1" exit_code="$2"
  clear_start_signal_traps
  log_warn "启动过程收到 ${signal_name}，正在停止受管隧道并清理本项目状态..."
  if acquire_service_operation_lock wait; then
    cleanup_start_attempt "${RUN_ID:-}" || true
    release_service_operation_lock
  else
    log_err "无法取得服务操作锁；保留当前状态供独立回滚或后续恢复。"
  fi
  exit "$exit_code"
}

start_managed_units() {
  verify_installed_units || return 1
  systemctl reset-failed "$SERVICE_NAME" &&
    systemctl enable "$SERVICE_NAME" "$HEALTH_TIMER_NAME" >/dev/null &&
    systemctl start "$SERVICE_NAME" &&
    systemctl start "$HEALTH_TIMER_NAME"
}

arm_rollback() {
  [ "$#" -eq 1 ] && valid_uuid "$1" || return 1
  local expected_run_id="$1"

  state_allows_service_run "$expected_run_id" || return 1
  cancel_rollback "$expected_run_id" || return 1
  systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active=3m -- \
    "$INSTALL_PATH" _rollback "$expected_run_id" || return 1
  rollback_pair_is_owned "$expected_run_id" || return 1
  log_warn "已武装独立回滚：3 分钟内未确认，将停止并禁用全局 VPN。"
}

rollback_now() {
  check_root
  [ "$#" -eq 1 ] && valid_uuid "$1" || return 1
  local expected_run_id="$1" now=0 remaining=0 claimed=0

  while :; do
    now="$(date +%s)" || return 1
    [[ "$now" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    acquire_service_operation_lock wait || return 1
    acquire_state_lock || { release_service_operation_lock; return 1; }
    if ! load_runtime_state || [ "$RUN_ID" != "$expected_run_id" ]; then
      release_state_lock
      release_service_operation_lock
      return 0
    fi
    if [ "$DESIRED_ACTIVE" != 1 ]; then
      release_state_lock
      release_service_operation_lock
      return 0
    fi
    case "$PHASE" in
      STARTING)
        claimed=1
        ;;
      AWAITING_CONFIRMATION)
        if [ "$ROLLBACK_DEADLINE" -gt "$now" ]; then
          remaining=$((ROLLBACK_DEADLINE - now))
          release_state_lock
          release_service_operation_lock
          sleep "$remaining"
          continue
        fi
        claimed=1
        ;;
      *)
        release_state_lock
        release_service_operation_lock
        return 0
        ;;
    esac
    if [ "$claimed" -eq 1 ] \
      && ! write_run_state "$expected_run_id" ROLLBACK_CLAIMED 0 0; then
      release_state_lock
      release_service_operation_lock
      return 1
    fi
    release_state_lock
    break
  done

  system_log "global-mode safety rollback triggered"
  if ! stop_and_disable_managed_units; then
    release_service_operation_lock
    return 1
  fi
  if ! cleanup_run_generation "$expected_run_id"; then
    release_service_operation_lock
    return 1
  fi
  release_service_operation_lock
}

confirm_global_run() {
  [ "$#" -eq 1 ] && valid_uuid "$1" || return 1
  local expected_run_id="$1"

  transition_run_state "$expected_run_id" AWAITING_CONFIRMATION CONFIRMED 1 0 || return 1
  if cancel_rollback "$expected_run_id"; then
    log "已确认入站正常，取消独立回滚。"
  else
    log "已确认入站正常，持久状态已禁止独立回滚。"
    log_warn "独立回滚单元清理失败；确认仍然有效，请检查 ${ROLLBACK_UNIT}.timer 和 ${ROLLBACK_UNIT}.service。"
  fi
}

managed_units_need_stop() {
  local service_state="" health_state="" timer_state="" state
  service_state="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
  health_state="$(systemctl is-active "$HEALTH_SERVICE_NAME" 2>/dev/null || true)"
  timer_state="$(systemctl is-active "$HEALTH_TIMER_NAME" 2>/dev/null || true)"
  for state in "$service_state" "$health_state" "$timer_state"; do
    case "$state" in
      inactive|failed) ;;
      *) return 0 ;;
    esac
  done
  return 1
}

confirm_service_replacement() {
  local answer=""
  REPLACEMENT_CONFIRMED=0
  if managed_units_need_stop; then
    log_warn "已有 oc-master 受管单元正在运行或切换状态，继续会先将其完整停止。"
    read -r -p "确认替换？[y/N]: " answer
    [[ "$answer" =~ ^[yY]$ ]] || return 1
    REPLACEMENT_CONFIRMED=1
  fi
}

prepare_service_replacement() {
  [ "$#" -eq 1 ] || return 1
  local replacement_confirmed="$1" old_run_id="" needs_stop=0

  if managed_units_need_stop; then needs_stop=1; fi
  if [ "$needs_stop" -eq 1 ] && [ "$replacement_confirmed" != 1 ]; then
    die "受管单元状态已变化，请重新执行启动并确认替换。"
    return 1
  fi

  acquire_state_lock || return 1
  if load_runtime_state >/dev/null 2>&1; then old_run_id="$RUN_ID"; fi
  release_state_lock

  if [ -n "$old_run_id" ]; then
    if ! stop_run_transaction "$old_run_id"; then
      log_err "旧运行代际未能完整停止和清理，拒绝创建新的运行快照。"
      return 1
    fi
  elif [ "$needs_stop" -eq 1 ]; then
    stop_and_disable_managed_units || return 1
  fi
  if [ -e "$ROUTE_PLAN_FILE" ] || [ -L "$ROUTE_PLAN_FILE" ]; then
    die "检测到未完成清理的代际路由计划，拒绝创建新的运行快照。"
    return 1
  fi
  if [ -e "$ROUTE_OWNER_FILE" ] || [ -L "$ROUTE_OWNER_FILE" ]; then
    if ! cleanup_legacy_return_routes; then
      die "旧版回程路由未能完整清理，拒绝创建新的运行快照。"
      return 1
    fi
  fi
  if [ -e "$ROUTE_PLAN_FILE" ] || [ -L "$ROUTE_PLAN_FILE" ] \
    || [ -e "$ROUTE_OWNER_FILE" ] || [ -L "$ROUTE_OWNER_FILE" ]; then
    die "回程路由清理证据仍然存在，拒绝创建新的运行快照。"
    return 1
  fi
  if [ -e "$SERVICE_RUN_ID_FILE" ] || [ -L "$SERVICE_RUN_ID_FILE" ]; then
    die "检测到未完成清理的服务代际证据，拒绝创建新的运行快照。"
    return 1
  fi

  local foreign_pids
  foreign_pids="$(pgrep -x openconnect 2>/dev/null || true)"
  [ -z "$foreign_pids" ] || die "检测到不属于 oc-master 的 OpenConnect 进程（PID: ${foreign_pids//$'\n'/,}），拒绝抢占。"
}

start_mode() {
  local mode="$1" socks_port="" answer="" snapshot_run_id=""
  local selected_account_index="" selected_protocol="" selected_account_record=""
  ensure_dependencies "$mode"
  select_account
  if [ "$mode" = "proxy" ]; then
    read -r -p "本地 SOCKS5 端口 [1080]: " socks_port
    socks_port="${socks_port:-1080}"
    valid_port "$socks_port" || { die "端口无效。"; return 1; }
  else
    confirm_global_risk || return 0
  fi

  selected_account_index="$ACCOUNT_INDEX"
  selected_protocol="$VPN_PROTOCOL"
  selected_account_record="$ACCOUNT_RECORD"
  REPLACEMENT_CONFIRMED=0
  confirm_service_replacement || return 1

  acquire_service_operation_lock wait || return 1
  if ! prepare_runtime_configuration_for_start; then
    release_service_operation_lock
    return 1
  fi
  if ! prepare_service_replacement "$REPLACEMENT_CONFIRMED"; then
    release_service_operation_lock
    return 1
  fi
  ACCOUNT_INDEX="$selected_account_index"
  VPN_PROTOCOL="$selected_protocol"
  ACCOUNT_RECORD="$selected_account_record"
  if [ "$mode" = "proxy" ] && ! port_is_free "$socks_port"; then
    die "端口 $socks_port 已被占用。"
    release_service_operation_lock
    return 1
  fi
  if ! install_self_and_units; then
    release_service_operation_lock
    return 1
  fi

  trap 'handle_interrupted_start SIGINT 130' INT
  trap 'handle_interrupted_start SIGTERM 143' TERM
  trap 'handle_interrupted_start SIGHUP 129' HUP

  if ! snapshot_run_id="$(create_run_snapshot "$mode" "$ACCOUNT_INDEX" "$VPN_PROTOCOL" "$socks_port" "$ACCOUNT_RECORD")"; then
    log_err "无法创建运行快照，拒绝启动 VPN。"
    cleanup_start_attempt "" || true
    release_service_operation_lock
    clear_start_signal_traps
    return 1
  fi
  RUN_ID="$snapshot_run_id"
  if [ "$mode" = global ]; then
    if ! build_route_plan "$snapshot_run_id" \
      || ! write_route_plan "$snapshot_run_id" \
      || ! validate_route_plan_against_snapshot "$snapshot_run_id"; then
      log_err "无法为当前运行代际建立安全回程计划，拒绝启动整机全局 VPN。"
      if ! cleanup_start_attempt "$snapshot_run_id"; then
        log_err "回程计划启动前检查失败，且本代际清理未完成；已保留恢复证据。"
      fi
      release_service_operation_lock
      clear_start_signal_traps
      return 1
    fi
  fi
  if ! transition_run_state "$snapshot_run_id" PREPARING STARTING 1 0; then
    log_err "无法提交运行状态，拒绝启动 VPN。"
    cleanup_start_attempt "$snapshot_run_id" || true
    release_service_operation_lock
    clear_start_signal_traps
    return 1
  fi
  rm -f "$HEALTH_FAILURE_FILE" "$HEALTH_RESTART_FILE"
  if [ "$mode" = "global" ] && ! arm_rollback "$snapshot_run_id"; then
    log_err "无法创建独立安全回滚，拒绝启动整机全局 VPN。"
    cleanup_start_attempt "$snapshot_run_id" || true
    release_service_operation_lock
    clear_start_signal_traps
    return 1
  fi
  if ! start_managed_units; then
    log_err "systemd 启动链失败，正在立即停止、禁用并清理本项目状态。"
    cleanup_start_attempt "$snapshot_run_id" || true
    release_service_operation_lock
    clear_start_signal_traps
    return 1
  fi
  release_service_operation_lock

  log_info "等待真实数据面可用（最长 60 秒）..."
  if ! wait_until_healthy; then
    log_err "连接没有通过数据面检查，正在停止并清理。"
    if acquire_service_operation_lock wait; then
      cleanup_start_attempt "$snapshot_run_id" || true
      release_service_operation_lock
    else
      log_err "无法取得服务操作锁；保留当前状态供独立回滚或后续恢复。"
    fi
    clear_start_signal_traps
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
    return 1
  fi

  if [ "$mode" = "proxy" ]; then
    if ! transition_run_state "$snapshot_run_id" STARTING RUNNING 1 0; then
      log_err "连接健康，但无法提交运行状态，正在停止并清理。"
      if acquire_service_operation_lock wait; then
        cleanup_start_attempt "$snapshot_run_id" || true
        release_service_operation_lock
      else
        log_err "无法取得服务操作锁；保留当前状态供后续恢复。"
      fi
      clear_start_signal_traps
      return 1
    fi
    clear_start_signal_traps
    log "SOCKS5 已可用：127.0.0.1:${socks_port}；宿主机默认路由未修改。"
    return 0
  fi

  if ! transition_run_state "$snapshot_run_id" STARTING AWAITING_CONFIRMATION 1 "$(( $(date +%s) + 120 ))"; then
    log_err "连接健康，但无法进入入站确认阶段，正在停止并清理。"
    if acquire_service_operation_lock wait; then
      cleanup_start_attempt "$snapshot_run_id" || true
      release_service_operation_lock
    else
      log_err "无法取得服务操作锁；保留当前状态供后续恢复。"
    fi
    clear_start_signal_traps
    return 1
  fi
  log "全局 VPN 数据面已可用。"
  printf '%s\n' "请现在从外部新建一次 SSH 或其他入站连接，确认回程正常。"
  read -r -t 120 -p "确认无误后在 120 秒内输入 KEEP: " answer || answer=""
  printf '\n'
  if [ "$answer" = "KEEP" ]; then
    if ! confirm_global_run "$snapshot_run_id"; then
      log_err "独立回滚已接管或运行状态已变化，本次 KEEP 未生效。"
      clear_start_signal_traps
      return 1
    fi
    clear_start_signal_traps
  else
    log_warn "未收到 KEEP，立即执行安全回滚。"
    transition_run_state "$snapshot_run_id" AWAITING_CONFIRMATION AWAITING_CONFIRMATION 1 0 || true
    rollback_now "$snapshot_run_id" || true
    clear_start_signal_traps
    return 1
  fi
}

stop_vpn() {
  check_root
  local stop_run_id=""

  acquire_service_operation_lock wait || return 1
  if ! acquire_state_lock; then
    release_service_operation_lock
    return 1
  fi
  if load_runtime_state >/dev/null 2>&1; then stop_run_id="$RUN_ID"; fi
  release_state_lock
  if [ -z "$stop_run_id" ]; then
    if { [ -e "$RUN_STATE_FILE" ] || [ -L "$RUN_STATE_FILE" ]; } \
      && recover_uncommitted_preparing_state; then
      release_service_operation_lock
      log "VPN 已停止，oc-master 的策略路由已清理。"
      return 0
    fi
    if new_runtime_artifact_exists; then
      die "检测到不完整或非法的新运行状态；为避免破坏恢复证据，拒绝停止或清理。"
      release_service_operation_lock
      return 1
    fi
    if legacy_installation_exists; then
      if ! recover_legacy_installation; then release_service_operation_lock; return 1; fi
      release_service_operation_lock
      log "VPN 已停止，oc-master 的策略路由已清理。"
      return 0
    fi
    if ! stop_and_disable_managed_units; then release_service_operation_lock; return 1; fi
    if ! service_cleanup; then release_service_operation_lock; return 1; fi
    release_service_operation_lock
    log "VPN 已停止，oc-master 的策略路由已清理。"
    return 0
  fi

  if [ "$PHASE" != CLEANED ]; then
    if ! transition_run_state "$stop_run_id" \
      'PREPARING,STARTING,RUNNING,AWAITING_CONFIRMATION,CONFIRMED,ROLLBACK_CLAIMED,STOPPING,CLEANUP_FAILED' \
      STOPPING 0 0; then
      release_service_operation_lock
      return 1
    fi
  fi
  if ! stop_and_disable_managed_units; then
    release_service_operation_lock
    return 1
  fi
  if ! cleanup_run_generation "$stop_run_id"; then
    release_service_operation_lock
    return 1
  fi
  cancel_rollback "$stop_run_id" \
    || log_warn "VPN 已停止并完成清理，但独立回滚单元未能完全移除。"
  release_service_operation_lock
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
  if [ ! -r "$PROFILE_FILE" ] && [ ! -e "$ACTIVE_RUN_FILE" ] && [ ! -L "$ACTIVE_RUN_FILE" ] \
    && [ ! -e "$RUN_STATE_FILE" ] && [ ! -L "$RUN_STATE_FILE" ]; then
    printf '  %bVPN 状态:%b %b🔴 停止%b\n' "$C_BOLD" "$C_RESET" "$C_RED" "$C_RESET"
    printf '    %b运行模式:%b 未配置\n' "$C_BOLD" "$C_RESET"
    printf '    %b自动守护:%b 未启用（首次启动后自动配置）\n' "$C_BOLD" "$C_RESET"
    printf '    %b本机公网 IPv4:%b %s\n' "$C_BOLD" "$C_RESET" "$(public_ip)"
    printf '    %b本机公网 IPv6:%b %s\n' "$C_BOLD" "$C_RESET" "$(public_ipv6)"
    sep
    return 0
  fi

  if ! load_runtime_configuration; then return 1; fi
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
  stop_vpn || { log_err "无法确认停止和清理已完成；保留所有恢复证据。"; return 1; }
  if new_runtime_artifact_exists; then
    acquire_state_lock || return 1
    if ! load_runtime_state || [ "$PHASE" != CLEANED ] || [ "$DESIRED_ACTIVE" != 0 ]; then
      release_state_lock
      log_err "未取得 CLEANED 状态证明；保留所有恢复证据。"
      return 1
    fi
    release_state_lock
  fi
  remove_managed_units || return 1
  if ! systemctl daemon-reload; then
    log_err "systemctl daemon-reload 失败；磁盘上的已删除单元尚未由 systemd 重载，已保留运行快照和其余恢复证据。"
    return 1
  fi
  remove_managed_shortcut || return 1
  if [ -f "$INSTALL_PATH" ] && [ ! -L "$INSTALL_PATH" ]; then
    if cmp -s -- "$SCRIPT_PATH" "$INSTALL_PATH"; then
      rm -f -- "$INSTALL_PATH" || return 1
    else
      log_warn "保留无法确认属于本项目的程序副本：$INSTALL_PATH"
    fi
  elif [ -e "$INSTALL_PATH" ] || [ -L "$INSTALL_PATH" ]; then
    log_warn "保留无法确认属于本项目的程序副本：$INSTALL_PATH"
  fi
  rm -f -- "$PROFILE_FILE" "$ACTIVE_RUN_FILE" "$RUN_STATE_FILE" "$ROUTE_PLAN_FILE" "$ROUTE_OWNER_FILE" \
    "$SERVICE_RUN_ID_FILE" "$HEALTH_FAILURE_FILE" "$HEALTH_RESTART_FILE" || return 1
  rmdir "$CONFIG_DIR" "$RUNTIME_DIR" 2>/dev/null || true
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
    _rollback)
      [ "$#" -eq 2 ] && valid_uuid "$2" \
        || { log_err "独立回滚任务缺少有效代际参数。"; return "$NON_RESTARTABLE_EXIT"; }
      rollback_now "$2"
      ;;
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
