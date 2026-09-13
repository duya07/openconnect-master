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

# Git Bash may not ship util-linux flock. Keep the deterministic state-machine
# coverage there, but never present the fallback as advisory-lock coverage.
HAVE_REAL_FLOCK=1
if ! command -v flock >/dev/null 2>&1; then
  HAVE_REAL_FLOCK=0
  # Preserve state/CAS coverage without pretending to exercise cross-process
  # advisory locking. Task 8 supplies the required real-flock Linux gate.
  acquire_state_lock() {
    [ -z "${TEST_STATE_LOCK_HELD:-}" ] || return 1
    TEST_STATE_LOCK_HELD=1
  }
  release_state_lock() { unset TEST_STATE_LOCK_HELD; }
  acquire_service_operation_lock() {
    [ "$#" -eq 1 ] || return 1
    case "$1" in wait|try) ;; *) return 1 ;; esac
    [ -z "${TEST_SERVICE_LOCK_HELD:-}" ] || return 0
    TEST_SERVICE_LOCK_HELD=1
  }
  release_service_operation_lock() { unset TEST_SERVICE_LOCK_HELD; }
  printf 'SKIP: lifecycle advisory-lock assertions (real flock unavailable)\n'
fi

check_root() { :; }
ensure_dirs() {
  mkdir -p -- "$CONFIG_DIR" "$RUNTIME_DIR" "${STATE_LOCK_FILE%/*}" "${SERVICE_LOCK_FILE%/*}"
}

seed_lifecycle_managed_units() {
  local unit
  mkdir -p -- "$SYSTEMD_DIR"
  for unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
    write_unit_file "$unit" "$(unit_path "$unit")" || fail "could not seed current unit: $unit"
  done
}

mock_lifecycle_unit_query() {
  if [ "$#" -eq 4 ] && [ "$1" = show ] && [ "$3" = --all ] && [ "$4" = --property=DropInPaths ]; then
    if [ "$2" = "${LIFECYCLE_DROPIN_UNIT:-}" ]; then
      case "${LIFECYCLE_DROPIN_MODE:-present}" in
        query-fail) return 1 ;;
        missing) return 0 ;;
        present) printf 'DropInPaths=/etc/systemd/system/%s.d/override.conf\n' "$2"; return 0 ;;
      esac
    fi
    printf 'DropInPaths=\n'
    return 0
  fi
  [ "$#" -eq 4 ] && [ "$1" = show ] && [ "$4" = --value ] || return 1
  local unit="$2" property="$3"

  if [ "$unit" = "${LIFECYCLE_QUERY_FAIL_UNIT:-}" ]; then return 1; fi
  case "$property" in
    --property=LoadState) printf '%s\n' loaded ;;
    --property=FragmentPath)
      if [ "$unit" = "${LIFECYCLE_FOREIGN_SOURCE_UNIT:-}" ]; then
        printf '/etc/systemd/system/%s\n' "$unit"
      else
        unit_path "$unit"
      fi
      ;;
    --property=ExecStart)
      case "$unit" in
        "$SERVICE_NAME")
          printf 'path=%s ; argv[]=%s %s ; ignore_errors=no\n' \
            "$INSTALL_PATH" "$INSTALL_PATH" "${LIFECYCLE_MAIN_START_ACTION:-_service_run}"
          ;;
        "$HEALTH_SERVICE_NAME")
          printf 'path=%s ; argv[]=%s %s ; ignore_errors=no\n' \
            "$INSTALL_PATH" "$INSTALL_PATH" "${LIFECYCLE_HEALTH_ACTION:-_service_health}"
          ;;
        *) return 1 ;;
      esac
      ;;
    --property=ExecStopPost)
      [ "$unit" = "$SERVICE_NAME" ] || return 1
      printf 'path=%s ; argv[]=%s %s ; ignore_errors=yes\n' \
        "$INSTALL_PATH" "$INSTALL_PATH" "${LIFECYCLE_MAIN_STOP_ACTION:-_service_cleanup}"
      ;;
    --property=Restart)
      [ "$unit" = "$SERVICE_NAME" ] || return 1
      printf '%s\n' "${LIFECYCLE_MAIN_RESTART:-always}"
      ;;
    --property=RestartPreventExitStatus)
      [ "$unit" = "$SERVICE_NAME" ] || return 1
      printf '%s\n' "${LIFECYCLE_MAIN_RESTART_PREVENT:-78}"
      ;;
    --property=Triggers)
      [ "$unit" = "$HEALTH_TIMER_NAME" ] || return 1
      printf '%s\n' "${LIFECYCLE_TIMER_TRIGGERS:-$HEALTH_SERVICE_NAME}"
      ;;
    --property=NeedDaemonReload)
      if [ "$unit" = "${LIFECYCLE_NEED_RELOAD_UNIT:-}" ]; then
        case "${LIFECYCLE_NEED_RELOAD_MODE:-yes}" in
          query-fail) return 1 ;;
          empty) printf '\n' ;;
          yes) printf 'yes\n' ;;
          no) printf 'no\n' ;;
          *) return 1 ;;
        esac
      else
        printf 'no\n'
      fi
      ;;
    *) return 1 ;;
  esac
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

REVIEW_FAILURES=0
review_failure() {
  printf 'review regression: %s\n' "$1" >&2
  REVIEW_FAILURES=$((REVIEW_FAILURES + 1))
}

# Replacement confirmation is user input: it must happen before the service lock.
rm -f -- "$ACTIVE_RUN_FILE" "$RUN_STATE_FILE" "$SERVICE_RUN_ID_FILE"
LOCKED_READ="${TEST_ROOT}/locked-read"
set +e
(
  SERVICE_LOCK_HELD=0
  acquire_service_operation_lock() { SERVICE_LOCK_HELD=1; }
  release_service_operation_lock() { SERVICE_LOCK_HELD=0; }
  ensure_dependencies() { :; }
  prepare_runtime_configuration_for_start() { :; }
  select_account() { export ACCOUNT_INDEX=0 VPN_PROTOCOL=nc ACCOUNT_RECORD="$ACCOUNT"; }
  install_self_and_units() { :; }
  stop_and_disable_managed_units() { :; }
  start_managed_units() { :; }
  wait_until_healthy() { return 0; }
  port_is_free() { return 0; }
  pgrep() { return 1; }
  systemctl() {
    case "$1" in is-active) printf 'active\n'; return 0 ;; *) return 0 ;; esac
  }
  read() {
    local test_read_target="${!#}" test_read_value=""
    case " $* " in
      *' -p '*) ;;
      *) builtin read "$@"; return ;;
    esac
    [ "$SERVICE_LOCK_HELD" -eq 0 ] || : > "$LOCKED_READ"
    [ "$test_read_target" != answer ] || test_read_value=y
    printf -v "$test_read_target" '%s' "$test_read_value"
  }
  create_run_snapshot() {
    write_runtime_fixture "$RUN_A" "$BOOT_A" proxy PREPARING 1 0
    printf '%s\n' "$RUN_A"
  }
  start_mode proxy >/dev/null 2>&1
)
LOCK_PROMPT_RC=$?
set -e
[ "$LOCK_PROMPT_RC" -eq 0 ] || review_failure 'replacement confirmation fixture did not complete'
[ ! -e "$LOCKED_READ" ] || review_failure 'replacement confirmation read while holding the service-operation lock'

# A unit-state TOCTOU after the prompt must be rejected without a second locked read.
rm -f -- "$ACTIVE_RUN_FILE" "$RUN_STATE_FILE" "$SERVICE_RUN_ID_FILE" "$LOCKED_READ"
TOCTOU_SNAPSHOT="${TEST_ROOT}/toctou-snapshot"
set +e
(
  SERVICE_LOCK_HELD=0
  acquire_service_operation_lock() { SERVICE_LOCK_HELD=1; }
  release_service_operation_lock() { SERVICE_LOCK_HELD=0; }
  ensure_dependencies() { :; }
  prepare_runtime_configuration_for_start() { :; }
  select_account() { export ACCOUNT_INDEX=0 VPN_PROTOCOL=nc ACCOUNT_RECORD="$ACCOUNT"; }
  install_self_and_units() { :; }
  stop_and_disable_managed_units() { :; }
  port_is_free() { return 0; }
  pgrep() { return 1; }
  systemctl() {
    case "$1" in
      is-active)
        if [ "$SERVICE_LOCK_HELD" -eq 1 ]; then printf 'active\n'; return 0; fi
        printf 'inactive\n'; return 3
        ;;
      *) return 0 ;;
    esac
  }
  read() {
    local test_read_target="${!#}"
    case " $* " in
      *' -p '*) ;;
      *) builtin read "$@"; return ;;
    esac
    [ "$SERVICE_LOCK_HELD" -eq 0 ] || : > "$LOCKED_READ"
    printf -v "$test_read_target" '%s' ''
  }
  create_run_snapshot() { : > "$TOCTOU_SNAPSHOT"; return 1; }
  start_mode proxy >/dev/null 2>&1
)
TOCTOU_RC=$?
set -e
[ "$TOCTOU_RC" -ne 0 ] || review_failure 'unit-state TOCTOU unexpectedly started a replacement'
[ ! -e "$LOCKED_READ" ] || review_failure 'unit-state TOCTOU caused a second user read under lock'
[ ! -e "$TOCTOU_SNAPSHOT" ] || review_failure 'unit-state TOCTOU reached snapshot creation without confirmation'

# Replacing an old generation must stop and explicitly clean it before a snapshot.
write_runtime_fixture "$RUN_A" "$BOOT_A" global RUNNING 1 0
printf '%s\n' "$RUN_A" > "$SERVICE_RUN_ID_FILE"
REPLACE_SNAPSHOT="${TEST_ROOT}/replace-snapshot"
set +e
(
  ensure_dependencies() { :; }
  prepare_runtime_configuration_for_start() { :; }
  select_account() { export ACCOUNT_INDEX=0 VPN_PROTOCOL=nc ACCOUNT_RECORD="$ACCOUNT"; }
  install_self_and_units() { :; }
  stop_and_disable_managed_units() { :; }
  port_is_free() { return 0; }
  pgrep() { return 1; }
  systemctl() {
    case "$1" in is-active) printf 'active\n'; return 0 ;; *) return 0 ;; esac
  }
  read() {
    local test_read_target="${!#}" test_read_value=""
    case " $* " in
      *' -p '*) ;;
      *) builtin read "$@"; return ;;
    esac
    [ "$test_read_target" != answer ] || test_read_value=y
    printf -v "$test_read_target" '%s' "$test_read_value"
  }
  cleanup_return_routes() { return 1; }
  create_run_snapshot() { : > "$REPLACE_SNAPSHOT"; return 1; }
  start_mode proxy >/dev/null 2>&1
)
REPLACE_RC=$?
set -e
[ "$REPLACE_RC" -ne 0 ] || review_failure 'replacement continued after old-generation cleanup failed'
[ ! -e "$REPLACE_SNAPSHOT" ] || review_failure 'new snapshot was attempted before old-generation cleanup completed'
if load_run_state; then
  [ "$RUN_ID" = "$RUN_A" ] || review_failure 'failed replacement overwrote the old generation id'
  [ "$PHASE" = CLEANUP_FAILED ] || review_failure 'failed replacement did not retain CLEANUP_FAILED evidence'
  [ "$DESIRED_ACTIVE" = 0 ] || review_failure 'failed replacement did not persist desired-active=0'
else
  review_failure 'failed replacement made the old generation unreadable'
fi
[ "$(cat "$SERVICE_RUN_ID_FILE" 2>/dev/null || true)" = "$RUN_A" ] \
  || review_failure 'failed replacement discarded the old generation owner marker'

# Cleanup failure must re-read desired-active after its unlocked route work.
write_runtime_fixture "$RUN_A" "$BOOT_A" global RUNNING 1 0
printf '%s\n' "$RUN_A" > "$SERVICE_RUN_ID_FILE"
CLEANUP_READY="${TEST_ROOT}/cleanup-reread.ready"
CLEANUP_RELEASE="${TEST_ROOT}/cleanup-reread.release"
CLEANUP_RESULT="${TEST_ROOT}/cleanup-reread.result"
(
  cleanup_return_routes() {
    : > "$CLEANUP_READY"
    while [ ! -e "$CLEANUP_RELEASE" ]; do /usr/bin/sleep 0.01; done
    return 1
  }
  if service_cleanup >/dev/null 2>&1; then printf '0\n' > "$CLEANUP_RESULT"; else printf '%s\n' "$?" > "$CLEANUP_RESULT"; fi
) &
CLEANUP_PID=$!
BACKGROUND_PIDS="$BACKGROUND_PIDS $CLEANUP_PID"
wait_for_file "$CLEANUP_READY" 'cleanup failure desired-active re-read'
transition_run_state "$RUN_A" RUNNING STOPPING 0 0 \
  || review_failure 'stop could not update desired-active during route cleanup'
: > "$CLEANUP_RELEASE"
wait "$CLEANUP_PID"
BACKGROUND_PIDS="${BACKGROUND_PIDS/ $CLEANUP_PID/}"
[ "$(cat "$CLEANUP_RESULT")" -ne 0 ] || review_failure 'route cleanup failure returned success'
if load_run_state; then
  [ "$PHASE" = CLEANUP_FAILED ] || review_failure 'route cleanup failure did not persist CLEANUP_FAILED'
  [ "$DESIRED_ACTIVE" = 0 ] || review_failure 'route cleanup failure restored stale desired-active=1'
else
  review_failure 'route cleanup failure left unreadable state'
fi

# If CLEANUP_FAILED cannot be committed, the retained owner marker must block restart.
write_runtime_fixture "$RUN_A" "$BOOT_A" global RUNNING 1 0
printf '%s\n' "$RUN_A" > "$SERVICE_RUN_ID_FILE"
CLEANUP_COMMIT_OUTPUT="${TEST_ROOT}/cleanup-commit.output"
set +e
(
  cleanup_return_routes() { return 1; }
  write_run_state() {
    [ "${2:-}" != CLEANUP_FAILED ] || return 1
    return 0
  }
  service_cleanup
) >"$CLEANUP_COMMIT_OUTPUT" 2>&1
CLEANUP_COMMIT_RC=$?
set -e
[ "$CLEANUP_COMMIT_RC" -ne 0 ] || review_failure 'failed CLEANUP_FAILED commit returned success'
grep -F 'CLEANUP_FAILED' "$CLEANUP_COMMIT_OUTPUT" >/dev/null 2>&1 \
  || review_failure 'failed CLEANUP_FAILED commit was silently swallowed'
[ "$(cat "$SERVICE_RUN_ID_FILE" 2>/dev/null || true)" = "$RUN_A" ] \
  || review_failure 'failed cleanup-state commit removed the owner marker'
SERVICE_SIDE_EFFECTS="${TEST_ROOT}/service-restart.side-effects"
MOCK_BIN="${TEST_ROOT}/mock-bin"
mkdir -p -- "$MOCK_BIN"
printf '#!/usr/bin/env bash\nprintf "openconnect\\n" >> "$SERVICE_SIDE_EFFECTS"\n' > "$MOCK_BIN/openconnect"
chmod 0700 "$MOCK_BIN/openconnect"
set +e
(
  export SERVICE_SIDE_EFFECTS
  PATH="$MOCK_BIN:$PATH"
  setup_return_routes() { printf 'routes\n' >> "$SERVICE_SIDE_EFFECTS"; }
  service_run >/dev/null 2>&1
)
SERVICE_RESTART_RC=$?
set -e
[ "$SERVICE_RESTART_RC" -eq "$NON_RESTARTABLE_EXIT" ] \
  || review_failure 'unresolved cleanup owner did not fail closed with exit 78'
[ ! -e "$SERVICE_SIDE_EFFECTS" ] || review_failure 'fail-closed service restart touched routes or OpenConnect'

[ "$REVIEW_FAILURES" -eq 0 ] || fail "$REVIEW_FAILURES review regression(s) detected"

# Starting persistent units must bind every unit name to the exact managed
# source and contract before reset-failed/enable/start can mutate systemd.
seed_lifecycle_managed_units
START_SYSTEMCTL_MUTATIONS="${TEST_ROOT}/start-systemctl.mutations"
for rejected_unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
  : > "$START_SYSTEMCTL_MUTATIONS"
  if (
    LIFECYCLE_FOREIGN_SOURCE_UNIT="$rejected_unit"
    systemctl() {
      if [ "$1" = show ]; then mock_lifecycle_unit_query "$@"; return; fi
      printf '%s\n' "$*" >> "$START_SYSTEMCTL_MUTATIONS"
    }
    start_managed_units >/dev/null 2>&1
  ); then
    fail "start accepted an external systemd source for $rejected_unit"
  fi
  [ ! -s "$START_SYSTEMCTL_MUTATIONS" ] \
    || fail "start mutated systemd before rejecting external source for $rejected_unit"
done

: > "$START_SYSTEMCTL_MUTATIONS"
if (
  LIFECYCLE_QUERY_FAIL_UNIT="$HEALTH_SERVICE_NAME"
  systemctl() {
    if [ "$1" = show ]; then mock_lifecycle_unit_query "$@"; return; fi
    printf '%s\n' "$*" >> "$START_SYSTEMCTL_MUTATIONS"
  }
  start_managed_units >/dev/null 2>&1
); then
  fail 'start accepted an unverifiable health unit'
fi
[ ! -s "$START_SYSTEMCTL_MUTATIONS" ] || fail 'start mutated systemd after a unit query failed'

: > "$START_SYSTEMCTL_MUTATIONS"
if (
  LIFECYCLE_TIMER_TRIGGERS='foreign-health.service'
  systemctl() {
    if [ "$1" = show ]; then mock_lifecycle_unit_query "$@"; return; fi
    printf '%s\n' "$*" >> "$START_SYSTEMCTL_MUTATIONS"
  }
  start_managed_units >/dev/null 2>&1
); then
  fail 'start accepted a foreign timer trigger'
fi
[ ! -s "$START_SYSTEMCTL_MUTATIONS" ] || fail 'start mutated systemd before rejecting timer contract drift'

# A current marker is not the current contract.  Any byte drift, any drop-in,
# or an unprovable/pending daemon reload must abort before the first mutation.
for rejected_unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
  rejected_path="$(unit_path "$rejected_unit")"
  cp -- "$rejected_path" "${rejected_path}.exact"
  printf '%s\n' '# stale current-unit bytes' >> "$rejected_path"
  : > "$START_SYSTEMCTL_MUTATIONS"
  if (
    systemctl() {
      if [ "$1" = show ]; then mock_lifecycle_unit_query "$@"; return; fi
      printf '%s\n' "$*" >> "$START_SYSTEMCTL_MUTATIONS"
    }
    start_managed_units >/dev/null 2>&1
  ); then
    fail "start accepted byte drift in $rejected_unit"
  fi
  [ ! -s "$START_SYSTEMCTL_MUTATIONS" ] \
    || fail "start mutated systemd before rejecting byte drift in $rejected_unit"
  mv -f -- "${rejected_path}.exact" "$rejected_path"
done

for dropin_mode in query-fail missing present; do
  : > "$START_SYSTEMCTL_MUTATIONS"
  if (
    LIFECYCLE_DROPIN_UNIT="$HEALTH_SERVICE_NAME"
    LIFECYCLE_DROPIN_MODE="$dropin_mode"
    systemctl() {
      if [ "$1" = show ]; then mock_lifecycle_unit_query "$@"; return; fi
      printf '%s\n' "$*" >> "$START_SYSTEMCTL_MUTATIONS"
    }
    start_managed_units >/dev/null 2>&1
  ); then
    fail "start accepted DropInPaths=$dropin_mode evidence"
  fi
  [ ! -s "$START_SYSTEMCTL_MUTATIONS" ] \
    || fail "start mutated systemd before rejecting DropInPaths=$dropin_mode evidence"
done

for reload_unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
  : > "$START_SYSTEMCTL_MUTATIONS"
  if (
    LIFECYCLE_NEED_RELOAD_UNIT="$reload_unit"
    LIFECYCLE_NEED_RELOAD_MODE=yes
    systemctl() {
      if [ "$1" = show ]; then mock_lifecycle_unit_query "$@"; return; fi
      printf '%s\n' "$*" >> "$START_SYSTEMCTL_MUTATIONS"
    }
    start_managed_units >/dev/null 2>&1
  ); then
    fail "start accepted NeedDaemonReload=yes for $reload_unit"
  fi
  [ ! -s "$START_SYSTEMCTL_MUTATIONS" ] \
    || fail "start mutated systemd before rejecting NeedDaemonReload=yes for $reload_unit"
done
for reload_mode in query-fail empty; do
  : > "$START_SYSTEMCTL_MUTATIONS"
  if (
    LIFECYCLE_NEED_RELOAD_UNIT="$SERVICE_NAME"
    LIFECYCLE_NEED_RELOAD_MODE="$reload_mode"
    systemctl() {
      if [ "$1" = show ]; then mock_lifecycle_unit_query "$@"; return; fi
      printf '%s\n' "$*" >> "$START_SYSTEMCTL_MUTATIONS"
    }
    start_managed_units >/dev/null 2>&1
  ); then
    fail "start accepted NeedDaemonReload=$reload_mode"
  fi
  [ ! -s "$START_SYSTEMCTL_MUTATIONS" ] \
    || fail "start mutated systemd before rejecting NeedDaemonReload=$reload_mode"
done

: > "$START_SYSTEMCTL_MUTATIONS"
if ! (
  systemctl() {
    if [ "$1" = show ]; then mock_lifecycle_unit_query "$@"; return; fi
    printf '%s\n' "$*" >> "$START_SYSTEMCTL_MUTATIONS"
  }
  start_managed_units >/dev/null 2>&1
); then
  fail 'start rejected exact managed unit sources and contracts'
fi
assert_eq $'reset-failed oc-master.service\nenable oc-master.service oc-master-health.timer\nstart oc-master.service\nstart oc-master-health.timer' \
  "$(cat "$START_SYSTEMCTL_MUTATIONS")" 'systemd start mutation order changed'
printf 'persistent unit start ownership tests passed\n'

reset_rollback_unit_mock() {
  ROLLBACK_TIMER_LOAD=not-found
  ROLLBACK_TIMER_TRANSIENT=''
  ROLLBACK_TIMER_FRAGMENT=''
  ROLLBACK_TIMER_TRIGGERS=''
  ROLLBACK_TIMER_ACTIVE=inactive
  ROLLBACK_SERVICE_LOAD=not-found
  ROLLBACK_SERVICE_TRANSIENT=''
  ROLLBACK_SERVICE_FRAGMENT=''
  ROLLBACK_SERVICE_EXEC_START=''
  ROLLBACK_SERVICE_ACTIVE=inactive
  ROLLBACK_QUERY_FAIL=''
  ROLLBACK_TIMER_DROPIN_MODE=empty
  ROLLBACK_SERVICE_DROPIN_MODE=empty
  ROLLBACK_TIMER_NEED_RELOAD=no
  ROLLBACK_SERVICE_NEED_RELOAD=no
  ROLLBACK_STOP_STICKS=''
  ROLLBACK_STOP_EMPTIES=''
}

seed_owned_rollback_timer() {
  ROLLBACK_TIMER_LOAD=loaded
  ROLLBACK_TIMER_TRANSIENT=yes
  ROLLBACK_TIMER_FRAGMENT="/run/systemd/transient/${ROLLBACK_UNIT}.timer"
  ROLLBACK_TIMER_TRIGGERS="${ROLLBACK_UNIT}.service"
  ROLLBACK_TIMER_ACTIVE=active
}

seed_owned_rollback_service() {
  local run_id="${1:-$RUN_A}"
  ROLLBACK_SERVICE_LOAD=loaded
  ROLLBACK_SERVICE_TRANSIENT=yes
  ROLLBACK_SERVICE_FRAGMENT="/run/systemd/transient/${ROLLBACK_UNIT}.service"
  ROLLBACK_SERVICE_EXEC_START="path=${INSTALL_PATH} ; argv[]=${INSTALL_PATH} _rollback ${run_id} ; ignore_errors=no"
  ROLLBACK_SERVICE_ACTIVE=active
}

mock_rollback_systemctl() {
  [ -z "${TEST_STATE_LOCK_HELD:-}" ] || : > "$ROLLBACK_LOCK_VIOLATION"
  local command_name="${1:-}" unit="" property="" value="" argument
  shift || true
  case "$command_name" in
    show)
      unit="${1:-}"
      property="${2:-}"
      if [ "$property" = --all ] && [ "${3:-}" = --property=DropInPaths ]; then
        [ "$ROLLBACK_QUERY_FAIL" != "${unit}:--property=DropInPaths" ] || return 1
        case "$unit" in
          "${ROLLBACK_UNIT}.timer") value="$ROLLBACK_TIMER_DROPIN_MODE" ;;
          "${ROLLBACK_UNIT}.service") value="$ROLLBACK_SERVICE_DROPIN_MODE" ;;
          *) return 96 ;;
        esac
        case "$value" in
          empty) printf 'DropInPaths=\n' ;;
          present) printf 'DropInPaths=/etc/systemd/system/%s.d/override.conf\n' "$unit" ;;
          *) return 96 ;;
        esac
        return 0
      fi
      [ "$3" = --value ] || return 96
      [ "$ROLLBACK_QUERY_FAIL" != "${unit}:${property}" ] || return 1
      case "${unit}:${property}" in
        "${ROLLBACK_UNIT}.timer:--property=LoadState") value="$ROLLBACK_TIMER_LOAD" ;;
        "${ROLLBACK_UNIT}.timer:--property=Transient") value="$ROLLBACK_TIMER_TRANSIENT" ;;
        "${ROLLBACK_UNIT}.timer:--property=FragmentPath") value="$ROLLBACK_TIMER_FRAGMENT" ;;
        "${ROLLBACK_UNIT}.timer:--property=Triggers") value="$ROLLBACK_TIMER_TRIGGERS" ;;
        "${ROLLBACK_UNIT}.timer:--property=ActiveState") value="$ROLLBACK_TIMER_ACTIVE" ;;
        "${ROLLBACK_UNIT}.timer:--property=NeedDaemonReload") value="$ROLLBACK_TIMER_NEED_RELOAD" ;;
        "${ROLLBACK_UNIT}.service:--property=LoadState") value="$ROLLBACK_SERVICE_LOAD" ;;
        "${ROLLBACK_UNIT}.service:--property=Transient") value="$ROLLBACK_SERVICE_TRANSIENT" ;;
        "${ROLLBACK_UNIT}.service:--property=FragmentPath") value="$ROLLBACK_SERVICE_FRAGMENT" ;;
        "${ROLLBACK_UNIT}.service:--property=ExecStart") value="$ROLLBACK_SERVICE_EXEC_START" ;;
        "${ROLLBACK_UNIT}.service:--property=ActiveState") value="$ROLLBACK_SERVICE_ACTIVE" ;;
        "${ROLLBACK_UNIT}.service:--property=NeedDaemonReload") value="$ROLLBACK_SERVICE_NEED_RELOAD" ;;
        *) return 96 ;;
      esac
      printf '%s\n' "$value"
      ;;
    stop)
      for argument in "$@"; do
        [[ "$argument" == -* ]] && continue
        printf 'stop %s\n' "$argument" >> "$ROLLBACK_MUTATIONS"
        if [ "$argument" = "${ROLLBACK_UNIT}.timer" ]; then
          if [ "$ROLLBACK_STOP_STICKS" = timer ]; then
            ROLLBACK_TIMER_ACTIVE=active
          elif [ "$ROLLBACK_STOP_EMPTIES" = timer ]; then
            ROLLBACK_TIMER_ACTIVE=''
          else
            ROLLBACK_TIMER_ACTIVE=inactive
          fi
        elif [ "$argument" = "${ROLLBACK_UNIT}.service" ]; then
          if [ "$ROLLBACK_STOP_STICKS" = service ]; then
            ROLLBACK_SERVICE_ACTIVE=active
          elif [ "$ROLLBACK_STOP_EMPTIES" = service ]; then
            ROLLBACK_SERVICE_ACTIVE=''
          else
            ROLLBACK_SERVICE_ACTIVE=inactive
          fi
        else
          return 96
        fi
      done
      ;;
    reset-failed)
      [ "$#" -eq 1 ] && [ "$1" = "${ROLLBACK_UNIT}.service" ] || return 96
      printf 'reset-failed %s\n' "$1" >> "$ROLLBACK_MUTATIONS"
      ;;
    *) return 96 ;;
  esac
}

run_rejected_rollback_cancel_case() (
  local case_name="$1"
  write_runtime_fixture "$RUN_A" "$BOOT_A" global CONFIRMED 1 0
  reset_rollback_unit_mock
  seed_owned_rollback_timer
  seed_owned_rollback_service "$RUN_A"
  ROLLBACK_MUTATIONS="${TEST_ROOT}/rollback-${case_name}.mutations"
  ROLLBACK_LOCK_VIOLATION="${TEST_ROOT}/rollback-${case_name}.lock-violation"
  : > "$ROLLBACK_MUTATIONS"
  case "$case_name" in
    query-fail) ROLLBACK_QUERY_FAIL="${ROLLBACK_UNIT}.timer:--property=LoadState" ;;
    empty-load) ROLLBACK_TIMER_LOAD='' ;;
    masked-load) ROLLBACK_TIMER_LOAD=masked ;;
    transient-query-fail) ROLLBACK_QUERY_FAIL="${ROLLBACK_UNIT}.timer:--property=Transient" ;;
    transient-empty) ROLLBACK_SERVICE_TRANSIENT='' ;;
    transient-no) ROLLBACK_TIMER_TRANSIENT=no ;;
    fragment-query-fail) ROLLBACK_QUERY_FAIL="${ROLLBACK_UNIT}.service:--property=FragmentPath" ;;
    empty-fragment) ROLLBACK_TIMER_FRAGMENT='' ;;
    external-source) ROLLBACK_SERVICE_FRAGMENT="/etc/systemd/system/${ROLLBACK_UNIT}.service" ;;
    exec-query-fail) ROLLBACK_QUERY_FAIL="${ROLLBACK_UNIT}.service:--property=ExecStart" ;;
    wrong-uuid) seed_owned_rollback_service "$RUN_B" ;;
    extra-argument) ROLLBACK_SERVICE_EXEC_START="path=${INSTALL_PATH} ; argv[]=${INSTALL_PATH} _rollback ${RUN_A} extra ; ignore_errors=no" ;;
    ignored-exec) ROLLBACK_SERVICE_EXEC_START="path=${INSTALL_PATH} ; argv[]=${INSTALL_PATH} _rollback ${RUN_A} ; ignore_errors=yes" ;;
    triggers-query-fail) ROLLBACK_QUERY_FAIL="${ROLLBACK_UNIT}.timer:--property=Triggers" ;;
    wrong-trigger) ROLLBACK_TIMER_TRIGGERS=foreign.service ;;
    multiple-triggers) ROLLBACK_TIMER_TRIGGERS="${ROLLBACK_UNIT}.service foreign.service" ;;
    dropin-query-fail-timer) ROLLBACK_QUERY_FAIL="${ROLLBACK_UNIT}.timer:--property=DropInPaths" ;;
    dropin-query-fail-service) ROLLBACK_QUERY_FAIL="${ROLLBACK_UNIT}.service:--property=DropInPaths" ;;
    dropin-present-timer) ROLLBACK_TIMER_DROPIN_MODE=present ;;
    dropin-present-service) ROLLBACK_SERVICE_DROPIN_MODE=present ;;
    reload-query-fail-timer) ROLLBACK_QUERY_FAIL="${ROLLBACK_UNIT}.timer:--property=NeedDaemonReload" ;;
    reload-query-fail-service) ROLLBACK_QUERY_FAIL="${ROLLBACK_UNIT}.service:--property=NeedDaemonReload" ;;
    reload-empty-timer) ROLLBACK_TIMER_NEED_RELOAD='' ;;
    reload-empty-service) ROLLBACK_SERVICE_NEED_RELOAD='' ;;
    reload-yes-timer) ROLLBACK_TIMER_NEED_RELOAD=yes ;;
    reload-yes-service) ROLLBACK_SERVICE_NEED_RELOAD=yes ;;
    *) return 96 ;;
  esac
  systemctl() { mock_rollback_systemctl "$@"; }
  if cancel_rollback "$RUN_A" >/dev/null 2>&1; then
    fail "rollback cancel accepted unsafe metadata: $case_name"
  fi
  [ ! -s "$ROLLBACK_MUTATIONS" ] \
    || fail "rollback cancel mutated systemd before rejecting: $case_name"
)

# The probe's three outcomes are part of the cancellation contract: exact
# ownership, strict absence, and every unprovable state remain distinguishable.
reset_rollback_unit_mock
ROLLBACK_MUTATIONS="${TEST_ROOT}/rollback-probe.mutations"
ROLLBACK_LOCK_VIOLATION="${TEST_ROOT}/rollback-probe.lock-violation"
: > "$ROLLBACK_MUTATIONS"
systemctl() { mock_rollback_systemctl "$@"; }
set +e
rollback_unit_probe "$RUN_A" "${ROLLBACK_UNIT}.service" >/dev/null 2>&1
ROLLBACK_PROBE_RC=$?
set -e
assert_eq 3 "$ROLLBACK_PROBE_RC" 'strictly absent rollback unit did not return probe status 3'
seed_owned_rollback_service "$RUN_A"
rollback_unit_probe "$RUN_A" "${ROLLBACK_UNIT}.service" >/dev/null 2>&1 \
  || fail 'owned rollback unit did not return probe status 0'
ROLLBACK_SERVICE_TRANSIENT=''
set +e
rollback_unit_probe "$RUN_A" "${ROLLBACK_UNIT}.service" >/dev/null 2>&1
ROLLBACK_PROBE_RC=$?
set -e
assert_eq 1 "$ROLLBACK_PROBE_RC" 'unprovable rollback unit did not return probe status 1'
unset -f systemctl

# Strict absence is a safe no-op.  It must not stop/reset an unrelated fixed name.
write_runtime_fixture "$RUN_A" "$BOOT_A" global CONFIRMED 1 0
reset_rollback_unit_mock
ROLLBACK_MUTATIONS="${TEST_ROOT}/rollback-absent.mutations"
ROLLBACK_LOCK_VIOLATION="${TEST_ROOT}/rollback-absent.lock-violation"
: > "$ROLLBACK_MUTATIONS"
systemctl() { mock_rollback_systemctl "$@"; }
cancel_rollback "$RUN_A" >/dev/null 2>&1 || fail 'strictly absent rollback pair was rejected'
[ ! -s "$ROLLBACK_MUTATIONS" ] || fail 'absent rollback pair caused a systemd mutation'
unset -f systemctl

# A fully owned pair is stopped only after both units are proven, and systemd
# queries must happen after state_matches_run has released the state lock.
write_runtime_fixture "$RUN_A" "$BOOT_A" global CONFIRMED 1 0
reset_rollback_unit_mock
seed_owned_rollback_timer
seed_owned_rollback_service "$RUN_A"
ROLLBACK_MUTATIONS="${TEST_ROOT}/rollback-owned.mutations"
ROLLBACK_LOCK_VIOLATION="${TEST_ROOT}/rollback-owned.lock-violation"
: > "$ROLLBACK_MUTATIONS"
(
  TEST_STATE_LOCK_HELD=''
  acquire_state_lock() { [ -z "$TEST_STATE_LOCK_HELD" ] || return 1; TEST_STATE_LOCK_HELD=1; }
  release_state_lock() { TEST_STATE_LOCK_HELD=''; }
  systemctl() { mock_rollback_systemctl "$@"; }
  cancel_rollback "$RUN_A" >/dev/null 2>&1
) || fail 'owned rollback pair could not be cancelled'
assert_eq $'stop oc-master-rollback.timer\nstop oc-master-rollback.service\nreset-failed oc-master-rollback.service' \
  "$(cat "$ROLLBACK_MUTATIONS")" 'owned rollback cancellation mutation set changed'
[ ! -e "$ROLLBACK_LOCK_VIOLATION" ] || fail 'rollback ownership query ran while state lock was held'

# A service carries its UUID in ExecStart and can therefore be cancelled on its
# own.  A timer carries no UUID evidence: without the matching service, its
# fixed name and trigger are insufficient to prove generation ownership.
for owned_half in timer service; do
  write_runtime_fixture "$RUN_A" "$BOOT_A" global CONFIRMED 1 0
  reset_rollback_unit_mock
  if [ "$owned_half" = timer ]; then seed_owned_rollback_timer; else seed_owned_rollback_service "$RUN_A"; fi
  ROLLBACK_MUTATIONS="${TEST_ROOT}/rollback-partial-${owned_half}.mutations"
  ROLLBACK_LOCK_VIOLATION="${TEST_ROOT}/rollback-partial-${owned_half}.lock-violation"
  : > "$ROLLBACK_MUTATIONS"
  systemctl() { mock_rollback_systemctl "$@"; }
  if [ "$owned_half" = timer ]; then
    if cancel_rollback "$RUN_A" >/dev/null 2>&1; then
      fail 'timer-only rollback cancellation accepted a unit without RUN_ID evidence'
    fi
    [ ! -s "$ROLLBACK_MUTATIONS" ] \
      || fail 'timer-only rollback cancellation mutated systemd without RUN_ID evidence'
  else
    cancel_rollback "$RUN_A" >/dev/null 2>&1 \
      || fail 'UUID-bound service-only rollback cancellation was rejected'
    assert_eq $'stop oc-master-rollback.service\nreset-failed oc-master-rollback.service' \
      "$(cat "$ROLLBACK_MUTATIONS")" 'partial service cancellation touched another unit'
  fi
  unset -f systemctl
done

for rollback_rejection in query-fail empty-load masked-load transient-query-fail transient-empty \
  transient-no fragment-query-fail empty-fragment external-source exec-query-fail wrong-uuid \
  extra-argument ignored-exec triggers-query-fail wrong-trigger multiple-triggers \
  dropin-query-fail-timer dropin-query-fail-service dropin-present-timer dropin-present-service \
  reload-query-fail-timer reload-query-fail-service reload-empty-timer reload-empty-service \
  reload-yes-timer reload-yes-service; do
  run_rejected_rollback_cancel_case "$rollback_rejection"
done

# A mutation is not success until the same owned unit is proven inactive (or
# strictly gone).  Active and unreadable post-stop states both fail closed.
for post_state in active empty query-fail; do
  write_runtime_fixture "$RUN_A" "$BOOT_A" global CONFIRMED 1 0
  reset_rollback_unit_mock
  seed_owned_rollback_timer
  seed_owned_rollback_service "$RUN_A"
  ROLLBACK_MUTATIONS="${TEST_ROOT}/rollback-post-${post_state}.mutations"
  ROLLBACK_LOCK_VIOLATION="${TEST_ROOT}/rollback-post-${post_state}.lock-violation"
  : > "$ROLLBACK_MUTATIONS"
  case "$post_state" in
    active) ROLLBACK_STOP_STICKS=service ;;
    empty) ROLLBACK_STOP_EMPTIES=service ;;
    query-fail) ROLLBACK_QUERY_FAIL="${ROLLBACK_UNIT}.service:--property=ActiveState" ;;
  esac
  systemctl() { mock_rollback_systemctl "$@"; }
  if cancel_rollback "$RUN_A" >/dev/null 2>&1; then
    fail "rollback cancellation accepted post-stop service state: $post_state"
  fi
  unset -f systemctl
done

# systemd-run success alone is insufficient: arming succeeds only after the
# exact UUID-bound transient pair is read back as an active timer and an
# inactive waiting service.  Empty, unexpected, and unreadable states fail
# without printing the armed-success warning.
for arm_shape in complete service-only wrong-uuid timer-inactive timer-empty \
  timer-query-fail service-active service-empty service-query-fail \
  dropin-query-fail-timer dropin-query-fail-service dropin-present-timer dropin-present-service \
  reload-query-fail-timer reload-query-fail-service reload-empty-timer reload-empty-service \
  reload-yes-timer reload-yes-service; do
  write_runtime_fixture "$RUN_A" "$BOOT_A" global STARTING 1 0
  reset_rollback_unit_mock
  ROLLBACK_MUTATIONS="${TEST_ROOT}/rollback-arm-${arm_shape}.mutations"
  ROLLBACK_ARM_OUTPUT="${TEST_ROOT}/rollback-arm-${arm_shape}.output"
  ROLLBACK_LOCK_VIOLATION="${TEST_ROOT}/rollback-arm-${arm_shape}.lock-violation"
  : > "$ROLLBACK_MUTATIONS"
  : > "$ROLLBACK_ARM_OUTPUT"
  systemctl() { mock_rollback_systemctl "$@"; }
  systemd-run() {
    printf 'systemd-run\n' >> "$ROLLBACK_MUTATIONS"
    reset_rollback_unit_mock
    seed_owned_rollback_service "$RUN_A"
    ROLLBACK_SERVICE_ACTIVE=inactive
    case "$arm_shape" in
      complete) seed_owned_rollback_timer ;;
      service-only) ;;
      wrong-uuid) seed_owned_rollback_service "$RUN_B"; seed_owned_rollback_timer ;;
      timer-inactive) seed_owned_rollback_timer; ROLLBACK_TIMER_ACTIVE=inactive ;;
      timer-empty) seed_owned_rollback_timer; ROLLBACK_TIMER_ACTIVE='' ;;
      timer-query-fail)
        seed_owned_rollback_timer
        ROLLBACK_QUERY_FAIL="${ROLLBACK_UNIT}.timer:--property=ActiveState"
        ;;
      service-active) seed_owned_rollback_timer; ROLLBACK_SERVICE_ACTIVE=active ;;
      service-empty) seed_owned_rollback_timer; ROLLBACK_SERVICE_ACTIVE='' ;;
      service-query-fail)
        seed_owned_rollback_timer
        ROLLBACK_QUERY_FAIL="${ROLLBACK_UNIT}.service:--property=ActiveState"
        ;;
      dropin-query-fail-timer)
        seed_owned_rollback_timer
        ROLLBACK_QUERY_FAIL="${ROLLBACK_UNIT}.timer:--property=DropInPaths"
        ;;
      dropin-query-fail-service)
        seed_owned_rollback_timer
        ROLLBACK_QUERY_FAIL="${ROLLBACK_UNIT}.service:--property=DropInPaths"
        ;;
      dropin-present-timer)
        seed_owned_rollback_timer
        ROLLBACK_TIMER_DROPIN_MODE=present
        ;;
      dropin-present-service)
        seed_owned_rollback_timer
        ROLLBACK_SERVICE_DROPIN_MODE=present
        ;;
      reload-query-fail-timer)
        seed_owned_rollback_timer
        ROLLBACK_QUERY_FAIL="${ROLLBACK_UNIT}.timer:--property=NeedDaemonReload"
        ;;
      reload-query-fail-service)
        seed_owned_rollback_timer
        ROLLBACK_QUERY_FAIL="${ROLLBACK_UNIT}.service:--property=NeedDaemonReload"
        ;;
      reload-empty-timer)
        seed_owned_rollback_timer
        ROLLBACK_TIMER_NEED_RELOAD=''
        ;;
      reload-empty-service)
        seed_owned_rollback_timer
        ROLLBACK_SERVICE_NEED_RELOAD=''
        ;;
      reload-yes-timer)
        seed_owned_rollback_timer
        ROLLBACK_TIMER_NEED_RELOAD=yes
        ;;
      reload-yes-service)
        seed_owned_rollback_timer
        ROLLBACK_SERVICE_NEED_RELOAD=yes
        ;;
    esac
  }
  if [ "$arm_shape" = complete ]; then
    arm_rollback "$RUN_A" >"$ROLLBACK_ARM_OUTPUT" 2>&1 \
      || fail 'active timer with inactive waiting service failed post-arm proof'
    grep -F '已武装独立回滚' "$ROLLBACK_ARM_OUTPUT" >/dev/null \
      || fail 'proven armed rollback did not print its success warning'
  elif arm_rollback "$RUN_A" >"$ROLLBACK_ARM_OUTPUT" 2>&1; then
    fail "rollback arm accepted incomplete/unprovable pair: $arm_shape"
  elif grep -F '已武装独立回滚' "$ROLLBACK_ARM_OUTPUT" >/dev/null; then
    fail "rollback arm printed success before proving unit states: $arm_shape"
  fi
  unset -f systemctl systemd-run
done
printf 'rollback transient unit ownership tests passed\n'

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
confirm_service_replacement() { REPLACEMENT_CONFIRMED=0; }
prepare_service_replacement() { :; }
install_self_and_units() { :; }
start_managed_units() { :; }
wait_until_healthy() { return 0; }
start_mode proxy <<< '' >/dev/null || fail 'proxy lifecycle rejected a healthy start'
assert_state RUNNING 1 0 'proxy lifecycle did not finish in RUNNING'
unset -f ensure_dependencies prepare_runtime_configuration_for_start select_account \
  confirm_service_replacement prepare_service_replacement install_self_and_units \
  start_managed_units wait_until_healthy

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
  confirm_service_replacement() { REPLACEMENT_CONFIRMED=0; }
  prepare_service_replacement() { [ "${1:-}" = "$REPLACEMENT_CONFIRMED" ]; }
  install_self_and_units() { :; }
  build_route_plan() { [ "${1:-}" = "$RUN_A" ]; }
  write_route_plan() { [ "${1:-}" = "$RUN_A" ]; }
  validate_route_plan_against_snapshot() { [ "${1:-}" = "$RUN_A" ]; }
  start_managed_units() { :; }
  wait_until_healthy() { return 0; }
  reset_rollback_unit_mock
  ROLLBACK_MUTATIONS="${TEST_ROOT}/global-rollback.mutations"
  ROLLBACK_LOCK_VIOLATION="${TEST_ROOT}/global-rollback.lock-violation"
  : > "$ROLLBACK_MUTATIONS"
  systemctl() {
    case "$1" in
      is-active) return 3 ;;
      show|stop|reset-failed) mock_rollback_systemctl "$@" ;;
      *) return 96 ;;
    esac
  }
  systemd-run() {
    reset_rollback_unit_mock
    seed_owned_rollback_service "$RUN_A"
    ROLLBACK_SERVICE_ACTIVE=inactive
    seed_owned_rollback_timer
  }
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
reset_rollback_unit_mock
ROLLBACK_MUTATIONS="${TEST_ROOT}/keep-rollback.mutations"
ROLLBACK_LOCK_VIOLATION="${TEST_ROOT}/keep-rollback.lock-violation"
: > "$ROLLBACK_MUTATIONS"
systemctl() {
  case "$1" in
    is-active) return 3 ;;
    show|stop|reset-failed) mock_rollback_systemctl "$@" ;;
    *) return 96 ;;
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
if [ "$HAVE_REAL_FLOCK" -eq 1 ]; then
  acquire_service_operation_lock try || fail 'rollback timer held service-operation lock while sleeping'
  release_service_operation_lock
fi
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

# A foreign main-unit source at the restart threshold must not consume the
# cooldown or restart a same-named service.  Source/property reads also remain
# outside the state lock.
write_runtime_fixture "$RUN_B" "$BOOT_A" proxy RUNNING 1 0
printf '%s\n' "${RUN_B}=2" > "$HEALTH_FAILURE_FILE"
rm -f -- "$HEALTH_RESTART_FILE"
HEALTH_FOREIGN_CALLS="${TEST_ROOT}/health-foreign.calls"
HEALTH_LOCK_VIOLATION="${TEST_ROOT}/health-state-lock-systemctl"
if ! (
  TEST_STATE_LOCK_HELD=''
  acquire_state_lock() {
    [ -z "$TEST_STATE_LOCK_HELD" ] || return 1
    TEST_STATE_LOCK_HELD=1
  }
  release_state_lock() { TEST_STATE_LOCK_HELD=''; }
  LIFECYCLE_FOREIGN_SOURCE_UNIT="$SERVICE_NAME"
  systemctl() {
    [ -z "$TEST_STATE_LOCK_HELD" ] || : > "$HEALTH_LOCK_VIOLATION"
    if [ "$1" = show ]; then mock_lifecycle_unit_query "$@"; return; fi
    case "$*" in
      "is-active --quiet $SERVICE_NAME") return 0 ;;
      "restart $SERVICE_NAME") printf '%s\n' restart >> "$HEALTH_FOREIGN_CALLS"; return 0 ;;
      *) return 0 ;;
    esac
  }
  health_once() { return 1; }
  date() { printf '3000\n'; }
  service_health >/dev/null 2>&1
); then
  fail 'health foreign-source guard returned an operational error'
fi
[ ! -e "$HEALTH_LOCK_VIOLATION" ] || fail 'health queried systemd while holding the state lock'
[ ! -e "$HEALTH_FOREIGN_CALLS" ] || fail 'health restarted a foreign same-named main service'
[ ! -e "$HEALTH_RESTART_FILE" ] || fail 'health consumed cooldown before rejecting a foreign main service'
assert_eq "${RUN_B}=3" "$(cat "$HEALTH_FAILURE_FILE")" 'health foreign-source guard lost the failure count'
printf 'health restart ownership test passed\n'

# Health-triggered restart is a mutation too: a stale template, active drop-in,
# or pending reload must preserve the failure counter without claiming cooldown
# or restarting the same-named service.
for health_guard_case in byte-drift dropin-present reload-needed; do
  seed_lifecycle_managed_units
  write_runtime_fixture "$RUN_B" "$BOOT_A" proxy RUNNING 1 0
  printf '%s\n' "${RUN_B}=2" > "$HEALTH_FAILURE_FILE"
  rm -f -- "$HEALTH_RESTART_FILE"
  HEALTH_GUARD_CALLS="${TEST_ROOT}/health-${health_guard_case}.calls"
  rm -f -- "$HEALTH_GUARD_CALLS"
  if ! (
    case "$health_guard_case" in
      byte-drift) printf '%s\n' '# stale main unit' >> "$(unit_path "$SERVICE_NAME")" ;;
      dropin-present)
        LIFECYCLE_DROPIN_UNIT="$SERVICE_NAME"
        LIFECYCLE_DROPIN_MODE=present
        ;;
      reload-needed)
        LIFECYCLE_NEED_RELOAD_UNIT="$SERVICE_NAME"
        LIFECYCLE_NEED_RELOAD_MODE=yes
        ;;
    esac
    systemctl() {
      if [ "$1" = show ]; then mock_lifecycle_unit_query "$@"; return; fi
      case "$*" in
        "is-active --quiet $SERVICE_NAME") return 0 ;;
        "restart $SERVICE_NAME") printf '%s\n' restart >> "$HEALTH_GUARD_CALLS"; return 0 ;;
        *) return 0 ;;
      esac
    }
    health_once() { return 1; }
    date() { printf '3000\n'; }
    service_health >/dev/null 2>&1
  ); then
    fail "health $health_guard_case guard returned an operational error"
  fi
  [ ! -e "$HEALTH_GUARD_CALLS" ] || fail "health restarted after $health_guard_case"
  [ ! -e "$HEALTH_RESTART_FILE" ] || fail "health claimed cooldown before rejecting $health_guard_case"
  assert_eq "${RUN_B}=3" "$(cat "$HEALTH_FAILURE_FILE")" "health $health_guard_case guard lost the failure count"
done
seed_lifecycle_managed_units

# Old-generation failure/cooldown values are ignored rather than inherited.
write_runtime_fixture "$RUN_B" "$BOOT_A" proxy RUNNING 1 0
printf '%s\n' "${RUN_A}=2" > "$HEALTH_FAILURE_FILE"
printf '%s\n' "${RUN_A}=1999" > "$HEALTH_RESTART_FILE"
HEALTH_CALLS="${TEST_ROOT}/health.calls"
systemctl() {
  if [ "$1" = show ]; then mock_lifecycle_unit_query "$@"; return; fi
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
[ ! -e "$SERVICE_RUN_ID_FILE" ] && [ ! -L "$SERVICE_RUN_ID_FILE" ] \
  || fail 'successful active-generation cleanup retained the restart-blocking owner marker'
rm -f -- "$SERVICE_SIDE_EFFECTS"
if ! (
  export SERVICE_SIDE_EFFECTS
  PATH="$MOCK_BIN:$PATH"
  openconnect_option_supported() { return 1; }
  service_run
) >/dev/null 2>&1; then
  fail 'successful cleanup prevented a legal service restart'
fi
grep -Fx openconnect "$SERVICE_SIDE_EFFECTS" >/dev/null \
  || fail 'legal service restart did not reach OpenConnect'
write_run_state "$RUN_B" STOPPING 0 0
printf '%s\n' "$RUN_B" > "$SERVICE_RUN_ID_FILE"
service_cleanup >/dev/null || fail 'inactive-generation ExecStopPost cleanup failed'
assert_state CLEANED 0 0 'inactive-generation ExecStopPost did not commit CLEANED'
[ ! -e "$SERVICE_RUN_ID_FILE" ] && [ ! -L "$SERVICE_RUN_ID_FILE" ] \
  || fail 'successful inactive-generation cleanup retained the owner marker'

printf 'lifecycle checks passed\n'
