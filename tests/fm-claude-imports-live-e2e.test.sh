#!/usr/bin/env bash
# Real Claude TUI proof for a worker pool nested under a scratch Firstmate home.
# A loopback Anthropic fixture proves the launch processes its prompt and the
# imported home instructions without credentials or a remote model request.
# The control arm must show the genuine external-import dialog; no keys answer it.
# Run with FM_CLAUDE_IMPORTS_LIVE=1 after Claude upgrades.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CLAUDE_IMPORTS_LIVE claude tmux python3 node

VERSION=$(claude --version) || fail "claude could not report its version"
LAB=$(fm_test_tmproot fm-claude-imports-live)
PROJ="$LAB/home/projects/demo"
WT="$PROJ/.worktrees/.treehouse/worker"
CONFIG="$LAB/claude-config"
SOCKET="fm-claude-imports-$$"
SERVER_PID=
cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT

fm_git_worktree "$PROJ" "$WT" worker
printf '@AGENTS.md\n' > "$LAB/home/CLAUDE.md"
printf 'Home import sentinel: FM_HOME_IMPORT_PROOF\n' > "$LAB/home/AGENTS.md"
mkdir -p "$CONFIG"
node - "$CONFIG/.claude.json" "$PROJ" "$WT" <<'NODE'
const fs = require("node:fs");
const [store, project, worktree] = process.argv.slice(2);
fs.writeFileSync(store, JSON.stringify({
  hasCompletedOnboarding: true,
  theme: "dark",
  primaryApiKey: "sk-ant-fm-live-synthetic",
  customApiKeyResponses: {approved: ["sk-ant-fm-live-synthetic".slice(-20)], rejected: []},
  projects: {
    [project]: {hasTrustDialogAccepted: true},
    [worktree]: {hasTrustDialogAccepted: true},
  },
}));
NODE

# Return an actual streaming Messages response to the installed CLI, and record
# only booleans about the synthetic request, never its body or authentication.
cat > "$LAB/provider.py" <<'PY'
import json
import pathlib
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lab = pathlib.Path(sys.argv[1])
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        if "FM_WORKER_PROMPT_PROOF" in body and "FM_HOME_IMPORT_PROOF" in body:
            (lab / "processed").write_text("prompt and home import reached Claude's Messages request\n")
        events = [
            ("message_start", {"type": "message_start", "message": {
                "id": "msg_fixture", "type": "message", "role": "assistant",
                "model": "claude-haiku-4-5", "content": [], "stop_reason": None,
                "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 0}}}),
            ("content_block_start", {"type": "content_block_start", "index": 0,
                "content_block": {"type": "text", "text": ""}}),
            ("content_block_delta", {"type": "content_block_delta", "index": 0,
                "delta": {"type": "text_delta", "text": "IMPORT_WORKER_PROCESSED"}}),
            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
            ("message_delta", {"type": "message_delta", "delta": {
                "stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 1}}),
            ("message_stop", {"type": "message_stop"}),
        ]
        payload = "".join(f"event: {event}\ndata: {json.dumps(data)}\n\n" for event, data in events).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(lab / "port").write_text(str(server.server_port))
server.serve_forever()
PY
python3 "$LAB/provider.py" "$LAB" &
SERVER_PID=$!
for _ in $(seq 1 100); do
  [ ! -s "$LAB/port" ] || break
  sleep 0.1
done
[ -s "$LAB/port" ] || fail "Claude $VERSION: loopback fixture failed to start"
PORT=$(cat "$LAB/port")

# A script keeps the synthetic key and exact isolated config out of tmux's
# inherited environment and never accesses the operator's credential store.
cat > "$LAB/launch.sh" <<EOF
#!/usr/bin/env bash
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN \
  CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
export CLAUDE_CONFIG_DIR='$CONFIG'
export ANTHROPIC_API_KEY=sk-ant-fm-live-synthetic
export ANTHROPIC_BASE_URL='http://127.0.0.1:$PORT'
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
exec claude --model haiku --permission-mode auto --setting-sources project,local \\
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' -- 'Reply briefly to FM_WORKER_PROMPT_PROOF'
EOF
chmod +x "$LAB/launch.sh"
launch() {
  tmux -L "$SOCKET" new-session -d -s worker -x 120 -y 40 -c "$WT" "$LAB/launch.sh" \
    || fail "Claude $VERSION: could not launch disposable worker"
}
screen() { tmux -L "$SOCKET" capture-pane -p -t worker -S -80 2>/dev/null || true; }
launch
for _ in $(seq 1 200); do
  screen > "$LAB/control.txt"
  grep -Fq 'Allow external CLAUDE.md file imports?' "$LAB/control.txt" && break
  sleep 0.1
done
assert_grep 'Allow external CLAUDE.md file imports?' "$LAB/control.txt" "Claude $VERSION: control did not reproduce the import dialog"
assert_grep "$LAB/home/AGENTS.md" "$LAB/control.txt" "Claude $VERSION: control did not name the external home import"
assert_absent "$LAB/processed" "Claude $VERSION: control processed its prompt despite the dialog"
# Kill the disposable session without Escape, which would persist a decline.
tmux -L "$SOCKET" kill-session -t worker
pass "Claude $VERSION: nested home import reproduces the external-import dialog"

CLAUDE_CONFIG_DIR="$CONFIG" bash "$ROOT/bin/fm-claude-trust.sh" "$WT" "$PROJ" >/dev/null \
  || fail "Claude $VERSION: production worker pre-registration failed"
launch
for _ in $(seq 1 300); do
  screen > "$LAB/worker.txt"
  if grep -Fq 'Allow external CLAUDE.md file imports?' "$LAB/worker.txt"; then
    fail "Claude $VERSION: worker still parked on the external-import dialog"
  fi
  if [ -f "$LAB/processed" ] && grep -Fq 'IMPORT_WORKER_PROCESSED' "$LAB/worker.txt"; then
    break
  fi
  sleep 0.1
done
assert_present "$LAB/processed" "Claude $VERSION: worker never processed its prompt and imported home instructions"
assert_grep 'IMPORT_WORKER_PROCESSED' "$LAB/worker.txt" "Claude $VERSION: worker never rendered the loopback response"
pass "Claude $VERSION: pre-registration clears the dialog and processes the prompt with home imports"
