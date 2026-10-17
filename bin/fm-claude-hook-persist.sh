#!/usr/bin/env bash
# fm-claude-hook-persist.sh - keep a large Claude hook body when the project
# directory is a symlink.
#
# Claude Code walks $CLAUDE_CONFIG_DIR/projects (or ~/.claude/projects) with
# lstat and refuses to persist hook output above 10000 characters when any
# component under that directory is a symlink. A symlink at the project
# directory is the case that drops a session-start digest.
# This script reads the hook body on stdin. When that refusal would apply, it
# writes the full body through the symlink and prints a short pointer the
# harness can keep inline. Every other body is copied to stdout unchanged.
#
# Usage: fm-claude-hook-persist.sh [--cwd DIR] [--session-id ID]
#   --cwd         Directory whose Claude project key is checked. Default: $PWD.
#   --session-id  Session directory name under the project directory. Optional.
# The project key matches Claude Code: non-alphanumerics become '-', and a key
# longer than 200 characters keeps the first 200 plus '-' and the absolute
# value of Claude's 32-bit hash of the original path in base 36.
# CLAUDE_CODE_PROJECT_DIR_NAME replaces that key only when CLAUDE_CONFIG_DIR
# is set and the name matches Claude's 1-64 character token rule.
# A write that fails prints the original body, so the hook still returns it.
set -u

# Claude Code 2.1.302 uses BGs=1e4. A body of this many characters or fewer
# stays inline, so the symlink refusal never runs.
FM_CLAUDE_HOOK_PERSIST_LIMIT=10000
# Leave room for the pointer lines and a long path.
FM_CLAUDE_HOOK_PREVIEW_MAX=8000

usage() {
  printf '%s\n' "usage: fm-claude-hook-persist.sh [--cwd DIR] [--session-id ID]" >&2
}

cwd=$PWD
session_id=
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd)
      [ $# -ge 2 ] || { usage; exit 2; }
      cwd=$2
      shift 2
      ;;
    --session-id)
      [ $# -ge 2 ] || { usage; exit 2; }
      session_id=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

# fm_claude_hash36 <text>
# Prints Math.abs of Claude's signed 32-bit hash, in base 36.
fm_claude_hash36() {
  local text=$1 i n char code hash=0 neg=0 digits=0123456789abcdefghijklmnopqrstuvwxyz out='' LC_ALL=C
  n=${#text}
  i=0
  while [ "$i" -lt "$n" ]; do
    char=${text:i:1}
    code=$(printf '%s' "$char" | LC_ALL=C od -An -tu1 | awk 'NF { print $1; exit }')
    case "$code" in
      ''|*[!0-9]*) code=0 ;;
    esac
    hash=$(( (hash * 33 + code) & 4294967295 ))
    if [ "$hash" -ge 2147483648 ]; then
      hash=$(( hash - 4294967296 ))
    fi
    i=$(( i + 1 ))
  done
  if [ "$hash" -lt 0 ]; then
    neg=$(( -hash ))
  else
    neg=$hash
  fi
  if [ "$neg" -eq 0 ]; then
    printf '0'
    return
  fi
  while [ "$neg" -gt 0 ]; do
    out=${digits:neg%36:1}$out
    neg=$(( neg / 36 ))
  done
  printf '%s' "$out"
}

# fm_claude_project_key <cwd>
fm_claude_project_key() {
  local path=$1 sanitized
  sanitized=$(printf '%s' "$path" | sed 's/[^a-zA-Z0-9]/-/g')
  if [ "${#sanitized}" -le 200 ]; then
    printf '%s' "$sanitized"
    return
  fi
  printf '%s-%s' "${sanitized:0:200}" "$(fm_claude_hash36 "$path")"
}

# Reserved Windows device names Claude rejects for CLAUDE_CODE_PROJECT_DIR_NAME.
fm_claude_dir_name_ok() {
  local name=$1 lower
  case "$name" in
    ''|*[!A-Za-z0-9_-]*) return 1 ;;
  esac
  [ "${#name}" -le 64 ] || return 1
  lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    con|prn|aux|nul|com[0-9]|lpt[0-9]) return 1 ;;
  esac
  return 0
}

body=$(mktemp)
trap 'rm -f "$body"' EXIT
cat > "$body"
size=$(wc -c < "$body" | tr -d ' ')
case "$size" in
  ''|*[!0-9]*) size=0 ;;
esac

passthrough() {
  cat "$body"
  exit 0
}

config=${CLAUDE_CONFIG_DIR:-}
if [ -z "$config" ]; then
  [ -n "${HOME:-}" ] || passthrough
  config=$HOME/.claude
fi
case "$config" in
  /*) ;;
  *) passthrough ;;
esac

key=
if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && fm_claude_dir_name_ok "${CLAUDE_CODE_PROJECT_DIR_NAME:-}"; then
  key=$CLAUDE_CODE_PROJECT_DIR_NAME
else
  key=$(fm_claude_project_key "$cwd")
fi
[ -n "$key" ] || passthrough
project=$config/projects/$key
[ -L "$project" ] || passthrough
[ "$size" -gt "$FM_CLAUDE_HOOK_PERSIST_LIMIT" ] || passthrough

leaf=session-start-digest.txt
case "$session_id" in
  ''|*[!A-Za-z0-9._-]*) session_id= ;;
esac
if [ -n "$session_id" ]; then
  dest=$project/$session_id/tool-results/$leaf
else
  dest=$project/tool-results/$leaf
fi

dest_dir=$(dirname "$dest")
if ! mkdir -p "$dest_dir"; then
  passthrough
fi
tmp=$dest_dir/.session-start-digest.$$
if ! cp "$body" "$tmp"; then
  rm -f "$tmp"
  passthrough
fi
if ! mv "$tmp" "$dest"; then
  rm -f "$tmp"
  passthrough
fi

header=$(printf '%s\n%s\n%s\n\n%s\n' \
  "Full session-start digest saved to: $dest" \
  "Read that file now. It is the complete digest." \
  "Claude Code will not persist hook output while this project directory is a symlink." \
  "Preview:")
header_size=$(printf '%s' "$header" | wc -c | tr -d ' ')
preview_len=$FM_CLAUDE_HOOK_PREVIEW_MAX
room=$(( FM_CLAUDE_HOOK_PERSIST_LIMIT - header_size - 1 ))
if [ "$room" -lt "$preview_len" ]; then
  preview_len=$room
fi
if [ "$preview_len" -lt 0 ]; then
  preview_len=0
fi
if [ "$preview_len" -gt "$size" ]; then
  preview_len=$size
fi
{
  printf '%s' "$header"
  head -c "$preview_len" "$body"
  printf '\n'
}
exit 0
