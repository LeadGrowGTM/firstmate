#!/usr/bin/env bash
# Read-only evaluation of this home's numeric targets.
# Usage: fm-targets.sh [--json]
# Configuration schema: docs/configuration.md (Idle sweep and standing targets).
# Unknown evidence prints unknown, never zero; --json is fm-targets.v1.
# Staleness uses the sweep's heartbeat observations and is unknown until observed.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-targets-lib.sh
. "$SCRIPT_DIR/fm-targets-lib.sh"
case "${1:-}" in
  --help|-h) sed -n '2,7s/^# \{0,1\}//p' "$0"; exit 0 ;;
  ''|--json) ;;
  *) echo 'usage: fm-targets.sh [--json]' >&2; exit 2 ;;
esac
fm_targets_init
snapshot=$(fm_targets_backlog)
result=$(fm_targets_collect "$snapshot")
if [ "${1:-}" = --json ]; then
  printf '%s\n' "$result"
else
  printf '%s' "$result" | jq -r '.targets[] | "\(.id): current=\(.current // "unknown") limit=\(.limit) gap=\(.gap // "unknown")"'
fi
