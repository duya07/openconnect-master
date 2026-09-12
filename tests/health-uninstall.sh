#!/usr/bin/env bash
set -Eeuo pipefail

# Break caught: accepting an arbitrary listener on the configured SOCKS port
# would report a foreign proxy as oc-master's healthy data plane.
cd -- "${BASH_SOURCE[0]%/*}/.."

TEST_ROOT="$(mktemp -d)"
cleanup() { rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT

export OCM_INSTALL_PATH="${TEST_ROOT}/sbin/oc-master"
export OCM_SHORTCUT_PATH="${TEST_ROOT}/bin/ocm"
export OCM_SYSTEMD_DIR="${TEST_ROOT}/systemd"
export OCM_CONFIG_DIR="${TEST_ROOT}/config"
export OCM_RUNTIME_DIR="${TEST_ROOT}/run"
export OCM_LOCK_FILE="${TEST_ROOT}/lock/manager.lock"
export OCM_STATE_LOCK_FILE="${TEST_ROOT}/lock/state.lock"
export OCM_SERVICE_LOCK_FILE="${TEST_ROOT}/lock/service.lock"
export OCM_ROUTE_OWNER_FILE="${TEST_ROOT}/config/owns-return-routing"
export OCM_ROUTE_PLAN_FILE="${TEST_ROOT}/config/route-plan.conf"
export OCM_ACCOUNTS_FILE="${TEST_ROOT}/accounts.env"
export OCM_PROC_ROOT="${TEST_ROOT}/proc"

# shellcheck source=../oc_master.sh
source ./oc_master.sh

# The production directory owner is root.  This portable test only needs the
# temporary directory side effect, so leave ownership to the test runner.
install() {
  local directory=0 source='' destination=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -d) directory=1; shift ;;
      -m|-o|-g) shift 2 ;;
      --) shift ;;
      *)
        if [ "$directory" = 1 ]; then command mkdir -p -- "$1"; else
          if [ -z "$source" ]; then source="$1"; else destination="$1"; fi
        fi
        shift
        ;;
    esac
  done
  [ "$directory" = 1 ] || command cp -- "$source" "$destination"
}
chown() { :; }
chmod() { :; }
flock() { :; }

fail() { printf 'health/uninstall test failed: %s\n' "$*" >&2; exit 1; }
RUN_PROXY='123e4567-e89b-42d3-a456-426614174101'
RUN_GLOBAL='123e4567-e89b-42d3-a456-426614174102'
BOOT_ID='123e4567-e89b-42d3-a456-426614174103'
ACCOUNT='Health test|alice|secret|vpn.example.test||nc'

write_proxy_state() {
  ensure_dirs
  write_active_run "$RUN_PROXY" "$BOOT_ID" proxy 0 nc 1080 "$ACCOUNT"
  write_run_state "$RUN_PROXY" RUNNING 1 0
}

write_global_state() {
  ensure_dirs
  write_active_run "$RUN_GLOBAL" "$BOOT_ID" global 0 nc '' "$ACCOUNT"
  write_run_state "$RUN_GLOBAL" CONFIRMED 1 0
  cat > "$ROUTE_PLAN_FILE" <<EOF
FORMAT_VERSION=1
RUN_ID=$RUN_GLOBAL
DEFAULT4=default via 192.0.2.1 dev eth0
DEV4=eth0
RETURN4_ADDRESS=198.51.100.8
DEFAULT6=
DEV6=
EOF
}

reset_runtime() {
  rm -rf -- "$CONFIG_DIR" "$RUNTIME_DIR" "$OCM_PROC_ROOT" "$SYSTEMD_DIR" \
    "$(dirname -- "$INSTALL_PATH")" "$(dirname -- "$SHORTCUT_PATH")"
  rm -f -- "$ACCOUNTS_FILE"
  unset -f systemctl ss ip openconnect_process_is_alive http_data_probe cleanup_legacy_return_routes 2>/dev/null || true
}

# RED: the current port-only health check incorrectly accepts this foreign
# listener. The remaining cases become reachable after the ownership fix.
reset_runtime
openconnect_process_is_alive() { :; }
http_data_probe() { :; }
systemctl() {
  case "$*" in
    "show $SERVICE_NAME --property=ControlGroup --value") printf '%s\n' '/system.slice/oc-master.service' ;;
    *) return 1 ;;
  esac
}
ss() { printf '%s\n' 'LISTEN 0 4096 127.0.0.1:1080 0.0.0.0:* users:(("foreign",pid=301,fd=3))'; }
write_proxy_state
if health_once; then fail 'foreign listener was accepted as healthy'; fi

# A listener in the service cgroup is healthy; all unprovable or foreign
# listeners fail closed.
mkdir -p -- "$OCM_PROC_ROOT/200"
printf '%s\n' '0::/system.slice/oc-master.service/ocproxy.scope' > "$OCM_PROC_ROOT/200/cgroup"
ss() { printf '%s\n' 'LISTEN 0 4096 127.0.0.1:1080 0.0.0.0:* users:(("ocproxy",pid=200,fd=3))'; }
health_once || fail 'managed listener was not accepted'
for colliding_group in \
  '/system.slice/oc-master.service.evil' \
  '/system.slice/oc-master.service.evil/ocproxy.scope'; do
  printf '%s\n' "0::${colliding_group}" > "$OCM_PROC_ROOT/200/cgroup"
  if health_once; then fail "service-name prefix collision was accepted: $colliding_group"; fi
done
printf '%s\n' '0::/system.slice/oc-master.service/ocproxy.scope' > "$OCM_PROC_ROOT/200/cgroup"
health_once || fail 'real service cgroup subpath was rejected after prefix-collision checks'
ss() { printf '%s\n' 'LISTEN 0 4096 127.0.0.1:1080 0.0.0.0:* users:(("foreign",pid=301,fd=3))'; }
if health_once; then fail 'foreign listener was accepted'; fi
ss() { printf '%s\n' 'LISTEN 0 4096 127.0.0.1:1080 0.0.0.0:*'; }
if health_once; then fail 'listener without PID was accepted'; fi
ss() { printf '%s\n' 'LISTEN 0 4096 127.0.0.1:1080 0.0.0.0:* users:(("ocproxy",pid=200,fd=3))'; }
printf '%s\n' '0::/system.slice/other.service' > "$OCM_PROC_ROOT/200/cgroup"
if health_once; then fail 'foreign cgroup listener was accepted'; fi
rm -f -- "$OCM_PROC_ROOT/200/cgroup"
if health_once; then fail 'listener with unavailable cgroup was accepted'; fi
mkdir -p -- "$OCM_PROC_ROOT/200"
printf '%s\n' '0::/system.slice/oc-master.service' > "$OCM_PROC_ROOT/200/cgroup"
systemctl() { return 1; }
if health_once; then fail 'unknown systemd ControlGroup was accepted'; fi

# Legacy recovery must prove ownership of every same-named unit before the
# first stop/disable mutation. A foreign unit must fail closed and preserve all
# legacy evidence; a mixed set must not stop the owned subset first.
make_foreign_units() {
  mkdir -p -- "$SYSTEMD_DIR"
  for unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
    printf '%s\n' '# foreign unit' > "$(unit_path "$unit")"
  done
}

reset_runtime
ensure_dirs
write_profile proxy 0 nc 1080
printf '%s\n' 'DEFAULT4=default via 192.0.2.1 dev eth0' > "$ROUTE_OWNER_FILE"
make_foreign_units
unit_mutation_calls="${TEST_ROOT}/unit-mutation.calls"
record_systemctl_call() { printf '%s\n' "$*" >> "$unit_mutation_calls"; return 0; }
systemctl() { record_systemctl_call "$@"; }
if recover_legacy_installation; then fail 'all-foreign legacy recovery was accepted'; fi
[ ! -s "$unit_mutation_calls" ] || fail 'all-foreign recovery mutated a unit before ownership failure'
[ -f "$PROFILE_FILE" ] || fail 'all-foreign recovery removed the legacy profile'
[ -f "$ROUTE_OWNER_FILE" ] || fail 'all-foreign recovery removed route ownership evidence'
for unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
  [ -f "$(unit_path "$unit")" ] || fail "all-foreign recovery removed $unit evidence"
done

reset_runtime
ensure_dirs
write_profile proxy 0 nc 1080
printf '%s\n' 'DEFAULT4=default via 192.0.2.1 dev eth0' > "$ROUTE_OWNER_FILE"
mkdir -p -- "$SYSTEMD_DIR"
printf '%s\n' '# Managed by oc-master' > "$(unit_path "$SERVICE_NAME")"
printf '%s\n' '# foreign unit' > "$(unit_path "$HEALTH_SERVICE_NAME")"
printf '%s\n' '# foreign unit' > "$(unit_path "$HEALTH_TIMER_NAME")"
: > "$unit_mutation_calls"
systemctl() {
  case "$*" in
    "show $SERVICE_NAME --property=LoadState --value") printf '%s\n' loaded ;;
    "show $SERVICE_NAME --property=FragmentPath --value") unit_path "$SERVICE_NAME" ;;
    "show $SERVICE_NAME --all --property=DropInPaths") printf 'DropInPaths=\n' ;;
    "show $SERVICE_NAME --property=NeedDaemonReload --value") printf '%s\n' no ;;
    *) record_systemctl_call "$@" ;;
  esac
}
if recover_legacy_installation; then fail 'mixed legacy recovery was accepted'; fi
[ ! -s "$unit_mutation_calls" ] || fail 'mixed recovery mutated an owned unit before foreign preflight completed'
[ -f "$PROFILE_FILE" ] || fail 'mixed recovery removed the legacy profile'
[ -f "$ROUTE_OWNER_FILE" ] || fail 'mixed recovery removed route ownership evidence'
[ -f "$(unit_path "$SERVICE_NAME")" ] || fail 'mixed recovery removed the owned unit evidence'
[ -f "$(unit_path "$HEALTH_SERVICE_NAME")" ] || fail 'mixed recovery removed foreign health unit evidence'
[ -f "$(unit_path "$HEALTH_TIMER_NAME")" ] || fail 'mixed recovery removed foreign timer evidence'

# With no valid runtime state, the stop path must use the same ownership gate
# before it can call systemctl stop/disable.
reset_runtime
ensure_dirs
make_foreign_units
: > "$unit_mutation_calls"
check_root() { :; }
acquire_service_operation_lock() { :; }
release_service_operation_lock() { :; }
systemctl() { record_systemctl_call "$@"; }
if stop_vpn; then fail 'stateless stop accepted foreign units'; fi
[ ! -s "$unit_mutation_calls" ] || fail 'stateless stop mutated a foreign unit'

# A missing file in SYSTEMD_DIR does not prove that systemd has no same-named
# unit: it may be loaded from a vendor, generator, or transient search path.
# Read-only show/is-active probes are not mutations and must not satisfy the
# zero-side-effect assertion.
external_fragment_systemctl() {
  local action="${1:-}"
  case "$action" in
    show)
      case "$*" in
        "show $SERVICE_NAME --property=LoadState --value") printf '%s\n' not-found ;;
        "show $HEALTH_SERVICE_NAME --property=LoadState --value") printf '%s\n' loaded ;;
        "show $HEALTH_SERVICE_NAME --property=FragmentPath --value")
          printf '/usr/lib/systemd/system/%s\n' "$HEALTH_SERVICE_NAME"
          ;;
        "show $HEALTH_TIMER_NAME --property=LoadState --value") printf '%s\n' not-found ;;
        'show -p MainPID --value '*) printf '0\n' ;;
        *) return 1 ;;
      esac
      ;;
    is-active) printf '%s\n' inactive; return 3 ;;
    stop|disable|reset-failed|restart|start|enable|reenable|reload|daemon-reload)
      record_systemctl_call "$@"
      ;;
    *) return 1 ;;
  esac
}

reset_runtime
ensure_dirs
: > "$unit_mutation_calls"
for unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
  [ ! -e "$(unit_path "$unit")" ] && [ ! -L "$(unit_path "$unit")" ] \
    || fail "external-fragment fixture unexpectedly created $unit"
done
systemctl() { external_fragment_systemctl "$@"; }
external_stop_rc=0
stop_vpn >/dev/null 2>&1 || external_stop_rc=$?
[ ! -s "$unit_mutation_calls" ] || fail 'stateless stop mutated a vendor-path unit before source rejection'
[ "$external_stop_rc" -ne 0 ] || fail 'stateless stop accepted a vendor-path unit'

reset_runtime
ensure_dirs
write_profile proxy 0 nc 1080
printf '%s\n' 'DEFAULT4=default via 192.0.2.1 dev eth0' > "$ROUTE_OWNER_FILE"
: > "$unit_mutation_calls"
systemctl() { external_fragment_systemctl "$@"; }
external_recovery_rc=0
recover_legacy_installation >/dev/null 2>&1 || external_recovery_rc=$?
[ ! -s "$unit_mutation_calls" ] || fail 'legacy recovery mutated a vendor-path unit before source rejection'
[ "$external_recovery_rc" -ne 0 ] || fail 'legacy recovery accepted a vendor-path unit'
[ -f "$PROFILE_FILE" ] || fail 'vendor-path recovery removed the legacy profile'
[ -f "$ROUTE_OWNER_FILE" ] || fail 'vendor-path recovery removed route ownership evidence'

# Every unprovable source state fails closed. Conversely, an explicit
# not-found result is safe, and a loaded unit is accepted only when its exact
# fragment path exists and carries oc-master ownership evidence.
SOURCE_PROBE_MODE=''
unit_source_probe_systemctl() {
  local action="${1:-}" unit="${2:-}" property="${3:-}"
  if [ "$action" != show ]; then
    record_systemctl_call "$@"
    return 0
  fi
  case "$unit" in
    "$SERVICE_NAME"|"$HEALTH_SERVICE_NAME"|"$HEALTH_TIMER_NAME") ;;
    *) return 1 ;;
  esac
  if [ "${3:-}" = --all ] && [ "${4:-}" = --property=DropInPaths ] && [ "$#" -eq 4 ]; then
    case "$SOURCE_PROBE_MODE" in
      dropin-query-failure) return 1 ;;
      dropin-missing) return 0 ;;
      dropin-present) printf 'DropInPaths=/etc/systemd/system/%s.d/override.conf\n' "$unit" ;;
      *) printf 'DropInPaths=\n' ;;
    esac
    return 0
  fi
  [ "${4:-}" = --value ] || return 1
  case "$property" in
    --property=LoadState)
      [ "$SOURCE_PROBE_MODE" != load-query-failure ] || return 1
      case "$SOURCE_PROBE_MODE" in
        not-found) printf '%s\n' not-found ;;
        unexpected-load) printf '%s\n' masked ;;
        *) printf '%s\n' loaded ;;
      esac
      ;;
    --property=FragmentPath)
      [ "$SOURCE_PROBE_MODE" != fragment-query-failure ] || return 1
      case "$SOURCE_PROBE_MODE" in
        empty-fragment) : ;;
        owned|missing-owned-fragment|reload-query-failure|reload-empty|reload-yes) unit_path "$unit" ;;
        *) printf '/run/systemd/transient/%s\n' "$unit" ;;
      esac
      ;;
    --property=NeedDaemonReload)
      case "$SOURCE_PROBE_MODE" in
        reload-query-failure) return 1 ;;
        reload-empty) : ;;
        reload-yes) printf '%s\n' yes ;;
        *) printf '%s\n' no ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

for SOURCE_PROBE_MODE in load-query-failure unexpected-load fragment-query-failure empty-fragment \
  transient-fragment missing-owned-fragment dropin-query-failure dropin-missing dropin-present; do
  reset_runtime
  ensure_dirs
  : > "$unit_mutation_calls"
  systemctl() { unit_source_probe_systemctl "$@"; }
  if preflight_managed_units_ownership >/dev/null 2>&1; then
    fail "unit source probe accepted $SOURCE_PROBE_MODE"
  fi
  [ ! -s "$unit_mutation_calls" ] || fail "unit source probe mutated a unit for $SOURCE_PROBE_MODE"
done

reset_runtime
ensure_dirs
SOURCE_PROBE_MODE=not-found
systemctl() { unit_source_probe_systemctl "$@"; }
preflight_managed_units_ownership || fail 'explicit not-found units were rejected'

reset_runtime
ensure_dirs
mkdir -p -- "$SYSTEMD_DIR"
for unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
  printf '%s\n' '# Managed by oc-master' > "$(unit_path "$unit")"
done
SOURCE_PROBE_MODE=owned
systemctl() { unit_source_probe_systemctl "$@"; }
preflight_managed_units_ownership || fail 'owned loaded unit fragments were rejected'

# Stop and legacy recovery are destructive systemd paths.  A loaded unit at
# the owned FragmentPath is still unprovable while daemon-reload is pending or
# its state cannot be read, so both paths must reject before their first
# mutation and preserve recovery evidence.
seed_owned_source_units() {
  local unit
  mkdir -p -- "$SYSTEMD_DIR"
  for unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
    printf '%s\n' '# Managed by oc-master' > "$(unit_path "$unit")"
  done
}

reload_guard_failures=0
record_reload_guard_failure() {
  printf 'NeedDaemonReload guard regression: %s\n' "$*" >&2
  reload_guard_failures=$((reload_guard_failures + 1))
}

for SOURCE_PROBE_MODE in reload-yes reload-empty reload-query-failure; do
  reset_runtime
  ensure_dirs
  seed_owned_source_units
  : > "$unit_mutation_calls"
  systemctl() { unit_source_probe_systemctl "$@"; }
  reload_stop_rc=0
  stop_and_disable_managed_units >/dev/null 2>&1 || reload_stop_rc=$?
  [ "$reload_stop_rc" -ne 0 ] \
    || record_reload_guard_failure "stop accepted NeedDaemonReload evidence: $SOURCE_PROBE_MODE"
  [ ! -s "$unit_mutation_calls" ] \
    || record_reload_guard_failure "stop mutated systemd for NeedDaemonReload evidence: $SOURCE_PROBE_MODE"

  reset_runtime
  ensure_dirs
  seed_owned_source_units
  write_profile proxy 0 nc 1080
  printf '%s\n' 'DEFAULT4=default via 192.0.2.1 dev eth0' > "$ROUTE_OWNER_FILE"
  : > "$unit_mutation_calls"
  systemctl() { unit_source_probe_systemctl "$@"; }
  reload_recovery_rc=0
  recover_legacy_installation >/dev/null 2>&1 || reload_recovery_rc=$?
  [ "$reload_recovery_rc" -ne 0 ] \
    || record_reload_guard_failure "legacy recovery accepted NeedDaemonReload evidence: $SOURCE_PROBE_MODE"
  [ ! -s "$unit_mutation_calls" ] \
    || record_reload_guard_failure "legacy recovery mutated systemd for NeedDaemonReload evidence: $SOURCE_PROBE_MODE"
  [ -f "$PROFILE_FILE" ] \
    || record_reload_guard_failure "legacy recovery removed profile for $SOURCE_PROBE_MODE"
  [ -f "$ROUTE_OWNER_FILE" ] \
    || record_reload_guard_failure "legacy recovery removed route evidence for $SOURCE_PROBE_MODE"
done
[ "$reload_guard_failures" -eq 0 ] \
  || fail "$reload_guard_failures NeedDaemonReload stop/recovery regression(s) detected"
printf 'NeedDaemonReload stop/recovery guards passed\n'

# Global health binds plan generation and both data-plane directions: ordinary
# traffic uses ocm0 and each saved source address retains its planned egress.
reset_runtime
openconnect_process_is_alive() { :; }
http_data_probe() { :; }
write_global_state
ip() {
  case "$*" in
    '-4 route get 1.1.1.1') printf '%s\n' '1.1.1.1 dev ocm0 src 10.0.0.2' ;;
    '-4 route get 1.1.1.1 from 198.51.100.8') printf '%s\n' '1.1.1.1 from 198.51.100.8 via 192.0.2.1 dev eth0' ;;
    *) return 1 ;;
  esac
}
health_once || fail 'valid global route plan was not healthy'
sed -i "s/^RUN_ID=.*/RUN_ID=$RUN_PROXY/" "$ROUTE_PLAN_FILE"
if health_once; then fail 'global health accepted a route plan from another run'; fi
sed -i "s/^RUN_ID=.*/RUN_ID=$RUN_GLOBAL/" "$ROUTE_PLAN_FILE"
ip() {
  case "$*" in
    '-4 route get 1.1.1.1') printf '%s\n' '1.1.1.1 via 192.0.2.1 dev eth0' ;;
    '-4 route get 1.1.1.1 from 198.51.100.8') printf '%s\n' '1.1.1.1 from 198.51.100.8 via 192.0.2.1 dev eth0' ;;
    *) return 1 ;;
  esac
}
if health_once; then fail 'global health accepted ordinary traffic outside ocm0'; fi

# Legacy recovery is allowed only when no new state artifact exists. A partial
# new snapshot must never be treated as an old profile.
reset_runtime
ensure_dirs
write_profile proxy 0 nc 1080
printf '%s\n' 'DEFAULT4=default via 192.0.2.1 dev eth0' 'DEFAULT6=' > "$ROUTE_OWNER_FILE"
legacy_cleanup_calls="${TEST_ROOT}/legacy-cleanup.calls"
SOURCE_PROBE_MODE=not-found
systemctl() { unit_source_probe_systemctl "$@"; }
stop_and_disable_managed_units() { printf '%s\n' stop >> "$legacy_cleanup_calls"; }
cleanup_legacy_return_routes() { printf '%s\n' cleanup >> "$legacy_cleanup_calls"; rm -f -- "$ROUTE_OWNER_FILE"; }
recover_legacy_installation || fail 'clean legacy installation was not recovered'
[ "$(tr '\n' ' ' < "$legacy_cleanup_calls")" = 'stop cleanup ' ] || fail 'legacy recovery order is unsafe'
[ ! -e "$ROUTE_OWNER_FILE" ] || fail 'legacy route ownership evidence remained after verified cleanup'
[ -f "$PROFILE_FILE" ] || fail 'legacy profile was removed before migration'
: > "$ACTIVE_RUN_FILE"
legacy_migration_called=0
migrate_legacy_profile() { legacy_migration_called=1; }
if prepare_runtime_configuration_for_start >/dev/null 2>&1; then fail 'partial new state fell back to legacy'; fi
[ "$legacy_migration_called" = 0 ] || fail 'partial new state invoked legacy migration'

# v8's bare decimal counter/timestamp is legacy residue only after unit
# ownership and quiescence have been established. It must be removed by the
# start recovery path; arbitrary new-generation-looking health evidence stays
# fail-closed and must not trigger legacy mutations.
for health_artifact in "$HEALTH_FAILURE_FILE" "$HEALTH_RESTART_FILE"; do
  reset_runtime
  ensure_dirs
  write_profile proxy 0 nc 1080
  printf '%s\n' 12345 > "$health_artifact"
  legacy_cleanup_called=0
  legacy_migration_called=0
  preflight_managed_units_ownership() { legacy_cleanup_called=$((legacy_cleanup_called + 1)); }
  stop_and_disable_managed_units() { [ "$legacy_cleanup_called" -eq 1 ] || return 1; legacy_cleanup_called=$((legacy_cleanup_called + 1)); }
  migrate_legacy_profile() { legacy_migration_called=1; }
  prepare_runtime_configuration_for_start \
    || fail "v8 decimal ${health_artifact##*/} did not converge through start recovery"
  [ "$legacy_cleanup_called" -eq 2 ] \
    || fail "v8 decimal ${health_artifact##*/} was removed before unit ownership/quiescence"
  [ "$legacy_migration_called" = 1 ] \
    || fail "v8 decimal ${health_artifact##*/} did not continue legacy start migration"
  [ ! -e "$health_artifact" ] && [ ! -L "$health_artifact" ] \
    || fail "v8 decimal ${health_artifact##*/} remained after verified legacy recovery"
done

# Non-decimal regular files, multi-line files, links and directories are never
# v8 residue.
for health_artifact in "$HEALTH_FAILURE_FILE" "$HEALTH_RESTART_FILE"; do
  for artifact_kind in regular multiline trailing-blank symlink directory; do
    reset_runtime
    ensure_dirs
    write_profile proxy 0 nc 1080
    case "$artifact_kind" in
      regular) printf '%s\n' evidence > "$health_artifact" ;;
      multiline) printf '%s\n%s\n' 123 UNKNOWN > "$health_artifact" ;;
      trailing-blank) printf '123\n\n' > "$health_artifact" ;;
      symlink) printf '%s\n' target > "${TEST_ROOT}/health-target"; ln -s -- "${TEST_ROOT}/health-target" "$health_artifact" ;;
      directory) mkdir -p -- "$health_artifact" ;;
    esac
    legacy_cleanup_called=0
    legacy_migration_called=0
    stop_and_disable_managed_units() { legacy_cleanup_called=1; }
    migrate_legacy_profile() { legacy_migration_called=1; }
    if prepare_runtime_configuration_for_start >/dev/null 2>&1; then
      fail "${health_artifact##*/} ${artifact_kind} was treated as legacy-only state"
    fi
    [ "$legacy_cleanup_called" = 0 ] || fail "${health_artifact##*/} ${artifact_kind} attempted legacy unit cleanup"
    [ "$legacy_migration_called" = 0 ] || fail "${health_artifact##*/} ${artifact_kind} invoked legacy migration"
  done
done

# The public stop and uninstall routes must take the same verified legacy
# recovery branch as start.  This guards the actual dispatch chain rather than
# merely calling the recovery helper directly.
for legacy_public_action in stop uninstall; do
  reset_runtime
  ensure_dirs
  write_profile proxy 0 nc 1080
  printf '%s\n' 12345 > "$HEALTH_FAILURE_FILE"
  legacy_public_calls="${TEST_ROOT}/legacy-public-${legacy_public_action}.calls"
  preflight_managed_units_ownership() { printf '%s\n' preflight >> "$legacy_public_calls"; }
  stop_and_disable_managed_units() { printf '%s\n' stop >> "$legacy_public_calls"; }
  acquire_service_operation_lock() { :; }
  release_service_operation_lock() { :; }
  systemctl() { [ "$*" = daemon-reload ] || return 0; }
  if [ "$legacy_public_action" = stop ]; then
    stop_vpn || fail 'v8 decimal residue did not converge through public stop'
  else
    printf 'REMOVE\n' | uninstall_manager \
      || fail 'v8 decimal residue did not converge through uninstall-via-stop'
  fi
  [ "$(cat "$legacy_public_calls")" = $'preflight\nstop' ] \
    || fail "public ${legacy_public_action} skipped verified legacy unit recovery"
  [ ! -e "$HEALTH_FAILURE_FILE" ] && [ ! -L "$HEALTH_FAILURE_FILE" ] \
    || fail "public ${legacy_public_action} retained v8 decimal residue"
done

make_owned_install() {
  mkdir -p -- "$SYSTEMD_DIR" "$(dirname -- "$INSTALL_PATH")" "$(dirname -- "$SHORTCUT_PATH")"
  install -m 0755 -- "$SCRIPT_PATH" "$INSTALL_PATH"
  ln -s -- "$INSTALL_PATH" "$SHORTCUT_PATH"
  for unit in "$SERVICE_NAME" "$HEALTH_SERVICE_NAME" "$HEALTH_TIMER_NAME"; do
    printf '%s\n' '# Managed by oc-master' > "$(unit_path "$unit")"
  done
  write_profile proxy 0 nc 1080
}

owned_shortcut_supported=0

# Deleting managed units is an uninstall commit boundary.  A failure at any
# position must stop immediately, report failure, and leave that unit plus all
# later units available for a safe retry.
managed_unit_paths=(
  "$(unit_path "$SERVICE_NAME")"
  "$(unit_path "$HEALTH_SERVICE_NAME")"
  "$(unit_path "$HEALTH_TIMER_NAME")"
)
for unit_remove_case in first middle last; do
  case "$unit_remove_case" in
    first) unit_remove_failure_index=1 ;;
    middle) unit_remove_failure_index=2 ;;
    last) unit_remove_failure_index=3 ;;
  esac
  reset_runtime
  ensure_dirs
  mkdir -p -- "$SYSTEMD_DIR"
  for unit_path_fixture in "${managed_unit_paths[@]}"; do
    printf '%s\n' '# Managed by oc-master' > "$unit_path_fixture"
  done
  unit_remove_output="${TEST_ROOT}/unit-remove-${unit_remove_case}.out"
  unit_remove_result=0
  if (
    unit_remove_count=0
    rm() {
      local target="${!#}" candidate
      for candidate in "${managed_unit_paths[@]}"; do
        if [ "$target" = "$candidate" ]; then
          unit_remove_count=$((unit_remove_count + 1))
          [ "$unit_remove_count" -ne "$unit_remove_failure_index" ] || return 1
          break
        fi
      done
      command rm "$@"
    }
    remove_managed_units
  ) > "$unit_remove_output" 2>&1; then
    unit_remove_result=0
  else
    unit_remove_result=$?
  fi
  [ "$unit_remove_result" -ne 0 ] || fail "managed unit removal masked $unit_remove_case deletion failure"
  grep -F '删除 systemd 单元失败' "$unit_remove_output" >/dev/null \
    || fail "$unit_remove_case unit deletion failure lacked a diagnostic"
  for ((unit_path_index = 0; unit_path_index < ${#managed_unit_paths[@]}; unit_path_index++)); do
    if [ "$unit_path_index" -lt $((unit_remove_failure_index - 1)) ]; then
      [ ! -e "${managed_unit_paths[unit_path_index]}" ] && [ ! -L "${managed_unit_paths[unit_path_index]}" ] \
        || fail "$unit_remove_case unit deletion did not remove an earlier committed target"
    else
      [ -f "${managed_unit_paths[unit_path_index]}" ] \
        || fail "$unit_remove_case unit deletion continued after its first failure"
    fi
  done
done

# A successful rm result is insufficient when the unit path still exists.
reset_runtime
ensure_dirs
mkdir -p -- "$SYSTEMD_DIR"
for unit_path_fixture in "${managed_unit_paths[@]}"; do
  printf '%s\n' '# Managed by oc-master' > "$unit_path_fixture"
done
unit_remove_postcondition_output="${TEST_ROOT}/unit-remove-postcondition.out"
unit_remove_postcondition_result=0
if (
  skipped_unit_delete=0
  rm() {
    local target="${!#}"
    if [ "$skipped_unit_delete" -eq 0 ] && [ "$target" = "${managed_unit_paths[0]}" ]; then
      skipped_unit_delete=1
      return 0
    fi
    command rm "$@"
  }
  remove_managed_units
) > "$unit_remove_postcondition_output" 2>&1; then
  unit_remove_postcondition_result=0
else
  unit_remove_postcondition_result=$?
fi
[ "$unit_remove_postcondition_result" -ne 0 ] \
  || fail 'managed unit removal trusted rm success although the path still existed'
for unit_path_fixture in "${managed_unit_paths[@]}"; do
  [ -f "$unit_path_fixture" ] || fail 'managed unit removal continued after a failed deletion postcondition'
done
grep -F '删除 systemd 单元失败' "$unit_remove_postcondition_output" >/dev/null \
  || fail 'unit deletion postcondition failure lacked a diagnostic'

# An unlink may have happened even when rm reports failure. This is still a
# partial delete: reload before returning the original failure so systemd does
# not keep a stale fragment that blocks the next public uninstall.
reset_runtime
ensure_dirs
mkdir -p -- "$SYSTEMD_DIR"
for unit_path_fixture in "${managed_unit_paths[@]}"; do
  printf '%s\n' '# Managed by oc-master' > "$unit_path_fixture"
done
rm_after_unlink_reload_log="${TEST_ROOT}/rm-after-unlink.reload"
if (
  rm() {
    local target="${!#}"
    if [ "$target" = "${managed_unit_paths[0]}" ]; then command rm "$@"; return 1; fi
    command rm "$@"
  }
  systemctl() {
    case "$*" in
      daemon-reload) printf '%s\n' reload >> "$rm_after_unlink_reload_log" ;;
      "show $SERVICE_NAME --property=LoadState --value") printf '%s\n' not-found ;;
      *) return 0 ;;
    esac
  }
  remove_managed_units
); then
  fail 'rm failure after unlink was incorrectly reported as success'
fi
[ ! -e "${managed_unit_paths[0]}" ] || fail 'rm-after-unlink fixture did not remove the first unit'
[ -f "$rm_after_unlink_reload_log" ] || fail 'rm failure after unlink did not daemon-reload before returning'

# The full uninstaller must not cross the unit-removal boundary after a middle
# failure: daemon-reload, program/shortcut removal, and recovery evidence all
# remain untouched.
reset_runtime
ensure_dirs
make_owned_install
write_active_run "$RUN_PROXY" "$BOOT_ID" proxy 0 nc 1080 "$ACCOUNT"
write_run_state "$RUN_PROXY" CLEANED 0 0
uninstall_daemon_calls="${TEST_ROOT}/uninstall-unit-failure.daemon"
uninstall_unit_failure_output="${TEST_ROOT}/uninstall-unit-failure.out"
had_shortcut_before_failure=0
if [ -e "$SHORTCUT_PATH" ] || [ -L "$SHORTCUT_PATH" ]; then had_shortcut_before_failure=1; fi
uninstall_unit_failure_result=0
if printf 'REMOVE\n' | (
  stop_vpn() { :; }
  systemctl() {
    [ "$*" != 'daemon-reload' ] || printf '%s\n' daemon-reload >> "$uninstall_daemon_calls"
    return 0
  }
  rm() {
    local target="${!#}"
    [ "$target" != "${managed_unit_paths[1]}" ] || return 1
    command rm "$@"
  }
  uninstall_manager
) > "$uninstall_unit_failure_output" 2>&1; then
  uninstall_unit_failure_result=0
else
  uninstall_unit_failure_result=$?
fi
[ "$uninstall_unit_failure_result" -ne 0 ] || fail 'uninstall masked a managed unit deletion failure'
[ -f "$uninstall_daemon_calls" ] || fail 'uninstall did not daemon-reload after a partial managed-unit deletion'
for preserved in "$INSTALL_PATH" "$PROFILE_FILE" "$ACTIVE_RUN_FILE" "$RUN_STATE_FILE"; do
  [ -e "$preserved" ] || fail "unit deletion failure let uninstall remove $preserved"
done
[ "$had_shortcut_before_failure" -eq 0 ] || { [ -e "$SHORTCUT_PATH" ] || [ -L "$SHORTCUT_PATH" ]; } \
  || fail 'unit deletion failure let uninstall remove the shortcut'
[ -f "${managed_unit_paths[1]}" ] && [ -f "${managed_unit_paths[2]}" ] \
  || fail 'uninstall continued deleting units after the middle failure'
printf 'managed unit removal failure tests passed\n'

# A failed first/middle/last deletion must leave a retryable public uninstall.
# In particular, units deleted before the failure need a reload immediately so
# the next invocation does not see stale loaded fragments and require a manual
# daemon-reload.
for uninstall_retry_case in first middle last; do
  case "$uninstall_retry_case" in
    first) uninstall_retry_index=0 ;;
    middle) uninstall_retry_index=1 ;;
    last) uninstall_retry_index=2 ;;
  esac
  reset_runtime
  ensure_dirs
  make_owned_install
  write_active_run "$RUN_PROXY" "$BOOT_ID" proxy 0 nc 1080 "$ACCOUNT"
  write_run_state "$RUN_PROXY" CLEANED 0 0
  uninstall_retry_marker="${TEST_ROOT}/uninstall-retry-${uninstall_retry_case}.injected"
  uninstall_retry_reload_log="${TEST_ROOT}/uninstall-retry-${uninstall_retry_case}.reload"
  if ! (
    stop_vpn() { :; }
    systemctl() {
      local unit path
      case "$*" in
        daemon-reload) printf '%s\n' reload >> "$uninstall_retry_reload_log" ;;
        "show "*" --property=LoadState --value")
          unit="$2"; path="$(unit_path "$unit")"
          if [ -e "$path" ] || [ -L "$path" ]; then printf '%s\n' loaded; else printf '%s\n' not-found; fi
          ;;
        "show "*" --property=FragmentPath --value") unit="$2"; unit_path "$unit" ;;
        "show "*" --all --property=DropInPaths") printf '%s\n' 'DropInPaths=' ;;
        "show "*" --property=NeedDaemonReload --value") printf '%s\n' no ;;
        *) return 0 ;;
      esac
    }
    rm() {
      local target="${!#}"
      if [ "$target" = "${managed_unit_paths[uninstall_retry_index]}" ] && [ ! -e "$uninstall_retry_marker" ]; then
        : > "$uninstall_retry_marker"
        return 1
      fi
      command rm "$@"
    }
    if printf 'REMOVE\n' | uninstall_manager >/dev/null 2>&1; then
      fail "uninstall retry fixture accepted its first ${uninstall_retry_case} deletion failure"
    fi
    [ -e "$uninstall_retry_marker" ] || fail "uninstall retry fixture did not inject ${uninstall_retry_case} failure"
    if [ "$uninstall_retry_index" -gt 0 ]; then
      [ -s "$uninstall_retry_reload_log" ] || fail "${uninstall_retry_case} failure did not reload deleted units"
    fi
    printf 'REMOVE\n' | uninstall_manager >/dev/null 2>&1 \
      || fail "public uninstall did not converge after ${uninstall_retry_case} failure"
  ); then
    fail "uninstall retry regression failed for ${uninstall_retry_case}"
  fi
  for removed in "${managed_unit_paths[@]}" "$INSTALL_PATH" "$PROFILE_FILE" "$ACTIVE_RUN_FILE" "$RUN_STATE_FILE"; do
    [ ! -e "$removed" ] && [ ! -L "$removed" ] \
      || fail "retry after ${uninstall_retry_case} failure retained $removed"
  done
done
printf 'public uninstall retry convergence tests passed\n'

# Uninstall removes only confirmed-owned objects after a committed CLEANED
# state; accounts and foreign files are retained.
reset_runtime
ensure_dirs
make_owned_install
shortcut_is_ours && owned_shortcut_supported=1 || true
printf '%s\n' 'foreign unit' > "${SYSTEMD_DIR}/foreign.service"
printf '%s\n' keep > "$ACCOUNTS_FILE"
write_active_run "$RUN_PROXY" "$BOOT_ID" proxy 0 nc 1080 "$ACCOUNT"
write_run_state "$RUN_PROXY" CLEANED 0 0
printf '%s\n' "$RUN_PROXY" > "$SERVICE_RUN_ID_FILE"
printf '%s\n' route > "$ROUTE_PLAN_FILE"
printf '%s\n' owner > "$ROUTE_OWNER_FILE"
stop_vpn() { :; }
systemctl() { [ "$*" = 'daemon-reload' ]; }
printf 'REMOVE\n' | uninstall_manager || fail 'owned uninstall failed'
for removed in "$INSTALL_PATH" "$PROFILE_FILE" "$ACTIVE_RUN_FILE" "$RUN_STATE_FILE" "$ROUTE_PLAN_FILE" "$ROUTE_OWNER_FILE" "$SERVICE_RUN_ID_FILE"; do
  [ ! -e "$removed" ] && [ ! -L "$removed" ] || fail "successful uninstall retained $removed"
done
[ "$owned_shortcut_supported" = 0 ] || { [ ! -e "$SHORTCUT_PATH" ] && [ ! -L "$SHORTCUT_PATH" ]; } \
  || fail 'successful uninstall retained owned shortcut'
[ -f "$ACCOUNTS_FILE" ] || fail 'uninstall removed accounts file'
[ -f "${SYSTEMD_DIR}/foreign.service" ] || fail 'uninstall removed foreign unit'

# A cleanup failure preserves every credential-bearing recovery artifact.
reset_runtime
ensure_dirs
make_owned_install
write_active_run "$RUN_PROXY" "$BOOT_ID" proxy 0 nc 1080 "$ACCOUNT"
write_run_state "$RUN_PROXY" RUNNING 1 0
printf '%s\n' "$RUN_PROXY" > "$SERVICE_RUN_ID_FILE"
stop_vpn() { return 1; }
printf 'REMOVE\n' | uninstall_manager >/dev/null 2>&1 && fail 'uninstall accepted failed cleanup'
for preserved in "$INSTALL_PATH" "$PROFILE_FILE" "$ACTIVE_RUN_FILE" "$RUN_STATE_FILE" "$SERVICE_RUN_ID_FILE"; do
  [ -e "$preserved" ] || fail "failed cleanup deleted $preserved"
done

# If unit deletion reaches daemon-reload but reload fails, return non-zero and
# retain the internal snapshot rather than destroying recovery evidence.
reset_runtime
ensure_dirs
make_owned_install
write_active_run "$RUN_PROXY" "$BOOT_ID" proxy 0 nc 1080 "$ACCOUNT"
write_run_state "$RUN_PROXY" CLEANED 0 0
stop_vpn() { :; }
systemctl() { [ "$*" = 'daemon-reload' ] && return 1; }
if printf 'REMOVE\n' | uninstall_manager >"${TEST_ROOT}/uninstall.out" 2>&1; then
  fail 'uninstall accepted daemon-reload failure'
fi
grep -F 'daemon-reload' "${TEST_ROOT}/uninstall.out" >/dev/null || fail 'daemon-reload failure was not reported'
[ -f "$ACTIVE_RUN_FILE" ] && [ -f "$RUN_STATE_FILE" ] || fail 'daemon-reload failure deleted snapshot evidence'

printf 'health/uninstall checks passed\n'
