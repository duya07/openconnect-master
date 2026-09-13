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

mkdir -p -- "$OCM_CONFIG_DIR" "$OCM_RUNTIME_DIR" "${OCM_STATE_LOCK_FILE%/*}" \
  "${OCM_BOOT_ID_FILE%/*}"

ITERATIONS="${OCM_PERF_ITERATIONS:-200}"
[[ "$ITERATIONS" =~ ^[1-9][0-9]*$ ]] \
  || fail 'OCM_PERF_ITERATIONS must be a positive decimal integer'
readonly ITERATIONS
readonly MAX_STATE_BYTES=32768
readonly PROXY_RUN_ID='123e4567-e89b-42d3-a456-426614174020'
readonly GLOBAL_RUN_ID='123e4567-e89b-42d3-a456-426614174021'
readonly TEST_BOOT_ID='123e4567-e89b-42d3-a456-426614174022'
readonly TEST_ACCOUNT_LINE='benchmark|bench-user|fixture-password|vpn.example.test||anyconnect'
BASELINE_SCRIPT="${OCM_BASELINE_SCRIPT:-$TEST_ROOT/oc_master.baseline.sh}"
readonly BASELINE_SCRIPT
readonly BASELINE_STATUS_ROOT="$TEST_ROOT/status-baseline"
readonly CURRENT_STATUS_ROOT="$TEST_ROOT/status-current"
readonly BASELINE_REQUEST_COUNT_FILE="$TEST_ROOT/status-baseline.requests"
readonly CURRENT_REQUEST_COUNT_FILE="$TEST_ROOT/status-current.requests"
MAX_OBSERVED_STATE_BYTES=0

printf '%s\n' "$TEST_BOOT_ID" > "$OCM_BOOT_ID_FILE"

if [ -z "${OCM_BASELINE_SCRIPT:-}" ]; then
  git show e03f2aa:oc_master.sh > "$BASELINE_SCRIPT" \
    || fail 'baseline script could not be extracted'
fi
[ -r "$BASELINE_SCRIPT" ] || fail "baseline script is not readable: $BASELINE_SCRIPT"

count_status_public_requests() {
  local script_path="$1" status_root="$2" count_file="$3"
  local count

  (
    export_test_paths "$status_root"
    mkdir -p -- "$OCM_CONFIG_DIR" "$OCM_RUNTIME_DIR" "${OCM_STATE_LOCK_FILE%/*}"
    : > "$count_file"

    # 两版都使用完全未配置状态：无 profile、active-run 或 run-state。
    # 该等价分支只覆盖 show_status 的公网地址查询，不进入 systemctl/health 路径。
    # shellcheck source=/dev/null
    source "$script_path"

    curl() {
      local arg caller="${FUNCNAME[1]:-unknown}"

      printf '%s\n' "$caller" >> "$count_file"
      for arg in "$@"; do
        if [ "$arg" = '-6' ]; then
          printf '2001:db8::10\n'
          return 0
        fi
      done
      printf '198.51.100.10\n'
    }

    local status_output
    status_output="$(show_status)" || fail 'show_status returned non-zero'
    case "$status_output" in
      *198.51.100.10*2001:db8::10*) ;;
      *) fail 'show_status did not return both fixed public addresses' ;;
    esac
  )

  awk '$0 != "public_ip" && $0 != "public_ipv6" { exit 1 }' "$count_file" \
    || fail 'public request counter observed a call outside public_ip/public_ipv6'
  count="$(awk 'END { print NR + 0 }' "$count_file")" \
    || fail 'public request count could not be read'
  ((count > 0)) || fail 'show_status made no measured public IP request'
  printf '%s' "$count"
}

BASELINE_PUBLIC_REQUESTS="$(count_status_public_requests \
  "$BASELINE_SCRIPT" "$BASELINE_STATUS_ROOT" "$BASELINE_REQUEST_COUNT_FILE")"
CURRENT_PUBLIC_REQUESTS="$(count_status_public_requests \
  "$PWD/oc_master.sh" "$CURRENT_STATUS_ROOT" "$CURRENT_REQUEST_COUNT_FILE")"
readonly BASELINE_PUBLIC_REQUESTS CURRENT_PUBLIC_REQUESTS

if ((CURRENT_PUBLIC_REQUESTS > BASELINE_PUBLIC_REQUESTS)); then
  fail "show_status public requests increased (baseline: $BASELINE_PUBLIC_REQUESTS; current: $CURRENT_PUBLIC_REQUESTS)"
fi
printf 'show_status public requests baseline=%s current=%s\n' \
  "$BASELINE_PUBLIC_REQUESTS" "$CURRENT_PUBLIC_REQUESTS"

# shellcheck source=../oc_master.sh
source oc_master.sh

FLOCK_STUBBED=0
if ! command -v flock >/dev/null 2>&1; then
  flock() { return 0; }
  FLOCK_STUBBED=1
fi
readonly FLOCK_STUBBED

state_tree_bytes() {
  find "$CONFIG_DIR" "$RUNTIME_DIR" -type f -exec stat -c '%s' -- {} + \
    | awk '{ total += $1 } END { print total + 0 }'
}

benchmark_mode() {
  local mode="$1" fixture_run_id="$2" socks_port="$3"
  local run_id boot_id iteration expected_phase next_phase size_bytes max_bytes
  local start_ms end_ms elapsed_ms

  printf '%s\n' "$fixture_run_id" > "$OCM_UUID_FILE"
  run_id="$(new_run_id)" || fail "$mode UUID fixture was rejected"
  boot_id="$(current_boot_id)" || fail "$mode boot-ID fixture was rejected"
  write_active_run "$run_id" "$boot_id" "$mode" 0 anyconnect "$socks_port" \
    "$TEST_ACCOUNT_LINE" || fail "$mode active snapshot was rejected"
  write_run_state "$run_id" RUNNING 1 0 || fail "$mode run state was rejected"

  size_bytes="$(state_tree_bytes)" || fail "$mode initial state size could not be measured"
  max_bytes="$size_bytes"
  start_ms="$(date +%s%3N)" || fail "$mode start time could not be read"
  for ((iteration = 1; iteration <= ITERATIONS; iteration++)); do
    if ((iteration % 2 == 1)); then
      expected_phase=RUNNING
      next_phase=CONFIRMED
    else
      expected_phase=CONFIRMED
      next_phase=RUNNING
    fi
    load_runtime_state || fail "$mode runtime state load failed at iteration $iteration"
    assert_eq "$run_id" "$RUN_ID" "$mode runtime generation changed"
    assert_eq "$mode" "$MODE" "$mode runtime mode changed"
    assert_eq "$expected_phase" "$PHASE" "$mode runtime phase changed unexpectedly"

    transition_run_state "$run_id" "$expected_phase" "$next_phase" 1 0 \
      || fail "$mode $expected_phase-to-$next_phase CAS failed at iteration $iteration"
  done
  end_ms="$(date +%s%3N)" || fail "$mode end time could not be read"
  elapsed_ms=$((end_ms - start_ms))

  size_bytes="$(state_tree_bytes)" || fail "$mode final state size could not be measured"
  if ((size_bytes > max_bytes)); then
    max_bytes="$size_bytes"
  fi
  if ((max_bytes > MAX_OBSERVED_STATE_BYTES)); then
    MAX_OBSERVED_STATE_BYTES="$max_bytes"
  fi
  printf '%s elapsed_ms=%s iterations=%s max_bytes=%s\n' \
    "$mode" "$elapsed_ms" "$ITERATIONS" "$max_bytes"
}

JOBS_BEFORE="$(jobs -pr)"
readonly JOBS_BEFORE

benchmark_mode proxy "$PROXY_RUN_ID" 1080
benchmark_mode global "$GLOBAL_RUN_ID" ''

if ((MAX_OBSERVED_STATE_BYTES >= MAX_STATE_BYTES)); then
  fail "state exceeded byte limit (max: $MAX_OBSERVED_STATE_BYTES; limit: $MAX_STATE_BYTES)"
fi

JOBS_AFTER="$(jobs -pr)"
readonly JOBS_AFTER
assert_eq "$JOBS_BEFORE" "$JOBS_AFTER" 'benchmark changed the current shell background jobs'

if [ "$FLOCK_STUBBED" -eq 1 ]; then
  printf 'note: flock unavailable; elapsed measurements are not locking-performance evidence\n'
fi
printf 'performance checks passed\n'
