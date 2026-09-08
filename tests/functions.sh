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

if ! (
  ip() {
    case "$*" in
      '-4 rule show'|'-6 rule show'|"-4 route show table $RETURN4_TABLE") : ;;
      "-6 route show table $RETURN6_TABLE")
        printf '%s\n' 'Error: ipv6: FIB table does not exist.' 'Dump terminated' >&2
        return 2
        ;;
      '-o link show') printf '%s\n' '2: eth0: <BROADCAST,MULTICAST,UP> mtu 1500' ;;
      *) return 0 ;;
    esac
  }
  return_route_state_is_clean
); then
  fail "an absent IPv6 FIB table was treated as residual routing state"
fi

MOCK_ROUTE_CLEANUP_RESULT=0
(
  mkdir -p "$(dirname "$ROUTE_OWNER_FILE")"
  printf '%s\n' 'DEFAULT4=default via 192.0.2.1 dev eth0' 'DEFAULT6=' > "$ROUTE_OWNER_FILE"
  ip() {
    case "$*" in
      "-4 rule del priority $RETURN4_PRIORITY lookup $RETURN4_TABLE") return 1 ;;
      '-4 rule show') printf '%s\n' "$RETURN4_PRIORITY: from 192.0.2.10 lookup $RETURN4_TABLE" ;;
      '-6 rule show') : ;;
      "-4 route show table $RETURN4_TABLE"|"-6 route show table $RETURN6_TABLE") : ;;
      "link show dev $VPN_INTERFACE") return 1 ;;
      '-4 route show default') printf '%s\n' 'default via 192.0.2.1 dev eth0' ;;
      '-6 route show default') : ;;
      *) return 0 ;;
    esac
  }
  if cleanup_return_routes >/dev/null 2>&1; then
    exit 11
  fi
  [ -e "$ROUTE_OWNER_FILE" ] || exit 12
) || MOCK_ROUTE_CLEANUP_RESULT=$?
case "$MOCK_ROUTE_CLEANUP_RESULT" in
  0) ;;
  11) fail "return-route cleanup accepted a policy rule that remained installed" ;;
  12) fail "return-route ownership marker was removed after incomplete cleanup" ;;
  *) fail "return-route cleanup test failed unexpectedly (rc=$MOCK_ROUTE_CLEANUP_RESULT)" ;;
esac

if (
  printf '%s\n' 'DEFAULT4=' 'DEFAULT6=' > "$ROUTE_OWNER_FILE"
  ip() {
    case "$*" in
      '-4 rule show'|'-6 rule show'|'-4 route show default'|'-6 route show default'|"-4 route show table $RETURN4_TABLE"|"-6 route show table $RETURN6_TABLE") : ;;
      "link show dev $VPN_INTERFACE") return 1 ;;
      '-o link show') printf '%s\n' '2: eth0: <BROADCAST,MULTICAST,UP> mtu 1500' ;;
      *) return 0 ;;
    esac
  }
  cleanup_return_routes >/dev/null 2>&1
); then
  fail "cleanup accepted an ownership marker without the saved IPv4 default route"
fi
[ -e "$ROUTE_OWNER_FILE" ] || fail "invalid route ownership marker was removed"

if (
  printf '%s\n' 'DEFAULT4=default via 192.0.2.1 dev eth0' 'DEFAULT6=' > "$ROUTE_OWNER_FILE"
  ip() {
    case "$*" in
      '-4 rule show'|'-6 rule show'|"-4 route show table $RETURN4_TABLE"|"-6 route show table $RETURN6_TABLE") : ;;
      "-4 rule del priority $RETURN4_PRIORITY lookup $RETURN4_TABLE"|"-6 rule del priority $RETURN6_PRIORITY lookup $RETURN6_TABLE") return 1 ;;
      "link show dev $VPN_INTERFACE") return 1 ;;
      '-o link show') printf '%s\n' '2: eth0: <BROADCAST,MULTICAST,UP> mtu 1500' ;;
      '-4 route show default') printf '%s\n' 'blackhole default metric 42760' ;;
      '-6 route show default') : ;;
      '-4 route replace '*) return 1 ;;
      *) return 0 ;;
    esac
  }
  cleanup_return_routes >/dev/null 2>&1
); then
  fail "a blackhole default route was accepted as restored connectivity"
fi
[ -e "$ROUTE_OWNER_FILE" ] || fail "route ownership marker was removed without a usable default route"

if ! (
  printf '%s\n' 'DEFAULT4=default via 192.0.2.1 dev eth0' 'DEFAULT6=' > "$ROUTE_OWNER_FILE"
  ip() {
    case "$*" in
      "-4 rule del priority $RETURN4_PRIORITY lookup $RETURN4_TABLE"|"-6 rule del priority $RETURN6_PRIORITY lookup $RETURN6_TABLE") return 1 ;;
      '-4 rule show'|'-6 rule show'|"-4 route show table $RETURN4_TABLE"|"-6 route show table $RETURN6_TABLE") : ;;
      "link show dev $VPN_INTERFACE") return 1 ;;
      '-o link show') printf '%s\n' '2: eth0: <BROADCAST,MULTICAST,UP> mtu 1500' ;;
      '-4 route show default') printf '%s\n' 'default via 192.0.2.1 dev eth0' ;;
      '-6 route show default') : ;;
      *) return 0 ;;
    esac
  }
  cleanup_return_routes >/dev/null 2>&1
  [ ! -e "$ROUTE_OWNER_FILE" ]
); then
  fail "verified clean return-route state did not release its ownership marker"
fi

if (
  check_root() { :; }
  cleanup_return_routes() { return 1; }
  service_cleanup >/dev/null 2>&1
); then
  fail "service cleanup hid a return-route cleanup failure"
fi

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

if ! (
  MOCK_PREPARE_MAIN_STATE='activating'
  MOCK_PREPARE_HEALTH_STATE='inactive'
  MOCK_PREPARE_TIMER_STATE='inactive'
  systemctl() {
    local action="$1" quiet=0 unit state
    shift
    case "$action" in
      is-active)
        if [ "${1:-}" = '--quiet' ]; then quiet=1; shift; fi
        unit="$1"
        case "$unit" in
          "$SERVICE_NAME") state="$MOCK_PREPARE_MAIN_STATE" ;;
          "$HEALTH_SERVICE_NAME") state="$MOCK_PREPARE_HEALTH_STATE" ;;
          "$HEALTH_TIMER_NAME") state="$MOCK_PREPARE_TIMER_STATE" ;;
        esac
        [ "$quiet" -eq 1 ] || printf '%s\n' "$state"
        [ "$state" = 'active' ] || [ "$state" = 'reloading' ]
        ;;
      stop)
        for unit in "$@"; do
          case "$unit" in
            "$SERVICE_NAME") MOCK_PREPARE_MAIN_STATE='inactive' ;;
            "$HEALTH_SERVICE_NAME") MOCK_PREPARE_HEALTH_STATE='inactive' ;;
            "$HEALTH_TIMER_NAME") MOCK_PREPARE_TIMER_STATE='inactive' ;;
          esac
        done
        ;;
      show) printf '0\n' ;;
      disable) : ;;
      *) : ;;
    esac
  }
  pgrep() { return 1; }
  prepare_service_replacement <<< 'y' >/dev/null 2>&1
  [ "$MOCK_PREPARE_MAIN_STATE" = 'inactive' ]
); then
  fail "an activating auto-restart job was not stopped before profile replacement"
fi

MOCK_GLOBAL_START_CALLS="${TEST_ROOT}/global-start.calls"
if (
  ensure_dependencies() { :; }
  select_account() { export ACCOUNT_INDEX=0 VPN_PROTOCOL='nc'; }
  confirm_global_risk() { :; }
  prepare_service_replacement() { :; }
  install_self_and_units() { :; }
  write_profile() { :; }
  cancel_rollback() { printf '%s\n' cancel >> "$MOCK_GLOBAL_START_CALLS"; }
  systemd-run() { printf '%s\n' rollback >> "$MOCK_GLOBAL_START_CALLS"; return 1; }
  start_managed_units() { printf '%s\n' start >> "$MOCK_GLOBAL_START_CALLS"; return 0; }
  wait_until_healthy() { return 1; }
  cleanup_start_attempt() { printf '%s\n' cleanup >> "$MOCK_GLOBAL_START_CALLS"; return 0; }
  journalctl() { :; }
  log_info() { :; }
  log_warn() { :; }
  log_err() { :; }
  start_mode global </dev/null >/dev/null 2>&1
); then
  fail "global start unexpectedly succeeded without a rollback unit"
fi
if grep -Fx start "$MOCK_GLOBAL_START_CALLS" >/dev/null 2>&1; then
  fail "global service started after rollback arming failed"
fi

for signal_spec in 'SIGHUP:129' 'SIGINT:130' 'SIGTERM:143'; do
  signal_name="${signal_spec%%:*}"
  expected_rc="${signal_spec##*:}"
  set +e
  (
    clear_start_signal_traps() { :; }
    cleanup_start_attempt() { :; }
    log_warn() { :; }
    handle_interrupted_start "$signal_name" "$expected_rc"
  ) >/dev/null 2>&1
  actual_rc=$?
  set -e
  [ "$actual_rc" -eq "$expected_rc" ] \
    || fail "$signal_name startup interruption returned $actual_rc instead of $expected_rc"
done

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

if ! (
  MOCK_MAIN_STATE='active'
  MOCK_HEALTH_STATE='active'
  service_main_pid() { printf '0\n'; }
  systemctl() {
    local action="$1" unit
    shift
    case "$action" in
      stop)
        for unit in "$@"; do
          case "$unit" in
            "$HEALTH_TIMER_NAME") : ;;
            "$HEALTH_SERVICE_NAME") MOCK_HEALTH_STATE='inactive' ;;
            "$SERVICE_NAME")
              if [ "$MOCK_HEALTH_STATE" = 'active' ]; then
                MOCK_MAIN_STATE='active'
              else
                MOCK_MAIN_STATE='inactive'
              fi
              ;;
          esac
        done
        ;;
      is-active)
        case "$1" in
          "$HEALTH_SERVICE_NAME") printf '%s\n' "$MOCK_HEALTH_STATE"; [ "$MOCK_HEALTH_STATE" = 'active' ] ;;
          "$SERVICE_NAME") printf '%s\n' "$MOCK_MAIN_STATE"; [ "$MOCK_MAIN_STATE" = 'active' ] ;;
          *) printf '%s\n' inactive; return 3 ;;
        esac
        ;;
      disable) : ;;
      *) : ;;
    esac
  }
  stop_and_disable_managed_units >/dev/null 2>&1
); then
  fail "health checker was not quiesced before the main VPN service"
fi

MOCK_DELAYED_RACE_DIR="${TEST_ROOT}/delayed-health-race"
mkdir -p "$MOCK_DELAYED_RACE_DIR"
printf '%s\n' active > "$MOCK_DELAYED_RACE_DIR/main.state"
if (
  service_main_pid() { printf '0\n'; }
  systemctl() {
    local action="$1" state
    shift
    case "$action" in
      stop)
        case "$1" in
          "$SERVICE_NAME")
            printf '%s\n' inactive > "$MOCK_DELAYED_RACE_DIR/main.state"
            : > "$MOCK_DELAYED_RACE_DIR/restart.pending"
            ;;
        esac
        ;;
      is-active)
        case "$1" in
          "$HEALTH_TIMER_NAME") printf '%s\n' inactive; return 3 ;;
          "$HEALTH_SERVICE_NAME")
            if [ -e "$MOCK_DELAYED_RACE_DIR/restart.pending" ]; then
              printf '%s\n' active > "$MOCK_DELAYED_RACE_DIR/main.state"
              rm -f "$MOCK_DELAYED_RACE_DIR/restart.pending"
            fi
            printf '%s\n' inactive
            return 3
            ;;
          "$SERVICE_NAME")
            state="$(cat "$MOCK_DELAYED_RACE_DIR/main.state")"
            printf '%s\n' "$state"
            [ "$state" = 'active' ]
            ;;
        esac
        ;;
      disable) : ;;
      *) : ;;
    esac
  }
  stop_and_disable_managed_units >/dev/null 2>&1
); then
  fail "a delayed health restart of the main VPN service was accepted as stopped"
fi

if (
  MOCK_MAIN_STATE='active'
  service_main_pid() { printf '0\n'; }
  systemctl() {
    local action="$1"
    shift
    case "$action" in
      stop)
        case "$1" in
          "$HEALTH_SERVICE_NAME") return 1 ;;
          "$SERVICE_NAME") MOCK_MAIN_STATE='inactive' ;;
        esac
        ;;
      is-active)
        case "$1" in
          "$HEALTH_TIMER_NAME") printf '%s\n' inactive; return 3 ;;
          "$HEALTH_SERVICE_NAME") printf '%s\n' active; return 0 ;;
          "$SERVICE_NAME") printf '%s\n' "$MOCK_MAIN_STATE"; [ "$MOCK_MAIN_STATE" = 'active' ] ;;
        esac
        ;;
      disable) : ;;
      *) : ;;
    esac
  }
  stop_and_disable_managed_units >/dev/null 2>&1
); then
  fail "active health service was accepted as stopped"
fi

if (
  service_main_pid() { printf '0\n'; }
  systemctl() {
    local action="$1"
    shift
    case "$action" in
      stop|disable) : ;;
      is-active)
        case "$1" in
          "$HEALTH_TIMER_NAME"|"$SERVICE_NAME") printf '%s\n' inactive; return 3 ;;
          "$HEALTH_SERVICE_NAME") printf '%s\n' unknown; return 4 ;;
        esac
        ;;
      *) : ;;
    esac
  }
  stop_and_disable_managed_units >/dev/null 2>&1
); then
  fail "unknown health-service state was accepted as stopped"
fi

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
MOCK_CLEANUP_RESULT=0
stop_and_disable_managed_units() {
  printf '%s\n' stop >> "$MOCK_CLEANUP_CALLS"
  return "$MOCK_STOP_RESULT"
}
service_cleanup() {
  printf '%s\n' cleanup >> "$MOCK_CLEANUP_CALLS"
  return "$MOCK_CLEANUP_RESULT"
}
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
MOCK_CLEANUP_RESULT=1
if cleanup_start_attempt >/dev/null 2>&1; then
  fail "failed route cleanup was accepted during start-attempt cleanup"
fi
[ "$(tr '\n' ' ' < "$MOCK_CLEANUP_CALLS")" = 'stop cleanup ' ] \
  || fail "rollback was cancelled after incomplete route cleanup"

: > "$MOCK_CLEANUP_CALLS"
MOCK_STOP_RESULT=0
MOCK_CLEANUP_RESULT=1
check_root() { :; }
log() { printf '%s\n' log >> "$MOCK_CLEANUP_CALLS"; }
if stop_vpn >/dev/null 2>&1; then
  fail "manual stop reported success after incomplete route cleanup"
fi
[ "$(tr '\n' ' ' < "$MOCK_CLEANUP_CALLS")" = 'stop cleanup ' ] \
  || fail "manual stop cancelled rollback or logged success after incomplete route cleanup"

: > "$MOCK_CLEANUP_CALLS"
MOCK_CLEANUP_RESULT=0
stop_vpn
[ "$(tr '\n' ' ' < "$MOCK_CLEANUP_CALLS")" = 'stop cleanup cancel log ' ] \
  || fail "manual stop did not preserve stop-cleanup-cancel order"

: > "$MOCK_CLEANUP_CALLS"
MOCK_STOP_RESULT=1
if rollback_now >/dev/null 2>&1; then
  fail "automatic rollback reported success without confirming the tunnel stopped"
fi
[ "$(tr '\n' ' ' < "$MOCK_CLEANUP_CALLS")" = 'stop ' ] \
  || fail "automatic rollback cleaned routes before confirming the tunnel stopped"

printf 'function checks passed\n'
