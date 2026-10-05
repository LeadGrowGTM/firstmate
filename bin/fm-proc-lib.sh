#!/usr/bin/env bash
# Portable process inspection for harness-identity walks.
#
# ONE owner of reading a process's command name, argument string, parent pid,
# and liveness for bin/fm-harness.sh and bin/fm-session-lock-lib.sh. On Linux
# and macOS it is `ps -o <field>= -p <pid>` and `kill -0`, unchanged. Git Bash
# (MSYS) cannot answer either: its ps rejects -o, its kill only sees MSYS pids,
# and MSYS ancestry ends at its own pid 1 below the Windows harness process
# (omp.exe, claude.exe), so a walk never reaches the harness. There the answers
# come from one Windows process snapshot (Win32_Process), with the .exe suffix
# dropped from the command name. An MSYS pid (one with /proc/<pid>/winpid) is
# looked up by its Windows pid, and its parent is its MSYS parent, because MSYS
# fork-then-exec leaves the Windows parent pointing at an exited fork stub. Only
# at the top of the MSYS tree (MSYS parent 1) does the walk cross to the Windows
# parent - the real Windows process that launched Git Bash - and every pid past
# that point is a Windows pid.
# A bare pid which is both an MSYS pid with a different Windows pid and a live
# Windows pid is ambiguous, so field lookups fail closed instead of guessing.
# Trap handlers must return lookup statuses explicitly: bare return inherits the prior trap status.
#
# A snapshot costs about a second, so a walking shell calls fm_proc_prime once
# before it walks; the command-substitution subshells of the walk then share
# that snapshot. A lookup with no primed snapshot takes its own.
# This file is sourced and has no side effects on source.

case "${OSTYPE:-}" in
  msys*|cygwin*) _FM_PROC_WINDOWS=1 ;;
  *) _FM_PROC_WINDOWS=0 ;;
esac
FM_PROC_SNAPSHOT=

# Take a fresh Windows process snapshot into FM_PROC_SNAPSHOT: one
# "<pid>\t<ppid>\t<name>\t<command line>" line per process. No-op off Windows.
fm_proc_prime() {
  [ "$_FM_PROC_WINDOWS" -eq 1 ] || return 0
  # shellcheck disable=SC2016 # A PowerShell expression, expanded by PowerShell.
  FM_PROC_SNAPSHOT=$(powershell.exe -NoProfile -NonInteractive -Command \
    'Get-CimInstance Win32_Process | ForEach-Object { "{0}`t{1}`t{2}`t{3}" -f $_.ProcessId,$_.ParentProcessId,$_.Name,(($_.CommandLine + "") -replace "[\t\r\n]"," ") }' \
    </dev/null 2>/dev/null | tr -d '\r')
}

# Print the snapshot line for a Windows pid $1, or return 1 when absent.
_fm_proc_windows_snapshot_line() {  # <windows-pid>
  [ -n "$FM_PROC_SNAPSHOT" ] || fm_proc_prime
  printf '%s\n' "$FM_PROC_SNAPSHOT" | awk -F'\t' -v p="$1" '$1 == p { print; found = 1; exit } END { exit !found }'
}

# Print msys, native, ambiguous, or unknown for bare pid $1. A numeric collision
# between different MSYS and Windows processes cannot be disambiguated by callers.
_fm_proc_windows_pid_kind() {  # <pid>
  local pid=$1 winpid snapshot=0
  [ -n "$FM_PROC_SNAPSHOT" ] || fm_proc_prime
  _fm_proc_windows_snapshot_line "$pid" >/dev/null && snapshot=1
  if [ -r "/proc/$pid/winpid" ]; then
    winpid=$(cat "/proc/$pid/winpid" 2>/dev/null) || return 1
    case "$winpid" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$winpid" != "$pid" ] && [ "$snapshot" -eq 1 ]; then
      printf '%s\n' ambiguous
    else
      printf '%s\n' msys
    fi
    return 0
  fi
  [ "$snapshot" -eq 1 ] && printf '%s\n' native || printf '%s\n' unknown
}

# Print the snapshot line for bare pid $1, rejecting ambiguous MSYS/Windows pids.
_fm_proc_windows_line() {  # <pid>
  local pid=$1 kind winpid
  kind=$(_fm_proc_windows_pid_kind "$pid") || return 1
  case "$kind" in
    msys)
      winpid=$(cat "/proc/$pid/winpid" 2>/dev/null) || return 1
      _fm_proc_windows_snapshot_line "$winpid"
      ;;
    native) _fm_proc_windows_snapshot_line "$pid" ;;
    *) return 1 ;;
  esac
}

# Print field comm, args, or ppid of pid $1, or return 1 when the process is
# not found.
fm_proc_field() {  # <comm|args|ppid> <pid>
  local field=$1 pid=$2 line kind
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$_FM_PROC_WINDOWS" -eq 0 ]; then
    case "$field" in
      ppid) ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' ;;
      *) ps -o "$field=" -p "$pid" 2>/dev/null ;;
    esac
    return $?
  fi
  kind=$(_fm_proc_windows_pid_kind "$pid") || return 1
  [ "$kind" = ambiguous ] && return 1
  if [ "$field" = ppid ] && [ "$kind" = msys ] && [ -r "/proc/$pid/ppid" ]; then
    line=$(cat "/proc/$pid/ppid" 2>/dev/null) || return 1
    if [ "$line" != 1 ]; then
      printf '%s\n' "$line"
      return 0
    fi
  fi
  line=$(_fm_proc_windows_line "$pid") || return 1
  case "$field" in
    ppid) line=${line#*$'\t'}; printf '%s\n' "${line%%$'\t'*}" ;;
    comm) line=${line#*$'\t'*$'\t'}; line=${line%%$'\t'*}; printf '%s\n' "${line%.[eE][xX][eE]}" ;;
    args) line=${line#*$'\t'*$'\t'*$'\t'}; printf '%s\n' "$line" ;;
    *) return 1 ;;
  esac
}

# True when pid $1 names a live process. On Windows an MSYS pid answers to
# kill -0; a Windows-native pid (the harness, recorded in the session lock) is
# checked with tasklist, which costs a fraction of a snapshot.
fm_proc_alive() {  # <pid>
  local kind
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$_FM_PROC_WINDOWS" -eq 0 ]; then
    kill -0 "$1" 2>/dev/null
    return $?
  fi
  kind=$(_fm_proc_windows_pid_kind "$1") || return 1
  if [ "$kind" = msys ] || [ "$kind" = ambiguous ]; then
    kill -0 "$1" 2>/dev/null && return 0
  fi
  case "$(tasklist.exe //FI "PID eq $1" //NH //FO CSV 2>/dev/null)" in
    *\""$1"\"*) return 0 ;;
  esac
  return 1
}

# True when command name $1 and argument string $2 are omp's own runtime when
# it is not the single compiled `omp` binary: Bun running the installed
# @oh-my-pi/pi-coding-agent CLI. On Windows `omp.exe` is only a launcher shim and
# this Bun process is the session itself - it loads the extensions, so it is the
# pid they record and the pid the session lock must anchor on.
fm_proc_is_omp_runtime() {  # <comm> <args>
  case "$(basename -- "$1")" in
    bun|bun.exe) ;;
    *) return 1 ;;
  esac
  case "$2" in
    *@oh-my-pi/pi-coding-agent/*|*@oh-my-pi\\pi-coding-agent\\*) return 0 ;;
  esac
  return 1
}
