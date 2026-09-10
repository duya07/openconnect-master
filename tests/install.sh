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

# The public `ocm install` path has the same transactional obligation as the
# unit installer.  Exercise both of its commit renames against a real staged
# program and symlink when the filesystem supports symlinks.
if mkdir -p -- "$(dirname -- "$OCM_SHORTCUT_PATH")" \
  && ln -s -- probe "${OCM_SHORTCUT_PATH}.probe" 2>/dev/null; then
  rm -f -- "${OCM_SHORTCUT_PATH}.probe"
  for failure in managed-program managed-shortcut; do
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
  done
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
  rm -rf -- "$(dirname -- "$OCM_INSTALL_PATH")" "$(dirname -- "$OCM_SHORTCUT_PATH")"
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
