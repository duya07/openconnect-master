#!/usr/bin/env bash
set -Eeuo pipefail

PATH="/usr/bin:/bin:${PATH}"
export PATH

cd -- "${BASH_SOURCE[0]%/*}/.."
source tests/testlib.sh

TEST_ROOT="$(new_test_root)"
trap 'cleanup_test_root "$TEST_ROOT"' EXIT
export_test_paths "$TEST_ROOT"
mkdir -p -- "$OCM_CONFIG_DIR" "$OCM_RUNTIME_DIR" "${OCM_STATE_LOCK_FILE%/*}" "${OCM_BOOT_ID_FILE%/*}"

readonly TEST_RUN_ID='123e4567-e89b-42d3-a456-426614174000'
readonly OTHER_RUN_ID='123e4567-e89b-42d3-a456-426614174001'
readonly TEST_BOOT_ID='123e4567-e89b-42d3-a456-426614174002'
readonly TEST_ACCOUNT_LINE='primary vpn|alice|secret=$(printf unsafe) with spaces|vpn.example.com||anyconnect'

printf '%s\n' "$TEST_RUN_ID" > "$OCM_UUID_FILE"
printf '%s\n' "$TEST_BOOT_ID" > "$OCM_BOOT_ID_FILE"

source oc_master.sh

assert_rejected_without_secret() {
  local label="$1" command_name="$2" error_file="${TEST_ROOT}/error.log"
  shift 2

  : > "$error_file"
  if "$command_name" "$@" >/dev/null 2>"$error_file"; then
    fail "$label was accepted"
  fi
  if grep -F 'secret=' "$error_file" >/dev/null 2>&1; then
    fail "$label exposed an account secret"
  fi
}

write_active_fixture() {
  local version="$1" run_id="$2" boot_id="$3" mode="$4" index="$5" protocol="$6" port="$7" record="$8"
  printf '%s\n' \
    "FORMAT_VERSION=$version" \
    "RUN_ID=$run_id" \
    "CREATED_BOOT_ID=$boot_id" \
    "MODE=$mode" \
    "ACCOUNT_INDEX=$index" \
    "VPN_PROTOCOL=$protocol" \
    "SOCKS_PORT=$port" \
    "ACCOUNT_RECORD=$record" > "$ACTIVE_RUN_FILE"
}

write_state_fixture() {
  local version="$1" run_id="$2" phase="$3" desired="$4" deadline="$5"
  printf '%s\n' \
    "FORMAT_VERSION=$version" \
    "RUN_ID=$run_id" \
    "PHASE=$phase" \
    "DESIRED_ACTIVE=$desired" \
    "ROLLBACK_DEADLINE=$deadline" > "$RUN_STATE_FILE"
}

valid_uuid "$TEST_RUN_ID" || fail 'a valid lowercase RFC 4122 UUID was rejected'
valid_uuid '123e4567-e89b-42d3-a456-426614174000' || fail 'a valid versioned UUID was rejected'
assert_rejected_without_secret 'uppercase UUID' valid_uuid '123E4567-E89B-42D3-A456-426614174000'
assert_rejected_without_secret 'truncated UUID' valid_uuid '123e4567-e89b-42d3-a456-42661417400'
assert_eq "$TEST_RUN_ID" "$(new_run_id)" 'new_run_id did not read the configured UUID source'
assert_eq "$TEST_BOOT_ID" "$(current_boot_id)" 'current_boot_id did not read the configured boot ID source'

printf '%s\n%s\n' "$TEST_RUN_ID" "$OTHER_RUN_ID" > "$OCM_UUID_FILE"
assert_rejected_without_secret 'multi-line UUID source' new_run_id
printf '%s\n' "$TEST_RUN_ID" > "$OCM_UUID_FILE"
printf '%s\n%s\n' "$TEST_BOOT_ID" "$OTHER_RUN_ID" > "$OCM_BOOT_ID_FILE"
assert_rejected_without_secret 'multi-line boot ID source' current_boot_id
printf '%s\n' "$TEST_BOOT_ID" > "$OCM_BOOT_ID_FILE"

write_active_run "$TEST_RUN_ID" "$TEST_BOOT_ID" proxy 0 anyconnect 1080 "$TEST_ACCOUNT_LINE"
assert_file_mode "$ACTIVE_RUN_FILE" 600
load_active_run || fail 'valid active-run snapshot was rejected'
assert_eq "$TEST_RUN_ID" "$RUN_ID" 'active-run RUN_ID was not loaded'
assert_eq "$TEST_BOOT_ID" "$CREATED_BOOT_ID" 'active-run boot ID was not loaded'
assert_eq proxy "$MODE" 'active-run mode was not loaded'
assert_eq 0 "$ACCOUNT_INDEX" 'active-run account index was not loaded'
assert_eq anyconnect "$VPN_PROTOCOL" 'active-run protocol was not loaded'
assert_eq 1080 "$SOCKS_PORT" 'active-run SOCKS port was not loaded'
[ "$ACCOUNT_RECORD" = "$TEST_ACCOUNT_LINE" ] || fail 'active-run account record was not preserved exactly'

write_active_fixture 1 "$TEST_RUN_ID" "$TEST_BOOT_ID" proxy 0 anyconnect 1080 "$TEST_ACCOUNT_LINE"
sed -i '/^CREATED_BOOT_ID=/d' "$ACTIVE_RUN_FILE"
assert_rejected_without_secret 'active-run missing field' load_active_run
write_active_fixture 1 "$TEST_RUN_ID" "$TEST_BOOT_ID" proxy 0 anyconnect 1080 "$TEST_ACCOUNT_LINE"
printf '%s\n' "RUN_ID=$TEST_RUN_ID" >> "$ACTIVE_RUN_FILE"
assert_rejected_without_secret 'active-run duplicate field' load_active_run
write_active_fixture 1 "$TEST_RUN_ID" "$TEST_BOOT_ID" proxy 0 anyconnect 1080 "$TEST_ACCOUNT_LINE"
printf '%s\n' 'UNKNOWN_FIELD=1' >> "$ACTIVE_RUN_FILE"
assert_rejected_without_secret 'active-run unknown field' load_active_run
write_active_fixture 2 "$TEST_RUN_ID" "$TEST_BOOT_ID" proxy 0 anyconnect 1080 "$TEST_ACCOUNT_LINE"
assert_rejected_without_secret 'active-run unknown format version' load_active_run
write_active_fixture 1 "$TEST_RUN_ID" "$TEST_BOOT_ID" invalid 0 anyconnect 1080 "$TEST_ACCOUNT_LINE"
assert_rejected_without_secret 'active-run invalid mode' load_active_run
write_active_fixture 1 "$TEST_RUN_ID" "$TEST_BOOT_ID" proxy 0 invalid 1080 "$TEST_ACCOUNT_LINE"
assert_rejected_without_secret 'active-run invalid protocol' load_active_run
write_active_fixture 1 "$TEST_RUN_ID" "$TEST_BOOT_ID" proxy 0 anyconnect 1080 "$TEST_ACCOUNT_LINE"
printf '%s\n' 'injected-line' >> "$ACTIVE_RUN_FILE"
assert_rejected_without_secret 'active-run embedded newline record' load_active_run
assert_rejected_without_secret 'writer embedded newline record' write_active_run \
  "$TEST_RUN_ID" "$TEST_BOOT_ID" proxy 0 anyconnect 1080 "${TEST_ACCOUNT_LINE}"$'\n''injected-line'

write_active_run "$TEST_RUN_ID" "$TEST_BOOT_ID" proxy 0 anyconnect 1080 "$TEST_ACCOUNT_LINE"
ACTIVE_BEFORE_FAILURE="$(cksum < "$ACTIVE_RUN_FILE")"
readonly ACTIVE_BEFORE_FAILURE
mv() { return 1; }
if printf '%s\n' 'replacement must fail' | atomic_replace_from_stdin "$ACTIVE_RUN_FILE" 0600 >/dev/null 2>&1; then
  unset -f mv
  fail 'atomic replacement unexpectedly succeeded when mv failed'
fi
unset -f mv
assert_eq "$ACTIVE_BEFORE_FAILURE" "$(cksum < "$ACTIVE_RUN_FILE")" 'failed atomic replacement changed the old file'

write_run_state "$TEST_RUN_ID" PREPARING 1 0
assert_file_mode "$RUN_STATE_FILE" 600
load_run_state || fail 'valid run state was rejected'
assert_eq "$TEST_RUN_ID" "$RUN_ID" 'run-state RUN_ID was not loaded'
assert_eq PREPARING "$PHASE" 'run-state phase was not loaded'
assert_eq 1 "$DESIRED_ACTIVE" 'run-state desired-active flag was not loaded'
assert_eq 0 "$ROLLBACK_DEADLINE" 'run-state rollback deadline was not loaded'

write_state_fixture 1 "$TEST_RUN_ID" PREPARING 1 0
sed -i '/^PHASE=/d' "$RUN_STATE_FILE"
assert_rejected_without_secret 'run-state missing field' load_run_state
write_state_fixture 1 "$TEST_RUN_ID" PREPARING 1 0
printf '%s\n' 'PHASE=PREPARING' >> "$RUN_STATE_FILE"
assert_rejected_without_secret 'run-state duplicate field' load_run_state
write_state_fixture 1 "$TEST_RUN_ID" PREPARING 1 0
printf '%s\n' 'UNKNOWN_FIELD=1' >> "$RUN_STATE_FILE"
assert_rejected_without_secret 'run-state unknown field' load_run_state
write_state_fixture 2 "$TEST_RUN_ID" PREPARING 1 0
assert_rejected_without_secret 'run-state unknown format version' load_run_state
write_state_fixture 1 "$TEST_RUN_ID" INVALID 1 0
assert_rejected_without_secret 'run-state invalid phase' load_run_state
write_state_fixture 1 "$TEST_RUN_ID" PREPARING 2 0
assert_rejected_without_secret 'run-state invalid desired-active flag' load_run_state

write_active_run "$TEST_RUN_ID" "$TEST_BOOT_ID" proxy 0 anyconnect 1080 "$TEST_ACCOUNT_LINE"
write_run_state "$OTHER_RUN_ID" PREPARING 1 0
assert_rejected_without_secret 'runtime RUN_ID mismatch' load_runtime_state

write_run_state "$TEST_RUN_ID" PREPARING 1 0
if ! command -v flock >/dev/null 2>&1; then
  flock() { return 0; }
fi
transition_run_state "$TEST_RUN_ID" 'PREPARING,CLEANUP_FAILED' STARTING 1 0 \
  || fail 'valid compare-and-set transition was rejected'
load_run_state || fail 'transitioned run state was invalid'
assert_eq STARTING "$PHASE" 'compare-and-set did not persist the new phase'

STATE_BEFORE_REJECTED_CAS="$(cksum < "$RUN_STATE_FILE")"
readonly STATE_BEFORE_REJECTED_CAS
assert_rejected_without_secret 'compare-and-set old phase mismatch' transition_run_state \
  "$TEST_RUN_ID" 'RUNNING,AWAITING_CONFIRMATION' CONFIRMED 1 0
assert_eq "$STATE_BEFORE_REJECTED_CAS" "$(cksum < "$RUN_STATE_FILE")" \
  'rejected compare-and-set changed run-state bytes'

printf 'state checks passed\n'
