#!/usr/bin/env python3
"""Linux process evidence for recovery; never sends signals or reads terminal input."""
import os
from pathlib import Path
import subprocess
import sys

SHELLS = {'zsh', 'bash', 'sh', 'dash', 'ash', 'ksh', 'mksh', 'tcsh', 'csh', 'fish'}
INTERACTIVE_FLAGS = {'-i', '-l', '-il', '-li', '--login', '--noprofile', '--norc', '-f'}


def fields(pid):
    row = (Path('/proc') / str(pid) / 'stat').read_text().rsplit(')', 1)[1].split()
    return row[0], int(row[1]), int(row[2]), int(row[4]), int(row[5])


def shell_identity(pid):
    proc = Path('/proc') / str(pid)
    if proc.stat().st_uid != os.geteuid():
        return False
    name = proc.joinpath('comm').read_text().strip().lstrip('-')
    argv = [arg.decode('utf-8', 'surrogateescape') for arg in
            proc.joinpath('cmdline').read_bytes().rstrip(b'\0').split(b'\0')]
    return (name in SHELLS and bool(argv[0])
            and os.path.basename(argv[0]).lstrip('-') in SHELLS
            and all(arg in INTERACTIVE_FLAGS for arg in argv[1:]))


def terminal_input_shell(pid):
    state, _, group, tty, foreground = fields(pid)
    # Generic do_select/wait_woken also describe active builtin reads on other
    # descriptors. Only a kernel tty-read wait is evidence of terminal input.
    wait = (Path('/proc') / str(pid) / 'wchan').read_text().strip()
    return (state == 'S' and tty != 0 and group > 0 and group == foreground
            and wait in {'n_tty_read', 'tty_read'} and shell_identity(pid))


def descendant(candidate, original):
    visited = set()
    while candidate != original and candidate > 1 and candidate not in visited:
        visited.add(candidate)
        candidate = fields(candidate)[1]
    return candidate == original


def pane_input_shell(candidate, original):
    return (shell_identity(original) and terminal_input_shell(candidate)
            and descendant(candidate, original))


def worktree_processes(root, original):
    inventory = subprocess.run(['ps', '-u', str(os.geteuid()), '-o', 'pid='],
                               check=True, capture_output=True, text=True).stdout.split()
    if not inventory or any(not pid.isdigit() for pid in inventory):
        raise RuntimeError('unreadable process inventory')

    def task_shell(pid):
        if not original:
            return False
        try:
            if pane_input_shell(int(pid), original):
                return True
            # A pane's parent shell may be waiting for its nested foreground
            # shell. Exempt it only when that foreground shell has tty proof.
            state, _, _, _, foreground = fields(pid)
            if (int(pid) != original or state != 'S' or not shell_identity(pid)
                    or (Path('/proc') / pid / 'wchan').read_text().strip() != 'do_wait'):
                return False
            return any(fields(child)[2] == foreground and
                       pane_input_shell(int(child), original) for child in inventory)
        except (OSError, ValueError, IndexError):
            return False

    for pid in inventory:
        proc = Path('/proc') / pid
        try:
            cwd = os.readlink(proc / 'cwd')
        except OSError:
            try:
                state = fields(pid)[0]
            except FileNotFoundError:
                continue
            if state == 'Z':
                continue
            raise RuntimeError(f"cannot read live process {pid}'s cwd")
        literal = cwd == root or cwd.startswith(root + '/')
        deleted = cwd.endswith(' (deleted)') and (
            cwd[:-10] == root or cwd[:-10].startswith(root + '/'))
        if (literal or deleted) and (deleted or not task_shell(pid)):
            print(pid)


try:
    mode, *args = sys.argv[1:]
    if sys.platform != 'linux':
        raise RuntimeError('Linux process proof unavailable')
    if mode == 'rooted':
        root, pane = args
        worktree_processes(root, int(pane) if pane else 0)
    elif mode == 'input':
        sys.exit(0 if terminal_input_shell(int(args[0])) else 1)
    else:
        raise ValueError('unknown process-proof mode')
except (OSError, RuntimeError, ValueError, subprocess.SubprocessError, IndexError) as error:
    if sys.argv[1:2] == ['rooted']:
        print(f'process absence unproven: {error}', file=sys.stderr)
    sys.exit(1)
