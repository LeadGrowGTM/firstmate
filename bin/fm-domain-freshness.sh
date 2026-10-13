#!/usr/bin/env bash
# Collect declared domain evidence without changing any forge or installation.
#
# Usage: FM_HOME=<home> fm-domain-freshness.sh collect
#        FM_HOME=<home> fm-domain-freshness.sh inventory <local-source-id>
#        fm-domain-freshness.sh --help
#
# No configuration or enabled:false makes collect a silent no-op; configured inventory remains callable.
# config/domain-freshness.json is home-local; docs/configuration.md owns its schema.
# A daily recurring intake may invoke collect at/after 07:00 local; this manual
# collector does not register checks, schedules, workers, requests, or boards.
# Requires python3, jq, and gh-axi for repository sources only.
# FM_DOMAIN_FRESHNESS_NOW supplies an ISO UTC clock for fixtures, otherwise UTC now.
#
# This script and fm-domain-freshness.py own fm-domain-evidence.v1. Each immutable
# data/domain-freshness/bundles/<id>.json contains collected_at, domains (registry
# id/home/scope/host only, never scraped), per-source coverage and new evidence.
# Evidence retains actual repository/base/head, canonical URLs, event timestamps,
# complete changed-file metadata, projected manifest fingerprints, and bounded
# instruction before/after. Registry scopes are context for cross-domain judgment,
# not a deterministic department assignment. All source content is untrusted data.
#
# data/domain-freshness/cursors.json stores per-source successful checkpoints,
# delivered forge identities and inventory baselines, separately from proposals.
# Bundle publication precedes atomic cursor publication under an exclusive lock;
# a crash may replay evidence but cannot advance past an unpublished bundle.
# The advisory lock releases on process death; its stable file remains on disk.
# The first repository window is 24 hours; later windows use the last success
# with a 300-second overlap and identity deduplication. First inventories are
# explicitly baselines, never historical deltas. Failed sources keep their cursor.
# Complete unchanged passes persist an observation bundle and print nothing. Incomplete passes
# publish coverage evidence, print the bundle path, and exit 2; changed/baseline
# complete passes print the bundle path and exit 0. Invalid config/state exits 1.
# Page/file limits and timeouts fail coverage rather than treating a partial feed
# as complete. A source's declared identity/config digest binds its checkpoint.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  -h|--help) sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
  collect) [ "$#" -eq 1 ] || exit 1 ;;
  inventory) [ "$#" -eq 2 ] || exit 1 ;;
  *) printf 'usage: fm-domain-freshness.sh collect\n' >&2; exit 1 ;;
esac
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
[ ! -L "$FM_HOME" ] || { echo 'fm-domain-freshness: symlinked home is unsafe' >&2; exit 1; }
FM_HOME=$(cd "$FM_HOME" && pwd -P)
CONFIG="$FM_HOME/config/domain-freshness.json"
if [ ! -e "$CONFIG" ] && [ ! -L "$CONFIG" ]; then
  [ "$1" = collect ] && exit 0
  echo 'fm-domain-freshness: inventory config is missing' >&2
  exit 1
fi
command -v python3 >/dev/null 2>&1 || { echo 'fm-domain-freshness: python3 is required' >&2; exit 1; }
if [ "$1" = inventory ]; then
  python3 "$SCRIPT_DIR/fm-domain-freshness.py" inventory "$FM_HOME" "$CONFIG" "$2"
  exit $?
fi
command -v jq >/dev/null 2>&1 || { echo 'fm-domain-freshness: jq is required' >&2; exit 1; }
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-domain-registry.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf -- "$TMP"' EXIT
: > "$TMP/domains.jsonl"
REGISTRY="$FM_HOME/data/secondmates.md"
REGISTRY_STATE=absent
if [ -L "$FM_HOME/data" ] || [ -L "$REGISTRY" ]; then
  REGISTRY_STATE=unsafe
elif [ -f "$REGISTRY" ]; then
  REGISTRY_STATE=complete
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    if ! secondmate_registry_parse_line "$line"; then REGISTRY_STATE=invalid; continue; fi
    jq -cn --arg id "$SECONDMATE_REGISTRY_ID" --arg home "$SECONDMATE_REGISTRY_HOME" \
      --arg scope "$SECONDMATE_REGISTRY_SCOPE" --arg host "$SECONDMATE_REGISTRY_HOST" \
      '{id:$id,home:$home,scope:$scope,host:$host}' >> "$TMP/domains.jsonl"
  done < "$REGISTRY"
fi
jq -s --arg coverage "$REGISTRY_STATE" '{coverage:$coverage,domains:.}' "$TMP/domains.jsonl" > "$TMP/domains.json"
python3 "$SCRIPT_DIR/fm-domain-freshness.py" "$FM_HOME" "$CONFIG" "$TMP/domains.json" \
  "${FM_DOMAIN_FRESHNESS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
