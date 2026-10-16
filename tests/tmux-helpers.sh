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
  if [ -f "$FM_TEST_TMUX_ROOT/children" ]; then
    local child_root
    while IFS= read -r child_root; do
      [ -n "$child_root" ] && [ "$child_root" != "$FM_TEST_TMUX_ROOT" ] || continue
      FM_TEST_TMUX_ROOT="$child_root" fm_test_tmux_cleanup
    done < "$FM_TEST_TMUX_ROOT/children"
  fi
  if [ -n "${FM_TEST_TMUX_REAL:-}" ] && [ -d "$FM_TEST_TMUX_ROOT" ]; then
    local socket
    for socket in "$FM_TEST_TMUX_ROOT/s/tmux-$(id -u)"/*; do
      [ -S "$socket" ] || continue
      "$FM_TEST_TMUX_REAL" -S "$socket" kill-server >/dev/null 2>&1 || true
    done
    if [ -f "$FM_TEST_TMUX_ROOT/explicit-sockets" ]; then
      while IFS= read -r socket; do
        case "$socket" in /*) ;; *) continue ;; esac
        [ "${socket##*/}" != default ] && [ ! -L "$socket" ] && [ -S "$socket" ] || continue
        "$FM_TEST_TMUX_REAL" -S "$socket" kill-server >/dev/null 2>&1 || true
      done < "$FM_TEST_TMUX_ROOT/explicit-sockets"
    fi
  fi
  rm -rf "${FM_TEST_TMUX_ROOT:?}"
}

# Capability check for positive real-shell cases, independent of the production
# predicate. Generic select/wait channels cannot distinguish shell activity.
fm_test_terminal_read_available() {  # <pid>
  local wait attempt
  [ "$(uname -s)" = Linux ] || return 1
  for attempt in $(seq 1 20); do
    wait=$(cat "/proc/$1/wchan" 2>/dev/null) || return 1
    case "$wait" in n_tty_read|tty_read) return 0 ;; esac
    sleep 0.05
  done
  return 1
}

# Start a real interactive shell executing builtins with unchanged argv. All
# writes and endpoints belong to the caller's disposable fixture.
fm_test_active_tmux_shell() {  # <label> <session> <window> <cwd> <busy|fd> <dir>
  local label=$1 session=$2 window=$3 cwd=$4 mode=$5 dir=$6 command pane attempt
  mkdir -p "$dir"
  tmux -L "$label" new-session -d -s "$session" -n "$window" -c "$cwd" \
    'bash --noprofile --norc -i' || return 1
  pane=$(tmux -L "$label" display-message -p -t "$session:$window" '#{pane_pid}') || return 1
  case "$mode" in
    busy)
      # The shell in the pane expands these variables when it executes input.
      # shellcheck disable=SC2016
      printf -v command 'printf "%%s\\n" "$$" > %q; n=0; while :; do n=$((n+1)); printf "%%s\\n" "$n" >> %q; done' \
        "$dir/active.pid" "$dir/work.log"
      ;;
    fd)
      mkfifo "$dir/input" || return 1
      # shellcheck disable=SC2016
      printf -v command 'exec 3<> %q; printf "%%s\\n" "$$" > %q; read -r -t 120 -u 3 value; : > %q' \
        "$dir/input" "$dir/active.pid" "$dir/finished"
      ;;
    *) return 1 ;;
  esac
  tmux -L "$label" send-keys -t "$session:$window" -l "$command" || return 1
  tmux -L "$label" send-keys -t "$session:$window" Enter || return 1
  for attempt in $(seq 1 100); do
    [ ! -s "$dir/active.pid" ] || break
    sleep 0.05
  done
  [ "$(cat "$dir/active.pid" 2>/dev/null)" = "$pane" ] || return 1
  if [ "$mode" = busy ]; then
    for attempt in $(seq 1 100); do
      [ ! -s "$dir/work.log" ] || break
      sleep 0.01
    done
    [ -s "$dir/work.log" ] || return 1
  else
    [ ! -e "$dir/finished" ] || return 1
  fi
  printf '%s\n' "$pane"
}

# Model kernel/foreground evidence only for the hermetic lifecycle model's
# synthetic PID. Real process fixtures always reach the real proof helper.
fm_test_fake_shell_input_proof() {  # <fakebin> <command-file> [synthetic-tty]
  local fakebin=$1 command_file=$2 tty=${3:-fakepane} real_python real_ps
  real_python=$(command -v python3)
  real_ps=$(command -v ps)
  if [ -e "$fakebin/ps" ]; then
    mv "$fakebin/ps" "$fakebin/ps.shell-fixture"
    real_ps="$fakebin/ps.shell-fixture"
  fi
  printf '#!/usr/bin/env bash\nreal_ps=%q\ncommand_file=%q\nfixture_tty=%q\n' \
    "$real_ps" "$command_file" "$tty" > "$fakebin/ps"
  cat >> "$fakebin/ps" <<'SH'
if [ "${1:-}" = -t ] && [ "${2:-}" = "$fixture_tty" ]; then
  printf '2147483647 2147483647 2147483647 %s\n' "$(cat "$command_file")"
elif [ "${1:-}" = -p ] && [ "${2:-}" = 2147483647 ]; then
  cat "$command_file"
else
  exec "$real_ps" "$@"
fi
SH
  printf '#!/usr/bin/env bash\nreal_python=%q\n' "$real_python" > "$fakebin/python3"
  cat >> "$fakebin/python3" <<'SH'
case "${1:-}:${2:-}:${3:-}" in
  */fm-agent-process.py:input:2147483647) exit 0 ;;
esac
exec "$real_python" "$@"
SH
  chmod +x "$fakebin/ps" "$fakebin/python3"
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
: > "$FM_TEST_TMUX_ROOT/explicit-sockets" || return 1
if [ -n "$FM_TEST_TMUX_REAL" ]; then
  {
    printf '#!/usr/bin/env bash\nreal=%q\nfixture_dir=%q\nfixture_owner=%q\nsocket_registry=%q\n' \
      "$FM_TEST_TMUX_REAL" "$(cd -P -- "$FM_TEST_TMUX_ROOT/s" && pwd -P)" "$$" \
      "$FM_TEST_TMUX_ROOT/explicit-sockets"
    cat <<'SH'
set -eu
refuse() { echo "test tmux: $*" >&2; exit 2; }
private_dir() {
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  local mode owner
  case "$(uname -s)" in
    Darwin) mode=$(/usr/bin/stat -f '%Lp' "$1"); owner=$(/usr/bin/stat -f '%u' "$1") ;;
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
explicit_sockets=()
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
    [ "$dir" = "$fixture_dir" ] || explicit_sockets+=("$dir/tmux-$(id -u)/$value")
  else
    [ -n "$value" ] || refuse 'missing socket selector'
    case "$value" in /*) socket_path=$value ;; *) socket_path="$(pwd -P)/$value" ;; esac
    case "$socket_path" in *$'\n'*) refuse 'invalid socket path' ;; esac
    [ "${value##*/}" != default ] && recorded_socket "$socket_path" || refuse 'default or non-private or unrecorded socket path'
    socket_parent=$(cd -P -- "$(dirname "$socket_path")" && pwd -P) || refuse 'unsafe socket parent'
    explicit_sockets+=("$socket_parent/${socket_path##*/}")
  fi
  explicit=1
  shift
done
for socket_path in "${explicit_sockets[@]+"${explicit_sockets[@]}"}"; do
  printf '%s\n' "$socket_path" >> "$socket_registry" || refuse 'cannot record explicit socket'
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
