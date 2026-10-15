#!/usr/bin/env bash
# fm-lab-home.sh - mint a disposable firstmate "lab" home.
#
# A lab home is a throwaway FM_HOME that a no-mistakes GATE agent may drive
# through the fleet lifecycle entrypoints: bin/fm-gate-refuse-lib.sh refuses
# those calls inside a gate agent unless FM_HOME carries the marker file this
# helper writes (the lib owns the marker format and authorization decision;
# this script is the supported writer).
#
# Usage:
#   fm-lab-home.sh create <dir>       make a marked lab home and print it
#   fm-lab-home.sh tmux-dir <dir>     create or print its private tmux socket dir
#   fm-lab-home.sh tmux-check <dir>   refuse unless its named socket is selected
#   fm-lab-home.sh tmux <dir> <cmd>   run tmux only on its recorded named socket
#   fm-lab-home.sh teardown <dir>     remove its private tmux socket dir
#
# A lab home is the stock layout only - state/, data/, config/, projects/ - and
# callers remove it with ordinary rm -rf when done. Drive it with plain
# FM_HOME=<dir>; bin/fm-gate-refuse-lib.sh owns permitted supervision overrides.
# tmux-dir records the short private socket directory; tmux runs commands on
# its named fm-lab socket. Callers stop that server before teardown, which
# refuses to remove a directory while any server there remains live.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

fm_lab_home_error() {
  echo "fm-lab-home: $*" >&2
}

fm_lab_home_tmux_record() { printf '%s/state/.fm-lab-tmux-dir' "$1"; }
fm_lab_home_mode() {
  case "$(uname -s)" in Darwin) stat -f '%Lp' "$1" ;; *) stat -c '%a' "$1" ;; esac
}
fm_lab_home_owner() {
  case "$(uname -s)" in Darwin) stat -f '%u' "$1" ;; *) stat -c '%u' "$1" ;; esac
}

case "${1:-}" in
  create)
    dir=${2:-}
    [ -n "$dir" ] || { fm_lab_home_error "create requires a directory path"; exit 2; }
    if [ -e "$dir" ] && [ ! -d "$dir" ]; then
      fm_lab_home_error "refusing '$dir': exists and is not a directory"
      exit 1
    fi
    mkdir -p "$dir" || exit 1
    fm_gate_lab_mark "$dir" || {
      fm_lab_home_error "refusing '$dir': a lab marker is only ever stamped on a fresh empty dir"
      exit 1
    }
    mkdir -p "$dir/state" "$dir/data" "$dir/config" "$dir/projects" || exit 1
    printf '%s\n' "$dir"
    ;;
  tmux-dir|tmux-check|tmux)
    dir=${2:-}
    [ -n "$dir" ] || { fm_lab_home_error "tmux-dir requires a marked lab home"; exit 2; }
    [ -f "$dir/.fm-lab-home" ] && [ -d "$dir/state" ] \
      || { fm_lab_home_error "refusing '$dir': not a marked lab home"; exit 1; }
    record=$(fm_lab_home_tmux_record "$dir")
    if [ -f "$record" ]; then
      socket_dir=$(cat "$record")
      case "$socket_dir" in /tmp/fml.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;; *) fm_lab_home_error "invalid recorded tmux directory"; exit 1 ;; esac
      [ -d "$socket_dir" ] && [ ! -L "$socket_dir" ] \
        || { fm_lab_home_error "recorded tmux directory is missing or unsafe"; exit 1; }
      [ "$(fm_lab_home_mode "$socket_dir")" = 700 ] && [ "$(fm_lab_home_owner "$socket_dir")" = "$(id -u)" ] \
        || { fm_lab_home_error "recorded tmux directory is not private and user-owned"; exit 1; }
    else
      [ "$1" = tmux-dir ] || { fm_lab_home_error "lab tmux socket record is missing"; exit 1; }
      socket_dir=$(mktemp -d /tmp/fml.XXXXXX) || exit 1
      chmod 700 "$socket_dir" || { rmdir "$socket_dir" 2>/dev/null || true; exit 1; }
      [ "$(fm_lab_home_mode "$socket_dir")" = 700 ] && [ "$(fm_lab_home_owner "$socket_dir")" = "$(id -u)" ] \
        || { rmdir "$socket_dir" 2>/dev/null || true; fm_lab_home_error "cannot secure tmux directory"; exit 1; }
      (umask 077; printf '%s\n' "$socket_dir" > "$record") || { rmdir "$socket_dir" 2>/dev/null || true; exit 1; }
      chmod 600 "$record" || { rm -f "$record"; rmdir "$socket_dir" 2>/dev/null || true; exit 1; }
    fi
    if [ "$1" = tmux ]; then
      shift 2
      case "${1:-}" in ''|-*) fm_lab_home_error "tmux requires a command, not socket options"; exit 2 ;; esac
      socket_parent="$socket_dir/tmux-$(id -u)"
      [ -d "$socket_parent" ] || mkdir -m 700 "$socket_parent" || exit 1
      [ ! -L "$socket_parent" ] || { fm_lab_home_error "unsafe tmux socket parent"; exit 1; }
      exec env -u TMUX -u TMUX_PANE FM_TEST_TMUX_LAB_HOME="$dir" TMUX_TMPDIR="$socket_dir" \
        tmux -S "$socket_dir/tmux-$(id -u)/fm-lab" -f /dev/null "$@"
    elif [ "$1" = tmux-check ]; then
      socket_path="$socket_dir/tmux-$(id -u)/fm-lab"
      [ "${TMUX_TMPDIR:-}" = "$socket_dir" ] && [ "${TMUX:-}" != "" ] && [ "${TMUX%%,*}" = "$socket_path" ] \
        || { fm_lab_home_error "lab private named tmux socket is not selected"; exit 1; }
    else
      printf '%s\n' "$socket_dir"
    fi
    ;;
  teardown)
    dir=${2:-}
    [ -n "$dir" ] || { fm_lab_home_error "teardown requires a marked lab home"; exit 2; }
    [ -f "$dir/.fm-lab-home" ] && [ -d "$dir/state" ] \
      || { fm_lab_home_error "refusing '$dir': not a marked lab home"; exit 1; }
    record=$(fm_lab_home_tmux_record "$dir")
    [ -f "$record" ] || exit 0
    socket_dir=$(cat "$record")
    case "$socket_dir" in /tmp/fml.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;; *) fm_lab_home_error "invalid recorded tmux directory"; exit 1 ;; esac
    [ -d "$socket_dir" ] && [ ! -L "$socket_dir" ] \
      || { fm_lab_home_error "recorded tmux directory is missing or unsafe"; exit 1; }
    [ "$(fm_lab_home_mode "$socket_dir")" = 700 ] && [ "$(fm_lab_home_owner "$socket_dir")" = "$(id -u)" ] \
      || { fm_lab_home_error "refusing to remove a non-private or non-user-owned tmux directory"; exit 1; }
    # -L names its own socket (not "default"); inspect every socket this
    # private TMUX_TMPDIR could have hosted before removing the directory.
    for socket in "$socket_dir/tmux-$(id -u)"/*; do
      [ -e "$socket" ] || [ -L "$socket" ] || continue
      if probe=$(FM_TEST_TMUX_LAB_HOME="$dir" TMUX_TMPDIR="$socket_dir" \
        tmux -S "$socket" list-sessions 2>&1 >/dev/null) \
        || [ "${probe#*no server running}" = "$probe" ]; then
        fm_lab_home_error "refusing teardown: cannot confirm the lab tmux server has stopped"
        exit 1
      fi
    done
    rm -rf "$socket_dir" && rm -f "$record"
    ;;
  *)
    fm_lab_home_error "usage: fm-lab-home.sh create <dir> | tmux-dir <dir> | tmux-check <dir> | tmux <dir> <cmd> | teardown <dir>"
    exit 2
    ;;
esac
