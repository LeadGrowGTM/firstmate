#!/usr/bin/env bash
# Backend-neutral harness-process identity.
# Sourced by bin/backends/tmux.sh and bin/backends/herdr.sh. This file is
# sourced by scripts and has no side effects on source.
#
# Why one owner: every runtime backend that proves an agent is alive does it by
# attributing operating-system processes - the pane's foreground process group
# on tmux, Herdr's `pane process-info` view plus the pane shell's descendants
# on Herdr - and the two must agree on what a given process name means, or a
# harness one backend recognizes silently reads as a dead pane on the other.
# The classifier moved here verbatim from the tmux adapter, where it was born;
# docs/tmux-backend.md "Agent liveness probe" owns the empirical basis for the
# names below, and tests/fm-tmux-agent-liveness.test.sh plus
# tests/fm-harness-liveness-drift-live-e2e.test.sh keep them honest.

_FM_AGENT_PROCESS_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_AGENT_PROCESS_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_AGENT_PROCESS_LIB_DIR=.
# shellcheck source=bin/fm-session-lock-lib.sh
. "${_FM_AGENT_PROCESS_LIB_DIR:-/}/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-gemini-lib.sh
. "${_FM_AGENT_PROCESS_LIB_DIR:-/}/fm-gemini-lib.sh"
unset _FM_AGENT_PROCESS_LIB_DIR

# fm_agent_process_classify_name: the single owner of the process-name
# vocabulary shared by every liveness signal - `agent` for a verified harness,
# `shell` for an idle login/interactive shell, `other` for anything else.
# Keeping one classifier means independent name sources (a kernel process
# name, an argv[0], a rendered pane title) can never drift into disagreeing
# about what a given name means.
fm_agent_process_classify_name() {  # <path> [argv0] -> agent|shell|other
  local path=$1 argv0=${2:-} base
  base=${path##*/}
  base=${base#-}
  case "$base" in
    # muse is anchored rather than globbed like its neighbours: its installed
    # binary is muse-bin-<version> (the launcher execs it, so the version is the
    # live process name and changes on every auto-update), and unlike `claude` or
    # `codex` the substring `muse` is a common English fragment - a *muse* glob
    # would classify musescore or amuse as a live agent pane. The install path
    # cannot carry it either: ~/.local/bin/muse-bin-<version> has no `muse` path
    # COMPONENT, so the fm_harness_path_name fallback below never fires for it.
    muse|muse-bin-*) printf 'agent' ;;
    # omp (Oh My Pi) is anchored for the same reason as muse: its live process
    # name is the bare word `omp` (verified, omp 18.1.11) and a glob would claim
    # unrelated commands such as ompd or comp.
    *claude*|*codex*|*opencode*|*grok*|*kimi*|*rovo*|pi|pi-signed|pi-launcher|Pi|omp) printf 'agent' ;;
    # agy (Antigravity CLI) is anchored for the same reason as muse and omp: its
    # live process name is the bare word `agy` (verified, agy 1.2.0: a Go-compiled
    # single binary, comm=agy with argv[0]=agy), and a glob would claim
    # unrelated commands containing that fragment. devin is anchored the same
    # way (verified, devin 3000.11.1: comm=devin), so a `*devin*` glob never
    # claims an unrelated command.
    agy|devin) printf 'agent' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'shell' ;;
    *)
      if fm_harness_path_name "$path" >/dev/null || fm_harness_path_name "$argv0" >/dev/null; then
        printf 'agent'
      # cursor-agent runs as a bundled node script, so tmux reports the pane
      # command as a bare `node` that no name pattern above can own, and its
      # other installed name is the far-too-generic `agent` (verified live on
      # cursor-agent 2026.08.11-e8db854: #{pane_current_command} is `node` while
      # `ps -o comm=` carries the cursor-agent install path). Identity therefore
      # comes from the narrowed structural rule in bin/fm-cursor-lib.sh, which
      # demands Cursor's own name or install tree in the path or argv[0]. An
      # unrelated `node` or `agent` matches nothing here and stays `other`,
      # which the callers fold into `ambiguous` rather than `dead`, so a
      # stranger's node pane is never reported as an agent-free pane.
      elif fm_cursor_process_matches "${path:-$argv0}" '' "$argv0"; then
        printf 'agent'
      else
        printf 'other'
      fi
      ;;
  esac
}

# fm_agent_process_classify: one process, from every identity surface a
# backend can hand over, as agent|shell|other. Any single surface naming a
# verified harness carries `agent`, because a false negative is the one outcome
# that launches a duplicate agent onto a live worktree; `shell` needs every
# readable surface to agree the process is a shell; anything else is `other`.
#
#   <name>   the kernel process name (ps comm, or Herdr's process-info .name):
#            on Linux the exec name, on macOS argv[0] truncated to 16 bytes.
#   <argv0>  argv[0] as the process reports it - a bare name or an install
#            path, whichever the launcher used (empty when unknown).
#   <args>   the flattened command line, read only for the node-bundle
#            harnesses whose identity sits in argv[1] (bin/fm-gemini-lib.sh).
#   [pid]    when given, lets the Gemini rule read argv boundaries from the
#            live process instead of the flattened line.
fm_agent_process_classify() {  # <name> <argv0> <args> [pid] -> agent|shell|other
  local name=${1:-} argv0=${2:-} args=${3:-} pid=${4:-} by_name by_argv0
  by_name=$(fm_agent_process_classify_name "$name" "$argv0")
  [ "$by_name" != agent ] || { printf 'agent'; return 0; }
  if [ -n "$argv0" ]; then
    # argv[0] is classified as a path in its own right, so a bare `pi` or a
    # `-zsh` login name reads by basename and an install path by component.
    by_argv0=$(fm_agent_process_classify_name "$argv0" "$argv0")
    [ "$by_argv0" != agent ] || { printf 'agent'; return 0; }
  else
    by_argv0=$by_name
  fi
  if [ -n "$pid" ] && fm_gemini_pid_is_gemini "$pid"; then
    printf 'agent'
    return 0
  fi
  if [ -n "$args" ] && fm_gemini_args_are_gemini "$args"; then
    printf 'agent'
    return 0
  fi
  if [ "$by_name" = shell ] && [ "$by_argv0" = shell ]; then
    printf 'shell'
  else
    printf 'other'
  fi
}

# Recovery proof, independent of harness names: EVERY same-user process rooted
# in the recorded copy is a possible surviving worker. No signals are sent.
# Print matching pids; a failed inventory or an unreadable live cwd refuses.
# Linux uses kernel cwd links, including descendants in subdirectories. macOS
# uses the bounded cwd-only lsof inventory, never a recursive file-tree walk.
fm_agent_worktree_processes() {  # <worktree> [<pane-shell-pid>] [allow-missing] -> pids (empty means none)
  local worktree=$1 excluded_pid=${2:-} allow_missing=${3:-} out pid path line parent leaf deleted_match
  if [ -d "$worktree" ]; then
    worktree=$(CDPATH='' cd -- "$worktree" && pwd -P) || return 1
  else
    [ "$allow_missing" = allow-missing ] || return 1
    [ ! -e "$worktree" ] && [ ! -L "$worktree" ] || return 1
    parent=${worktree%/*}
    leaf=${worktree##*/}
    [ -n "$parent" ] && [ -n "$leaf" ] && [ "$leaf" != . ] && [ "$leaf" != .. ] || return 1
    parent=$(CDPATH='' cd -- "$parent" && pwd -P) || return 1
    worktree="$parent/$leaf"
  fi
  case "$excluded_pid" in ''|*[!0-9]*) excluded_pid= ;; esac
  case "$(uname -s)" in
    Linux)
      python3 - "$worktree" "$excluded_pid" <<'PY'
import os
from pathlib import Path
import subprocess
import sys

try:
    root, excluded = sys.argv[1:]
    inventory = subprocess.run(
        ["ps", "-u", str(os.geteuid()), "-o", "pid="],
        check=True, capture_output=True, text=True,
    ).stdout.split()
    if not inventory or any(not pid.isdigit() for pid in inventory):
        raise RuntimeError("unreadable process inventory")
    def process_fields(pid):
        fields = ((Path('/proc') / pid / 'stat').read_text()).rsplit(')', 1)[1].split()
        return int(fields[1]), int(fields[2]), int(fields[5]), fields[0]

    def idle_shell(pid):
        name = ((Path('/proc') / pid / 'comm').read_text()).strip().lstrip('-')
        shells = {'zsh', 'bash', 'sh', 'dash', 'ash', 'ksh', 'mksh', 'tcsh', 'csh', 'fish'}
        if name not in shells:
            return False
        argv = [arg.decode('utf-8', 'surrogateescape') for arg in
                (Path('/proc') / pid / 'cmdline').read_bytes().rstrip(b'\0').split(b'\0')]
        return (bool(argv[0]) and os.path.basename(argv[0]).lstrip('-') in shells
                and all(arg in {'-i', '-l', '-il', '-li', '--login',
                                '--noprofile', '--norc', '-f'} for arg in argv[1:]))

    def task_shell(pid):
        if not excluded or not excluded.isdigit():
            return False
        original = int(excluded)
        try:
            if not idle_shell(str(original)) or not idle_shell(pid):
                return False
            if int(pid) == original:
                return True
            _, group, foreground, _ = process_fields(pid)
            if group <= 0 or group != foreground:
                return False
            current = int(pid)
            while current != original and current > 1:
                current = process_fields(str(current))[0]
            return current == original
        except (OSError, ValueError, IndexError):
            return False

    for pid in inventory:
        process = Path("/proc") / pid
        try:
            cwd = os.readlink(process / "cwd")
        except OSError:
            try:
                stat = (process / "stat").read_text()
            except FileNotFoundError:
                continue
            fields = stat.rsplit(")", 1)[1].split()
            if fields[0] == "Z":
                continue
            raise RuntimeError(f"cannot read live process {pid}'s cwd")
        literal_match = cwd == root or cwd.startswith(root + "/")
        deleted_match = cwd.endswith(' (deleted)') and (
            cwd[:-10] == root or cwd[:-10].startswith(root + "/"))
        if (literal_match or deleted_match) and (deleted_match or not task_shell(pid)):
            print(pid)
except (OSError, RuntimeError, ValueError, subprocess.SubprocessError, IndexError) as error:
    print(f"process absence unproven: {error}", file=sys.stderr)
    sys.exit(1)
PY
      ;;
    Darwin)
      out=$(lsof -a -u "$(id -u)" -d cwd -Fpn 2>&1) || return 1
      [ -n "$out" ] || return 1
      pid=
      while IFS= read -r line; do
        case "$line" in
          p*) pid=${line#p}; case "$pid" in ''|*[!0-9]*) return 1 ;; esac ;;
          fcwd) [ -n "$pid" ] || return 1 ;;
          n*)
            [ -n "$pid" ] || return 1
            path=${line#n}
            deleted_match=0
            case "$path" in
              "$worktree"|"$worktree"/*)
                case "$path" in *' (deleted)') deleted_match=1 ;; esac
                if [ "$deleted_match" = 0 ] && [ -n "$excluded_pid" ] \
                  && fm_agent_verified_pane_shell "$pid" "$excluded_pid"; then
                  :
                else
                  printf '%s\n' "$pid"
                fi
                ;;
              *' (deleted)')
                path=${path% (deleted)}
                case "$path" in "$worktree"|"$worktree"/*) printf '%s\n' "$pid" ;; esac
                ;;
            esac
            ;;
          '') ;;
          *) return 1 ;;
        esac
      done <<EOF
$out
EOF
      ;;
    *) return 1 ;;
  esac
}

fm_agent_verified_pane_shell() {
  python3 - "$1" "$2" <<'PY'
import subprocess
import sys
import shlex
import os

shells = {'zsh', 'bash', 'sh', 'dash', 'ash', 'ksh', 'mksh', 'tcsh', 'csh', 'fish'}

def fields(pid):
    row = subprocess.run(
        ['ps', '-p', str(pid), '-o', 'ppid=,pgid=,tpgid=,comm='],
        check=True, capture_output=True, text=True,
    ).stdout.split()
    if len(row) != 4:
        raise ValueError('unreadable process identity')
    return int(row[0]), int(row[1]), int(row[2]), row[3].split('/')[-1].lstrip('-')

def idle_shell(pid):
    args = subprocess.run(
        ['ps', '-p', str(pid), '-o', 'args='],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    argv = shlex.split(args)
    return (bool(argv) and os.path.basename(argv[0]).lstrip('-') in shells
            and all(arg in {'-i', '-l', '-il', '-li', '--login',
                            '--noprofile', '--norc', '-f'} for arg in argv[1:]))

try:
    candidate, original = map(int, sys.argv[1:])
    if fields(original)[3] not in shells or fields(candidate)[3] not in shells \
            or not idle_shell(original) or not idle_shell(candidate):
        sys.exit(1)
    if candidate != original:
        _, group, foreground, _ = fields(candidate)
        if group <= 0 or group != foreground:
            sys.exit(1)
        while candidate != original and candidate > 1:
            candidate = fields(candidate)[0]
    sys.exit(0 if candidate == original else 1)
except (OSError, ValueError, subprocess.SubprocessError):
    sys.exit(1)
PY
}
