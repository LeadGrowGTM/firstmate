#!/usr/bin/env bash
# fm-lavish-open.sh - present a Lavish artifact in the home's selected browser.
# Usage: fm-lavish-open.sh <artifact.html> [--reopen] [--no-gate]
# config/lavish-browser: auto (default), orca, or system.
# auto uses Orca when orca-ide is on PATH, otherwise Lavish's system opener.
# config/lavish-orca-worktree: required explicit Orca worktree selector when
# using Orca; no active/current or inferred WSL worktree is ever selected.
# Orca mode establishes the session with --no-open and opens only live URLs.
# A failed Orca open is an error, never a fallback to the system browser.
# Output preserves Lavish's session fields; Orca's receipt goes to stderr.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
fail() { printf 'fm-lavish-open: %s\n' "$*" >&2; exit 1; }
if [ "${1:-}" = --help ]; then
  sed -n '2,/^set -eu/{ /^set -eu/d; s/^# //; p; }' "$0"
  exit 0
fi
[ "$#" -ge 1 ] || fail 'an artifact path is required'
artifact=$1
shift
for arg in "$@"; do
  case "$arg" in --reopen|--no-gate) ;; *) fail "unsupported option: $arg" ;; esac
done
read_config() {
  local path="$FM_HOME/config/$1"
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ -r "$path" ] || fail "$path must be a readable regular file"
    cat "$path"
  fi
}
browser=$(read_config lavish-browser)
browser=${browser:-auto}
case "$browser" in
  auto) if command -v orca-ide >/dev/null 2>&1; then browser=orca; else browser=system; fi ;;
  orca|system) ;;
  *) fail 'config/lavish-browser must contain auto, orca, or system' ;;
esac
if [ "$browser" = system ]; then
  exec lavish-axi "$artifact" "$@"
fi
command -v orca-ide >/dev/null 2>&1 || fail 'orca-ide is unavailable'
worktree=$(read_config lavish-orca-worktree)
case "$worktree" in
  id:?*::?*|identity:?*|path:?*|name:?*|branch:?*|issue:?*) ;;
  *) fail 'config/lavish-orca-worktree must contain an explicit Orca worktree selector' ;;
esac
case "$worktree" in *$'\n'*|*$'\r'*) fail 'config/lavish-orca-worktree must contain one line' ;; esac
out=$(lavish-axi "$artifact" --no-open "$@") || fail 'cannot establish the Lavish session'
printf '%s\n' "$out"
status=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1 | tr -d '"')
case "$status" in opened|resumed|open) ;; *) exit 0 ;; esac
url=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1 | tr -d '"')
case "$url" in http://?*|https://?*) ;; *) fail 'Lavish did not return a page URL' ;; esac
orca-ide tab create --worktree "$worktree" --url "$url" --json >&2 \
  || fail 'cannot open the Lavish page in Orca'
