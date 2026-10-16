#!/usr/bin/env bash
# fm-crew-name-lib.sh - the visible names a home's short form selects for new
# work: worker window labels and the default ship-branch prefix.
#
# docs/configuration.md "Crew names" owns the declaration and naming contract.
# Consumers: bin/fm-project-mode.sh, bin/fm-brief.sh and bin/fm-promote.sh take
# their default ship-branch prefix from fm_crew_default_branch_prefix, so a
# registered branch=<prefix> or an explicit --branch-prefix still wins.
# bin/fm-spawn.sh reads fm_crew_usable_short_name once and derives both its
# default prefix and a fresh tmux endpoint's visible label from it; the
# endpoint's address (fm-<id>) never changes. A malformed declaration only
# warns and falls back to the fm- names, so it never blocks work.
#
# No side effects on source.

fm_crew_short_name() {  # <config-dir> -> prints the short form, or nothing when unset
  local file=$1/mate-short-name value='' extra=''
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

# fm_crew_usable_short_name <config-dir> -> the short form, or nothing when it
# is unset or malformed. A malformed declaration never blocks work: it prints
# one warning naming the file and falls back to today's fm- names.
fm_crew_usable_short_name() {
  local short
  if short=$(fm_crew_short_name "$1" 2>&1); then
    printf '%s\n' "$short"
  else
    echo "warning: ${short#error: }; using the default fm- names" >&2
  fi
}

fm_crew_branch_prefix_for() {  # <short-or-empty> -> "<short>/crew/" or "fm/"
  if [ -n "$1" ]; then
    printf '%s/crew/\n' "$1"
  else
    printf 'fm/\n'
  fi
}

fm_crew_label_for() {  # <short-or-empty> <kind> <id> -> visible label, or nothing
  [ -n "$1" ] || return 0
  if [ "$2" = secondmate ]; then
    printf '%s\n' "$3"
  else
    printf '%s-crew-%s\n' "$1" "$3"
  fi
}

fm_crew_default_branch_prefix() {  # <config-dir> -> "<short>/crew/" or "fm/"
  fm_crew_branch_prefix_for "$(fm_crew_usable_short_name "$1")"
}

fm_crew_window_label() {  # <config-dir> <kind> <id> -> visible label, or nothing
  fm_crew_label_for "$(fm_crew_usable_short_name "$1")" "$2" "$3"
}
