#!/usr/bin/env bash
set -Eeuo pipefail

PATH="/usr/bin:/bin:${PATH}"
export PATH

cd -- "${BASH_SOURCE[0]%/*}/.."

# shellcheck source=./testlib.sh
source tests/testlib.sh

TEST_ROOT="$(new_test_root)"
trap 'cleanup_test_root "$TEST_ROOT"' EXIT
export_test_paths "$TEST_ROOT"

RUN_A='123e4567-e89b-42d3-a456-426614174051'
RUN_B='123e4567-e89b-42d3-a456-426614174052'
BOOT_ID='123e4567-e89b-42d3-a456-426614174053'
ACCOUNT='Route test|alice|route-secret|vpn.example.test||nc'
MOCK_BIN="${TEST_ROOT}/mock-bin"
export MOCK_IP_LOG="${TEST_ROOT}/ip.calls"
export MOCK_IP_ARGV_LOG="${TEST_ROOT}/ip.argv"
export MOCK_RM_LOG="${TEST_ROOT}/rm.calls"
export MOCK_OPENCONNECT_ARGS="${TEST_ROOT}/openconnect.argv"
export MOCK_OPENCONNECT_PASSWORD="${TEST_ROOT}/openconnect.password"
export MOCK_DEFAULT4="${TEST_ROOT}/default4"
export MOCK_DEFAULT6="${TEST_ROOT}/default6"
export MOCK_ADDR4="${TEST_ROOT}/addr4"
export MOCK_ADDR6="${TEST_ROOT}/addr6"
export MOCK_RULE4="${TEST_ROOT}/rule4"
export MOCK_RULE6="${TEST_ROOT}/rule6"
export MOCK_TABLE4="${TEST_ROOT}/table4"
export MOCK_TABLE6="${TEST_ROOT}/table6"
export MOCK_LINKS="${TEST_ROOT}/links"
export MOCK_IP_FAIL_STAGE=''
export MOCK_IPV6_TABLE_MISSING=0
export MOCK_EXPECT_APPLY_ORDER=0
export MOCK_ROUTE_GET4_DEV='eth0'
export MOCK_ROUTE_GET6_DEV='eth0'
export MOCK_RM_FAIL_TARGET=''
mkdir -p -- "$MOCK_BIN" "$OCM_CONFIG_DIR" "$OCM_RUNTIME_DIR" \
  "$(dirname -- "$OCM_STATE_LOCK_FILE")" "$(dirname -- "$OCM_BOOT_ID_FILE")"
printf '%s\n' "$BOOT_ID" > "$OCM_BOOT_ID_FILE"
printf '%s\n' "$RUN_A" > "$OCM_UUID_FILE"

cat > "${MOCK_BIN}/ip" <<'MOCK_IP'
#!/usr/bin/env bash
set -u

printf '%s\n' "$*" >> "$MOCK_IP_LOG"
{
  for argument in "$@"; do printf '<%s>' "$argument"; done
  printf '\n'
} >> "$MOCK_IP_ARGV_LOG"

delete_rule_for_source() {
  local source_file="$1" source="$2" temporary_file
  temporary_file="${source_file}.tmp"
  awk -v source="$source" '$0 !~ (" from " source "([/[:space:]]|$)") { print }' \
    "$source_file" > "$temporary_file" || exit 1
  mv -f -- "$temporary_file" "$source_file"
}

case "$*" in
  '-4 route show default') cat "$MOCK_DEFAULT4" ;;
  '-6 route show default') cat "$MOCK_DEFAULT6" ;;
  '-4 -o addr show scope global') cat "$MOCK_ADDR4" ;;
  '-6 -o addr show scope global')
    [ "$MOCK_IP_FAIL_STAGE" != 'read-addr6' ] || exit 91
    cat "$MOCK_ADDR6"
    ;;
  '-4 rule show') cat "$MOCK_RULE4" ;;
  '-6 rule show') cat "$MOCK_RULE6" ;;
  '-4 route show table 51888') cat "$MOCK_TABLE4" ;;
  '-6 route show table 51889')
    if [ "$MOCK_IPV6_TABLE_MISSING" = 1 ]; then
      printf '%s\n' 'Error: ipv6: FIB table does not exist.' 'Dump terminated' >&2
      exit 2
    fi
    cat "$MOCK_TABLE6"
    ;;
  '-o link show') cat "$MOCK_LINKS" ;;
  'link show dev ocm0')
    grep -Eq '^[[:space:]]*[0-9]+:[[:space:]]+ocm0(:|@)' "$MOCK_LINKS"
    ;;
  '-4 route replace table 51888 '*)
    [ -f "$OCM_ROUTE_OWNER_FILE" ] || exit 97
    [ "$MOCK_IP_FAIL_STAGE" != 'apply-table4' ] || exit 91
    shift 5
    printf '%s\n' "$*" > "$MOCK_TABLE4"
    ;;
  '-6 route replace table 51889 '*)
    [ -f "$OCM_ROUTE_OWNER_FILE" ] || exit 97
    [ "$MOCK_IP_FAIL_STAGE" != 'apply-table6' ] || exit 91
    shift 5
    printf '%s\n' "$*" > "$MOCK_TABLE6"
    ;;
  '-4 rule add priority 10000 from '*'/32 lookup 51888')
    [ -s "$MOCK_TABLE4" ] || exit 98
    [ "$MOCK_IP_FAIL_STAGE" != 'apply-rule4' ] || exit 91
    printf '10000: from %s lookup 51888\n' "$7" >> "$MOCK_RULE4"
    ;;
  '-6 rule add priority 10001 from '*'/128 lookup 51889')
    [ -s "$MOCK_TABLE6" ] || exit 98
    [ "$MOCK_IP_FAIL_STAGE" != 'apply-rule6' ] || exit 91
    printf '10001: from %s lookup 51889\n' "$7" >> "$MOCK_RULE6"
    ;;
  '-4 rule del priority 10000 from '*'/32 lookup 51888')
    [ "$MOCK_IP_FAIL_STAGE" != 'cleanup-rule4' ] || exit 91
    [ "$MOCK_IP_FAIL_STAGE" = 'cleanup-rule4-noeffect' ] \
      || delete_rule_for_source "$MOCK_RULE4" "${7%/32}"
    ;;
  '-6 rule del priority 10001 from '*'/128 lookup 51889')
    [ "$MOCK_IP_FAIL_STAGE" != 'cleanup-rule6' ] || exit 91
    [ "$MOCK_IP_FAIL_STAGE" = 'cleanup-rule6-noeffect' ] \
      || delete_rule_for_source "$MOCK_RULE6" "${7%/128}"
    ;;
  '-4 rule del priority 10000 lookup 51888')
    [ "$MOCK_IP_FAIL_STAGE" != 'legacy-rule4' ] || exit 91
    grep -Ev '^[[:space:]]*10000:|lookup 51888([[:space:]]|$)' "$MOCK_RULE4" > "${MOCK_RULE4}.tmp"
    mv -f -- "${MOCK_RULE4}.tmp" "$MOCK_RULE4"
    ;;
  '-6 rule del priority 10001 lookup 51889')
    [ "$MOCK_IP_FAIL_STAGE" != 'legacy-rule6' ] || exit 91
    grep -Ev '^[[:space:]]*10001:|lookup 51889([[:space:]]|$)' "$MOCK_RULE6" > "${MOCK_RULE6}.tmp"
    mv -f -- "${MOCK_RULE6}.tmp" "$MOCK_RULE6"
    ;;
  '-4 route flush table 51888')
    [ "$MOCK_IP_FAIL_STAGE" != 'cleanup-table4' ] || exit 91
    [ "$MOCK_IP_FAIL_STAGE" = 'cleanup-table4-noeffect' ] || : > "$MOCK_TABLE4"
    ;;
  '-6 route flush table 51889')
    [ "$MOCK_IP_FAIL_STAGE" != 'cleanup-table6' ] || exit 91
    [ "$MOCK_IP_FAIL_STAGE" = 'cleanup-table6-noeffect' ] || : > "$MOCK_TABLE6"
    ;;
  'link del dev ocm0')
    [ "$MOCK_IP_FAIL_STAGE" != 'cleanup-link' ] || exit 91
    if [ "$MOCK_IP_FAIL_STAGE" != 'cleanup-link-noeffect' ]; then
      grep -Ev '^[[:space:]]*[0-9]+:[[:space:]]+ocm0(:|@)' "$MOCK_LINKS" > "${MOCK_LINKS}.tmp"
      mv -f -- "${MOCK_LINKS}.tmp" "$MOCK_LINKS"
    fi
    ;;
  '-4 route replace default '*)
    shift 3
    if [ "$MOCK_IP_FAIL_STAGE" = 'restore-default4-after-apply' ]; then
      printf '%s\n' "$*" > "$MOCK_DEFAULT4"
      exit 91
    fi
    [ "$MOCK_IP_FAIL_STAGE" != 'restore-default4' ] || exit 91
    [ "$MOCK_IP_FAIL_STAGE" = 'restore-default4-noeffect' ] \
      || printf '%s\n' "$*" > "$MOCK_DEFAULT4"
    ;;
  '-6 route replace default '*)
    shift 3
    [ "$MOCK_IP_FAIL_STAGE" != 'restore-default6' ] || exit 91
    [ "$MOCK_IP_FAIL_STAGE" = 'restore-default6-noeffect' ] \
      || printf '%s\n' "$*" > "$MOCK_DEFAULT6"
    ;;
  '-4 route get '*' from '*)
    [ "$MOCK_IP_FAIL_STAGE" != 'route-get4' ] || exit 91
    if [ "$MOCK_EXPECT_APPLY_ORDER" = 1 ]; then
      grep -F " from $6/32 " "$MOCK_RULE4" >/dev/null || exit 99
    fi
    printf '%s from %s via 192.0.2.1 dev %s src %s\n' "$4" "$6" "$MOCK_ROUTE_GET4_DEV" "$6"
    ;;
  '-6 route get '*' from '*)
    [ "$MOCK_IP_FAIL_STAGE" != 'route-get6' ] || exit 91
    if [ "$MOCK_EXPECT_APPLY_ORDER" = 1 ]; then
      grep -F " from $6/128 " "$MOCK_RULE6" >/dev/null || exit 99
    fi
    printf '%s from %s via 2001:db8::1 dev %s src %s\n' "$4" "$6" "$MOCK_ROUTE_GET6_DEV" "$6"
    ;;
  *)
    printf 'unexpected mock ip call: %s\n' "$*" >&2
    exit 96
    ;;
esac
MOCK_IP
chmod 0700 "${MOCK_BIN}/ip"

cat > "${MOCK_BIN}/rm" <<'MOCK_RM'
#!/usr/bin/env bash
set -u

printf '%s\n' "$*" >> "$MOCK_RM_LOG"
if [ -z "${MOCK_RM_FAIL_TARGET:-}" ]; then
  exec /usr/bin/rm "$@"
fi

for argument in "$@"; do
  case "$argument" in
    -*) continue ;;
  esac
  if [ "$argument" = "$MOCK_RM_FAIL_TARGET" ]; then exit 91; fi
  /usr/bin/rm -f -- "$argument" || exit 1
done
MOCK_RM
chmod 0700 "${MOCK_BIN}/rm"

cat > "${MOCK_BIN}/openconnect" <<'MOCK_OPENCONNECT'
#!/usr/bin/env bash
set -u

if [ "${1:-}" = '--help' ]; then
  printf '%s\n' '  --tcp-keepalive=INT'
  exit 0
fi
{
  for argument in "$@"; do printf '<%s>' "$argument"; done
  printf '\n'
} >> "$MOCK_OPENCONNECT_ARGS"
cat > "$MOCK_OPENCONNECT_PASSWORD"
MOCK_OPENCONNECT
chmod 0700 "${MOCK_BIN}/openconnect"
PATH="${MOCK_BIN}:/usr/bin:/bin:${PATH}"
export PATH

# shellcheck source=../oc_master.sh
source ./oc_master.sh

if ! command -v flock >/dev/null 2>&1; then
  flock() { return 0; }
fi
ensure_dirs() {
  mkdir -p -- "$CONFIG_DIR" "$RUNTIME_DIR" "${STATE_LOCK_FILE%/*}" "${SERVICE_LOCK_FILE%/*}"
}

reset_network() {
  export MOCK_IP_FAIL_STAGE=''
  export MOCK_IPV6_TABLE_MISSING=0
  export MOCK_EXPECT_APPLY_ORDER=0
  export MOCK_ROUTE_GET4_DEV='eth0'
  export MOCK_ROUTE_GET6_DEV='eth0'
  export MOCK_RM_FAIL_TARGET=''
  printf '%s\n' 'default via 192.0.2.1 dev eth0 metric 100' > "$MOCK_DEFAULT4"
  : > "$MOCK_DEFAULT6"
  printf '%s\n' '2: eth0 inet 192.0.2.10/24 scope global eth0' > "$MOCK_ADDR4"
  : > "$MOCK_ADDR6"
  printf '%s\n' \
    '0: from all lookup local' \
    '32766: from all lookup main' \
    '32767: from all lookup default' > "$MOCK_RULE4"
  printf '%s\n' \
    '0: from all lookup local' \
    '32766: from all lookup main' > "$MOCK_RULE6"
  : > "$MOCK_TABLE4"
  : > "$MOCK_TABLE6"
  printf '%s\n' '2: eth0: <BROADCAST,MULTICAST,UP> mtu 1500' > "$MOCK_LINKS"
  : > "$MOCK_IP_LOG"
  : > "$MOCK_IP_ARGV_LOG"
  : > "$MOCK_RM_LOG"
  : > "$MOCK_OPENCONNECT_ARGS"
  : > "$MOCK_OPENCONNECT_PASSWORD"
  rm -f -- "$ROUTE_PLAN_FILE" "$ROUTE_OWNER_FILE"
}

write_global_runtime() {
  local run_id="$1" phase="${2:-PREPARING}"
  write_active_run "$run_id" "$BOOT_ID" global 0 nc '' "$ACCOUNT"
  write_run_state "$run_id" "$phase" 1 0
}

assert_no_network_writes() {
  local message="$1"
  if grep -Eq '(^| )(add|replace|del|flush)( |$)' "$MOCK_IP_LOG"; then
    fail "$message"
  fi
}

assert_build_rejected() {
  local message="$1"
  : > "$MOCK_IP_LOG"
  if build_route_plan "$RUN_A" >/dev/null 2>&1; then
    fail "$message"
  fi
  assert_no_network_writes "$message modified network state"
}

prepare_dual_plan() {
  reset_network
  printf '%s\n' 'default via 2001:db8::1 dev eth0 metric 100' > "$MOCK_DEFAULT6"
  printf '%s\n' '2: eth0 inet6 2001:db8::10/64 scope global eth0' > "$MOCK_ADDR6"
  write_global_runtime "$RUN_A" PREPARING
  build_route_plan "$RUN_A"
  write_route_plan "$RUN_A"
  write_run_state "$RUN_A" STARTING 1 0
}

assert_recovery_evidence_retained() {
  local message="$1"
  [ -f "$ROUTE_PLAN_FILE" ] || fail "$message removed route plan"
  [ -f "$ROUTE_OWNER_FILE" ] || fail "$message removed route owner"
}

# A single IPv4 default produces a strict, read-only plan.
reset_network
write_global_runtime "$RUN_A"
build_route_plan "$RUN_A" || fail 'single-IPv4 route plan was rejected'
assert_no_network_writes 'route-plan build performed a network write'
write_route_plan "$RUN_A" || fail 'single-IPv4 route plan could not be written'
assert_file_mode "$ROUTE_PLAN_FILE" 600
load_route_plan "$RUN_A" || fail 'written single-IPv4 route plan was not parseable'
assert_eq 'default via 192.0.2.1 dev eth0 metric 100' "$ROUTE_PLAN_DEFAULT4" 'saved IPv4 default changed'
assert_eq 'eth0' "$ROUTE_PLAN_DEV4" 'saved IPv4 device changed'
assert_eq '1' "${#ROUTE_PLAN_RETURN4_ADDRESSES[@]}" 'single IPv4 address count changed'
assert_eq '192.0.2.10' "${ROUTE_PLAN_RETURN4_ADDRESSES[0]}" 'saved IPv4 address changed'
assert_eq '' "$ROUTE_PLAN_DEFAULT6" 'absent IPv6 default became populated'

# Multiple addresses on one egress are allowed and duplicate addresses are canonicalized.
reset_network
printf '%s\n' \
  '2: eth0 inet 192.0.2.10/24 scope global eth0' \
  '2: eth0 inet 192.0.2.11/24 scope global secondary eth0' \
  '2: eth0 inet 192.0.2.10/24 scope global eth0' > "$MOCK_ADDR4"
write_global_runtime "$RUN_A"
build_route_plan "$RUN_A"
write_route_plan "$RUN_A"
load_route_plan "$RUN_A"
assert_eq '2' "${#ROUTE_PLAN_RETURN4_ADDRESSES[@]}" 'same-device IPv4 addresses were not deduplicated'
assert_eq '192.0.2.10' "${ROUTE_PLAN_RETURN4_ADDRESSES[0]}" 'first IPv4 address order changed'
assert_eq '192.0.2.11' "${ROUTE_PLAN_RETURN4_ADDRESSES[1]}" 'second IPv4 address order changed'

# IPv4 and IPv6 plans coexist; a missing empty IPv6 FIB table is not a conflict.
reset_network
printf '%s\n' 'default via 2001:db8::1 dev eth0 metric 100' > "$MOCK_DEFAULT6"
printf '%s\n' '2: eth0 inet6 2001:db8::10/64 scope global eth0' > "$MOCK_ADDR6"
write_global_runtime "$RUN_A"
build_route_plan "$RUN_A"
write_route_plan "$RUN_A"
load_route_plan "$RUN_A"
assert_eq 'default via 2001:db8::1 dev eth0 metric 100' "$ROUTE_PLAN_DEFAULT6" 'saved IPv6 default changed'
assert_eq '2001:db8::10' "${ROUTE_PLAN_RETURN6_ADDRESSES[0]}" 'saved IPv6 address changed'

reset_network
export MOCK_IPV6_TABLE_MISSING=1
write_global_runtime "$RUN_A"
build_route_plan "$RUN_A" || fail 'missing IPv6 FIB table was treated as a conflict'
assert_no_network_writes 'missing IPv6 FIB handling wrote network state'

# Unsupported or ambiguous topology is rejected before any network mutation.
reset_network
printf '%s\n' '2: eth0 inet6 2001:db8::10/64 scope global eth0' > "$MOCK_ADDR6"
write_global_runtime "$RUN_A"
assert_build_rejected 'global IPv6 address without an IPv6 default was accepted'

reset_network
write_global_runtime "$RUN_A"
export MOCK_IP_FAIL_STAGE='read-addr6'
: > "$MOCK_IP_LOG"
IPV6_QUERY_BUILD_SUCCEEDED=0
if build_route_plan "$RUN_A" >/dev/null 2>&1; then
  IPV6_QUERY_BUILD_SUCCEEDED=1
fi
assert_no_network_writes 'failed IPv6 global-address query modified network state'
[ "$IPV6_QUERY_BUILD_SUCCEEDED" -eq 0 ] \
  || fail 'failed IPv6 global-address query was treated as empty IPv6 state'

reset_network
printf '%s\n' \
  'default via 192.0.2.1 dev eth0 metric 100' \
  'default via 198.51.100.1 dev eth1 metric 200' > "$MOCK_DEFAULT4"
assert_build_rejected 'multiple non-VPN defaults were accepted'

reset_network
printf '%s\n' 'default proto static metric 100 nexthop via 192.0.2.1 dev eth0 weight 1 nexthop via 198.51.100.1 dev eth1 weight 1' > "$MOCK_DEFAULT4"
assert_build_rejected 'ECMP/nexthop default was accepted'

for route_type in blackhole unreachable prohibit; do
  reset_network
  printf '%s\n' "$route_type default metric 42760" > "$MOCK_DEFAULT4"
  assert_build_rejected "$route_type default was accepted"
done

reset_network
printf '%s\n' 'default via 192.0.2.1 metric 100' > "$MOCK_DEFAULT4"
assert_build_rejected 'default route without dev was accepted'

reset_network
printf '%s\n' \
  '2: eth0 inet 192.0.2.10/24 scope global eth0' \
  '3: eth1 inet 198.51.100.10/24 scope global eth1' > "$MOCK_ADDR4"
assert_build_rejected 'global addresses split across interfaces were accepted'

reset_network
printf '%s\n' '10000: from all lookup main' > "$MOCK_RULE4"
assert_build_rejected 'reserved IPv4 rule priority was accepted'

reset_network
printf '%s\n' '12000: from 192.0.2.10 lookup 51888' > "$MOCK_RULE4"
assert_build_rejected 'reserved IPv4 route table lookup was accepted'

reset_network
printf '%s\n' '100: from 192.0.2.10 lookup 100' >> "$MOCK_RULE4"
assert_build_rejected 'foreign source-specific IPv4 rule was accepted'

reset_network
printf '\n\n' >> "$MOCK_RULE4"
write_global_runtime "$RUN_A"
build_route_plan "$RUN_A" || fail 'blank policy-rule output lines were rejected'
assert_no_network_writes 'blank policy-rule output lines modified network state'

reset_network
printf '%s\n' 'default via 192.0.2.1 dev eth0' > "$MOCK_TABLE4"
assert_build_rejected 'occupied IPv4 route table was accepted'

reset_network
printf '%s\n' \
  '2: eth0: <BROADCAST,MULTICAST,UP> mtu 1500' \
  '9: ocm0: <POINTOPOINT,UP> mtu 1400' > "$MOCK_LINKS"
assert_build_rejected 'occupied VPN link was accepted'

reset_network
printf '%s\n' 'unparseable policy rule' > "$MOCK_RULE4"
assert_build_rejected 'unparseable policy-rule state was accepted'

# The plan parser rejects mismatch, malformed scalar fields, and unknown keys.
reset_network
write_global_runtime "$RUN_A"
build_route_plan "$RUN_A"
write_route_plan "$RUN_A"
if load_route_plan "$RUN_B" >/dev/null 2>&1; then
  fail 'route plan matched the wrong RUN_ID'
fi
if validate_route_plan_against_snapshot "$RUN_B" >/dev/null 2>&1; then
  fail 'route plan validated against the wrong snapshot generation'
fi
cp -- "$ROUTE_PLAN_FILE" "${ROUTE_PLAN_FILE}.valid"
printf '%s\n' 'UNKNOWN=value' >> "$ROUTE_PLAN_FILE"
if load_route_plan "$RUN_A" >/dev/null 2>&1; then fail 'route plan accepted an unknown key'; fi
cp -- "${ROUTE_PLAN_FILE}.valid" "$ROUTE_PLAN_FILE"
printf '%s\n' 'DEV4=eth0' >> "$ROUTE_PLAN_FILE"
if load_route_plan "$RUN_A" >/dev/null 2>&1; then fail 'route plan accepted a duplicate scalar'; fi
grep -v '^DEV4=' "${ROUTE_PLAN_FILE}.valid" > "$ROUTE_PLAN_FILE"
if load_route_plan "$RUN_A" >/dev/null 2>&1; then fail 'route plan accepted a missing scalar'; fi
sed 's/^RETURN4_ADDRESS=.*/RETURN4_ADDRESS=999.0.0.1/' "${ROUTE_PLAN_FILE}.valid" > "$ROUTE_PLAN_FILE"
if load_route_plan "$RUN_A" >/dev/null 2>&1; then fail 'route plan accepted an invalid IPv4 address'; fi
cp -- "${ROUTE_PLAN_FILE}.valid" "$ROUTE_PLAN_FILE"
printf '%s\n' 'RETURN6_ADDRESS=not::ipv6' >> "$ROUTE_PLAN_FILE"
if load_route_plan "$RUN_A" >/dev/null 2>&1; then fail 'route plan accepted an invalid IPv6 address'; fi
sed -e 's/^DEFAULT4=.*/DEFAULT4=default via 192.0.2.1 dev eth0 nexthop via 198.51.100.1/' \
  "${ROUTE_PLAN_FILE}.valid" > "$ROUTE_PLAN_FILE"
if load_route_plan "$RUN_A" >/dev/null 2>&1; then fail 'route plan accepted a malformed IPv4 default'; fi
sed -e 's/^DEFAULT4=.*/DEFAULT4=default via 192.0.2.1 dev bad\/dev/' \
  -e 's/^DEV4=.*/DEV4=bad\/dev/' "${ROUTE_PLAN_FILE}.valid" > "$ROUTE_PLAN_FILE"
if load_route_plan "$RUN_A" >/dev/null 2>&1; then fail 'route plan accepted an invalid device token'; fi
sed 's/$/\r/' "${ROUTE_PLAN_FILE}.valid" > "$ROUTE_PLAN_FILE"
if load_route_plan "$RUN_A" >/dev/null 2>&1; then fail 'route plan accepted CR-terminated fields'; fi
cp -- "${ROUTE_PLAN_FILE}.valid" "$ROUTE_PLAN_FILE"
printf '%s\n' 'RETURN4_ADDRESS=192.0.2.10' >> "$ROUTE_PLAN_FILE"
load_route_plan "$RUN_A" || fail 'route plan rejected duplicate address canonicalization'
assert_eq '1' "${#ROUTE_PLAN_RETURN4_ADDRESSES[@]}" 'route plan duplicate IPv4 address was not deduplicated'

# route-get verification compares the device as an exact token, not as a regular expression.
reset_network
export MOCK_ROUTE_GET4_DEV='ethX0'
if route_get_uses_device -4 1.1.1.1 192.0.2.10 'eth.0'; then
  fail 'route-get accepted a regex-only device match'
fi

# Apply records ownership first, installs tables before exact rules, and verifies every source route.
prepare_dual_plan
write_active_run "$RUN_B" "$BOOT_ID" global 0 nc '' "$ACCOUNT"
write_run_state "$RUN_B" STARTING 1 0
: > "$MOCK_IP_LOG"
if apply_route_plan "$RUN_A" >/dev/null 2>&1; then
  fail 'route plan applied after the runtime RUN_ID changed'
fi
[ ! -e "$ROUTE_OWNER_FILE" ] || fail 'RUN_ID mismatch created a false owner marker'
assert_no_network_writes 'RUN_ID mismatch modified network state'

assert_apply_topology_drift_rejected() {
  local message="$1"
  : > "$MOCK_IP_LOG"
  if apply_route_plan "$RUN_A" >/dev/null 2>&1; then
    fail "$message"
  fi
  [ ! -e "$ROUTE_OWNER_FILE" ] || fail "$message created a false owner marker"
  assert_no_network_writes "$message modified network state"
}

# The worker must revalidate the complete live topology immediately before
# recording ownership or mutating any route object.
prepare_dual_plan
printf '%s\n' 'default via 198.51.100.1 dev eth1 metric 200' >> "$MOCK_DEFAULT4"
assert_apply_topology_drift_rejected 'apply accepted a newly added second default'

prepare_dual_plan
printf '%s\n' '2: eth0 inet 192.0.2.11/24 scope global secondary eth0' >> "$MOCK_ADDR4"
assert_apply_topology_drift_rejected 'apply accepted a newly added egress address'

prepare_dual_plan
printf '%s\n' '3: eth1 inet 198.51.100.10/24 scope global eth1' >> "$MOCK_ADDR4"
assert_apply_topology_drift_rejected 'apply accepted a newly added foreign-interface address'

prepare_dual_plan
printf '%s\n' 'default proto static metric 100 nexthop via 192.0.2.1 dev eth0 weight 1 nexthop via 198.51.100.1 dev eth1 weight 1' > "$MOCK_DEFAULT4"
assert_apply_topology_drift_rejected 'apply accepted an ECMP default replacing the planned default'

# Keep IPv4 unchanged: these independently prove that IPv6 topology is checked
# before owner creation or any route mutation.
prepare_dual_plan
printf '%s\n' 'default proto static metric 100 nexthop via 2001:db8::1 dev eth0 weight 1 nexthop via 2001:db8::2 dev eth1 weight 1' > "$MOCK_DEFAULT6"
assert_apply_topology_drift_rejected 'apply accepted an IPv6 ECMP default replacing the planned default'

prepare_dual_plan
printf '%s\n' '2: eth0 inet6 2001:db8::11/64 scope global secondary eth0' >> "$MOCK_ADDR6"
assert_apply_topology_drift_rejected 'apply accepted a newly added IPv6 global address'

prepare_dual_plan
printf '%s\n' 'default via 198.51.100.1 dev eth1 metric 100' > "$MOCK_DEFAULT4"
printf '%s\n' '3: eth1 inet 192.0.2.10/24 scope global eth1' > "$MOCK_ADDR4"
printf '%s\n' '3: eth1 inet6 2001:db8::10/64 scope global eth1' > "$MOCK_ADDR6"
assert_apply_topology_drift_rejected 'apply accepted a changed egress default'

prepare_dual_plan
if (
  atomic_replace_from_stdin() {
    [ "$1" != "$ROUTE_OWNER_FILE" ] || return 1
    return 99
  }
  apply_route_plan "$RUN_A" >/dev/null 2>&1
); then
  fail 'owner write failure returned success'
fi
[ -f "$ROUTE_PLAN_FILE" ] || fail 'owner write failure removed route plan'
[ ! -e "$ROUTE_OWNER_FILE" ] || fail 'owner write failure created a false owner marker'

for fail_stage in apply-table4 apply-rule4 route-get4 apply-table6 apply-rule6 route-get6; do
  prepare_dual_plan
  export MOCK_EXPECT_APPLY_ORDER=1
  export MOCK_IP_FAIL_STAGE="$fail_stage"
  if apply_route_plan "$RUN_A" >/dev/null 2>&1; then
    fail "apply failure stage $fail_stage returned success"
  fi
  assert_recovery_evidence_retained "apply failure stage $fail_stage"
done

prepare_dual_plan
export MOCK_EXPECT_APPLY_ORDER=1
apply_route_plan "$RUN_A" || fail 'valid dual-stack route plan could not be applied'
assert_recovery_evidence_retained 'successful apply'
grep -Fx '<-4><rule><add><priority><10000><from><192.0.2.10/32><lookup><51888>' "$MOCK_IP_ARGV_LOG" >/dev/null \
  || fail 'IPv4 policy-rule argv was not preserved exactly'
grep -Fx '<-4><route><replace><table><51888><default><via><192.0.2.1><dev><eth0><metric><100>' "$MOCK_IP_ARGV_LOG" >/dev/null \
  || fail 'IPv4 policy-table argv was not preserved exactly'
assert_file_mode "$ROUTE_OWNER_FILE" 600
grep -Fx 'DEFAULT4=default via 192.0.2.1 dev eth0 metric 100' "$ROUTE_OWNER_FILE" >/dev/null \
  || fail 'owner marker did not preserve the IPv4 default'
grep -Fx 'DEFAULT6=default via 2001:db8::1 dev eth0 metric 100' "$ROUTE_OWNER_FILE" >/dev/null \
  || fail 'owner marker did not preserve the IPv6 default'

# A persisted plan without an owner proves apply never began; cleanup remains read-only.
prepare_dual_plan
: > "$MOCK_IP_LOG"
cleanup_route_plan "$RUN_A" || fail 'verified pre-apply plan cleanup failed'
assert_no_network_writes 'pre-apply plan cleanup modified network state'
[ ! -e "$ROUTE_PLAN_FILE" ] || fail 'verified pre-apply cleanup retained route plan'

prepare_dual_plan
: > "$MOCK_IP_LOG"
export MOCK_IP_FAIL_STAGE='route-get4'
if cleanup_route_plan "$RUN_A" >/dev/null 2>&1; then
  fail 'unverified pre-apply plan cleanup returned success'
fi
assert_no_network_writes 'failed pre-apply cleanup modified network state'
[ -e "$ROUTE_PLAN_FILE" ] || fail 'failed pre-apply cleanup removed route plan evidence'
[ ! -e "$ROUTE_OWNER_FILE" ] || fail 'failed pre-apply cleanup fabricated route ownership'

# Cleanup failures retain both artifacts, including failures detected only by post-verification.
prepare_applied_dual_plan() {
  prepare_dual_plan
  export MOCK_EXPECT_APPLY_ORDER=1
  apply_route_plan "$RUN_A"
  export MOCK_EXPECT_APPLY_ORDER=0
  printf '%s\n' \
    '2: eth0: <BROADCAST,MULTICAST,UP> mtu 1500' \
    '9: ocm0: <POINTOPOINT,UP> mtu 1400' > "$MOCK_LINKS"
  : > "$MOCK_IP_LOG"
}

for fail_stage in cleanup-rule4 cleanup-rule6 cleanup-table4 cleanup-table6 cleanup-link route-get4 route-get6; do
  prepare_applied_dual_plan
  export MOCK_IP_FAIL_STAGE="$fail_stage"
  if cleanup_route_plan "$RUN_A" >/dev/null 2>&1; then
    fail "cleanup failure stage $fail_stage returned success"
  fi
  assert_recovery_evidence_retained "cleanup failure stage $fail_stage"
done

prepare_applied_dual_plan
: > "$MOCK_DEFAULT4"
export MOCK_IP_FAIL_STAGE='restore-default4'
if cleanup_route_plan "$RUN_A" >/dev/null 2>&1; then
  fail 'failed default restoration returned success'
fi
assert_recovery_evidence_retained 'failed default restoration'

# A failed default restore command is idempotent only when a fresh read proves
# the non-VPN default was nevertheless restored.
prepare_applied_dual_plan
: > "$MOCK_DEFAULT4"
export MOCK_IP_FAIL_STAGE='restore-default4-after-apply'
cleanup_route_plan "$RUN_A" || fail 'verified default restoration after command failure was rejected'
[ ! -e "$ROUTE_PLAN_FILE" ] || fail 'verified default restoration retained route plan'
[ ! -e "$ROUTE_OWNER_FILE" ] || fail 'verified default restoration retained owner marker'

for fail_stage in cleanup-rule4-noeffect cleanup-table4-noeffect cleanup-link-noeffect restore-default4-noeffect; do
  prepare_applied_dual_plan
  if [ "$fail_stage" = restore-default4-noeffect ]; then : > "$MOCK_DEFAULT4"; fi
  export MOCK_IP_FAIL_STAGE="$fail_stage"
  if cleanup_route_plan "$RUN_A" >/dev/null 2>&1; then
    fail "cleanup residual stage $fail_stage returned success"
  fi
  assert_recovery_evidence_retained "cleanup residual stage $fail_stage"
done

prepare_applied_dual_plan
cleanup_route_plan "$RUN_A" || fail 'verified cleanup rejected a valid applied plan'
[ ! -e "$ROUTE_PLAN_FILE" ] || fail 'verified cleanup retained route plan'
[ ! -e "$ROUTE_OWNER_FILE" ] || fail 'verified cleanup retained owner marker'
[ "$(grep -Fc -- '-4 rule del priority 10000 from 192.0.2.10/32 lookup 51888' "$MOCK_IP_LOG")" -eq 1 ] \
  || fail 'cleanup did not delete the exact IPv4 source rule once'
[ "$(grep -Fc -- '-6 rule del priority 10001 from 2001:db8::10/128 lookup 51889' "$MOCK_IP_LOG")" -eq 1 ] \
  || fail 'cleanup did not delete the exact IPv6 source rule once'

# An active-generation ExecStopPost cleans network state but keeps its immutable
# plan so Restart=always can establish owner evidence and reapply it.
prepare_applied_dual_plan
printf '%s\n' "$RUN_A" > "$SERVICE_RUN_ID_FILE"
cleanup_run_generation "$RUN_A" || fail 'unexpected-exit cleanup failed'
return_route_state_is_clean || fail 'unexpected-exit cleanup left route resources behind'
[ ! -e "$ROUTE_OWNER_FILE" ] || fail 'unexpected-exit cleanup retained owner evidence'
[ -f "$ROUTE_PLAN_FILE" ] || fail 'unexpected-exit cleanup deleted the restart route plan'
[ ! -e "$SERVICE_RUN_ID_FILE" ] || fail 'unexpected-exit cleanup retained service generation marker'
: > "$MOCK_IP_ARGV_LOG"
(
  check_root() { :; }
  service_run
) || fail 'Restart=always worker did not reapply the retained route plan'
[ -f "$ROUTE_OWNER_FILE" ] || fail 'Restart=always worker did not recreate owner evidence'
grep -F '<--interface=ocm0>' "$MOCK_OPENCONNECT_ARGS" >/dev/null \
  || fail 'Restart=always worker lost the global OpenConnect interface argument'
grep -F '<--protocol=nc>' "$MOCK_OPENCONNECT_ARGS" >/dev/null \
  || fail 'Restart=always worker lost the OpenConnect protocol argument'
assert_eq 'route-secret' "$(cat "$MOCK_OPENCONNECT_PASSWORD")" \
  'Restart=always worker lost the OpenConnect password stdin input'

# An explicit inactive stop consumes both new-format artifacts after cleanup.
prepare_applied_dual_plan
write_run_state "$RUN_A" STOPPING 0 0
printf '%s\n' "$RUN_A" > "$SERVICE_RUN_ID_FILE"
cleanup_run_generation "$RUN_A" || fail 'inactive stop cleanup failed'
[ ! -e "$ROUTE_OWNER_FILE" ] || fail 'inactive stop cleanup retained owner evidence'
[ ! -e "$ROUTE_PLAN_FILE" ] || fail 'inactive stop cleanup retained route plan'
load_run_state || fail 'inactive stop removed its run state'
assert_eq CLEANED "$PHASE" 'inactive stop did not record CLEANED'

# New-format evidence is removed owner-first.  A failed owner unlink retains
# the plan, so retry cannot take the broad legacy cleanup path.
prepare_applied_dual_plan
: > "$MOCK_RM_LOG"
export MOCK_RM_FAIL_TARGET="$ROUTE_OWNER_FILE"
if cleanup_route_plan "$RUN_A" >/dev/null 2>&1; then
  fail 'owner unlink failure returned success'
fi
assert_eq "-f -- $ROUTE_OWNER_FILE" "$(sed -n '1p' "$MOCK_RM_LOG")" \
  'cleanup did not attempt owner evidence removal first'
[ -f "$ROUTE_OWNER_FILE" ] || fail 'owner unlink failure removed owner evidence'
[ -f "$ROUTE_PLAN_FILE" ] || fail 'owner unlink failure removed route plan evidence'
export MOCK_RM_FAIL_TARGET=''
: > "$MOCK_IP_LOG"
cleanup_route_plan "$RUN_A" || fail 'owner unlink failure retry did not finish'
if grep -Eq -- '-[46] rule del priority (10000|10001) lookup 5188[89]' "$MOCK_IP_LOG"; then
  fail 'owner unlink failure retry downgraded to legacy rule cleanup'
fi

# A failed plan unlink happens only after owner deletion.  The remaining plan
# is read-only evidence on retry and must never trigger legacy network writes.
prepare_applied_dual_plan
: > "$MOCK_RM_LOG"
export MOCK_RM_FAIL_TARGET="$ROUTE_PLAN_FILE"
if cleanup_route_plan "$RUN_A" >/dev/null 2>&1; then
  fail 'plan unlink failure returned success'
fi
assert_eq "-f -- $ROUTE_OWNER_FILE" "$(sed -n '1p' "$MOCK_RM_LOG")" \
  'cleanup did not delete owner evidence before the route plan'
assert_eq "-f -- $ROUTE_PLAN_FILE" "$(sed -n '2p' "$MOCK_RM_LOG")" \
  'cleanup did not attempt route-plan deletion after owner evidence'
[ ! -e "$ROUTE_OWNER_FILE" ] || fail 'plan unlink failure retained owner evidence'
[ -f "$ROUTE_PLAN_FILE" ] || fail 'plan unlink failure removed route plan evidence'
export MOCK_RM_FAIL_TARGET=''
: > "$MOCK_IP_LOG"
cleanup_route_plan "$RUN_A" || fail 'plan unlink failure retry did not finish'
assert_no_network_writes 'plan-only cleanup retry performed network writes'

# A legacy owner without a new plan retains the bounded compatibility cleanup.
reset_network
printf '%s\n' \
  'DEFAULT4=default via 192.0.2.1 dev eth0 metric 100' \
  'DEFAULT6=' > "$ROUTE_OWNER_FILE"
cleanup_route_plan "$RUN_A" || fail 'legacy owner cleanup was not preserved'
[ ! -e "$ROUTE_OWNER_FILE" ] || fail 'verified legacy cleanup retained owner marker'

prepare_legacy_applied_state() {
  reset_network
  printf '%s\n' \
    'DEFAULT4=default via 192.0.2.1 dev eth0 metric 100' \
    'DEFAULT6=default via 2001:db8::1 dev eth0 metric 100' > "$ROUTE_OWNER_FILE"
  printf '%s\n' 'default via 2001:db8::1 dev eth0 metric 100' > "$MOCK_DEFAULT6"
  printf '%s\n' '10000: from 192.0.2.10 lookup 51888' >> "$MOCK_RULE4"
  printf '%s\n' '10001: from 2001:db8::10 lookup 51889' >> "$MOCK_RULE6"
  printf '%s\n' 'default via 192.0.2.1 dev eth0 metric 100' > "$MOCK_TABLE4"
  printf '%s\n' 'default via 2001:db8::1 dev eth0 metric 100' > "$MOCK_TABLE6"
  printf '%s\n' \
    '2: eth0: <BROADCAST,MULTICAST,UP> mtu 1500' \
    '9: ocm0: <POINTOPOINT,UP> mtu 1400' > "$MOCK_LINKS"
  : > "$MOCK_IP_LOG"
}

# A failed legacy rule delete is unresolved while that exact rule remains; cleanup stops there.
for fail_stage in legacy-rule4 legacy-rule6; do
  prepare_legacy_applied_state
  export MOCK_IP_FAIL_STAGE="$fail_stage"
  if cleanup_legacy_return_routes >/dev/null 2>&1; then
    fail "$fail_stage returned success with an owned rule still present"
  fi
  [ -e "$ROUTE_OWNER_FILE" ] || fail "$fail_stage removed legacy recovery evidence"
  if grep -Eq 'route flush table|link del dev|route replace default' "$MOCK_IP_LOG"; then
    fail "$fail_stage continued network mutation after an unresolved delete error"
  fi
done

# A legacy delete error is idempotent only when a fresh read proves the object was already absent.
reset_network
printf '%s\n' \
  'DEFAULT4=default via 192.0.2.1 dev eth0 metric 100' \
  'DEFAULT6=' > "$ROUTE_OWNER_FILE"
export MOCK_IP_FAIL_STAGE='legacy-rule4'
cleanup_legacy_return_routes || fail 'an already-absent legacy rule was treated as an unresolved delete failure'
[ ! -e "$ROUTE_OWNER_FILE" ] || fail 'idempotent legacy cleanup retained owner evidence'

prepare_legacy_applied_state
: > "$MOCK_DEFAULT4"
export MOCK_IP_FAIL_STAGE='restore-default4-after-apply'
cleanup_legacy_return_routes || fail 'legacy default restoration after command failure was rejected'
[ ! -e "$ROUTE_OWNER_FILE" ] || fail 'verified legacy default restoration retained owner evidence'

# Legacy owner evidence must be a regular, non-symlink file before any network mutation.
reset_network
LEGACY_OWNER_TARGET="${TEST_ROOT}/legacy-owner-target"
printf '%s\n' \
  'DEFAULT4=default via 192.0.2.1 dev eth0 metric 100' \
  'DEFAULT6=' > "$LEGACY_OWNER_TARGET"
if ln -s -- "$LEGACY_OWNER_TARGET" "$ROUTE_OWNER_FILE" 2>/dev/null && [ -L "$ROUTE_OWNER_FILE" ]; then
  : > "$MOCK_IP_LOG"
  if cleanup_legacy_return_routes >/dev/null 2>&1; then
    fail 'legacy cleanup accepted a symlink owner marker'
  fi
  assert_no_network_writes 'legacy symlink owner triggered network mutation'
  [ -L "$ROUTE_OWNER_FILE" ] || fail 'legacy symlink owner evidence was removed'
  rm -f -- "$ROUTE_OWNER_FILE"
fi

# Manager persists and reloads the read-only plan before PREPARING -> STARTING.
reset_network
rm -f -- "$ACTIVE_RUN_FILE" "$RUN_STATE_FILE" "$PROFILE_FILE"
PLAN_BEFORE_STARTING="${TEST_ROOT}/plan-before-starting"
if (
  ensure_dependencies() { :; }
  select_account() {
    export ACCOUNT_INDEX=0 VPN_PROTOCOL=nc ACCOUNT_RECORD="$ACCOUNT"
  }
  confirm_global_risk() { :; }
  confirm_service_replacement() { :; }
  prepare_runtime_configuration_for_start() { :; }
  prepare_service_replacement() { :; }
  install_self_and_units() { :; }
  transition_run_state() {
    [ "$2" = PREPARING ] && [ "$3" = STARTING ] || return 1
    load_route_plan "$1" || return 1
    assert_no_network_writes 'manager wrote network state before STARTING'
    : > "$PLAN_BEFORE_STARTING"
    write_run_state "$1" STARTING 1 0
  }
  arm_rollback() { return 1; }
  cleanup_start_attempt() { :; }
  log_err() { :; }
  log_warn() { :; }
  start_mode global </dev/null >/dev/null 2>&1
); then
  fail 'global start unexpectedly succeeded without rollback arming'
fi
[ -e "$PLAN_BEFORE_STARTING" ] || fail 'manager did not persist and reload route plan before STARTING'

# Worker apply and ExecStopPost cleanup both receive the exact service generation.
prepare_dual_plan
rm -f -- "$SERVICE_RUN_ID_FILE"
SERVICE_ROUTE_CALLS="${TEST_ROOT}/service-route.calls"
set +e
(
  check_root() { :; }
  apply_route_plan() { printf 'apply:%s\n' "$1" >> "$SERVICE_ROUTE_CALLS"; return 1; }
  setup_return_routes() { printf 'legacy-setup\n' >> "$SERVICE_ROUTE_CALLS"; return 1; }
  openconnect() { printf 'openconnect\n' >> "$SERVICE_ROUTE_CALLS"; return 1; }
  service_run >/dev/null 2>&1
)
SERVICE_ROUTE_RC=$?
set -e
[ "$SERVICE_ROUTE_RC" -ne 0 ] || fail 'worker ignored an apply_route_plan failure'
assert_eq "apply:$RUN_A" "$(cat "$SERVICE_ROUTE_CALLS" 2>/dev/null || true)" 'worker did not apply the exact generation plan'

write_global_runtime "$RUN_A" STOPPING
write_run_state "$RUN_A" STOPPING 0 0
printf '%s\n' "$RUN_A" > "$SERVICE_RUN_ID_FILE"
CLEANUP_GENERATION_CALLS="${TEST_ROOT}/cleanup-generation.calls"
(
  cleanup_return_routes() {
    printf 'cleanup:%s\n' "$1" >> "$CLEANUP_GENERATION_CALLS"
  }
  cleanup_run_generation "$RUN_A"
)
assert_eq "cleanup:$RUN_A" "$(cat "$CLEANUP_GENERATION_CALLS" 2>/dev/null || true)" \
  'ExecStopPost cleanup did not receive the exact generation'

# Legacy owner state is cleaned before replacement; unprovable new-format evidence blocks snapshots.
reset_network
rm -f -- "$ACTIVE_RUN_FILE" "$RUN_STATE_FILE" "$PROFILE_FILE"
printf '%s\n' \
  'DEFAULT4=default via 192.0.2.1 dev eth0 metric 100' \
  'DEFAULT6=' > "$ROUTE_OWNER_FILE"
(
  managed_units_need_stop() { return 1; }
  pgrep() { return 1; }
  prepare_service_replacement 0
) || fail 'verified legacy route cleanup blocked service replacement'
[ ! -e "$ROUTE_OWNER_FILE" ] || fail 'service replacement left a legacy route owner behind'

reset_network
rm -f -- "$ACTIVE_RUN_FILE" "$RUN_STATE_FILE" "$PROFILE_FILE"
printf '%s\n' 'FORMAT_VERSION=1' "RUN_ID=$RUN_A" > "$ROUTE_PLAN_FILE"
REPLACEMENT_SNAPSHOT_CALLS="${TEST_ROOT}/replacement-snapshot.calls"
if (
  ensure_dependencies() { :; }
  select_account() {
    export ACCOUNT_INDEX=0 VPN_PROTOCOL=nc ACCOUNT_RECORD="$ACCOUNT"
  }
  confirm_service_replacement() { :; }
  managed_units_need_stop() { return 1; }
  install_self_and_units() { :; }
  port_is_free() { return 0; }
  pgrep() { return 1; }
  create_run_snapshot() {
    : > "$REPLACEMENT_SNAPSHOT_CALLS"
    printf '%s\n' "$RUN_B"
  }
  cleanup_start_attempt() { :; }
  log_err() { :; }
  log_warn() { :; }
  start_mode proxy <<< '' >/dev/null 2>&1
); then
  fail 'mode replacement with unprovable route plan unexpectedly succeeded'
fi
[ ! -e "$REPLACEMENT_SNAPSHOT_CALLS" ] || fail 'mode replacement created a snapshot before proving route cleanup'
[ -e "$ROUTE_PLAN_FILE" ] || fail 'mode replacement removed unprovable route evidence'

printf 'route checks passed\n'
