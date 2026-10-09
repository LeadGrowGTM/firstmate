#!/usr/bin/env bash
# usage: classify.sh <fm-root> <lab> ; prints timestamped classifier verdict + record
R=$1 LAB=$2
. "$R/bin/fm-backend.sh" 2>/dev/null
. "$R/bin/fm-busy-lib.sh"
v=$(TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" fm_busy_classify tmux firstmate:fm-design claude design "$LAB/state" "")
printf '%s classify=[%s] record=[%s]\n' "$(date +%T)" "$v" "$(cat "$LAB/state/design.busy-state")"
