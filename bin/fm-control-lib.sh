#!/usr/bin/env bash
# fm-control-lib.sh - the ONE executable owner of firstmate's agent lifecycle
# CONTROL-PLANE mechanics.
#
# Data plane vs control plane (captain-approved root architecture, 2026-07-13).
# bin/fm-send.sh is the DATA plane: conversational text for the agent to read,
# always routing-marked for a kind=secondmate target so the reply comes back
# through the status path. That marking is exactly right for a message and
# exactly wrong for a lifecycle command: a marked "/quit" arrives as ordinary
# chat ("[fm-from-firstmate] /quit") that the agent reasons ABOUT instead of
# executing. bin/fm-control.sh is the CONTROL plane: allowlisted lifecycle
# verbs addressed to an exact task id, with the per-harness mechanics owned
# here rather than improvised per harness in agent prose.
#
# This file owns three capability tables plus their pure artifact-path tables,
# and ONE named exception to that purity - fm_control_endpoint_absence_verdict,
# the single owner of the per-backend endpoint-absence proof, which does run
# backend reads. Everything else has no side effects, runs no backend command,
# and reads no state, so sourcing this file is still free and the tables can be
# read by a test as a pure contract:
#
#   1. Verb allowlist. There is no arbitrary-text and no generic raw-key entry
#      point on the control plane; a caller either names an allowlisted verb or
#      is refused.
#   2. Per-harness control mechanics: which key interrupts a running turn, how
#      many times it must be sent, whether the composer needs clearing after
#      that key, which adapter-owned cancellation acknowledgement is observable,
#      which command exits the agent, and which task kinds the adapter is
#      verified to run. These are the empirically verified facts previously
#      carried only in the harness-adapters skill's per-adapter tables; that
#      skill now points here so one executable owner holds them, and
#      bin/fm-send.sh's --key path reads the same table rather than a second
#      copy of it.
#   3. Per-backend capability: which named keys a runtime backend can deliver,
#      and whether the backend has a recovery-grade agent-state classifier
#      (bin/fm-backend.sh's fm_backend_agent_state) able to PROVE that an agent
#      stopped. A verb whose postcondition cannot be proven on the recorded
#      backend is refused rather than performed blind.
#
# `resume` is deliberately NOT a verb: it is not deterministic across the
# verified adapters (docs/agent-control.md owns the per-adapter resume facts).
# `relaunch` uses the brief on disk rather than a harness-private session as
# its durable instruction. The relaunch-time exception is
# fm_control_relaunch_resume_flag below: a reference the endpoint's runtime
# bound as its status authority is returned to a replacement with that adapter.

# The complete control-plane verb allowlist, one per line.
fm_control_verbs() {
  cat <<'EOF'
interrupt
exit
relaunch
EOF
}

fm_control_verb_allowed() {  # <verb>
  case "${1-}" in
    interrupt|exit|relaunch) return 0 ;;
  esac
  return 1
}

# The harnesses whose control mechanics are verified. Mirrors AGENTS.md
# section 4's verified-adapter list; an unverified adapter is refused rather
# than guessed at, exactly as a spawn on it would be.
fm_control_harnesses() {
  printf '%s\n' claude codex opencode pi pi-signed grok kimi cursor gemini muse rovo omp agy devin
}

fm_control_harness_supported() {  # <harness>
  local harness found=1
  while read -r harness; do
    [ "$harness" = "${1-}" ] && found=0
  done < <(fm_control_harnesses)
  return "$found"
}

# The verified adapter a RECORDED harness value belongs to. Every table below
# is keyed by the exact verified adapter name, but a task launched from a raw
# command records the command's basename instead (bin/fm-spawn.sh derives
# harness= that way), which is why the spawn adapters match `claude*`, `muse*`,
# and friends. This is the one place that prefix rule is stated. `pi` and
# `pi-signed` are exact because a `pi*` prefix would swallow the signed adapter,
# `omp` is exact because an `omp*` prefix would claim unrelated commands, `agy`
# is exact for the same reason on an even shorter name, and an
# unrecognized value returns nonzero rather than being guessed into a family.
fm_control_harness_family() {  # <recorded-harness>
  case "${1-}" in
    pi) printf 'pi' ;;
    pi-signed) printf 'pi-signed' ;;
    omp) printf 'omp' ;;
    agy) printf 'agy' ;;
    devin) printf 'devin' ;;
    claude*) printf 'claude' ;;
    codex*) printf 'codex' ;;
    opencode*) printf 'opencode' ;;
    grok*) printf 'grok' ;;
    kimi*) printf 'kimi' ;;
    cursor*) printf 'cursor' ;;
    gemini*) printf 'gemini' ;;
    muse*) printf 'muse' ;;
    rovo*) printf 'rovo' ;;
    *) return 1 ;;
  esac
}

# Which task kinds an adapter is verified to run. muse, gemini, rovo, agy, and devin
# are crewmate/scout adapters only: none has a primary supervision protocol,
# and bin/fm-spawn.sh refuses a --secondmate launch on any of them. The control
# plane asks this BEFORE it stops anything, so an incompatible relaunch target is
# refused while the current agent is still running rather than after it has
# been stopped.
fm_control_harness_supports_kind() {  # <harness> <kind>
  local harness=${1-} kind=${2-}
  fm_control_harness_supported "$harness" || return 1
  case "$harness" in
    muse|gemini|rovo|agy|devin) [ "$kind" != secondmate ] || return 1 ;;
  esac
  return 0
}

# The key that cancels a running turn. Escape for every adapter except grok,
# whose Esc only moves focus to the scrollback; grok cancels on Ctrl+C.
# gemini names its own key in the running turn's status row
# (`(esc to cancel, <n>s)`), and a single Escape was verified to cancel it.
# rovo cancels on a single Escape too, printing "Agent cancelled" (verified,
# 202609.1.2). agy cancels on a single Escape, printing the Interrupted row
# with an idle composer and no repollution (verified live, agy 1.2.0 through
# Herdr). omp (Oh My Pi) shares Pi's single Escape, empty composer
# afterwards, and /quit exit (verified omp 18.1.2 in a PTY, re-verified 18.1.11
# through Herdr).
fm_control_interrupt_key() {  # <harness>
  case "${1-}" in
    claude|codex|opencode|pi|pi-signed|omp|kimi|cursor|gemini|muse|rovo|agy|devin) printf 'Escape' ;;
    grok) printf 'C-c' ;;
    *) return 1 ;;
  esac
}

# How many times the interrupt key must be delivered. OpenCode and Devin need a double
# Escape; every other verified adapter interrupts on a single press.
fm_control_interrupt_repeat() {  # <harness>
  case "${1-}" in
    opencode|devin) printf '2' ;;
    claude|codex|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy) printf '1' ;;
    *) return 1 ;;
  esac
}

# The rendered proof, read from the visible viewport between presses, that the
# first interrupt press landed on a RUNNING turn; empty when the adapter sends
# its presses blind. Devin needs it because the same fast double Escape that
# cancels a running turn opens its /revert "Revert to step" picker on an idle
# agent, where a later Enter reverts file changes. One Escape on a running turn
# renders `esc again to interrupt` for about three seconds, while an idle agent
# renders nothing, so the second press is sent only after that proof and never
# sooner than fm_control_interrupt_press_gap: an unproven arm sends nothing
# more. Verified live on devin 3000.11.1: an idle pair opened the picker at a
# 0.05-0.1 s gap and did not at 0.15 s or more, and a running turn cancelled
# with a 0.6 s gap.
fm_control_interrupt_arm_signal() {  # <harness>
  case "${1-}" in
    devin) printf '%s' 'esc again to interrupt' ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy) ;;
    *) return 1 ;;
  esac
}

# The minimum seconds between two presses of an armed interrupt: several times
# Devin's observed idle double-tap window, well inside its three-second armed
# window. A turn that ends between the presses therefore cannot pair them.
fm_control_interrupt_press_gap() {  # <harness>
  case "${1-}" in
    devin) printf '0.5' ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy) printf '0.2' ;;
    *) return 1 ;;
  esac
}

# A rendered surface that a mistimed interrupt press can open and that must be
# dismissed with one more interrupt key before anything else is typed; empty
# when the adapter has none. Devin's revert picker is recognized by either of
# two independent rows, its `Revert to step:` title or its `↵ revert` footer,
# and Escape cancels it without reverting (verified live, devin 3000.11.1).
fm_control_interrupt_hazard_signal() {  # <harness>
  case "${1-}" in
    devin) printf '%s' 'Revert to step:|↵ revert' ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|muse|rovo|agy) ;;
    *) return 1 ;;
  esac
}

# The key that must follow the interrupt key to leave the composer empty, or
# nothing when the adapter needs none. muse is the one verified adapter that
# RESTORES the cancelled prompt into its composer as real bright text, so an
# interrupt is not complete until Ctrl+U has cleared it; leaving it there would
# make the next submitted line - a steer, or this plane's own exit command -
# concatenate onto it. cursor was checked for exactly that behaviour and does
# NOT repollute: after a single Escape its composer shows only the `Add a
# follow-up` placeholder, so it needs no clear key. gemini was checked the
# same way and also does not repollute: after a single Escape it prints
# `Request cancelled.` and its composer shows only the `Type your message
# or @path/to/file` placeholder. Prints the key or nothing;
# a harness with no verified mechanics returns nonzero, matching the tables
# above.
fm_control_interrupt_clear_key() {  # <harness>
  case "${1-}" in
    muse) printf 'C-u' ;;
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|rovo|agy|devin) ;;
    *) return 1 ;;
  esac
}

fm_control_interrupt_ack_source() {  # <harness>
  case "${1-}" in
    muse) printf 'muse-session-terminal' ;;
    # cursor's transcript DOES type an aborted close, but its write latency
    # after an interrupt was measured as variable - sometimes seconds, sometimes
    # not within 20 - so a cancellation claim built on it would be unreliable.
    # Normal turn completion is prompt, which is what the busy fold depends on.
    # rovo's TUI prints "Agent cancelled" on Escape, but for parity with
    # claude/cursor this stays 'none': the ack is a rendered string, not a
    # recorded state source, and rovo has no busy wiring to confirm against.
    claude|codex|opencode|pi|pi-signed|omp|grok|kimi|cursor|gemini|rovo|agy|devin) printf 'none' ;;
    *) return 1 ;;
  esac
}

# The command that exits the agent from its own composer.
fm_control_exit_command() {  # <harness>
  case "${1-}" in
    claude|opencode|grok|kimi|cursor|muse|rovo) printf '/exit' ;;
    codex|pi|pi-signed|omp|gemini|agy|devin) printf '/quit' ;;
    *) return 1 ;;
  esac
}

# The launch argument that makes a RELAUNCH of <harness> RESUME an exact agent
# session instead of starting a fresh one, printed only when <registered-agent>
# is the label that session reference belongs to; nothing otherwise.
#
# This exists for one runtime failure, not as a general resume feature. Herdr
# gives a pane one status authority, and for Pi with its installed integration
# that authority is the lifecycle hooks, which also suppress Herdr's screen
# detection for the pane. That registration outlives its agent process in the
# crew shape - a nested worktree shell under the pane's top shell - and Herdr
# then applies only reports carrying the session identity it bound. A
# replacement agent started fresh in that same pane reports a NEW session, so
# its state reports are ignored and the pane stays frozen at whatever the
# previous agent last reported: a working crewmate reads idle until its task
# ends (reproduced and fixed live 2026-09-21, herdr 0.9.1; the read that
# supplies the reference is
# bin/backends/herdr.sh's fm_backend_herdr_pane_agent_session_ref).
#
# So the reference is not chosen from what looks recent - it is the exact
# identity the endpoint's own runtime recorded, which is why a matched
# registered-agent label is required: resuming a reference reported by a
# DIFFERENT agent would inject another agent's conversation into this launch.
# `pi` is the label Pi and pi-signed both report, so one entry covers both.
# Every other harness returns nothing and keeps today's fresh-session
# relaunch, which is what the adapter tables above (and the absence of a
# verified resume form for those harnesses) require.
#
# Prints the flag name only; the caller quotes and appends the reference, since
# shell quoting belongs to the owner of the launch line (bin/fm-spawn.sh).
fm_control_relaunch_resume_flag() {  # <harness> <registered-agent>
  case "${1-}" in
    pi|pi-signed)
      [ "${2-}" = pi ] && printf -- '--session'
      ;;
  esac
  return 0
}

# Which named keys a backend adapter can deliver. Every session provider
# normalizes Enter, Ctrl+C, and the Ctrl+U composer clear; Orca's terminal API
# exposes only an interrupt and an Enter, so it can deliver neither Escape nor
# Ctrl+U (bin/backends/orca.sh's fm_backend_orca_send_key).
fm_control_backend_supports_key() {  # <backend> <key>
  local backend=${1-} key=${2-}
  case "$backend" in
    tmux|herdr|zellij|cmux)
      case "$key" in Escape|Enter|C-c|C-u) return 0 ;; esac
      ;;
    orca)
      case "$key" in Enter|C-c) return 0 ;; esac
      ;;
  esac
  return 1
}

# Whether <backend> has a recovery-grade agent-state classifier. Only tmux and
# herdr implement fm_backend_agent_state; zellij, orca, and cmux report
# `unverified`, so no reading of theirs can prove an agent stopped. The control
# plane refuses a stop-proving verb there instead of reporting an unprovable
# transition as success.
fm_control_backend_state_verified() {  # <backend>
  case "${1-}" in
    tmux|herdr) return 0 ;;
  esac
  return 1
}

fm_control_secondmate_crew_ids() {  # <meta> <worktree> -> crew task ids
  local meta=$1 worktree=$2 home_canon f kind id
  [ "$(fm_meta_get "$meta" kind)" = secondmate ] || return 0
  [ -d "$worktree" ] || return 1
  home_canon=$(CDPATH='' cd -- "$worktree" && pwd -P) || return 1
  for f in "$home_canon/state"/*.meta; do
    if [ ! -e "$f" ] && [ ! -L "$f" ]; then
      continue
    fi
    if [ ! -f "$f" ] || [ -L "$f" ] || [ ! -r "$f" ]; then
      return 1
    fi
    kind=$(fm_meta_get "$f" kind)
    case "$kind" in ship|scout) ;; *) continue ;; esac
    id=$(fm_backend_meta_exact_value "$f" endpoint_task_id) || continue
    [ "$id.meta" = "${f##*/}" ] || continue
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    printf '%s\n' "$id"
  done
}

fm_control_secondmate_crew_ancestors() {  # <meta> <worktree> -> crew pane shell pids
  local meta=$1 worktree=$2 home_canon f window pid backend kind id
  [ "$(fm_meta_get "$meta" kind)" = secondmate ] || return 0
  [ -d "$worktree" ] || return 0
  home_canon=$(CDPATH='' cd -- "$worktree" && pwd -P) || return 0
  for f in "$home_canon/state"/*.meta; do
    if [ ! -e "$f" ] && [ ! -L "$f" ]; then
      continue
    fi
    if [ ! -f "$f" ] || [ -L "$f" ] || [ ! -r "$f" ]; then
      continue
    fi
    kind=$(fm_meta_get "$f" kind)
    case "$kind" in ship|scout) ;; *) continue ;; esac
    id=$(fm_backend_meta_exact_value "$f" endpoint_task_id) || continue
    [ "$id.meta" = "${f##*/}" ] || continue
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    window=$(fm_backend_meta_exact_value "$f" window) || window=
    [ -n "$window" ] || continue
    if grep -q '^backend=' "$f"; then
      backend=$(fm_backend_meta_exact_value "$f" backend) || continue
    else
      backend=tmux
    fi
    pid=
    if [ "$backend" = tmux ]; then
      pid=$(tmux display-message -p -t "$window" '#{pane_pid}' 2>/dev/null) || pid=
    elif [ "$backend" = herdr ]; then
      fm_backend_source herdr >/dev/null 2>&1 || continue
      if fm_backend_herdr_parse_target "$window"; then
        pid=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane process-info --pane "$FM_BACKEND_HERDR_PANE" 2>/dev/null \
          | jq -er --arg pane "$FM_BACKEND_HERDR_PANE" \
            'select(.result.type == "pane_process_info" and .result.process_info.pane_id == $pane) | .result.process_info.shell_pid | select(type == "number" and . > 1) | floor' 2>/dev/null) || pid=
      fi
    fi
    case "$pid" in ''|*[!0-9]*) ;; *) printf '%s\n' "$pid" ;; esac
  done
  return 0
}

fm_control_process_task_id() {  # <pid> -> FM_TASK_ID
  local pid=$1 entry id='' seen=0
  [ "$(uname -s)" = Linux ] || return 1
  [ -r "/proc/$pid/environ" ] || return 1
  while IFS= read -r -d '' entry; do
    case "$entry" in
      FM_TASK_ID=*)
        [ "$seen" = 0 ] || return 1
        id=${entry#FM_TASK_ID=}
        seen=1
        ;;
    esac
  done < "/proc/$pid/environ" 2>/dev/null || return 1
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s' "$id"
}

fm_control_pid_descends_from() {  # <pid> <ancestor-pid>
  local pid=$1 ancestor=$2 hops=0 ppid
  while [ "$pid" != "$ancestor" ] && [ "$hops" -lt 64 ]; do
    case "$pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
    case "$ppid" in ''|*[!0-9]*|0) return 1 ;; esac
    pid=$ppid
    hops=$((hops + 1))
  done
  [ "$pid" = "$ancestor" ]
}

# fm_control_rooted_processes: fm_agent_worktree_processes with the second
# mate crew attribution above applied. Prints pids; nonzero means absence
# could not be proven, exactly as the unfiltered inventory means it.
fm_control_rooted_processes() {  # <backend> <meta> <worktree> [<pane-shell-pid>] -> pids
  local backend=$1 meta=$2 worktree=$3 pane_pid=${4:-} rooted ids_text pid ancestor id task_id keep
  local -a ancestors=() ids=()
  if [ "$(fm_meta_get "$meta" kind)" != secondmate ]; then
    fm_agent_worktree_processes "$worktree" "$pane_pid"
    return
  fi
  ids_text=$(fm_control_secondmate_crew_ids "$meta" "$worktree") || return 1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    ids+=("$id")
  done <<EOF
$ids_text
EOF
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    ancestors+=("$pid")
  done < <(fm_control_secondmate_crew_ancestors "$meta" "$worktree")
  rooted=$(fm_agent_worktree_processes "$worktree" "$pane_pid" ${ancestors[@]+"${ancestors[@]}"}) || return 1
  [ -n "$rooted" ] || return 0
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    keep=1
    if [ -n "$pane_pid" ] && fm_control_pid_descends_from "$pid" "$pane_pid"; then
      keep=1
    else
      for ancestor in ${ancestors[@]+"${ancestors[@]}"}; do
        if fm_control_pid_descends_from "$pid" "$ancestor"; then
          keep=0
          break
        fi
      done
      if [ "$keep" = 1 ] && task_id=$(fm_control_process_task_id "$pid"); then
        for id in ${ids[@]+"${ids[@]}"}; do
          [ "$task_id" != "$id" ] || { keep=0; break; }
        done
      fi
    fi
    [ "$keep" = 0 ] || printf '%s\n' "$pid"
  done <<EOF
$rooted
EOF
}

# fm_control_endpoint_absence_verdict: the ONE owner of the per-backend proof
# that an endpoint reading `missing` is actually GONE rather than merely
# unreachable from this seat. Call it only for a `missing` raw state. Tmux and
# Herdr callers pass the task record.
#
# Prints "<verdict>\t<reason>" - always exactly one TAB, so a caller splits
# unambiguously with ${raw%%$'\t'*} and ${raw#*$'\t'}. The reason is empty
# except on `unproven`, where it is the concrete sentence the caller's refusal
# message embeds. It is returned on stdout rather than set in a variable
# because every caller reads this through a command substitution, where an
# assignment made here could never reach them.
#
# The verdicts:
#   gone     - absence is PROVEN. There is no endpoint and therefore no agent.
#   dead     - the endpoint is there after all and holds no agent.
#   alive    - the endpoint is there and an agent is running in it.
#   unproven - neither could be established; the caller must refuse.
#
# fm_backend_agent_state's `missing` conflates "the endpoint was DESTROYED"
# with "the endpoint is UNREACHABLE from here right now". An unreachable
# endpoint can still hold a live agent on the task's worktree, so every caller
# that would act on absence - `exit` claiming the agent stopped, `relaunch`
# re-creating the endpoint - must come through here rather than trusting the
# raw verdict.
#
# Whether absence is provable AT ALL is a property of the backend, not of the
# reading:
#   herdr CAN prove it. Every read goes through fm_backend_herdr_cli, which
#     passes `--session <session>`, so the recheck starts and reads the session
#     the RECORD names, through that session's own socket. A missing pane also
#     needs a worktree process inventory before absence is proven.
#   tmux requires socket and server attribution plus a same-user process-cwd
#     inventory proving no process remains rooted in the recorded worktree.
#     A legacy record without a socket must pass the same conservative proof.
#
# Both control-plane callers share this one implementation so the proof cannot
# drift into two answers for the same endpoint.
fm_control_endpoint_absence_verdict() {  # <backend> <target> [<meta-file>]
  local backend=${1-} target=${2-} meta=${3-} socket spawn_gen worktree rooted
  local sock candidates probe kind pid started epoch process_inventory process_type process_pid found i
  local -a answering_pids=() answering_sockets=() server_pids=() tmux_pids=()
  fm_backend_source "$backend" \
    || { printf 'unproven\tbackend %s could not be loaded to prove anything about that endpoint' "'$backend'"; return 0; }
  case "$backend" in
    tmux)
      if [ ! -f "$meta" ] || [ -L "$meta" ] || [ ! -r "$meta" ]; then
        printf 'unproven\ttmux absence requires a readable regular task record'
        return 0
      fi
      if grep -q '^tmux_socket=' "$meta"; then
        socket=$(fm_backend_meta_exact_value "$meta" tmux_socket) || socket=
        case "$socket" in /*) ;; *) printf 'unproven\tthe recorded tmux socket identity is malformed'; return 0 ;; esac
        case "$socket" in *[$'\n\r\t']*) printf 'unproven\tthe recorded tmux socket identity is malformed'; return 0 ;; esac
      else
        socket=
      fi
      spawn_gen=$(fm_meta_get "$meta" spawn_gen)
      worktree=$(fm_backend_meta_exact_value "$meta" worktree) || worktree=
      case "$target" in
        *:*:*|'':*|*:'') printf 'unproven\ttmux target %s is not an exact session:window address' "'$target'"; return 0 ;;
        *:*) ;;
        *) printf 'unproven\ttmux target %s is not an exact session:window address' "'$target'"; return 0 ;;
      esac
      candidates=$(fm_backend_tmux_socket_candidates) || {
        printf 'unproven\ttmux socket directory %s could not be listed' "${candidates##*$'\n'}"
        return 0
      }
      [ -z "$socket" ] || candidates=$(printf '%s\n%s' "$socket" "$candidates")
      if [[ $spawn_gen =~ ^s([0-9]{1,12})\.[0-9]+\.[0-9]+$ ]]; then
        epoch=${BASH_REMATCH[1]}
      else
        epoch=
      fi
      while IFS= read -r sock; do
        [ -n "$sock" ] || continue
        probe=$(fm_backend_tmux_server_on_socket "$sock")
        read -r kind pid started <<< "$probe"
        case "$kind" in
          absent) continue ;;
          answer)
            answering_pids+=("$pid")
            answering_sockets+=("$sock")
            if { [ -z "$socket" ] || [ "$sock" = "$socket" ]; } &&
              { [ -z "$epoch" ] || (( 10#$started <= 10#$epoch )); }; then
              printf 'unproven\ttmux server %s on socket %s is not proven newer than spawn_gen %s' "$pid" "$sock" "$spawn_gen"
              return 0
            fi
            ;;
          *)
            printf 'unproven\ttmux socket %s could not be read' "$sock"
            return 0
            ;;
        esac
      done <<EOF
$candidates
EOF
      process_inventory=$(fm_backend_tmux_processes) || {
        printf 'unproven\ttmux process enumeration for uid %s failed' "$(id -u)"
        return 0
      }
      while read -r process_type process_pid; do
        [ -n "$process_type" ] || continue
        case "$process_type" in
          server) server_pids+=("$process_pid") ;;
          tmux) tmux_pids+=("$process_pid") ;;
        esac
      done <<< "$process_inventory"
      for process_pid in "${server_pids[@]}"; do
        found=0
        for pid in "${answering_pids[@]}"; do
          [ "$pid" != "$process_pid" ] || { found=1; break; }
        done
        if [ "$found" = 0 ]; then
          printf 'unproven\ttmux server process %s has no answering socket' "$process_pid"
          return 0
        fi
      done
      for i in "${!answering_pids[@]}"; do
        found=0
        for process_pid in "${server_pids[@]}"; do
          [ "$process_pid" != "${answering_pids[$i]}" ] || { found=1; break; }
        done
        if [ "$found" = 0 ]; then
          printf 'unproven\ttmux socket %s answers as server %s, but process enumeration cannot see it' "${answering_sockets[$i]}" "${answering_pids[$i]}"
          return 0
        fi
      done
      if [ "${#answering_pids[@]}" -eq 0 ] && [ "${#tmux_pids[@]}" -gt 0 ]; then
        printf 'unproven\ttmux process %s exists while no socket answers' "${tmux_pids[0]}"
        return 0
      fi
      if ! rooted=$(fm_control_rooted_processes tmux "$meta" "$worktree"); then
        printf 'unproven\tprocess absence in the recorded worktree could not be proven'
      elif [ -n "$rooted" ]; then
        printf 'unproven\tlive processes still have cwd in the recorded worktree (pids %s)' "$(printf '%s' "$rooted" | tr '\n' ' ')"
      else
        printf 'gone\tno live process is rooted in the recorded worktree'
      fi
      ;;
    herdr)
      # Start the RECORDED session's server (only the server - nothing is
      # created) and re-read the recorded pane. A pane that comes back with the
      # server was never destroyed.
      case "$(fm_backend_herdr_endpoint_absence_recheck "$target")" in
        dead) printf 'dead\t' ;;
        alive) printf 'alive\t' ;;
        missing)
          if [ ! -f "$meta" ] || [ -L "$meta" ] || [ ! -r "$meta" ]; then
            printf 'unproven\therdr absence requires a readable regular task record'
            return 0
          fi
          worktree=$(fm_backend_meta_exact_value "$meta" worktree) || worktree=
          if ! rooted=$(fm_control_rooted_processes herdr "$meta" "$worktree"); then
            printf 'unproven\tprocess absence in the recorded worktree could not be proven'
          elif [ -n "$rooted" ]; then
            printf 'unproven\tlive processes still have cwd in the recorded worktree (pids %s)' "$(printf '%s' "$rooted" | tr '\n' ' ')"
          else
            printf 'gone\tno live process is rooted in the recorded worktree'
          fi
          ;;
        *) printf 'unproven\tthe recorded herdr session'"'"'s server could not be started, or its pane could not be classified once it was running' ;;
      esac
      ;;
    *)
      printf 'unproven\tbackend %s has no recovery-grade classifier, so absence cannot be proven on it at all' "'$backend'"
      ;;
  esac
}

fm_control_dead_endpoint_process_verdict() {
  local backend=$1 target=$2 meta=$3 worktree pane_pid='' pane_comm rooted
  case "$backend" in
    tmux|herdr) ;;
    *) printf 'clear\t'; return 0 ;;
  esac
  if [ ! -f "$meta" ] || [ -L "$meta" ] || [ ! -r "$meta" ]; then
    printf 'unproven\tprocess absence requires a readable regular task record'
    return 0
  fi
  fm_backend_source "$backend" || { printf 'unproven\t%s backend could not be loaded' "$backend"; return 0; }
  worktree=$(fm_backend_meta_exact_value "$meta" worktree) || worktree=
  if [ "$backend" = tmux ]; then
    pane_pid=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null) || pane_pid=
    case "$pane_pid" in ''|*[!0-9]*) pane_pid= ;; esac
    if [ -n "$pane_pid" ]; then
      pane_comm=$(ps -p "$pane_pid" -o comm= 2>/dev/null) || pane_comm=
      [ "$(fm_agent_process_classify_name "$pane_comm")" = shell ] || pane_pid=
    fi
  elif fm_backend_herdr_parse_target "$target"; then
    pane_pid=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane process-info --pane "$FM_BACKEND_HERDR_PANE" 2>/dev/null \
      | jq -er --arg pane "$FM_BACKEND_HERDR_PANE" \
        'select(.result.type == "pane_process_info" and .result.process_info.pane_id == $pane) | .result.process_info.shell_pid | select(type == "number" and . > 1) | floor' 2>/dev/null) || pane_pid=
  fi
  if ! rooted=$(fm_control_rooted_processes "$backend" "$meta" "$worktree" "$pane_pid"); then
    printf 'unproven\tprocess absence in the recorded worktree could not be proven'
  elif [ -n "$rooted" ]; then
    printf 'unproven\tlive processes still have cwd in the recorded worktree (pids %s)' "$(printf '%s' "$rooted" | tr '\n' ' ')"
  else
    printf 'clear\t'
  fi
}

# A .claude/settings.local.json that never invokes fm-busy-event.sh was not
# written by firstmate, so it is the operator's and firstmate never removes or
# replaces it.
fm_control_claude_settings_operator_owned() {  # <worktree>
  [ -e "$1/.claude/settings.local.json" ] &&
    ! grep -qF 'fm-busy-event.sh' "$1/.claude/settings.local.json" 2>/dev/null
}

fm_control_wiring_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_control_wiring_json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Optional sixth argument: the Claude statusLine command spawn chose to add.
fm_control_render_claude_settings() {
  local FM_ROOT=$1 STATE_REAL=$2 ID=$3 BUSY_GEN=$4 TURNEND_NOTIFY=$5 STATUSLINE_CMD=${6:-} TURNEND
  local busy_cmd_prefix busy_suffix turnend_touch j_submit j_pretool j_stop j_stopfail j_sessionend j_statusline
  [ -n "$BUSY_GEN" ] || return 1
  TURNEND="$STATE_REAL/$ID.turn-ended"
  busy_cmd_prefix="$(fm_control_wiring_shell_quote "$FM_ROOT/bin/fm-busy-event.sh") apply $(fm_control_wiring_shell_quote "$STATE_REAL") $(fm_control_wiring_shell_quote "$ID")"
  busy_suffix="--gen $(fm_control_wiring_shell_quote "$BUSY_GEN") --source claude-hook"
  turnend_touch=
  [ "$TURNEND_NOTIFY" -eq 0 ] || turnend_touch="touch $(fm_control_wiring_shell_quote "$TURNEND"); "
  j_submit=$(fm_control_wiring_json_escape "$busy_cmd_prefix busy $busy_suffix --event user-prompt-submit 2>/dev/null || true")
  j_pretool=$(fm_control_wiring_json_escape "$busy_cmd_prefix busy $busy_suffix --event pre-tool-use >/dev/null 2>&1 || true")
  j_stop=$(fm_control_wiring_json_escape "$turnend_touch$busy_cmd_prefix idle $busy_suffix --event stop 2>/dev/null || true")
  j_stopfail=$(fm_control_wiring_json_escape "$busy_cmd_prefix idle $busy_suffix --event stop-failure 2>/dev/null || true")
  j_sessionend=$(fm_control_wiring_json_escape "$busy_cmd_prefix idle $busy_suffix --event session-end 2>/dev/null || true")
  j_statusline=
  [ -z "$STATUSLINE_CMD" ] || j_statusline=",\"statusLine\":{\"type\":\"command\",\"command\":\"$(fm_control_wiring_json_escape "$STATUSLINE_CMD")\"}"
  cat <<EOF
{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"$j_submit"}]}],"PreToolUse":[{"matcher":".*","hooks":[{"type":"command","command":"$j_pretool"}]}],"Stop":[{"hooks":[{"type":"command","command":"$j_stop"}]}],"StopFailure":[{"hooks":[{"type":"command","command":"$j_stopfail"}]}],"SessionEnd":[{"hooks":[{"type":"command","command":"$j_sessionend"}]}]}$j_statusline}
EOF
}

fm_control_render_opencode_plugin() {
  local FM_ROOT=$1 STATE_REAL=$2 ID=$3 BUSY_GEN=$4 JS_TURNEND_NOTIFY=$5 TURNEND
  [ -n "$BUSY_GEN" ] || return 1
  TURNEND="$STATE_REAL/$ID.turn-ended"
  cat <<EOF
// Firstmate semantic busy-state events + turn-end notification; written by
// fm-spawn under the contract owned by bin/fm-busy-lib.sh.
// Semantic state comes from OpenCode's session.status events: busy and retry
// are active, idle is inactive. Scoping latches the first session that
// reports activity (the worker's main session - a subagent child session can
// only start while the main session is already busy) and ignores other
// sessions' status until the latched session settles, so a child's idle can
// never clear the worker's busy state. The session.idle touch stays the
// watcher's wake NOTIFICATION, never current-state truth, and a secondmate
// launch writes none (notifyTurnEnd false).
import { execFile } from "node:child_process";
const notifyTurnEnd = $JS_TURNEND_NOTIFY;
const busyEvent = (state, event) =>
  new Promise((resolve) => {
    execFile("$FM_ROOT/bin/fm-busy-event.sh", [
      "apply", "$STATE_REAL", "$ID", state,
      "--gen", "$BUSY_GEN", "--source", "opencode-plugin", "--event", event,
    ], () => resolve());
  });
export const FmBusyState = async () => {
  let activeSession = null;
  return {
    event: async ({ event }) => {
      if (event.type === "session.status") {
        const sessionID = event.properties.sessionID;
        const statusType = event.properties.status && event.properties.status.type;
        if (statusType === "busy" || statusType === "retry") {
          if (activeSession === null) activeSession = sessionID;
          if (sessionID === activeSession) await busyEvent("busy", "session-" + statusType);
          return;
        }
        if (statusType === "idle" && sessionID === activeSession) {
          activeSession = null;
          await busyEvent("idle", "session-status-idle");
        }
        return;
      }
      if (event.type === "session.idle") {
        if (event.properties.sessionID === activeSession) {
          activeSession = null;
          await busyEvent("idle", "session-idle");
        }
        if (notifyTurnEnd) {
          await new Promise((resolve) => {
            execFile("touch", ["$TURNEND"], () => resolve());
          });
        }
      }
    },
  };
};
EOF
}

# The per-task wiring artifacts a harness leaves behind, so a relaunch that
# changes harness (or re-arms the same one with a fresh busy generation) can
# clear the previous incarnation's wiring instead of leaving a stale hook
# pointing at a retired generation. Prints zero or more absolute paths, one per
# line: worktree-resident hook files and firstmate-owned state tokens only,
# never a harness's own managed config.
fm_control_harness_wiring_paths() {  # <harness> <worktree> <state-dir> <id>
  local harness=${1-} wt=${2-} state=${3-} id=${4-}
  [ -n "$wt" ] && [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    claude) printf '%s\n' "$wt/.claude/settings.local.json" ;;
    opencode) printf '%s\n' "$wt/.opencode/plugins/fm-busy-state.js" ;;
    pi|pi-signed) printf '%s\n' "$state/$id.pi-ext.ts" ;;
    omp) printf '%s\n' "$state/$id.omp-ext.ts" ;;
    grok)
      printf '%s\n' "$wt/.fm-grok-turnend"
      printf '%s\n' "$state/$id.grok-turnend-token"
      ;;
    kimi)
      printf '%s\n' "$wt/.fm-kimi-turnend"
      printf '%s\n' "$state/$id.kimi-turnend-token"
      ;;
    muse)
      # muse installs no hook: its busy source is its own session event log,
      # bound to the pane by these two firstmate-owned sidecars. A relaunch
      # ONTO muse rewrites them, but a relaunch AWAY from muse must retire them
      # so no retired incarnation's session binding outlives the agent.
      printf '%s\n' "$state/$id.muse-session"
      printf '%s\n' "$state/$id.muse-session-current"
      ;;
    cursor) printf '%s\n' "$state/$id.cursor-session" ;;
    # gemini's busy-state and turn-end hooks live in a firstmate-owned
    # settings file the launch reaches through GEMINI_CLI_SYSTEM_SETTINGS_PATH,
    # so retiring that one file retires the whole incarnation's wiring. Nothing
    # is written into the worktree, whose own .gemini/settings.json belongs to
    # the project, and nothing global is installed.
    gemini) printf '%s\n' "$state/$id.gemini-settings.json" ;;
    devin) printf '%s\n' "$state/$id.devin-config.json" ;;
  esac
}

# The firstmate-owned global turn-end registry entry a harness mints per task.
# grok and kimi are the two adapters whose turn-end hook is global and gated by
# a private token file; every other adapter's wiring is fully covered by
# fm_control_harness_wiring_paths. Prints the registry path or nothing.
fm_control_harness_turnend_token_path() {  # <harness> <state-dir> <id>
  local harness=${1-} state=${2-} id=${3-}
  [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    grok) printf '%s\n' "$state/$id.grok-turnend-token" ;;
    kimi) printf '%s\n' "$state/$id.kimi-turnend-token" ;;
  esac
}

fm_control_harness_turnend_auth_path() {  # <harness> <token>
  local harness=${1-} token=${2-}
  case "$token" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  case "$harness" in
    grok) printf '%s\n' "${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d/$token" ;;
    kimi) printf '%s\n' "$HOME/.kimi-code/fm-turn-end.d/$token" ;;
    *) return 0 ;;
  esac
}
