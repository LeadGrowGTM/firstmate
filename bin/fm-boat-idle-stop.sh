#!/usr/bin/env bash
# Stop the approved Boat box after 20 minutes without live or queued Boat work.
# Usage: fm-boat-idle-stop.sh arm|reset|check
# arm registers check with the existing watcher; send holds .boat-send.lock.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:?FM_HOME is required}
unset FM_STATE_OVERRIDE
STATE="$FM_HOME/state"
BOX=bx_ahnbu3qr
BOAT_BIN=${FM_BOAT_BIN:-boat}
STAMP="$STATE/.boat-idle-since"
LOCK="$STATE/.boat-send.lock"
SHIM="$STATE/boat-idle.check.sh"
TRUST="$STATE/boat-idle.check-trust"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
die() { printf 'error: %s\n' "$1" >&2; exit 1; }
[ -d "$STATE" ] && [ ! -L "$STATE" ] || die 'Boat state directory is unavailable'
case "${1:-}" in
  arm)
    [ "$#" -eq 1 ] || die 'one operation required'
    [ ! -L "$SHIM" ] && [ ! -L "$TRUST" ] || die 'unsafe Boat check registration'
    tmp=$(mktemp "$STATE/.boat-idle-check.XXXXXX") || die 'Boat check shim unavailable'
    {
      printf '#!/usr/bin/env bash\n'
      printf 'export FM_HOME=%q FM_STATE_OVERRIDE= FM_DATA_OVERRIDE=%q FM_BOAT_BIN=%q\n' "$FM_HOME" "${FM_DATA_OVERRIDE:-}" "$BOAT_BIN"
      printf 'exec %q check\n' "$SCRIPT_DIR/fm-boat-idle-stop.sh"
    } > "$tmp"
    chmod 0700 "$tmp"
    mv -f -- "$tmp" "$SHIM"
    if ! "$SCRIPT_DIR/fm-check-register.sh" boat-idle >/dev/null; then
      rm -f -- "$SHIM" "$TRUST"
      die 'Boat check registration failed'
    fi
    ;;
  reset)
    [ "$#" -eq 1 ] || die 'one operation required'
    [ ! -L "$STAMP" ] || die 'unsafe Boat idle stamp'
    rm -f -- "$STAMP"
    ;;
  check)
    [ "$#" -eq 1 ] || die 'one operation required'
    fm_lock_try_acquire "$LOCK" || exit 0
    trap 'fm_lock_release "$LOCK" || true' EXIT
    [ -f "$STATE/.boat-no-env" ] && [ ! -L "$STATE/.boat-no-env" ] &&
      [ "$(cat "$STATE/.boat-no-env")" = "$BOX" ] || exit 0
    info=$(fm_run_timed 5 "$BOAT_BIN" --no-update info "$BOX" --json) || die 'Boat info unavailable'
    state=$(printf '%s\n' "$info" | jq -er --arg box "$BOX" 'select(.sandbox.id == $box) | .sandbox.state') || die 'Boat info is invalid'
    case "$state" in
      stopped) rm -f -- "$STAMP"; exit 0 ;;
      ready|idle|running) ;;
      *) die 'Boat state is unknown' ;;
    esac
    activity=$(fm_run_timed 10 "$SCRIPT_DIR/fm-on.sh" boat-eng fm-boat-worker.sh idle) || die 'Boat worker state unavailable'
    case "$activity" in
      active) rm -f -- "$STAMP"; exit 0 ;;
      empty) ;;
      *) die 'Boat worker state is invalid' ;;
    esac
    [ ! -L "$STAMP" ] || die 'unsafe Boat idle stamp'
    now=$(date +%s)
    case "$now" in ''|*[!0-9]*) die 'Boat clock is invalid' ;; esac
    if [ ! -f "$STAMP" ]; then
      printf '%s\n' "$now" > "$STAMP"
      exit 0
    fi
    since=$(cat "$STAMP")
    case "$since" in ''|*[!0-9]*) die 'Boat idle stamp is invalid' ;; esac
    [ "$now" -ge "$since" ] || die 'Boat clock moved backward'
    [ $((now - since)) -ge 1200 ] || exit 0
    fm_run_timed 10 "$BOAT_BIN" --no-update stop "$BOX" --json >/dev/null || die 'Boat idle stop failed'
    rm -f -- "$STAMP"
    ;;
  *) die 'expected arm, reset, or check' ;;
esac
