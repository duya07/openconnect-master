#!/usr/bin/env bash
set -Eeuo pipefail

PATH="/usr/bin:/bin:${PATH}"
export PATH

cd -- "${BASH_SOURCE[0]%/*}/.."

# shellcheck source=tests/testlib.sh
source tests/testlib.sh

TEST_ROOT="$(new_test_root)"
trap 'cleanup_test_root "$TEST_ROOT"' EXIT

CURRENT_SCRIPT="$(pwd)/oc_master.sh"
BASELINE_SCRIPT="${OCM_BASELINE_SCRIPT:-${TEST_ROOT}/baseline/oc_master.sh}"
if [ -z "${OCM_BASELINE_SCRIPT:-}" ]; then
  mkdir -p "${BASELINE_SCRIPT%/*}"
  git show e03f2aa:oc_master.sh > "$BASELINE_SCRIPT"
fi
[ -r "$BASELINE_SCRIPT" ] || fail "baseline script is not readable: $BASELINE_SCRIPT"

normalize_file() {
  local input_file="$1" normalized_file="$2" script_path="$3" public_ipv4="$4" public_ipv6="$5" output

  output="$(cat -- "$input_file"; printf '\001')"
  output="${output%$'\001'}"
  output="${output//"$script_path"/<SCRIPT_PATH>}"
  output="${output//"$TEST_ROOT"/<TEST_ROOT>}"
  output="${output//"$public_ipv4"/<PUBLIC_IPV4>}"
  output="${output//"$public_ipv6"/<PUBLIC_IPV6>}"
  printf '%s' "$output" > "$normalized_file"
}

run_case() {
  local case_name="$1" script_path="$2" input="$3" suffix="$4" command="$5"
  local case_root="${TEST_ROOT}/${case_name}"
  local stdout_file="${case_root}/stdout-${suffix}" stderr_file="${case_root}/stderr-${suffix}"
  local rc_file="${case_root}/rc-${suffix}"
  local public_ipv4="198.51.100.${suffix}" public_ipv6="2001:db8::${suffix}"

  mkdir -p "$case_root"
  export_test_paths "$case_root"
  set +e
  "${BASH}" -c '
    source "$1"
    BASH_ARGV0="$1"
    mock_public_ipv4="$3"
    mock_public_ipv6="$4"
    check_root() { :; }
    acquire_manager_lock() { :; }
    ensure_dirs() { mkdir -p "$CONFIG_DIR" "$RUNTIME_DIR"; }
    curl() {
      case " $* " in
        *" -6 "*) printf "%s" "$mock_public_ipv6" ;;
        *) printf "%s" "$mock_public_ipv4" ;;
      esac
    }
    if [ "$5" = "start-proxy-without-account" ]; then
      ensure_dependencies() { :; }
    fi
    run_main "$2"
  ' compat-case "$script_path" "$command" "$public_ipv4" "$public_ipv6" "$case_name" < "$input" > "$stdout_file" 2> "$stderr_file"
  rc=$?
  set -e
  printf '%s\n' "$rc" > "$rc_file"
}

compare_stream() {
  local case_name="$1" stream_name="$2"
  local baseline_file="$3" current_file="$4"
  local baseline_script="$5" baseline_ipv4="$6" baseline_ipv6="$7"
  local current_script="$8" current_ipv4="$9" current_ipv6="${10}"
  local baseline_normalized="${baseline_file}.normalized"
  local current_normalized="${current_file}.normalized"

  normalize_file "$baseline_file" "$baseline_normalized" "$baseline_script" "$baseline_ipv4" "$baseline_ipv6"
  normalize_file "$current_file" "$current_normalized" "$current_script" "$current_ipv4" "$current_ipv6"
  if ! cmp -s "$baseline_normalized" "$current_normalized"; then
    diff -u --label "baseline ${stream_name}" --label "current ${stream_name}" \
      "$baseline_normalized" "$current_normalized" >&2 || true
    fail "$case_name ${stream_name} changed"
  fi
}

compare_case() {
  local case_name="$1" command="$2" input_text="$3"
  local input_file="${TEST_ROOT}/${case_name}.input"
  local baseline_stdout baseline_stderr baseline_rc_file baseline_ipv4 baseline_ipv6
  local current_stdout current_stderr current_rc_file current_ipv4 current_ipv6
  local baseline_rc current_rc

  printf '%s' "$input_text" > "$input_file"
  run_case "$case_name" "$BASELINE_SCRIPT" "$input_file" 10 "$command"
  run_case "$case_name" "$CURRENT_SCRIPT" "$input_file" 20 "$command"
  baseline_stdout="${TEST_ROOT}/${case_name}/stdout-10"
  baseline_stderr="${TEST_ROOT}/${case_name}/stderr-10"
  baseline_rc_file="${TEST_ROOT}/${case_name}/rc-10"
  baseline_ipv4='198.51.100.10'
  baseline_ipv6='2001:db8::10'
  current_stdout="${TEST_ROOT}/${case_name}/stdout-20"
  current_stderr="${TEST_ROOT}/${case_name}/stderr-20"
  current_rc_file="${TEST_ROOT}/${case_name}/rc-20"
  current_ipv4='198.51.100.20'
  current_ipv6='2001:db8::20'

  baseline_rc="$(<"$baseline_rc_file")"
  current_rc="$(<"$current_rc_file")"
  assert_eq "$baseline_rc" "$current_rc" "$case_name exit status changed"

  compare_stream "$case_name" stdout "$baseline_stdout" "$current_stdout" \
    "$BASELINE_SCRIPT" "$baseline_ipv4" "$baseline_ipv6" \
    "$CURRENT_SCRIPT" "$current_ipv4" "$current_ipv6"
  compare_stream "$case_name" stderr "$baseline_stderr" "$current_stderr" \
    "$BASELINE_SCRIPT" "$baseline_ipv4" "$baseline_ipv6" \
    "$CURRENT_SCRIPT" "$current_ipv4" "$current_ipv6"
}

compare_case 'unknown-command' 'unknown-command' ''
compare_case 'status-without-profile' 'status' ''
compare_case 'main-menu-exit' '' $'0\n'
compare_case 'start-proxy-without-account' 'start-proxy' ''
compare_case 'accounts-menu-exit-without-account' 'accounts' $'0\n'

grep -F 'start-proxy|start-global|stop|accounts|deps|install|uninstall|status|check|logs' "$CURRENT_SCRIPT" >/dev/null \
  || fail 'public command set changed'
grep -F '请选择 [0-9]:' "$CURRENT_SCRIPT" >/dev/null || fail 'main menu prompt changed'
grep -F '[ "$answer" = "GLOBAL" ]' "$CURRENT_SCRIPT" >/dev/null || fail 'GLOBAL confirmation changed'
grep -F '[ "$answer" = "GLOBAL-DDNS-RISK" ]' "$CURRENT_SCRIPT" >/dev/null || fail 'GLOBAL-DDNS-RISK confirmation changed'
grep -F '[ "$answer" = "KEEP" ]' "$CURRENT_SCRIPT" >/dev/null || fail 'KEEP confirmation changed'
grep -F 'socks_port="${socks_port:-1080}"' "$CURRENT_SCRIPT" >/dev/null || fail 'default SOCKS port changed'
grep -F 'readonly RETURN4_TABLE="51888"' "$CURRENT_SCRIPT" >/dev/null || fail 'IPv4 return table changed'
grep -F 'readonly RETURN6_TABLE="51889"' "$CURRENT_SCRIPT" >/dev/null || fail 'IPv6 return table changed'
grep -F 'readonly RETURN4_PRIORITY="10000"' "$CURRENT_SCRIPT" >/dev/null || fail 'IPv4 rule priority changed'
grep -F 'readonly RETURN6_PRIORITY="10001"' "$CURRENT_SCRIPT" >/dev/null || fail 'IPv6 rule priority changed'

printf 'compatibility checks passed\n'
