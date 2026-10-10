#!/usr/bin/env bash
# bin/fm-boat-alias-refresh.sh: the optional Boat sandbox SSH alias helper.
#
# Every case runs the real script against a fake `boat` binary that is first on
# PATH and against a temporary HOME, so neither the real Boat CLI nor the real
# ~/.ssh is ever reached. Host keys are real ED25519 keys generated into the
# fixture, and the written alias is read back through OpenSSH itself (`ssh -G`
# and `ssh-keygen`) instead of by matching the block's text.
#
# What these pin:
#   1. A first run writes an alias OpenSSH resolves to the sandbox's endpoint
#      and pins to the host key Boat returned, using only the two read-only
#      Boat calls, each with --no-update.
#   2. A run after a resume replaces that alias's endpoint and pinned key, and
#      leaves the operator's other config and the default known_hosts alone.
#   3. With no SSH endpoint the sandbox ip on port 22 is used.
#   4. A stopped sandbox, a failed Boat call, an unreadable host key, an
#      unexpected endpoint, a missing CLI key, and invalid use are refused
#      before anything under ~/.ssh changes.
#   5. A symlinked config and an unterminated block are refused unchanged.
#   6. The run waits for the disk restore, and reports a restore that does not
#      finish as a failure with the alias already refreshed.
#   7. --remove deletes only that alias's block and known-hosts file, without
#      calling Boat.
#   8. FM_BOAT_BIN selects the CLI, and --help prints the usage.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for tool in jq ssh ssh-keygen; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'skip: %s not found\n' "$tool"; exit 0; }
done

HELPER="$ROOT/bin/fm-boat-alias-refresh.sh"
ID=bx_fixture1
TMP_ROOT=$(fm_test_tmproot fm-boat-alias-refresh)

# The fake Boat CLI answers only the two read-only calls the helper may make and
# records every invocation. `info` serves info.<n>.json for its n-th call when
# that file exists, so a case can script a restore that finishes later, and
# fails its n-th call when info.<n>.fail exists.
FAKE_BOAT="$TMP_ROOT/fake-boat"
cat > "$FAKE_BOAT" <<'SH'
#!/usr/bin/env bash
set -u
D=$FAKE_BOAT_DIR
printf '%s\n' "$*" >> "$D/calls"
[ "${1:-}" = --no-update ] || { echo "fake boat: --no-update missing: $*" >&2; exit 97; }
shift
case "${1:-}" in
  info)
    [ "$*" = "info $FAKE_BOAT_ID --json" ] || { echo "fake boat: unexpected: $*" >&2; exit 97; }
    n=$(($(cat "$D/info.count" 2>/dev/null || echo 0) + 1))
    printf '%s\n' "$n" > "$D/info.count"
    [ ! -e "$D/info.fail" ] && [ ! -e "$D/info.$n.fail" ] || { echo "fake boat: info failed" >&2; exit 1; }
    if [ -f "$D/info.$n.json" ]; then cat "$D/info.$n.json"; else cat "$D/info.json"; fi
    ;;
  exec)
    [ "$*" = "exec $FAKE_BOAT_ID --json -- cat /etc/ssh/ssh_host_ed25519_key.pub" ] ||
      { echo "fake boat: unexpected: $*" >&2; exit 97; }
    cat "$D/exec.json"
    ;;
  *) echo "fake boat: unexpected: $*" >&2; exit 97 ;;
esac
SH
chmod +x "$FAKE_BOAT"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cp "$FAKE_BOAT" "$FAKEBIN/boat"

# Two real host keys, as a sandbox would present before and after a resume.
KEYS="$TMP_ROOT/keys"
mkdir -p "$KEYS"
for name in host1 host2; do
  HOME="$TMP_ROOT" ssh-keygen -q -t ed25519 -N '' -C "$name" -f "$KEYS/$name" ||
    fail "could not generate the $name fixture key"
done
FP1=$(ssh-keygen -lf "$KEYS/host1.pub" | awk '{print $2}')
FP2=$(ssh-keygen -lf "$KEYS/host2.pub" | awk '{print $2}')
[ -n "$FP1" ] && [ -n "$FP2" ] && [ "$FP1" != "$FP2" ] || fail "fixture host keys are unusable"

new_case() {  # <name>; sets CASE, SSH, and BOAT
  CASE="$TMP_ROOT/$1"
  SSH="$CASE/home/.ssh"
  BOAT="$CASE/boat"
  mkdir -p "$SSH" "$BOAT"
  chmod 700 "$SSH"
  # The helper only requires that the Boat CLI's key exists; it never reads it.
  : > "$SSH/ascii_box_ed25519"
}

set_info() {  # <state> <sshEndpoint|null> <ip|null> <hydrated> [file]
  jq -n --arg state "$1" --arg endpoint "$2" --arg ip "$3" --argjson hydrated "$4" '
    {sandbox: {
      state: $state,
      sshEndpoint: (if $endpoint == "null" then null else $endpoint end),
      ip: (if $ip == "null" then null else $ip end),
      hydrated: $hydrated
    }}' > "$BOAT/${5:-info.json}"
}

set_exec() {  # <exit-code> <stdout>
  jq -n --argjson code "$1" --arg out "$2" '{exitCode: $code, stdout: $out, stderr: ""}' > "$BOAT/exec.json"
}

set_hostkey() {  # <host1|host2>
  set_exec 0 "$(cat "$KEYS/$1.pub")"$'\n'
}

# Sets OUT, ERR, and CODE. Extra leading NAME=value words reach the helper's
# environment.
run_helper() {
  OUT=$(env -u FM_BOAT_BIN -u FM_BOAT_HYDRATE_WAIT HOME="$CASE/home" PATH="$FAKEBIN:$PATH" \
    FAKE_BOAT_DIR="$BOAT" FAKE_BOAT_ID="$ID" FM_BOAT_HYDRATE_POLL=1 "$@" 2>"$CASE/stderr")
  CODE=$?
  ERR=$(cat "$CASE/stderr")
}

refresh() {  # [NAME=value...] <helper args...>
  local env_words=()
  while [ "$#" -gt 0 ]; do
    case "$1" in [A-Z]*=*) env_words+=("$1"); shift ;; *) break ;; esac
  done
  run_helper ${env_words[@]+"${env_words[@]}"} bash "$HELPER" "$@"
}

effective() {  # <alias> <lowercase ssh option>; the value OpenSSH resolves
  ssh -T -F "$SSH/config" -G "$1" | awk -v key="$2" '$1 == key { print $2; exit }'
}

assert_alias() {  # <alias> <host> <port> <fingerprint> <label>
  local alias=$1 known strict
  known="$SSH/known_hosts_$(printf '%s' "$alias" | tr - _)"
  assert_equals "$2" "$(effective "$alias" hostname)" "$5: host"
  assert_equals "$3" "$(effective "$alias" port)" "$5: port"
  assert_equals user "$(effective "$alias" user)" "$5: user"
  assert_equals "$alias" "$(effective "$alias" hostkeyalias)" "$5: host key alias"
  assert_equals "$known" "$(effective "$alias" userknownhostsfile)" "$5: known-hosts file"
  assert_equals /dev/null "$(effective "$alias" globalknownhostsfile)" "$5: global known-hosts file"
  assert_equals "$SSH/ascii_box_ed25519" "$(effective "$alias" identityfile)" "$5: identity file"
  assert_equals no "$(effective "$alias" forwardagent)" "$5: agent forwarding"
  strict=$(effective "$alias" stricthostkeychecking)
  case "$strict" in true|yes) ;; *) fail "$5: strict host-key checking is '$strict'" ;; esac
  ssh-keygen -F "$alias" -f "$known" >/dev/null || fail "$5: $alias is not pinned in $known"
  assert_equals 1 "$(grep -c . "$known")" "$5: the known-hosts file must hold one key"
  assert_equals "$4" "$(ssh-keygen -lf "$known" | awk '{print $2}')" "$5: pinned fingerprint"
}

mode_of() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

ssh_listing() {
  ( cd "$SSH" && find . -mindepth 1 | LC_ALL=C sort | tr '\n' ' ' )
}

boat_calls() {
  if [ -f "$BOAT/calls" ]; then wc -l < "$BOAT/calls" | tr -d ' '; else echo 0; fi
}

# --- T1: a first run writes a pinned, resolvable alias -------------------------
test_first_run_writes_pinned_alias() {
  new_case first
  set_info running 203.0.113.7:19034 2001:db8::22 true
  set_hostkey host1

  refresh "$ID" boat-pilot
  expect_code 0 "$CODE" "a first run must succeed"$'\n'"$ERR"
  assert_contains "$OUT" "sandbox=$ID state=running" "the sandbox and state must be reported"
  assert_contains "$OUT" "endpoint: none -> 203.0.113.7:19034" "the new endpoint must be reported"
  assert_contains "$OUT" "hostkey:  none -> $FP1" "the new fingerprint must be reported"
  assert_contains "$OUT" "hydrated=true waited=" "the finished restore must be reported"
  assert_alias boat-pilot 203.0.113.7 19034 "$FP1" "first run"
  assert_equals 600 "$(mode_of "$SSH/config")" "the config must be private"
  assert_equals 600 "$(mode_of "$SSH/known_hosts_boat_pilot")" "the known-hosts file must be private"
  assert_equals "./ascii_box_ed25519 ./config ./known_hosts_boat_pilot " "$(ssh_listing)" \
    "only the config and the dedicated known-hosts file may appear"
  assert_equals "--no-update info $ID --json
--no-update exec $ID --json -- cat /etc/ssh/ssh_host_ed25519_key.pub" "$(cat "$BOAT/calls")" \
    "only the two read-only Boat calls may run"
  pass "T1 a first run writes a pinned, resolvable alias"
}

# --- T2: a resume replaces the alias and nothing else --------------------------
test_resume_replaces_only_the_alias() {
  new_case resume
  cat > "$SSH/config" <<'EOF'
Host existing
  HostName existing.invalid
  User someone
EOF
  printf 'unrelated.invalid ssh-ed25519 AAAAunrelated\n' > "$SSH/known_hosts"
  cp "$SSH/known_hosts" "$CASE/known_hosts.before"
  set_info running 203.0.113.7:19034 null true
  set_hostkey host1
  refresh "$ID" boat-pilot
  expect_code 0 "$CODE" "the first run must succeed"$'\n'"$ERR"
  # An operator block added later leaves the managed block mid-file.
  printf 'Host later\n  HostName later.invalid\n' >> "$SSH/config"

  set_info running 198.51.100.9:19043 null true
  set_hostkey host2
  refresh "$ID" boat-pilot
  expect_code 0 "$CODE" "the run after a resume must succeed"$'\n'"$ERR"
  assert_contains "$OUT" "endpoint: 203.0.113.7:19034 -> 198.51.100.9:19043" "the endpoint change must be reported"
  assert_contains "$OUT" "hostkey:  $FP1 -> $FP2" "the host-key change must be reported"
  assert_alias boat-pilot 198.51.100.9 19043 "$FP2" "after a resume"
  assert_equals existing.invalid "$(effective existing hostname)" "an earlier operator alias must survive"
  assert_equals someone "$(effective existing user)" "an earlier operator alias must keep its options"
  assert_equals later.invalid "$(effective later hostname)" "a later operator alias must survive"
  assert_equals 3 "$(grep -c '^Host ' "$SSH/config")" "the alias must be replaced, not duplicated"
  cmp -s "$SSH/known_hosts" "$CASE/known_hosts.before" || fail "the default known_hosts file was changed"
  pass "T2 a resume replaces the alias and nothing else"
}

# --- T3: no SSH endpoint falls back to the sandbox ip --------------------------
test_ip_fallback() {
  new_case ipv6
  set_info ready null 2001:db8::22 true
  set_hostkey host1
  refresh "$ID" boat-six
  expect_code 0 "$CODE" "a sandbox with only an ip must succeed"$'\n'"$ERR"
  assert_contains "$OUT" "state=ready" "the ready state must be accepted"
  assert_alias boat-six 2001:db8::22 22 "$FP1" "ip fallback"
  pass "T3 no SSH endpoint falls back to the sandbox ip on port 22"
}

# --- T4: refusals happen before anything under ~/.ssh changes ------------------
expect_refusal() {  # <code> <message> <label>; the last refresh must have changed nothing
  expect_code "$1" "$CODE" "$3"$'\n'"$OUT"$'\n'"$ERR"
  assert_contains "$ERR" "$2" "$3: the reason must be named"
  assert_equals "$4" "$(ssh_listing)" "$3: ~/.ssh must be unchanged"
}

test_refusals_change_nothing() {
  local bare="./ascii_box_ed25519 "
  new_case refusals
  set_hostkey host1

  set_info stopped null null false
  refresh "$ID" boat-pilot
  expect_refusal 1 "is not running (state=stopped)" "a stopped sandbox" "$bare"
  assert_equals 1 "$(boat_calls)" "a stopped sandbox must not be asked for its host key"

  set_info running 203.0.113.7:19034 null true
  : > "$BOAT/info.fail"
  refresh "$ID" boat-pilot
  expect_refusal 1 "boat info failed" "a failed boat info" "$bare"
  rm -f "$BOAT/info.fail"
  printf 'service unavailable\n' > "$BOAT/info.json"
  refresh "$ID" boat-pilot
  expect_refusal 1 "boat info returned unexpected output" "boat info output that is not JSON" "$bare"
  printf '[]\n' > "$BOAT/info.json"
  refresh "$ID" boat-pilot
  expect_refusal 1 "boat info returned unexpected output" "boat info output with no sandbox object" "$bare"
  set_info running 203.0.113.7:19034 null true

  set_exec 1 ''
  refresh "$ID" boat-pilot
  expect_refusal 1 "could not read the sandbox host key" "a failed boat exec" "$bare"
  set_exec 0 'ssh-rsa AAAAB3NzaC1yc2E host'
  refresh "$ID" boat-pilot
  expect_refusal 1 "could not read the sandbox host key" "a host key of another type" "$bare"
  set_exec 0 'ssh-ed25519 AAAAnotakey host'
  refresh "$ID" boat-pilot
  expect_refusal 1 "ssh-keygen cannot read" "a malformed host key" "$bare"
  set_hostkey host1

  set_info running 'bad;host:19034' null true
  refresh "$ID" boat-pilot
  expect_refusal 1 "unexpected SSH host" "an endpoint host with shell characters" "$bare"
  set_info running 203.0.113.7:22x null true
  refresh "$ID" boat-pilot
  expect_refusal 1 "unexpected SSH port" "a non-numeric endpoint port" "$bare"
  set_info running null null true
  refresh "$ID" boat-pilot
  expect_refusal 1 "no SSH endpoint or ip" "a sandbox with no address" "$bare"

  set_info running 203.0.113.7:19034 null true
  rm -f "$BOAT/calls"
  refresh
  expect_refusal 2 "expected a sandbox id and an alias" "no arguments" "$bare"
  refresh sandbox boat-pilot
  expect_refusal 2 "not a sandbox id" "an id without the sandbox prefix" "$bare"
  refresh 'bx_a;b' boat-pilot
  expect_refusal 2 "unsafe sandbox id" "an id with shell characters" "$bare"
  refresh "$ID" 'boat pilot'
  expect_refusal 2 "unsafe alias" "an alias with a space" "$bare"
  refresh "$ID" -oProxyCommand=x
  expect_refusal 2 "unsafe alias" "an alias that reads as an option" "$bare"
  refresh FM_BOAT_HYDRATE_POLL=0 "$ID" boat-pilot
  expect_refusal 2 "FM_BOAT_HYDRATE_POLL" "a poll that would never advance the wait" "$bare"
  refresh FM_BOAT_HYDRATE_WAIT=soon "$ID" boat-pilot
  expect_refusal 2 "FM_BOAT_HYDRATE_WAIT" "a non-numeric wait" "$bare"
  rm -f "$SSH/ascii_box_ed25519"
  refresh "$ID" boat-pilot
  expect_refusal 1 "no Boat CLI key" "a missing Boat CLI key" ""
  assert_equals 0 "$(boat_calls)" "invalid use and a missing CLI key must not reach Boat"
  pass "T4 refusals happen before anything under ~/.ssh changes"
}

# --- T5: a config the rewrite would damage is refused unchanged ----------------
test_unsafe_config_is_refused() {
  new_case symlink
  set_info running 203.0.113.7:19034 null true
  set_hostkey host1
  mkdir -p "$CASE/dotfiles"
  printf 'Host existing\n  HostName existing.invalid\n' > "$CASE/dotfiles/ssh_config"
  cp "$CASE/dotfiles/ssh_config" "$CASE/config.before"
  ln -s "$CASE/dotfiles/ssh_config" "$SSH/config"
  refresh "$ID" boat-pilot
  expect_refusal 1 "symbolic link" "a symlinked config" "./ascii_box_ed25519 ./config "
  [ -L "$SSH/config" ] || fail "the config symlink was replaced"
  cmp -s "$CASE/dotfiles/ssh_config" "$CASE/config.before" || fail "the symlink target was changed"
  refresh --remove boat-pilot
  expect_refusal 1 "symbolic link" "removing from a symlinked config" "./ascii_box_ed25519 ./config "
  [ -L "$SSH/config" ] || fail "the config symlink was replaced by --remove"

  new_case unterminated
  set_info running 203.0.113.7:19034 null true
  set_hostkey host1
  cat > "$SSH/config" <<'EOF'
Host existing
  HostName existing.invalid
# >>> boat-alias boat-pilot >>>
Host boat-pilot
  HostName 192.0.2.1
Host later
  HostName later.invalid
EOF
  cp "$SSH/config" "$CASE/config.before"
  refresh "$ID" boat-pilot
  expect_refusal 1 "no matching end line" "an unterminated block" "./ascii_box_ed25519 ./config "
  cmp -s "$SSH/config" "$CASE/config.before" || fail "an unterminated block was rewritten"
  refresh --remove boat-pilot
  expect_refusal 1 "no matching end line" "removing an unterminated block" "./ascii_box_ed25519 ./config "
  cmp -s "$SSH/config" "$CASE/config.before" || fail "an unterminated block was removed"
  pass "T5 a symlinked config and an unterminated block are refused unchanged"
}

# --- T6: the run waits for the disk restore ------------------------------------
test_restore_wait() {
  new_case restore
  set_hostkey host1
  set_info running 203.0.113.7:19034 null false
  set_info running 203.0.113.7:19034 null true info.3.json
  refresh "$ID" boat-pilot
  expect_code 0 "$CODE" "a restore that finishes in time must succeed"$'\n'"$ERR"
  assert_contains "$OUT" "hydrated=true waited=" "the finished restore must be reported"
  assert_equals 3 "$(cat "$BOAT/info.count")" "the restore must be polled until it finishes"

  new_case restore-late
  set_hostkey host1
  set_info running 203.0.113.7:19034 null false
  refresh FM_BOAT_HYDRATE_WAIT=1 "$ID" boat-pilot
  expect_code 1 "$CODE" "a restore that does not finish must fail"$'\n'"$OUT"
  assert_contains "$OUT" "hydrated=false waited=" "the unfinished restore must be reported"
  assert_contains "$ERR" "has not finished restoring its disk" "the unfinished restore must be named"
  assert_alias boat-pilot 203.0.113.7 19034 "$FP1" "an unfinished restore still leaves the refreshed alias"

  new_case restore-poll-fails
  set_hostkey host1
  set_info running 203.0.113.7:19034 null false
  : > "$BOAT/info.2.fail"
  refresh FM_BOAT_HYDRATE_WAIT=1 "$ID" boat-pilot
  expect_code 1 "$CODE" "a restore whose only poll failed must fail"$'\n'"$OUT"
  assert_contains "$OUT" "hydrated=unknown waited=" "a failed poll must be reported as unknown"

  new_case restore-poll-recovers
  set_hostkey host1
  set_info running 203.0.113.7:19034 null false
  : > "$BOAT/info.2.fail"
  set_info running 203.0.113.7:19034 null true info.3.json
  refresh "$ID" boat-pilot
  expect_code 0 "$CODE" "a failed poll must not end the wait"$'\n'"$ERR"
  assert_contains "$OUT" "hydrated=true waited=" "the restore that finished after a failed poll must be reported"

  new_case restore-nowait
  set_hostkey host1
  set_info running 203.0.113.7:19034 null false
  refresh FM_BOAT_HYDRATE_WAIT=0 "$ID" boat-pilot
  expect_code 1 "$CODE" "a zero wait must report an unfinished restore at once"$'\n'"$OUT"
  assert_equals 1 "$(cat "$BOAT/info.count")" "a zero wait must not poll"
  pass "T6 the run waits for the disk restore and fails when it does not finish"
}

# --- T7: --remove deletes only that alias --------------------------------------
test_remove() {
  new_case remove
  set_info running 203.0.113.7:19034 null true
  set_hostkey host1
  printf 'Host existing\n  HostName existing.invalid\n' > "$SSH/config"
  refresh "$ID" boat-pilot
  expect_code 0 "$CODE" "writing the first alias must succeed"$'\n'"$ERR"
  printf 'Host later\n  HostName later.invalid\n' >> "$SSH/config"
  refresh "$ID" boat-two
  expect_code 0 "$CODE" "writing the second alias must succeed"$'\n'"$ERR"
  rm -f "$BOAT/calls"

  refresh --remove boat-pilot
  expect_code 0 "$CODE" "--remove must succeed"$'\n'"$ERR"
  assert_contains "$OUT" "removed: alias boat-pilot" "the removal must be reported"
  assert_absent "$SSH/known_hosts_boat_pilot" "the removed alias kept its known-hosts file"
  assert_no_grep "boat-pilot" "$SSH/config" "the removed alias is still in the config"
  assert_equals existing.invalid "$(effective existing hostname)" "an earlier operator alias must survive"
  assert_equals later.invalid "$(effective later hostname)" "a later operator alias must survive"
  assert_alias boat-two 203.0.113.7 19034 "$FP1" "the other Boat alias"
  refresh --remove boat-two
  expect_code 0 "$CODE" "removing the second alias must succeed"$'\n'"$ERR"
  cmp -s "$SSH/config" - <<'EOF' || fail "the operator's own config was not left exactly as written"
Host existing
  HostName existing.invalid
Host later
  HostName later.invalid
EOF

  new_case remove-whole
  set_info running 203.0.113.7:19034 null true
  set_hostkey host1
  refresh "$ID" boat-pilot
  expect_code 0 "$CODE" "writing the only alias must succeed"$'\n'"$ERR"
  rm -f "$BOAT/calls"
  refresh --remove boat-pilot
  expect_code 0 "$CODE" "removing the only alias must succeed"$'\n'"$ERR"
  assert_equals "./ascii_box_ed25519 " "$(ssh_listing)" "a config that held only the alias must be removed"
  refresh --remove boat-pilot
  expect_code 0 "$CODE" "removing an absent alias must succeed"$'\n'"$ERR"
  refresh --remove
  expect_code 2 "$CODE" "--remove without an alias is invalid use"
  refresh --remove 'boat pilot'
  expect_code 2 "$CODE" "--remove with an unsafe alias is invalid use"
  assert_equals 0 "$(boat_calls)" "--remove must not call Boat"
  pass "T7 --remove deletes only that alias and never calls Boat"
}

# --- T8: FM_BOAT_BIN selects the CLI; --help prints the usage ------------------
test_cli_override_and_help() {
  local tripbin
  new_case override
  set_info running 203.0.113.7:19034 null true
  set_hostkey host1
  # A `boat` on PATH that must never run once FM_BOAT_BIN names another CLI.
  tripbin=$(fm_fakebin "$CASE")
  printf '#!/usr/bin/env bash\necho tripped >> "%s"\nexit 99\n' "$CASE/tripped" > "$tripbin/boat"
  chmod +x "$tripbin/boat"
  OUT=$(env HOME="$CASE/home" PATH="$tripbin:$PATH" FAKE_BOAT_DIR="$BOAT" FAKE_BOAT_ID="$ID" \
    FM_BOAT_BIN="$FAKE_BOAT" bash "$HELPER" "$ID" boat-pilot 2>&1)
  CODE=$?
  expect_code 0 "$CODE" "a named CLI must be used"$'\n'"$OUT"
  assert_absent "$CASE/tripped" "the boat on PATH ran despite FM_BOAT_BIN"
  assert_equals 2 "$(boat_calls)" "the named CLI must receive both calls"
  OUT=$(env HOME="$CASE/home" PATH="$tripbin:$PATH" FM_BOAT_BIN="$CASE/no-such-cli" \
    bash "$HELPER" "$ID" boat-pilot 2>&1)
  CODE=$?
  expect_code 1 "$CODE" "an unresolvable CLI must be refused"$'\n'"$OUT"
  assert_contains "$OUT" "is required but does not resolve" "the missing CLI must be named"

  rm -f "$BOAT/calls"
  refresh --help
  expect_code 0 "$CODE" "--help must succeed"
  assert_contains "$OUT" "fm-boat-alias-refresh.sh <sandbox-id> <alias>" "--help must print the usage"
  assert_contains "$OUT" "FM_BOAT_HYDRATE_WAIT" "--help must name the environment knobs"
  assert_equals 0 "$(boat_calls)" "--help must not call Boat"
  pass "T8 FM_BOAT_BIN selects the CLI; --help prints the usage"
}

test_first_run_writes_pinned_alias
test_resume_replaces_only_the_alias
test_ip_fallback
test_refusals_change_nothing
test_unsafe_config_is_refused
test_restore_wait
test_remove
test_cli_override_and_help

echo "# all fm-boat-alias-refresh tests passed"
