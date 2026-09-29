#!/usr/bin/env bash
# bin/backends/orca.sh - the Orca terminal session-provider adapter.
#
# FirstMate owns the linked git checkout. Orca is the terminal only.
# Escape key support remains unsupported until Orca exposes a terminal-send primitive for it.
#
# Target string shape: the Orca terminal id accepted by `orca terminal ...`.

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-composer-lib.sh"

fm_backend_orca_tool_check() {
  command -v orca >/dev/null 2>&1 || { echo "error: backend=orca selected but the 'orca' CLI is not installed" >&2; return 1; }
}

fm_backend_orca_runtime_check() {
  fm_backend_orca_tool_check || return 1
  local out
  out=$(orca status --json 2>/dev/null) || {
    echo "error: backend=orca selected but 'orca status --json' failed; start Orca and wait for the runtime to be ready" >&2
    return 1
  }
  # shellcheck disable=SC2016  # Single quotes are deliberate: ${...} belongs to the Node snippet.
  printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (err) {
  console.error("error: invalid Orca status JSON: " + err.message);
  process.exit(1);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  console.error("error: Orca runtime is not ready" + (msg ? ": " + msg : ""));
  process.exit(1);
}
const r = data.result || {};
const runtime = r.runtime || {};
const reachable = runtime.reachable ?? r.runtimeReachable;
const state = runtime.state || r.runtimeState || "";
if (reachable === true && state === "ready") process.exit(0);
console.error(`error: backend=orca requires a ready Orca runtime (reachable=${String(reachable)}, state=${state || "unknown"})`);
process.exit(1);
'
}

fm_backend_orca_json_get() {  # <field> ; fields: worktree-id worktree-path terminal-handle terminal-worktree-id worktree-terminal-handle repo-id
  # Terminal handles are accepted only from verified terminal result shapes:
  # result.terminal or a root terminal object with .handle. Undocumented
  # result.id and result.worktree.terminal shapes are ignored until a real Orca
  # smoke run proves them.
  local field=$1
  node -e '
const fs = require("fs");
const field = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
const wt = r.worktree || r.item || r;
const explicitTerm = r.terminal || null;
const repo = r.repo || r.repository || r;
function scalar(v) {
  return (typeof v === "string" || typeof v === "number") ? String(v) : "";
}
function handle(obj) {
  if (!obj) return "";
  if (typeof obj === "string" || typeof obj === "number") return String(obj);
  return scalar(obj.handle) || "";
}
if (field === "terminal-handle-count") {
  const found = [];
  function add(obj) {
    const h = handle(obj);
    if (!h || found.indexOf(h) !== -1) return;
    found.push(h);
  }
  if (r.terminal) add(r.terminal);
  if (r.handle != null) add(r);
  process.stdout.write(String(found.length));
  process.exit(0);
}
let v = "";
if (field === "worktree-id") v = wt.id || wt.worktreeId || r.worktreeId || "";
if (field === "worktree-path") v = wt.path || (wt.git && wt.git.path) || r.path || "";
if (field === "terminal-handle") v = handle(explicitTerm || r) || "";
if (field === "worktree-terminal-handle") v = handle(explicitTerm) || "";
if (field === "terminal-worktree-id") v = scalar(explicitTerm && explicitTerm.worktreeId);
if (field === "repo-id") v = repo.id || repo.repoId || r.repoId || "";
if (!v) process.exit(1);
process.stdout.write(String(v));
' "$field"
}

fm_backend_orca_json_ok() {
  node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8").trim();
if (!input) process.exit(0);
let data;
try {
  data = JSON.parse(input);
} catch (err) {
  console.error("invalid Orca JSON: " + err.message);
  process.exit(2);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
'
}

fm_backend_orca_run_json() {
  local out
  out=$("$@") || return 1
  printf '%s' "$out" | fm_backend_orca_json_ok
}

fm_backend_orca_repo_ensure() {  # <project-path>
  local project=$1 out repo_id native
  fm_backend_orca_tool_check || return 1
  native=$(fm_backend_orca_native_path "$project") || return 1
  if out=$(orca repo show --repo "path:$native" --json); then
    repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id) || {
      echo "error: orca repo show returned no repo id for $native" >&2
      return 1
    }
    printf '%s' "$repo_id"
    return 0
  fi
  if ! printf '%s' "$out" | node -e '
const fs = require("fs");
let result;
try { result = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(1); }
process.exit(result.ok === false && result.error?.code === "repo_not_found" ? 0 : 1);
'; then
    echo "error: orca repo show failed for $native without a proven repo_not_found; refusing registration" >&2
    return 1
  fi
  out=$(orca repo add --path "$native" --json) || return 1
  repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id) || {
    echo "error: orca repo add did not return a repo id for $native" >&2
    return 1
  }
  printf '%s' "$repo_id"
}

# Native Windows path for the Orca path: selector. Git Bash pwd (/tmp or /c)
# and git's C:/ porcelain disagree until cygpath -m. Absent cygpath (Linux)
# keeps the absolute path. WSL /mnt/c and PowerShell are not rewritten.
fm_backend_orca_native_path() {  # <path>
  local path=$1 native
  [ -n "$path" ] || return 1
  if command -v cygpath >/dev/null 2>&1; then
    native=$(cygpath -m "$path") || return 1
    printf '%s' "$native"
    return 0
  fi
  printf '%s' "$path"
}

fm_backend_orca_expected_dir() {  # <project> <task-id>
  local project=$1 id=$2 proj_real
  case "$id" in
    ''|*[!A-Za-z0-9._-]*)
      echo "error: refusing Orca checkout; task id is not one path segment" >&2
      return 1
      ;;
  esac
  proj_real=$(cd "$project" && pwd -P) || return 1
  printf '%s' "$proj_real/.worktrees/$id"
}

fm_backend_orca_registration_count() {  # <checkout> <native-path>
  local checkout=$1 native=$2 list line path one n=0
  if ! list=$(git -C "$checkout" worktree list --porcelain 2>/dev/null); then
    echo "error: git worktree list failed for $checkout; this does not prove the checkout is unregistered" >&2
    return 1
  fi
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        path=${line#worktree }
        one=$(fm_backend_orca_native_path "$path") || return 1
        if [ "$one" = "$native" ]; then
          n=$((n + 1))
        fi
        ;;
    esac
  done <<EOF
$list
EOF
  printf '%s' "$n"
}

fm_backend_orca_assert_linked_checkout() {  # <project> <expected-path>
  local project=$1 expected=$2 proj_common wt_common git_dir count real exp_native
  if [ -L "$expected" ]; then
    echo "error: refusing Orca checkout; $expected is a symlink" >&2
    return 1
  fi
  [ -d "$expected" ] || {
    echo "error: refusing Orca checkout; $expected is not a directory" >&2
    return 1
  }
  if ! wt_common=$(git -C "$expected" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    echo "error: refusing Orca checkout; common dir of $expected could not be read. This does not prove the checkout is unregistered." >&2
    return 1
  fi
  proj_common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
    echo "error: refusing Orca checkout; common dir of $project could not be read" >&2
    return 1
  }
  wt_common=$(fm_backend_orca_native_path "$wt_common") || return 1
  proj_common=$(fm_backend_orca_native_path "$proj_common") || return 1
  if [ "$wt_common" != "$proj_common" ]; then
    echo "error: refusing Orca checkout; $expected does not share the target repo common dir" >&2
    return 1
  fi
  git_dir=$(git -C "$expected" rev-parse --absolute-git-dir 2>/dev/null) || {
    echo "error: refusing Orca checkout; git dir of $expected could not be read. This does not prove the checkout is unregistered." >&2
    return 1
  }
  git_dir=$(fm_backend_orca_native_path "$git_dir") || return 1
  if [ "$git_dir" = "$proj_common" ]; then
    echo "error: refusing Orca checkout; $expected is the primary checkout" >&2
    return 1
  fi
  exp_native=$(fm_backend_orca_native_path "$expected") || return 1
  count=$(fm_backend_orca_registration_count "$expected" "$exp_native") || return 1
  if [ "$count" != 1 ]; then
    echo "error: refusing Orca checkout; $expected is registered $count times. Nothing was deleted." >&2
    return 1
  fi
  real=$(cd "$expected" && pwd -P) || return 1
  real=$(fm_backend_orca_native_path "$real") || return 1
  if [ "$real" != "$exp_native" ]; then
    echo "error: refusing Orca checkout; canonical path $real does not match $exp_native" >&2
    return 1
  fi
}

fm_backend_orca_assert_recorded_checkout() {  # <project> <task-id> <recorded-path>
  local expected=$3 native_expected native_recorded
  expected=$(fm_backend_orca_expected_dir "$1" "$2") || return 1
  if [ -L "$3" ] || [ -L "$expected" ]; then
    echo "error: refusing Orca relaunch; checkout path is a symlink" >&2
    return 1
  fi
  native_expected=$(fm_backend_orca_native_path "$expected") || return 1
  native_recorded=$(fm_backend_orca_native_path "$3") || return 1
  if [ "$native_expected" != "$native_recorded" ]; then
    echo "error: refusing Orca relaunch; recorded worktree $3 is not $expected" >&2
    return 1
  fi
  fm_backend_orca_assert_linked_checkout "$1" "$expected"
}

# Prints bash_pwd<TAB>native_path. Exit 1: refused before a checkout this call
# created. Exit 2: a checkout exists or the add result is uncertain; caller
# records recovery and does not delete it.
fm_backend_orca_prepare_linked_checkout() {  # <project> <task-id>
  local project=$1 id=$2 expected parent bash_path native
  expected=$(fm_backend_orca_expected_dir "$project" "$id") || return 1
  parent=$(dirname -- "$expected")
  if [ -L "$expected" ] || [ -e "$expected" ]; then
    echo "error: refusing Orca launch; checkout path already exists: $expected" >&2
    return 1
  fi
  if [ -L "$parent" ] || { [ -e "$parent" ] && [ ! -d "$parent" ]; }; then
    echo "error: refusing Orca launch; .worktrees is not a real directory: $parent" >&2
    return 1
  fi
  if ! git -C "$project" check-ignore -q -- "$expected"; then
    echo "error: refusing Orca launch; target repo must ignore .worktrees/ before FirstMate creates $expected" >&2
    return 1
  fi
  mkdir -p -- "$parent" || return 1
  if [ -L "$expected" ] || [ -e "$expected" ]; then
    echo "error: refusing Orca launch; checkout path already exists: $expected" >&2
    return 1
  fi
  if ! git -C "$project" worktree add --detach -- "$expected" HEAD >/dev/null; then
    if [ -e "$expected" ] || [ -L "$expected" ]; then
      echo "error: git worktree add failed for $expected; the path exists and a failed add does not prove it is unregistered. Leaving it in place." >&2
      return 2
    fi
    echo "error: git worktree add failed for $expected; a failed add does not prove the checkout or its registration is absent. Recording recovery without deletion." >&2
    return 2
  fi
  if ! fm_backend_orca_assert_linked_checkout "$project" "$expected"; then
    echo "error: linked checkout at $expected failed identity checks. Leaving it in place." >&2
    return 2
  fi
  bash_path=$(cd "$expected" && pwd) || return 2
  native=$(fm_backend_orca_native_path "$bash_path") || return 2
  printf '%s\t%s' "$bash_path" "$native"
}

fm_backend_orca_compose_id() {  # <maybe-id> <bash-path>
  local id=$1 path=$2
  case "$id" in
    ''|*[!A-Za-z0-9._@%+-]*) printf 'linked::%s' "$path" ;;
    *) printf '%s::%s' "$id" "$path" ;;
  esac
}

fm_backend_orca_resolve_existing() {  # <native-path>
  local native=$1 out path shown id
  fm_backend_orca_tool_check || return 1
  if ! out=$(orca worktree show --worktree "path:$native" --json); then
    echo "error: orca worktree show failed for path:$native; a failed show does not prove the checkout is unregistered" >&2
    return 1
  fi
  if ! printf '%s' "$out" | fm_backend_orca_json_ok; then
    echo "error: orca worktree show for path:$native was not ok; a failed show does not prove the checkout is unregistered" >&2
    return 1
  fi
  if ! path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path); then
    echo "error: orca worktree show for path:$native did not return a worktree path; refusing" >&2
    return 1
  fi
  shown=$(fm_backend_orca_native_path "$path") || return 1
  if [ "$shown" != "$native" ]; then
    echo "error: orca registration path mismatch for $native (show returned $shown); refusing launch" >&2
    return 1
  fi
  id=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-id 2>/dev/null || true)
  printf '%s' "$id"
}

fm_backend_orca_terminal_create() {  # <native-path> <resolved-worktree-id> <unique-title>
  local native=$1 expected_id=$2 title=$3 out count terminal bound_id
  fm_backend_orca_tool_check || return 1
  if ! out=$(orca terminal create --worktree "path:$native" --shell git-bash --title "$title" --json); then
    echo "error: orca terminal create failed for path:$native; a failed create does not prove no terminal was created" >&2
    return 1
  fi
  if ! count=$(printf '%s' "$out" | fm_backend_orca_json_get terminal-handle-count); then
    echo "error: orca terminal create for path:$native did not return an unambiguous handle; a failed create does not prove no terminal was created" >&2
    return 1
  fi
  if [ "$count" != 1 ]; then
    echo "error: orca terminal create for path:$native returned $count accepted handles; refusing as ambiguous and not creating another terminal" >&2
    return 1
  fi
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get terminal-handle) || {
    echo "error: orca terminal create did not return one terminal handle for $native" >&2
    return 1
  }
  if ! bound_id=$(printf '%s' "$out" | fm_backend_orca_json_get terminal-worktree-id); then
    echo "error: orca terminal create JSON has no worktree identity binding for $native; refusing" >&2
    return 1
  fi
  if [ "$bound_id" != "$expected_id" ]; then
    echo "error: orca terminal create bound worktree $bound_id, not $expected_id; refusing" >&2
    return 1
  fi
  printf '%s' "$terminal"
}

# Reconcile only a uniquely titled terminal bound to the exact resolved
# worktree. An incomplete inventory cannot prove absence after a failed create.
fm_backend_orca_terminal_lookup() {  # <native-path> <resolved-worktree-id> <unique-title>
  local out
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal list --worktree "path:$1" --json) || return 1
  printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try { data = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(1); }
const r = data.result || {};
if (data.ok !== true || !Array.isArray(r.terminals) || r.truncated !== false || r.totalCount !== r.terminals.length) process.exit(1);
const matches = r.terminals.filter(t => t.title === process.argv[1] && t.worktreeId === process.argv[2] && typeof t.handle === "string" && t.handle.length > 0);
if (matches.length !== 1) process.exit(1);
process.stdout.write(matches[0].handle);
' "$3" "$2"
}

fm_backend_orca_send_text_line() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$text" --enter --json
}

fm_backend_orca_send_literal() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "$text" --json
}

fm_backend_orca_remove_worktree() {  # <worktree-id>
  local worktree_id=${1:-}
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot remove worktree" >&2; return 1; }
  echo "error: refusing to remove Orca task checkout $worktree_id; stop_unverified does not prove the child process tree is dead, so no orca worktree rm, git worktree remove, or prune is run" >&2
  return 1
}

fm_backend_orca_worktree_path() {
  local worktree_id=${1:-} recorded native out path
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot resolve worktree path" >&2; return 1; }
  case "$worktree_id" in
    *::*) recorded=${worktree_id#*::} ;;
    *) recorded=$worktree_id ;;
  esac
  native=$(fm_backend_orca_native_path "$recorded") || return 1
  fm_backend_orca_tool_check || return 1
  if ! out=$(orca worktree show --worktree "path:$native" --json); then
    echo "error: orca worktree show failed for path:$native; a failed show does not prove the checkout is unregistered" >&2
    return 1
  fi
  path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree show did not return a path for $worktree_id; a failed show does not prove the checkout is unregistered" >&2
    return 1
  }
  printf '%s' "$path"
}

fm_backend_orca_capture() {  # <terminal-id> <lines>
  local terminal=$1 lines=${2:-40} out
  fm_backend_orca_tool_check || return 1
  out=$(orca terminal read --terminal "$terminal" --limit "$lines" --json) || return 1
  fm_backend_orca_json_text "$out"
}

fm_backend_orca_json_text() {  # <json>
  printf '%s' "$1" | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
if (r.terminal && Array.isArray(r.terminal.tail)) {
  process.stdout.write(r.terminal.tail.join("\n"));
} else if (Array.isArray(r.tail)) {
  process.stdout.write(r.tail.join("\n"));
} else {
  process.stdout.write(r.text || r.output || r.content || r.preview || "");
}
'
}

# fm_backend_orca_composer_capture: the orca composer screen - one bounded
# tail read of the live terminal. Deliberately NOT the old 200-line
# backward-paged read: the composer is bottom-anchored, and paging back into
# scrollback is what let a stale startup banner (codex's bordered
# "permissions" box) compete with - and once outrank - the live composer.
fm_backend_orca_composer_capture() {  # <terminal-id> [expected-label]
  fm_backend_orca_capture "$1" "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_caps: static capability facts, not logic (see the
# capability model in bin/fm-composer-lib.sh). Orca's `terminal read` returns
# plain text; whether it can emit ANSI is unverified (orca is not installed
# on the verification machine), so styled stays 0 - the conservative
# degradation - until a live capture proves otherwise.
fm_backend_orca_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_state: thin adapter - capture plus capabilities in,
# shared verdict out. Every shape (bordered boxes AND the borderless bare-glyph
# row this adapter never learned, which left every claude/codex/pi/muse steer
# unconfirmed) lives in bin/fm-composer-lib.sh.
fm_backend_orca_composer_state() {  # <terminal-id> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_orca_composer_capture "$1") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_backend_orca_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

fm_backend_orca_send_key() {  # <terminal-id> <key>
  local terminal=$1 key=$2
  fm_backend_orca_tool_check || return 1
  case "$key" in
    C-c|ctrl+c|Ctrl-c|Ctrl-C)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --interrupt --json
      ;;
    Enter|enter)
      fm_backend_orca_run_json orca terminal send --terminal "$terminal" --text "" --enter --json
      ;;
    *)
      echo "error: unsupported Orca key '$key'" >&2
      return 1
      ;;
  esac
}

# fm_backend_orca_send_text_submit: type <text> once, then drive the shared
# verify-and-retry-Enter loop (bin/fm-composer-lib.sh:
# fm_composer_submit_retry_core) against the shared composer verdict, so a
# slash-command popup placeholder fill gets the required second Enter without
# duplicating text.
fm_backend_orca_send_text_submit() {  # <terminal-id> <text> <retries> <enter-sleep> <settle>
  local terminal=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  fm_backend_orca_tool_check || { printf 'send-failed'; return 0; }
  fm_backend_orca_send_literal "$terminal" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_orca_send_key fm_backend_orca_composer_state \
    "$terminal" "$retries" "$sleep_s"
}

# fm_backend_orca_kill: close one recorded task terminal. A missing CLI is a
# close that was never attempted. A failed close is returned, not swallowed.
# Close success, including ptyKilled, is not proof the child process tree is
# dead: Orca show stays orphaned with exitCause stop_unverified.
fm_backend_orca_kill() {  # <terminal-id>
  local out
  fm_backend_orca_tool_check || return 1
  [ -n "${1:-}" ] || { echo "error: missing Orca terminal; close was not attempted" >&2; return 1; }
  if ! out=$(orca terminal close --terminal "$1" --json); then
    echo "error: orca terminal close failed for $1; the close error is not masked" >&2
    return 1
  fi
  printf '%s' "$out" | fm_backend_orca_json_ok
}
