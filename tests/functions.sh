#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "${BASH_SOURCE[0]%/*}/.."

TEST_ROOT="$(mktemp -d)"
cleanup() {
  [ -n "${TEST_ROOT:-}" ] && [ -d "$TEST_ROOT" ] && rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

export OCM_INSTALL_PATH="${TEST_ROOT}/sbin/oc-master"
export OCM_SHORTCUT_PATH="${TEST_ROOT}/bin/ocm"
export OCM_CONFIG_DIR="${TEST_ROOT}/config"
export OCM_RUNTIME_DIR="${TEST_ROOT}/run"
export OCM_LOCK_FILE="${TEST_ROOT}/lock/oc-master.lock"
export OCM_DDNS_SCAN_ROOT="${TEST_ROOT}/scan"

# shellcheck source=../oc_master.sh
source ./oc_master.sh

fail() {
  printf 'function test failed: %s\n' "$*" >&2
  exit 1
}

parse_account_line 'valid|user|password|https://vpn.example.test||nc' || fail "valid account was rejected"
if parse_account_line 'invalid|user|password|--help||nc' >/dev/null 2>&1; then
  fail "option-like VPN host was accepted"
fi

systemctl() {
  [ "$*" = "is-active --quiet $SERVICE_NAME" ]
}
if install_command >/dev/null 2>&1; then
  fail "managed script was replaced while its service was active"
fi
[ ! -e "$OCM_INSTALL_PATH" ] || fail "active-service install wrote a managed copy"
unset -f systemctl

mkdir -p "${OCM_DDNS_SCAN_ROOT}/etc/cron.d"
ddns_automation_detected && fail "empty scan root was reported as DDNS"

printf '%s\n' '*/5 * * * * root /usr/local/bin/ordinary-job' > "${OCM_DDNS_SCAN_ROOT}/etc/crontab"
ddns_automation_detected && fail "unrelated cron job was reported as DDNS"

printf '%s\n' '*/2 * * * * root /root/cf-v4-ddns.sh' > "${OCM_DDNS_SCAN_ROOT}/etc/cron.d/cloudflare"
ddns_automation_detected || fail "DDNS cron job was not detected"
rm -f -- "${OCM_DDNS_SCAN_ROOT}/etc/cron.d/cloudflare"
mkdir -p "${OCM_DDNS_SCAN_ROOT}/etc/systemd/system"
printf '%s\n' '[Service]' 'ExecStart=/usr/sbin/ddclient' > "${OCM_DDNS_SCAN_ROOT}/etc/systemd/system/ddclient.service"
ddns_automation_detected || fail "DDNS systemd job was not detected"

ss() {
  printf '%s\n' 'LISTEN 0 4096 127.0.0.1:1080 0.0.0.0:*'
}
tcp_port_is_listening 1080 || fail "existing TCP listener was not detected"
if tcp_port_is_listening 1081; then
  fail "unused TCP port was reported as listening"
fi
unset -f ss

ip() {
  case "$*" in
    '-4 rule show') printf '%s\n' '10000: from all lookup main' ;;
    *) return 0 ;;
  esac
}
route_state_conflicts || fail "occupied policy-rule priority was not detected"
unset -f ip

MOCK_SYSTEMCTL_CALLS="${TEST_ROOT}/systemctl.calls"
systemctl() {
  printf '%s\n' "$*" >> "$MOCK_SYSTEMCTL_CALLS"
  [ "$*" != "start $SERVICE_NAME" ]
}
if start_managed_units; then
  fail "systemd start-chain failure was not propagated"
fi
[ "$(wc -l < "$MOCK_SYSTEMCTL_CALLS" | tr -d ' ')" = '3' ] || fail "systemd chain continued after a failed service start"
unset -f systemctl

service_main_pid() {
  printf '0\n'
}
MOCK_STOP_STATE='active'
systemctl() {
  case "$1" in
    stop) [ "$MOCK_STOP_STATE" = 'inactive' ] ;;
    is-active)
      [ "$MOCK_STOP_STATE" = 'unknown' ] && return 1
      printf '%s\n' "$MOCK_STOP_STATE"
      [ "$MOCK_STOP_STATE" = 'active' ]
      ;;
    disable) return 0 ;;
    *) return 0 ;;
  esac
}
if stop_and_disable_managed_units >/dev/null 2>&1; then
  fail "active service was accepted as stopped"
fi
MOCK_STOP_STATE='unknown'
if stop_and_disable_managed_units >/dev/null 2>&1; then
  fail "unverifiable failed stop was accepted"
fi
MOCK_STOP_STATE='inactive'
stop_and_disable_managed_units || fail "confirmed inactive service was rejected"
unset -f systemctl service_main_pid

if command -v flock >/dev/null 2>&1; then
  acquire_manager_lock
  if (acquire_manager_lock) >/dev/null 2>&1; then
    fail "a concurrent manager lock was accepted"
  fi
else
  printf 'lock checks skipped: flock is unavailable\n'
fi

if ln -s -- 'probe-target' "${TEST_ROOT}/symlink-probe" 2>/dev/null && [ -L "${TEST_ROOT}/symlink-probe" ]; then
  rm -f -- "${TEST_ROOT}/symlink-probe"

  install_managed_copy
  [ -x "$OCM_INSTALL_PATH" ] || fail "managed executable was not installed"
  [ -L "$OCM_SHORTCUT_PATH" ] || fail "shortcut was not created"
  [ "$(readlink "$OCM_SHORTCUT_PATH")" = "$OCM_INSTALL_PATH" ] || fail "shortcut target is wrong"

  remove_managed_shortcut
  [ ! -e "$OCM_SHORTCUT_PATH" ] && [ ! -L "$OCM_SHORTCUT_PATH" ] || fail "owned shortcut was not removed"

  printf '%s\n' 'foreign shortcut' > "$OCM_SHORTCUT_PATH"
  printf '%s\n' 'previous managed copy' > "$OCM_INSTALL_PATH"
  if install_managed_copy >/dev/null 2>&1; then
    fail "foreign shortcut was overwritten"
  fi
  grep -Fx 'foreign shortcut' "$OCM_SHORTCUT_PATH" >/dev/null || fail "foreign shortcut content changed"
  grep -Fx 'previous managed copy' "$OCM_INSTALL_PATH" >/dev/null || fail "managed copy changed despite shortcut conflict"
else
  rm -f -- "${TEST_ROOT}/symlink-probe"
  printf 'shortcut checks skipped: filesystem does not expose POSIX symlinks\n'
fi

MOCK_CLEANUP_CALLS="${TEST_ROOT}/cleanup.calls"
MOCK_STOP_RESULT=0
stop_and_disable_managed_units() {
  printf '%s\n' stop >> "$MOCK_CLEANUP_CALLS"
  return "$MOCK_STOP_RESULT"
}
service_cleanup() { printf '%s\n' cleanup >> "$MOCK_CLEANUP_CALLS"; }
cancel_rollback() { printf '%s\n' cancel >> "$MOCK_CLEANUP_CALLS"; }

cleanup_start_attempt || fail "confirmed stopped start attempt was not cleaned"
[ "$(tr '\n' ' ' < "$MOCK_CLEANUP_CALLS")" = 'stop cleanup cancel ' ] \
  || fail "start-attempt cleanup order is wrong"

: > "$MOCK_CLEANUP_CALLS"
MOCK_STOP_RESULT=1
if cleanup_start_attempt >/dev/null 2>&1; then
  fail "failed service stop was accepted during start-attempt cleanup"
fi
[ "$(tr '\n' ' ' < "$MOCK_CLEANUP_CALLS")" = 'stop ' ] \
  || fail "routes or rollback were changed after an unconfirmed service stop"

: > "$MOCK_CLEANUP_CALLS"
MOCK_STOP_RESULT=0
check_root() { :; }
log() { printf '%s\n' log >> "$MOCK_CLEANUP_CALLS"; }
stop_vpn
[ "$(tr '\n' ' ' < "$MOCK_CLEANUP_CALLS")" = 'stop cleanup cancel log ' ] \
  || fail "manual stop did not preserve stop-cleanup-cancel order"

printf 'function checks passed\n'
