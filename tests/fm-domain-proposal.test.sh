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
BUNDLE2=fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210
mkdir -p "$HOME_DIR/data/domain-freshness/bundles" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
printf '%s\n' '- media - Media mate (home: /x/media; scope: newsletter and SEO; projects: -; added 2026-10-13)' > "$HOME_DIR/data/secondmates.md"
FAKEBIN=$(fm_fakebin "$HOME_DIR")
fm_fake_exit0 "$FAKEBIN" tmux treehouse no-mistakes gh gh-axi
jq -n '{schema:"fm-domain-evidence.v1",collected_at:"2026-10-13T12:00:00Z",complete:true,registry_coverage:"complete",
  domains:[{id:"media",home:"/x/media",scope:"stale bundle scope",host:""}],coverage:[],evidence:[]}' \
  > "$HOME_DIR/data/domain-freshness/bundles/$BUNDLE.json"
cp "$HOME_DIR/data/domain-freshness/bundles/$BUNDLE.json" "$HOME_DIR/data/domain-freshness/bundles/$BUNDLE2.json"

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
assert_contains "$out" 'Your registered scope: newsletter and SEO' 'request uses current registered scope'
assert_contains "$out" "Report with bundle_id $BUNDLE" 'request binds its reply to the bundle'
jq -e --arg b "$BUNDLE" '.latest_bundle_id == $b and (.bundles == [$b]) and (has("corr") | not)' "$DIR/request.json" >/dev/null \
  || fail 'request did not record its latest bundle'
hold_tool open "$TASK" --distinguish-absent >/dev/null 2>&1; expect_code 1 "$?" 'request task exists before its hold'
pass 'request validates the bundle and prints a read-only marked request'

proposal 'v1 text' > "$TMP_ROOT/p1.json"
printf '{"schema":"wrong"}\n' > "$TMP_ROOT/stream.json"
cat "$TMP_ROOT/p1.json" >> "$TMP_ROOT/stream.json"
tool submit media "$TMP_ROOT/stream.json" >/dev/null 2>&1; expect_code 1 "$?" 'a stream with a valid final value is refused'
[ ! -e "$DIR/v1.json" ] || fail 'invalid JSON stream published a proposal version'
for unsafe_source in $'https://example.com\n\n## Exact changes' $'https://example.com\tforged' $'https://example.com\x7f' $'https://example.com\u0085' $'https://example.com\u2028## Exact changes'; do
  jq --arg source "$unsafe_source" '.changes[0].sources = [$source]' "$TMP_ROOT/p1.json" > "$TMP_ROOT/unsafe-source.json"
  tool submit media "$TMP_ROOT/unsafe-source.json" >/dev/null 2>&1; expect_code 1 "$?" 'source URL with control or line separator is refused'
  [ ! -e "$DIR/v1.json" ] || fail 'unsafe source URL published a proposal version'
done
pass 'source URLs cannot inject report lines or control characters'
tool submit media "$TMP_ROOT/p1.json" > "$TMP_ROOT/submit.out" || fail 'submit v1 failed'
assert_contains "$(cat "$TMP_ROOT/submit.out")" "held: $TASK v1" 'submit holds one card'
hold_tool open "$TASK" || fail 'card is not an open captain call'
assert_present "$DIR/v1.md" 'exact before/after rendering exists'
assert_grep 'v1 text' "$DIR/v1.md" 'rendering carries the after text'
D1=$(jq -r .digest "$DIR/v1.json")
out=$(tool submit media "$TMP_ROOT/p1.json"); assert_contains "$out" 'unchanged' 'identical resubmission is idempotent'
[ ! -e "$DIR/v2.json" ] || fail 'idempotent resubmission wrote a version'
pass 'submit opens one card and an identical resubmission is a no-op'

printf '{"schema":"fm-domain-proposal.v1","mate":"media","bundle_id":"%s","bullets":["x"],"changes":[{"kind":"skill","file":"f","original_digest":"nothex","before":"a","after":"b","always_loaded_size_delta":0,"sources":["https://e.x"],"effect":"e"}]}' \
  "$BUNDLE" > "$TMP_ROOT/bad.json"
tool submit media "$TMP_ROOT/bad.json" >/dev/null 2>&1; expect_code 1 "$?" 'invalid digest is refused'
proposal 'x' otherbundle > "$TMP_ROOT/bad2.json"
tool submit media "$TMP_ROOT/bad2.json" >/dev/null 2>&1; expect_code 1 "$?" 'unrequested bundle is refused'
tool submit media "$TMP_ROOT/p1.json" --corr 0123456789abcdef >/dev/null 2>&1; expect_code 1 "$?" 'obsolete correlation option is refused'
pass 'submit refuses malformed or unrequested proposals'

tool approve media >/dev/null 2>&1; expect_code 2 "$?" 'approve before an answer'
for field in before after; do
  for value in $'text\rmore' $'text\r\nmore'; do
    jq --arg field "$field" --arg value "$value" '.changes[0][$field] = $value' "$TMP_ROOT/p1.json" > "$TMP_ROOT/unsafe-change.json"
    out=$(tool submit media "$TMP_ROOT/unsafe-change.json" 2>&1); rc=$?
    expect_code 1 "$rc" 'change text with a carriage return is refused'
    [[ "$out" != *$'\n'* ]] || fail 'carriage-return refusal was not one line'
    [ ! -e "$DIR/v2.json" ] || fail 'carriage-return change published a proposal version'
  done
done
pass 'carriage returns in exact before or after text are refused'
proposal $'v2 text\n~~~~\n ~~~~~\n   ~~~~~~\nfinish' > "$TMP_ROOT/p2.json"
tool submit media "$TMP_ROOT/p2.json" >/dev/null || fail 'submit v2 failed'
grep -xF '~~~~~~~' "$DIR/v2.md" >/dev/null || fail 'indented closing fence did not get a safe delimiter'
assert_grep '   ~~~~~~' "$DIR/v2.md" 'indented proposed text was not preserved'
D2=$(jq -r .digest "$DIR/v2.json")
assert_not_equals "$D1" "$D2" 'versions have distinct digests'
hold_tool open "$TASK" || fail 'v2 re-hold closed the card'
[ "$(find "$HOME_DIR/data/domain-freshness/proposals/media" -name 'request.json' | wc -l)" -eq 1 ] || fail 'second card or cycle was created'
answer "$TASK" "approve-$D1"
out=$(tool approve media 2>&1); rc=$?
expect_code 3 "$rc" 'approval of an older digest authorizes nothing'
assert_contains "$out" 'stale' 'stale approval is named'
[ ! -s "$DIR/receipts.jsonl" ] || [ ! -e "$DIR/receipts.jsonl" ] || fail 'stale approval wrote a receipt'
pass 'a newer version re-holds one card and an older digest approval is refused'

out=$(tool request media "$BUNDLE"); assert_contains "$out" 'cycle 2' 'answered cycle starts a new cycle'
proposal 'cycle2 text' > "$TMP_ROOT/p3.json"
tool submit media "$TMP_ROOT/p3.json" >/dev/null || fail 'submit cycle 2 failed'
D3=$(jq -r .digest "$HOME_DIR/data/domain-freshness/proposals/media/2/v1.json")
answer domain-proposal-media-2 "approve-$D3"
out=$(tool request media "$BUNDLE" 2>&1); rc=$?
expect_code 1 "$rc" 'an answered approval stays on its current cycle'
assert_contains "$out" 'activation is pending' 'pending approval is disclosed'
[ ! -d "$HOME_DIR/data/domain-freshness/proposals/media/3" ] || fail 'request advanced past an answered approval'
out=$(tool approve media) || fail 'approve failed on a matching answer'
assert_contains "$(PATH="$FAKEBIN:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" bash "$ROOT/bin/fm-tasks-axi.sh" show domain-proposal-media-2 --full)" 'state: queued' 'approval did not preserve the activation task'
assert_contains "$out" "digest $D3" 'application request binds the digest'
assert_contains "$out" 'cycle2 text' 'application request carries only approved after text'
assert_contains "$out" 'original_digest=absent' 'application request carries the precondition'
tool request media "$BUNDLE" >/dev/null 2>&1; expect_code 1 "$?" 'approved activation blocks another request'
out=$(tool receipt media applied --evidence 'file written' 2>&1); rc=$?
expect_code 1 "$rc" 'application receipt requires an explicit digest'
assert_contains "$out" 'receipt requires --digest' 'missing digest refusal is clear'
jq -es 'all(.[]; .state == "approved")' "$HOME_DIR/data/domain-freshness/proposals/media/2/receipts.jsonl" >/dev/null \
  || fail 'missing digest wrote an applied receipt'
tool receipt media applied --digest "$D3" --evidence 'file written' >/dev/null || fail 'applied receipt failed'
tool receipt media applied --digest "$D3" >/dev/null || fail 'repeated receipt is not idempotent'
tool receipt media validated >/dev/null 2>&1; expect_code 1 "$?" 'extra receipt state is refused'
jq -es --arg b "$BUNDLE" --arg d "$D3" 'all(.[]; .bundle_id == $b and .digest == $d and (has("corr") | not))' \
  "$HOME_DIR/data/domain-freshness/proposals/media/2/receipts.jsonl" >/dev/null \
  || fail 'receipts did not retain the approved bundle and digest'
tool receipt media applied --digest "$D1" >/dev/null 2>&1; expect_code 1 "$?" 'receipt for an unapproved digest is refused'
pass 'approval stays current until its digest-bound application closes the task'

proposal 'rejected text' > "$TMP_ROOT/p4.json"
tool request media "$BUNDLE" >/dev/null
tool submit media "$TMP_ROOT/p4.json" >/dev/null || fail 'submit cycle 3 failed'
answer domain-proposal-media-3 reject
tool approve media >/dev/null 2>&1; expect_code 4 "$?" 'rejection authorizes nothing'
pass 'a rejected proposal stays inactive'

jq -n --arg b "$BUNDLE" '{schema:"fm-domain-proposal.v1",mate:"media",bundle_id:$b,bullets:["No action needed"],changes:[]}' > "$TMP_ROOT/p5.json"
tool request media "$BUNDLE" >/dev/null
out=$(tool submit media "$TMP_ROOT/p5.json"); assert_contains "$out" 'no-change' 'no change opens no card'
out=$(tool submit media "$TMP_ROOT/p5.json"); assert_contains "$out" 'no-change' 'closed zero-change replay is idempotent'
[ ! -e "$HOME_DIR/data/domain-freshness/proposals/media/4/v2.json" ] || fail 'zero-change replay wrote a new version'
tool submit media "$TMP_ROOT/p4.json" >/dev/null 2>&1; expect_code 1 "$?" 'a different closed-cycle proposal is refused'
assert_contains "$(tool receipt media applied --digest "$D3" 2>&1)" 'no approved receipt' 'withdrawal does not approve application'
pass 'a no-change proposal records a version and opens no card'

printf '%s\n' '- media - Media mate (host: remote-host; root: /x/code; home: /x/media; scope: remote scope; projects: -; added 2026-10-13)' > "$HOME_DIR/data/secondmates.md"
out=$(tool request media "$BUNDLE" 2>&1); rc=$?
expect_code 1 "$rc" 'remote route is refused'
assert_contains "$out" 'remote domain handoff is not yet supported' 'remote refusal is clear'
rm "$HOME_DIR/data/secondmates.md"
out=$(tool request media "$BUNDLE" 2>&1); rc=$?
expect_code 1 "$rc" 'unavailable current route is refused'
assert_contains "$out" 'current mate route is unavailable' 'route read failure is clear'
printf '%s\n' '- media - Media mate (home: /x/media; scope: newsletter and SEO; projects: -; added 2026-10-13)' > "$HOME_DIR/data/secondmates.md"
pass 'current registration controls local handoff and scope'

tool request media "$BUNDLE" >/dev/null
proposal 'withdraw this' > "$TMP_ROOT/withdraw.json"
tool submit media "$TMP_ROOT/withdraw.json" >/dev/null || fail 'withdrawal setup failed'
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
tool submit media "$TMP_ROOT/p5.json" >/dev/null 2>&1; expect_code 1 "$?" 'failed withdrawal close is reported'
tool submit media "$TMP_ROOT/p5.json" >/dev/null || fail 'withdrawal failed'
rm "$FAKEBIN/tasks-axi"
out=$(PATH="$FAKEBIN:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" bash "$ROOT/bin/fm-tasks-axi.sh" show domain-proposal-media-5 --full)
assert_contains "$out" 'state: done' 'withdrawal did not close held task'
assert_contains "$out" 'withdrawn' 'withdrawal evidence was not recorded'
pass 'zero-change revision closes the held task with evidence'

tool request media "$BUNDLE" >/dev/null
head -c 150000 /dev/zero | tr '\0' x > "$TMP_ROOT/large.txt"
jq -n --rawfile after "$TMP_ROOT/large.txt" --arg b "$BUNDLE" '{schema:"fm-domain-proposal.v1",mate:"media",bundle_id:$b,
  bullets:["Large exact change"],changes:[{kind:"rule",file:"/x/media/RULE.md",original_digest:"absent",before:"",after:$after,
  always_loaded_size_delta:0,sources:["https://github.com/example/repo/pull/1"],effect:"rule updated"}]}' > "$TMP_ROOT/large.json"
tool submit media "$TMP_ROOT/large.json" >/dev/null || fail 'large proposal was not accepted'
jq -e '.proposal.changes[0].after | length == 150000' "$HOME_DIR/data/domain-freshness/proposals/media/6/v1.json" >/dev/null \
  || fail 'large proposal version was truncated'
pass 'large proposals persist a complete version and report'

answer domain-proposal-media-6 reject
tool request media "$BUNDLE" >/dev/null
proposal 'approved first version' > "$TMP_ROOT/approved-first.json"
tool submit media "$TMP_ROOT/approved-first.json" >/dev/null || fail 'first version setup failed'
D7=$(jq -r .digest "$HOME_DIR/data/domain-freshness/proposals/media/7/v1.json")
answer domain-proposal-media-7 "approve-$D7"
tool approve media >/dev/null || fail 'first version approval failed'
proposal 'pending second version' > "$TMP_ROOT/pending-second.json"
tool submit media "$TMP_ROOT/pending-second.json" >/dev/null || fail 'second version submission failed'
hold_tool open domain-proposal-media-7 || fail 'second version is not held'
tool receipt media applied --digest "$D7" --evidence 'first version applied' >/dev/null || fail 'first receipt failed'
hold_tool open domain-proposal-media-7 || fail 'first receipt closed the newer pending version'
tool receipt media applied --digest "$D7" >/dev/null || fail 'repeat first receipt failed'
hold_tool open domain-proposal-media-7 || fail 'repeat receipt closed the newer pending version'
pass 'older application receipts preserve a newer captain hold'

out=$(tool request media "$BUNDLE2") || fail 'request remained blocked by an applied historical approval'
assert_contains "$out" 'cycle 7' 'new evidence should remain on the open cycle'
jq -e --arg b "$BUNDLE2" '.latest_bundle_id == $b' "$HOME_DIR/data/domain-freshness/proposals/media/7/request.json" >/dev/null \
  || fail 'new bundle was not recorded as latest'
out=$(tool submit media "$TMP_ROOT/pending-second.json" 2>&1); rc=$?
expect_code 1 "$rc" 'delayed proposal for older bundle is refused'
assert_contains "$out" 'not the latest requested bundle' 'stale bundle refusal is clear'
proposal 'current bundle proposal' "$BUNDLE2" > "$TMP_ROOT/current-bundle.json"
tool submit media "$TMP_ROOT/current-bundle.json" >/dev/null || fail 'current bundle proposal failed'
hold_tool open domain-proposal-media-7 || fail 'current bundle did not keep the one held task'
answer domain-proposal-media-7 reject
pass 'latest requested bundle binds proposal replies on the same cycle'

tool request media "$BUNDLE" >/dev/null || fail 'new cycle after applied approval failed'
proposal 'approved but outstanding' > "$TMP_ROOT/outstanding.json"
tool submit media "$TMP_ROOT/outstanding.json" >/dev/null || fail 'outstanding approval setup failed'
D8=$(jq -r .digest "$HOME_DIR/data/domain-freshness/proposals/media/8/v1.json")
answer domain-proposal-media-8 "approve-$D8"
tool approve media >/dev/null || fail 'outstanding approval failed'
proposal 'later rejected version' > "$TMP_ROOT/later-rejected.json"
tool submit media "$TMP_ROOT/later-rejected.json" >/dev/null || fail 'later version submission failed'
answer domain-proposal-media-8 reject
proposal 'refreshed after rejection' > "$TMP_ROOT/refreshed.json"
tool submit media "$TMP_ROOT/refreshed.json" >/dev/null || fail 'refresh after a rejected newer version was refused'
hold_tool open domain-proposal-media-8 || fail 'refreshed version did not reopen the activation task'
answer domain-proposal-media-8 reject
out=$(tool request media "$BUNDLE2" 2>&1); rc=$?
expect_code 1 "$rc" 'unapplied earlier approval blocks a new cycle'
assert_contains "$out" 'activation is pending' 'outstanding earlier approval is disclosed'
[ ! -d "$HOME_DIR/data/domain-freshness/proposals/media/9" ] || fail 'outstanding approval allowed a new cycle'
tool receipt media applied --digest "$D8" --evidence 'earlier approved version applied' >/dev/null || fail 'outstanding receipt failed'
out=$(tool request media "$BUNDLE2") || fail 'applied earlier approval failed to unblock a new cycle'
assert_contains "$out" 'cycle 9' 'new cycle did not start after all approvals were applied'
pass 'new-cycle gate checks every approved digest for application'

proposal 'prefix answer' "$BUNDLE2" > "$TMP_ROOT/prefix.json"
tool submit media "$TMP_ROOT/prefix.json" >/dev/null || fail 'prefix refusal setup failed'
D9=$(jq -r .digest "$HOME_DIR/data/domain-freshness/proposals/media/9/v1.json")
answer domain-proposal-media-9 "approve-${D9:0:12}"
out=$(tool approve media 2>&1); rc=$?
expect_code 3 "$rc" 'a digest prefix cannot approve a version'
assert_contains "$out" 'stale' 'prefix-only approval is stale'
[ ! -s "$HOME_DIR/data/domain-freshness/proposals/media/9/receipts.jsonl" ] \
  || fail 'prefix-only answer wrote an approval receipt'
pass 'approval requires the full version digest'

tool request media "$BUNDLE2" >/dev/null || fail 'released-answer setup request failed'
proposal 'released answer' "$BUNDLE2" > "$TMP_ROOT/released.json"
tool submit media "$TMP_ROOT/released.json" >/dev/null || fail 'released-answer setup proposal failed'
D10=$(jq -r .digest "$HOME_DIR/data/domain-freshness/proposals/media/10/v1.json")
printf 'approve-%s\n' "$D10" > "$TMP_ROOT/answer"
hold_tool answer domain-proposal-media-10 --decision-file "$TMP_ROOT/answer" --release >/dev/null \
  || fail 'released-answer setup failed'
out=$(tool approve media 2>&1); rc=$?
expect_code 4 "$rc" 'a released decision cannot authorize application'
assert_contains "$out" 'resolution mode is released' 'released answer is rejected'
[ ! -s "$HOME_DIR/data/domain-freshness/proposals/media/10/receipts.jsonl" ] \
  || fail 'released answer wrote an approval receipt'
pass 'only an answered captain decision authorizes application'

PATH="$FAKEBIN:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  bash "$ROOT/bin/fm-tasks-axi.sh" "done" domain-proposal-media-10 --note 'released cycle closed by the fixture' >/dev/null || fail 'fixture could not close the released cycle'
tool request media "$BUNDLE" >/dev/null || fail 'refresh scenario request failed'
proposal 'refresh v1' > "$TMP_ROOT/r1.json"
tool submit media "$TMP_ROOT/r1.json" >/dev/null || fail 'refresh v1 failed'
R1=$(jq -r .digest "$HOME_DIR/data/domain-freshness/proposals/media/11/v1.json")
answer domain-proposal-media-11 "approve-$R1"
tool approve media >/dev/null || fail 'refresh v1 approval failed'
proposal 'refresh v2' > "$TMP_ROOT/r2.json"
tool submit media "$TMP_ROOT/r2.json" >/dev/null || fail 'refresh v2 failed'
R2=$(jq -r .digest "$HOME_DIR/data/domain-freshness/proposals/media/11/v2.json")
answer domain-proposal-media-11 "approve-$R2"
tool approve media >/dev/null || fail 'refresh v2 approval failed'
tool receipt media applied --digest "$R2" --evidence 'refreshed version applied' >/dev/null || fail 'refresh v2 receipt failed'
jq -se --arg d "$R1" 'any(.[]; .state == "applied" and (.superseded | index($d) != null))' \
  "$HOME_DIR/data/domain-freshness/proposals/media/11/receipts.jsonl" >/dev/null || fail 'receipt did not record the superseded approval'
out=$(tool request media "$BUNDLE2") || fail 'a superseded approval still blocks a new cycle'
assert_contains "$out" 'cycle 12' 'new cycle starts after the refreshed version applied'
pass 'an applied receipt retires older unapplied approvals'

proposal 'card v1' > "$TMP_ROOT/c1.json"
tool submit media "$TMP_ROOT/c1.json" >/dev/null 2>&1 && fail 'card v1 used the stale bundle'
proposal 'card v1' "$BUNDLE2" > "$TMP_ROOT/c1.json"
tool submit media "$TMP_ROOT/c1.json" >/dev/null || fail 'card v1 failed'
proposal 'card v2' "$BUNDLE2" > "$TMP_ROOT/c2.json"
cat > "$FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "$1" = hold ] && [ -f "$FM_HOME/state/fail-domain-hold-once" ]; then
  rm "$FM_HOME/state/fail-domain-hold-once"
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
SH
chmod +x "$FAKEBIN/tasks-axi"
: > "$HOME_DIR/state/fail-domain-hold-once"
tool submit media "$TMP_ROOT/c2.json" >/dev/null 2>&1; expect_code 1 "$?" 'failed card update is reported'
rm "$FAKEBIN/tasks-axi"
C2=$(jq -r .digest "$HOME_DIR/data/domain-freshness/proposals/media/12/v2.json")
out=$(tool submit media "$TMP_ROOT/c2.json") || fail 'retry of the failed card update failed'
assert_contains "$out" "held: domain-proposal-media-12 v2 digest $C2" 'retry re-ran the missing hold'
out=$(tool submit media "$TMP_ROOT/c2.json"); assert_contains "$out" 'unchanged' 'bound card makes resubmission unchanged'
shown=$(PATH="$FAKEBIN:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" bash "$ROOT/bin/fm-tasks-axi.sh" show domain-proposal-media-12 --full)
assert_contains "$shown" "$C2" 'card is bound to the newest digest'
pass 'identical resubmission re-runs a hold that failed'

answer domain-proposal-media-12 reject
tool request media "$BUNDLE2" >/dev/null || fail 'withdrawal scenario request failed'
proposal 'approved then withdrawn' "$BUNDLE2" > "$TMP_ROOT/w1.json"
tool submit media "$TMP_ROOT/w1.json" >/dev/null || fail 'withdrawal v1 failed'
W1=$(jq -r .digest "$HOME_DIR/data/domain-freshness/proposals/media/13/v1.json")
answer domain-proposal-media-13 "approve-$W1"
tool approve media >/dev/null || fail 'withdrawal v1 approval failed'
jq -n --arg b "$BUNDLE2" '{schema:"fm-domain-proposal.v1",mate:"media",bundle_id:$b,bullets:["Withdrawn"],changes:[]}' > "$TMP_ROOT/w2.json"
out=$(tool submit media "$TMP_ROOT/w2.json") || fail 'zero-change after approval failed'
assert_contains "$out" 'withdrawn' 'withdrawal is recorded'
shown=$(PATH="$FAKEBIN:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" bash "$ROOT/bin/fm-tasks-axi.sh" show domain-proposal-media-13 --full)
assert_not_contains "$shown" 'state: done' 'withdrawal closed an outstanding activation task'
tool receipt media applied --digest "$W1" --evidence 'approved version applied' >/dev/null || fail 'withdrawal v1 receipt failed'
shown=$(PATH="$FAKEBIN:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" bash "$ROOT/bin/fm-tasks-axi.sh" show domain-proposal-media-13 --full)
assert_contains "$shown" 'state: done' 'receipt did not close the activation task'
pass 'a zero-change revision keeps an approved activation task open'

tool request media "$BUNDLE2" >/dev/null || fail 'multiple-approval withdrawal request failed'
proposal 'first approved change' "$BUNDLE2" > "$TMP_ROOT/multi-first.json"
tool submit media "$TMP_ROOT/multi-first.json" >/dev/null || fail 'first multiple-approval submission failed'
M1=$(jq -r .digest "$HOME_DIR/data/domain-freshness/proposals/media/14/v1.json")
answer domain-proposal-media-14 "approve-$M1"
tool approve media >/dev/null || fail 'first multiple-approval decision failed'
proposal 'second approved change' "$BUNDLE2" > "$TMP_ROOT/multi-second.json"
tool submit media "$TMP_ROOT/multi-second.json" >/dev/null || fail 'second multiple-approval submission failed'
M2=$(jq -r .digest "$HOME_DIR/data/domain-freshness/proposals/media/14/v2.json")
answer domain-proposal-media-14 "approve-$M2"
tool approve media >/dev/null || fail 'second multiple-approval decision failed'
tool submit media "$TMP_ROOT/w2.json" >/dev/null || fail 'multiple-approval withdrawal failed'
jq -e '.proposal.changes == []' "$HOME_DIR/data/domain-freshness/proposals/media/14/v3.json" >/dev/null \
  || fail 'withdrawal was not recorded as a zero-change version'
jq -es 'all(.[]; .state == "approved")' "$HOME_DIR/data/domain-freshness/proposals/media/14/receipts.jsonl" >/dev/null \
  || fail 'withdrawal added a redundant receipt'
pass 'a zero-change version records withdrawal without a separate receipt'

tool receipt media applied --digest "$M1" --evidence 'first approved change applied' >/dev/null || fail 'first multiple-approval receipt failed'
shown=$(PATH="$FAKEBIN:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" bash "$ROOT/bin/fm-tasks-axi.sh" show domain-proposal-media-14 --full)
assert_not_contains "$shown" 'state: done' 'first receipt closed the outstanding second approval'
tool receipt media applied --digest "$M1" >/dev/null || fail 'repeat first multiple-approval receipt failed'
shown=$(PATH="$FAKEBIN:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" bash "$ROOT/bin/fm-tasks-axi.sh" show domain-proposal-media-14 --full)
assert_not_contains "$shown" 'state: done' 'repeat first receipt closed the outstanding second approval'
tool receipt media applied --digest "$M2" --evidence 'second approved change applied' >/dev/null || fail 'second multiple-approval receipt failed'
shown=$(PATH="$FAKEBIN:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" bash "$ROOT/bin/fm-tasks-axi.sh" show domain-proposal-media-14 --full)
assert_contains "$shown" 'state: done' 'final approval receipt did not close the activation task'
pass 'first and repeat receipts preserve each outstanding approval'

tool request media "$BUNDLE2" >/dev/null || fail 'repeated-digest request failed'
proposal 'first digest content' "$BUNDLE2" > "$TMP_ROOT/digest-first.json"
tool submit media "$TMP_ROOT/digest-first.json" >/dev/null || fail 'first digest submission failed'
S1=$(jq -r .digest "$HOME_DIR/data/domain-freshness/proposals/media/15/v1.json")
answer domain-proposal-media-15 "approve-$S1"
tool approve media >/dev/null || fail 'first digest approval failed'
proposal 'second digest content' "$BUNDLE2" > "$TMP_ROOT/digest-second.json"
tool submit media "$TMP_ROOT/digest-second.json" >/dev/null || fail 'second digest submission failed'
S2=$(jq -r .digest "$HOME_DIR/data/domain-freshness/proposals/media/15/v2.json")
answer domain-proposal-media-15 "approve-$S2"
tool approve media >/dev/null || fail 'second digest approval failed'
out=$(tool submit media "$TMP_ROOT/digest-first.json" 2>&1); rc=$?
expect_code 1 "$rc" 'an earlier digest cannot become a new version'
assert_contains "$out" 'change it or start a new cycle' 'repeated-digest refusal offers a next step'
[[ "$out" != *$'\n'* ]] || fail 'repeated-digest refusal was not one line'
[ ! -e "$HOME_DIR/data/domain-freshness/proposals/media/15/v3.json" ] || fail 'repeated digest created a version'
tool receipt media applied --digest "$S2" --evidence 'second digest applied' >/dev/null || fail 'latest digest receipt failed'
jq -se --arg d "$S1" 'any(.[]; .state == "applied" and (.superseded | index($d) != null))' \
  "$HOME_DIR/data/domain-freshness/proposals/media/15/receipts.jsonl" >/dev/null || fail 'latest application did not retire the earlier approval'
pass 'a cycle refuses reuse of an earlier proposal digest'

tool request media "$BUNDLE2" >/dev/null || fail 'multiline-answer request failed'
proposal 'conditional answer' "$BUNDLE2" > "$TMP_ROOT/conditional.json"
tool submit media "$TMP_ROOT/conditional.json" >/dev/null || fail 'multiline-answer submission failed'
C1=$(jq -r .digest "$HOME_DIR/data/domain-freshness/proposals/media/16/v1.json")
printf -v conditional_answer 'approve-%s\n\nOnly after another review' "$C1"
answer domain-proposal-media-16 "$conditional_answer"
out=$(tool approve media 2>&1); rc=$?
expect_code 4 "$rc" 'a multiline conditional answer cannot approve a version'
assert_contains "$out" 'not-approved' 'conditional answer needs a decision'
[ ! -s "$HOME_DIR/data/domain-freshness/proposals/media/16/receipts.jsonl" ] \
  || fail 'conditional answer wrote an approval receipt'
out=$(tool request media "$BUNDLE2") || fail 'conditional answer blocked a new cycle'
assert_contains "$out" 'cycle 17' 'conditional answer was treated as exact approval at the new-cycle check'
proposal 'whitespace answer' "$BUNDLE2" > "$TMP_ROOT/whitespace.json"
tool submit media "$TMP_ROOT/whitespace.json" >/dev/null || fail 'whitespace-answer submission failed'
C2=$(jq -r .digest "$HOME_DIR/data/domain-freshness/proposals/media/17/v1.json")
answer domain-proposal-media-17 "  approve-$C2  "
tool approve media >/dev/null || fail 'surrounding whitespace prevented an exact approval'
pass 'only the complete trimmed captain answer authorizes application'

mkdir -p "$TMP_ROOT/mate/state"
printf 'media\n' > "$TMP_ROOT/mate/.fm-secondmate-home"
FM_HOME="$TMP_ROOT/mate" bash "$TOOL" request media "$BUNDLE" >/dev/null 2>&1; expect_code 1 "$?" 'a non-main home is refused'
pass 'secondmate homes cannot own proposals'
