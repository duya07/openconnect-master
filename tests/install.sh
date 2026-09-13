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
if [ "${OCM_INSTALL_SELF_PATH_CASE:-0}" = 1 ]; then
  mkdir -p -- "$(dirname -- "$OCM_INSTALL_PATH")"
  cp -- ./oc_master.sh "$OCM_INSTALL_PATH"
  chmod 0755 -- "$OCM_INSTALL_PATH"
  source "$OCM_INSTALL_PATH"
else
  source ./oc_master.sh
fi

# Directory ownership is not part of the deployment transaction and Git for
# Windows cannot emulate root-owned 0700 directories.
ensure_dirs() {
  mkdir -p -- "$OCM_CONFIG_DIR" "$OCM_RUNTIME_DIR"
}

systemctl() {
  local action="${1:-}" unit="" property="" source_case="${MOCK_SOURCE_CASE:-owned}"
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
      printf '%s\n' daemon-reload >> "${MOCK_SYSTEMCTL_MUTATIONS:-/dev/null}"
      [ "${MOCK_DAEMON_RELOAD_FAIL:-0}" != 1 ]
      ;;
    show)
      unit="${1:-}"
      shift || true
      if [ "$#" -eq 2 ] && [ "$1" = --all ] && [ "$2" = --property=DropInPaths ]; then
        if [ "$unit" = "${MOCK_SOURCE_UNIT:-}" ]; then
          case "$source_case" in
            dropin-query-fail) return 1 ;;
            dropin-missing) return 0 ;;
            dropin-present) printf 'DropInPaths=/etc/systemd/system/%s.d/override.conf\n' "$unit"; return 0 ;;
          esac
        fi
        printf 'DropInPaths=\n'
        return 0
      fi
      if [[ " $* " != *' --value '* ]] && [[ " $* " == *' --property=ExecStart '* ]]; then
        [ "${MOCK_SHOW_FAIL:-0}" != 1 ] || return 1
        case "$unit" in
          "$SERVICE_NAME")
            printf '%s\n' \
              "ExecStart={ path=${INSTALL_PATH} ; argv[]=${INSTALL_PATH} ${MOCK_MAIN_START_ACTION:-_service_run} ; }" \
              "ExecStopPost={ path=${INSTALL_PATH} ; argv[]=${INSTALL_PATH} ${MOCK_MAIN_STOP_ACTION:-_service_cleanup} ; }" \
              "Restart=${MOCK_MAIN_RESTART:-always}" \
              "RestartPreventExitStatus=${MOCK_MAIN_RESTART_PREVENT:-78}"
            ;;
          "$HEALTH_SERVICE_NAME") printf 'ExecStart={ path=%s ; argv[]=%s %s ; }\n' "$INSTALL_PATH" "$INSTALL_PATH" "${MOCK_HEALTH_ACTION:-_service_health}" ;;
          *) return 1 ;;
        esac
        return 0
      fi
      case " $* " in
        *' --property=LoadState --value '*) property=LoadState ;;
        *' --property=FragmentPath --value '*) property=FragmentPath ;;
        *' --property=ExecStart --value '*) property=ExecStart ;;
        *' --property=ExecStopPost --value '*) property=ExecStopPost ;;
        *' --property=Restart --value '*) property=Restart ;;
        *' --property=RestartPreventExitStatus --value '*) property=RestartPreventExitStatus ;;
        *' --property=Triggers --value '*) property=Triggers ;;
        *' --property=NeedDaemonReload --value '*) property=NeedDaemonReload ;;
      esac
      if [ "$unit" = "${MOCK_SOURCE_UNIT:-}" ]; then
        case "$source_case:$property" in
          query-fail:LoadState|fragment-query-fail:FragmentPath) return 1 ;;
          not-found:LoadState) printf '%s\n' not-found; return 0 ;;
          masked:LoadState) printf '%s\n' masked; return 0 ;;
          empty-load:LoadState) printf '\n'; return 0 ;;
          external:FragmentPath) printf '/etc/systemd/system/%s\n' "$unit"; return 0 ;;
          empty-fragment:FragmentPath) printf '\n'; return 0 ;;
        esac
      fi
      case "$property" in
        LoadState) printf '%s\n' "${MOCK_LOAD_STATE:-loaded}"; return 0 ;;
        FragmentPath) unit_path "$unit"; return 0 ;;
      esac
      [ "${MOCK_SHOW_FAIL:-0}" != 1 ] || return 1
      case "$unit:$property" in
        "$SERVICE_NAME:ExecStart") printf 'path=%s ; argv[]=%s %s ; ignore_errors=no\n' "$INSTALL_PATH" "$INSTALL_PATH" "${MOCK_MAIN_START_ACTION:-_service_run}" ;;
        "$SERVICE_NAME:ExecStopPost") printf 'path=%s ; argv[]=%s %s ; ignore_errors=yes\n' "$INSTALL_PATH" "$INSTALL_PATH" "${MOCK_MAIN_STOP_ACTION:-_service_cleanup}" ;;
        "$SERVICE_NAME:Restart") printf '%s\n' "${MOCK_MAIN_RESTART:-always}" ;;
        "$SERVICE_NAME:RestartPreventExitStatus") printf '%s\n' "${MOCK_MAIN_RESTART_PREVENT:-78}" ;;
        "$HEALTH_SERVICE_NAME:ExecStart") printf 'path=%s ; argv[]=%s %s ; ignore_errors=no\n' "$INSTALL_PATH" "$INSTALL_PATH" "${MOCK_HEALTH_ACTION:-_service_health}" ;;
        "$HEALTH_TIMER_NAME:Triggers") printf '%s\n' "${MOCK_TIMER_TRIGGERS:-$HEALTH_SERVICE_NAME}" ;;
        "${MOCK_NEED_RELOAD_UNIT:-__none__}:NeedDaemonReload")
          case "${MOCK_NEED_RELOAD_CASE:-no}" in
            query-fail) return 1 ;;
            empty) printf '\n' ;;
            yes) printf 'yes\n' ;;
            no) printf 'no\n' ;;
            *) return 1 ;;
          esac
          ;;
        *:NeedDaemonReload) printf 'no\n' ;;
        *) return 1 ;;
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

seed_current_units() {
  local unit
  mkdir -p -- "$OCM_SYSTEMD_DIR" "$(dirname -- "$OCM_INSTALL_PATH")"
  printf '#!/usr/bin/env bash\nprintf old-program\\n\n' > "$OCM_INSTALL_PATH"
  chmod 0755 -- "$OCM_INSTALL_PATH"
  for unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
    write_unit_file "$unit" "$(unit_path "$unit")" || fail "could not seed current unit: $unit"
  done
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

run_self_path_post_promotion_race() {
  local race_marker='foreign post-promotion self-path program' injected backup new_reference install_rc=0
  local -a INSTALL_TX_TARGETS=() INSTALL_TX_KINDS=() INSTALL_TX_STAGED_TYPES=()
  local -a INSTALL_TX_STAGED_FILES=() INSTALL_TX_STAGED_VALUES=()

  seed_legacy_units
  save_legacy_originals
  new_reference="${TEST_ROOT}/self-path-program.new-expected"
  cp -- "$INSTALL_PATH" "$new_reference"
  INSTALL_TX_TARGETS=( "$INSTALL_PATH" )
  INSTALL_TX_KINDS=( program )
  INSTALL_TX_STAGED_TYPES=( file )
  INSTALL_TX_STAGED_FILES=( "$new_reference" )
  INSTALL_TX_STAGED_VALUES=( '' )
  # The production verifier consumes these arrays through Bash dynamic scope.
  : "${INSTALL_TX_TARGETS[@]}" "${INSTALL_TX_KINDS[@]}" "${INSTALL_TX_STAGED_TYPES[@]}" \
    "${INSTALL_TX_STAGED_FILES[@]}" "${INSTALL_TX_STAGED_VALUES[@]}"
  printf '#!/usr/bin/env bash\n# %s\n' "$race_marker" > "$INSTALL_PATH"
  [ "$SCRIPT_PATH" = "$INSTALL_PATH" ] || fail 'self-path fixture did not bind SCRIPT_PATH to INSTALL_PATH'
  [ -f "$INSTALL_PATH" ] && [ ! -L "$INSTALL_PATH" ] && [ -x "$INSTALL_PATH" ] \
    || fail 'self-path replacement did not retain the executable file shape'
  if installed_target_matches_transaction 0; then
    fail 'self-path verifier accepted bytes that differ from the staged program'
  fi

  seed_legacy_units
  save_legacy_originals
  injected="${TEST_ROOT}/post-promotion-self-path.injected"
  shortcut_is_ours() { return 0; }
  preflight_install_targets() { return 0; }
  MOCK_DAEMON_RELOAD_FAIL=1
  mv() {
    local source="${*: -2:1}" destination="${!#}"
    if [ ! -e "$injected" ] && [ "$destination" = "$INSTALL_PATH" ] \
      && [[ "$source" != *.backup ]]; then
      command mv "$@" || return 1
      printf '#!/usr/bin/env bash\n# %s\n' "$race_marker" > "$INSTALL_PATH"
      : > "$injected"
      return 0
    fi
    command mv "$@"
  }
  install_self_and_units >/dev/null 2>&1 || install_rc=$?
  [ -e "$injected" ] || fail 'self-path fixture did not replace the promoted program'
  [ "$install_rc" -ne 0 ] || fail 'self-path post-promotion race reported success'
  grep -Fx "# $race_marker" "$INSTALL_PATH" >/dev/null \
    || fail 'self-path rollback deleted the foreign replacement'
  backup="$(find "$(dirname -- "$INSTALL_PATH")" -maxdepth 1 -name '*.backup' -print -quit)"
  [ -n "$backup" ] || fail 'self-path rollback did not retain the old program backup'
  cmp -s "$TEST_ROOT/original-program" "$backup" \
    || fail 'self-path rollback changed the old program backup'
}

if [ "${OCM_INSTALL_SELF_PATH_CASE:-0}" = 1 ]; then
  run_self_path_post_promotion_race
  printf 'self-path post-promotion race test passed\n'
  exit 0
fi

if ! OCM_INSTALL_SELF_PATH_CASE=1 "${BASH}" tests/install.sh; then
  fail 'installed-path program identity guard regressed'
fi

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
MOCK_LOAD_STATE=loaded

# Install preflight must validate systemd's currently loaded source, not only
# the bytes found at /etc/systemd/system.  Every rejection happens before even
# the first staging function is entered; strict not-found remains installable.
seed_legacy_units
for source_unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
  for source_case in external query-fail fragment-query-fail empty-fragment masked empty-load \
    dropin-query-fail dropin-missing dropin-present; do
    preflight_stage_marker="${TEST_ROOT}/preflight-${source_unit}-${source_case}.stage"
    if (
      MOCK_SOURCE_UNIT="$source_unit"
      MOCK_SOURCE_CASE="$source_case"
      stage_managed_program() { : > "$preflight_stage_marker"; return 1; }
      install_self_and_units >/dev/null 2>&1
    ); then
      fail "install accepted $source_case source evidence for $source_unit"
    fi
    [ ! -e "$preflight_stage_marker" ] \
      || fail "install staged files before rejecting $source_case source evidence for $source_unit"
  done
  if ! (
    MOCK_SOURCE_UNIT="$source_unit"
    MOCK_SOURCE_CASE=not-found
    preflight_install_targets >/dev/null 2>&1
  ); then
    fail "install preflight rejected strict not-found for $source_unit"
  fi
done
unset MOCK_SOURCE_UNIT MOCK_SOURCE_CASE
rm -rf -- "$OCM_SYSTEMD_DIR" "$(dirname -- "$OCM_INSTALL_PATH")"
printf 'install source preflight tests passed\n'

# Post-reload verification must bind all three loaded units to the exact
# managed path and validate the full service/timer execution contract.
seed_current_units
for source_unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
  for source_case in external query-fail fragment-query-fail empty-fragment not-found \
    dropin-query-fail dropin-missing dropin-present; do
    if (
      MOCK_SOURCE_UNIT="$source_unit"
      MOCK_SOURCE_CASE="$source_case"
      verify_installed_units >/dev/null 2>&1
    ); then
      fail "post-reload verification accepted $source_case source evidence for $source_unit"
    fi
  done
done
if (MOCK_MAIN_START_ACTION='_service_run --foreign'; verify_installed_units >/dev/null 2>&1); then
  fail 'post-reload verification accepted extra main ExecStart arguments'
fi
if (MOCK_MAIN_STOP_ACTION='_service_cleanup --foreign'; verify_installed_units >/dev/null 2>&1); then
  fail 'post-reload verification accepted extra main ExecStopPost arguments'
fi
if (MOCK_HEALTH_ACTION='_service_health --foreign'; verify_installed_units >/dev/null 2>&1); then
  fail 'post-reload verification accepted extra health ExecStart arguments'
fi
if (MOCK_TIMER_TRIGGERS='foreign-health.service'; verify_installed_units >/dev/null 2>&1); then
  fail 'post-reload verification accepted a foreign timer trigger'
fi
verify_installed_units || fail 'post-reload verification rejected the exact managed contract'

# Current-runtime validation is stricter than legacy ownership: every unit file
# must match the complete generated template, and systemd must prove it has no
# pending daemon-reload for any of the three units.
for drift_unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
  drift_path="$(unit_path "$drift_unit")"
  cp -- "$drift_path" "${drift_path}.exact"
  printf '%s\n' '# unexpected current-unit drift' >> "$drift_path"
  if verify_installed_units >/dev/null 2>&1; then
    fail "post-reload verification accepted byte drift in $drift_unit"
  fi
  mv -f -- "${drift_path}.exact" "$drift_path"
done

timer_path="$(unit_path "$HEALTH_TIMER_NAME")"
while IFS='|' read -r timer_from timer_to timer_label; do
  cp -- "$timer_path" "${timer_path}.exact"
  sed -i "s/^${timer_from}$/${timer_to}/" "$timer_path"
  if verify_installed_units >/dev/null 2>&1; then
    fail "post-reload verification accepted timer contract drift: $timer_label"
  fi
  mv -f -- "${timer_path}.exact" "$timer_path"
done <<EOF
OnBootSec=45s|OnBootSec=46s|OnBootSec
OnUnitInactiveSec=30s|OnUnitInactiveSec=31s|OnUnitInactiveSec
AccuracySec=5s|AccuracySec=6s|AccuracySec
Unit=${HEALTH_SERVICE_NAME}|Unit=foreign-health.service|Unit
WantedBy=timers.target|WantedBy=multi-user.target|WantedBy
EOF

for reload_unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
  for reload_case in query-fail empty yes; do
    if (
      MOCK_NEED_RELOAD_UNIT="$reload_unit"
      MOCK_NEED_RELOAD_CASE="$reload_case"
      verify_installed_units >/dev/null 2>&1
    ); then
      fail "post-reload verification accepted NeedDaemonReload=$reload_case for $reload_unit"
    fi
  done
done
rm -rf -- "$OCM_SYSTEMD_DIR" "$(dirname -- "$OCM_INSTALL_PATH")"
printf 'installed unit source and contract tests passed\n'

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

# A second complete preflight is required after every stage exists.  Races in
# this bounded staging window must preserve the new foreign object byte-for-byte
# and remove only our stages, without backups or daemon-reload.
for staging_race in unit-create unit-replace shortcut-create shortcut-replace; do
  seed_legacy_units
  save_legacy_originals
  MOCK_SOURCE_UNIT=''
  MOCK_SOURCE_CASE=owned
  race_systemctl_mutations="${TEST_ROOT}/${staging_race}.systemctl"
  : > "$race_systemctl_mutations"
  MOCK_SYSTEMCTL_MUTATIONS="$race_systemctl_mutations"
  case "$staging_race" in
    unit-create)
      race_target="$(unit_path "$SERVICE_NAME")"
      rm -f -- "$race_target"
      MOCK_SOURCE_UNIT="$SERVICE_NAME"
      MOCK_SOURCE_CASE=not-found
      ;;
    unit-replace) race_target="$(unit_path "$SERVICE_NAME")" ;;
    shortcut-create) race_target="$OCM_SHORTCUT_PATH" ;;
    shortcut-replace)
      race_target="$OCM_SHORTCUT_PATH"
      mkdir -p -- "$(dirname -- "$race_target")"
      printf '%s\n' 'owned staging shortcut' > "$race_target"
      ;;
  esac
  race_bytes="foreign staging-window ${staging_race}"
  if (
    stage_unit_file() {
      local unit="$1" temporary
      temporary="$(mktemp "${SYSTEMD_DIR}/.${unit}.${TAG}.race.XXXXXX")" || return 1
      write_unit_file "$unit" "$temporary" || return 1
      if [ "$unit" = "$HEALTH_TIMER_NAME" ]; then
        case "$staging_race" in
          unit-create|unit-replace|shortcut-replace) printf '%s\n' "$race_bytes" > "$race_target" ;;
        esac
      fi
      printf '%s\n' "$temporary"
    }
    stage_shortcut() {
      local temporary
      mkdir -p -- "$(dirname -- "$SHORTCUT_PATH")"
      temporary="$(mktemp "$(dirname -- "$SHORTCUT_PATH")/.${TAG}.shortcut.race.XXXXXX")" || return 1
      printf '%s\n' staged-shortcut > "$temporary"
      if [ "$staging_race" = shortcut-create ]; then
        printf '%s\n' "$race_bytes" > "$race_target"
      fi
      printf '%s\n' "$temporary"
    }
    if [ "$staging_race" = shortcut-replace ]; then
      shortcut_is_ours() {
        [ -f "$SHORTCUT_PATH" ] \
          && grep -Fx 'owned staging shortcut' "$SHORTCUT_PATH" >/dev/null
      }
    fi
    install_self_and_units >/dev/null 2>&1
  ); then
    fail "install accepted a foreign $staging_race race after staging"
  fi
  grep -Fx "$race_bytes" "$race_target" >/dev/null \
    || fail "install changed the foreign $staging_race race target"
  cmp -s "$TEST_ROOT/original-program" "$OCM_INSTALL_PATH" \
    || fail "$staging_race race changed the managed program"
  cmp -s "$TEST_ROOT/original-health" "$(unit_path "$HEALTH_SERVICE_NAME")" \
    || fail "$staging_race race changed the health unit"
  cmp -s "$TEST_ROOT/original-timer" "$(unit_path "$HEALTH_TIMER_NAME")" \
    || fail "$staging_race race changed the timer unit"
  [ ! -s "$race_systemctl_mutations" ] || fail "$staging_race race triggered daemon-reload"
  assert_no_transaction_leftovers
  rm -rf -- "$OCM_SYSTEMD_DIR" "$(dirname -- "$OCM_INSTALL_PATH")" "$(dirname -- "$OCM_SHORTCUT_PATH")"
done
unset MOCK_SYSTEMCTL_MUTATIONS MOCK_SOURCE_UNIT MOCK_SOURCE_CASE
printf 'post-staging preflight race tests passed\n'

# A loaded unit whose exact fragment still needs daemon-reload is not safe to
# replace.  Reject it before staging or any systemd mutation.
commit_guard_failures=0
record_commit_guard_failure() {
  printf 'commit guard regression: %s\n' "$*" >&2
  commit_guard_failures=$((commit_guard_failures + 1))
}

for reload_case in yes empty query-fail; do
  seed_legacy_units
  reload_stage_marker="${TEST_ROOT}/reload-needed-install-${reload_case}.stage"
  reload_mutations="${TEST_ROOT}/reload-needed-install-${reload_case}.systemctl"
  : > "$reload_mutations"
  reload_install_rc=0
  (
    MOCK_NEED_RELOAD_UNIT="$SERVICE_NAME"
    MOCK_NEED_RELOAD_CASE="$reload_case"
    MOCK_SYSTEMCTL_MUTATIONS="$reload_mutations"
    stage_managed_program() { : > "$reload_stage_marker"; return 1; }
    install_self_and_units >/dev/null 2>&1
  ) || reload_install_rc=$?
  [ "$reload_install_rc" -ne 0 ] \
    || record_commit_guard_failure "install accepted NeedDaemonReload=$reload_case"
  [ ! -e "$reload_stage_marker" ] \
    || record_commit_guard_failure "install staged before rejecting NeedDaemonReload=$reload_case"
  [ ! -s "$reload_mutations" ] \
    || record_commit_guard_failure "install mutated systemd for NeedDaemonReload=$reload_case"
  rm -rf -- "$OCM_SYSTEMD_DIR" "$(dirname -- "$OCM_INSTALL_PATH")" "$(dirname -- "$OCM_SHORTCUT_PATH")"
done

# If the shortcut becomes managed between the outer decision and
# stage_shortcut's inner recheck, its empty stage means there is no target to
# commit.  It must not enter the transaction or create a relative `.backup`.
seed_legacy_units
empty_shortcut_backup_call="${TEST_ROOT}/empty-shortcut-stage.backup-call"
empty_shortcut_rc=0
(
  cd -- "$TEST_ROOT"
  shortcut_is_ours() {
    if [ -f "$SHORTCUT_PATH" ] \
      && grep -Fx 'managed shortcut appeared during staging' "$SHORTCUT_PATH" >/dev/null; then
      return 0
    fi
    mkdir -p -- "$(dirname -- "$SHORTCUT_PATH")"
    printf '%s\n' 'managed shortcut appeared during staging' > "$SHORTCUT_PATH"
    return 1
  }
  mv() {
    local destination="${!#}"
    [ "$destination" != .backup ] || : > "$empty_shortcut_backup_call"
    command mv "$@"
  }
  install_self_and_units >/dev/null 2>&1
) || empty_shortcut_rc=$?
[ "$empty_shortcut_rc" -eq 0 ] \
  || record_commit_guard_failure 'empty shortcut stage entered the transaction'
[ ! -e "$empty_shortcut_backup_call" ] \
  || record_commit_guard_failure 'empty shortcut stage formed a relative .backup'
grep -Fx 'managed shortcut appeared during staging' "$OCM_SHORTCUT_PATH" >/dev/null \
  || record_commit_guard_failure 'managed shortcut changed after an empty stage'
rm -rf -- "$OCM_SYSTEMD_DIR" "$(dirname -- "$OCM_INSTALL_PATH")" "$(dirname -- "$OCM_SHORTCUT_PATH")"

# A snapshot that fails after creating earlier old/new references must remove
# every reference and stage without changing any target.
seed_legacy_units
save_legacy_originals
snapshot_failure_rc=0
(
  shortcut_is_ours() { return 0; }
  preflight_install_targets() { return 0; }
  snapshot_copy_count=0
  cp() {
    local destination="${!#}"
    if [[ "$destination" == *.expected ]]; then
      snapshot_copy_count=$((snapshot_copy_count + 1))
      [ "$snapshot_copy_count" -ne 3 ] || return 1
    fi
    command cp "$@"
  }
  install_self_and_units >/dev/null 2>&1
) || snapshot_failure_rc=$?
[ "$snapshot_failure_rc" -ne 0 ] \
  || record_commit_guard_failure 'mid-snapshot copy failure reported success'
assert_legacy_restored
rm -rf -- "$OCM_SYSTEMD_DIR" "$(dirname -- "$OCM_INSTALL_PATH")" "$(dirname -- "$OCM_SHORTCUT_PATH")"

# Commit-race assertions use the first target (program) and the last target
# when no shortcut stage is needed (health timer), so both loop boundaries are
# covered without relying on POSIX symlink support.
assert_non_raced_targets_restored() {
  local label="$1" raced_target="$2" unit target original
  if [ "$raced_target" != "$INSTALL_PATH" ] \
    && ! cmp -s "$TEST_ROOT/original-program" "$INSTALL_PATH"; then
    record_commit_guard_failure "$label did not restore the non-raced program"
  fi
  for unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
    target="$(unit_path "$unit")"
    [ "$raced_target" != "$target" ] || continue
    case "$unit" in
      "$SERVICE_NAME") original="$TEST_ROOT/original-main" ;;
      "$HEALTH_SERVICE_NAME") original="$TEST_ROOT/original-health" ;;
      "$HEALTH_TIMER_NAME") original="$TEST_ROOT/original-timer" ;;
    esac
    cmp -s "$original" "$target" \
      || record_commit_guard_failure "$label did not restore non-raced $unit"
  done
}

assert_race_backup_retained() {
  local label="$1" target="$2" original="$3" retain_references="${4:-1}"
  local backup stage old_reference new_reference
  backup="$(find "$(dirname -- "$target")" -maxdepth 1 -name '*.backup' -print -quit)"
  if [ -z "$backup" ]; then
    record_commit_guard_failure "$label did not retain the old managed backup"
    return
  fi
  cmp -s "$original" "$backup" \
    || record_commit_guard_failure "$label changed the old managed backup"
  stage="${backup%.backup}"
  old_reference="${stage}.expected"
  new_reference="${stage}.new-expected"
  [ "$retain_references" = 1 ] || return 0
  [ -f "$old_reference" ] \
    || record_commit_guard_failure "$label did not retain the old target reference"
  [ -f "$new_reference" ] \
    || record_commit_guard_failure "$label did not retain the staged-new reference"
  if [ -f "$new_reference" ] && cmp -s "$target" "$new_reference"; then
    record_commit_guard_failure "$label foreign target matched the staged-new reference"
  fi
}

assert_no_race_leftovers() {
  local label="$1"
  if find "$TEST_ROOT" \( -name '*.backup' -o -name '.*.oc-master.*' \) -print -quit | grep -q .; then
    record_commit_guard_failure "$label left a transaction file"
  fi
}

write_foreign_commit_target() {
  local target="$1" marker="$2"

  if [ "$target" = "$INSTALL_PATH" ]; then
    printf '#!/usr/bin/env bash\n# %s\n' "$marker" > "$target"
  else
    printf '%s\n' "$marker" > "$target"
  fi
}

assert_foreign_commit_target() {
  local label="$1" target="$2" marker="$3" expected
  expected="$marker"

  [ "$target" != "$INSTALL_PATH" ] || expected="# $marker"
  grep -Fx "$expected" "$target" >/dev/null \
    || record_commit_guard_failure "$label overwrote foreign bytes"
}

run_commit_race_case() {
  local window="$1" race_position="$2" race_target race_original shape label race_marker race_injected install_rc=0

  seed_legacy_units
  save_legacy_originals
  case "$race_position" in
    first)
      race_target="$INSTALL_PATH"
      race_original="$TEST_ROOT/original-program"
      ;;
    last)
      race_target="$(unit_path "$HEALTH_TIMER_NAME")"
      race_original="$TEST_ROOT/original-timer"
      ;;
    *) return 1 ;;
  esac
  case "$window" in
    post-preflight)
      shape=replace
      if [ "$race_position" = last ]; then
        shape=create
        rm -f -- "$race_target"
      fi
      label="post-preflight-${race_position}-${shape}"
      race_marker="foreign ${label}"
      (
        shortcut_is_ours() { return 0; }
        install_preflight_calls=0
        preflight_install_targets() {
          install_preflight_calls=$((install_preflight_calls + 1))
          if [ "$install_preflight_calls" -eq 2 ]; then
            write_foreign_commit_target "$race_target" "$race_marker"
          fi
          return 0
        }
        install_self_and_units >/dev/null 2>&1
      ) || install_rc=$?
      ;;
    post-backup-move|pre-promotion|post-promotion)
      label="${window}-${race_position}"
      race_marker="foreign ${label}"
      race_injected="${TEST_ROOT}/${label}.injected"
      [ "$window" != pre-promotion ] || rm -f -- "$race_target"
      (
        shortcut_is_ours() { return 0; }
        preflight_install_targets() { return 0; }
        if [ "$window" = post-promotion ]; then
          MOCK_DAEMON_RELOAD_FAIL=1
        fi
        mv() {
          local source="${*: -2:1}" destination="${!#}"
          if [ ! -e "$race_injected" ] && [ "$window" = post-backup-move ] \
            && [ "$source" = "$race_target" ] && [[ "$destination" == *.backup ]]; then
            command mv "$@" || return 1
            write_foreign_commit_target "$race_target" "$race_marker"
            : > "$race_injected"
            return 0
          fi
          if [ ! -e "$race_injected" ] && [ "$destination" = "$race_target" ] \
            && [[ "$source" != *.backup ]]; then
            if [ "$window" = post-promotion ]; then
              command mv "$@" || return 1
            fi
            write_foreign_commit_target "$race_target" "$race_marker"
            : > "$race_injected"
            [ "$window" != post-promotion ] || return 0
          fi
          command mv "$@"
        }
        install_self_and_units >/dev/null 2>&1
      ) || install_rc=$?
      [ -e "$race_injected" ] \
        || record_commit_guard_failure "$label fixture did not reach its commit window"
      ;;
    *) return 1 ;;
  esac

  [ "$install_rc" -ne 0 ] || record_commit_guard_failure "$label reported success"
  assert_foreign_commit_target "$label" "$race_target" "$race_marker"
  case "$window" in
    # A target that reappears before the post-move disappearance check cannot
    # arm rollback.  Its safe backup remains, but its references are not
    # recovery evidence for a confirmed migration.
    post-backup-move) assert_race_backup_retained "$label" "$race_target" "$race_original" 0 ;;
    post-promotion) assert_race_backup_retained "$label" "$race_target" "$race_original" ;;
    post-preflight|pre-promotion) assert_no_race_leftovers "$label" ;;
  esac
  assert_non_raced_targets_restored "$label" "$race_target"
  rm -rf -- "$OCM_SYSTEMD_DIR" "$(dirname -- "$OCM_INSTALL_PATH")" "$(dirname -- "$OCM_SHORTCUT_PATH")"
}

# Cross the four commit windows with both loop boundaries.  This preserves the
# create/replace, no-clobber, source-disappearance and rollback ownership checks
# while keeping the race injector identical across positions.
for race_window in post-preflight post-backup-move pre-promotion post-promotion; do
  for race_position in first last; do
    run_commit_race_case "$race_window" "$race_position"
  done
done

# Once a managed target has moved to its backup, that backup is evidence rather
# than an interchangeable replacement.  A byte change before verification must
# not put it back at the target or discard either transaction reference.
run_untrusted_backup_case() {
  local race_position="$1" race_target label race_marker backup_marker backup stage old_reference new_reference
  local race_injected install_rc=0

  seed_legacy_units
  save_legacy_originals
  case "$race_position" in
    first) race_target="$INSTALL_PATH" ;;
    last) race_target="$(unit_path "$HEALTH_TIMER_NAME")" ;;
    *) return 1 ;;
  esac
  label="untrusted-backup-${race_position}"
  race_marker="tampered ${label}"
  [ "$race_target" = "$INSTALL_PATH" ] && backup_marker="# $race_marker" || backup_marker="$race_marker"
  race_injected="${TEST_ROOT}/${label}.injected"
  (
    shortcut_is_ours() { return 0; }
    preflight_install_targets() { return 0; }
    mv() {
      local source="${*: -2:1}" destination="${!#}"
      if [ ! -e "$race_injected" ] && [ "$source" = "$race_target" ] \
        && [[ "$destination" == *.backup ]]; then
        command mv "$@" || return 1
        printf '%s\n' "$backup_marker" >> "$destination"
        : > "$race_injected"
        return 0
      fi
      command mv "$@"
    }
    install_self_and_units >/dev/null 2>&1
  ) || install_rc=$?

  [ -e "$race_injected" ] \
    || record_commit_guard_failure "$label fixture did not tamper after the backup move"
  [ "$install_rc" -ne 0 ] \
    || record_commit_guard_failure "$label reported success"
  [ ! -e "$race_target" ] && [ ! -L "$race_target" ] \
    || record_commit_guard_failure "$label restored the untrusted backup to the target"
  backup="$(find "$(dirname -- "$race_target")" -maxdepth 1 -name '*.backup' -print -quit)"
  if [ -z "$backup" ]; then
    record_commit_guard_failure "$label did not retain the untrusted backup"
  else
    grep -Fx "$backup_marker" "$backup" >/dev/null \
      || record_commit_guard_failure "$label did not retain the tampered backup bytes"
    stage="${backup%.backup}"
    old_reference="${stage}.expected"
    new_reference="${stage}.new-expected"
    [ -f "$old_reference" ] \
      || record_commit_guard_failure "$label did not retain the old target reference"
    [ -f "$new_reference" ] \
      || record_commit_guard_failure "$label did not retain the staged-new reference"
  fi
  assert_non_raced_targets_restored "$label" "$race_target"
  rm -rf -- "$OCM_SYSTEMD_DIR" "$(dirname -- "$OCM_INSTALL_PATH")" "$(dirname -- "$OCM_SHORTCUT_PATH")"
}

for race_position in first last; do
  run_untrusted_backup_case "$race_position"
done

[ "$commit_guard_failures" -eq 0 ] \
  || fail "$commit_guard_failures install commit guard regression(s) detected"
printf 'install commit guard tests passed\n'

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

# After the public install has verified its promoted program, a backup cleanup
# failure must retain that verified program and its evidence.  Re-entering the
# rollback path here could turn a cleanup error into a partial restoration.
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
cmp -s "$SCRIPT_PATH" "$OCM_INSTALL_PATH" || fail 'managed-copy backup cleanup failure rolled back the verified program'
find "$(dirname -- "$OCM_INSTALL_PATH")" -name '*.backup' -print -quit | grep -q . \
  || fail 'managed-copy backup cleanup failure discarded the old-program backup'
find "$(dirname -- "$OCM_INSTALL_PATH")" -name '*.expected' -print -quit | grep -q . \
  || fail 'managed-copy backup cleanup failure discarded its target snapshot'
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

# Public `install` promotes only program/shortcut, but it must keep the same
# no-clobber contract as the persistent-unit installer. These hooks model the
# three observable commit windows without installing any unit.
run_public_install_commit_guard() {
  local window="$1" backup install_rc=0
  local marker="foreign-public-${window}"

  rm -rf -- "$(dirname -- "$OCM_INSTALL_PATH")" "$(dirname -- "$OCM_SHORTCUT_PATH")"
  mkdir -p -- "$(dirname -- "$OCM_INSTALL_PATH")"
  printf '#!/usr/bin/env bash\nprintf old-public\n' > "$OCM_INSTALL_PATH"
  (
    stage_shortcut() { return 0; }
    mv() {
      local source="${*: -2:1}" destination="${!#}"
      if [ "$source" = "$OCM_INSTALL_PATH" ] && [[ "$destination" == *.backup ]]; then
        command mv "$@" || return 1
        if [ "$window" = untrusted-backup ]; then
          printf '%s\n' "$marker" >> "$destination"
        elif [ "$window" = pre-promotion ]; then
          printf '%s\n' "$marker" > "$OCM_INSTALL_PATH"
        fi
        return 0
      fi
      if [ "$destination" = "$OCM_INSTALL_PATH" ] && [ "$window" = post-promotion ]; then
        command mv "$@" || return 1
        printf '%s\n' "$marker" > "$OCM_INSTALL_PATH"
        return 0
      fi
      command mv "$@"
    }
    install_managed_copy
  ) || install_rc=$?
  [ "$install_rc" -ne 0 ] || fail "public install accepted ${window} transaction drift"
  case "$window" in
    pre-promotion|post-promotion)
      grep -Fx "$marker" "$OCM_INSTALL_PATH" >/dev/null \
        || fail "public install overwrote foreign program during ${window}"
      ;;
    untrusted-backup)
      [ ! -e "$OCM_INSTALL_PATH" ] || fail 'public install restored an untrusted program backup'
      backup="$(find "$(dirname -- "$OCM_INSTALL_PATH")" -name '*.backup' -print -quit)"
      [ -n "$backup" ] && grep -Fx "$marker" "$backup" >/dev/null \
        || fail 'public install discarded untrusted program backup evidence'
      ;;
  esac
}

for public_install_window in pre-promotion post-promotion untrusted-backup; do
  run_public_install_commit_guard "$public_install_window"
done
printf 'public install commit guard tests passed\n'

# Public install is intentionally program/shortcut-only: it must not create
# runtime/config state or call daemon-reload, including on a rollback path.
rm -rf -- "$OCM_CONFIG_DIR" "$OCM_RUNTIME_DIR" "$(dirname -- "$OCM_INSTALL_PATH")"
mkdir -p -- "$(dirname -- "$OCM_INSTALL_PATH")"
if ! (
  stage_shortcut() { return 0; }
  ensure_dirs() { : > "$TEST_ROOT/public-install.ensure-dirs"; return 1; }
  systemctl() { : > "$TEST_ROOT/public-install.systemctl"; return 1; }
  install_managed_copy
); then
  fail 'public install unexpectedly required manager runtime directories'
fi
[ ! -e "$TEST_ROOT/public-install.ensure-dirs" ] || fail 'public install created manager runtime/config state'
[ ! -e "$TEST_ROOT/public-install.systemctl" ] || fail 'public install invoked systemctl on its success path'
[ ! -e "$OCM_CONFIG_DIR" ] && [ ! -e "$OCM_RUNTIME_DIR" ] \
  || fail 'public install created a config or runtime directory'
rm -rf -- "$(dirname -- "$OCM_INSTALL_PATH")"

mkdir -p -- "$(dirname -- "$OCM_INSTALL_PATH")"
printf '#!/usr/bin/env bash\nprintf old-public\n' > "$OCM_INSTALL_PATH"
if (
  stage_shortcut() { return 0; }
  systemctl() { : > "$TEST_ROOT/public-install-rollback.systemctl"; return 1; }
  mv() {
    local source="${*: -2:1}" destination="${!#}"
    if [ "$destination" = "$OCM_INSTALL_PATH" ] && [[ "$source" != *.backup ]]; then
      return 1
    fi
    command mv "$@"
  }
  install_managed_copy
); then
  fail 'public install accepted a forced promotion failure'
fi
[ ! -e "$TEST_ROOT/public-install-rollback.systemctl" ] \
  || fail 'public install rollback invoked daemon-reload without unit changes'
grep -F 'old-public' "$OCM_INSTALL_PATH" >/dev/null \
  || fail 'public install rollback did not preserve the old program'
rm -rf -- "$(dirname -- "$OCM_INSTALL_PATH")"
printf 'public install boundary-effect tests passed\n'

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
  # The optional shortcut has the same no-clobber contract as the program.
  # Cover both an absent target becoming occupied before promotion and a
  # foreign replacement immediately after the shortcut promotion.
  run_public_shortcut_commit_guard() {
    local window="$1" install_rc=0
    local marker="foreign-shortcut-${window}"

    rm -rf -- "$(dirname -- "$OCM_INSTALL_PATH")" "$(dirname -- "$OCM_SHORTCUT_PATH")"
    mkdir -p -- "$(dirname -- "$OCM_INSTALL_PATH")"
    printf '#!/usr/bin/env bash\nprintf old-public\n' > "$OCM_INSTALL_PATH"
    (
      mv() {
        local source="${*: -2:1}" destination="${!#}"
        if [ "$destination" = "$OCM_INSTALL_PATH" ] && [ "$source" != "$OCM_INSTALL_PATH" ]; then
          command mv "$@" || return 1
          if [ "$window" = pre-promotion ]; then
            printf '%s\n' "$marker" > "$OCM_SHORTCUT_PATH"
          fi
          return 0
        fi
        if [ "$destination" = "$OCM_SHORTCUT_PATH" ] && [ "$window" = post-promotion ]; then
          command mv "$@" || return 1
          command rm -f -- "$OCM_SHORTCUT_PATH"
          printf '%s\n' "$marker" > "$OCM_SHORTCUT_PATH"
          return 0
        fi
        command mv "$@"
      }
      install_managed_copy
    ) || install_rc=$?
    [ "$install_rc" -ne 0 ] || fail "public install accepted shortcut ${window} drift"
    grep -Fx "$marker" "$OCM_SHORTCUT_PATH" >/dev/null \
      || fail "public install overwrote foreign shortcut during ${window}"
    grep -F 'old-public' "$OCM_INSTALL_PATH" >/dev/null \
      || fail "public install did not restore the program after shortcut ${window} drift"
  }

  for public_shortcut_window in pre-promotion post-promotion; do
    run_public_shortcut_commit_guard "$public_shortcut_window"
  done
  printf 'public shortcut commit guard tests passed\n'

  failure=managed-shortcut
    rm -rf -- "$(dirname -- "$OCM_INSTALL_PATH")" "$(dirname -- "$OCM_SHORTCUT_PATH")"
    mkdir -p -- "$(dirname -- "$OCM_INSTALL_PATH")"
    printf '#!/usr/bin/env bash\nprintf old-managed-program\\n' > "$OCM_INSTALL_PATH"
    cp -- "$OCM_INSTALL_PATH" "$TEST_ROOT/original-managed-program"
    MOCK_MANAGED_PROGRAM_MOVES=0
    MOCK_MANAGED_SHORTCUT_MOVES=0
    mv() {
      local destination="${!#}"
      if [ "$destination" = "$OCM_INSTALL_PATH" ]; then
        MOCK_MANAGED_PROGRAM_MOVES=$((MOCK_MANAGED_PROGRAM_MOVES + 1))
      fi
      if [ "$destination" = "$OCM_SHORTCUT_PATH" ]; then
        MOCK_MANAGED_SHORTCUT_MOVES=$((MOCK_MANAGED_SHORTCUT_MOVES + 1))
      fi
      if [ "$failure" = managed-program ] && [ "$destination" = "$OCM_INSTALL_PATH" ] && [ "$MOCK_MANAGED_PROGRAM_MOVES" -eq 1 ]; then return 1; fi
      if [ "$failure" = managed-shortcut ] && [ "$destination" = "$OCM_SHORTCUT_PATH" ]; then return 1; fi
      command mv "$@"
    }
    if install_managed_copy >"$TEST_ROOT/${failure}.out" 2>&1; then
      fail "install_managed_copy unexpectedly succeeded after $failure failure"
    fi
    unset -f mv
    [ "$MOCK_MANAGED_SHORTCUT_MOVES" -eq 1 ] \
      || fail 'install_managed_copy managed-shortcut fixture did not reach shortcut promotion'
    cmp -s "$TEST_ROOT/original-managed-program" "$OCM_INSTALL_PATH" || fail "install_managed_copy did not restore old program after $failure failure"
    [ ! -e "$OCM_SHORTCUT_PATH" ] && [ ! -L "$OCM_SHORTCUT_PATH" ] || fail "install_managed_copy left shortcut after $failure failure"
    assert_no_transaction_leftovers
    rm -rf -- "$(dirname -- "$OCM_INSTALL_PATH")" "$(dirname -- "$OCM_SHORTCUT_PATH")"
  printf 'managed-copy shortcut commit rollback test passed\n'

  # When removing a promoted shortcut fails during rollback, retain it as
  # evidence and report the rollback failure instead of claiming success.
  mkdir -p -- "$(dirname -- "$OCM_INSTALL_PATH")" "$(dirname -- "$OCM_SHORTCUT_PATH")"
  printf '#!/usr/bin/env bash\nprintf old-managed-program\\n' > "$OCM_INSTALL_PATH"
  shortcut_remove_marker="$TEST_ROOT/managed-shortcut-restore-failure.injected"
  if (
    verify_installed_transaction_targets() { return 1; }
    rm() {
      local target="${!#}"
      if [ "$target" = "$OCM_SHORTCUT_PATH" ] && [ ! -e "$shortcut_remove_marker" ]; then
        : > "$shortcut_remove_marker"
        return 1
      fi
      command rm "$@"
    }
    install_managed_copy
  ) >"$TEST_ROOT/managed-shortcut-restore-failure.out" 2>&1; then
    fail 'install_managed_copy succeeded although shortcut restoration failed'
  fi
  [ -e "$shortcut_remove_marker" ] \
    || fail 'shortcut restoration failure fixture did not reach rollback removal'
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
  failed_backup_stage="${failed_backup_path%.backup}"
  [ -f "${failed_backup_stage}.expected" ] \
    || fail "$backup_failure_case cleanup failure discarded the old target reference"
  [ -f "${failed_backup_stage}.new-expected" ] \
    || fail "$backup_failure_case cleanup failure discarded the staged-new reference"
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
  grep -F '保留本轮目标快照作为核验依据' "$backup_cleanup_output" >/dev/null \
    || fail "$backup_failure_case cleanup failure lacked retained-reference diagnostic"
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
postcondition_backup="$(find "$TEST_ROOT" -name '*.backup' -type f -print -quit)"
[ -f "${postcondition_backup%.backup}.expected" ] \
  || fail 'backup postcondition failure discarded the old target reference'
[ -f "${postcondition_backup%.backup}.new-expected" ] \
  || fail 'backup postcondition failure discarded the staged-new reference'
grep -F '安装已提交并验证，但备份清理未完成' "$backup_postcondition_output" >/dev/null \
  || fail 'backup postcondition failure lacked committed-state diagnostic'
grep -F '保留本轮目标快照作为核验依据' "$backup_postcondition_output" >/dev/null \
  || fail 'backup postcondition failure lacked retained-reference diagnostic'
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
