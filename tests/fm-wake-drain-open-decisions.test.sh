#!/usr/bin/env bash
# tests/fm-wake-drain-open-decisions.test.sh - behavior tests for the OPEN
# DECISIONS section bin/fm-wake-drain.sh prints on every drain (including the
# empty-queue fast path). The section is pure wiring around
# fm-classify-lib.sh's status_open_decisions fold (the ONE authoritative
# open/resolved statement); these tests exercise the real drain script over
# crafted status logs and assert on its printed output, not on the fold's own
# source text.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-open-decisions-tests)

test_buried_decision_still_surfaces() {
  local dir state out
  dir=$(make_case buried)
  state="$dir/state"
  out="$dir/drain.out"
  # The needs-decision line sits under later routine and unrelated-key lines,
  # exactly the burial scenario the fix targets: last-line-only reads would
  # show "resolved [key=other]" and hide the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task1.status"
  printf 'working: continuing other work\n' >> "$state/task1.status"
  printf 'resolved [key=other]: unrelated decision closed\n' >> "$state/task1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a buried decision"

  grep -F 'OPEN DECISIONS' "$out" >/dev/null || fail "buried decision produced no OPEN DECISIONS section"
  grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "buried needs-decision was not surfaced with its task, key, and note"
  grep -F "close one by answering it: bin/fm-send.sh <task> --resolve-key <key>" "$out" >/dev/null \
    || fail "open section is missing the answerer-closes hint"
  pass "a needs-decision buried under later routine/other-key lines still reports as open"
}

test_explicit_resolution_closes_it() {
  local dir state out
  dir=$(make_case resolved)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task2.status"
  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/task2.status"
  printf 'done: shipped\n' >> "$state/task2.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an explicit resolution"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an explicitly resolved decision still printed as open: $(cat "$out")"
  fi
  pass "an explicit resolved [key=X] closes the keyed decision"
}

test_reserved_key_namespace_is_owned_by_its_library() {
  local dir state out
  dir=$(make_case reserved-key)
  state="$dir/state"
  out="$dir/drain.out"
  # `pending-reply-<id>` names a decision bin/fm-pending-reply-lib.sh raises and
  # is the only writer that closes it. Every writer reaches this same stream - a
  # local mate appends into it directly, and a remote mate's lines are mirrored
  # into it verbatim - so another writer must not be able to take that key over
  # or clear it just by naming it.
  printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=ios pending-reply-id=abcdef0123456789 request=ship it\n' > "$state/task9.status"
  printf 'blocked [key=pending-reply-abcdef0123456789]: shipping is blocked on infra\n' >> "$state/task9.status"
  printf 'resolved [key=pending-reply-abcdef0123456789]: all good now\n' >> "$state/task9.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on reserved-key lines"

  grep -F 'pending-reply-id=abcdef0123456789' "$out" >/dev/null \
    || fail "a foreign resolution cleared a reserved decision it does not own: $(cat "$out")"
  if grep -F 'task9 [key=pending-reply-abcdef0123456789] blocked: shipping is blocked on infra' "$out" >/dev/null; then
    fail "a foreign line took over a reserved decision key: $(cat "$out")"
  fi

  # The owner's own resolution, which speaks that namespace's vocabulary, closes it.
  printf 'resolved [key=pending-reply-abcdef0123456789]: pending-reply-resolved: task=ios pending-reply-id=abcdef0123456789 via=status\n' >> "$state/task9.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after the owner closed its decision"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the owner's own resolution did not close its reserved decision: $(cat "$out")"
  fi
  pass "a reserved decision key can only be opened or closed by its owning library"
}

test_later_unrelated_terminal_line_does_not_close_it() {
  local dir state out
  dir=$(make_case unrelated-terminal)
  state="$dir/state"
  out="$dir/drain.out"
  # A later done: with no matching [key=...] token opens/closes only the
  # "default" key; it must never clear the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task3.status"
  printf 'done: unrelated later milestone\n' >> "$state/task3.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an unrelated terminal line"

  grep -F 'task3' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "a later unrelated terminal line incorrectly cleared the open decision"
  pass "a later unrelated terminal line never clears an open decision"
}

test_no_open_decisions_prints_nothing() {
  local dir state out
  dir=$(make_case none-open)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: on it\n' > "$state/task4.status"
  printf 'resolved: shipped clean\n' > "$state/task5.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with no open decisions"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the empty case printed an OPEN DECISIONS section: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the empty case with no queued wakes was not silent: $(cat "$out")"
  pass "no open decisions across the fleet prints nothing"
}

test_open_decision_surfaces_even_with_an_unrelated_queued_wake() {
  local dir state out
  dir=$(make_case fleet-wide)
  state="$dir/state"
  out="$dir/drain.out"
  # task6 has a buried, still-open decision but generates NO new queue record
  # this turn; task7 is what actually wakes the drain. The fleet-wide scan
  # must still catch task6's decision alongside task7's own raw row.
  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$state/task6.status"
  printf 'working: continuing\n' >> "$state/task6.status"
  printf 'blocked: waiting on credentials\n' > "$state/task7.status"
  append_wake "$state" signal task7.status "blocked: waiting on credentials" \
    || fail "queueing the unrelated wake failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a mixed fleet"

  grep "$(printf '\tsignal\ttask7.status\t')" "$out" >/dev/null || fail "task7's own raw row is missing"
  grep -F 'task6' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "task6's buried decision was not surfaced even though only task7 queued a wake"
  pass "the open-decision section is fleet-wide, not scoped to this drain's own queued records"
}

test_buried_decision_surfaces_on_the_empty_queue_fast_path() {
  local dir state out
  dir=$(make_case empty-queue-fast-path)
  state="$dir/state"
  out="$dir/drain.out"
  # No wake is queued at all (the empty-queue exit), but the decision is still
  # open on disk - session-start relies on exactly this path.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task8.status"
  printf 'working: continuing\n' >> "$state/task8.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "empty-queue drain failed"

  grep -F 'task8' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "the empty-queue fast path did not surface a still-open decision"
  pass "a buried open decision surfaces even when the wake queue itself is empty"
}

test_status_symlink_is_not_followed() {
  local dir state out
  dir=$(make_case status-symlink)
  state="$dir/state"
  out="$dir/drain.out"
  mkdir -p "$dir/outside"
  printf 'needs-decision [key=local]: keep this visible\n' > "$state/local.status"
  printf 'needs-decision [key=foreign]: do not expose this\n' > "$dir/outside/foreign.status"
  ln -s ../outside/foreign.status "$state/linked.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a symlinked status file"

  grep -F 'local [key=local] needs-decision: keep this visible' "$out" >/dev/null \
    || fail "the valid local decision did not surface alongside a rejected status symlink"
  if grep -F 'do not expose this' "$out" >/dev/null; then
    fail "the fleet scan followed a status symlink outside the state directory"
  fi
  pass "the fleet-wide decision scan does not follow status symlinks"
}

# The per-item cut now comes from bin/fm-line-cap-lib.sh, shared with the
# session-start digest's status tails so one truncation marker means the same
# thing wherever an agent meets it. This pins the drain's own end of that
# contract: the lede survives, the marker appears, and the item still fits the
# section's per-item budget including the newline it is charged for.
test_over_long_decision_note_is_capped_with_a_marker() {
  local dir state out line longest
  dir=$(make_case long-note)
  state="$dir/state"
  out="$dir/drain.out"
  {
    printf 'needs-decision [key=api-shape]: pick REST or RPC'
    awk 'BEGIN { while (i++ < 200) printf " and-then-some" }'
    printf '\n'
  } > "$state/task-long.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on an over-long decision note"

  line=$(grep -F 'task-long' "$out")
  case "$line" in
    'task-long [key=api-shape] needs-decision: pick REST or RPC'*' [truncated]') : ;;
    *) fail "an over-long decision note was not capped with its lede intact: $line" ;;
  esac
  longest=${#line}
  [ "$longest" -le 219 ] || fail "a capped decision item ran $longest characters past its per-item budget"

  printf 'needs-decision [key=short]: brief enough to keep whole\n' > "$state/task-short.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a short decision note"
  grep -F 'task-short [key=short] needs-decision: brief enough to keep whole' "$out" >/dev/null \
    || fail "a decision note already under the cap was altered"
  if grep -F 'brief enough to keep whole [truncated]' "$out" >/dev/null; then
    fail "a decision note already under the cap was marked truncated"
  fi

  pass "an over-long open decision is cut to its per-item budget with the shared truncation marker"
}

# A fake gh for the PR-gated annotation: `pr view <url>` answers from
# $FM_FAKE_GH_MAP ("<url> merged|closed|open|fail|hang" per line) in the field
# shape bin/fm-pr-state.sh asks for, `pr checks` reports nothing, and every call
# is logged to $FM_FAKE_GH_LOG so a test can prove which lookups happened.
make_fake_gh() {  # <fakebin>
  cat > "$1/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_GH_LOG"
[ "${1:-}" = pr ] && [ "${2:-}" = view ] || exit 0
mode=$(awk -v u="$3" '$1 == u { print $2 }' "$FM_FAKE_GH_MAP")
case "$mode" in
  merged) printf 'state=merged\nmerged_at=2026-10-12T02:15:00Z\n' ;;
  closed) printf 'state=closed\nmerged_at=\n' ;;
  open) printf 'state=open\nmerged_at=\n' ;;
  hang) exec sleep 60 ;;
  *) exit 1 ;;
esac
printf 'draft=false\nhead=abc123\nauthor=someone\nmergeability=mergeable\nreview_decision=\n'
SH
  chmod +x "$1/gh"
}

test_pr_gated_decision_is_flagged_with_its_close_command() {
  local dir state out map
  dir=$(make_case pr-gated)
  state="$dir/state"
  out="$dir/drain.out"
  map="$dir/gh.map"
  make_fake_gh "$dir/fakebin"
  : > "$dir/gh.log"
  {
    printf 'https://github.com/o/r/pull/24 merged\n'
    printf 'https://github.com/o/r/pull/31 closed\n'
    printf 'https://github.com/o/r/pull/40 open\n'
    printf 'https://github.com/o/r/pull/70 fail\n'
  } > "$map"
  printf 'needs-decision [key=m1]: merge https://github.com/o/r/pull/24 now?\n' > "$state/t-merged.status"
  printf 'needs-decision [key=m2]: also gated on https://github.com/o/r/pull/24\n' > "$state/t-same.status"
  printf 'needs-decision [key=c1]: merge https://github.com/o/r/pull/31?\n' > "$state/t-closed.status"
  printf 'needs-decision [key=o1]: merge https://github.com/o/r/pull/40?\n' > "$state/t-open.status"
  printf 'needs-decision [key=two]: pick https://github.com/o/r/pull/50 or https://github.com/o/r/pull/51\n' > "$state/t-two.status"
  printf 'needs-decision [key=f1]: merge https://github.com/o/r/pull/70?\n' > "$state/t-fail.status"
  # The offline signal: this log already records the merge, so no lookup is due.
  printf 'needs-decision [key=off]: merge https://github.com/o/r/pull/60?\n' > "$state/t-off.status"
  printf 'done [key=merged-t-off]: merged t-off https://github.com/o/r/pull/60\n' >> "$state/t-off.status"
  # A merge record for a different PR number is not this PR's merge.
  printf 'needs-decision [key=n1]: merge https://github.com/o/r/pull/6?\n' > "$state/t-near.status"
  printf 'done [key=merged-t-near]: merged t-near https://github.com/o/r/pull/66\n' >> "$state/t-near.status"
  printf 'https://github.com/o/r/pull/6 fail\n' >> "$map"

  PATH="$dir/fakebin:$PATH" FM_FAKE_GH_LOG="$dir/gh.log" FM_FAKE_GH_MAP="$map" \
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with PR-gated decisions"

  for key in m1 m2 c1 o1 two f1 off n1; do
    grep -F "[key=$key] needs-decision:" "$out" >/dev/null \
      || fail "the PR annotation changed which decisions are open (missing $key): $(cat "$out")"
  done
  grep -A1 -F 't-merged [key=m1]' "$out" | grep -F "  ^ PR https://github.com/o/r/pull/24 is merged at 2026-10-12T02:15:00Z; if that settles it, close it: bin/fm-send.sh t-merged --resolve-key m1 'PR https://github.com/o/r/pull/24 merged'" >/dev/null \
    || fail "a merged PR was not flagged with its exact close command: $(cat "$out")"
  grep -A1 -F 't-same [key=m2]' "$out" | grep -F "bin/fm-send.sh t-same --resolve-key m2 'PR https://github.com/o/r/pull/24 merged'" >/dev/null \
    || fail "a second decision gated on the same PR was not flagged: $(cat "$out")"
  grep -A1 -F 't-closed [key=c1]' "$out" | grep -F "  ^ PR https://github.com/o/r/pull/31 is closed; if that settles it, close it: bin/fm-send.sh t-closed --resolve-key c1 'PR https://github.com/o/r/pull/31 closed'" >/dev/null \
    || fail "a closed PR was not flagged with its exact close command: $(cat "$out")"
  grep -A1 -F 't-off [key=off]' "$out" | grep -F "bin/fm-send.sh t-off --resolve-key off 'PR https://github.com/o/r/pull/60 merged'" >/dev/null \
    || fail "a merge already recorded in the same log did not flag the decision: $(cat "$out")"
  for task in t-open t-two t-fail t-near; do
    if grep -A1 -F "$task [key=" "$out" | grep -F '  ^ PR ' >/dev/null; then
      fail "$task was flagged although its PR is open, ambiguous, unreadable, or unmerged: $(cat "$out")"
    fi
  done
  [ "$(grep -c 'pr view https://github.com/o/r/pull/24 ' "$dir/gh.log")" = 1 ] \
    || fail "one PR named by two decisions was read more than once per drain: $(cat "$dir/gh.log")"
  if grep -E 'pull/(50|51|60) ' "$dir/gh.log" >/dev/null; then
    fail "an ambiguous or already-recorded PR was looked up: $(cat "$dir/gh.log")"
  fi
  pass "an open decision gated on one merged or closed PR is flagged with its exact close command"
}

test_captain_hold_pr_uses_owning_home_close_path() {
  local dir state out map
  dir=$(make_case captain-hold-pr)
  state="$dir/state"
  out="$dir/drain.out"
  map="$dir/gh.map"
  make_fake_gh "$dir/fakebin"
  : > "$dir/gh.log"
  printf 'https://github.com/o/r/pull/31 closed\n' > "$map"
  printf 'needs-decision [key=captain-hold-release-1]: review https://github.com/o/r/pull/24\n' > "$state/mate.status"
  printf 'done [key=merged-release]: merged https://github.com/o/r/pull/24\n' >> "$state/mate.status"
  printf 'blocked [key=captain-hold-release-2]: review https://github.com/o/r/pull/31\n' > "$state/mate-closed.status"

  PATH="$dir/fakebin:$PATH" FM_FAKE_GH_LOG="$dir/gh.log" FM_FAKE_GH_MAP="$map" \
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on PR-gated captain holds"
  grep -A1 -F 'mate [key=captain-hold-release-1]' "$out" | grep -F 'PR https://github.com/o/r/pull/24 is merged' >/dev/null \
    || fail "the merged PR flag was lost for a captain hold: $(cat "$out")"
  grep -A1 -F 'mate-closed [key=captain-hold-release-2]' "$out" | grep -F 'PR https://github.com/o/r/pull/31 is closed' >/dev/null \
    || fail "the closed PR flag was lost for a captain hold: $(cat "$out")"
  grep -F 'call held for the captain: close only in its owning home via bin/fm-captain-hold.sh (captain' "$out" >/dev/null \
    || fail "the owning-home close instruction was missing: $(cat "$out")"
  grep -F 'evidence-backed reconcile close), never by resolving the key as moot' "$out" >/dev/null \
    || fail "the held-call close restriction was missing: $(cat "$out")"
  if grep -F 'bin/fm-send.sh' "$out" >/dev/null; then
    fail "a captain hold was offered the ordinary status-key close path: $(cat "$out")"
  fi

  printf 'needs-decision [key=ordinary]: review https://github.com/o/r/pull/24\n' > "$state/ordinary.status"
  printf 'done [key=merged-ordinary]: merged https://github.com/o/r/pull/24\n' >> "$state/ordinary.status"
  PATH="$dir/fakebin:$PATH" FM_FAKE_GH_LOG="$dir/gh.log" FM_FAKE_GH_MAP="$map" \
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with an ordinary PR decision"
  grep -A1 -F 'ordinary [key=ordinary]' "$out" | grep -F "bin/fm-send.sh ordinary --resolve-key ordinary 'PR https://github.com/o/r/pull/24 merged'" >/dev/null \
    || fail "the ordinary decision lost its exact close command: $(cat "$out")"
  pass "captain holds retain PR flags but close only in their owning home"
}

test_pr_lookups_are_capped_and_bounded() {
  local dir state out map i start elapsed
  dir=$(make_case pr-bounded)
  state="$dir/state"
  out="$dir/drain.out"
  map="$dir/gh.map"
  make_fake_gh "$dir/fakebin"
  : > "$dir/gh.log"
  : > "$map"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    printf 'https://github.com/o/r/pull/%s hang\n' "$i" >> "$map"
    printf 'needs-decision [key=k%s]: merge https://github.com/o/r/pull/%s?\n' "$i" "$i" > "$state/t$i.status"
  done
  start=$(date +%s)
  PATH="$dir/fakebin:$PATH" FM_FAKE_GH_LOG="$dir/gh.log" FM_FAKE_GH_MAP="$map" \
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed while PR lookups hung"
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 20 ] || fail "hung PR lookups delayed the drain by ${elapsed}s"
  [ "$(grep -c '^pr view ' "$dir/gh.log")" -le 8 ] \
    || fail "the drain made more than the capped PR lookups: $(cat "$dir/gh.log")"
  [ "$(grep -c 'needs-decision:' "$out")" = 12 ] \
    || fail "hung lookups changed the listed decisions: $(cat "$out")"
  if grep -F '  ^ PR ' "$out" >/dev/null; then
    fail "a timed-out lookup still annotated a decision: $(cat "$out")"
  fi

  # A missing gh prints nothing extra and still lists every decision.
  printf '#!/usr/bin/env bash\nexit 127\n' > "$dir/fakebin/gh"
  FM_STATE_OVERRIDE="$state" PATH="$dir/fakebin:$PATH" "$DRAIN" > "$out" \
    || fail "drain failed without a usable gh"
  [ "$(grep -c 'needs-decision:' "$out")" = 12 ] || fail "an unusable gh changed the listing: $(cat "$out")"
  pass "PR lookups are capped per drain, bounded in time, and silent when they fail"
}

test_pr_decisions_over_lookup_cap_are_counted() {
  local dir state out map i
  dir=$(make_case pr-over-cap)
  state="$dir/state"
  out="$dir/drain.out"
  map="$dir/gh.map"
  make_fake_gh "$dir/fakebin"
  : > "$dir/gh.log"
  : > "$map"
  for i in 1 2 3 4 5 6 7 8 9; do
    printf 'https://github.com/o/r/pull/%s open\n' "$i" >> "$map"
    printf 'needs-decision [key=k%s]: merge https://github.com/o/r/pull/%s?\n' "$i" "$i" > "$state/t$i.status"
  done
  printf 'blocked [key=same]: also waiting on https://github.com/o/r/pull/9\n' > "$state/tz.status"

  PATH="$dir/fakebin:$PATH" FM_FAKE_GH_LOG="$dir/gh.log" FM_FAKE_GH_MAP="$map" \
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with PR decisions over the lookup cap"
  [ "$(grep -c '^pr view ' "$dir/gh.log")" = 8 ] \
    || fail "the lookup cap changed: $(cat "$dir/gh.log")"
  [ "$(grep -c 'needs-decision:' "$out")" = 9 ] \
    || fail "an over-cap decision disappeared: $(cat "$out")"
  grep -F 'tz [key=same] blocked:' "$out" >/dev/null \
    || fail "the repeated over-cap PR decision disappeared: $(cat "$out")"
  [ "$(grep -c '^OPEN DECISIONS: 2 PR-linked decisions were not checked this drain (lookup cap)$' "$out")" = 1 ] \
    || fail "the two unchecked PR-linked decisions were not counted once: $(cat "$out")"
  pass "PR-linked decisions beyond the lookup cap are visibly counted"
}

test_later_offline_merge_record_covers_shared_pr() {
  local dir state out map i
  dir=$(make_case pr-later-offline)
  state="$dir/state"
  out="$dir/drain.out"
  map="$dir/gh.map"
  make_fake_gh "$dir/fakebin"
  : > "$dir/gh.log"
  : > "$map"
  printf 'https://github.com/o/r/pull/24 fail\n' >> "$map"
  printf 'needs-decision [key=first]: merge https://github.com/o/r/pull/24?\n' > "$state/t9.status"
  printf 'blocked [key=second]: waiting on https://github.com/o/r/pull/24\n' > "$state/tz.status"
  printf 'done [key=merged-tz]: merged https://github.com/o/r/pull/24\n' >> "$state/tz.status"

  PATH="$dir/fakebin:$PATH" FM_FAKE_GH_LOG="$dir/gh.log" FM_FAKE_GH_MAP="$map" \
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a later offline merge record"
  grep -A1 -F 't9 [key=first]' "$out" | grep -F 'PR https://github.com/o/r/pull/24 is merged' >/dev/null \
    || fail "the first decision did not use the later offline merge record: $(cat "$out")"
  grep -A1 -F 'tz [key=second]' "$out" | grep -F 'PR https://github.com/o/r/pull/24 is merged' >/dev/null \
    || fail "the second decision did not use its own offline merge record: $(cat "$out")"
  if grep -F 'pr view https://github.com/o/r/pull/24 ' "$dir/gh.log" >/dev/null; then
    fail "a failing live lookup hid the later offline merge record: $(cat "$dir/gh.log")"
  fi

  for i in 1 2 3 4 5 6 7 8; do
    printf 'https://github.com/o/r/pull/%s fail\n' "$i" >> "$map"
    printf 'needs-decision [key=k%s]: merge https://github.com/o/r/pull/%s?\n' "$i" "$i" > "$state/t$i.status"
  done
  : > "$dir/gh.log"
  PATH="$dir/fakebin:$PATH" FM_FAKE_GH_LOG="$dir/gh.log" FM_FAKE_GH_MAP="$map" \
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with an offline merge after the lookup cap"
  if grep -F 'PR-linked decisions were not checked' "$out" >/dev/null; then
    fail "a decision with an offline merge record was counted as unchecked: $(cat "$out")"
  fi
  [ "$(grep -c '^pr view ' "$dir/gh.log")" = 8 ] \
    || fail "the lookup cap changed while an offline merge was available: $(cat "$dir/gh.log")"
  if grep -F 'pr view https://github.com/o/r/pull/24 ' "$dir/gh.log" >/dev/null; then
    fail "an offline merged PR was looked up despite a failing live result: $(cat "$dir/gh.log")"
  fi
  pass "a later offline merge record covers every decision sharing its PR"
}

test_unparsed_decision_line_is_warned_once() {
  local dir state out
  dir=$(make_case unparsed)
  state="$dir/state"
  out="$dir/drain.out"
  {
    printf 'working: started\n'
    printf 'needs-decision key=x-article at=1791734068: pick the data source\n'
    printf 'needs-decision [key=bad!]: invalid key\n'
    printf 'needs-decision at=1: malformed head\n'
    printf 'blocked [key=bad!]: invalid blocker key\n'
    printf 'needs-decision [key=ok]: a well-formed ask\n'
    printf 'blocked: waiting on key=value prose, not a key\n'
  } > "$state/mate.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on an unparsed decision line"
  grep -F "OPEN DECISIONS: unparsed decision line $state/mate.status:2, not read as open; rewrite it with [key=<slug>]: needs-decision key=x-article at=1791734068: pick the data source" "$out" >/dev/null \
    || fail "an unbracketed decision key was not warned with its file and line: $(cat "$out")"
  grep -F "OPEN DECISIONS: unparsed decision line $state/mate.status:3, not read as open; rewrite it with [key=<slug>]: needs-decision [key=bad!]: invalid key" "$out" >/dev/null \
    || fail "an invalid decision key was not warned: $(cat "$out")"
  grep -F "OPEN DECISIONS: unparsed decision line $state/mate.status:4, not read as open; rewrite it with [key=<slug>]: needs-decision at=1: malformed head" "$out" >/dev/null \
    || fail "a malformed head without a bracketed key was not warned: $(cat "$out")"
  grep -F "OPEN DECISIONS: unparsed decision line $state/mate.status:5, not read as open; rewrite it with [key=<slug>]: blocked [key=bad!]: invalid blocker key" "$out" >/dev/null \
    || fail "an invalid blocker key was not warned: $(cat "$out")"
  [ "$(grep -c 'unparsed decision line' "$out")" = 4 ] \
    || fail "a well-formed or keyless line was warned as unparsed: $(cat "$out")"
  if grep -F '[key=x-article]' "$out" >/dev/null; then
    fail "the unparsed line was treated as an open decision: $(cat "$out")"
  fi
  grep -F 'mate [key=ok] needs-decision: a well-formed ask' "$out" >/dev/null \
    || fail "the well-formed decision beside it was lost: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain failed"
  if grep -F 'unparsed decision line' "$out" >/dev/null; then
    fail "an already presented unparsed line was warned again: $(cat "$out")"
  fi

  {
    printf 'resolved [key=ok]: answered\n'
    printf 'blocked key=codex: signed out\n'
  } >> "$state/mate.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "third drain failed"
  grep -F "OPEN DECISIONS: unparsed decision line $state/mate.status:9," "$out" >/dev/null \
    || fail "a new unparsed line with no open decision beside it was not warned: $(cat "$out")"
  [ "$(grep -c 'unparsed decision line' "$out")" = 1 ] \
    || fail "the earlier unparsed line re-printed: $(cat "$out")"
  pass "a decision line the fold cannot parse is warned once with its file and line"
}

test_identical_unparsed_lines_keep_distinct_positions() {
  local dir state out
  dir=$(make_case repeated-unparsed)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'note: first presentation\n' > "$state/mate.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "initial drain failed"
  {
    printf 'working: next phase\n'
    printf 'needs-decision [key=bad!]: choose\n'
    printf 'needs-decision [key=bad!]: choose\n'
  } >> "$state/mate.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on repeated malformed lines"
  grep -F "unparsed decision line $state/mate.status:3," "$out" >/dev/null \
    || fail "the first malformed line did not keep its position: $(cat "$out")"
  grep -F "unparsed decision line $state/mate.status:4," "$out" >/dev/null \
    || fail "the second malformed line did not keep its position: $(cat "$out")"
  [ "$(grep -c 'unparsed decision line' "$out")" = 2 ] \
    || fail "the repeated malformed lines were not each warned once: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "later drain failed"
  if grep -F 'unparsed decision line' "$out" >/dev/null; then
    fail "the repeated malformed lines were warned after presentation: $(cat "$out")"
  fi
  pass "repeated malformed lines retain distinct positions and warn once"
}

test_buried_decision_still_surfaces
test_over_long_decision_note_is_capped_with_a_marker
test_explicit_resolution_closes_it
test_later_unrelated_terminal_line_does_not_close_it
test_reserved_key_namespace_is_owned_by_its_library
test_no_open_decisions_prints_nothing
test_open_decision_surfaces_even_with_an_unrelated_queued_wake
test_buried_decision_surfaces_on_the_empty_queue_fast_path
test_status_symlink_is_not_followed
test_pr_gated_decision_is_flagged_with_its_close_command
test_captain_hold_pr_uses_owning_home_close_path
test_pr_lookups_are_capped_and_bounded
test_pr_decisions_over_lookup_cap_are_counted
test_later_offline_merge_record_covers_shared_pr
test_unparsed_decision_line_is_warned_once
test_identical_unparsed_lines_keep_distinct_positions
