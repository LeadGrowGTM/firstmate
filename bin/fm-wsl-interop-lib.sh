#!/usr/bin/env bash
# fm-wsl-interop-lib.sh - pick a live WSL Windows-interop socket for new launches.
#
# Sourced, never executed.
#
#   fm_wsl_live_interop
#       On WSL, prints the lowest-numbered <dir>/<n>_interop socket through which
#       a Windows program actually answers, and returns 0. Prints nothing and
#       returns 1 when no candidate answers or when this is not WSL (no
#       interop directory), which costs one directory test.
#
# Why: a long-lived process such as a tmux server keeps the WSL_INTEROP value of
# the login that started it. Once that login's interop server is gone, every
# Windows program started under it fails with "UtilAcceptVsock ... accept4
# failed 110". The dead socket still accepts a connection, so only running a
# Windows program through a candidate proves it works. Candidates are tried in
# ascending numeric order, so the choice is deterministic; the low-numbered
# sockets belong to WSL's own init and outlive individual logins.
#
# Environment knobs (tests and unusual installs):
#   FM_WSL_INTEROP_DIR      directory holding the sockets (default /run/WSL)
#   FM_WSL_INTEROP_PROBE    program run with WSL_INTEROP=<candidate> to prove it
#                           (default: cmd.exe /c exit 0)
#   FM_WSL_INTEROP_TIMEOUT  seconds one probe may take (default 3)

# shellcheck source=bin/fm-timeout-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-timeout-lib.sh"

fm_wsl_interop_probe() {  # <socket>
  if [ -n "${FM_WSL_INTEROP_PROBE:-}" ]; then
    WSL_INTEROP=$1 fm_run_timed "${FM_WSL_INTEROP_TIMEOUT:-3}" "$FM_WSL_INTEROP_PROBE" </dev/null >/dev/null 2>&1
    return
  fi
  local cmd
  cmd=$(command -v cmd.exe 2>/dev/null) || cmd=/mnt/c/Windows/System32/cmd.exe
  [ -x "$cmd" ] || return 1
  (cd / && WSL_INTEROP=$1 fm_run_timed "${FM_WSL_INTEROP_TIMEOUT:-3}" "$cmd" /c exit 0 </dev/null >/dev/null 2>&1)
}

fm_wsl_live_interop() {
  local dir=${FM_WSL_INTEROP_DIR:-/run/WSL} n path
  [ -d "$dir" ] || return 1
  while IFS= read -r n; do
    path="$dir/${n}_interop"
    [ -e "$path" ] || continue
    if fm_wsl_interop_probe "$path"; then
      printf '%s\n' "$path"
      return 0
    fi
  done <<EOF
$(for path in "$dir"/*_interop; do
    n=${path##*/}
    n=${n%_interop}
    case "$n" in '' | *[!0-9]*) continue ;; esac
    printf '%s\n' "$n"
  done | sort -n)
EOF
  return 1
}
