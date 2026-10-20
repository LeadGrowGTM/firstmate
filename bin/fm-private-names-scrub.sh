#!/usr/bin/env bash
# Scrub listed private names out of a repository's existing public surfaces:
# pull-request titles and bodies, and files on the no-mistakes evidence branch.
#
# Usage:
#   fm-private-names-scrub.sh --repo <owner/repo> [--pr <number>]...
#       [--no-evidence] [--evidence-branch <name>] [--evidence-remote <url>]
#       [--apply]
#
# Default is a dry run: it prints what would change - PR numbers, how many
# title and body lines hold a listed name, and evidence file paths rewritten to
# neutral ids - and never prints a matched name. --apply makes the changes:
#   - every PR (open, merged, or closed; or only the --pr numbers) whose title
#     or body holds a listed name gets gh pr edit with the title and body
#     rewritten to neutral ids (mate-1, client-1, ...);
#   - every file on the evidence branch tip (default no-mistakes/evidence)
#     whose path or content holds a listed name is removed by one ordinary
#     commit on top of that tip, pushed as a fast-forward.
# It never force-pushes and never rewrites history: earlier evidence commits
# and PR edit history stay readable on the forge, so removing them needs the
# forge's own support process. --pr limits the run to those PRs; pair it with
# --no-evidence to scrub one PR, as a worker does after its pipeline opens one.
# The evidence branch is read from a temporary bare clone of --evidence-remote
# (default https://github.com/<owner/repo>.git) and removed afterwards.
#
# The list, neutral ids, and visibility come from bin/fm-private-names-lib.sh:
# a private repository is left untouched, and an absent or empty list refuses.
# GitHub is reached through the real gh, never a shim.
set -u
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-private-names-lib.sh
. "$SCRIPT_DIR/fm-private-names-lib.sh"
fm_pn_init "$CONFIG" "$STATE"

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" >&2
  exit 2
}

REPO=
PRS=()
EVIDENCE=1
EVIDENCE_BRANCH=no-mistakes/evidence
EVIDENCE_REMOTE=
APPLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || usage; REPO=$2; shift 2 ;;
    --pr)
      [ "$#" -ge 2 ] || usage
      case "$2" in '' | *[!0-9]*) usage ;; esac
      PRS+=("$2")
      shift 2
      ;;
    --no-evidence) EVIDENCE=0; shift ;;
    --evidence-branch) [ "$#" -ge 2 ] || usage; EVIDENCE_BRANCH=$2; shift 2 ;;
    --evidence-remote) [ "$#" -ge 2 ] || usage; EVIDENCE_REMOTE=$2; shift 2 ;;
    --apply) APPLY=1; shift ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
done
case "$REPO" in
  */*) ;;
  *) usage ;;
esac
[ -n "$EVIDENCE_REMOTE" ] || EVIDENCE_REMOTE="https://github.com/$REPO.git"

if [ "$(fm_pn_visibility "$REPO")" = private ]; then
  echo "repository $REPO is private: nothing to scrub"
  exit 0
fi
fm_pn_require_list "the scrub" || exit 3
GH=$(fm_pn_real_bin gh) || {
  echo "fm-private-names-scrub: gh is not installed" >&2
  exit 1
}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-private-names-scrub.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

hit_lines() {  # stdin -> number of lines holding a listed name
  local out
  out=$(fm_pn_check_stream)
  if [ -z "$out" ]; then
    echo 0
  else
    printf '%s\n' "$out" | wc -l | tr -d ' '
  fi
}

PR_JQ='[.number, .state, (.title | @base64), ((.body // "") | @base64)] | @tsv'

pr_rows() {
  local n
  if [ "${#PRS[@]}" -eq 0 ]; then
    "$GH" api --paginate "repos/$REPO/pulls?state=all&per_page=100" --jq ".[] | $PR_JQ"
    return
  fi
  for n in "${PRS[@]}"; do
    "$GH" pr view "$n" --repo "$REPO" --json number,state,title,body --jq "$PR_JQ" || return 1
  done
}

scrub_prs() {
  local rows number state title64 body64 title t_hits b_hits found=0 failed=0
  rows=$(pr_rows) || {
    echo "fm-private-names-scrub: could not read pull requests from $REPO" >&2
    return 1
  }
  while IFS=$'\t' read -r number state title64 body64; do
    [ -n "$number" ] || continue
    title=$(printf '%s' "$title64" | base64 -d) || return 1
    printf '%s' "$body64" | base64 -d >"$WORK/body" || return 1
    t_hits=$(printf '%s\n' "$title" | hit_lines)
    b_hits=$(hit_lines <"$WORK/body")
    [ "$t_hits" = 0 ] && [ "$b_hits" = 0 ] && continue
    found=$((found + 1))
    if [ "$APPLY" = 0 ]; then
      echo "PR #$number ($state): title lines with a listed name: $t_hits, body lines: $b_hits; would rewrite to neutral ids"
      continue
    fi
    fm_pn_scrub_stream <"$WORK/body" >"$WORK/body.scrubbed" || return 1
    if "$GH" pr edit "$number" --repo "$REPO" \
      --title "$(fm_pn_scrub_string "$title")" --body-file "$WORK/body.scrubbed" >/dev/null; then
      echo "PR #$number ($state): rewrote $t_hits title and $b_hits body lines to neutral ids"
    else
      echo "PR #$number ($state): gh pr edit failed" >&2
      failed=1
    fi
  done <<<"$rows"
  echo "pull requests holding a listed name: $found"
  return "$failed"
}

scrub_evidence() {
  local bare=$WORK/evidence.git tip path removed=0 total=0 tree commit branch_status
  git ls-remote --exit-code "$EVIDENCE_REMOTE" "refs/heads/$EVIDENCE_BRANCH" >"$WORK/evidence-ref" 2>/dev/null
  branch_status=$?
  if [ "$branch_status" = 2 ] && [ ! -s "$WORK/evidence-ref" ]; then
    echo "evidence branch $EVIDENCE_BRANCH: absent; nothing to scrub"
    return 0
  fi
  if [ "$branch_status" -ne 0 ]; then
    echo "fm-private-names-scrub: cannot check the evidence branch" >&2
    return 1
  fi
  # One full fetch of that branch alone: every file is read, so a lazy partial
  # clone would pay one network round trip per file.
  if ! git clone --quiet --bare --single-branch --branch "$EVIDENCE_BRANCH" \
    "$EVIDENCE_REMOTE" "$bare" 2>/dev/null; then
    echo "fm-private-names-scrub: cannot clone the evidence branch" >&2
    return 1
  fi
  tip=$(git -C "$bare" rev-parse --verify "refs/heads/$EVIDENCE_BRANCH^{commit}") || return 1
  : >"$WORK/remove"
  while IFS= read -r -d '' path; do
    total=$((total + 1))
    if [ "$(printf '%s\n' "$path" | hit_lines)" != 0 ] ||
      [ "$(git -C "$bare" cat-file blob "$tip:$path" | hit_lines)" != 0 ]; then
      printf '%s\0' "$path" >>"$WORK/remove"
      removed=$((removed + 1))
      [ "$APPLY" = 1 ] || echo "evidence file would be removed: $(fm_pn_scrub_string "$path")"
    fi
  done < <(git -C "$bare" ls-tree -r -z --name-only "$tip")
  echo "evidence branch $EVIDENCE_BRANCH: $removed of $total files hold a listed name"
  [ "$removed" -gt 0 ] && [ "$APPLY" = 1 ] || return 0
  # A private index over an empty scratch work tree: --force-remove edits only
  # the index, so no evidence file is ever checked out.
  mkdir -p "$WORK/tree" || return 1
  export GIT_INDEX_FILE="$WORK/index"
  git --git-dir="$bare" --work-tree="$WORK/tree" read-tree "$tip" || return 1
  xargs -0 git --git-dir="$bare" --work-tree="$WORK/tree" update-index --force-remove -- <"$WORK/remove" || return 1
  tree=$(git --git-dir="$bare" write-tree) || return 1
  unset GIT_INDEX_FILE
  commit=$(git -C "$bare" commit-tree "$tree" -p "$tip" \
    -m "Remove evidence files that hold a listed private name ($removed files)") || return 1
  # An ordinary fast-forward push: refused rather than forced if the tip moved.
  git -C "$bare" push --quiet "$EVIDENCE_REMOTE" "$commit:refs/heads/$EVIDENCE_BRANCH" || {
    echo "fm-private-names-scrub: pushing the evidence removal commit failed; nothing was forced" >&2
    return 1
  }
  echo "evidence branch $EVIDENCE_BRANCH: removed $removed files in commit ${commit:0:12}"
}

[ "$APPLY" = 1 ] || echo "dry run: nothing will change; rerun with --apply to rewrite"
rc=0
scrub_prs || rc=1
if [ "$EVIDENCE" = 1 ]; then
  scrub_evidence || rc=1
fi
exit "$rc"
