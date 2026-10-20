#!/usr/bin/env bash
# Owner of the Muse client-data decision for a launch.
# A Muse launch carries client data when the spawning home is one of the
# client homes below, or when the task brief carries the exact marker line
# `client-data: yes` (written by bin/fm-brief.sh --client).
# The decision is deterministic: it is never inferred from brief prose.
# Such a launch must pass --contributor-mode off (per-run, never persisted),
# so its prompts do not enter the contributor tier.
# bin/fm-spawn.sh is the only consumer; docs/configuration.md "Muse
# permission mode" owns the operator-facing rule.

# The one owner list of client home basenames.
FM_MUSE_CLIENT_HOMES="ikeuchi launchclub polyshares pewter ottersec napoleon"

# The exact brief marker line that marks a task as carrying client data.
FM_MUSE_CLIENT_MARKER="client-data: yes"

fm_muse_client_home_p() { # <home-path>
  local path base
  local h
  path=$(CDPATH='' cd -- "${1:-}" 2>/dev/null && pwd -P) || return 1
  base=${path##*/}
  for h in $FM_MUSE_CLIENT_HOMES; do
    [ "$base" = "$h" ] && return 0
  done
  return 1
}

fm_muse_brief_client_p() { # <brief-path>
  [ -f "${1:-}" ] || return 1
  grep -qxF -- "$FM_MUSE_CLIENT_MARKER" "$1" 2>/dev/null
}

fm_muse_carries_client_data() { # <home-path> <brief-path>
  fm_muse_client_home_p "${1:-}" || fm_muse_brief_client_p "${2:-}"
}

# Prints the contributor flag for a muse launch, with trailing space, or
# nothing when the launch does not carry client data.
fm_muse_contributor_flag() { # <home-path> <brief-path>
  if fm_muse_carries_client_data "${1:-}" "${2:-}"; then
    printf '%s' '--contributor-mode off '
  fi
}
