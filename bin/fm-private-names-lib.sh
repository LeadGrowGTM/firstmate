# shellcheck shell=bash
# shellcheck disable=SC2034 # FM_PN_* paths are read by sourcing callers.
# Shared private-name guard: matching, neutral-id scrubbing, and repository
# visibility for the one gitignored private-name list.
#
# Usage: . bin/fm-private-names-lib.sh, then fm_pn_init <config-dir> <state-dir>.
#
# THE LIST. config/private-names holds one private name per line as
# "<kind> <name>" or "<kind>:context <name>", where kind is mate, client, or private; '#' lines and blank
# lines are ignored. bin/fm-private-names.sh refresh is its only writer and
# owns how names are derived from local records; config/private-names.local is
# the operator's hand-edited input to that refresh. Publishing guards read
# the list. A name matches case-insensitively as a whole word, where a word
# character is [A-Za-z0-9_], so a hyphen, slash, dot, or space ends a word and
# a name never matches inside a longer word. Context-tier names match only in
# fm-homes/<name>, <name>.status, <name>.inbox, <name> mate, <name> home,
# <name> second mate, and @<name>.
#
# NEUTRAL IDS. Each listed name maps to "<kind>-<n>", where n counts entries of
# that kind in list order (mate-1, mate-2, client-1, ...). Refresh only appends,
# so an id stays stable while the list grows. Every report this library prints
# names a neutral id and a location, never the matched name itself, because a
# refusal message can itself land in a public log or pipeline evidence.
#
# VISIBILITY. Only a public destination is checked; a private one passes
# untouched. fm_pn_visibility decides, in order:
#   1. config/repo-visibility, an explicit local list of "<repo> public"
#      lines, where <repo> is a GitHub owner/repo or a literal remote URL or path;
#   2. a local path or file:// URL is private (local disk is not a public exit);
#   3. a GitHub URL or owner/repo asks GitHub once through the real gh
#      (gh api repos/<owner>/<repo> --jq .visibility) and caches the answer in
#      state/repo-visibility.cache for 30 days. Private and internal answers
#      are never cached; a failed lookup is public and is not cached;
#   4. any other network URL is public.
# An absent or empty list on a public destination refuses rather than passing.

FM_PN_CONFIG=
FM_PN_STATE=
FM_PN_LIST=
FM_PN_LOCAL=
FM_PN_VISIBILITY=
FM_PN_CACHE=
FM_PN_PUBLIC_TTL=${FM_PN_PUBLIC_TTL:-2592000}
# Tracked list of ordinary words that refresh puts in the context tier.
FM_PN_GENERIC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-private-names-generic.txt"
# Marker file that identifies a gh shim directory, so the real-binary lookup
# skips every shim directory on PATH, including a parent launch's.
FM_PN_SHIM_MARKER=.fm-private-names-shim

fm_pn_init() {  # <config-dir> <state-dir>
  FM_PN_CONFIG=$1
  FM_PN_STATE=$2
  FM_PN_LIST=$FM_PN_CONFIG/private-names
  FM_PN_LOCAL=$FM_PN_CONFIG/private-names.local
  FM_PN_VISIBILITY=$FM_PN_CONFIG/repo-visibility
  FM_PN_CACHE=$FM_PN_STATE/repo-visibility.cache
}

# Number of names in the list; 0 when the list is absent or unreadable.
fm_pn_count() {
  [ -f "$FM_PN_LIST" ] && [ -r "$FM_PN_LIST" ] || {
    echo 0
    return 0
  }
  awk 'NF >= 2 && $1 !~ /^#/ { n++ } END { print n + 0 }' "$FM_PN_LIST"
}

# The matcher. Mode check prints "<line> <id>[,<id>...]" for every input line
# holding a listed name and exits 1 when any matched; mode scrub prints the
# input with every listed name replaced by its neutral id. Longest names are
# tried first so a name containing a shorter listed name is replaced whole.
fm_pn_perl() {  # <check|scrub> <list-file>
  perl -e '
    use strict; use warnings;
    my ($mode, $list) = @ARGV; @ARGV = ();
    my (%id, %seen, %count, @plain, @context, @names);
    open(my $fh, "<", $list) or die "fm-private-names: cannot read list\n";
    while (my $line = <$fh>) {
      $line =~ s/\r?\n\z//;
      next if $line =~ /^\s*(#|$)/;
      my ($kind, $name) = $line =~ /^\s*(\S+)\s+(.*?)\s*$/ or next;
      my $context = $kind =~ s/:context\z//;
      next if $name eq "" || $seen{lc $name}++;
      $count{$kind}++;
      $id{lc $name} = "$kind-$count{$kind}";
      push @names, $name;
      push @{$context ? \@context : \@plain}, $name;
    }
    close $fh;
    exit 0 unless @names;
    my $plain = join "|", map { quotemeta } sort { length($b) <=> length($a) } @plain;
    my $context = join "|", map { quotemeta } sort { length($b) <=> length($a) } @context;
    my @patterns;
    push @patterns, "(?<![A-Za-z0-9_])($plain)(?![A-Za-z0-9_])" if @plain;
    if (@context) {
      push @patterns, "(?<=fm-homes/)($context)(?![A-Za-z0-9_])";
      push @patterns, "(?<=@)($context)(?![A-Za-z0-9_])";
      push @patterns, "(?<![A-Za-z0-9_])($context)(?=\\.status\\b|\\.inbox\\b|\\s+(?:mate|home|second\\s+mate)\\b)";
    }
    my $re = qr/(?|@{[join "|", @patterns]})/i;
    my $hit = 0;
    while (my $line = <STDIN>) {
      if ($mode eq "scrub") {
        $line =~ s/$re/$id{lc $1}/g;
        print $line;
        next;
      }
      my %ids;
      while ($line =~ /$re/g) { $ids{$id{lc $1}} = 1; }
      next unless %ids;
      $hit = 1;
      print "$. ", join(",", sort keys %ids), "\n";
    }
    exit($hit ? 1 : 0);
  ' "$1" "$2"
}

# Scan stdin. Prints matcher findings; 0 clean, 1 a listed name is present.
fm_pn_check_stream() {
  [ -s "$FM_PN_LIST" ] || return 0
  fm_pn_perl check "$FM_PN_LIST"
}

# Copy stdin to stdout with every listed name rewritten to its neutral id.
fm_pn_scrub_stream() {
  if [ -s "$FM_PN_LIST" ]; then
    fm_pn_perl scrub "$FM_PN_LIST"
  else
    cat
  fi
}

# Scrub one string argument; prints the rewritten string without a newline.
fm_pn_scrub_string() {  # <text>
  local out
  out=$(printf '%s\n' "$1" | fm_pn_scrub_stream; printf x) || return 1
  out=${out%x}
  printf '%s' "${out%$'\n'}"
}

# Canonical repository identity: lowercase owner/repo for GitHub, the literal
# value otherwise.
fm_pn_repo_id() {  # <url|owner/repo|path>
  local v=$1 rest
  case "$v" in
    https://github.com/* | http://github.com/* | ssh://git@github.com/* | git@github.com:* | git://github.com/*)
      rest=${v#*github.com}
      rest=${rest#[:/]}
      rest=${rest%/}
      rest=${rest%.git}
      printf '%s\n' "$rest" | tr '[:upper:]' '[:lower:]'
      ;;
    *://* | *@*:* | /* | ./* | ../* | ~*)
      printf '%s\n' "$v"
      ;;
    */*)
      case "$v" in
        */*/*) printf '%s\n' "$v" ;;
        *) printf '%s\n' "${v%.git}" | tr '[:upper:]' '[:lower:]' ;;
      esac
      ;;
    *) printf '%s\n' "$v" ;;
  esac
}

# Real executable for <name> on PATH, skipping every gh shim directory.
fm_pn_real_bin() {  # <name>
  local name=$1 dir old_ifs=$IFS
  IFS=:
  for dir in $PATH; do
    IFS=$old_ifs
    [ -n "$dir" ] || continue
    [ -e "$dir/$FM_PN_SHIM_MARKER" ] && continue
    if [ -x "$dir/$name" ] && [ ! -d "$dir/$name" ]; then
      printf '%s\n' "$dir/$name"
      return 0
    fi
  done
  IFS=$old_ifs
  return 1
}

fm_pn_explicit_visibility() {  # <repo-id> <raw>
  local id=$1 raw=$2 key value
  [ -f "$FM_PN_VISIBILITY" ] || return 1
  while read -r key value _; do
    case "$key" in '' | '#'*) continue ;; esac
    [ "$value" = public ] || continue
    if [ "$key" = "$raw" ] || [ "$(fm_pn_repo_id "$key")" = "$id" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  done <"$FM_PN_VISIBILITY"
  return 1
}

fm_pn_cached_visibility() {  # <repo-id>
  local id=$1 now key value at
  [ -f "$FM_PN_CACHE" ] || return 1
  now=$(date +%s)
  while read -r key value at; do
    [ "$key" = "$id" ] || continue
    [ "$value" = public ] || continue
    case "$at" in '' | *[!0-9]*) continue ;; esac
    if [ $((now - at)) -lt "$FM_PN_PUBLIC_TTL" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  done <"$FM_PN_CACHE"
  return 1
}

fm_pn_cache_store() {  # <repo-id> <public|private>
  local id=$1 value=$2 tmp
  mkdir -p "$FM_PN_STATE" 2>/dev/null || return 0
  tmp=$(mktemp "$FM_PN_STATE/.repo-visibility.XXXXXX" 2>/dev/null) || return 0
  {
    [ -f "$FM_PN_CACHE" ] && awk -v id="$id" '$1 != id' "$FM_PN_CACHE"
    printf '%s %s %s\n' "$id" "$value" "$(date +%s)"
  } >"$tmp" || {
    rm -f "$tmp"
    return 0
  }
  mv "$tmp" "$FM_PN_CACHE" || rm -f "$tmp"
}

# Prints public or private for a destination; see VISIBILITY above.
fm_pn_visibility() {  # <url|owner/repo|path>
  local raw=$1 live=${2:-} id gh answer host=github.com api_id cache_id
  id=$(fm_pn_repo_id "$raw")
  if [ "$live" != live ] && fm_pn_explicit_visibility "$id" "$raw"; then
    return 0
  fi
  case "$raw" in
    file://* | /* | ./* | ../* | ~*)
      echo private
      return 0
      ;;
  esac
  api_id=$id
  case "$raw" in
    *://*)
      host=${raw#*://}
      host=${host#*@}
      host=${host%%/*}
      api_id=${raw#*://}
      api_id=${api_id#*/}
      ;;
    *@*:*)
      host=${raw#*@}
      host=${host%%:*}
      api_id=${raw#*:}
      ;;
    */*/*)
      host=${raw%%/*}
      api_id=${raw#*/}
      ;;
  esac
  api_id=${api_id%/}
  api_id=${api_id%.git}
  case "$api_id" in
    */*) ;;
    *)
      case "$raw" in *://* | *@*:*) echo public ;; *) echo private ;; esac
      return 0
      ;;
  esac
  cache_id=$id
  [ "$host" = github.com ] || cache_id=$host/$api_id
  if [ "$live" != live ] && fm_pn_cached_visibility "$cache_id"; then
    return 0
  fi
  answer=
  if gh=$(fm_pn_real_bin gh); then
    answer=$("$gh" api "repos/$api_id" --hostname "$host" --jq .visibility 2>/dev/null) || answer=
  fi
  case "$answer" in
    public)
      fm_pn_cache_store "$cache_id" public
      echo public
      ;;
    private | internal) echo private ;;
    *)
      if [ "$live" = live ]; then return 1; fi
      echo public
      ;;
  esac
}

# 0 when <dest> is public and therefore checked, 1 when it is private.
fm_pn_dest_is_public() {  # <dest>
  [ "$(fm_pn_visibility "$1")" = public ]
}

# Refusal for a public destination with no usable list. Prints the reason and
# returns 3; returns 0 when the list has names.
fm_pn_require_list() {  # <what>
  [ "$(fm_pn_count)" -gt 0 ] && return 0
  echo "fm-private-names: refusing $1: the private-name list config/private-names is missing or empty, so a public destination cannot be checked; run bin/fm-private-names.sh refresh in this home" >&2
  return 3
}
