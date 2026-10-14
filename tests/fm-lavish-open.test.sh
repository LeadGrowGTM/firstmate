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
selector='id:example::C:\Users\example\firstmate'
printf '%s\n' "$selector" > "$FM_HOME/config/lavish-orca-worktree"
bash "$opener" 'file with spaces.html' --reopen >/dev/null
assert_contains "$(cat "$OPEN_LOG")" '<--no-open>' 'auto suppresses the default browser'
assert_contains "$(cat "$OPEN_LOG")" "<--worktree> <$selector>" 'explicit Windows selector is one argument'
assert_contains "$(cat "$OPEN_LOG")" '<--reopen>' 'reopen is forwarded'
: > "$OPEN_LOG"
FAKE_STATUS=user-ended bash "$opener" test.html >/dev/null
assert_not_contains "$(cat "$OPEN_LOG")" 'orca' 'user-ended sessions stay closed'
: > "$OPEN_LOG"
printf 'system\n' > "$FM_HOME/config/lavish-browser"
bash "$opener" test.html >/dev/null
assert_not_contains "$(cat "$OPEN_LOG")" '--no-open' 'system preserves the existing opener'
assert_not_contains "$(cat "$OPEN_LOG")" 'orca' 'system never calls Orca'
printf 'orca\n' > "$FM_HOME/config/lavish-browser"
rm "$FM_HOME/config/lavish-orca-worktree"
: > "$OPEN_LOG"
if bash "$opener" test.html 2>/dev/null; then fail 'missing selector must fail'; fi
[ ! -s "$OPEN_LOG" ] || fail 'missing selector must not open anything'
printf 'active\n' > "$FM_HOME/config/lavish-orca-worktree"
if bash "$opener" test.html 2>/dev/null; then fail 'active project must fail'; fi
printf '%s\n' "$selector" > "$FM_HOME/config/lavish-orca-worktree"
if FAKE_ORCA_RC=1 bash "$opener" test.html >/dev/null 2>&1; then fail 'Orca failure must propagate'; fi
assert_contains "$(cat "$OPEN_LOG")" '<--no-open>' 'Orca failure still suppresses the system browser'
printf 'invalid\n' > "$FM_HOME/config/lavish-browser"
if bash "$opener" test.html 2>/dev/null; then fail 'invalid browser must fail'; fi
rm "$FM_HOME/config/lavish-browser" "$LAB/bin/orca-ide"
: > "$OPEN_LOG"
# Pin tool availability without exposing an installed real Orca executable.
mkdir -p "$LAB/portable"
for tool in bash dirname cat; do ln -s "$(command -v "$tool")" "$LAB/portable/$tool"; done
ln -s "$LAB/bin/lavish-axi" "$LAB/portable/lavish-axi"
PATH="$LAB/portable" bash "$opener" test.html >/dev/null
assert_not_contains "$(cat "$OPEN_LOG")" '--no-open' 'auto without Orca uses system'
pass 'browser routing, refusal, argument preservation, and fallback'
