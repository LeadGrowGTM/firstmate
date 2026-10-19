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
#   1. A first run writes an alias with no address and pins the host key Boat
#      returned, using only two read-only Boat calls with --no-update.
#   2. A run after a resume replaces that alias's endpoint proof and pinned key, and
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
#   9. A refresh of a stopped sandbox parks its existing alias with no address
#      and no pin.
#  10. --verify leaves a non-Boat alias alone, prints Boat's confirmed address
#      and pin, and refuses a moved, parked, stopped,
#      unrestored, or re-keyed sandbox and a block with no sandbox id.
#  11. The real fm-on.sh dials a Boat alias only at the address and key Boat
#      just confirmed, refuses a moved alias until refresh, and treats a
#      stopped or re-keyed sandbox as unavailable without connecting.
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
REAL_TIMEOUT=$(command -v timeout || command -v gtimeout || true)
if [ -n "$REAL_TIMEOUT" ]; then
  cat > "$FAKEBIN/timeout" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$3" >> "\$FAKE_BOAT_DIR/timeout.calls"
exec '$REAL_TIMEOUT' "\$@"
SH
  chmod +x "$FAKEBIN/timeout"
fi

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

assert_alias() {  # <alias> <fingerprint> <label>
  local alias=$1 known strict
  known="$SSH/known_hosts_$(printf '%s' "$alias" | tr - _)"
  assert_equals "$alias" "$(effective "$alias" hostname)" "$3: no address in the alias"
  assert_equals 22 "$(effective "$alias" port)" "$3: no port in the alias"
  assert_equals user "$(effective "$alias" user)" "$3: user"
  assert_equals "$alias" "$(effective "$alias" hostkeyalias)" "$3: host key alias"
  assert_equals "$known" "$(effective "$alias" userknownhostsfile)" "$3: known-hosts file"
  assert_equals /dev/null "$(effective "$alias" globalknownhostsfile)" "$3: global known-hosts file"
  assert_equals "$SSH/ascii_box_ed25519" "$(effective "$alias" identityfile)" "$3: identity file"
  assert_equals no "$(effective "$alias" forwardagent)" "$3: agent forwarding"
  strict=$(effective "$alias" stricthostkeychecking)
  case "$strict" in true|yes) ;; *) fail "$3: strict host-key checking is '$strict'" ;; esac
  ssh-keygen -F "$alias" -f "$known" >/dev/null || fail "$3: $alias is not pinned in $known"
  assert_equals 1 "$(grep -c . "$known")" "$3: the known-hosts file must hold one key"
  assert_equals "$2" "$(ssh-keygen -lf "$known" | awk '{print $2}')" "$3: pinned fingerprint"
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
  assert_contains "$OUT" "endpoint: 203.0.113.7:19034" "the new endpoint must be reported"
  assert_contains "$OUT" "hostkey:  none -> $FP1" "the new fingerprint must be reported"
  assert_contains "$OUT" "hydrated=true waited=" "the finished restore must be reported"
  assert_alias boat-pilot "$FP1" "first run"
  assert_equals 600 "$(mode_of "$SSH/config")" "the config must be private"
  assert_equals 600 "$(mode_of "$SSH/known_hosts_boat_pilot")" "the known-hosts file must be private"
  assert_equals "./ascii_box_ed25519 ./config ./known_hosts_boat_pilot " "$(ssh_listing)" \
    "only the config and the dedicated known-hosts file may appear"
  assert_equals "--no-update info $ID --json
--no-update exec $ID --json -- cat /etc/ssh/ssh_host_ed25519_key.pub" "$(cat "$BOAT/calls")" \
    "only the two read-only Boat calls may run"
  if [ -n "$REAL_TIMEOUT" ]; then
    assert_equals $'15\n45' "$(cat "$BOAT/timeout.calls")" 'info and exec calls need individual bounds'
  fi
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
  assert_contains "$OUT" "endpoint: 198.51.100.9:19043" "the new endpoint must be reported"
  assert_contains "$OUT" "hostkey:  $FP1 -> $FP2" "the host-key change must be reported"
  assert_alias boat-pilot "$FP2" "after a resume"
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
  assert_alias boat-six "$FP1" "ip fallback"
  verify --verify boat-six
  expect_code 0 "$CODE" "the ip fallback must verify"$'\n'"$ERR"
  assert_contains "$OUT" 'HostName=2001:db8::22' "the fallback host must come from Boat"
  assert_contains "$OUT" 'Port=22' "the fallback port must come from Boat"
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
  if [ -n "$REAL_TIMEOUT" ]; then
    assert_equals 3 "$(grep -c '^15$' "$BOAT/timeout.calls")" 'every hydration info poll needs a bound'
  fi

  new_case restore-late
  set_hostkey host1
  set_info running 203.0.113.7:19034 null false
  refresh FM_BOAT_HYDRATE_WAIT=1 "$ID" boat-pilot
  expect_code 1 "$CODE" "a restore that does not finish must fail"$'\n'"$OUT"
  assert_contains "$OUT" "hydrated=false waited=" "the unfinished restore must be reported"
  assert_contains "$ERR" "has not finished restoring its disk" "the unfinished restore must be named"
  assert_alias boat-pilot "$FP1" "an unfinished restore still leaves the refreshed alias"

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
  assert_alias boat-two "$FP1" "the other Boat alias"
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

assert_parked() {  # <alias> <label>; the block holds no address and no pin
  assert_equals "$1" "$(effective "$1" hostname)" "$2: a parked alias must resolve to no address"
  assert_absent "$SSH/known_hosts_$(printf '%s' "$1" | tr - _)" "$2: a parked alias must keep no pin"
  assert_no_grep 203.0.113.7 "$SSH/config" "$2: the old address must be gone from the config"
}

# --- T9: a refresh of a stopped sandbox parks its existing alias ---------------
test_refresh_parks_a_stopped_alias() {
  new_case park
  printf 'Host existing\n  HostName existing.invalid\n' > "$SSH/config"
  set_info running 203.0.113.7:19034 null true
  set_hostkey host1
  refresh "$ID" boat-pilot
  expect_code 0 "$CODE" "writing the alias must succeed"$'\n'"$ERR"
  rm -f "$BOAT/calls"

  set_info stopped null null true
  refresh "$ID" boat-pilot
  expect_code 1 "$CODE" "a stopped sandbox must be refused"$'\n'"$OUT"
  assert_contains "$ERR" "is not running (state=stopped)" "the stopped state must be named"
  assert_parked boat-pilot "a refresh of a stopped sandbox"
  assert_equals existing.invalid "$(effective existing hostname)" "the operator's alias must survive parking"
  assert_equals "--no-update info $ID --json" "$(cat "$BOAT/calls")" "a stopped sandbox must not be asked for its host key"
  refresh --park "$ID" boat-pilot
  expect_code 0 "$CODE" "parking an already parked stopped alias must succeed"$'\n'"$ERR"
  : > "$BOAT/info.fail"
  refresh --park "$ID" boat-pilot
  expect_code 1 "$CODE" "parking must report an unreadable API"$'\n'"$ERR"
  assert_parked boat-pilot "an unreadable API after parking"
  rm -f "$BOAT/info.fail"

  set_info running 198.51.100.9:19043 null true
  set_hostkey host2
  refresh "$ID" boat-pilot
  expect_code 0 "$CODE" "a refresh after the next resume must succeed"$'\n'"$ERR"
  assert_contains "$OUT" "endpoint: 198.51.100.9:19043" "the new endpoint must be reported"
  assert_alias boat-pilot "$FP2" "a refresh of a parked alias"

  new_case park-api-failure
  set_info running 203.0.113.7:19034 null true
  set_hostkey host1
  refresh "$ID" boat-pilot
  expect_code 0 "$CODE" "writing the alias before a stop must succeed"$'\n'"$ERR"
  : > "$BOAT/info.fail"
  refresh --park "$ID" boat-pilot
  expect_code 1 "$CODE" "a failed post-stop API read must be reported"$'\n'"$ERR"
  assert_parked boat-pilot "a stopped alias after an unreadable API"
  pass "T9 a refresh of a stopped sandbox parks its alias with no address or pin"
}

# --- T10: --verify confirms the alias against Boat before every connection -----
verify() {  # [NAME=value...] <alias>
  refresh "$@"
}

test_verify() {
  local listing pins
  new_case verify
  set_info running 203.0.113.7:19034 null true
  set_hostkey host1

  verify --verify boat-pilot
  expect_code 3 "$CODE" "an alias with no Boat block is not a Boat alias"$'\n'"$ERR"
  assert_equals 0 "$(boat_calls)" "a non-Boat alias must not reach Boat"
  printf 'Host boat-pilot\n  HostName 192.0.2.50\n' > "$SSH/config"
  verify --verify boat-pilot
  expect_code 3 "$CODE" "an operator's own alias is not a Boat alias"$'\n'"$ERR"
  assert_equals 0 "$(boat_calls)" "an operator's own alias must not reach Boat"
  rm -f "$SSH/config"

  refresh "$ID" boat-pilot
  expect_code 0 "$CODE" "writing the alias must succeed"$'\n'"$ERR"
  rm -f "$BOAT/calls"
  verify --verify boat-pilot
  expect_code 0 "$CODE" "a running sandbox at its pinned address must verify"$'\n'"$ERR"
  pins="HostName=203.0.113.7
Port=19034
HostKeyAlias=boat-pilot
UserKnownHostsFile=$SSH/known_hosts_boat_pilot
GlobalKnownHostsFile=/dev/null
StrictHostKeyChecking=yes
UpdateHostKeys=no"
  assert_equals "$pins" "$OUT" "the verified address and pin must be printed as ssh options"
  assert_equals "--no-update info $ID --json
--no-update exec $ID --json -- cat /etc/ssh/ssh_host_ed25519_key.pub" "$(cat "$BOAT/calls")" \
    "verifying must use only the two read-only Boat calls"

  # Same endpoint, different host key: refused, nothing rewritten.
  set_hostkey host2
  cp "$SSH/config" "$CASE/config.before"
  cp "$SSH/known_hosts_boat_pilot" "$CASE/known.before"
  verify --verify boat-pilot
  expect_code 1 "$CODE" "a host key mismatch must be refused"$'\n'"$OUT"
  assert_contains "$ERR" "does not match the key pinned" "the mismatch must be named"
  assert_equals "" "$OUT" "a refusal must print no ssh options"
  cmp -s "$SSH/config" "$CASE/config.before" || fail "a host key mismatch rewrote the config"
  cmp -s "$SSH/known_hosts_boat_pilot" "$CASE/known.before" || fail "a host key mismatch replaced the pin"

  # A moved endpoint needs an explicit refresh before any connection.
  set_info running 198.51.100.9:19043 null true
  verify --verify boat-pilot
  expect_code 1 "$CODE" "a moved sandbox must be refused"$'\n'"$ERR"
  assert_contains "$ERR" "moved from its pinned endpoint" "the move must be named"
  refresh "$ID" boat-pilot
  expect_code 0 "$CODE" "an explicit refresh must accept the moved endpoint"$'\n'"$ERR"
  assert_alias boat-pilot "$FP2" "a verify after a move"

  # An unfinished restore is refused after the refresh.
  set_info running 198.51.100.9:19043 null false
  verify --verify boat-pilot
  expect_code 1 "$CODE" "an unfinished restore must be refused"$'\n'"$OUT"
  assert_contains "$ERR" "has not finished restoring" "the unfinished restore must be named"

  # A stopped sandbox parks the alias with only one Boat call.
  set_info stopped null null true
  rm -f "$BOAT/calls"
  verify --verify boat-pilot
  expect_code 1 "$CODE" "a stopped sandbox must be refused"$'\n'"$OUT"
  assert_contains "$ERR" "is not running (state=stopped)" "the stopped state must be named"
  assert_equals "--no-update info $ID --json" "$(cat "$BOAT/calls")" "a stopped sandbox must not be asked for its host key"
  assert_parked boat-pilot "a verify of a stopped sandbox"
  listing=$(ssh_listing)
  verify --verify boat-pilot
  expect_code 1 "$CODE" "a parked alias of a stopped sandbox must stay refused"$'\n'"$OUT"
  assert_equals "$listing" "$(ssh_listing)" "a second stopped verify must change nothing"

  # A parked alias needs an explicit refresh after the sandbox resumes.
  set_info running 192.0.2.44:19050 null true
  set_hostkey host1
  verify --verify boat-pilot
  expect_code 1 "$CODE" "a parked alias must not auto-connect after resume"$'\n'"$ERR"
  assert_contains "$ERR" "has no endpoint proof" "the parked state must be named"
  refresh "$ID" boat-pilot
  expect_code 0 "$CODE" "an explicit refresh of a parked alias must succeed"$'\n'"$ERR"
  assert_alias boat-pilot "$FP1" "an explicit refresh of a parked alias"

  # A failed Boat read is refused unchanged.
  cp "$SSH/config" "$CASE/config.before"
  : > "$BOAT/info.fail"
  verify --verify boat-pilot
  expect_code 1 "$CODE" "a failed Boat read must be refused"$'\n'"$OUT"
  cmp -s "$SSH/config" "$CASE/config.before" || fail "a failed Boat read rewrote the config"
  rm -f "$BOAT/info.fail"

  # A block from before the sandbox id line cannot be checked and is refused.
  new_case verify-legacy
  cat > "$SSH/config" <<'EOF'
# >>> boat-alias boat-pilot >>>
Host boat-pilot
  HostName 203.0.113.7
  Port 19034
# <<< boat-alias boat-pilot <<<
EOF
  verify --verify boat-pilot
  expect_code 1 "$CODE" "a block with no sandbox id must be refused"$'\n'"$OUT"
  assert_contains "$ERR" "names no sandbox" "the missing sandbox id must be named"
  assert_equals 0 "$(boat_calls)" "a block with no sandbox id must not reach Boat"

  verify --verify
  expect_code 2 "$CODE" "--verify without an alias is invalid use"
  verify --verify 'boat pilot'
  expect_code 2 "$CODE" "--verify with an unsafe alias is invalid use"
  pass "T10 --verify confirms a Boat alias against Boat and refuses a stopped, unrestored, or re-keyed sandbox"
}

# --- T11: fm-on.sh never dials a Boat alias Boat has not just confirmed --------
# The real fm-on.sh runs against a registry route whose host is the Boat alias,
# with the fake Boat CLI and a fake ssh that records each attempt.
test_fm_on_dials_only_confirmed_boat_addresses() {
  local fmhome ssh_log
  new_case fm-on
  fmhome="$CASE/fm-home"
  ssh_log="$CASE/ssh.log"
  mkdir -p "$fmhome/data"
  printf -- '- pilot - Boat overflow (host: boat-pilot; root: /home/user/firstmate; home: /home/user/fm-boat-eng; scope: overflow; projects: firstmate; added 2026-10-16)\n' \
    > "$fmhome/data/secondmates.md"
  cat > "$CASE/fake-ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SSH_LOG"
printf 'connected\n'
SH
  chmod +x "$CASE/fake-ssh"
  fm_on() {
    OUT=$(env -u FM_BOAT_BIN HOME="$CASE/home" PATH="$FAKEBIN:$PATH" FAKE_BOAT_DIR="$BOAT" FAKE_BOAT_ID="$ID" \
      FM_HOME="$fmhome" FM_SSH_BIN="$CASE/fake-ssh" FAKE_SSH_LOG="$ssh_log" \
      bash "$ROOT/bin/fm-on.sh" pilot fm-crew-state.sh 2>"$CASE/stderr")
    CODE=$?
    ERR=$(cat "$CASE/stderr")
  }
  ssh_calls() {
    if [ -f "$ssh_log" ]; then wc -l < "$ssh_log" | tr -d ' '; else echo 0; fi
  }

  set_info running 203.0.113.7:19034 null true
  set_hostkey host1
  refresh "$ID" boat-pilot
  expect_code 0 "$CODE" "writing the alias must succeed"$'\n'"$ERR"

  # A running sandbox at the pinned address is dialled with Boat's pins.
  fm_on
  expect_code 0 "$CODE" "a confirmed sandbox must be reached"$'\n'"$ERR"
  assert_equals connected "$OUT" "the remote command must run"
  assert_equals 1 "$(ssh_calls)" "one connection must be made"
  assert_contains "$(tail -n 1 "$ssh_log")" "-o HostName=203.0.113.7 -o Port=19034 -o HostKeyAlias=boat-pilot" \
    "the connection must pin Boat's address"
  assert_contains "$(tail -n 1 "$ssh_log")" "-o StrictHostKeyChecking=yes" "the connection must never accept a new key"

  # A moved endpoint is refused until an explicit refresh.
  set_info running 198.51.100.9:19043 null true
  set_hostkey host2
  fm_on
  expect_code 255 "$CODE" "a moved sandbox must be refused"$'\n'"$ERR"
  assert_equals 1 "$(ssh_calls)" "a moved sandbox must not be dialled"
  refresh "$ID" boat-pilot
  expect_code 0 "$CODE" "an explicit refresh must succeed"$'\n'"$ERR"
  fm_on
  expect_code 0 "$CODE" "a refreshed sandbox must be reached"$'\n'"$ERR"
  assert_equals 2 "$(ssh_calls)" "one more connection must be made"
  assert_contains "$(tail -n 1 "$ssh_log")" "-o HostName=198.51.100.9 -o Port=19043" "the connection must use the new address"
  assert_alias boat-pilot "$FP2" "fm-on after a move"

  # A host key Boat reports that differs from the pin is refused unconnected.
  set_hostkey host1
  fm_on
  expect_code 255 "$CODE" "a host key mismatch must read as unavailable transport"$'\n'"$OUT"
  assert_contains "$ERR" "does not match the key pinned" "the mismatch must be named"
  assert_contains "$ERR" "not connecting" "fm-on must say it did not connect"
  assert_equals 2 "$(ssh_calls)" "a host key mismatch must not connect"

  # A stopped sandbox is offline: no connection, no resume, alias parked.
  set_info stopped null null true
  rm -f "$BOAT/calls"
  fm_on
  expect_code 255 "$CODE" "a stopped sandbox must read as unavailable transport"$'\n'"$OUT"
  assert_contains "$ERR" "is not running (state=stopped)" "the stopped state must be named"
  assert_equals 2 "$(ssh_calls)" "a stopped sandbox must not be dialled"
  assert_equals "--no-update info $ID --json" "$(cat "$BOAT/calls")" "a stopped sandbox must get one read and no resume"
  assert_parked boat-pilot "fm-on for a stopped sandbox"
  fm_on
  expect_code 255 "$CODE" "a parked alias must stay offline"$'\n'"$OUT"
  assert_equals 2 "$(ssh_calls)" "a parked alias must not be dialled"

  # A route whose host is not a Boat alias never reaches Boat.
  rm -f "$SSH/config" "$BOAT/calls"
  fm_on
  expect_code 0 "$CODE" "a non-Boat route must connect as before"$'\n'"$ERR"
  assert_equals 3 "$(ssh_calls)" "a non-Boat route must connect once"
  assert_not_contains "$(tail -n 1 "$ssh_log")" "HostName=" "a non-Boat route must get no Boat pins"
  assert_equals 0 "$(boat_calls)" "a non-Boat route must not reach Boat"
  pass "T11 fm-on.sh dials a Boat alias only at the address and key Boat just confirmed"
}

test_direct_ssh_checks_boat_before_transport() {
  local nc_log calls
  new_case direct-ssh
  nc_log="$CASE/nc.log"
  cat > "$FAKEBIN/nc" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_NC_LOG"
exit 1
SH
  chmod +x "$FAKEBIN/nc"
  set_info running 203.0.113.7:19034 null true
  set_hostkey host1
  printf 'Host *\n  ProxyCommand false\n' > "$SSH/config"
  refresh "$ID" boat-pilot
  expect_code 0 "$CODE" "writing the guarded alias must succeed"
  direct_ssh() {
    OUT=$(env HOME="$CASE/home" PATH="$FAKEBIN:$PATH" FAKE_BOAT_DIR="$BOAT" FAKE_BOAT_ID="$ID" \
      FAKE_NC_LOG="$nc_log" ssh -F "$SSH/config" -o BatchMode=yes boat-pilot true 2>&1)
    CODE=$?
  }
  direct_ssh
  assert_equals '203.0.113.7 19034' "$(cat "$nc_log")" "direct SSH must dial the API-confirmed endpoint"
  calls=$(boat_calls)
  [ "$calls" -ge 4 ] || fail "direct SSH did not reread Boat"

  set_info running 198.51.100.9:19043 null true
  direct_ssh
  assert_equals 1 "$(wc -l < "$nc_log" | tr -d ' ')" "a moved box must not reach transport"
  set_info running 203.0.113.7:19034 null true
  set_hostkey host2
  direct_ssh
  assert_equals 1 "$(wc -l < "$nc_log" | tr -d ' ')" "a re-keyed box must not reach transport"
  set_info stopped null null true
  direct_ssh
  assert_equals 1 "$(wc -l < "$nc_log" | tr -d ' ')" "a stopped box must not reach transport"
  : > "$BOAT/info.fail"
  direct_ssh
  assert_equals 1 "$(wc -l < "$nc_log" | tr -d ' ')" "an unreadable API must not reach transport"
  pass "T12 direct SSH checks Boat before transport"
}

test_boat_route_recovers_missing_alias() {
  local saved_id=$ID fmhome ssh_log
  ID=bx_ahnbu3qr
  new_case missing-alias
  fmhome="$CASE/fm-home"
  ssh_log="$CASE/ssh.log"
  mkdir -p "$fmhome/data" "$fmhome/config"
  printf '%s\n' "$ID" > "$fmhome/config/boat-box-id"
  printf -- '- boat-eng - Boat overflow (host: boat-prove; root: /home/user/firstmate; home: /home/user/fm-boat-eng; scope: overflow; projects: firstmate; added 2026-10-16)\n' \
    > "$fmhome/data/secondmates.md"
  cat > "$CASE/fake-ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SSH_LOG"
SH
  chmod +x "$CASE/fake-ssh"
  boat_route() {
    OUT=$(env HOME="$CASE/home" PATH="$FAKEBIN:$PATH" FAKE_BOAT_DIR="$BOAT" FAKE_BOAT_ID="$ID" \
      FM_HOME="$fmhome" FM_SSH_BIN="$CASE/fake-ssh" FAKE_SSH_LOG="$ssh_log" \
      bash "$ROOT/bin/fm-on.sh" boat-eng fm-crew-state.sh 2>"$CASE/stderr")
    CODE=$?
    ERR=$(cat "$CASE/stderr")
  }
  set_info running 203.0.113.7:19034 null true
  set_hostkey host1
  boat_route
  expect_code 0 "$CODE" "a running Boat box must recover its missing alias"$'\n'"$ERR"
  assert_equals 1 "$(wc -l < "$ssh_log" | tr -d ' ')" "the recovered route must connect once"
  assert_alias boat-prove "$FP1" "recovered Boat route"
  printf 'bx_zzzzzzzz\n' > "$fmhome/config/boat-box-id"
  boat_route
  expect_code 255 "$CODE" "an alias for a different selected box must stay offline"$'\n'"$ERR"
  assert_equals 1 "$(wc -l < "$ssh_log" | tr -d ' ')" "a mismatched box was dialled"
  printf '%s\n' "$ID" > "$fmhome/config/boat-box-id"

  rm -f "$SSH/config" "$SSH/known_hosts_boat_prove" "$ssh_log"
  set_info stopped null null true
  boat_route
  expect_code 255 "$CODE" "a stopped box with no alias must stay offline"$'\n'"$ERR"
  assert_absent "$ssh_log" "a stopped box was dialled"
  assert_absent "$SSH/config" "a stopped box recreated an alias"
  : > "$BOAT/info.fail"
  boat_route
  expect_code 255 "$CODE" "an unreadable API with no alias must stay offline"$'\n'"$ERR"
  assert_absent "$ssh_log" "an unreadable box was dialled"
  ID=$saved_id
  pass "T13 a known Boat route recovers only from a running API-confirmed box"
}

test_first_run_writes_pinned_alias
test_resume_replaces_only_the_alias
test_ip_fallback
test_refusals_change_nothing
test_unsafe_config_is_refused
test_restore_wait
test_remove
test_cli_override_and_help
test_refresh_parks_a_stopped_alias
test_verify
test_fm_on_dials_only_confirmed_boat_addresses
test_direct_ssh_checks_boat_before_transport
test_boat_route_recovers_missing_alias

test_boat_route_uses_the_recorded_listed_box() {
  local fmhome ssh_log saved_id=$ID
  ID=bx_ahnbu3qr
  new_case listed-box
  fmhome="$CASE/fm-home"
  ssh_log="$CASE/ssh.log"
  mkdir -p "$fmhome/data" "$fmhome/config" "$fmhome/state"
  printf '%s\n' 'bx_ahnbu3qr' 'bx_bbbbbbbb' > "$fmhome/config/boat-box-id"
  printf '%s\n' '{"expected_running":2}' > "$fmhome/config/boat-spend.json"
  printf '%s\n' "$ID" > "$fmhome/state/.boat-route-box"
  printf -- '- boat-eng - Boat overflow (host: boat-prove; root: /home/user/firstmate; home: /home/user/fm-boat-eng; scope: overflow; projects: firstmate; added 2026-10-16)\n' \
    > "$fmhome/data/secondmates.md"
  cat > "$CASE/fake-ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SSH_LOG"
SH
  chmod +x "$CASE/fake-ssh"
  boat_route() {
    OUT=$(env HOME="$CASE/home" PATH="$FAKEBIN:$PATH" FAKE_BOAT_DIR="$BOAT" FAKE_BOAT_ID="$ID" \
      FM_HOME="$fmhome" FM_SSH_BIN="$CASE/fake-ssh" FAKE_SSH_LOG="$ssh_log" \
      bash "$ROOT/bin/fm-on.sh" boat-eng fm-crew-state.sh 2>"$CASE/stderr")
    CODE=$?
    ERR=$(cat "$CASE/stderr")
  }
  set_info running 203.0.113.7:19034 null true
  set_hostkey host1
  boat_route
  expect_code 0 "$CODE" "a recorded listed box must recover its alias"$'\n'"$ERR"
  assert_equals 1 "$(wc -l < "$ssh_log" | tr -d ' ')" "the listed box must connect once"
  printf '%s\n' 'bx_bbbbbbbb' > "$fmhome/state/.boat-route-box"
  boat_route
  expect_code 255 "$CODE" "a different listed box must not reuse the other box's alias"$'\n'"$ERR"
  assert_equals 1 "$(wc -l < "$ssh_log" | tr -d ' ')" "the other listed box was dialled"
  rm -f "$fmhome/state/.boat-route-box" "$ssh_log"
  boat_route
  expect_code 1 "$CODE" "a list of boxes without a recorded selection must not connect"$'\n'"$ERR"
  assert_absent "$ssh_log" "an unselected list was dialled"
  ID=$saved_id
  pass "T14 a listed Boat route connects only to the recorded box"
}

test_boat_route_uses_the_recorded_listed_box

test_boat_task_box_overrides_the_route() {
  local fmhome ssh_log saved_id=$ID
  ID=bx_ahnbu3qr
  new_case task-box
  fmhome="$CASE/fm-home"
  ssh_log="$CASE/ssh.log"
  mkdir -p "$fmhome/data" "$fmhome/config" "$fmhome/state"
  printf '%s\n' 'bx_ahnbu3qr' 'bx_bbbbbbbb' > "$fmhome/config/boat-box-id"
  printf '%s\n' '{"expected_running":2}' > "$fmhome/config/boat-spend.json"
  printf '%s\n' "$ID" > "$fmhome/state/.boat-route-box"
  printf -- '- boat-eng - Boat overflow (host: boat-prove; root: /home/user/firstmate; home: /home/user/fm-boat-eng; scope: overflow; projects: firstmate; added 2026-10-16)\n' \
    > "$fmhome/data/secondmates.md"
  cat > "$CASE/fake-ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SSH_LOG"
SH
  chmod +x "$CASE/fake-ssh"
  boat_route() {
    OUT=$(env HOME="$CASE/home" PATH="$FAKEBIN:$PATH" FAKE_BOAT_DIR="$BOAT" FAKE_BOAT_ID="$ID" \
      FM_HOME="$fmhome" FM_CHECK_INTERVAL=600 FM_SSH_BIN="$CASE/fake-ssh" FAKE_SSH_LOG="$ssh_log" \
      bash "$ROOT/bin/fm-on.sh" "$@" 2>"$CASE/stderr")
    CODE=$?
    ERR=$(cat "$CASE/stderr")
  }
  set_info running 203.0.113.7:19034 null true
  set_hostkey host1
  boat_route boat-eng fm-crew-state.sh
  expect_code 0 "$CODE" "the route box connects before a task override"$'\n'"$ERR"
  printf '%s\n' 'bx_bbbbbbbb' > "$fmhome/state/.boat-route-box"
  printf '%s\n' 'task-one bx_ahnbu3qr' > "$fmhome/state/.boat-task-box"
  boat_route boat-eng fm-crew-state.sh task-one
  expect_code 0 "$CODE" "a recorded task connects to its own box"$'\n'"$ERR"
  assert_equals 2 "$(wc -l < "$ssh_log" | tr -d ' ')" "the task box must be dialled"
  assert_equals 'bx_ahnbu3qr' "$(tr -d '\n' < "$fmhome/state/.boat-route-box")" 'the route follows the task box'
  printf '%s\n' 'bx_bbbbbbbb' > "$fmhome/state/.boat-route-box"
  boat_route boat-eng fm-crew-state.sh task-two
  expect_code 255 "$CODE" "an unrecorded task must not borrow another box"$'\n'"$ERR"
  assert_equals 2 "$(wc -l < "$ssh_log" | tr -d ' ')" "an unrecorded task was dialled"
  ID=$saved_id
  pass "T15 a recorded task is reached on its own box"
}

test_failed_task_refresh_keeps_the_route() {
  local fmhome ssh_log saved_id=$ID
  ID=bx_ahnbu3qr
  new_case failed-refresh
  fmhome="$CASE/fm-home"
  ssh_log="$CASE/ssh.log"
  mkdir -p "$fmhome/data" "$fmhome/config" "$fmhome/state"
  printf '%s\n' 'bx_ahnbu3qr' 'bx_bbbbbbbb' > "$fmhome/config/boat-box-id"
  printf '%s\n' '{"expected_running":2}' > "$fmhome/config/boat-spend.json"
  printf '%s\n' "$ID" > "$fmhome/state/.boat-route-box"
  printf '%s\n' 'task-one bx_bbbbbbbb' > "$fmhome/state/.boat-task-box"
  printf -- '- boat-eng - Boat overflow (host: boat-prove; root: /home/user/firstmate; home: /home/user/fm-boat-eng; scope: overflow; projects: firstmate; added 2026-10-16)\n' \
    > "$fmhome/data/secondmates.md"
  cat > "$CASE/fake-ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SSH_LOG"
SH
  chmod +x "$CASE/fake-ssh"
  boat_route() {
    OUT=$(env HOME="$CASE/home" PATH="$FAKEBIN:$PATH" FAKE_BOAT_DIR="$BOAT" FAKE_BOAT_ID="$ID" \
      FM_HOME="$fmhome" FM_SSH_BIN="$CASE/fake-ssh" FAKE_SSH_LOG="$ssh_log" \
      bash "$ROOT/bin/fm-on.sh" "$@" 2>"$CASE/stderr")
    CODE=$?
    ERR=$(cat "$CASE/stderr")
  }
  set_info running 203.0.113.7:19034 null true
  set_hostkey host1
  boat_route boat-eng fm-crew-state.sh
  expect_code 0 "$CODE" "the current box connects before a failed switch"$'\n'"$ERR"
  : > "$BOAT/calls"
  boat_route boat-eng fm-crew-state.sh task-one
  expect_code 1 "$CODE" "a failed switch must not connect"$'\n'"$ERR"
  assert_equals 'bx_ahnbu3qr' "$(tr -d '\n' < "$fmhome/state/.boat-route-box")" 'a failed refresh published the new route'
  boat_route boat-eng fm-crew-state.sh task-one
  expect_code 1 "$CODE" "a later call must retry the refresh"$'\n'"$ERR"
  assert_equals 'bx_ahnbu3qr' "$(tr -d '\n' < "$fmhome/state/.boat-route-box")" 'the second failure published the new route'
  assert_no_grep 'rather than configured box' "$CASE/stderr" 'the retry skipped alias refresh and verified the stale alias'
  assert_equals 2 "$(grep -c 'info bx_bbbbbbbb' "$BOAT/calls")" 'the retry did not ask Boat about the task box again'
  ID=$saved_id
  pass "T16 a failed task switch leaves the route unchanged"
}

test_boat_task_box_overrides_the_route
test_failed_task_refresh_keeps_the_route

echo "# all fm-boat-alias-refresh tests passed"
