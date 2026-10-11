# Sourced by the generated driver: replaces the canned dialog screen of
# tests/fm-remote-secondmate-launch-dialog.test.sh with the screen the REAL
# Claude Code renders, captured from a real tmux pane on a private socket under
# a scratch CLAUDE_CONFIG_DIR that has never accepted bypass mode.
REAL_SOCK="fm-lab-dialog-$$"
REAL_CFG="$TMP_ROOT/claude-cfg"
REAL_WT="$TMP_ROOT/claude-wt"
eval "orig_$(declare -f cleanup)"
cleanup() { tmux -L "$REAL_SOCK" kill-server >/dev/null 2>&1 || true; orig_cleanup; }
pass() { printf 'ok - %s\n' "$1"; printf -- '----- product output -----\n%s\n--------------------------\n' "${out:-}"; }
park_on_bypass_dialog() {
  local i tail=''
  if ! tmux -L "$REAL_SOCK" has-session -t dlg 2>/dev/null; then
    mkdir -p "$REAL_CFG" "$REAL_WT"; git -C "$REAL_WT" init -q
    jq -n --arg wt "$(cd "$REAL_WT" && pwd -P)" \
      '{hasCompletedOnboarding: true, projects: {($wt): {hasTrustDialogAccepted: true}}}' > "$REAL_CFG/.claude.json"
    tmux -L "$REAL_SOCK" new-session -d -s dlg -x 120 -y 40 -c "$REAL_WT" -- \
      env CLAUDE_CONFIG_DIR="$REAL_CFG" "$(command -v claude)" --dangerously-skip-permissions hello
  fi
  for i in $(seq 1 100); do
    tail=$(tmux -L "$REAL_SOCK" capture-pane -p -t dlg -S -40 2>/dev/null) || true
    printf '%s' "$tail" | grep -q 'Bypass Permissions mode' && break
    sleep 0.2
  done
  printf '%s' "$tail" | grep -q 'Bypass Permissions mode' || fail "real claude never rendered the dialog: $tail"
  printf '%s\n' "$tail" > "$SCREEN"
  printf '===== real Claude Code %s pane, captured live =====\n%s\n=====\n' "$(claude --version)" "$tail"
}
