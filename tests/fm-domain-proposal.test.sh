#!/usr/bin/env bash
# Domain proposal handoff through its public subcommands, against an isolated main home.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo 'skip: tasks-axi not found'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-domain-proposal)
TASKS_AXI_BIN=$(command -v tasks-axi)
TOOL="$ROOT/bin/fm-domain-proposal.sh"
HOME_DIR="$TMP_ROOT/home"
BUNDLE=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
mkdir -p "$HOME_DIR/data/domain-freshness/bundles" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
FAKEBIN=$(fm_fakebin "$HOME_DIR")
fm_fake_exit0 "$FAKEBIN" tmux treehouse no-mistakes gh gh-axi
jq -n '{schema:"fm-domain-evidence.v1",collected_at:"2026-10-13T12:00:00Z",complete:true,registry_coverage:"complete",
  domains:[{id:"media",home:"/x/media",scope:"newsletter and SEO",host:""}],coverage:[],evidence:[]}' \
  > "$HOME_DIR/data/domain-freshness/bundles/$BUNDLE.json"

tool() {
  PATH="$FAKEBIN:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    bash "$TOOL" "$@"
}
hold_tool() {
  PATH="$FAKEBIN:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    bash "$ROOT/bin/fm-captain-hold.sh" "$@"
}
proposal() {  # <after-text> [<bundle>]
  jq -n --arg after "$1" --arg bundle "${2:-$BUNDLE}" '{schema:"fm-domain-proposal.v1",mate:"media",bundle_id:$bundle,
    bullets:["Index contract changed; media skill must follow"],
    changes:[{kind:"skill",file:"/x/media/SKILL.md",original_digest:"absent",before:"",after:$after,
      always_loaded_size_delta:0,sources:["https://github.com/example/repo/pull/1"],effect:"media drafts follow the contract"}]}'
}
answer() {  # <task> <text>
  printf '%s\n' "$2" > "$TMP_ROOT/answer"
  hold_tool answer "$1" --decision-file "$TMP_ROOT/answer" >/dev/null
}
DIR="$HOME_DIR/data/domain-freshness/proposals/media/1"
TASK=domain-proposal-media-1

out=$(tool request media nosuchbundle 2>&1); rc=$?
expect_code 1 "$rc" 'request refuses a missing bundle'
out=$(tool request ghost "$BUNDLE" 2>&1); rc=$?
expect_code 1 "$rc" 'request refuses a mate absent from the bundle'
cat > "$FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "$1" = add ] && [ -f "$FM_HOME/state/fail-domain-add-once" ]; then
  rm "$FM_HOME/state/fail-domain-add-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
SH
chmod +x "$FAKEBIN/tasks-axi"
: > "$HOME_DIR/state/fail-domain-add-once"
tool request media "$BUNDLE" >/dev/null 2>&1; expect_code 1 "$?" 'failed task creation is reported'
rm "$FAKEBIN/tasks-axi"
out=$(tool request media "$BUNDLE")
assert_contains "$out" 'READ-ONLY' 'request text forbids applying'
assert_contains "$out" "$BUNDLE.json" 'request text names the bundle'
CORR=$(jq -r .corr "$DIR/request.json")
assert_contains "$out" "$CORR" 'request text carries its durable correlation id'
assert_contains "$(tool status media)" 'requested, no proposal' 'request created a proposal cycle'
hold_tool open "$TASK" --distinguish-absent >/dev/null 2>&1; expect_code 1 "$?" 'request task exists before its hold'
pass 'request validates the bundle and prints a read-only marked request'

proposal 'v1 text' > "$TMP_ROOT/p1.json"
tool submit media "$TMP_ROOT/p1.json" --corr "$CORR" > "$TMP_ROOT/submit.out" || fail 'submit v1 failed'
assert_contains "$(cat "$TMP_ROOT/submit.out")" "held: $TASK v1" 'submit holds one card'
hold_tool open "$TASK" || fail 'card is not an open captain call'
assert_present "$DIR/v1.md" 'exact before/after rendering exists'
assert_grep 'v1 text' "$DIR/v1.md" 'rendering carries the after text'
D1=$(jq -r .digest "$DIR/v1.json")
out=$(tool submit media "$TMP_ROOT/p1.json" --corr "$CORR"); assert_contains "$out" 'unchanged' 'identical resubmission is idempotent'
[ ! -e "$DIR/v2.json" ] || fail 'idempotent resubmission wrote a version'
pass 'submit opens one card and an identical resubmission is a no-op'

printf '{"schema":"fm-domain-proposal.v1","mate":"media","bundle_id":"%s","bullets":["x"],"changes":[{"kind":"skill","file":"f","original_digest":"nothex","before":"a","after":"b","always_loaded_size_delta":0,"sources":["https://e.x"],"effect":"e"}]}' \
  "$BUNDLE" > "$TMP_ROOT/bad.json"
tool submit media "$TMP_ROOT/bad.json" --corr "$CORR" >/dev/null 2>&1; expect_code 1 "$?" 'invalid digest is refused'
proposal 'x' otherbundle > "$TMP_ROOT/bad2.json"
tool submit media "$TMP_ROOT/bad2.json" --corr "$CORR" >/dev/null 2>&1; expect_code 1 "$?" 'unrequested bundle is refused'
tool submit media "$TMP_ROOT/p1.json" --corr 0123456789abcdef >/dev/null 2>&1; expect_code 1 "$?" 'wrong correlation is refused'
tool submit media "$TMP_ROOT/p1.json" >/dev/null 2>&1; expect_code 1 "$?" 'missing correlation is refused'
pass 'submit refuses malformed or unrequested proposals'

tool approve media >/dev/null 2>&1; expect_code 2 "$?" 'approve before an answer'
proposal $'v2 text\n~~~~\nfinish' > "$TMP_ROOT/p2.json"
tool submit media "$TMP_ROOT/p2.json" --corr "$CORR" >/dev/null || fail 'submit v2 failed'
assert_grep '~~~~~' "$DIR/v2.md" 'exact change text did not get a safe fence'
D2=$(jq -r .digest "$DIR/v2.json")
assert_not_equals "$D1" "$D2" 'versions have distinct digests'
hold_tool open "$TASK" || fail 'v2 re-hold closed the card'
[ "$(find "$HOME_DIR/data/domain-freshness/proposals/media" -name 'request.json' | wc -l)" -eq 1 ] || fail 'second card or cycle was created'
answer "$TASK" "approve-$(printf %s "$D1" | cut -c1-12)"
out=$(tool approve media 2>&1); rc=$?
expect_code 3 "$rc" 'approval of an older digest authorizes nothing'
assert_contains "$out" 'stale' 'stale approval is named'
[ ! -s "$DIR/receipts.jsonl" ] || [ ! -e "$DIR/receipts.jsonl" ] || fail 'stale approval wrote a receipt'
pass 'a newer version re-holds one card and an older digest approval is refused'

out=$(tool request media "$BUNDLE"); assert_contains "$out" 'cycle 2' 'answered cycle starts a new cycle'
CORR=$(jq -r .corr "$HOME_DIR/data/domain-freshness/proposals/media/2/request.json")
proposal 'cycle2 text' > "$TMP_ROOT/p3.json"
tool submit media "$TMP_ROOT/p3.json" --corr "$CORR" >/dev/null || fail 'submit cycle 2 failed'
D3=$(jq -r .digest "$HOME_DIR/data/domain-freshness/proposals/media/2/v1.json")
answer domain-proposal-media-2 "approve-$(printf %s "$D3" | cut -c1-12)"
out=$(tool approve media) || fail 'approve failed on a matching answer'
assert_contains "$(PATH="$FAKEBIN:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" bash "$ROOT/bin/fm-tasks-axi.sh" show domain-proposal-media-2 --full)" 'state: queued' 'approval did not preserve the activation task'
assert_contains "$out" "digest $D3" 'application request binds the digest'
assert_contains "$out" 'cycle2 text' 'application request carries only approved after text'
assert_contains "$out" 'original_digest=absent' 'application request carries the precondition'
tool receipt media applied --evidence 'file written' >/dev/null || fail 'applied receipt failed'
tool receipt media applied >/dev/null || fail 'repeated receipt is not idempotent'
tool receipt media validated >/dev/null 2>&1; expect_code 1 "$?" 'extra receipt state is refused'
out=$(tool status media)
assert_contains "$out" 'receipt=applied' 'status shows the application receipt'
jq -es --arg corr "$CORR" 'all(.[]; .corr == $corr)' "$HOME_DIR/data/domain-freshness/proposals/media/2/receipts.jsonl" >/dev/null \
  || fail 'receipts did not retain request correlation'
tool receipt media applied --digest "$D1" >/dev/null 2>&1; expect_code 1 "$?" 'receipt for an unapproved digest is refused'
pass 'approval is digest-bound and application closes the same task'

proposal 'rejected text' > "$TMP_ROOT/p4.json"
tool request media "$BUNDLE" >/dev/null
CORR=$(jq -r .corr "$HOME_DIR/data/domain-freshness/proposals/media/3/request.json")
tool submit media "$TMP_ROOT/p4.json" --corr "$CORR" >/dev/null || fail 'submit cycle 3 failed'
answer domain-proposal-media-3 reject
tool approve media >/dev/null 2>&1; expect_code 4 "$?" 'rejection authorizes nothing'
pass 'a rejected proposal stays inactive'

jq -n --arg b "$BUNDLE" '{schema:"fm-domain-proposal.v1",mate:"media",bundle_id:$b,bullets:["No action needed"],changes:[]}' > "$TMP_ROOT/p5.json"
tool request media "$BUNDLE" >/dev/null
CORR=$(jq -r .corr "$HOME_DIR/data/domain-freshness/proposals/media/4/request.json")
out=$(tool submit media "$TMP_ROOT/p5.json" --corr "$CORR"); assert_contains "$out" 'no-change' 'no change opens no card'
assert_contains "$(tool status media)" 'answer=no-change' 'withdrawal is visible'
assert_contains "$(tool receipt media applied 2>&1)" 'no approved receipt' 'withdrawal does not approve application'
pass 'a no-change proposal records a version and opens no card'

jq '.domains[0].host="remote-host"' "$HOME_DIR/data/domain-freshness/bundles/$BUNDLE.json" > "$TMP_ROOT/remote-bundle.json"
cp "$TMP_ROOT/remote-bundle.json" "$HOME_DIR/data/domain-freshness/bundles/$BUNDLE.json"
out=$(tool request media "$BUNDLE" 2>&1); rc=$?
expect_code 1 "$rc" 'remote route is refused'
assert_contains "$out" 'remote domain handoff is not yet supported' 'remote refusal is clear'
jq '.domains[0].host=""' "$TMP_ROOT/remote-bundle.json" > "$HOME_DIR/data/domain-freshness/bundles/$BUNDLE.json"
pass 'remote routes refuse the local-only handoff'

tool request media "$BUNDLE" >/dev/null
CORR=$(jq -r .corr "$HOME_DIR/data/domain-freshness/proposals/media/5/request.json")
proposal 'withdraw this' > "$TMP_ROOT/withdraw.json"
tool submit media "$TMP_ROOT/withdraw.json" --corr "$CORR" >/dev/null || fail 'withdrawal setup failed'
cat > "$FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "$1" = done ] && [ -f "$FM_HOME/state/fail-domain-done-once" ]; then
  rm "$FM_HOME/state/fail-domain-done-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
SH
chmod +x "$FAKEBIN/tasks-axi"
: > "$HOME_DIR/state/fail-domain-done-once"
tool submit media "$TMP_ROOT/p5.json" --corr "$CORR" >/dev/null 2>&1; expect_code 1 "$?" 'failed withdrawal close is reported'
tool submit media "$TMP_ROOT/p5.json" --corr "$CORR" >/dev/null || fail 'withdrawal failed'
rm "$FAKEBIN/tasks-axi"
out=$(PATH="$FAKEBIN:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" bash "$ROOT/bin/fm-tasks-axi.sh" show domain-proposal-media-5 --full)
assert_contains "$out" 'state: done' 'withdrawal did not close held task'
assert_contains "$out" 'withdrawn' 'withdrawal evidence was not recorded'
pass 'zero-change revision closes the held task with evidence'

tool request media "$BUNDLE" >/dev/null
CORR=$(jq -r .corr "$HOME_DIR/data/domain-freshness/proposals/media/6/request.json")
head -c 150000 /dev/zero | tr '\0' x > "$TMP_ROOT/large.txt"
jq -n --rawfile after "$TMP_ROOT/large.txt" --arg b "$BUNDLE" '{schema:"fm-domain-proposal.v1",mate:"media",bundle_id:$b,
  bullets:["Large exact change"],changes:[{kind:"rule",file:"/x/media/RULE.md",original_digest:"absent",before:"",after:$after,
  always_loaded_size_delta:0,sources:["https://github.com/example/repo/pull/1"],effect:"rule updated"}]}' > "$TMP_ROOT/large.json"
tool submit media "$TMP_ROOT/large.json" --corr "$CORR" >/dev/null || fail 'large proposal was not accepted'
jq -e '.proposal.changes[0].after | length == 150000' "$HOME_DIR/data/domain-freshness/proposals/media/6/v1.json" >/dev/null \
  || fail 'large proposal version was truncated'
pass 'large proposals persist a complete version and report'

mkdir -p "$TMP_ROOT/mate/state"
printf 'media\n' > "$TMP_ROOT/mate/.fm-secondmate-home"
FM_HOME="$TMP_ROOT/mate" bash "$TOOL" status media >/dev/null 2>&1; expect_code 1 "$?" 'a non-main home is refused'
pass 'secondmate homes cannot own proposals'
