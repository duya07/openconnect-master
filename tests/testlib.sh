#!/usr/bin/env bash
set -Eeuo pipefail

new_test_root() {
  mktemp -d "${TMPDIR:-/tmp}/oc-master-test.XXXXXX"
}

cleanup_test_root() {
  local test_root="${1:-${TEST_ROOT:-}}"
  [ -n "$test_root" ] && [ -d "$test_root" ] && rm -rf -- "$test_root"
}

fail() {
  printf 'test failed: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" message="${3:-values differ}"
  [ "$expected" = "$actual" ] || fail "$message (expected: $expected; actual: $actual)"
}

assert_file_mode() {
  local path="$1" expected_mode="$2" actual_mode
  actual_mode="$(stat -c '%a' -- "$path")" || fail "could not read mode for $path"
  assert_eq "$expected_mode" "$actual_mode" "unexpected mode for $path"
}

export_test_paths() {
  local test_root="$1"

  export OCM_INSTALL_PATH="${test_root}/sbin/oc-master"
  export OCM_SHORTCUT_PATH="${test_root}/bin/ocm"
  export OCM_CONFIG_DIR="${test_root}/config"
  export OCM_PROFILE_FILE="${test_root}/config/profile.conf"
  export OCM_ACCOUNTS_FILE="${test_root}/accounts.env"
  export OCM_RUNTIME_DIR="${test_root}/run"
  export OCM_LOCK_FILE="${test_root}/lock/oc-master.lock"
  export OCM_STATE_LOCK_FILE="${test_root}/lock/oc-master-state.lock"
  export OCM_SERVICE_LOCK_FILE="${test_root}/lock/oc-master-service.lock"
  export OCM_SYSTEMD_DIR="${test_root}/systemd"
  export OCM_DDNS_SCAN_ROOT="${test_root}/scan"
  export OCM_ROUTE_OWNER_FILE="${test_root}/config/owns-return-routing"
  export OCM_BOOT_ID_FILE="${test_root}/proc/boot_id"
  export OCM_UUID_FILE="${test_root}/proc/uuid"
}
