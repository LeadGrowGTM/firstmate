#!/usr/bin/env bash
# Shared real-tmux isolation for direct suites and fm-test-run.sh children.
# Every bare call uses a named server in a short, private directory; inherited
# pane addresses and default socket selectors cannot reach the operator server.
# Missing directories or stripped isolation variables refuse before exec.
# Fakes prepended by a suite still take precedence. Explicit disposable -L/-S
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
if [ -n "${FM_TEST_TMUX_CHILD_REGISTRY:-}" ]; then
  if [ ! -f "$FM_TEST_TMUX_CHILD_REGISTRY" ] ||
    ! printf '%s\n' "$FM_TEST_TMUX_ROOT" >> "$FM_TEST_TMUX_CHILD_REGISTRY"; then
    rm -rf "$FM_TEST_TMUX_ROOT"
    return 1
  fi
fi
chmod 700 "$FM_TEST_TMUX_ROOT" || return 1
FM_TEST_TMUX_OWNER=$$
mkdir -m 700 "$FM_TEST_TMUX_ROOT/bin" "$FM_TEST_TMUX_ROOT/s" || return 1
if [ -n "$FM_TEST_TMUX_REAL" ]; then
  {
    printf '#!/usr/bin/env bash\nreal=%q\nfixture_dir=%q\nfixture_owner=%q\n' \
      "$FM_TEST_TMUX_REAL" "$(cd -P -- "$FM_TEST_TMUX_ROOT/s" && pwd -P)" "$$"
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
recorded_dir() {
  local root=$1 lab_home=${FM_TEST_TMUX_LAB_HOME:-${FM_HOME:-}} lab_dir
  [ "$root" = "$fixture_dir" ] && return 0
  case "$root" in "$fixture_dir"/*) return 0 ;; esac
  while [ "$root" != / ]; do
    if [ -f "$root/.fm-test-fixture" ] &&
      [ "$(sed -n '1p' "$root/.fm-test-fixture")" = "$fixture_owner" ]; then
      return 0
    fi
    root=${root%/*}
    [ -n "$root" ] || root=/
  done
  [ -n "$lab_home" ] && [ -f "$lab_home/.fm-lab-home" ] &&
    [ -f "$lab_home/state/.fm-lab-tmux-dir" ] || return 1
  lab_dir=$(cat "$lab_home/state/.fm-lab-tmux-dir")
  private_dir "$lab_dir" || return 1
  lab_dir=$(cd -P -- "$lab_dir" && pwd -P) || return 1
  case "$1" in "$lab_dir"|"$lab_dir/tmux-$(id -u)") return 0 ;; esac
  return 1
}
recorded_socket() {
  local path=$1 parent
  parent=$(cd -P -- "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
  [ ! -L "$path" ] && private_dir "$parent" && recorded_dir "$parent"
}
dir=${TMUX_TMPDIR:-}
[ -n "$dir" ] && private_dir "$dir" || refuse 'private TMUX_TMPDIR is missing or unsafe'
dir=$(cd -P -- "$dir" && pwd -P) || refuse 'private TMUX_TMPDIR is missing or unsafe'
recorded_dir "$dir" || refuse 'private TMUX_TMPDIR is missing or unsafe'
[ ! -L "$dir/tmux-$(id -u)" ] || refuse 'unsafe socket parent'
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
    -f) shift; [ "$#" -gt 0 ] || refuse 'missing option value'; shift; continue ;;
    -*) refuse 'unsupported tmux global option' ;;
    *) break ;;
  esac
  if [ "$opt" = -L ]; then
    [ -n "$value" ] && [ "$value" != default ] && [[ "$value" != */* ]] || refuse 'default or invalid named socket'
    [ ! -L "$dir/tmux-$(id -u)" ] && [ ! -L "$dir/tmux-$(id -u)/$value" ] || refuse 'unsafe named socket'
  else
    [ -n "$value" ] || refuse 'missing socket selector'
    case "$value" in /*) socket_path=$value ;; *) socket_path="$(pwd -P)/$value" ;; esac
    [ "${value##*/}" != default ] && recorded_socket "$socket_path" || refuse 'default or non-private or unrecorded socket path'
  fi
  explicit=1
  shift
done
selector=(-L fm-test)
if [ "$explicit" -eq 0 ] && [ -n "${TMUX:-}" ]; then
  socket=${TMUX%%,*}
  socket_parent=$(cd -P -- "$(dirname "$socket")" 2>/dev/null && pwd -P) || socket_parent=
  case "$socket_parent/${socket##*/}" in
    "$dir"/tmux-"$(id -u)"/*)
      [ "${socket##*/}" != default ] || refuse 'default inherited socket'
      recorded_socket "$socket" || refuse 'unsafe inherited socket'
      selector=(-S "$socket_parent/${socket##*/}")
      ;;
  esac
fi
[ "$explicit" -eq 1 ] || [ "${selector[0]}" != -L ] ||
  [ ! -L "$dir/tmux-$(id -u)/fm-test" ] || refuse 'unsafe named socket'
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
