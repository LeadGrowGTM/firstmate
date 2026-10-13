#!/usr/bin/env bash
# Shared real-tmux isolation for direct suites and fm-test-run.sh children.
# Every bare call uses a named server in a short, private directory; inherited
# pane addresses and default socket selectors cannot reach the operator server.
# Missing directories or stripped isolation variables refuse before exec.
# Fakes prepended by a suite still take precedence. Explicit private -L/-S
# selectors used by the live suites remain supported.
# Call fm_test_tmux_cleanup from the owner's existing cleanup trap.

fm_test_tmux_cleanup() {
  [ -n "${FM_TEST_TMUX_ROOT:-}" ] || return 0
  case "$FM_TEST_TMUX_ROOT" in /tmp/fmt.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;; *) return 1 ;; esac
  if [ -n "${FM_TEST_TMUX_REAL:-}" ] && [ -d "$FM_TEST_TMUX_ROOT" ]; then
    local socket
    for socket in "$FM_TEST_TMUX_ROOT/s/tmux-$(id -u)"/*; do
      [ -S "$socket" ] || continue
      "$FM_TEST_TMUX_REAL" -S "$socket" kill-server >/dev/null 2>&1 || true
    done
  fi
  rm -rf "${FM_TEST_TMUX_ROOT:?}"
}

# The runner and a suite are distinct shells, each owning its own directory.
[ "${FM_TEST_TMUX_OWNER:-}" != "$$" ] || return 0
fm_test_current_tmux=$(command -v tmux || true)
fm_test_keep_fake=0
if [ -n "${FM_TEST_TMUX_REAL:-}" ] && [ "$fm_test_current_tmux" != "$FM_TEST_TMUX_REAL" ]; then
  case "$fm_test_current_tmux" in
    /tmp/fmt.??????/bin/tmux) ;;
    *) fm_test_keep_fake=1 ;;
  esac
fi
FM_TEST_TMUX_REAL=${FM_TEST_TMUX_REAL:-$fm_test_current_tmux}
FM_TEST_TMUX_ROOT=$(mktemp -d /tmp/fmt.XXXXXX) || return 1
chmod 700 "$FM_TEST_TMUX_ROOT" || return 1
FM_TEST_TMUX_OWNER=$$
mkdir -m 700 "$FM_TEST_TMUX_ROOT/bin" "$FM_TEST_TMUX_ROOT/s" || return 1
if [ -n "$FM_TEST_TMUX_REAL" ]; then
  {
    printf '#!/usr/bin/env bash\nreal=%q\n' "$FM_TEST_TMUX_REAL"
    cat <<'SH'
set -eu
refuse() { echo "test tmux: $*" >&2; exit 2; }
private_dir() {
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  local mode owner
  case "$(uname -s)" in
    Darwin) mode=$(stat -f '%Lp' "$1"); owner=$(stat -f '%u' "$1") ;;
    *) mode=$(stat -c '%a' "$1"); owner=$(stat -c '%u' "$1") ;;
  esac
  [ "$mode" = 700 ] && [ "$owner" = "$(id -u)" ]
}
dir=${TMUX_TMPDIR:-}
[ -n "$dir" ] && private_dir "$dir" || refuse 'private TMUX_TMPDIR is missing or unsafe'
args=("$@")
explicit=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -L|-S)
      opt=$1; shift
      [ "$#" -gt 0 ] || refuse 'missing socket selector'
      value=$1
      ;;
    -L*|-S*) opt=${1:0:2}; value=${1:2} ;;
    -f|-T) shift; [ "$#" -gt 0 ] || refuse 'missing option value'; shift; continue ;;
    --) break ;;
    -*) shift; continue ;;
    *) break ;;
  esac
  if [ "$opt" = -L ]; then
    [ -n "$value" ] && [ "$value" != default ] && [[ "$value" != */* ]] || refuse 'default or invalid named socket'
  else
    [ "${value##*/}" != default ] && private_dir "$(dirname "$value")" || refuse 'default or non-private socket path'
  fi
  explicit=1
  shift
done
selector=(-L fm-test)
if [ "$explicit" -eq 0 ] && [ -n "${TMUX:-}" ]; then
  socket=${TMUX%%,*}
  case "$socket" in
    "$dir"/tmux-"$(id -u)"/*)
      [ "${socket##*/}" != default ] || refuse 'default inherited socket'
      selector=(-S "$socket")
      ;;
  esac
fi
exec env TMUX_TMPDIR="$dir" "$real" "${selector[@]}" -f /dev/null "${args[@]}"
SH
  } > "$FM_TEST_TMUX_ROOT/bin/tmux"
  chmod +x "$FM_TEST_TMUX_ROOT/bin/tmux" || return 1
  [ "$fm_test_keep_fake" -eq 1 ] || PATH="$FM_TEST_TMUX_ROOT/bin:$PATH"
fi
TMUX_TMPDIR=$FM_TEST_TMUX_ROOT/s
unset TMUX TMUX_PANE
export PATH TMUX_TMPDIR FM_TEST_TMUX_REAL
unset fm_test_current_tmux fm_test_keep_fake
