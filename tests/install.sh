#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "${BASH_SOURCE[0]%/*}/.."

PATH="/usr/bin:/bin:${PATH}"
export PATH

# shellcheck source=./testlib.sh
source tests/testlib.sh

TEST_ROOT="$(new_test_root)"
trap 'cleanup_test_root "$TEST_ROOT"' EXIT
export_test_paths "$TEST_ROOT"

# shellcheck source=../oc_master.sh
source ./oc_master.sh

# Directory ownership is not part of the deployment transaction and Git for
# Windows cannot emulate root-owned 0700 directories.
ensure_dirs() {
  mkdir -p -- "$OCM_CONFIG_DIR" "$OCM_RUNTIME_DIR"
}

systemctl() {
  local action="${1:-}" unit=""
  shift || true
  case "$action" in
    is-active)
      [ "${1:-}" = --quiet ] && shift
      unit="${1:-}"
      case "$unit" in
        "$SERVICE_NAME") printf '%s\n' "${MOCK_MAIN_STATE:-inactive}" ;;
        "$HEALTH_SERVICE_NAME") printf '%s\n' inactive ;;
        "$HEALTH_TIMER_NAME") printf '%s\n' inactive ;;
      esac
      return 3
      ;;
    daemon-reload)
      [ "${MOCK_DAEMON_RELOAD_FAIL:-0}" != 1 ]
      ;;
    show)
      unit="${1:-}"
      shift || true
      if [[ " $* " == *LoadState* ]]; then
        printf '%s\n' "${MOCK_LOAD_STATE:-loaded}"
        return 0
      fi
      [ "${MOCK_SHOW_FAIL:-0}" != 1 ] || return 1
      case "$unit" in
        "$SERVICE_NAME")
          printf '%s\n' \
            "ExecStart={ path=${INSTALL_PATH} ; argv[]=${INSTALL_PATH} _service_run ; }" \
            "ExecStopPost={ path=${INSTALL_PATH} ; argv[]=${INSTALL_PATH} _service_cleanup ; }" \
            'Restart=always' \
            'RestartPreventExitStatus=78'
          ;;
        "$HEALTH_SERVICE_NAME") printf 'ExecStart={ path=%s ; argv[]=%s _service_health ; }\n' "$INSTALL_PATH" "$INSTALL_PATH" ;;
      esac
      ;;
    *) return 0 ;;
  esac
}

seed_legacy_units() {
  mkdir -p -- "$OCM_SYSTEMD_DIR" "$(dirname -- "$OCM_INSTALL_PATH")"
  printf '#!/usr/bin/env bash\nprintf old-program\\n\n' > "$OCM_INSTALL_PATH"
  chmod 0755 -- "$OCM_INSTALL_PATH"
  cat > "${OCM_SYSTEMD_DIR}/${SERVICE_NAME}" <<EOF
[Unit]
Description=OpenConnect Master managed tunnel
[Service]
ExecStart=${OCM_INSTALL_PATH} _service_run
ExecStopPost=-${OCM_INSTALL_PATH} _service_cleanup
EOF
  cat > "${OCM_SYSTEMD_DIR}/${HEALTH_SERVICE_NAME}" <<EOF
[Unit]
Description=OpenConnect Master data-plane health check
[Service]
ExecStart=${OCM_INSTALL_PATH} _service_health
EOF
  cat > "${OCM_SYSTEMD_DIR}/${HEALTH_TIMER_NAME}" <<EOF
[Unit]
Description=Run OpenConnect Master health checks
[Timer]
Unit=${HEALTH_SERVICE_NAME}
EOF
}

assert_no_transaction_leftovers() {
  if find "$TEST_ROOT" \( -name '*.backup' -o -name '.*.oc-master.*' \) -print -quit | grep -q .; then
    fail "install left a temporary or backup file"
  fi
}

assert_deployed_mode() {
  local path="$1" expected="$2" observed
  observed="$(stat -c '%a' -- "$path")"
  if [ "$observed" = "$expected" ]; then return 0; fi
  case "$expected:$observed" in
    755:700) [ -x "$path" ] || fail "program is not executable: $path" ;;
    644:600) [ -r "$path" ] || fail "unit is not readable: $path" ;;
    *) fail "unexpected mode for $path (expected: $expected; actual: $observed)" ;;
  esac
  printf 'non-POSIX mode emulation: %s is %s rather than %s\n' "$path" "$observed" "$expected" >&2
}

assert_legacy_restored() {
  cmp -s "$TEST_ROOT/original-program" "$OCM_INSTALL_PATH" || fail "program was not restored"
  cmp -s "$TEST_ROOT/original-main" "${OCM_SYSTEMD_DIR}/${SERVICE_NAME}" || fail "main unit was not restored"
  cmp -s "$TEST_ROOT/original-health" "${OCM_SYSTEMD_DIR}/${HEALTH_SERVICE_NAME}" || fail "health unit was not restored"
  cmp -s "$TEST_ROOT/original-timer" "${OCM_SYSTEMD_DIR}/${HEALTH_TIMER_NAME}" || fail "timer unit was not restored"
  [ ! -e "$OCM_SHORTCUT_PATH" ] && [ ! -L "$OCM_SHORTCUT_PATH" ] || fail 'new shortcut was not removed'
  assert_no_transaction_leftovers
}

save_legacy_originals() {
  cp -- "$OCM_INSTALL_PATH" "$TEST_ROOT/original-program"
  cp -- "${OCM_SYSTEMD_DIR}/${SERVICE_NAME}" "$TEST_ROOT/original-main"
  cp -- "${OCM_SYSTEMD_DIR}/${HEALTH_SERVICE_NAME}" "$TEST_ROOT/original-health"
  cp -- "${OCM_SYSTEMD_DIR}/${HEALTH_TIMER_NAME}" "$TEST_ROOT/original-timer"
}

# A replacement while the main unit is transitioning can race with systemd's
# restart/stop machinery.  Only inactive, failed, or absent units are safe.
for state in active activating deactivating reloading; do
  rm -f -- "$OCM_INSTALL_PATH" "$OCM_SHORTCUT_PATH"
  MOCK_MAIN_STATE="$state"
  MOCK_LOAD_STATE=loaded
  if install_command >/dev/null 2>&1; then
    fail "install accepted main service state: $state"
  fi
  [ ! -e "$OCM_INSTALL_PATH" ] && [ ! -L "$OCM_INSTALL_PATH" ] \
    || fail "install changed program while main service was $state"
done

for state in inactive failed; do
  MOCK_MAIN_STATE="$state"
  MOCK_LOAD_STATE=loaded
  service_state_allows_install || fail "install rejected safe main service state: $state"
done
MOCK_MAIN_STATE=unknown
MOCK_LOAD_STATE=not-found
service_state_allows_install || fail 'install rejected an absent main unit'

# A foreign shortcut must abort before the installer changes the program or
# creates any unit file.
mkdir -p -- "$(dirname -- "$OCM_SHORTCUT_PATH")"
printf 'foreign shortcut\n' > "$OCM_SHORTCUT_PATH"
if install_self_and_units >/dev/null 2>&1; then
  fail 'foreign shortcut conflict was accepted'
fi
grep -Fx 'foreign shortcut' "$OCM_SHORTCUT_PATH" >/dev/null || fail 'foreign shortcut changed'
[ ! -e "$OCM_INSTALL_PATH" ] || fail 'foreign shortcut conflict changed program'
[ ! -e "${OCM_SYSTEMD_DIR}/${SERVICE_NAME}" ] || fail 'foreign shortcut conflict created main unit'
rm -f -- "$OCM_SHORTCUT_PATH"

# A foreign unit has the same zero-write guarantee as a foreign shortcut.
mkdir -p -- "$OCM_SYSTEMD_DIR" "$(dirname -- "$OCM_INSTALL_PATH")"
printf '#!/usr/bin/env bash\nprintf old-program\\n' > "$OCM_INSTALL_PATH"
printf 'foreign unit\n' > "${OCM_SYSTEMD_DIR}/${SERVICE_NAME}"
if install_self_and_units >/dev/null 2>&1; then
  fail 'foreign unit conflict was accepted'
fi
grep -Fx 'foreign unit' "${OCM_SYSTEMD_DIR}/${SERVICE_NAME}" >/dev/null || fail 'foreign unit changed'
grep -F 'old-program' "$OCM_INSTALL_PATH" >/dev/null || fail 'foreign unit conflict changed program'
rm -rf -- "$OCM_SYSTEMD_DIR" "$(dirname -- "$OCM_INSTALL_PATH")"

# Headerless v8 units are recognized by their complete legacy identity and
# migrate to the stable managed header.
seed_legacy_units
install_self_and_units || fail 'legacy v8 units were not migrated'
for unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
  head -n 1 "${OCM_SYSTEMD_DIR}/${unit}" | grep -Fx '# Managed by oc-master' >/dev/null \
    || fail "migrated unit lacks managed header: $unit"
  assert_deployed_mode "${OCM_SYSTEMD_DIR}/${unit}" 644
done
assert_deployed_mode "$OCM_INSTALL_PATH" 755
assert_no_transaction_leftovers
rm -rf -- "$OCM_SYSTEMD_DIR" "$(dirname -- "$OCM_INSTALL_PATH")" "$(dirname -- "$OCM_SHORTCUT_PATH")"

# A failed restoration must preserve the only old-program backup and report
# failure; deleting that evidence would turn a deployment error into data loss.
seed_legacy_units
save_legacy_originals
MOCK_HEALTH_STAGE_FAIL=1
MOCK_PROGRAM_RESTORE_FAIL=1
MOCK_PROGRAM_INSTALL_MOVES=0
mv() {
  local destination="${!#}"
  if [ "$destination" = "${OCM_SYSTEMD_DIR}/${HEALTH_SERVICE_NAME}" ] && [ "${MOCK_HEALTH_STAGE_FAIL:-0}" = 1 ]; then
    MOCK_HEALTH_STAGE_FAIL=0
    return 1
  fi
  if [ "$destination" = "$OCM_INSTALL_PATH" ]; then
    MOCK_PROGRAM_INSTALL_MOVES=$((MOCK_PROGRAM_INSTALL_MOVES + 1))
  fi
  if [ "$destination" = "$OCM_INSTALL_PATH" ] && [ "$MOCK_PROGRAM_INSTALL_MOVES" -eq 2 ] && [ "${MOCK_PROGRAM_RESTORE_FAIL:-0}" = 1 ]; then
    MOCK_PROGRAM_RESTORE_FAIL=0
    return 1
  fi
  command mv "$@"
}
if install_self_and_units >"$TEST_ROOT/install-restore-failure.out" 2>&1; then
  fail 'install succeeded although restoration failed'
fi
unset -f mv
find "$(dirname -- "$OCM_INSTALL_PATH")" -name '*.backup' -print -quit | grep -q . \
  || fail 'failed restoration deleted the old-program backup'
[ ! -e "$OCM_INSTALL_PATH" ] || fail 'failed restoration left a replacement program in place'
rm -rf -- "$OCM_SYSTEMD_DIR" "$(dirname -- "$OCM_INSTALL_PATH")" "$(dirname -- "$OCM_SHORTCUT_PATH")"
printf 'rollback-failure preservation test passed\n'

# Program-only managed-copy rollback must run even where Git for Windows cannot
# create symlinks.  The shortcut staging boundary is isolated in this subshell.
mkdir -p -- "$(dirname -- "$OCM_INSTALL_PATH")"
printf '#!/usr/bin/env bash\nprintf old-managed-program\\n' > "$OCM_INSTALL_PATH"
cp -- "$OCM_INSTALL_PATH" "$TEST_ROOT/original-managed-program"
if ! (
  stage_shortcut() { return 0; }
  MOCK_MANAGED_PROGRAM_MOVES=0
  mv() {
    local destination="${!#}"
    if [ "$destination" = "$OCM_INSTALL_PATH" ]; then
      MOCK_MANAGED_PROGRAM_MOVES=$((MOCK_MANAGED_PROGRAM_MOVES + 1))
      [ "$MOCK_MANAGED_PROGRAM_MOVES" -eq 1 ] && return 1
    fi
    command mv "$@"
  }
  install_managed_copy
); then
  :
else
  fail 'managed-copy program rename failure unexpectedly succeeded'
fi
cmp -s "$TEST_ROOT/original-managed-program" "$OCM_INSTALL_PATH" || fail 'managed-copy program rollback did not restore old program'
assert_no_transaction_leftovers
rm -rf -- "$(dirname -- "$OCM_INSTALL_PATH")"

# A backup deletion failure is a transaction failure, so it must restore the
# old program instead of leaving a new program with an ambiguous error result.
mkdir -p -- "$(dirname -- "$OCM_INSTALL_PATH")"
printf '#!/usr/bin/env bash\nprintf old-managed-program\\n' > "$OCM_INSTALL_PATH"
cp -- "$OCM_INSTALL_PATH" "$TEST_ROOT/original-managed-program"
if ! (
  stage_shortcut() { return 0; }
  MOCK_BACKUP_DELETE_FAIL=1
  rm() {
    local target="${!#}"
    if [ "${MOCK_BACKUP_DELETE_FAIL:-0}" = 1 ] && [[ "$target" == *.backup ]]; then
      MOCK_BACKUP_DELETE_FAIL=0
      return 1
    fi
    command rm "$@"
  }
  install_managed_copy
); then
  :
else
  fail 'managed-copy backup cleanup failure unexpectedly succeeded'
fi
cmp -s "$TEST_ROOT/original-managed-program" "$OCM_INSTALL_PATH" || fail 'managed-copy backup cleanup failure did not restore old program'
assert_no_transaction_leftovers
rm -rf -- "$(dirname -- "$OCM_INSTALL_PATH")"

# If restoring the old program also fails, the backup must remain available and
# the replacement target must not be reported as successfully installed.
mkdir -p -- "$(dirname -- "$OCM_INSTALL_PATH")"
printf '#!/usr/bin/env bash\nprintf old-managed-program\\n' > "$OCM_INSTALL_PATH"
MOCK_MANAGED_PROGRAM_MOVES=0
mv() {
  local destination="${!#}"
  if [ "$destination" = "$OCM_INSTALL_PATH" ]; then
    MOCK_MANAGED_PROGRAM_MOVES=$((MOCK_MANAGED_PROGRAM_MOVES + 1))
    [ "$MOCK_MANAGED_PROGRAM_MOVES" -le 2 ] && return 1
  fi
  command mv "$@"
}
if install_managed_copy >"$TEST_ROOT/managed-restore-failure.out" 2>&1; then
  fail 'install_managed_copy succeeded although its restoration failed'
fi
unset -f mv
find "$(dirname -- "$OCM_INSTALL_PATH")" -name '*.backup' -print -quit | grep -q . \
  || fail 'install_managed_copy deleted backup after restoration failure'
[ ! -e "$OCM_INSTALL_PATH" ] || fail 'install_managed_copy left replacement after restoration failure'
rm -rf -- "$(dirname -- "$OCM_INSTALL_PATH")"
printf 'managed-copy program transaction tests passed\n'

# When no shortcut staging is needed, cleanup after a failed program-backup
# rename must skip the empty placeholder rather than invoking rm with "".
mkdir -p -- "$(dirname -- "$OCM_INSTALL_PATH")"
printf '#!/usr/bin/env bash\nprintf old-managed-program\\n' > "$OCM_INSTALL_PATH"
empty_cleanup_marker="${TEST_ROOT}/managed-copy-empty-cleanup.called"
if (
  stage_shortcut() { return 0; }
  mv() {
    local destination="${!#}"
    [[ "$destination" != *.backup ]] || return 1
    command mv "$@"
  }
  rm() {
    local target="${!#}"
    if [ -z "$target" ]; then
      : > "$empty_cleanup_marker"
      return 0
    fi
    command rm "$@"
  }
  install_managed_copy
); then
  fail 'managed-copy backup rename failure unexpectedly succeeded'
fi
[ ! -e "$empty_cleanup_marker" ] || fail 'managed-copy cleanup called rm with an empty temporary path'
grep -F 'old-managed-program' "$OCM_INSTALL_PATH" >/dev/null \
  || fail 'managed-copy backup rename failure changed the old program'
rm -rf -- "$(dirname -- "$OCM_INSTALL_PATH")"
printf 'managed-copy empty cleanup test passed\n'

# A unit staging write failure whose local temporary cannot be deleted must
# leave the evidence and emit a cleanup-specific diagnostic.
mkdir -p -- "$OCM_SYSTEMD_DIR"
if ! (
  write_unit_file() { return 1; }
  rm() { return 1; }
  stage_unit_file "$SERVICE_NAME"
) >"$TEST_ROOT/unit-stage-cleanup.out" 2>&1; then
  :
else
  fail 'unit staging unexpectedly succeeded when writing and cleanup failed'
fi
grep -F '安装暂存清理失败' "$TEST_ROOT/unit-stage-cleanup.out" >/dev/null \
  || fail 'unit staging cleanup failure lacked a diagnostic'
find "$OCM_SYSTEMD_DIR" -name ".${SERVICE_NAME}.${TAG}.*" -print -quit | grep -q . \
  || fail 'unit staging cleanup failure did not preserve evidence'
rm -rf -- "$OCM_SYSTEMD_DIR"

# A failed heredoc writer must be the result of write_unit_file itself.  The
# chmod/readability tail must never turn any of the three failed writes into a
# successful staged unit.
for unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
  chmod_marker="${TEST_ROOT}/${unit}.chmod-after-write-failure"
  if (
    cat() { return 41; }
    chmod() { : > "$chmod_marker"; return 0; }
    write_unit_file "$unit" "${TEST_ROOT}/${unit}.failed-write"
  ); then
    fail "write_unit_file masked a failed heredoc write for $unit"
  fi
  [ ! -e "$chmod_marker" ] || fail "write_unit_file ran chmod after a failed heredoc write for $unit"
done
printf 'unit writer failure propagation tests passed\n'

# The public `ocm install` path has the same transactional obligation as the
# unit installer.  Only shortcut commit coverage needs a real POSIX symlink.
if mkdir -p -- "$(dirname -- "$OCM_SHORTCUT_PATH")" \
  && ln -s -- probe "${OCM_SHORTCUT_PATH}.probe" 2>/dev/null; then
  rm -f -- "${OCM_SHORTCUT_PATH}.probe"
  failure=managed-shortcut
    mkdir -p -- "$(dirname -- "$OCM_INSTALL_PATH")"
    printf '#!/usr/bin/env bash\nprintf old-managed-program\\n' > "$OCM_INSTALL_PATH"
    cp -- "$OCM_INSTALL_PATH" "$TEST_ROOT/original-managed-program"
    MOCK_MANAGED_PROGRAM_MOVES=0
    mv() {
      local destination="${!#}"
      if [ "$destination" = "$OCM_INSTALL_PATH" ]; then
        MOCK_MANAGED_PROGRAM_MOVES=$((MOCK_MANAGED_PROGRAM_MOVES + 1))
      fi
      if [ "$failure" = managed-program ] && [ "$destination" = "$OCM_INSTALL_PATH" ] && [ "$MOCK_MANAGED_PROGRAM_MOVES" -eq 1 ]; then return 1; fi
      if [ "$failure" = managed-shortcut ] && [ "$destination" = "$OCM_SHORTCUT_PATH" ]; then return 1; fi
      command mv "$@"
    }
    if install_managed_copy >"$TEST_ROOT/${failure}.out" 2>&1; then
      fail "install_managed_copy unexpectedly succeeded after $failure failure"
    fi
    unset -f mv
    cmp -s "$TEST_ROOT/original-managed-program" "$OCM_INSTALL_PATH" || fail "install_managed_copy did not restore old program after $failure failure"
    [ ! -e "$OCM_SHORTCUT_PATH" ] && [ ! -L "$OCM_SHORTCUT_PATH" ] || fail "install_managed_copy left shortcut after $failure failure"
    assert_no_transaction_leftovers
    rm -rf -- "$(dirname -- "$OCM_INSTALL_PATH")" "$(dirname -- "$OCM_SHORTCUT_PATH")"
  printf 'managed-copy shortcut commit rollback test passed\n'

  # When removing a committed shortcut fails during rollback, retain it as
  # evidence and report the rollback failure instead of claiming success.
  mkdir -p -- "$(dirname -- "$OCM_INSTALL_PATH")" "$(dirname -- "$OCM_SHORTCUT_PATH")"
  printf '#!/usr/bin/env bash\nprintf old-managed-program\\n' > "$OCM_INSTALL_PATH"
  MOCK_BACKUP_DELETE_FAIL=1
  MOCK_SHORTCUT_REMOVE_FAIL=1
  rm() {
    local target="${!#}"
    if [ "${MOCK_BACKUP_DELETE_FAIL:-0}" = 1 ] && [[ "$target" == *.backup ]]; then
      MOCK_BACKUP_DELETE_FAIL=0
      return 1
    fi
    if [ "${MOCK_SHORTCUT_REMOVE_FAIL:-0}" = 1 ] && [ "$target" = "$OCM_SHORTCUT_PATH" ]; then
      MOCK_SHORTCUT_REMOVE_FAIL=0
      return 1
    fi
    command rm "$@"
  }
  if install_managed_copy >"$TEST_ROOT/managed-shortcut-restore-failure.out" 2>&1; then
    fail 'install_managed_copy succeeded although shortcut restoration failed'
  fi
  unset -f rm
  cmp -s "$TEST_ROOT/original-managed-program" "$OCM_INSTALL_PATH" || fail 'shortcut restoration failure did not restore old program'
  [ -e "$OCM_SHORTCUT_PATH" ] || [ -L "$OCM_SHORTCUT_PATH" ] \
    || fail 'shortcut restoration failure discarded diagnostic evidence'
  grep -F '安装回滚失败' "$TEST_ROOT/managed-shortcut-restore-failure.out" >/dev/null \
    || fail 'shortcut restoration failure lacked a rollback diagnostic'
  rm -rf -- "$(dirname -- "$OCM_INSTALL_PATH")" "$(dirname -- "$OCM_SHORTCUT_PATH")"
  printf 'managed-copy shortcut restoration failure test passed\n'
else
  printf 'managed-copy shortcut rollback checks skipped: filesystem does not expose POSIX symlinks\n'
fi

for failure in program main-unit health-unit timer-unit shortcut daemon-reload show-properties; do
  printf 'testing failure recovery: %s\n' "$failure"
  seed_legacy_units
  save_legacy_originals
  MOCK_DAEMON_RELOAD_FAIL=0
  MOCK_SHOW_FAIL=0
  MOCK_MV_FAIL_DEST=''
  MOCK_MV_FAIL_ONCE=0
  case "$failure" in
    program)
      MOCK_MV_FAIL_DEST="$OCM_INSTALL_PATH"
      MOCK_MV_FAIL_ONCE=1
      ;;
    main-unit)
      MOCK_MV_FAIL_DEST="${OCM_SYSTEMD_DIR}/${SERVICE_NAME}"
      MOCK_MV_FAIL_ONCE=1
      ;;
    health-unit)
      MOCK_MV_FAIL_DEST="${OCM_SYSTEMD_DIR}/${HEALTH_SERVICE_NAME}"
      MOCK_MV_FAIL_ONCE=1
      ;;
    timer-unit)
      MOCK_MV_FAIL_DEST="${OCM_SYSTEMD_DIR}/${HEALTH_TIMER_NAME}"
      MOCK_MV_FAIL_ONCE=1
      ;;
    shortcut)
      MOCK_MV_FAIL_DEST="$OCM_SHORTCUT_PATH"
      MOCK_MV_FAIL_ONCE=1
      ;;
    daemon-reload) MOCK_DAEMON_RELOAD_FAIL=1 ;;
    show-properties) MOCK_SHOW_FAIL=1 ;;
  esac
  mv() {
    local destination="${!#}"
    if [ "${MOCK_MV_FAIL_ONCE:-0}" = 1 ] && [ "$destination" = "$MOCK_MV_FAIL_DEST" ]; then
      MOCK_MV_FAIL_ONCE=0
      return 1
    fi
    command mv "$@"
  }
  set +e
  install_self_and_units >"$TEST_ROOT/install-${failure}.out" 2>&1
  install_result=$?
  set -e
  if [ "$install_result" -eq 0 ]; then
    fail "install unexpectedly succeeded after $failure failure"
  fi
  unset -f mv
  assert_legacy_restored
  printf 'recovered failure: %s\n' "$failure"
  rm -rf -- "$OCM_SYSTEMD_DIR" "$(dirname -- "$OCM_INSTALL_PATH")" "$(dirname -- "$OCM_SHORTCUT_PATH")"
done

# Unit/program replacement is committed once daemon-reload and the property
# verification succeed.  A later backup deletion failure must be reported for
# every position without attempting an impossible partial rollback.
for backup_failure_case in first middle last; do
  case "$backup_failure_case" in
    first) backup_failure_index=1 ;;
    middle) backup_failure_index=2 ;;
    last) backup_failure_index=4 ;;
  esac
  seed_legacy_units
  MOCK_DAEMON_RELOAD_FAIL=0
  MOCK_SHOW_FAIL=0
  failed_backup_record="${TEST_ROOT}/backup-cleanup-${backup_failure_case}.path"
  backup_cleanup_output="${TEST_ROOT}/backup-cleanup-${backup_failure_case}.out"
  backup_cleanup_result=0
  if (
    shortcut_is_ours() { return 0; }
    backup_delete_count=0
    rm() {
      local target="${!#}"
      if [[ "$target" == *.backup ]]; then
        backup_delete_count=$((backup_delete_count + 1))
        if [ "$backup_delete_count" -eq "$backup_failure_index" ]; then
          printf '%s\n' "$target" > "$failed_backup_record"
          return 1
        fi
      fi
      command rm "$@"
    }
    install_self_and_units
  ) > "$backup_cleanup_output" 2>&1; then
    backup_cleanup_result=0
  else
    backup_cleanup_result=$?
  fi
  [ "$backup_cleanup_result" -ne 0 ] \
    || fail "committed install masked $backup_failure_case backup cleanup failure"
  [ -s "$failed_backup_record" ] || fail "$backup_failure_case backup cleanup failure was not injected"
  failed_backup_path="$(<"$failed_backup_record")"
  [ -f "$failed_backup_path" ] || fail "$backup_failure_case failed backup was not retained"
  [ "$(find "$TEST_ROOT" -name '*.backup' -type f | wc -l | tr -d ' ')" = 1 ] \
    || fail "$backup_failure_case backup cleanup retained more than the failed backup"
  cmp -s -- "$SCRIPT_PATH" "$OCM_INSTALL_PATH" \
    || fail "$backup_failure_case backup cleanup failure rolled back the committed program"
  for unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
    head -n 1 -- "$(unit_path "$unit")" | grep -Fx '# Managed by oc-master' >/dev/null \
      || fail "$backup_failure_case backup cleanup failure rolled back $unit"
  done
  grep -F '安装已提交并验证，但备份清理未完成' "$backup_cleanup_output" >/dev/null \
    || fail "$backup_failure_case backup cleanup failure lacked committed-state diagnostic"
  rm -rf -- "$OCM_SYSTEMD_DIR" "$(dirname -- "$OCM_INSTALL_PATH")" "$(dirname -- "$OCM_SHORTCUT_PATH")"
done
printf 'committed backup cleanup failure tests passed\n'

# Do not trust rm's exit status alone: a wrapper or filesystem race that leaves
# the backup path in place is still an incomplete committed cleanup.
seed_legacy_units
MOCK_DAEMON_RELOAD_FAIL=0
MOCK_SHOW_FAIL=0
backup_postcondition_output="${TEST_ROOT}/backup-cleanup-postcondition.out"
backup_postcondition_result=0
if (
  shortcut_is_ours() { return 0; }
  skipped_backup_delete=0
  rm() {
    local target="${!#}"
    if [ "$skipped_backup_delete" -eq 0 ] && [[ "$target" == *.backup ]]; then
      skipped_backup_delete=1
      return 0
    fi
    command rm "$@"
  }
  install_self_and_units
) > "$backup_postcondition_output" 2>&1; then
  backup_postcondition_result=0
else
  backup_postcondition_result=$?
fi
[ "$backup_postcondition_result" -ne 0 ] \
  || fail 'committed install trusted rm success although a backup still existed'
[ "$(find "$TEST_ROOT" -name '*.backup' -type f | wc -l | tr -d ' ')" = 1 ] \
  || fail 'backup postcondition failure did not retain exactly the undeleted backup'
grep -F '安装已提交并验证，但备份清理未完成' "$backup_postcondition_output" >/dev/null \
  || fail 'backup postcondition failure lacked committed-state diagnostic'
rm -rf -- "$OCM_SYSTEMD_DIR" "$(dirname -- "$OCM_INSTALL_PATH")" "$(dirname -- "$OCM_SHORTCUT_PATH")"
printf 'committed backup cleanup postcondition test passed\n'

# Successful deployment writes the documented modes and leaves no staging
# files, while systemctl properties confirm the generated lifecycle contract.
printf 'failure recovery tests passed\n'
MOCK_DAEMON_RELOAD_FAIL=0
MOCK_SHOW_FAIL=0
seed_legacy_units
install_self_and_units || fail 'managed install failed'
assert_deployed_mode "$OCM_INSTALL_PATH" 755
for unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
  assert_deployed_mode "${OCM_SYSTEMD_DIR}/${unit}" 644
done
assert_no_transaction_leftovers
rm -rf -- "$OCM_SYSTEMD_DIR" "$(dirname -- "$OCM_INSTALL_PATH")" "$(dirname -- "$OCM_SHORTCUT_PATH")"
printf 'successful deployment test passed\n'

# Uninstall must preserve a unit that cannot be attributed to oc-master.
mkdir -p -- "$OCM_SYSTEMD_DIR"
for unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
  printf 'foreign unit %s\n' "$unit" > "${OCM_SYSTEMD_DIR}/${unit}"
done
stop_vpn() { :; }
printf 'REMOVE\n' | uninstall_manager >/dev/null || fail 'uninstall failed with foreign units'
for unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
  grep -Fx "foreign unit $unit" "${OCM_SYSTEMD_DIR}/${unit}" >/dev/null \
    || fail "uninstall deleted foreign unit: $unit"
done

printf 'install tests passed\n'
