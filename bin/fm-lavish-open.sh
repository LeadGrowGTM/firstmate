#!/usr/bin/env bash
# fm-lavish-open.sh - present a Lavish artifact in Orca.
# Usage: fm-lavish-open.sh <artifact.html> [--reopen]
# config/lavish-browser: auto (default) or orca.
# config/lavish-orca-worktree: optional Windows worktree id override.
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
  case "$arg" in --reopen) ;; *) fail "unsupported option: $arg" ;; esac
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
  auto|orca) ;;
  *) fail 'config/lavish-browser must contain auto or orca' ;;
esac
if [ -e "$FM_HOME/config/lavish-orca-worktree" ] || [ -L "$FM_HOME/config/lavish-orca-worktree" ]; then
  worktree=$(read_config lavish-orca-worktree)
else
  worktree='id:33a08beb-aaba-4bf4-9d55-a9700dc0c36a::C:\Users\mitch\Everything_CC\firstmate'
fi
windows_worktree='^id:[^:[:space:]]+::[A-Za-z]:\\[^[:cntrl:]]+$'
[[ "$worktree" =~ $windows_worktree ]] || fail 'config/lavish-orca-worktree must contain a Windows worktree id'
out=$(lavish-axi "$artifact" --no-open "$@") || fail 'cannot establish the Lavish session'
printf '%s\n' "$out"
status=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1 | tr -d '"')
case "$status" in opened|resumed|open) ;; *) exit 0 ;; esac
url=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1 | tr -d '"')
case "$url" in http://?*|https://?*) ;; *) fail 'Lavish did not return a page URL' ;; esac
if ! command -v orca-ide >/dev/null 2>&1; then
  printf '%s\n' "$url"
  printf 'fm-lavish-open: Orca is unavailable; open this URL manually.\n' >&2
  exit 0
fi
orca-ide tab create --worktree "$worktree" --url "$url" --json >&2 \
  || fail 'cannot open the Lavish page in Orca'
