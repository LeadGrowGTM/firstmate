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
config='{"enabled":true,"steps":[]}'
if [ -e "$CONFIG/idle-sweep.json" ]; then
  jq -se 'length == 1 and (.[0] | type == "object" and (keys - ["enabled","steps"] | length == 0) and
  (if has("enabled") then (.enabled | type) == "boolean" else true end) and
  (if has("steps") then (.steps | type) == "array" else true end) and
  ([(.steps // [])[].id] | length) == ([(.steps // [])[].id] | unique | length) and
  all((.steps // [])[]; type == "object" and (keys - ["id","target","mode","reversible"] | length == 0) and
    (.id | type) == "string" and (.id | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
    .reversible == true and
    (.target as $t | ["red_default_branches","open_prs","stale_backlog","backlog"] | index($t)) != null and
    (.mode as $m | ["no-mistakes","direct-PR","local-only","scout"] | index($m)) != null))
  ' "$CONFIG/idle-sweep.json" >/dev/null || { echo 'fm-idle-sweep: invalid configuration' >&2; exit 2; }
  config=$(jq -c '{enabled:(if has("enabled") then .enabled else true end),steps:(.steps // [])}' "$CONFIG/idle-sweep.json")
fi
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

# Idle means no local ordinary worker process, not merely an idle terminal.
# Every unknown backend state, orphan in-flight row, or unreadable record holds.
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || [ -L "$meta" ] || continue
  [ -f "$meta" ] && [ ! -L "$meta" ] || exit 0
  [ "$(fm_meta_get "$meta" kind)" != secondmate ] || continue
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || exit 0
  # Arguments expand in the bounded child, not in this shell.
  # shellcheck disable=SC2016
  case "$(fm_run_timed 15 bash -c '. "$1/fm-backend.sh"; fm_backend_agent_state "$2" "$3"' _ "$SCRIPT_DIR" "$backend" "$target")" in
    dead|missing) ;;
    *) exit 0 ;;
  esac
done
printf '%s' "$snapshot" | jq -e 'any(.backlog.records[]; .state == "in_flight" and .current_role == "worker") | not' >/dev/null || exit 0

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
targets=$(fm_targets_collect "$snapshot")
# Red-branch evidence must be complete before a lower-priority task may start.
printf '%s' "$targets" | jq -e '.targets[] | select(.id == "red_default_branches") | .gap != null' >/dev/null || exit 0
candidates=$(jq -cn --argjson snapshot "$snapshot" --argjson targets "$targets" --argjson config "$config" '
  [$snapshot.backlog.records[] |
    select(.structured and (.id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
      .state == "queued" and .hold_reason == null and
      .hold_kind == null and (.unresolved_blocker_ids | length) == 0 and
      (.kind == null or .kind == "task" or .kind == "ship" or .kind == "scout")) |
    . as $row |
    ([$config.steps[] | select(.id == $row.id)][0] //
      {id:$row.id,mode:null,target:
        (if any($targets.repos[]; .project == $row.repo and .red_default_branches == 1) and
            any($targets.targets[]; .id == "red_default_branches" and .gap != null and .gap > 0)
         then "red_default_branches"
         elif ($targets.stale_ids | index($row.id)) != null and
            any($targets.targets[]; .id == "stale_backlog" and .gap != null and .gap > 0)
         then "stale_backlog" else "backlog" end)}) as $step |
    select($step.target == "backlog" or any($targets.targets[]; .id == $step.target and .gap != null and .gap > 0)) |
    select($step.target != "red_default_branches" or any($targets.repos[]; .project == $row.repo and .red_default_branches == 1)) |
    select($step.target != "stale_backlog" or ($targets.stale_ids | index($row.id)) != null) |
    $step + {repo:$row.repo,order:$row.order,row:$row,rank:
      (if $step.target == "red_default_branches" then 0 elif $step.target == "backlog" then 2 else 1 end)}]
  | sort_by(.rank,.order)
')
started=()
failed=0
while IFS= read -r candidate; do
  [ "${#started[@]}" -lt 3 ] || break
  id=$(printf '%s' "$candidate" | jq -r .id)
  project=$(printf '%s' "$candidate" | jq -r '.repo // ""')
  mode=$(printf '%s' "$candidate" | jq -r '.mode // ""')
  # Local clone names cannot be paths or shell programs; no cross-home work.
  case "$project" in ''|.*|*[!A-Za-z0-9._-]*) continue ;; esac
  [ -d "$PROJECTS/$project" ] && [ ! -L "$PROJECTS/$project" ] || continue
  [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || continue
  brief="$DATA/$id/brief.md"
  [ ! -L "$DATA/$id" ] || continue
  [ -f "$brief" ] && [ ! -L "$brief" ] || continue
  quota_clear || break
  if [ -e "$CONFIG/idle-sweep.json" ]; then
    [ "$(jq -c '{enabled:(if has("enabled") then .enabled else true end),steps:(.steps // [])}' "$CONFIG/idle-sweep.json")" = "$config" ] || break
  else
    [ "$config" = '{"enabled":true,"steps":[]}' ] || break
  fi
  current=$(fm_targets_backlog) || { failed=1; break; }
  printf '%s' "$current" | jq -e --argjson candidate "$candidate" \
    'any(.backlog.records[]; .structured and .id == $candidate.id and . == $candidate.row)' >/dev/null || continue
  spec=$(fm_brief_task_heading_body "$brief" '## Firstmate spec')
  printf '%s\n' "$spec" | grep -Fxq 'Never merge, deploy, spend money, contact a client, answer a captain decision, or alter a captain-held item.' || continue
  printf '%s\n' "$spec" | grep -Fxq 'If the task needs one of those actions, report needs-decision to firstmate and stop.' || continue
  if [ -z "$mode" ]; then
    if [ "$(printf '%s' "$candidate" | jq -r '.row.kind // ""')" = scout ]; then
      mode=scout
    else
      mode=$(sed -n 's/^Delivery contract: mode=\([^ ]*\).*$/\1/p' "$brief" | head -n 1)
    fi
  fi
  case "$mode" in no-mistakes|direct-PR|local-only|scout) ;; *) continue ;; esac
  brief_mode=$(sed -n 's/^Delivery contract: mode=\([^ ]*\).*$/\1/p' "$brief" | head -n 1)
  [ "$mode" = scout ] || [ "$mode" = "$brief_mode" ] || continue
  flags=(--mode "$mode" --yolo off)
  if [ "$mode" = scout ]; then
    flags=(--scout)
  else
    prefix=$(bash "$SCRIPT_DIR/fm-project-mode.sh" --branch-prefix "$project")
    flags+=(--branch-prefix "$prefix")
  fi
  [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || continue
  [ -z "$(status_open_decisions "$STATE/$id.status")" ] || continue
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
