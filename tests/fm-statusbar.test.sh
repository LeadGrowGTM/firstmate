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

statusbar() {  # <script> <explicit-private-socket> <command> [args...]
  local script=${1-} socket=${2-}
  [ -n "$socket" ] || { printf 'statusbar fixture requires an explicit private socket\n' >&2; return 2; }
  shift 2
  bash "$script" --socket "$socket" "$@"
}

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
: >"$WORK/empty.conf"
cat >"$WORK/bin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" -f "$WORK/empty.conf" "\$@"
SH
cat >"$WORK/bin/quota-axi" <<SH
#!/usr/bin/env bash
echo run >>"$WORK/quota-calls"
[ ! -f "$WORK/quota-fail" ] || exit 1
[ ! -f "$WORK/quota-hang" ] || sleep 15
cat <<'X'
quota[17]{provider,accountKey,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  claude,default,all_models,68,0.4,through_reset,high,none,none
  codex,default,all_models,68,0.4,through_reset,high,none,none
  grok,default,all_models,45,0.4,through_reset,high,none,none
  grok,xai,all_models,20,0.4,through_reset,high,none,none
  agy,default,all_models,40,0.4,through_reset,high,none,none
  codex,codex-home,all_models,0.5,-1.9,through_reset,high,none,none
  codex,openai-codex-home,all_models,4,-1.9,through_reset,high,none,none
  codex,openai-codex-work,all_models,0.5,-1.9,through_reset,high,none,none
  codex,openai-codex-work2,all_models,0.5,-1.9,through_reset,high,none,none
  codex,openai-codex-hi,all_models,0.04,-1.9,through_reset,high,none,none
  codex,openai-codex-lo,all_models,99.9999,-1.9,through_reset,high,none,none
  codex,openai-codex-scoped,"model:gpt-6-astra",2,-1.9,through_reset,high,none,none
  codex,openai-codex-unknown,all_models,headroom_unknown,-1.9,unknown,low,none,none
  claude,default,"model:fable",12,0.8,through_reset,high,none,none
  claude,default,"model:claude-opus-5-5[1m]",90,0.8,through_reset,high,none,none
  claude,default,"model:claude-3-5-sonnet",9,0.8,through_reset,high,none,none
  claude,default,"product:special-product",18,0.8,through_reset,high,none,none
attention[1]{provider,accountKey,scope,kind,detail,remedy}:
  codex,openai-codex-attention,all,auth_required,login_required,none
X
SH
chmod +x "$WORK/bin/tmux" "$WORK/bin/quota-axi"
export PATH="$WORK/bin:$PATH"
export FM_STATE_OVERRIDE="$WORK/state"
export FM_SB_TRACKER_ROOT="$WORK"
export FM_SB_TRACKER_CACHE_DIR="$WORK/tracker-cache"

tmux new-session -d -s firstmate -x 150 -y 20 -n fm-demo-task "sleep 600" || fail "scratch server did not start"
tmux new-window -d -t firstmate: -n bare "sleep 600"
tmux new-session -d -t firstmate -s orca-view -x 150 -y 20
tmux new-session -d -s unrelated -x 150 -y 20 "sleep 600"
SOCKET_PATH=$(tmux display-message -p -t firstmate '#{socket_path}')
[ -n "$SOCKET_PATH" ] || fail "scratch server did not expose its private socket"
if statusbar "$SB" >/dev/null 2>&1; then fail "statusbar helper accepted a missing socket"; fi
if statusbar "$SB" '' label firstmate:bare refused claude opus high /tmp >/dev/null 2>&1; then
  fail "statusbar helper accepted an empty socket"
fi

# Render the bottom of a pane at a client width through an attached view.
render() {  # <session> <width> <expected>
  local out i=0
  if "$REAL_TMUX" -L "$OUTER" has-session 2>/dev/null; then
    "$REAL_TMUX" -L "$OUTER" kill-server >/dev/null 2>&1 || true
    while "$REAL_TMUX" -L "$OUTER" has-session 2>/dev/null; do sleep 0.1; done
  fi
  "$REAL_TMUX" -L "$OUTER" -f "$WORK/empty.conf" new-session -d -x "$2" -y 6 \
    "env -u TMUX '$REAL_TMUX' -L '$SOCKET' attach -t '$1'" || return 1
  while [ "$i" -lt 40 ]; do
    out=$("$REAL_TMUX" -L "$OUTER" capture-pane -p | grep -v '^[[:space:]]*$' | tail -3)
    case "$out" in *"$3"*) break ;; esac
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# --- label + apply: grouped view sessions share window options ---
statusbar "$SB" "$SOCKET_PATH" label firstmate:fm-demo-task fm-demo-task claude 'claude-opus-5-5[1m]' high \
  /home/u/.treehouse/firstmate-840e8b/17/firstmate
[ "$(tmux show-options -wqv -t firstmate:fm-demo-task @fm_wt)" = firstmate/17 ] || fail "Treehouse direct label lost its slot"
mkdir -p "$WORK/slots"
: >"$WORK/slots/treehouse-state.json"
tmux new-window -d -t firstmate: -n custom-pool 'sleep 600'
statusbar "$SB" "$SOCKET_PATH" label firstmate:custom-pool custom-pool claude opus high "$WORK/slots/1/project"
[ "$(tmux show-options -wqv -t firstmate:custom-pool @fm_wt)" = project/1 ] || fail "custom Treehouse direct label lost its slot"
tmux new-window -d -t firstmate: -n numeric-home 'sleep 600'
statusbar "$SB" "$SOCKET_PATH" label firstmate:numeric-home numeric-home claude opus high /home/u/homes/2026/firstmate
[ "$(tmux show-options -wqv -t firstmate:numeric-home @fm_wt)" = firstmate ] || fail "ordinary numeric-parent home gained a slot"
tmux set-option -t firstmate 'status-format[0]' 'CUSTOM #{window_name}'
statusbar "$SB" "$SOCKET_PATH" apply firstmate
if out=$(statusbar "$SB" "$SOCKET_PATH" apply 2>&1); then fail "apply accepted an implicit session"; fi
[ "$out" = 'usage: fm-statusbar.sh apply [--primary] <session>' ] || fail "apply did not request an explicit session" "$out"
[ "$(tmux show-options -wqv -t orca-view:fm-demo-task pane-border-status)" = bottom ] || fail "view window did not get the detail line"
[ -z "$(tmux show-options -wqv -t unrelated pane-border-status)" ] || fail "an ungrouped window was changed"
[ "$(tmux show-options -qv -t firstmate 'status-format[0]')" = 'CUSTOM #{window_name}' ] || fail "apply replaced a custom status line"
case "$(tmux show-options -qv -t firstmate status-right)" in *crew-tracker*) ;; *) fail "firstmate status-right missed the crew tracker" ;; esac
case "$(tmux show-options -qv -t orca-view status-right)" in *crew-tracker*) ;; *) fail "view status-right missed the crew tracker" ;; esac
[ "$(tmux show-options -qv -t orca-view status-right-length)" = 200 ] || fail "view status-right truncates the crew tracker"
case "$(tmux show-options -qv -t unrelated status-right)" in *crew-tracker*) fail "unrelated status-right was changed" ;; esac
tmux new-session -d -t firstmate -s orca-later -x 150 -y 20
[ "$(tmux show-options -wqv -t orca-later:fm-demo-task pane-border-status)" = bottom ] || fail "late view lost the detail line"
case "$(tmux show-options -qv -t orca-later status-right)" in *crew-tracker*) ;; *) fail "late view status-right missed the crew tracker" ;; esac
pass "apply preserves custom status and covers current and later grouped views"

tmux new-session -d -s rename-base -n rename-task 'sleep 600'
tmux new-session -d -t rename-base -s rename-view
tmux rename-session -t rename-base renamed-base
statusbar "$SB" "$SOCKET_PATH" apply renamed-base
tmux new-session -d -t renamed-base -s renamed-later
case "$(tmux show-options -qv -t renamed-later status-right)" in *crew-tracker*) ;; *) fail "renamed group late view missed the crew tracker" ;; esac
pass "renamed groups still format later views"

statusbar "$SB" "$SOCKET_PATH" usage firstmate:fm-demo-task >/dev/null
i=0
while [ ! -s "$WORK/state/statusbar-usage.txt" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
selected=$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:fm-demo-task)
[ "$selected" = 'u cl:default32%' ] || fail "Claude pane did not select its quota row" "$selected"
tmux new-window -d -t firstmate: -n fable "sleep 600"
statusbar "$SB" "$SOCKET_PATH" label firstmate:fable fable claude fable high /home/u/fable
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:fable)" = 'u cl:default32%' ] || fail "Fable pane showed a model quota as account usage"
tmux new-window -d -t firstmate: -n sonnet "sleep 600"
statusbar "$SB" "$SOCKET_PATH" label firstmate:sonnet sonnet claude claude-3-5-sonnet high /home/u/sonnet
[ "$(tmux show-options -wqv -t firstmate:sonnet @fm_model)" = '3-5-sonnet' ] || fail "quota identity changed the short model label"
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:sonnet)" = 'u cl:default32%' ] || fail "Sonnet pane showed a model quota as account usage"
tmux new-window -d -t firstmate: -n product "sleep 600"
statusbar "$SB" "$SOCKET_PATH" label firstmate:product product claude special-product high /home/u/product
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:product)" = 'u cl:default32%' ] || fail "product quota appeared as account usage"
pass "model and product quotas do not change account-wide usage"
statusbar "$SB" "$SOCKET_PATH" apply firstmate

tmux select-window -t orca-view:fm-demo-task
wide=$(render orca-view 160 'u cl:default32%')
case "$wide" in
*"u cl:default32%"*"fm-demo-task"*"opus-5-5[1m] high"*"firstmate/17"*) pass "wide client shows task, model, effort, worktree and usage" ;;
*) fail "wide render missing fields" "$wide" ;;
esac
status_bar=$("$REAL_TMUX" -L "$OUTER" capture-pane -p | tail -1)
case "$status_bar" in
*'crew: loading'|*'churchill:'*) ;;
*) fail "view status bar did not show the crew tracker" "$status_bar" ;;
esac
tmux select-window -t orca-view:fable
case "$(tmux show-options -wqv -t orca-view:fable pane-border-format)" in *'@fm_task'*) pass "pane detail still follows the active pane" ;; *) fail "pane detail format was lost" ;; esac
tmux select-window -t orca-view:fm-demo-task

tmux split-window -h -d -t firstmate:fm-demo-task "sleep 600"
split_width=$(tmux display-message -p -t firstmate:fm-demo-task.0 '#{pane_width}')
[ "$split_width" -ge 60 ] && [ "$split_width" -lt 100 ] || fail "split pane was not narrower than its client" "$split_width"
split=$(render orca-view 140 'u cl:default32%|fm-demo-t|')
case "$split" in
*'u cl:default32%|fm-demo-t|'*'opus-5-5[1 high'*) pass "wide client formats each split pane by pane width" ;;
*) fail "split pane used the client width layout" "$split" ;;
esac
tmux kill-pane -t firstmate:fm-demo-task.1

narrow=$(render orca-view 60 'u cl:default32%')
case "$narrow" in
*"u cl:default32%"*"fm-demo"*"opus-5-5[1 high"*"firstmate/"*) ;;
*) fail "narrow render lost a required field" "$narrow" ;;
esac
pass "narrow client keeps task, model, effort, worktree and usage"

compact=$(render orca-view 40 'u cl:default32%')
case "$compact" in
*"u cl:default32%"*"fm-"*"op h"*"fi"*) pass "compact client keeps all required fields" ;;
*) fail "compact render lost a required field" "$compact" ;;
esac

tmux new-window -d -t firstmate: -n codex-home "sleep 600"
statusbar "$SB" "$SOCKET_PATH" label firstmate:codex-home cx-home codex gpt-6-sol high /home/u/codex
statusbar "$SB" "$SOCKET_PATH" apply firstmate
tmux select-window -t orca-view:codex-home
home_usage=$(render orca-view 40 'u cx:codex-home99.5%')
case "$home_usage" in *'u cx:codex-home99.5%'*) ;; *) fail "native Codex selected another account" "$home_usage" ;; esac
tmux new-window -d -t firstmate: -n pi-work "sleep 600"
statusbar "$SB" "$SOCKET_PATH" label firstmate:pi-work pi-work pi openai-codex-work/gpt-6-sol high /home/u/pi
statusbar "$SB" "$SOCKET_PATH" apply firstmate
tmux select-window -t orca-view:pi-work
work_usage=$(render orca-view 40 'u cx:openai~ex-work99.5%')
case "$work_usage" in *'u cx:openai~ex-work99.5%'*) pass "each pane shows its selected account usage" ;; *) fail "Pi selected another account" "$work_usage" ;; esac
[ "$(tmux show-options -wqv -t firstmate:pi-work @fm_model)" = gpt-6-sol ] || fail "qualified model did not retain its model identity"
wide_work=$(render orca-view 100 'u cx:openai~ex-work99.5%')
case "$wide_work" in *'u cx:openai~ex-work99.5%'*'gpt-6-sol high'*) ;; *) fail "wide account usage or qualified model was clipped" "$wide_work" ;; esac
narrow_work=$(render orca-view 60 'u cx:openai~ex-work99.5%')
case "$narrow_work" in *'u cx:openai~ex-work99.5%'*'gpt-6-sol'*) pass "usage stays visible ahead of variable-width fields" ;; *) fail "narrow account usage or qualified model was clipped" "$narrow_work" ;; esac

tmux new-window -d -t firstmate: -n pi-work2 "sleep 600"
statusbar "$SB" "$SOCKET_PATH" label firstmate:pi-work2 pi-work2 pi openai-codex-work2/gpt-6-sol high /home/u/pi
statusbar "$SB" "$SOCKET_PATH" apply firstmate
tmux select-window -t orca-view:pi-work2
work2_usage=$(render orca-view 40 'u cx:openai~x-work299.5%')
case "$work2_usage" in *'u cx:openai~x-work299.5%'*) ;; *) fail "work and work2 labels collided at equal usage" "$work2_usage" ;; esac

tmux new-window -d -t firstmate: -n pi-home "sleep 600"
statusbar "$SB" "$SOCKET_PATH" label firstmate:pi-home pi-home pi openai-codex-home/gpt-6-sol high /home/u/pi
statusbar "$SB" "$SOCKET_PATH" apply firstmate
home2_usage=$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:pi-home)
[ "$home2_usage" = 'u cx:openai~ex-home96%' ] || fail "distinct account keys collapsed into one label" "$home2_usage"
pass "bounded account labels distinguish two Codex accounts"

tmux new-window -d -t firstmate: -n opencode-usage "sleep 600"
statusbar "$SB" "$SOCKET_PATH" label firstmate:opencode-usage opencode-usage opencode openai/gpt-5.6-sol high /home/u/opencode
[ "$(tmux show-options -wqv -t firstmate:opencode-usage @fm_provider)" = codex ] || fail "OpenCode missed the shared Codex provider"
[ "$(tmux show-options -wqv -t firstmate:opencode-usage @fm_model)" = gpt-5.6-sol ] || fail "OpenCode model retained an account prefix"
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:opencode-usage)" = 'u cx:default32%' ] || fail "OpenCode missed its Codex quota"
tmux new-window -d -t firstmate: -n opencode-claude "sleep 600"
statusbar "$SB" "$SOCKET_PATH" label firstmate:opencode-claude opencode-claude opencode anthropic/claude-3-5-sonnet high /home/u/opencode
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:opencode-claude)" = 'u cl:default32%' ] || fail "OpenCode borrowed another provider or model quota"
tmux new-window -d -t firstmate: -n opencode-unknown "sleep 600"
statusbar "$SB" "$SOCKET_PATH" label firstmate:opencode-unknown opencode-unknown opencode google/gemini high /home/u/opencode
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:opencode-unknown)" = 'u ?' ] || fail "OpenCode borrowed quota for an unknown provider"
pass "OpenCode uses the model provider or reports unknown usage"

tmux new-window -d -t firstmate: -n high-used "sleep 600"
statusbar "$SB" "$SOCKET_PATH" label firstmate:high-used high-used pi openai-codex-hi/gpt-6-sol high /home/u/pi
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:high-used)" = 'u cx:openai~odex-hi>99.9%' ] || fail "nonterminal high usage rounded to 100%"
tmux new-window -d -t firstmate: -n low-used "sleep 600"
statusbar "$SB" "$SOCKET_PATH" label firstmate:low-used low-used pi openai-codex-lo/gpt-6-sol high /home/u/pi
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:low-used)" = 'u cx:openai~odex-lo<0.1%' ] || fail "nonterminal low usage rounded to 0%"
pass "nonterminal usage values remain distinct from endpoints"

tmux new-window -d -t firstmate: -n pinned-claude "sleep 600"
statusbar "$SB" "$SOCKET_PATH" label firstmate:pinned-claude pinned-claude claude opus high /home/u/claude /home/u/.claude/settings.json
[ "$(tmux show-options -wqv -t firstmate:pinned-claude @fm_account)" = default ] || fail "pinned Claude path became a quota account"
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:pinned-claude)" = 'u cl:default32%' ] || fail "pinned Claude missed default quota"
pass "pinned Claude uses the shared default quota lane"

tmux new-window -d -t firstmate: -n pi-fallback "sleep 600"
statusbar "$SB" "$SOCKET_PATH" label firstmate:pi-fallback pi-fallback pi anthropic/opus high /home/u/pi
[ "$(tmux show-options -wqv -t firstmate:pi-fallback @fm_account)" = anthropic ] || fail "Pi model prefix did not select its quota lane"
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:pi-fallback)" = 'u cl:default32%' ] || fail "Pi lane did not fall back to the provider default"
tmux new-window -d -t firstmate: -n pi-unknown "sleep 600"
statusbar "$SB" "$SOCKET_PATH" label firstmate:pi-unknown pi-unknown pi google/gemini high /home/u/pi
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:pi-unknown)" = 'u ?' ] || fail "Pi borrowed quota for an unknown provider"
pass "every quota lane can fall back to its provider default"

tmux new-window -d -t firstmate: -n pi-grok "sleep 600"
statusbar "$SB" "$SOCKET_PATH" label firstmate:pi-grok pi-grok pi xai/grok-4.5 high /home/u/pi
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:pi-grok)" = 'u gk:xai80%' ] || fail "Pi xAI model missed its Grok account quota"
tmux new-window -d -t firstmate: -n oc-grok "sleep 600"
statusbar "$SB" "$SOCKET_PATH" label firstmate:oc-grok oc-grok opencode xai/grok-4.5 high /home/u/oc
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:oc-grok)" = 'u gk:default55%' ] || fail "OpenCode xAI model missed Grok quota"
tmux new-window -d -t firstmate: -n pi-signed-grok "sleep 600"
statusbar "$SB" "$SOCKET_PATH" label firstmate:pi-signed-grok pi-signed-grok pi-signed xai/grok-4.5 high /home/u/pi-signed
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:pi-signed-grok)" = 'u gk:xai80%' ] || fail "Pi-signed xAI model missed Grok quota"
tmux new-window -d -t firstmate: -n agy "sleep 600"
statusbar "$SB" "$SOCKET_PATH" label firstmate:agy agy agy default high /home/u/agy
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:agy)" = 'u ag:default60%' ] || fail "Agy status usage disappeared with the legacy chooser mapping"
pass "xAI models and Agy use only their selected status quota lanes"

cat >"$WORK/state/sync-lane.meta" <<META
window=firstmate:pi-fallback
harness=pi
model=openai-codex-work/gpt-6-sol
effort=high
account=ordinary
account_provider=xai
worktree=/home/u/pi
META
statusbar "$SB" "$SOCKET_PATH" sync
[ "$(tmux show-options -wqv -t firstmate:pi-fallback @fm_account)" = openai-codex-work ] || fail "sync used a different quota lane than direct labeling"
[ "$(tmux show-options -wqv -t firstmate:pi-fallback @fm_provider)" = codex ] || fail "sync let account metadata override the model's provider"
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:pi-fallback)" = 'u cx:openai~ex-work99.5%' ] || fail "synced Pi lane selected another account"
pass "sync and direct labels use the same quota lane"

tmux new-window -d -t firstmate: -n pi-scoped "sleep 600"
statusbar "$SB" "$SOCKET_PATH" label firstmate:pi-scoped pi-scoped pi openai-codex-scoped/gpt-6-sol high /home/u/pi
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:pi-scoped)" = 'u ?' ] || fail "an unrelated model scope borrowed default account usage"
statusbar "$SB" "$SOCKET_PATH" label firstmate:pi-scoped pi-scoped pi openai-codex-scoped/gpt-6-astra high /home/u/pi
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:pi-scoped)" = 'u ?' ] || fail "matching model scope appeared as account usage"
pass "model-only accounts stay unknown without account-wide usage"

tmux new-window -d -t firstmate: -n pi-unknown-account "sleep 600"
statusbar "$SB" "$SOCKET_PATH" label firstmate:pi-unknown-account pi-unknown-account pi openai-codex-unknown/gpt-6-sol high /home/u/pi
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:pi-unknown-account)" = 'u ?' ] || fail "unknown exact account borrowed default quota"
awk -F '\t' '$1 == "codex" && $2 == "openai-codex-unknown" && $3 == "?" { found=1 } END { exit !found }' \
  "$WORK/state/statusbar-usage.txt" || fail "unknown exact account vanished from quota cache"
pass "unknown exact account presence blocks another account's usage"

tmux new-window -d -t firstmate: -n pi-attention-account "sleep 600"
statusbar "$SB" "$SOCKET_PATH" label firstmate:pi-attention-account pi-attention-account pi openai-codex-attention/gpt-6-sol high /home/u/pi
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:pi-attention-account)" = 'u ?' ] || fail "attention-only account borrowed default quota"
awk -F '\t' '$1 == "codex" && $2 == "openai-codex-attention" && $3 == "?" { found=1 } END { exit !found }' \
  "$WORK/state/statusbar-usage.txt" || fail "attention-only account vanished from quota cache"
pass "attention-only account presence blocks another account's usage"

tmux new-window -d -t firstmate: -n primary "sleep 600"
primary_pane=$(tmux display-message -p -t firstmate:primary '#{pane_id}')
statusbar "$SB" "$SOCKET_PATH" label "$primary_pane" firstmate claude '' '' /home/u/firstmate
statusbar "$SB" "$SOCKET_PATH" apply firstmate
tmux select-window -t orca-view:primary
primary=$(render orca-view 100 'u cl:default32%')
case "$primary" in
*"u cl:default32%|firstmate | ? ? | firstmate"*) pass "a primary pane reports missing model and effort honestly" ;;
*) fail "primary pane lost a required field" "$primary" ;;
esac

# --- missing fields: an unlabeled window still renders something truthful ---
tmux select-window -t orca-view:bare
bare=$(render orca-view 120 'sleep')
case "$bare" in
*bare*"sleep"*) pass "unlabeled window falls back to window name and live command" ;;
*) fail "unlabeled window render" "$bare" ;;
esac

# --- no secrets, no injection through option values ---
statusbar "$SB" "$SOCKET_PATH" label firstmate:bare 'x#(touch '"$WORK"'/pwned)#{pane_title}' claude "m\$(id)" high /tmp
for opt in @fm_task @fm_model; do
  v=$(tmux show-options -wqv -t firstmate:bare "$opt")
  case "$v" in *'#'* | *'$'* | *'{'*) fail "option $opt kept format metacharacters" "$v" ;; esac
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
rm -f "$WORK/state/statusbar-usage.txt" "$WORK/state/.statusbar-usage-attempt" "$WORK/quota-calls"
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:fm-demo-task)" = 'u ?' ] || fail "first usage read should be unknown before the cache exists"
i=0
while [ ! -s "$WORK/state/statusbar-usage.txt" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
awk -F '\t' '$1 == "claude" && $2 == "default" && $3 == 32 && NF == 3 { found=1 } END { exit !found }' "$WORK/state/statusbar-usage.txt" || fail "account-wide usage cache content"
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:fm-demo-task)" = "u cl:default32%" ] || fail "usage did not serve the selected account"
statusbar "$SB" "$SOCKET_PATH" usage >/dev/null 2>&1 && fail "usage accepted an implicit target"
statusbar "$SB" "$SOCKET_PATH" usage firstmate:fm-demo-task >/dev/null
statusbar "$SB" "$SOCKET_PATH" usage firstmate:fm-demo-task >/dev/null
sleep 0.5
[ "$(wc -l <"$WORK/quota-calls")" -eq 1 ] || fail "usage refreshed more than once inside the TTL" "$(cat "$WORK/quota-calls")"
grep -qi 'token\|secret\|key' "$WORK/state/statusbar-usage.txt" && fail "usage cache holds credential-like text"
pass "usage is a cached percentage figure refreshed at most once per TTL"

touch -t 200001010000 "$WORK/state/statusbar-usage.txt" "$WORK/state/.statusbar-usage-attempt"
touch "$WORK/quota-fail"
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:fm-demo-task)" = 'u ?' ] || fail "expired quota cache was shown as current"
i=0
while [ -d "$WORK/state/.statusbar-usage.lock" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ "$(statusbar "$SB" "$SOCKET_PATH" usage firstmate:fm-demo-task)" = 'u ?' ] || fail "failed refresh revived expired quota data"
rm -f "$WORK/quota-fail"
pass "expired usage stays unknown after a failed refresh"

rm -f "$WORK/state/statusbar-usage.txt" "$WORK/state/.statusbar-usage-attempt" "$WORK/quota-calls"
touch "$WORK/quota-fail"
statusbar "$SB" "$SOCKET_PATH" usage firstmate:fm-demo-task >/dev/null
i=0
while [ -d "$WORK/state/.statusbar-usage.lock" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
statusbar "$SB" "$SOCKET_PATH" usage firstmate:fm-demo-task >/dev/null
[ "$(wc -l <"$WORK/quota-calls")" -eq 1 ] || fail "failed quota refresh repeated inside TTL"
rm -f "$WORK/quota-fail"
pass "failed quota refresh observes the same TTL"

rm -f "$WORK/state/statusbar-usage.txt" "$WORK/state/.statusbar-usage-attempt" "$WORK/quota-calls"
touch "$WORK/quota-hang"
statusbar "$SB" "$SOCKET_PATH" usage firstmate:fm-demo-task >/dev/null
i=0
while [ -d "$WORK/state/.statusbar-usage.lock" ] && [ "$i" -lt 135 ]; do sleep 0.1; i=$((i + 1)); done
[ ! -d "$WORK/state/.statusbar-usage.lock" ] || fail "stalled quota refresh outlived its bound"
[ ! -e "$WORK/state/statusbar-usage.txt" ] || fail "timed-out quota refresh updated the cache"
rm -f "$WORK/quota-hang"
pass "quota refresh terminates a stalled probe"

# --- claude-line: whitelisted fields only ---
json='{"model":{"display_name":"Opus 5.5"},"effort":{"level":"high"},"context_window":{"used_percentage":7.4},"rate_limits":{"five_hour":{"used_percentage":31},"seven_day":{"used_percentage":11}},"workspace":{"current_dir":"/x/y/firstmate","git_worktree":"firstmate2"},"transcript_path":"/home/u/SECRET-transcript.jsonl","session_id":"abc-123","cost":{"total_cost_usd":1.5}}'
line=$(printf '%s' "$json" | bash "$SB" claude-line --task fm-demo-task)
[ "$line" = "Opus 5.5 high | fm-demo-task | firstmate2 | 5h 31% 7d 11%" ] || fail "claude-line output" "$line"
case "$line" in *SECRET* | *abc-123* | *1.5*) fail "claude-line leaked a non-whitelisted field" "$line" ;; esac
pass "claude-line prints only model, effort, task, worktree and rate limits"

sparse=$(printf '%s' '{"model":{"display_name":"Haiku"}}' | bash "$SB" claude-line --task t1)
[ "$sparse" = "Haiku ? | t1" ] || fail "claude-line with missing fields" "$sparse"
pass "claude-line tolerates missing fields"

optional=$(printf '%s' '{"model":{"display_name":"Haiku"},"context_window":{"used_percentage":7},"rate_limits":{"seven_day":{"used_percentage":13}},"workspace":{"current_dir":"/homes/secondmate/child","project_dir":"/homes/secondmate"}}' | bash "$SB" claude-line --task t1)
[ "$optional" = 'Haiku ? | t1 | secondmate | 7d 13%' ] || fail "optional Claude fields shifted or home changed after cd" "$optional"
no_model=$(printf '%s' '{"effort":{"level":"high"}}' | bash "$SB" claude-line --task t1)
[ "$no_model" = '? high | t1' ] || fail "missing Claude model lacked its own unknown marker" "$no_model"
pass "Claude fields remain aligned when effort and a limit window are absent"

# --- sync labels windows from recorded task metadata ---
cat >"$WORK/state/sync-task.meta" <<META
window=firstmate:bare
harness=codex
model=gpt-6-sol
effort=medium
worktree=/home/u/.treehouse/proj-abc123/4/proj
META
statusbar "$SB" "$SOCKET_PATH" sync
[ "$(tmux show-options -wqv -t firstmate:bare @fm_task)" = sync-task ] || fail "sync did not label the recorded window"
[ "$(tmux show-options -wqv -t firstmate:bare @fm_wt)" = proj/4 ] || fail "sync worktree label" "$(tmux show-options -wqv -t firstmate:bare @fm_wt)"
pass "sync labels recorded windows from state metadata"

cat >"$WORK/state/sync-custom.meta" <<META
window=firstmate:custom-pool
harness=claude
model=opus
effort=high
worktree=$WORK/slots/2/project
META
statusbar "$SB" "$SOCKET_PATH" sync
[ "$(tmux show-options -wqv -t firstmate:custom-pool @fm_wt)" = project/2 ] || fail "sync custom Treehouse worktree label"

cat >"$WORK/state/sync-home.meta" <<META
window=firstmate:numeric-home
harness=claude
model=opus
effort=high
worktree=/home/u/homes/2026/firstmate
META
statusbar "$SB" "$SOCKET_PATH" sync
[ "$(tmux show-options -wqv -t firstmate:numeric-home @fm_task)" = sync-home ] || fail "sync missed the ordinary numeric-parent home"
[ "$(tmux show-options -wqv -t firstmate:numeric-home @fm_wt)" = firstmate ] || fail "sync gave an ordinary numeric-parent home a slot"

cat >"$WORK/state/sync-task.meta" <<META
window=firstmate:bare
harness=codex
model=default
effort=default
worktree=/home/u/.treehouse/proj-abc123/4/proj
META
statusbar "$SB" "$SOCKET_PATH" sync
tmux select-window -t orca-later:bare
unknown=$(render orca-later 100 'u ?')
case "$unknown" in *'u ?'*sync-task*'?'*'?'*proj/4*) pass "metadata defaults render as unknown facts" ;; *) fail "metadata default rendered as a fact" "$unknown" ;; esac

# --- fleet: live worker and second-mate counts from recorded task metadata ---
FLEET_STATE="$WORK/fleet's-state"
mkdir -p "$FLEET_STATE"
tmux new-window -d -t firstmate: -n fm-live-crew "sleep 600"
tmux new-window -d -t firstmate: -n fm-live-second "sleep 600"
printf 'window=firstmate:fm-live-crew\nkind=ship\n' >"$FLEET_STATE/crew-a.meta"
printf 'window=firstmate:fm-gone-crew\nkind=ship\n' >"$FLEET_STATE/crew-gone.meta"
printf 'window=firstmate:fm-live-second\nkind=secondmate\n' >"$FLEET_STATE/second-a.meta"
printf 'window=remote:second-r\nkind=secondmate\nremote_backend=herdr\nremote_host=example.invalid\n' >"$FLEET_STATE/second-r.meta"
printf 'window=remote:crew-r\nkind=scout\nremote_backend=herdr\nremote_host=example.invalid\n' >"$FLEET_STATE/crew-r.meta"
fleet=$(FM_STATE_OVERRIDE="$FLEET_STATE" statusbar "$SB" "$SOCKET_PATH" fleet)
[ "$fleet" = "crew 2 | 2nd 2" ] || fail "fleet counted wrong" "$fleet"
rm -f "$FLEET_STATE"/*.meta
fleet=$(FM_STATE_OVERRIDE="$FLEET_STATE" statusbar "$SB" "$SOCKET_PATH" fleet)
[ "$fleet" = "crew 0 | 2nd 0" ] || fail "empty fleet counted wrong" "$fleet"
pass "fleet counts live workers and second mates from metadata"

printf 'window=firstmate:fm-live-crew\nkind=ship\nsecret=DO_NOT_DISPLAY\n' >"$FLEET_STATE/crew-a.meta"
printf 'window=firstmate:fm-live-second\nkind=secondmate\n' >"$FLEET_STATE/second-a.meta"
FM_STATE_OVERRIDE="$FLEET_STATE" statusbar "$SB" "$SOCKET_PATH" apply --primary firstmate
left=$(tmux show-options -t firstmate -v status-left)
right=$(tmux show-options -t firstmate -v status-right)
case "$right" in *"crew-tracker"*) pass "apply --primary puts the crew tracker in status-right" ;; *) fail "status-right lacks crew tracker" "$right" ;; esac
other=$(tmux show-options -t orca-later -v status-right)
case "$other" in *"crew-tracker"*) pass "grouped view session shares the crew tracker" ;; *) fail "view session lacks crew tracker" "$other" ;; esac

# fm-spawn's ordinary apply must preserve the established primary hook.
hooks=$(tmux show-hooks -g)
statusbar "$SB" "$SOCKET_PATH" apply firstmate
[ "$(tmux show-hooks -g)" = "$hooks" ] || fail "ordinary apply replaced the primary hook"
tmux new-session -d -t firstmate -s fleet-later
[ "$(tmux show-options -t fleet-later -v status-right)" = "$right" ] || fail "late view lost crew tracker"
bound=$(FM_STATE_OVERRIDE="$WORK/wrong-state" statusbar "$SB" "$SOCKET_PATH" fleet firstmate)
[ "$bound" = 'crew 1 | 2nd 1' ] || fail "fleet used ambient home instead of session state" "$bound"
tmux set-option -u -t fleet-later 'status-format[0]'
mkdir -p "$FM_SB_TRACKER_CACHE_DIR"
printf 'churchill:on 1r/0w\n' >"$FM_SB_TRACKER_CACHE_DIR/statusbar-crew-tracker.txt"
fleet_render=$(render fleet-later 100 'churchill:on 1r/0w')
case "$fleet_render" in *'churchill:on 1r/0w'*) ;; *) fail "tracker job failed to render on its private socket" "$fleet_render" ;; esac
case "$fleet_render" in *DO_NOT_DISPLAY*) fail "fleet exposed an unrelated metadata value" ;; esac
pass "crew tracker survives ordinary spawn apply and a late view"
[ "$(tmux show-options -qv -t fleet-later @fm_fleet_state)" = "$FLEET_STATE" ] || fail "late view did not copy its peer's binding"
# Simulate a view created before binding inheritance was available.
tmux set-option -u -t fleet-later @fm_fleet_state
before_left=$(tmux show-options -qv -t firstmate status-left)
before_right=$(tmux show-options -qv -t firstmate status-right)
FM_STATE_OVERRIDE="$WORK/foreign-home/state" statusbar "$SB" "$SOCKET_PATH" apply --primary fleet-later
[ "$(tmux show-options -qv -t firstmate @fm_fleet_state)" = "$FLEET_STATE" ] || fail "foreign home claimed group through an unbound view"
[ "$(tmux show-options -qv -t firstmate status-left)" = "$before_left" ] || fail "foreign home changed primary left bar"
[ "$(tmux show-options -qv -t firstmate status-right)" = "$before_right" ] || fail "foreign home changed primary right bar"
[ "$(tmux show-hooks -g)" = "$hooks" ] || fail "foreign home replaced group hook"
[ -z "$(tmux show-options -qv -t fleet-later @fm_fleet_state)" ] || fail "foreign home assigned a fleet binding"
FM_STATE_OVERRIDE="$FLEET_STATE" statusbar "$SB" "$SOCKET_PATH" apply --primary fleet-later
[ "$(tmux show-options -qv -t firstmate @fm_fleet_state)" = "$FLEET_STATE" ] || fail "same-home reapply changed primary binding"
[ "$(tmux show-hooks -g)" = "$hooks" ] || fail "same-home reapply replaced group hook"
pass "group ownership is write-once even through an unbound late view"


mkdir -p "$WORK/second-home/state"
touch "$WORK/second-home/.fm-secondmate-home"
# Exercise the public boundary even if a caller mistakenly requests ownership.
FM_HOME="$WORK/second-home" FM_STATE_OVERRIDE="$WORK/second-home/state" statusbar "$SB" "$SOCKET_PATH" apply --primary firstmate
[ "$(tmux show-options -qv -t firstmate @fm_fleet_state)" = "$FLEET_STATE" ] || fail "secondmate overwrote main fleet state"
[ "$(tmux show-options -qv -t firstmate status-right)" = "$right" ] || fail "secondmate replaced main tracker job"
FM_STATE_OVERRIDE="$WORK/wrong-state" statusbar "$SB" "$SOCKET_PATH" apply --primary firstmate
[ "$(tmux show-options -qv -t firstmate @fm_fleet_state)" = "$FLEET_STATE" ] || fail "different home stole main fleet state"
tmux new-session -d -s second-only -n second 'sleep 600'
FM_HOME="$WORK/second-home" FM_STATE_OVERRIDE="$WORK/second-home/state" statusbar "$SB" "$SOCKET_PATH" apply --primary second-only
[ -z "$(tmux show-options -qv -t second-only @fm_fleet_state)" ] || fail "secondmate claimed an unbound session"
tmux new-session -d -t firstmate -s after-second
[ "$(tmux show-options -qv -t after-second status-right)" = "$right" ] || fail "secondmate lost main tracker hook"
pass "secondmate startup and other homes preserve primary fleet ownership"

# Public tracker interface reads each home's recorded tasks and current-state
# helper, while preserving the rendered cache between refreshes.
export FM_SB_TRACKER_CACHE_DIR="$WORK/tracker-proof-cache"
mkdir -p "$WORK/firstmate/state" "$WORK/fm-homes/dev/state" \
  "$WORK/fm-homes/napoleon/state" "$WORK/fm-homes/alexander-media/state" \
  "$WORK/fm-homes/ottersec/state" "$WORK/fm-homes/legion/state"
printf 'window=firstmate:fm-live-crew\nkind=ship\n' >"$WORK/firstmate/state/main-task.meta"
printf 'window=firstmate:fm-live-crew\nkind=ship\n' >"$WORK/fm-homes/dev/state/dev-task.meta"
printf 'window=firstmate:fm-gone-crew\nkind=ship\n' >"$WORK/fm-homes/dev/state/gone-task.meta"
printf 'window=firstmate:fm-live-second\nkind=ship\n' >"$WORK/fm-homes/ottersec/state/otter-task.meta"
printf 'window=firstmate:fm-dev\nkind=secondmate\n' >"$WORK/firstmate/state/dev.meta"
cat >"$WORK/crew-state-fixture.sh" <<'SH'
#!/usr/bin/env bash
[ "$FM_STATE_OVERRIDE" = "$FM_HOME/state" ] || { echo 'state: unknown · source: wrong-home'; exit; }
[ "$FM_DATA_OVERRIDE" = "$FM_HOME/data" ] || { echo 'state: unknown · source: wrong-data'; exit; }
case "$TMUX" in "$FM_SB_EXPECTED_SOCKET",*) ;; *) echo 'state: unknown · source: wrong-socket'; exit ;; esac
case "$1" in
  main-task|dev-task) echo 'state: working · source: pane' ;;
  otter-task|dev) echo 'state: parked · source: status-log' ;;
  *) echo 'state: unknown · source: none' ;;
esac
SH
export FM_SB_CREW_STATE_SCRIPT="$WORK/crew-state-fixture.sh"
export FM_SB_EXPECTED_SOCKET="$SOCKET_PATH"
rm -f "$FM_SB_TRACKER_CACHE_DIR/statusbar-crew-tracker.txt" "$FM_SB_TRACKER_CACHE_DIR/.statusbar-crew-tracker-attempt"
tracker=$(FM_STATE_OVERRIDE="$WORK/wrong-state" statusbar "$SB" "$SOCKET_PATH" crew-tracker)
[ "$tracker" = 'crew: loading' ] || fail "cold tracker did not return immediately" "$tracker"
i=0
while [ ! -s "$FM_SB_TRACKER_CACHE_DIR/statusbar-crew-tracker.txt" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
tracker=$(statusbar "$SB" "$SOCKET_PATH" crew-tracker)
case "$tracker" in
  *'churchill:off 1r/0w'*'dev:parked 1r/0w'*'ottersec:unknown 0r/1w'*'legion:unknown 0r/0w'*) ;;
  *) fail "tracker did not reconcile per-mate running and waiting crew" "$tracker" ;;
esac
case "$tracker" in *website-genie*|*rothschild*) fail "tracker included excluded mates" "$tracker" ;; esac
pass "tracker refreshes all six homes through current-state reads"

# --- persistent config: preserve user settings and survive server restart ---
config="$WORK/user tmux.conf"
printf 'set -g mouse on' >"$config"
bash "$SB" check "$config" >/dev/null 2>&1 && fail "check accepted a missing source line"
before=$(cat "$config")
bash "$SB" source-line >/dev/null || fail "source-line failed"
[ "$(cat "$config")" = "$before" ] || fail "check or source-line edited config"
bash "$SB" install "$config" >/dev/null || fail "install failed"
bash "$SB" check "$config" >/dev/null || fail "check missed installed source line"
installed=$(cat "$config")
bash "$SB" install "$config" >/dev/null || fail "repeat install failed"
[ "$(cat "$config")" = "$installed" ] || fail "install duplicated its source line"
case "$installed" in 'set -g mouse on'*) ;; *) fail "install lost existing settings" ;; esac
pass "config install is idempotent and preserves existing bytes"

# Space-containing checkout paths remain usable by both tmux and the shell.
mkdir -p "$WORK/installed repo/bin"
cp "$ROOT/bin/fm-statusbar.sh" "$ROOT/bin/fm-statusbar.tmux" \
  "$ROOT/bin/fm-quota-axi-lib.sh" "$ROOT/bin/fm-timeout-lib.sh" "$WORK/installed repo/bin/"
space_config="$WORK/space.conf"
bash "$WORK/installed repo/bin/fm-statusbar.sh" install "$space_config" >/dev/null || fail "space path install failed"
"$REAL_TMUX" -L "$OUTER" kill-server >/dev/null 2>&1 || true
tmux kill-server >/dev/null 2>&1 || true
i=0
while "$REAL_TMUX" -L "$SOCKET" has-session 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
# No label, apply, or theme call: startup must load the snippet itself.
"$REAL_TMUX" -L "$SOCKET" -f "$space_config" new-session -d -s restarted -x 120 -y 10 "sleep 600" || fail "configured server failed to start"
[ "$(tmux show-options -gqv status-style)" = 'bg=colour234,fg=colour250' ] || fail "theme did not survive server restart"
case "$(tmux show-options -gqv status-right)" in *crew-tracker*) ;; *) fail "restart lost the crew tracker" ;; esac
[ "$(tmux show-options -gqv status-left)" = '[#S] ' ] || fail "restart lost the session label"
statusbar "$WORK/installed repo/bin/fm-statusbar.sh" "$SOCKET_PATH" label restarted persist codex gpt-6-sol high /home/u/project
printf 'codex\tdefault\t32\n' >"$WORK/state/statusbar-usage.txt"
# The fixture uses codex-home; seed the account that labeling actually chose.
printf 'codex\tcodex-home\t32\n' >>"$WORK/state/statusbar-usage.txt"
# @fm_state binds jobs to the window's home, even if the command is launched
# from another home's environment.
other=$(FM_STATE_OVERRIDE="$WORK/other" statusbar "$SB" "$SOCKET_PATH" usage restarted)
[ "$other" = 'u cx:codex-home32%' ] || fail "status job read another home's quota cache" "$other"
restarted=$(render restarted 120 'legion:unknown')
case "$restarted" in *'ottersec:unknown'*'legion:unknown'*) ;;
*) fail "restart render missed the crew tracker" "$restarted" ;; esac
pass "startup snippet handles spaces, uses the right socket and shows the crew tracker"
tmux source-file "$ROOT/bin/fm-statusbar.tmux"
[ "$(tmux show-options -gqv status-style)" = 'bg=colour234,fg=colour250' ] || fail "repeat source changed theme"
pass "theme can be sourced repeatedly"

echo "fm-statusbar: all passed"
