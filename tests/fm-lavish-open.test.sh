#!/usr/bin/env bash
# Public opener behavior; fake tools never open a real browser or tmux server.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-lavish-open)
mkdir -p "$LAB/home/config" "$LAB/bin"
export FM_HOME="$LAB/home" OPEN_LOG="$LAB/log"
cat > "$LAB/bin/lavish-axi" <<'STUB'
#!/usr/bin/env bash
printf 'lavish' >> "$OPEN_LOG"
printf ' <%s>' "$@" >> "$OPEN_LOG"
printf '\n' >> "$OPEN_LOG"
printf 'session:\n  url: "http://127.0.0.1:4387/session/test"\n  status: %s\n' "${FAKE_STATUS:-opened}"
STUB
cat > "$LAB/bin/orca-ide" <<'STUB'
#!/usr/bin/env bash
printf 'orca' >> "$OPEN_LOG"
printf ' <%s>' "$@" >> "$OPEN_LOG"
printf '\n' >> "$OPEN_LOG"
exit "${FAKE_ORCA_RC:-0}"
STUB
chmod +x "$LAB/bin/"*
export PATH="$LAB/bin:$PATH"
opener="$ROOT/bin/fm-lavish-open.sh"
default_selector='id:33a08beb-aaba-4bf4-9d55-a9700dc0c36a::C:\Users\mitch\Everything_CC\firstmate'
selector='id:example::C:\Users\example\firstmate'
bash "$opener" 'file with spaces.html' --reopen >/dev/null
assert_contains "$(cat "$OPEN_LOG")" '<--no-open>' 'opener suppresses the default browser'
assert_contains "$(cat "$OPEN_LOG")" "<--worktree> <$default_selector>" 'single-backslash captain Windows worktree is the default'
assert_contains "$(cat "$OPEN_LOG")" '<--reopen>' 'reopen is forwarded'
: > "$OPEN_LOG"
FAKE_STATUS=user-ended bash "$opener" test.html >/dev/null
assert_not_contains "$(cat "$OPEN_LOG")" 'orca' 'user-ended sessions stay closed'
: > "$OPEN_LOG"
printf '%s\n' "$selector" > "$FM_HOME/config/lavish-orca-worktree"
bash "$opener" test.html >/dev/null
assert_contains "$(cat "$OPEN_LOG")" "<--worktree> <$selector>" 'Windows worktree override is one argument'
: > "$OPEN_LOG"
: > "$FM_HOME/config/lavish-orca-worktree"
if bash "$opener" test.html >/dev/null 2>&1; then fail 'empty worktree override must fail'; fi
printf 'active\n' > "$FM_HOME/config/lavish-orca-worktree"
if bash "$opener" test.html >/dev/null 2>&1; then fail 'active project must fail'; fi
printf '%s\n' 'path:C:\Users\mitch\Everything_CC\firstmate' > "$FM_HOME/config/lavish-orca-worktree"
if bash "$opener" test.html >/dev/null 2>&1; then fail 'path selector must fail'; fi
printf 'id:example::/home/mitch/firstmate\n' > "$FM_HOME/config/lavish-orca-worktree"
if bash "$opener" test.html >/dev/null 2>&1; then fail 'WSL worktree id must fail'; fi
printf '%s\n' 'id:example::/home/mitch::C:\Users\mitch\firstmate' > "$FM_HOME/config/lavish-orca-worktree"
if bash "$opener" test.html >/dev/null 2>&1; then fail 'ambiguous worktree id must fail'; fi
[ ! -s "$OPEN_LOG" ] || fail 'invalid selectors must not establish a session'
printf '%s\n' "$selector" > "$FM_HOME/config/lavish-orca-worktree"
if FAKE_ORCA_RC=1 bash "$opener" test.html >/dev/null 2>&1; then fail 'Orca failure must propagate'; fi
assert_contains "$(cat "$OPEN_LOG")" '<--no-open>' 'Orca failure still suppresses the system browser'
: > "$OPEN_LOG"
if bash "$opener" test.html --no-gate >/dev/null 2>&1; then fail 'unsupported gate bypass must fail'; fi
[ ! -s "$OPEN_LOG" ] || fail 'unsupported option must not establish a session'
rm "$LAB/bin/orca-ide"
: > "$OPEN_LOG"
mkdir -p "$LAB/portable"
for tool in bash dirname cat sed head tr; do ln -s "$(command -v "$tool")" "$LAB/portable/$tool"; done
ln -s "$LAB/bin/lavish-axi" "$LAB/portable/lavish-axi"
out=$(PATH="$LAB/portable" bash "$opener" test.html 2>"$LAB/note")
assert_contains "$out" 'http://127.0.0.1:4387/session/test' 'missing Orca prints a manual page URL'
assert_contains "$(cat "$LAB/note")" 'Orca is unavailable; open this URL manually.' 'missing Orca explains manual opening'
assert_contains "$(cat "$OPEN_LOG")" '<--no-open>' 'missing Orca never asks Lavish to open a browser'
assert_not_contains "$(cat "$OPEN_LOG")" 'orca' 'missing Orca opens no tab'
pass 'Orca routing, Windows worktree selection, and manual URL fallback'
