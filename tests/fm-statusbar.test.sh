#!/usr/bin/env bash
# tests/fm-statusbar.test.sh - behavior of bin/fm-statusbar.sh: the tmux detail
# line (narrow widths, missing fields, grouped view sessions), the cached usage
# segment, and the Claude statusLine command (whitelisted fields, no secrets).
# Real tmux on a private socket behind a PATH shim, so no live session is touched.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SB="$ROOT/bin/fm-statusbar.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; [ -z "${2:-}" ] || printf '%s\n' "$2" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-statusbar-$$"
OUTER="fm-statusbar-outer-$$"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-statusbar.XXXXXX")
cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  "$REAL_TMUX" -L "$OUTER" kill-server >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/bin" "$WORK/state"
cat >"$WORK/bin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
cat >"$WORK/bin/quota-axi" <<SH
#!/usr/bin/env bash
echo run >>"$WORK/quota-calls"
cat <<'X'
quota[3]{provider,scope,effectivePercentRemaining,spendPriority}:
  claude,all_models,68,0.4
  codex,all_models,85,-1.9
  claude,"model:fable",12,0.8
X
SH
chmod +x "$WORK/bin/tmux" "$WORK/bin/quota-axi"
export PATH="$WORK/bin:$PATH"
export FM_STATE_OVERRIDE="$WORK/state"
export FM_STATUSBAR_USAGE_TTL=60

tmux new-session -d -s firstmate -x 150 -y 20 -n fm-demo-task "sleep 600" || fail "scratch server did not start"
tmux new-window -d -t firstmate: -n bare "sleep 600"
tmux new-session -d -t firstmate -s orca-view -x 150 -y 20
tmux new-session -d -s unrelated -x 150 -y 20 "sleep 600"

# Render the second status line of <session> at a client width, via an outer
# tmux that attaches it. Prints the two bottom lines: window list, then detail.
render() {  # <session> <width>
  local out i=0
  if "$REAL_TMUX" -L "$OUTER" has-session 2>/dev/null; then
    "$REAL_TMUX" -L "$OUTER" kill-server >/dev/null 2>&1 || true
    while "$REAL_TMUX" -L "$OUTER" has-session 2>/dev/null; do sleep 0.1; done
  fi
  "$REAL_TMUX" -L "$OUTER" new-session -d -x "$2" -y 6 \
    "env -u TMUX '$REAL_TMUX' -L '$SOCKET' attach -t '$1'" || return 1
  while [ "$i" -lt 40 ]; do
    out=$("$REAL_TMUX" -L "$OUTER" capture-pane -p | grep -v '^[[:space:]]*$' | tail -2)
    case "$out" in *"fm-"* | *bare* | *unlabeled*) break ;; esac
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# --- label + apply: grouped view session gets the line, unrelated one does not ---
bash "$SB" label firstmate:fm-demo-task fm-demo-task ship claude 'claude-opus-5-5[1m]' high \
  /home/u/.treehouse/firstmate-840e8b/17/firstmate
bash "$SB" apply firstmate
[ "$(tmux show-options -qv -t orca-view status)" = 2 ] || fail "view session in the group did not get the detail line"
[ "$(tmux show-options -qv -t firstmate status)" = 2 ] || fail "base session did not get the detail line"
[ -z "$(tmux show-options -qv -t unrelated status)" ] || fail "an ungrouped session was changed"
pass "apply covers the session group and leaves other sessions alone"

tmux select-window -t orca-view:fm-demo-task
wide=$(render orca-view 160)
case "$wide" in
*"0:"*"fm-demo-task (ship)"*"opus-5-5 high"*"firstmate/17"*) pass "wide client shows task, model, effort, worktree" ;;
*) fail "wide render missing fields" "$wide" ;;
esac

narrow=$(render orca-view 60)
case "$narrow" in
*"fm-demo-task (ship)"*"opus-5-5 high"*) ;;
*) fail "narrow render lost task or model" "$narrow" ;;
esac
case "$narrow" in
*"firstmate/17"* | *used*) fail "narrow render kept low-priority fields" "$narrow" ;;
esac
[ "$(printf '%s\n' "$narrow" | tail -1 | wc -c)" -le 61 ] || fail "narrow render exceeds the client width" "$narrow"
pass "narrow client keeps task and model, drops worktree and usage"

# --- missing fields: an unlabeled window still renders something truthful ---
tmux select-window -t orca-view:bare
bare=$(render orca-view 120)
case "$bare" in
*bare*"sleep"*) pass "unlabeled window falls back to window name and live command" ;;
*) fail "unlabeled window render" "$bare" ;;
esac

# --- no secrets, no injection through option values ---
bash "$SB" label firstmate:bare 'x#(touch '"$WORK"'/pwned)#{pane_title}' ship claude 'm$(id)' high /tmp
for opt in @fm_task @fm_model; do
  v=$(tmux show-options -wqv -t firstmate:bare "$opt")
  case "$v" in *'#'* | *'$'* | *'{'* | *'['*) fail "option $opt kept format metacharacters" "$v" ;; esac
done
sleep 1
[ ! -e "$WORK/pwned" ] || fail "an option value executed a command"
pass "option values are stripped of format and shell metacharacters"

# --- usage: cached, refreshed in the background no more than once per TTL ---
# Rendering the wide line above already ran the segment once; start from clean.
tmux kill-session -t orca-view 2>/dev/null || true
"$REAL_TMUX" -L "$OUTER" kill-server >/dev/null 2>&1 || true
i=0
while [ -d "$WORK/state/.statusbar-usage.lock" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
rm -f "$WORK/state/statusbar-usage.txt" "$WORK/quota-calls"
[ -z "$(bash "$SB" usage)" ] || fail "first usage read should be empty before the cache exists"
i=0
while [ ! -s "$WORK/state/statusbar-usage.txt" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ "$(cat "$WORK/state/statusbar-usage.txt")" = "used cl 32% cx 15%" ] || fail "usage cache content" "$(cat "$WORK/state/statusbar-usage.txt" 2>&1)"
[ "$(bash "$SB" usage)" = "used cl 32% cx 15%" ] || fail "usage did not serve the cache"
bash "$SB" usage >/dev/null
bash "$SB" usage >/dev/null
sleep 0.5
[ "$(wc -l <"$WORK/quota-calls")" -eq 1 ] || fail "usage refreshed more than once inside the TTL" "$(cat "$WORK/quota-calls")"
grep -qi 'token\|secret\|key' "$WORK/state/statusbar-usage.txt" && fail "usage cache holds credential-like text"
pass "usage is a cached percentage figure refreshed at most once per TTL"

# --- claude-line: whitelisted fields only ---
json='{"model":{"display_name":"Opus 5.5"},"effort":{"level":"high"},"context_window":{"used_percentage":7.4},"rate_limits":{"five_hour":{"used_percentage":31},"seven_day":{"used_percentage":11}},"workspace":{"current_dir":"/x/y/firstmate","git_worktree":"firstmate2"},"transcript_path":"/home/u/SECRET-transcript.jsonl","session_id":"abc-123","cost":{"total_cost_usd":1.5}}'
line=$(printf '%s' "$json" | bash "$SB" claude-line --task fm-demo-task --kind ship)
[ "$line" = "Opus 5.5 high | fm-demo-task (ship) | firstmate2 | ctx 7% | 5h 31% 7d 11%" ] || fail "claude-line output" "$line"
case "$line" in *SECRET* | *abc-123* | *1.5*) fail "claude-line leaked a non-whitelisted field" "$line" ;; esac
pass "claude-line prints only model, effort, task, worktree, context and rate limits"

sparse=$(printf '%s' '{"model":{"display_name":"Haiku"}}' | bash "$SB" claude-line --task t1)
[ "$sparse" = "Haiku | t1" ] || fail "claude-line with missing fields" "$sparse"
empty=$(printf '' | bash "$SB" claude-line)
[ -z "$empty" ] || fail "claude-line with empty input should print nothing useful" "$empty"
pass "claude-line tolerates missing fields and empty input"

# --- sync labels windows from recorded task metadata ---
cat >"$WORK/state/sync-task.meta" <<META
window=firstmate:bare
harness=codex
kind=scout
model=gpt-6-sol
effort=medium
worktree=/home/u/.treehouse/proj-abc123/4/proj
META
bash "$SB" sync
[ "$(tmux show-options -wqv -t firstmate:bare @fm_task)" = sync-task ] || fail "sync did not label the recorded window"
[ "$(tmux show-options -wqv -t firstmate:bare @fm_wt)" = proj/4 ] || fail "sync worktree label" "$(tmux show-options -wqv -t firstmate:bare @fm_wt)"
pass "sync labels recorded windows from state metadata"

# --- reset restores tmux defaults for the whole group ---
bash "$SB" reset firstmate
[ -z "$(tmux show-options -qv -t firstmate status)" ] || fail "reset left the detail line on"
pass "reset restores the group's defaults"

echo "fm-statusbar: all passed"
