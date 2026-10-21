#!/usr/bin/env bash
# Keep private names (operator home names and the clients they serve) off every
# public exit installed for fleet workers: commits, pushes, GitHub text, and the
# no-mistakes pipeline's own push.
#
# Usage:
#   fm-private-names.sh refresh
#       Regenerate the gitignored list (default config/private-names) from local
#       records and print only how many names it holds. Sources, in this home:
#       every data/secondmates.md route id (kind mate); every project name in
#       data/projects.md, in a route's projects: field, under projects/, or as a
#       clone's origin repository name that starts with gtm-client- (kind
#       client), plus the client slug after that prefix (kind client). For each
#       route whose home is on this machine, the same sources are read in that
#       home too. In a second mate home whose parent is on this machine, the
#       primary's list is merged in too. Names already in the list are kept in
#       place and new ones are appended, so neutral ids stay stable.
#       config/private-names.local adds names by hand as "<kind> <name>" or a
#       bare name (kind private). Short, number-only, and ordinary-word names
#       are listed in the context tier and match only name-shaped contexts.
#       Refresh also records this home in the gate index read by gate.
#   fm-private-names.sh check [--repo <dest>] [<file>...]
#       Scan the files (or stdin). Prints "<line> <neutral-id>" per hit, never
#       the name. Exit 0 clean or private destination, 1 a listed name, 3 the
#       destination is public and the list is missing or empty.
#   fm-private-names.sh scrub [<file>...]
#       Print the files (or stdin) with every listed name rewritten to its
#       neutral id (mate-1, client-1, ...).
#   fm-private-names.sh commit-msg <msgfile>
#       Git commit-msg hook. Checked when this repository's origin is public.
#   fm-private-names.sh pre-push <remote> <url>
#       Git pre-push hook. Reads git's ref lines on stdin and scans only
#       outgoing content: each pushed branch or tag name, annotated tag
#       messages, and for every commit the destination does not already have
#       its message, the content of added lines, paths it adds or renames, and
#       its binary blobs. The existing tree - unchanged lines and files a
#       commit only modifies - is not judged as text. A push to the
#       no-mistakes gate remote is judged by the repository's origin, because
#       the gate forwards there.
#   fm-private-names.sh gh-shim <gh|gh-axi> [<arg>...]
#       PATH shim for gh and gh-axi. On every destination it refuses a command
#       that could make a repository public or create a public copy unless it
#       makes an explicit private or internal choice: repo create or new
#       without --private or --internal, repo fork or an api fork of a source
#       not verified private, repo edit --visibility public, api writes whose
#       fields or input touch private or visibility, api creates without a
#       private choice, and transfer, Pages, and repository-mutating GraphQL.
#       Against a public or unknown repository, writes run only in the forms
#       the shim fully parses: pull requests, issues, releases (assets by
#       content), labels, repo edit and rename, workflow run, and api writes
#       (a method other than GET or HEAD, fields or input without one, or a
#       GraphQL mutation). It scans their text, files, stdin, head branch,
#       endpoint, and field keys and values before the real tool runs, and
#       refuses unknown options, other write commands, text from an editor,
#       browser, prompt, template, or attachment, JSON escapes it cannot
#       decode, and GraphQL with more than one operation. Private repositories
#       and read-only commands run unchanged.
#   fm-private-names.sh no-mistakes-shim [<arg>...]
#       PATH shim for no-mistakes. For a public origin it checks the intent, PR
#       title, fix instructions, added findings, reasons, and current branch
#       before the real tool runs, and adds --no-publish-intent to axi run.
#   fm-private-names.sh gate
#       no-mistakes pipeline gate (this repository's trusted .no-mistakes.yaml
#       runs it after lint). In the run worktree it looks up the homes whose
#       clones push through this gate in the per-user index refresh writes
#       (${XDG_STATE_HOME:-~/.local/state}/firstmate/private-names-gates/<id>)
#       and checks, against each home's list, everything the push would newly
#       expose plus uncommitted and untracked changes. A hit writes one
#       ask-user finding with neutral ids to $NO_MISTAKES_FINDINGS_FILE, which
#       parks the run before push. No registered home means nothing to check.
#
# Refusal and rewrite. A hit refuses (exit 1) and names only neutral ids. With
# FM_PRIVATE_NAMES_MODE=rewrite set, the commit-msg hook rewrites the message
# to neutral ids and the gh shim rewrites its arguments and body file before
# calling gh; a branch name or a pushed patch is never rewritten, so those
# still refuse and print the neutral-id form to rename to.
#
# Paths follow FM_HOME and FM_CONFIG_OVERRIDE / FM_STATE_OVERRIDE /
# FM_DATA_OVERRIDE / FM_PROJECTS_OVERRIDE like every other fleet script;
# bin/fm-git-strip-ai-trailers.sh bakes them into each launch's hooks and shims.
# bin/fm-private-names-lib.sh owns matching, neutral ids, and visibility.
# Worker launches also get a git shim that refuses git push --no-verify, a
# push whose effective core.hooksPath (from -c, --config-env, the environment,
# or an include) is not the launch's hooks, send-pack, http-push, and unknown
# options before the command (bin/fm-git-strip-ai-trailers.sh writes it).
# Accepted residual: a git alias that skips hooks, a process that runs git or
# gh by absolute path, or one that calls the GitHub API directly is not seen,
# and text the no-mistakes pipeline writes after its gate (the push step's
# commit subject and the PR text it drafts) is read back by
# bin/fm-private-names-scrub.sh after creation, as a backstop only.
set -u
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

# shellcheck source=bin/fm-private-names-lib.sh
. "$SCRIPT_DIR/fm-private-names-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
fm_pn_init "$CONFIG" "$STATE"

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" >&2
  exit 2
}

# ---------------------------------------------------------------- refresh

# Emit "<kind> <name>" candidates from one home's records.
emit_project_name() {  # <name>
  local name=$1 slug
  case "$name" in
    gtm-client-?*)
      printf 'client %s\n' "$name"
      slug=${name#gtm-client-}
      printf 'client %s\n' "$slug"
      ;;
  esac
}

emit_home_records() {  # <data-dir> <projects-dir> <with-routes:0|1>
  local data=$1 projects=$2 routes=$3 line name token dir url home
  if [ -f "$data/projects.md" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in '- '*) ;; *) continue ;; esac
      name=${line#- }
      name=${name%% \[*}
      name=${name%% - *}
      emit_project_name "$name"
    done <"$data/projects.md"
  fi
  if [ -d "$projects" ]; then
    for dir in "$projects"/*/; do
      [ -d "$dir" ] || continue
      dir=${dir%/}
      emit_project_name "${dir##*/}"
      url=$(git -C "$dir" remote get-url origin 2>/dev/null) || continue
      url=${url%/}
      url=${url%.git}
      emit_project_name "${url##*[/:]}"
    done
  fi
  [ -f "$data/secondmates.md" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    secondmate_registry_parse_line "$line" || continue
    printf 'mate %s\n' "$SECONDMATE_REGISTRY_ID"
    for token in ${SECONDMATE_REGISTRY_PROJECTS//,/ }; do
      emit_project_name "$token"
    done
    if [ "$routes" = 1 ] && [ "$SECONDMATE_REGISTRY_REMOTE" = 0 ]; then
      home=$SECONDMATE_REGISTRY_HOME
      case "$home" in \~/*) home=$HOME/${home#\~/} ;; esac
      if [ -d "$home" ]; then
        emit_home_records "$home/data" "$home/projects" 0
      fi
    fi
  done <"$data/secondmates.md"
}

refresh_source_snapshot() {
  local parent=$1
  [ -f "$FM_HOME/.fm-secondmate-parent" ] && cat "$FM_HOME/.fm-secondmate-parent"
  emit_home_records "$DATA" "$PROJECTS" 1
  if [ -n "$parent" ]; then
    emit_home_records "$parent/data" "$parent/projects" 1
    [ -f "$parent/config/private-names" ] && cat "$parent/config/private-names"
  fi
  [ -f "$FM_PN_LOCAL" ] && cat "$FM_PN_LOCAL"
  return 0
}

cmd_refresh() (
  [ "$#" -eq 0 ] || usage
  local out=$FM_PN_LIST tmp derived parent source_before
  mkdir -p "$(dirname "$out")" 2>/dev/null || return 1
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  if { [ -e "$out.lock" ] || [ -L "$out.lock" ]; } && [ ! -d "$out.lock" ]; then
    echo "fm-private-names: cannot lock the private-name list; refusing refresh" >&2
    return 1
  fi
  fm_lock_acquire_wait_max "$out.lock" 30 || {
    echo "fm-private-names: cannot lock the private-name list; refusing refresh" >&2
    return 1
  }
  trap 'fm_lock_release "$out.lock"' EXIT
  local attempt=0
  while :; do
  attempt=$((attempt + 1))
  if [ "$attempt" -gt 5 ]; then
    echo "fm-private-names: the home's records kept changing during refresh; refusing" >&2
    return 1
  fi
  # A second mate home on this machine also takes its primary's whole list, so
  # every home refuses the same names. The list is read from disk rather than
  # pushed as inherited config, which would paste it into the mate's context.
  parent=
  if fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" 2>/dev/null &&
    [ "$FM_SECONDMATE_PARENT_ROUTE" = local ]; then
    parent=$FM_SECONDMATE_PARENT_HOME
  fi
  source_before=$(refresh_source_snapshot "$parent")
  derived=$({
    emit_home_records "$DATA" "$PROJECTS" 1
    if [ -n "$parent" ]; then
      emit_home_records "$parent/data" "$parent/projects" 1
    fi
  } | LC_ALL=C sort -u)
  tmp=$(mktemp "$(dirname "$out")/.private-names.XXXXXX" 2>/dev/null) || return 1
  # Keep existing order, append newly derived names, then hand additions.
  {
    printf '# Generated by bin/fm-private-names.sh refresh. Do not edit by hand:\n'
    printf '# add names in private-names.local and rerun refresh. Never commit this file.\n'
    {
      [ -f "$out" ] && awk 'NF >= 2 && $1 !~ /^#/ { print }' "$out"
      [ -n "$parent" ] && [ -f "$parent/config/private-names" ] &&
        awk 'NF >= 2 && $1 !~ /^#/ { print }' "$parent/config/private-names"
      printf '%s\n' "$derived" | awk 'NF >= 2 { print }'
      [ -f "$FM_PN_LOCAL" ] && awk '
        /^[[:space:]]*(#|$)/ { next }
        /^[[:space:]]*!/ { next }
        NF == 1 { print "private " $1; next }
        { print }' "$FM_PN_LOCAL"
    } | awk -v generic_file="$FM_PN_GENERIC" '
      function trim(v) { sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v); return v }
      BEGIN {
        while ((getline line < generic_file) > 0) {
          line = trim(line)
          if (line != "" && line !~ /^#/) generic[tolower(line)] = 1
        }
      }
      NF >= 2 {
        kind = $1
        sub(/:context$/, "", kind)
        name = $0
        sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, "", name)
        name = trim(name)
        key = tolower(name)
        if (key in seen) next
        seen[key] = 1
        if (length(name) < 4 || name !~ /[A-Za-z]/ || (key in generic)) kind = kind ":context"
        print kind " " name
      }'
  } >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$out" 2>/dev/null || return 1
  [ "$(refresh_source_snapshot "$parent")" = "$source_before" ] && break
  done
  register_gates || {
    echo "fm-private-names: cannot record this home for its no-mistakes gates" >&2
    return 1
  }
  echo "private-names: $(fm_pn_count) names in config/private-names"
)

# Record this home against every local no-mistakes gate its clones push
# through, so the pipeline's own private-names gate (see cmd_gate) finds this
# home's list from the gate's run worktree, which carries no FM_HOME. One file
# per gate id, one tab-separated "home config state data projects" line per
# home; a home rewrites only its own line.
register_gates() (
  local index dir url id file tmp line
  index=$(fm_pn_gate_index) || return 1
  [ -d "$PROJECTS" ] || return 0
  mkdir -p "$index" && chmod 700 "$index" 2>/dev/null || return 1
  if { [ -e "$index/.private-names.lock" ] || [ -L "$index/.private-names.lock" ]; } &&
    [ ! -d "$index/.private-names.lock" ]; then
    echo "fm-private-names: cannot lock the gate index; refusing refresh" >&2
    return 1
  fi
  fm_lock_acquire_wait_max "$index/.private-names.lock" 30 || {
    echo "fm-private-names: cannot lock the gate index; refusing refresh" >&2
    return 1
  }
  trap 'fm_lock_release "$index/.private-names.lock"' EXIT
  line=$(printf '%s\t%s\t%s\t%s\t%s' "$(abs_dir "$FM_HOME")" "$(abs_dir "$CONFIG")" \
    "$(abs_dir "$STATE")" "$(abs_dir "$DATA")" "$(abs_dir "$PROJECTS")")
  for dir in "$PROJECTS"/*/; do
    [ -d "$dir" ] || continue
    url=$(git -C "$dir" remote get-url no-mistakes 2>/dev/null) || continue
    # A local gate: a path or file:// URL naming a git directory on this machine.
    case "$url" in
      file://*) url=${url#file://} ;;
      *://* | *@*:*) continue ;;
    esac
    # A gate directory that no longer exists has nothing pushing through it.
    (cd "$dir" 2>/dev/null && [ -e "$url" ]) || continue
    url=$(cd "$dir" 2>/dev/null && git -C "$url" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
      echo "fm-private-names: cannot resolve the no-mistakes gate of $(fm_pn_scrub_string "${dir%/}")" >&2
      return 1
    }
    id=$(gate_id "$url")
    case "$id" in
      '' | .* | *[!A-Za-z0-9._-]*)
        echo "fm-private-names: cannot record a no-mistakes gate whose name is not a plain file name" >&2
        return 1
        ;;
    esac
    file=$index/$id
    tmp=$(mktemp "$index/.$id.XXXXXX") || return 1
    {
      [ -f "$file" ] && awk -F '\t' -v c="$(abs_dir "$CONFIG")" '$2 != c' "$file"
      printf '%s\n' "$line"
    } >"$tmp" || {
      rm -f "$tmp"
      return 1
    }
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$file" || {
      rm -f "$tmp"
      return 1
    }
  done
)

# The index key of a gate: its git directory's name without a .git suffix.
gate_id() {  # <git-common-dir>
  local id=${1%/}
  case "$id" in */.git) id=${id%/.git} ;; esac
  id=${id%.git}
  printf '%s\n' "${id##*/}"
}

abs_dir() {  # <dir>
  (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
}

source_newer_in_home() {  # <data-dir> <projects-dir>
  local data=$1 projects=$2 dir config_path
  [ "$data/secondmates.md" -nt "$FM_PN_LIST" ] && return 0
  [ "$data/projects.md" -nt "$FM_PN_LIST" ] && return 0
  [ "$projects" -nt "$FM_PN_LIST" ] && return 0
  for dir in "$projects"/*/; do
    [ -d "$dir" ] || continue
    [ "$dir" -nt "$FM_PN_LIST" ] && return 0
    [ "$dir/.git" -nt "$FM_PN_LIST" ] && return 0
    [ "$dir/.git/config" -nt "$FM_PN_LIST" ] && return 0
    if [ -f "$dir/.git" ]; then
      config_path=$(git -C "$dir" rev-parse --git-path config 2>/dev/null) || continue
      case "$config_path" in /*) ;; *) config_path=$dir/$config_path ;; esac
      [ "$config_path" -nt "$FM_PN_LIST" ] && return 0
    fi
  done
  return 1
}

sources_newer_for_home() {  # <data-dir> <projects-dir>
  local data=$1 projects=$2 line home
  source_newer_in_home "$data" "$projects" && return 0
  if [ -f "$data/secondmates.md" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      secondmate_registry_parse_line "$line" || continue
      [ "$SECONDMATE_REGISTRY_REMOTE" = 0 ] || continue
      home=$SECONDMATE_REGISTRY_HOME
      case "$home" in \~/*) home=$HOME/${home#\~/} ;; esac
      source_newer_in_home "$home/data" "$home/projects" && return 0
    done <"$data/secondmates.md"
  fi
  return 1
}

refresh_if_stale() {
  local parent
  [ -s "$FM_PN_LIST" ] || { cmd_refresh >/dev/null; return; }
  [ "$FM_PN_GENERIC" -nt "$FM_PN_LIST" ] && { cmd_refresh >/dev/null; return; }
  [ "$FM_PN_LOCAL" -nt "$FM_PN_LIST" ] && { cmd_refresh >/dev/null; return; }
  [ "$FM_HOME/.fm-secondmate-parent" -nt "$FM_PN_LIST" ] && { cmd_refresh >/dev/null; return; }
  if fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" 2>/dev/null &&
    [ "$FM_SECONDMATE_PARENT_ROUTE" = local ]; then
    parent=$FM_SECONDMATE_PARENT_HOME
    [ "$parent/config/private-names" -nt "$FM_PN_LIST" ] && { cmd_refresh >/dev/null; return; }
    sources_newer_for_home "$parent/data" "$parent/projects" && { cmd_refresh >/dev/null; return; }
  fi
  sources_newer_for_home "$DATA" "$PROJECTS" && { cmd_refresh >/dev/null; return; }
  return 0
}

require_current_list() {
  refresh_if_stale 2>/dev/null || {
    echo "fm-private-names: cannot refresh the private-name list; refusing $1" >&2
    return 3
  }
  fm_pn_require_list "$1"
}

# ---------------------------------------------------------------- checks

# Print a finding report for stdin text; 0 clean, 1 hit. <label> names where
# the text came from in each line; pass noline when stdin is a filtered patch,
# whose line numbers do not match the file.
report_hits() {  # <label> [noline]
  local label=$1 where=${2:-} hits line ids rc
  hits=$(fm_pn_check_stream)
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -eq 1 ] || {
    echo "fm-private-names: cannot scan $label" >&2
    return 1
  }
  while read -r line ids; do
    if [ "$where" = noline ]; then
      echo "fm-private-names: listed private name ($ids) in $label" >&2
    else
      echo "fm-private-names: listed private name ($ids) in $label, line $line" >&2
    fi
  done <<<"$hits"
  return 1
}

cmd_check() {
  local dest='' f label rc=0
  if [ "${1:-}" = --repo ]; then
    [ "$#" -ge 2 ] || usage
    dest=$2
    shift 2
  fi
  if [ -n "$dest" ] && ! fm_pn_dest_is_public "$dest"; then
    return 0
  fi
  require_current_list "the check" || return 3
  if [ "$#" -eq 0 ]; then
    report_hits "stdin"
    return
  fi
  for f in "$@"; do
    label=$(fm_pn_scrub_string "$f")
    report_hits "$label" <"$f" || rc=1
  done
  return "$rc"
}

cmd_scrub() {
  if [ "$#" -eq 0 ]; then
    fm_pn_scrub_stream
    return
  fi
  cat -- "$@" | fm_pn_scrub_stream
}

origin_url() {
  git remote get-url origin 2>/dev/null
}

cmd_commit_msg() {
  local msg=${1:-} dest tmp
  [ -n "$msg" ] && [ -f "$msg" ] || usage
  dest=$(origin_url) || return 0
  fm_pn_dest_is_public "$dest" || return 0
  require_current_list "this commit" || return 3
  if report_hits "the commit message" <"$msg" 2>/dev/null; then
    return 0
  fi
  if [ "${FM_PRIVATE_NAMES_MODE:-}" = rewrite ]; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/fm-private-names-msg.XXXXXX") || return 1
    if ! fm_pn_scrub_stream <"$msg" >"$tmp" || ! mv "$tmp" "$msg"; then
      rm -f "$tmp"
      return 1
    fi
    echo "fm-private-names: rewrote listed private names in the commit message to neutral ids" >&2
    return 0
  fi
  report_hits "the commit message" <"$msg"
  echo "fm-private-names: refusing this commit to a public repository; reword it, or rerun with FM_PRIVATE_NAMES_MODE=rewrite to rewrite names to neutral ids" >&2
  return 1
}

ZERO_SHA=0000000000000000000000000000000000000000

# Paths a commit adds, renames to, or copies to.
new_paths() {  # <sha>
  changed_paths "$1" ACR
}

changed_paths() {  # <sha> <filter>
  if git rev-parse -q --verify "$1^" >/dev/null 2>&1; then
    git diff --name-only -z -M -C --diff-filter="$2" "$1^" "$1"
  else
    git diff-tree --root --no-commit-id --name-only -z -r -M -C --diff-filter="$2" "$1"
  fi
}

# The content of a commit's added lines, without the leading "+" or any diff
# header, optionally for one path.
added_lines() {  # <sha> [<path>]
  if git rev-parse -q --verify "$1^" >/dev/null 2>&1; then
    git diff --no-color --no-ext-diff --unified=0 "$1^" "$1" -- ${2:+"$2"}
  else
    git show --format= --no-color --no-ext-diff --unified=0 "$1" -- ${2:+"$2"}
  fi | awk '/^diff / { header = 1; next } /^@@/ { header = 0; next } !header && /^\+/ { print substr($0, 2) }'
}

binary_paths() {  # <sha>
  local entry
  if git rev-parse -q --verify "$1^" >/dev/null 2>&1; then
    git diff --numstat --no-renames --diff-filter=AM -z "$1^" "$1"
  else
    git diff-tree --root --no-commit-id --numstat --no-renames --diff-filter=AM -r -z "$1"
  fi | while IFS= read -r -d '' entry; do
    case "$entry" in $'-\t-\t'*) printf '%s\0' "${entry#$'-\t-\t'}" ;; esac
  done
}

cmd_pre_push() {
  local remote=${1:-} url=${2:-} dest
  [ -n "$remote" ] || usage
  dest=$url
  if [ "$remote" = no-mistakes ] || [ -z "$dest" ]; then
    dest=$(origin_url) || dest=$url
  fi
  [ -n "$dest" ] || return 0
  if ! fm_pn_dest_is_public "$dest"; then
    cat >/dev/null
    return 0
  fi
  if ! require_current_list "this push"; then
    cat >/dev/null
    return 3
  fi
  scan_outgoing "$dest"
}

# Scan git pre-push ref lines on stdin bound for public <dest>: each pushed
# ref name and annotated tag message, then every commit <dest> does not
# already have - its message, added and renamed paths, added lines, and
# binary blob content. 0 clean, 1 a listed name or an unreadable destination.
scan_outgoing() {  # <dest>
  local dest=$1 local_sha remote_ref branch range commits rc=0 sha path remote_commit remote_refs known_shas=()
  remote_refs=$(git ls-remote "$dest" 2>/dev/null) || {
    cat >/dev/null
    echo "fm-private-names: cannot read public destination refs; refusing this push" >&2
    return 1
  }
  while read -r remote_commit _; do
    [ -n "$remote_commit" ] || continue
    git cat-file -e "$remote_commit^{commit}" 2>/dev/null && known_shas+=("$remote_commit")
  done <<<"$remote_refs"
  while read -r _ local_sha remote_ref _; do
    [ -n "${local_sha:-}" ] || continue
    case "$local_sha" in *[!0]*) ;; *) continue ;; esac
    branch=${remote_ref#refs/heads/}
    branch=${branch#refs/tags/}
    if ! printf '%s\n' "$branch" | report_hits "the pushed ref name"; then
      echo "fm-private-names: rename the branch before pushing, for example to: $(fm_pn_scrub_string "$branch")" >&2
      rc=1
    fi
    # An annotated tag carries its own message, which no commit check sees.
    sha=$local_sha
    while [ "$(git cat-file -t "$sha" 2>/dev/null)" = tag ]; do
      git cat-file tag "$sha" | report_hits "the tag object" || rc=1
      sha=$(git cat-file tag "$sha" | sed -n '1s/^object //p')
      [ -n "$sha" ] || {
        echo "fm-private-names: cannot read the outgoing tag chain; refusing" >&2
        return 1
      }
    done
    # A ref that ends at a blob or tree carries content no commit check sees.
    if [ "$(git cat-file -t "$sha" 2>/dev/null)" != commit ]; then
      echo "fm-private-names: refusing to push a ref that points at a blob or tree to a public repository" >&2
      rc=1
      continue
    fi
    range=("$local_sha" --not ${known_shas[@]+"${known_shas[@]}"})
    commits=$(git rev-list "${range[@]}" 2>/dev/null) || {
      echo "fm-private-names: cannot list the commits being pushed; refusing" >&2
      return 1
    }
    for sha in $commits; do
      if ! git cat-file commit "$sha" | report_hits "the object of commit ${sha:0:12}"; then
        rc=1
      fi
      # Only what this commit adds is judged: paths it adds, renames, or
      # copies, and the content of its added lines. Unchanged context lines,
      # diff headers, and the paths of files it only modifies or deletes are
      # existing tree, never outgoing content. One pass over the whole commit;
      # only a hit pays for the per-file pass that locates it.
      if ! { new_paths "$sha" | tr '\0' '\n'
        added_lines "$sha"; } | report_hits "commit ${sha:0:12}" 2>/dev/null; then
        rc=1
        while IFS= read -r -d '' path; do
          printf '%s\n' "$path" |
            report_hits "a file path added in commit ${sha:0:12} ($(fm_pn_scrub_string "$path"))" noline
        done < <(new_paths "$sha")
        while IFS= read -r -d '' path; do
          [ -n "$path" ] || continue
          added_lines "$sha" "$path" |
            report_hits "an added line of $(fm_pn_scrub_string "$path") in commit ${sha:0:12}" noline
        done < <(changed_paths "$sha" d)
      fi
      while IFS= read -r -d '' path; do
        if ! (set -o pipefail; git cat-file blob "$sha:$path" |
          report_hits "binary content of $(fm_pn_scrub_string "$path") in commit ${sha:0:12}" noline); then
          rc=1
        fi
      done < <(binary_paths "$sha")
    done
  done
  if [ "$rc" -ne 0 ]; then
    echo "fm-private-names: refusing this push to a public repository; replace the listed names with their neutral ids and amend the commits" >&2
  fi
  return "$rc"
}

# ------------------------------------------------------------ gh and gh-axi
#
# Allowlist, not denylist. Every gh or gh-axi call is classified first:
#   read        never publishes; runs unchanged
#   safe        changes state without publishing text or visibility; unchanged
#   write       a checked publishing form (gh_flag_kind lists its options)
#   visibility  repo create, new, fork, and edit; gh_publish_guard decides
#               on every destination
#   api         gh api; gh_api_guard
#   other       a known command with no checked form: runs only when the
#               destination is verified private
#   refuse      gists, projects, repo sync, issue transfer, codespace and
#               stack writes, aliases, extensions, and unknown commands
# On a public or unknown destination a write runs only when every option is
# listed for that form; its text values, field keys and values, file and stdin
# contents, and release asset basenames are scanned first, and the real tool
# then runs with stdin from the staged copy or /dev/null so it cannot prompt.

gh_class() {  # <command> <action>
  case "$1" in
    '' | help | version | completion | status | browse | search | auth | config | alias | org | \
    attestation | ruleset | co | setup | update | dashboard) echo read; return ;;
    api) echo api; return ;;
    gist | project | codespace | stack)
      case "$1 $2" in
        "gist list" | "gist view" | "gist clone" | "gist delete" | "project list" | "project view" | \
        "project field-list" | "project item-list" | "codespace list" | "codespace view" | "stack view") echo read ;;
        *) echo refuse ;;
      esac
      return
      ;;
    pr | issue | repo | release | run | workflow | label | secret | variable | cache | extension | \
    gpg-key | ssh-key) ;;
    *) echo refuse; return ;;
  esac
  [ -n "$2" ] || { echo read; return; }
  case "$1 $2" in
    "pr list" | "pr view" | "pr status" | "pr diff" | "pr checks" | "pr checkout" | \
    "issue list" | "issue view" | "issue status" | \
    "repo list" | "repo view" | "repo clone" | "repo set-default" | "repo gitignore" | "repo license" | \
    "release list" | "release view" | "release download" | "release verify" | "release verify-asset" | \
    "run list" | "run view" | "run watch" | "run download" | "workflow list" | "workflow view" | \
    "label list" | "cache list" | "secret list" | "variable list" | "variable get" | \
    "extension list" | "extension search" | "extension browse" | "extension install" | \
    "extension upgrade" | "extension remove" | "gpg-key list" | "ssh-key list") echo read ;;
    "pr ready" | "pr lock" | "pr unlock" | "pr update-branch" | "issue delete" | "issue lock" | \
    "issue unlock" | "issue pin" | "issue unpin" | "issue subissue" | "release delete" | \
    "release delete-asset" | "label delete" | "repo delete" | "repo archive" | "repo unarchive" | \
    "repo deploy-key" | "run rerun" | "run cancel" | "run delete" | "workflow enable" | \
    "workflow disable" | "cache delete" | "secret set" | "secret delete" | "variable set" | \
    "variable delete" | "gpg-key add" | "gpg-key delete" | "ssh-key add" | "ssh-key delete") echo safe ;;
    "pr create" | "pr new" | "pr edit" | "pr comment" | "pr review" | "pr merge" | "pr close" | \
    "pr reopen" | "issue create" | "issue new" | "issue edit" | "issue comment" | "issue close" | \
    "issue reopen" | "issue develop" | "release create" | "release new" | "release edit" | \
    "release upload" | "label create" | "label edit" | "repo rename" | "workflow run") echo write ;;
    "repo create" | "repo new" | "repo fork" | "repo edit") echo visibility ;;
    "repo sync" | "issue transfer") echo refuse ;;
    *) echo other ;;
  esac
}

# Kind of <option> in the checked form "<command> <action>": t a published
# text value, f a file path or - whose content is published, k a workflow
# field (key=value, or key=@file for -F), j workflow JSON read from stdin,
# d the destination repository, h its host, b a flag without a value, x text
# gh would collect where the shim cannot see it, u not part of the checked
# form. Long options may also be written --option=value.
gh_flag_kind() {  # <command> <action> <option>
  local o=$3
  case "$o" in
    -R | --repo) echo d; return ;;
    --hostname) echo h; return ;;
    --attach) echo x; return ;;
  esac
  case "$1 $2" in
    "pr create" | "pr new")
      case "$o" in
        -t | --title | -b | --body | -H | --head | -B | --base | -l | --label | -a | --assignee | \
        -r | --reviewer | -m | --milestone | -p | --project) echo t ;;
        -F | --body-file) echo f ;;
        -d | --draft | --no-maintainer-edit | --dry-run) echo b ;;
        -f | --fill | --fill-first | --fill-verbose | -e | --editor | -w | --web | -T | --template | --recover) echo x ;;
        *) echo u ;;
      esac ;;
    "pr edit")
      case "$o" in
        -t | --title | -b | --body | -B | --base | --add-label | --remove-label | --add-assignee | \
        --remove-assignee | --add-reviewer | --remove-reviewer | --add-project | --remove-project | \
        -m | --milestone) echo t ;;
        -F | --body-file) echo f ;;
        --remove-milestone) echo b ;;
        *) echo u ;;
      esac ;;
    "pr comment" | "issue comment")
      case "$o" in
        -b | --body) echo t ;;
        -F | --body-file) echo f ;;
        --edit-last | --create-if-none | --delete-last | --yes) echo b ;;
        -e | --editor | -w | --web) echo x ;;
        *) echo u ;;
      esac ;;
    "pr review")
      case "$o" in
        -b | --body) echo t ;;
        -F | --body-file) echo f ;;
        -a | --approve | -r | --request-changes | -c | --comment) echo b ;;
        *) echo u ;;
      esac ;;
    "pr merge")
      case "$o" in
        -t | --subject | -b | --body | -A | --author-email | --match-head-commit | --method) echo t ;;
        -F | --body-file) echo f ;;
        -s | --squash | -m | --merge | -r | --rebase | --auto | --disable-auto | -d | --delete-branch | --admin) echo b ;;
        *) echo u ;;
      esac ;;
    "pr close")
      case "$o" in
        -c | --comment) echo t ;;
        -d | --delete-branch) echo b ;;
        *) echo u ;;
      esac ;;
    "pr reopen" | "issue reopen")
      case "$o" in
        -c | --comment) echo t ;;
        *) echo u ;;
      esac ;;
    "issue create" | "issue new")
      case "$o" in
        -t | --title | -b | --body | -l | --label | -a | --assignee | -m | --milestone | -p | --project | --type) echo t ;;
        -F | --body-file) echo f ;;
        -e | --editor | -w | --web | -T | --template | --recover) echo x ;;
        *) echo u ;;
      esac ;;
    "issue edit")
      case "$o" in
        -t | --title | -b | --body | --add-label | --remove-label | --add-assignee | --remove-assignee | \
        --add-project | --remove-project | -m | --milestone | --type) echo t ;;
        -F | --body-file) echo f ;;
        --remove-milestone) echo b ;;
        *) echo u ;;
      esac ;;
    "issue close")
      case "$o" in
        -c | --comment | -r | --reason | --duplicate-of) echo t ;;
        *) echo u ;;
      esac ;;
    "issue develop")
      case "$o" in
        -n | --name | -b | --base) echo t ;;
        -c | --checkout | -l | --list) echo b ;;
        --branch-repo) echo x ;;
        *) echo u ;;
      esac ;;
    "release create" | "release new")
      case "$o" in
        -t | --title | -n | --notes | --body | --notes-start-tag | --target | --discussion-category) echo t ;;
        -F | --notes-file | --body-file) echo f ;;
        -d | --draft | -p | --prerelease | --generate-notes | --notes-from-tag | --verify-tag | \
        --fail-on-no-commits | --latest) echo b ;;
        *) echo u ;;
      esac ;;
    "release edit")
      case "$o" in
        --tag | -t | --title | -n | --notes | --body | --target | --discussion-category) echo t ;;
        -F | --notes-file | --body-file) echo f ;;
        --draft | --prerelease | --latest | --verify-tag) echo b ;;
        *) echo u ;;
      esac ;;
    "release upload")
      case "$o" in
        --clobber) echo b ;;
        *) echo u ;;
      esac ;;
    "label create")
      case "$o" in
        -c | --color | -d | --description | --name) echo t ;;
        -f | --force) echo b ;;
        *) echo u ;;
      esac ;;
    "label edit")
      case "$o" in
        -n | --name | -c | --color | -d | --description) echo t ;;
        *) echo u ;;
      esac ;;
    "repo edit")
      case "$o" in
        -d | --description | -h | --homepage | --add-topic | --remove-topic | --default-branch | --visibility) echo t ;;
        --enable-* | --allow-* | --delete-branch-on-merge | --template | --accept-visibility-change-consequences) echo b ;;
        *) echo u ;;
      esac ;;
    "repo create" | "repo new")
      case "$o" in
        -d | --description | -h | --homepage | --team | -g | --gitignore | -l | --license | --template | \
        -s | --source | -r | --remote) echo t ;;
        --public | --private | --internal | --push | -c | --clone | --include-all-branches | \
        --disable-issues | --disable-wiki | --add-readme) echo b ;;
        *) echo u ;;
      esac ;;
    "repo fork")
      case "$o" in
        --fork-name | --org | --remote-name) echo t ;;
        --clone | --remote | --default-branch-only) echo b ;;
        *) echo u ;;
      esac ;;
    "repo rename")
      case "$o" in
        -y | --yes) echo b ;;
        *) echo u ;;
      esac ;;
    "workflow run")
      case "$o" in
        -r | --ref) echo t ;;
        -f | --raw-field | -F | --field) echo k ;;
        --json) echo j ;;
        *) echo u ;;
      esac ;;
    *) echo u ;;
  esac
}

# Stage a text-file argument (a path, or - for stdin) as a private copy under
# GH_SHIM_TMP and print the copy's path.
gh_stage_file() {  # <path|-> <tag>
  local src=$1 copy=$GH_SHIM_TMP/$2
  if [ "$src" = - ]; then
    cat >"$copy" || return 1
  else
    [ -n "$src" ] && cat -- "$src" >"$copy" 2>/dev/null || return 1
  fi
  printf '%s\n' "$copy"
}

gh_shim_tmp() {
  [ -n "${GH_SHIM_TMP:-}" ] && return 0
  GH_SHIM_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-private-names-gh.XXXXXX") || return 1
  trap 'rm -rf "$GH_SHIM_TMP"' EXIT
}

# JSON helpers over a staged file, through JSON::PP. text prints every key and
# every scalar value (decoded) so they can be scanned; it fails on input that
# is not JSON. vis fails when a key named private, visibility, or public holds
# anything but an explicit private choice (private true, visibility private or
# internal, public false). private-choice succeeds only when such a choice is
# present.
gh_json() {  # <text|vis|private-choice> <file>
  perl -MJSON::PP -e '
    my $mode = shift; local $/; open my $fh, "<", shift or exit 2; my $raw = <$fh>;
    my $data = eval { JSON::PP->new->allow_nonref->decode($raw) }; exit 2 if $@;
    my ($bad, $choice) = (0, 0);
    sub flag { my ($k, $v) = @_; my $lk = lc $k;
      return unless $lk =~ /private|visibility|public/;
      my $sv = ref($v) eq "JSON::PP::Boolean" ? ($v ? "true" : "false") : lc(defined $v ? "$v" : "");
      if (($lk eq "private" && $sv eq "true") || ($lk eq "visibility" && $sv =~ /^(private|internal)$/)) { $choice = 1 }
      elsif ($lk eq "public" && $sv eq "false") { }
      else { $bad = 1 } }
    sub walk { my ($v) = @_;
      if (ref $v eq "HASH") { for my $k (sort keys %$v) { print "$k\n" if $mode eq "text"; flag($k, $v->{$k}); walk($v->{$k}) } }
      elsif (ref $v eq "ARRAY") { walk($_) for @$v }
      elsif (defined $v && $mode eq "text") { print ref($v) ? ($v ? "true" : "false") : "$v", "\n" } }
    walk($data);
    exit($bad ? 1 : 0) if $mode eq "vis";
    exit($choice ? 0 : 1) if $mode eq "private-choice";
    exit 0;
  ' "$1" "$2"
}

# 0 when the text holds a \uXXXX escape of an ASCII character, which a
# GraphQL string decodes into text the scan never saw.
has_unicode_ascii_escape() {
  perl -e 'local $/; my $text = <STDIN> // ""; while ($text =~ /\\u(?:\{([0-9a-fA-F]{1,6})\}|([0-9a-fA-F]{4}))/g) { exit 0 if hex($1 // $2) < 128 } exit 1'
}

# Number of executable operations in a GraphQL document on stdin.
graphql_operation_count() {
  perl -e '
    local $/; my $d = <STDIN> // "";
    $d =~ s/"""(?:\\"""|.)*?"""/""/gs; $d =~ s/"(?:\\.|[^"\\\n])*"/""/g; $d =~ s/#[^\n]*//g;
    my ($depth, $paren, $ops, $head) = (0, 0, 0, "");
    for my $c (split //, $d) {
      if ($depth == 0 && $c eq "(") { $paren++ } elsif ($depth == 0 && $c eq ")") { $paren-- if $paren }
      elsif ($paren == 0 && $c eq "{") { if ($depth == 0) { $ops++ unless $head =~ /^\s*fragment\b/; $head = "" } $depth++ }
      elsif ($paren == 0 && $c eq "}") { $depth-- if $depth }
      elsif ($depth == 0) { $head .= $c }
    }
    print "$ops\n";'
}

# Destination from a pull-request or issue URL or owner/repo#number target.
gh_target_repo() {  # <token>
  case "$1" in
    https://*/*/*/pull/* | https://*/*/*/issues/*)
      local t=${1%/pull/*}
      t=${t%/issues/*}
      printf '%s\n' "$t"
      ;;
    */*\#*) printf '%s\n' "${1%%#*}" ;;
    *) return 1 ;;
  esac
}

gh_same_repo() {  # <a> <b>
  local a=$1 b=$2
  case "$a" in https://*) a=${a#https://} ;; */*/*) ;; *) a=github.com/$a ;; esac
  case "$b" in https://*) b=${b#https://} ;; */*/*) ;; *) b=github.com/$b ;; esac
  [ "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')" ]
}

cmd_gh_shim() {
  local tool=${1:-} real
  [ -n "$tool" ] || usage
  shift
  real=$(fm_pn_real_bin "$tool") || {
    echo "fm-private-names: no real $tool found on PATH" >&2
    return 127
  }
  # Find the command and action, past any leading destination option.
  local args=("$@") n=$# i=0 token command='' action='' class
  while [ "$i" -lt "$n" ]; do
    token=${args[i]}
    case "$token" in
      --) break ;;
      -R | --repo | --hostname) i=$((i + 2)); continue ;;
      -R?* | --repo=* | --hostname=*) i=$((i + 1)); continue ;;
      -h | --help | --version | -v | -V)
        [ -n "$command" ] || exec "$real" "$@"
        i=$((i + 1))
        continue
        ;;
      -*)
        if [ -z "$command" ]; then
          echo "fm-private-names: refusing $tool with an unchecked leading option" >&2
          return 1
        fi
        i=$((i + 1))
        continue
        ;;
    esac
    if [ -z "$command" ]; then
      command=$token
      [ "$command" != api ] || break
    else
      action=$token
      break
    fi
    i=$((i + 1))
  done
  class=$(gh_class "$command" "$action")
  case "$class" in
    read | safe) exec "$real" "$@" ;;
    api) gh_api_guard "$tool" "$real" "$@"; return ;;
    refuse)
      echo "fm-private-names: refusing $tool $(fm_pn_scrub_string "$command${action:+ $action}"): not a checked form, so it could publish text or change visibility unseen" >&2
      return 1
      ;;
  esac
  gh_publish_guard "$tool" "$real" "$class" "$command" "$action" "$@"
}

# Guard one write, visibility, or other gh call (see gh_class).
gh_publish_guard() {  # <tool> <real> <class> <command> <action> <arg>...
  local tool=$1 real=$2 class=$3 command=$4 action=$5
  shift 5
  local args=("$@") n=$# i token option value prefix value_idx kind options=1 seen=0 copy key j
  local repo='' host='' target='' dest='' head='' visibility='' public=0 private_choice=0
  local positional=() texts=() text_idx=() text_prefix=() files=()
  local unknown=0 opaque=0 missing=0 has_title=0 has_body=0 has_notes=0 has_flag=0 no_text=0 json='' rc=0
  local ca="$command $action"
  gh_shim_tmp || return 1
  for ((i = 0; i < n; i++)); do
    token=${args[i]}
    if [ "$options" = 1 ] && [ "$token" = -- ]; then
      options=0
      continue
    fi
    if [ "$options" = 0 ] || [ "${token:0:1}" != - ] || [ "$token" = - ]; then
      if [ "$seen" -lt 2 ] && [ "$options" = 1 ]; then
        seen=$((seen + 1))
        continue
      fi
      positional+=("$i")
      continue
    fi
    option=$token prefix='' value='' value_idx=''
    case "$token" in
      --*=*) option=${token%%=*}; prefix=$option=; value=${token#*=}; value_idx=$i ;;
      --*) ;;
      -??*)
        option=${token:0:2}
        prefix=$option
        value=${token:2}
        if [ "${value:0:1}" = = ]; then
          prefix+='='
          value=${value#=}
        fi
        value_idx=$i
        ;;
    esac
    kind=$(gh_flag_kind "$command" "$action" "$option")
    case "$option" in
      --public) public=1 ;;
      --private | --internal) private_choice=1 ;;
    esac
    case "$kind" in
      u) unknown=1; continue ;;
      x) opaque=1; continue ;;
      j) json=1; continue ;;
      b)
        has_flag=1
        case "$ca:$option" in
          "pr review:-a" | "pr review:--approve" | *:--delete-last) no_text=1 ;;
          *:--generate-notes | *:--notes-from-tag) has_notes=1 ;;
        esac
        continue
        ;;
    esac
    if [ -z "$value_idx" ]; then
      value_idx=$((i + 1))
      if [ "$value_idx" -ge "$n" ]; then
        missing=1
        break
      fi
      value=${args[value_idx]}
      i=$value_idx
    fi
    case "$kind" in
      d) repo=$value ;;
      h) host=$value ;;
      t)
        has_flag=1
        text_idx+=("$value_idx")
        text_prefix+=("$prefix")
        case "$option" in
          -t | --title | --subject) [ "$ca" = "pr merge" ] || has_title=1 ;;
          -b | --body) case "$command" in release) has_notes=1 ;; *) has_body=1 ;; esac ;;
          -n | --notes) has_notes=1 ;;
          -H | --head) head=$value ;;
          --visibility) visibility=$value ;;
        esac
        ;;
      f)
        has_flag=1
        copy=$(gh_stage_file "$value" "file-$value_idx") || {
          echo "fm-private-names: cannot read the $command text file" >&2
          return 1
        }
        args[value_idx]=$prefix$copy
        files+=("$copy")
        if [ "$command" = release ]; then has_notes=1; else has_body=1; fi
        ;;
      k)
        case "$value" in
          *=*) ;;
          *) echo "fm-private-names: refusing a workflow field without key=value" >&2; return 1 ;;
        esac
        key=${value%%=*}
        texts+=("$key")
        j=${value#*=}
        if { [ "$option" = -F ] || [ "$option" = --field ]; } && [ "${j:0:1}" = @ ]; then
          copy=$(gh_stage_file "${j#@}" "field-$value_idx") || {
            echo "fm-private-names: cannot read the workflow field file" >&2
            return 1
          }
          args[value_idx]=$prefix$key=@$copy
          files+=("$copy")
        else
          texts+=("$j")
        fi
        ;;
    esac
  done
  if [ "$missing" = 1 ]; then
    echo "fm-private-names: missing $tool $command $action option value; refusing" >&2
    return 1
  fi

  # Visibility, on every destination.
  if [ "$class" = visibility ]; then
    case "$action" in
      create | new)
        if [ "$public" = 1 ] || [ "$private_choice" = 0 ]; then
          echo "fm-private-names: refusing $tool repo $action: only an explicit --private or --internal repository can be created from a fleet worker" >&2
          return 1
        fi
        "$real" "${args[@]}" </dev/null
        return
        ;;
      fork)
        target=
        [ -n "${positional[0]:-}" ] && target=${args[${positional[0]}]}
        [ -n "$target" ] || target=$(origin_url) || target=
        # Only a GitHub repository can be verified private; a local path cannot.
        case "$target" in /* | ./* | ../* | ~* | file://*) target= ;; */* | *:*) ;; *) target= ;; esac
        if [ "$unknown" = 1 ] || [ -z "$target" ] || [ "$(fm_pn_visibility "$target")" != private ]; then
          echo "fm-private-names: refusing $tool repo fork: only a fork of a verified private repository is allowed from a fleet worker" >&2
          return 1
        fi
        "$real" "${args[@]}" </dev/null
        return
        ;;
      edit)
        if [ -n "$visibility" ]; then
          case "$(printf '%s' "$visibility" | tr '[:upper:]' '[:lower:]')" in
            private | internal) ;;
            *)
              echo "fm-private-names: refusing to make a repository public from a fleet worker" >&2
              return 1
              ;;
          esac
        fi
        [ -n "${positional[0]:-}" ] && target=${args[${positional[0]}]}
        ;;
    esac
  fi

  # Destination.
  for i in "${positional[@]}"; do
    target=$(gh_target_repo "${args[i]}") && break
    target=
  done
  [ "$ca" = "repo edit" ] && [ -n "${positional[0]:-}" ] && target=${args[${positional[0]}]}
  if [ -n "$target" ] && [ -n "$repo" ] && ! gh_same_repo "$target" "$repo"; then
    case "$command" in pr) value=pull-request ;; *) value=$command ;; esac
    echo "fm-private-names: conflicting $value destinations; refusing" >&2
    return 1
  fi
  dest=$target
  [ -n "$dest" ] || dest=$repo
  if [ -n "$dest" ] && [ -n "$host" ]; then
    case "$dest" in https://* | */*/*) ;; *) dest=$host/$dest ;; esac
  fi
  [ -n "$dest" ] || dest=$(origin_url) || dest=
  if [ -n "$dest" ] && [ "$(fm_pn_visibility "$dest")" = private ]; then
    "$real" "${args[@]}"
    return
  fi

  # Public or unknown destination: only the checked forms run.
  if [ "$class" = other ]; then
    echo "fm-private-names: refusing $tool $command $action on a public or unknown repository: not a checked form" >&2
    return 1
  fi
  require_current_list "this $tool $command $action" || return 3
  if [ "$unknown" = 1 ]; then
    echo "fm-private-names: refusing unchecked $tool $command $action option on a public repository: it is not part of the checked form" >&2
    return 1
  fi
  if [ "$opaque" = 1 ]; then
    echo "fm-private-names: refusing unchecked $command text source (editor, browser, template, fill, or another repository) on a public repository" >&2
    return 1
  fi
  case "$ca" in
    "pr create" | "pr new" | "issue create" | "issue new")
      { [ "$has_title" = 1 ] && [ "$has_body" = 1 ]; } || {
        echo "fm-private-names: refusing $command creation: title and body must be supplied as checked arguments" >&2
        return 1
      } ;;
    "pr comment" | "issue comment" | "pr review")
      { [ "$has_body" = 1 ] || [ "$no_text" = 1 ]; } || {
        echo "fm-private-names: refusing interactive $command text" >&2
        return 1
      } ;;
    "pr edit" | "issue edit" | "repo edit")
      [ "$has_flag" = 1 ] || { echo "fm-private-names: refusing interactive $command text" >&2; return 1; } ;;
    "release create" | "release new")
      [ "$has_notes" = 1 ] || {
        echo "fm-private-names: refusing release creation: notes must be supplied as checked arguments or --generate-notes" >&2
        return 1
      } ;;
  esac
  if [ -z "$head" ] && { [ "$ca" = "pr create" ] || [ "$ca" = "pr new" ]; }; then
    head=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || head=
  fi
  if [ -n "$head" ] && ! printf '%s\n' "$head" | report_hits "the head branch name"; then
    echo "fm-private-names: refusing: the head branch name holds a listed private name; rename the branch, for example to: $(fm_pn_scrub_string "$head")" >&2
    return 1
  fi
  if [ -n "$json" ]; then
    json=$(gh_stage_file - workflow-json) || {
      echo "fm-private-names: cannot read workflow JSON input" >&2
      return 1
    }
    gh_json text "$json" >"$json.text" || {
      echo "fm-private-names: refusing workflow JSON input the shim cannot decode" >&2
      return 1
    }
    files+=("$json.text")
  fi
  local pos_rc=0
  for i in "${positional[@]}"; do
    printf '%s\n' "${args[i]}" | report_hits "the $command text" 2>/dev/null || pos_rc=1
  done
  for i in "${positional[@]}"; do
    token=${args[i]}
    case "$ca" in
      "release create" | "release new" | "release upload")
        # Assets after the tag: scan the file content, basename, and label.
        if [ "$i" != "${positional[0]}" ] && [ -f "${token%%#*}" ]; then
          value="release asset $(fm_pn_scrub_string "${token%%#*}")"
          report_hits "$value" noline <"${token%%#*}" || rc=1
          value=${token%%#*}
          texts+=("${value##*/}")
          case "$token" in *\#*) texts+=("${token#*#}") ;; esac
          continue
        fi
        ;;
    esac
    texts+=("$token")
  done
  for copy in "${files[@]}"; do
    report_hits "the $command text file" <"$copy" 2>/dev/null || rc=1
  done
  for j in "${texts[@]}"; do
    printf '%s\n' "$j" | report_hits "the $command text" 2>/dev/null || rc=1
  done
  for ((j = 0; j < ${#text_idx[@]}; j++)); do
    printf '%s\n' "${args[${text_idx[j]}]#"${text_prefix[j]}"}" | report_hits "the $command text" 2>/dev/null || rc=1
  done
  if [ "$rc" -ne 0 ]; then
    case "$ca" in
      "pr create" | "pr new" | "pr edit" | "pr comment" | "pr review" | "pr merge")
        if [ "${FM_PRIVATE_NAMES_MODE:-}" = rewrite ] && [ "$pos_rc" = 0 ]; then
          gh_rewrite_and_run
          return
        fi
        ;;
    esac
    for copy in "${files[@]}"; do
      report_hits "the $command text file" <"$copy"
    done
    for j in "${texts[@]}"; do
      printf '%s\n' "$j" | report_hits "the $command text"
    done
    for ((j = 0; j < ${#text_idx[@]}; j++)); do
      printf '%s\n' "${args[${text_idx[j]}]#"${text_prefix[j]}"}" | report_hits "the $command text"
    done
    case "$command" in
      pr) echo "fm-private-names: refusing $tool $command $action on a public repository; reword it, or rerun with FM_PRIVATE_NAMES_MODE=rewrite to rewrite names to neutral ids" >&2 ;;
      *) echo "fm-private-names: refusing $tool $command $action on a public repository; replace the listed names with their neutral ids" >&2 ;;
    esac
    return 1
  fi
  if [ -n "$json" ]; then
    "$real" "${args[@]}" <"$json"
  else
    "$real" "${args[@]}" </dev/null
  fi
}

# Rewrite mode for pull-request text: scrub every option value and staged file
# to neutral ids, then run the real tool. Uses the caller's args, text_idx,
# text_prefix, and files.
gh_rewrite_and_run() {
  local copy j
  for copy in "${files[@]}"; do
    if ! fm_pn_scrub_stream <"$copy" >"$copy.scrubbed" || ! mv "$copy.scrubbed" "$copy"; then
      return 1
    fi
  done
  for ((j = 0; j < ${#text_idx[@]}; j++)); do
    args[text_idx[j]]=${text_prefix[j]}$(fm_pn_scrub_string "${args[${text_idx[j]}]#"${text_prefix[j]}"}")
  done
  echo "fm-private-names: rewrote listed private names in the pull-request text to neutral ids" >&2
  "$real" "${args[@]}" </dev/null
}

# Guard gh api. Reads (GET or HEAD, or a GraphQL document with no mutation)
# run unchanged. A write is refused on every destination when it can change
# visibility or create a copy - a field or JSON key named private, visibility,
# or public that is not an explicit private choice, a repository create
# endpoint without one, a fork of a repository not verified private, a
# transfer or Pages endpoint, or a GraphQL mutation touching repositories or
# visibility. A write to a public or unknown destination then runs only in the
# fully parsed form: every option known, every field key and value, @file and
# @- content, and decoded --input JSON scanned; GraphQL with one operation and
# no ASCII \u escapes.
gh_api_guard() {  # <tool> <real> <arg>...
  local tool=$1 real=$2
  shift 2
  local args=("$@") n=$# i token option value prefix value_idx kind endpoint='' method='' host='' options=1 seen_api=0
  local keys=() vals=() plain=() files=() inputs=() headers=() docs=() rc=0 j copy ep owner repo rest sub dest='' write=0
  gh_shim_tmp || return 1
  for ((i = 0; i < n; i++)); do
    token=${args[i]}
    if [ "$options" = 1 ] && [ "$token" = -- ]; then
      options=0
      continue
    fi
    if [ "$options" = 0 ] || [ "${token:0:1}" != - ] || [ "$token" = - ]; then
      if [ "$seen_api" = 0 ] && [ "$token" = api ]; then
        seen_api=1
      elif [ -z "$endpoint" ] && [ "$seen_api" = 1 ]; then
        endpoint=$token
      else
        echo "fm-private-names: refusing $tool api with an unexpected argument" >&2
        return 1
      fi
      continue
    fi
    option=$token prefix='' value='' value_idx=''
    case "$token" in
      --*=*) option=${token%%=*}; prefix=$option=; value=${token#*=}; value_idx=$i ;;
      --*) ;;
      -??*)
        option=${token:0:2}; prefix=$option; value=${token:2}; value_idx=$i
        if [ "${value:0:1}" = = ]; then
          prefix+='='
          value=${value#=}
        fi
        ;;
    esac
    case "$option" in
      -X | --method | -f | --raw-field | -F | --field | --input | --hostname | -H | --header | \
      -q | --jq | -t | --template | --cache | -p | --preview) kind=v ;;
      -i | --include | --paginate | --slurp | --silent | --verbose) kind=b ;;
      *)
        echo "fm-private-names: refusing $tool api with an option outside its checked form" >&2
        return 1
        ;;
    esac
    if [ "$kind" = b ]; then
      [ -z "$value_idx" ] || {
        echo "fm-private-names: refusing $tool api with a value on a flag" >&2
        return 1
      }
      continue
    fi
    if [ -z "$value_idx" ]; then
      value_idx=$((i + 1))
      if [ "$value_idx" -ge "$n" ]; then
        echo "fm-private-names: missing $tool api option value; refusing" >&2
        return 1
      fi
      value=${args[value_idx]}
      i=$value_idx
    fi
    case "$option" in
      -X | --method) method=$(printf '%s' "$value" | tr '[:lower:]' '[:upper:]') ;;
      --hostname) host=$value ;;
      -H | --header) headers+=("$value") ;;
      -f | --raw-field | -F | --field)
        case "$value" in
          *=*) ;;
          *) echo "fm-private-names: refusing an api field without key=value" >&2; return 1 ;;
        esac
        keys+=("${value%%=*}")
        j=${value#*=}
        if { [ "$option" = -F ] || [ "$option" = --field ]; } && [ "${j:0:1}" = @ ]; then
          copy=$(gh_stage_file "${j#@}" "field-$value_idx") || {
            echo "fm-private-names: cannot read the api field file" >&2
            return 1
          }
          args[value_idx]=$prefix${value%%=*}=@$copy
          files+=("$copy")
          vals+=("@$copy")
          plain+=(0)
        else
          vals+=("$j")
          plain+=(1)
        fi
        ;;
      --input)
        copy=$(gh_stage_file "$value" "input-$value_idx") || {
          echo "fm-private-names: cannot read the api input" >&2
          return 1
        }
        args[value_idx]=$prefix$copy
        inputs+=("$copy")
        ;;
    esac
  done
  if [ -z "$endpoint" ]; then
    "$real" "${args[@]}"
    return
  fi
  ep=$endpoint
  case "$ep" in *://*) ep=${ep#*://}; ep=${ep#*/} ;; esac
  ep=${ep#/}
  ep=${ep#api/v3/}
  ep=${ep%%\?*}
  ep=${ep%/}
  ep=$(printf '%s' "$ep" | tr '[:upper:]' '[:lower:]')

  if [ "$ep" = graphql ]; then
    for ((j = 0; j < ${#keys[@]}; j++)); do
      [ "${keys[j]}" = query ] || continue
      if [ "${plain[j]}" = 1 ]; then
        printf '%s\n' "${vals[j]}" >"$GH_SHIM_TMP/doc-$j"
      else
        cp -- "${vals[j]#@}" "$GH_SHIM_TMP/doc-$j" || return 1
      fi
      docs+=("$GH_SHIM_TMP/doc-$j")
    done
    for copy in "${inputs[@]}"; do
      perl -MJSON::PP -e 'local $/; my $d = eval { decode_json(<STDIN>) }; exit 2 unless ref $d eq "HASH";
        print defined $d->{query} ? $d->{query} : ""' <"$copy" >"$copy.query" || {
        echo "fm-private-names: refusing GraphQL --input the shim cannot decode" >&2
        return 1
      }
      docs+=("$copy.query")
    done
    for copy in "${docs[@]}"; do
      grep -q 'mutation' "$copy" && write=1
    done
    if [ "$write" = 0 ]; then
      "$real" "${args[@]}"
      return
    fi
    for copy in "${docs[@]}" "${inputs[@]}" "${files[@]}"; do
      if grep -q -i -E 'visibility|private|public' "$copy" || grep -q -E '[a-z]Repository([^A-Za-z0-9_]|$)' "$copy"; then
        echo "fm-private-names: refusing a GraphQL mutation that touches repositories or visibility from a fleet worker" >&2
        return 1
      fi
    done
    for ((j = 0; j < ${#vals[@]}; j++)); do
      if printf '%s\n%s\n' "${keys[j]}" "${vals[j]}" | grep -q -i -E 'visibility|private|public'; then
        echo "fm-private-names: refusing a GraphQL mutation that touches repositories or visibility from a fleet worker" >&2
        return 1
      fi
    done
  else
    if [ -z "$method" ]; then
      if [ "${#keys[@]}" -gt 0 ] || [ "${#inputs[@]}" -gt 0 ]; then method=POST; else method=GET; fi
    fi
    case "$method" in GET | HEAD) ;; *) write=1 ;; esac
    for j in "${headers[@]}"; do
      printf '%s\n' "$j" | grep -q -i 'method-override' && write=1
    done
    if [ "$write" = 0 ]; then
      "$real" "${args[@]}"
      return
    fi
    # Visibility and copies, on every destination.
    owner='' repo='' sub=''
    case "$ep" in
      repos/*/*)
        rest=${ep#repos/}
        owner=${rest%%/*}
        rest=${rest#*/}
        repo=${rest%%/*}
        case "$rest" in */*) sub=${rest#*/}; sub=${sub%%/*} ;; esac
        ;;
    esac
    for ((j = 0; j < ${#keys[@]}; j++)); do
      case "$(printf '%s' "${keys[j]}" | tr '[:upper:]' '[:lower:]')" in
        *private* | *visibility* | *public*) ;;
        *) continue ;;
      esac
      if [ "${plain[j]}" = 1 ]; then
        case "$(printf '%s=%s' "${keys[j]}" "${vals[j]}" | tr '[:upper:]' '[:lower:]')" in
          private=true | visibility=private | visibility=internal | public=false) continue ;;
        esac
      fi
      echo "fm-private-names: refusing a gh api write that can make a repository or gist public from a fleet worker" >&2
      return 1
    done
    for copy in "${inputs[@]}"; do
      gh_json vis "$copy" 2>/dev/null
      case $? in
        0) ;;
        1)
          echo "fm-private-names: refusing a gh api write that can make a repository or gist public from a fleet worker" >&2
          return 1
          ;;
        *)
          if grep -q -i -E 'visibility|private|public' "$copy"; then
            echo "fm-private-names: refusing a gh api write that can make a repository or gist public from a fleet worker" >&2
            return 1
          fi
          ;;
      esac
    done
    case "$ep:$sub" in
      user/repos: | orgs/*/repos: | repos/*:generate)
        j=0
        for ((i = 0; i < ${#keys[@]}; i++)); do
          [ "${plain[i]}" = 1 ] || continue
          case "$(printf '%s=%s' "${keys[i]}" "${vals[i]}" | tr '[:upper:]' '[:lower:]')" in
            private=true | visibility=private | visibility=internal) j=1 ;;
          esac
        done
        for copy in "${inputs[@]}"; do
          gh_json private-choice "$copy" 2>/dev/null && j=1
        done
        if [ "$j" = 0 ]; then
          echo "fm-private-names: refusing gh api repository creation without an explicit private choice" >&2
          return 1
        fi
        ;;
      repos/*:forks)
        if [ "$owner" = '{owner}' ] || [ "$repo" = '{repo}' ] ||
          [ "$(fm_pn_visibility "${host:+$host/}$owner/$repo")" != private ]; then
          echo "fm-private-names: refusing gh api fork: only a fork of a verified private repository is allowed from a fleet worker" >&2
          return 1
        fi
        ;;
      repos/*:transfer | repos/*:pages | repositories/*)
        echo "fm-private-names: refusing a gh api repository transfer, Pages, or id-addressed write from a fleet worker" >&2
        return 1
        ;;
    esac
    if [ -n "$owner" ] && [ -n "$repo" ]; then
      if [ "$owner" = '{owner}' ] && [ "$repo" = '{repo}' ]; then
        dest=$(origin_url) || dest=
      elif [ "$owner" != '{owner}' ] && [ "$repo" != '{repo}' ]; then
        dest=${host:+$host/}$owner/$repo
        [ -n "$host" ] && [ "$host" != github.com ] || dest=$owner/$repo
      fi
    fi
    if [ -n "$dest" ] && [ "$(fm_pn_visibility "$dest")" = private ]; then
      "$real" "${args[@]}"
      return
    fi
  fi

  # Public or unknown destination: the fully parsed form only.
  require_current_list "this $tool api write" || return 3
  printf '%s\n' "$endpoint" | report_hits "the api endpoint" || rc=1
  for ((j = 0; j < ${#keys[@]}; j++)); do
    printf '%s\n' "${keys[j]}" | report_hits "an api field name" || rc=1
    [ "${plain[j]}" = 1 ] || continue
    printf '%s\n' "${vals[j]}" | report_hits "an api field" || rc=1
  done
  for copy in "${files[@]}"; do
    report_hits "an api field file" <"$copy" || rc=1
  done
  for copy in "${inputs[@]}"; do
    gh_json text "$copy" >"$copy.text" || {
      echo "fm-private-names: refusing api --input the shim cannot decode as JSON on a public destination" >&2
      return 1
    }
    report_hits "the api input" <"$copy.text" || rc=1
  done
  if [ "$ep" = graphql ]; then
    for copy in "${docs[@]}"; do
      if [ "$(graphql_operation_count <"$copy")" != 1 ]; then
        echo "fm-private-names: refusing a GraphQL document without exactly one operation" >&2
        return 1
      fi
    done
    for copy in "${docs[@]}" "${files[@]}"; do
      if has_unicode_ascii_escape <"$copy"; then
        echo "fm-private-names: refusing encoded GraphQL text on a public destination" >&2
        rc=1
      fi
    done
    for ((j = 0; j < ${#vals[@]}; j++)); do
      [ "${plain[j]}" = 1 ] || continue
      if printf '%s\n' "${vals[j]}" | has_unicode_ascii_escape; then
        echo "fm-private-names: refusing encoded GraphQL text on a public destination" >&2
        rc=1
      fi
    done
  fi
  if [ "$rc" -ne 0 ]; then
    echo "fm-private-names: refusing $tool api write to a public destination; replace the listed names with their neutral ids" >&2
    return 1
  fi
  "$real" "${args[@]}" </dev/null
}

cmd_no_mistakes_shim() {
  local real dest branch i arg check_branch=0 rc=0 run=0 has_no_publish=0
  local args=("$@") text_idx=()
  real=$(fm_pn_real_bin no-mistakes) || {
    echo "fm-private-names: no real no-mistakes found on PATH" >&2
    return 127
  }
  if [ "${args[0]:-}" = axi ]; then
    case "${args[1]:-}" in
      run) check_branch=1 run=1 ;;
      respond) check_branch=1 ;;
    esac
  fi
  # Every text the pipeline agent can carry into a commit or the PR body:
  # intent, PR title, fix instructions, operator-added findings, and reasons.
  for ((i = 0; i < ${#args[@]}; i++)); do
    arg=${args[i]}
    case "$arg" in
      --intent | --title | --pr-title | --instructions | --add-finding | --reason)
        text_idx+=("$((i + 1))"); check_branch=1 ;;
      --intent=* | --title=* | --pr-title=* | --instructions=* | --add-finding=* | --reason=*)
        text_idx+=("$i"); check_branch=1 ;;
      --no-publish-intent | --no-publish-intent=true) has_no_publish=1 ;;
    esac
  done
  [ "$check_branch" = 1 ] || exec "$real" "$@"
  dest=$(origin_url) || dest=
  [ -n "$dest" ] || exec "$real" "$@"
  fm_pn_dest_is_public "$dest" || exec "$real" "$@"
  require_current_list "this no-mistakes run" || return 3
  # A run for a public origin never publishes its intent in the PR body.
  if [ "$run" = 1 ] && [ "$has_no_publish" = 0 ]; then
    args+=(--no-publish-intent)
  fi
  for i in "${text_idx[@]}"; do
    printf '%s\n' "${args[i]:-}" | report_hits "the no-mistakes text" || rc=1
  done
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=
  if [ -n "$branch" ]; then
    printf '%s\n' "$branch" | report_hits "the current branch name" || rc=1
  fi
  [ "$rc" = 0 ] || return 1
  exec "$real" "${args[@]}"
}

# ---------------------------------------------------------------- pipeline gate

# The no-mistakes pipeline commits its own fixes and pushes from a run
# worktree outside every worker hook, so this gate runs inside that worktree
# after lint, before the push step. It finds the homes registered for this
# gate (see register_gates) and checks, against each home's list, everything
# the push would newly expose plus the not-yet-committed changes the push
# step will commit. A hit parks the run with neutral ids only.
cmd_gate() {
  local common id file rc=0 out home config state data projects
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
    echo "fm-private-names: the gate must run inside a git worktree" >&2
    return 1
  }
  id=$(gate_id "$common")
  file=$(fm_pn_gate_index)/$id
  if [ ! -f "$file" ]; then
    echo "fm-private-names: no firstmate home on this machine pushes through this gate; nothing to check"
    return 0
  fi
  out=$(
    while IFS=$'\t' read -r home config state data projects || [ -n "$home" ]; do
      [ -n "$home" ] || continue
      FM_HOME=$home FM_CONFIG_OVERRIDE=$config FM_STATE_OVERRIDE=$state \
        FM_DATA_OVERRIDE=$data FM_PROJECTS_OVERRIDE=$projects "$0" gate-check 2>&1 || echo "rc=$?"
    done <"$file"
  )
  case "$out" in *rc=*) rc=1 ;; esac
  out=$(printf '%s\n' "$out" | grep -v '^rc=')
  [ -z "$out" ] || printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] && return 0
  if [ -n "${NO_MISTAKES_FINDINGS_FILE:-}" ]; then
    printf '%s\n' "$out" | perl -MJSON::PP -e '
      local $/; my $text = <STDIN>; $text =~ s/\s+\z//;
      $text = "fm-private-names: the private-name check could not complete" if $text eq "";
      print JSON::PP->new->canonical->encode({ findings => [ {
        id => "private-names", severity => "error", action => "ask-user",
        description => "Listed private names (neutral ids below) would be published by this push; replace them with their neutral ids:\n$text" } ] });
    ' >"$NO_MISTAKES_FINDINGS_FILE" && return 0
  fi
  return 1
}

# One home's check for cmd_gate, with that home's paths in the environment.
cmd_gate_check() {
  local dest branch sha rc=0 path label
  dest=$(origin_url) || dest=
  [ -n "$dest" ] || return 0
  fm_pn_dest_is_public "$dest" || return 0
  require_current_list "this pipeline push" || return 3
  sha=$(git rev-parse -q --verify HEAD) || return 1
  branch=$(git symbolic-ref --short -q HEAD) || branch=
  printf 'HEAD %s refs/heads/%s %s\n' "$sha" "${branch:-HEAD}" "$ZERO_SHA" |
    scan_outgoing "$dest" || rc=1
  # The identity the push step commits pending changes under.
  { git var GIT_AUTHOR_IDENT; git var GIT_COMMITTER_IDENT; } 2>/dev/null |
    report_hits "the commit identity" noline || rc=1
  # Uncommitted changes the push step will commit, staged or not: added lines,
  # added or renamed paths, and untracked files with their content.
  {
    git diff --no-color --no-ext-diff --unified=0 HEAD
    git diff --cached --no-color --no-ext-diff --unified=0 HEAD
  } | awk '/^diff / { header = 1; next } /^@@/ { header = 0; next } !header && /^\+/ { print substr($0, 2) }' |
    report_hits "an uncommitted change" noline || rc=1
  {
    git diff --name-only -z -M --diff-filter=ACR HEAD
    git diff --cached --name-only -z -M --diff-filter=ACR HEAD
  } | tr '\0' '\n' | report_hits "an uncommitted file path" noline || rc=1
  while IFS= read -r -d '' path; do
    label="uncommitted binary content of $(fm_pn_scrub_string "$path")"
    report_hits "$label" noline <"$path" || rc=1
  done < <(git diff --numstat --no-renames --diff-filter=AM -z HEAD |
    while IFS= read -r -d '' path; do
      case "$path" in $'-\t-\t'*) printf '%s\0' "${path#$'-\t-\t'}" ;; esac
    done)
  while IFS= read -r -d '' path; do
    label="staged binary content of $(fm_pn_scrub_string "$path")"
    (set -o pipefail; git show ":$path" | report_hits "$label" noline) || rc=1
  done < <(git diff --cached --numstat --no-renames --diff-filter=AM -z HEAD |
    while IFS= read -r -d '' path; do
      case "$path" in $'-\t-\t'*) printf '%s\0' "${path#$'-\t-\t'}" ;; esac
    done)
  while IFS= read -r -d '' path; do
    printf '%s\n' "$path" | report_hits "an untracked file path" noline || rc=1
    label="untracked file $(fm_pn_scrub_string "$path")"
    report_hits "$label" noline <"$path" || rc=1
  done < <(git ls-files --others --exclude-standard -z)
  return "$rc"
}

CMD=${1:-}
[ "$#" -gt 0 ] && shift
case "$CMD" in
  refresh) cmd_refresh "$@" ;;
  check) cmd_check "$@" ;;
  scrub) cmd_scrub "$@" ;;
  commit-msg) cmd_commit_msg "$@" ;;
  pre-push) cmd_pre_push "$@" ;;
  gh-shim) cmd_gh_shim "$@" ;;
  no-mistakes-shim) cmd_no_mistakes_shim "$@" ;;
  gate) cmd_gate "$@" ;;
  gate-check) cmd_gate_check "$@" ;;
  -h | --help | '') usage ;;
  *) usage ;;
esac
