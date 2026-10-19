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
: >"$WORK/state/statusbar-claude-usage.tsv"
touch "$WORK/state/.statusbar-claude-usage-attempt"
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
tracker_key() {  # <socket> <main-state> <main-home> [main-config]
  local key config=${4:-$3/config}
  key=$(printf '%s\037%s\037%s\037%s\037%s' \
    "$1" "$2" "$3/data" "$config" "$3/projects" | cksum)
  printf '%s' "${key%% *}"
}
TRACKER_SOCKET_KEY=$(tracker_key "$SOCKET_PATH" "$WORK/firstmate/state" "$WORK/firstmate")
TRACKER_CACHE_FILE="$FM_SB_TRACKER_CACHE_DIR/statusbar-crew-tracker.$TRACKER_SOCKET_KEY.txt"
TRACKER_ATTEMPT_FILE="$FM_SB_TRACKER_CACHE_DIR/.statusbar-crew-tracker-attempt.$TRACKER_SOCKET_KEY"
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
[ "$line" = "Opus 5.5 high | Ctx 7% | fm-demo-task | firstmate2 | 5h 31% 7d 11%" ] || fail "claude-line output" "$line"
case "$line" in *SECRET* | *abc-123* | *1.5* | *7.4*) fail "claude-line leaked a non-whitelisted field" "$line" ;; esac
pass "claude-line prints model, Ctx %, task, worktree and rate limits"

sparse=$(printf '%s' '{"model":{"display_name":"Haiku"}}' | bash "$SB" claude-line --task t1)
[ "$sparse" = "Haiku ? | t1" ] || fail "claude-line with missing fields" "$sparse"
pass "claude-line tolerates missing fields"

optional=$(printf '%s' '{"model":{"display_name":"Haiku"},"context_window":{"used_percentage":7},"rate_limits":{"seven_day":{"used_percentage":13}},"workspace":{"current_dir":"/homes/secondmate/child","project_dir":"/homes/secondmate"}}' | bash "$SB" claude-line --task t1)
[ "$optional" = 'Haiku ? | Ctx 7% | t1 | secondmate | 7d 13%' ] || fail "optional Claude fields shifted or home changed after cd" "$optional"
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
printf 'churchill:on 1r/0w\n' >"$TRACKER_CACHE_FILE"
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

tmux new-session -d -s legacy-owner -n old 'sleep 600'
tmux set-option -t legacy-owner @fm_fleet_state "$FLEET_STATE"
tmux set-option -t legacy-owner status-right '#{E:pane-border-format}'
FM_HOME="$WORK/firstmate" FM_STATE_OVERRIDE="$FLEET_STATE" \
  statusbar "$SB" "$SOCKET_PATH" apply --primary legacy-owner
legacy_right=$(tmux show-options -qv -t legacy-owner status-right)
case "$legacy_right" in *crew-tracker*) ;; *) fail "bound legacy session did not migrate to the tracker" "$legacy_right" ;; esac
tmux new-session -d -t legacy-owner -s legacy-later
[ "$(tmux show-options -qv -t legacy-later status-right)" = "$legacy_right" ] \
  || fail "migrated legacy group kept an old late-view hook"
pass "explicit primary apply migrates an existing legacy fleet binding"


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
TRACKER_CACHE_FILE="$FM_SB_TRACKER_CACHE_DIR/statusbar-crew-tracker.$TRACKER_SOCKET_KEY.txt"
TRACKER_ATTEMPT_FILE="$FM_SB_TRACKER_CACHE_DIR/.statusbar-crew-tracker-attempt.$TRACKER_SOCKET_KEY"
mkdir -p "$WORK/firstmate/state" "$WORK/fm-homes/dev/state" \
  "$WORK/custom-dev/state" \
  "$WORK/fm-homes/napoleon/state" "$WORK/fm-homes/alexander-media/state" \
  "$WORK/fm-homes/ottersec/state" "$WORK/fm-homes/legion/state"
printf 'window=firstmate:fm-live-crew\nkind=ship\n' >"$WORK/firstmate/state/main-task.meta"
printf 'window=firstmate:fm-live-crew\nkind=ship\n' >"$WORK/custom-dev/state/dev-task.meta"
printf 'window=firstmate:fm-live-second\nkind=ship\n' >"$WORK/custom-dev/state/dev-unknown.meta"
printf 'window=firstmate:fm-gone-crew\nkind=ship\n' >"$WORK/custom-dev/state/gone-task.meta"
printf 'window=firstmate:fm-live-second\nkind=ship\n' >"$WORK/fm-homes/ottersec/state/otter-task.meta"
printf 'window=firstmate:fm-dev\nkind=secondmate\nhome=%s\n' "$WORK/custom-dev" >"$WORK/firstmate/state/dev.meta"
FM_STATE_OVERRIDE="$WORK/firstmate/state" statusbar "$SB" "$SOCKET_PATH" \
  label firstmate:fm-demo-task firstmate claude opus high "$WORK/firstmate"
cat >"$WORK/crew-state-fixture.sh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = override-task ] || [ "$1" = override-waiting ]; then
  [ "$FM_STATE_OVERRIDE" = "${FM_SB_EXPECTED_OVERRIDE_STATE:-}" ] || { echo 'state: unknown · source: wrong-override'; exit; }
else
  [ "$FM_STATE_OVERRIDE" = "$FM_HOME/state" ] || { echo 'state: unknown · source: wrong-home'; exit; }
fi
[ "$FM_DATA_OVERRIDE" = "$FM_HOME/data" ] || { echo 'state: unknown · source: wrong-data'; exit; }
if [ "$1" = config-task ]; then
  [ "$FM_CONFIG_OVERRIDE" = "${FM_SB_EXPECTED_CONFIG:-}" ] || { echo 'state: unknown · source: wrong-config'; exit; }
fi
case "$TMUX" in "$FM_SB_EXPECTED_SOCKET",*) ;; *) echo 'state: unknown · source: wrong-socket'; exit ;; esac
case "$1" in
  dev|napoleon|alexander-media|ottersec|legion)
    [ -z "${FM_SB_SLOW_MATE_PROBES:-}" ] || sleep 8 ;;
  slow-task*)
    [ -z "${FM_SB_SLOW_MATE_PROBES:-}" ] || sleep 8 ;;
esac
case "$1" in
  main-task|dev-task|override-task|config-task) echo 'state: working · source: pane' ;;
  otter-task|dev|override-waiting) echo 'state: parked · source: status-log' ;;
  *) echo 'state: unknown · source: none' ;;
esac
SH
export FM_SB_CREW_STATE_SCRIPT="$WORK/crew-state-fixture.sh"
export FM_SB_EXPECTED_SOCKET="$SOCKET_PATH"
rm -f "$TRACKER_CACHE_FILE" "$TRACKER_ATTEMPT_FILE"
tracker=$(FM_STATE_OVERRIDE="$WORK/wrong-state" statusbar "$SB" "$SOCKET_PATH" crew-tracker)
[ "$tracker" = 'crew: loading' ] || fail "cold tracker did not return immediately" "$tracker"
i=0
while [ ! -s "$TRACKER_CACHE_FILE" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
tracker=$(statusbar "$SB" "$SOCKET_PATH" crew-tracker)
case "$tracker" in
  *'churchill:on 1r/0w'*'dev:parked 1r/0w+1?'*'ottersec:unknown 0r/1w'*'legion:unknown 0r/0w'*) ;;
  *) fail "tracker did not reconcile per-mate running and waiting crew" "$tracker" ;;
esac
case "$tracker" in *website-genie*|*rothschild*) fail "tracker included excluded mates" "$tracker" ;; esac
pass "tracker refreshes all six homes through current-state reads"
mkdir -p "$WORK/fail-inventory-bin"
cat >"$WORK/fail-inventory-bin/tmux" <<SH
#!/usr/bin/env bash
case " \$* " in *' list-windows '*) exit 1 ;; esac
exec "$REAL_TMUX" "\$@"
SH
chmod +x "$WORK/fail-inventory-bin/tmux"
if PATH="$WORK/fail-inventory-bin:$PATH" statusbar "$SB" "$SOCKET_PATH" crew-tracker-refresh >/dev/null; then
  fail "failed tmux inventory was treated as an empty fleet"
fi
[ "$(cat "$TRACKER_CACHE_FILE")" = "$tracker" ] || fail "failed inventory replaced valid cached counts"
pass "failed tmux inventory preserves the last valid crew summary"
for i in 1 2 3 4 5 6 7 8; do
  printf 'window=firstmate:fm-live-second\nkind=ship\n' >"$WORK/custom-dev/state/slow-task-$i.meta"
done
export FM_SB_SLOW_MATE_PROBES=1
rm -f "$TRACKER_CACHE_FILE" "$TRACKER_ATTEMPT_FILE"
tracker=$(statusbar "$SB" "$SOCKET_PATH" crew-tracker)
[ "$tracker" = 'crew: loading' ] || fail "slow tracker did not start a fresh refresh" "$tracker"
i=0
while [ ! -s "$TRACKER_CACHE_FILE" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$TRACKER_CACHE_FILE" ] || fail "slow mate probes prevented a cache publish inside the deadline"
tracker=$(cat "$TRACKER_CACHE_FILE")
case "$tracker" in
  *'churchill:on 1r/0w'*'dev:unknown '*'ottersec:unknown 0r/1w'*'legion:unknown 0r/0w'*) ;;
  *) fail "slow mate probes lost the reconciled summary" "$tracker" ;;
esac
unset FM_SB_SLOW_MATE_PROBES
rm -f "$WORK/custom-dev/state"/slow-task-*.meta
pass "concurrent slow mate probes publish a summary inside the refresh deadline"
other_socket=$("$REAL_TMUX" -L "$OUTER" display-message -p '#{socket_path}')
other_key=$(tracker_key "$other_socket" "$WORK/firstmate/state" "$WORK/firstmate")
other_cache="$FM_SB_TRACKER_CACHE_DIR/statusbar-crew-tracker.$other_key.txt"
[ "$other_cache" != "$TRACKER_CACHE_FILE" ] || fail "two tmux servers shared a tracker cache path"
other_tracker=$(statusbar "$SB" "$other_socket" crew-tracker)
[ "$other_tracker" = 'crew: loading' ] || fail "another tmux server reused the first server's tracker" "$other_tracker"
i=0
while [ ! -s "$other_cache" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$other_cache" ] || fail "another tmux server did not refresh its own cache"
[ "$(cat "$TRACKER_CACHE_FILE")" = "$tracker" ] || fail "another tmux server overwrote the first cache"
pass "tracker caches are isolated by tmux socket"

socketless_cache_dir="$WORK/socketless-cache"
socketless_cache="$socketless_cache_dir/statusbar-crew-tracker.$TRACKER_SOCKET_KEY.txt"
socketless=$(FM_SB_TRACKER_CACHE_DIR="$socketless_cache_dir" bash "$SB" crew-tracker)
[ "$socketless" = 'crew: loading' ] || fail "socketless tracker did not start its own refresh" "$socketless"
i=0
while [ ! -s "$socketless_cache" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$socketless_cache" ] || fail "socketless tracker did not publish under the resolved socket key"
socketless=$(FM_SB_TRACKER_CACHE_DIR="$socketless_cache_dir" bash "$SB" crew-tracker)
case "$socketless" in *'churchill:on 1r/0w'*) ;; *) fail "socketless tracker did not read its published cache" "$socketless" ;; esac
pass "socketless tracker resolves the live socket before caching"

mkdir -p "$WORK/operator/state"
printf 'window=firstmate:fm-live-crew\nkind=ship\n' >"$WORK/operator/state/main-task.meta"
FM_STATE_OVERRIDE="$WORK/operator/state" statusbar "$SB" "$SOCKET_PATH" \
  label firstmate:fm-demo-task operator claude opus high "$WORK/operator"
operator_cache_dir="$WORK/operator-cache"
operator_key=$(tracker_key "$SOCKET_PATH" "$WORK/operator/state" "$WORK/operator")
operator_cache="$operator_cache_dir/statusbar-crew-tracker.$operator_key.txt"
operator=$(FM_HOME="$WORK/operator" FM_STATE_OVERRIDE="$WORK/operator/state" \
  FM_SB_TRACKER_ROOT='' FM_SB_TRACKER_CACHE_DIR="$operator_cache_dir" \
  statusbar "$SB" "$SOCKET_PATH" crew-tracker)
[ "$operator" = 'crew: loading' ] || fail "selected-home tracker did not start a fresh refresh" "$operator"
i=0
while [ ! -s "$operator_cache" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$operator_cache" ] || fail "selected-home tracker did not publish"
operator=$(cat "$operator_cache")
case "$operator" in *'churchill:on 1r/0w'*) ;; *) fail "tracker did not read or recognize the selected operational home" "$operator" ;; esac
pass "tracker uses the selected operational home and its primary marker"
FM_STATE_OVERRIDE="$WORK/firstmate/state" statusbar "$SB" "$SOCKET_PATH" \
  label firstmate:fm-demo-task firstmate claude opus high "$WORK/firstmate"

mkdir -p "$WORK/override-state"
export FM_SB_EXPECTED_OVERRIDE_STATE="$WORK/override-state"
tmux new-session -d -s override-owner -n primary 'sleep 600'
printf 'window=override-owner:primary\nkind=ship\n' >"$WORK/override-state/override-task.meta"
FM_HOME="$WORK/firstmate" FM_STATE_OVERRIDE="$WORK/override-state" statusbar "$SB" "$SOCKET_PATH" \
  label override-owner:primary firstmate claude opus high "$WORK/firstmate"
FM_HOME="$WORK/firstmate" FM_STATE_OVERRIDE="$WORK/override-state" statusbar "$SB" "$SOCKET_PATH" \
  apply --primary override-owner
override_right=$(tmux show-options -qv -t override-owner status-right)
case "$override_right" in *"FM_SB_TRACKER_MAIN_STATE=$WORK/override-state"*) ;;
  *) fail "primary status job lost its bound state directory" "$override_right" ;;
esac
override_cache_dir="$WORK/override-cache"
override_key=$(tracker_key "$SOCKET_PATH" "$WORK/override-state" "$WORK/firstmate")
override_cache="$override_cache_dir/statusbar-crew-tracker.$override_key.txt"
override=$(FM_HOME="$WORK/firstmate" FM_STATE_OVERRIDE="$WORK/override-state" \
  FM_SB_TRACKER_ROOT="$WORK" FM_SB_TRACKER_CACHE_DIR="$override_cache_dir" \
  statusbar "$SB" "$SOCKET_PATH" crew-tracker)
[ "$override" = 'crew: loading' ] || fail "state-override tracker did not start a fresh refresh" "$override"
i=0
while [ ! -s "$override_cache" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$override_cache" ] || fail "state-override tracker did not publish"
override=$(cat "$override_cache")
case "$override" in *'churchill:on 1r/0w'*) ;; *) fail "tracker ignored the primary state override" "$override" ;; esac
pass "tracker carries the primary session's configured state directory"

mkdir -p "$WORK/override-state-b"
export FM_SB_EXPECTED_OVERRIDE_STATE="$WORK/override-state-b"
printf 'window=override-owner:primary\nkind=ship\n' >"$WORK/override-state-b/override-waiting.meta"
override_b_key=$(tracker_key "$SOCKET_PATH" "$WORK/override-state-b" "$WORK/firstmate")
override_b_cache="$override_cache_dir/statusbar-crew-tracker.$override_b_key.txt"
override_b=$(FM_HOME="$WORK/firstmate" FM_STATE_OVERRIDE="$WORK/override-state-b" \
  FM_SB_TRACKER_ROOT="$WORK" FM_SB_TRACKER_CACHE_DIR="$override_cache_dir" \
  statusbar "$SB" "$SOCKET_PATH" crew-tracker)
[ "$override_b" = 'crew: loading' ] || fail "second primary state reused the first state's cache" "$override_b"
i=0
while [ ! -s "$override_b_cache" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$override_b_cache" ] || fail "second primary state did not publish"
override_b=$(cat "$override_b_cache")
case "$override_b" in *'churchill:off 0r/1w'*) ;; *) fail "second primary state borrowed another state's counts" "$override_b" ;; esac
pass "tracker cache keys include the selected primary state"

mkdir -p "$WORK/custom-config"
export FM_SB_EXPECTED_CONFIG="$WORK/custom-config"
printf 'window=firstmate:fm-live-crew\nkind=ship\n' >"$WORK/firstmate/state/config-task.meta"
tmux new-session -d -s config-owner -n primary 'sleep 600'
FM_HOME="$WORK/firstmate" FM_STATE_OVERRIDE="$WORK/firstmate/state" \
  FM_CONFIG_OVERRIDE="$WORK/custom-config" statusbar "$SB" "$SOCKET_PATH" apply --primary config-owner
config_right=$(tmux show-options -qv -t config-owner status-right)
case "$config_right" in *"FM_SB_TRACKER_MAIN_CONFIG=$WORK/custom-config"*) ;;
  *) fail "primary status job lost its configured directory" "$config_right" ;;
esac
config_hooks=$(tmux show-hooks -g)
FM_HOME="$WORK/firstmate" FM_STATE_OVERRIDE="$WORK/firstmate/state" \
  statusbar "$SB" "$SOCKET_PATH" apply config-owner
[ "$(tmux show-options -qv -t config-owner status-right)" = "$config_right" ] \
  || fail "ordinary apply replaced the primary config tracker"
[ "$(tmux show-hooks -g)" = "$config_hooks" ] || fail "ordinary apply replaced the primary config hook"
tmux new-session -d -t config-owner -s config-later
[ "$(tmux show-options -qv -t config-later status-right)" = "$config_right" ] \
  || fail "late configured view lost the primary tracker"
config_cache_dir="$WORK/config-cache"
config_key=$(tracker_key "$SOCKET_PATH" "$WORK/firstmate/state" "$WORK/firstmate" "$WORK/custom-config")
config_cache="$config_cache_dir/statusbar-crew-tracker.$config_key.txt"
config_tracker=$(FM_HOME="$WORK/firstmate" FM_STATE_OVERRIDE="$WORK/firstmate/state" \
  FM_CONFIG_OVERRIDE="$WORK/custom-config" FM_SB_TRACKER_ROOT="$WORK" \
  FM_SB_TRACKER_CACHE_DIR="$config_cache_dir" statusbar "$SB" "$SOCKET_PATH" crew-tracker)
[ "$config_tracker" = 'crew: loading' ] || fail "configured tracker did not start a fresh refresh" "$config_tracker"
i=0
while [ ! -s "$config_cache" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$config_cache" ] || fail "configured tracker did not publish"
config_tracker=$(cat "$config_cache")
case "$config_tracker" in *'churchill:on 2r/0w'*) ;; *) fail "tracker ignored the primary config override" "$config_tracker" ;; esac
rm -f "$WORK/firstmate/state/config-task.meta"
pass "tracker carries the primary configuration directory into worker probes"

leased_home="$WORK/pool/45/dev"
mkdir -p "$leased_home/state"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$WORK/firstmate" >"$leased_home/.fm-secondmate-parent"
leased_cache_dir="$WORK/leased-cache"
leased_cache="$leased_cache_dir/statusbar-crew-tracker.$TRACKER_SOCKET_KEY.txt"
leased=$(FM_HOME="$leased_home" FM_SB_TRACKER_ROOT='' FM_SB_TRACKER_CACHE_DIR="$leased_cache_dir" \
  statusbar "$SB" "$SOCKET_PATH" crew-tracker)
[ "$leased" = 'crew: loading' ] || fail "leased-home tracker did not start a fresh refresh" "$leased"
i=0
while [ ! -s "$leased_cache" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$leased_cache" ] || fail "leased-home tracker did not publish"
leased=$(cat "$leased_cache")
case "$leased" in *'churchill:on 1r/0w'*) ;; *) fail "tracker treated a leased secondmate as the main home" "$leased" ;; esac
pass "tracker resolves a leased secondmate's recorded local parent"

cp "$WORK/firstmate/state/dev.meta" "$WORK/dev-local.meta"
printf 'window=remote:dev\nkind=secondmate\nhome=%s\nremote_backend=herdr\nremote_host=example.invalid\n' \
  "$WORK/custom-dev" >"$WORK/firstmate/state/dev.meta"
remote_cache_dir="$WORK/remote-cache"
remote_cache="$remote_cache_dir/statusbar-crew-tracker.$TRACKER_SOCKET_KEY.txt"
remote=$(FM_SB_TRACKER_CACHE_DIR="$remote_cache_dir" statusbar "$SB" "$SOCKET_PATH" crew-tracker)
[ "$remote" = 'crew: loading' ] || fail "remote-mate tracker did not start a fresh refresh" "$remote"
i=0
while [ ! -s "$remote_cache" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$remote_cache" ] || fail "remote-mate tracker did not publish"
remote=$(cat "$remote_cache")
case "$remote" in *'dev:parked ?r/?w'*) ;; *) fail "remote mate borrowed local workers at the same home path" "$remote" ;; esac
cp "$WORK/dev-local.meta" "$WORK/firstmate/state/dev.meta"
pass "remote mate crew stays unknown despite a matching local home path"

mkdir -p "$WORK/bad-parent-home"
printf 'schema=broken\n' >"$WORK/bad-parent-home/.fm-secondmate-parent"
unrelated=$(printf '%s' '{"model":{"display_name":"Opus"}}' | \
  FM_HOME="$WORK/bad-parent-home" bash "$SB" claude-line --task intact)
[ "$unrelated" = 'Opus ? | intact' ] || fail "bad parent binding broke unrelated statusbar command" "$unrelated"
pass "unrelated statusbar commands do not resolve tracker ancestry"

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

tmux new-session -d -s space-owner -n root 'sleep 600'
FM_SB_TRACKER_ROOT="$WORK/root with spaces" FM_SB_TRACKER_CACHE_DIR="$WORK/cache with spaces" \
  statusbar "$SB" "$SOCKET_PATH" apply --primary space-owner
space_right=$(tmux show-options -qv -t space-owner status-right)
tmux new-session -d -t space-owner -s space-later
late_right=$(tmux show-options -qv -t space-later status-right)
[ "$late_right" = "$space_right" ] || fail "late grouped view lost tracker job shell escapes" "$late_right"
pass "late grouped views preserve tracker paths containing spaces"

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

# The theme shows a recorded crew label instead of the addressed window name,
# from the server-wide format alone, and an unlabeled window keeps its name.
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "could not load the tmux backend"
tmux new-window -d -t restarted: -n fm-themed 'sleep 600' || fail "could not open a themed task window"
fm_backend_tmux_show_label restarted:fm-themed nap-crew-themed || fail "could not record a crew label"
for opt in window-status-format window-status-current-format; do
  theme_fmt=$(tmux show-window-options -gv "$opt")
  [ "$(tmux display-message -p -t restarted:fm-themed "$theme_fmt")" = " 1:nap-crew-themed " ] \
    || fail "theme $opt did not show the crew label" "$(tmux display-message -p -t restarted:fm-themed "$theme_fmt")"
  [ "$(tmux display-message -p -t restarted:0 "$theme_fmt")" = " 0:$(tmux display-message -p -t restarted:0 '#{window_name}') " ] \
    || fail "theme $opt changed an unlabeled window's name" "$(tmux display-message -p -t restarted:0 "$theme_fmt")"
done
[ "$(tmux display-message -p -t restarted:fm-themed '#{window_name}')" = fm-themed ] || fail "theme label renamed the window"
[ -z "$(tmux show-window-options -v -t restarted:fm-themed window-status-format)" ] \
  || fail "the theme label needed a per-window format"
pass "theme shows a recorded crew label while the window keeps its addressed name"

tmux set-window-option -g window-status-format ' #I:#W '
tmux set-window-option -g window-status-current-format ' #I:#W '
tmux new-window -d -t restarted: -n fm-later 'sleep 600' || fail "could not open a task window before loading the theme"
fm_backend_tmux_show_label restarted:fm-later nap-crew-later || fail "could not record a label before loading the theme"
for opt in window-status-format window-status-current-format; do
  [ "$(tmux show-window-options -gv "$opt")" = ' #I:#W ' ] || fail "label changed the previous $opt"
  [ -z "$(tmux show-window-options -v -t restarted:fm-later "$opt")" ] || fail "label changed the window's $opt"
  shown=$(tmux display-message -p -t restarted:fm-later "$(tmux show-window-options -gv "$opt")")
  case "$shown" in *fm-later*) ;; *) fail "previous $opt changed the plain name to '$shown'" ;; esac
done
statusbar "$SB" "$SOCKET_PATH" theme || fail "could not load the theme after recording a crew label"
for opt in window-status-format window-status-current-format; do
  [ -z "$(tmux show-window-options -v -t restarted:fm-later "$opt")" ] || fail "previous $opt shadowed the loaded theme"
  theme_fmt=$(tmux show-window-options -gv "$opt")
  shown=$(tmux display-message -p -t restarted:fm-later "$theme_fmt")
  case "$shown" in *nap-crew-later*) ;; *) fail "loaded theme $opt hid the label as '$shown'" ;; esac
  shown=$(tmux display-message -p -t restarted:0 "$theme_fmt")
  case "$shown" in *"$(tmux display-message -p -t restarted:0 '#{window_name}')"*) ;; *) fail "loaded theme $opt changed an unlabeled window to '$shown'" ;; esac
done
pass "loading the theme after spawn shows the recorded label"

# --- claude-line fleet segment: durable mates, cache, captain holds ---
FLEET_HOME="$WORK/fleet-home"
FLEET_STATE="$FLEET_HOME/state"
FLEET_DATA="$FLEET_HOME/data"
DEV_HOME="$WORK/fleet-mates/dev"
NAP_HOME="$WORK/fleet-mates/ada"
OTTER_HOME="$WORK/fleet-mates/ottersec"
ALEX_HOME="$WORK/fleet-mates/alexander"
LEGION_HOME="$WORK/fleet-mates/legion"
HEALTH_HOME="$WORK/fleet-mates/health"
DECOY_HOME="$WORK/fleet-mates/remote-decoy"
mkdir -p "$FLEET_STATE" "$FLEET_DATA" \
  "$DEV_HOME/state" "$NAP_HOME/state" "$OTTER_HOME/state" \
  "$ALEX_HOME/state" "$LEGION_HOME/state" "$HEALTH_HOME/state" "$DECOY_HOME/state"
: >"$FLEET_STATE/statusbar-claude-usage.tsv"
touch "$FLEET_STATE/.statusbar-claude-usage-attempt"
tmux new-session -d -s fleetbar -n spare "sleep 600" || fail "fleet session did not start"
tmux new-window -d -t fleetbar: -n fm-fleet-dev "sleep 600" || fail "dev window did not start"
tmux new-window -d -t fleetbar: -n fm-fleet-dev-task "sleep 600" || fail "dev task window did not start"
tmux new-window -d -t fleetbar: -n fm-fleet-ada "sleep 600" || fail "ada window did not start"
tmux new-window -d -t fleetbar: -n fm-fleet-otter "sleep 600" || fail "otter window did not start"
tmux new-window -d -t fleetbar: -n fm-fleet-alex "sleep 600" || fail "alex window did not start"
tmux new-window -d -t fleetbar: -n fm-fleet-legion "sleep 600" || fail "legion window did not start"
tmux new-window -d -t fleetbar: -n fm-fleet-health "sleep 600" || fail "health window did not start"
cat >"$FLEET_DATA/secondmates.md" <<REG
- dev - charts (home: $DEV_HOME; scope: charts; projects: none; added 2026-01-01)
- ada - copy (home: $NAP_HOME; scope: copy; projects: none; added 2026-01-01)
- ottersec - review (home: $OTTER_HOME; scope: review; projects: none; added 2026-01-01)
- alexander - media (home: $ALEX_HOME; scope: media; projects: none; added 2026-01-01)
- legion - mail (home: $LEGION_HOME; scope: mail; projects: none; added 2026-01-01)
REG
printf 'window=fleetbar:fm-fleet-dev\nkind=secondmate\nhome=%s\n' "$DEV_HOME" >"$FLEET_STATE/dev.meta"
printf 'window=fleetbar:fm-fleet-ada\nkind=secondmate\nhome=%s\n' "$NAP_HOME" >"$FLEET_STATE/ada.meta"
printf 'window=fleetbar:fm-fleet-otter\nkind=secondmate\nhome=%s\n' "$OTTER_HOME" >"$FLEET_STATE/ottersec.meta"
printf 'window=fleetbar:fm-fleet-alex\nkind=secondmate\nhome=%s\n' "$ALEX_HOME" >"$FLEET_STATE/alexander.meta"
printf 'window=fleetbar:fm-fleet-legion\nkind=secondmate\nhome=%s\n' "$LEGION_HOME" >"$FLEET_STATE/legion.meta"
printf 'window=fleetbar:fm-fleet-health\nkind=secondmate\nhome=%s\n' "$HEALTH_HOME" >"$FLEET_STATE/health.meta"
printf 'window=fleetbar:fm-fleet-health\nkind=ship\nbackend=tmux\n' >"$HEALTH_HOME/state/vitals.meta"
printf 'working [at=1]: checking vitals\n' >"$HEALTH_HOME/state/vitals.status"
printf '# example only\nhealth\nlead-haven\n' >"$FLEET_DATA/secondmate-on-demand"
printf 'window=fleetbar:fm-gone-mate\nkind=secondmate\nhome=%s\n' "$DEV_HOME" >"$FLEET_STATE/gone.meta"
printf 'window=remote:far\nkind=secondmate\nremote_host=example.invalid\nhome=%s\n' "$DECOY_HOME" >"$FLEET_STATE/far.meta"
printf 'window=fleetbar:fm-fleet-dev-task\nkind=ship\nbackend=tmux\n' >"$DEV_HOME/state/supercalifragilistic.meta"
printf 'working [at=1]: reviewing charts\n' >"$DEV_HOME/state/supercalifragilistic.status"
printf 'window=fleetbar:fm-fleet-ada\nkind=ship\nbackend=tmux\n' >"$NAP_HOME/state/headlines.meta"
printf 'paused [at=1]: waiting on a draft\n' >"$NAP_HOME/state/headlines.status"
printf 'window=fleetbar:fm-fleet-otter\nkind=ship\nbackend=tmux\n' >"$OTTER_HOME/state/audit.meta"
printf 'working [at=1]: auditing\n' >"$OTTER_HOME/state/audit.status"
printf 'window=fleetbar:fm-fleet-alex\nkind=ship\nbackend=tmux\n' >"$ALEX_HOME/state/cuts.meta"
printf 'working [at=1]: cutting\n' >"$ALEX_HOME/state/cuts.status"
printf 'window=fleetbar:fm-fleet-legion\nkind=ship\nbackend=tmux\n' >"$LEGION_HOME/state/send.meta"
printf 'working [at=1]: sending\n' >"$LEGION_HOME/state/send.status"
printf 'needs-decision [at=1] [key=color]: choose a color\n' >"$FLEET_STATE/palette.status"
printf 'needs-decision [at=1] [key=old]: stale\nresolved [at=2] [key=old]: picked\n' >"$FLEET_STATE/closed.status"
printf 'needs-decision [at=1] [key=mate-pick]: which chart\n' >"$DEV_HOME/state/chart-call.status"
printf 'window=fleetbar:fm-fleet-dev-task\nkind=ship\nbackend=tmux\n' >"$DECOY_HOME/state/should-not-appear.meta"
printf 'working [at=1]: leak\n' >"$DECOY_HOME/state/should-not-appear.status"
fleet_env() {
  FM_HOME="$FLEET_HOME" FM_STATE_OVERRIDE="$FLEET_STATE" FM_DATA_OVERRIDE="$FLEET_DATA" "$@"
}
fleet_env bash "$SB" --socket "$SOCKET_PATH" claude-fleet-refresh || fail "fleet refresh failed"
fleet_line=$(printf '%s' '{"model":{"display_name":"Opus"},"effort":{"level":"high"},"context_window":{"used_percentage":12.8}}' | fleet_env bash "$SB" --socket "$SOCKET_PATH" claude-line --task main-task)
case "$fleet_line" in
  "Opus high | Ctx 12% | "*" | main-task") ;;
  *) fail "fleet line dropped Ctx or the model and task segments" "$fleet_line" ;;
esac
case "$fleet_line" in
  *"dev:supercalifra working"*) ;;
  *) fail "live mate task was not truncated into the line" "$fleet_line" ;;
esac
case "$fleet_line" in
  *"ada:headlines paused"*) ;;
  *) fail "paused mate task missing" "$fleet_line" ;;
esac
case "$fleet_line" in
  *"far:remote"*) ;;
  *) fail "remote mate missing" "$fleet_line" ;;
esac
case "$fleet_line" in
  *should-not-appear* | *gone:* | *health* | *vitals*) fail "dead, on-demand, or remote-decoy work leaked" "$fleet_line" ;;
esac
case "$fleet_line" in
  *"hold 2"*) ;;
  *) fail "captain waits were not counted" "$fleet_line" ;;
esac
case "$fleet_line" in
  *"+2"*) ;;
  *) fail "mates past the fourth were not collapsed" "$fleet_line" ;;
esac
pass "claude-line shows live mates, truncates names, and counts captain waits"

stale="$FLEET_STATE/statusbar-claude-fleet.txt"
printf 'cached-mates\n' >"$stale"
touch "$stale" "$FLEET_STATE/.statusbar-claude-fleet-attempt"
cached_line=$(printf '%s' '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":3}}' | fleet_env bash "$SB" --socket "$SOCKET_PATH" claude-line --task main-task)
case "$cached_line" in
  "Opus ? | Ctx 3% | cached-mates | main-task") ;;
  *) fail "warm cache was not used" "$cached_line" ;;
esac
start_ns=$(date +%s%N)
i=0
while [ "$i" -lt 20 ]; do
  printf '%s' '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":3}}' | fleet_env bash "$SB" --socket "$SOCKET_PATH" claude-line --task main-task >/dev/null
  i=$((i + 1))
done
elapsed_ms=$(( ($(date +%s%N) - start_ns) / 1000000 ))
# A quiet 20-call run measured about 96ms each. The bound stays above that so a
# synchronous rebuild (sourcing the status readers on the hot path) still fails.
[ "$elapsed_ms" -lt 3000 ] || fail "warm statusLine did not stay on the cache" "$elapsed_ms ms for 20 calls"
pass "warm fleet cache stays fast and is not rebuilt inside the TTL"

chmod 000 "$FLEET_DATA/secondmates.md"
touch -d '30 seconds ago' "$stale" "$FLEET_STATE/.statusbar-claude-fleet-attempt"
fleet_env bash "$SB" --socket "$SOCKET_PATH" claude-fleet-refresh || fail "unreadable registry refresh failed"
chmod 644 "$FLEET_DATA/secondmates.md"
unreadable=$(head -n 1 "$stale")
[ -z "$unreadable" ] || fail "unreadable registry still produced a fleet segment" "$unreadable"
dropped=$(printf '%s' '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":3}}' | fleet_env bash "$SB" --socket "$SOCKET_PATH" claude-line --task main-task)
[ "$dropped" = "Opus ? | Ctx 3% | main-task" ] || fail "unreadable fleet source changed the model or Ctx segments" "$dropped"
pass "an unreadable mate registry drops only the fleet segment"

missing=$(printf '%s' '{"model":{"display_name":"Haiku"}}' | FM_HOME="$WORK/missing-fleet-home" FM_STATE_OVERRIDE="$WORK/missing-fleet-home/state" FM_DATA_OVERRIDE="$WORK/missing-fleet-home/data" bash "$SB" --socket "$SOCKET_PATH" claude-line --task t1)
[ "$missing" = "Haiku ? | t1" ] || fail "missing fleet sources failed the status line" "$missing"
pass "missing fleet sources leave the status line intact"

# --- subscription usage segment: cached quota-axi read, per-account labels ---
USAGE_HOME="$WORK/usage-home"
USAGE_STATE="$USAGE_HOME/state"
USAGE_BIN="$WORK/usage-bin"
ACCOUNTS="$WORK/accounts"
mkdir -p "$USAGE_STATE" "$USAGE_HOME/config" "$USAGE_BIN" \
  "$ACCOUNTS/gmail" "$ACCOUNTS/second" "$ACCOUNTS/backups"
: >"$ACCOUNTS/gmail/.claude.json"; : >"$ACCOUNTS/second/.claude.json"; : >"$ACCOUNTS/backups/.claude.json"
printf '%s\n%s\n' "$ACCOUNTS/gmail" "$ACCOUNTS/second" >"$USAGE_HOME/config/statusline-claude-accounts"
RESET_2D=$(date -u -d '+50 hours' +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -v+50H +%Y-%m-%dT%H:%M:%S.000Z)
RESET_4H=$(date -u -d '+4 hours 30 minutes' +%Y-%m-%dT%H:%M:%S+00:00 2>/dev/null || date -u -v+4H -v+30M +%Y-%m-%dT%H:%M:%S+00:00)
RESET_6D=$(date -u -d '+6 days 2 hours' +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -v+6d -v+2H +%Y-%m-%dT%H:%M:%S.000Z)
cat >"$USAGE_BIN/quota-axi" <<SH
#!/usr/bin/env bash
echo "\$CLAUDE_CONFIG_DIR|\$*" >>"$WORK/usage-calls"
[ ! -f "$WORK/usage-fail" ] || exit 1
if [ -f "$WORK/usage-profile-missing" ] && [[ "\$CLAUDE_CONFIG_DIR" == */gmail ]]; then
  case "\$*" in
    *--profile-only*)
      echo 'quota: []'
      echo 'attention[1]{provider,accountKey,scope,kind,detail,remedy}:'
      echo '  claude,default,all_models,auth_required,profile_missing,none' ;;
    *)
      echo 'quota[1]{provider,accountKey,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:'
      echo '  claude,default,all_models,77,0.1,through_reset,early,five_hour,none' ;;
  esac
  exit 0
fi
if [ -f "$WORK/usage-codex-default-only" ]; then
  echo 'quota[1]{provider,accountKey,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:'
  echo '  codex,default,all_models,68,0.1,through_reset,early,weekly,none'
  exit 0
fi
if [ -f "$WORK/usage-codex-attention-counted" ]; then
  echo 'quota: []'
  echo 'attention[1]{provider,accountKey,scope,kind,detail,remedy}:'
  echo '  codex,default,all_models,unmeasurable,no_quota,none'
  exit 0
fi
if [ -f "$WORK/usage-codex-attention-inline" ]; then
  echo 'quota: []'
  echo 'attention: [{"provider":"codex","accountKey":"default","scope":"all_models","kind":"unmeasurable","detail":"no_quota","remedy":"none"}]'
  exit 0
fi
if [ -f "$WORK/usage-endpoints" ]; then
  case "\$*" in
    *--provider\ claude*)
      echo 'quota[1]{provider,accountKey,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:'
      case "\$CLAUDE_CONFIG_DIR" in
        */gmail) echo '  claude,default,all_models,0.5,0.1,through_reset,early,weekly,none' ;;
        *) echo '  claude,default,all_models,99.6,0.1,through_reset,early,weekly,none' ;;
      esac ;;
    *)
      echo 'quota[3]{provider,accountKey,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:'
      echo '  muse,default,all_models,0.5,0.1,through_reset,early,weekly,none'
      echo '  grok,default,all_products,99.6,0.1,through_reset,early,weekly,none'
      echo '  codex,codex-home,all_models,0.5,0.1,through_reset,early,weekly,none' ;;
  esac
  exit 0
fi
if [ -f "$WORK/usage-attention" ]; then
  echo 'quota: []'
  echo 'attention[5]{provider,accountKey,scope,kind,detail,remedy}:'
  echo '  muse,default,all_models,unmeasurable,no_quota,none'
  echo '  grok,default,all_models,auth_required,login_required,none'
  echo '  codex,codex-home,all_models,error,request_failed,none'
  echo '  claude,default,all_models,auth_required,login_required,none'
  echo '  claude,other,all_models,unmeasurable,no_quota,none'
  exit 0
fi
if [ -f "$WORK/usage-inline-attention" ]; then
  echo 'quota: []'
  echo 'attention: [{"provider":"muse","accountKey":"default","scope":"all_models","kind":"unmeasurable","detail":"no_quota","remedy":"none"},{"provider":"grok","accountKey":"default","scope":"all_models","kind":"auth_required","detail":"login_required","remedy":"none"},{"provider":"codex","accountKey":"codex-home","scope":"all_models","kind":"error","detail":"request_failed","remedy":"none"},{"provider":"claude","accountKey":"default","scope":"all_models","kind":"auth_required","detail":"login_required","remedy":"none"}]'
  exit 0
fi
case "\$*" in
  *--provider\ claude*)
    echo 'quota[2]{provider,accountKey,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:'
    case "\$CLAUDE_CONFIG_DIR" in
      */gmail) echo '  claude,other,all_models,77,0.1,through_reset,early,five_hour,"$RESET_4H"'; echo '  claude,default,all_models,15,0.1,through_reset,early,seven_day,"$RESET_2D"' ;;
      */second) echo '  claude,other,all_models,77,0.1,through_reset,early,five_hour,"$RESET_4H"'; echo '  claude,default,all_models,91.4,0.1,through_reset,early,five_hour,"$RESET_4H"' ;;
      *) echo '  claude,other,all_models,77,0.1,through_reset,early,five_hour,"$RESET_4H"'; echo '  claude,default,all_models,77,0.1,through_reset,early,five_hour,"$RESET_4H"' ;;
    esac ;;
  *)
    echo 'quota[5]{provider,accountKey,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:'
    echo '  grok,xai,all_products,30,1,through_reset,established,credits,"$RESET_2D"'
    echo '  codex,default,all_models,68,-1,projected_exhaustion,established,weekly,"$RESET_6D"'
    echo '  grok,default,all_products,47,1,through_reset,established,credits,"$RESET_2D"'
    echo '  grok,default,"product:grok_build",30,1,through_reset,established,credits,"$RESET_2D"'
    echo '  codex,codex-home,all_models,43,-1,projected_exhaustion,established,weekly,"$RESET_6D"' ;;
esac
SH
chmod +x "$USAGE_BIN/quota-axi"
usage_env() {
  FM_HOME="$USAGE_HOME" FM_STATE_OVERRIDE="$USAGE_STATE" FM_DATA_OVERRIDE="$USAGE_HOME/data" \
    COLUMNS="${COLUMNS:-160}" PATH="$USAGE_BIN:$PATH" "$@"
}
cache="$USAGE_STATE/statusbar-claude-usage.tsv"
wait_usage() {
  local expected=$1 actual
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    actual=$(usage_env bash "$SB" claude-segments)
    case "$actual" in *"$expected"*) printf '%s' "$actual"; return 0 ;; esac
    sleep 0.25
  done
  fail "background usage refresh did not produce $expected" "$actual"
}

cold=$(usage_env bash "$SB" claude-segments)
[ -z "$cold" ] || fail "cold usage cache printed a segment" "$cold"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$cache" ] && break; sleep 0.25; done
[ -s "$cache" ] || fail "cold render did not start a background refresh"
seg=$(usage_env bash "$SB" claude-segments)
expect_re='^mu n/a, gk 47% 2d, cl-gmail 15% 2d, cl-second 91% 4h[0-9]+m, cx 43% 6d$'
[[ $seg =~ $expect_re ]] || fail "usage segment wrong" "$seg"
case "$seg" in *backups*) fail "a config directory without projects was treated as an account" "$seg" ;; esac
grep -q "second|--provider claude --profile-only" "$WORK/usage-calls" || fail "claude read did not select only the account directory" "$(cat "$WORK/usage-calls")"
pass "usage segment shows each subscription, labelled per Claude account, from a background refresh"

narrow=$(COLUMNS=65 usage_env bash "$SB" claude-segments)
[ "$narrow" = 'mu n/a, gk 47%, cl-gmail 15%, cl-second 91%, cx 43%' ] || fail "narrow usage segment lost a percentage or retained reset times" "$narrow"
narrow_line=$(printf '%s' '{"model":{"display_name":"Opus"},"rate_limits":{"seven_day":{"used_percentage":11}}}' | COLUMNS=60 usage_env bash "$SB" claude-line --task t1)
case "$narrow_line" in *'mu n/a, gk 47%, cl-gmail 15%, cl-second 91%, cx 43%') ;; *) fail "narrow Claude line lost a percentage or retained reset times" "$narrow_line" ;; esac
pass "both status-line commands omit reset times before subscription percentages"

calls=$(wc -l <"$WORK/usage-calls")
for _ in 1 2 3; do usage_env bash "$SB" claude-segments >/dev/null; done
[ "$(wc -l <"$WORK/usage-calls")" = "$calls" ] || fail "fresh usage cache re-ran quota-axi"
pass "a fresh usage cache is only read"

line=$(printf '%s' '{"model":{"display_name":"Opus"},"rate_limits":{"seven_day":{"used_percentage":11}}}' | usage_env bash "$SB" claude-line --task t1)
case "$line" in "Opus ? | t1 | 7d 11% | mu n/a, gk 47%"*) ;; *) fail "claude-line missing the usage segment" "$line" ;; esac
pass "claude-line appends the usage segment after the limits"

printf 'cached-mate:idle\n' >"$USAGE_STATE/statusbar-claude-fleet.txt"
both=$(usage_env bash "$SB" claude-segments)
case "$both" in "cached-mate:idle | mu n/a, gk 47% 2d, cl-gmail 15% 2d, cl-second 91% 4h"*"m, cx 43% 6d") ;; *) fail "claude-segments did not join mates and usage" "$both" ;; esac
narrow_both=$(COLUMNS=75 usage_env bash "$SB" claude-segments)
[ "$narrow_both" = "cached-mate:idle | $narrow" ] || fail "wrapper segment ignored the mate prefix width" "$narrow_both"
pass "claude-segments prints mates and usage on one line"

touch -d '12 minutes ago' "$cache"
touch "$USAGE_STATE/.statusbar-claude-usage-attempt"
stale=$(usage_env bash "$SB" claude-segments)
case "$stale" in *' (stale)') ;; *) fail "old usage cache was not marked stale" "$stale" ;; esac
touch -d '2 hours ago' "$cache"
touch "$USAGE_STATE/.statusbar-claude-usage-attempt"
dropped_usage=$(usage_env bash "$SB" claude-segments)
[ "$dropped_usage" = "cached-mate:idle" ] || fail "very old usage cache was not dropped" "$dropped_usage"
pass "a stale usage cache is marked and a very old one is dropped"

touch "$WORK/usage-fail"
rm -f "$cache" "$USAGE_STATE/.statusbar-claude-usage-attempt"
failed=$(wait_usage 'cl-second ?, cx ?')
[ "$failed" = "cached-mate:idle | mu ?, gk ?, cl-gmail ?, cl-second ?, cx ?" ] || fail "unreadable quota-axi did not mark providers unknown" "$failed"
rm -f "$WORK/usage-fail"
pass "a failed quota read marks the segment unknown instead of failing"

touch "$WORK/usage-attention"
rm -f "$cache" "$USAGE_STATE/.statusbar-claude-usage-attempt"
attention=$(wait_usage 'cl-second ?, cx ?')
[ "$attention" = "cached-mate:idle | mu n/a, gk ?, cl-gmail ?, cl-second ?, cx ?" ] || fail "quota attention was misclassified as unmeasurable" "$attention"
rm -f "$WORK/usage-attention"
pass "quota attention distinguishes unmeasurable and failed reads for every subscription"

touch "$WORK/usage-inline-attention"
rm -f "$cache" "$USAGE_STATE/.statusbar-claude-usage-attempt"
inline_attention=$(wait_usage 'cl-second ?, cx ?')
[ "$inline_attention" = "$attention" ] || fail "inline quota attention differed from the counted table" "$inline_attention"
rm -f "$WORK/usage-inline-attention"
pass "inline quota attention also distinguishes unmeasurable and failed reads"

for source in default-only attention-counted attention-inline; do
  touch "$WORK/usage-codex-$source"
  rm -f "$cache" "$USAGE_STATE/.statusbar-claude-usage-attempt"
  exact=$(wait_usage 'cx ?')
  case "$exact" in *'cx ?') ;; *) fail "Codex borrowed another account from $source" "$exact" ;; esac
  rm -f "$WORK/usage-codex-$source"
done
pass "Codex ignores other accounts in quota and both attention formats"

touch "$WORK/usage-profile-missing"
rm -f "$cache" "$USAGE_STATE/.statusbar-claude-usage-attempt"
profile=$(wait_usage 'cl-gmail ?')
case "$profile" in *'cl-second 91%'*) ;; *) fail "profile-only Claude read hid the available account" "$profile" ;; esac
rm -f "$WORK/usage-profile-missing"
pass "unavailable Claude profile cannot borrow another credential"

touch "$WORK/usage-endpoints"
rm -f "$cache" "$USAGE_STATE/.statusbar-claude-usage-attempt"
endpoints=$(wait_usage 'cx <1%')
[ "$endpoints" = 'cached-mate:idle | mu <1%, gk >99%, cl-gmail <1%, cl-second >99%, cx <1%' ] || fail "usage endpoints rounded to an exhausted or full percent" "$endpoints"
rm -f "$WORK/usage-endpoints"
pass "all subscription percentages retain nonzero and nonfull endpoints"

printf '# pinned\n%s\n%s\n' "$ACCOUNTS/gmail-missing" "$ACCOUNTS/second" >"$USAGE_HOME/config/statusline-claude-accounts"
rm -f "$cache" "$USAGE_STATE/.statusbar-claude-usage-attempt"
pinned=$(wait_usage 'cl-second 91%')
case "$pinned" in *'cl-gmail ?'*) ;; *) fail "missing configured account was omitted" "$pinned" ;; esac
case "$pinned" in *"cl-second 91%"*) ;; *) fail "configured account missing" "$pinned" ;; esac
pass "configured Claude paths keep both labelled accounts, including unavailable ones"

printf '%s' "$pinned" | grep -qiE 'token|secret|credential' && fail "usage output carried a credential-like word"
pass "usage output holds no credential material"

echo "fm-statusbar: all passed"
