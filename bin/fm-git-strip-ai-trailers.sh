#!/usr/bin/env bash
# Strip AI co-author trailers from a commit message, and
# install that strip as a per-task git commit-msg hook for a fleet launch.
#
# Usage:
#   fm-git-strip-ai-trailers.sh <msgfile>
#       Commit-msg hook mode. Git passes the proposed message file as $1.
#       Rewrites that file in place, then exits 0 so the commit proceeds.
#   fm-git-strip-ai-trailers.sh install <hooks-dir> <worktree> [--keep-ai-trailers]
#                                  [--private-names <config-dir> <state-dir> <home-dir> <data-dir> <projects-dir>]
#       Recreate <hooks-dir> as a core.hooksPath for this launch: a commit-msg
#       hook that runs this strip (omitted with --keep-ai-trailers), plus one
#       wrapper per client-side hook name
#       git documents except reference-transaction and post-index-change,
#       which are deliberately excluded (see FM_GIT_CLIENT_HOOKS below).
#       Each wrapper unsets GIT_CONFIG_* and then resolves
#       core.hooksPath (or $GIT_DIR/hooks) in the repository git is actually
#       running in, so a husky directory that only appears after npm install
#       still runs, and git -C some-other-repo does not inherit the task
#       worktree's hooks. That lookup also ignores GIT_CONFIG_PARAMETERS,
#       because git -c core.hooksPath=<this dir> (or a child process that
#       inherits it) carries the override there, and a lookup that honored it
#       would find this directory again and never run the repository's own
#       hook - a skipped pre-push guard. An empty core.hooksPath means no
#       repository hook, as in plain git; any other failed lookup exits
#       nonzero rather than skipping the repository's hook. Does not touch the
#       project's git config; the caller prefixes the pane with
#       GIT_CONFIG_COUNT / GIT_CONFIG_KEY_0 / GIT_CONFIG_VALUE_0.
#       --private-names adds the private-name guard (bin/fm-private-names.sh,
#       reading that home's config, state, data, and project directories) to the commit-msg
#       and pre-push hooks before the repository's own hook runs, and writes
#       git, gh, gh-axi, and no-mistakes shims into <hooks-dir>/bin for the caller to put first
#       on the pane's PATH. The pre-push wrapper replays git's ref lines to
#       the repository's own pre-push hook after the guard reads them.
#
# WHY THIS EXISTS. Claude launches already carry attribution-off in their
# per-launch --settings JSON. Cursor and other non-Claude runtimes inject a
# Co-Authored-By trailer at the tooling layer AFTER the worker types a clean
# message, so the typed message is not the commit object.
# A prior per-machine ~/.cursor/cli-config.json attribution-off is not durable:
# it does not travel with Firstmate, it defaults back to on when unset, and it
# only feeds the CLI's request to the server - the trailer text is emitted by
# the model, so the setting suppresses rather than prevents it. Verified live
# on cursor-agent 2026.09.15 with attribution on: the trailer is already in
# .git/COMMIT_EDITMSG when the commit-msg hook runs, so the spawn-owned hook is
# the layer that sees the assembled message before the commit object is written.
# Human Co-Authored-By trailers are left untouched. Author identity is not
# rewritten.
#
# ACCEPTED RESIDUAL, ruled 2026-09-17. git commit --no-verify skips every hook,
# so a worker that passes it still lands the trailer, as would a runtime that
# writes the commit object without running git. Both incidents that motivated
# this strip came through an ordinary hook-running commit, so the ruling is to
# accept that gap rather than add a push-side rewrite or a push-side check. A
# trailer found on a fleet commit therefore points at one of those two paths,
# not at an unnoticed hole in the matcher.
#
# ACCEPTED RESIDUAL, ruled 2026-09-17. Inside a fleet pane git reports this
# directory as the repository's hooks directory, so a hook manager run there
# (lefthook's npm postinstall, pre-commit install) targets it and would
# displace the strip. install leaves the directory and every hook in it
# read-only, so such a manager fails loudly instead of silently winning. Hook
# managers therefore cannot install from inside fleet panes until a registered
# project genuinely needs it. Whoever removes the directory restores the owner
# write bit first.
set -u
unset CDPATH GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

SELF="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"

usage() {
  cat >&2 <<'EOF'
usage:
  fm-git-strip-ai-trailers.sh <msgfile>
  fm-git-strip-ai-trailers.sh install <hooks-dir> <worktree> [--keep-ai-trailers]
                                 [--private-names <config-dir> <state-dir> <home-dir> <data-dir> <projects-dir>]
EOF
  exit 2
}

trim_space() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# True when this line is an AI Co-Authored-By trailer that must not reach a
# commit object. Matches known product names and exact observed bot addresses only; an
# address is added when a runtime is seen emitting it, never guessed from a
# vendor domain, so a human co-author who works at a vendor is kept. A human
# whose name or address merely contains a substring such as "ai" is kept.
fm_is_ai_attribution_line() {
  local raw=$1 lowered rest name email
  raw=${raw%$'\r'}
  raw=$(trim_space "$raw")
  [ -n "$raw" ] || return 1
  lowered=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  case "$lowered" in
  co-authored-by:*) ;;
  *) return 1 ;;
  esac
  rest=$(trim_space "${raw#*:}")
  name=$rest
  email=
  case "$rest" in
  *'<'*'>'*)
    email=$(printf '%s' "$rest" | tr '[:upper:]' '[:lower:]')
    email=${email#*'<'}
    email=${email%%'>'*}
    name=$(trim_space "${rest%%'<'*}")
    ;;
  esac
  name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  case "$email" in
  noreply@anthropic.com | cursoragent@* | noreply@openai.com | copilot@github.com)
    return 0
    ;;
  esac
  case "$name" in
  cursor | 'cursor agent' | claude | 'claude code' | 'github copilot' | copilot | codex | chatgpt | gemini | 'google gemini' | grok | openai)
    return 0
    ;;
  esac
  return 1
}

strip_msgfile() {
  local src=$1 tmp
  [ -f "$src" ] || {
    echo "error: commit message file not found: $src" >&2
    return 1
  }
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-git-strip-ai-trailers.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if fm_is_ai_attribution_line "$line"; then
      continue
    fi
    printf '%s\n' "$line"
  done <"$src" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$src"
}

quote_for_hook() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

write_executable() {
  local dest=$1
  cat >"$dest" || return 1
  chmod 500 "$dest"
}

# Shared body for every wrapper: after the pane-wide GIT_CONFIG override is
# cleared, resolve this repository's own hooks directory the way git does
# (core.hooksPath, else the common dir's hooks) and exec that name if it
# exists. The lookup runs without GIT_CONFIG_PARAMETERS as well, since git -c
# is the other environment channel that can carry this directory as
# core.hooksPath; only the repository's config files name its own hooks. Skip
# when the lookup still names this launch's own hooks dir, meaning those files
# point here, so the wrapper cannot recurse into itself. An empty
# core.hooksPath makes that lookup fail, but plain git reads it as "no hooks",
# so the wrapper runs none; any other failure reruns the lookup to show git's
# error and refuses.
runtime_chain_body() {
  local ours=$1
  cat <<EOF
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
ours=$(quote_for_hook "$ours")
name=\${0##*/}
orig=\$(unset GIT_CONFIG_PARAMETERS; git rev-parse --path-format=absolute --git-path hooks 2>/dev/null) || {
  if hooks_path=\$(unset GIT_CONFIG_PARAMETERS; git config --get --type=path core.hooksPath 2>/dev/null) && [ -z "\$hooks_path" ]; then
    exit 0
  fi
  (unset GIT_CONFIG_PARAMETERS; git rev-parse --path-format=absolute --git-path hooks >/dev/null)
  echo "fm-git-strip-ai-trailers: cannot resolve this repository's hooks directory; refusing to skip its \$name hook" >&2
  exit 1
}
if [ "\$orig" = "\$ours" ]; then
  exit 0
fi
if [ -x "\$orig/\$name" ]; then
  exec "\$orig/\$name" "\$@"
fi
EOF
}

# Client-side hook names git invokes by name from core.hooksPath, per
# githooks(5) in git 2.50. The receive-side names, the config-invoked
# fsmonitor-watchman, and the git-p4 names are left out because git never looks
# them up in a fleet worker's own worktree. commit-msg is written separately
# because it is the one that carries the strip.
#
# reference-transaction and post-index-change are deliberately excluded, ruled
# 2026-09-17. git invokes them twice per updated ref and on every index write,
# so a wrapper for either turns a stat git used to skip into hundreds of forks
# on one bulk command. Measured on git 2.50.1: a fetch of 300 new refs goes
# 0.23s -> 24.6s, and a no-op /bin/sh hook still costs 4.9s, so the price is
# git's invocation rather than the wrapper body. Neither name is one
# commit-message or lint tooling installs, which is what this chaining exists
# to preserve. A project that does install one loses chaining for it inside
# fleet panes only.
#
# The names kept are not free either, and that cost is accepted, ruled
# 2026-09-17. Every wrapper call forks bash plus one git rev-parse. A plain
# commit fires four wrappers, and git's sequencer fires prepare-commit-msg and
# post-commit once per replayed commit in rebase and cherry-pick, as git am does
# its applypatch hooks per patch. Measured on git 2.50.1 with no project hooks:
# one commit goes ~76ms -> ~276ms, and a 60-commit rebase 0.74s -> 3.7s. They
# stay because git-lfs installs post-commit, post-checkout, post-merge and
# pre-push, and a slower rebase inside a pane is the accepted price.
FM_GIT_CLIENT_HOOKS='applypatch-msg pre-applypatch post-applypatch pre-commit
pre-merge-commit prepare-commit-msg post-commit pre-rebase post-checkout
post-merge pre-push post-rewrite pre-auto-gc sendemail-validate'

# The guard command line a hook runs, with the launching home's config and
# state directories baked in; empty when the private-name guard is off.
private_names_command() {  # <subcommand>
  [ -n "$PN_CONFIG" ] || return 0
  printf 'FM_HOME=%s FM_DATA_OVERRIDE=%s FM_PROJECTS_OVERRIDE=%s FM_CONFIG_OVERRIDE=%s FM_STATE_OVERRIDE=%s %s %s' \
    "$(quote_for_hook "$PN_HOME")" "$(quote_for_hook "$PN_DATA")" "$(quote_for_hook "$PN_PROJECTS")" \
    "$(quote_for_hook "$PN_CONFIG")" "$(quote_for_hook "$PN_STATE")" \
    "$(quote_for_hook "$PN_GUARD")" "$1"
}

# <path> made absolute against the current directory, so hooks that run from
# another directory still read the launching home.
absolute_path() {  # <path>
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}

# The first git on PATH that is not in a private-name shim directory.
real_git_path() {
  local dir old_ifs=$IFS
  IFS=:
  for dir in $PATH; do
    IFS=$old_ifs
    [ -n "$dir" ] && [ ! -e "$dir/.fm-private-names-shim" ] || continue
    if [ -x "$dir/git" ] && [ ! -d "$dir/git" ]; then
      printf '%s\n' "$dir/git"
      return 0
    fi
  done
  IFS=$old_ifs
  return 1
}

# shellcheck disable=SC2016 # hook bodies are written literally for git to run
install_hooks() {
  local hooks_dir=$1 wt=$2 name tool real_git
  [ -n "$hooks_dir" ] && [ -n "$wt" ] || usage
  [ -d "$wt" ] || {
    echo "error: worktree is not a directory: $wt" >&2
    return 1
  }
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null || {
    echo "error: not a git worktree: $wt" >&2
    return 1
  }
  chmod u+w "$hooks_dir" 2>/dev/null
  rm -rf "$hooks_dir"
  mkdir -p "$hooks_dir" || return 1
  chmod 700 "$hooks_dir" 2>/dev/null || true
  hooks_dir=$(CDPATH='' cd -- "$hooks_dir" && pwd -P) || return 1

  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -u'
    if [ "$KEEP_TRAILERS" = 0 ]; then
      printf '%s "$1" || exit $?\n' "$(quote_for_hook "$SELF")"
    fi
    if [ -n "$PN_CONFIG" ]; then
      printf '%s "$1" || exit $?\n' "$(private_names_command commit-msg)"
    fi
    runtime_chain_body "$hooks_dir"
  } | write_executable "$hooks_dir/commit-msg" || return 1

  for name in $FM_GIT_CLIENT_HOOKS; do
    {
      printf '%s\n' '#!/usr/bin/env bash' 'set -u'
      if [ "$name" = pre-push ] && [ -n "$PN_CONFIG" ]; then
        # Keep git's ref lines for the repository's own pre-push hook: the
        # unlinked file stays readable on stdin after the guard consumed it.
        printf '%s\n' 'refs=$(mktemp "${TMPDIR:-/tmp}/fm-pre-push.XXXXXX") || exit 1' \
          'cat >"$refs" || { rm -f "$refs"; exit 1; }'
        printf '%s "$@" <"$refs" || { rc=$?; rm -f "$refs"; exit "$rc"; }\n' \
          "$(private_names_command pre-push)"
        printf '%s\n' 'exec <"$refs"' 'rm -f "$refs"'
      fi
      runtime_chain_body "$hooks_dir"
    } | write_executable "$hooks_dir/$name" || return 1
  done

  if [ -n "$PN_CONFIG" ]; then
    mkdir -p "$hooks_dir/bin" || return 1
    : >"$hooks_dir/bin/.fm-private-names-shim" || return 1
    real_git=$(real_git_path) || {
      echo "error: no git found on PATH" >&2
      return 1
    }
    # A push that would skip the pre-push guard is refused: --no-verify in any
    # form git accepts, any core.hooksPath other than this directory as git
    # itself resolves it under the caller's options and environment (-c,
    # --config-env, GIT_CONFIG_*, include files, an unset override), and the
    # plumbing commands that push without hooks. The one exception is a push
    # whose destination is the local gate of the remote named exactly
    # no-mistakes: every push URL of that remote, and of the destination git
    # will actually use, is that one directory. The gate scans that content
    # before publishing it. Every other call runs unchanged. Git
    # aliases are outside this shim; a push through one still runs the
    # pre-push hook unless the alias skips hooks.
    {
      printf '%s\n' '#!/usr/bin/env bash' \
        "real=$(quote_for_hook "$real_git")" \
        "hooks=$(quote_for_hook "$hooks_dir")"
      cat <<'GIT'
# Canonical directory for a local path or file:// URL, else failure. A URL
# with a host, and an scp-style path, is not a local gate.
canon_dir() {
  local url=$1 top
  case "$url" in
    file://localhost/*) url="/${url#file://localhost/}" ;;
    file:///*) url=${url#file://} ;;
    *://* | *:*) return 1 ;;
  esac
  case "$url" in
    /*) ;;
    *)
      top=$("$real" "${args[@]:0:i}" rev-parse --show-toplevel 2>/dev/null) || return 1
      url=$top/$url
      ;;
  esac
  (cd -- "$url" 2>/dev/null && pwd -P)
}

# 0 when $1 is the gate directory no-mistakes init writes: the push URL of the
# remote it names exactly "no-mistakes", shaped <root>/repos/<id>.git. <id> is
# 12 lowercase hex digits (SHA-256 of the repo path, first 6 bytes). <root> is
# $NM_HOME when that is set, otherwise $HOME/.no-mistakes. A remote whose name
# merely contains that word is not this directory.
gate_dir() {
  local path=$1 base parent root nm_home home_root top
  base=${path##*/}
  parent=${path%/*}
  [ "${parent##*/}" = repos ] || return 1
  root=${parent%/*}
  case "$base" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f].git) ;;
    *) return 1 ;;
  esac
  if [ -n "${NM_HOME:-}" ]; then
    nm_home=$NM_HOME
    case "$nm_home" in
      /*) ;;
      *)
        top=$("$real" "${args[@]:0:i}" rev-parse --show-toplevel 2>/dev/null) || return 1
        nm_home=$top/$nm_home
        ;;
    esac
    nm_home=$(cd -- "$nm_home" 2>/dev/null && pwd -P) || return 1
    [ "$root" = "$nm_home" ]
    return
  fi
  [ -n "${HOME:-}" ] || return 1
  home_root=$(cd -- "$HOME/.no-mistakes" 2>/dev/null && pwd -P) || return 1
  [ "$root" = "$home_root" ]
}

# Repository git will push to. A positional argument, including one after --,
# wins over --repo. With neither, git uses branch.<name>.pushRemote, then
# remote.pushDefault, then branch.<name>.remote, then origin.
push_repository() {
  local j a repo_flag="" repo_pos="" saw_pos=0 separated=0 branch
  j=$((i + 1))
  while [ "$j" -lt "$n" ]; do
    a=${args[j]}
    if [ "$separated" -eq 0 ] && [ "$a" = -- ]; then
      separated=1
      j=$((j + 1))
      continue
    fi
    if [ "$separated" -eq 1 ]; then
      if [ "$saw_pos" -eq 0 ]; then
        repo_pos=$a
        saw_pos=1
      fi
      j=$((j + 1))
      continue
    fi
    case "$a" in
      --repo)
        j=$((j + 1))
        [ "$j" -lt "$n" ] || return 1
        repo_flag=${args[j]}
        ;;
      --receive-pack | --exec | --push-option | -o | --recurse-submodules)
        j=$((j + 1))
        ;;
      --repo=*)
        repo_flag=${a#--repo=}
        ;;
      -*) ;;
      *)
        if [ "$saw_pos" -eq 0 ]; then
          repo_pos=$a
          saw_pos=1
        fi
        ;;
    esac
    j=$((j + 1))
  done
  if [ "$saw_pos" -eq 1 ]; then
    printf '%s\n' "$repo_pos"
    return
  fi
  if [ -n "$repo_flag" ]; then
    printf '%s\n' "$repo_flag"
    return
  fi
  branch=$("$real" "${args[@]:0:i}" symbolic-ref --short HEAD 2>/dev/null) || return 1
  a=$("$real" "${args[@]:0:i}" config --get "branch.${branch}.pushRemote" 2>/dev/null) || a=
  if [ -z "$a" ]; then
    a=$("$real" "${args[@]:0:i}" config --get remote.pushDefault 2>/dev/null) || a=
  fi
  if [ -z "$a" ]; then
    a=$("$real" "${args[@]:0:i}" config --get "branch.${branch}.remote" 2>/dev/null) || a=origin
  fi
  [ -n "$a" ] || return 1
  printf '%s\n' "$a"
}

# Every push URL of remote $1, one per line. Fails when $1 is not a remote.
remote_push_urls() {
  "$real" "${args[@]:0:i}" remote get-url --push --all "$1" 2>/dev/null
}

# Canonical gate directory when every URL on stdin is that same directory.
one_gate_path() {
  local url path first=""
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    path=$(canon_dir "$url") || return 1
    gate_dir "$path" || return 1
    if [ -z "$first" ]; then
      first=$path
    elif [ "$path" != "$first" ]; then
      return 1
    fi
  done
  [ -n "$first" ] || return 1
  printf '%s\n' "$first"
}

# 0 when this push's target is the configured no-mistakes gate, and nothing else.
# A remote with several push URLs is the gate only when every one of them is.
push_targets_gate() {
  local gate_urls gate_path dest_name dest_urls dest_path
  gate_urls=$(remote_push_urls no-mistakes) || return 1
  gate_path=$(printf '%s\n' "$gate_urls" | one_gate_path) || return 1
  dest_name=$(push_repository) || return 1
  if dest_urls=$(remote_push_urls "$dest_name"); then
    dest_path=$(printf '%s\n' "$dest_urls" | one_gate_path) || return 1
  else
    dest_path=$(canon_dir "$dest_name") || return 1
    gate_dir "$dest_path" || return 1
  fi
  [ "$dest_path" = "$gate_path" ]
}

args=("$@")
n=$#
i=0
while [ "$i" -lt "$n" ]; do
  case "${args[i]}" in
    -C | -c | --git-dir | --work-tree | --namespace | --super-prefix | --config-env | --attr-source | --list-cmds)
      i=$((i + 2))
      continue
      ;;
    -C?* | -c?* | --git-dir=* | --work-tree=* | --namespace=* | --super-prefix=* | --config-env=* | \
      --attr-source=* | --exec-path=* | --list-cmds=* | -p | --paginate | -P | --no-pager | --bare | \
      --no-replace-objects | --no-lazy-fetch | --no-optional-locks | --no-advice | --literal-pathspecs | \
      --glob-pathspecs | --noglob-pathspecs | --icase-pathspecs | --exec-path | --html-path | --man-path | \
      --info-path | -v | --version | -h | --help) ;;
    -*)
      echo "fm-private-names: unrecognized git option before the command; refusing so a push cannot skip the private-name check" >&2
      exit 1
      ;;
    *) break ;;
  esac
  i=$((i + 1))
done
case "${args[i]:-}" in
  push)
    skip_hook=0
    for a in "${args[@]:i+1}"; do
      [ "$a" = -- ] && break
      case "$a" in
        --no-veri | --no-verif | --no-verify) skip_hook=1 ;;
      esac
    done
    if [ "$skip_hook" -eq 1 ] && ! push_targets_gate; then
      echo "fm-private-names: git push --no-verify would skip the private-name check; push without it" >&2
      exit 1
    fi
    effective=$("$real" "${args[@]:0:i}" config --type=path --get core.hooksPath 2>/dev/null) || effective=
    case "$effective" in
      '' | /*) ;;
      *)
        top=$("$real" "${args[@]:0:i}" rev-parse --show-toplevel 2>/dev/null) || top=
        effective=$top/$effective
        ;;
    esac
    resolved=$(cd -- "$effective" 2>/dev/null && pwd -P) || resolved=
    if [ -z "$effective" ] || [ "$resolved" != "$hooks" ]; then
      echo "fm-private-names: git push under another core.hooksPath would skip the private-name check" >&2
      exit 1
    fi
    ;;
  send-pack | http-push)
    echo "fm-private-names: git ${args[i]} pushes without the pre-push hook; use git push" >&2
    exit 1
    ;;
esac
exec "$real" "$@"
GIT
    } | write_executable "$hooks_dir/bin/git" || return 1
    for tool in gh gh-axi no-mistakes; do
      if [ "$tool" = no-mistakes ]; then
        printf '%s\n' '#!/usr/bin/env bash' \
          "exec env $(private_names_command no-mistakes-shim) \"\$@\"" |
          write_executable "$hooks_dir/bin/$tool" || return 1
        continue
      fi
      printf '%s\n' '#!/usr/bin/env bash' \
        "exec env $(private_names_command gh-shim) $tool \"\$@\"" |
        write_executable "$hooks_dir/bin/$tool" || return 1
    done
  fi
  chmod 500 "$hooks_dir"
}

CMD=${1:-}
case "$CMD" in
install)
  [ "$#" -ge 3 ] || usage
  hooks_arg=$2
  wt_arg=$3
  shift 3
  KEEP_TRAILERS=0
  PN_CONFIG=
  PN_STATE=
  PN_HOME=
  PN_DATA=
  PN_PROJECTS=
  PN_GUARD="$(cd "$(dirname "$SELF")" && pwd -P)/fm-private-names.sh"
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --keep-ai-trailers)
      KEEP_TRAILERS=1
      shift
      ;;
    --private-names)
      [ "$#" -ge 6 ] && [ -n "$2" ] && [ -n "$3" ] && [ -n "$4" ] && [ -n "$5" ] && [ -n "$6" ] || usage
      PN_CONFIG=$(absolute_path "$2")
      PN_STATE=$(absolute_path "$3")
      PN_HOME=$(absolute_path "$4")
      PN_DATA=$(absolute_path "$5")
      PN_PROJECTS=$(absolute_path "$6")
      shift 6
      ;;
    *) usage ;;
    esac
  done
  install_hooks "$hooks_arg" "$wt_arg"
  ;;
-h | --help)
  usage
  ;;
'')
  usage
  ;;
*)
  if [ "$CMD" = "${CMD#-}" ] && [ "$#" -ge 1 ]; then
    strip_msgfile "$1"
  else
    usage
  fi
  ;;
esac
