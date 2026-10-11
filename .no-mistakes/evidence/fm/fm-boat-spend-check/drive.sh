#!/usr/bin/env bash
# Live drive of bin/fm-boat-spend-check.sh against a disposable home and a
# recording stand-in for the Boat CLI. Usage: drive.sh <worktree>
set -u
ROOT=$1
CHECK="$ROOT/bin/fm-boat-spend-check.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-boat-drive.XXXXXX")
trap 'rm -rf "$T"' EXIT
NOW=1791727200  # 2026-10-11T14:00:00Z
CALLS="$T/all-calls.log"; : > "$CALLS"

# Stand-in CLI: serves fixtures from the dir beside it, logs every argv.
mkboat() {  # <dir>
  cat > "$1/boat" <<'F'
#!/usr/bin/env bash
d=$(cd "$(dirname "$0")" && pwd)
printf '%s\n' "$*" >> "$d/calls.log"
printf '%s\n' "$*" >> "$ALLCALLS_FILE_PLACEHOLDER"
[ ! -e "$d/hang" ] || sleep 60
case "$*" in
  "--no-update limits --json") f=limits ;;
  "--no-update list --all --json") f=list ;;
  "--no-update billing status --json") f=billing ;;
  *) exit 97 ;;
esac
cat "$d/$f.json"
F
  sed -i "s#\$ALLCALLS_FILE_PLACEHOLDER#$CALLS#" "$1/boat"
  chmod +x "$1/boat"
}
world() {  # <name> [config|none] -> home
  local h="$T/$1"; mkdir -p "$h/config" "$h/state" "$h/fx"
  [ "${2-'{}'}" = none ] || printf '%s\n' "${2-{\}}" > "$h/config/boat-spend.json"
  mkboat "$h/fx"
  echo '{"activeStates":["provisioned","cloning","ready","idle","running"],"creditSecondsPerDollar":100000,"creditUsedSeconds":6124,"last24hUsageSeconds":4671,"subscriptionCurrentPeriodEnd":"2026-10-30T21:38:16.000Z","subscriptionTrialEndsAt":"2026-10-30T21:38:16.000Z"}' > "$h/fx/limits.json"
  echo '{"pageInfo":{"hasMore":false,"limit":200,"nextCursor":null},"sandboxes":[{"id":"bx_one","state":"running","type":"default","archiveAfter":"2026-10-11T16:00:00.000Z"},{"id":"bx_old","state":"stopped","type":"xlarge","archiveAfter":null}]}' > "$h/fx/list.json"
  echo '{"prepaid":{"balanceCents":0,"bufferSeconds":2500000,"cards":[],"enabled":false,"graceUntil":null}}' > "$h/fx/billing.json"
  echo "$h"
}
setj() { jq -c "$3" "$1/fx/$2.json" > "$1/fx/$2.new" && mv "$1/fx/$2.new" "$1/fx/$2.json"; }
run() {  # <label> <home> [env...]
  local label=$1 h=$2 out rc; shift 2
  out=$(env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$h" FM_BOAT_BIN="$h/fx/boat" FM_BOAT_SPEND_NOW="$NOW" "$@" "$CHECK" check 2>&1); rc=$?
  printf '### %s\n  exit=%s calls=%s\n  stdout: %s\n' "$label" "$rc" "$( [ -f "$h/fx/calls.log" ] && wc -l < "$h/fx/calls.log" || echo 0)" "${out:-<silent>}"
}

echo "===== 1. healthy account (one running default box with auto-stop, one stopped xlarge with none)"
h=$(world healthy); run healthy "$h"; sed 's/^/  boat argv: /' "$h/fx/calls.log"

echo "===== 2. each agreed condition"
h=$(world over); setj "$h" limits '.creditUsedSeconds=3100000'; run "spend over ceiling (\$31 used)" "$h"
h=$(world proj); setj "$h" limits '.creditUsedSeconds=2000000|.last24hUsageSeconds=100000'; run "spend projected over (\$20 used, \$1/day, 19 days left)" "$h"
h=$(world projok); setj "$h" limits '.creditUsedSeconds=1000000|.last24hUsageSeconds=100000'; run "spend projected under (\$10 used, \$1/day) - must be silent" "$h"
h=$(world many); setj "$h" list '.sandboxes+=[{"id":"bx_two","state":"idle","type":"small","archiveAfter":"2026-10-11T16:00:00.000Z"}]'; run "two active, expected 1" "$h"
h=$(world many2 '{"expected_running":2}'); setj "$h" list '.sandboxes+=[{"id":"bx_two","state":"idle","type":"small","archiveAfter":"2026-10-11T16:00:00.000Z"}]'; run "two active, expected_running=2 - must be silent" "$h"
h=$(world size); setj "$h" list '.sandboxes[0].type="xlarge"'; run "active xlarge box" "$h"
h=$(world nostop); setj "$h" list '.sandboxes[0].archiveAfter=null'; run "active box with no auto-stop" "$h"
h=$(world nostopok '{"always_on":["bx_one"]}'); setj "$h" list '.sandboxes[0].archiveAfter=null'; run "no auto-stop but on always_on - must be silent" "$h"
h=$(world refill); setj "$h" billing '.prepaid.enabled=true'; run "auto-refill enabled" "$h"
h=$(world trial); setj "$h" limits '.subscriptionTrialEndsAt="2026-10-13T14:00:00.000Z"'; run "trial ends in 2 days" "$h"
h=$(world plan); setj "$h" limits '.subscriptionTrialEndsAt=null|.subscriptionCurrentPeriodEnd="2026-10-14T13:59:00.000Z"'; run "plan ends just inside 3 days" "$h"
h=$(world trial4); setj "$h" limits '.subscriptionTrialEndsAt="2026-10-15T14:00:00.000Z"'; run "trial ends in 4 days - must be silent" "$h"
h=$(world all); setj "$h" limits '.creditUsedSeconds=3100000|.subscriptionTrialEndsAt="2026-10-12T14:00:00.000Z"'; setj "$h" billing '.prepaid.enabled=true'
setj "$h" list '.sandboxes[0].type="xlarge"|.sandboxes[0].archiveAfter=null|.sandboxes+=[{"id":"bx_two","state":"ready","type":"small","archiveAfter":"2026-10-11T16:00:00.000Z"}]'
run "everything wrong at once - one line" "$h"

echo "===== 3. daily gate"
h=$(world gate); setj "$h" billing '.prepaid.enabled=true'
run "first evaluation" "$h"; run "5 minutes later (no new Boat calls expected)" "$h" FM_BOAT_SPEND_NOW=$((NOW+300))
run "23h59m later" "$h" FM_BOAT_SPEND_NOW=$((NOW+86399)); run "24h later, condition persists" "$h" FM_BOAT_SPEND_NOW=$((NOW+86400))

echo "===== 4. no config: not checked"
h=$(world nocfg none); run "check with no config" "$h"
out=$(FM_HOME="$h" "$CHECK" arm 2>&1); echo "  arm: exit=$? ${out#"$T"}"; ls -A "$h/state" | sed 's/^/  state: /'

echo "===== 5. cannot read is not quiet"
h=$(world missing); run "CLI missing" "$h" FM_BOAT_BIN="$T/nope/boat"
h=$(world badjson); echo 'Error: not signed in' > "$h/fx/limits.json"; run "CLI prints non-JSON" "$h"
h=$(world hang); touch "$h/fx/hang"; s=$(date +%s); run "CLI hangs (real 9 s bound)" "$h"; echo "  elapsed: $(( $(date +%s)-s )) s"
h=$(world nostates); setj "$h" limits 'del(.activeStates)'; setj "$h" list '.sandboxes[0].type="xlarge"|.sandboxes[0].archiveAfter=null'; run "activeStates missing, with an xlarge no-stop box (no guessed list)" "$h"
h=$(world paged); setj "$h" list '.pageInfo.hasMore=true'; run "sandbox list has more pages" "$h"
h=$(world norefill); setj "$h" billing 'del(.prepaid.enabled)'; setj "$h" limits 'del(.creditUsedSeconds)'; run "refill and spend fields missing - one consolidated part" "$h"
h=$(world transient); setj "$h" billing '.prepaid.enabled=true'; cp "$h/fx/limits.json" "$h/fx/limits.good"; echo oops > "$h/fx/limits.json"
run "transient: failed read" "$h"; run "transient: still failing 5 min later (retries Boat, no second line)" "$h" FM_BOAT_SPEND_NOW=$((NOW+300))
cp "$h/fx/limits.good" "$h/fx/limits.json"; run "transient: recovered 10 min later, same day" "$h" FM_BOAT_SPEND_NOW=$((NOW+600))
h=$(world persist); echo oops > "$h/fx/limits.json"; run "persistent: day 1" "$h"; run "persistent: +12h" "$h" FM_BOAT_SPEND_NOW=$((NOW+43200)); run "persistent: +24h" "$h" FM_BOAT_SPEND_NOW=$((NOW+86400))

echo "===== 6. invalid config runs nothing"
i=0; for cfg in '' '{} {"ceiling_usd":1}' '[]' '{"cieling_usd":30}' '{"ceiling_usd":0}' '{"ceiling_usd":"30"}' '{"expected_running":1.5}' '{"boat_bin":"bin/boat"}' '{"boat_bin":"/nonexistent/boat"}' '{"boat_bin":"/etc/hostname"}' '{not json'; do
  i=$((i+1)); h=$(world "bad$i"); printf '%s\n' "$cfg" > "$h/config/boat-spend.json"; run "config: ${cfg:-<empty file>}" "$h"
  out=$(FM_HOME="$h" "$CHECK" arm 2>&1); echo "  arm: exit=$? ${out/$T/<tmp>}"
done

echo "===== 7. boat_bin key, no boat on PATH, no FM_BOAT_BIN"
h=$(world key); printf '{"boat_bin":"%s"}\n' "$h/fx/boat" > "$h/config/boat-spend.json"; setj "$h" billing '.prepaid.enabled=true'
out=$(env -u FM_BOAT_BIN -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE PATH=/usr/bin:/bin:"$(dirname "$(command -v jq)")" FM_HOME="$h" FM_BOAT_SPEND_NOW="$NOW" "$CHECK" check 2>&1); echo "  exit=$? stdout: ${out:-<silent>}"
h2=$(world nokey); out=$(env -u FM_BOAT_BIN -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE PATH=/usr/bin:/bin:"$(dirname "$(command -v jq)")" FM_HOME="$h2" FM_BOAT_SPEND_NOW="$NOW" "$CHECK" check 2>&1); echo "  without the key: exit=$? stdout: ${out:-<silent>}"

echo "===== 8. read-only: every argv the CLI received across all runs above"
sort "$CALLS" | uniq -c | sed 's/^/  /'
