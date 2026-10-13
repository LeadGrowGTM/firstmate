#!/usr/bin/env bash
# Manual domain freshness collection through its public collect command.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'skip: python3 not found'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-domain-freshness)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
COLLECTOR="$ROOT/bin/fm-domain-freshness.sh"
NOW=2026-10-13T12:00:00Z
MERGE_SHA=1111111111111111111111111111111111111111
PARENT_SHA=2222222222222222222222222222222222222222
PARENT_TREE=3333333333333333333333333333333333333333
MERGE_TREE=4444444444444444444444444444444444444444
BASE_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
FILE_SHA=cccccccccccccccccccccccccccccccccccccccc
N=0
cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
set -eu
[ "$#" -eq 6 ] && [ "$1" = api ] && [ "$2" = GET ] && [ "$4" = --jq ] && [ "$5" = @base64 ] && [ "$6" = --full ] || exit 91
path=$3
printf '%s\n' "$path" >> "$FM_FAKE_FEED/requests"
if [ -f "$FM_FAKE_FEED/shift" ] && [[ "$path" == *'page=2' ]]; then
  kind=$(cat "$FM_FAKE_FEED/shift")
  if [[ "$path" == *"/$kind?"* ]]; then
    mv "$FM_FAKE_FEED/$kind-1-shift.json" "$FM_FAKE_FEED/$kind-1.json"
    mv "$FM_FAKE_FEED/$kind-2-shift.json" "$FM_FAKE_FEED/$kind-2.json"
    rm "$FM_FAKE_FEED/shift"
  fi
fi
case "$path" in
  /repos/*/commits/*/pulls\?*)
    name=${path#*/commits/}; name=${name%%/*}
    page=${path##*page=}
    file="$FM_FAKE_FEED/associated-$name-$page.json" ;;
  /repos/*/pulls\?*)
    page=${path##*page=}
    file="$FM_FAKE_FEED/pulls-$page.json" ;;
  /repos/*/issues\?*)
    page=${path##*page=}
    file="$FM_FAKE_FEED/issues-$page.json" ;;
  /repos/*/pulls/*/files\?*)
    number=${path#*/pulls/}; number=${number%%/*}
    page=${path##*page=}
    file="$FM_FAKE_FEED/files-$number-$page.json" ;;
  /repos/*/contents/*\?ref=*)
    name=${path#*/contents/}; name=${name%%\?*}; name=${name##*/}
    revision=${path##*ref=}
    file="$FM_FAKE_FEED/content-$revision-$name.json" ;;
  /repos/*/git/blobs/*)
    file="$FM_FAKE_FEED/blob-${path##*/}.json" ;;
  /repos/*/git/commits/*)
    file="$FM_FAKE_FEED/commit-${path##*/}.json" ;;
  /repos/*/git/trees/*\?recursive=1)
    name=${path##*/}; name=${name%%\?*}
    file="$FM_FAKE_FEED/tree-$name.json" ;;
  /repos/*/pulls/*)
    number=${path##*/}
    file="$FM_FAKE_FEED/detail-$number.json" ;;
  *) exit 92 ;;
esac
[ ! -e "$FM_FAKE_FEED/fail" ] || { grep -Fqx "$path" "$FM_FAKE_FEED/fail" && exit 93 || :; }
if [[ "$path" == /repos/*/git/blobs/* ]]; then
  if [ -f "$file.failure" ]; then
    case "$(cat "$file.failure")" in
      timeout) printf 'request timed out\n' >&2; exit 124 ;;
      server) printf 'HTTP 503: Service Unavailable\n' >&2; exit 1 ;;
    esac
  fi
  if [ ! -f "$file" ]; then
    printf 'HTTP 404: Not Found\n' >&2
    exit 1
  fi
fi
if [ -f "$file" ]; then
  body=$(base64 < "$file" | tr -d '\n')
else
  body=$(printf '[]' | base64 | tr -d '\n')
fi
printf 'api_response:\n  body: %s\n  truncated: false\n' "$body"
SH
chmod +x "$FAKEBIN/gh-axi"

new_home() {
  N=$((N + 1))
  HOME_DIR="$TMP_ROOT/home-$N"
  FEED="$HOME_DIR/forge"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/data" "$FEED"
  : > "$FEED/requests"
}

config() { # sources JSON
  jq -n --argjson sources "$1" \
    '{version:1,enabled:true,sources:$sources}' > "$HOME_DIR/config/domain-freshness.json"
}

collect() { # home, time; exposes status and output, saves stderr in scratch
  local home=$1 now=$2
  PATH="$FAKEBIN:$PATH" FM_FAKE_FEED="$home/forge" FM_HOME="$home" \
    FM_DOMAIN_FRESHNESS_NOW="$now" bash "$COLLECTOR" collect \
    > "$TMP_ROOT/stdout" 2> "$TMP_ROOT/stderr"
  STATUS=$?
  OUT=$(cat "$TMP_ROOT/stdout")
}

bundle() {
  [ -n "$OUT" ] && [ -f "$OUT" ] || fail 'collector did not print an existing bundle'
  case "$OUT" in "$HOME_DIR"/data/domain-freshness/bundles/*.json) ;; *) fail 'bundle path is not absolute and home-scoped' ;; esac
  jq -e '.schema == "fm-domain-evidence.v1" and (.domains | type == "array") and (.coverage | type == "array") and (.evidence | type == "array")' "$OUT" >/dev/null || fail 'bundle schema missing'
}

repo_sources='[{"id":"forge","kind":"repository","repo":"acme/widgets"}]'
pr() { # number, merged time, updated time
  jq -n --argjson n "$1" --arg when "$2" --arg updated "$3" \
    '{number:$n,html_url:("https://github.com/acme/widgets/pull/"+($n|tostring)),title:"Shared change",labels:[],merged_at:$when,updated_at:$updated}'
}
detail() { # number, merged time, changed count
  jq -n --argjson n "$1" --arg when "$2" --argjson count "$3" --arg base "$BASE_SHA" --arg head "$HEAD_SHA" \
    '{html_url:("https://github.com/acme/widgets/pull/"+($n|tostring)),merged_at:$when,changed_files:$count,base:{ref:"main",sha:$base,repo:{full_name:"acme/widgets"}},head:{ref:"topic",sha:$head,repo:{full_name:"acme/widgets"}}}'
}
pr_file() {
  jq -n --arg path "$1" --arg status "$2" --arg old "${3:-}" --arg sha "$FILE_SHA" \
    '{filename:$path,status:$status,sha:$sha,additions:(if $status == "removed" then 0 else 1 end),deletions:(if $status == "removed" then 1 else 0 end),changes:1,blob_url:("https://github.com/acme/widgets/blob/"+$sha+"/"+$path),raw_url:("https://github.com/acme/widgets/raw/"+$sha+"/"+$path)} + (if $old == "" then {} else {previous_filename:$old} end)'
}
merge_history() {
  local number=$1 parents=${2:-2} scratch="$FEED/detail-history.json"
  jq --arg merge "$MERGE_SHA" --argjson count "$parents" '.merge_commit_sha = $merge | .commits = $count' "$FEED/detail-$number.json" > "$scratch"
  mv "$scratch" "$FEED/detail-$number.json"
  jq -n --arg sha "$PARENT_SHA" --arg tree "$PARENT_TREE" '{sha:$sha,tree:{sha:$tree},parents:[]}' > "$FEED/commit-$PARENT_SHA.json"
  if [ "$parents" -eq 2 ]; then
    jq -n --arg sha "$MERGE_SHA" --arg tree "$MERGE_TREE" --arg parent "$PARENT_SHA" '{sha:$sha,tree:{sha:$tree},parents:[{sha:$parent},{sha:"5555555555555555555555555555555555555555"}]}' > "$FEED/commit-$MERGE_SHA.json"
  else
    jq -n --arg sha "$MERGE_SHA" --arg tree "$MERGE_TREE" --arg parent "$PARENT_SHA" '{sha:$sha,tree:{sha:$tree},parents:[{sha:$parent}]}' > "$FEED/commit-$MERGE_SHA.json"
  fi
  jq -n --arg sha "$PARENT_TREE" '{sha:$sha,truncated:false,tree:[]}' > "$FEED/tree-$PARENT_TREE.json"
  jq -n --arg sha "$MERGE_TREE" '{sha:$sha,truncated:false,tree:[]}' > "$FEED/tree-$MERGE_TREE.json"
}
tree_content() {
  local tree=$1 path=$2 content=$3 blob scratch="$FEED/tree-update.json"
  blob=$(printf '%s' "$content" | git hash-object --stdin)
  jq -n --arg sha "$blob" --arg content "$(printf '%s' "$content" | base64 | tr -d '\n')" '{sha:$sha,encoding:"base64",content:$content}' > "$FEED/blob-$blob.json"
  jq --arg path "$path" --arg sha "$blob" '.tree += [{path:$path,sha:$sha,type:"blob",mode:"100644"}]' "$FEED/tree-$tree.json" > "$scratch"
  mv "$scratch" "$FEED/tree-$tree.json"
}
issue() { # number, created time
  jq -n --argjson n "$1" --arg when "$2" \
    '{number:$n,html_url:("https://github.com/acme/widgets/issues/"+($n|tostring)),title:"New question",labels:[],created_at:$when}'
}

new_home
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'absent configuration'
assert_equals '' "$OUT" 'absent configuration must be silent'
assert_absent "$HOME_DIR/data/domain-freshness" 'absent configuration wrote state'
printf '{"version":1,"enabled":false,"sources":[]}\n' > "$HOME_DIR/config/domain-freshness.json"
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'disabled configuration'
assert_equals '' "$OUT" 'disabled configuration must be silent'
pass 'absent and disabled configuration are silent'

new_home
printf '%s\n' '{"version":true,"enabled":true,"sources":[]}' > "$HOME_DIR/config/domain-freshness.json"
collect "$HOME_DIR" "$NOW"
expect_code 1 "$STATUS" 'boolean config version'
assert_grep 'config requires version:1' "$TMP_ROOT/stderr" 'boolean config version was accepted'
assert_absent "$HOME_DIR/data/domain-freshness" 'invalid config wrote collector state'
pass 'configuration version requires an integer'

new_home
mkdir -p "$HOME_DIR/skills"
printf '# Available\n' > "$HOME_DIR/skills/SKILL.md"
jq -n --arg root "$HOME_DIR/skills" '{version:1,enabled:false,sources:[{id:"skills",kind:"skills",root:$root}]}' > "$HOME_DIR/config/domain-freshness.json"
NO_JQ_BIN="$TMP_ROOT/no-jq-bin"
BASH_BIN=$(command -v bash)
mkdir -p "$NO_JQ_BIN"
ln -s "$(command -v python3)" "$NO_JQ_BIN/python3"
ln -s "$(command -v dirname)" "$NO_JQ_BIN/dirname"
PATH="$NO_JQ_BIN" FM_HOME="$HOME_DIR" "$BASH_BIN" "$COLLECTOR" inventory skills > "$TMP_ROOT/inventory.json" 2> "$TMP_ROOT/inventory-stderr"
expect_code 0 "$?" 'disabled explicit inventory without jq'
jq -e '.source == "skills" and .inventory["SKILL.md"].content == "# Available\n"' "$TMP_ROOT/inventory.json" >/dev/null || fail 'explicit inventory did not read disabled configured source'
assert_absent "$HOME_DIR/data/domain-freshness" 'explicit inventory wrote collector state'
pass 'disabled configured inventory needs Python but not jq'

PATH="$NO_JQ_BIN" FM_HOME="$HOME_DIR" "$BASH_BIN" "$COLLECTOR" collect > "$TMP_ROOT/probe-stdout" 2> "$TMP_ROOT/probe-stderr"
expect_code 0 "$?" 'disabled collect without jq'
assert_equals '' "$(cat "$TMP_ROOT/probe-stdout")" 'disabled collect emitted output without jq'
assert_absent "$HOME_DIR/data/domain-freshness" 'disabled collect without jq wrote state'
jq '.enabled = true' "$HOME_DIR/config/domain-freshness.json" > "$HOME_DIR/config/domain-freshness-next.json"
mv "$HOME_DIR/config/domain-freshness-next.json" "$HOME_DIR/config/domain-freshness.json"
PATH="$NO_JQ_BIN" FM_HOME="$HOME_DIR" "$BASH_BIN" "$COLLECTOR" collect > "$TMP_ROOT/probe-stdout" 2> "$TMP_ROOT/probe-stderr"
expect_code 1 "$?" 'enabled collect without jq'
assert_grep 'jq is required' "$TMP_ROOT/probe-stderr" 'enabled collect bypassed jq requirement'
printf '%s\n' '{"version":1,"enabled":true,"enabled":false,"sources":[]}' > "$HOME_DIR/config/domain-freshness.json"
PATH="$NO_JQ_BIN" FM_HOME="$HOME_DIR" "$BASH_BIN" "$COLLECTOR" collect > "$TMP_ROOT/probe-stdout" 2> "$TMP_ROOT/probe-stderr"
expect_code 1 "$?" 'duplicate enabled keys'
assert_grep 'duplicate JSON key' "$TMP_ROOT/probe-stderr" 'duplicate enabled keys were accepted'
printf '%s\n' '{"version":1,"enabled":true,"sources":[],"nested":{"enabled":false},"note":"enabled: false"}' > "$HOME_DIR/config/domain-freshness.json"
PATH="$NO_JQ_BIN" FM_HOME="$HOME_DIR" "$BASH_BIN" "$COLLECTOR" collect > "$TMP_ROOT/probe-stdout" 2> "$TMP_ROOT/probe-stderr"
expect_code 1 "$?" 'nested or quoted false with enabled true'
assert_grep 'jq is required' "$TMP_ROOT/probe-stderr" 'nested or quoted false disabled an enabled source'
printf '%s\n' '{"version":1,"enabled":false,"sources":[]}' > "$HOME_DIR/config/domain-freshness.json"
NO_PYTHON_BIN="$TMP_ROOT/no-python-bin"
mkdir -p "$NO_PYTHON_BIN"
ln -s "$(command -v dirname)" "$NO_PYTHON_BIN/dirname"
PATH="$NO_PYTHON_BIN" FM_HOME="$HOME_DIR" "$BASH_BIN" "$COLLECTOR" collect > "$TMP_ROOT/probe-stdout" 2> "$TMP_ROOT/probe-stderr"
expect_code 1 "$?" 'disabled collect without JSON parser'
assert_grep 'python3 is required' "$TMP_ROOT/probe-stderr" 'unvalidated disabled config was treated as safe'
assert_absent "$HOME_DIR/data/domain-freshness" 'dependency probes wrote collector state'
pass 'disabled collect skips jq only after strict configuration validation'

new_home
mkdir -p "$HOME_DIR/skills/one"
printf '# One\n' > "$HOME_DIR/skills/one/SKILL.md"
config "$(jq -nc --arg root "$HOME_DIR/skills" '[{id:"skills",kind:"skills",root:$root}]')"
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'skill baseline'
bundle
jq -e '.complete and .coverage[0].baseline and .evidence[0].kind == "inventory-baseline" and .evidence[0].before == null' "$OUT" >/dev/null || fail 'first skill inventory was not explicit baseline'
collect "$HOME_DIR" 2026-10-14T12:00:00Z
expect_code 0 "$STATUS" 'unchanged inventory'
assert_equals '' "$OUT" 'unchanged inventory should be silent'
printf '# Two\n' > "$HOME_DIR/skills/one/SKILL.md"
collect "$HOME_DIR" 2026-10-15T12:00:00Z
bundle
jq -e '.evidence | length == 1 and .[0].kind == "inventory-change" and .[0].before.content == "# One\n" and .[0].after.content == "# Two\n"' "$OUT" >/dev/null || fail 'skill edit delta missing'
mv "$HOME_DIR/skills/one/SKILL.md" "$HOME_DIR/removed-skill.md"
collect "$HOME_DIR" 2026-10-16T12:00:00Z
bundle
jq -e '.evidence | length == 1 and .[0].kind == "inventory-change" and .[0].after == null' "$OUT" >/dev/null || fail 'skill removal delta missing'
pass 'inventory baseline, change, removal and unchanged silence'

new_home
mkdir -p "$HOME_DIR/plugins"
printf '%s\n' '{"plugins":{"demo":[{"version":"1.0","scope":"user","projectPath":"/clients/example/private-campaign","installPath":"/clients/example/private-campaign/install"}]},"token":"secret-one"}' > "$HOME_DIR/plugins/manifest.json"
printf '%s\n' '{"enabledPlugins":{"demo":true}}' > "$HOME_DIR/plugins/enabled.json"
config "$(jq -nc --arg root "$HOME_DIR/plugins" '[{id:"plugins",kind:"plugin-files",root:$root,files:[{path:"manifest.json",kind:"plugin-manifest"}]}]')"
collect "$HOME_DIR" "$NOW"
bundle
jq -e '(.evidence | length) == 1 and .evidence[0].after.manifest.plugins.demo == [{"version":"1.0"}] and .coverage[0].surfaces == ["plugin-manifest"]' "$OUT" >/dev/null || fail 'plugin baseline did not retain only names and versions'
assert_no_grep 'secret-one' "$OUT" 'irrelevant manifest field persisted in bundle'
assert_no_grep 'private-campaign' "$OUT" 'client path persisted in bundle'
assert_no_grep 'private-campaign' "$HOME_DIR/data/domain-freshness/cursors.json" 'client path persisted in cursor'
FM_HOME="$HOME_DIR" bash "$COLLECTOR" inventory plugins > "$TMP_ROOT/inventory.json" 2> "$TMP_ROOT/inventory-stderr"
expect_code 0 "$?" 'plugin inventory with client path'
assert_no_grep 'private-campaign' "$TMP_ROOT/inventory.json" 'client path persisted in inventory'
printf '%s\n' '{"plugins":{"demo":[{"version":"1.0","scope":"project"}]},"token":"secret-two"}' > "$HOME_DIR/plugins/manifest.json"
printf '%s\n' '{"enabledPlugins":{"demo":false}}' > "$HOME_DIR/plugins/enabled.json"
collect "$HOME_DIR" 2026-10-14T12:00:00Z
assert_equals '' "$OUT" 'uncollected plugin fields changed fingerprint'
printf '%s\n' '{"plugins":{"demo":[{"version":"2.0"}]}}' > "$HOME_DIR/plugins/manifest.json"
collect "$HOME_DIR" 2026-10-15T12:00:00Z
bundle
jq -e '(.evidence | length) == 1 and .evidence[0].after.manifest.plugins.demo == [{"version":"2.0"}] and .evidence[0].before.digest != .evidence[0].after.digest' "$OUT" >/dev/null || fail 'plugin version change absent'
pass 'plugin fingerprints retain names versions and manifest digest only'

new_home
mkdir -p "$HOME_DIR/plugins"
printf '%s\n' '{"plugins":{"demo":[{"version":"1.0"}]}}' > "$HOME_DIR/plugins/manifest.json"
config "$(jq -nc --arg root "$HOME_DIR/plugins" '[{id:"plugins",kind:"plugin-files",root:$root,files:[{path:"manifest.json",kind:"plugin-manifest"},{path:"./manifest.json",kind:"plugin-version"}]}]')"
collect "$HOME_DIR" "$NOW"
expect_code 1 "$STATUS" 'normalized plugin file collision'
assert_grep 'invalid or duplicate inventory filename' "$TMP_ROOT/stderr" 'colliding plugin file paths passed config validation'
assert_absent "$HOME_DIR/data/domain-freshness" 'colliding plugin file paths wrote collector state'
pass 'local configuration rejects paths that normalize to one inventory record'

new_home
mkdir -p "$HOME_DIR/skills/one" "$HOME_DIR/plugins"
printf '# Only skill\n' > "$HOME_DIR/skills/one/SKILL.md"
printf 'private password content' > "$HOME_DIR/skills/one/passwords.md"
printf 'private client secret' > "$HOME_DIR/skills/one/clientsecret.md"
printf 'first script' > "$HOME_DIR/skills/one/run.py"
printf '%s\n' '{"plugins":{}}' > "$HOME_DIR/plugins/manifest.json"
printf 'private token content' > "$HOME_DIR/plugins/token.json"
config "$(jq -nc --arg skills "$HOME_DIR/skills" --arg plugins "$HOME_DIR/plugins" '[
  {id:"skills",kind:"skills",root:$skills},
  {id:"plugins",kind:"plugin-files",root:$plugins,files:[{path:"manifest.json",kind:"plugin-manifest"}]}
]')"
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'narrow inventory baseline'
bundle
jq -e '(.evidence | length) == 2 and all(.evidence[]; .kind == "inventory-baseline") and .coverage[0].surfaces == ["instruction"] and .coverage[1].surfaces == ["plugin-manifest"]' "$OUT" >/dev/null || fail 'narrow inventory included extra surfaces'
for marker in 'private password content' 'private client secret' 'private token content'; do
  assert_no_grep "$marker" "$OUT" 'unselected content entered inventory bundle'
  assert_no_grep "$marker" "$HOME_DIR/data/domain-freshness/cursors.json" 'unselected content entered cursor'
done
printf 'second script' > "$HOME_DIR/skills/one/run.py"
printf 'second private password' > "$HOME_DIR/skills/one/passwords.md"
printf 'second private token' > "$HOME_DIR/plugins/token.json"
collect "$HOME_DIR" 2026-10-14T12:00:00Z
expect_code 0 "$STATUS" 'unselected files changed'
assert_equals '' "$OUT" 'unselected files produced inventory delta'
rm "$HOME_DIR/skills/one/SKILL.md"
ln -s passwords.md "$HOME_DIR/skills/one/SKILL.md"
collect "$HOME_DIR" 2026-10-15T12:00:00Z
expect_code 2 "$STATUS" 'skill alias to non-SKILL target'
bundle
jq -e '.coverage[0].complete == false and (.coverage[0].reason | contains("skill instruction unavailable")) and (.evidence | length) == 0' "$OUT" >/dev/null || fail 'non-SKILL alias claimed complete coverage'
assert_no_grep 'second private password' "$OUT" 'non-SKILL alias leaked content'
jq -e '.sources.skills.checkpoint == "2026-10-14T12:00:00Z"' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'non-SKILL alias advanced checkpoint'
pass 'only SKILL.md and plugin manifests enter inventory'

new_home
mkdir -p "$HOME_DIR/plugins"
printf '%s\n' '{"plugins":{}}' > "$HOME_DIR/plugins/manifest.json"
for bad_kind in asset instruction plugin-enablement; do
  config "$(jq -nc --arg root "$HOME_DIR/plugins" --arg kind "$bad_kind" '[{id:"plugins",kind:"plugin-files",root:$root,files:[{path:"manifest.json",kind:"plugin-manifest"},{path:"extra.md",kind:$kind}]}]')"
  collect "$HOME_DIR" "$NOW"
  expect_code 1 "$STATUS" "removed plugin file kind $bad_kind"
  assert_grep 'invalid inventory file kind' "$TMP_ROOT/stderr" "removed plugin file kind $bad_kind was accepted"
done
assert_absent "$HOME_DIR/data/domain-freshness" 'removed plugin file kinds wrote state'
pass 'plugin file declarations accept manifests and versions only'

new_home
mkdir -p "$HOME_DIR/plugins"
printf '%s\n' '{"name":"demo","version":"1"}' > "$HOME_DIR/plugins/version.json"
config "$(jq -nc --arg root "$HOME_DIR/plugins" '[{id:"plugins",kind:"plugin-files",root:$root,files:[{path:"version.json",kind:"plugin-version"}]}]')"
collect "$HOME_DIR" "$NOW"
expect_code 2 "$STATUS" 'plugin source without installed manifest'
bundle
jq -e '.coverage[0].complete == false and (.coverage[0].reason | contains("plugin manifest surface")) and (.evidence | length) == 0' "$OUT" >/dev/null || fail 'version-only plugin source claimed complete coverage'
jq -e '.sources.plugins == null' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'incomplete plugin source advanced cursor'
pass 'plugin coverage requires installed manifest declaration'

new_home
mkdir -p "$HOME_DIR/plugins"
printf '%s\n' '{"plugins":{}}' > "$HOME_DIR/plugins/manifest.json"
printf '%s\n' '{"name":"demo","version":"1"}' > "$HOME_DIR/plugins/version.json"
config "$(jq -nc --arg root "$HOME_DIR/plugins" '[{id:"plugins",kind:"plugin-files",root:$root,files:[{path:"manifest.json",kind:"plugin-manifest"},{path:"version.json",kind:"plugin-version"}]}]')"
collect "$HOME_DIR" "$NOW"
rm "$HOME_DIR/plugins/version.json"
collect "$HOME_DIR" 2026-10-14T12:00:00Z
expect_code 0 "$STATUS" 'removed plugin version'
bundle
jq -e '(.evidence | length) == 1 and .evidence[0].kind == "inventory-change" and .evidence[0].after == null and .coverage[0].surfaces == ["plugin-manifest"]' "$OUT" >/dev/null || fail 'removed plugin version did not produce a delta'
rm "$HOME_DIR/plugins/manifest.json"
collect "$HOME_DIR" 2026-10-15T12:00:00Z
expect_code 2 "$STATUS" 'missing required plugin manifest'
pass 'optional version removal is a delta and required manifest loss fails coverage'

for parent_mode in symlink file; do
  new_home
  mkdir -p "$HOME_DIR/plugins/optional"
  printf '%s\n' '{"plugins":{}}' > "$HOME_DIR/plugins/manifest.json"
  config "$(jq -nc --arg root "$HOME_DIR/plugins" '[{id:"plugins",kind:"plugin-files",root:$root,files:[{path:"manifest.json",kind:"plugin-manifest"},{path:"optional/version.json",kind:"plugin-version"}]}]')"
  collect "$HOME_DIR" "$NOW"
  expect_code 0 "$STATUS" 'absent optional version'
  rmdir "$HOME_DIR/plugins/optional"
  if [ "$parent_mode" = symlink ]; then
    ln -s "$HOME_DIR/plugins/missing" "$HOME_DIR/plugins/optional"
  else
    printf 'not a directory' > "$HOME_DIR/plugins/optional"
  fi
  collect "$HOME_DIR" 2026-10-14T12:00:00Z
  expect_code 2 "$STATUS" "optional version $parent_mode parent"
  bundle
  jq -e '.coverage[0].complete == false and (.evidence | length) == 0' "$OUT" >/dev/null || fail "optional version $parent_mode parent claimed complete coverage"
  jq -e '.sources.plugins.checkpoint == "2026-10-13T12:00:00Z"' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail "optional version $parent_mode parent advanced checkpoint"
done
pass 'absent optional version requires an available directory parent'

new_home
config "$repo_sources"
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'empty forge baseline'
assert_equals '' "$OUT" 'empty forge baseline should not publish evidence'
jq -e '.sources.forge.checkpoint == "2026-10-13T12:00:00Z"' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'empty forge success did not checkpoint'
issue 8 2026-10-15T09:00:00Z | jq -s . > "$FEED/issues-1.json"
collect "$HOME_DIR" 2026-10-16T12:00:00Z
bundle
jq -e '.coverage[0].window_start == "2026-10-13T11:55:00Z" and .evidence[0].kind == "new-issue" and .evidence[0].url == "https://github.com/acme/widgets/issues/8"' "$OUT" >/dev/null || fail 'since-success multi-day issue window failed'
pass 'repository window starts at last success with overlap across days'

new_home
config "$repo_sources"
pr 7 2026-10-10T10:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
issue 9 2026-10-13T11:00:00Z | jq -s '. + [{number:10,html_url:"https://github.com/acme/widgets/issues/10",created_at:"2026-10-13T11:00:00Z",pull_request:{}}]' > "$FEED/issues-1.json"
collect "$HOME_DIR" "$NOW"
bundle
jq -e '.evidence | length == 1 and .[0].kind == "new-issue" and .[0].url == "https://github.com/acme/widgets/issues/9"' "$OUT" >/dev/null || fail 'updated old PR or PR issue-feed item leaked'
assert_absent "$FEED/detail-7.json" 'unexpected PR detail fixture exists'
assert_no_grep '/pulls/7' "$FEED/requests" 'old PR detail was fetched'
pass 'old merged PR updates and PR issue-feed rows are filtered'

new_home
config "$repo_sources"
pr 12 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
detail 12 2026-10-13T11:00:00Z 101 > "$FEED/detail-12.json"
jq -n --arg sha "$FILE_SHA" '[range(0;100)|("src/file-"+(.|tostring)) as $path|{filename:$path,status:"modified",sha:$sha,additions:1,deletions:0,changes:1,blob_url:("https://github.com/acme/widgets/blob/"+$sha+"/"+$path),raw_url:("https://github.com/acme/widgets/raw/"+$sha+"/"+$path)}]' > "$FEED/files-12-1.json"
pr_file src/last added | jq -s . > "$FEED/files-12-2.json"
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'paginated PR files'
bundle
jq -e --arg sha "$HEAD_SHA" '.evidence[0].kind == "merged-pr" and (.evidence[0].files | length == 101) and .evidence[0].files[-1].filename == "src/last" and .evidence[0].base.ref == "main" and .evidence[0].head.sha == $sha' "$OUT" >/dev/null || fail 'paginated PR file metadata incomplete'
assert_grep '/pulls/12/files?per_page=100&page=2' "$FEED/requests" 'second PR file page was not requested'
pass 'merged PR includes every paginated file and base/head metadata'

new_home
config '[{"id":"forge","kind":"repository","repo":"ACME/WIDGETS"}]'
mkdir -p "$HOME_DIR/data/owned"
printf '%s\n' '{"schema":"fm-contributions.v1","task":"owned","records":[{"url":"https://github.com/AcMe/WidGets/pull/30","kind":"pr","pending":[],"seen":[],"observation":null}]}' > "$HOME_DIR/data/owned/contributions.json"
pr 30 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
issue 31 2026-10-13T11:00:00Z | jq -s . > "$FEED/issues-1.json"
detail 30 2026-10-13T11:00:00Z 4 > "$FEED/detail-30.json"
merge_history 30
jq '.base.sha = "1111111111111111111111111111111111111111"' "$FEED/detail-30.json" > "$FEED/detail-history.json"
mv "$FEED/detail-history.json" "$FEED/detail-30.json"
{ pr_file AGENTS.md modified; pr_file skills/one/SKILL.md added; pr_file CLAUDE.md removed; pr_file skills/new.md renamed skills/old.md; } | jq -s . > "$FEED/files-30-1.json"
tree_content "$PARENT_TREE" AGENTS.md '# Before'
tree_content "$MERGE_TREE" AGENTS.md '# Resolved after'
tree_content "$MERGE_TREE" skills/one/SKILL.md '# Added'
tree_content "$PARENT_TREE" CLAUDE.md '# Removed'
tree_content "$PARENT_TREE" skills/old.md '# Old name'
tree_content "$MERGE_TREE" skills/new.md '# New name'
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'canonical forge casing and instruction revisions'
bundle
jq -e --arg sha "$HEAD_SHA" '(.evidence | length) == 2 and
  (any(.evidence[]; .kind == "new-issue" and .repository == "acme/widgets")) and
  (any(.evidence[]; .kind == "merged-pr" and .repository == "acme/widgets" and .base.repository == "acme/widgets" and
    .linked_contributions[0].task == "owned" and
    .base.sha == "1111111111111111111111111111111111111111" and .head.sha == $sha and
    .files[0].instruction.before.content == "# Before" and .files[0].instruction.after.content == "# Resolved after" and
    .files[1].instruction.before == null and .files[1].instruction.after.content == "# Added" and
    .files[2].instruction.before.content == "# Removed" and .files[2].instruction.after == null and
    .files[3].instruction.before.content == "# Old name" and .files[3].instruction.after.content == "# New name"))' "$OUT" >/dev/null || fail 'canonical casing or instruction content missing'
pass 'canonical repository casing and changed instruction revisions retain provenance'

new_home
config "$repo_sources"
pr 32 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
detail 32 2026-10-13T11:00:00Z 4 > "$FEED/detail-32.json"
merge_history 32
{ pr_file skills/added.md added; pr_file skills/copied.md copied skills/source.md; pr_file skills/removed.md removed; pr_file skills/new.md renamed skills/old.md; } | jq -s . > "$FEED/files-32-1.json"
tree_content "$PARENT_TREE" skills/added.md '# Already added'
tree_content "$MERGE_TREE" skills/added.md '# Merged addition'
tree_content "$PARENT_TREE" skills/copied.md '# Existing copy'
tree_content "$MERGE_TREE" skills/copied.md '# Merged copy'
tree_content "$PARENT_TREE" skills/removed.md '# Before removal'
tree_content "$MERGE_TREE" skills/removed.md '# Kept by merge'
tree_content "$PARENT_TREE" skills/old.md '# Before rename'
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'merge history differs from PR file statuses'
bundle
jq -e '.complete and (.evidence[0].files | length == 4) and
  .evidence[0].files[0].instruction.before.content == "# Already added" and .evidence[0].files[0].instruction.after.content == "# Merged addition" and
  .evidence[0].files[1].instruction.before.content == "# Existing copy" and .evidence[0].files[1].instruction.after.content == "# Merged copy" and
  .evidence[0].files[2].instruction.before.content == "# Before removal" and .evidence[0].files[2].instruction.after.content == "# Kept by merge" and
  .evidence[0].files[3].instruction.before.content == "# Before rename" and .evidence[0].files[3].instruction.after == null' "$OUT" >/dev/null || fail 'effective merge history did not determine instruction before and after'
pass 'merge history determines instruction content across PR statuses'

new_home
config "$repo_sources"
pr 40 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
detail 40 2026-10-13T11:00:00Z 1 | jq '.head.repo.full_name = "contrib/widgets"' > "$FEED/detail-40.json"
merge_history 40
pr_file AGENTS.md modified | jq -s . > "$FEED/files-40-1.json"
tree_content "$PARENT_TREE" AGENTS.md '# Base revision'
tree_content "$MERGE_TREE" AGENTS.md '# Merged fork revision'
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'fork PR instruction content'
bundle
jq -e '.evidence[0].head.repository == "contrib/widgets" and .evidence[0].files[0].instruction.before.content == "# Base revision" and .evidence[0].files[0].instruction.after.content == "# Merged fork revision"' "$OUT" >/dev/null || fail 'fork merged instruction content was not captured'
assert_grep "/repos/acme/widgets/git/commits/$MERGE_SHA" "$FEED/requests" 'fork merged commit was not queried'
assert_no_grep '/repos/contrib/widgets/' "$FEED/requests" 'fork head was used for effective content'
pass 'fork instruction content comes from effective base merge history'

new_home
config "$repo_sources"
pr 41 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
detail 41 2026-10-13T11:00:00Z 1 | jq '.head.repo = null' > "$FEED/detail-41.json"
merge_history 41
pr_file AGENTS.md added | jq -s 'map(del(.sha, .blob_url, .raw_url))' > "$FEED/files-41-1.json"
tree_content "$MERGE_TREE" AGENTS.md '# Deleted fork merged revision'
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'deleted fork merged content'
bundle
jq -e '.evidence[0].head.repository == null and .evidence[0].files[0].instruction.before == null and .evidence[0].files[0].instruction.after.content == "# Deleted fork merged revision"' "$OUT" >/dev/null || fail 'deleted fork merged instruction was not captured'
assert_no_grep '/repos/contrib/widgets/' "$FEED/requests" 'deleted fork head was queried'
pass 'deleted fork uses effective base merge history'

for head_case in fork deleted-fork; do
  new_home
  config "$repo_sources"
  pr 41 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
  if [ "$head_case" = fork ]; then
    detail 41 2026-10-13T11:00:00Z 1 | jq '.head.repo.full_name = "contrib/widgets"' > "$FEED/detail-41.json"
  else
    detail 41 2026-10-13T11:00:00Z 1 | jq '.head.repo = null' > "$FEED/detail-41.json"
  fi
  merge_history 41
  pr_file AGENTS.md modified | jq -s . > "$FEED/files-41-1.json"
  tree_content "$PARENT_TREE" AGENTS.md '# Available before'
  tree_content "$MERGE_TREE" AGENTS.md '# Missing merged blob'
  rm "$FEED/blob-$(printf '%s' '# Missing merged blob' | git hash-object --stdin).json"
  collect "$HOME_DIR" "$NOW"
  expect_code 0 "$STATUS" "$head_case unavailable merged blob"
  bundle
  jq -e '.coverage[0].complete and .evidence[0].files[0].instruction.before.content == "# Available before" and .evidence[0].files[0].instruction.after.availability == "content unavailable"' "$OUT" >/dev/null || fail "$head_case unavailable content was not recorded"
  jq -e '.sources.forge.checkpoint == "2026-10-13T12:00:00Z"' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail "$head_case unavailable content did not checkpoint"
  assert_no_grep '/repos/contrib/widgets/' "$FEED/requests" "$head_case queried fork endpoint"
done
pass 'unavailable fork content is recorded without failed coverage'

for head_case in fork deleted-fork; do
  for read_failure in timeout server; do
    new_home
    config "$repo_sources"
    pr 41 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
    if [ "$head_case" = fork ]; then
      detail 41 2026-10-13T11:00:00Z 1 | jq '.head.repo.full_name = "contrib/widgets"' > "$FEED/detail-41.json"
    else
      detail 41 2026-10-13T11:00:00Z 1 | jq '.head.repo = null' > "$FEED/detail-41.json"
    fi
    merge_history 41
    pr_file AGENTS.md modified | jq -s . > "$FEED/files-41-1.json"
    tree_content "$PARENT_TREE" AGENTS.md '# Available before'
    tree_content "$MERGE_TREE" AGENTS.md '# After read failure'
    failed_blob="$FEED/blob-$(printf '%s' '# After read failure' | git hash-object --stdin).json"
    printf '%s\n' "$read_failure" > "$failed_blob.failure"
    collect "$HOME_DIR" "$NOW"
    expect_code 2 "$STATUS" "$head_case $read_failure after-blob read"
    bundle
    jq -e '.coverage[0].complete == false and (.coverage[0].reason | contains("forge read failed")) and (.evidence | length) == 0' "$OUT" >/dev/null || fail "$head_case $read_failure read claimed complete coverage"
    jq -e '.sources.forge == null' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail "$head_case $read_failure read advanced checkpoint"
    rm "$failed_blob.failure"
    collect "$HOME_DIR" "$NOW"
    expect_code 0 "$STATUS" "$head_case $read_failure retry"
    bundle
    jq -e '.evidence[0].files[0].instruction.after.content == "# After read failure"' "$OUT" >/dev/null || fail "$head_case $read_failure retry lost content"
  done
done
pass 'fork timeouts and server errors keep coverage incomplete until retry'

new_home
config "$repo_sources"
pr 41 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
detail 41 2026-10-13T11:00:00Z 1 > "$FEED/detail-41.json"
merge_history 41
pr_file AGENTS.md added | jq -s . > "$FEED/files-41-1.json"
tree_content "$MERGE_TREE" AGENTS.md '# Missing local blob'
rm "$FEED/blob-$(printf '%s' '# Missing local blob' | git hash-object --stdin).json"
collect "$HOME_DIR" "$NOW"
expect_code 2 "$STATUS" 'unavailable same-repository blob'
bundle
jq -e '.coverage[0].complete == false and (.evidence | length) == 0' "$OUT" >/dev/null || fail 'unavailable same-repository blob claimed complete coverage'
jq -e '.sources.forge == null' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'unavailable same-repository blob advanced checkpoint'
pass 'same-repository blob failure retains incomplete coverage'

new_home
config "$repo_sources"
pr 42 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
detail 42 2026-10-13T11:00:00Z 1 > "$FEED/detail-42.json"
merge_history 42 1
pr_file AGENTS.md modified | jq -s . > "$FEED/files-42-1.json"
tree_content "$PARENT_TREE" AGENTS.md '# Before linear merge'
tree_content "$MERGE_TREE" AGENTS.md '# After linear merge'
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'single-commit linear merge'
bundle
jq -e '.evidence[0].files[0].instruction.before.content == "# Before linear merge" and .evidence[0].files[0].instruction.after.content == "# After linear merge"' "$OUT" >/dev/null || fail 'single-commit linear merge evidence missing'
for head_case in same fork deleted; do
  new_home
  config "$repo_sources"
  pr 43 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
  detail 43 2026-10-13T11:00:00Z 1 > "$FEED/detail-43.json"
  merge_history 43 1
  jq '.commits = 2' "$FEED/detail-43.json" > "$FEED/detail-history.json"
  mv "$FEED/detail-history.json" "$FEED/detail-43.json"
  case "$head_case" in
    fork) jq '.head.repo.full_name = "contrib/widgets"' "$FEED/detail-43.json" > "$FEED/detail-history.json" ;;
    deleted) jq '.head.repo = null' "$FEED/detail-43.json" > "$FEED/detail-history.json" ;;
  esac
  if [ "$head_case" != same ]; then
    mv "$FEED/detail-history.json" "$FEED/detail-43.json"
  fi
  pr_file AGENTS.md modified | jq -s . > "$FEED/files-43-1.json"
  tree_content "$PARENT_TREE" AGENTS.md '# Before squash'
  tree_content "$MERGE_TREE" AGENTS.md '# After squash'
  pr 43 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/associated-$MERGE_SHA-1.json"
  printf '[]\n' > "$FEED/associated-$PARENT_SHA-1.json"
  collect "$HOME_DIR" "$NOW"
  expect_code 0 "$STATUS" "$head_case multi-commit squash"
  bundle
  jq -e '.evidence[0].files[0].instruction.before.content == "# Before squash" and .evidence[0].files[0].instruction.after.content == "# After squash"' "$OUT" >/dev/null || fail "$head_case squash evidence missing"
  assert_grep "/repos/acme/widgets/commits/$PARENT_SHA/pulls?per_page=100&page=1" "$FEED/requests" "$head_case squash parent association was not checked"
done
pass 'multi-commit squash history covers same-repository, fork and deleted-fork PRs'

new_home
config "$repo_sources"
pr 42 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
detail 42 2026-10-13T11:00:00Z 1 > "$FEED/detail-42.json"
merge_history 42 1
pr_file AGENTS.md modified | jq -s . > "$FEED/files-42-1.json"
jq '.commits = 2' "$FEED/detail-42.json" > "$FEED/detail-history.json"
mv "$FEED/detail-history.json" "$FEED/detail-42.json"
pr 42 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/associated-$MERGE_SHA-1.json"
pr 42 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/associated-$PARENT_SHA-1.json"
collect "$HOME_DIR" "$NOW"
expect_code 2 "$STATUS" 'ambiguous multi-commit linear merge'
bundle
jq -e '.coverage[0].complete == false and (.coverage[0].reason | contains("ambiguous")) and (.evidence | length) == 0' "$OUT" >/dev/null || fail 'ambiguous merge history claimed complete coverage'
jq -e '.sources.forge == null' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'ambiguous merge history advanced checkpoint'
pass 'single-parent history rejects ambiguous multi-commit rebases'

new_home
config "$repo_sources"
mkdir -p "$HOME_DIR/data/owned"
printf '%s\n' '{"schema":"fm-contributions.v1","task":"owned","records":[{"url":"https://github.com/acme/widgets/pull/12","kind":"pr","pending":[],"seen":[],"checked_at":"2026-10-13T11:30:00Z","error":null,"observation":{"head":"0123456789012345678901234567890123456789","state":"merged","draft":false,"mergeable":"mergeable","can_merge":true,"review_decision":"APPROVED","checks":[],"reviews":[],"events":[]}}]}' > "$HOME_DIR/data/owned/contributions.json"
pr 12 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
detail 12 2026-10-13T11:00:00Z 0 > "$FEED/detail-12.json"
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'linked contribution observation'
bundle
jq -e '.evidence[0].linked_contributions == [{"task":"owned","checked_at":"2026-10-13T11:30:00Z","error":null,"observation":{"head":"0123456789012345678901234567890123456789","state":"merged","draft":false,"mergeable":"mergeable"}}]' "$OUT" >/dev/null || fail 'linked contribution observation missing'
pass 'repository discovery reuses durable linked contribution observation'

new_home
config "$repo_sources"
mkdir -p "$HOME_DIR/data/active" "$HOME_DIR/data/retired"
jq -n '{schema:"fm-contributions.v1",task:"active",records:[
  {url:"https://github.com/acme/widgets/pull/12",kind:"pr",pending:[],seen:[],checked_at:"2026-10-13T11:30:00Z",error:null,observation:{head:"0123456789012345678901234567890123456789",state:"merged",draft:false,mergeable:"mergeable",can_merge:true,review_decision:"APPROVED",checks:[],reviews:[],events:[]}},
  {url:"https://github.com/acme/widgets/issues/13",kind:"issue",pending:[],seen:[],checked_at:"2026-10-13T11:31:00Z",error:null,observation:{state:"open",ready:true,checks:[],reviews:[],events:[]}}
]}' > "$HOME_DIR/data/active/contributions.json"
jq -n '{schema:"fm-contributions.v1",task:"retired",records:[
  {url:"https://github.com/acme/widgets/pull/12",kind:"pr",pending:[],seen:[],retired:{actor:"captain",reason:"settled",at:"2026-10-13T10:00:00Z"},observation:null},
  {url:"https://github.com/acme/widgets/issues/13",kind:"issue",pending:[],seen:[],retired:{actor:"captain",reason:"settled",at:"2026-10-13T10:00:00Z"},observation:null}
]}' > "$HOME_DIR/data/retired/contributions.json"
pr 12 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
detail 12 2026-10-13T11:00:00Z 0 > "$FEED/detail-12.json"
issue 13 2026-10-13T11:10:00Z | jq -s . > "$FEED/issues-1.json"
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'active PR and issue contributions'
bundle
jq -e '(.evidence | length) == 2 and all(.evidence[]; (.linked_contributions | length) == 1 and .linked_contributions[0].task == "active") and (any(.evidence[]; .kind == "merged-pr" and .linked_contributions[0].observation.state == "merged")) and (any(.evidence[]; .kind == "new-issue" and .linked_contributions[0].observation.ready == true))' "$OUT" >/dev/null || fail 'active contribution links or issue readiness missing'
pass 'PR and issue events reuse only active linked observations'

new_home
config "$repo_sources"
mkdir -p "$HOME_DIR/data/owned"
jq -n '{schema:"fm-contributions.v1",task:"owned",records:[
  {url:"https://github.com/acme/widgets/issues/13",kind:"issue",pending:[],seen:[],checked_at:"2026-10-13T11:30:00Z",error:null,observation:{state:"open",ready:true,checks:[],reviews:[],events:[]}},
  {url:"https://github.com/acme/widgets/pull/12",kind:"pr",pending:[],seen:[],checked_at:"2026-10-13T11:30:00Z",error:null,observation:{head:"0123456789012345678901234567890123456789",state:"merged",draft:false,mergeable:"mergeable",can_merge:true,review_decision:"APPROVED",checks:[],reviews:[],events:[]}}
]}' > "$TMP_ROOT/linked-good.json"
for bad in issue_ready issue_state url kind checked_at error pr_head pr_state pr_draft pr_mergeable; do
  case "$bad" in
    issue_ready) filter='.records[0].observation.ready = "yes"' ;;
    issue_state) filter='.records[0].observation.state = "pending"' ;;
    url) filter='.records[0].url = "not-a-link"' ;;
    kind) filter='.records[0].kind = "pr"' ;;
    checked_at) filter='.records[0].checked_at = "yesterday"' ;;
    error) filter='.records[0].error = true' ;;
    pr_head) filter='.records[1].observation.head = "bad"' ;;
    pr_state) filter='.records[1].observation.state = "pending"' ;;
    pr_draft) filter='.records[1].observation.draft = "false"' ;;
    pr_mergeable) filter='.records[1].observation.mergeable = "yes"' ;;
  esac
  jq "$filter" "$TMP_ROOT/linked-good.json" > "$HOME_DIR/data/owned/contributions.json"
  collect "$HOME_DIR" "$NOW"
  expect_code 2 "$STATUS" "invalid linked $bad"
  bundle
  jq -e '.coverage[0].complete == false and (.coverage[0].reason | contains("durable contribution")) and (.evidence | length) == 0' "$OUT" >/dev/null || fail "invalid linked $bad reached evidence"
  jq -e '.sources.forge == null' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail "invalid linked $bad advanced checkpoint"
done
pass 'malformed durable linked observations fail repository coverage'

new_home
config "$repo_sources"
pr 12 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
detail 12 2026-10-13T11:00:00Z 2 > "$FEED/detail-12.json"
pr_file src/only added | jq -s . > "$FEED/files-12-1.json"
collect "$HOME_DIR" "$NOW"
expect_code 2 "$STATUS" 'incomplete PR changed-file count'
bundle
jq -e '.complete == false and .coverage[0].complete == false and (.coverage[0].reason | contains("changed-file")) and (.evidence | length == 0)' "$OUT" >/dev/null || fail 'truncated PR files were treated as complete'
jq -e '.sources.forge == null' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'truncated PR feed advanced the cursor'
pass 'changed-file count mismatch fails coverage without checkpoint'

for malformed in renamed-path status file-sha missing-file-sha file-count blob-url raw-url base-ref base-sha head-ref head-sha pr-title pr-labels; do
  new_home
  config "$repo_sources"
  pr 12 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
  detail 12 2026-10-13T11:00:00Z 1 > "$FEED/detail-12.json"
  pr_file src/one modified | jq -s . > "$FEED/files-12-1.json"
  case "$malformed" in
    renamed-path) jq '.[0].status = "renamed" | del(.[0].previous_filename)' "$FEED/files-12-1.json" > "$FEED/bad.json" ; mv "$FEED/bad.json" "$FEED/files-12-1.json" ;;
    status) jq '.[0].status = "mystery"' "$FEED/files-12-1.json" > "$FEED/bad.json" ; mv "$FEED/bad.json" "$FEED/files-12-1.json" ;;
    file-sha) jq '.[0].sha = "invalid"' "$FEED/files-12-1.json" > "$FEED/bad.json" ; mv "$FEED/bad.json" "$FEED/files-12-1.json" ;;
    missing-file-sha) jq '.[0] |= del(.sha)' "$FEED/files-12-1.json" > "$FEED/bad.json" ; mv "$FEED/bad.json" "$FEED/files-12-1.json" ;;
    file-count) jq '.[0].changes = -1' "$FEED/files-12-1.json" > "$FEED/bad.json" ; mv "$FEED/bad.json" "$FEED/files-12-1.json" ;;
    blob-url) jq '.[0].blob_url = "http://invalid.test/blob"' "$FEED/files-12-1.json" > "$FEED/bad.json" ; mv "$FEED/bad.json" "$FEED/files-12-1.json" ;;
    raw-url) jq '.[0].raw_url = 12' "$FEED/files-12-1.json" > "$FEED/bad.json" ; mv "$FEED/bad.json" "$FEED/files-12-1.json" ;;
    base-ref) jq '.base.ref = null' "$FEED/detail-12.json" > "$FEED/bad.json" ; mv "$FEED/bad.json" "$FEED/detail-12.json" ;;
    base-sha) jq '.base.sha = "invalid"' "$FEED/detail-12.json" > "$FEED/bad.json" ; mv "$FEED/bad.json" "$FEED/detail-12.json" ;;
    head-ref) jq 'del(.head.ref)' "$FEED/detail-12.json" > "$FEED/bad.json" ; mv "$FEED/bad.json" "$FEED/detail-12.json" ;;
    head-sha) jq '.head.sha = null' "$FEED/detail-12.json" > "$FEED/bad.json" ; mv "$FEED/bad.json" "$FEED/detail-12.json" ;;
    pr-title) jq '.[0].title = null' "$FEED/pulls-1.json" > "$FEED/bad.json" ; mv "$FEED/bad.json" "$FEED/pulls-1.json" ;;
    pr-labels) jq '.[0].labels = [{color:"ff0000"}]' "$FEED/pulls-1.json" > "$FEED/bad.json" ; mv "$FEED/bad.json" "$FEED/pulls-1.json" ;;
  esac
  collect "$HOME_DIR" "$NOW"
  expect_code 2 "$STATUS" "malformed $malformed forge metadata"
  bundle
  jq -e '.coverage[0].complete == false and (.evidence | length) == 0' "$OUT" >/dev/null || fail "$malformed metadata claimed complete coverage"
  jq -e '.sources.forge == null' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail "$malformed metadata advanced the checkpoint"
done
for malformed in issue-title issue-labels; do
  new_home
  config "$repo_sources"
  issue 12 2026-10-13T11:00:00Z | jq -s . > "$FEED/issues-1.json"
  if [ "$malformed" = issue-title ]; then
    jq '.[0].title = false' "$FEED/issues-1.json" > "$FEED/bad.json"
  else
    jq '.[0].labels = "bug"' "$FEED/issues-1.json" > "$FEED/bad.json"
  fi
  mv "$FEED/bad.json" "$FEED/issues-1.json"
  collect "$HOME_DIR" "$NOW"
  expect_code 2 "$STATUS" "malformed $malformed forge metadata"
  bundle
  jq -e '.coverage[0].complete == false and (.evidence | length) == 0' "$OUT" >/dev/null || fail "$malformed metadata claimed complete coverage"
  jq -e '.sources.forge == null' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail "$malformed metadata advanced the checkpoint"
done
pass 'malformed retained forge metadata fails source coverage without checkpoint'

new_home
config "$repo_sources"
pr 12 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
detail 12 2026-10-13T11:00:00Z 1 > "$FEED/detail-12.json"
pr_file src/removed removed | jq -s 'map(del(.sha, .blob_url, .raw_url))' > "$FEED/files-12-1.json"
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'removed file with absent optional URLs and SHA'
bundle
jq -e '.coverage[0].complete and .evidence[0].files[0].status == "removed" and .evidence[0].files[0].sha == null' "$OUT" >/dev/null || fail 'removed file optional metadata was rejected'
pass 'removed files may omit optional identity and URLs'

new_home
config "$repo_sources"
pr 12 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
detail 12 2026-10-13T11:00:00Z 1 > "$FEED/detail-12.json"
pr_file src/submodule modified | jq -s 'map(.sha = null | .blob_url = null | .raw_url = null)' > "$FEED/files-12-1.json"
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'nullable PR file identity and URLs'
bundle
jq -e '.coverage[0].complete and .evidence[0].files[0].sha == null and .evidence[0].files[0].blob_url == null and .evidence[0].files[0].raw_url == null' "$OUT" >/dev/null || fail 'nullable file metadata was rejected'
pass 'GitHub nullable file metadata remains readable'

new_home
mkdir -p "$HOME_DIR/skills/a"
printf '# Initial\n' > "$HOME_DIR/skills/a/SKILL.md"
config "$(jq -nc --arg root "$HOME_DIR/skills" '[{id:"good",kind:"skills",root:$root},{id:"bad",kind:"repository",repo:"acme/widgets"}]')"
collect "$HOME_DIR" "$NOW"
bundle
jq -e '.sources.good.checkpoint == "2026-10-13T12:00:00Z" and .sources.bad.checkpoint == "2026-10-13T12:00:00Z"' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'initial checkpoints absent'
printf '# Changed\n' > "$HOME_DIR/skills/a/SKILL.md"
printf '%s\n' '/repos/acme/widgets/issues?state=all&sort=created&direction=desc&since=2026-10-13T11:55:00Z&per_page=100&page=1' > "$FEED/fail"
collect "$HOME_DIR" 2026-10-14T12:00:00Z
expect_code 2 "$STATUS" 'partial source failure'
bundle
jq -e '.complete == false and (any(.coverage[]; .id == "bad" and .complete == false)) and (any(.evidence[]; .source == "good" and .kind == "inventory-change"))' "$OUT" >/dev/null || fail 'partial bundle lacks good evidence or bad coverage'
jq -e '.sources.good.checkpoint == "2026-10-14T12:00:00Z" and .sources.bad.checkpoint == "2026-10-13T12:00:00Z"' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'partial pass advanced failed source or lost good checkpoint'
pass 'partial failure preserves failed cursor while good source advances'

new_home
config "$repo_sources"
issue 21 2026-10-13T11:59:00Z | jq -s . > "$FEED/issues-1.json"
collect "$HOME_DIR" "$NOW"
bundle
collect "$HOME_DIR" 2026-10-13T12:03:00Z
expect_code 0 "$STATUS" 'late overlap replay'
assert_equals '' "$OUT" 'overlap replay duplicated event'
pass 'late overlap identity dedup keeps unchanged pass silent'

new_home
config "$repo_sources"
pr 22 2026-10-13T11:59:00Z 2026-10-13T11:59:00Z | jq '.html_url = "https://github.com/ACME/WIDGETS/pull/22"' | jq -s . > "$FEED/pulls-1.json"
issue 23 2026-10-13T11:59:00Z | jq '.html_url = "https://github.com/ACME/WIDGETS/issues/23"' | jq -s . > "$FEED/issues-1.json"
detail 22 2026-10-13T11:59:00Z 0 > "$FEED/detail-22.json"
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'case-varying forge detail'
bundle
jq -e '(.evidence | length) == 2 and all(.evidence[]; .url | startswith("https://github.com/ACME/WIDGETS/"))' "$OUT" >/dev/null || fail 'returned forge URL casing was not retained in evidence'
jq -e '.sources.forge.seen | has("merged-pr:https://github.com/acme/widgets/pull/22") and has("new-issue:https://github.com/acme/widgets/issues/23")' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'new overlap identities were not case-stable'
jq '.sources.forge.seen |= with_entries(.key |= gsub("acme/widgets"; "ACME/WIDGETS"))' "$HOME_DIR/data/domain-freshness/cursors.json" > "$HOME_DIR/data/domain-freshness/cursors-next.json"
mv "$HOME_DIR/data/domain-freshness/cursors-next.json" "$HOME_DIR/data/domain-freshness/cursors.json"
pr 22 2026-10-13T11:59:00Z 2026-10-13T11:59:00Z | jq -s . > "$FEED/pulls-1.json"
issue 23 2026-10-13T11:59:00Z | jq -s . > "$FEED/issues-1.json"
collect "$HOME_DIR" 2026-10-13T12:03:00Z
expect_code 0 "$STATUS" 'case-varying overlap replay'
assert_equals '' "$OUT" 'case-varying overlap replay duplicated an event'
jq -e '.sources.forge.checkpoint == "2026-10-13T12:03:00Z" and (.sources.forge.seen | has("merged-pr:https://github.com/acme/widgets/pull/22") and has("new-issue:https://github.com/acme/widgets/issues/23"))' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'legacy overlap identities were not normalized without losing the checkpoint'
pass 'PR and issue overlap dedup survives URL casing and legacy cursor keys'

new_home
mkdir -p "$HOME_DIR/skills"
ln -s "$TMP_ROOT/outside" "$HOME_DIR/skills/escaped"
mkdir -p "$TMP_ROOT/outside"
printf '# Outside\n' > "$TMP_ROOT/outside/SKILL.md"
config "$(jq -nc --arg root "$HOME_DIR/skills" '[{id:"skills",kind:"skills",root:$root}]')"
collect "$HOME_DIR" "$NOW"
expect_code 2 "$STATUS" 'unsafe inventory symlink'
bundle
jq -e '.complete == false and .coverage[0].complete == false and (.coverage[0].reason | test("symlink|root")) and (.evidence | length == 0)' "$OUT" >/dev/null || fail 'unsafe symlink was not failed coverage'
pass 'unsafe inventory symlink fails coverage'

new_home
mkdir -p "$HOME_DIR/skills" "$HOME_DIR/external/linked-skill"
printf '# Linked instruction\n' > "$HOME_DIR/external/linked-skill/SKILL.md"
ln -s "$HOME_DIR/external/linked-skill" "$HOME_DIR/skills/linked-skill"
config "$(jq -nc --arg root "$HOME_DIR/skills" --arg allowed "$HOME_DIR/external" '[{id:"skills",kind:"skills",root:$root,symlink_roots:[$allowed]}]')"
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'linked skill baseline'
mv "$HOME_DIR/external/linked-skill" "$HOME_DIR/external/unavailable-skill"
collect "$HOME_DIR" 2026-10-14T12:00:00Z
expect_code 2 "$STATUS" 'dangling skill directory link'
bundle
jq -e '.coverage[0].complete == false and (.evidence | length) == 0' "$OUT" >/dev/null || fail 'unavailable linked skill was treated as a removal'
jq -e '.sources.skills.checkpoint == "2026-10-13T12:00:00Z" and .sources.skills.inventory["linked-skill/SKILL.md"].content == "# Linked instruction\n"' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'dangling skill directory advanced or lost its baseline'
rm "$HOME_DIR/skills/linked-skill"
collect "$HOME_DIR" 2026-10-15T12:00:00Z
expect_code 0 "$STATUS" 'deleted skill directory link'
bundle
jq -e '.complete and .evidence[0].before.content == "# Linked instruction\n" and .evidence[0].after == null' "$OUT" >/dev/null || fail 'deleted skill link did not produce a removal'
jq -e '.sources.skills.checkpoint == "2026-10-15T12:00:00Z"' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'deleted skill link did not checkpoint'
pass 'dangling skill directory retains coverage gap while deleted link is a removal'

mkdir -p "$TMP_ROOT/race-hook"
cat > "$TMP_ROOT/race-hook/sitecustomize.py" <<'PY'
import os
from pathlib import Path

original_resolve = Path.resolve
original_scandir = os.scandir
target = os.environ.get('FM_RACE_TARGET')
seen = 0

def resolve(self, *args, **kwargs):
    global seen
    result = original_resolve(self, *args, **kwargs)
    if target and os.fspath(self) == target:
        seen += 1
        if seen == int(os.environ['FM_RACE_AFTER']):
            if os.environ['FM_RACE_MODE'] == 'directory':
                os.rename(target, target + '.original')
            else:
                os.unlink(target)
            os.symlink(os.environ['FM_RACE_OUTSIDE'], target)
    return result

def scandir(path):
    if target and not isinstance(path, int) and os.fspath(path) == target and os.path.islink(target):
        Path(os.environ['FM_RACE_MARKER']).write_text('outside directory scanned')
    return original_scandir(path)

Path.resolve = resolve
os.scandir = scandir
PY
new_home
mkdir -p "$HOME_DIR/plugins" "$HOME_DIR/clients"
printf '%s\n' '{"plugins":{}}' > "$HOME_DIR/plugins/manifest.json"
printf '%s\n' '{"plugins":{"private":[{"version":"1"}]}}' > "$HOME_DIR/clients/private.json"
config "$(jq -nc --arg root "$HOME_DIR/plugins" '[{id:"plugins",kind:"plugin-files",root:$root,files:[{path:"manifest.json",kind:"plugin-manifest"}]}]')"
FM_RACE_TARGET="$HOME_DIR/plugins/manifest.json" FM_RACE_OUTSIDE="$HOME_DIR/clients/private.json" FM_RACE_AFTER=1 FM_RACE_MODE=file FM_RACE_MARKER="$TMP_ROOT/race-marker" PYTHONPATH="$TMP_ROOT/race-hook" collect "$HOME_DIR" "$NOW"
expect_code 2 "$STATUS" 'inventory file replaced after validation'
bundle
jq -e '.coverage[0].complete == false and (.evidence | length) == 0' "$OUT" >/dev/null || fail 'replaced inventory file claimed complete coverage'
assert_no_grep 'private' "$OUT" 'replaced file leaked client content'
jq -e '.sources.plugins == null' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'replaced inventory file advanced checkpoint'

new_home
mkdir -p "$HOME_DIR/skills" "$HOME_DIR/clients/private"
printf '# Public guidance\n' > "$HOME_DIR/skills/SKILL.md"
printf '# Private client guidance\n' > "$HOME_DIR/clients/private/SKILL.md"
config "$(jq -nc --arg root "$HOME_DIR/skills" '[{id:"skills",kind:"skills",root:$root}]')"
FM_RACE_TARGET="$HOME_DIR/skills" FM_RACE_OUTSIDE="$HOME_DIR/clients/private" FM_RACE_AFTER=4 FM_RACE_MODE=directory FM_RACE_MARKER="$TMP_ROOT/race-marker" PYTHONPATH="$TMP_ROOT/race-hook" collect "$HOME_DIR" "$NOW"
expect_code 2 "$STATUS" 'inventory directory replaced after validation'
bundle
jq -e '.coverage[0].complete == false and (.evidence | length) == 0' "$OUT" >/dev/null || fail 'replaced inventory directory claimed complete coverage'
assert_absent "$TMP_ROOT/race-marker" 'collector scanned a replaced client directory'
jq -e '.sources.skills == null' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'replaced inventory directory advanced checkpoint'
pass 'opened inventory files and directories resist replacement'

for root_field in root symlink_roots; do
  new_home
  mkdir -p "$HOME_DIR/skills"
  if [ "$root_field" = root ]; then
    config '[{"id":"skills","kind":"skills","root":"/.."}]'
  else
    config "$(jq -nc --arg root "$HOME_DIR/skills" '[{id:"skills",kind:"skills",root:$root,symlink_roots:["/.."]}]')"
  fi
  collect "$HOME_DIR" "$NOW"
  expect_code 1 "$STATUS" "$root_field resolves to filesystem root"
  assert_absent "$HOME_DIR/data/domain-freshness" "$root_field root-target configuration created collection state"
done
pass 'declared roots and symlink targets cannot resolve to filesystem root'

new_home
mkdir -p "$HOME_DIR/skills"
for number in $(seq 1 2001); do
  : > "$HOME_DIR/skills/resource-$number.png"
done
config "$(jq -nc --arg root "$HOME_DIR/skills" '[{id:"skills",kind:"skills",root:$root}]')"
collect "$HOME_DIR" "$NOW"
expect_code 2 "$STATUS" 'oversized skill directory'
bundle
jq -e '.coverage[0].complete == false and (.coverage[0].reason | contains("skill inventory limit"))' "$OUT" >/dev/null || fail 'non-Markdown directory entries bypassed inventory limit'
jq -e '.sources.skills == null' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'oversized skill directory advanced checkpoint'
pass 'every skill directory entry counts toward the inventory bound'

new_home
mkdir -p "$HOME_DIR/skills"
deep_path="$HOME_DIR/skills"
for number in $(seq 1 257); do
  deep_path="$deep_path/d"
  mkdir "$deep_path"
done
config "$(jq -nc --arg root "$HOME_DIR/skills" '[{id:"skills",kind:"skills",root:$root}]')"
collect "$HOME_DIR" "$NOW"
expect_code 2 "$STATUS" 'deep skill directory'
bundle
jq -e '.coverage[0].complete == false and (.coverage[0].reason | contains("skill inventory depth limit")) and (.evidence | length) == 0' "$OUT" >/dev/null || fail 'deep skill directory omitted incomplete coverage'
jq -e '.sources.skills == null' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'deep skill directory advanced checkpoint'
pass 'deep skill traversal fails coverage within its bound'

new_home
printf '%s\n' '- design - Design operations (host: local; root: /srv/design; home: /srv/design/home; scope: design and research; projects: app; added 2026-10-01)' \
  '- sales - Sales operations (host: remote-mac; root: /srv/sales; home: /srv/sales/home; scope: outbound campaigns; projects: app; added 2026-10-01)' > "$HOME_DIR/data/secondmates.md"
config '[{"id":"remote","kind":"unavailable","reason":"remote home has not supplied an inventory"}]'
collect "$HOME_DIR" "$NOW"
expect_code 2 "$STATUS" 'remote unavailable'
bundle
jq -e '.complete == false and (.domains | length == 2) and (any(.domains[]; .id == "design" and .scope == "design and research")) and (any(.domains[]; .id == "sales" and .host == "remote-mac")) and (any(.coverage[]; .id == "remote" and .complete == false and (.reason | contains("remote home"))))' "$OUT" >/dev/null || fail 'cross-domain context or unavailable coverage missing'
pass 'remote gap is explicit beside cross-domain registry context'

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${FM_FAKE_REMOTE_FAIL:-}" != 1 ] || exit 93
last=${!#}
decoded=$(printf '%s' "$last" | base64 -d | tr '\0' '\n')
[ "$decoded" = $'fm-domain-freshness.sh\ninventory\nremote-skills' ] || exit 94
FM_HOME="$FM_FAKE_REMOTE_HOME" bash "$FM_FAKE_COLLECTOR" inventory remote-skills
SH
chmod +x "$FAKEBIN/fake-ssh"
new_home
REMOTE_HOME="$TMP_ROOT/remote-home"
mkdir -p "$REMOTE_HOME/config" "$REMOTE_HOME/skills"
printf '# Remote original\n' > "$REMOTE_HOME/skills/SKILL.md"
jq -n --arg root "$REMOTE_HOME/skills" '{version:1,enabled:false,sources:[{id:"remote-skills",kind:"skills",root:$root}]}' > "$REMOTE_HOME/config/domain-freshness.json"
printf '%s\n' "- remote - Remote operations (host: fixture-host; root: $ROOT; home: $REMOTE_HOME; scope: fixtures; projects: app; added 2026-10-01)" > "$HOME_DIR/data/secondmates.md"
config '[{"id":"remote","kind":"remote-inventory","route":"remote","source":"remote-skills"}]'
FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_REMOTE_HOME="$REMOTE_HOME" FM_FAKE_COLLECTOR="$COLLECTOR" collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'remote inventory baseline'
bundle
jq -e '.evidence[0].kind == "inventory-baseline" and .evidence[0].after.content == "# Remote original\n"' "$OUT" >/dev/null || fail 'remote baseline absent'
printf '# Remote changed\n' > "$REMOTE_HOME/skills/SKILL.md"
FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_REMOTE_HOME="$REMOTE_HOME" FM_FAKE_COLLECTOR="$COLLECTOR" collect "$HOME_DIR" 2026-10-14T12:00:00Z
expect_code 0 "$STATUS" 'remote inventory change'
bundle
jq -e '.evidence[0].kind == "inventory-change" and .evidence[0].after.content == "# Remote changed\n"' "$OUT" >/dev/null || fail 'remote delta absent'
FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_REMOTE_FAIL=1 FM_FAKE_REMOTE_HOME="$REMOTE_HOME" FM_FAKE_COLLECTOR="$COLLECTOR" collect "$HOME_DIR" 2026-10-15T12:00:00Z
expect_code 2 "$STATUS" 'remote transport unavailable'
bundle
jq -e '.coverage[0].complete == false and (.coverage[0].reason | contains("remote inventory transport"))' "$OUT" >/dev/null || fail 'remote transport failure lost coverage reason'
jq -e '.sources.remote.checkpoint == "2026-10-14T12:00:00Z"' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'failed remote transport advanced checkpoint'
mkdir -p "$REMOTE_HOME/skills-new"
printf '# Different root\n' > "$REMOTE_HOME/skills-new/SKILL.md"
jq -n --arg root "$REMOTE_HOME/skills-new" '{version:1,enabled:false,sources:[{id:"remote-skills",kind:"skills",root:$root}]}' > "$REMOTE_HOME/config/domain-freshness.json"
FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_REMOTE_HOME="$REMOTE_HOME" FM_FAKE_COLLECTOR="$COLLECTOR" collect "$HOME_DIR" 2026-10-16T12:00:00Z
expect_code 0 "$STATUS" 'reconfigured remote root'
bundle
jq -e '.coverage[0].baseline and .evidence[0].kind == "inventory-baseline" and .evidence[0].before == null and .evidence[0].after.content == "# Different root\n"' "$OUT" >/dev/null || fail 'remote root reconfiguration reused old before state'
printf '%s\n' '{"plugins":{}}' > "$REMOTE_HOME/skills-new/manifest.json"
printf '%s\n' '{"name":"first","version":"1"}' > "$REMOTE_HOME/skills-new/first.json"
printf '%s\n' '{"name":"second","version":"1"}' > "$REMOTE_HOME/skills-new/second.json"
jq -n --arg root "$REMOTE_HOME/skills-new" '{version:1,enabled:false,sources:[{id:"remote-skills",kind:"plugin-files",root:$root,files:[{path:"manifest.json",kind:"plugin-manifest"},{path:"first.json",kind:"plugin-version"}]}]}' > "$REMOTE_HOME/config/domain-freshness.json"
FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_REMOTE_HOME="$REMOTE_HOME" FM_FAKE_COLLECTOR="$COLLECTOR" collect "$HOME_DIR" 2026-10-17T12:00:00Z
expect_code 0 "$STATUS" 'remote plugin file baseline'
bundle
jq -e '.coverage[0].baseline and .coverage[0].surfaces == ["plugin-manifest","plugin-version"]' "$OUT" >/dev/null || fail 'remote observed surfaces omitted plugin version'
jq '.sources[0].files[1].path = "second.json"' "$REMOTE_HOME/config/domain-freshness.json" > "$REMOTE_HOME/config/domain-freshness-next.json"
mv "$REMOTE_HOME/config/domain-freshness-next.json" "$REMOTE_HOME/config/domain-freshness.json"
FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_REMOTE_HOME="$REMOTE_HOME" FM_FAKE_COLLECTOR="$COLLECTOR" collect "$HOME_DIR" 2026-10-18T12:00:00Z
expect_code 0 "$STATUS" 'reconfigured remote file list'
bundle
jq -e '.coverage[0].baseline and all(.evidence[]; .kind == "inventory-baseline" and .before == null) and any(.evidence[]; .path | endswith("second.json"))' "$OUT" >/dev/null || fail 'remote file-list reconfiguration reused old before state'
pass 'fake parent transport returns bounded remote inventory and preserves failed cursor'
jq -n '{version:1,enabled:false,sources:[{id:"remote-skills",kind:"skills",root:"/.."}]}' > "$REMOTE_HOME/config/domain-freshness.json"
FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_REMOTE_HOME="$REMOTE_HOME" FM_FAKE_COLLECTOR="$COLLECTOR" collect "$HOME_DIR" 2026-10-19T12:00:00Z
expect_code 2 "$STATUS" 'remote root resolves to filesystem root'
bundle
jq -e '.coverage[0].complete == false and (.coverage[0].reason | contains("remote inventory transport")) and (.evidence | length) == 0' "$OUT" >/dev/null || fail 'remote root-target inventory claimed complete coverage'
jq -e '.sources.remote.checkpoint == "2026-10-18T12:00:00Z"' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'remote root-target inventory advanced checkpoint'
pass 'remote inventory rejects a root target before returning a snapshot'

mkdir -p "$REMOTE_HOME/skills-new/sub"
printf '%s\n' '{"plugins":{}}' > "$REMOTE_HOME/skills-new/sub/manifest.json"
jq -n --arg root "$REMOTE_HOME/skills-new" '{version:1,enabled:false,sources:[{id:"remote-skills",kind:"plugin-files",root:$root,files:[{path:"sub/manifest.json",kind:"plugin-manifest"},{path:"sub//manifest.json",kind:"plugin-version"}]}]}' > "$REMOTE_HOME/config/domain-freshness.json"
FM_HOME="$REMOTE_HOME" bash "$COLLECTOR" inventory remote-skills > "$TMP_ROOT/remote-collision-stdout" 2> "$TMP_ROOT/remote-collision-stderr"
expect_code 1 "$?" 'remote inventory normalized path collision'
assert_grep 'invalid or duplicate inventory filename' "$TMP_ROOT/remote-collision-stderr" 'remote inventory accepted redundant separator collision'
assert_equals '' "$(cat "$TMP_ROOT/remote-collision-stdout")" 'remote inventory emitted a colliding snapshot'
FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_REMOTE_HOME="$REMOTE_HOME" FM_FAKE_COLLECTOR="$COLLECTOR" collect "$HOME_DIR" 2026-10-20T12:00:00Z
expect_code 2 "$STATUS" 'parent collection of colliding remote inventory'
bundle
jq -e '.coverage[0].complete == false and (.evidence | length) == 0' "$OUT" >/dev/null || fail 'colliding remote inventory claimed complete coverage'
jq -e '.sources.remote.checkpoint == "2026-10-18T12:00:00Z"' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'colliding remote inventory advanced checkpoint'
pass 'remote inventory CLI rejects redundant separator aliases before transport checkpoint'

new_home
config "$repo_sources"
jq -n '[range(100;200)|{number:.,html_url:("https://github.com/acme/widgets/issues/"+(.|tostring)),title:"page one",labels:[],created_at:"2026-10-13T11:00:00Z"}]' > "$FEED/issues-1.json"
issue 200 2026-10-13T10:00:00Z | jq -s . > "$FEED/issues-2.json"
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'paginated issue feed'
bundle
jq -e '(.evidence | length) == 101' "$OUT" >/dev/null || fail 'issue feed omitted second page'
# On the next day a delayed event within the overlap becomes visible.
issue 201 2026-10-13T11:58:00Z | jq -s . > "$FEED/issues-1.json"
printf '[]\n' > "$FEED/issues-2.json"
collect "$HOME_DIR" 2026-10-14T12:00:00Z
expect_code 0 "$STATUS" 'late visible issue'
bundle
jq -e '(.evidence | length) == 1 and .evidence[0].url == "https://github.com/acme/widgets/issues/201"' "$OUT" >/dev/null || fail 'late-visible overlap event was lost'
pass 'issue pagination and newly visible overlap events retain coverage'

new_home
config "$repo_sources"
collect "$HOME_DIR" "$NOW"
jq -n '[range(100;200)|{number:.,html_url:("https://github.com/acme/widgets/pull/"+(.|tostring)),title:"closed",labels:[],merged_at:null,updated_at:"2026-10-14T11:00:00Z"}]' > "$FEED/pulls-1.json"
printf '%s\n' '/repos/acme/widgets/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=2' > "$FEED/fail"
collect "$HOME_DIR" 2026-10-14T12:00:00Z
expect_code 2 "$STATUS" 'failed second PR feed page'
bundle
jq -e '.sources.forge.checkpoint == "2026-10-13T12:00:00Z"' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'failed page advanced success'
assert_grep 'per_page=100&page=2' "$FEED/requests" 'PR feed second page was not attempted'
pass 'failed PR feed page retains previous successful window'

for attempt_mode in first binding-reset; do
  new_home
  config "$repo_sources"
  if [ "$attempt_mode" = binding-reset ]; then
    collect "$HOME_DIR" "$NOW"
    expect_code 0 "$STATUS" 'checkpoint before repository binding reset'
    config '[{"id":"forge","kind":"repository","repo":"acme/gadgets"}]'
    ATTEMPT_TIME=2026-10-14T12:00:00Z
    WINDOW_START=2026-10-13T12:00:00Z
    EVENT_TIME=2026-10-13T13:00:00Z
    EVENT_REPO=gadgets
    RETRY_TIME=2026-10-17T12:00:00Z
  else
    ATTEMPT_TIME=$NOW
    WINDOW_START=2026-10-12T12:00:00Z
    EVENT_TIME=2026-10-13T11:00:00Z
    EVENT_REPO=widgets
    RETRY_TIME=2026-10-16T12:00:00Z
  fi
  printf '/repos/acme/%s/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=1\n' "$EVENT_REPO" > "$FEED/fail"
  collect "$HOME_DIR" "$ATTEMPT_TIME"
  expect_code 2 "$STATUS" "$attempt_mode first attempted window failure"
  jq -e --arg start "$WINDOW_START" '.attempts.forge.window_start == $start' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail "$attempt_mode failure did not retain attempted window"
  if [ "$attempt_mode" = binding-reset ]; then
    jq -e '.sources.forge.checkpoint == "2026-10-13T12:00:00Z"' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'binding reset failure advanced old success'
  else
    jq -e '.sources.forge == null' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'first attempt failure saved a success cursor'
  fi
  rm "$FEED/fail"
  issue 58 "$EVENT_TIME" | jq --arg repo "$EVENT_REPO" '.html_url = ("https://github.com/acme/" + $repo + "/issues/58")' | jq -s . > "$FEED/issues-1.json"
  collect "$HOME_DIR" "$RETRY_TIME"
  expect_code 0 "$STATUS" "$attempt_mode delayed recovery"
  bundle
  jq -e --arg start "$WINDOW_START" --arg when "$EVENT_TIME" '.complete and .coverage[0].window_start == $start and .evidence[0].created_at == $when' "$OUT" >/dev/null || fail "$attempt_mode retry lost original-window evidence"
  jq -e --arg now "$RETRY_TIME" '.sources.forge.checkpoint == $now and .attempts.forge == null' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail "$attempt_mode recovery did not finish attempted window"
done
pass 'first failure and binding reset retain attempted window across multi-day retry'

for feed_kind in pulls issues; do
  new_home
  config "$repo_sources"
  if [ "$feed_kind" = pulls ]; then
    jq -n '[range(1;101)|{number:.,html_url:("https://github.com/acme/widgets/pull/"+(.|tostring)),merged_at:"2026-10-13T11:00:00Z",updated_at:"2026-10-13T11:00:00Z"}]' > "$FEED/pulls-1.json"
    pr 101 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-2.json"
  else
    jq -n '[range(1;101)|{number:.,html_url:("https://github.com/acme/widgets/issues/"+(.|tostring)),created_at:"2026-10-13T11:00:00Z"}]' > "$FEED/issues-1.json"
    issue 101 2026-10-13T11:00:00Z | jq -s . > "$FEED/issues-2.json"
  fi
  jq -s '.[1] + .[0][0:99]' "$FEED/$feed_kind-1.json" "$FEED/$feed_kind-2.json" > "$FEED/$feed_kind-1-shift.json"
  jq '.[99:100]' "$FEED/$feed_kind-1.json" > "$FEED/$feed_kind-2-shift.json"
  printf '%s\n' "$feed_kind" > "$FEED/shift"
  collect "$HOME_DIR" "$NOW"
  expect_code 2 "$STATUS" "shifting $feed_kind feed"
  bundle
  jq -e '.coverage[0].complete == false and (.coverage[0].reason | contains("feed changed"))' "$OUT" >/dev/null || fail "shifting $feed_kind feed advanced coverage"
  jq -e '.sources.forge == null' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail "shifting $feed_kind feed advanced cursor"
done
pass 'shifting PR and issue pages fail coverage before checkpoint'

new_home
config "$repo_sources"
for page in $(seq 1 20); do
  jq -n --argjson page "$page" '[range(1;101)|(. + ($page - 1) * 100) | {number:.,html_url:("https://github.com/acme/widgets/issues/"+(.|tostring)),created_at:"2026-10-13T11:00:00Z"}]' > "$FEED/issues-$page.json"
done
collect "$HOME_DIR" "$NOW"
expect_code 2 "$STATUS" 'bounded page limit'
bundle
jq -e '.coverage[0].complete == false and (.coverage[0].reason | contains("pagination limit"))' "$OUT" >/dev/null || fail 'page limit claimed complete coverage'
jq -e '.sources.forge == null' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'page limit advanced cursor'
pass 'pagination bounds remain explicit incomplete coverage'

new_home
mkdir -p "$HOME_DIR/plugins"
printf '%s\n' '{"plugins":{}}' > "$HOME_DIR/plugins/manifest.json"
head -c 4096 /dev/zero | tr '\0' x | jq -Rs '{name:"preview",version:.}' > "$HOME_DIR/plugins/preview.json"
for number in $(seq 1 1998); do
  cp "$HOME_DIR/plugins/preview.json" "$HOME_DIR/plugins/version-$number.json"
done
config "$(jq -nc --arg root "$HOME_DIR/plugins" '[{id:"large",kind:"plugin-files",root:$root,files:([{path:"manifest.json",kind:"plugin-manifest"}] + [range(1;1999)|{path:("version-"+(.|tostring)+".json"),kind:"plugin-version"}])}]')"
collect "$HOME_DIR" "$NOW"
expect_code 2 "$STATUS" 'oversized inventory cursor'
bundle
jq -e '.coverage[0].complete == false and (.coverage[0].reason | contains("cursor exceeds read limit"))' "$OUT" >/dev/null || fail 'oversized cursor did not fail source coverage'
jq -e '.sources.large == null' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'oversized cursor was published'
pass 'cursor read limit fails oversized source without unreadable state'

new_home
config "$repo_sources"
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'repository checkpoint before removal'
config '[]'
collect "$HOME_DIR" 2026-10-14T12:00:00Z
expect_code 0 "$STATUS" 'repository source absent for a day'
jq -e '.sources.forge.checkpoint == "2026-10-13T12:00:00Z"' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'absent repository lost its successful checkpoint'
issue 57 2026-10-14T13:00:00Z | jq -s . > "$FEED/issues-1.json"
config "$repo_sources"
collect "$HOME_DIR" 2026-10-16T12:00:00Z
expect_code 0 "$STATUS" 'repository re-added after three days'
bundle
jq -e '.coverage[0].window_start == "2026-10-13T11:55:00Z" and .evidence[0].url == "https://github.com/acme/widgets/issues/57"' "$OUT" >/dev/null || fail 're-added repository lost an event older than 24 hours'
jq -e '.sources.forge.checkpoint == "2026-10-16T12:00:00Z"' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 're-added repository did not advance its retained checkpoint'

new_home
mkdir -p "$HOME_DIR/skills"
printf '# Before\n' > "$HOME_DIR/skills/SKILL.md"
config "$(jq -nc --arg root "$HOME_DIR/skills" '[{id:"skills",kind:"skills",root:$root}]')"
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'skill checkpoint before removal'
config '[]'
collect "$HOME_DIR" 2026-10-14T12:00:00Z
expect_code 0 "$STATUS" 'skill source absent for a day'
printf '# After\n' > "$HOME_DIR/skills/SKILL.md"
config "$(jq -nc --arg root "$HOME_DIR/skills" '[{id:"skills",kind:"skills",root:$root}]')"
collect "$HOME_DIR" 2026-10-16T12:00:00Z
expect_code 0 "$STATUS" 'skill source re-added after three days'
bundle
jq -e '.coverage[0].baseline == false and .evidence[0].kind == "inventory-change" and .evidence[0].before.content == "# Before\n" and .evidence[0].after.content == "# After\n"' "$OUT" >/dev/null || fail 're-added skill source lost its prior inventory'
pass 'inactive source cursors retain missed forge and inventory changes'

new_home
mkdir -p "$HOME_DIR/skills/one"
printf '# Original\n' > "$HOME_DIR/skills/one/SKILL.md"
config "$(jq -nc --arg root "$HOME_DIR/skills" '[{id:"skills",kind:"skills",root:$root}]')"
collect "$HOME_DIR" "$NOW"
cp "$HOME_DIR/data/domain-freshness/cursors.json" "$HOME_DIR/old-cursor.json"
printf '# New\n' > "$HOME_DIR/skills/one/SKILL.md"
collect "$HOME_DIR" 2026-10-14T12:00:00Z
bundle
REPLAY_BUNDLE=$OUT
# Simulate a crash after durable evidence publication but before cursor rename.
cp "$HOME_DIR/old-cursor.json" "$HOME_DIR/data/domain-freshness/cursors.json"
collect "$HOME_DIR" 2026-10-14T12:00:00Z
expect_code 0 "$STATUS" 'publication replay'
assert_equals "$REPLAY_BUNDLE" "$OUT" 'publication replay changed evidence identity'
collect "$HOME_DIR" 2026-10-15T12:00:00Z
assert_equals '' "$OUT" 'settled replay emitted unchanged evidence'
# Every advanced successful checkpoint has a corresponding durable observation.
find "$HOME_DIR/data/domain-freshness/bundles" -name '*.json' -exec cat '{}' + | jq -s -e 'any(.[]; .collected_at == "2026-10-15T12:00:00Z" and .complete and (.evidence | length) == 0)' >/dev/null || fail 'silent checkpoint has no durable observation'
pass 'publication replay converges and silent checkpoints retain observations'

new_home
mkdir -p "$HOME_DIR/skills/one/resources"
printf '# Entry\n' > "$HOME_DIR/skills/one/SKILL.md"
printf '# Guidance\n' > "$HOME_DIR/skills/one/resources/ENTRY.md"
config "$(jq -nc --arg root "$HOME_DIR/skills" '[{id:"skills",kind:"skills",root:$root}]')"
collect "$HOME_DIR" "$NOW"
bundle
printf '# Revised guidance\n' > "$HOME_DIR/skills/one/resources/ENTRY.md"
collect "$HOME_DIR" 2026-10-14T12:00:00Z
expect_code 0 "$STATUS" 'supporting resource change'
assert_equals '' "$OUT" 'supporting resource changed SKILL.md fingerprint'
pass 'only SKILL.md content participates in skill fingerprints'

new_home
config "$repo_sources"
collect "$HOME_DIR" "$NOW"
FM_HOME="$HOME_DIR" FM_DOMAIN_FRESHNESS_NOW=2026-10-14T12:00:00Z \
  PATH="$FAKEBIN:$PATH" FM_FAKE_FEED="$FEED" \
  python3 - "$HOME_DIR/data/domain-freshness/.collect.lock" "$COLLECTOR" <<'PY'
import fcntl
import os
import subprocess
import sys
lock = open(sys.argv[1], 'w')
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
result = subprocess.run(['bash', sys.argv[2], 'collect'], capture_output=True, text=True)
if result.returncode != 1 or result.stdout:
    sys.exit('concurrent collector bypassed held lock')
# Abrupt process death must release the lock without unlinking its inode.
os._exit(0)
PY
expect_code 0 "$?" 'exclusive lock contention'
jq -e '.sources.forge.checkpoint == "2026-10-13T12:00:00Z"' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'contending collector changed cursor'
collect "$HOME_DIR" 2026-10-14T12:00:00Z
expect_code 0 "$STATUS" 'collector after lock owner death'
jq -e '.sources.forge.checkpoint == "2026-10-14T12:00:00Z"' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'lock owner death did not allow recovery'
pass 'collector contention is refused and lock owner death permits recovery'
