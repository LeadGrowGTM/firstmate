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
#       PATH shim for gh and gh-axi. Against a public repository it scans,
#       before the real tool runs: pull-request titles, bodies, labels, merge
#       subjects, body files and stdin, and the head branch (pr create, new,
#       edit, comment, review, merge); every argument and text file of pr close
#       and reopen, issue create, edit, comment, close, reopen, and develop,
#       release create, edit, and upload (assets by content), label create and
#       edit, repo create, edit, rename, and fork, and workflow run; and the
#       endpoint, fields, field files, and --input of gh api writes (a method
#       other than GET or HEAD, fields or input without one, or a GraphQL
#       mutation). Text from an editor, browser, prompt, template, or
#       attachment is refused, as is making a repository public; the
#       destination and file paths are not judged; read-only commands run
#       unchanged.
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
# Worker launches also get a git shim that refuses git push --no-verify and a
# push under another core.hooksPath (bin/fm-git-strip-ai-trailers.sh writes it).
# Accepted residual: a process that runs git or gh by absolute path, rewrites
# the git environment, or calls the GitHub API directly is not seen, and text
# the no-mistakes pipeline writes after its gate (the push step's commit subject
# and the PR text it drafts) is read back by bin/fm-private-names-scrub.sh
# after creation, as a backstop only.
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
    while IFS= read -r line; do
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
  while IFS= read -r line; do
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

cmd_refresh() {
  [ "$#" -eq 0 ] || usage
  local out=$FM_PN_LIST tmp derived parent
  mkdir -p "$(dirname "$out")" 2>/dev/null || return 1
  # A second mate home on this machine also takes its primary's whole list, so
  # every home refuses the same names. The list is read from disk rather than
  # pushed as inherited config, which would paste it into the mate's context.
  parent=
  if fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" 2>/dev/null &&
    [ "$FM_SECONDMATE_PARENT_ROUTE" = local ]; then
    parent=$FM_SECONDMATE_PARENT_HOME
  fi
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
  register_gates || {
    echo "fm-private-names: cannot record this home for its no-mistakes gates" >&2
    return 1
  }
  echo "private-names: $(fm_pn_count) names in config/private-names"
}

# Record this home against every local no-mistakes gate its clones push
# through, so the pipeline's own private-names gate (see cmd_gate) finds this
# home's list from the gate's run worktree, which carries no FM_HOME. One file
# per gate id, one tab-separated "home config state data projects" line per
# home; a home rewrites only its own line.
register_gates() {
  local index dir url id file tmp line
  index=$(fm_pn_gate_index) || return 1
  [ -d "$PROJECTS" ] || return 0
  line=$(printf '%s\t%s\t%s\t%s\t%s' "$(abs_dir "$FM_HOME")" "$(abs_dir "$CONFIG")" \
    "$(abs_dir "$STATE")" "$(abs_dir "$DATA")" "$(abs_dir "$PROJECTS")")
  for dir in "$PROJECTS"/*/; do
    [ -d "$dir" ] || continue
    url=$(git -C "$dir" remote get-url no-mistakes 2>/dev/null) || continue
    case "$url" in /*.git) ;; *) continue ;; esac
    [ -d "$url" ] || continue
    id=${url%.git}
    id=${id##*/}
    case "$id" in '' | *[!A-Za-z0-9_-]*) continue ;; esac
    mkdir -p "$index" && chmod 700 "$index" 2>/dev/null || return 1
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
    while IFS= read -r line; do
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
    git diff --name-only -M -C --diff-filter="$2" "$1^" "$1"
  else
    git diff-tree --root --no-commit-id --name-only -r -M -C --diff-filter="$2" "$1"
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
      git cat-file tag "$sha" | sed '1,/^$/d' | report_hits "the tag message" || rc=1
      sha=$(git cat-file tag "$sha" | sed -n '1s/^object //p')
      [ -n "$sha" ] || {
        echo "fm-private-names: cannot read the outgoing tag chain; refusing" >&2
        return 1
      }
    done
    range=("$local_sha" --not "${known_shas[@]}")
    commits=$(git rev-list "${range[@]}" 2>/dev/null) || {
      echo "fm-private-names: cannot list the commits being pushed; refusing" >&2
      return 1
    }
    for sha in $commits; do
      if ! git log -1 --format=%B "$sha" | report_hits "the message of commit ${sha:0:12}"; then
        rc=1
      fi
      # Only what this commit adds is judged: paths it adds, renames, or
      # copies, and the content of its added lines. Unchanged context lines,
      # diff headers, and the paths of files it only modifies or deletes are
      # existing tree, never outgoing content. One pass over the whole commit;
      # only a hit pays for the per-file pass that locates it.
      if ! { new_paths "$sha"
        added_lines "$sha"; } | report_hits "commit ${sha:0:12}" 2>/dev/null; then
        rc=1
        while IFS= read -r path; do
          printf '%s\n' "$path" |
            report_hits "a file path added in commit ${sha:0:12} ($(fm_pn_scrub_string "$path"))" noline
        done < <(new_paths "$sha")
        while IFS= read -r path; do
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

# ---------------------------------------------------------------- gh shim

cmd_gh_shim() {
  local tool=${1:-} real
  [ -n "$tool" ] || usage
  shift
  real=$(fm_pn_real_bin "$tool") || {
    echo "fm-private-names: no real $tool found on PATH" >&2
    return 127
  }
  local args=("$@") i=0 n=$# repo='' head='' body_file_idx=() body_file_prefix=() text_idx=() text_prefix=() dest action='' command='' target='' target_repo='' repo_id='' target_id=''
  local has_title=0 has_body=0 has_edit_option=0 no_text_action=0 opaque=0 missing_value=0
  local token option value prefix value_idx takes_value options=1
  for ((i = 0; i < n; i++)); do
    token=${args[i]}
    if [ "$options" = 1 ] && [ "$token" = -- ]; then
      options=0
      continue
    fi
    option='' prefix='' value='' value_idx=$i takes_value=0
    if [ "$options" = 1 ]; then
      case "$token" in
        --*=*) option=${token%%=*}; prefix=$option=; value=${token#*=} ;;
        --*) option=$token ;;
        -?*)
          option=${token:0:2}
          value=${token:2}
          if [ -n "$value" ]; then
            prefix=$option
            if [ "${value:0:1}" = = ]; then
              prefix+='='
              value=${value#=}
            fi
          fi
          ;;
      esac
    fi
    if [ -z "$option" ]; then
      if [ -z "$command" ]; then
        command=$token
      elif [ -z "$action" ]; then
        action=$token
      elif [ -z "$target" ]; then
        target=$token
      fi
      continue
    fi
    case "$option" in
      --repo | -R | --head | -H | --body-file | -F | --title | -t | --body | -b | \
      --subject | --label | -l | --add-label | --remove-label | --base | -B | \
      --assignee | --add-assignee | --remove-assignee | --reviewer | --add-reviewer | --remove-reviewer | \
      --milestone | --project | -p | --add-project | --remove-project | \
      --template | -T | --recover | --author-email | -A | --match-head-commit | --attach)
        takes_value=1
        ;;
      -a | -r) [ "$action" != create ] || takes_value=1 ;;
      -m) [ "$action" != create ] && [ "$action" != edit ] || takes_value=1 ;;
    esac
    if [ "$takes_value" = 1 ] && [ -z "$prefix" ]; then
      value_idx=$((i + 1))
      value=${args[value_idx]:-}
    fi
    if [ "$takes_value" = 1 ] && [ "$value_idx" -ge "$n" ]; then
      missing_value=1
    fi
    case "$option" in
      --repo | -R) repo=$value ;;
      --head | -H) head=$value ;;
      --body-file | -F) body_file_idx+=("$value_idx"); body_file_prefix+=("$prefix"); has_body=1 ;;
      --title | -t) text_idx+=("$value_idx"); text_prefix+=("$prefix"); has_title=1 ;;
      --body | -b) text_idx+=("$value_idx"); text_prefix+=("$prefix"); has_body=1 ;;
      --subject | --label | -l | --add-label)
        text_idx+=("$value_idx"); text_prefix+=("$prefix"); has_edit_option=1 ;;
      --remove-label | --base | -B | --assignee | --add-assignee | --remove-assignee | \
      --reviewer | --add-reviewer | --remove-reviewer | --milestone | -m | --remove-milestone | \
      --project | -p | --add-project | --remove-project) has_edit_option=1 ;;
      --approve | --delete-last) no_text_action=1 ;;
      -a) [ "$action" != review ] || no_text_action=1 ;;
      --template | -T | --fill | -f | --fill-first | --fill-verbose | --recover | --editor | -e | --web | -w | --attach) opaque=1 ;;
    esac
    [ "$takes_value" = 0 ] || [ -n "$prefix" ] || i=$((i + 1))
  done
  if [ "$command" = api ]; then
    gh_api_guard "$tool" "$real" "$@"
    return
  fi
  if [ "$command" = pr ]; then
    case "$action" in
      create | new | edit | comment | review | merge) ;;
      close | reopen) gh_write_guard "$tool" "$real" "$command" "$action" "$@"; return ;;
      *) exec "$real" "$@" ;;
    esac
  elif gh_writes_text "$command" "$action"; then
    gh_write_guard "$tool" "$real" "$command" "$action" "$@"
    return
  else
    exec "$real" "$@"
  fi
  case "$target" in
    https://*/*/*/pull/*)
      case "${target##*/}" in '' | *[!0-9]*) ;; *) target_repo=${target%/pull/*} ;; esac
      ;;
    */*\#*)
      case "${target#*#}" in '' | *[!0-9]*) ;; *) target_repo=${target%#*} ;; esac
      ;;
  esac
  if [ -n "$target_repo" ] && [ -n "$repo" ]; then
    case "$repo" in
      https://*) repo_id=${repo#https://} ;;
      */*/*) repo_id=$repo ;;
      *) repo_id=github.com/$repo ;;
    esac
    case "$target_repo" in
      https://*) target_id=${target_repo#https://} ;;
      */*/*) target_id=$target_repo ;;
      *) target_id=github.com/$target_repo ;;
    esac
    if [ "${repo_id,,}" != "${target_id,,}" ]; then
      echo "fm-private-names: conflicting pull-request destinations; refusing" >&2
      return 1
    fi
  fi
  dest=$target_repo
  [ -n "$dest" ] || dest=$repo
  [ -n "$dest" ] || dest=$(origin_url) || dest=
  if [ -n "$dest" ] && ! fm_pn_dest_is_public "$dest"; then
    exec "$real" "$@"
  fi
  require_current_list "this pull-request text" || return 3
  if [ "$missing_value" = 1 ]; then
    echo "fm-private-names: missing pull-request option value; refusing" >&2
    return 1
  fi
  if [ "$opaque" = 1 ]; then
    echo "fm-private-names: refusing unchecked pull-request text source" >&2
    return 1
  fi
  case "$action" in
    create | new)
      if [ "$has_title" = 0 ] || [ "$has_body" = 0 ]; then
        echo "fm-private-names: refusing PR creation: title and body must be supplied as checked arguments" >&2
        return 1
      fi
      ;;
    comment | review)
      if [ "$has_body" = 0 ] && [ "$no_text_action" = 0 ]; then
        echo "fm-private-names: refusing interactive pull-request text" >&2
        return 1
      fi
      ;;
    edit)
      if [ "$has_title" = 0 ] && [ "$has_body" = 0 ] && [ "$has_edit_option" = 0 ]; then
        echo "fm-private-names: refusing interactive pull-request text" >&2
        return 1
      fi
      ;;
  esac
  if [ -z "$head" ] && { [ "$action" = create ] || [ "$action" = new ]; }; then
    head=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || head=
  fi

  # Stage stdin and body files as private temp copies so they are scanned and,
  # in rewrite mode, replaced by their scrubbed copy.
  local idx src copy rc=0 copies=() j
  GH_SHIM_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-private-names-gh.XXXXXX") || return 1
  trap 'rm -rf "$GH_SHIM_TMP"' EXIT
  for ((j = 0; j < ${#body_file_idx[@]}; j++)); do
    idx=${body_file_idx[j]}
    prefix=${body_file_prefix[j]}
    src=${args[idx]:-}
    src=${src#"$prefix"}
    copy=$GH_SHIM_TMP/body-$idx
    if [ "$src" = - ]; then
      cat >"$copy" || return 1
    else
      cat -- "$src" >"$copy" 2>/dev/null || {
        echo "fm-private-names: cannot read the body file" >&2
        return 1
      }
    fi
    args[idx]=$prefix$copy
    copies+=("$copy")
    report_hits "the pull-request body file" <"$copy" 2>/dev/null || rc=1
  done
  for ((j = 0; j < ${#text_idx[@]}; j++)); do
    idx=${text_idx[j]}
    printf '%s\n' "${args[idx]#"${text_prefix[j]}"}" | report_hits "the pull-request text" 2>/dev/null || rc=1
  done
  if [ -n "$head" ] && ! printf '%s\n' "$head" | report_hits "the head branch name"; then
    echo "fm-private-names: refusing: the head branch name holds a listed private name; rename the branch, for example to: $(fm_pn_scrub_string "$head")" >&2
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    if [ "${FM_PRIVATE_NAMES_MODE:-}" != rewrite ]; then
      for copy in "${copies[@]}"; do
        report_hits "the pull-request body file" <"$copy"
      done
      for ((j = 0; j < ${#text_idx[@]}; j++)); do
        idx=${text_idx[j]}
        printf '%s\n' "${args[idx]#"${text_prefix[j]}"}" | report_hits "the pull-request text"
      done
      echo "fm-private-names: refusing $tool pr $action on a public repository; reword it, or rerun with FM_PRIVATE_NAMES_MODE=rewrite to rewrite names to neutral ids" >&2
      return 1
    fi
    for copy in "${copies[@]}"; do
      if ! fm_pn_scrub_stream <"$copy" >"$copy.scrubbed" || ! mv "$copy.scrubbed" "$copy"; then
        return 1
      fi
    done
    for ((j = 0; j < ${#text_idx[@]}; j++)); do
      idx=${text_idx[j]}
      args[idx]=${text_prefix[j]}$(fm_pn_scrub_string "${args[idx]#"${text_prefix[j]}"}")
    done
    echo "fm-private-names: rewrote listed private names in the pull-request text to neutral ids" >&2
  fi
  "$real" "${args[@]}"
}

# gh commands other than the PR text paths above that publish text to a
# repository: issues, releases, labels, repository settings, and workflow
# inputs. Read-only commands are not listed and run unchanged.
gh_writes_text() {  # <command> <action>
  case "$1 $2" in
    "issue create" | "issue new" | "issue edit" | "issue comment" | "issue close" | \
    "issue reopen" | "issue develop" | \
    "release create" | "release new" | "release edit" | "release upload" | \
    "label create" | "label edit" | \
    "repo create" | "repo new" | "repo edit" | "repo rename" | "repo fork" | \
    "workflow run") return 0 ;;
  esac
  return 1
}

# Stage a text-file argument (a path, or - for stdin) as a private copy under
# GH_SHIM_TMP and print the copy's path.
gh_stage_file() {  # <path|-> <tag>
  local src=$1 copy=$GH_SHIM_TMP/$2
  if [ "$src" = - ]; then
    cat >"$copy" || return 1
  else
    cat -- "$src" >"$copy" 2>/dev/null || return 1
  fi
  printf '%s\n' "$copy"
}

gh_shim_tmp() {
  [ -n "${GH_SHIM_TMP:-}" ] && return 0
  GH_SHIM_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-private-names-gh.XXXXXX") || return 1
  trap 'rm -rf "$GH_SHIM_TMP"' EXIT
}

# Guard one text-writing gh command (see gh_writes_text, plus pr close and
# reopen comments). On a public destination every argument except the
# destination and file paths is scanned, text files and release assets are
# scanned by content, text gh would collect in an editor, browser, or prompt
# is refused, and the real tool runs only when nothing matched. Never rewrites.
gh_write_guard() {  # <tool> <real> <command> <action> <arg>...
  local tool=$1 real=$2 command=$3 action=$4
  shift 4
  local args=("$@") n=$# i token option value prefix value_idx options=1 dest='' target='' rc=0 takes_value
  local positional=() texts=() files=() opaque=0 has_title=0 has_body=0 has_notes=0 has_flag=0
  local visibility='' make_public=0 copy j workflow_json=''
  gh_shim_tmp || return 1
  for ((i = 0; i < n; i++)); do
    token=${args[i]}
    if [ "$options" = 1 ] && [ "$token" = -- ]; then
      options=0
      continue
    fi
    if [ "$options" = 0 ] || [ "${token:0:1}" != - ] || [ "$token" = - ]; then
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
    takes_value=0
    case "$option" in
      -R | --repo | -F | --body-file | --notes-file | -t | --title | -b | --body | -n | --notes | \
      --comment | --description | -l | --label | --add-label | --remove-label | \
      -a | --assignee | --add-assignee | --remove-assignee | -m | --milestone | --project | \
      --add-project | --remove-project | --target | --discussion-category | --notes-start-tag | \
      --name | --base | -B | --branch-repo | --color | -f | --raw-field | --field | -r | --ref | \
      --visibility | --homepage | --fork-name | --org | --default-branch | --source | --remote | \
      --license | --gitignore | --team | --template | --add-topic | --remove-topic | --reason)
        takes_value=1 ;;
      -c) [ "$command" = release ] || takes_value=1 ;;
      -d) case "$command" in label | repo) takes_value=1 ;; esac ;;
      -p) [ "$command" != issue ] || takes_value=1 ;;
    esac
    if [ "$takes_value" = 1 ] && [ -z "$value_idx" ]; then
      value_idx=$((i + 1))
      value=${args[value_idx]:-}
      i=$value_idx
    fi
    [ "$option" = -R ] || [ "$option" = --repo ] || has_flag=1
    case "$option" in
      -R | --repo) dest=$value; continue ;;
      -F | --body-file | --notes-file)
        if [ "$command $action" = "workflow run" ] && [ "$option" = -F ]; then
          case "$value" in
            *=@*)
              copy=$(gh_stage_file "${value#*=@}" "field-$value_idx") || {
                echo "fm-private-names: cannot read the workflow field file" >&2
                return 1
              }
              args[value_idx]=$prefix${value%%=*}=@$copy
              files+=("$copy")
              texts+=("${value%%=*}")
              continue
              ;;
          esac
          texts+=("$value")
          continue
        fi
        copy=$(gh_stage_file "$value" "file-$value_idx") || {
          echo "fm-private-names: cannot read the text file" >&2
          return 1
        }
        args[value_idx]=$prefix$copy
        files+=("$copy")
        if [ "$option" = --notes-file ] || [ "$command" = release ]; then
          has_notes=1
        else
          has_body=1
        fi
        continue
        ;;
      -t | --title) has_title=1 ;;
      -b | --body) has_body=1 ;;
      -n | --notes | --generate-notes | --notes-from-tag) has_notes=1 ;;
      --visibility) visibility=$value ;;
      --json)
        if [ "$command $action" = "workflow run" ]; then
          workflow_json=$(gh_stage_file - workflow-json) || {
            echo "fm-private-names: cannot read workflow JSON input" >&2
            return 1
          }
          files+=("$workflow_json")
        fi
        ;;
      --public) visibility=public ;;
      --private) visibility=private ;;
      --internal) visibility=internal ;;
      -e | --editor | -w | --web | -T | --recover | --attach | --edit-last) opaque=1 ;;
      --template) [ "$command" = repo ] || opaque=1 ;;
    esac
    [ -n "$value_idx" ] && texts+=("${args[value_idx]#"$prefix"}")
    texts+=("$option")
  done
  case "$command $action" in
    "repo edit") [ "$visibility" = public ] && make_public=1 ;;
  esac
  if [ "$make_public" = 1 ]; then
    echo "fm-private-names: refusing to make a repository public from a fleet worker" >&2
    return 1
  fi
  for i in "${positional[@]}"; do
    token=${args[i]}
    case "$token" in
      https://*/*/*/pull/* | https://*/*/*/issues/*) target=${token%/pull/*}; target=${target%/issues/*} ;;
      */*\#*) target=${token%#*} ;;
    esac
  done
  case "$command $action" in
    "repo create" | "repo new")
      [ -n "${positional[0]:-}" ] && target=${args[${positional[0]}]}
      if [ "$visibility" != public ]; then
        "$real" "${args[@]}"
        return
      fi
      ;;
    "repo edit" | "repo rename" | "repo fork")
      [ "$action" = edit ] && [ -n "${positional[0]:-}" ] && case "${args[${positional[0]}]}" in */*) target=${args[${positional[0]}]} ;; esac
      ;;
  esac
  if [ -n "$target" ]; then
    dest=$target
  elif [ -z "$dest" ]; then
    dest=$(origin_url) || dest=
  fi
  if [ -n "$dest" ] && [ "$command $action" != "repo create" ] && [ "$command $action" != "repo new" ] &&
    ! fm_pn_dest_is_public "$dest"; then
    if [ -n "$workflow_json" ]; then
      "$real" "${args[@]}" <"$workflow_json"
    else
      "$real" "${args[@]}"
    fi
    return
  fi
  require_current_list "this $tool $command $action" || return 3
  if [ "$opaque" = 1 ]; then
    echo "fm-private-names: refusing unchecked $command text source (editor, browser, template, or attachment) on a public repository" >&2
    return 1
  fi
  case "$command $action" in
    "issue create" | "issue new")
      { [ "$has_title" = 1 ] && [ "$has_body" = 1 ]; } || {
        echo "fm-private-names: refusing issue creation: title and body must be supplied as checked arguments" >&2
        return 1
      } ;;
    "issue comment")
      [ "$has_body" = 1 ] || { echo "fm-private-names: refusing interactive issue text" >&2; return 1; } ;;
    "issue edit" | "repo edit")
      [ "$has_flag" = 1 ] || { echo "fm-private-names: refusing interactive $command text" >&2; return 1; } ;;
    "release create" | "release new")
      [ "$has_notes" = 1 ] || {
        echo "fm-private-names: refusing release creation: notes must be supplied as checked arguments or --generate-notes" >&2
        return 1
      } ;;
  esac
  for i in "${positional[@]}"; do
    token=${args[i]}
    case "$command $action" in
      "release create" | "release new" | "release upload")
        # Assets after the tag: scan the file content and any display label.
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
    report_hits "the $command text file" <"$copy" || rc=1
  done
  for j in "${texts[@]}"; do
    printf '%s\n' "$j" | report_hits "the $command text" || rc=1
  done
  if [ "$rc" -ne 0 ]; then
    echo "fm-private-names: refusing $tool $command $action on a public repository; replace the listed names with their neutral ids" >&2
    return 1
  fi
  if [ -n "$workflow_json" ]; then
    "$real" "${args[@]}" <"$workflow_json"
  else
    "$real" "${args[@]}"
  fi
}

# Guard gh api. A write - a method other than GET or HEAD, fields or --input
# without a method, or a GraphQL mutation - to a public repository endpoint,
# or to any endpoint not under repos/<owner>/<repo>, has its endpoint, every
# field value (and @file content), and --input content scanned first.
gh_api_guard() {  # <tool> <real> <arg>...
  local tool=$1 real=$2
  shift 2
  local args=("$@") n=$# i token option value prefix value_idx endpoint='' method='' host='' fields=0 input=0
  local texts=() files=() visibility_fields=() copy rc=0 j rest owner repo dest='' seen_api=0 mutation=0 make_public=0 input_copy=''
  gh_shim_tmp || return 1
  for ((i = 0; i < n; i++)); do
    token=${args[i]}
    if [ "${token:0:1}" != - ] || [ "$token" = - ]; then
      if [ "$seen_api" = 0 ] && [ "$token" = api ]; then
        seen_api=1
      elif [ -z "$endpoint" ] && [ "$seen_api" = 1 ]; then
        endpoint=$token
      fi
      continue
    fi
    option=$token prefix='' value='' value_idx=''
    case "$token" in
      --*=*) option=${token%%=*}; prefix=$option=; value=${token#*=}; value_idx=$i ;;
      --*) ;;
      -??*) option=${token:0:2}; prefix=$option; value=${token:2}; value_idx=$i ;;
    esac
    case "$option" in
      -X | --method | -f | --raw-field | -F | --field | --input | --hostname | -H | --header | \
      -q | --jq | -t | --template | --cache | -p | --preview | -R | --repo)
        if [ -z "$value_idx" ]; then
          value_idx=$((i + 1))
          value=${args[value_idx]:-}
          i=$value_idx
        fi
        ;;
    esac
    case "$option" in
      -X | --method) method=$(printf '%s' "$value" | tr '[:lower:]' '[:upper:]') ;;
      --hostname) host=$value ;;
      -f | --raw-field) fields=1; texts+=("${value#*=}"); visibility_fields+=("$value") ;;
      -F | --field)
        fields=1
        visibility_fields+=("$value")
        case "${value#*=}" in
          @*)
            copy=$(gh_stage_file "${value#*=@}" "field-$value_idx") || {
              echo "fm-private-names: cannot read the api field file" >&2
              return 1
            }
            args[value_idx]=$prefix${value%%=*}=@$copy
            files+=("$copy")
            ;;
          *) texts+=("${value#*=}") ;;
        esac
        ;;
      --input)
        input=1
        copy=$(gh_stage_file "$value" "input-$value_idx") || {
          echo "fm-private-names: cannot read the api input" >&2
          return 1
        }
        args[value_idx]=$prefix$copy
        files+=("$copy")
        input_copy=$copy
        ;;
    esac
  done
  if [ "$endpoint" = graphql ]; then
    for j in "${texts[@]}"; do
      printf '%s\n' "$j" | grep -q -i 'mutation' && mutation=1
    done
    for copy in "${files[@]}"; do
      grep -q -i 'mutation' "$copy" && mutation=1
    done
    if [ "$mutation" = 0 ]; then
      "$real" "${args[@]}"
      return
    fi
  else
    case "$method" in
      '') if [ "$fields" = 0 ] && [ "$input" = 0 ]; then "$real" "${args[@]}"; return; fi ;;
      GET | HEAD) "$real" "${args[@]}"; return ;;
    esac
    rest=${endpoint#/}
    case "$rest" in
      repos/*/*)
        rest=${rest#repos/}
        owner=${rest%%/*}
        rest=${rest#*/}
        repo=${rest%%/*}
        repo=${repo%%\?*}
        if [ "$owner" = '{owner}' ] || [ "$repo" = '{repo}' ]; then
          dest=$(origin_url) || dest=
        elif [ -z "$host" ] || [ "$host" = github.com ]; then
          dest=$owner/$repo
        else
          dest=$host/$owner/$repo
        fi
        ;;
    esac
    if [ "$method" = PATCH ]; then
      rest=${endpoint%%\?*}
      rest=${rest#/}
      case "${rest#repos/}" in
        */*/*) ;;
        */*)
          case "$rest" in
            repos/*)
              for j in "${visibility_fields[@]}"; do
                case "${j,,}" in
                  private=false | visibility=public) make_public=1 ;;
                  private=@* | visibility=@*)
                    copy=${j#*=@}
                    value=$(tr -d '[:space:]' <"$copy")
                    case "${j%%=*}:${value,,}" in private:false | visibility:public) make_public=1 ;; esac
                    ;;
                esac
              done
              if [ -n "$input_copy" ] && perl -MJSON::PP -e '
                local $/; my $data = eval { decode_json(<STDIN>) } || {};
                exit(!((exists $data->{private} && !$data->{private}) ||
                  (exists $data->{visibility} && lc($data->{visibility}) eq "public")));
              ' <"$input_copy"; then
                make_public=1
              fi
              ;;
          esac
          ;;
      esac
    fi
    if [ "$make_public" = 1 ]; then
      echo "fm-private-names: refusing to make a repository public from a fleet worker" >&2
      return 1
    fi
    if [ -n "$dest" ] && ! fm_pn_dest_is_public "$dest"; then
      "$real" "${args[@]}"
      return
    fi
  fi
  require_current_list "this $tool api write" || return 3
  printf '%s\n' "$endpoint" | report_hits "the api endpoint" || rc=1
  for copy in "${files[@]}"; do
    report_hits "the api input" <"$copy" || rc=1
  done
  for j in "${texts[@]}"; do
    printf '%s\n' "$j" | report_hits "an api field" || rc=1
  done
  if [ "$rc" -ne 0 ]; then
    echo "fm-private-names: refusing $tool api write to a public destination; replace the listed names with their neutral ids" >&2
    return 1
  fi
  "$real" "${args[@]}"
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
  id=${common%/}
  id=${id%.git}
  id=${id##*/}
  file=$(fm_pn_gate_index)/$id
  if [ ! -f "$file" ]; then
    echo "fm-private-names: no firstmate home on this machine pushes through this gate; nothing to check"
    return 0
  fi
  out=$(
    while IFS=$'\t' read -r home config state data projects; do
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
  # Uncommitted changes the push step will commit: added lines, added or
  # renamed paths, and untracked files with their content.
  git diff --no-color --no-ext-diff --unified=0 HEAD |
    awk '/^diff / { header = 1; next } /^@@/ { header = 0; next } !header && /^\+/ { print substr($0, 2) }' |
    report_hits "an uncommitted change" noline || rc=1
  git diff --name-only -M --diff-filter=ACR HEAD | report_hits "an uncommitted file path" noline || rc=1
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
