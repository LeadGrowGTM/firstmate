#!/usr/bin/env bash
# Keep private names (operator home names and the clients they serve) off every
# public exit: commits, pushes, and pull-request text created by firstmate and
# its workers.
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
#       outgoing content: each pushed branch name, every outgoing commit
#       message, the content of added lines, and paths a commit adds or
#       renames. The existing tree - unchanged lines and files a commit only
#       modifies - is never judged. A push to the no-mistakes gate remote is
#       judged by the repository's origin, because the gate forwards there.
#   fm-private-names.sh gh-shim <gh|gh-axi> [<arg>...]
#       PATH shim for gh and gh-axi. For pr create, edit, comment, review, and
#       merge against a public repository it scans the outgoing PR text - the
#       --title, --body, --subject, and label values, any --body-file (or -F)
#       content including stdin, and the head branch - before the real tool
#       runs; other option values, such as a body file's own path, are not
#       judged, and everything else runs the real tool unchanged.
#   fm-private-names.sh no-mistakes-shim [<arg>...]
#       PATH shim for no-mistakes; checks intent, PR title, and branch inputs
#       before the real tool runs for a public origin.
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
# Accepted residual: git --no-verify skips both hooks, and a tool that writes
# commits or calls the GitHub API without git hooks or the gh shim is not seen;
# the no-mistakes pipeline's own PR is read back by bin/fm-private-names-scrub.sh.
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
  derived=$(emit_home_records "$DATA" "$PROJECTS" 1 | LC_ALL=C sort -u)
  # A second mate home on this machine also takes its primary's whole list, so
  # every home refuses the same names. The list is read from disk rather than
  # pushed as inherited config, which would paste it into the mate's context.
  parent=
  if fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" 2>/dev/null &&
    [ "$FM_SECONDMATE_PARENT_ROUTE" = local ]; then
    parent=$FM_SECONDMATE_PARENT_HOME/config/private-names
  fi
  tmp=$(mktemp "$(dirname "$out")/.private-names.XXXXXX" 2>/dev/null) || return 1
  # Keep existing order, append newly derived names, then hand additions.
  {
    printf '# Generated by bin/fm-private-names.sh refresh. Do not edit by hand:\n'
    printf '# add names in private-names.local and rerun refresh. Never commit this file.\n'
    {
      [ -f "$out" ] && awk 'NF >= 2 && $1 !~ /^#/ { print }' "$out"
      [ -n "$parent" ] && [ -f "$parent" ] && awk 'NF >= 2 && $1 !~ /^#/ { print }' "$parent"
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
  echo "private-names: $(fm_pn_count) names in config/private-names"
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

refresh_if_stale() {
  local line home parent
  [ -s "$FM_PN_LIST" ] || { cmd_refresh >/dev/null; return; }
  [ "$FM_PN_GENERIC" -nt "$FM_PN_LIST" ] && { cmd_refresh >/dev/null; return; }
  [ "$FM_PN_LOCAL" -nt "$FM_PN_LIST" ] && { cmd_refresh >/dev/null; return; }
  [ "$FM_HOME/.fm-secondmate-parent" -nt "$FM_PN_LIST" ] && { cmd_refresh >/dev/null; return; }
  if fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" 2>/dev/null &&
    [ "$FM_SECONDMATE_PARENT_ROUTE" = local ]; then
    parent=$FM_SECONDMATE_PARENT_HOME/config/private-names
    [ "$parent" -nt "$FM_PN_LIST" ] && { cmd_refresh >/dev/null; return; }
  fi
  source_newer_in_home "$DATA" "$PROJECTS" && { cmd_refresh >/dev/null; return; }
  if [ -f "$DATA/secondmates.md" ]; then
    while IFS= read -r line; do
      secondmate_registry_parse_line "$line" || continue
      [ "$SECONDMATE_REGISTRY_REMOTE" = 0 ] || continue
      home=$SECONDMATE_REGISTRY_HOME
      case "$home" in \~/*) home=$HOME/${home#\~/} ;; esac
      source_newer_in_home "$home/data" "$home/projects" && { cmd_refresh >/dev/null; return; }
    done <"$DATA/secondmates.md"
  fi
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
  git diff-tree --root --no-commit-id --name-only -r -M -C --diff-filter=ACR "$1"
}

# The content of a commit's added lines, without the leading "+" or any diff
# header, optionally for one path.
added_lines() {  # <sha> [<path>]
  git show --format= --no-color --no-ext-diff --unified=0 "$1" -- ${2:+"$2"} |
    awk '/^diff / { header = 1; next } /^@@/ { header = 0; next } !header && /^\+/ { print substr($0, 2) }'
}

cmd_pre_push() {
  local remote=${1:-} url=${2:-} dest local_sha remote_ref remote_sha
  local branch range commits rc=0 sha path ref effective_remote base_ref base_sha
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
  while read -r _ local_sha remote_ref remote_sha; do
    [ -n "${local_sha:-}" ] || continue
    case "$local_sha" in *[!0]*) ;; *) continue ;; esac
    branch=${remote_ref#refs/heads/}
    branch=${branch#refs/tags/}
    if ! printf '%s\n' "$branch" | report_hits "the pushed ref name"; then
      echo "fm-private-names: rename the branch before pushing, for example to: $(fm_pn_scrub_string "$branch")" >&2
      rc=1
    fi
    if [ "${remote_sha:-$ZERO_SHA}" != "$ZERO_SHA" ] && git cat-file -e "$remote_sha^{commit}" 2>/dev/null; then
      range=("$remote_sha..$local_sha")
    else
      range=("$local_sha" --not)
      effective_remote=$remote
      [ "$remote" != no-mistakes ] || effective_remote=origin
      while IFS= read -r ref; do
        [ -n "$ref" ] && range+=("$ref")
      done < <(git for-each-ref --format='%(refname)' "refs/remotes/$effective_remote/")
      if [ "${#range[@]}" -eq 2 ]; then
        base_ref=$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) || base_ref=
        if [ -z "$base_ref" ]; then
          for ref in refs/remotes/origin/main refs/remotes/origin/master; do
            if git show-ref --verify --quiet "$ref"; then
              base_ref=$ref
              break
            fi
          done
        fi
        if [ -n "$base_ref" ]; then
          base_sha=$(git merge-base "$local_sha" "$base_ref" 2>/dev/null) || base_sha=
          [ -z "$base_sha" ] || range+=("$base_sha")
        fi
      fi
    fi
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
      if { new_paths "$sha"
        added_lines "$sha"; } | report_hits "commit ${sha:0:12}" 2>/dev/null; then
        continue
      fi
      rc=1
      while IFS= read -r path; do
        printf '%s\n' "$path" |
          report_hits "a file path added in commit ${sha:0:12} ($(fm_pn_scrub_string "$path"))" noline
      done < <(new_paths "$sha")
      while IFS= read -r path; do
        [ -n "$path" ] || continue
        added_lines "$sha" "$path" |
          report_hits "an added line of $(fm_pn_scrub_string "$path") in commit ${sha:0:12}" noline
      done < <(git diff-tree --root --no-commit-id --name-only -r -M --diff-filter=d "$sha")
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
  local args=("$@") i=0 n=$# repo='' head='' body_file_idx=() text_idx=() dest action
  local has_title=0 has_body=0 has_edit_option=0 no_text_action=0 opaque=0
  while [ "$i" -lt "$n" ]; do
    case "${args[i]}" in
      --repo | -R) i=$((i + 2)) ;;
      --repo=* | -R?* | -*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  if [ "${args[i]:-}" != pr ]; then
    exec "$real" "$@"
  fi
  action=${args[i + 1]:-}
  case "$action" in
    create | new | edit | comment | review | merge) ;;
    *) exec "$real" "$@" ;;
  esac

  for ((i = 0; i < n; i++)); do
    case "${args[i]}" in
      --repo | -R) repo=${args[i + 1]:-} ;;
      --repo=*) repo=${args[i]#--repo=} ;;
      -R?*) repo=${args[i]#-R}; repo=${repo#=} ;;
      --head | -H) head=${args[i + 1]:-} ;;
      --head=*) head=${args[i]#--head=} ;;
      --body-file | -F) body_file_idx+=("$((i + 1))"); has_body=1 ;;
      --body-file=*) body_file_idx+=("=$i"); has_body=1 ;;
      --title | -t) text_idx+=("$((i + 1))"); has_title=1 ;;
      --title=*) text_idx+=("$i"); has_title=1 ;;
      --body | -b) text_idx+=("$((i + 1))"); has_body=1 ;;
      --body=*) text_idx+=("$i"); has_body=1 ;;
      --subject | --label | -l | --add-label) text_idx+=("$((i + 1))"); has_edit_option=1 ;;
      --subject=* | --label=* | --add-label=*) text_idx+=("$i"); has_edit_option=1 ;;
      --remove-label | --remove-label=* | --base | --base=* | --add-assignee | --add-assignee=* | --remove-assignee | --remove-assignee=* | --add-reviewer | --add-reviewer=* | --remove-reviewer | --remove-reviewer=* | --milestone | --milestone=* | --remove-milestone | --project | --project=* | --remove-project | --remove-project=*) has_edit_option=1 ;;
      --approve | --delete-last) no_text_action=1 ;;
      --template | --template=* | --fill | --fill-first | --fill-verbose | --recover | --recover=* | --editor | --web | -w) opaque=1 ;;
    esac
  done
  dest=$repo
  [ -n "$dest" ] || dest=$(origin_url) || dest=
  if [ -n "$dest" ] && ! fm_pn_dest_is_public "$dest"; then
    exec "$real" "$@"
  fi
  require_current_list "this pull-request text" || return 3
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
  local idx src copy rc=0 copies=()
  GH_SHIM_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-private-names-gh.XXXXXX") || return 1
  trap 'rm -rf "$GH_SHIM_TMP"' EXIT
  local prefix
  for idx in "${body_file_idx[@]}"; do
    prefix=
    case "$idx" in
      =*)
        idx=${idx#=}
        prefix=--body-file=
        ;;
    esac
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
  for idx in "${text_idx[@]}"; do
    printf '%s\n' "${args[idx]:-}" | report_hits "the pull-request text" 2>/dev/null || rc=1
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
      for idx in "${text_idx[@]}"; do
        printf '%s\n' "${args[idx]:-}" | report_hits "the pull-request text"
      done
      echo "fm-private-names: refusing $tool pr $action on a public repository; reword it, or rerun with FM_PRIVATE_NAMES_MODE=rewrite to rewrite names to neutral ids" >&2
      return 1
    fi
    for copy in "${copies[@]}"; do
      if ! fm_pn_scrub_stream <"$copy" >"$copy.scrubbed" || ! mv "$copy.scrubbed" "$copy"; then
        return 1
      fi
    done
    for idx in "${text_idx[@]}"; do
      args[idx]=$(fm_pn_scrub_string "${args[idx]:-}")
    done
    echo "fm-private-names: rewrote listed private names in the pull-request text to neutral ids" >&2
  fi
  "$real" "${args[@]}"
}

cmd_no_mistakes_shim() {
  local real dest branch i arg check_branch=0 rc=0
  local args=("$@") text_idx=()
  real=$(fm_pn_real_bin no-mistakes) || {
    echo "fm-private-names: no real no-mistakes found on PATH" >&2
    return 127
  }
  if [ "${args[0]:-}" = axi ]; then
    case "${args[1]:-}" in run | respond) check_branch=1 ;; esac
  fi
  for ((i = 0; i < ${#args[@]}; i++)); do
    arg=${args[i]}
    case "$arg" in
      --intent | --title | --pr-title) text_idx+=("$((i + 1))"); check_branch=1 ;;
      --intent=* | --title=* | --pr-title=*) text_idx+=("$i"); check_branch=1 ;;
    esac
  done
  [ "$check_branch" = 1 ] || exec "$real" "$@"
  dest=$(origin_url) || dest=
  [ -n "$dest" ] || exec "$real" "$@"
  fm_pn_dest_is_public "$dest" || exec "$real" "$@"
  require_current_list "this no-mistakes run" || return 3
  for i in "${text_idx[@]}"; do
    printf '%s\n' "${args[i]:-}" | report_hits "the no-mistakes text" || rc=1
  done
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=
  if [ -n "$branch" ]; then
    printf '%s\n' "$branch" | report_hits "the current branch name" || rc=1
  fi
  [ "$rc" = 0 ] || return 1
  exec "$real" "$@"
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
  -h | --help | '') usage ;;
  *) usage ;;
esac
