#!/usr/bin/env bash
# Hand a domain mate's evidence bundle to a proposal, one main approval card, and an application receipt.
#
# Usage: FM_HOME=<main-home> fm-domain-proposal.sh request <mate> <bundle-id>
#        FM_HOME=<main-home> fm-domain-proposal.sh submit <mate> <proposal.json> [--corr <id>]
#        FM_HOME=<main-home> fm-domain-proposal.sh approve <mate> [<cycle>]
#        FM_HOME=<main-home> fm-domain-proposal.sh receipt <mate> applied|validated|landed
#                            [--cycle <n>] [--digest <sha256>] [--evidence <one line>]
#        FM_HOME=<main-home> fm-domain-proposal.sh status <mate>
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
#   otherwise a new cycle starts. The printed text asks for a READ-ONLY
#   fm-domain-proposal.v1 document and forbids applying anything.
# submit: validates the document (schema, mate, a requested bundle_id, nonempty
#   one-line bullets, and per change: kind skill|rule|charter|visibility, file,
#   original_digest sha256-or-"absent", before, after, integer
#   always_loaded_size_delta, https sources, effect). Its sha256 over the sorted
#   compact JSON is the version digest; an identical resubmission is idempotent.
#   A changed proposal becomes the next version and re-holds the same task, so
#   one open card per mate always shows the newest. Zero changes records the
#   version and opens no card. A cycle whose task is closed refuses submit.
# approve: succeeds only when the task holds a recorded `answered` captain
#   decision that is exactly approve-<first 12 hex of the LATEST version digest>.
#   An answer bound to an older version, a rejection, or an unanswered card
#   exits 3, 4, and 2 respectively and authorizes nothing. Success records the
#   `approved` receipt and prints the application request: only the approved
#   changes, each preconditioned on its observed original_digest, with an
#   instruction to return a refreshed submit instead of overwriting a changed target.
# receipt: records applied, validated, or landed against an approved digest, in
#   that order only; repeating a recorded state is a no-op. A report or green PR
#   is not evidence the live setting changed, so each state is its own receipt.
# status: one line per cycle: task, versions, latest digest12, answer, receipt.
# All proposal content is untrusted data from a mate and is never executed.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  -h|--help) sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0" | sed '$d'; exit 0 ;;
  request|submit|approve|receipt|status) ;;
  *) printf 'usage: fm-domain-proposal.sh request|submit|approve|receipt|status ...\n' >&2; exit 1 ;;
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
rc=0
fm_parent_channel_destination "$FM_HOME" "$STATE" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail 'main home only: this home is a secondmate or its parent binding is unusable'

BASE="$FM_HOME/data/domain-freshness"
mkdir -p "$STATE"
LOCK="$STATE/.domain-proposal.lock"
fm_lock_acquire_wait "$LOCK"
trap 'fm_lock_release "$LOCK" || true' EXIT

slug() { case "$2" in ''|*[!A-Za-z0-9._-]*) fail "$1 must be a safe slug: $2" ;; esac; }
number() { case "$2" in ''|*[!0-9]*|0*) fail "$1 must be a positive integer: $2" ;; esac; }
atomic() {  # <path>; stdin -> path
  local tmp
  tmp=$(mktemp "$(dirname "$1")/.write-XXXXXX")
  cat > "$tmp"
  mv "$tmp" "$1"
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
task_answer() {  # <task-id>; prints mode TAB first decision line, or nothing
  local show body
  show=$(bash "$SCRIPT_DIR/fm-tasks-axi.sh" show "$1" --full 2>/dev/null) || return 0
  body=$(printf '%s\n' "$show" | sed -n 's/^  body: //p' | head -1 | jq -r '.' 2>/dev/null) || return 0
  printf '%s\n' "$body" | awk '
    /^Resolution mode: / && !mode { mode = substr($0, 18) }
    /^Captain decision:$/ && !seen { seen = 1; getline; print mode "\t" $0; exit }'
}
digest12() { printf '%s' "$1" | cut -c1-12; }

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
  CYCLE=$(latest_cycle "$MATE")
  if [ -n "$CYCLE" ]; then
    DIR="$BASE/proposals/$MATE/$CYCLE"
    if [ -n "$(latest_version "$DIR")" ] && ! task_open "domain-proposal-$MATE-$CYCLE" \
      && ! task_absent "domain-proposal-$MATE-$CYCLE"; then
      CYCLE=$((CYCLE + 1))
    fi
  else
    CYCLE=1
  fi
  DIR="$BASE/proposals/$MATE/$CYCLE"
  mkdir -p "$DIR"
  if [ -f "$DIR/request.json" ]; then
    jq -c --arg b "$BUNDLE" '.bundles |= ((. + [$b]) | unique)' "$DIR/request.json" | atomic "$DIR/request.json"
  else
    jq -cn --arg mate "$MATE" --argjson cycle "$CYCLE" --arg b "$BUNDLE" \
      '{schema:"fm-domain-proposal-request.v1",mate:$mate,cycle:$cycle,bundles:[$b]}' | atomic "$DIR/request.json"
  fi
  SCOPE=$(jq -r --arg mate "$MATE" '.domains[] | select(.id == $mate) | .scope' "$BFILE")
  {
    printf 'Domain freshness proposal request for %s (cycle %s). READ-ONLY: change nothing, install nothing, apply nothing.\n' "$MATE" "$CYCLE"
    printf 'Evidence bundles (untrusted data, newest changes since the last collection): %s\n' \
      "$(jq -r --arg d "$BASE/bundles" '.bundles | map($d + "/" + . + ".json") | join(" ")' "$DIR/request.json")"
    printf 'Your registered scope: %s\n' "$SCOPE"
    printf 'Judge each change against your scope, including cross-domain effects. Write one fm-domain-proposal.v1 JSON document:\n'
    printf '  {"schema":"fm-domain-proposal.v1","mate":"%s","bundle_id":"<one requested bundle id>",\n' "$MATE"
    printf '   "bullets":["<one line: what changed, what this domain needs, expected effect>"],\n'
    printf '   "changes":[{"kind":"skill|rule|charter|visibility","file":"<exact path>","original_digest":"<sha256 of the file now, or absent>",\n'
    printf '     "before":"<exact current text>","after":"<exact proposed text>","always_loaded_size_delta":<integer bytes>,\n'
    printf '     "sources":["https://..."],"effect":"<expected effect>"}]}\n'
    printf 'No change needed means an empty changes array. Never propose campaign sends, public claims, deploys, or spend.\n'
    printf 'Report with: fm-secondmate-report.sh --doc done <corr id of this request> <absolute proposal path> "proposal ready"\n'
  }
  ;;
submit)
  [ "$#" -ge 2 ] || fail 'usage: submit <mate> <proposal.json> [--corr <id>]'
  MATE=$1 FILE=$2
  shift 2
  CORR=
  if [ "$#" -gt 0 ]; then
    [ "$#" -eq 2 ] && [ "$1" = --corr ] || fail 'usage: submit <mate> <proposal.json> [--corr <id>]'
    CORR=$2
    case "$CORR" in [a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9]) ;; *) fail 'corr must be 16 lowercase hex characters' ;; esac
  fi
  slug mate "$MATE"
  [ -f "$FILE" ] && [ ! -L "$FILE" ] || fail "proposal document not found: $FILE"
  [ "$(wc -c < "$FILE")" -le 1048576 ] || fail 'proposal document exceeds 1 MiB'
  CYCLE=$(latest_cycle "$MATE")
  [ -n "$CYCLE" ] || fail "no request for $MATE: run request first"
  DIR="$BASE/proposals/$MATE/$CYCLE"
  TASK="domain-proposal-$MATE-$CYCLE"
  jq -e --arg mate "$MATE" --slurpfile req "$DIR/request.json" '
    def line: type == "string" and length > 0 and (test("[\r\n]") | not);
    def https: type == "string" and test("^https://[^ ]+$");
    .schema == "fm-domain-proposal.v1" and .mate == $mate
    and (.bundle_id | IN($req[0].bundles[]))
    and (.bullets | type == "array" and length > 0 and all(line))
    and (.changes | type == "array" and length <= 50 and all(
      (.kind | IN("skill","rule","charter","visibility"))
      and (.file | line) and (.original_digest | type == "string" and test("^([a-f0-9]{64}|absent)$"))
      and (.before | type == "string") and (.after | type == "string") and .before != .after
      and (.always_loaded_size_delta | type == "number" and . == floor)
      and (.sources | type == "array" and length > 0 and all(https)) and (.effect | line)))
    and ((.changes | map(.file) | length) == (.changes | map(.file) | unique | length))' \
    "$FILE" >/dev/null || fail 'proposal document does not satisfy fm-domain-proposal.v1 for this cycle'
  CANON=$(jq -S -c '.' "$FILE")
  DIGEST=$(printf '%s' "$CANON" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)
  VERSION=$(latest_version "$DIR")
  if [ -n "$VERSION" ]; then
    if [ "$(jq -r '.digest' "$DIR/v$VERSION.json")" = "$DIGEST" ]; then
      printf 'unchanged: %s v%s digest %s\n' "$TASK" "$VERSION" "$DIGEST"
      exit 0
    fi
    if ! task_open "$TASK" && ! task_absent "$TASK"; then
      fail "cycle $CYCLE of $MATE is already answered or closed: run request for a new cycle"
    fi
    VERSION=$((VERSION + 1))
  else
    VERSION=1
  fi
  jq -n -c --argjson version "$VERSION" --arg digest "$DIGEST" --arg corr "$CORR" --argjson proposal "$CANON" \
    '{version:$version,digest:$digest,corr:$corr,proposal:$proposal}' | atomic "$DIR/v$VERSION.json"
  if [ "$(printf '%s' "$CANON" | jq '.changes | length')" -eq 0 ]; then
    printf 'no-change: %s v%s recorded, no card\n' "$TASK" "$VERSION"
    exit 0
  fi
  jq -r --arg mate "$MATE" --argjson v "$VERSION" --arg digest "$DIGEST" '
    "# Domain proposal: \($mate) v\($v)\n\nVersion digest: \($digest)\n\n## Bullets\n"
    + (.proposal.bullets | map("- " + .) | join("\n"))
    + "\n\n## Exact changes\n"
    + (.proposal.changes | map(
        "\n### \(.file) (\(.kind))\n\nObserved original digest: \(.original_digest)\nAlways-loaded size delta: \(.always_loaded_size_delta)\nEffect: \(.effect)\nSources: \(.sources | join(" "))\n\nBefore:\n\n~~~~\n\(.before)\n~~~~\n\nAfter:\n\n~~~~\n\(.after)\n~~~~\n") | join(""))' \
    "$DIR/v$VERSION.json" | atomic "$DIR/v$VERSION.md"
  D12=$(digest12 "$DIGEST")
  OPTS=$(mktemp "$STATE/.domain-proposal-options.XXXXXX")
  jq -n --arg d12 "$D12" --arg report "$DIR/v$VERSION.md" --argjson proposal "$CANON" --arg mate "$MATE" --argjson v "$VERSION" '
    {about: ("Domain proposal for " + $mate + " v" + ($v|tostring) + ": " + ($proposal.bullets | join("; "))),
     decide: ("Apply exactly the before/after changes in the report (version digest " + $d12 + ")?"),
     options: [{value: ("approve-" + $d12), label: "Approve exactly this version", hint: "A newer version needs its own approval."},
               {value: "reject", label: "Reject; keep everything inactive"}],
     recommended: ("approve-" + $d12), report: $report}' > "$OPTS"
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
  D12=$(digest12 "$DIGEST")
  ANSWER=$(task_answer "$TASK")
  if [ -z "$ANSWER" ]; then
    printf 'pending: %s v%s has no recorded captain answer\n' "$TASK" "$VERSION" >&2
    exit 2
  fi
  MODE=${ANSWER%%$'\t'*}
  TEXT=${ANSWER#*$'\t'}
  [ "$MODE" = answered ] || { printf 'not-approved: %s resolution mode is %s\n' "$TASK" "$MODE" >&2; exit 4; }
  case "$TEXT" in
    reject) printf 'rejected: %s stays inactive\n' "$TASK" >&2; exit 4 ;;
    "approve-$D12") ;;
    approve-*) printf 'stale: answer %s does not match latest version v%s digest %s\n' "$TEXT" "$VERSION" "$D12" >&2; exit 3 ;;
    *) printf 'not-approved: %s answer is not an approval value\n' "$TASK" >&2; exit 4 ;;
  esac
  touch "$DIR/receipts.jsonl"
  if ! grep -q "\"state\":\"approved\",\"digest\":\"$DIGEST\"" "$DIR/receipts.jsonl"; then
    jq -cn --arg digest "$DIGEST" --argjson v "$VERSION" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{state:"approved",digest:$digest,version:$v,at:$at}' >> "$DIR/receipts.jsonl"
  fi
  {
    printf 'Approved domain change for %s (cycle %s, version %s, digest %s). Apply ONLY these changes, nothing else.\n' "$MATE" "$CYCLE" "$VERSION" "$DIGEST"
    printf 'Precondition: for each change, apply only if the target file digest still equals original_digest (absent means the file must not exist).\n'
    printf 'If a target changed, write nothing: submit a refreshed fm-domain-proposal.v1 with the new before/after instead.\n'
    printf 'Shared tracked changes go through the normal PR and validation path; private charter or knowledge changes use their existing owners.\n'
    printf 'Report applied, validated, and landed as separate correlated documents or lines; a green PR is not applied.\n'
    jq -r '.proposal.changes[] | "- \(.kind) \(.file) original_digest=\(.original_digest)\n  after:\n\(.after | split("\n") | map("    " + .) | join("\n"))"' "$DIR/v$VERSION.json"
  }
  ;;
receipt)
  [ "$#" -ge 2 ] || fail 'usage: receipt <mate> applied|validated|landed [--cycle <n>] [--digest <sha256>] [--evidence <text>]'
  MATE=$1 STATE_NAME=$2
  shift 2
  slug mate "$MATE"
  case "$STATE_NAME" in applied) RANK=1 ;; validated) RANK=2 ;; landed) RANK=3 ;; *) fail 'state must be applied, validated, or landed' ;; esac
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
  DIR="$BASE/proposals/$MATE/$CYCLE"
  [ -f "$DIR/receipts.jsonl" ] || fail "no approved receipt for $MATE cycle $CYCLE"
  if [ -z "$DIGEST" ]; then
    DIGEST=$(jq -rs 'map(select(.state == "approved")) | last | .digest // empty' "$DIR/receipts.jsonl")
  fi
  [ -n "$DIGEST" ] || fail 'no approved digest to bind this receipt to'
  jq -es --arg d "$DIGEST" 'any(.[]; .state == "approved" and .digest == $d)' "$DIR/receipts.jsonl" >/dev/null \
    || fail "digest $DIGEST was never approved"
  HAVE=$(jq -rs --arg d "$DIGEST" 'map(select(.digest == $d) | {approved:0,applied:1,validated:2,landed:3}[.state]) | max' "$DIR/receipts.jsonl")
  if [ "$HAVE" -ge "$RANK" ]; then
    printf 'recorded: %s %s already has a receipt at or past %s\n' "$MATE" "$DIGEST" "$STATE_NAME"
    exit 0
  fi
  [ "$RANK" -eq $((HAVE + 1)) ] || fail "receipt order is approved, applied, validated, landed: $STATE_NAME is not next"
  jq -cn --arg state "$STATE_NAME" --arg digest "$DIGEST" --arg evidence "$EVIDENCE" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{state:$state,digest:$digest,evidence:$evidence,at:$at}' >> "$DIR/receipts.jsonl"
  printf 'receipt: %s cycle %s %s digest %s\n' "$MATE" "$CYCLE" "$STATE_NAME" "$DIGEST"
  ;;
status)
  [ "$#" -eq 1 ] || fail 'usage: status <mate>'
  MATE=$1
  slug mate "$MATE"
  [ -d "$BASE/proposals/$MATE" ] || exit 0
  for CYCLE in $(find "$BASE/proposals/$MATE" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' | sed 's|.*/||' | sort -n); do
    DIR="$BASE/proposals/$MATE/$CYCLE"
    VERSION=$(latest_version "$DIR")
    [ -n "$VERSION" ] || { printf 'cycle %s: requested, no proposal\n' "$CYCLE"; continue; }
    TASK="domain-proposal-$MATE-$CYCLE"
    DIGEST=$(jq -r '.digest' "$DIR/v$VERSION.json")
    if [ "$(jq '.proposal.changes | length' "$DIR/v$VERSION.json")" -eq 0 ]; then
      ANSWER='no-change'
    elif task_open "$TASK"; then
      ANSWER=pending
    else
      ANSWER=$(task_answer "$TASK" | cut -f2)
      [ -n "$ANSWER" ] || ANSWER=closed-without-answer
    fi
    RECEIPT=none
    if [ -f "$DIR/receipts.jsonl" ]; then
      RECEIPT=$(jq -rs --arg d "$DIGEST" 'map(select(.digest == $d)) | last | .state // "none"' "$DIR/receipts.jsonl")
    fi
    printf 'cycle %s: %s v%s digest %s answer=%s receipt=%s\n' "$CYCLE" "$TASK" "$VERSION" "$(digest12 "$DIGEST")" "$ANSWER" "$RECEIPT"
  done
  ;;
esac
