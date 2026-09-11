#!/usr/bin/env bash
set -Eeuo pipefail

PATH="/usr/bin:/bin:${PATH}"
export PATH

cd -- "${BASH_SOURCE[0]%/*}/.."

# shellcheck source=tests/testlib.sh
source tests/testlib.sh

TEST_ROOT="$(new_test_root)"
trap 'cleanup_test_root "$TEST_ROOT"' EXIT
export_test_paths "$TEST_ROOT"
mkdir -p -- "$OCM_CONFIG_DIR" "$OCM_RUNTIME_DIR" "${OCM_STATE_LOCK_FILE%/*}" "${OCM_BOOT_ID_FILE%/*}"

readonly SNAPSHOT_RUN_ID='123e4567-e89b-42d3-a456-426614174010'
readonly MIGRATION_RUN_ID='123e4567-e89b-42d3-a456-426614174011'
readonly FAILURE_RUN_ID='123e4567-e89b-42d3-a456-426614174012'
readonly SNAPSHOT_BOOT_ID='123e4567-e89b-42d3-a456-426614174013'
readonly ACCOUNT_A='Account A|alice|alpha-secret|vpn-a.example.test|group-a|nc'
readonly ACCOUNT_B='Account B|bob|beta-secret|vpn-b.example.test|group-b|nc'
readonly LEGACY_ACCOUNT='Legacy account|carol|legacy-secret|vpn-legacy.example.test|legacy-group'

printf '%s\n' "$SNAPSHOT_RUN_ID" > "$OCM_UUID_FILE"
printf '%s\n' "$SNAPSHOT_BOOT_ID" > "$OCM_BOOT_ID_FILE"

# shellcheck source=../oc_master.sh
source oc_master.sh

# Git Bash cannot chown already-created directories to numeric root, while the
# snapshot/account writers themselves still exercise the real atomic file path.
ensure_dirs() {
  mkdir -p -- "$CONFIG_DIR" "$RUNTIME_DIR"
}

assert_runtime_is_b() {
  assert_eq 'Account B' "$VPN_DESC" 'runtime account description drifted from snapshot'
  assert_eq bob "$VPN_USER" 'runtime username drifted from snapshot'
  assert_eq beta-secret "$VPN_PASS" 'runtime password drifted from snapshot'
  assert_eq vpn-b.example.test "$VPN_HOST" 'runtime host drifted from snapshot'
  assert_eq group-b "$VPN_GROUP" 'runtime auth group drifted from snapshot'
  assert_eq nc "$PROFILE_PROTOCOL" 'runtime protocol drifted from snapshot'
  assert_eq 1080 "$PROFILE_SOCKS_PORT" 'runtime SOCKS port drifted from snapshot'
}

write_accounts_fixture() {
  printf '%s\n' \
    '# fixture header' \
    "$ACCOUNT_A" \
    '' \
    '# keep this comment' \
    "$ACCOUNT_B" > "$ACCOUNTS_FILE"
  chmod 0600 "$ACCOUNTS_FILE"
}

load_file_exact() {
  FILE_CONTENT="$(cat -- "$1"; printf '\001')"
  FILE_CONTENT="${FILE_CONTENT%$'\001'}"
}

write_mismatched_active_run() {
  local run_id="$1" boot_id="$2" mode="$3" account_index="$4"
  local protocol="$5" socks_port="$6" account_record="$7"

  case "$MISMATCH_FIELD" in
    CREATED_BOOT_ID) boot_id="$SNAPSHOT_RUN_ID" ;;
    MODE) mode=global; socks_port="" ;;
    ACCOUNT_INDEX) account_index=0 ;;
    VPN_PROTOCOL) protocol=anyconnect ;;
    SOCKS_PORT) socks_port=1081 ;;
    ACCOUNT_RECORD) account_record="$ACCOUNT_A" ;;
    *) return 1 ;;
  esac
  printf '%s\n' \
    'FORMAT_VERSION=1' \
    "RUN_ID=$run_id" \
    "CREATED_BOOT_ID=$boot_id" \
    "MODE=$mode" \
    "ACCOUNT_INDEX=$account_index" \
    "VPN_PROTOCOL=$protocol" \
    "SOCKS_PORT=$socks_port" \
    "ACCOUNT_RECORD=$account_record" \
    | atomic_replace_from_stdin "$ACTIVE_RUN_FILE" 0600
}

write_mismatched_run_state() {
  local run_id="$1" phase="$2" desired_active="$3" rollback_deadline="$4"

  case "$MISMATCH_FIELD" in
    PHASE) phase=STARTING ;;
    DESIRED_ACTIVE) desired_active=0 ;;
    ROLLBACK_DEADLINE) rollback_deadline=1 ;;
    *) return 1 ;;
  esac
  printf '%s\n' \
    'FORMAT_VERSION=1' \
    "RUN_ID=$run_id" \
    "PHASE=$phase" \
    "DESIRED_ACTIVE=$desired_active" \
    "ROLLBACK_DEADLINE=$rollback_deadline" \
    | atomic_replace_from_stdin "$RUN_STATE_FILE" 0600
}

# Break caught: rejecting the historical five-field account format prevents a
# selected protocol from being committed into an otherwise valid run snapshot.
LEGACY_STDOUT="${TEST_ROOT}/legacy-snapshot.stdout"
LEGACY_STDERR="${TEST_ROOT}/legacy-snapshot.stderr"
if ! create_run_snapshot proxy 0 pulse 1081 "$LEGACY_ACCOUNT" \
  >"$LEGACY_STDOUT" 2>"$LEGACY_STDERR"; then
  fail 'legacy five-field account could not create a run snapshot'
fi
load_runtime_configuration 2>>"$LEGACY_STDERR" \
  || fail 'legacy five-field account snapshot could not be loaded'
assert_eq "$LEGACY_ACCOUNT" "$ACCOUNT_RECORD" 'legacy account record was not preserved byte-for-byte'
assert_eq pulse "$PROFILE_PROTOCOL" 'selected protocol was not preserved for a legacy account'
if grep -F 'legacy-secret' "$LEGACY_STDOUT" "$LEGACY_STDERR" >/dev/null 2>&1; then
  fail 'legacy account password was exposed in snapshot diagnostics'
fi
rm -f -- "$ACTIVE_RUN_FILE" "$RUN_STATE_FILE" "$PROFILE_FILE"

valid_account_record 'Old|user|secret|vpn.example.test|group' \
  || fail 'valid five-field account was rejected'
valid_account_record 'Old no group|user|secret|vpn.example.test|' \
  || fail 'valid five-field account with an empty auth group was rejected'
valid_account_record 'New|user|secret|vpn.example.test|group|nc' \
  || fail 'valid six-field account was rejected'
for invalid_account in \
  'Too few|user|secret|vpn.example.test' \
  'Too many|user|secret|vpn.example.test|group|nc|extra' \
  '|user|secret|vpn.example.test|group' \
  'Missing user||secret|vpn.example.test|group' \
  'Missing password|user||vpn.example.test|group' \
  'Missing host|user|secret||group' \
  'Option host|user|secret|-unsafe.example.test|group' \
  'Bad protocol|user|secret|vpn.example.test|group|invalid' \
  $'Embedded newline|user|secret|vpn.example.test|group\nsecond-line'; do
  if valid_account_record "$invalid_account"; then
    fail 'invalid account record was accepted'
  fi
done

reset_uncommitted_state_fixture() {
  rm -rf -- "$CONFIG_DIR" "$RUNTIME_DIR"
  mkdir -p -- "$CONFIG_DIR" "$RUNTIME_DIR"
  printf '%s\n' "$LEGACY_ACCOUNT" > "$ACCOUNTS_FILE"
  write_profile proxy 0 pulse 1081
  write_run_state "$FAILURE_RUN_ID" PREPARING 1 0
  RECOVERY_ACTIVE_UNIT=""
  RECOVERY_FAILED_UNIT="$HEALTH_SERVICE_NAME"
  RECOVERY_UNKNOWN_UNIT=""
  RECOVERY_MUTATIONS="${TEST_ROOT}/recovery.mutations"
  : > "$RECOVERY_MUTATIONS"
}

install_recovery_doubles() {
  RECOVERY_SERVICE_LOCK_HELD=0
  RECOVERY_STATE_LOCK_HELD=0
  check_root() { :; }
  acquire_service_operation_lock() {
    [ "$#" -eq 1 ] || return 1
    RECOVERY_SERVICE_LOCK_HELD=1
    # shellcheck disable=SC2034 # production lock guard consumes this sourced variable.
    SERVICE_OPERATION_LOCK_FD=901
  }
  release_service_operation_lock() {
    RECOVERY_SERVICE_LOCK_HELD=0
    unset SERVICE_OPERATION_LOCK_FD
  }
  acquire_state_lock() {
    [ "$RECOVERY_SERVICE_LOCK_HELD" -eq 1 ] \
      || fail 'state-only recovery acquired the state lock outside the service-operation lock'
    [ "$RECOVERY_STATE_LOCK_HELD" -eq 0 ] || return 1
    RECOVERY_STATE_LOCK_HELD=1
  }
  release_state_lock() {
    RECOVERY_STATE_LOCK_HELD=0
    unset STATE_LOCK_FD
  }
  systemctl() {
    [ "$RECOVERY_STATE_LOCK_HELD" -eq 0 ] \
      || fail 'state-only recovery queried systemd while holding the state lock'
    if [ "${1:-}" = is-active ]; then
      if [ "${2:-}" = "$RECOVERY_ACTIVE_UNIT" ]; then
        printf '%s\n' active
        return 0
      fi
      if [ "${2:-}" = "$RECOVERY_UNKNOWN_UNIT" ]; then return 1; fi
      if [ "${2:-}" = "$RECOVERY_FAILED_UNIT" ]; then
        printf '%s\n' failed
        return 3
      fi
      printf '%s\n' inactive
      return 3
    fi
    printf 'systemctl %s\n' "$*" >> "$RECOVERY_MUTATIONS"
  }
  ip() { printf 'ip %s\n' "$*" >> "$RECOVERY_MUTATIONS"; return 1; }
}

prepare_with_service_lock() {
  local rc=0
  acquire_service_operation_lock wait || return 1
  prepare_runtime_configuration_for_start || rc=$?
  release_service_operation_lock
  return "$rc"
}

assert_prepare_recovery_rejected() {
  local label="$1" output="${TEST_ROOT}/recovery-rejected.out"
  local account_sum profile_sum
  account_sum="$(cksum < "$ACCOUNTS_FILE")"
  profile_sum="$(cksum < "$PROFILE_FILE")"
  : > "$output"
  if prepare_with_service_lock >"$output" 2>&1; then
    fail "$label was accepted for state-only recovery"
  fi
  { [ -e "$RUN_STATE_FILE" ] || [ -L "$RUN_STATE_FILE" ]; } \
    || fail "$label rejection removed run-state evidence"
  assert_eq "$account_sum" "$(cksum < "$ACCOUNTS_FILE")" "$label rejection changed the account file"
  assert_eq "$profile_sum" "$(cksum < "$PROFILE_FILE")" "$label rejection changed the profile"
  [ ! -s "$RECOVERY_MUTATIONS" ] || fail "$label rejection mutated systemd or networking"
  if grep -F 'legacy-secret' "$output" >/dev/null 2>&1; then
    fail "$label rejection exposed the account password"
  fi
}

assert_stop_recovery_rejected() {
  local label="$1" output="${TEST_ROOT}/stop-recovery-rejected.out"
  : > "$output"
  if stop_vpn >"$output" 2>&1; then fail "$label was accepted by manual stop recovery"; fi
  { [ -e "$RUN_STATE_FILE" ] || [ -L "$RUN_STATE_FILE" ]; } \
    || fail "$label stop rejection removed run-state evidence"
  [ -f "$PROFILE_FILE" ] || fail "$label stop rejection removed the profile"
  grep -Fx "$LEGACY_ACCOUNT" "$ACCOUNTS_FILE" >/dev/null \
    || fail "$label stop rejection changed the account file"
  [ ! -s "$RECOVERY_MUTATIONS" ] || fail "$label stop rejection mutated systemd or networking"
  if grep -F 'legacy-secret' "$output" >/dev/null 2>&1; then
    fail "$label stop rejection exposed the account password"
  fi
}

# Break caught: an active-run rename failure leaves a safe PREPARING state-only
# transaction that the next manager start must discard while holding both locks.
(
  reset_uncommitted_state_fixture
  install_recovery_doubles
  RECOVERY_STDERR="${TEST_ROOT}/recovery-success.stderr"
  prepare_with_service_lock >/dev/null 2>"$RECOVERY_STDERR" \
    || fail 'safe PREPARING state-only transaction was not recovered for the next start'
  [ ! -s "$RECOVERY_STDERR" ] \
    || fail 'successful state-only recovery emitted a misleading load failure'
  [ ! -e "$RUN_STATE_FILE" ] && [ ! -L "$RUN_STATE_FILE" ] \
    || fail 'recovered PREPARING state-only evidence was not removed'
  [ -f "$PROFILE_FILE" ] || fail 'state-only recovery removed the compatibility profile'
  grep -Fx "$LEGACY_ACCOUNT" "$ACCOUNTS_FILE" >/dev/null \
    || fail 'state-only recovery changed the account file'
  [ ! -s "$RECOVERY_MUTATIONS" ] || fail 'safe state-only recovery mutated systemd or networking'
)

# Network evidence means the transaction is no longer provably pre-network.
(
  reset_uncommitted_state_fixture
  install_recovery_doubles
  printf '%s\n' evidence > "$ROUTE_PLAN_FILE"
  if prepare_with_service_lock >/dev/null 2>&1; then
    fail 'state-only recovery accepted route-plan evidence'
  fi
  [ -f "$RUN_STATE_FILE" ] && [ -f "$ROUTE_PLAN_FILE" ] \
    || fail 'rejected route-evidence recovery removed evidence'
  [ ! -s "$RECOVERY_MUTATIONS" ] || fail 'route-evidence rejection mutated systemd or networking'
)

# Every route/worker/health artifact makes state-only deletion unsafe, even if
# all persistent units currently look quiescent.
for recovery_evidence in \
  "$ROUTE_OWNER_FILE" "$SERVICE_RUN_ID_FILE" "$HEALTH_FAILURE_FILE" "$HEALTH_RESTART_FILE"; do
  (
    reset_uncommitted_state_fixture
    install_recovery_doubles
    printf '%s\n' evidence > "$recovery_evidence"
    if prepare_with_service_lock >/dev/null 2>&1; then
      fail "state-only recovery accepted ${recovery_evidence##*/} evidence"
    fi
    [ -f "$RUN_STATE_FILE" ] && [ -f "$recovery_evidence" ] \
      || fail "rejected ${recovery_evidence##*/} recovery removed evidence"
    [ ! -s "$RECOVERY_MUTATIONS" ] \
      || fail "${recovery_evidence##*/} rejection mutated systemd or networking"
  )
done

# Strict state parsing and the immutable half of a committed snapshot must not
# be relaxed merely because the active snapshot cannot be loaded as a pair.
for rejected_state in corrupt directory starting desired-inactive deadline mismatch; do
  (
    reset_uncommitted_state_fixture
    install_recovery_doubles
    case "$rejected_state" in
      corrupt) printf '%s\n' 'FORMAT_VERSION=1' 'BROKEN=1' > "$RUN_STATE_FILE" ;;
      directory) rm -f -- "$RUN_STATE_FILE"; mkdir -- "$RUN_STATE_FILE" ;;
      starting) write_run_state "$FAILURE_RUN_ID" STARTING 1 0 ;;
      desired-inactive) write_run_state "$FAILURE_RUN_ID" PREPARING 0 0 ;;
      deadline) write_run_state "$FAILURE_RUN_ID" PREPARING 1 1 ;;
      mismatch)
        write_active_run "$MIGRATION_RUN_ID" "$SNAPSHOT_BOOT_ID" proxy 0 pulse 1081 "$LEGACY_ACCOUNT"
        ;;
    esac
    assert_prepare_recovery_rejected "$rejected_state state"
    if [ "$rejected_state" = mismatch ]; then
      [ -f "$ACTIVE_RUN_FILE" ] || fail 'mismatched active snapshot was removed'
    fi
  )
done

# The unit probes happen between two state-lock acquisitions. A competing
# writer that changes the candidate generation or adds evidence must be caught
# by the second complete validation, without deleting either generation.
for between_lock_change in run-id route-owner; do
  (
    reset_uncommitted_state_fixture
    install_recovery_doubles
    RECOVERY_INJECTED=0
    systemctl() {
      [ "$RECOVERY_STATE_LOCK_HELD" -eq 0 ] \
        || fail 'between-lock probe queried systemd while holding the state lock'
      if [ "$RECOVERY_INJECTED" -eq 0 ]; then
        RECOVERY_INJECTED=1
        case "$between_lock_change" in
          run-id) write_run_state "$MIGRATION_RUN_ID" PREPARING 1 0 ;;
          route-owner) printf '%s\n' evidence > "$ROUTE_OWNER_FILE" ;;
        esac
      fi
      printf '%s\n' inactive
      return 3
    }
    assert_prepare_recovery_rejected "between-lock ${between_lock_change} change"
    if [ "$between_lock_change" = run-id ]; then
      load_run_state || fail 'between-lock generation replacement became unreadable'
      assert_eq "$MIGRATION_RUN_ID" "$RUN_ID" 'between-lock generation replacement was deleted or overwritten'
    else
      [ -f "$ROUTE_OWNER_FILE" ] || fail 'between-lock route evidence was deleted'
    fi
  )
done

# Each persistent unit is part of the quiescence proof; unknown is not treated
# as inactive. These probes are read-only and rejection must not call stop.
for non_quiescent_unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME" unknown; do
  (
    reset_uncommitted_state_fixture
    install_recovery_doubles
    if [ "$non_quiescent_unit" = unknown ]; then
      RECOVERY_UNKNOWN_UNIT="$SERVICE_NAME"
    else
      RECOVERY_ACTIVE_UNIT="$non_quiescent_unit"
    fi
    assert_prepare_recovery_rejected "non-quiescent ${non_quiescent_unit}"
  )
done

# A persistent unit that is not inactive/failed may already own side effects.
(
  reset_uncommitted_state_fixture
  install_recovery_doubles
  RECOVERY_ACTIVE_UNIT="$SERVICE_NAME"
  if prepare_with_service_lock >/dev/null 2>&1; then
    fail 'state-only recovery accepted an active managed service'
  fi
  [ -f "$RUN_STATE_FILE" ] || fail 'active-unit rejection removed PREPARING evidence'
  [ ! -s "$RECOVERY_MUTATIONS" ] || fail 'active-unit rejection mutated systemd or networking'
)

# Manual stop (and therefore uninstall) must be able to finish the same exact
# pre-network half-transaction without stopping units or touching routes.
(
  reset_uncommitted_state_fixture
  install_recovery_doubles
  stop_vpn >/dev/null 2>&1 \
    || fail 'manual stop did not recover a safe PREPARING state-only transaction'
  [ ! -e "$RUN_STATE_FILE" ] && [ ! -L "$RUN_STATE_FILE" ] \
    || fail 'manual stop left recovered PREPARING evidence behind'
  [ -f "$PROFILE_FILE" ] || fail 'manual state-only recovery removed the compatibility profile'
  grep -Fx "$LEGACY_ACCOUNT" "$ACCOUNTS_FILE" >/dev/null \
    || fail 'manual state-only recovery changed the account file'
  [ ! -s "$RECOVERY_MUTATIONS" ] || fail 'manual state-only recovery mutated systemd or networking'
)

# The stop entry point shares the same fail-closed gate for unsafe partial state.
for unsafe_stop in route-owner active-unit; do
  (
    reset_uncommitted_state_fixture
    install_recovery_doubles
    case "$unsafe_stop" in
      route-owner) printf '%s\n' evidence > "$ROUTE_OWNER_FILE" ;;
      active-unit) RECOVERY_ACTIVE_UNIT="$HEALTH_TIMER_NAME" ;;
    esac
    assert_stop_recovery_rejected "$unsafe_stop"
  )
done

# Dangling and ordinary symlinks are distinct from absence. Exercise them on
# hosts that provide real POSIX symlinks (the mandatory Linux gate does).
SYMLINK_TARGET="${TEST_ROOT}/recovery-symlink-target"
rm -f -- "$SYMLINK_TARGET"
printf '%s\n' target > "$SYMLINK_TARGET"
SYMLINK_PROBE="${TEST_ROOT}/recovery-symlink-probe"
rm -f -- "$SYMLINK_PROBE"
if command ln -s -- "$SYMLINK_TARGET" "$SYMLINK_PROBE" 2>/dev/null && [ -L "$SYMLINK_PROBE" ]; then
  rm -f -- "$SYMLINK_PROBE"
  for symlink_case in run-state active-run route-owner; do
    (
      reset_uncommitted_state_fixture
      install_recovery_doubles
      case "$symlink_case" in
        run-state)
          mv -- "$RUN_STATE_FILE" "$SYMLINK_TARGET"
          ln -s -- "$SYMLINK_TARGET" "$RUN_STATE_FILE"
          ;;
        active-run) ln -s -- "$SYMLINK_TARGET" "$ACTIVE_RUN_FILE" ;;
        route-owner) ln -s -- "$SYMLINK_TARGET" "$ROUTE_OWNER_FILE" ;;
      esac
      assert_prepare_recovery_rejected "$symlink_case symlink"
    )
  done
else
  rm -f -- "$SYMLINK_PROBE"
  printf 'SKIP: snapshot symlink recovery assertions (real symlinks unavailable)\n'
fi

# Regression proof: the old implementation follows ACCOUNT_INDEX after a reorder.
# Once snapshots exist, the same scenario must load the immutable B record instead.
write_accounts_fixture
write_profile proxy 1 nc 1080
if declare -F create_run_snapshot >/dev/null 2>&1; then
  create_run_snapshot proxy 1 nc 1080 "$ACCOUNT_B" >/dev/null
fi
printf '%s\n' '# fixture header' "$ACCOUNT_B" '' '# keep this comment' "$ACCOUNT_A" > "$ACCOUNTS_FILE"
if declare -F load_runtime_configuration >/dev/null 2>&1; then
  load_runtime_configuration || fail 'valid runtime snapshot was rejected after account reorder'
else
  load_profile || fail 'legacy profile was rejected after account reorder'
  PROFILE_SOCKS_PORT=1080
fi
assert_runtime_is_b

# Deleting the selected live account must not affect runtime configuration or service arguments.
write_accounts_fixture
printf '%s\n' "$SNAPSHOT_RUN_ID" > "$OCM_UUID_FILE"
create_run_snapshot proxy 1 nc 1080 "$ACCOUNT_B" >/dev/null
printf '%s\n' '# fixture header' "$ACCOUNT_A" '' '# keep this comment' > "$ACCOUNTS_FILE"
load_runtime_configuration || fail 'valid runtime snapshot was rejected after account deletion'
assert_runtime_is_b
assert_eq "$SNAPSHOT_RUN_ID" "$RUN_ID" 'snapshot RUN_ID was not returned by the configured UUID source'
assert_eq PREPARING "$PHASE" 'snapshot creation advanced beyond PREPARING'

PROFILE_LINES="$(wc -l < "$PROFILE_FILE" | tr -d '[:space:]')"
assert_eq 4 "$PROFILE_LINES" 'compatibility profile does not contain exactly four fields'
assert_eq $'MODE=proxy\nACCOUNT_INDEX=1\nVPN_PROTOCOL=nc\nSOCKS_PORT=1080' "$(cat "$PROFILE_FILE")" \
  'compatibility profile fields changed'

MOCK_BIN="${TEST_ROOT}/mock-bin"
MOCK_ARGS="${TEST_ROOT}/openconnect.args"
MOCK_STDIN="${TEST_ROOT}/openconnect.stdin"
MOCK_STDOUT="${TEST_ROOT}/service.stdout"
MOCK_STDERR="${TEST_ROOT}/service.stderr"
mkdir -p "$MOCK_BIN"
cat > "${MOCK_BIN}/openconnect" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_ARGS"
cat > "$MOCK_STDIN"
EOF
chmod +x "${MOCK_BIN}/openconnect"
export MOCK_ARGS MOCK_STDIN
if ! command -v flock >/dev/null 2>&1; then flock() { return 0; }; fi
transition_run_state "$SNAPSHOT_RUN_ID" PREPARING STARTING 1 0 \
  || fail 'worker fixture could not commit STARTING'
if ! (
  PATH="${MOCK_BIN}:${PATH}"
  check_root() { :; }
  openconnect_option_supported() { return 1; }
  service_run
) >"$MOCK_STDOUT" 2>"$MOCK_STDERR"; then
  fail 'service_run rejected a valid immutable snapshot'
fi
assert_eq vpn-b.example.test "$(sed -n '1p' "$MOCK_ARGS")" 'OpenConnect host did not come from snapshot'
grep -Fx -- '--protocol=nc' "$MOCK_ARGS" >/dev/null || fail 'OpenConnect protocol did not come from snapshot'
grep -Fx -- '--user=bob' "$MOCK_ARGS" >/dev/null || fail 'OpenConnect username did not come from snapshot'
grep -Fx -- '--authgroup=group-b' "$MOCK_ARGS" >/dev/null || fail 'OpenConnect auth group did not come from snapshot'
grep -Fx -- '--script' "$MOCK_ARGS" >/dev/null || fail 'OpenConnect proxy script flag is missing'
grep -Fx -- 'ocproxy -k 30 -D 1080' "$MOCK_ARGS" >/dev/null || fail 'OpenConnect SOCKS port did not come from snapshot'
assert_eq beta-secret "$(tr -d '\r\n' < "$MOCK_STDIN")" 'OpenConnect password stdin did not come from snapshot'
if grep -F 'beta-secret' "$MOCK_STDOUT" "$MOCK_STDERR" >/dev/null 2>&1; then
  fail 'service logs exposed the account password'
fi

# Workers must fail closed when only a legacy profile exists or new state is half-written.
rm -f -- "$ACTIVE_RUN_FILE" "$RUN_STATE_FILE"
write_accounts_fixture
write_profile proxy 1 nc 1080
if load_runtime_configuration >/dev/null 2>&1; then
  fail 'worker runtime loader silently migrated a legacy profile'
fi
if (
  check_root() { :; }
  openconnect() { fail 'worker reached OpenConnect without a snapshot'; }
  service_run
) >/dev/null 2>&1; then
  fail 'service worker accepted a legacy profile without a snapshot'
fi

printf '%s\n' "$MIGRATION_RUN_ID" > "$OCM_UUID_FILE"
migrate_legacy_profile >/dev/null || fail 'explicit legacy migration rejected a valid legacy profile'
load_runtime_configuration || fail 'explicit legacy migration did not create a valid snapshot'
assert_runtime_is_b
MIGRATED_ACTIVE_SUM="$(cksum < "$ACTIVE_RUN_FILE")"
MIGRATED_STATE_SUM="$(cksum < "$RUN_STATE_FILE")"
if migrate_legacy_profile >/dev/null 2>&1; then
  fail 'legacy migration created another generation over new state'
fi
assert_eq "$MIGRATED_ACTIVE_SUM" "$(cksum < "$ACTIVE_RUN_FILE")" 'rejected migration changed the active snapshot'
assert_eq "$MIGRATED_STATE_SUM" "$(cksum < "$RUN_STATE_FILE")" 'rejected migration changed run state'

rm -f -- "$ACTIVE_RUN_FILE"
if load_runtime_configuration >/dev/null 2>&1; then
  fail 'runtime loader accepted run-state without its matching snapshot'
fi
if (
  check_root() { :; }
  openconnect() { fail 'worker reached OpenConnect with half-written state'; }
  service_run
) >/dev/null 2>&1; then
  fail 'service worker fell back to accounts after snapshot removal'
fi

# A failed snapshot write may leave PREPARING evidence, but must never enter STARTING.
rm -f -- "$ACTIVE_RUN_FILE" "$RUN_STATE_FILE"
printf '%s\n' "$FAILURE_RUN_ID" > "$OCM_UUID_FILE"
FAILURE_ERROR="${TEST_ROOT}/snapshot-failure.stderr"
if (
  write_active_run() { return 1; }
  create_run_snapshot proxy 1 nc 1080 "$ACCOUNT_B"
) >/dev/null 2>"$FAILURE_ERROR"; then
  fail 'snapshot creation succeeded after active-run write failure'
fi
load_run_state || fail 'failed snapshot creation did not preserve valid PREPARING evidence'
assert_eq PREPARING "$PHASE" 'failed snapshot creation advanced beyond PREPARING'
if grep -F 'beta-secret' "$FAILURE_ERROR" >/dev/null 2>&1; then
  fail 'snapshot failure exposed the account password'
fi

rm -f -- "$ACTIVE_RUN_FILE" "$RUN_STATE_FILE" "$PROFILE_FILE"
if (
  write_profile() { return 0; }
  create_run_snapshot proxy 1 nc 1080 "$ACCOUNT_B"
) >/dev/null 2>"$FAILURE_ERROR"; then
  fail 'snapshot creation accepted a compatibility profile that was not persisted'
fi
load_run_state || fail 'missing-profile failure did not preserve valid PREPARING evidence'
assert_eq PREPARING "$PHASE" 'missing-profile failure advanced beyond PREPARING'

# A writer that reports success with valid but mismatched persisted values must be rejected.
for mismatch_field in \
  CREATED_BOOT_ID MODE ACCOUNT_INDEX VPN_PROTOCOL SOCKS_PORT ACCOUNT_RECORD \
  PHASE DESIRED_ACTIVE ROLLBACK_DEADLINE; do
  rm -f -- "$ACTIVE_RUN_FILE" "$RUN_STATE_FILE" "$PROFILE_FILE"
  if (
    MISMATCH_FIELD="$mismatch_field"
    case "$MISMATCH_FIELD" in
      CREATED_BOOT_ID|MODE|ACCOUNT_INDEX|VPN_PROTOCOL|SOCKS_PORT|ACCOUNT_RECORD)
        write_active_run() { write_mismatched_active_run "$@"; }
        ;;
      PHASE|DESIRED_ACTIVE|ROLLBACK_DEADLINE)
        write_run_state() { write_mismatched_run_state "$@"; }
        ;;
    esac
    create_run_snapshot proxy 1 nc 1080 "$ACCOUNT_B"
  ) >/dev/null 2>"$FAILURE_ERROR"; then
    fail "snapshot creation accepted mismatched persisted ${mismatch_field}"
  fi
  if grep -F 'beta-secret' "$FAILURE_ERROR" >/dev/null 2>&1; then
    fail "mismatched ${mismatch_field} failure exposed the account password"
  fi
done

# Complete account replacement must preserve non-account lines, ordering and mode.
ORIGINAL_ACCOUNTS=$'# first comment\n\nAccount A|alice|alpha-secret|vpn-a.example.test|group-a|nc\n# middle comment\nAccount B|bob|beta-secret|vpn-b.example.test|group-b|nc\n'
printf '%s' "$ORIGINAL_ACCOUNTS" | replace_accounts_from_stdin
load_file_exact "$ACCOUNTS_FILE"
assert_eq "$ORIGINAL_ACCOUNTS" "$FILE_CONTENT" 'atomic account replacement changed file content'
assert_file_mode "$ACCOUNTS_FILE" 600
if [ "$(id -u)" -eq 0 ]; then
  assert_eq 0 "$(stat -c '%u' "$ACCOUNTS_FILE")" 'account replacement did not preserve root ownership'
fi

if (
  mv() { return 1; }
  manage_accounts <<< $'1\nAccount C\ncarol\ngamma-secret\nvpn-c.example.test\ngroup-c\n2\n0\n'
) >/dev/null 2>&1; then
  fail 'account addition reported success after atomic rename failure'
fi
load_file_exact "$ACCOUNTS_FILE"
assert_eq "$ORIGINAL_ACCOUNTS" "$FILE_CONTENT" 'failed account addition changed the old file'

manage_accounts <<< $'1\nAccount C\ncarol\ngamma-secret\nvpn-c.example.test\ngroup-c\n2\n0\n' >/dev/null \
  || fail 'valid account addition failed'
EXPECTED_AFTER_ADD="${ORIGINAL_ACCOUNTS}"$'Account C|carol|gamma-secret|vpn-c.example.test|group-c|nc\n'
load_file_exact "$ACCOUNTS_FILE"
assert_eq "$EXPECTED_AFTER_ADD" "$FILE_CONTENT" 'account addition changed comments, blank lines or ordering'
assert_file_mode "$ACCOUNTS_FILE" 600

load_file_exact "$ACCOUNTS_FILE"
BEFORE_FAILED_DELETE="$FILE_CONTENT"
if (
  mv() { return 1; }
  manage_accounts <<< $'2\n2\n0\n'
) >/dev/null 2>&1; then
  fail 'account deletion reported success after atomic rename failure'
fi
load_file_exact "$ACCOUNTS_FILE"
assert_eq "$BEFORE_FAILED_DELETE" "$FILE_CONTENT" 'failed account deletion changed the old file'

manage_accounts <<< $'2\n2\n0\n' >/dev/null || fail 'valid account deletion failed'
EXPECTED_AFTER_DELETE=$'# first comment\n\nAccount A|alice|alpha-secret|vpn-a.example.test|group-a|nc\n# middle comment\nAccount C|carol|gamma-secret|vpn-c.example.test|group-c|nc\n'
load_file_exact "$ACCOUNTS_FILE"
assert_eq "$EXPECTED_AFTER_DELETE" "$FILE_CONTENT" 'account deletion changed comments, blank lines or ordering'
assert_file_mode "$ACCOUNTS_FILE" 600

printf 'snapshot checks passed\n'
