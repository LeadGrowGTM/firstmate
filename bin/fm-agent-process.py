#!/usr/bin/env python3
"""Linux process evidence for recovery; never sends signals or reads terminal input."""
import os
from pathlib import Path
import stat
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


AGENT_NAME_FRAGMENTS = ('claude', 'codex', 'opencode', 'grok', 'kimi',
                        'cursor', 'gemini', 'devin')
AGENT_NAMES = {'pi', 'pi-signed', 'pi-launcher', 'omp', 'agy', 'rovo'}


def agent_named(pid):
    try:
        name = (Path('/proc') / str(pid) / 'comm').read_text().strip().lstrip('-')
    except OSError:
        return True
    base = os.path.basename(name)
    return (base in AGENT_NAMES or base.startswith('muse-bin-')
            or any(fragment in base for fragment in AGENT_NAME_FRAGMENTS))


BRIDGE_SCRIPT_SUFFIX = '/chrome-devtools-axi/dist/bin/chrome-devtools-axi-bridge.js'


def cmdline(pid):
    raw = (Path('/proc') / str(pid) / 'cmdline').read_bytes()
    if not raw:
        return []
    parts = raw.split(b'\0')
    if parts and parts[-1] == b'':
        parts.pop()
    return [part.decode('utf-8', 'surrogateescape') for part in parts]


def stat_row(pid):
    row = (Path('/proc') / str(pid) / 'stat').read_text().rsplit(')', 1)[1].split()
    return row[0], int(row[1]), int(row[2]), int(row[3])


def harness_argv(argv):
    for arg in argv:
        base = os.path.basename(arg).lstrip('-')
        if not base:
            continue
        if (base in AGENT_NAMES or base.startswith('muse-bin-')
                or any(fragment in base for fragment in AGENT_NAME_FRAGMENTS)):
            return True
    return False


def orphan_bridge_process(pid):
    """Detached chrome-devtools-axi bridge reparented off the agent.

    The argv has to be exactly `node` and the bridge script. The process has
    to be its own session leader, which is what `detached: true` does, and its
    parent has to be pid 1 or the user session manager. A bridge still parented
    to an ordinary process is not this case.
    """
    try:
        argv = cmdline(pid)
        _, ppid, _, sid = stat_row(pid)
    except (OSError, ValueError, IndexError):
        return False
    if sid != int(pid) or len(argv) != 2:
        return False
    if os.path.basename(argv[0]) != 'node':
        return False
    script = argv[1]
    if not script.endswith(BRIDGE_SCRIPT_SUFFIX):
        return False
    if ppid == 1:
        return True
    return session_manager(ppid)


def orphan_bridge_noise(pid):
    """The orphan bridge, or a descendant that is not itself a harness."""
    try:
        if agent_named(pid) or harness_argv(cmdline(pid)):
            return False
    except OSError:
        return False
    current = int(pid)
    seen = set()
    hops = 0
    while current > 1 and current not in seen and hops < 64:
        seen.add(current)
        hops += 1
        if orphan_bridge_process(current):
            return True
        try:
            current = stat_row(current)[1]
        except (OSError, ValueError, IndexError):
            return False
    return False


def session_manager(pid):
    try:
        proc = Path('/proc') / str(pid)
        name = proc.joinpath('comm').read_text().strip()
        if name == '(sd-pam)':
            return True
        if name != 'systemd':
            return False
        argv = [arg.decode('utf-8', 'surrogateescape') for arg in
                proc.joinpath('cmdline').read_bytes().rstrip(b'\0').split(b'\0')]
        return '--user' in argv
    except OSError:
        return False


def all_fds_are_terminal(pid):
    try:
        entries = list((Path('/proc') / str(pid) / 'fd').iterdir())
    except OSError:
        return False
    if not entries:
        return False
    for entry in entries:
        try:
            target = os.readlink(entry)
        except OSError:
            return False
        if target.endswith(' (deleted)'):
            target = target[:-10]
        if not (target in {'/dev/tty', '/dev/console', '/dev/ptmx'}
                or target.startswith('/dev/pts/')
                or (target.startswith('/dev/tty') and target[8:].isdigit())):
            return False
    return True


def terminal_input_shell(pid):
    state, _, group, tty, foreground = fields(pid)
    if not (state == 'S' and tty != 0 and group > 0 and group == foreground
            and shell_identity(pid)):
        return False
    wait = (Path('/proc') / str(pid) / 'wchan').read_text().strip()
    if wait in {'n_tty_read', 'tty_read'}:
        return True
    # An idle interactive shell does not universally sit in a tty-read wait:
    # bash readline waits in do_select on its terminal descriptors and dash
    # in a generic wait_woken. Those waits are terminal-input evidence only
    # when every open descriptor is a terminal, which separates an idle
    # prompt from a builtin read on an unrelated descriptor (that descriptor
    # is open and non-terminal) and from a busy loop (never in state S).
    return (wait in {'do_select', 'do_sys_poll', 'poll_schedule_timeout',
                     'wait_woken'}
            and all_fds_are_terminal(pid))


def descendant(candidate, original):
    visited = set()
    while candidate != original and candidate > 1 and candidate not in visited:
        visited.add(candidate)
        candidate = fields(candidate)[1]
    return candidate == original


def pane_input_shell(candidate, original):
    return (shell_identity(original) and terminal_input_shell(candidate)
            and descendant(candidate, original))


SHELL_INTERPRETERS = {'bash', 'sh', 'dash', 'ash', 'ksh', 'mksh', 'zsh', 'env'}


def home_procevent_script(root):
    """The home's own runner, only as a regular file at that exact path.

    A secondmate home is its code root, so the runner it starts is
    ``<home>/bin/fm-procevent.sh``. A symlink, or the same basename anywhere
    else, is not that script.
    """
    script = root + '/bin/fm-procevent.sh'
    try:
        info = os.lstat(script)
    except OSError:
        return None
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        return None
    try:
        if os.path.realpath(script) != script:
            return None
    except OSError:
        return None
    return script


def fm_home_is(pid, root):
    """True when this process has exactly one FM_HOME and it is ``root``."""
    try:
        raw = (Path('/proc') / str(pid) / 'environ').read_bytes()
    except OSError:
        return False
    found = [entry[len(b'FM_HOME='):] for entry in raw.split(b'\0')
             if entry.startswith(b'FM_HOME=')]
    if len(found) != 1:
        return False
    value = found[0].decode('utf-8', 'surrogateescape')
    if not value or '\n' in value or '\x00' in value:
        return False
    try:
        return os.path.realpath(value) == root
    except OSError:
        return False


def script_arg(arg, script):
    """True when this absolute argv path is exactly ``script``.

    ``normpath`` collapses ``..`` without looking at symlinks, so
    ``<home>/bin/link/../fm-procevent.sh`` can name a file outside the home
    while comparing equal to the home script. The kernel opens the resolved
    file, so the comparison has to resolve it too.
    """
    if not isinstance(arg, str) or not arg.startswith('/'):
        return False
    try:
        if not os.path.exists(arg):
            return False
        return os.path.realpath(arg) == script
    except OSError:
        return False


def trusted_interpreter_ids():
    """Device and inode of the shell interpreters this host actually has.

    A basename is not identity: a copy of another program named ``bash``
    has a different inode from ``/usr/bin/bash``. ``stat`` follows a
    symlink, so a path that points at the real interpreter counts as that
    interpreter. The result is cached for this process.
    """
    cached = getattr(trusted_interpreter_ids, 'ids', None)
    if cached is not None:
        return cached
    ids = set()
    for name in SHELL_INTERPRETERS:
        # Fixed prefixes only. A PATH entry can name a different program
        # bash, and that program must not become a trusted interpreter.
        for directory in ('/bin', '/usr/bin', '/usr/local/bin'):
            path = os.path.join(directory, name)
            try:
                info = os.stat(path)
            except OSError:
                continue
            if stat.S_ISREG(info.st_mode):
                ids.add((info.st_dev, info.st_ino))
    trusted_interpreter_ids.ids = ids
    return ids


def is_trusted_interpreter(pid):
    """True when ``/proc/<pid>/exe`` is one of this host's shell interpreters."""
    try:
        info = os.stat(f'/proc/{int(pid)}/exe')
    except (OSError, TypeError, ValueError):
        return False
    if not stat.S_ISREG(info.st_mode):
        return False
    return (info.st_dev, info.st_ino) in trusted_interpreter_ids()


def is_home_procevent_runner(pid, script, root):
    """The process is a shell interpreter executing this home's script.

    ``/proc/<pid>/exe`` has to be a shell interpreter installed on this
    host, not a renamed copy, and the live argv has to name an interpreter
    with this exact script path as the next argument. That is what the
    kernel leaves after ``#!/usr/bin/env bash``. An argv that only names
    the script, or that names a shell while the executable is something
    else, is not this runner. A basename, a copy of the script outside the
    home, or the path buried later in the argument list is not this runner
    either. FM_HOME must resolve to the same home.
    """
    try:
        argv = cmdline(pid)
    except OSError:
        return False
    if len(argv) < 2:
        return False
    if not is_trusted_interpreter(pid):
        return False
    if os.path.basename(argv[0]).lstrip('-') not in SHELL_INTERPRETERS:
        return False
    if not script_arg(argv[1], script):
        return False
    return fm_home_is(pid, root)


def home_procevent_listener(pid, root):
    """This home's process-event runner, or a non-harness descendant of one.

    The runner's listener command keeps the runner's cwd. It is part of the
    same listener. A harness-named process is never ignored, including one
    inside that tree. The watcher's automatic secondmate restart does not
    scan cwd at all, so this proof is the one exemption and both relaunch
    callers reach it through fm_control_rooted_processes.
    """
    script = home_procevent_script(root)
    if script is None:
        return False
    try:
        current = int(pid)
    except (TypeError, ValueError):
        return False
    if is_home_procevent_runner(current, script, root):
        return True
    try:
        if agent_named(current) or harness_argv(cmdline(current)):
            return False
    except OSError:
        return False
    seen = set()
    hops = 0
    try:
        current = stat_row(current)[1]
    except (OSError, ValueError, IndexError):
        return False
    while current > 1 and current not in seen and hops < 64:
        seen.add(current)
        hops += 1
        if is_home_procevent_runner(current, script, root):
            return True
        try:
            current = stat_row(current)[1]
        except (OSError, ValueError, IndexError):
            return False
    return False


def worktree_processes(root, original, excluded_ancestors=()):
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
            # A process positively attributed to an excluded ancestor tree
            # (a second mate's own crew pane) is that crew's worker, never
            # the agent this proof guards, even when its cwd cannot be read.
            try:
                if any(descendant(int(pid), ancestor)
                       for ancestor in excluded_ancestors):
                    continue
            except (OSError, ValueError, IndexError):
                pass
            # A live process whose cwd is unreadable (a non-dumpable process
            # the user owns, such as `systemd --user`) aborts the absence
            # proof only when it could be the surviving agent. With a pane
            # tree to compare against, an unreadable process outside that
            # tree and not itself harness-named cannot be the pane's agent:
            # a dumpable agent rooted in the worktree stays readable and is
            # still reported below. Without a pane tree, only the user
            # session manager and its PAM helper are positively not an
            # agent; every other unreadable process still refuses, so a
            # non-dumpable survivor rooted in the worktree is never treated
            # as absent.
            if agent_named(pid):
                raise RuntimeError(f"cannot read live process {pid}'s cwd")
            if original:
                try:
                    in_pane_tree = (int(pid) == original
                                    or descendant(int(pid), original))
                except (OSError, ValueError, IndexError):
                    in_pane_tree = True
                if in_pane_tree:
                    raise RuntimeError(f"cannot read live process {pid}'s cwd")
            elif not session_manager(pid):
                raise RuntimeError(f"cannot read live process {pid}'s cwd")
            continue
        literal = cwd == root or cwd.startswith(root + '/')
        deleted = cwd.endswith(' (deleted)') and (
            cwd[:-10] == root or cwd[:-10].startswith(root + '/'))
        if (literal or deleted) and (deleted or not task_shell(pid)):
            # An orphaned chrome-devtools-axi bridge keeps the cwd of whoever
            # launched it. It is not the agent this proof is guarding. A
            # harness-named process, including one inside that tree, still
            # counts. Deleted cwd stays unfiltered.
            try:
                if not deleted and orphan_bridge_noise(pid):
                    continue
            except (OSError, ValueError, IndexError):
                pass
            print(pid)


def pool_worktree_processes(root):
    root = os.path.realpath(root)
    with os.scandir('/proc') as inventory:
        for entry in inventory:
            if not entry.name.isdigit():
                continue
            try:
                cwd = os.path.realpath(os.readlink(entry.path + '/cwd'))
            except OSError:
                continue
            if cwd == root or cwd.startswith(root + '/'):
                print(entry.name)


try:
    mode, *args = sys.argv[1:]
    if sys.platform != 'linux':
        raise RuntimeError('Linux process proof unavailable')
    if mode == 'rooted':
        root, pane, *ancestors = args
        worktree_processes(root, int(pane) if pane else 0,
                           tuple(int(a) for a in ancestors))
    elif mode == 'pool-rooted':
        pool_worktree_processes(args[0])
    elif mode == 'home-procevent':
        root, pid = args
        sys.exit(0 if home_procevent_listener(int(pid), os.path.realpath(root)) else 1)
    elif mode == 'input':
        sys.exit(0 if terminal_input_shell(int(args[0])) else 1)
    else:
        raise ValueError('unknown process-proof mode')
except (OSError, RuntimeError, ValueError, subprocess.SubprocessError, IndexError) as error:
    if sys.argv[1:2] == ['rooted']:
        print(f'process absence unproven: {error}', file=sys.stderr)
    sys.exit(1)
