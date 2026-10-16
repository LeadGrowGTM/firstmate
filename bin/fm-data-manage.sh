#!/usr/bin/env bash
# fm-data-manage.sh - measure disk use and plan retention cleanup.
#
# Usage:
#   fm-data-manage.sh measure --config <file>
#   fm-data-manage.sh clean --config <file> [--live]
#   fm-data-manage.sh --help
#
# Dry-run is the default. `clean` prints what it would free and deletes nothing.
# Live cleanup requires a regular config/data-management.live-authorized file
# in the first listed home, which must be the root Firstmate home.
# `--live` deletes only aged regular files under configured tmp, log, and cache
# roots, then may run `fm-treehouse-guard.sh prune` for a project whose linked
# pool slots are landed, clean, and idle. It never removes a worktree directory
# itself, never runs `git worktree remove`, and never runs `rm -r`.
#
# A worktree is kept when it is the primary checkout, named by any surveyed
# home's `state/*.meta` `worktree=` line, has a live /proc cwd or fd path inside
# it, has tracked, untracked, or ignored changes, has commits not contained in
# any remote-tracking ref, has a git index lock or a flagged index path, or
# cannot be inspected. Inspection uses read-only git commands with
# `--no-optional-locks` so a survey does not write an index. Without /proc,
# every worktree is kept because idleness cannot be proven.
#
# Config grammar is one directive per line. `#` comments and blank lines are
# ignored. Paths are absolute, contain no whitespace, and are refused when they
# are `/`, `/mnt`, or anything under `/mnt`, or when any component is `data`,
# `.ssh`, `.aws`, `.kube`, `.gnupg`, `.mozilla`, `google-chrome`, `chromium`,
# `Brave-Browser`, or `BraveSoftware`.
#
#   home <path>
#   pool-root <path>
#   tmp <path> <days>
#   log <path> <days>
#   cache <name> <path> <days>
#   measure-only <category> <path>
#   procevent-result <days>
#   codex-sessions <days>
#   claude-sessions <path> <days>
#   cache-tool <npm|pip|uv|go> <path>
#
# `<days>` is an integer from 1 to 3650. `<name>` and `<category>` match
# `[A-Za-z0-9][A-Za-z0-9_-]*`. `home` and `pool-root` must exist and must not
# be symlinks. A deletion root inside a configured home is allowed only for
# that home's `.tmp`, `tmp`, or `state/logs`, or a directory under one of those.
# Other deletion roots must sit outside every configured home. A deletion root
# that is inside a git worktree is skipped rather than cleaned. Log roots only
# yield files named `*.log`, `*.log.N`, or `*.log.gz`. Dotenv variants,
# credential-bearing names, and certificate and key files are never deleted.
# `procevent-result` removes only an old handled inbox group whose source is
# not still registered, and only when none of that group's files are open.
# `claude-sessions` removes only old `*.jsonl` files that are not open, not
# inside a checkout, and whose first 8192 bytes do not name a surveyed one.
# `codex-sessions` runs `codex-session-prune` when that program is installed,
# passing `--dry-run` unless this command was given `--live`.
# `cache-tool` runs that tool's own purge bound to the configured directory
# (`npm --cache`, `PIP_CACHE_DIR`, `UV_CACHE_DIR`, or `GOCACHE`) and skips a
# store that has an open file, protected path, or checkout, or cannot be proved idle. Without `/proc`,
# those stores and the codex prune are skipped. Dry-run prints at most 30
# paths for the procevent and claude categories and still counts the rest.
# A live pool prune is bounded so a stuck prune cannot hold the cleanup open.
# Missing tmp, log, cache, session, and measure-only directories are reported
# absent and skipped. A missing home or pool-root refuses the run before any
# deletion.
#
# Copies a task record still names are kept, including when the pool walk did
# not list that copy. A file inside any checkout is never deleted, even when
# a deletion root contains that checkout. Pool slots are recognized when
# `.git` is on the slot or one directory deeper. Stopped Firstmate tasks stay
# with `fm-deadweight-sweep.sh`. Docker is measured when the client answers and
# is never pruned. `fm-clutter-check.sh` remains the read-only threshold check.
# Category totals overlap: do not add a path to its children.
#
# Output records are tab-separated:
#   measure phase=<before|after>
#   measure df mount=<m> size-kib=<n> used-kib=<n> avail-kib=<n> capacity=<pct>
#   measure path category=<c> bytes=<n|timeout|error|absent> path=<p>
#   measure docker status=<ok|unavailable> detail=<text>
#   measure note text=<text>
#   clean keep reason=<r> category=worktree path=<p>
#   clean would-delegate reason=landed-clean tool=fm-treehouse-guard.sh project=<p> bytes=<n|unknown> path=<wt>
#   clean would-free reason=aged-file category=<c> bytes=<n> age-days=<n> path=<p>
#   clean freed reason=aged-file category=<c> bytes=<n> age-days=<n> path=<p>
#   clean skip reason=<r> category=<c> path=<p>
#   clean category name=<c> files=<n> would-free-bytes=<n>
#   clean would-run tool=<name> path=<p> command=<text>
#   clean ran tool=<name> status=<n> path=<p>
#   clean external tool=<name> status=<n>
#   clean delegate-ran status=<n> project=<p>
#   summary mode=<dry-run|live> would-free-bytes=<n> freed-bytes=<n> delegate-upper-bound-bytes=<n> kept-worktrees=<n> candidate-worktrees=<n>
#
# Exit 0 means the survey finished. Exit 1 means the config or a path was
# refused, or a live deletion failed. Exit 2 means the command line was wrong.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

LIVE=0
MODE=
CONFIG=
WALK_CAP=20000
LIST_CAP=30
DU_SECS=120
GIT_SECS=60
NODE_CAP=10
NODE_SECS=8
DOCKER_SECS=15
DELEGATE_SECS=300
GUARD="$SCRIPT_DIR/fm-treehouse-guard.sh"

HOMES=()
POOLS=()
DEL_KIND=()
DEL_NAME=()
DEL_PATH=()
DEL_DAYS=()
MEAS_CAT=()
MEAS_PATH=()
CLAUDE_PATH=()
CLAUDE_DAYS=()
CACHE_NAME=()
CACHE_PATH=()
RESOLVED_DIR=
PROC_DAYS=
CODEX_DAYS=
NAMED=()
WT_PATH=()
WT_REASON=()
WT_ACTION=()
WT_PROJECT=()
WT_BYTES=()
SEEN_MOUNT_FILE=
LIVE_PATHS=
OPEN_INODES=
LOCK_DIR=
LOCK_FD=
WOULD_FREE=0
FREED=0
DELEGATE_BYTES=0
KEPT_WT=0
CAND_WT=0
UNLINK_ERRORS=0
PROC_LISTED=0
CLAUDE_LISTED=0

usage() {
  sed -n '2,/^set -euo pipefail/{ /^#/ {s/^# \{0,1\}//;p;} }' "$0"
}

die() {
  printf 'fm-data-manage: %s\n' "$1" >&2
  exit 1
}

die_usage() {
  usage >&2
  exit 2
}

emit() {
  printf '%s\n' "$1"
}

cleanup() {
  local old=
  if [ -n "$LOCK_DIR" ] && [ -f "$LOCK_DIR/pid" ]; then
    old=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if [ "$old" = "$$" ]; then
      rm -rf -- "$LOCK_DIR"
    fi
  fi
  [ -z "${WORK:-}" ] || rm -rf -- "$WORK"
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

file_bytes() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %z "$1" 2>/dev/null
  else
    stat -c %s "$1" 2>/dev/null
  fi
}

file_inode_key() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f '%d:%i' "$1" 2>/dev/null
  else
    stat -c '%d:%i' "$1" 2>/dev/null
  fi
}

physical_dir() {
  local p=$1
  [ -d "$p" ] && [ ! -L "$p" ] || return 1
  (cd -P -- "$p" && pwd -P)
}

token_ok() {
  case "$1" in
    [A-Za-z0-9][A-Za-z0-9_-]*) return 0 ;;
    *) return 1 ;;
  esac
}

days_ok() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 3650 ]
}

path_forbidden() {
  local p=$1 part
  case "$p" in
    /|/mnt|/mnt/*) return 0 ;;
    *[![:print:]]*) return 0 ;;
    *[[:space:]]*) return 0 ;;
  esac
  case "$p" in
    /*) ;;
    *) return 0 ;;
  esac
  p=${p#/}
  while [ -n "$p" ]; do
    part=${p%%/*}
    part=${part,,}
    case "$part" in
      data|.ssh|.aws|.azure|.kube|.gnupg|.docker|gcloud|gh|1password|..|.) return 0 ;;
      *chrome*|*chromium*|*edge*|*msedge*|*firefox*|*mozilla*|*brave*|*opera*|*vivaldi*|*safari*|*profile*|*cookies*|*history*|*login*data*|*local*state*|*keyring*|*keychain*) return 0 ;;
      .env*|*.env|*.env.*|*dotenv*|*cert*|*crt*|*pem*|*key*|*p12*|*pfx*|*jks*|*keystore*|*.cer|*.der|*.p8|*.p7b|*.p7c|*.pub|*token*|*oauth*|*credential*|*secret*|*auth*|*cookie*|*password*|*passwd*|.netrc|.npmrc|id_rsa|id_ed25519|id_ecdsa) return 0 ;;
    esac
    case "$p" in
      */*) p=${p#*/} ;;
      *) p= ;;
    esac
  done
  return 1
}

require_abs_path() {
  local p=$1 label=$2
  case "$p" in
    /*) ;;
    *) die "$label path is not an allowed absolute path: $p" ;;
  esac
  case "$p" in
    /|/mnt|/mnt/*|*[![:print:]]*|*[[:space:]]*) die "$label path is not an allowed absolute path: $p" ;;
    */) die "$label path must not end with a slash: $p" ;;
  esac
}

take_lock() {
  local pid_file old parent=${CONFIG%/*}
  [ -n "$parent" ] || parent=/
  exec {LOCK_FD}<"$parent" || die "could not open lock directory $parent"
  flock -n "$LOCK_FD" || die "another data-manage run holds ${CONFIG}.lock"
  LOCK_DIR="${CONFIG}.lock"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    old=
    [ -f "$LOCK_DIR/pid" ] && old=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    case "$old" in
      ''|*[!0-9]*) die "another data-manage run holds $LOCK_DIR" ;;
    esac
    if kill -0 "$old" 2>/dev/null; then
      die "another data-manage run holds $LOCK_DIR (pid $old)"
    fi
    rm -rf -- "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || die "could not take lock $LOCK_DIR"
  fi
  pid_file="$LOCK_DIR/pid"
  printf '%s\n' "$$" > "$pid_file" || die "could not record lock pid"
}

parse_config() {
  local line kind a b c nwords phys
  [ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] || die "config must be a regular file: $CONFIG"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      ''|\#*) continue ;;
      *'  '*) die "config line has consecutive spaces: $line" ;;
    esac
    set -f
    # shellcheck disable=SC2086
    set -- $line
    set +f
    nwords=$#
    kind=$1
    a=${2:-}
    b=${3:-}
    c=${4:-}
    case "$kind" in
      home)
        [ "$nwords" -eq 2 ] || die "home takes one path: $line"
        require_abs_path "$a" home
        phys=$(physical_dir "$a") || die "home is missing or is a symlink: $a"
        path_forbidden "$phys" && die "home is protected: $phys"
        HOMES+=("$phys")
        ;;
      pool-root)
        [ "$nwords" -eq 2 ] || die "pool-root takes one path: $line"
        require_abs_path "$a" pool-root
        phys=$(physical_dir "$a") || die "pool-root is missing or is a symlink: $a"
        path_forbidden "$phys" && die "pool-root is protected: $phys"
        POOLS+=("$phys")
        ;;
      tmp|log)
        [ "$nwords" -eq 3 ] || die "$kind takes a path and a day count: $line"
        require_abs_path "$a" "$kind"
        days_ok "$b" || die "$kind day count must be 1-3650: $line"
        DEL_KIND+=("$kind")
        DEL_NAME+=("$kind")
        DEL_PATH+=("$a")
        DEL_DAYS+=("$b")
        ;;
      cache)
        [ "$nwords" -eq 4 ] || die "cache takes a name, a path, and a day count: $line"
        token_ok "$a" || die "cache name is not a token: $line"
        require_abs_path "$b" cache
        days_ok "$c" || die "cache day count must be 1-3650: $line"
        DEL_KIND+=("cache")
        DEL_NAME+=("$a")
        DEL_PATH+=("$b")
        DEL_DAYS+=("$c")
        ;;
      measure-only)
        [ "$nwords" -eq 3 ] || die "measure-only takes a category and a path: $line"
        token_ok "$a" || die "measure-only category is not a token: $line"
        require_abs_path "$b" measure-only
        MEAS_CAT+=("$a")
        MEAS_PATH+=("$b")
        ;;
      procevent-result)
        [ "$nwords" -eq 2 ] || die "procevent-result takes a day count: $line"
        days_ok "$a" || die "procevent-result day count must be 1-3650: $line"
        [ -z "$PROC_DAYS" ] || die "procevent-result is set twice"
        PROC_DAYS=$a
        ;;
      codex-sessions)
        [ "$nwords" -eq 2 ] || die "codex-sessions takes a day count: $line"
        days_ok "$a" || die "codex-sessions day count must be 1-3650: $line"
        [ -z "$CODEX_DAYS" ] || die "codex-sessions is set twice"
        CODEX_DAYS=$a
        ;;
      claude-sessions)
        [ "$nwords" -eq 3 ] || die "claude-sessions takes a path and a day count: $line"
        require_abs_path "$a" claude-sessions
        days_ok "$b" || die "claude-sessions day count must be 1-3650: $line"
        CLAUDE_PATH+=("$a")
        CLAUDE_DAYS+=("$b")
        ;;
      cache-tool)
        [ "$nwords" -eq 3 ] || die "cache-tool takes a tool name and a path: $line"
        case "$a" in
          npm|pip|uv|go) ;;
          *) die "cache-tool name must be npm, pip, uv, or go: $line" ;;
        esac
        require_abs_path "$b" cache-tool
        CACHE_NAME+=("$a")
        CACHE_PATH+=("$b")
        ;;
      *) die "unknown config directive: $line" ;;
    esac
  done < "$CONFIG"
  [ "${#HOMES[@]}" -ge 1 ] || die "config must list at least one home"
}

deletion_root_allowed() {
  local path=$1 home
  local i=0
  root_contains_home "$path" && return 1
  while [ "$i" -lt "${#HOMES[@]}" ]; do
    home=${HOMES[$i]}
    case "$path" in
      "$home"|"$home"/*)
        case "$path" in
          "$home/.tmp"|"$home/.tmp"/*|"$home/tmp"|"$home/tmp"/*|"$home/state/logs"|"$home/state/logs"/*) ;;
          *) return 1 ;;
        esac
        ;;
    esac
    i=$((i + 1))
  done
  return 0
}

root_contains_home() {
  local root=$1 home
  for home in "${HOMES[@]}"; do
    case "$home" in "$root"|"$root"/*) return 0 ;; esac
  done
  return 1
}

resolve_deletion_roots() {
  local i=0 path phys
  while [ "$i" -lt "${#DEL_PATH[@]}" ]; do
    path=${DEL_PATH[$i]}
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
      emit "$(printf 'measure\tpath\tcategory=%s\tbytes=absent\tpath=%s' "${DEL_NAME[$i]}" "$path")"
      DEL_PATH[i]=
      i=$((i + 1))
      continue
    fi
    if [ -L "$path" ] || [ ! -d "$path" ]; then
      die "deletion root must be a real directory: $path"
    fi
    phys=$(physical_dir "$path") || die "deletion root must be a real directory: $path"
    if path_forbidden "$phys" || ! deletion_root_allowed "$phys"; then
      die "deletion root is protected or outside the allowed home directories: $phys"
    fi
    DEL_PATH[i]=$phys
    i=$((i + 1))
  done
}

resolve_real_dir() {
  local kind=$1 path=$2 phys
  RESOLVED_DIR=
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    emit "$(printf 'measure\tpath\tcategory=%s\tbytes=absent\tpath=%s' "$kind" "$path")"
    return 1
  fi
  if [ -L "$path" ] || [ ! -d "$path" ]; then
    die "$kind root must be a real directory: $path"
  fi
  phys=$(physical_dir "$path") || die "$kind root must be a real directory: $path"
  if path_forbidden "$phys" || ! deletion_root_allowed "$phys"; then
    die "$kind root is protected: $phys"
  fi
  RESOLVED_DIR=$phys
}

resolve_tool_roots() {
  local i=0 path
  while [ "$i" -lt "${#CLAUDE_PATH[@]}" ]; do
    path=${CLAUDE_PATH[$i]}
    if resolve_real_dir claude-sessions "$path"; then
      CLAUDE_PATH[i]=$RESOLVED_DIR
    else
      CLAUDE_PATH[i]=
    fi
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#CACHE_PATH[@]}" ]; do
    path=${CACHE_PATH[$i]}
    if resolve_real_dir "${CACHE_NAME[$i]}" "$path"; then
      CACHE_PATH[i]=$RESOLVED_DIR
    else
      CACHE_PATH[i]=
    fi
    i=$((i + 1))
  done
}

du_bytes() {
  local secs=$1 dir=$2 out rc=0
  out=$(fm_run_timed "$secs" du -sk -- "$dir" 2>/dev/null) || rc=$?
  if fm_timed_out "$rc"; then
    printf 'timeout\n'
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    printf 'error\n'
    return 0
  fi
  out=${out%%[!0-9]*}
  case "$out" in
    ''|*[!0-9]*) printf 'error\n' ;;
    *) printf '%s\n' $((out * 1024)) ;;
  esac
}

emit_du() {
  local category=$1 dir=$2 bytes
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    emit "$(printf 'measure\tpath\tcategory=%s\tbytes=absent\tpath=%s' "$category" "$dir")"
    return 0
  fi
  if [ -L "$dir" ]; then
    emit "$(printf 'measure\tpath\tcategory=%s\tbytes=error\tpath=%s' "$category" "$dir")"
    return 0
  fi
  bytes=$(du_bytes "$DU_SECS" "$dir")
  emit "$(printf 'measure\tpath\tcategory=%s\tbytes=%s\tpath=%s' "$category" "$bytes" "$dir")"
}

record_df() {
  local dir=$1 line mount size used avail cap
  [ -d "$dir" ] || return 0
  line=$(df -kP "$dir" 2>/dev/null | awk 'NR==2 { print }') || true
  [ -n "$line" ] || return 0
  mount=$(printf '%s\n' "$line" | awk '{
    for (i = 1; i <= NF; i++) if ($i ~ /%$/) { m = ""; for (j = i + 1; j <= NF; j++) m = m (j == i + 1 ? "" : " ") $j; print m; exit }
  }')
  [ -n "$mount" ] || return 0
  case "$mount" in
    /mnt|/mnt/*) return 0 ;;
  esac
  if [ -n "$SEEN_MOUNT_FILE" ] && grep -Fxq "$mount" "$SEEN_MOUNT_FILE"; then
    return 0
  fi
  printf '%s\n' "$mount" >> "$SEEN_MOUNT_FILE"
  size=$(printf '%s\n' "$line" | awk '{
    for (i = 1; i <= NF; i++) if ($i ~ /%$/) { print $(i - 3); exit }
  }')
  used=$(printf '%s\n' "$line" | awk '{
    for (i = 1; i <= NF; i++) if ($i ~ /%$/) { print $(i - 2); exit }
  }')
  avail=$(printf '%s\n' "$line" | awk '{
    for (i = 1; i <= NF; i++) if ($i ~ /%$/) { print $(i - 1); exit }
  }')
  cap=$(printf '%s\n' "$line" | awk '{
    for (i = 1; i <= NF; i++) if ($i ~ /%$/) { print $i; exit }
  }')
  emit "$(printf 'measure\tdf\tmount=%s\tsize-kib=%s\tused-kib=%s\tavail-kib=%s\tcapacity=%s' "$mount" "$size" "$used" "$avail" "$cap")"
}

measure_docker() {
  local out rc=0 detail
  if ! command -v docker >/dev/null 2>&1; then
    emit "measure	docker	status=unavailable	detail=docker-not-installed"
    return 0
  fi
  out=$(fm_run_timed "$DOCKER_SECS" docker system df --format '{{.Type}} {{.TotalCount}} {{.Size}} {{.Reclaimable}}' 2>/dev/null) || rc=$?
  if fm_timed_out "$rc" || [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    emit "measure	docker	status=unavailable	detail=docker-df-failed"
    return 0
  fi
  detail=$(printf '%s\n' "$out" | tr '\n' ';' | tr '\t' ' ')
  detail=${detail%;}
  emit "$(printf 'measure\tdocker\tstatus=ok\tdetail=%s' "$detail")"
}

measure_all() {
  local home pool i
  emit "measure	note	text=category totals overlap; do not add a path to its children"
  record_df /
  i=0
  while [ "$i" -lt "${#HOMES[@]}" ]; do
    home=${HOMES[$i]}
    record_df "$home"
    emit_du home "$home"
    emit_du projects "$home/projects"
    emit_du state "$home/state"
    emit_du procevent "$home/state/procevent"
    emit_du procevent-inbox "$home/state/procevent-inbox"
    emit_du data "$home/data"
    emit_du config "$home/config"
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#POOLS[@]}" ]; do
    pool=${POOLS[$i]}
    record_df "$pool"
    emit_du pool-root "$pool"
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#MEAS_PATH[@]}" ]; do
    record_df "${MEAS_PATH[$i]}"
    emit_du "${MEAS_CAT[$i]}" "${MEAS_PATH[$i]}"
    i=$((i + 1))
  done
  measure_docker
}

collect_named() {
  local home meta wt phys
  local i=0
  while [ "$i" -lt "${#HOMES[@]}" ]; do
    home=${HOMES[$i]}
    for meta in "$home"/state/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      wt=$(grep '^worktree=' "$meta" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)
      [ -n "$wt" ] || continue
      if [ -d "$wt" ] && [ ! -L "$wt" ]; then
        phys=$(physical_dir "$wt") || phys=$wt
        NAMED+=("$phys")
      else
        NAMED+=("$wt")
      fi
    done
    i=$((i + 1))
  done
}

named_has() {
  local want=$1 i=0
  while [ "$i" -lt "${#NAMED[@]}" ]; do
    [ "${NAMED[$i]}" = "$want" ] && return 0
    i=$((i + 1))
  done
  return 1
}

# stat of a /proc fd entry reports the procfs symlink inode, not the open file.
# Keys come from the readlink target. /proc is absent on Darwin, so the GNU
# xargs delimiter below is never used there.
collect_live_paths() {
  local ent target raw real
  LIVE_PATHS="$WORK/live-paths"
  OPEN_INODES="$WORK/open-inodes"
  raw="$WORK/live-raw"
  real="$WORK/live-real"
  : > "$raw"
  : > "$OPEN_INODES"
  : > "$LIVE_PATHS"
  [ -d /proc ] || return 0
  for ent in /proc/[0-9]*/cwd /proc/[0-9]*/fd/*; do
    [ -L "$ent" ] || continue
    target=$(readlink -- "$ent" 2>/dev/null) || continue
    case "$target" in
      /*) printf '%s\n' "$target" >> "$raw" ;;
    esac
  done
  sort -u -o "$raw" "$raw"
  [ -s "$raw" ] || return 0
  xargs -d $'\n' -r stat -c '%d:%i' -- < "$raw" > "$OPEN_INODES" 2>/dev/null || true
  sort -u -o "$OPEN_INODES" "$OPEN_INODES"
  if command -v realpath >/dev/null 2>&1; then
    xargs -d $'\n' -r realpath -e -- < "$raw" > "$real" 2>/dev/null || true
    sort -u -o "$LIVE_PATHS" "$raw" "$real"
  else
    sort -u -o "$LIVE_PATHS" "$raw"
  fi
}

path_is_live() {
  local wt=$1 live
  [ -d /proc ] || return 0
  [ -f "$LIVE_PATHS" ] || return 1
  while IFS= read -r live; do
    [ -n "$live" ] || continue
    case "$live" in
      "$wt"|"$wt"/*) return 0 ;;
    esac
  done < "$LIVE_PATHS"
  return 1
}

file_in_use() {
  local key output status dir base phys
  if [ -d /proc ]; then
    key=$(file_inode_key "$1" 2>/dev/null || true)
    [ -n "$key" ] || return 0
    if grep -Fxq -- "$key" "$OPEN_INODES"; then
      return 0
    fi
    if grep -Fxq -- "$1" "$LIVE_PATHS"; then
      return 0
    fi
    if [ ! -L "$1" ]; then
      dir=$(dirname -- "$1")
      base=$(basename -- "$1")
      phys=$(cd -P -- "$dir" 2>/dev/null && pwd -P) || phys=
      if [ -n "$phys" ] && grep -Fxq -- "$phys/$base" "$LIVE_PATHS"; then
        return 0
      fi
    fi
    return 1
  fi
  if command -v lsof >/dev/null 2>&1; then
    if output=$(lsof -- "$1" 2>&1); then
      return 0
    else
      status=$?
    fi
    [ "$status" -eq 1 ] && [ -z "$output" ] && return 1
    return 0
  fi
  return 0
}

file_in_use_now() {
  local output status
  file_in_use "$1" && return 0
  [ -d /proc ] || return 1
  if command -v lsof >/dev/null 2>&1; then
    if output=$(lsof -- "$1" 2>&1); then
      return 0
    else
      status=$?
    fi
    [ "$status" -eq 1 ] && [ -z "$output" ] && return 1
    return 0
  fi
  collect_live_paths
  file_in_use "$1"
}

already_have_wt() {
  local want=$1 i=0
  while [ "$i" -lt "${#WT_PATH[@]}" ]; do
    [ "${WT_PATH[$i]}" = "$want" ] && return 0
    i=$((i + 1))
  done
  return 1
}

project_of_worktree() {
  local wt=$1 common
  common=$(git --no-optional-locks -C "$wt" rev-parse --git-common-dir 2>/dev/null) || return 1
  if [ "${common#/}" = "$common" ]; then
    common=$(cd "$wt" && cd "$common" && pwd -P) || return 1
  else
    common=$(cd "$common" && pwd -P) || return 1
  fi
  case "$common" in
    */.git) printf '%s\n' "${common%/.git}" ;;
    *) printf '%s\n' "$common" ;;
  esac
}

home_project() {
  local project=$1 home
  local i=0
  while [ "$i" -lt "${#HOMES[@]}" ]; do
    home=${HOMES[$i]}
    case "$project" in
      "$home"/projects/*)
        [ -d "$project" ] && [ ! -L "$project" ] && printf '%s\n' "$project" && return 0
        ;;
    esac
    i=$((i + 1))
  done
  return 1
}

git_dirty() {
  local wt=$1 rc out
  rc=0
  git --no-optional-locks -C "$wt" diff --quiet >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *) return 2 ;;
  esac
  rc=0
  git --no-optional-locks -C "$wt" diff --cached --quiet >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *) return 2 ;;
  esac
  out=$(fm_run_timed "$GIT_SECS" git --no-optional-locks -C "$wt" ls-files --others --exclude-standard --directory 2>/dev/null) || return 2
  [ -z "$out" ] || return 0
  out=$(fm_run_timed "$GIT_SECS" git --no-optional-locks -C "$wt" ls-files --others --ignored --exclude-standard --directory 2>/dev/null) || return 2
  [ -z "$out" ] || return 0
  return 1
}

git_unpushed() {
  local wt=$1 out rc=0
  out=$(fm_run_timed "$GIT_SECS" git --no-optional-locks -C "$wt" rev-list -n 1 HEAD --not --remotes 2>/dev/null) || rc=$?
  if fm_timed_out "$rc" || [ "$rc" -ne 0 ]; then
    return 2
  fi
  [ -n "$out" ]
}

classify_one() {
  local wt=$1 reason=landed-clean action=candidate project="" gitdir common flagged rc
  if [ ! -d "$wt" ] || [ -L "$wt" ]; then
    reason=missing-or-link
    action=keep
  elif ! project=$(project_of_worktree "$wt"); then
    reason=inspect-failed
    action=keep
    project=
  elif named_has "$wt"; then
    reason=named-by-task-record
    action=keep
  elif [ ! -d /proc ]; then
    reason=cannot-prove-idle
    action=keep
  elif path_is_live "$wt"; then
    reason="live-process"
    action=keep
  else
    gitdir=$(git --no-optional-locks -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) || gitdir=
    common=$(git --no-optional-locks -C "$wt" rev-parse --git-common-dir 2>/dev/null) || common=
    if [ -z "$gitdir" ] || [ -z "$common" ]; then
      reason=inspect-failed
      action=keep
    else
      if [ "${common#/}" = "$common" ]; then
        common=$(cd "$wt" && cd "$common" && pwd -P) || common=
      else
        common=$(cd "$common" && pwd -P) || common=
      fi
      gitdir=$(cd "$gitdir" && pwd -P) || gitdir=
      if [ -z "$gitdir" ] || [ -z "$common" ]; then
        reason=inspect-failed
        action=keep
      elif [ "$gitdir" = "$common" ]; then
        reason=primary-checkout
        action=keep
      elif [ -e "$gitdir/index.lock" ]; then
        reason=git-lock
        action=keep
      else
        flagged=$(git --no-optional-locks -C "$wt" ls-files -v 2>/dev/null) || flagged='?'
        if [ "$flagged" = '?' ]; then
          reason=inspect-failed
          action=keep
        elif printf '%s\n' "$flagged" | grep -qE '^([a-z]|S) '; then
          reason="flagged-paths"
          action=keep
        else
          rc=0
          git_dirty "$wt" || rc=$?
          case "$rc" in
            0)
              reason=uncommitted-changes
              action=keep
              ;;
            1)
              rc=0
              if git_unpushed "$wt"; then
                reason=commits-not-on-remote
                action=keep
              else
                rc=$?
                if [ "$rc" -eq 2 ]; then
                  reason=inspect-failed
                  action=keep
                fi
              fi
              ;;
            *)
              reason=inspect-failed
              action=keep
              ;;
          esac
        fi
      fi
    fi
  fi
  if [ "$action" = candidate ]; then
    if ! home_project "$project" >/dev/null; then
      reason=no-guarded-path
      action=keep
    fi
  fi
  WT_PATH+=("$wt")
  WT_REASON+=("$reason")
  WT_ACTION+=("$action")
  WT_PROJECT+=("$project")
  WT_BYTES+=("")
}

add_worktree() {
  local path=$1 phys
  [ -n "$path" ] || return 0
  if [ -d "$path" ] && [ ! -L "$path" ]; then
    phys=$(physical_dir "$path") || phys=$path
  else
    phys=$path
  fi
  already_have_wt "$phys" && return 0
  classify_one "$phys"
}

survey_project_worktrees() {
  local project=$1 field path=
  local list="$WORK/worktrees"
  fm_run_timed "$GIT_SECS" git --no-optional-locks -C "$project" worktree list --porcelain -z > "$list" 2>/dev/null || {
    emit "$(printf 'clean\tskip\treason=worktree-list-failed\tcategory=worktree\tpath=%s' "$project")"
    return 0
  }
  while IFS= read -r -d '' field; do
    case "$field" in
      '') path= ;;
      worktree\ *) path=${field#worktree } ;;
      *) ;;
    esac
    case "$field" in
      ''|worktree\ *)
        [ -n "$path" ] || continue
        add_worktree "$path"
        path=
        ;;
    esac
  done < "$list"
}

survey_worktrees() {
  local home project pool child slot repo
  local i=0
  while [ "$i" -lt "${#HOMES[@]}" ]; do
    home=${HOMES[$i]}
    [ -d "$home/projects" ] || { i=$((i + 1)); continue; }
    for project in "$home"/projects/*; do
      [ -d "$project" ] && [ ! -L "$project" ] || continue
      git --no-optional-locks -C "$project" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
      survey_project_worktrees "$project"
    done
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#POOLS[@]}" ]; do
    pool=${POOLS[$i]}
    for child in "$pool"/*; do
      [ -d "$child" ] && [ ! -L "$child" ] || continue
      for slot in "$child"/*; do
        [ -d "$slot" ] && [ ! -L "$slot" ] || continue
        if [ -e "$slot/.git" ]; then
          git --no-optional-locks -C "$slot" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
          add_worktree "$slot"
          continue
        fi
        for repo in "$slot"/*; do
          [ -d "$repo" ] && [ ! -L "$repo" ] || continue
          if [ -e "$repo/.git" ]; then
            git --no-optional-locks -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
            add_worktree "$repo"
          fi
        done
      done
    done
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#NAMED[@]}" ]; do
    add_worktree "${NAMED[$i]}"
    i=$((i + 1))
  done
}

task_named_project() {
  local project=$1 i=0
  while [ "$i" -lt "${#WT_PATH[@]}" ]; do
    if [ "${WT_PROJECT[$i]}" = "$project" ] && [ "${WT_REASON[$i]}" = named-by-task-record ]; then
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

finalize_worktrees() {
  local i=0 project bytes
  while [ "$i" -lt "${#WT_PATH[@]}" ]; do
    if [ "${WT_ACTION[$i]}" = candidate ]; then
      project=${WT_PROJECT[$i]}
      if task_named_project "$project"; then
        WT_ACTION[i]=keep
        WT_REASON[i]="task-record-in-project"
      fi
    fi
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#WT_PATH[@]}" ]; do
    if [ "${WT_ACTION[$i]}" = keep ]; then
      KEPT_WT=$((KEPT_WT + 1))
      emit "$(printf 'clean\tkeep\treason=%s\tcategory=worktree\tpath=%s' "${WT_REASON[$i]}" "${WT_PATH[$i]}")"
    else
      CAND_WT=$((CAND_WT + 1))
      bytes=$(du_bytes 20 "${WT_PATH[$i]}")
      case "$bytes" in
        ''|*[!0-9]*) bytes=unknown ;;
        *) DELEGATE_BYTES=$((DELEGATE_BYTES + bytes)) ;;
      esac
      WT_BYTES[i]=$bytes
      emit "$(printf 'clean\twould-delegate\treason=landed-clean\ttool=fm-treehouse-guard.sh\tproject=%s\tbytes=%s\tpath=%s' "${WT_PROJECT[$i]}" "$bytes" "${WT_PATH[$i]}")"
    fi
    i=$((i + 1))
  done
}

measure_node_modules() {
  local i=0 n=0 bytes wt
  while [ "$i" -lt "${#WT_PATH[@]}" ] && [ "$n" -lt "$NODE_CAP" ]; do
    wt=${WT_PATH[$i]}
    if [ -d "$wt/node_modules" ] && [ ! -L "$wt/node_modules" ]; then
      bytes=$(du_bytes "$NODE_SECS" "$wt/node_modules")
      emit "$(printf 'measure\tpath\tcategory=node_modules\tbytes=%s\tpath=%s' "$bytes" "$wt/node_modules")"
      n=$((n + 1))
    fi
    i=$((i + 1))
  done
  if [ "$i" -lt "${#WT_PATH[@]}" ]; then
    emit "measure	note	text=node_modules survey stopped at the cap"
  fi
}

root_inside_worktree() {
  git --no-optional-locks -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

log_name_ok() {
  case "$1" in
    *.log|*.log.[0-9]|*.log.[0-9][0-9]|*.log.gz) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup_file_safe() {
  local file=$1 root=$2 dir base phys wt i=0
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  dir=$(physical_dir "${file%/*}") || return 1
  base=${file##*/}
  phys=$dir/$base
  case "$phys" in "$root"/*) ;; *) return 1 ;; esac
  path_forbidden "$phys" && return 1
  while [ "$i" -lt "${#WT_PATH[@]}" ]; do
    wt=${WT_PATH[$i]}
    case "$phys" in "$wt"|"$wt"/*) return 1 ;; esac
    i=$((i + 1))
  done
  while :; do
    [ ! -e "$dir/.git" ] && [ ! -L "$dir/.git" ] || return 1
    [ "$dir" = "$root" ] && break
    dir=${dir%/*}
  done
  return 0
}

cache_store_safe() {
  local root=$1 path phys walked=0 list=$WORK/cache-paths
  root_inside_worktree "$root" && return 1
  find -P "$root" -xdev -print0 > "$list" 2>/dev/null || return 1
  while IFS= read -r -d '' path; do
    walked=$((walked + 1))
    [ "$walked" -le "$WALK_CAP" ] || return 1
    [ ! -L "$path" ] || return 1
    if [ -f "$path" ]; then
      cleanup_file_safe "$path" "$root" || return 1
    elif [ -d "$path" ]; then
      phys=$(physical_dir "$path") || return 1
      case "$phys" in "$root"|"$root"/*) ;; *) return 1 ;; esac
      path_forbidden "$phys" && return 1
      [ ! -e "$path/.git" ] && [ ! -L "$path/.git" ] || return 1
    else
      return 1
    fi
  done < "$list"
  return 0
}

add_category_bytes() {
  local name=$1 bytes=$2 i=0
  while [ "$i" -lt "${#CAT_NAME[@]}" ]; do
    if [ "${CAT_NAME[$i]}" = "$name" ]; then
      CAT_FILES[i]=$((CAT_FILES[i] + 1))
      CAT_BYTES[i]=$((CAT_BYTES[i] + bytes))
      return 0
    fi
    i=$((i + 1))
  done
  CAT_NAME+=("$name")
  CAT_FILES+=(1)
  CAT_BYTES+=("$bytes")
}

CAT_NAME=()
CAT_FILES=()
CAT_BYTES=()

note_category() {
  local name=$1
  local i=0
  while [ "$i" -lt "${#CAT_NAME[@]}" ]; do
    [ "${CAT_NAME[$i]}" = "$name" ] && return 0
    i=$((i + 1))
  done
  CAT_NAME+=("$name")
  CAT_FILES+=(0)
  CAT_BYTES+=(0)
}

root_owns_file() {
  local file=$1 owner=$2 i=0 root
  while [ "$i" -lt "${#DEL_PATH[@]}" ]; do
    root=${DEL_PATH[$i]}
    if [ -n "$root" ] && [ "$i" -ne "$owner" ]; then
      case "$file" in
        "$root"/*)
          if [ "${DEL_KIND[$i]}" != log ] || log_name_ok "${file##*/}"; then
            if [ "${DEL_DAYS[$i]}" -gt "${DEL_DAYS[$owner]}" ] ||
              { [ "${DEL_DAYS[$i]}" -eq "${DEL_DAYS[$owner]}" ] && [ "$i" -lt "$owner" ]; }; then
              return 1
            fi
          fi
          ;;
      esac
    fi
    i=$((i + 1))
  done
  return 0
}

scan_root() {
  local kind=$1 name=$2 root=$3 days=$4 owner=$5
  local now file base age mtime bytes listed=0 walked=0 rc
  now=$(date +%s)
  note_category "$name"
  if root_inside_worktree "$root"; then
    emit "$(printf 'clean\tskip\treason=inside-worktree\tcategory=%s\tpath=%s' "$name" "$root")"
    return 0
  fi
  while IFS= read -r -d '' file; do
    walked=$((walked + 1))
    if [ "$walked" -gt "$WALK_CAP" ]; then
      emit "$(printf 'clean\tskip\treason=walk-cap\tcategory=%s\tpath=%s' "$name" "$root")"
      break
    fi
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    base=${file##*/}
    cleanup_file_safe "$file" "$root" || continue
    root_owns_file "$file" "$owner" || continue
    if [ "$kind" = log ] && ! log_name_ok "$base"; then
      continue
    fi
    mtime=$(file_mtime "$file" 2>/dev/null || true)
    case "$mtime" in
      ''|*[!0-9]*) continue ;;
    esac
    age=$((now - mtime))
    [ "$age" -ge $((days * 86400)) ] || continue
    if file_in_use "$file"; then
      continue
    fi
    bytes=$(file_bytes "$file" 2>/dev/null || true)
    case "$bytes" in
      ''|*[!0-9]*) continue ;;
    esac
    # Re-check immediately before any unlink so a swapped symlink is not removed as a file.
    cleanup_file_safe "$file" "$root" || continue
    if [ "$LIVE" -eq 1 ]; then
      file_in_use_now "$file" && continue
      rc=0
      rm -f -- "$file" || rc=$?
      if [ "$rc" -ne 0 ] || [ -e "$file" ]; then
        UNLINK_ERRORS=$((UNLINK_ERRORS + 1))
        emit "$(printf 'clean\tskip\treason=unlink-failed\tcategory=%s\tpath=%s' "$name" "$file")"
        continue
      fi
      FREED=$((FREED + bytes))
      emit "$(printf 'clean\tfreed\treason=aged-file\tcategory=%s\tbytes=%s\tage-days=%s\tpath=%s' "$name" "$bytes" $((age / 86400)) "$file")"
    else
      listed=$((listed + 1))
      if [ "$listed" -le "$LIST_CAP" ]; then
        emit "$(printf 'clean\twould-free\treason=aged-file\tcategory=%s\tbytes=%s\tage-days=%s\tpath=%s' "$name" "$bytes" $((age / 86400)) "$file")"
      fi
    fi
    WOULD_FREE=$((WOULD_FREE + bytes))
    add_category_bytes "$name" "$bytes"
  done < <(find -P "$root" -xdev \( -name .ssh -o -name .aws -o -name .kube -o -name .gnupg -o -name .mozilla -o -name google-chrome -o -name chromium -o -name Brave-Browser -o -name BraveSoftware -o -name data \) -prune -o -type f -print0 2>/dev/null)
  if [ "$LIVE" -eq 0 ] && [ "$listed" -gt "$LIST_CAP" ]; then
    emit "$(printf 'clean\tskip\treason=list-cap\tcategory=%s\tpath=%s' "$name" "$root")"
  fi
}

emit_categories() {
  local i=0
  while [ "$i" -lt "${#CAT_NAME[@]}" ]; do
    emit "$(printf 'clean\tcategory\tname=%s\tfiles=%s\twould-free-bytes=%s' "${CAT_NAME[$i]}" "${CAT_FILES[$i]}" "${CAT_BYTES[$i]}")"
    i=$((i + 1))
  done
}

home_for_project() {
  local project=$1 home i=0
  while [ "$i" -lt "${#HOMES[@]}" ]; do
    home=${HOMES[$i]}
    case "$project" in
      "$home"/projects/*)
        printf '%s\n' "$home"
        return 0
        ;;
    esac
    i=$((i + 1))
  done
  return 1
}

delegate_live() {
  local i=0 project seen home ran=""
  while [ "$i" -lt "${#WT_PATH[@]}" ]; do
    if [ "${WT_ACTION[$i]}" = candidate ]; then
      project=${WT_PROJECT[$i]}
      case $'\n'"$ran"$'\n' in
        *$'\n'"$project"$'\n'*) ;;
        *)
          home=$(home_for_project "$project") || home=
          seen=0
          if [ -n "$home" ]; then
            fm_run_timed "$DELEGATE_SECS" env FM_HOME="$home" FM_TREEHOUSE_GUARD_PRUNE_SECS=240 \
              bash "$GUARD" prune "$project" > "$WORK/delegate" 2>&1 || seen=$?
          else
            seen=1
          fi
          emit "$(printf 'clean\tdelegate-ran\tstatus=%s\tproject=%s' "$seen" "$project")"
          ran="${ran}"$'\n'"$project"
          ;;
      esac
    fi
    i=$((i + 1))
  done
}

path_has_live_child() {
  local root=$1 live
  # No process table means the store cannot be proved idle.
  [ -d /proc ] || return 0
  [ -f "$LIVE_PATHS" ] || return 1
  while IFS= read -r live; do
    [ -n "$live" ] || continue
    case "$live" in
      "$root"|"$root"/*) return 0 ;;
    esac
  done < "$LIVE_PATHS"
  return 1
}

write_session_names() {
  local i=0
  : > "$WORK/session-names"
  while [ "$i" -lt "${#NAMED[@]}" ]; do
    [ -n "${NAMED[$i]}" ] && printf '%s\n' "${NAMED[$i]}" >> "$WORK/session-names"
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#WT_PATH[@]}" ]; do
    [ -n "${WT_PATH[$i]}" ] && printf '%s\n' "${WT_PATH[$i]}" >> "$WORK/session-names"
    i=$((i + 1))
  done
  sort -u -o "$WORK/session-names" "$WORK/session-names"
}

# Return 0 when the file must be kept: unreadable, or its first 8192 bytes
# name a task worktree or any surveyed worktree. Return 1 when they do not.
session_names_worktree() {
  local file=$1 chunk
  chunk=$(head -c 8192 -- "$file" 2>/dev/null) || return 0
  [ -n "$chunk" ] || return 1
  [ -s "$WORK/session-names" ] || return 1
  printf '%s' "$chunk" | grep -F -q -f "$WORK/session-names" && return 0
  return 1
}

procevent_group_old() {
  local inbox=$1 stem=$2 days=$3 now=$4 suffix f mtime age
  PROC_GROUP_FILES=()
  for suffix in result adapter handled; do
    f="$inbox/$stem.$suffix"
    [ -f "$f" ] && [ ! -L "$f" ] || return 1
    PROC_GROUP_FILES+=("$f")
  done
  for suffix in owner-task extension; do
    f="$inbox/$stem.$suffix"
    if [ -e "$f" ] || [ -L "$f" ]; then
      [ -f "$f" ] && [ ! -L "$f" ] || return 1
      PROC_GROUP_FILES+=("$f")
    fi
  done
  for f in "${PROC_GROUP_FILES[@]}"; do
    mtime=$(file_mtime "$f" 2>/dev/null || true)
    case "$mtime" in
      ''|*[!0-9]*) return 1 ;;
    esac
    age=$((now - mtime))
    [ "$age" -ge $((days * 86400)) ] || return 1
  done
  return 0
}

emit_or_free_file() {
  local category=$1 file=$2 now=$3 bucket=$4 root=$5
  local mtime age bytes rc base
  base=${file##*/}
  cleanup_file_safe "$file" "$root" || return 0
  file_in_use "$file" && return 0
  mtime=$(file_mtime "$file" 2>/dev/null || true)
  case "$mtime" in
    ''|*[!0-9]*) return 0 ;;
  esac
  age=$((now - mtime))
  bytes=$(file_bytes "$file" 2>/dev/null || true)
  case "$bytes" in
    ''|*[!0-9]*) return 0 ;;
  esac
  cleanup_file_safe "$file" "$root" || return 0
  if [ "$LIVE" -eq 1 ]; then
    file_in_use_now "$file" && return 0
    rc=0
    rm -f -- "$file" || rc=$?
    if [ "$rc" -ne 0 ] || [ -e "$file" ]; then
      UNLINK_ERRORS=$((UNLINK_ERRORS + 1))
      emit "$(printf 'clean\tskip\treason=unlink-failed\tcategory=%s\tpath=%s' "$category" "$file")"
      return 0
    fi
    FREED=$((FREED + bytes))
    WOULD_FREE=$((WOULD_FREE + bytes))
    add_category_bytes "$category" "$bytes"
    emit "$(printf 'clean\tfreed\treason=aged-file\tcategory=%s\tbytes=%s\tage-days=%s\tpath=%s' "$category" "$bytes" $((age / 86400)) "$file")"
    return 0
  fi
  WOULD_FREE=$((WOULD_FREE + bytes))
  add_category_bytes "$category" "$bytes"
  case "$bucket" in
    proc)
      PROC_LISTED=$((PROC_LISTED + 1))
      [ "$PROC_LISTED" -le "$LIST_CAP" ] || return 0
      ;;
    claude)
      CLAUDE_LISTED=$((CLAUDE_LISTED + 1))
      [ "$CLAUDE_LISTED" -le "$LIST_CAP" ] || return 0
      ;;
  esac
  emit "$(printf 'clean\twould-free\treason=aged-file\tcategory=%s\tbytes=%s\tage-days=%s\tpath=%s' "$category" "$bytes" $((age / 86400)) "$file")"
}

clean_procevent() {
  local home i inbox handled base stem id now f busy phys
  [ -n "$PROC_DAYS" ] || return 0
  now=$(date +%s)
  i=0
  while [ "$i" -lt "${#HOMES[@]}" ]; do
    home=${HOMES[$i]}
    inbox="$home/state/procevent-inbox"
    if [ -d "$inbox" ] && [ ! -L "$inbox" ]; then
      phys=$(physical_dir "$inbox") || { i=$((i + 1)); continue; }
      if path_forbidden "$phys" || root_inside_worktree "$phys"; then
        i=$((i + 1))
        continue
      fi
      inbox=$phys
      for handled in "$inbox"/*.handled; do
        [ -f "$handled" ] && [ ! -L "$handled" ] || continue
        base=${handled##*/}
        stem=${base%.handled}
        id=${stem%.*}
        [ -n "$id" ] && [ "$id" != "$stem" ] || continue
        case "$id" in
          */*|*[!A-Za-z0-9._-]*) continue ;;
        esac
        if [ -e "$home/state/procevent/$id.source" ] || [ -L "$home/state/procevent/$id.source" ]; then
          emit "$(printf 'clean\tskip\treason=live-source\tcategory=procevent-result\tpath=%s' "$handled")"
          continue
        fi
        procevent_group_old "$inbox" "$stem" "$PROC_DAYS" "$now" || continue
        busy=0
        for f in "${PROC_GROUP_FILES[@]}"; do
          if file_in_use_now "$f"; then
            busy=1
          fi
        done
        if [ "$busy" -eq 1 ]; then
          emit "$(printf 'clean\tskip\treason=in-use\tcategory=procevent-result\tpath=%s' "$handled")"
          continue
        fi
        for f in "${PROC_GROUP_FILES[@]}"; do
          emit_or_free_file procevent-result "$f" "$now" proc "$inbox"
        done
      done
    fi
    i=$((i + 1))
  done
  if [ "$LIVE" -eq 0 ] && [ "$PROC_LISTED" -gt "$LIST_CAP" ]; then
    emit "clean	skip	reason=list-cap	category=procevent-result	path=procevent-result"
  fi
}

clean_claude_sessions() {
  local i=0 root days now file base age mtime walked rc
  now=$(date +%s)
  write_session_names
  while [ "$i" -lt "${#CLAUDE_PATH[@]}" ]; do
    root=${CLAUDE_PATH[$i]}
    days=${CLAUDE_DAYS[$i]}
    if [ -z "$root" ]; then
      i=$((i + 1))
      continue
    fi
    if root_inside_worktree "$root"; then
      emit "$(printf 'clean\tskip\treason=inside-worktree\tcategory=claude-sessions\tpath=%s' "$root")"
      i=$((i + 1))
      continue
    fi
    walked=0
    while IFS= read -r -d '' file; do
      walked=$((walked + 1))
      if [ "$walked" -gt "$WALK_CAP" ]; then
        emit "$(printf 'clean\tskip\treason=walk-cap\tcategory=claude-sessions\tpath=%s' "$root")"
        break
      fi
      [ -f "$file" ] && [ ! -L "$file" ] || continue
      base=${file##*/}
      cleanup_file_safe "$file" "$root" || continue
      case "$base" in
        *.jsonl) ;;
        *) continue ;;
      esac
      mtime=$(file_mtime "$file" 2>/dev/null || true)
      case "$mtime" in
        ''|*[!0-9]*) continue ;;
      esac
      age=$((now - mtime))
      [ "$age" -ge $((days * 86400)) ] || continue
      file_in_use "$file" && continue
      rc=0
      session_names_worktree "$file" || rc=$?
      [ "$rc" -eq 1 ] || continue
      emit_or_free_file claude-sessions "$file" "$now" claude "$root"
    done < <(find -P "$root" -xdev \( -name .ssh -o -name .aws -o -name .kube -o -name .gnupg -o -name .mozilla -o -name google-chrome -o -name chromium -o -name Brave-Browser -o -name BraveSoftware -o -name data \) -prune -o -type f -name '*.jsonl' -print0 2>/dev/null)
    i=$((i + 1))
  done
  if [ "$LIVE" -eq 0 ] && [ "$CLAUDE_LISTED" -gt "$LIST_CAP" ]; then
    emit "clean	skip	reason=list-cap	category=claude-sessions	path=claude-sessions"
  fi
}

clean_codex_sessions() {
  local tool rc=0 line n=0
  [ -n "$CODEX_DAYS" ] || return 0
  if [ ! -d /proc ]; then
    emit "clean	skip	reason=cannot-prove-idle	category=codex-sessions	path=codex-session-prune"
    return 0
  fi
  tool=$(command -v codex-session-prune 2>/dev/null || true)
  if [ -z "$tool" ]; then
    emit "clean	skip	reason=tool-missing	category=codex-sessions	path=codex-session-prune"
    return 0
  fi
  if [ "$LIVE" -eq 1 ]; then
    fm_run_timed 180 "$tool" --days "$CODEX_DAYS" > "$WORK/codex-out" 2>&1 || rc=$?
  else
    fm_run_timed 180 "$tool" --days "$CODEX_DAYS" --dry-run > "$WORK/codex-out" 2>&1 || rc=$?
  fi
  emit "$(printf 'clean\texternal\ttool=codex-session-prune\tstatus=%s' "$rc")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    [ "$n" -le 20 ] || break
    line=$(printf '%s' "$line" | tr '\t\r' '  ')
    emit "$(printf 'clean\texternal-line\ttool=codex-session-prune\ttext=%s' "$line")"
  done < "$WORK/codex-out"
}

clean_cache_tools() {
  local i=0 name path rc toolbin shown
  while [ "$i" -lt "${#CACHE_PATH[@]}" ]; do
    name=${CACHE_NAME[$i]}
    path=${CACHE_PATH[$i]}
    if [ -z "$path" ]; then
      i=$((i + 1))
      continue
    fi
    if [ ! -d /proc ] || path_has_live_child "$path" || ! cache_store_safe "$path"; then
      emit "$(printf 'clean\tskip\treason=in-use\tcategory=%s\tpath=%s' "$name" "$path")"
      i=$((i + 1))
      continue
    fi
    toolbin=
    shown=
    case "$name" in
      npm)
        toolbin=npm
        shown="npm cache clean --force --cache $path"
        ;;
      pip)
        if command -v pip3 >/dev/null 2>&1; then
          toolbin=pip3
        elif command -v pip >/dev/null 2>&1; then
          toolbin=pip
        fi
        shown="env PIP_CACHE_DIR=$path ${toolbin:-pip} cache purge"
        ;;
      uv)
        toolbin=uv
        shown="env UV_CACHE_DIR=$path uv cache clean"
        ;;
      go)
        toolbin=go
        shown="env GOCACHE=$path go clean -cache"
        ;;
    esac
    if [ -z "$toolbin" ] || ! command -v "$toolbin" >/dev/null 2>&1; then
      emit "$(printf 'clean\tskip\treason=tool-missing\tcategory=%s\tpath=%s' "$name" "$path")"
      i=$((i + 1))
      continue
    fi
    if [ "$LIVE" -eq 0 ]; then
      emit "$(printf 'clean\twould-run\ttool=%s\tpath=%s\tcommand=%s' "$name" "$path" "$shown")"
    else
      collect_live_paths
      if path_has_live_child "$path"; then
        emit "$(printf 'clean\tskip\treason=in-use\tcategory=%s\tpath=%s' "$name" "$path")"
        i=$((i + 1))
        continue
      fi
      rc=0
      case "$name" in
        npm) fm_run_timed 180 npm cache clean --force --cache "$path" >/dev/null 2>&1 || rc=$? ;;
        pip) fm_run_timed 180 env PIP_CACHE_DIR="$path" "$toolbin" cache purge >/dev/null 2>&1 || rc=$? ;;
        uv) fm_run_timed 180 env UV_CACHE_DIR="$path" uv cache clean >/dev/null 2>&1 || rc=$? ;;
        go) fm_run_timed 180 env GOCACHE="$path" go clean -cache >/dev/null 2>&1 || rc=$? ;;
      esac
      emit "$(printf 'clean\tran\ttool=%s\tstatus=%s\tpath=%s' "$name" "$rc" "$path")"
    fi
    i=$((i + 1))
  done
}

run_clean_actions() {
  local i=0
  while [ "$i" -lt "${#DEL_PATH[@]}" ]; do
    [ -n "${DEL_PATH[$i]}" ] || { i=$((i + 1)); continue; }
    scan_root "${DEL_KIND[$i]}" "${DEL_NAME[$i]}" "${DEL_PATH[$i]}" "${DEL_DAYS[$i]}" "$i"
    i=$((i + 1))
  done
  clean_procevent
  clean_claude_sessions
  clean_codex_sessions
  clean_cache_tools
  if [ "$LIVE" -eq 1 ]; then
    delegate_live
  fi
}

main() {
  local cmd=${1:-} marker
  shift || true
  case "$cmd" in
    --help|-h|help) usage; exit 0 ;;
    measure|clean) MODE=$cmd ;;
    '') die_usage ;;
    *) die_usage ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config)
        [ "$#" -ge 2 ] || die_usage
        CONFIG=$2
        shift 2
        ;;
      --live)
        [ "$MODE" = clean ] || die "--live is only valid with clean"
        LIVE=1
        shift
        ;;
      --help|-h) usage; exit 0 ;;
      *) die_usage ;;
    esac
  done
  [ -n "$CONFIG" ] || die_usage
  case "$CONFIG" in
    /*) ;;
    *) die "config path must be absolute: $CONFIG" ;;
  esac
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-data-manage.XXXXXX") || die "could not create a work directory"
  SEEN_MOUNT_FILE="$WORK/mounts"
  : > "$SEEN_MOUNT_FILE"
  trap cleanup EXIT
  trap 'exit 1' HUP INT TERM
  take_lock
  parse_config
  if [ "$LIVE" -eq 1 ]; then
    marker=${HOMES[0]}/config/data-management.live-authorized
    if [ -e "${HOMES[0]}/.fm-secondmate-parent" ] || [ -L "${HOMES[0]}/.fm-secondmate-parent" ] ||
      [ ! -f "$marker" ] || [ -L "$marker" ] || [ -L "${HOMES[0]}/config" ]; then
      LIVE=0
      emit "$(printf 'clean\tskip\treason=first-live-not-authorized')"
    fi
  fi
  resolve_deletion_roots
  resolve_tool_roots
  emit "$(printf 'measure\tphase=before')"
  measure_all
  if [ "$MODE" = measure ]; then
    exit 0
  fi
  collect_named
  collect_live_paths
  survey_worktrees
  finalize_worktrees
  measure_node_modules
  run_clean_actions
  emit_categories
  if [ "$LIVE" -eq 1 ]; then
    emit "$(printf 'measure\tphase=after')"
    : > "$SEEN_MOUNT_FILE"
    measure_all
    emit "$(printf 'summary\tmode=live\twould-free-bytes=%s\tfreed-bytes=%s\tdelegate-upper-bound-bytes=%s\tkept-worktrees=%s\tcandidate-worktrees=%s' "$WOULD_FREE" "$FREED" "$DELEGATE_BYTES" "$KEPT_WT" "$CAND_WT")"
  else
    emit "$(printf 'summary\tmode=dry-run\twould-free-bytes=%s\tfreed-bytes=0\tdelegate-upper-bound-bytes=%s\tkept-worktrees=%s\tcandidate-worktrees=%s' "$WOULD_FREE" "$DELEGATE_BYTES" "$KEPT_WT" "$CAND_WT")"
  fi
  [ "$UNLINK_ERRORS" -eq 0 ] || exit 1
}

main "$@"
