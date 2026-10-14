#!/usr/bin/env bash
set -u

FM_HOME=$1 FM_STATE_OVERRIDE=$1/state
. "$(dirname "${BASH_SOURCE[0]}")/fm-wake-lib.sh" || exit 1
if error=$(fm_treehouse_pool_check "$1" "$2" "$HOME" 2>&1); then
  exit 0
fi
error=${error:-error: could not resolve Treehouse pool before allocation}
printf '%s\n' "$error" > "$3"
printf '%s\n' "$error" >&2
exit 1
