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
  unset -f systemctl ss ip openconnect_process_is_alive http_data_probe cleanup_legacy_return_routes stop_and_disable_managed_units stop_vpn 2>/dev/null || true
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
