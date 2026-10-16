#!/usr/bin/env bash
# Exercise both Boat task entry points as executables, using copied scripts,
# real validation/locks/Git, and fixture-only Boat, transport, and worker helpers.
# No real Boat, SSH, tmux, home, endpoint, or remote service is reached.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
for tool in jq tasks-axi; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'skip: %s not found\n' "$tool"; exit 0; }
done

TMP_ROOT=$(fm_test_tmproot fm-boat-send)
NOW=1791892800
BIN="$TMP_ROOT/bin"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
mkdir -p "$BIN"
for script in fm-boat-send.sh fm-boat-worker.sh fm-secondmate-registry-lib.sh \
  fm-tasks-axi.sh; do
  cp "$ROOT/bin/$script" "$BIN/$script"
done
cp "$ROOT/bin/"*-lib.sh "$BIN/"
cat > "$BIN/fm-backend.sh" <<'SH'
#!/usr/bin/env bash
fm_backend_name() { cat "$FM_HOME/config/backend"; }
fm_backend_source() { [ "$1" = tmux ]; }
fm_backend_of_meta() { sed -n 's/^backend=//p' "$1" | awk 'NR==1 { found=1; print } END { if (!found) print "tmux" }'; }
fm_backend_tmux_visible_capture() {
  printf 'capture %s\n' "$1" >> "$FIXTURES/calls"
  if [ -e "$FIXTURES/trust" ]; then
    printf 'Do you trust the contents of this directory?\n\n› 1. Yes, I trust this folder\n  2. No, exit\n'
  elif [ -e "$FIXTURES/quoted-trust" ]; then
    printf 'FIRSTMATE_OP: v1 launch-brief: Fix the \"Trust this folder?\" prompt\nDo you trust the contents of this directory?\n› 1. Yes, I trust this folder\n  2. No, exit\n'
  elif [ -e "$FIXTURES/quoted-no-op" ]; then
    printf 'Quoted tool output:\nDo you trust the contents of this directory?\n› 1. Yes, I trust this folder\n  2. No, exit\n'
  elif [ -e "$FIXTURES/quoted-exact" ]; then
    printf 'Do you trust the contents of this directory?\n› 1. Yes, I trust this folder\n  2. No, exit\n'
  elif [ -e "$FIXTURES/negative-trust" ]; then
    printf 'Do you trust the contents of this directory?\n  1. Yes, I trust this folder\n› 2. No, exit\n'
  else printf 'Worker running\n'; fi
}
fm_backend_tmux_send_key() {
  printf 'key %s\n' "$*" >> "$FIXTURES/calls"
}
fm_backend_tmux_window_inventory() {
  printf 'inventory %s\n' "$1" >> "$FIXTURES/calls"
  [ "$1" = '=firstmate' ] || return 1
  [ ! -f "$FIXTURES/inventory.fail" ] || return 1
  [ ! -f "$FIXTURES/inventory.absent" ] || return 2
  cat "$FIXTURES/windows"
}
SH
REAL_DATE=$(command -v date)
REAL_CAT=$(command -v cat)
REAL_TIMEOUT=$(command -v timeout || command -v gtimeout || true)
cat > "$FAKEBIN/cat" <<SH
#!/usr/bin/env bash
if [ "\$*" = /proc/sys/kernel/random/boot_id ]; then
  exec '$REAL_CAT' "\$FIXTURES/boot-id"
fi
exec '$REAL_CAT' "\$@"
SH
if [ -n "$REAL_TIMEOUT" ]; then
  cat > "$FAKEBIN/timeout" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$3" >> "\$FIXTURES/timeout.calls"
exec '$REAL_TIMEOUT' "\$@"
SH
fi
cat > "$FAKEBIN/date" <<SH
#!/usr/bin/env bash
if [ "\$*" = +%s ]; then
  printf '%s\n' '$NOW'
else exec '$REAL_DATE' "\$@"; fi
SH
cat > "$FAKEBIN/boat" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'boat %s\n' "$*" >> "$FIXTURES/calls"
[ "${1:-}" = --no-update ] || exit 97
shift
box=$(cat "$FIXTURES/box-id")
case "$*" in
  'limits --json')
    file=limits
    if [ -e "$FIXTURES/independent-resume" ]; then
      : > "$FIXTURES/resumed"
      printf '33333333-3333-4333-8333-333333333333\n' > "$FIXTURES/boot-id"
      printf 'independent-resume during limits read\n' >> "$FIXTURES/calls"
    fi
    ;;
  'list --all --json') file=list ;;
  "info $box --json")
    file=info
    [ ! -e "$FIXTURES/resumed" ] || file=ready
    ;;
  "exec $box --json -- cat /proc/sys/kernel/random/boot_id")
    jq -n --arg id "$(cat "$FIXTURES/boot-id")" '{exitCode:0,stdout:($id+"\n")}'
    exit 0
    ;;
  "usage $box --since $((BOAT_NOW - 86400)) --json") file=usage ;;
  "resume $box --environment fm-code --ttl 14400 --json"|"resume $box --environment fm-code --ttl 7200 --json")
    : > "$FIXTURES/resumed"
    printf '%s\n' '22222222-2222-4222-8222-222222222222' > "$FIXTURES/boot-id"
    printf '{}\n'
    exit 0
    ;;
  "resume $box --json")
    : > "$FIXTURES/resumed"
    printf '%s\n' '33333333-3333-4333-8333-333333333333' > "$FIXTURES/boot-id"
    printf '{}\n'
    exit 0
    ;;
  "stop $box --json") rm -f "$FIXTURES/resumed"; printf '{}\n'; exit 0 ;;
  *) printf 'unexpected Boat call: %s\n' "$*" >&2; exit 97 ;;
esac
[ ! -e "$FIXTURES/$file.fail" ] || exit 124
cat "$FIXTURES/$file.json"
SH
cat > "$BIN/fm-boat-alias-refresh.sh" <<'SH'
#!/usr/bin/env bash
printf 'alias %s\n' "$*" >> "$FIXTURES/calls"
# A post-stop check parks the alias; the real helper refuses a stopped box.
[ "$*" != '--verify boat-prove' ] || exit 1
[ "$*" = "$(cat "$FIXTURES/box-id") boat-prove" ] || exit 97
[ ! -e "$FIXTURES/rotate-on-alias" ] || printf '%s\n' '33333333-3333-4333-8333-333333333333' > "$FIXTURES/boot-id"
[ ! -e "$FIXTURES/alias.fail" ]
SH
cat > "$BIN/fm-on.sh" <<'SH'
#!/usr/bin/env bash
printf 'on %s\n' "$*" >> "$FIXTURES/calls"
if [ "${1:-}" = boat-eng ] && [ "${2:-}" = fm-boat-worker.sh ] && [ "${3:-}" = idle ]; then
  FM_HOME="$FIXTURE_REMOTE_HOME" "$BIN/fm-boat-worker.sh" idle "$4"
  status=$?
  [ ! -e "$FIXTURES/rotate-after-idle" ] || printf '%s\n' '33333333-3333-4333-8333-333333333333' > "$FIXTURES/boot-id"
  exit "$status"
fi
if [ "${1:-}" = boat-eng ] && [ "${2:-}" = fm-boat-worker.sh ] && [ "${3:-}" = teardown ]; then
  FM_HOME="$FIXTURE_REMOTE_HOME" "$BIN/fm-boat-worker.sh" teardown "$4" "$5"
  status=$?
  [ ! -e "$FIXTURES/rotate-after-teardown" ] || printf '%s\n' '33333333-3333-4333-8333-333333333333' > "$FIXTURES/boot-id"
  exit "$status"
fi
[ "${1:-}" = --stdin ] && [ "${2:-}" = boat-eng ] && [ "${3:-}" = fm-boat-worker.sh ] && [ "${4:-}" = spawn ] || exit 97
cat > "$FIXTURES/transport.request"
if [ -e "$FIXTURES/use-real-worker" ]; then
  FM_HOME="$FIXTURE_REMOTE_HOME" "$BIN/fm-boat-worker.sh" spawn "$5" < "$FIXTURES/transport.request"
  exit $?
fi
if [ ! -e "$FIXTURES/bare-success" ]; then
  printf 'boat-started: %s (fresh worker status)\n' "$(jq -r .id "$FIXTURES/transport.request")"
fi
exit "$(cat "$FIXTURES/transport.code" 2>/dev/null || printf 0)"
SH
cat > "$BIN/fm-brief.sh" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'brief %s\n' "$*" >> "$FIXTURES/calls"
if [ -e "$FIXTURES/use-real-brief" ]; then
  exec "$REAL_BRIEF" "$@"
fi
mkdir -p "$FM_HOME/data/$1"
printf '## Intent\n{TASK}\n## Spec\n{FIRSTMATE_SPEC}\n' > "$FM_HOME/data/$1/brief.md"
SH
cat > "$BIN/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf 'spawn %s\n' "$*" >> "$FIXTURES/calls"
if [ -e "$FIXTURES/spawn.fail" ]; then exit 1; fi
if [ -e "$FIXTURES/spawn.postlaunch.fail" ]; then
  : > "$FIXTURES/endpoint-launched"
  printf 'fm-%s\n' "$1" >> "$FIXTURES/windows"
  exit 1
fi
printf '%s\n' "$@" > "$FIXTURES/spawn.argv"
kind=ship
for arg in "$@"; do [ "$arg" != --scout ] || kind=scout; done
if [ -e "$FIXTURES/spawn-status" ]; then
  cat "$FIXTURES/spawn-status" >> "$FM_HOME/state/$1.status"
elif [ ! -e "$FIXTURES/no-start" ] && [ ! -e "$FIXTURES/trust" ]; then
  printf 'working [at=1791892800]: brief consumed\n' >> "$FM_HOME/state/$1.status"
fi
printf 'kind=%s\nproject=%s\n' "$kind" "$2" > "$FM_HOME/state/$1.meta"
SH
cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'gh-axi %s\n' "$*" >> "$FIXTURES/calls"
[ "${1:-}" = api ] && { [ "${2:-}" = user ] || [ "${2:-}" = /user ]; } || exit 97
[ ! -e "$FIXTURES/github.fail" ] || { printf 'fixture GitHub account unavailable\n' >&2; exit 1; }
if [ -f "$FIXTURES/github-response" ]; then cat "$FIXTURES/github-response"; exit 0; fi
jq -r '"api_response:\n  body: fm_boat_identity=\(tojson|@base64)\n  truncated: false"' "$FIXTURES/github-account"
SH
cat > "$BIN/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
printf 'hold %s\n' "$*" >> "$FIXTURES/calls"
[ "$1" = verify ] && [ "$2" = task-one ] && [ ! -e "$FIXTURES/hold-missing" ]
SH
cat > "$BIN/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
printf 'teardown %s\n' "$*" >> "$FIXTURES/calls"
[ ! -e "$FIXTURES/teardown.fail" ] || exit 1
rm "$FM_HOME/state/$1.meta"
grep -Fxv "fm-$1" "$FIXTURES/windows" > "$FIXTURES/windows.new" || true
mv "$FIXTURES/windows.new" "$FIXTURES/windows"
SH
# These guards make accidental fixture escape a failure instead of contacting
# an ambient terminal server or endpoint.
for tool in tmux ssh; do
  cat > "$FAKEBIN/$tool" <<'SH'
#!/usr/bin/env bash
printf 'unexpected live interface: %s\n' "$0" >&2
exit 97
SH
done
chmod +x "$BIN/"*.sh "$FAKEBIN/"*

new_case() {
  CASE="$TMP_ROOT/$1"
  FIXTURES="$CASE/fixtures"
  LOCAL_HOME="$CASE/local"
  REMOTE_HOME="$CASE/remote"
  mkdir -p "$FIXTURES" "$CASE/user-home" "$LOCAL_HOME/data" \
    "$LOCAL_HOME/state" "$LOCAL_HOME/config" "$REMOTE_HOME/"{data,state,config,projects}
  printf '%s\n' '- boat-eng - Code overflow (host: boat-prove; root: /home/user/firstmate; home: /home/user/boat-eng; scope: Code only; projects: firstmate, dev-loop; added 2026-10-13)' \
    > "$LOCAL_HOME/data/secondmates.md"
  printf 'boat-eng\n' > "$REMOTE_HOME/.fm-secondmate-home"
  printf 'tmux\n' > "$REMOTE_HOME/config/backend"
  printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$REMOTE_HOME/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$REMOTE_HOME/data/backlog.md"
  : > "$FIXTURES/windows"
  printf '%s\n' '{"id":"task-one","project":"firstmate","kind":"ship","mode":"direct-PR","intent":"Implement the requested fix","spec":"Use existing helpers","harness":"codex","model":"gpt-6-sol","effort":"medium"}' \
    > "$FIXTURES/request.json"
  cp "$FIXTURES/request.json" "$FIXTURES/worker-request.json"
  printf 'bx_ahnbu3qr\n' > "$LOCAL_HOME/config/boat-box-id"
  cp "$LOCAL_HOME/config/boat-box-id" "$FIXTURES/box-id"
  printf '%s\n' '{"id":12345,"login":"fixture-boat"}' > "$FIXTURES/github-account"
  printf '%s\n' '{"id":12345,"login":"fixture-boat"}' > "$REMOTE_HOME/config/boat-github-account.json"
  printf '%s\n' '{"billingStatus":"active","canStart":true,"creditSecondsPerDollar":100000,"creditUsedSeconds":1000,"last24hUsageSeconds":2000,"creditBalanceSeconds":100000,"activeStates":["ready","idle","running"]}' \
    > "$FIXTURES/limits.json"
  printf '%s\n' '{"pageInfo":{"hasMore":false},"sandboxes":[{"id":"bx_ahnbu3qr","state":"stopped"}]}' \
    > "$FIXTURES/list.json"
  printf '%s\n' '{"sandbox":{"id":"bx_ahnbu3qr","type":"default","state":"stopped"}}' \
    > "$FIXTURES/info.json"
  jq -n --argjson end "$((NOW + 14390))" \
    '{sandbox:{id:"bx_ahnbu3qr",type:"default",state:"ready",environment:"fm-code",archiveAfter:($end|todateiso8601)}}' \
    > "$FIXTURES/ready.json"
  printf '%s\n' '{"sandboxId":"bx_ahnbu3qr","sandboxType":"default","secondsPerDollar":100000,"billingMultiplier":1,"seconds":3000}' \
    > "$FIXTURES/usage.json"
  printf '%s\n' '11111111-1111-4111-8111-111111111111' > "$FIXTURES/boot-id"
  git config --file "$CASE/user-home/.gitconfig" user.name Fixture
  git config --file "$CASE/user-home/.gitconfig" user.email fixture@example.invalid
  fm_git_init_commit "$LOCAL_HOME/projects/firstmate"
  git -C "$LOCAL_HOME/projects/firstmate" config user.name 'Firstmate Local'
  git -C "$LOCAL_HOME/projects/firstmate" config user.email firstmate-local@example.invalid
  : > "$FIXTURES/calls"
}

set_json() {
  jq "$2" "$FIXTURES/$1.json" > "$FIXTURES/$1.new" || fail 'fixture JSON mutation failed'
  mv "$FIXTURES/$1.new" "$FIXTURES/$1.json"
  if [ "$1" = request ]; then
    jq "$2" "$FIXTURES/worker-request.json" > "$FIXTURES/worker-request.new" || fail 'worker fixture JSON mutation failed'
    mv "$FIXTURES/worker-request.new" "$FIXTURES/worker-request.json"
  fi
}

# All environment and operational paths are fixture-local. Each test invokes
# the complete executable, never sources the production implementation.
run_entry() {
  local home=$1 entry=$2 input="$FIXTURES/request.json"
  shift 2
  if [ "$entry" = fm-boat-worker.sh ] && [ "${1:-}" = spawn ]; then input="$FIXTURES/worker-request.json"; fi
  OUT=$(env -u FM_ROOT -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u STATE \
    -u FM_WAKE_QUEUE -u FM_WAKE_QUEUE_LOCK -u TMUX -u TMUX_PANE \
    FM_HOME="$home" HOME="$CASE/user-home" GIT_CONFIG_GLOBAL="$CASE/user-home/.gitconfig" GIT_CONFIG_NOSYSTEM=1 PATH="$FAKEBIN:$PATH" \
    FM_DATA_OVERRIDE="${OVERRIDE_DATA:-}" \
    TMUX="${BOAT_TEST_TMUX:-}" FM_BOAT_START_POLLS=2 FM_BOAT_START_INTERVAL=0 \
    FM_BOAT_BIN="$FAKEBIN/boat" FIXTURES="$FIXTURES" BOAT_NOW="$NOW" \
    BIN="$BIN" REAL_BRIEF="$ROOT/bin/fm-brief.sh" FIXTURE_REMOTE_HOME="$REMOTE_HOME" \
    "$BIN/$entry" "$@" < "$input" 2>&1)
  CODE=$?
}
send_task() { run_entry "$LOCAL_HOME" fm-boat-send.sh --code-only; }
spawn_task() { run_entry "$REMOTE_HOME" fm-boat-worker.sh spawn "$(cat "$FIXTURES/boot-id")"; }
seed_receipt() { printf 'bx_ahnbu3qr %s fm-code\n' "$(cat "$FIXTURES/boot-id")" > "$LOCAL_HOME/state/.boat-environment"; }

assert_pre_resume_refusal() {
  expect_code 1 "$CODE" "$1 refusal"
  assert_no_grep 'boat --no-update stop bx_ahnbu3qr --json' "$FIXTURES/calls" "$1 stopped a box before its own resume"
  assert_no_grep 'boat --no-update resume' "$FIXTURES/calls" "$1 resumed before refusing"
  assert_no_grep 'on --stdin boat-eng' "$FIXTURES/calls" "$1 reached remote transport"
}

test_validation() {
  local filter n=0
  for filter in '.project = "other"' '.project = "clients"' '.env = {API_KEY:"fixture"}' \
    '.home = "/home/user/other"' '.origin = "https://example.invalid/repo"' '.yolo = "on"' \
    '.flags = ["--unsafe"]' '.secrets = {}' '.mode = "local-only"' '.kind = "secondmate"' \
    '.harness = "echo"' '.effort = "unknown"' '.model = ""' '.intent = ""' \
    '.spec = ""' '.goal = "still {GOAL}"' '.off_limits = "no pushes"' '.contracts = "none"' '.git_name = ""' '.git_email = "invalid"' '.git_name = "Fixture"' '.git_name = "Fixture" | .git_email = "fixture@example.invalid"' '.id = "../task"' '.id = "-task"' 'del(.spec)' \
    '.intent = "hidden\u0000text"' '.kind = "scout"'; do
    n=$((n + 1))
    new_case "invalid-$n"
    set_json request "$filter"
    run_entry "$LOCAL_HOME" fm-boat-worker.sh validate
    expect_code 1 "$CODE" "validator rejects $filter"
    send_task
    expect_code 1 "$CODE" "sender rejects $filter"
    [ ! -s "$FIXTURES/calls" ] || fail "invalid request contacted Boat: $filter"
  done
  for input in '{bad json' '[]' '{}' '' '{} {}'; do
    n=$((n + 1)); new_case "malformed-$n"
    printf '%s' "$input" > "$FIXTURES/request.json"
    run_entry "$LOCAL_HOME" fm-boat-worker.sh validate
    expect_code 1 "$CODE" 'validator malformed or multiple-object request'
    send_task
    expect_code 1 "$CODE" 'malformed or multiple-object request'
    [ ! -s "$FIXTURES/calls" ] || fail 'malformed request contacted Boat'
  done
  new_case oversize
  jq '.intent = ("x" * 65537)' "$FIXTURES/request.json" > "$FIXTURES/large"
  mv "$FIXTURES/large" "$FIXTURES/request.json"
  run_entry "$LOCAL_HOME" fm-boat-worker.sh validate
  expect_code 1 "$CODE" 'oversized validator request'
  assert_contains "$OUT" '65536' 'validator size limit'
  send_task
  expect_code 1 "$CODE" 'oversized sender request'
  [ ! -s "$FIXTURES/calls" ] || fail 'oversized request contacted Boat'
  new_case valid-scout
  set_json request '.kind = "scout" | .mode = "scout"'
  run_entry "$LOCAL_HOME" fm-boat-worker.sh validate
  expect_code 0 "$CODE" 'valid scout request'
  run_entry "$LOCAL_HOME" fm-boat-send.sh
  expect_code 1 "$CODE" 'missing code-only attestation'
  [ ! -s "$FIXTURES/calls" ] || fail 'missing attestation contacted Boat'
  pass 'Boat request validation refuses unsupported or oversized envelopes before contact'
}

test_running_reservation_and_start() {
  local row file filter name
  for row in 'limits|.creditUsedSeconds = 1996400|monthly' \
    'limits|.last24hUsageSeconds = 56400|account' \
    'usage|.seconds = 39400|box' \
    'limits|.creditBalanceSeconds = 3599|balance'; do
    IFS='|' read -r file filter name <<< "$row"
    new_case "running-cap-$name"
    jq --argjson end "$((NOW + 3600))" '.sandbox.archiveAfter = ($end|todateiso8601)' "$FIXTURES/ready.json" > "$FIXTURES/info.json"
    seed_receipt
    set_json "$file" "$filter"
    send_task
    assert_pre_resume_refusal "remaining timer $name cap"
  done
  new_case running-short-timer
  jq --argjson end "$((NOW + 3600))" '.sandbox.archiveAfter = ($end|todateiso8601)' "$FIXTURES/ready.json" > "$FIXTURES/info.json"
  seed_receipt
  set_json usage '.seconds = 39000'
  set_json limits '.creditUsedSeconds = 1996000 | .last24hUsageSeconds = 56000 | .creditBalanceSeconds = 3600'
  send_task
  expect_code 0 "$CODE" "remaining timer fits all caps: $OUT"
  assert_no_grep 'boat --no-update resume' "$FIXTURES/calls" 'running dispatch extended timer'
  new_case bare-spawn-success
  : > "$FIXTURES/bare-success"
  send_task
  expect_code 1 "$CODE" 'sender requires positive worker start proof'
  assert_contains "$OUT" 'start unconfirmed' 'bare success diagnostic'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'unconfirmed worker stopped'
  pass 'running dispatch reserves remaining timer and sender requires start proof'
}

test_worker_start() {
  local variant
  for variant in status key-before-at at-before-key failed-key-before-at needs-decision-key-before-at trust stale quoted quoted-no-op quoted-exact negative; do
    new_case "start-$variant"
    seed_project firstmate
    case "$variant" in
      key-before-at) printf 'working [key=start] [at=1791892800]: brief consumed\n' > "$FIXTURES/spawn-status" ;;
      at-before-key) printf 'working [at=1791892800] [key=start]: brief consumed\n' > "$FIXTURES/spawn-status" ;;
      failed-key-before-at) printf 'failed [key=start] [at=1791892800]: launch failed\n' > "$FIXTURES/spawn-status" ;;
      needs-decision-key-before-at) printf 'needs-decision [key=start] [at=1791892800]: choose path\n' > "$FIXTURES/spawn-status" ;;
      trust) : > "$FIXTURES/trust" ;;
      stale) : > "$FIXTURES/no-start"; printf 'working [at=1]: old\n' > "$REMOTE_HOME/state/task-one.status" ;;
      quoted) : > "$FIXTURES/quoted-trust"; : > "$FIXTURES/no-start" ;;
      quoted-no-op) : > "$FIXTURES/quoted-no-op"; : > "$FIXTURES/no-start" ;;
      quoted-exact) : > "$FIXTURES/quoted-exact"; : > "$FIXTURES/no-start" ;;
      negative) : > "$FIXTURES/negative-trust"; : > "$FIXTURES/no-start" ;;
    esac
    spawn_task
    case "$variant" in
      status|key-before-at|at-before-key)
        expect_code 0 "$CODE" "worker $variant start: $OUT"
        assert_contains "$OUT" 'boat-started: task-one' 'missing positive start proof'
        ;;
      failed-*|needs-decision-*)
        expect_code 1 "$CODE" "worker $variant refuses start"
        assert_contains "$OUT" 'declared a failure or decision before start confirmation' 'missing immediate refusal'
        if [[ "$OUT" == *boat-started:* ]]; then fail 'failure was treated as start proof'; fi
        ;;
      *)
        expect_code 1 "$CODE" "worker $variant refuses success"
        if [[ "$OUT" == *boat-started:* ]]; then fail 'false start proof'; fi
        [ -e "$REMOTE_HOME/state/task-one.meta" ] || fail 'unconfirmed launch lost metadata'
        ;;
    esac
    case "$variant" in trust|stale|quoted|quoted-no-op|quoted-exact|negative)
      assert_contains "$OUT" 'worker task-one did not prove start with a fresh status' 'missing start refusal'
      assert_contains "$OUT" 'Codex folder-trust prompt is a known cause' 'missing trust diagnostic'
      assert_contains "$OUT" 'Inspect: fm-on.sh boat-eng fm-peek.sh task-one' 'missing inspect command'
      assert_contains "$OUT" 'fm-on.sh boat-eng fm-send.sh task-one --key Enter' 'missing conditional answer command'
      assert_contains "$OUT" 'Then inspect: fm-on.sh boat-eng fm-peek.sh task-one' 'missing follow-up inspect command'
      ;;
    esac
    assert_no_grep 'capture ' "$FIXTURES/calls" 'worker still gated start on viewport capture'
    assert_no_grep 'key ' "$FIXTURES/calls" 'viewport text received Enter without modal proof'
  done
  new_case scout-completion-missing
  seed_receipt
  seed_worker task-one scout dev-loop 'state: done complete'
  : > "$FIXTURES/hold-missing"
  run_entry "$LOCAL_HOME" fm-boat-send.sh --teardown task-one
  expect_code 1 "$CODE" 'unreviewed scout completion refuses teardown'
  assert_contains "$OUT" 'fm-on.sh boat-eng fm-captain-hold.sh complete task-one --none' 'missing exact controller command'
  assert_equals '' "$(sed -n '/^teardown /p' "$FIXTURES/calls")" 'unreviewed scout was torn down'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'unreviewed scout box was stopped'
  pass 'worker confirms fresh progress, refuses ambiguous trust text, and preserves unreviewed scouts'
}

test_ship_prerequisites_and_identity() {
  local variant
  new_case sender-without-controller-project
  mv "$LOCAL_HOME/projects" "$CASE/unused-controller-projects"
  rm "$CASE/user-home/.gitconfig"
  send_task
  expect_code 0 "$CODE" "sender needs no controller project or identity: $OUT"
  jq -e 'has("git_name") or has("git_email") | not' "$FIXTURES/transport.request" >/dev/null || fail 'controller identity entered task transport'
  assert_equals "$(jq -Sc . "$FIXTURES/request.json")" "$(jq -Sc . "$FIXTURES/transport.request")" 'sender changed raw request'
  new_case sender-unsafe-local-identity-ignored
  git -C "$LOCAL_HOME/projects/firstmate" config user.name $'Injected\nname'
  git -C "$LOCAL_HOME/projects/firstmate" config user.email worker@extra@example.invalid
  send_task
  expect_code 0 "$CODE" 'irrelevant controller identity does not gate Boat'
  for variant in ship scout; do
    new_case "worker-github-identity-$variant"
    seed_project firstmate
    if [ "$variant" = scout ]; then set_json request '.kind = "scout" | .mode = "scout"'; fi
    spawn_task
    expect_code 0 "$CODE" "GitHub $variant identity: $OUT"
    assert_grep 'gh-axi api /user ' "$FIXTURES/calls" 'identity did not come from box GitHub account'
    grep -Fx 'fixture-boat' "$FIXTURES/spawn.argv" >/dev/null || fail 'GitHub committer name omitted'
    grep -Fx '12345+fixture-boat@users.noreply.github.com' "$FIXTURES/spawn.argv" >/dev/null || fail 'GitHub noreply identity omitted'
    assert_equals Fixture "$(git -C "$REMOTE_HOME/projects/firstmate" config user.name)" 'worker changed project clone identity'
    assert_equals fixture@example.invalid "$(git -C "$REMOTE_HOME/projects/firstmate" config user.email)" 'worker changed project clone email'
  done
  new_case worker-quoted-numeric-login
  seed_project firstmate
  printf '%s\n' '{"id":12345,"login":"123"}' > "$FIXTURES/github-account"
  spawn_task
  expect_code 0 "$CODE" "quoted numeric GitHub login: $OUT"
  grep -Fx '12345+123@users.noreply.github.com' "$FIXTURES/spawn.argv" >/dev/null || fail 'numeric login was not decoded'
  for variant in ship scout; do
    new_case "github-other-account-$variant"
    seed_project firstmate
    if [ "$variant" = scout ]; then set_json request '.kind = "scout" | .mode = "scout"'; fi
    printf '%s\n' '{"id":54321,"login":"other-user"}' > "$FIXTURES/github-account"
    spawn_task
    expect_code 1 "$CODE" "other GitHub account $variant refusal"
    assert_contains "$OUT" 'expected fixture-boat (12345); actual other-user (54321)' 'account mismatch diagnostic omitted expected or actual'
    assert_no_grep 'brief ' "$FIXTURES/calls" "other account $variant reached brief generation"
    assert_no_grep 'spawn task-one ' "$FIXTURES/calls" "other account $variant reached spawn"
    assert_no_grep 'task-one' "$REMOTE_HOME/data/backlog.md" "other account $variant reached backlog intake"
    new_case "github-missing-account-setting-$variant"
    seed_project firstmate
    if [ "$variant" = scout ]; then set_json request '.kind = "scout" | .mode = "scout"'; fi
    rm "$REMOTE_HOME/config/boat-github-account.json"
    spawn_task
    expect_code 1 "$CODE" "missing GitHub account setting $variant refusal"
    assert_contains "$OUT" 'expected Boat GitHub account is missing (config/boat-github-account.json); actual fixture-boat (12345)' 'missing account setting diagnostic omitted actual account'
    assert_no_grep 'brief ' "$FIXTURES/calls" "missing account setting $variant reached brief generation"
    assert_no_grep 'spawn task-one ' "$FIXTURES/calls" "missing account setting $variant reached spawn"
    assert_no_grep 'task-one' "$REMOTE_HOME/data/backlog.md" "missing account setting $variant reached backlog intake"
  done
  for variant in unavailable missing-login missing-id invalid-login invalid-id bad-envelope truncated; do
    new_case "github-$variant"
    seed_project firstmate
    case "$variant" in
      unavailable) : > "$FIXTURES/github.fail" ;;
      missing-login) printf '%s\n' '{"id":12345}' > "$FIXTURES/github-account" ;;
      missing-id) printf '%s\n' '{"login":"fixture-boat"}' > "$FIXTURES/github-account" ;;
      invalid-login) printf '%s\n' '{"id":12345,"login":"bad<login"}' > "$FIXTURES/github-account" ;;
      invalid-id) printf '%s\n' '{"id":"nope","login":"fixture-boat"}' > "$FIXTURES/github-account" ;;
      bad-envelope) printf 'api_response:\n  body: fm_boat_identity=broken\n  truncated: false\n' > "$FIXTURES/github-response" ;;
      truncated) jq -r '"api_response:\n  body: fm_boat_identity=\(tojson|@base64)\n  truncated: true"' "$FIXTURES/github-account" > "$FIXTURES/github-response" ;;
    esac
    spawn_task
    expect_code 1 "$CODE" "GitHub $variant refusal"
    assert_no_grep 'brief ' "$FIXTURES/calls" "$variant reached brief generation"
    assert_no_grep 'spawn task-one ' "$FIXTURES/calls" "$variant reached spawn"
    assert_no_grep 'task-one' "$REMOTE_HOME/data/backlog.md" "$variant reached backlog intake"
  done
  new_case worker-no-gh-axi
  seed_project firstmate
  mkdir -p "$CASE/no-gh"
  printf 'command() { if [ "$*" = "-v gh-axi" ]; then return 1; fi; builtin command "$@"; }\n' > "$CASE/no-gh/bash-env"
  OUT=$(BASH_ENV="$CASE/no-gh/bash-env" env -u TMUX FM_HOME="$REMOTE_HOME" HOME="$CASE/user-home" PATH="$FAKEBIN:$PATH" FIXTURES="$FIXTURES" FM_BOAT_START_POLLS=2 FM_BOAT_START_INTERVAL=0 "$BIN/fm-boat-worker.sh" spawn "$(cat "$FIXTURES/boot-id")" < "$FIXTURES/worker-request.json" 2>&1)
  CODE=$?
  expect_code 1 "$CODE" 'worker refuses missing gh-axi'
  assert_contains "$OUT" 'gh-axi installed' 'missing gh-axi diagnostic'
  assert_no_grep 'brief ' "$FIXTURES/calls" 'missing gh-axi accepted backlog intake'
  pass 'ships and scouts derive box GitHub noreply identity without PC Git configuration'
}

test_whole_timer_reservation() {
  local row file filter name
  for row in 'limits|.creditUsedSeconds = 1985600|monthly' \
    'limits|.last24hUsageSeconds = 45600|account-day' \
    'usage|.seconds = 28600|box-day' \
    'limits|.creditBalanceSeconds = 14399|credit-balance'; do
    IFS='|' read -r file filter name <<< "$row"
    new_case "$name"
    set_json "$file" "$filter"
    send_task
    assert_pre_resume_refusal "$name whole-timer reservation"
  done
  new_case just-under-caps
  set_json limits '.creditUsedSeconds = 1985599 | .last24hUsageSeconds = 45599 | .creditBalanceSeconds = 14400'
  set_json usage '.seconds = 28599'
  send_task
  expect_code 0 "$CODE" "one second under caps with exact timer balance: $OUT"
  pass 'Boat reserves the entire timer against every spend ceiling and balance'
}

test_unreadable_caps() {
  local row file filter name
  for row in 'limits|del(.creditUsedSeconds)|missing-spend' \
    'limits|.last24hUsageSeconds = "2000"|string-usage' \
    'limits|.creditBalanceSeconds = null|null-balance' \
    'limits|del(.activeStates)|missing-states' \
    'limits|.creditSecondsPerDollar = 1|unknown-rate' \
    'list|.pageInfo.hasMore = true|incomplete-list' \
    'list|.sandboxes += [{id:"bx_other",state:"running"}]|other-active-box' \
    'info|.sandbox.type = "large"|wrong-size' \
    'usage|.sandboxId = "bx_other"|wrong-usage-box' \
    'usage|.seconds = -1|negative-usage' \
    'usage|.billingMultiplier = 2|wrong-multiplier'; do
    IFS='|' read -r file filter name <<< "$row"
    new_case "$name"
    set_json "$file" "$filter"
    send_task
    assert_pre_resume_refusal "$name"
  done
  for file in limits list info usage; do
    new_case "failed-$file"
    : > "$FIXTURES/$file.fail"
    send_task
    if [ "$file" = info ]; then
      expect_code 1 "$CODE" 'info unavailable refusal'
      assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'unknown box state stopped existing work'
    else
      assert_pre_resume_refusal "$file unavailable"
    fi
    new_case "bad-json-$file"
    printf 'not JSON' > "$FIXTURES/$file.json"
    send_task
    if [ "$file" = info ]; then
      expect_code 1 "$CODE" 'info malformed refusal'
      assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'unknown box state stopped existing work'
    else
      assert_pre_resume_refusal "$file malformed"
    fi
  done
  pass 'Boat unreadable, incomplete, or unsafe readings refuse before resume'
}

test_sender_success_and_timer() {
  local plan ttl
  for plan in active trialing; do
    new_case "success-$plan"
    ttl=14400; [ "$plan" != trialing ] || ttl=7200
    set_json limits ".billingStatus = \"$plan\""
    jq --argjson end "$((NOW + ttl - 10))" '.sandbox.archiveAfter = ($end|todateiso8601)' \
      "$FIXTURES/ready.json" > "$FIXTURES/ready.new"
    mv "$FIXTURES/ready.new" "$FIXTURES/ready.json"
    send_task
    expect_code 0 "$CODE" "$plan dispatch: $OUT"
    assert_grep "boat --no-update resume bx_ahnbu3qr --environment fm-code --ttl $ttl --json" \
      "$FIXTURES/calls" "$plan explicit safe resume"
    if [ -n "$REAL_TIMEOUT" ]; then
      grep -Fx 120 "$FIXTURES/timeout.calls" >/dev/null || fail "$plan resume was not bounded"
      grep -Fx 45 "$FIXTURES/timeout.calls" >/dev/null || fail "$plan instance read was not bounded"
    fi
    assert_equals $'alias bx_ahnbu3qr boat-prove\non --stdin boat-eng fm-boat-worker.sh spawn 22222222-2222-4222-8222-222222222222' \
      "$(tail -n 2 "$FIXTURES/calls")" 'alias refresh precedes existing remote lane'
    assert_equals "$(jq -Sc . "$FIXTURES/request.json")" "$(jq -Sc . "$FIXTURES/transport.request")" 'transport changed task fields'
    assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'successful dispatch stopped the box'
    assert_equals 'bx_ahnbu3qr 22222222-2222-4222-8222-222222222222 fm-code' "$(cat "$LOCAL_HOME/state/.boat-environment")" 'successful environment resume receipt'
  done
  new_case already-running
  cp "$FIXTURES/ready.json" "$FIXTURES/info.json"
  seed_receipt
  send_task
  expect_code 0 "$CODE" "already-running dispatch: $OUT"
  assert_no_grep 'boat --no-update resume' "$FIXTURES/calls" 'running box timer was extended'
  new_case plain-resume-after-stop
  send_task
  expect_code 0 "$CODE" 'initial safe resume before external stop'
  FIXTURES="$FIXTURES" BOAT_NOW="$NOW" "$FAKEBIN/boat" --no-update stop bx_ahnbu3qr --json >/dev/null
  FIXTURES="$FIXTURES" BOAT_NOW="$NOW" "$FAKEBIN/boat" --no-update resume bx_ahnbu3qr --json >/dev/null
  : > "$FIXTURES/calls"
  send_task
  expect_code 1 "$CODE" 'plain resume must invalidate old environment receipt'
  assert_contains "$OUT" 'no current fm-code environment receipt' 'stale instance refusal explanation'
  assert_no_grep '^on ' "$FIXTURES/calls" 'plain-resumed box received a worker'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'plain-resumed box was stopped by refusal'
  new_case running-no-receipt
  cp "$FIXTURES/ready.json" "$FIXTURES/info.json"
  send_task
  expect_code 1 "$CODE" 'running box with no environment receipt'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'running box with no receipt stopped existing work'
  assert_no_grep 'on --stdin boat-eng' "$FIXTURES/calls" 'running box with no receipt reached transport'
  new_case timer-missing
  set_json ready 'del(.sandbox.archiveAfter)'
  send_task
  expect_code 1 "$CODE" 'missing auto-stop timer'
  assert_grep 'boat --no-update stop bx_ahnbu3qr --json' "$FIXTURES/calls" 'missing timer must stop box'
  assert_absent "$LOCAL_HOME/state/.boat-environment" 'failed resumed box retained environment receipt'
  assert_no_grep 'on --stdin boat-eng' "$FIXTURES/calls" 'missing timer reached transport'
  new_case timer-too-long
  jq --argjson end "$((NOW + 14401))" '.sandbox.archiveAfter = ($end|todateiso8601)' \
    "$FIXTURES/ready.json" > "$FIXTURES/info.json"
  seed_receipt
  send_task
  expect_code 1 "$CODE" 'running timer exceeds reservation'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'running timer refusal stopped existing work'
  assert_no_grep 'on --stdin boat-eng' "$FIXTURES/calls" 'running timer refusal reached transport'
  new_case uncertain-transport
  printf '255\n' > "$FIXTURES/transport.code"
  send_task
  expect_code 255 "$CODE" 'uncertain remote launch preserves transport exit'
  assert_equals 1 "$(grep -c '^on ' "$FIXTURES/calls")" 'uncertain launch was retried'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'uncertain remote launch stopped running work'
  pass 'Boat resumes only the approved box with fm-code, preserves timers, and sends once through fm-on'
}

test_running_quota_and_route() {
  new_case running-start-quota
  cp "$FIXTURES/ready.json" "$FIXTURES/info.json"
  seed_receipt
  set_json limits '.canStart = false'
  send_task
  expect_code 0 "$CODE" "running box needs no start quota: $OUT"
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'running worker stopped at exhausted start quota'
  new_case running-cap-refusal
  cp "$FIXTURES/ready.json" "$FIXTURES/info.json"
  seed_receipt
  set_json limits '.creditUsedSeconds = 2000000'
  send_task
  expect_code 1 "$CODE" 'running box refuses a new task at spend cap'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'spend refusal stopped existing work'
  new_case stopped-start-quota
  set_json limits '.canStart = false'
  send_task
  assert_pre_resume_refusal 'stopped box with no start quota'
  new_case alternate-route
  mkdir -p "$CASE/alternate"
  printf '%s\n' '- boat-eng - Wrong route (host: other-host; root: /home/user/firstmate; home: /home/user/boat-eng; scope: Code only; projects: firstmate; added 2026-10-13)' > "$CASE/alternate/secondmates.md"
  OVERRIDE_DATA="$CASE/alternate"
  send_task
  unset OVERRIDE_DATA
  expect_code 1 "$CODE" 'alternate registry route is refused'
  [ ! -s "$FIXTURES/calls" ] || fail 'alternate registry route contacted Boat'
  pass 'running work survives start quota and cap refusals; route validation follows transport registry'
}

test_prepare_before_route() {
  new_case prepare-before-route
  rm "$LOCAL_HOME/data/secondmates.md"
  run_entry "$LOCAL_HOME" fm-boat-send.sh --prepare --code-only
  expect_code 0 "$CODE" "prepare before route registration: $OUT"
  assert_grep 'boat --no-update resume bx_ahnbu3qr --environment fm-code' "$FIXTURES/calls" 'prepare did not safely resume'
  assert_grep 'alias bx_ahnbu3qr boat-prove' "$FIXTURES/calls" 'prepare did not refresh alias'
  assert_no_grep 'on --stdin boat-eng' "$FIXTURES/calls" 'prepare dispatched without route'
  : > "$FIXTURES/calls"
  send_task
  expect_code 1 "$CODE" 'dispatch without registered route'
  [ ! -s "$FIXTURES/calls" ] || fail 'dispatch without route contacted Boat'
  pass 'prepare establishes access before route registration while dispatch still requires the route'
}

test_teardown_stop() {
  new_case last-task-teardown
  seed_receipt
  seed_worker task-one ship firstmate 'state: done complete'
  run_entry "$LOCAL_HOME" fm-boat-send.sh --teardown task-one
  expect_code 0 "$CODE" "last task teardown: $OUT"
  assert_grep 'teardown task-one' "$FIXTURES/calls" 'ordinary remote teardown was not called'
  assert_grep 'boat --no-update stop bx_ahnbu3qr --json' "$FIXTURES/calls" 'last task did not stop approved box'
  assert_equals 'alias --verify boat-prove' "$(tail -n 1 "$FIXTURES/calls")" 'the stop did not park the alias'
  assert_absent "$LOCAL_HOME/state/.boat-environment" 'stopped box retained environment receipt'
  assert_absent "$REMOTE_HOME/state/task-one.meta" 'last task record remained'
  new_case another-task-remains
  seed_receipt
  seed_worker task-one ship firstmate 'state: done complete'
  seed_worker task-two scout dev-loop 'state: working active'
  run_entry "$LOCAL_HOME" fm-boat-send.sh --teardown task-one
  expect_code 0 "$CODE" 'teardown with another task'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'other task was stopped'
  new_case orphan-endpoint-remains
  seed_receipt
  seed_worker task-one ship firstmate 'state: done complete'
  printf 'fm-task-one\nfm-orphan\n' > "$FIXTURES/windows"
  run_entry "$LOCAL_HOME" fm-boat-send.sh --teardown task-one
  expect_code 0 "$CODE" 'teardown with an orphan endpoint'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'orphan endpoint was stopped'
  assert_absent "$REMOTE_HOME/state/task-one.meta" 'ordinary task record remained'
  assert_equals 'fm-orphan' "$(cat "$FIXTURES/windows")" 'orphan endpoint was removed'
  new_case dev-loop-scout-teardown
  seed_receipt
  seed_worker task-one scout dev-loop 'state: done complete'
  run_entry "$LOCAL_HOME" fm-boat-send.sh --teardown task-one
  expect_code 0 "$CODE" "dev-loop scout teardown: $OUT"
  assert_grep 'teardown task-one' "$FIXTURES/calls" 'allowed scout teardown was not called'
  assert_grep 'boat --no-update stop bx_ahnbu3qr --json' "$FIXTURES/calls" 'last scout did not stop approved box'
  new_case teardown-refused
  seed_receipt
  seed_worker task-one ship firstmate 'state: working active'
  : > "$FIXTURES/teardown.fail"
  run_entry "$LOCAL_HOME" fm-boat-send.sh --teardown task-one
  expect_code 1 "$CODE" 'landed-work or report refusal'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'refused teardown stopped box'
  [ -f "$REMOTE_HOME/state/task-one.meta" ] || fail 'refused teardown removed task record'
  new_case teardown-other-home
  seed_receipt
  seed_worker task-one secondmate firstmate 'state: done complete'
  run_entry "$LOCAL_HOME" fm-boat-send.sh --teardown task-one
  expect_code 1 "$CODE" 'teardown of non-worker record'
  [ "$(grep -c '^teardown task-one$' "$FIXTURES/calls")" -eq 0 ] || fail 'non-worker record reached teardown'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'non-worker record stopped box'
  new_case teardown-wrong-project
  seed_receipt
  seed_worker task-one ship other 'state: done complete'
  run_entry "$LOCAL_HOME" fm-boat-send.sh --teardown task-one
  expect_code 1 "$CODE" 'teardown of non-Boat project'
  assert_no_grep '^teardown task-one$' "$FIXTURES/calls" 'non-Boat project reached teardown'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'non-Boat project stopped box'
  new_case teardown-short-project
  seed_receipt
  fm_write_meta "$REMOTE_HOME/state/task-one.meta" 'kind=ship' 'project=firstmate'
  run_entry "$LOCAL_HOME" fm-boat-send.sh --teardown task-one
  expect_code 1 "$CODE" 'teardown of noncanonical project record'
  assert_no_grep '^teardown task-one$' "$FIXTURES/calls" 'noncanonical project reached teardown'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'noncanonical project stopped box'
  new_case teardown-no-receipt
  seed_worker task-one ship firstmate 'state: done complete'
  run_entry "$LOCAL_HOME" fm-boat-send.sh --teardown task-one
  expect_code 1 "$CODE" 'teardown without environment receipt'
  assert_no_grep 'on boat-eng' "$FIXTURES/calls" 'teardown without receipt contacted remote'
  pass 'last-task teardown stops only the approved box after ordinary cleanup succeeds'
}

test_confirmed_prelaunch_refusal_stop() {
  new_case resumed-refusal-empty
  set_json request '.mode = "no-mistakes"'
  : > "$FIXTURES/use-real-worker"
  send_task
  expect_code 1 "$CODE" 'confirmed prelaunch no-mistakes refusal'
  assert_contains "$OUT" 'has not been proven' 'remote refusal was not preserved'
  assert_grep 'boat --no-update stop bx_ahnbu3qr --json' "$FIXTURES/calls" 'confirmed empty refusal left newly resumed box on'
  assert_absent "$LOCAL_HOME/state/.boat-environment" 'refused box kept its receipt'
  assert_no_grep '^spawn ' "$FIXTURES/calls" 'prelaunch refusal spawned a worker'
  new_case running-refusal-empty
  cp "$FIXTURES/ready.json" "$FIXTURES/info.json"
  seed_receipt
  set_json request '.mode = "no-mistakes"'
  : > "$FIXTURES/use-real-worker"
  send_task
  expect_code 1 "$CODE" 'prelaunch refusal on a previously running box'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'refusal stopped a box this send did not resume'
  new_case resumed-refusal-busy
  seed_worker earlier-worker ship firstmate 'state: working active'
  set_json request '.mode = "no-mistakes"'
  : > "$FIXTURES/use-real-worker"
  send_task
  expect_code 1 "$CODE" 'confirmed refusal with retained workers'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'confirmed refusal stopped another worker'
  pass 'confirmed prelaunch refusal stops only a newly resumed empty box'
}

test_native_spawn_refusal_stop() {
  new_case native-refusal-empty
  seed_project firstmate
  : > "$FIXTURES/use-real-worker"
  : > "$FIXTURES/spawn.fail"
  send_task
  expect_code 1 "$CODE" 'native preflight refusal on newly resumed box'
  assert_grep 'spawn task-one ' "$FIXTURES/calls" 'native spawn was not attempted'
  assert_grep 'on boat-eng fm-boat-worker.sh idle' "$FIXTURES/calls" 'native refusal did not check locked inventory'
  assert_grep 'boat --no-update stop bx_ahnbu3qr --json' "$FIXTURES/calls" 'empty native refusal left newly resumed box on'
  assert_absent "$LOCAL_HOME/state/.boat-environment" 'empty native refusal kept environment receipt'
  new_case native-refusal-endpoint
  seed_project firstmate
  : > "$FIXTURES/use-real-worker"
  : > "$FIXTURES/spawn.postlaunch.fail"
  send_task
  expect_code 1 "$CODE" 'native refusal after endpoint launch'
  assert_grep 'on boat-eng fm-boat-worker.sh idle' "$FIXTURES/calls" 'postlaunch refusal did not check locked inventory'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'live endpoint was stopped'
  new_case native-refusal-running
  seed_project firstmate
  cp "$FIXTURES/ready.json" "$FIXTURES/info.json"
  seed_receipt
  : > "$FIXTURES/use-real-worker"
  : > "$FIXTURES/spawn.fail"
  send_task
  expect_code 1 "$CODE" 'native refusal on already running box'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'native refusal stopped a box this send did not resume'
  pass 'native refusals stop only newly resumed boxes with empty locked inventories'
}

test_existing_backlog_row() {
  local variant
  for variant in kind project 'done' matching; do
    new_case "existing-row-$variant"
    seed_project firstmate
    mkdir -p "$REMOTE_HOME/data/task-one"
    printf 'Original instructions\n' > "$REMOTE_HOME/data/task-one/brief.md"
    case "$variant" in
      kind) run_entry "$REMOTE_HOME" fm-tasks-axi.sh add task-one 'Existing row' --kind scout --repo firstmate --queue ;;
      project) run_entry "$REMOTE_HOME" fm-tasks-axi.sh add task-one 'Existing row' --kind ship --repo dev-loop --queue ;;
      *) run_entry "$REMOTE_HOME" fm-tasks-axi.sh add task-one 'Existing row' --kind ship --repo firstmate --queue ;;
    esac
    expect_code 0 "$CODE" "seed $variant backlog row"
    if [ "$variant" = 'done' ]; then
      run_entry "$REMOTE_HOME" fm-tasks-axi.sh 'done' task-one
      expect_code 0 "$CODE" 'close existing backlog row'
    fi
    : > "$FIXTURES/calls"
    spawn_task
    if [ "$variant" = matching ]; then
      expect_code 0 "$CODE" "matching queued row remains reusable: $OUT"
      assert_grep 'Implement the requested fix' "$REMOTE_HOME/data/task-one/brief.md" 'matching row did not rewrite brief'
    else
      expect_code 1 "$CODE" "$variant row refusal"
      assert_equals 'Original instructions' "$(cat "$REMOTE_HOME/data/task-one/brief.md")" "$variant row changed brief"
      assert_no_grep 'brief task-one ' "$FIXTURES/calls" "$variant row reached brief generation"
      assert_no_grep 'spawn task-one ' "$FIXTURES/calls" "$variant row reached native spawn"
    fi
  done
  pass 'existing backlog rows must be dispatchable and match task kind and project'
}

placeholders_present() {
  (
    # shellcheck source=bin/fm-dod-lib.sh
    . "$ROOT/bin/fm-dod-lib.sh" || exit 2
    fm_brief_task_placeholders_present "$1"
  )
}

test_brief_placeholder_fill() {
  local brief
  new_case brief-tokens-fallback
  seed_project firstmate
  : > "$FIXTURES/use-real-brief"
  spawn_task
  expect_code 0 "$CODE" "fallback brief reaches spawn: $OUT"
  brief="$REMOTE_HOME/data/task-one/brief.md"
  [ -f "$brief" ] || fail 'fallback brief was not written'
  placeholders_present "$brief" && fail 'fallback brief still has unfilled task placeholders'
  [ "$?" -eq 1 ] || fail 'fallback brief placeholder check did not run'
  assert_grep 'Goal: Complete the one code-only task in the spec.' "$brief" 'fallback goal'
  assert_grep 'Off-limits: Secrets, client data, pushes, merges, deploys, and captain contact.' "$brief" 'fallback off-limits'
  assert_grep 'Contracts and gates (follow them; spawned inside a pipeline, move only through its states): none' "$brief" 'fallback contracts'
  assert_grep 'Implement the requested fix' "$brief" 'fallback kept intent'
  new_case brief-tokens-scout
  seed_project firstmate
  : > "$FIXTURES/use-real-brief"
  set_json request '.kind = "scout" | .mode = "scout"'
  spawn_task
  expect_code 0 "$CODE" "scout fallback brief reaches spawn: $OUT"
  brief="$REMOTE_HOME/data/task-one/brief.md"
  placeholders_present "$brief" && fail 'scout brief still has unfilled task placeholders'
  [ "$?" -eq 1 ] || fail 'scout brief placeholder check did not run'
  assert_grep '--scout' "$FIXTURES/spawn.argv" 'scout brief was not spawned as a scout'
  pass 'Boat brief rewrite fills every scaffold placeholder before spawn'
}

seed_project() {
  fm_git_init_commit "$REMOTE_HOME/projects/$1"
  git -C "$REMOTE_HOME/projects/$1" config user.name Fixture
  git -C "$REMOTE_HOME/projects/$1" config user.email fixture@example.invalid
  git -C "$REMOTE_HOME/projects/$1" remote add origin "https://github.com/LeadGrowGTM/$1.git"
}
seed_worker() {
  fm_write_meta "$REMOTE_HOME/state/$1.meta" "kind=$2" "project=$REMOTE_HOME/projects/$3" "status=$4"
}

test_remote_cap_and_merge_authority() {
  new_case orphan-endpoints-cap
  seed_project firstmate
  seed_worker worker-a ship firstmate 'state: working active'
  seed_worker worker-b scout dev-loop 'state: working active'
  printf 'fm-worker-a\nfm-worker-b\nfm-orphan\n' > "$FIXTURES/windows"
  spawn_task
  expect_code 75 "$CODE" 'orphan endpoint must reserve the third slot'
  assert_equals 1 "$(grep -c '^inventory ' "$FIXTURES/calls")" 'capacity performed more than one endpoint inventory'
  assert_no_grep '^spawn ' "$FIXTURES/calls" 'orphan endpoint bypassed capacity'
  new_case mixed-record-endpoint-cap
  seed_project firstmate
  seed_worker worker-a ship firstmate 'state: working active'
  seed_worker worker-b scout dev-loop 'state: working active'
  printf 'fm-worker-a\nfm-orphan\n' > "$FIXTURES/windows"
  spawn_task
  expect_code 75 "$CODE" 'distinct records and endpoints must fill the box'
  assert_contains "$OUT" 'three-worker cap' 'mixed inventory refusal did not reach capacity check'
  assert_equals 1 "$(grep -c '^inventory ' "$FIXTURES/calls")" 'mixed inventory performed more than one endpoint read'
  assert_no_grep '^spawn ' "$FIXTURES/calls" 'mixed inventory launched a fourth task'
  assert_absent "$REMOTE_HOME/data/task-one/brief.md" 'mixed inventory wrote a fourth brief'
  new_case unavailable-endpoints
  seed_project firstmate
  : > "$FIXTURES/inventory.fail"
  spawn_task
  expect_code 1 "$CODE" 'unreadable endpoint inventory must refuse'
  assert_no_grep '^spawn ' "$FIXTURES/calls" 'unreadable inventory spawned a worker'
  new_case unsupported-runtime
  seed_project firstmate
  printf 'orca\n' > "$REMOTE_HOME/config/backend"
  spawn_task
  expect_code 1 "$CODE" 'unsupported Boat runtime must refuse'
  assert_no_grep 'inventory ' "$FIXTURES/calls" 'unsupported runtime attempted tmux inventory'
  new_case cross-project-cap
  seed_project firstmate
  seed_worker worker-a ship firstmate 'state: working active'
  seed_worker worker-b scout dev-loop 'state: working active'
  seed_worker worker-c ship dev-loop 'state: paused waiting'
  spawn_task
  expect_code 75 "$CODE" 'box-wide three-worker cap'
  assert_contains "$OUT" 'three-worker cap' 'cap refusal explanation'
  assert_no_grep 'brief ' "$FIXTURES/calls" 'full box generated a new brief'
  assert_no_grep '^spawn ' "$FIXTURES/calls" 'full box spawned a worker'
  assert_absent "$REMOTE_HOME/state/.boat-worker.lock" 'refused dispatch leaked its lock'
  new_case remote-spawn
  seed_project firstmate
  seed_worker worker-a ship dev-loop 'state: working active'
  seed_worker worker-b scout firstmate 'state: paused waiting'
  seed_worker worker-done ship dev-loop 'state: done complete'
  seed_worker mate secondmate dev-loop 'state: working active'
  spawn_task
  expect_code 75 "$CODE" 'retained terminal worker still occupies a slot'
  assert_no_grep '^spawn ' "$FIXTURES/calls" 'terminal worker metadata bypassed capacity'
  rm "$REMOTE_HOME/state/worker-done.meta"
  : > "$FIXTURES/calls"
  spawn_task
  expect_code 0 "$CODE" "remote dispatch: $OUT"
  assert_equals "$(printf '%s\n' task-one "$REMOTE_HOME/projects/firstmate" \
    --mode direct-PR --yolo off --git-name fixture-boat --git-email 12345+fixture-boat@users.noreply.github.com --backend tmux --harness codex --model gpt-6-sol --effort medium)" \
    "$(cat "$FIXTURES/spawn.argv")" 'remote spawn forces merge authority off with selected profile'
  assert_grep 'Implement the requested fix' "$REMOTE_HOME/data/task-one/brief.md" 'intent omitted from remote brief'
  assert_grep 'Use existing helpers' "$REMOTE_HOME/data/task-one/brief.md" 'spec omitted from remote brief'
  assert_grep 'Never merge,' "$REMOTE_HOME/data/task-one/brief.md" 'remote safety rules omitted'
  assert_no_grep '{TASK}' "$REMOTE_HOME/data/task-one/brief.md" 'intent placeholder remained'
  assert_absent "$REMOTE_HOME/state/.boat-worker.lock" 'successful dispatch leaked its lock'
  : > "$FIXTURES/calls"
  spawn_task
  expect_code 1 "$CODE" 'existing task id refuses relaunch'
  assert_no_grep '^spawn ' "$FIXTURES/calls" 'existing task id launched again'
  new_case retry-prelaunch-failure
  seed_project firstmate
  : > "$FIXTURES/use-real-brief"
  : > "$FIXTURES/spawn.fail"
  spawn_task
  expect_code 1 "$CODE" 'failed spawn'
  [ -f "$REMOTE_HOME/data/task-one/brief.md" ] || fail 'failed spawn deleted task material'
  rm "$FIXTURES/spawn.fail"
  set_json request '.intent = "Retried intent"'
  spawn_task
  expect_code 0 "$CODE" 'same task id retry after prelaunch failure'
  assert_grep 'Retried intent' "$REMOTE_HOME/data/task-one/brief.md" 'retry did not rewrite brief'
  assert_no_grep 'Implement the requested fix' "$REMOTE_HOME/data/task-one/brief.md" 'retry kept stale intent'
  : > "$FIXTURES/calls"
  spawn_task
  expect_code 1 "$CODE" 'spawn metadata refuses another retry'
  assert_contains "$OUT" 'task id already exists' 'spawn metadata refusal explanation'
  assert_no_grep 'brief ' "$FIXTURES/calls" 'recorded task regenerated its brief'
  assert_grep 'Retried intent' "$REMOTE_HOME/data/task-one/brief.md" 'recorded task changed its brief'
  new_case postlaunch-failure
  seed_project firstmate
  : > "$FIXTURES/spawn.postlaunch.fail"
  spawn_task
  expect_code 1 "$CODE" 'postlaunch failure'
  [ -f "$FIXTURES/endpoint-launched" ] || fail 'postlaunch fixture did not launch'
  [ -f "$REMOTE_HOME/data/task-one/brief.md" ] || fail 'postlaunch failure deleted a live brief'
  new_case no-mistakes-unproven
  set_json request '.mode = "no-mistakes"'
  seed_project firstmate
  spawn_task
  expect_code 1 "$CODE" 'unproven remote no-mistakes mode'
  assert_contains "$OUT" 'has not been proven' 'unproven pipeline refusal'
  assert_no_grep '^spawn ' "$FIXTURES/calls" 'unproven no-mistakes launched or downgraded'
  pass 'remote capacity spans projects until teardown, excludes secondmates, and merge authority is off'
}

test_same_id_orphan_retry() {
  new_case ambient-tmux-refusal
  BOAT_TEST_TMUX=fixture spawn_task
  expect_code 1 "$CODE" 'ambient tmux session refuses Boat commands'
  assert_contains "$OUT" 'must run outside tmux' 'ambient session refusal explanation'
  assert_no_grep '^inventory ' "$FIXTURES/calls" 'ambient session reached inventory'
  assert_no_grep '^brief ' "$FIXTURES/calls" 'ambient session rewrote instructions'
  new_case same-id-orphan-retry
  seed_project firstmate
  mkdir -p "$REMOTE_HOME/data/task-one"
  printf 'Original worker instructions\n' > "$REMOTE_HOME/data/task-one/brief.md"
  printf 'Original launch instructions\n' > "$REMOTE_HOME/data/task-one/launch-brief.md"
  cp "$REMOTE_HOME/data/task-one/brief.md" "$FIXTURES/brief.before"
  cp "$REMOTE_HOME/data/task-one/launch-brief.md" "$FIXTURES/launch.before"
  printf 'fm-task-one\n' > "$FIXTURES/windows"
  set_json request '.intent = "Replacement instructions"'
  spawn_task
  expect_code 1 "$CODE" 'same-ID orphan endpoint refuses retry'
  assert_no_grep '^brief ' "$FIXTURES/calls" 'orphan retry regenerated the brief'
  assert_no_grep '^spawn ' "$FIXTURES/calls" 'orphan retry reached native spawn'
  cmp -s "$FIXTURES/brief.before" "$REMOTE_HOME/data/task-one/brief.md" || fail 'orphan retry changed worker instructions'
  cmp -s "$FIXTURES/launch.before" "$REMOTE_HOME/data/task-one/launch-brief.md" || fail 'orphan retry changed launch instructions'
  assert_equals 1 "$(grep -c '^inventory ' "$FIXTURES/calls")" 'same-ID guard performed a second inventory'
  assert_absent "$REMOTE_HOME/state/.boat-worker.lock" 'orphan retry leaked worker lock'
  pass 'same-ID orphan retry refuses before either worker brief can change'
}

test_independent_resume_before_refusal() {
  local variant
  for variant in failed-read exhausted-budget; do
    new_case "independent-resume-$variant"
    : > "$FIXTURES/independent-resume"
    if [ "$variant" = failed-read ]; then
      : > "$FIXTURES/limits.fail"
    else
      set_json limits '.creditUsedSeconds = 2000000'
    fi
    send_task
    expect_code 1 "$CODE" "$variant refuses after independent resume"
    assert_grep 'independent-resume during limits read' "$FIXTURES/calls" 'independent transition was not exercised'
    assert_no_grep 'boat --no-update resume' "$FIXTURES/calls" 'refused invocation resumed a box'
    assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'refusal stopped independently resumed box'
    assert_present "$FIXTURES/resumed" 'independently resumed box did not remain running'
    assert_no_grep 'on ' "$FIXTURES/calls" 'refused invocation reached remote transport'
  done
  pass 'pre-resume safety refusals preserve an independently resumed box'
}

test_instance_changes_at_action_boundary() {
  new_case instance-changes-during-alias-refresh
  cp "$FIXTURES/ready.json" "$FIXTURES/info.json"
  seed_receipt
  : > "$FIXTURES/rotate-on-alias"
  : > "$FIXTURES/use-real-worker"
  send_task
  expect_code 1 "$CODE" 'changed instance refuses remote spawn'
  assert_contains "$OUT" 'Boat instance changed; action refused' 'remote instance refusal was not returned'
  assert_no_grep '^spawn ' "$FIXTURES/calls" 'changed instance launched a worker'
  assert_absent "$REMOTE_HOME/data/task-one/brief.md" 'changed instance wrote a worker brief'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'changed running instance was stopped'

  new_case instance-changes-before-teardown-stop
  seed_receipt
  seed_worker task-one ship firstmate 'state: done complete'
  : > "$FIXTURES/rotate-after-teardown"
  run_entry "$LOCAL_HOME" fm-boat-send.sh --teardown task-one
  expect_code 1 "$CODE" 'changed instance refuses last-task stop'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'changed teardown instance was stopped'

  new_case instance-changes-before-refusal-stop
  set_json request '.mode = "no-mistakes"'
  : > "$FIXTURES/use-real-worker"
  : > "$FIXTURES/rotate-after-idle"
  send_task
  expect_code 1 "$CODE" 'changed instance refuses cleanup stop'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'changed refusal instance was stopped'
  pass 'instance changes refuse remote work and later Boat stops'
}

test_box_config_and_environment() {
  local variant
  for variant in absent directory symlink unsafe multiple whitespace blank-lines; do
    new_case "box-config-$variant"
    case "$variant" in
      absent) rm "$LOCAL_HOME/config/boat-box-id" ;;
      directory) rm "$LOCAL_HOME/config/boat-box-id"; mkdir "$LOCAL_HOME/config/boat-box-id" ;;
      symlink) rm "$LOCAL_HOME/config/boat-box-id"; ln -s "$FIXTURES/box-id" "$LOCAL_HOME/config/boat-box-id" ;;
      unsafe) printf 'bx_../bad\n' > "$LOCAL_HOME/config/boat-box-id" ;;
      multiple) printf 'bx_ahnbu3qr\nbx_23456789\n' > "$LOCAL_HOME/config/boat-box-id" ;;
      whitespace) printf ' bx_ahnbu3qr\n' > "$LOCAL_HOME/config/boat-box-id" ;;
      blank-lines) printf 'bx_ahnbu3qr\n\n' > "$LOCAL_HOME/config/boat-box-id" ;;
    esac
    send_task
    expect_code 1 "$CODE" "$variant configured box refuses"
    [ ! -s "$FIXTURES/calls" ] || fail "$variant config contacted Boat"
  done
  new_case replacement-configured-box
  printf 'bx_23456789\n' > "$LOCAL_HOME/config/boat-box-id"
  cp "$LOCAL_HOME/config/boat-box-id" "$FIXTURES/box-id"
  set_json info '.sandbox.id = "bx_23456789"'
  set_json ready '.sandbox.id = "bx_23456789"'
  set_json list '.sandboxes[0].id = "bx_23456789"'
  set_json usage '.sandboxId = "bx_23456789"'
  send_task
  expect_code 0 "$CODE" "approved replacement box dispatch: $OUT"
  assert_grep 'boat --no-update resume bx_23456789 --environment fm-code --ttl 14400 --json' "$FIXTURES/calls" 'configured replacement did not resume'
  assert_no_grep 'bx_ahnbu3qr' "$FIXTURES/calls" 'sender still used previous box id'
  assert_equals 'bx_23456789 22222222-2222-4222-8222-222222222222 fm-code' "$(cat "$LOCAL_HOME/state/.boat-environment")" 'replacement receipt not bound to new box'
  for variant in missing wrong protected; do
    new_case "resumed-environment-$variant"
    case "$variant" in
      missing) set_json ready 'del(.sandbox.environment)' ;;
      wrong) set_json ready '.sandbox.environment = "base"' ;;
      protected) set_json ready '.sandbox.noEnv = true' ;;
    esac
    send_task
    expect_code 1 "$CODE" "$variant resumed environment refuses"
    assert_no_grep 'on --stdin boat-eng' "$FIXTURES/calls" "$variant environment dispatched a worker"
    assert_grep 'boat --no-update stop bx_ahnbu3qr --json' "$FIXTURES/calls" "$variant environment left newly resumed box on"
  done
  new_case running-wrong-environment
  set_json ready '.sandbox.environment = "base"'
  cp "$FIXTURES/ready.json" "$FIXTURES/info.json"
  seed_receipt
  send_task
  expect_code 1 "$CODE" 'running wrong environment refuses'
  assert_no_grep 'on --stdin boat-eng' "$FIXTURES/calls" 'wrong running environment dispatched'
  assert_no_grep 'boat --no-update stop' "$FIXTURES/calls" 'wrong running environment stopped existing work'
  new_case legacy-no-env-receipt
  cp "$FIXTURES/ready.json" "$FIXTURES/info.json"
  printf 'bx_ahnbu3qr %s\n' "$(cat "$FIXTURES/boot-id")" > "$LOCAL_HOME/state/.boat-no-env"
  send_task
  expect_code 1 "$CODE" 'legacy no-env receipt does not authorize environment dispatch'
  assert_no_grep 'on --stdin boat-eng' "$FIXTURES/calls" 'legacy no-env receipt reached transport'
  new_case receipt-wrong-environment
  cp "$FIXTURES/ready.json" "$FIXTURES/info.json"
  printf 'bx_ahnbu3qr %s base\n' "$(cat "$FIXTURES/boot-id")" > "$LOCAL_HOME/state/.boat-environment"
  send_task
  expect_code 1 "$CODE" 'receipt must bind fm-code'
  assert_no_grep 'on --stdin boat-eng' "$FIXTURES/calls" 'wrong receipt environment reached transport'
  pass 'configured box and current fm-code environment are required for dispatch'
}

test_box_config_and_environment
test_brief_placeholder_fill
test_independent_resume_before_refusal
test_instance_changes_at_action_boundary
test_same_id_orphan_retry
test_existing_backlog_row
test_confirmed_prelaunch_refusal_stop
test_native_spawn_refusal_stop
test_running_reservation_and_start
test_worker_start
test_ship_prerequisites_and_identity
test_validation
test_whole_timer_reservation
test_unreadable_caps
test_sender_success_and_timer
test_running_quota_and_route
test_prepare_before_route
test_teardown_stop
test_remote_cap_and_merge_authority
pass 'fm-boat-send'
