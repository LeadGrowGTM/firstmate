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
  /repos/*/pulls/*)
    number=${path##*/}
    file="$FM_FAKE_FEED/detail-$number.json" ;;
  *) exit 92 ;;
esac
[ ! -e "$FM_FAKE_FEED/fail" ] || { grep -Fqx "$path" "$FM_FAKE_FEED/fail" && exit 93 || :; }
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
  jq -n --argjson n "$1" --arg when "$2" --argjson count "$3" \
    '{html_url:("https://github.com/acme/widgets/pull/"+($n|tostring)),merged_at:$when,changed_files:$count,base:{ref:"main",sha:"base-sha",repo:{full_name:"acme/widgets"}},head:{ref:"topic",sha:"head-sha",repo:{full_name:"acme/widgets"}}}'
}
instruction_content() {
  jq -n --arg content "$(printf '%s' "$3" | base64 | tr -d '\n')" \
    '{type:"file",encoding:"base64",content:$content}' > "$FEED/content-$1-$2.json"
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
printf '%s\n' '{"plugins":{"demo":[{"version":"1.0","scope":"user"}]},"token":"secret-one"}' > "$HOME_DIR/plugins/manifest.json"
printf '%s\n' '{"enabledPlugins":{"demo":true},"token":"secret-one"}' > "$HOME_DIR/plugins/enabled.json"
config "$(jq -nc --arg root "$HOME_DIR/plugins" '[{id:"plugins",kind:"plugin-files",root:$root,files:[{path:"manifest.json",kind:"plugin-manifest"},{path:"enabled.json",kind:"plugin-enablement"}]}]')"
collect "$HOME_DIR" "$NOW"
bundle
jq -e '.evidence | length == 2 and (all(.[]; .kind == "inventory-baseline"))' "$OUT" >/dev/null || fail 'plugin baseline absent'
assert_no_grep 'secret-one' "$OUT" 'irrelevant manifest field persisted in bundle'
assert_no_grep 'secret-one' "$HOME_DIR/data/domain-freshness/cursors.json" 'irrelevant manifest field persisted in cursor'
printf '%s\n' '{"plugins":{"demo":[{"version":"1.0","scope":"user"}]},"token":"secret-two"}' > "$HOME_DIR/plugins/manifest.json"
printf '%s\n' '{"enabledPlugins":{"demo":true},"token":"secret-two"}' > "$HOME_DIR/plugins/enabled.json"
collect "$HOME_DIR" 2026-10-14T12:00:00Z
assert_equals '' "$OUT" 'irrelevant manifest fields changed fingerprint'
printf '%s\n' '{"plugins":{"demo":[{"version":"2.0","scope":"user"}]}}' > "$HOME_DIR/plugins/manifest.json"
printf '%s\n' '{"enabledPlugins":{"demo":false}}' > "$HOME_DIR/plugins/enabled.json"
collect "$HOME_DIR" 2026-10-15T12:00:00Z
bundle
jq -e '.evidence | length == 2 and (any(.[]; .after.manifest.plugins.demo[0].version == "2.0")) and (any(.[]; .after.manifest.enabledPlugins.demo == false))' "$OUT" >/dev/null || fail 'effective plugin changes absent'
pass 'plugin projections omit irrelevant fields and detect effective changes'

new_home
mkdir -p "$HOME_DIR/skills/one" "$HOME_DIR/plugins"
printf 'first script' > "$HOME_DIR/skills/one/run.py"
printf '%s\n' '{"plugins":{}}' > "$HOME_DIR/plugins/manifest.json"
printf '%s\n' '{"enabledPlugins":{}}' > "$HOME_DIR/plugins/enabled.json"
printf 'first template' > "$HOME_DIR/plugins/template.txt"
config "$(jq -nc --arg skills "$HOME_DIR/skills" --arg plugins "$HOME_DIR/plugins" '[
  {id:"skills",kind:"skills",root:$skills},
  {id:"plugins",kind:"plugin-files",root:$plugins,files:[{path:"manifest.json",kind:"plugin-manifest"},{path:"enabled.json",kind:"plugin-enablement"},{path:"template.txt",kind:"asset"}]}
]')"
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'asset baselines'
printf 'second script' > "$HOME_DIR/skills/one/run.py"
printf 'second template' > "$HOME_DIR/plugins/template.txt"
collect "$HOME_DIR" 2026-10-14T12:00:00Z
expect_code 0 "$STATUS" 'asset changes'
bundle
jq -e '(.evidence | length) == 2 and all(.evidence[]; .kind == "inventory-change" and .before.kind == "asset" and .after.kind == "asset" and .before.digest != .after.digest and (.after | has("content") | not) and (.after | has("manifest") | not))' "$OUT" >/dev/null || fail 'effective asset change or digest-only evidence missing'
rm "$HOME_DIR/plugins/template.txt"
collect "$HOME_DIR" 2026-10-15T12:00:00Z
expect_code 0 "$STATUS" 'removed plugin asset'
bundle
jq -e --arg path "$HOME_DIR/plugins/template.txt" '(.evidence | length) == 1 and .evidence[0].path == $path and .evidence[0].before.kind == "asset" and .evidence[0].after == null and .coverage[1].surfaces == ["plugin-enablement","plugin-manifest"]' "$OUT" >/dev/null || fail 'removed plugin asset did not produce a delta'
pass 'skill and plugin assets change digest-only fingerprints'

new_home
mkdir -p "$HOME_DIR/plugins/optional"
printf '%s\n' '{"plugins":{}}' > "$HOME_DIR/plugins/manifest.json"
printf '%s\n' '{"enabledPlugins":{}}' > "$HOME_DIR/plugins/enabled.json"
config "$(jq -nc --arg root "$HOME_DIR/plugins" '[{id:"plugins",kind:"plugin-files",root:$root,files:[{path:"manifest.json",kind:"plugin-manifest"},{path:"enabled.json",kind:"plugin-enablement"},{path:"optional/template.txt",kind:"asset"}]}]')"
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'initially absent plugin asset'
bundle
jq -e '.coverage[0].complete and .coverage[0].baseline and .coverage[0].surfaces == ["plugin-enablement","plugin-manifest"] and (.evidence | length) == 2' "$OUT" >/dev/null || fail 'initially absent plugin asset broke baseline'
rmdir "$HOME_DIR/plugins/optional"
ln -s "$HOME_DIR/plugins/missing" "$HOME_DIR/plugins/optional"
collect "$HOME_DIR" 2026-10-14T12:00:00Z
expect_code 2 "$STATUS" 'broken optional asset parent'
bundle
jq -e '.coverage[0].complete == false and (.evidence | length) == 0' "$OUT" >/dev/null || fail 'broken optional asset parent claimed complete coverage'
jq -e '.sources.plugins.checkpoint == "2026-10-13T12:00:00Z"' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'broken optional asset parent advanced checkpoint'
pass 'absent assets need an available parent and removals emit deltas'

new_home
mkdir -p "$HOME_DIR/plugins"
printf '# Only instructions\n' > "$HOME_DIR/plugins/PLUGIN.md"
config "$(jq -nc --arg root "$HOME_DIR/plugins" '[{id:"plugins",kind:"plugin-files",root:$root,files:[{path:"PLUGIN.md",kind:"instruction"}]}]')"
collect "$HOME_DIR" "$NOW"
expect_code 2 "$STATUS" 'plugin source without install state'
bundle
jq -e '.coverage[0].complete == false and (.coverage[0].reason | contains("manifest and enablement")) and (.evidence | length) == 0' "$OUT" >/dev/null || fail 'instruction-only plugin source claimed complete coverage'
jq -e '.sources.plugins == null' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'incomplete plugin source advanced cursor'
pass 'plugin coverage requires manifest and enablement declarations'

new_home
mkdir -p "$HOME_DIR/plugins"
printf '%s\n' '{"plugins":{}}' > "$HOME_DIR/plugins/manifest.json"
printf '%s\n' '{"enabledPlugins":{}}' > "$HOME_DIR/plugins/enabled.json"
printf '%s\n' '{"name":"demo","version":"1"}' > "$HOME_DIR/plugins/version.json"
printf '# Installed\n' > "$HOME_DIR/plugins/PLUGIN.md"
config "$(jq -nc --arg root "$HOME_DIR/plugins" '[{id:"plugins",kind:"plugin-files",root:$root,files:[{path:"manifest.json",kind:"plugin-manifest"},{path:"enabled.json",kind:"plugin-enablement"},{path:"version.json",kind:"plugin-version"},{path:"PLUGIN.md",kind:"instruction"}]}]')"
collect "$HOME_DIR" "$NOW"
rm "$HOME_DIR/plugins/version.json" "$HOME_DIR/plugins/PLUGIN.md"
collect "$HOME_DIR" 2026-10-14T12:00:00Z
expect_code 0 "$STATUS" 'removed plugin content'
bundle
jq -e '(.evidence | length) == 2 and all(.evidence[]; .kind == "inventory-change" and .after == null)' "$OUT" >/dev/null || fail 'removed plugin content did not produce null after'
jq -e '.coverage[0].surfaces == ["plugin-enablement","plugin-manifest"]' "$OUT" >/dev/null || fail 'absent optional files counted as observed'
rm "$HOME_DIR/plugins/manifest.json"
collect "$HOME_DIR" 2026-10-15T12:00:00Z
expect_code 2 "$STATUS" 'missing required plugin manifest'
pass 'plugin content removal is a delta and required manifest loss fails coverage'

new_home
mkdir -p "$HOME_DIR/plugins/optional"
printf '%s\n' '{"plugins":{}}' > "$HOME_DIR/plugins/manifest.json"
printf '%s\n' '{"enabledPlugins":{}}' > "$HOME_DIR/plugins/enabled.json"
config "$(jq -nc --arg root "$HOME_DIR/plugins" '[{id:"plugins",kind:"plugin-files",root:$root,files:[{path:"manifest.json",kind:"plugin-manifest"},{path:"enabled.json",kind:"plugin-enablement"},{path:"optional/PLUGIN.md",kind:"instruction"},{path:"optional/version.json",kind:"plugin-version"}]}]')"
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'absent optional plugin files'
rmdir "$HOME_DIR/plugins/optional"
ln -s "$HOME_DIR/plugins/missing" "$HOME_DIR/plugins/optional"
collect "$HOME_DIR" 2026-10-14T12:00:00Z
expect_code 2 "$STATUS" 'broken optional inventory parent'
bundle
jq -e '.coverage[0].complete == false and (.evidence | length) == 0' "$OUT" >/dev/null || fail 'broken optional parent claimed complete coverage'
jq -e '.sources.plugins.checkpoint == "2026-10-13T12:00:00Z"' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'broken optional parent advanced checkpoint'
pass 'missing optional files remain optional only under available parents'

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
jq -n '[range(0;100)|{filename:("src/file-"+(.|tostring)),status:"modified",sha:"sha",additions:1,deletions:0,changes:1}]' > "$FEED/files-12-1.json"
printf '[{"filename":"src/last","status":"added","sha":"last","additions":1,"deletions":0,"changes":1}]\n' > "$FEED/files-12-2.json"
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'paginated PR files'
bundle
jq -e '.evidence[0].kind == "merged-pr" and (.evidence[0].files | length == 101) and .evidence[0].files[-1].filename == "src/last" and .evidence[0].base.ref == "main" and .evidence[0].head.sha == "head-sha"' "$OUT" >/dev/null || fail 'paginated PR file metadata incomplete'
assert_grep '/pulls/12/files?per_page=100&page=2' "$FEED/requests" 'second PR file page was not requested'
pass 'merged PR includes every paginated file and base/head metadata'

new_home
config '[{"id":"forge","kind":"repository","repo":"ACME/WIDGETS"}]'
mkdir -p "$HOME_DIR/data/owned"
printf '%s\n' '{"schema":"fm-contributions.v1","task":"owned","records":[{"url":"https://github.com/AcMe/WidGets/pull/30","kind":"pr","observation":{"state":"merged"}}]}' > "$HOME_DIR/data/owned/contributions.json"
pr 30 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
issue 31 2026-10-13T11:00:00Z | jq -s . > "$FEED/issues-1.json"
detail 30 2026-10-13T11:00:00Z 4 > "$FEED/detail-30.json"
jq -n '[
  {filename:"AGENTS.md",status:"modified"},
  {filename:"skills/one/SKILL.md",status:"added"},
  {filename:"CLAUDE.md",status:"removed"},
  {filename:"skills/new.md",previous_filename:"skills/old.md",status:"renamed"}
]' > "$FEED/files-30-1.json"
instruction_content base-sha AGENTS.md '# Before'
instruction_content head-sha AGENTS.md '# After'
instruction_content head-sha SKILL.md '# Added'
instruction_content base-sha CLAUDE.md '# Removed'
instruction_content base-sha old.md '# Old name'
instruction_content head-sha new.md '# New name'
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'canonical forge casing and instruction revisions'
bundle
jq -e '(.evidence | length) == 2 and
  (any(.evidence[]; .kind == "new-issue" and .repository == "acme/widgets")) and
  (any(.evidence[]; .kind == "merged-pr" and .repository == "acme/widgets" and .base.repository == "acme/widgets" and
    .linked_contributions[0].task == "owned" and
    .files[0].instruction.before.content == "# Before" and .files[0].instruction.after.content == "# After" and
    .files[1].instruction.before == null and .files[1].instruction.after.content == "# Added" and
    .files[2].instruction.before.content == "# Removed" and .files[2].instruction.after == null and
    .files[3].instruction.before.content == "# Old name" and .files[3].instruction.after.content == "# New name"))' "$OUT" >/dev/null || fail 'canonical casing or instruction content missing'
pass 'canonical repository casing and changed instruction revisions retain provenance'

new_home
config "$repo_sources"
pr 40 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
detail 40 2026-10-13T11:00:00Z 1 | jq '.head.repo.full_name = "contrib/widgets"' > "$FEED/detail-40.json"
printf '[{"filename":"AGENTS.md","status":"modified"}]\n' > "$FEED/files-40-1.json"
instruction_content base-sha AGENTS.md '# Base revision'
instruction_content head-sha AGENTS.md '# Fork revision'
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'fork PR instruction content'
bundle
jq -e '.evidence[0].head.repository == "contrib/widgets" and .evidence[0].files[0].instruction.before.content == "# Base revision" and .evidence[0].files[0].instruction.after.content == "# Fork revision"' "$OUT" >/dev/null || fail 'fork instruction content was not captured'
assert_grep '/repos/contrib/widgets/contents/AGENTS.md?ref=head-sha' "$FEED/requests" 'fork head repository was not queried'
assert_no_grep '/repos/acme/widgets/contents/AGENTS.md?ref=head-sha' "$FEED/requests" 'fork head read used base repository'
pass 'fork instruction after content comes from its head repository'

deleted_blob_content='# Deleted fork revision'
deleted_blob_sha=$(printf '%s' "$deleted_blob_content" | git hash-object --stdin)
new_home
config "$repo_sources"
pr 41 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
detail 41 2026-10-13T11:00:00Z 1 | jq '.head.repo = null' > "$FEED/detail-41.json"
jq -n --arg sha "$deleted_blob_sha" '[{filename:"AGENTS.md",status:"added",sha:$sha}]' > "$FEED/files-41-1.json"
jq -n --arg sha "$deleted_blob_sha" --arg content "$(printf '%s' "$deleted_blob_content" | base64 | tr -d '\n')" '{sha:$sha,encoding:"base64",content:$content}' > "$FEED/blob-$deleted_blob_sha.json"
collect "$HOME_DIR" "$NOW"
expect_code 0 "$STATUS" 'deleted fork blob content'
bundle
jq -e '.evidence[0].head.repository == null and .evidence[0].files[0].instruction.before == null and .evidence[0].files[0].instruction.after.content == "# Deleted fork revision"' "$OUT" >/dev/null || fail 'deleted fork instruction blob was not captured'
assert_grep "/repos/acme/widgets/git/blobs/$deleted_blob_sha" "$FEED/requests" 'deleted fork blob was not queried'
pass 'deleted fork uses PR file blob when available'

new_home
config "$repo_sources"
pr 41 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
detail 41 2026-10-13T11:00:00Z 1 | jq '.head.repo = null' > "$FEED/detail-41.json"
jq -n --arg sha "$deleted_blob_sha" '[{filename:"AGENTS.md",status:"added",sha:$sha}]' > "$FEED/files-41-1.json"
collect "$HOME_DIR" "$NOW"
expect_code 2 "$STATUS" 'unavailable deleted fork blob'
bundle
jq -e '.coverage[0].complete == false and (.evidence | length) == 0' "$OUT" >/dev/null || fail 'unavailable deleted fork blob claimed complete coverage'
jq -e '.sources.forge == null' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'unavailable deleted fork blob advanced checkpoint'
pass 'unavailable deleted fork blob leaves explicit incomplete coverage'

new_home
config "$repo_sources"
mkdir -p "$HOME_DIR/data/owned"
printf '%s\n' '{"schema":"fm-contributions.v1","task":"owned","records":[{"url":"https://github.com/acme/widgets/pull/12","kind":"pr","checked_at":"2026-10-13T11:30:00Z","error":null,"observation":{"head":"0123456789012345678901234567890123456789","state":"merged","draft":false,"mergeable":"mergeable"}}]}' > "$HOME_DIR/data/owned/contributions.json"
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
  {url:"https://github.com/acme/widgets/pull/12",kind:"pr",checked_at:"2026-10-13T11:30:00Z",error:null,observation:{head:"0123456789012345678901234567890123456789",state:"merged",draft:false,mergeable:"mergeable"}},
  {url:"https://github.com/acme/widgets/issues/13",kind:"issue",checked_at:"2026-10-13T11:31:00Z",error:null,observation:{state:"open",ready:true}}
]}' > "$HOME_DIR/data/active/contributions.json"
jq -n '{schema:"fm-contributions.v1",task:"retired",records:[
  {url:"https://github.com/acme/widgets/pull/12",kind:"pr",retired:{actor:"captain",reason:"settled",at:"2026-10-13T10:00:00Z"},observation:{state:"merged"}},
  {url:"https://github.com/acme/widgets/issues/13",kind:"issue",retired:{actor:"captain",reason:"settled",at:"2026-10-13T10:00:00Z"},observation:{state:"open",ready:false}}
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
pr 12 2026-10-13T11:00:00Z 2026-10-13T11:00:00Z | jq -s . > "$FEED/pulls-1.json"
detail 12 2026-10-13T11:00:00Z 2 > "$FEED/detail-12.json"
printf '[{"filename":"src/only","status":"added"}]\n' > "$FEED/files-12-1.json"
collect "$HOME_DIR" "$NOW"
expect_code 2 "$STATUS" 'incomplete PR changed-file count'
bundle
jq -e '.complete == false and .coverage[0].complete == false and (.coverage[0].reason | contains("changed-file")) and (.evidence | length == 0)' "$OUT" >/dev/null || fail 'truncated PR files were treated as complete'
jq -e '.sources.forge == null' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'truncated PR feed advanced the cursor'
pass 'changed-file count mismatch fails coverage without checkpoint'

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
printf '%s\n' '{"enabledPlugins":{}}' > "$REMOTE_HOME/skills-new/enabled.json"
printf 'first asset' > "$REMOTE_HOME/skills-new/first.txt"
printf 'second asset' > "$REMOTE_HOME/skills-new/second.txt"
jq -n --arg root "$REMOTE_HOME/skills-new" '{version:1,enabled:false,sources:[{id:"remote-skills",kind:"plugin-files",root:$root,files:[{path:"manifest.json",kind:"plugin-manifest"},{path:"enabled.json",kind:"plugin-enablement"},{path:"first.txt",kind:"asset"},{path:"optional.json",kind:"plugin-version"}]}]}' > "$REMOTE_HOME/config/domain-freshness.json"
FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_REMOTE_HOME="$REMOTE_HOME" FM_FAKE_COLLECTOR="$COLLECTOR" collect "$HOME_DIR" 2026-10-17T12:00:00Z
expect_code 0 "$STATUS" 'remote plugin file baseline'
bundle
jq -e '.coverage[0].baseline and .coverage[0].surfaces == ["asset","plugin-enablement","plugin-manifest"]' "$OUT" >/dev/null || fail 'remote observed surfaces included absent optional file'
jq '.sources[0].files[2].path = "second.txt"' "$REMOTE_HOME/config/domain-freshness.json" > "$REMOTE_HOME/config/domain-freshness-next.json"
mv "$REMOTE_HOME/config/domain-freshness-next.json" "$REMOTE_HOME/config/domain-freshness.json"
FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_REMOTE_HOME="$REMOTE_HOME" FM_FAKE_COLLECTOR="$COLLECTOR" collect "$HOME_DIR" 2026-10-18T12:00:00Z
expect_code 0 "$STATUS" 'reconfigured remote file list'
bundle
jq -e '.coverage[0].baseline and all(.evidence[]; .kind == "inventory-baseline" and .before == null) and any(.evidence[]; .path | endswith("second.txt"))' "$OUT" >/dev/null || fail 'remote file-list reconfiguration reused old before state'
pass 'fake parent transport returns bounded remote inventory and preserves failed cursor'

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
printf '%s\n' '{"enabledPlugins":{}}' > "$HOME_DIR/plugins/enabled.json"
head -c 4096 /dev/zero | tr '\0' x > "$HOME_DIR/plugins/preview.md"
for number in $(seq 1 1998); do
  cp "$HOME_DIR/plugins/preview.md" "$HOME_DIR/plugins/instruction-$number.md"
done
config "$(jq -nc --arg root "$HOME_DIR/plugins" '[{id:"large",kind:"plugin-files",root:$root,files:([{path:"manifest.json",kind:"plugin-manifest"},{path:"enabled.json",kind:"plugin-enablement"}] + [range(1;1999)|{path:("instruction-"+(.|tostring)+".md"),kind:"instruction"}])}]')"
collect "$HOME_DIR" "$NOW"
expect_code 2 "$STATUS" 'oversized inventory cursor'
bundle
jq -e '.coverage[0].complete == false and (.coverage[0].reason | contains("cursor exceeds read limit"))' "$OUT" >/dev/null || fail 'oversized cursor did not fail source coverage'
jq -e '.sources.large == null' "$HOME_DIR/data/domain-freshness/cursors.json" >/dev/null || fail 'oversized cursor was published'
pass 'cursor read limit fails oversized source without unreadable state'

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
bundle
jq -e '(.evidence | length) == 1 and (.evidence[0].path | endswith("resources/ENTRY.md")) and .evidence[0].before.content == "# Guidance\n"' "$OUT" >/dev/null || fail 'supporting skill instruction change was missed'
pass 'supporting skill instructions participate in fingerprints'

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
