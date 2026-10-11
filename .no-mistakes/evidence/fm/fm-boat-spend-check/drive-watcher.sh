#!/usr/bin/env bash
# Arm the check in a disposable home and let the real bin/fm-watch.sh run it.
# Usage: drive-watcher.sh <worktree>
set -u
ROOT=$1
CHECK="$ROOT/bin/fm-boat-spend-check.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-boat-watch.XXXXXX")
trap 'rm -rf "$T"' EXIT
CLEAN=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_BOAT_BIN)
home() {  # <name> <refill true|false>
  local h="$T/$1"; mkdir -p "$h/config" "$h/state" "$h/fx"
  cat > "$h/fx/boat" <<'F'
#!/usr/bin/env bash
d=$(cd "$(dirname "$0")" && pwd)
printf '%s\n' "$*" >> "$d/calls.log"
case "$*" in
  "--no-update limits --json") f=limits ;;
  "--no-update list --all --json") f=list ;;
  "--no-update billing status --json") f=billing ;;
  *) exit 97 ;;
esac
cat "$d/$f.json"
F
  chmod +x "$h/fx/boat"
  echo '{"activeStates":["provisioned","cloning","ready","idle","running"],"creditSecondsPerDollar":100000,"creditUsedSeconds":6124,"last24hUsageSeconds":4671,"subscriptionCurrentPeriodEnd":"2026-10-31T14:38:13.000Z","subscriptionTrialEndsAt":null}' > "$h/fx/limits.json"
  echo '{"pageInfo":{"hasMore":false},"sandboxes":[{"id":"bx_one","state":"running","type":"default","archiveAfter":"2099-01-01T00:00:00.000Z"}]}' > "$h/fx/list.json"
  printf '{"prepaid":{"enabled":%s}}\n' "$2" > "$h/fx/billing.json"
  printf '{"ceiling_usd":30,"boat_bin":"%s"}\n' "$h/fx/boat" > "$h/config/boat-spend.json"
  echo "$h"
}
watch() {  # <home> <seconds>
  "${CLEAN[@]}" FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 FM_POLL=0.2 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
    timeout "$2" "$ROOT/bin/fm-watch.sh" 2>&1 | sed "s#$T#<tmp>#g; s/^/  watcher: /"
  echo "  watcher exit=${PIPESTATUS[0]} (124 = still blocking quietly when the bound hit)"
}
echo "===== A. armed home, auto-refill on: the watcher surfaces the line as a check: wake"
h=$(home drift true)
"${CLEAN[@]}" FM_HOME="$h" "$CHECK" arm; echo "  arm exit=$?"; ls -A "$h/state" | sed 's/^/  state: /'; sed "s#$T#<tmp>#g; s#$ROOT#<worktree>#g; s/^/  shim: /" "$h/state/boat-spend.check.sh"
watch "$h" 30; sed 's/^/  boat argv: /' "$h/fx/calls.log"
echo "===== B. same home, watcher re-armed minutes later: already evaluated today, no Boat calls (rearm-resurface is the watcher re-offering the undelivered wake from A, not a new check run)"
watch "$h" 8; echo "  boat calls total: $(wc -l < "$h/fx/calls.log")"
echo "===== C. disarm removes shim, trust binding and records"
"${CLEAN[@]}" FM_HOME="$h" "$CHECK" disarm; echo "  disarm exit=$?"; echo "  state now: $(ls -A "$h/state" | grep -i boat | tr '\n' ' ')<end>"
echo "===== D. armed healthy home: watcher stays quiet"
h=$(home quiet false); "${CLEAN[@]}" FM_HOME="$h" "$CHECK" arm; watch "$h" 8; sed 's/^/  boat argv: /' "$h/fx/calls.log"
