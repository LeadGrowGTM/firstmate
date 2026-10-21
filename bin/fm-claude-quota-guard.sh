#!/usr/bin/env bash
# Decide one Claude ship or scout launch against the subscription budget.
#
# Usage:
#   fm-claude-quota-guard.sh check --config <dir> --state <dir> --home <dir> \
#     --id <task-id> --brief <path> --model <name> --verdict <path> [--apply-status]
#
# bin/fm-claude-quota-guard-lib.sh owns the decision.
# docs/configuration.md "Claude quota guard" owns the config file.
# Exit 0 when the launch may proceed or was rerouted. The verdict file then
# holds action, harness, model, and effort, one key per line. Notices go to stdout.
# Exit 1 when the launch is refused or the config or task records cannot be
# trusted. Exit 75 on a cap or dispatch-route deferral.
# Exit 2 when the command line is unusable.
# --model may be empty. Pass it as --model= so an empty value is explicit.
# A missing quota reading never refuses the launch by itself.
# --apply-status appends the one pace, cap, or route line for this task. A retry of
# that same line appends nothing.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  printf '%s\n' 'usage: fm-claude-quota-guard.sh check --config <dir> --state <dir> --home <dir> --id <task-id> --brief <path> --model <name> --verdict <path> [--apply-status]' >&2
}

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-muse-client-lib.sh
. "$SCRIPT_DIR/fm-muse-client-lib.sh"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-claude-quota-guard-lib.sh
. "$SCRIPT_DIR/fm-claude-quota-guard-lib.sh"

[ "${1:-}" = check ] || { usage; exit 2; }
shift

config=
state=
home=
id=
brief=
model=
verdict=
model_set=0
apply=0
FM_CQG_REFUSAL_ONLY=0
FM_CQG_DISPATCH_RULE=
FM_CQG_EFFORT=default
while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      [ $# -ge 2 ] || { usage; exit 2; }
      config=$2
      shift 2
      ;;
    --config=*) config=${1#--config=}; shift ;;
    --state)
      [ $# -ge 2 ] || { usage; exit 2; }
      state=$2
      shift 2
      ;;
    --state=*) state=${1#--state=}; shift ;;
    --home)
      [ $# -ge 2 ] || { usage; exit 2; }
      home=$2
      shift 2
      ;;
    --home=*) home=${1#--home=}; shift ;;
    --id)
      [ $# -ge 2 ] || { usage; exit 2; }
      id=$2
      shift 2
      ;;
    --id=*) id=${1#--id=}; shift ;;
    --brief)
      [ $# -ge 2 ] || { usage; exit 2; }
      brief=$2
      shift 2
      ;;
    --brief=*) brief=${1#--brief=}; shift ;;
    --model=*) model=${1#--model=}; model_set=1; shift ;;
    --model)
      model_set=1
      if [ $# -ge 2 ] && [ "${2#--}" = "$2" ]; then
        model=$2
        shift 2
      else
        model=
        shift
      fi
      ;;
    --verdict)
      [ $# -ge 2 ] || { usage; exit 2; }
      verdict=$2
      shift 2
      ;;
    --verdict=*) verdict=${1#--verdict=}; shift ;;
    --apply-status) apply=1; shift ;;
    --refusal-only) FM_CQG_REFUSAL_ONLY=1; shift ;;
    --dispatch-rule) FM_CQG_DISPATCH_RULE=$2; shift 2 ;;
    --effort) FM_CQG_EFFORT=$2; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[ -n "$config" ] && [ -n "$state" ] && [ -n "$home" ] && [ -n "$id" ] && [ -n "$brief" ] && [ -n "$verdict" ] && [ "$model_set" = 1 ] || { usage; exit 2; }
case "$id" in
  ''|.*|*[!A-Za-z0-9._-]*) usage; exit 2 ;;
esac
[ "${#id}" -le 64 ] || { usage; exit 2; }

FM_CQG_APPLY_STATUS=$apply
fm_cqg_decide "$config" "$state" "$home" "$id" "$brief" "$model" "$verdict"
