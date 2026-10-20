#!/usr/bin/env bash
# Behavior tests for the private-name guard and its scrub tool.
#
# Every case drives the public interfaces a fleet pane uses: real git commits
# and pushes through the installed hooksPath, gh and gh-axi through the
# installed shims, and the CLIs. Only made-up names appear here.
set -u

# A fleet pane already carries GIT_CONFIG core.hooksPath. These cases set that
# override themselves, so drop the inherited one before any git command.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS
unset FM_PRIVATE_NAMES_MODE FM_CONFIG_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PN="$ROOT/bin/fm-private-names.sh"
SCRUB="$ROOT/bin/fm-private-names-scrub.sh"
STRIP="$ROOT/bin/fm-git-strip-ai-trailers.sh"
TMP_ROOT=$(fm_test_tmproot fm-private-names)
BASE_PATH=$PATH
# Replaced by a fake gh in the cases that drive one.
FAKEBIN=$TMP_ROOT/no-fakebin

fm_git_identity 'Guard Tests' 'guard@example.invalid'

# A home with a two-name list: mate-1 is acme-test, client-1 is zenith-sample.
make_home() {  # <dir>
  local home=$1
  mkdir -p "$home/config" "$home/state" "$home/data"
  printf '%s\n' '# test list' 'mate acme-test' 'client zenith-sample' >"$home/config/private-names"
}

# A fake real gh (and gh-axi) that records each call and its body file.
make_fake_gh() {  # <dir> -> fakebin path
  local bin=$1/fakebin tool
  mkdir -p "$bin"
  for tool in gh gh-axi; do
    cat >"$bin/$tool" <<'SH'
#!/usr/bin/env bash
log=${FAKE_GH_LOG:?}
printf '%s' "${0##*/}" >>"$log"
printf ' [%s]' "$@" >>"$log"
printf '\n' >>"$log"
prev=
for a in "$@"; do
  if [ "$prev" = --body-file ] || [ "$prev" = -F ]; then
    printf 'BODY<<\n' >>"$log"
    cat -- "$a" >>"$log"
    printf '>>BODY\n' >>"$log"
  fi
  prev=$a
done
case "$1 $2" in
  "api repos/"*)
    [ -z "${FAKE_GH_COUNT:-}" ] || echo x >>"$FAKE_GH_COUNT"
    [ "${FAKE_GH_VIS:-public}" = fail ] && exit 1
    printf '%s\n' "${FAKE_GH_VIS:-public}"
    ;;
  "api --paginate") cat "${FAKE_GH_PRS:?}" ;;
  "pr view") awk -F '\t' -v n="$3" '$1 == n' "${FAKE_GH_PRS:?}" ;;
esac
exit 0
SH
    chmod +x "$bin/$tool"
  done
  printf '%s\n' "$bin"
}

make_fake_no_mistakes() {  # <bin>
  cat >"$1/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '[%s]' "$@" >>"${FAKE_NM_LOG:?}"
printf '\n' >>"$FAKE_NM_LOG"
SH
  chmod +x "$1/no-mistakes"
}

# A worktree whose origin is a local bare repository, with the guard hooks
# installed for <home>. Pass "public" to mark that origin public.
make_repo() {  # <dir> <home> <public|private> -> sets REPO ORIGIN HOOKS
  local dir=$1 home=$2 vis=$3
  REPO=$dir/work
  ORIGIN=$dir/origin.git
  HOOKS=$dir/hooks
  fm_git_init_commit "$REPO"
  git init -q --bare "$ORIGIN"
  git -C "$REPO" remote add origin "$ORIGIN"
  git -C "$REPO" push -q origin main
  git -C "$REPO" fetch -q origin
  if [ "$vis" = public ]; then
    printf '%s public\n' "$ORIGIN" >>"$home/config/repo-visibility"
  fi
  "$STRIP" install "$HOOKS" "$REPO" --private-names "$home/config" "$home/state" "$home" "$home/data" "$home/projects" ||
    fail "hook install failed"
}

in_pane() {  # <hooks> <command...>: run as a fleet pane with the shims on PATH
  local hooks=$1
  shift
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$hooks \
    PATH="$hooks/bin:$FAKEBIN:$BASE_PATH" "$@"
}

commit_file() {  # <repo> <path> <content> <message> [git commit args...]
  local repo=$1 path=$2 content=$3 msg=$4
  shift 4
  mkdir -p "$(dirname "$repo/$path")"
  printf '%s\n' "$content" >"$repo/$path"
  git -C "$repo" add -- "$path"
  git -C "$repo" commit -q -m "$msg" "$@"
}

test_refresh_derives_names_from_local_records() {
  local d=$TMP_ROOT/refresh home mate out list
  d=$TMP_ROOT/refresh
  home=$d/home
  mate=$d/mate-home
  mkdir -p "$home/data" "$home/config" "$home/projects/gtm-client-zenith-sample" \
    "$mate/data" "$home/projects/plain-project"
  cat >"$home/data/secondmates.md" <<EOF
# Secondmates
- acme-test - Runs a made-up domain. (home: $mate; scope: made-up work; projects: firstmate, gtm-client-quasar-mock; added 2026-01-01)
- zed - A three-letter id. (home: /nonexistent; scope: x; projects: gtm-client-abc; added 2026-01-01)
- Health - An ordinary-word id. (home: /nonexistent; scope: x; projects: none; added 2026-01-01)
EOF
  printf '%s\n' '- gtm-client-orbit-sample [direct-PR] - A made-up client (added 2026-01-01)' \
    '- firstmate - The shared repo (added 2026-01-01)' >"$home/data/projects.md"
  printf '%s\n' '- gtm-client-nova-mock - Made up (added 2026-01-01)' >"$mate/data/projects.md"
  fm_git_init_commit "$home/projects/plain-project"
  git -C "$home/projects/plain-project" remote add origin https://github.com/example/gtm-client-delta-fake.git
  printf '%s\n' 'client hand-added-name' 'bare-hand-name' '!orbit-sample' 'xy' 'mate qrs' >"$home/config/private-names.local"

  out=$(FM_HOME=$home "$PN" refresh) || fail "refresh failed: $out"
  list=$(grep -v '^#' "$home/config/private-names")
  assert_contains "$out" "names in config/private-names" "refresh did not report the list location"
  assert_not_contains "$out" "$home" "refresh printed the private home path"
  for name in acme-test quasar-mock zenith-sample nova-mock delta-fake hand-added-name bare-hand-name; do
    assert_not_contains "$out" "$name" "refresh output printed a listed name"
    assert_contains "$list" "$name" "refresh missed $name"
  done
  assert_contains "$list" "mate acme-test" "a route id must be kind mate"
  assert_contains "$list" "client gtm-client-zenith-sample" "a client clone must be listed whole"
  assert_contains "$list" "private bare-hand-name" "a bare hand name must be kind private"
  assert_contains "$list" "client orbit-sample" "a local exclusion must not drop a registered name"
  assert_not_contains "$list" "firstmate" "a non-client project must not be listed"
  assert_contains "$list" "private:context xy" "a short hand name must be listed in the context tier"
  assert_contains "$list" "mate:context qrs" "a short hand name must use context matching"
  assert_contains "$list" "mate:context zed" "a short registered name must be listed"
  assert_contains "$list" "client:context abc" "a short client slug must be listed"
  assert_contains "$list" "mate:context Health" "an ordinary-word registered name must be listed"
  assert_contains "$list" "client gtm-client-abc" "the whole client repository name must still be listed"
  if out=$(printf 'health is good\nfm-homes/Health\nzed.status\n@abc\nqrs second mate\n' | FM_HOME=$home "$PN" check 2>&1); then
    fail "context-tier names in name-shaped text were accepted"
  fi
  assert_contains "$out" "mate-" "a context-tier mate was not reported"
  assert_contains "$out" "client-" "a context-tier client was not reported"
  out=$(printf 'health is good; abc is ordinary prose; zed is plain prose\n' | FM_HOME=$home "$PN" check 2>&1) ||
    fail "a context-tier name blocked ordinary prose: $out"
  [ "$(stat -c %a "$home/config/private-names" 2>/dev/null || stat -f %Lp "$home/config/private-names")" = 600 ] ||
    fail "the list must be private to its owner"

  # Append-only: a new route keeps every existing neutral id in place.
  echo "Acme-Test" | FM_HOME=$home "$PN" scrub >"$d/before"
  printf '%s\n' "- zenith-mate - Another. (home: /nonexistent; scope: x; projects: none; added 2026-01-02)" \
    | cat - "$home/data/secondmates.md" >"$d/sm" && mv "$d/sm" "$home/data/secondmates.md"
  FM_HOME=$home "$PN" refresh >/dev/null || fail "second refresh failed"
  echo "Acme-Test" | FM_HOME=$home "$PN" scrub >"$d/after"
  assert_equals "$(cat "$d/before")" "$(cat "$d/after")" "a neutral id moved after refresh"
  case "$(cat "$d/after")" in mate-[0-9]*) ;; *) fail "the route id was not neutralized" ;; esac
  assert_grep "mate zenith-mate" "$home/config/private-names" "a new route was not appended"
  rm -f "$home/data/secondmates.md"
  FM_HOME=$home "$PN" refresh >/dev/null || fail "third refresh failed"
  assert_grep "mate acme-test" "$home/config/private-names" "a removed record dropped its name"
  pass "refresh derives mate and client names from local records, honors hand edits, prints only a count, and only appends"
}

test_secondmate_refresh_merges_the_primary_list() {
  local d=$TMP_ROOT/parent primary mate
  primary=$d/primary
  mate=$d/mate
  make_home "$primary"
  mkdir -p "$mate/data" "$mate/config"
  printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$primary" >"$mate/.fm-secondmate-parent"
  FM_HOME=$mate "$PN" refresh >/dev/null || fail "secondmate refresh failed"
  assert_grep "mate acme-test" "$mate/config/private-names" "a second mate home did not take its primary's list"
  assert_grep "client zenith-sample" "$mate/config/private-names" "a second mate home lost a primary name"
  pass "a second mate home's refresh merges its primary's list from disk"
}

test_commit_message_is_refused_or_rewritten_on_a_public_repo() {
  local d=$TMP_ROOT/commit home out rc
  home=$d/home
  make_home "$home"
  make_repo "$d" "$home" public
  out=$(in_pane "$HOOKS" commit_file "$REPO" a.txt one "Fix the acme-test lane" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a commit message naming a listed name was accepted"
  assert_contains "$out" "mate-1" "the refusal must name the neutral id"
  assert_not_contains "$out" "acme-test" "the refusal printed the private name"
  assert_equals 1 "$(git -C "$REPO" rev-list --count HEAD)" "a refused commit was written"

  out=$(FM_PRIVATE_NAMES_MODE=rewrite in_pane "$HOOKS" commit_file "$REPO" a.txt one "Fix the ZENITH-SAMPLE lane" 2>&1) ||
    fail "rewrite mode refused the commit: $out"
  assert_equals "Fix the client-1 lane" "$(git -C "$REPO" log -1 --format=%s)" "rewrite mode did not scrub the message"
  pass "a commit message with a listed name is refused, or rewritten to a neutral id on request"
}

test_private_repo_passes_untouched() {
  local d=$TMP_ROOT/private home out
  home=$d/home
  make_home "$home"
  make_repo "$d" "$home" private
  in_pane "$HOOKS" commit_file "$REPO" b/acme-test.txt "zenith-sample" "Work for acme-test" ||
    fail "a private repository refused a commit"
  out=$(in_pane "$HOOKS" git -C "$REPO" push -q origin HEAD:refs/heads/acme-test-work 2>&1) ||
    fail "a private repository refused a push: $out"
  assert_equals "Work for acme-test" "$(git -C "$REPO" log -1 --format=%s)" "a private commit was rewritten"
  pass "a private repository passes commits and pushes untouched"
}

test_empty_list_on_a_public_repo_refuses() {
  local d=$TMP_ROOT/empty home out rc
  home=$d/home
  make_home "$home"
  make_repo "$d" "$home" public
  : >"$home/config/private-names"
  out=$(in_pane "$HOOKS" commit_file "$REPO" c.txt clean "Clean message" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an empty list let a public commit through"
  assert_contains "$out" "missing or empty" "the refusal must say the list is empty"
  assert_contains "$out" "fm-private-names.sh refresh" "the refusal must name the refresh command"
  git -C "$REPO" commit -q --allow-empty -m "Clean" --no-verify
  rm -f "$home/config/private-names"
  out=$(in_pane "$HOOKS" git -C "$REPO" push -q origin HEAD:refs/heads/clean 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a missing list let a public push through"
  assert_contains "$out" "missing or empty" "the push refusal must say the list is missing"
  out=$(printf 'clean\n' | FM_HOME=$home "$PN" check --repo "$ORIGIN" 2>&1)
  expect_code 3 "$?" "check with a missing list on a public destination"
  pass "a missing or empty list refuses public commits, pushes, and checks"
}

test_private_home_path_stays_out_of_guard_output() {
  local d=$TMP_ROOT/acme-test-home out bad
  make_home "$d"
  printf 'example/public-repo public\n' >"$d/config/repo-visibility"
  : >"$d/config/private-names"
  out=$(printf 'clean\n' | FM_HOME=$d "$PN" check --repo example/public-repo 2>&1) &&
    fail "an empty list passed the public check"
  assert_contains "$out" "config/private-names" "the refusal omitted the fixed list location"
  assert_not_contains "$out" "acme-test-home" "the refusal printed the private home path"
  out=$(FM_HOME=$d "$PN" refresh 2>&1) || fail "refresh failed: $out"
  assert_not_contains "$out" "acme-test-home" "refresh printed the private home path"
  bad=$TMP_ROOT/blocked-acme-test-home
  mkdir -p "$bad/data"
  : >"$bad/config"
  out=$(FM_HOME=$bad "$PN" refresh 2>&1) && fail "a blocked list write passed refresh"
  assert_not_contains "$out" "blocked-acme-test-home" "failed refresh printed the private home path"
  pass "guard refusals and refresh reports keep private home paths out of output"
}

test_pre_push_refuses_names_in_branch_message_patch_and_path() {
  local d=$TMP_ROOT/push home out rc
  home=$d/home
  make_home "$home"
  make_repo "$d" "$home" public

  in_pane "$HOOKS" git -C "$REPO" checkout -q -b fm/zenith-sample-fix
  in_pane "$HOOKS" commit_file "$REPO" ok.txt clean "Clean change"
  out=$(in_pane "$HOOKS" git -C "$REPO" push -q origin HEAD 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a branch name holding a listed name was pushed"
  assert_contains "$out" "fm/client-1-fix" "the refusal must suggest the neutral branch name"
  assert_not_contains "$out" "zenith-sample" "the branch refusal printed the private name"

  in_pane "$HOOKS" git -C "$REPO" checkout -q -b fm/clean-1 main
  commit_file "$REPO" m.txt clean "Mention acme-test" --no-verify
  out=$(in_pane "$HOOKS" git -C "$REPO" push -q origin HEAD 2>&1) &&
  fail "a commit message bypassing commit-msg was pushed"
  assert_contains "$out" "the message of commit" "the refusal must locate the commit message"

  in_pane "$HOOKS" git -C "$REPO" checkout -q -b fm/clean-2 main
  in_pane "$HOOKS" commit_file "$REPO" docs/note.md "Route to Zenith-Sample today" "Add a note"
  out=$(in_pane "$HOOKS" git -C "$REPO" push -q origin HEAD 2>&1) &&
  fail "an added line holding a listed name was pushed"
  assert_contains "$out" "listed private name (client-1) in an added line of docs/note.md in commit" \
    "the refusal must locate the added line by file, not by a patch line number"
  assert_contains "$out" "client-1" "the refusal must name the neutral id"
  assert_not_contains "$out" "Zenith-Sample" "the patch refusal printed the private name"

  in_pane "$HOOKS" git -C "$REPO" checkout -q -b fm/clean-3 main
  in_pane "$HOOKS" commit_file "$REPO" logs/acme-test.log "nothing private" "Add a log"
  out=$(in_pane "$HOOKS" git -C "$REPO" push -q origin HEAD 2>&1) &&
  fail "a file path holding a listed name was pushed"
  assert_contains "$out" "a file path added in commit" "the refusal must locate the file path"
  assert_contains "$out" "logs/mate-1.log" "the refusal must print the path with neutral ids"

  in_pane "$HOOKS" git -C "$REPO" checkout -q -b fm/clean-4 main
  in_pane "$HOOKS" commit_file "$REPO" ok.txt "plain text" "Plain change"
  out=$(in_pane "$HOOKS" git -C "$REPO" push -q origin HEAD 2>&1) || fail "a clean push was refused: $out"
  pass "pre-push refuses a listed name in a branch name, commit message, added line, or file path, and passes a clean push"
}

test_new_public_branch_scans_commits_from_other_remotes() {
  local d=$TMP_ROOT/other-remote home private out
  home=$d/home
  make_home "$home"
  make_repo "$d" "$home" public
  private=$d/private.git
  git init -q --bare "$private"
  git -C "$REPO" remote add private "$private"
  git -C "$REPO" checkout -q -b fm/remote-copy
  commit_file "$REPO" copied.txt plain "Fix acme-test" --no-verify
  git -C "$REPO" push -q private HEAD:refs/heads/fm/remote-copy
  git -C "$REPO" fetch -q private
  out=$(in_pane "$HOOKS" git -C "$REPO" push -q origin HEAD:refs/heads/fm/remote-copy 2>&1) &&
    fail "a commit known only to another remote reached the public origin"
  assert_contains "$out" "mate-1" "the public push did not scan the other remote's commit"
  pass "a new public branch scans commits reachable only from another remote"
}

test_stale_registered_name_is_refreshed_before_commit() {
  local d=$TMP_ROOT/stale home out
  home=$d/home
  make_home "$home"
  make_repo "$d" "$home" public
  printf '%s\n' '- quasar-mate - A made-up route. (home: /nonexistent; scope: x; projects: none; added 2026-01-01)' \
    >"$home/data/secondmates.md"
  out=$(unset FM_HOME FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE; in_pane "$HOOKS" commit_file "$REPO" fresh.txt plain "Route quasar-mate work" 2>&1) &&
    fail "a newly registered name passed the commit guard"
  assert_contains "$out" "mate-" "the stale-list refusal did not report a neutral id"
  assert_contains "$(cat "$home/config/private-names")" "quasar-mate" "the list was not refreshed"
  pass "the commit guard refreshes a stale registered-name list"
}

test_evidence_push_with_a_listed_name_is_refused() {
  local d=$TMP_ROOT/evidence home out rc
  home=$d/home
  make_home "$home"
  make_repo "$d" "$home" public
  git -C "$REPO" checkout -q --orphan no-mistakes/evidence
  git -C "$REPO" rm -rq --cached .
  in_pane "$HOOKS" commit_file "$REPO" run-1/test.log "spawned acme-test worker" "Store run evidence"
  out=$(in_pane "$HOOKS" git -C "$REPO" push -q origin HEAD:refs/heads/no-mistakes/evidence 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "evidence naming a listed name was pushed"
  assert_contains "$out" "run-1/test.log" "the refusal must locate the evidence file"
  assert_not_contains "$out" "acme-test" "the evidence refusal printed the private name"
  git -C "$ORIGIN" rev-parse -q --verify refs/heads/no-mistakes/evidence >/dev/null &&
    fail "the refused evidence branch reached the remote"
  pass "an evidence push holding a listed name is refused before it leaves the machine"
}

test_gate_remote_is_judged_by_origin_and_repo_hook_still_runs() {
  local d=$TMP_ROOT/gate home gate out
  home=$d/home
  make_home "$home"
  make_repo "$d" "$home" public
  gate=$d/gate.git
  git init -q --bare "$gate"
  git -C "$REPO" remote add no-mistakes "$gate"
  mkdir -p "$REPO/.git/hooks"
  printf '%s\n' '#!/usr/bin/env bash' "cat >$(printf '%q' "$d/repo-hook-stdin")" >"$REPO/.git/hooks/pre-push"
  chmod +x "$REPO/.git/hooks/pre-push"
  in_pane "$HOOKS" git -C "$REPO" checkout -q -b fm/gate-test
  commit_file "$REPO" g.txt "mentions acme-test" "Gate change" --no-verify
  out=$(in_pane "$HOOKS" git -C "$REPO" push -q no-mistakes HEAD 2>&1) &&
  fail "a push to the gate remote of a public origin was not checked"
  git -C "$REPO" reset -q --hard main
  in_pane "$HOOKS" commit_file "$REPO" g.txt "plain" "Plain gate change"
  in_pane "$HOOKS" git -C "$REPO" push -q no-mistakes HEAD 2>/dev/null || fail "a clean gate push was refused"
  assert_contains "$(cat "$d/repo-hook-stdin")" "refs/heads/fm/gate-test" \
    "the repository's own pre-push hook did not receive git's ref lines"
  pass "a no-mistakes gate push is judged by origin, and the repository's pre-push still gets its ref lines"
}

test_new_gate_and_unfetched_public_branches_skip_public_history() {
  local d=$TMP_ROOT/gate-public-history home gate fork behind out
  home=$d/home
  make_home "$home"
  make_repo "$d" "$home" public
  behind=$d/behind.git
  git init -q --bare "$behind"
  git -C "$REPO" -c core.hooksPath=/dev/null push -q "$behind" main
  commit_file "$REPO" existing.txt "acme-test was already published" "Published history" --no-verify
  git -C "$REPO" -c core.hooksPath=/dev/null push -q origin main
  git -C "$REPO" fetch -q origin
  gate=$d/gate.git
  fork=$d/fork.git
  git init -q --bare "$gate"
  git init -q --bare "$fork"
  git -C "$REPO" -c core.hooksPath=/dev/null push -q "$fork" main
  git -C "$REPO" remote add no-mistakes "$gate"
  git -C "$REPO" remote add public-copy "$ORIGIN"
  git -C "$REPO" remote add fork "$fork"
  git -C "$REPO" remote add behind "$behind"
  printf '%s public\n%s public\n' "$fork" "$behind" >>"$home/config/repo-visibility"
  git -C "$REPO" checkout -q -b fm/clean-first
  in_pane "$HOOKS" commit_file "$REPO" fresh.txt "clean addition" "Clean first push"
  out=$(in_pane "$HOOKS" git -C "$REPO" push -q no-mistakes HEAD 2>&1) ||
    fail "a clean first gate push scanned already public history: $out"
  out=$(in_pane "$HOOKS" git -C "$REPO" push -q public-copy HEAD:refs/heads/fm/clean-first 2>&1) ||
    fail "an unfetched public alias scanned already public history: $out"
  out=$(in_pane "$HOOKS" git -C "$REPO" push -q fork HEAD:refs/heads/fm/clean-first 2>&1) ||
    fail "a separate public fork scanned already public history: $out"
  out=$(in_pane "$HOOKS" git -C "$REPO" push -q behind HEAD:refs/heads/fm/clean-first 2>&1) &&
    fail "a fork behind origin accepted a newly exposed listed name"
  assert_contains "$out" "mate-1" "the behind-fork refusal omitted the neutral id"
  assert_equals "$(git -C "$REPO" rev-parse HEAD)" "$(git -C "$gate" rev-parse refs/heads/fm/clean-first)" \
    "the clean branch did not reach the gate"
  git -C "$REPO" checkout -q -b fm/fork-secret
  commit_file "$REPO" new.txt "Route zenith-sample" "New private name" --no-verify
  out=$(in_pane "$HOOKS" git -C "$REPO" push -q fork HEAD 2>&1) &&
    fail "a new listed name reached the separate public fork"
  assert_contains "$out" "client-1" "the separate fork refusal omitted the neutral id"
  pass "new gate and unfetched fork branches skip published history while checking new commits"
}

test_merge_added_paths_and_lines_are_checked() {
  local d=$TMP_ROOT/merge-path home out
  home=$d/home
  make_home "$home"
  make_repo "$d" "$home" public
  git -C "$REPO" checkout -q -b fm/merge-path
  commit_file "$REPO" first.txt clean "First clean change"
  git -C "$REPO" checkout -q -b fm/merge-side main
  commit_file "$REPO" side.txt clean "Second clean change"
  git -C "$REPO" checkout -q fm/merge-path
  git -C "$REPO" merge -q --no-commit --no-ff fm/merge-side
  printf 'Route zenith-sample\n' >"$REPO/route.txt"
  git -C "$REPO" add route.txt
  commit_file "$REPO" logs/acme-test.log clean "Merge clean work" --no-verify
  out=$(in_pane "$HOOKS" git -C "$REPO" push -q origin HEAD 2>&1) &&
    fail "a merge-added listed filename reached the public origin"
  assert_contains "$out" "logs/mate-1.log" "the merge-added path was not scanned"
  assert_contains "$out" "client-1" "the merge-added line was not scanned"
  git -C "$ORIGIN" rev-parse -q --verify refs/heads/fm/merge-path >/dev/null &&
    fail "the refused merge branch reached the public origin"
  pass "a merge-added listed filename is refused before a public push"
}

test_unreadable_public_refs_refuse_push() {
  local d=$TMP_ROOT/unknown-refs home out gate missing_origin
  home=$d/home
  make_home "$home"
  make_repo "$d" "$home" public
  git -C "$REPO" checkout -q -b fm/clean-unknown
  commit_file "$REPO" clean.txt clean "Clean change"
  gate=$d/gate.git
  missing_origin=$d/unreadable.git
  git init -q --bare "$gate"
  git -C "$REPO" remote add no-mistakes "$gate"
  git -C "$REPO" remote set-url origin "$missing_origin"
  printf '%s public\n' "$missing_origin" >>"$home/config/repo-visibility"
  out=$(in_pane "$HOOKS" git -C "$REPO" push -q no-mistakes HEAD 2>&1) &&
    fail "a public push proceeded after its ref lookup failed"
  assert_contains "$out" "cannot read public destination refs" "the push refusal omitted its reason"
  assert_not_contains "$out" "$missing_origin" "the refusal printed the destination path"
  pass "a failed public destination ref lookup refuses the push"
}

test_gh_shim_refuses_or_rewrites_pr_text() {
  local d=$TMP_ROOT/gh home out rc log repo_arg flag action
  local repo_words=()
  home=$d/home
  make_home "$home"
  make_repo "$d" "$home" public
  FAKEBIN=$(make_fake_gh "$d")
  log=$d/gh.log
  export FAKE_GH_LOG=$log FAKE_GH_VIS=public
  printf 'example/public-repo public\nexample/private-repo private\n' >>"$home/config/repo-visibility"

  : >"$log"
  out=$(cd "$REPO" && in_pane "$HOOKS" gh pr create --repo example/public-repo --title "Fix acme-test" --body ok 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "gh pr create with a listed name in the title ran"
  [ ! -s "$log" ] || fail "the real gh ran before the refusal"
  assert_contains "$out" "mate-1" "the gh refusal must name the neutral id"
  assert_not_contains "$out" "acme-test" "the gh refusal printed the private name"
  assert_not_contains "$out" "unbound variable" "the gh refusal did not clean up its staging"

  printf 'Body names Zenith-Sample.\n' >"$d/body.md"
  : >"$log"
  out=$(cd "$REPO" && in_pane "$HOOKS" gh-axi pr create --repo example/public-repo --title Clean --body-file "$d/body.md" 2>&1) &&
  fail "gh-axi pr create with a listed name in the body file ran"
  [ ! -s "$log" ] || fail "the real gh-axi ran before the refusal"

  : >"$log"
  out=$(cd "$REPO" && FM_PRIVATE_NAMES_MODE=rewrite in_pane "$HOOKS" gh-axi pr create --repo example/public-repo \
    --title "Fix acme-test" --body-file "$d/body.md" 2>&1) || fail "rewrite mode failed: $out"
  assert_contains "$(cat "$log")" "[Fix mate-1]" "rewrite mode did not scrub the title"
  assert_contains "$(cat "$log")" "Body names client-1." "rewrite mode did not scrub the body file"
  assert_not_contains "$(cat "$log")" "acme-test" "the real tool received a private name"
  assert_equals "Body names Zenith-Sample." "$(cat "$d/body.md")" "rewrite mode changed the caller's own file"

  : >"$log"
  out=$(cd "$REPO" && printf 'stdin names acme-test\n' |
    FM_PRIVATE_NAMES_MODE=rewrite in_pane "$HOOKS" gh pr edit 7 --repo example/public-repo -F - 2>&1) ||
    fail "a stdin body was not rewritten: $out"
  assert_contains "$(cat "$log")" "stdin names mate-1" "a stdin body was not scrubbed"

  : >"$log"
  out=$(cd "$REPO" && FM_PRIVATE_NAMES_MODE=rewrite in_pane "$HOOKS" gh pr create --repo example/public-repo \
    --title Clean --body ok --head fm/acme-test-branch 2>&1) &&
  fail "a head branch with a listed name was accepted in rewrite mode"
  assert_contains "$out" "fm/mate-1-branch" "the head refusal must suggest the neutral branch"
  [ ! -s "$log" ] || fail "the real gh ran for a refused head branch"

  : >"$log"
  (cd "$REPO" && FAKE_GH_VIS=private in_pane "$HOOKS" gh pr create --repo example/private-repo --title "Fix acme-test" --body ok) ||
    fail "a private repository's PR was refused"
  assert_contains "$(cat "$log")" "[Fix acme-test]" "a private repository's PR text was changed"
  : >"$log"
  out=$(cd "$REPO" && FAKE_GH_VIS=public in_pane "$HOOKS" gh pr create --repo example/private-repo \
    --title "Fix acme-test" --body ok 2>&1) && fail "a private visibility override bypassed a public result"
  assert_not_contains "$(cat "$log")" "[pr] [create]" "the real gh ran despite the public result"

  mkdir -p "$d/acme-test-drafts"
  printf 'Clean body.\n' >"$d/acme-test-drafts/body.md"
  : >"$log"
  out=$(cd "$REPO" && in_pane "$HOOKS" gh pr create --repo example/public-repo --title Clean \
    --body-file "$d/acme-test-drafts/body.md" 2>&1) ||
    fail "a clean body file was refused because its own path holds a listed name: $out"
  assert_contains "$(cat "$log")" "Clean body." "the clean body did not reach the real gh"

  : >"$log"
  out=$(cd "$REPO" && in_pane "$HOOKS" gh pr edit 7 --repo example/public-repo --add-label zenith-sample 2>&1) &&
    fail "a label holding a listed name was accepted"
  [ ! -s "$log" ] || fail "the real gh ran for a refused label"

  : >"$log"
  out=$(cd "$REPO" && in_pane "$HOOKS" gh pr new --repo example/public-repo --title Clean --body acme-test 2>&1) &&
    fail "the pr new alias passed a listed body"
  [ ! -s "$log" ] || fail "the real gh ran for a refused pr new"
  for repo_arg in '-R example/public-repo' '--repo example/public-repo' '--repo=example/public-repo' '-Rexample/public-repo'; do
    : >"$log"
    read -r -a repo_words <<<"$repo_arg"
    out=$(cd "$REPO" && in_pane "$HOOKS" gh "${repo_words[@]}" pr create --title 'Fix acme-test' --body Clean 2>&1) &&
      fail "a global repo option bypassed the PR guard"
    [ ! -s "$log" ] || fail "the real gh ran for a global repo option"
  done
  for flag in --template --fill --fill-first --fill-verbose --recover; do
    : >"$log"
    out=$(cd "$REPO" && in_pane "$HOOKS" gh pr create --repo example/public-repo --title Clean --body Clean "$flag" 2>&1) &&
      fail "an unchecked $flag PR source reached gh"
    [ ! -s "$log" ] || fail "the real gh ran for $flag"
  done
  : >"$log"
  out=$(cd "$REPO" && in_pane "$HOOKS" gh pr create --repo example/public-repo --title Clean 2>&1) &&
    fail "an editor-supplied PR body reached gh"
  [ ! -s "$log" ] || fail "the real gh ran for an editor-supplied body"
  for flag in --editor --web; do
    : >"$log"
    out=$(cd "$REPO" && in_pane "$HOOKS" gh pr create --repo example/public-repo --title Clean --body Clean "$flag" 2>&1) &&
      fail "a $flag PR escaped the guard"
    [ ! -s "$log" ] || fail "the real gh ran for $flag"
  done
  for action in comment review edit; do
    : >"$log"
    out=$(cd "$REPO" && in_pane "$HOOKS" gh pr "$action" 7 --repo example/public-repo 2>&1) &&
      fail "interactive pr $action reached gh"
    [ ! -s "$log" ] || fail "the real gh ran for interactive pr $action"
  done
  : >"$log"
  (cd "$REPO" && in_pane "$HOOKS" gh pr comment 7 --repo example/public-repo --body Clean) ||
    fail "a checked clean PR comment was refused"
  assert_contains "$(cat "$log")" "[pr] [comment]" "the clean comment did not reach real gh"
  : >"$log"
  (cd "$REPO" && in_pane "$HOOKS" gh pr review 7 --repo example/public-repo --approve) ||
    fail "a text-free PR approval was refused"
  assert_contains "$(cat "$log")" "[pr] [review]" "the clean approval did not reach real gh"

  : >"$log"
  (cd "$REPO" && in_pane "$HOOKS" gh issue list --search acme-test >/dev/null) || fail "a non-PR command was refused"
  assert_contains "$(cat "$log")" "[issue] [list]" "a non-PR command did not reach the real gh"

  : >"$home/config/private-names"
  : >"$log"
  out=$(cd "$REPO" && in_pane "$HOOKS" gh pr create --repo example/public-repo --title Clean --body ok 2>&1) &&
  fail "an empty list let a public PR open"
  [ ! -s "$log" ] || fail "the real gh ran with an empty list"
  unset FAKE_GH_LOG FAKE_GH_VIS
  pass "the gh and gh-axi shims refuse or rewrite PR titles, bodies, and stdin, refuse a named head branch, and pass private repos"
}

test_no_mistakes_shim_checks_public_inputs() {
  local d=$TMP_ROOT/no-mistakes home log out
  home=$d/home
  make_home "$home"
  make_repo "$d" "$home" public
  mkdir -p "$d/fakebin"
  FAKEBIN=$d/fakebin
  make_fake_no_mistakes "$FAKEBIN"
  log=$d/no-mistakes.log
  export FAKE_NM_LOG=$log
  : >"$log"
  out=$(cd "$REPO" && in_pane "$HOOKS" no-mistakes axi run --intent 'Build for acme-test' 2>&1) &&
    fail "no-mistakes accepted a listed intent"
  [ ! -s "$log" ] || fail "the real no-mistakes ran for a listed intent"
  assert_contains "$out" "mate-1" "the intent refusal omitted a neutral id"
  out=$(cd "$REPO" && in_pane "$HOOKS" no-mistakes axi respond --pr-title='Serve zenith-sample' 2>&1) &&
    fail "no-mistakes accepted a listed PR title"
  [ ! -s "$log" ] || fail "the real no-mistakes ran for a listed title"
  git -C "$REPO" checkout -q -b fm/acme-test-work
  out=$(cd "$REPO" && in_pane "$HOOKS" no-mistakes axi run 2>&1) &&
    fail "no-mistakes accepted a listed branch"
  [ ! -s "$log" ] || fail "the real no-mistakes ran for a listed branch"
  git -C "$REPO" checkout -q main
  (cd "$REPO" && in_pane "$HOOKS" no-mistakes axi run --intent 'Clean work') ||
    fail "no-mistakes refused a clean run"
  assert_contains "$(cat "$log")" "[axi][run][--intent][Clean work]" "the clean call did not reach no-mistakes"
  unset FAKE_NM_LOG
  pass "the no-mistakes shim refuses listed intent, PR title, and branch inputs"
}

test_visibility_asks_github_once_and_caches() {
  local d=$TMP_ROOT/vis home count out
  home=$d/home
  make_home "$home"
  make_repo "$d" "$home" private
  FAKEBIN=$(make_fake_gh "$d")
  count=$d/count
  : >"$count"
  export FAKE_GH_LOG=$d/gh.log FAKE_GH_COUNT=$count
  : >"$FAKE_GH_LOG"
  out=$(cd "$REPO" && GH_HOST=enterprise.example.invalid FAKE_GH_VIS=public in_pane "$HOOKS" gh pr create \
    --repo https://github.com/Example/Open.git --title 'Fix acme-test' --body ok 2>&1) &&
    fail "a public answer allowed a named PR"
  assert_contains "$out" "mate-1" "the public refusal omitted the neutral id"
  assert_contains "$(cat "$FAKE_GH_LOG")" "[--hostname] [github.com]" \
    "the visibility lookup used the ambient GitHub host"
  assert_contains "$(cat "$home/state/repo-visibility.cache")" "example/open public" \
    "the public answer was not persisted"
  out=$(cd "$REPO" && FAKE_GH_VIS=private in_pane "$HOOKS" gh pr create \
    --repo example/open --title 'Fix acme-test' --body ok 2>&1) &&
    fail "a cached public answer allowed a named PR"
  assert_equals 1 "$(wc -l <"$count" | tr -d ' ')" "visibility asked GitHub more than once"
  out=$(cd "$REPO" && FAKE_GH_VIS=fail in_pane "$HOOKS" gh pr create \
    --repo example/unknown --title 'Fix acme-test' --body ok 2>&1) &&
    fail "a failed lookup allowed a named PR"
  out=$(cd "$REPO" && FAKE_GH_VIS=private in_pane "$HOOKS" gh pr create \
    --repo example/unknown --title 'Fix acme-test' --body ok 2>&1) ||
    fail "a failed lookup was cached as public: $out"
  assert_equals 3 "$(wc -l <"$count" | tr -d ' ')" "a failed lookup was cached"
  out=$(cd "$REPO" && FAKE_GH_VIS=private in_pane "$HOOKS" gh pr create \
    --repo example/change --title 'Fix acme-test' --body ok 2>&1) ||
    fail "a private destination refused a named PR: $out"
  out=$(cd "$REPO" && FAKE_GH_VIS=public in_pane "$HOOKS" gh pr create \
    --repo example/change --title 'Fix acme-test' --body ok 2>&1) &&
    fail "a former private result bypassed the public guard"
  assert_equals 5 "$(wc -l <"$count" | tr -d ' ')" "a private result was cached"
  : >"$FAKE_GH_LOG"
  out=$(cd "$REPO" && GH_HOST=other.example.invalid FAKE_GH_VIS=private in_pane "$HOOKS" gh pr create \
    --repo https://forge.example.invalid/Example/Open.git --title 'Fix acme-test' --body ok 2>&1) ||
    fail "an enterprise private destination refused a named PR: $out"
  assert_contains "$(cat "$FAKE_GH_LOG")" "[--hostname] [forge.example.invalid]" \
    "the visibility lookup used the ambient host instead of the destination"
  assert_contains "$(cat "$FAKE_GH_LOG")" "[pr] [create]" \
    "a public result from another host was reused for the private destination"
  out=$(cd "$REPO" && in_pane "$HOOKS" gh pr create \
    --repo "$d/local.git" --title 'Fix acme-test' --body ok 2>&1) ||
    fail "a local destination refused a named PR: $out"
  out=$(cd "$REPO" && in_pane "$HOOKS" gh pr create \
    --repo https://git.example.invalid/x/y.git --title 'Fix acme-test' --body ok 2>&1) &&
    fail "an unknown network destination allowed a named PR"
  assert_equals 7 "$(wc -l <"$count" | tr -d ' ')" "visibility did not query both network hosts"
  unset FAKE_GH_LOG FAKE_GH_COUNT
  pass "PR publication uses public visibility caching and checks fresh private answers"
}

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

test_scrub_tool_dry_run_and_apply() {
  local d=$TMP_ROOT/scrub home ev seed out log old_tip new_tip
  home=$d/home
  make_home "$home"
  FAKEBIN=$(make_fake_gh "$d")
  log=$d/gh.log
  : >"$log"
  printf '%s\t%s\t%s\t%s\n' \
    11 MERGED "$(b64 "Ship the acme-test lane")" "$(b64 $'Clean line\nRoutes to zenith-sample')" \
    12 OPEN "$(b64 "Plain title")" "$(b64 "Plain body")" >"$d/prs.tsv"
  ev=$d/evidence.git
  seed=$d/seed
  git init -q --bare "$ev"
  fm_git_init_commit "$seed"
  git -C "$seed" checkout -q --orphan no-mistakes/evidence
  git -C "$seed" rm -rq --cached .
  rm -f "$seed/README.md"
  commit_file "$seed" run-1/clean.log "all good" "Run 1 evidence"
  commit_file "$seed" run-2/acme-test.log "path names it" "Run 2 evidence"
  commit_file "$seed" run-3/out.log "content names Zenith-Sample" "Run 3 evidence"
  git -C "$seed" push -q "$ev" no-mistakes/evidence
  old_tip=$(git -C "$ev" rev-parse no-mistakes/evidence)
  export FAKE_GH_LOG=$log FAKE_GH_PRS=$d/prs.tsv FAKE_GH_VIS=public
  out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME=$home "$SCRUB" --repo example/public-repo \
    --evidence-remote "$ev" 2>&1) && fail "an alternate evidence remote was accepted"
  out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME=$home "$SCRUB" --repo example/public-repo \
    --evidence-branch other/evidence 2>&1) && fail "an alternate evidence branch was accepted"

  out=$(GH_HOST=enterprise.example.invalid PATH="$FAKEBIN:$BASE_PATH" FM_HOME=$home FM_TEST_SEAM=1 FM_TEST_PRIVATE_NAMES_EVIDENCE_REMOTE=$ev \
    "$SCRUB" --repo example/public-repo 2>&1) ||
    fail "dry run failed: $out"
  assert_contains "$out" "dry run" "the dry run did not say so"
  assert_contains "$out" "PR #11 (MERGED): title lines with a listed name: 1, body lines: 1" "the dry run missed PR 11"
  assert_not_contains "$out" "PR #12" "the dry run reported a clean PR"
  assert_contains "$out" "would be removed: run-2/mate-1.log" "the dry run missed a named path"
  assert_contains "$out" "would be removed: run-3/out.log" "the dry run missed named content"
  assert_contains "$out" "2 of 3 files hold a listed name" "the dry run miscounted evidence"
  assert_not_contains "$out" "acme-test" "the dry run printed a private name"
  assert_not_contains "$out" "zenith-sample" "the dry run printed a private name"
  assert_contains "$(cat "$log")" "[api] [--paginate]" "the scrub tool did not page through all pull requests"
  assert_contains "$(cat "$log")" "[--hostname] [github.com]" "the scrub API used the ambient GitHub host"
  assert_not_contains "$(cat "$log")" "[edit]" "the dry run edited a PR"
  assert_equals "$old_tip" "$(git -C "$ev" rev-parse no-mistakes/evidence)" "the dry run moved the evidence branch"

  out=$(GH_HOST=enterprise.example.invalid PATH="$FAKEBIN:$BASE_PATH" FM_HOME=$home FM_TEST_SEAM=1 FM_TEST_PRIVATE_NAMES_EVIDENCE_REMOTE=$ev \
    "$SCRUB" --repo example/public-repo --apply 2>&1) ||
    fail "apply failed: $out"
  assert_contains "$(cat "$log")" "[pr] [edit] [11] [--repo] [github.com/example/public-repo] [--title] [Ship the mate-1 lane]" \
    "apply did not rewrite PR 11's title"
  assert_contains "$(cat "$log")" $'Clean line\nRoutes to client-1' "apply did not rewrite PR 11's body"
  assert_not_contains "$(cat "$log")" "[edit] [12]" "apply edited a clean PR"
  new_tip=$(git -C "$ev" rev-parse no-mistakes/evidence)
  assert_equals "$old_tip" "$(git -C "$ev" rev-parse "$new_tip^")" "the removal was not one commit on top of the old tip"
  assert_equals "run-1/clean.log" "$(git -C "$ev" ls-tree -r --name-only "$new_tip")" "apply removed the wrong files"
  assert_equals 4 "$(git -C "$ev" rev-list --count "$new_tip")" "history was rewritten"
  git -C "$ev" cat-file -e "$old_tip:run-2/acme-test.log" || fail "an earlier evidence commit lost its file"

  cat >"$FAKEBIN/git" <<SH
#!/usr/bin/env bash
if [ "\$1" = clone ]; then exit 1; fi
exec "$(command -v git)" "\$@"
SH
  chmod +x "$FAKEBIN/git"
  out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME=$home FM_TEST_SEAM=1 FM_TEST_PRIVATE_NAMES_EVIDENCE_REMOTE=$ev \
    "$SCRUB" --repo example/public-repo --pr 12 --apply 2>&1) &&
    fail "the scrub tool reported success after a clone failure"
  assert_contains "$out" "cannot clone" "the scrub tool did not report the clone failure"
  rm -f "$FAKEBIN/git"

  : >"$log"
  out=$(FAKE_GH_VIS=private PATH="$FAKEBIN:$BASE_PATH" FM_HOME=$home "$SCRUB" --repo example/closed-repo --apply 2>&1) ||
    fail "a private repository scrub failed: $out"
  assert_contains "$out" "is private: nothing to scrub" "a private repository was scrubbed"
  assert_not_contains "$(cat "$log")" "[edit]" "a private repository's PR was edited"
  unset FAKE_GH_LOG FAKE_GH_PRS FAKE_GH_VIS
  pass "the scrub tool dry-runs by default without printing names, and applies PR rewrites plus one evidence removal commit"
}

test_scrub_refreshes_registered_names() {
  local d=$TMP_ROOT/scrub-stale home bad log out
  home=$d/home
  make_home "$home"
  FAKEBIN=$(make_fake_gh "$d")
  log=$d/gh.log
  : >"$log"
  printf '%s\t%s\t%s\t%s\n' 17 OPEN "$(b64 'Ship quasar-mate work')" "$(b64 'Clean body')" >"$d/prs.tsv"
  printf '%s\n' '- quasar-mate - A made-up route. (home: /nonexistent; scope: x; projects: none; added 2026-01-01)' \
    >"$home/data/secondmates.md"
  export FAKE_GH_LOG=$log FAKE_GH_PRS=$d/prs.tsv FAKE_GH_VIS=public
  out=$(GH_HOST=other.example.invalid PATH="$FAKEBIN:$BASE_PATH" FM_HOME=$home "$SCRUB" \
    --repo https://forge.example.invalid/example/public-repo --no-evidence --apply 2>&1) ||
    fail "a stale-list scrub failed: $out"
  assert_contains "$(cat "$log")" "[pr] [edit] [17]" "the newly registered name remained in PR text"
  assert_contains "$(cat "$log")" "[--hostname] [forge.example.invalid]" "the URL host was not used for the PR API"
  assert_contains "$(cat "$log")" "[--repo] [forge.example.invalid/example/public-repo]" "the URL host was not used for PR edits"
  assert_not_contains "$(cat "$log")" "quasar-mate" "the newly registered name reached the edit call"
  assert_contains "$(cat "$home/config/private-names")" "quasar-mate" "the scrub did not refresh the list"
  bad=$d/bad-home
  mkdir -p "$bad/state" "$bad/data"
  : >"$bad/config"
  : >"$log"
  out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME=$bad "$SCRUB" --repo example/public-repo --no-evidence --apply 2>&1) &&
    fail "the scrub proceeded after its list refresh failed"
  assert_contains "$out" "cannot refresh" "the scrub did not explain the failed refresh"
  assert_not_contains "$(cat "$log")" "[api] [--paginate]" "the scrub read PR text after refresh failed"
  unset FAKE_GH_LOG FAKE_GH_PRS FAKE_GH_VIS
  pass "the scrub tool refreshes registered names before editing public PR text"
}

test_keep_ai_trailers_install_keeps_the_trailer_and_the_guard() {
  local d=$TMP_ROOT/keep home hooks repo
  home=$d/home
  make_home "$home"
  repo=$d/work
  hooks=$d/hooks
  fm_git_init_commit "$repo"
  "$STRIP" install "$hooks" "$repo" --keep-ai-trailers --private-names "$home/config" "$home/state" "$home" "$home/data" "$home/projects" ||
    fail "keep-ai-trailers install failed"
  printf 'x\n' >"$repo/k.txt"
  git -C "$repo" add k.txt
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$hooks \
    git -C "$repo" commit -q -m $'Keep\n\nCo-authored-by: Cursor <cursoragent@cursor.com>' ||
    fail "keep-ai-trailers commit failed"
  assert_contains "$(git -C "$repo" log -1 --format=%B)" "Co-authored-by: Cursor" "keep-ai-trailers stripped the trailer"
  [ -x "$hooks/bin/gh" ] && [ -x "$hooks/bin/gh-axi" ] && [ -x "$hooks/bin/no-mistakes" ] ||
    fail "keep-ai-trailers install omitted a publishing shim"
  pass "a keep-ai-trailers install keeps AI trailers but still installs the private-name guard"
}

test_existing_tree_never_blocks_an_unrelated_push() {
  local d=$TMP_ROOT/existing home out
  home=$d/home
  make_home "$home"
  make_repo "$d" "$home" public
  # Content that was already public before the guard: pushed without hooks.
  printf '%s\n' one "routes to acme-test" three four five >"$REPO/notes.md"
  mkdir -p "$REPO/zenith-sample"
  printf 'old\n' >"$REPO/zenith-sample/readme.txt"
  git -C "$REPO" add notes.md zenith-sample/readme.txt
  git -C "$REPO" commit -q -m "Existing content"
  git -C "$REPO" push -q origin main
  git -C "$REPO" fetch -q origin

  in_pane "$HOOKS" git -C "$REPO" checkout -q -b fm/unrelated
  sed -i.bak 's/^three$/three changed/' "$REPO/notes.md" && rm -f "$REPO/notes.md.bak"
  printf 'new\n' >"$REPO/zenith-sample/readme.txt"
  git -C "$REPO" add notes.md zenith-sample/readme.txt
  in_pane "$HOOKS" git -C "$REPO" commit -q -m "Touch unrelated lines" || fail "an unrelated commit was refused"
  out=$(in_pane "$HOOKS" git -C "$REPO" push -q origin HEAD 2>&1) ||
    fail "an existing tracked line or path holding a listed name blocked an unrelated push: $out"
  pass "an existing tracked line or file path holding a listed name never blocks an unrelated push"
}

test_refresh_derives_names_from_local_records
test_secondmate_refresh_merges_the_primary_list
test_existing_tree_never_blocks_an_unrelated_push
test_commit_message_is_refused_or_rewritten_on_a_public_repo
test_private_repo_passes_untouched
test_empty_list_on_a_public_repo_refuses
test_private_home_path_stays_out_of_guard_output
test_pre_push_refuses_names_in_branch_message_patch_and_path
test_new_public_branch_scans_commits_from_other_remotes
test_stale_registered_name_is_refreshed_before_commit
test_evidence_push_with_a_listed_name_is_refused
test_gate_remote_is_judged_by_origin_and_repo_hook_still_runs
test_new_gate_and_unfetched_public_branches_skip_public_history
test_merge_added_paths_and_lines_are_checked
test_unreadable_public_refs_refuse_push
test_gh_shim_refuses_or_rewrites_pr_text
test_no_mistakes_shim_checks_public_inputs
test_visibility_asks_github_once_and_caches
test_scrub_tool_dry_run_and_apply
test_scrub_refreshes_registered_names
test_keep_ai_trailers_install_keeps_the_trailer_and_the_guard

echo "# all fm-private-names tests passed"
