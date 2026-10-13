#!/usr/bin/env bash
# fm-schedule-check.sh - opt-in, enqueue-only recurring work.
# Usage: fm-schedule-check.sh [check|arm|disarm]
#
# config/schedules.json is owned by docs/configuration.md. Nothing is armed
# automatically. arm installs a private authenticated watcher shim; disarm
# retires only that shim/trust, preserving the journal and queued intent.
# A normal watcher check (approximately 300 seconds) catches up the current
# local day after its HH:MM gate, or the current UTC epoch interval slot.
# Missed slots coalesce. DST uses IANA zoneinfo: a skipped wall time fires on
# the first later poll, a repeated wall time retains one local-date identity.
# One unfinished occurrence per job suppresses new slots until completion.
#
# state/.schedule-occurrences.json retains each job's latest occurrence and a
# snapshot of its intent. Keys are <id>:daily:<YYYY-MM-DD> or
# <id>:interval:<UTC-start>-<UTC-end>.
# A deterministic sched-<digest> task id survives replay of the same occurrence.
# Schedule edits retain completed identities while their time windows remain
# reachable; interval identities include the UTC window, and daily identities
# remain until that date has ended in every possible timezone.
# detected means frozen intent; enqueued means a verified ordinary backlog row;
# dispatched and completed are observed from that same row's In flight and Done
# states. Filing a task or publishing a wake never implies successful completion.
# A due check files/reuses the deterministic task through fm-tasks-axi.sh, with
# a frozen request brief and ownership digest in its body. Ordinary queued-task
# intake owns routing, capacity, launch reconciliation and delivery authority.
# A crash after add or wake publication reuses the same task and wake keys.
# A durable add-attempt marker refuses to recreate a disappeared task, including
# one completed/archived between polls; unknown custody remains pending with
# one failure episode for ordinary backlog reconciliation.
# At most five occurrences are reconciled per poll, with a durable round-robin
# cursor so a busy task or a timed-out segment cannot starve later jobs.
# Disarming or disabling never deletes already filed work or its evidence.
#
# Each operation has a 20-second hard bound, reduced below FM_CHECK_TIMEOUT
# (default 30). Lock contention/timeouts leave durable intent intact. check
# reports an identical failure once until a successful check clears the episode.
# Brief input must be a regular single-link file inside this home's data root,
# at most 64 KiB. Its bytes are frozen at detection; changed sources cannot alter
# a pending request. A task-type pointer freezes the existing type owner's brief
# section, excluding its worker profile. No input command, model, credential,
# forge, endpoint or other home is executed or inspected. Python 3.9+ with IANA
# timezone data and compatible tasks-axi are required for enabled intake.
# FM_SCHEDULE_NOW is a nonnegative epoch override accepted only with FM_TEST_SEAM=1.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/schedules.json"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
JOURNAL="$STATE/.schedule-occurrences.json"
CHECK_ID=scheduled-work
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
ERROR_RECORD="$STATE/.schedule-error"

usage() { awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; }
fail() { printf 'fm-schedule-check: %s\n' "$*" >&2; exit 1; }
scheduler_shim_content() {
  printf '%s\n' '#!/usr/bin/env bash' "export FM_HOME=$(printf '%q' "$FM_HOME")" "exec $(printf '%q' "$SCRIPT_DIR/fm-schedule-check.sh") check"
}
scheduler_shim_owned() {
  [ -f "$CHECK_SHIM" ] && scheduler_shim_content | cmp -s - "$CHECK_SHIM"
}

case "${1:-check}" in
  -h|--help|help) usage; exit 0 ;;
  check|arm|disarm|--locked) ;;
  *) usage >&2; exit 2 ;;
esac
if [ "${1:-check}" = check ] && [ ! -e "$CONFIG" ] && [ ! -L "$CONFIG" ] && [ ! -e "$JOURNAL" ] && [ ! -L "$JOURNAL" ]; then exit 0; fi
[ -d "$STATE" ] && [ ! -L "$STATE" ] || fail 'state directory is unavailable'
[ -d "$(dirname "$CONFIG")" ] && [ ! -L "$(dirname "$CONFIG")" ] || fail 'config directory is unavailable'
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
DEVICE=$(fm_pr_file_device "$STATE") || exit 1
for path in "$JOURNAL" "$ERROR_RECORD"; do
  fm_pr_regular_destination_on_device_or_absent "$path" "$DEVICE" || fail "unsafe path: $path"
done

engine() {
  local now=''
  if [ "${FM_TEST_SEAM:-}" = 1 ]; then now=${FM_SCHEDULE_NOW:-}; fi
  python3 - "$CONFIG" "$JOURNAL" "$FM_HOME" "$now" "$DATA" "$SCRIPT_DIR" "$@" <<'PY'
import datetime as dt
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
from zoneinfo import ZoneInfo

config, journal, home, clock, root, scripts, op, *args = sys.argv[1:]
now = int(clock) if clock else int(time.time())
if now < 0:
    raise SystemExit("invalid epoch")
slug = re.compile(r"[a-z0-9][a-z0-9-]{0,62}\Z")

def read(path, default, limit=1048576):
    if not os.path.lexists(path):
        return default
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > limit:
        raise ValueError("unsafe or oversized file: " + path)
    with open(path, encoding="utf-8") as source:
        return json.load(source)

def atomic(path, content):
    fd, temp = tempfile.mkstemp(prefix=".schedule-write.", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as target:
            target.write(content)
            target.flush()
            os.fsync(target.fileno())
        os.replace(temp, path)
        directory = os.open(os.path.dirname(path), os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)

def write(value):
    content = json.dumps(value, sort_keys=True) + "\n"
    if len(content.encode()) > 16777216:
        raise ValueError("occurrence journal exceeds 16 MiB")
    atomic(journal, content)

def safe_file(path, limit):
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > limit:
        raise ValueError("unsafe or oversized brief: " + path)
    with open(path, encoding="utf-8") as source:
        return source.read()

def freeze(job):
    if "brief" in job:
        if os.path.commonpath((os.path.realpath(root), os.path.realpath(job["brief"]))) != os.path.realpath(root):
            raise ValueError("brief must remain inside this home's data root")
        source = safe_file(job["brief"], 65536)
    else:
        read(os.path.join(os.path.dirname(config), "task-types.json"), None)
        rendered = subprocess.run([
            "bash", "-c", '. "$1"; fm_task_type_render "$2" "$3" "$4" || exit 1; printf "%s\\n" "$FM_TASK_TYPE_SECTION"',
            "_", os.path.join(scripts, "fm-task-type-lib.sh"), os.path.dirname(config), job["task_type"], job["project"]
        ], capture_output=True, text=True, check=True)
        source = rendered.stdout
    content = "# Recurring work request\n\n## Captain's intent\n" + job["intent"] + "\n\n" + source
    if len(content.encode()) > 73728:
        raise ValueError("frozen brief exceeds size bound")
    return content

def slot_end(key):
    slot = key.rsplit(":", 1)[1]
    if ":interval:" in key:
        return int(slot.rsplit("-", 1)[1])
    next_day = dt.date.fromisoformat(slot) + dt.timedelta(days=1)
    return int(dt.datetime.combine(next_day, dt.time(), dt.timezone.utc).timestamp()) + 12 * 3600

def body(record):
    return ("schedule-occurrence: " + record["key"] + "\n"
            + "brief: " + record["brief_path"] + "\n"
            + "frozen-brief-sha256: " + record["brief_sha256"] + "\n"
            + "delivery intent: " + record["intent"]["delivery"] + "\n")

def persist_frozen(path, content):
    if os.path.lexists(path):
        if safe_file(path, 1048576) != content:
            raise ValueError("frozen task material changed: " + path)
    else:
        atomic(path, content)

def text(value):
    return isinstance(value, str) and 0 < len(value) <= 4096 and not any(ord(c) < 32 for c in value)

def jobs():
    cfg = read(config, {"version": 1, "schedules": []})
    if not isinstance(cfg, dict) or set(cfg) != {"version", "schedules"} or type(cfg["version"]) is not int or cfg["version"] != 1:
        raise ValueError("invalid schedules schema")
    items = cfg["schedules"]
    if not isinstance(items, list) or len(items) > 100:
        raise ValueError("schedules must be an array of at most 100 jobs")
    seen = set()
    for job in items:
        required = {"id", "enabled", "home", "project", "delivery", "intent", "cadence"}
        if not isinstance(job, dict) or not required <= set(job) or set(job) - required - {"brief", "task_type"}:
            raise ValueError("invalid job fields (commands, accounts and models are not schedule fields)")
        identity = job["id"]
        if not isinstance(identity, str) or not slug.fullmatch(identity) or identity in seen:
            raise ValueError("invalid or duplicate schedule id")
        seen.add(identity)
        if type(job["enabled"]) is not bool or not os.path.isabs(home) or job["home"] != home:
            raise ValueError(identity + ": enabled must be boolean and home must match FM_HOME")
        if any(not text(job[field]) for field in ("project", "intent")):
            raise ValueError(identity + ": invalid project or intent")
        if job["delivery"] not in ("no-mistakes", "direct-PR", "local-only", "scout"):
            raise ValueError(identity + ": invalid delivery intent")
        if ("brief" in job) == ("task_type" in job):
            raise ValueError(identity + ": select exactly one brief or task_type pointer")
        if "brief" in job:
            if not text(job["brief"]) or not os.path.isabs(job["brief"]):
                raise ValueError(identity + ": brief must be an absolute pointer")
        elif not isinstance(job["task_type"], str) or not slug.fullmatch(job["task_type"]):
            raise ValueError(identity + ": invalid task_type")
        cadence = job["cadence"]
        if not isinstance(cadence, dict):
            raise ValueError(identity + ": invalid cadence")
        if cadence.get("kind") == "daily-local" and set(cadence) == {"kind", "at", "timezone"}:
            if not isinstance(cadence["at"], str) or not re.fullmatch(r"(?:[01][0-9]|2[0-3]):[0-5][0-9]", cadence["at"]):
                raise ValueError(identity + ": invalid daily HH:MM")
            ZoneInfo(cadence["timezone"])
        elif cadence.get("kind") == "interval" and set(cadence) == {"kind", "seconds"}:
            if type(cadence["seconds"]) is not int or not 60 <= cadence["seconds"] <= 31536000:
                raise ValueError(identity + ": interval seconds must be 60..31536000")
        else:
            raise ValueError(identity + ": invalid cadence fields")
    return items

try:
    data = read(journal, {"version": 1, "cursor": 0, "jobs": {}}, 16777216)
    if not isinstance(data, dict) or set(data) != {"version", "cursor", "jobs"} or data["version"] != 1 or not isinstance(data["jobs"], dict) or type(data["cursor"]) is not int:
        raise ValueError("invalid occurrence journal")
    for identity, record in data["jobs"].items():
        if not slug.fullmatch(identity) or not isinstance(record, dict) or record.get("state") not in ("detected", "enqueued", "dispatched", "completed"):
            raise ValueError("invalid occurrence record")
        if not text(record.get("key")) or not re.fullmatch(r"sched-[0-9a-f]{24}", record.get("task_id", "")):
            raise ValueError("invalid occurrence identity")
        if not record["key"].startswith(identity + ":") or record["task_id"] != "sched-" + hashlib.sha256(record["key"].encode()).hexdigest()[:24]:
            raise ValueError("occurrence/task digest mismatch")
        if not isinstance(record.get("intent"), dict) or record["intent"].get("id") != identity:
            raise ValueError("invalid occurrence intent snapshot")
        if record.get("brief_path") != os.path.join(root, record["task_id"], "schedule-brief.md") or record.get("brief_sha256") != hashlib.sha256(record.get("brief_text", "").encode()).hexdigest():
            raise ValueError("invalid frozen brief identity")
        completed_slots = record.get("completed_slots", {})
        if not isinstance(completed_slots, dict) or any(
            not isinstance(key, str) or not key.startswith(identity + ":") or type(end) is not int
            for key, end in completed_slots.items()
        ):
            raise ValueError("invalid completed occurrence slots")
    if op == "poll":
        items = jobs()  # Validate the whole configuration before any publication.
        changed = False
        for record in data["jobs"].values():
            slots = record.get("completed_slots", {})
            active = {key: end for key, end in slots.items() if end > now}
            if active != slots:
                record["completed_slots"] = active
                changed = True
        for job in items:
            if not job["enabled"]:
                continue
            old = data["jobs"].get(job["id"])
            if old and old["state"] != "completed":
                continue
            cadence = job["cadence"]
            if cadence["kind"] == "daily-local":
                local = dt.datetime.fromtimestamp(now, ZoneInfo(cadence["timezone"]))
                if local.strftime("%H:%M") < cadence["at"]:
                    continue
                slot = local.date().isoformat()
                key = job["id"] + ":daily:" + slot
            else:
                start = (now // cadence["seconds"]) * cadence["seconds"]
                slot = str(start) + "-" + str(start + cadence["seconds"])
                key = job["id"] + ":interval:" + slot
            if old and key == old["key"]:
                continue
            if old and key in old.get("completed_slots", {}):
                continue
            # A backwards wall clock never resurrects an earlier successful slot.
            if old and old["intent"]["cadence"] == cadence:
                old_slot = old["key"].rsplit(":", 1)[1]
                if (slot <= old_slot if cadence["kind"] == "daily-local" else int(slot.split("-", 1)[0]) <= int(old_slot.split("-", 1)[0])):
                    continue
            task = "sched-" + hashlib.sha256(key.encode()).hexdigest()[:24]
            brief = freeze(job)
            completed_slots = dict(old.get("completed_slots", {})) if old else {}
            if old and old["state"] == "completed":
                end = slot_end(old["key"])
                if end > now:
                    completed_slots[old["key"]] = end
            data["jobs"][job["id"]] = {
                "key": key, "task_id": task, "brief_text": brief,
                "brief_sha256": hashlib.sha256(brief.encode()).hexdigest(),
                "brief_path": os.path.join(root, task, "schedule-brief.md"),
                "state": "detected", "detected_at": now, "intent": job,
                "completed_slots": completed_slots}
            changed = True
        pending = sorted(record["key"] for record in data["jobs"].values() if record["state"] != "completed")
        selected = []
        if pending:
            start = data["cursor"] % len(pending)
            selected = (pending[start:] + pending[:start])[:5]
            data["cursor"] = (start + 1) % len(pending)
            changed = True
        if changed:
            write(data)
        for key in selected:
            print(key)
    elif op == "validate":
        jobs()
    elif op == "advance":
        step = int(args[0])
        if not 0 <= step <= 4:
            raise ValueError("invalid cursor advance")
        data["cursor"] += step
        write(data)
    elif op in ("prepare", "observe", "attempt"):
        record = next(r for r in data["jobs"].values() if r["key"] == args[0])
        if op == "attempt":
            if "add_attempted_at" in record:
                raise ValueError("unknown custody: attempted task " + record["task_id"] + " is absent; reconcile backlog/archive before retry")
            record["add_attempted_at"] = now
            write(data)
        elif op == "prepare":
            folder = os.path.dirname(record["brief_path"])
            if os.path.lexists(folder) and (os.path.islink(folder) or not os.path.isdir(folder)):
                raise ValueError("unsafe task material directory")
            os.makedirs(folder, mode=0o700, exist_ok=True)
            persist_frozen(record["brief_path"], record["brief_text"])
            note = os.path.join(folder, "schedule-body.md")
            persist_frozen(note, body(record))
            print(json.dumps({"task": record["task_id"], "body_file": note,
                              "project": record["intent"]["project"],
                              "kind": "scout" if record["intent"]["delivery"] == "scout" else "ship",
                              "title": "Recurring " + record["intent"]["id"] + " (" + record["key"].rsplit(":", 1)[1] + ")"}))
        else:
            fields = {}
            for line in args[1].splitlines():
                match = re.fullmatch(r"  ([a-z_]+): (.*)", line)
                if match:
                    value = match[2]
                    fields[match[1]] = json.loads(value) if value.startswith('"') else value
            if fields.get("id") != record["task_id"] or fields.get("repo") != record["intent"]["project"] or not all(line in fields.get("body", "").splitlines() for line in body(record).splitlines()):
                raise ValueError("backlog item does not match frozen occurrence ownership")
            state = fields.get("state")
            target = {"queued": "enqueued", "in_flight": "dispatched", "done": "completed"}.get(state)
            if target is None:
                raise ValueError("unknown backlog task state")
            rank = {"detected": 0, "enqueued": 1, "dispatched": 2, "completed": 3}
            if rank[target] > rank[record["state"]]:
                record["state"] = target
                record[target + "_at"] = now
                write(data)
            print(state)
    else:
        raise ValueError("invalid operation")
except (ValueError, TypeError, KeyError, OSError, StopIteration, subprocess.CalledProcessError) as error:
    detail = (error.stderr or "").strip() if isinstance(error, subprocess.CalledProcessError) else ""
    print("fm-schedule-check: " + (detail or str(error)), file=sys.stderr)
    raise SystemExit(1)
PY
}

locked() {
  local op=${1:-check} keys key task tmp prepared observed backlog_state project kind title note trust_backup='' new_shim=0 rc=0 processed=0
  shift || true
  fm_lock_acquire_wait "$STATE/.schedule-check.lock" || return 1
  trap 'fm_lock_release "$STATE/.schedule-check.lock"' EXIT
  case "$op" in
    check)
      [ -d "$DATA" ] && [ ! -L "$DATA" ] || fail 'data directory is unavailable'
      case "$DATA" in /*) ;; *) fail 'data directory must be absolute' ;; esac
      keys=$(engine poll) || return 1
      [ -n "$keys" ] || return 0
      if ! command -v tasks-axi >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        fail 'enabled intake needs tasks-axi and jq'
      fi
      while IFS= read -r key; do
        [ -n "$key" ] || continue
        processed=$((processed + 1))
        prepared=$(engine prepare "$key") || return 1
        task=$(printf '%s' "$prepared" | jq -r '.task') || return 1
        project=$(printf '%s' "$prepared" | jq -r '.project') || return 1
        kind=$(printf '%s' "$prepared" | jq -r '.kind') || return 1
        title=$(printf '%s' "$prepared" | jq -r '.title') || return 1
        note=$(printf '%s' "$prepared" | jq -r '.body_file') || return 1
        if ! observed=$("$SCRIPT_DIR/fm-tasks-axi.sh" show "$task" --full 2>&1); then
          printf '%s\n' "$observed" | grep -Fx 'code: NOT_FOUND' >/dev/null || { printf '%s\n' "$observed" >&2; return 1; }
          engine attempt "$key" || return 1
          "$SCRIPT_DIR/fm-tasks-axi.sh" add "$task" "$title" --repo "$project" --kind "$kind" --body-file "$note" --queue >/dev/null || return 1
          observed=$("$SCRIPT_DIR/fm-tasks-axi.sh" show "$task" --full 2>&1) || { printf '%s\n' "$observed" >&2; return 1; }
        fi
        backlog_state=$(engine observe "$key" "$observed") || return 1
        [ "$backlog_state" = queued ] || continue
        fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
        if ! fm_wake_queued_keys_locked check | grep -Fx "queued-task:$task" >/dev/null; then
          fm_wake_append_locked check "queued-task:$task" "check: queued task $task in backlog; brief=$DATA/$task/schedule-brief.md" || rc=1
        fi
        fm_lock_release "$FM_WAKE_QUEUE_LOCK" || rc=1
        [ "$rc" -eq 0 ] || return 1
      done <<< "$keys"
      engine advance "$((processed - 1))" || return 1
      ;;
    arm)
      engine validate || return 1
      fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$DEVICE" || return 1
      fm_pr_regular_destination_on_device_or_absent "$STATE/$CHECK_ID.check-trust" "$DEVICE" || return 1
      if [ -f "$CHECK_SHIM" ]; then
        scheduler_shim_owned || fail 'scheduled-work check is not scheduler-owned'
      elif [ -e "$STATE/$CHECK_ID.check-trust" ]; then
        fail 'scheduled-work trust has no scheduler-owned shim'
      fi
      if [ -f "$STATE/$CHECK_ID.check-trust" ]; then
        trust_backup=$(umask 077; mktemp "$STATE/.schedule-trust-backup.XXXXXX") || return 1
        if ! cp -p "$STATE/$CHECK_ID.check-trust" "$trust_backup"; then
          rm -f -- "$trust_backup"
          return 1
        fi
      fi
      if [ ! -f "$CHECK_SHIM" ]; then
        tmp=$(umask 077; mktemp "$STATE/.schedule-shim.XXXXXX") || { rm -f -- "$trust_backup"; return 1; }
        if ! scheduler_shim_content > "$tmp" || ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
          rm -f -- "$tmp" "$trust_backup"
          return 1
        fi
        new_shim=1
      fi
      if ! "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID"; then
        if [ -n "$trust_backup" ]; then
          mv -f -- "$trust_backup" "$STATE/$CHECK_ID.check-trust" || return 1
        else
          rm -f -- "$STATE/$CHECK_ID.check-trust" || return 1
        fi
        [ "$new_shim" -eq 0 ] || rm -f -- "$CHECK_SHIM" || return 1
        return 1
      fi
      [ -z "$trust_backup" ] || rm -f -- "$trust_backup"
      ;;
    disarm)
      fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$DEVICE" || return 1
      fm_pr_regular_destination_on_device_or_absent "$STATE/$CHECK_ID.check-trust" "$DEVICE" || return 1
      if [ -f "$CHECK_SHIM" ]; then
        scheduler_shim_owned || fail 'scheduled-work check is not scheduler-owned'
      elif [ -e "$STATE/$CHECK_ID.check-trust" ]; then
        fail 'scheduled-work trust has no scheduler-owned shim'
      fi
      "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID"
      ;;
    *) return 2 ;;
  esac
}

if [ "${1:-}" = --locked ]; then shift; locked "$@"; exit $?; fi
[ "$#" -le 1 ] || { usage >&2; exit 2; }
BOUND=${FM_CHECK_TIMEOUT:-30}
case "$BOUND" in ''|*[!0-9]*) fail 'invalid FM_CHECK_TIMEOUT' ;; esac
[ "$BOUND" -gt 1 ] || fail 'FM_CHECK_TIMEOUT must allow a bounded operation'
BOUND=$((BOUND - 1))
[ "$BOUND" -le 20 ] || BOUND=20
OUT=$(fm_run_timed "$BOUND" bash "$0" --locked "${@:-check}" 2>&1) && RC=0 || RC=$?
if [ "$RC" -ne 0 ] && [ "${1:-check}" = check ]; then
  if [ "$RC" = 124 ]; then OUT='fm-schedule-check: operation timed out; durable intent retained'; fi
  OLD=$(cat "$ERROR_RECORD" 2>/dev/null || true)
  if [ "$OLD" != "$OUT" ]; then
    TMP=$(umask 077; mktemp "$STATE/.schedule-error.XXXXXX") || exit 1
    if ! printf '%s\n' "$OUT" > "$TMP" || ! mv -f -- "$TMP" "$ERROR_RECORD"; then
      rm -f -- "$TMP"
      exit 1
    fi
    printf '%s\n' "$OUT"
  fi
  exit "$RC"
fi
[ "$RC" -ne 0 ] || rm -f -- "$ERROR_RECORD"
[ -z "$OUT" ] || printf '%s\n' "$OUT"
exit "$RC"
