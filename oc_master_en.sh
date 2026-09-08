#!/usr/bin/env bash
# Compatibility entry point. v8 intentionally uses one audited implementation
# so the English and Chinese launchers cannot drift in networking behavior.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE_SCRIPT="${SCRIPT_DIR}/oc_master.sh"

if [ ! -r "$CORE_SCRIPT" ]; then
  printf 'oc_master.sh was not found next to this launcher. Clone the complete repository and try again.\n' >&2
  exit 1
fi

printf 'Note: v8 currently uses Chinese interactive prompts; command names and configuration are language-neutral.\n' >&2
exec bash "$CORE_SCRIPT" "$@"
