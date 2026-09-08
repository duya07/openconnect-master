#!/usr/bin/env bash
set -Eeuo pipefail

PATH="/usr/bin:/bin:${PATH}"
export PATH

cd -- "${BASH_SOURCE[0]%/*}/.."

"${BASH}" -n oc_master.sh oc_master_en.sh tests/static.sh tests/functions.sh

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x -S warning oc_master.sh oc_master_en.sh tests/static.sh tests/functions.sh
fi

"${BASH}" tests/functions.sh

if command -v jq >/dev/null 2>&1; then
  jq -e . examples/sing-box-selected-inbound.json examples/sing-box-all-tcp.json >/dev/null
elif command -v python3 >/dev/null 2>&1; then
  python3 -m json.tool examples/sing-box-selected-inbound.json >/dev/null
  python3 -m json.tool examples/sing-box-all-tcp.json >/dev/null
fi

if command -v sing-box >/dev/null 2>&1; then
  sing-box check -c examples/sing-box-selected-inbound.json
  sing-box check -c examples/sing-box-all-tcp.json
  printf 'sing-box configuration checks passed\n'
fi

if grep -R $'\r' --include='*.sh' --include='*.md' --include='*.json' . >/dev/null 2>&1; then
  printf 'CRLF detected in a text artifact\n' >&2
  exit 1
fi

if grep -F 'at now + 2 分钟之前' oc_master.sh >/dev/null 2>&1; then
  printf 'broken v7 rollback command is still present\n' >&2
  exit 1
fi

if grep -F 'systemctl disable --now' oc_master.sh >/dev/null 2>&1; then
  printf 'tunnel shutdown must not depend on whether a unit can be disabled\n' >&2
  exit 1
fi

grep -F -- '--reconnect-timeout=86400' oc_master.sh >/dev/null
grep -F -- '--tcp-keepalive=30' oc_master.sh >/dev/null
grep -F 'Restart=always' oc_master.sh >/dev/null
grep -F 'http_data_probe' oc_master.sh >/dev/null
grep -F 'chmod 600 "$ACCOUNTS_FILE"' oc_master.sh >/dev/null
grep -F 'chown 0:0 "$ACCOUNTS_FILE"' oc_master.sh >/dev/null
grep -F 'systemctl stop "$HEALTH_TIMER_NAME" "$SERVICE_NAME"' oc_master.sh >/dev/null
grep -F '拒绝清理路由' oc_master.sh >/dev/null
grep -F 'stop_and_disable_managed_units' oc_master.sh >/dev/null
grep -F 'GLOBAL-DDNS-RISK' oc_master.sh >/dev/null
grep -F 'start_managed_units' oc_master.sh >/dev/null
grep -F 'acquire_manager_lock' oc_master.sh >/dev/null
grep -F 'readonly SHORTCUT_PATH="${OCM_SHORTCUT_PATH:-/usr/local/bin/ocm}"' oc_master.sh >/dev/null

printf 'static checks passed\n'
