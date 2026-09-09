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
