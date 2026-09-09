#!/usr/bin/env bash
set -Eeuo pipefail

PATH="/usr/bin:/bin:${PATH}"
export PATH

cd -- "${BASH_SOURCE[0]%/*}/.."

# shellcheck source=tests/testlib.sh
source tests/testlib.sh

TEST_ROOT="$(new_test_root)"
BACKGROUND_PIDS=""
cleanup() {
  local pid
  for pid in $BACKGROUND_PIDS; do
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  done
  cleanup_test_root "$TEST_ROOT"
}
trap cleanup EXIT

export_test_paths "$TEST_ROOT"
mkdir -p -- "$OCM_CONFIG_DIR" "$OCM_RUNTIME_DIR" "${OCM_STATE_LOCK_FILE%/*}" \
  "${OCM_BOOT_ID_FILE%/*}"

readonly RUN_A='123e4567-e89b-42d3-a456-426614174020'
readonly RUN_B='123e4567-e89b-42d3-a456-426614174021'
readonly BOOT_A='123e4567-e89b-42d3-a456-426614174022'
readonly BOOT_B='123e4567-e89b-42d3-a456-426614174023'
readonly ACCOUNT='Lifecycle|alice|top-secret|vpn.example.test|group-a|nc'

printf '%s\n' "$RUN_A" > "$OCM_UUID_FILE"
printf '%s\n' "$BOOT_A" > "$OCM_BOOT_ID_FILE"

# shellcheck source=../oc_master.sh
source oc_master.sh

# Git Bash may not ship util-linux flock. State behavior remains testable there;
# Linux CI exercises the same cases with the real advisory locks.
if ! command -v flock >/dev/null 2>&1; then
  flock() { return 0; }
fi

check_root() { :; }
ensure_dirs() {
  mkdir -p -- "$CONFIG_DIR" "$RUNTIME_DIR" "${STATE_LOCK_FILE%/*}" "${SERVICE_LOCK_FILE%/*}"
}

write_runtime_fixture() {
  local run_id="$1" boot_id="$2" mode="$3" phase="$4" desired="$5" deadline="$6"
  local socks_port=1080
  [ "$mode" = proxy ] || socks_port=""
  write_active_run "$run_id" "$boot_id" "$mode" 0 nc "$socks_port" "$ACCOUNT"
  write_run_state "$run_id" "$phase" "$desired" "$deadline"
}

wait_for_file() {
  local path="$1" label="$2"
  for _ in $(seq 1 200); do
    [ -e "$path" ] && return 0
    /usr/bin/sleep 0.01
  done
  fail "timed out waiting for barrier: $label"
}

assert_state() {
  local phase="$1" desired="$2" deadline="$3" message="$4"
  load_run_state || fail "$message: state could not be loaded"
  assert_eq "$phase" "$PHASE" "$message: phase"
  assert_eq "$desired" "$DESIRED_ACTIVE" "$message: desired-active"
  assert_eq "$deadline" "$ROLLBACK_DEADLINE" "$message: deadline"
}

# A stale rollback worker must not touch the current generation.
write_runtime_fixture "$RUN_B" "$BOOT_A" proxy RUNNING 1 0
STALE_CALLS="${TEST_ROOT}/stale-rollback.calls"
(
  stop_and_disable_managed_units() { printf '%s\n' stop >> "$STALE_CALLS"; }
  cleanup_run_generation() { printf '%s\n' cleanup >> "$STALE_CALLS"; }
  rollback_now "$RUN_A" >/dev/null 2>&1
) || fail 'stale rollback did not exit harmlessly'
[ ! -e "$STALE_CALLS" ] || fail 'stale rollback changed the current service or cleanup state'
assert_state RUNNING 1 0 'stale rollback changed current state'

# Proxy lifecycle must commit STARTING before systemd and RUNNING only after health.
rm -f -- "$ACTIVE_RUN_FILE" "$RUN_STATE_FILE"
ensure_dependencies() { :; }
prepare_runtime_configuration_for_start() { :; }
select_account() { export ACCOUNT_INDEX=0 VPN_PROTOCOL=nc ACCOUNT_RECORD="$ACCOUNT"; }
prepare_service_replacement() { :; }
install_self_and_units() { :; }
start_managed_units() { :; }
wait_until_healthy() { return 0; }
start_mode proxy <<< '' >/dev/null || fail 'proxy lifecycle rejected a healthy start'
assert_state RUNNING 1 0 'proxy lifecycle did not finish in RUNNING'
unset -f ensure_dependencies prepare_runtime_configuration_for_start select_account \
  prepare_service_replacement install_self_and_units start_managed_units wait_until_healthy

# Global lifecycle must expose AWAITING_CONFIRMATION before reading KEEP.
rm -f -- "$ACTIVE_RUN_FILE" "$RUN_STATE_FILE"
GLOBAL_READY="${TEST_ROOT}/global.ready"
GLOBAL_RELEASE="${TEST_ROOT}/global.release"
GLOBAL_RESULT="${TEST_ROOT}/global.result"
(
  ensure_dependencies() { :; }
  prepare_runtime_configuration_for_start() { :; }
  select_account() { export ACCOUNT_INDEX=0 VPN_PROTOCOL=nc ACCOUNT_RECORD="$ACCOUNT"; }
  confirm_global_risk() { :; }
  prepare_service_replacement() { :; }
  install_self_and_units() { :; }
  start_managed_units() { :; }
  wait_until_healthy() { return 0; }
  systemctl() {
    case "$1" in
      is-active) return 3 ;;
      *) return 0 ;;
    esac
  }
  systemd-run() { return 0; }
  read() {
    local target="${!#}"
    case " $* " in
      *' -t '*) ;;
      *) builtin read "$@"; return ;;
    esac
    : > "$GLOBAL_READY"
    while [ ! -e "$GLOBAL_RELEASE" ]; do /usr/bin/sleep 0.01; done
    printf -v "$target" '%s' KEEP
  }
  if start_mode global >/dev/null 2>&1; then printf '0\n' > "$GLOBAL_RESULT"; else printf '%s\n' "$?" > "$GLOBAL_RESULT"; fi
) &
GLOBAL_PID=$!
BACKGROUND_PIDS="$BACKGROUND_PIDS $GLOBAL_PID"
wait_for_file "$GLOBAL_READY" 'global confirmation prompt'
load_run_state || fail 'global state was unreadable at confirmation barrier'
assert_eq AWAITING_CONFIRMATION "$PHASE" 'global lifecycle did not reach AWAITING_CONFIRMATION'
assert_eq 1 "$DESIRED_ACTIVE" 'global lifecycle became inactive before confirmation'
[[ "$ROLLBACK_DEADLINE" =~ ^[1-9][0-9]*$ ]] || fail 'global confirmation deadline was not persisted'
: > "$GLOBAL_RELEASE"
wait "$GLOBAL_PID"
BACKGROUND_PIDS="${BACKGROUND_PIDS/ $GLOBAL_PID/}"
assert_eq 0 "$(cat "$GLOBAL_RESULT")" 'global KEEP path returned failure'
assert_state CONFIRMED 1 0 'global KEEP did not persist CONFIRMED'

# KEEP wins: an already-created worker released by a deterministic barrier has no side effect.
write_runtime_fixture "$RUN_A" "$BOOT_A" global AWAITING_CONFIRMATION 1 1000
KEEP_WORKER_RELEASE="${TEST_ROOT}/keep-worker.release"
KEEP_WORKER_STARTED="${TEST_ROOT}/keep-worker.started"
KEEP_SIDE_EFFECTS="${TEST_ROOT}/keep.side-effects"
(
  : > "$KEEP_WORKER_STARTED"
  while [ ! -e "$KEEP_WORKER_RELEASE" ]; do /usr/bin/sleep 0.01; done
  stop_and_disable_managed_units() { printf '%s\n' stop >> "$KEEP_SIDE_EFFECTS"; }
  cleanup_run_generation() { printf '%s\n' cleanup >> "$KEEP_SIDE_EFFECTS"; }
  date() { printf '1000\n'; }
  rollback_now "$RUN_A"
) &
KEEP_PID=$!
BACKGROUND_PIDS="$BACKGROUND_PIDS $KEEP_PID"
wait_for_file "$KEEP_WORKER_STARTED" 'KEEP-first worker start'
systemctl() {
  case "$1" in
    is-active) return 3 ;;
    *) return 0 ;;
  esac
}
confirm_global_run "$RUN_A" >/dev/null || fail 'KEEP could not claim an awaiting generation'
: > "$KEEP_WORKER_RELEASE"
wait "$KEEP_PID"
BACKGROUND_PIDS="${BACKGROUND_PIDS/ $KEEP_PID/}"
[ ! -e "$KEEP_SIDE_EFFECTS" ] || fail 'rollback worker acted after KEEP won'
assert_state CONFIRMED 1 0 'rollback worker reversed KEEP'
unset -f systemctl

# Persistent confirmation remains successful when transient unit cleanup leaves evidence.
write_runtime_fixture "$RUN_A" "$BOOT_A" global AWAITING_CONFIRMATION 1 1000
CONFIRM_WARNING="${TEST_ROOT}/confirm-warning.output"
systemctl() {
  case "$1" in
    is-active) printf 'failed\n'; return 3 ;;
    *) return 1 ;;
  esac
}
confirm_global_run "$RUN_A" >"$CONFIRM_WARNING" 2>&1 \
  || fail 'persisted KEEP was reversed by transient unit cleanup failure'
assert_state CONFIRMED 1 0 'unit cleanup failure reversed persistent confirmation'
grep -F '清理失败' "$CONFIRM_WARNING" >/dev/null \
  || fail 'transient unit cleanup failure did not emit an actionable warning'
unset -f systemctl

# Rollback wins: hold it after the persistent claim, then prove KEEP loses without success text.
write_runtime_fixture "$RUN_A" "$BOOT_A" global AWAITING_CONFIRMATION 1 1000
printf '%s\n' "$RUN_A" > "$SERVICE_RUN_ID_FILE"
ROLLBACK_READY="${TEST_ROOT}/rollback.ready"
ROLLBACK_RELEASE="${TEST_ROOT}/rollback.release"
ROLLBACK_RESULT="${TEST_ROOT}/rollback.result"
(
  date() { printf '1000\n'; }
  stop_and_disable_managed_units() {
    : > "$ROLLBACK_READY"
    while [ ! -e "$ROLLBACK_RELEASE" ]; do /usr/bin/sleep 0.01; done
  }
  cleanup_return_routes() { return 0; }
  if rollback_now "$RUN_A"; then printf '0\n' > "$ROLLBACK_RESULT"; else printf '%s\n' "$?" > "$ROLLBACK_RESULT"; fi
) &
ROLLBACK_PID=$!
BACKGROUND_PIDS="$BACKGROUND_PIDS $ROLLBACK_PID"
wait_for_file "$ROLLBACK_READY" 'rollback persistent claim'
assert_state ROLLBACK_CLAIMED 0 0 'rollback did not persist its claim before stopping'
KEEP_OUTPUT="${TEST_ROOT}/keep-lost.output"
set +e
confirm_global_run "$RUN_A" >"$KEEP_OUTPUT" 2>&1
KEEP_RC=$?
set -e
[ "$KEEP_RC" -ne 0 ] || fail 'KEEP succeeded after rollback claimed the generation'
if grep -F '取消独立回滚' "$KEEP_OUTPUT" >/dev/null 2>&1; then
  fail 'losing KEEP path reported rollback cancellation success'
fi
: > "$ROLLBACK_RELEASE"
wait "$ROLLBACK_PID"
BACKGROUND_PIDS="${BACKGROUND_PIDS/ $ROLLBACK_PID/}"
assert_eq 0 "$(cat "$ROLLBACK_RESULT")" 'claimed rollback failed to stop and clean'
assert_state CLEANED 0 0 'claimed rollback did not finish CLEANED'

# An early timer must release service-operation lock and sleep exactly the remaining deadline.
write_runtime_fixture "$RUN_A" "$BOOT_A" global AWAITING_CONFIRMATION 1 1120
TIMER_READY="${TEST_ROOT}/timer.ready"
TIMER_RELEASE="${TEST_ROOT}/timer.release"
TIMER_SLEEP_ARG="${TEST_ROOT}/timer.sleep"
TIMER_SIDE_EFFECTS="${TEST_ROOT}/timer.side-effects"
(
  MOCK_NOW=1000
  date() { printf '%s\n' "$MOCK_NOW"; }
  sleep() {
    printf '%s\n' "$1" > "$TIMER_SLEEP_ARG"
    : > "$TIMER_READY"
    while [ ! -e "$TIMER_RELEASE" ]; do /usr/bin/sleep 0.01; done
    MOCK_NOW=1120
  }
  stop_and_disable_managed_units() { printf '%s\n' stop >> "$TIMER_SIDE_EFFECTS"; }
  cleanup_run_generation() { printf '%s\n' cleanup >> "$TIMER_SIDE_EFFECTS"; }
  rollback_now "$RUN_A"
) &
TIMER_PID=$!
BACKGROUND_PIDS="$BACKGROUND_PIDS $TIMER_PID"
wait_for_file "$TIMER_READY" 'early rollback sleep'
assert_eq 120 "$(cat "$TIMER_SLEEP_ARG")" 'rollback timer did not sleep only the remaining deadline'
acquire_service_operation_lock try || fail 'rollback timer held service-operation lock while sleeping'
release_service_operation_lock
transition_run_state "$RUN_A" AWAITING_CONFIRMATION CONFIRMED 1 0 \
  || fail 'KEEP could not win while early rollback worker slept'
: > "$TIMER_RELEASE"
wait "$TIMER_PID"
BACKGROUND_PIDS="${BACKGROUND_PIDS/ $TIMER_PID/}"
[ ! -e "$TIMER_SIDE_EFFECTS" ] || fail 'early rollback acted after state changed during its wait'
assert_state CONFIRMED 1 0 'early rollback reversed confirmation after waking'

# Deterministically invalid cross-boot global state returns the non-restartable code.
write_runtime_fixture "$RUN_A" "$BOOT_A" global STARTING 1 0
printf '%s\n' "$BOOT_B" > "$OCM_BOOT_ID_FILE"
setup_return_routes() { fail 'cross-boot unconfirmed worker touched routes'; }
openconnect() { fail 'cross-boot unconfirmed worker reached OpenConnect'; }
set +e
service_run >/dev/null 2>&1
SERVICE_RC=$?
set -e
assert_eq 78 "$SERVICE_RC" 'cross-boot unconfirmed global worker returned a restartable status'
unset -f setup_return_routes openconnect

for rejected_phase in PREPARING CLEANUP_FAILED; do
  write_runtime_fixture "$RUN_A" "$BOOT_B" proxy "$rejected_phase" 1 0
  openconnect() { fail 'deterministically invalid worker reached OpenConnect'; }
  set +e
  service_run >/dev/null 2>&1
  SERVICE_RC=$?
  set -e
  assert_eq 78 "$SERVICE_RC" "$rejected_phase worker returned a restartable status"
  unset -f openconnect
done

# Confirmed global and active proxy generations remain restartable across boot.
write_runtime_fixture "$RUN_A" "$BOOT_A" global CONFIRMED 1 0
state_allows_service_run "$RUN_A" || fail 'confirmed global generation could not recover across boot'
write_runtime_fixture "$RUN_A" "$BOOT_A" proxy RUNNING 1 0
state_allows_service_run "$RUN_A" || fail 'active proxy generation could not recover across boot'
printf '%s\n' "$BOOT_A" > "$OCM_BOOT_ID_FILE"

# Stop commits inactive state before systemctl; concurrent health must skip and never restart.
write_runtime_fixture "$RUN_A" "$BOOT_A" proxy RUNNING 1 0
printf '%s\n' "$RUN_A" > "$SERVICE_RUN_ID_FILE"
STOP_READY="${TEST_ROOT}/stop.ready"
STOP_RELEASE="${TEST_ROOT}/stop.release"
STOP_RESULT="${TEST_ROOT}/stop.result"
HEALTH_SYSTEMCTL="${TEST_ROOT}/stop-health.systemctl"
(
  cancel_rollback() { return 0; }
  stop_and_disable_managed_units() {
    : > "$STOP_READY"
    while [ ! -e "$STOP_RELEASE" ]; do /usr/bin/sleep 0.01; done
  }
  if stop_vpn >/dev/null 2>&1; then printf '0\n' > "$STOP_RESULT"; else printf '%s\n' "$?" > "$STOP_RESULT"; fi
) &
STOP_PID=$!
BACKGROUND_PIDS="$BACKGROUND_PIDS $STOP_PID"
wait_for_file "$STOP_READY" 'stop inactive commit'
assert_state STOPPING 0 0 'stop did not commit inactive state before systemctl'
systemctl() {
  printf '%s\n' "$*" >> "$HEALTH_SYSTEMCTL"
  case "$*" in
    'is-active --quiet '*) return 0 ;;
    *) return 0 ;;
  esac
}
health_once() { return 1; }
(service_health) >/dev/null 2>&1 || fail 'health did not skip an inactive/locked generation cleanly'
if grep -F 'restart ' "$HEALTH_SYSTEMCTL" >/dev/null 2>&1; then
  fail 'health restarted the service after stop committed inactive state'
fi
: > "$STOP_RELEASE"
wait "$STOP_PID"
BACKGROUND_PIDS="${BACKGROUND_PIDS/ $STOP_PID/}"
assert_eq 0 "$(cat "$STOP_RESULT")" 'stop transaction failed after releasing its barrier'
assert_state CLEANED 0 0 'stop transaction did not finish CLEANED'
unset -f systemctl health_once

# Old-generation failure/cooldown values are ignored rather than inherited.
write_runtime_fixture "$RUN_B" "$BOOT_A" proxy RUNNING 1 0
printf '%s\n' "${RUN_A}=2" > "$HEALTH_FAILURE_FILE"
printf '%s\n' "${RUN_A}=1999" > "$HEALTH_RESTART_FILE"
HEALTH_CALLS="${TEST_ROOT}/health.calls"
systemctl() {
  case "$*" in
    "is-active --quiet $SERVICE_NAME") return 0 ;;
    "restart $SERVICE_NAME") printf '%s\n' restart >> "$HEALTH_CALLS"; return 0 ;;
    *) return 0 ;;
  esac
}
health_once() { return 1; }
date() { printf '2000\n'; }
(service_health) >/dev/null 2>&1 || fail 'first failed health probe returned an operational error'
assert_eq "${RUN_B}=1" "$(cat "$HEALTH_FAILURE_FILE")" 'old failure count leaked into the new generation'
[ ! -e "$HEALTH_CALLS" ] || fail 'one new-generation failure triggered a restart'
printf '%s\n' "${RUN_B}=2" > "$HEALTH_FAILURE_FILE"
(service_health) >/dev/null 2>&1 || fail 'third failed health probe returned an operational error'
grep -Fx restart "$HEALTH_CALLS" >/dev/null || fail 'old-generation cooldown suppressed the new generation restart'
assert_eq "${RUN_B}=2000" "$(cat "$HEALTH_RESTART_FILE")" 'health cooldown was not rewritten for the current generation'
unset -f systemctl health_once date

# ExecStopPost is generation-aware and preserves active phases on unexpected exits.
write_runtime_fixture "$RUN_B" "$BOOT_A" global RUNNING 1 0
printf '%s\n' "$RUN_B" > "$SERVICE_RUN_ID_FILE"
if (
  cleanup_return_routes() { return 1; }
  service_cleanup >/dev/null 2>&1
); then
  fail 'same-generation ExecStopPost hid a return-route cleanup failure'
fi
assert_state CLEANUP_FAILED 1 0 'failed same-generation cleanup did not commit CLEANUP_FAILED'

write_runtime_fixture "$RUN_B" "$BOOT_A" proxy RUNNING 1 0
printf '%s\n' "$RUN_A" > "$SERVICE_RUN_ID_FILE"
service_cleanup >/dev/null || fail 'stale ExecStopPost did not exit harmlessly'
assert_state RUNNING 1 0 'stale ExecStopPost changed current state'
printf '%s\n' "$RUN_B" > "$SERVICE_RUN_ID_FILE"
service_cleanup >/dev/null || fail 'active-generation ExecStopPost cleanup failed'
assert_state RUNNING 1 0 'unexpected exit disabled an active generation'
write_run_state "$RUN_B" STOPPING 0 0
printf '%s\n' "$RUN_B" > "$SERVICE_RUN_ID_FILE"
service_cleanup >/dev/null || fail 'inactive-generation ExecStopPost cleanup failed'
assert_state CLEANED 0 0 'inactive-generation ExecStopPost did not commit CLEANED'

printf 'lifecycle checks passed\n'
