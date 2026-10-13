#!/usr/bin/env bash
set -eu
lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
log=/home/mitch/.no-mistakes/evidence/01M4VNDAD4QTCRG15CBSNB45NK/live-deadweight-transcript.log
rcfile="$lab/rc"
cleanup() {
  TMUX_TMPDIR="$lab/tmux" tmux -L fm-lab kill-server >/dev/null 2>&1 || true
  python3 - "$lab" <<'PY'
import pathlib, shutil, sys
p = pathlib.Path(sys.argv[1])
if p.parent != pathlib.Path('/tmp') or not p.name.startswith('fm-lab.') or not (p / '.fm-lab-home').is_file():
    raise SystemExit('refusing to remove non-lab path')
shutil.rmtree(p)
PY
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$lab" >/dev/null
mkdir -p "$lab/tmux"
runner="env HOME=$lab/user FM_HOME=$lab bash /home/mitch/.no-mistakes/evidence/01M4VNDAD4QTCRG15CBSNB45NK/live-deadweight-check.sh > $log 2>&1; printf '%s' \$? > $rcfile"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$lab/tmux" tmux -L fm-lab new-session -d -s firstmate -c "$PWD" "$runner"
i=0
while [ ! -f "$rcfile" ] && [ "$i" -lt 240 ]; do sleep 0.25; i=$((i+1)); done
if [ ! -f "$rcfile" ]; then echo 'timeout waiting for live lab' >> "$log"; cat "$log"; exit 124; fi
cat "$log"
exit "$(cat "$rcfile")"
