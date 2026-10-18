#!/usr/bin/env bash
# Run one idle batch inside the existing supervision heartbeat.
# Usage: fm-idle-sweep.sh
# docs/configuration.md owns the two per-home configuration schemas.
# Only reversible, prepared queued tasks may start.
# Output and state/idle-sweep.status name successful starts and each refusal.
# Exit 0 includes safe no-ops; each nonzero exit names its reason on stderr and in that file.
# Spawn errors stop the batch without retrying a different backend or model.
set -eu
# FM_IDLE_SWEEP_COLLECTION_BUDGET, a whole number from 1 to 120, replaces the
# 120 second target-collection budget for a test. Any other value keeps 120.
# A refusal appends one line to state/idle-sweep.status:
# [at=<epoch>] idle sweep refused: <reason>
# bin/fm-watch.sh copies that reason into the check: idle-sweep wake payload.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-targets-lib.sh
. "$SCRIPT_DIR/fm-targets-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"

# Record and print one refusal. The status line is the contract fm-watch.sh reads.
idle_sweep_record_refusal() { # <reason>
  local reason=$1 line
  reason=$(printf '%s' "$reason" | tr '\t\r\n' '   ' | cut -c1-160)
  reason=${reason#"${reason%%[![:space:]]*}"}
  reason=${reason%"${reason##*[![:space:]]}"}
  [ -n "$reason" ] || reason='idle sweep refused'
  [ -n "${STATE:-}" ] || return 0
  mkdir -p -- "$STATE" 2>/dev/null || return 0
  line="[at=$(date +%s)] idle sweep refused: ${reason}"
  printf '%s\n' "$line" >> "$STATE/idle-sweep.status" || return 0
}

refuse() { # <status> <reason>
  printf 'fm-idle-sweep: %s\n' "$2" >&2
  idle_sweep_record_refusal "$2"
  exit "$1"
}

idle_collection_budget() {
  case "${FM_IDLE_SWEEP_COLLECTION_BUDGET:-}" in
    [1-9]|[1-9][0-9]|1[0-1][0-9]|120) printf '%s' "$FM_IDLE_SWEEP_COLLECTION_BUDGET" ;;
    *) printf '120' ;;
  esac
}

classify_snapshot_failure() { # <errfile>
  local errfile=$1
  if [ -f "$errfile" ] && [ ! -L "$errfile" ] && grep -F -q 'only the local markdown backlog is supported' "$errfile"; then
    printf 'invalid configuration'
    return 0
  fi
  printf 'snapshot failure'
}

classify_targets_failure() { # <rc> <errfile> <bound-seconds>
  local rc=$1 errfile=$2 bound=$3
  if fm_timed_out "$rc"; then
    printf 'targets collection timed out after %s s' "$bound"
    return 0
  fi
  if [ -f "$errfile" ] && [ ! -L "$errfile" ] && grep -F -q 'only the local markdown backlog is supported' "$errfile"; then
    printf 'invalid configuration'
    return 0
  fi
  if [ -f "$errfile" ] && [ ! -L "$errfile" ] && grep -F -q 'fm-fleet-snapshot:' "$errfile"; then
    printf 'snapshot failure'
    return 0
  fi
  if ! fm_targets_init >/dev/null 2>&1; then
    printf 'invalid configuration'
    return 0
  fi
  printf 'GitHub evidence unavailable'
}

case "${1:-}" in
  --help|-h) sed -n '2,9s/^# \{0,1\}//p' "$0"; exit 0 ;;
  '') ;;
  *)
    FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
    STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
    printf '%s\n' 'usage: fm-idle-sweep.sh' >&2
    idle_sweep_record_refusal 'usage: fm-idle-sweep.sh'
    exit 2
    ;;
esac
fm_targets_init || refuse 1 'invalid configuration'
# A marked lab must address its private tmux server even when the sweep is
# invoked from a host shell instead of a lab pane.
if [ -e "$FM_HOME/.fm-lab-home" ] || [ -L "$FM_HOME/.fm-lab-home" ]; then
  lab_socket_record="$FM_HOME/state/.fm-lab-tmux-dir"
  [ -f "$lab_socket_record" ] && [ ! -L "$lab_socket_record" ] || refuse 2 'lab tmux socket record is missing'
  lab_socket_dir=$(cat "$lab_socket_record") || refuse 2 'lab tmux socket record is invalid'
  [[ "$lab_socket_dir" =~ ^/tmp/fml\.[A-Za-z0-9]{6}$ ]] || refuse 2 'lab tmux socket record is invalid'
  [ "${TMUX_TMPDIR:-}" = "$lab_socket_dir" ] || refuse 2 'lab private tmux socket is not selected'
  if [ -n "${TMUX:-}" ]; then
    case "${TMUX%%,*}" in
      "$lab_socket_dir"/tmux-"$(id -u)"/*) ;;
      *) refuse 2 'current tmux pane is outside the lab' ;;
    esac
  fi
fi
idle_config() {
  if [ ! -e "$CONFIG/idle-sweep.json" ] && [ ! -L "$CONFIG/idle-sweep.json" ]; then
    printf '%s\n' '{"enabled":true}'
    return
  fi
  jq -se 'length == 1 and (.[0] | type == "object" and (keys - ["enabled"] | length == 0) and
    (if has("enabled") then (.enabled | type) == "boolean" else true end))
  ' "$CONFIG/idle-sweep.json" >/dev/null &&
    jq -c '{enabled:(if has("enabled") then .enabled else true end)}' "$CONFIG/idle-sweep.json"
}
config=$(idle_config) || refuse 2 'invalid configuration'
[ "$(printf '%s' "$config" | jq -r .enabled)" = true ] || exit 0
# Independently linted runtime owners, loaded only when running.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
mkdir -p "$STATE"
lock="$STATE/.idle-sweep.lock"
fm_lock_try_acquire "$lock" || exit 0
payload_dir=
collection_err=
cleanup_idle_payload() {
  if [ -n "$payload_dir" ]; then
    rm -rf -- "$payload_dir"
    payload_dir=
  fi
  if [ -n "$collection_err" ]; then
    rm -f -- "$collection_err"
    collection_err=
  fi
}
trap 'cleanup_idle_payload || true; fm_lock_release "$lock" || true' EXIT
collection_err=$(mktemp "${TMPDIR:-/tmp}/fm-idle-sweep-err.XXXXXX") || refuse 1 'snapshot failure'
snapshot_rc=0
snapshot=$(fm_targets_backlog 2>"$collection_err") || snapshot_rc=$?
if [ "$snapshot_rc" -ne 0 ]; then
  refuse 1 "$(classify_snapshot_failure "$collection_err")"
fi
fm_targets_observe "$snapshot" || refuse 1 'snapshot failure'

home_idle() {
  local current_snapshot=$1 meta id backend target started_id
  shift
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    for started_id; do [ "$id" != "$started_id" ] || continue 2; done
    [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
    [ "$(fm_meta_get "$meta" kind)" != secondmate ] || continue
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || return 1
    # shellcheck disable=SC2016
    case "$(fm_run_timed 15 bash -c '. "$1/fm-backend.sh"; fm_backend_agent_state "$2" "$3"' _ "$SCRIPT_DIR" "$backend" "$target")" in
      dead|missing) ;;
      *) return 1 ;;
    esac
  done
  printf '%s' "$current_snapshot" | jq -e '
    any(.backlog.records[]; .state == "in_flight" and
      ((.structured | not) or (.current_role == "worker" and
        (.id as $id | ($ARGS.positional | index($id)) == null)))) | not
  ' --args "$@" >/dev/null
}
home_idle "$snapshot" || exit 0

quota_clear() {
  local quota
  quota=$(fm_run_timed 20 quota-axi --provider codex --json --no-credential-refresh) || return 1
  printf '%s' "$quota" | fm_quota_json_valid || return 1
  printf '%s' "$quota" | jq -e "$FM_QUOTA_ROW_JQ"'
    . as $s | quota_row($s; "codex"; quota_lane("codex"; "gpt-6.1-sol")) |
    select(.state.status == "fresh" and .state.stale == false and .notSetUp != true) |
    .quotaSemantics | .status == "known" and (.effectiveAvailability | length) > 0 and
    all(.effectiveAvailability[]; .status == "known" and .effectivePercentRemaining > 15)
  ' >/dev/null
}
quota_clear || exit 0
collection_budget=$(idle_collection_budget)
collection_remaining=$collection_budget
collection_start=$(date +%s)
: > "$collection_err"
targets_rc=0
targets=$(fm_run_timed "$collection_remaining" bash "$SCRIPT_DIR/fm-targets.sh" --json 2>"$collection_err") || targets_rc=$?
if [ "$targets_rc" -ne 0 ]; then
  refuse 1 "$(classify_targets_failure "$targets_rc" "$collection_err" "$collection_remaining")"
fi
collection_remaining=$((collection_remaining - ($(date +%s) - collection_start)))
# Red-branch evidence must be complete before a lower-priority task may start.
printf '%s' "$targets" | jq -e '.targets[] | select(.id == "red_default_branches") | .gap != null' >/dev/null || exit 0
payload_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-idle-sweep.XXXXXX") || refuse 1 'snapshot failure'
printf '%s' "$snapshot" > "$payload_dir/snapshot.json" || refuse 1 'snapshot failure'
printf '%s' "$targets" > "$payload_dir/targets.json" || refuse 1 'snapshot failure'
candidates=$(jq -cn --slurpfile snapshot "$payload_dir/snapshot.json" --slurpfile targets "$payload_dir/targets.json" '
  def row_target:
    [.body_lines[] | select(startswith("Idle target: ")) | ltrimstr("Idle target: ")] as $tags |
    if ($tags | length) == 0 then "backlog"
    elif ($tags | length) == 1 and (["red_default_branches","open_prs","stale_backlog"] | index($tags[0])) != null
    then $tags[0] else null end;
  ($snapshot[0]) as $snapshot | ($targets[0]) as $targets |
  [$snapshot.backlog.records[] |
    select(.structured and (.id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
      .state == "queued" and .hold_reason == null and
      .hold_kind == null and (.unresolved_blocker_ids | length) == 0 and
      (.kind == null or .kind == "task" or .kind == "ship" or .kind == "scout")) |
    . as $row |
    ($row | row_target) as $target |
    select($target != null) |
    select($target == "backlog" or any($targets.targets[]; .id == $target and .gap != null and .gap > 0)) |
    select($target != "red_default_branches" or any($targets.repos[]; .project == $row.repo and .red_default_branches == 1)) |
    select($target != "stale_backlog" or ($targets.stale_ids | index($row.id)) != null) |
    {id:$row.id,target:$target,repo:$row.repo,order:$row.order,row:$row,rank:
      (if $target == "red_default_branches" then 0 elif $target == "backlog" then 2 else 1 end)}]
  | sort_by(.rank,.order)
')
started=()
failed=0
refusal_reason=
while IFS= read -r candidate; do
  [ "${#started[@]}" -lt 3 ] || break
  id=$(printf '%s' "$candidate" | jq -r .id)
  project=$(printf '%s' "$candidate" | jq -r '.repo // ""')
  target_kind=$(printf '%s' "$candidate" | jq -r .target)
  # Local clone names cannot be paths or shell programs; no cross-home work.
  case "$project" in ''|.*|*[!A-Za-z0-9._-]*) continue ;; esac
  [ -d "$PROJECTS/$project" ] && [ ! -L "$PROJECTS/$project" ] || continue
  [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || continue
  brief="$DATA/$id/brief.md"
  [ ! -L "$DATA/$id" ] || continue
  [ -f "$brief" ] && [ ! -L "$brief" ] || continue
  quota_clear || break
  if [ "$target_kind" != backlog ]; then
    [ "$collection_remaining" -gt 0 ] || {
      refusal_reason="targets collection timed out after ${collection_budget} s"
      failed=1
      break
    }
    collection_start=$(date +%s)
    : > "$collection_err"
    latest_rc=0
    latest_targets=$(fm_run_timed "$collection_remaining" bash "$SCRIPT_DIR/fm-targets.sh" --json 2>"$collection_err") || latest_rc=$?
    if [ "$latest_rc" -ne 0 ]; then
      refusal_reason=$(classify_targets_failure "$latest_rc" "$collection_err" "$collection_remaining")
      failed=1
      break
    fi
    collection_remaining=$((collection_remaining - ($(date +%s) - collection_start)))
    printf '%s' "$latest_targets" | jq -e '.targets[] | select(.id == "red_default_branches") | .gap != null' >/dev/null || break
  fi
  current_config=$(idle_config) || { refusal_reason='invalid configuration'; failed=1; break; }
  [ "$current_config" = "$config" ] || break
  fm_targets_init || { refusal_reason='invalid configuration'; failed=1; break; }
  if [ "$target_kind" != backlog ]; then
    printf '%s' "$candidate" > "$payload_dir/candidate.json" || { refusal_reason='snapshot failure'; failed=1; break; }
    printf '%s' "$latest_targets" | jq -e --slurpfile candidate "$payload_dir/candidate.json" --argjson limits "$TARGET_LIMITS" '
      ($candidate[0]) as $candidate |
      any(.targets[]; .id == $candidate.target and .limit == $limits[$candidate.target] and .gap != null and .gap > 0) and
      ($candidate.target != "red_default_branches" or
        any(.repos[]; .project == $candidate.repo and .red_default_branches == 1)) and
      ($candidate.target != "stale_backlog" or (.stale_ids | index($candidate.id)) != null)
    ' >/dev/null || continue
  fi
  spec=$(fm_brief_task_heading_body "$brief" '## Firstmate spec')
  printf '%s\n' "$spec" | grep -Fxq 'Never merge, deploy, spend money, contact a client, answer a captain decision, or alter a captain-held item.' || continue
  printf '%s\n' "$spec" | grep -Fxq 'If the task needs one of those actions, report needs-decision to firstmate and stop.' || continue
  brief_mode=$(sed -n 's/^Delivery contract: mode=\([^ ]*\).*$/\1/p' "$brief" | head -n 1)
  if [ "$(printf '%s' "$candidate" | jq -r '.row.kind // ""')" = scout ]; then
    [ -z "$brief_mode" ] || [ "$brief_mode" = scout ] || continue
    mode=scout
  else
    mode=$brief_mode
    case "$mode" in no-mistakes|direct-PR|local-only) ;; *) continue ;; esac
  fi
  flags=(--mode "$mode" --yolo off)
  if [ "$mode" = scout ]; then
    flags=(--scout)
  else
    ship_branches=$(sed -n 's/^Ship branch: //p' "$brief")
    if [ -n "$ship_branches" ]; then
      ship_branch=$(printf '%s\n' "$ship_branches" | head -n 1)
      if printf '%s\n' "$ship_branches" | grep -vxF -- "$ship_branch" >/dev/null; then continue; fi
      git check-ref-format --branch "$ship_branch" >/dev/null 2>&1 || continue
      case "$ship_branch" in
        *"$id") prefix=${ship_branch%"$id"} ;;
        *) continue ;;
      esac
    else
      prefix=$(bash "$SCRIPT_DIR/fm-project-mode.sh" --branch-prefix "$project")
    fi
    flags+=(--branch-prefix "$prefix")
  fi
  if base_branches=$(fm_brief_base_branches "$brief"); then
    base_branch=$(printf '%s\n' "$base_branches" | head -n 1)
    [ -n "$base_branch" ] || continue
    if printf '%s\n' "$base_branches" | grep -vxF -- "$base_branch" >/dev/null; then continue; fi
    forge=$(bash "$SCRIPT_DIR/fm-project-mode.sh" --forge "$project")
    fm_base_branch_valid "$base_branch" "$mode" "$forge" fm-idle-sweep.sh || continue
    flags+=(--base-branch "$base_branch")
  fi
  [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || continue
  [ -z "$(status_open_decisions "$STATE/$id.status")" ] || continue
  : > "$collection_err"
  current_rc=0
  current=$(fm_targets_backlog 2>"$collection_err") || current_rc=$?
  if [ "$current_rc" -ne 0 ]; then
    refusal_reason=$(classify_snapshot_failure "$collection_err")
    failed=1
    break
  fi
  printf '%s' "$candidate" > "$payload_dir/candidate.json" || { refusal_reason='snapshot failure'; failed=1; break; }
  printf '%s' "$current" | jq -e --slurpfile candidate "$payload_dir/candidate.json" \
    '($candidate[0]) as $candidate |
     any(.backlog.records[]; .structured and .id == $candidate.id and del(.order) == ($candidate.row | del(.order)))' >/dev/null || continue
  home_idle "$current" "${started[@]}" || break
  if bash "$SCRIPT_DIR/fm-spawn.sh" "$id" "$PROJECTS/$project" "${flags[@]}" --harness codex --model gpt-6.1-sol; then
    started+=("$id")
  else
    refusal_reason='spawn error'
    failed=1
    break
  fi
done < <(printf '%s' "$candidates" | jq -c '.[]')
if [ "${#started[@]}" -gt 0 ]; then
  line="working [at=$(date +%s)]: idle sweep started ${started[*]}"
  printf '%s\n' "$line" | tee -a "$STATE/idle-sweep.status"
fi
if [ "$failed" != 0 ]; then
  refuse 1 "${refusal_reason:-snapshot failure}"
fi
