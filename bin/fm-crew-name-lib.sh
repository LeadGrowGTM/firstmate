#!/usr/bin/env bash
# fm-crew-name-lib.sh - the visible names a home's short form selects for new
# work: worker window labels and the default ship-branch prefix.
#
# Without a short form a worker shows as fm-<id> on branch fm/<id>, so every
# crew reads as the first mate's own. With one, a worker this home spawns shows
# as <short>-crew-<id> on branch <short>/crew/<id>, and a second mate this home
# launches shows its plain id.
#
# This file is the single owner of the declaration format and of the names it
# produces. docs/configuration.md "Crew names" is the operator reference.
# Consumers: bin/fm-project-mode.sh, bin/fm-brief.sh, bin/fm-spawn.sh and
# bin/fm-promote.sh take their default ship-branch prefix from
# fm_crew_default_branch_prefix, so a registered branch=<prefix> or an explicit
# --branch-prefix still wins. bin/fm-spawn.sh asks fm_crew_window_label for a
# fresh endpoint's visible label; the endpoint's address (fm-<id>) never
# changes, and only the tmux backend can show a label apart from that address.
#
# Declaration: config/mate-short-name in the spawning home, holding one short
# form: 1-16 characters of lowercase letters, digits and inner dashes, for
# example `nap`, on one line with an optional final newline. A missing or
# empty file means no short form and today's names exactly. Any other shape
# is malformed: the lookup prints an error and returns 1 so a caller refuses
# rather than guessing a name.
#
# No side effects on source.

fm_crew_short_name() {  # <config-dir> -> prints the short form, or nothing when unset
  local file=$1/mate-short-name value= extra=
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: $file is not a readable file" >&2
    return 1
  fi
  [ -s "$file" ] || return 0
  {
    IFS= read -r value || :
    if IFS= read -r extra || [ -n "$extra" ]; then
      echo "error: $file must contain one short form on one line" >&2
      return 1
    fi
  } <"$file"
  if [ "${#value}" -gt 16 ] || ! printf '%s' "$value" | grep -Eqx '[a-z0-9]([a-z0-9-]*[a-z0-9])?'; then
    echo "error: $file holds '$value'; a short form is 1-16 lowercase letters, digits and inner dashes" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

fm_crew_default_branch_prefix() {  # <config-dir> -> "<short>/crew/" or "fm/"
  local short
  short=$(fm_crew_short_name "$1") || return 1
  if [ -n "$short" ]; then
    printf '%s/crew/\n' "$short"
  else
    printf 'fm/\n'
  fi
}

fm_crew_window_label() {  # <config-dir> <kind> <id> -> visible label, or nothing when unset
  local short
  short=$(fm_crew_short_name "$1") || return 1
  [ -n "$short" ] || return 0
  if [ "$2" = secondmate ]; then
    printf '%s\n' "$3"
  else
    printf '%s-crew-%s\n' "$short" "$3"
  fi
}
