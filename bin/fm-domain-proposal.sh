#!/usr/bin/env bash
# Hand a domain mate's evidence bundle to a proposal, one main approval card, and an application receipt.
#
# Usage: FM_HOME=<main-home> fm-domain-proposal.sh request <mate> <bundle-id>
#        FM_HOME=<main-home> fm-domain-proposal.sh submit <mate> <proposal.json>
#        FM_HOME=<main-home> fm-domain-proposal.sh approve <mate> [<cycle>]
#        FM_HOME=<main-home> fm-domain-proposal.sh receipt <mate> applied
#                            --digest <sha256> [--cycle <n>] [--evidence <one line>]
#        fm-domain-proposal.sh --help
#
# Main-home only. This script never sends, schedules, enables, or applies anything:
# request and approve print the marked request text, and the firstmate sends it with
# fm-send.sh; the mate replies through fm-secondmate-report.sh --doc, and the
# firstmate runs submit on the replied document. Nothing here touches a mate's home.
# A mate never mutates main's backlog; main owns the task from the first request.
#
# State lives beside the evidence it consumes, never in a second decision store:
# data/domain-freshness/proposals/<mate>/<cycle>/{request.json,v<K>.json,v<K>.md,
# receipts.jsonl}. The captain call itself is the ordinary captain-held task
# domain-proposal-<mate>-<cycle> (bin/fm-captain-hold.sh), shown on the one
# existing decisions board; its card carries that mate's bullet list and points
# at v<K>.md, which holds the exact before/after.
#
# request: the bundle (data/domain-freshness/bundles/<id>.json, schema
#   fm-domain-evidence.v1, produced by fm-domain-freshness.sh) must list <mate>
#   among its domains. A mate with an open cycle accumulates the bundle into it;
#   otherwise a new cycle starts. It creates one main-owned task and records the
#   latest requested bundle. Remote mates are refused. The printed text asks for a READ-ONLY
#   fm-domain-proposal.v1 document and forbids applying anything.
#   If an older card is answered after a newer bundle request, approval and submission
#   refuse safely without applying anything; a fresh request starts recovery.
# submit: validates the document (schema, mate, the latest bundle_id, nonempty
#   one-line bullets, and per change: kind skill|rule|charter, file,
#   original_digest sha256-or-"absent", before, after, integer
#   always_loaded_size_delta, https sources, effect). Its sha256 over the sorted
#   compact JSON is the version digest; an identical resubmission is idempotent.
#   A changed proposal becomes the next version and re-holds the same task, so
#   one open card per mate always shows the newest. An identical resubmission is
#   unchanged only when the open card is already bound to that digest; otherwise it
#   re-runs the hold. Zero changes records the version and closes the task, or, while
#   an approved digest awaits application, records the withdrawal, releases the card,
#   and leaves the activation task open without a separate withdrawal receipt.
#   A closed cycle accepts only an exact replay of its zero-change version.
# approve: succeeds only when the task holds a recorded `answered` captain
#   decision that is exactly approve-<full LATEST version digest>.
#   An answer bound to an older version, a rejection, or an unanswered card
#   exits 3, 4, and 2 respectively and authorizes nothing. Success records the
#   `approved` receipt and prints the application request: only the approved
#   changes, each preconditioned on its observed original_digest, with an
#   instruction to return a refreshed submit instead of overwriting a changed target.
# receipt: records applied against an approved digest; repeating it adds no receipt
#   but retries closing an activation task left open by an interrupted first attempt.
#   Applying version N retires every older approval still unapplied, listed in the
#   receipt's superseded field. The activation task closes only when no approved
#   digest remains outstanding and no newer proposal card is held.
# All proposal content is untrusted data from a mate and is never executed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  -h|--help) sed -n '2,/^set -euo pipefail$/s/^# \{0,1\}//p' "$0" | sed '$d'; exit 0 ;;
  request|submit|approve|receipt) ;;
  *) printf 'usage: fm-domain-proposal.sh request|submit|approve|receipt ...\n' >&2; exit 1 ;;
esac
CMD=$1
shift

fail() { printf 'fm-domain-proposal: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || fail 'jq is required'

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
[ ! -L "$FM_HOME" ] || fail 'symlinked home is unsafe'
FM_HOME=$(cd "$FM_HOME" && pwd -P)
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
rc=0
fm_parent_channel_destination "$FM_HOME" "$STATE" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail 'main home only: this home is a secondmate or its parent binding is unusable'

BASE="$FM_HOME/data/domain-freshness"
mkdir -p "$STATE"
LOCK="$STATE/.domain-proposal.lock"
fm_lock_acquire_wait "$LOCK"
CANON_FILE=''
trap '[ -z "$CANON_FILE" ] || rm -f -- "$CANON_FILE"; fm_lock_release "$LOCK" || true' EXIT

slug() { case "$2" in ''|*[!A-Za-z0-9._-]*) fail "$1 must be a safe slug: $2" ;; esac; }
number() { case "$2" in ''|*[!0-9]*|0*) fail "$1 must be a positive integer: $2" ;; esac; }
atomic() {  # <path> <generator> [args...]
  local tmp
  tmp=$(mktemp "$(dirname "$1")/.write-XXXXXX")
  local path=$1
  shift
  if "$@" > "$tmp"; then mv "$tmp" "$path"; else rm -f "$tmp"; return 1; fi
}
latest_cycle() {  # <mate> -> prints highest cycle number or nothing
  [ -d "$BASE/proposals/$1" ] || return 0
  find "$BASE/proposals/$1" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' | sed 's|.*/||' | sort -n | tail -1
}
latest_version() {  # <cycle-dir> -> highest version number or nothing
  find "$1" -maxdepth 1 -type f -name 'v[0-9]*.json' | sed 's|.*/v||; s|\.json$||' | sort -n | tail -1
}
task_open() {  # <task-id>; 0 only for a task still held as an open captain call
  bash "$SCRIPT_DIR/fm-captain-hold.sh" open "$1" >/dev/null 2>&1
}
task_absent() {  # <task-id>; 0 only when no such task exists in this home's backlog
  local code=0
  bash "$SCRIPT_DIR/fm-captain-hold.sh" open "$1" --distinguish-absent >/dev/null 2>&1 || code=$?
  [ "$code" -eq 3 ]
}
task_state() {
  local show
  show=$(bash "$SCRIPT_DIR/fm-tasks-axi.sh" show "$1" --full 2>/dev/null) || return 2
  printf '%s\n' "$show" | sed -n 's/^  state: //p' | head -1
}
task_answer() {  # <task-id>; prints mode TAB first decision line, or nothing
  local show body
  show=$(bash "$SCRIPT_DIR/fm-tasks-axi.sh" show "$1" --full 2>/dev/null) || return 0
  body=$(printf '%s\n' "$show" | sed -n 's/^  body: //p' | head -1 | jq -r '.' 2>/dev/null) || return 0
  printf '%s\n' "$body" | awk '
    /^Resolution mode: / && !mode { mode = substr($0, 18) }
    /^Captain decision:$/ && !seen { seen = 1; getline; print mode "\t" $0; exit }'
}
card_digest() {  # <task-id>; the version digest the open card was held for, or nothing
  local show
  show=$(bash "$SCRIPT_DIR/fm-tasks-axi.sh" show "$1" --full 2>/dev/null) || return 0
  printf '%s\n' "$show" | sed -n 's/^  hold_reason: .*digest \([a-f0-9]\{64\}\).*/\1/p' | head -1
}
withdraw() {  # <task> <dir> <version> <digest>: close the task unless an approved digest awaits application
  local task=$1 dir=$2 version=$3 digest=$4
  if has_outstanding_approval "$dir/receipts.jsonl"; then
    if task_open "$task"; then
      bash "$SCRIPT_DIR/fm-tasks-axi.sh" unhold "$task" >/dev/null || fail "could not release the withdrawn card on $task"
    fi
    printf 'withdrawn: %s v%s recorded, activation of an approved version stays open\n' "$task" "$version"
  else
    bash "$SCRIPT_DIR/fm-tasks-axi.sh" "done" "$task" --note "Domain proposal withdrawn at v$version digest $digest; no changes requested" >/dev/null \
      || fail "could not close withdrawn proposal task $task"
    printf 'no-change: %s v%s recorded, no card\n' "$task" "$version"
  fi
}
has_outstanding_approval() {
  local pending
  [ -f "$1" ] || return 1
  pending=$(jq -rs '([.[] | select(.state == "approved") | .digest] - [.[] | select(.state == "applied") | .digest, (.superseded // [])[]] | length) > 0' "$1") \
    || fail "cannot read application receipts: $1"
  [ "$pending" = true ]
}

case "$CMD" in
request)
  [ "$#" -eq 2 ] || fail 'usage: request <mate> <bundle-id>'
  MATE=$1 BUNDLE=$2
  slug mate "$MATE"
  slug bundle-id "$BUNDLE"
  BFILE="$BASE/bundles/$BUNDLE.json"
  [ -f "$BFILE" ] && [ ! -L "$BFILE" ] || fail "bundle not found: $BFILE"
  jq -e --arg mate "$MATE" '.schema == "fm-domain-evidence.v1" and (.domains | map(.id) | index($mate) != null)' \
    "$BFILE" >/dev/null || fail "bundle is not fm-domain-evidence.v1 listing mate $MATE"
  secondmate_registry_line_for_id "$FM_HOME/data/secondmates.md" "$MATE" \
    || fail "current mate route is unavailable for $MATE"
  [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || fail "remote domain handoff is not yet supported for $MATE"
  SCOPE=$SECONDMATE_REGISTRY_SCOPE
  CYCLE=$(latest_cycle "$MATE")
  if [ -n "$CYCLE" ]; then
    DIR="$BASE/proposals/$MATE/$CYCLE"
    TASK="domain-proposal-$MATE-$CYCLE"
    if task_absent "$TASK"; then
      [ ! -f "$DIR/request.json" ] || fail "request task $TASK is missing"
    else
      TASK_STATE=$(task_state "$TASK") || fail "cannot read task $TASK"
      has_outstanding_approval "$DIR/receipts.jsonl" && fail "activation is pending for $TASK"
      if [ "$TASK_STATE" = "done" ]; then
        VERSION=$(latest_version "$DIR")
        if [ -n "$VERSION" ]; then
          DIGEST=$(jq -r '.digest' "$DIR/v$VERSION.json")
          ANSWER=$(task_answer "$TASK")
          if [ "$ANSWER" = "answered"$'\t'"approve-$DIGEST" ] \
            && [ "$(jq -r '.proposal.bundle_id' "$DIR/v$VERSION.json")" = "$(jq -r '.latest_bundle_id' "$DIR/request.json")" ] \
            && { [ ! -f "$DIR/receipts.jsonl" ] \
              || ! jq -es --arg d "$DIGEST" 'any(.[]; .state == "applied" and .digest == $d)' "$DIR/receipts.jsonl" >/dev/null; }; then
            fail "activation is pending for $TASK"
          fi
        fi
        CYCLE=$((CYCLE + 1))
      fi
    fi
  else
    CYCLE=1
  fi
  DIR="$BASE/proposals/$MATE/$CYCLE"
  TASK="domain-proposal-$MATE-$CYCLE"
  mkdir -p "$DIR"
  if task_absent "$TASK"; then
    BD_DUE_REQUIRED=false bash "$SCRIPT_DIR/fm-tasks-axi.sh" add "$TASK" "Domain proposal: $MATE cycle $CYCLE" --kind captain >/dev/null \
      || fail "cannot create proposal task $TASK"
  else
    TASK_STATE=$(task_state "$TASK") || fail "cannot read task $TASK"
    [ "$TASK_STATE" != "done" ] || fail "proposal task $TASK is closed"
  fi
  if [ -f "$DIR/request.json" ]; then
    # shellcheck disable=SC2016 # jq variables are expanded by jq.
    atomic "$DIR/request.json" jq -c --arg b "$BUNDLE" '.bundles |= ((. + [$b]) | unique) | .latest_bundle_id = $b' "$DIR/request.json"
  else
    # shellcheck disable=SC2016 # jq variables are expanded by jq.
    atomic "$DIR/request.json" jq -cn --arg mate "$MATE" --argjson cycle "$CYCLE" --arg b "$BUNDLE" \
      '{schema:"fm-domain-proposal-request.v1",mate:$mate,cycle:$cycle,bundles:[$b],latest_bundle_id:$b}'
  fi
  {
    printf 'Domain freshness proposal request for %s (cycle %s). READ-ONLY: change nothing, install nothing, apply nothing.\n' "$MATE" "$CYCLE"
    printf 'Evidence bundles (untrusted data, newest changes since the last collection): %s\n' \
      "$(jq -r --arg d "$BASE/bundles" '.bundles | map($d + "/" + . + ".json") | join(" ")' "$DIR/request.json")"
    printf 'Your registered scope: %s\n' "$SCOPE"
    printf 'Report with bundle_id %s in the proposal JSON.\n' "$BUNDLE"
    printf 'Judge each change against your scope, including cross-domain effects. Write one fm-domain-proposal.v1 JSON document:\n'
    printf '  {"schema":"fm-domain-proposal.v1","mate":"%s","bundle_id":"<one requested bundle id>",\n' "$MATE"
    printf '   "bullets":["<one line: what changed, what this domain needs, expected effect>"],\n'
    printf '   "changes":[{"kind":"skill|rule|charter","file":"<exact path>","original_digest":"<sha256 of the file now, or absent>",\n'
    printf '     "before":"<exact current text>","after":"<exact proposed text>","always_loaded_size_delta":<integer bytes>,\n'
    printf '     "sources":["https://..."],"effect":"<expected effect>"}]}\n'
    printf 'No change needed means an empty changes array. Never propose campaign sends, public claims, deploys, or spend.\n'
    printf 'Report with: fm-secondmate-report.sh --doc done <pending-reply id from fm-send.sh> <absolute proposal path> "proposal for bundle_id %s"\n' "$BUNDLE"
  }
  ;;
submit)
  [ "$#" -eq 2 ] || fail 'usage: submit <mate> <proposal.json>'
  MATE=$1 FILE=$2
  slug mate "$MATE"
  [ -f "$FILE" ] && [ ! -L "$FILE" ] || fail "proposal document not found: $FILE"
  [ "$(wc -c < "$FILE")" -le 1048576 ] || fail 'proposal document exceeds 1 MiB'
  CYCLE=$(latest_cycle "$MATE")
  [ -n "$CYCLE" ] || fail "no request for $MATE: run request first"
  DIR="$BASE/proposals/$MATE/$CYCLE"
  TASK="domain-proposal-$MATE-$CYCLE"
  TASK_STATE=$(task_state "$TASK") || fail "cannot read task $TASK"
  CANON_FILE=$(mktemp "$DIR/.proposal-XXXXXX")
  jq -scS 'if length == 1 then .[0] else error("one JSON value required") end' "$FILE" > "$CANON_FILE" \
    || fail 'proposal document must contain exactly one JSON value'
  BUNDLE=$(jq -r '.latest_bundle_id' "$DIR/request.json")
  [ "$(jq -r '.bundle_id // empty' "$CANON_FILE")" = "$BUNDLE" ] \
    || fail "bundle_id is not the latest requested bundle for $MATE"
  jq -e --arg mate "$MATE" --arg bundle "$BUNDLE" '
    def line: type == "string" and length > 0 and (test("[\r\n]") | not);
    def https: type == "string" and test("^https://[^ ]+$")
      and (explode | all(. >= 32 and (. < 127 or . > 159) and . != 8232 and . != 8233));
    .schema == "fm-domain-proposal.v1" and .mate == $mate
    and .bundle_id == $bundle
    and (.bullets | type == "array" and length > 0 and all(line))
    and (.changes | type == "array" and length <= 50 and all(
      (.kind | IN("skill","rule","charter"))
      and (.file | line) and (.original_digest | type == "string" and test("^([a-f0-9]{64}|absent)$"))
      and (.before | type == "string") and (.after | type == "string") and .before != .after
      and (.always_loaded_size_delta | type == "number" and . == floor)
      and (.sources | type == "array" and length > 0 and all(https)) and (.effect | line)))
    and ((.changes | map(.file) | length) == (.changes | map(.file) | unique | length))' \
    "$CANON_FILE" >/dev/null || fail 'proposal document does not satisfy fm-domain-proposal.v1 for this cycle'
  CANON=$(cat "$CANON_FILE")
  DIGEST=$(printf '%s' "$CANON" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
  VERSION=$(latest_version "$DIR")
  if [ "$TASK_STATE" = "done" ]; then
    if [ -n "$VERSION" ] && [ "$(jq -r '.digest' "$DIR/v$VERSION.json")" = "$DIGEST" ] \
      && [ "$(jq '.proposal.changes | length' "$DIR/v$VERSION.json")" -eq 0 ]; then
      printf 'no-change: %s v%s recorded, no card\n' "$TASK" "$VERSION"
      exit 0
    fi
    fail "cycle $CYCLE of $MATE is closed: run request for a new cycle"
  fi
  APPROVED=0
  if [ -f "$DIR/receipts.jsonl" ] && jq -es 'any(.[]; .state == "approved")' "$DIR/receipts.jsonl" >/dev/null; then APPROVED=1; fi
  APPROVED_THIS=0
  if [ -f "$DIR/receipts.jsonl" ] && jq -es --arg d "$DIGEST" 'any(.[]; .state == "approved" and .digest == $d)' "$DIR/receipts.jsonl" >/dev/null; then APPROVED_THIS=1; fi
  if [ -n "$VERSION" ]; then
    if [ "$(jq -r '.digest' "$DIR/v$VERSION.json")" = "$DIGEST" ]; then
      if [ "$(jq '.proposal.changes | length' "$DIR/v$VERSION.json")" -eq 0 ]; then
        withdraw "$TASK" "$DIR" "$VERSION" "$DIGEST"
        exit 0
      fi
      # Unchanged only when the open card is already bound to this digest or it was approved.
      if { task_open "$TASK" && [ "$(card_digest "$TASK")" = "$DIGEST" ]; } || [ "$APPROVED_THIS" -eq 1 ]; then
        printf 'unchanged: %s v%s digest %s\n' "$TASK" "$VERSION" "$DIGEST"
        exit 0
      fi
      if [ "$(jq '.proposal.changes | length' "$DIR/v$VERSION.json")" -gt 0 ]; then
        VERSION=$((VERSION - 1))
      fi
    else
      for prior in "$DIR"/v[0-9]*.json; do
        [ -f "$prior" ] || continue
        [ "$(jq -r '.digest' "$prior")" != "$DIGEST" ] \
          || fail 'proposal digest matches an earlier version; change it or start a new cycle'
      done
      task_open "$TASK" || [ "$APPROVED" -eq 1 ] || fail "cycle $CYCLE of $MATE is no longer awaiting a proposal"
    fi
    VERSION=$((VERSION + 1))
  else
    VERSION=1
  fi
  # shellcheck disable=SC2016 # jq variables are expanded by jq.
  atomic "$DIR/v$VERSION.json" jq -n -c --argjson version "$VERSION" --arg digest "$DIGEST" --slurpfile proposal "$CANON_FILE" \
    '{version:$version,digest:$digest,proposal:$proposal[0]}'
  if [ "$(printf '%s' "$CANON" | jq '.changes | length')" -eq 0 ]; then
    withdraw "$TASK" "$DIR" "$VERSION" "$DIGEST"
    exit 0
  fi
  # shellcheck disable=SC2016 # jq variables are expanded by jq.
  atomic "$DIR/v$VERSION.md" jq -r --arg mate "$MATE" --argjson v "$VERSION" --arg digest "$DIGEST" '
    def nl: gsub("\r\n?"; "\n");
    def fence($s): ([($s | scan("(?m)^ {0,3}~{3,}") | sub("^ {0,3}"; "")) | length] | max // 3) as $n | "~" * ($n + 1);
    "# Domain proposal: \($mate) v\($v)\n\nVersion digest: \($digest)\n\n## Bullets\n"
    + (.proposal.bullets | map("- " + .) | join("\n"))
    + "\n\n## Exact changes\n"
    + (.proposal.changes | map(
        "\n### \(.file) (\(.kind))\n\nObserved original digest: \(.original_digest)\nAlways-loaded size delta: \(.always_loaded_size_delta)\nEffect: \(.effect)\nSources: \(.sources | join(" "))\n\nBefore:\n\n\(fence(.before | nl))\n\(.before | nl)\n\(fence(.before | nl))\n\nAfter:\n\n\(fence(.after | nl))\n\(.after | nl)\n\(fence(.after | nl))\n") | join(""))' \
    "$DIR/v$VERSION.json"
  OPTS=$(mktemp "$STATE/.domain-proposal-options.XXXXXX")
  jq -n --arg digest "$DIGEST" --arg report "$DIR/v$VERSION.md" --slurpfile proposal "$DIR/v$VERSION.json" --arg mate "$MATE" --argjson v "$VERSION" '
    {about: ("Domain proposal for " + $mate + " v" + ($v|tostring) + ": " + ($proposal[0].proposal.bullets | join("; "))),
     decide: ("Apply exactly the before/after changes in the report (version digest " + $digest + ")?"),
     options: [{value: ("approve-" + $digest), label: "Approve exactly this version", hint: "A newer version needs its own approval."},
               {value: "reject", label: "Reject; keep everything inactive"}],
     recommended: ("approve-" + $digest), report: $report}' > "$OPTS"
  rc=0
  bash "$SCRIPT_DIR/fm-captain-hold.sh" hold "$TASK" --title "Domain proposal: $MATE cycle $CYCLE" \
    --reason "Domain proposal $MATE cycle $CYCLE v$VERSION digest $DIGEST; approval applies only that digest" \
    --options-file "$OPTS" >/dev/null || rc=$?
  rm -f "$OPTS"
  [ "$rc" -eq 0 ] || fail "could not hold $TASK for the captain (exit $rc); version v$VERSION is recorded, rerun submit"
  printf 'held: %s v%s digest %s report %s\n' "$TASK" "$VERSION" "$DIGEST" "$DIR/v$VERSION.md"
  ;;
approve)
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || fail 'usage: approve <mate> [<cycle>]'
  MATE=$1 CYCLE=${2:-$(latest_cycle "$1")}
  slug mate "$MATE"
  number cycle "${CYCLE:-}"
  DIR="$BASE/proposals/$MATE/$CYCLE"
  VERSION=$(latest_version "$DIR")
  [ -n "$VERSION" ] || fail "no submitted version for $MATE cycle $CYCLE"
  TASK="domain-proposal-$MATE-$CYCLE"
  DIGEST=$(jq -r '.digest' "$DIR/v$VERSION.json")
  [ "$(jq -r '.proposal.bundle_id' "$DIR/v$VERSION.json")" = "$(jq -r '.latest_bundle_id' "$DIR/request.json")" ] \
    || fail "latest proposal does not cover the latest requested bundle for $MATE"
  ANSWER=$(task_answer "$TASK")
  if [ -z "$ANSWER" ]; then
    printf 'pending: %s v%s has no recorded captain answer\n' "$TASK" "$VERSION" >&2
    exit 2
  fi
  MODE=${ANSWER%%$'\t'*}
  TEXT=${ANSWER#*$'\t'}
  case "$MODE" in answered) ;; *) printf 'not-approved: %s resolution mode is %s\n' "$TASK" "$MODE" >&2; exit 4 ;; esac
  case "$TEXT" in
    reject) printf 'rejected: %s stays inactive\n' "$TASK" >&2; exit 4 ;;
    "approve-$DIGEST") ;;
    approve-*) printf 'stale: answer %s does not match latest version v%s digest %s\n' "$TEXT" "$VERSION" "$DIGEST" >&2; exit 3 ;;
    *) printf 'not-approved: %s answer is not an approval value\n' "$TASK" >&2; exit 4 ;;
  esac
  if [ -f "$DIR/receipts.jsonl" ] && jq -es --arg d "$DIGEST" 'any(.[]; .state == "applied" and .digest == $d)' "$DIR/receipts.jsonl" >/dev/null; then
    fail "digest $DIGEST is already applied"
  fi
  TASK_STATE=$(task_state "$TASK") || fail "cannot read task $TASK"
  if [ "$TASK_STATE" = "done" ]; then
    bash "$SCRIPT_DIR/fm-tasks-axi.sh" reopen "$TASK" >/dev/null || fail "cannot reopen activation task $TASK"
  fi
  touch "$DIR/receipts.jsonl"
  if ! grep -q "\"state\":\"approved\",\"digest\":\"$DIGEST\"" "$DIR/receipts.jsonl"; then
    jq -cn --arg digest "$DIGEST" --arg bundle "$(jq -r '.proposal.bundle_id' "$DIR/v$VERSION.json")" --argjson v "$VERSION" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{state:"approved",digest:$digest,bundle_id:$bundle,version:$v,at:$at}' >> "$DIR/receipts.jsonl"
  fi
  {
    printf 'Approved domain change for %s (cycle %s, version %s, digest %s). Apply ONLY these changes, nothing else.\n' "$MATE" "$CYCLE" "$VERSION" "$DIGEST"
    printf 'Precondition: for each change, apply only if the target file digest still equals original_digest (absent means the file must not exist).\n'
    printf 'If a target changed, write nothing: submit a refreshed fm-domain-proposal.v1 with the new before/after instead.\n'
    printf 'Shared tracked changes go through the normal PR and validation path; private charter or knowledge changes use their existing owners.\n'
    printf 'Report application with bundle_id %s and digest %s using the pending-reply id from fm-send.sh; a green PR is not applied.\n' \
      "$(jq -r '.proposal.bundle_id' "$DIR/v$VERSION.json")" "$DIGEST"
    jq -r '.proposal.changes[] | "- \(.kind) \(.file) original_digest=\(.original_digest)\n  after:\n\(.after | split("\n") | map("    " + .) | join("\n"))"' "$DIR/v$VERSION.json"
  }
  ;;
receipt)
  [ "$#" -ge 2 ] || fail 'usage: receipt <mate> applied --digest <sha256> [--cycle <n>] [--evidence <text>]'
  MATE=$1 STATE_NAME=$2
  shift 2
  slug mate "$MATE"
  [ "$STATE_NAME" = applied ] || fail 'state must be applied'
  CYCLE=$(latest_cycle "$MATE")
  DIGEST=''
  EVIDENCE=''
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || fail "missing value for $1"
    case "$1" in
      --cycle) CYCLE=$2 ;;
      --digest) DIGEST=$2 ;;
      --evidence) EVIDENCE=$2 ;;
      *) fail "unknown option $1" ;;
    esac
    shift 2
  done
  number cycle "${CYCLE:-}"
  case "$EVIDENCE" in *$'\n'*) fail 'evidence must be one line' ;; esac
  [ -n "$DIGEST" ] || fail 'receipt requires --digest'
  DIR="$BASE/proposals/$MATE/$CYCLE"
  [ -f "$DIR/receipts.jsonl" ] || fail "no approved receipt for $MATE cycle $CYCLE"
  jq -es --arg d "$DIGEST" 'any(.[]; .state == "approved" and .digest == $d)' "$DIR/receipts.jsonl" >/dev/null \
    || fail "digest $DIGEST was never approved"
  BUNDLE=$(jq -rs --arg d "$DIGEST" 'map(select(.state == "approved" and .digest == $d)) | last | .bundle_id' "$DIR/receipts.jsonl")
  VERSION=$(latest_version "$DIR")
  LATEST_DIGEST=$(jq -r '.digest' "$DIR/v$VERSION.json")
  CLOSES=0
  if [ "$DIGEST" = "$LATEST_DIGEST" ] || [ "$(jq '.proposal.changes | length' "$DIR/v$VERSION.json")" -eq 0 ]; then CLOSES=1; fi
  if jq -es --arg d "$DIGEST" 'any(.[]; .state == "applied" and .digest == $d)' "$DIR/receipts.jsonl" >/dev/null; then
    if [ "$CLOSES" -eq 1 ] && ! has_outstanding_approval "$DIR/receipts.jsonl"; then
      bash "$SCRIPT_DIR/fm-tasks-axi.sh" "done" "domain-proposal-$MATE-$CYCLE" --note "Applied digest $DIGEST bundle_id $BUNDLE" >/dev/null \
        || fail "could not close activation task for $MATE cycle $CYCLE"
    fi
    printf 'recorded: %s %s already has an applied receipt\n' "$MATE" "$DIGEST"
    exit 0
  fi
  [ -n "$EVIDENCE" ] || fail 'application evidence is required'
  # Applying version N supersedes every older approval still unapplied; the receipt records them.
  # shellcheck disable=SC2016 # jq variables are expanded by jq.
  SUPERSEDED=$(jq -cs --arg d "$DIGEST" '
    (map(select(.state == "approved" and .digest == $d)) | last | .version) as $n
    | ([.[] | select(.state == "approved" and .version < $n) | .digest] - [.[] | select(.state == "applied") | .digest]) | unique' "$DIR/receipts.jsonl")
  jq -cn --arg digest "$DIGEST" --arg bundle "$BUNDLE" --arg evidence "$EVIDENCE" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson superseded "$SUPERSEDED" \
    '{state:"applied",digest:$digest,bundle_id:$bundle,evidence:$evidence,superseded:$superseded,at:$at}' >> "$DIR/receipts.jsonl"
  if [ "$CLOSES" -eq 1 ] && ! has_outstanding_approval "$DIR/receipts.jsonl"; then
    bash "$SCRIPT_DIR/fm-tasks-axi.sh" "done" "domain-proposal-$MATE-$CYCLE" --note "Applied digest $DIGEST bundle_id $BUNDLE: $EVIDENCE" >/dev/null \
      || fail "application receipt recorded but could not close activation task for $MATE cycle $CYCLE"
  fi
  printf 'receipt: %s cycle %s %s digest %s\n' "$MATE" "$CYCLE" "$STATE_NAME" "$DIGEST"
  ;;
esac
