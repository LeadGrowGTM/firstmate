# shellcheck shell=bash
# shellcheck disable=SC2034 # FM_PN_* paths are read by sourcing callers.
# Shared private-name guard: matching, neutral-id scrubbing, and repository
# visibility for the one gitignored private-name list.
#
# Usage: . bin/fm-private-names-lib.sh, then fm_pn_init <config-dir> <state-dir>.
#
# THE LIST. config/private-names holds one private name per line as
# "<kind> <name>", where kind is mate, client, or private; '#' lines and blank
# lines are ignored. bin/fm-private-names.sh refresh is its only writer and
# owns how names are derived from local records; config/private-names.local is
# the operator's hand-edited input to that refresh. Tracked code only reads
# the list. A name matches case-insensitively on word boundaries, where a word
# character is [A-Za-z0-9_], so a hyphen, slash, dot, or space ends a word.
#
# NEUTRAL IDS. Each listed name maps to "<kind>-<n>", where n counts entries of
# that kind in list order (mate-1, mate-2, client-1, ...). Refresh only appends,
# so an id stays stable while the list grows. Every report this library prints
# names a neutral id and a location, never the matched name itself, because a
# refusal message can itself land in a public log or pipeline evidence.
#
# VISIBILITY. Only a public destination is checked; a private one passes
# untouched. fm_pn_visibility decides, in order:
#   1. config/repo-visibility, an explicit local list of "<repo> public|private"
#      lines, where <repo> is a GitHub owner/repo or a literal remote URL or path;
#   2. a local path or file:// URL is private (local disk is not a public exit);
#   3. a GitHub URL or owner/repo asks GitHub once through the real gh
#      (gh api repos/<owner>/<repo> --jq .visibility) and caches the answer in
#      state/repo-visibility.cache: a public answer for 30 days, a private or
#      internal one for 1 hour, so a repository flipped to public is checked
#      again soon; a failed lookup is treated as public and is not cached;
#   4. any other network URL is public.
# An absent or empty list on a public destination refuses rather than passing.

FM_PN_CONFIG=
FM_PN_STATE=
FM_PN_LIST=
FM_PN_LOCAL=
FM_PN_VISIBILITY=
FM_PN_CACHE=
FM_PN_PUBLIC_TTL=${FM_PN_PUBLIC_TTL:-2592000}
FM_PN_PRIVATE_TTL=${FM_PN_PRIVATE_TTL:-3600}
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
    my (%id, %seen, %count, @names);
    open(my $fh, "<", $list) or die "fm-private-names: cannot read list\n";
    while (my $line = <$fh>) {
      $line =~ s/\r?\n\z//;
      next if $line =~ /^\s*(#|$)/;
      my ($kind, $name) = $line =~ /^\s*(\S+)\s+(.*?)\s*$/ or next;
      next if $name eq "" || $seen{lc $name}++;
      $count{$kind}++;
      $id{lc $name} = "$kind-$count{$kind}";
      push @names, $name;
    }
    close $fh;
    exit 0 unless @names;
    my $alt = join "|", map { quotemeta } sort { length($b) <=> length($a) } @names;
    my $re = qr/(?<![A-Za-z0-9_])($alt)(?![A-Za-z0-9_])/i;
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
    case "$value" in public | private) ;; *) continue ;; esac
    if [ "$key" = "$raw" ] || [ "$(fm_pn_repo_id "$key")" = "$id" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  done <"$FM_PN_VISIBILITY"
  return 1
}

fm_pn_cached_visibility() {  # <repo-id>
  local id=$1 now key value at ttl
  [ -f "$FM_PN_CACHE" ] || return 1
  now=$(date +%s)
  while read -r key value at; do
    [ "$key" = "$id" ] || continue
    case "$at" in '' | *[!0-9]*) continue ;; esac
    ttl=$FM_PN_PRIVATE_TTL
    [ "$value" = public ] && ttl=$FM_PN_PUBLIC_TTL
    if [ $((now - at)) -lt "$ttl" ]; then
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
  local raw=$1 id gh answer
  id=$(fm_pn_repo_id "$raw")
  if fm_pn_explicit_visibility "$id" "$raw"; then
    return 0
  fi
  case "$raw" in
    file://* | /* | ./* | ../* | ~*)
      echo private
      return 0
      ;;
  esac
  case "$id" in
    *://* | *@*:*)
      echo public
      return 0
      ;;
  esac
  case "$id" in
    */*) ;;
    *)
      # A bare relative path with no slash is a local directory remote.
      echo private
      return 0
      ;;
  esac
  if fm_pn_cached_visibility "$id"; then
    return 0
  fi
  answer=
  if gh=$(fm_pn_real_bin gh); then
    answer=$("$gh" api "repos/$id" --jq .visibility 2>/dev/null) || answer=
  fi
  case "$answer" in
    public)
      fm_pn_cache_store "$id" public
      echo public
      ;;
    private | internal)
      fm_pn_cache_store "$id" private
      echo private
      ;;
    *) echo public ;;
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
  echo "fm-private-names: refusing $1: the private-name list $FM_PN_LIST is missing or empty, so a public destination cannot be checked; run bin/fm-private-names.sh refresh in this home" >&2
  return 3
}
