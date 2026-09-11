#!/usr/bin/env bash
set -Eeuo pipefail

PATH="/usr/bin:/bin:${PATH}"
export PATH

cd -- "${BASH_SOURCE[0]%/*}/.."

# shellcheck source=tests/testlib.sh
source tests/testlib.sh

TEST_ROOT="$(new_test_root)"
trap 'cleanup_test_root "$TEST_ROOT"' EXIT

CURRENT_SCRIPT="$(pwd)/oc_master.sh"
BASELINE_SCRIPT="${OCM_BASELINE_SCRIPT:-${TEST_ROOT}/baseline/oc_master.sh}"
if [ -z "${OCM_BASELINE_SCRIPT:-}" ]; then
  mkdir -p "${BASELINE_SCRIPT%/*}"
  git show e03f2aa:oc_master.sh > "$BASELINE_SCRIPT"
fi
[ -r "$BASELINE_SCRIPT" ] || fail "baseline script is not readable: $BASELINE_SCRIPT"

normalize_file() {
  local input_file="$1" normalized_file="$2" script_path="$3" public_ipv4="$4" public_ipv6="$5" output

  output="$(cat -- "$input_file"; printf '\001')"
  output="${output%$'\001'}"
  output="${output//"$script_path"/<SCRIPT_PATH>}"
  output="${output//"$TEST_ROOT"/<TEST_ROOT>}"
  output="${output//"$public_ipv4"/<PUBLIC_IPV4>}"
  output="${output//"$public_ipv6"/<PUBLIC_IPV6>}"
  printf '%s' "$output" > "$normalized_file"
}

run_case() {
  local case_name="$1" script_path="$2" input="$3" suffix="$4" command="$5"
  local case_root="${TEST_ROOT}/${case_name}"
  local stdout_file="${case_root}/stdout-${suffix}" stderr_file="${case_root}/stderr-${suffix}"
  local rc_file="${case_root}/rc-${suffix}"
  local public_ipv4="198.51.100.${suffix}" public_ipv6="2001:db8::${suffix}"

  mkdir -p "$case_root"
  export_test_paths "$case_root"
  set +e
  "${BASH}" -c '
    source "$1"
    BASH_ARGV0="$1"
    mock_public_ipv4="$3"
    mock_public_ipv6="$4"
    check_root() { :; }
    acquire_manager_lock() { :; }
    ensure_dirs() { mkdir -p "$CONFIG_DIR" "$RUNTIME_DIR"; }
    curl() {
      case " $* " in
        *" -6 "*) printf "%s" "$mock_public_ipv6" ;;
        *) printf "%s" "$mock_public_ipv4" ;;
      esac
    }
    if [ "$5" = "start-proxy-without-account" ]; then
      ensure_dependencies() { :; }
    fi
    run_main "$2"
  ' compat-case "$script_path" "$command" "$public_ipv4" "$public_ipv6" "$case_name" < "$input" > "$stdout_file" 2> "$stderr_file"
  rc=$?
  set -e
  printf '%s\n' "$rc" > "$rc_file"
}

compare_stream() {
  local case_name="$1" stream_name="$2"
  local baseline_file="$3" current_file="$4"
  local baseline_script="$5" baseline_ipv4="$6" baseline_ipv6="$7"
  local current_script="$8" current_ipv4="$9" current_ipv6="${10}"
  local baseline_normalized="${baseline_file}.normalized"
  local current_normalized="${current_file}.normalized"

  normalize_file "$baseline_file" "$baseline_normalized" "$baseline_script" "$baseline_ipv4" "$baseline_ipv6"
  normalize_file "$current_file" "$current_normalized" "$current_script" "$current_ipv4" "$current_ipv6"
  if ! cmp -s "$baseline_normalized" "$current_normalized"; then
    diff -u --label "baseline ${stream_name}" --label "current ${stream_name}" \
      "$baseline_normalized" "$current_normalized" >&2 || true
    fail "$case_name ${stream_name} changed"
  fi
}

compare_case() {
  local case_name="$1" command="$2" input_text="$3"
  local input_file="${TEST_ROOT}/${case_name}.input"
  local baseline_stdout baseline_stderr baseline_rc_file baseline_ipv4 baseline_ipv6
  local current_stdout current_stderr current_rc_file current_ipv4 current_ipv6
  local baseline_rc current_rc

  printf '%s' "$input_text" > "$input_file"
  run_case "$case_name" "$BASELINE_SCRIPT" "$input_file" 10 "$command"
  run_case "$case_name" "$CURRENT_SCRIPT" "$input_file" 20 "$command"
  baseline_stdout="${TEST_ROOT}/${case_name}/stdout-10"
  baseline_stderr="${TEST_ROOT}/${case_name}/stderr-10"
  baseline_rc_file="${TEST_ROOT}/${case_name}/rc-10"
  baseline_ipv4='198.51.100.10'
  baseline_ipv6='2001:db8::10'
  current_stdout="${TEST_ROOT}/${case_name}/stdout-20"
  current_stderr="${TEST_ROOT}/${case_name}/stderr-20"
  current_rc_file="${TEST_ROOT}/${case_name}/rc-20"
  current_ipv4='198.51.100.20'
  current_ipv6='2001:db8::20'

  baseline_rc="$(<"$baseline_rc_file")"
  current_rc="$(<"$current_rc_file")"
  assert_eq "$baseline_rc" "$current_rc" "$case_name exit status changed"

  compare_stream "$case_name" stdout "$baseline_stdout" "$current_stdout" \
    "$BASELINE_SCRIPT" "$baseline_ipv4" "$baseline_ipv6" \
    "$CURRENT_SCRIPT" "$current_ipv4" "$current_ipv6"
  compare_stream "$case_name" stderr "$baseline_stderr" "$current_stderr" \
    "$BASELINE_SCRIPT" "$baseline_ipv4" "$baseline_ipv6" \
    "$CURRENT_SCRIPT" "$current_ipv4" "$current_ipv6"
}

write_lifecycle_mocks() {
  local mock_bin="$1"

  mkdir -p "$mock_bin"
  cat > "${mock_bin}/systemctl" <<'MOCK_SYSTEMCTL'
#!/usr/bin/env bash
set -u
printf '<%s>' "$@" >> "$MOCK_SYSTEMCTL_LOG"
printf '\n' >> "$MOCK_SYSTEMCTL_LOG"
command_name="${1:-}"
shift || true
case "$command_name" in
  is-active)
    quiet=0 unit=""
    for argument in "$@"; do
      [ "$argument" != --quiet ] || quiet=1
      [[ "$argument" == -* ]] || unit="$argument"
    done
    if [ -e "${MOCK_SYSTEMCTL_STATE}/${unit}.active" ]; then
      [ "$quiet" -eq 1 ] || printf 'active\n'
      exit 0
    fi
    [ "$quiet" -eq 1 ] || printf 'inactive\n'
    exit 3
    ;;
  show)
    case " $* " in
      *DropInPaths*) printf 'DropInPaths=\n' ;;
      *MainPID*) printf '%s\n' "$MOCK_OPENCONNECT_PID" ;;
      *ControlGroup*) printf '/system.slice/oc-master.service\n' ;;
      *LoadState*)
        unit="${1:-}"
        if [ -f "${MOCK_SYSTEMCTL_STATE}/${unit}.load" ]; then
          cat "${MOCK_SYSTEMCTL_STATE}/${unit}.load"
        elif [ -f "${OCM_SYSTEMD_DIR}/${unit}" ]; then
          printf 'loaded\n'
        else
          printf 'not-found\n'
        fi
        ;;
      *Transient*) cat "${MOCK_SYSTEMCTL_STATE}/${1:-}.transient" ;;
      *FragmentPath*)
        if [ -f "${MOCK_SYSTEMCTL_STATE}/${1:-}.fragment" ]; then
          cat "${MOCK_SYSTEMCTL_STATE}/${1:-}.fragment"
        else
          printf '%s/%s\n' "$OCM_SYSTEMD_DIR" "${1:-}"
        fi
        ;;
      *ActiveState*)
        [ -e "${MOCK_SYSTEMCTL_STATE}/${1:-}.active" ] \
          && printf 'active\n' || printf 'inactive\n'
        ;;
      *ExecStopPost*)
        printf 'path=%s ; argv[]=%s _service_cleanup ; ignore_errors=yes\n' \
          "$OCM_INSTALL_PATH" "$OCM_INSTALL_PATH"
        ;;
      *RestartPreventExitStatus*) printf '78\n' ;;
      *Restart*) printf 'always\n' ;;
      *NeedDaemonReload*) printf 'no\n' ;;
      *ExecStart*)
        case "${1:-}" in
          oc-master.service)
            printf 'path=%s ; argv[]=%s _service_run ; ignore_errors=no\n' \
              "$OCM_INSTALL_PATH" "$OCM_INSTALL_PATH"
            ;;
          oc-master-health.service)
            printf 'path=%s ; argv[]=%s _service_health ; ignore_errors=no\n' \
              "$OCM_INSTALL_PATH" "$OCM_INSTALL_PATH"
            ;;
          oc-master-rollback.service)
            cat "${MOCK_SYSTEMCTL_STATE}/oc-master-rollback.service.exec-start"
            ;;
          *) exit 96 ;;
        esac
        ;;
      *Triggers*)
        case "${1:-}" in
          oc-master-rollback.timer)
            cat "${MOCK_SYSTEMCTL_STATE}/oc-master-rollback.timer.triggers"
            ;;
          *) printf 'oc-master-health.service\n' ;;
        esac
        ;;
      *) printf '\n' ;;
    esac
    ;;
  start|stop)
    for argument in "$@"; do
      [[ "$argument" == -* ]] && continue
      if [ "$command_name" = start ]; then
        [ -e "${MOCK_SYSTEMCTL_STATE}/${argument}.active" ] && continue
        printf 'start<%s>\n' "$argument" >> "$MOCK_SYSTEMCTL_EFFECTS"
        : > "${MOCK_SYSTEMCTL_STATE}/${argument}.active"
      else
        [ -e "${MOCK_SYSTEMCTL_STATE}/${argument}.active" ] || continue
        printf 'stop<%s>\n' "$argument" >> "$MOCK_SYSTEMCTL_EFFECTS"
        rm -f -- "${MOCK_SYSTEMCTL_STATE}/${argument}.active"
      fi
    done
    ;;
  reset-failed)
    for argument in "$@"; do
      [ -e "${MOCK_SYSTEMCTL_STATE}/${argument}.failed" ] || continue
      printf 'reset-failed<%s>\n' "$argument" >> "$MOCK_SYSTEMCTL_EFFECTS"
      rm -f -- "${MOCK_SYSTEMCTL_STATE}/${argument}.failed"
    done
    ;;
  enable|disable|daemon-reload)
    printf '%s' "$command_name" >> "$MOCK_SYSTEMCTL_EFFECTS"
    for argument in "$@"; do printf '<%s>' "$argument" >> "$MOCK_SYSTEMCTL_EFFECTS"; done
    printf '\n' >> "$MOCK_SYSTEMCTL_EFFECTS"
    ;;
  *)
    printf 'unexpected mock systemctl call: %s\n' "$command_name $*" >&2
    exit 96
    ;;
esac
MOCK_SYSTEMCTL

  cat > "${mock_bin}/openconnect" <<'MOCK_OPENCONNECT'
#!/usr/bin/env bash
set -u
for argument in "$@"; do
  [ "$argument" != --help ] || { printf '%s\n' '--tcp-keepalive'; exit 0; }
done
: > "$MOCK_OPENCONNECT_ARGV"
for argument in "$@"; do printf '<%s>\n' "$argument" >> "$MOCK_OPENCONNECT_ARGV"; done
cat > "$MOCK_OPENCONNECT_STDIN"
MOCK_OPENCONNECT

  cat > "${mock_bin}/ss" <<'MOCK_SS'
#!/usr/bin/env bash
set -u
[ -e "${MOCK_SYSTEMCTL_STATE}/oc-master.service.active" ] || exit 0
printf 'LISTEN 0 4096 127.0.0.1:1080 0.0.0.0:* users:(("ocproxy",pid=%s,fd=3))\n' "$MOCK_OPENCONNECT_PID"
MOCK_SS

  cat > "${mock_bin}/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -u
case " $* " in
  *' -o /dev/null '*) exit 0 ;;
  *' -6 '*) printf '%s' "$MOCK_PUBLIC_IPV6" ;;
  *) printf '%s' "$MOCK_PUBLIC_IPV4" ;;
esac
MOCK_CURL

  cat > "${mock_bin}/ps" <<'MOCK_PS'
#!/usr/bin/env bash
printf 'systemd\n'
MOCK_PS
  cat > "${mock_bin}/pgrep" <<'MOCK_PGREP'
#!/usr/bin/env bash
exit 1
MOCK_PGREP
  cat > "${mock_bin}/ip" <<'MOCK_IP'
#!/usr/bin/env bash
set -u
{
  for argument in "$@"; do printf '<%s>' "$argument"; done
  printf '\n'
} >> "$MOCK_IP_LOG"

delete_managed_rule() {
  local rules_file="$1" table="$2"
  grep -Ev "lookup ${table}([[:space:]]|$)" "$rules_file" > "${rules_file}.tmp" || true
  mv -f -- "${rules_file}.tmp" "$rules_file"
}

case "$*" in
  '-4 route show default') cat "$MOCK_DEFAULT4" ;;
  '-6 route show default') cat "$MOCK_DEFAULT6" ;;
  '-4 -o addr show scope global'|'-4 -o addr show dev eth0 scope global') cat "$MOCK_ADDR4" ;;
  '-6 -o addr show scope global'|'-6 -o addr show dev eth0 scope global') cat "$MOCK_ADDR6" ;;
  '-4 rule show') cat "$MOCK_RULE4" ;;
  '-6 rule show') cat "$MOCK_RULE6" ;;
  '-4 route show table 51888') cat "$MOCK_TABLE4" ;;
  '-6 route show table 51889') cat "$MOCK_TABLE6" ;;
  '-o link show') cat "$MOCK_LINKS" ;;
  'link show dev ocm0') exit 1 ;;
  '-4 route replace table 51888 '*)
    shift 5
    printf '%s\n' "$*" > "$MOCK_TABLE4"
    printf '%s\n' 'ipv4-table-install' >> "$MOCK_IP_EFFECTS"
    ;;
  '-6 route replace table 51889 '*)
    shift 5
    printf '%s\n' "$*" > "$MOCK_TABLE6"
    printf '%s\n' 'ipv6-table-install' >> "$MOCK_IP_EFFECTS"
    ;;
  '-4 rule add priority 10000 from 192.0.2.10/32 lookup 51888')
    printf '%s\n' '10000: from 192.0.2.10 lookup 51888' >> "$MOCK_RULE4"
    printf '%s\n' 'ipv4-rule-install' >> "$MOCK_IP_EFFECTS"
    ;;
  '-6 rule add priority 10001 from '*)
    printf '%s\n' '10001: from 2001:db8::10 lookup 51889' >> "$MOCK_RULE6"
    printf '%s\n' 'ipv6-rule-install' >> "$MOCK_IP_EFFECTS"
    ;;
  '-4 rule del priority 10000 lookup 51888'|'-4 rule del priority 10000 from 192.0.2.10/32 lookup 51888')
    grep -Eq 'lookup 51888([[:space:]]|$)' "$MOCK_RULE4" || exit 2
    delete_managed_rule "$MOCK_RULE4" 51888
    printf '%s\n' 'ipv4-rule-remove' >> "$MOCK_IP_EFFECTS"
    ;;
  '-6 rule del priority 10001 lookup 51889'|'-6 rule del priority 10001 from '*' lookup 51889')
    grep -Eq 'lookup 51889([[:space:]]|$)' "$MOCK_RULE6" || exit 2
    delete_managed_rule "$MOCK_RULE6" 51889
    printf '%s\n' 'ipv6-rule-remove' >> "$MOCK_IP_EFFECTS"
    ;;
  '-4 route flush table 51888')
    : > "$MOCK_TABLE4"
    printf '%s\n' 'ipv4-table-flush' >> "$MOCK_IP_EFFECTS"
    ;;
  '-6 route flush table 51889')
    : > "$MOCK_TABLE6"
    printf '%s\n' 'ipv6-table-flush' >> "$MOCK_IP_EFFECTS"
    ;;
  '-4 route get 1.1.1.1 from 192.0.2.10')
    printf '%s\n' '1.1.1.1 from 192.0.2.10 via 192.0.2.1 dev eth0 src 192.0.2.10'
    ;;
  '-6 route get 2606:4700:4700::1111 from '*)
    printf '%s\n' '2606:4700:4700::1111 from 2001:db8::10 via 2001:db8::1 dev eth0 src 2001:db8::10'
    ;;
  '-4 route get 1.1.1.1')
    printf '%s\n' '1.1.1.1 dev ocm0 src 10.0.0.2'
    ;;
  'link del dev ocm0')
    printf '%s\n' 'vpn-link-remove' >> "$MOCK_IP_EFFECTS"
    ;;
  *)
    printf 'unexpected mock ip call: %s\n' "$*" >&2
    exit 96
    ;;
esac
MOCK_IP
  cat > "${mock_bin}/flock" <<'MOCK_FLOCK'
#!/usr/bin/env bash
exit 0
MOCK_FLOCK
  cat > "${mock_bin}/systemd-run" <<'MOCK_SYSTEMD_RUN'
#!/usr/bin/env bash
set -u
unit_name="" command_path="" command_action="" command_run_id=""
{
  for argument in "$@"; do printf '<%s>' "$argument"; done
  printf '\n'
} >> "$MOCK_SYSTEMD_RUN_LOG"
printf '%s\n' 'arm-global-rollback' >> "$MOCK_SYSTEMD_RUN_EFFECTS"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --unit=*) unit_name="${1#--unit=}"; shift ;;
    --)
      shift
      command_path="${1:-}"
      command_action="${2:-}"
      command_run_id="${3:-}"
      break
      ;;
    *) shift ;;
  esac
done
[ -n "$unit_name" ] && [ -n "$command_path" ] && [ "$command_action" = _rollback ] || exit 96
service_unit="${unit_name}.service"
timer_unit="${unit_name}.timer"
printf 'loaded\n' > "${MOCK_SYSTEMCTL_STATE}/${service_unit}.load"
printf 'loaded\n' > "${MOCK_SYSTEMCTL_STATE}/${timer_unit}.load"
printf 'yes\n' > "${MOCK_SYSTEMCTL_STATE}/${service_unit}.transient"
printf 'yes\n' > "${MOCK_SYSTEMCTL_STATE}/${timer_unit}.transient"
printf '/run/systemd/transient/%s\n' "$service_unit" > "${MOCK_SYSTEMCTL_STATE}/${service_unit}.fragment"
printf '/run/systemd/transient/%s\n' "$timer_unit" > "${MOCK_SYSTEMCTL_STATE}/${timer_unit}.fragment"
if [ -n "$command_run_id" ]; then
  printf 'path=%s ; argv[]=%s %s %s ; ignore_errors=no\n' \
    "$command_path" "$command_path" "$command_action" "$command_run_id" \
    > "${MOCK_SYSTEMCTL_STATE}/${service_unit}.exec-start"
else
  printf 'path=%s ; argv[]=%s %s ; ignore_errors=no\n' \
    "$command_path" "$command_path" "$command_action" \
    > "${MOCK_SYSTEMCTL_STATE}/${service_unit}.exec-start"
fi
printf '%s\n' "$service_unit" > "${MOCK_SYSTEMCTL_STATE}/${timer_unit}.triggers"
: > "${MOCK_SYSTEMCTL_STATE}/${service_unit}.active"
: > "${MOCK_SYSTEMCTL_STATE}/${timer_unit}.active"
MOCK_SYSTEMD_RUN
  cat > "${mock_bin}/date" <<'MOCK_DATE'
#!/usr/bin/env bash
[ "${1:-}" = +%s ] && { printf '%s\n' '2000000000'; exit 0; }
exec /usr/bin/date "$@"
MOCK_DATE
  for command_name in logger ocproxy journalctl; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "${mock_bin}/${command_name}"
  done
  chmod 0700 "${mock_bin}"/*
}

run_lifecycle_action() {
  local version_root="$1" script_path="$2" action="$3" input_text="$4"
  local output_root="${version_root}/output" stdout_file="${version_root}/output/${action}.stdout"
  local stderr_file="${version_root}/output/${action}.stderr" rc_file="${version_root}/output/${action}.rc"

  mkdir -p "$output_root"
  set +e
  printf '%s' "$input_text" | env \
    PATH="${version_root}/mock-bin:/usr/bin:/bin" \
    OCM_INSTALL_PATH="${version_root}/sbin/oc-master" \
    OCM_SHORTCUT_PATH="${version_root}/bin/ocm" \
    OCM_SYSTEMD_DIR="${version_root}/systemd" \
    OCM_CONFIG_DIR="${version_root}/config" \
    OCM_PROFILE_FILE="${version_root}/config/profile.conf" \
    OCM_ACCOUNTS_FILE="${version_root}/accounts.env" \
    OCM_RUNTIME_DIR="${version_root}/run" \
    OCM_LOCK_FILE="${version_root}/lock/manager.lock" \
    OCM_STATE_LOCK_FILE="${version_root}/lock/state.lock" \
    OCM_SERVICE_LOCK_FILE="${version_root}/lock/service.lock" \
    OCM_BOOT_ID_FILE="${version_root}/proc/boot_id" \
    OCM_UUID_FILE="${version_root}/proc/uuid" \
    OCM_PROC_ROOT="${version_root}/proc" \
    OCM_DDNS_SCAN_ROOT="${version_root}/scan" \
    MOCK_SYSTEMCTL_LOG="${version_root}/systemctl.log" \
    MOCK_SYSTEMCTL_EFFECTS="${version_root}/systemctl.effects" \
    MOCK_SYSTEMCTL_STATE="${version_root}/systemctl-state" \
    MOCK_OPENCONNECT_ARGV="${version_root}/openconnect.argv" \
    MOCK_OPENCONNECT_STDIN="${version_root}/openconnect.stdin" \
    MOCK_OPENCONNECT_PID=4242 \
    MOCK_PUBLIC_IPV4=198.51.100.77 \
    MOCK_PUBLIC_IPV6=2001:db8::77 \
    MOCK_IP_LOG="${version_root}/ip.log" \
    MOCK_IP_EFFECTS="${version_root}/ip.effects" \
    MOCK_DEFAULT4="${version_root}/network/default4" \
    MOCK_DEFAULT6="${version_root}/network/default6" \
    MOCK_ADDR4="${version_root}/network/addr4" \
    MOCK_ADDR6="${version_root}/network/addr6" \
    MOCK_RULE4="${version_root}/network/rule4" \
    MOCK_RULE6="${version_root}/network/rule6" \
    MOCK_TABLE4="${version_root}/network/table4" \
    MOCK_TABLE6="${version_root}/network/table6" \
    MOCK_LINKS="${version_root}/network/links" \
    MOCK_SYSTEMD_RUN_LOG="${version_root}/systemd-run.log" \
    MOCK_SYSTEMD_RUN_EFFECTS="${version_root}/systemd-run.effects" \
    "$BASH" -c '
      source "$1"
      BASH_ARGV0="$1"
      check_root() { :; }
      # e03f2aa 把 unit 目录和 root ownership 写死；这里给两版共用同一安全
      # 测试根安装 seam。真实 staged install/ownership 由 tests/install.sh 覆盖。
      ensure_dirs() { mkdir -p -- "$CONFIG_DIR" "$RUNTIME_DIR" "${LOCK_FILE%/*}"; }
      install_self_and_units() {
        ensure_dirs
        install -d -m 0755 "$(dirname "$INSTALL_PATH")" "$(dirname "$SHORTCUT_PATH")" "$OCM_SYSTEMD_DIR"
        install -m 0755 "$SCRIPT_PATH" "$INSTALL_PATH"
        [ "$SHORTCUT_PATH" = "$INSTALL_PATH" ] || ln -sfn -- "$INSTALL_PATH" "$SHORTCUT_PATH"
        cat > "$OCM_SYSTEMD_DIR/$SERVICE_NAME" <<EOF
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
        cat > "$OCM_SYSTEMD_DIR/$HEALTH_SERVICE_NAME" <<EOF
# Managed by oc-master
[Unit]
Description=OpenConnect Master data-plane health check
After=${SERVICE_NAME}

[Service]
Type=oneshot
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${INSTALL_PATH} _service_health
EOF
        cat > "$OCM_SYSTEMD_DIR/$HEALTH_TIMER_NAME" <<EOF
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
      }
      if ! declare -p PROC_ROOT >/dev/null 2>&1; then
        # baseline 无 OCM_PROC_ROOT seam，等价地用受管 service active 证明进程存在。
        openconnect_process_is_alive() { systemctl is-active --quiet "$SERVICE_NAME"; }
      fi
      run_main "$2"
    ' compat-lifecycle "$script_path" "$action" > "$stdout_file" 2> "$stderr_file"
  rc=$?
  set -e
  printf '%s\n' "$rc" > "$rc_file"
}

initialize_lifecycle_root() {
  local version_root="$1"

  mkdir -p "$version_root" "$version_root/systemctl-state" "$version_root/proc/4242" \
    "$version_root/lock" "$version_root/systemd" "$version_root/network" "$version_root/scan"
  write_lifecycle_mocks "$version_root/mock-bin"
  printf '%s\n' 'Compat account|compat-user|compat-secret-7Z!|vpn.example.test|compat-group|nc' > "$version_root/accounts.env"
  printf '%s\n' '123e4567-e89b-42d3-a456-426614174011' > "$version_root/proc/uuid"
  printf '%s\n' '123e4567-e89b-42d3-a456-426614174012' > "$version_root/proc/boot_id"
  printf 'openconnect\n' > "$version_root/proc/4242/comm"
  printf '0::/system.slice/oc-master.service\n' > "$version_root/proc/4242/cgroup"
  printf '%s\n' 'default via 192.0.2.1 dev eth0 metric 100' > "$version_root/network/default4"
  : > "$version_root/network/default6"
  printf '%s\n' '2: eth0 inet 192.0.2.10/24 scope global eth0' > "$version_root/network/addr4"
  : > "$version_root/network/addr6"
  printf '%s\n' \
    '0: from all lookup local' \
    '32766: from all lookup main' \
    '32767: from all lookup default' > "$version_root/network/rule4"
  printf '%s\n' \
    '0: from all lookup local' \
    '32766: from all lookup main' > "$version_root/network/rule6"
  : > "$version_root/network/table4"
  : > "$version_root/network/table6"
  printf '%s\n' '2: eth0: <BROADCAST,MULTICAST,UP> mtu 1500' > "$version_root/network/links"
  : > "$version_root/systemctl.log"
  : > "$version_root/systemctl.effects"
  : > "$version_root/systemd-run.log"
  : > "$version_root/systemd-run.effects"
  : > "$version_root/ip.log"
  : > "$version_root/ip.effects"
}

run_proxy_lifecycle() {
  local script_path="$1" suffix="$2" version_root
  local action action_script

  version_root="${TEST_ROOT}/proxy-${suffix}"

  initialize_lifecycle_root "$version_root"

  run_lifecycle_action "$version_root" "$script_path" start-proxy $'1\n1080\n'
  action_script="$version_root/sbin/oc-master"
  [ -x "$action_script" ] || fail 'proxy start did not install its worker script'
  for action in _service_run status stop; do
    run_lifecycle_action "$version_root" "$action_script" "$action" ''
  done
  for action in start-proxy _service_run status stop; do
    if [ "$(<"$version_root/output/${action}.rc")" -ne 0 ]; then
      printf '%s\n' "--- proxy ${action} stdout (${suffix}) ---" >&2
      cat -- "$version_root/output/${action}.stdout" >&2
      printf '%s\n' "--- proxy ${action} stderr (${suffix}) ---" >&2
      cat -- "$version_root/output/${action}.stderr" >&2
    fi
    assert_eq 0 "$(<"$version_root/output/${action}.rc")" "proxy ${action} failed for variant ${suffix}"
  done
}

normalize_lifecycle_file() {
  local input_file="$1" output_file="$2" case_root="$3" script_path="$4" output

  output="$(cat -- "$input_file"; printf '\001')"
  output="${output%$'\001'}"
  output="${output//"$script_path"/<SOURCE_SCRIPT>}"
  output="${output//"$case_root"/<CASE_ROOT>}"
  output="${output//"$TEST_ROOT"/<TEST_ROOT>}"
  printf '%s' "$output" > "$output_file"
}

lifecycle_files_match() {
  local baseline_file="$1" current_file="$2" baseline_root="$3" current_root="$4"
  local current_script_path="${5:-$CURRENT_SCRIPT}"
  local baseline_normalized="${TEST_ROOT}/compare-baseline" current_normalized="${TEST_ROOT}/compare-current"

  normalize_lifecycle_file "$baseline_file" "$baseline_normalized" "$baseline_root" "$BASELINE_SCRIPT"
  normalize_lifecycle_file "$current_file" "$current_normalized" "$current_root" "$current_script_path"
  cmp -s -- "$baseline_normalized" "$current_normalized"
}

compare_proxy_lifecycle() {
  local action artifact baseline_file current_file

  for action in start-proxy _service_run status stop; do
    for artifact in stdout stderr rc; do
      baseline_file="${TEST_ROOT}/proxy-31/output/${action}.${artifact}"
      current_file="${TEST_ROOT}/proxy-32/output/${action}.${artifact}"
      if ! lifecycle_files_match "$baseline_file" "$current_file" \
        "${TEST_ROOT}/proxy-31" "${TEST_ROOT}/proxy-32"; then
        diff -u --label "baseline proxy ${action}.${artifact}" --label "current proxy ${action}.${artifact}" \
          "${TEST_ROOT}/compare-baseline" "${TEST_ROOT}/compare-current" >&2 || true
        fail "proxy ${action}.${artifact} changed"
      fi
    done
  done
  for artifact in openconnect.argv openconnect.stdin systemctl.effects systemd-run.effects ip.effects \
    accounts.env config/profile.conf; do
    baseline_file="${TEST_ROOT}/proxy-31/${artifact}"
    current_file="${TEST_ROOT}/proxy-32/${artifact}"
    if ! lifecycle_files_match "$baseline_file" "$current_file" \
      "${TEST_ROOT}/proxy-31" "${TEST_ROOT}/proxy-32"; then
      diff -u --label "baseline proxy ${artifact}" --label "current proxy ${artifact}" \
        "${TEST_ROOT}/compare-baseline" "${TEST_ROOT}/compare-current" >&2 || true
      fail "proxy ${artifact} changed"
    fi
  done
}

self_test_lifecycle_comparator() {
  local original="${TEST_ROOT}/proxy-32/openconnect.argv"
  local mutated="${TEST_ROOT}/proxy-32/openconnect.mutated.argv"

  sed 's/--reconnect-timeout=86400/--reconnect-timeout=1/' "$original" > "$mutated"
  cmp -s -- "$original" "$mutated" && fail 'lifecycle comparator mutation fixture did not change argv'
  if lifecycle_files_match "${TEST_ROOT}/proxy-31/openconnect.argv" "$mutated" \
    "${TEST_ROOT}/proxy-31" "${TEST_ROOT}/proxy-32"; then
    fail 'lifecycle comparator accepted a changed OpenConnect argument'
  fi
  printf 'lifecycle comparator mutation self-test passed\n'
}

run_global_lifecycle() {
  local script_path="$1" suffix="$2" version_root action action_script

  version_root="${TEST_ROOT}/global-${suffix}"
  initialize_lifecycle_root "$version_root"

  run_lifecycle_action "$version_root" "$script_path" start-global $'1\nGLOBAL\nKEEP\n'
  action_script="$version_root/sbin/oc-master"
  [ -x "$action_script" ] || fail 'global start did not install its worker script'
  for action in _service_run status stop; do
    run_lifecycle_action "$version_root" "$action_script" "$action" ''
  done
  for action in start-global _service_run status stop; do
    if [ "$(<"$version_root/output/${action}.rc")" -ne 0 ]; then
      printf '%s\n' "--- global ${action} stdout (${suffix}) ---" >&2
      cat -- "$version_root/output/${action}.stdout" >&2
      printf '%s\n' "--- global ${action} stderr (${suffix}) ---" >&2
      cat -- "$version_root/output/${action}.stderr" >&2
    fi
    assert_eq 0 "$(<"$version_root/output/${action}.rc")" "global ${action} failed for variant ${suffix}"
  done
}

compare_global_lifecycle() {
  local action artifact baseline_file current_file
  local baseline_root="${TEST_ROOT}/global-41" current_root="${TEST_ROOT}/global-42"

  for action in start-global _service_run status stop; do
    for artifact in stdout stderr rc; do
      baseline_file="${baseline_root}/output/${action}.${artifact}"
      current_file="${current_root}/output/${action}.${artifact}"
      if ! lifecycle_files_match "$baseline_file" "$current_file" "$baseline_root" "$current_root"; then
        diff -u --label "baseline global ${action}.${artifact}" --label "current global ${action}.${artifact}" \
          "${TEST_ROOT}/compare-baseline" "${TEST_ROOT}/compare-current" >&2 || true
        fail "global ${action}.${artifact} changed"
      fi
    done
  done
  # 新控制面会增加只读的归属/CAS 证明，因此保留完整调用日志用于审计，
  # 对真正改变服务或网络状态的 effect transcript 做严格等价比较。
  for artifact in openconnect.argv openconnect.stdin systemctl.effects systemd-run.effects ip.effects \
    accounts.env config/profile.conf; do
    baseline_file="${baseline_root}/${artifact}"
    current_file="${current_root}/${artifact}"
    if ! lifecycle_files_match "$baseline_file" "$current_file" "$baseline_root" "$current_root"; then
      diff -u --label "baseline global ${artifact}" --label "current global ${artifact}" \
        "${TEST_ROOT}/compare-baseline" "${TEST_ROOT}/compare-current" >&2 || true
      fail "global ${artifact} changed"
    fi
  done

  [ -s "${baseline_root}/systemctl.log" ] && [ -s "${current_root}/systemctl.log" ] \
    || fail 'global systemctl read transcript was not captured'
  [ -s "${baseline_root}/ip.log" ] && [ -s "${current_root}/ip.log" ] \
    || fail 'global ip read transcript was not captured'
  [ -s "${baseline_root}/systemd-run.log" ] && [ -s "${current_root}/systemd-run.log" ] \
    || fail 'global rollback transcript was not captured'
}

assert_rollback_transcript_contract() {
  local baseline_root="${TEST_ROOT}/global-41" current_root="${TEST_ROOT}/global-42"
  local baseline_expected current_expected

  baseline_expected="<--quiet><--unit=oc-master-rollback><--on-active=3m><--><${baseline_root}/sbin/oc-master><_rollback>"
  current_expected="<--quiet><--unit=oc-master-rollback><--on-active=3m><--><${current_root}/sbin/oc-master><_rollback><123e4567-e89b-42d3-a456-426614174011>"
  assert_eq 1 "$(wc -l < "${baseline_root}/systemd-run.log" | tr -d ' ')" \
    'baseline armed rollback more than once'
  assert_eq 1 "$(wc -l < "${current_root}/systemd-run.log" | tr -d ' ')" \
    'current armed rollback more than once'
  grep -Fx -- "$baseline_expected" "${baseline_root}/systemd-run.log" >/dev/null \
    || fail 'baseline rollback argv changed'
  grep -Fx -- "$current_expected" "${current_root}/systemd-run.log" >/dev/null \
    || fail 'current rollback argv differs beyond its required generation UUID'
}

assert_secret_boundary() {
  local root="$1" candidate

  assert_eq 'compat-secret-7Z!' "$(<"$root/openconnect.stdin")" \
    "OpenConnect password stdin changed for ${root##*/}"
  for candidate in "$root"/output/*.stdout "$root"/output/*.stderr \
    "$root/openconnect.argv" "$root/systemctl.log" "$root/systemctl.effects" \
    "$root/systemd-run.log" "$root/systemd-run.effects" "$root/ip.log" "$root/ip.effects"; do
    if grep -F 'compat-secret-7Z!' "$candidate" >/dev/null; then
      fail "password leaked outside OpenConnect stdin: $candidate"
    fi
  done
}

compare_case 'unknown-command' 'unknown-command' ''
compare_case 'status-without-profile' 'status' ''
compare_case 'main-menu-exit' '' $'0\n'
compare_case 'start-proxy-without-account' 'start-proxy' ''
compare_case 'accounts-menu-exit-without-account' 'accounts' $'0\n'

run_proxy_lifecycle "$BASELINE_SCRIPT" 31
run_proxy_lifecycle "$CURRENT_SCRIPT" 32
compare_proxy_lifecycle
self_test_lifecycle_comparator

run_global_lifecycle "$BASELINE_SCRIPT" 41
run_global_lifecycle "$CURRENT_SCRIPT" 42
compare_global_lifecycle
assert_rollback_transcript_contract
assert_secret_boundary "${TEST_ROOT}/proxy-31"
assert_secret_boundary "${TEST_ROOT}/proxy-32"
assert_secret_boundary "${TEST_ROOT}/global-41"
assert_secret_boundary "${TEST_ROOT}/global-42"

grep -F 'start-proxy|start-global|stop|accounts|deps|install|uninstall|status|check|logs' "$CURRENT_SCRIPT" >/dev/null \
  || fail 'public command set changed'
grep -F '请选择 [0-9]:' "$CURRENT_SCRIPT" >/dev/null || fail 'main menu prompt changed'
grep -F '[ "$answer" = "GLOBAL" ]' "$CURRENT_SCRIPT" >/dev/null || fail 'GLOBAL confirmation changed'
grep -F '[ "$answer" = "GLOBAL-DDNS-RISK" ]' "$CURRENT_SCRIPT" >/dev/null || fail 'GLOBAL-DDNS-RISK confirmation changed'
grep -F '[ "$answer" = "KEEP" ]' "$CURRENT_SCRIPT" >/dev/null || fail 'KEEP confirmation changed'
grep -F 'socks_port="${socks_port:-1080}"' "$CURRENT_SCRIPT" >/dev/null || fail 'default SOCKS port changed'
grep -F 'readonly RETURN4_TABLE="51888"' "$CURRENT_SCRIPT" >/dev/null || fail 'IPv4 return table changed'
grep -F 'readonly RETURN6_TABLE="51889"' "$CURRENT_SCRIPT" >/dev/null || fail 'IPv6 return table changed'
grep -F 'readonly RETURN4_PRIORITY="10000"' "$CURRENT_SCRIPT" >/dev/null || fail 'IPv4 rule priority changed'
grep -F 'readonly RETURN6_PRIORITY="10001"' "$CURRENT_SCRIPT" >/dev/null || fail 'IPv6 rule priority changed'

printf 'compatibility checks passed\n'
