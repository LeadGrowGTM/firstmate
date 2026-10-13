#!/usr/bin/env bash
# Run one idle batch inside the existing supervision heartbeat.
# Usage: fm-idle-sweep.sh
# docs/configuration.md owns the two per-home configuration schemas.
# Only reversible, prepared queued tasks may start.
# Output and state/idle-sweep.status name the successful starts in one line.
# Exit 0 includes safe no-ops; invalid config or failed evidence exits nonzero.
# Spawn errors stop the batch without retrying a different backend or model.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-targets-lib.sh
. "$SCRIPT_DIR/fm-targets-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"

case "${1:-}" in
  --help|-h) sed -n '2,9s/^# \{0,1\}//p' "$0"; exit 0 ;;
  '') ;;
  *) echo 'usage: fm-idle-sweep.sh' >&2; exit 2 ;;
esac
fm_targets_init
idle_config() {
  if [ ! -e "$CONFIG/idle-sweep.json" ] && [ ! -L "$CONFIG/idle-sweep.json" ]; then
    printf '%s\n' '{"enabled":true,"steps":[]}'
    return
  fi
  jq -se 'length == 1 and (.[0] | type == "object" and (keys - ["enabled","steps"] | length == 0) and
    (if has("enabled") then (.enabled | type) == "boolean" else true end) and
    (if has("steps") then (.steps | type) == "array" else true end) and
    ([(.steps // [])[].id] | length) == ([(.steps // [])[].id] | unique | length) and
    all((.steps // [])[]; type == "object" and (keys - ["id","target"] | length == 0) and
      (.id | type) == "string" and (.id | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
      (.target as $t | ["red_default_branches","open_prs","stale_backlog","backlog"] | index($t)) != null))
  ' "$CONFIG/idle-sweep.json" >/dev/null &&
    jq -c '{enabled:(if has("enabled") then .enabled else true end),steps:(.steps // [])}' "$CONFIG/idle-sweep.json"
}
config=$(idle_config) || { echo 'fm-idle-sweep: invalid configuration' >&2; exit 2; }
[ "$(printf '%s' "$config" | jq -r .enabled)" = true ] || exit 0
# Independently linted runtime owners, loaded only when running.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"
mkdir -p "$STATE"
lock="$STATE/.idle-sweep.lock"
fm_lock_try_acquire "$lock" || exit 0
trap 'fm_lock_release "$lock" || true' EXIT
snapshot=$(fm_targets_backlog)
fm_targets_observe "$snapshot"

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
    any(.backlog.records[]; .state == "in_flight" and .current_role == "worker" and
      (.id as $id | ($ARGS.positional | index($id)) == null)) | not
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
target_deadline=$(($(date +%s) + 120))
remaining=$((target_deadline - $(date +%s)))
[ "$remaining" -gt 0 ] || exit 1
targets=$(fm_run_timed "$remaining" bash "$SCRIPT_DIR/fm-targets.sh" --json) || exit 1
# Red-branch evidence must be complete before a lower-priority task may start.
printf '%s' "$targets" | jq -e '.targets[] | select(.id == "red_default_branches") | .gap != null' >/dev/null || exit 0
candidates=$(jq -cn --argjson snapshot "$snapshot" --argjson targets "$targets" --argjson config "$config" '
  def row_target:
    [.body_lines[] | select(startswith("Idle target: ")) | ltrimstr("Idle target: ")] as $tags |
    if ($tags | length) == 0 then "backlog"
    elif ($tags | length) == 1 and (["red_default_branches","open_prs","stale_backlog"] | index($tags[0])) != null
    then $tags[0] else null end;
  [$snapshot.backlog.records[] |
    select(.structured and (.id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
      .state == "queued" and .hold_reason == null and
      .hold_kind == null and (.unresolved_blocker_ids | length) == 0 and
      (.kind == null or .kind == "task" or .kind == "ship" or .kind == "scout")) |
    . as $row |
    ([$config.steps[] | select(.id == $row.id)][0].target // ($row | row_target)) as $target |
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
    remaining=$((target_deadline - $(date +%s)))
    [ "$remaining" -gt 0 ] || { failed=1; break; }
    latest_targets=$(fm_run_timed "$remaining" bash "$SCRIPT_DIR/fm-targets.sh" --json) || { failed=1; break; }
  fi
  current_config=$(idle_config) || { failed=1; break; }
  [ "$current_config" = "$config" ] || break
  fm_targets_init || { failed=1; break; }
  if [ "$target_kind" != backlog ]; then
    printf '%s' "$latest_targets" | jq -e --argjson candidate "$candidate" --argjson limits "$TARGET_LIMITS" '
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
    prefix=$(bash "$SCRIPT_DIR/fm-project-mode.sh" --branch-prefix "$project")
    flags+=(--branch-prefix "$prefix")
  fi
  [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || continue
  [ -z "$(status_open_decisions "$STATE/$id.status")" ] || continue
  current=$(fm_targets_backlog) || { failed=1; break; }
  printf '%s' "$current" | jq -e --argjson candidate "$candidate" \
    'any(.backlog.records[]; .structured and .id == $candidate.id and del(.order) == ($candidate.row | del(.order)))' >/dev/null || continue
  home_idle "$current" "${started[@]}" || break
  if bash "$SCRIPT_DIR/fm-spawn.sh" "$id" "$PROJECTS/$project" "${flags[@]}" --harness codex --model gpt-6.1-sol; then
    started+=("$id")
  else
    failed=1
    break
  fi
done < <(printf '%s' "$candidates" | jq -c '.[]')
if [ "${#started[@]}" -gt 0 ]; then
  line="working [at=$(date +%s)]: idle sweep started ${started[*]}"
  printf '%s\n' "$line" | tee -a "$STATE/idle-sweep.status"
fi
[ "$failed" = 0 ]
