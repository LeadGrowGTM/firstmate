#!/usr/bin/env bash
# fm-launch-outcome-lib.sh - attempt-scoped spawn evidence for scheduled intake.
# Sourced by fm-spawn.sh; no file or extra probe unless FM_SPAWN_OUTCOME_FILE
# names an absolute, absent file in an existing private directory owned by us.
# The initial receipt is uncertain so a crash never grants retry authority.
# Single-task workers only; a batch or supervisor launch refuses this opt-in.
# Final receipts are atomically replaced, version=1, with task, backend,
# harness/model/effort, mode/yolo, spawn_gen, exit_code, launch_sent, outcome.
# Outcomes: unsafe-refusal (default), capacity (explicit admission deferral),
# worker-unavailable (explicit pre-provisioning guard), uncertain (delivery
# started but did not commit), worker-published (spawn's commit succeeded).
# Guarded control relaunch additionally emits live-worker after confirming alive.
# worker-published proves launch delivery/backlog publication, not process health.
# Missing/malformed receipts and nonzero late outcomes require reconciliation.
# No receipt contains credentials or account-root paths.

fm_launch_outcome_init() {
  FM_OUTCOME_TASK=${1:-}
  FM_LAUNCH_OUTCOME_FILE=${FM_SPAWN_OUTCOME_FILE:-}
  FM_LAUNCH_OUTCOME=unsafe-refusal
  FM_LAUNCH_OUTCOME_REASON=guard-refusal
  [ -n "$FM_LAUNCH_OUTCOME_FILE" ] || return 0
  local parent
  case "$FM_LAUNCH_OUTCOME_FILE" in /*) ;; *) return 1 ;; esac
  parent=${FM_LAUNCH_OUTCOME_FILE%/*}
  [ -d "$parent" ] && [ ! -L "$parent" ] && [ -O "$parent" ] || return 1
  [ -z "$(find "$parent" -prune \( -perm -g=w -o -perm -o=w \) -print)" ] || return 1
  # noclobber also refuses an existing symlink and serializes equal paths.
  (umask 077; set -C; printf '{"version":1,"outcome":"uncertain","reason":"attempt-started"}\n' > "$FM_LAUNCH_OUTCOME_FILE") || return 1
}

fm_launch_outcome_write() { # <exit-code>
  [ -n "${FM_LAUNCH_OUTCOME_FILE:-}" ] || return 0
  local code=$1 outcome=$FM_LAUNCH_OUTCOME tmp
  if { [ "${SPAWN_LAUNCH_SENT:-0}" = 1 ] || [ "${SPAWN_PROVISIONING_STARTED:-0}" = 1 ] || [ "${RELAUNCH_STOP_STARTED:-0}" = 1 ]; } && [ "$code" -ne 0 ]; then
    outcome=uncertain
    FM_LAUNCH_OUTCOME_REASON=provisioning-or-delivery-started
  fi
  tmp=$(mktemp "${FM_LAUNCH_OUTCOME_FILE}.XXXXXX") || return 1
  if ! jq -n --arg outcome "$outcome" --arg reason "$FM_LAUNCH_OUTCOME_REASON" \
    --arg task "${ID:-${FM_OUTCOME_TASK:-}}" --arg backend "${BACKEND:-}" \
    --arg harness "${FM_OUTCOME_HARNESS:-${HARNESS:-}}" --arg model "${MODEL:-default}" \
    --arg effort "${EFFORT:-default}" --arg mode "${MODE:-}" \
    --arg yolo "${YOLO:-}" --arg gen "${SPAWN_GEN:-}" \
    --argjson code "$code" --argjson sent "${SPAWN_LAUNCH_SENT:-0}" \
    '{version:1,outcome:$outcome,reason:$reason,task:$task,backend:$backend,
      harness:$harness,model:$model,effort:$effort,mode:$mode,yolo:$yolo,
      spawn_gen:$gen,exit_code:$code,launch_sent:($sent == 1)}' > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp" && mv -f "$tmp" "$FM_LAUNCH_OUTCOME_FILE"
}
