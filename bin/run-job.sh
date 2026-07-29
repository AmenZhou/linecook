#!/usr/bin/env bash
# Dispatch orchestrate launchd jobs to cursor-agent or claude based on .orchestrate/agent.conf
# Intentionally NO --force / --yolo: tend runs every 5 min unattended; inbox is an exec channel.
set -euo pipefail

JOB="${1:?usage: run-job.sh <tend|inbox-log-analyzer>}"

ROOT="$(pwd)"
CONF="${ORCHESTRATE_AGENT_CONF:-$ROOT/.orchestrate/agent.conf}"
HEARTBEAT_LOG="$ROOT/.orchestrate/logs/heartbeat.log"

# Fail fast on syntax errors so launchd does not silently break tend (exit 2).
if ! bash -n "${BASH_SOURCE[0]}" 2>/dev/null; then
  mkdir -p "$(dirname "$HEARTBEAT_LOG")" 2>/dev/null || true
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] run-job — script syntax error; reinstall from ai-toolbox" >>"$HEARTBEAT_LOG" 2>/dev/null || true
  echo "run-job.sh: syntax check failed" >&2
  exit 2
fi

RUNNER=cursor
TEND_MODE="${TEND_MODE:-go auto}"
CURSOR_FALLBACK="${CURSOR_FALLBACK:-auto}"
CURSOR_AUTO_OPEN="${CURSOR_AUTO_OPEN:-false}"
CURSOR_BIN="${CURSOR_AGENT_BIN:-$HOME/.local/bin/cursor-agent}"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"

# launchd invokes this script with a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin)
# because it never sources ~/.zshrc — that file's PATH exports (incl.
# $HOME/.local/bin, where node/npm/npx/tsc are symlinked in from the hermes
# node install) only run for INTERACTIVE zsh shells, so even `zsh -lc` skips
# them. Without this, every dispatched agent session's Bash tool inherits the
# launchd-minimal PATH and node/npm/npx/tsc are unreachable, silently
# degrading Test & Verify phases to `confidence: low` (see task 20260719-inbox-B6B3,
# root-caused from 20260718-210655 phase2 log). Export the same dirs an
# interactive login shell would have so unattended tend/inbox sessions can run
# `npm test`/`tsc`/`jest`. Prepended (not replacing) so an operator's own PATH,
# or an override sourced from agent.conf below, still wins.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"

cursor_ide_running() {
  if [[ -n "${CURSOR_IDE_RUNNING:-}" ]]; then
    [[ "$CURSOR_IDE_RUNNING" == "1" || "$CURSOR_IDE_RUNNING" == "true" ]]
    return
  fi
  pgrep -xq "Cursor"
}

maybe_open_cursor_ide() {
  [[ "$CURSOR_AUTO_OPEN" == "true" ]] || return 0
  if cursor_ide_running; then
    return 0
  fi
  if command -v open >/dev/null 2>&1; then
    open -a Cursor >/dev/null 2>&1 || true
    sleep 2
  fi
}

if [[ -f "$CONF" ]]; then
  # shellcheck disable=SC1090
  source "$CONF"
fi

# Churn guard: shared re-queue counter + "blocked after 3×" park. Sourced so the
# counter/park logic exists once (also used by requeue-unblocked.sh + rescue.sh).
# CG_ROOT pins the helper to this project root regardless of caller cwd.
CG_ROOT="$ROOT"
if [[ -f "$ROOT/.orchestrate/bin/churn-guard.sh" ]]; then
  # shellcheck disable=SC1090
  source "$ROOT/.orchestrate/bin/churn-guard.sh"
fi

log_heartbeat() {
  # Trailing [pid=$$] attributes every line to this wrapper's own process
  # (20260725-inbox-6B7E): a low-noise suffix so a future duplicate-execution
  # incident can confirm/rule out "two separate run-job.sh wrapper processes
  # were both alive" from heartbeat.log alone. $$ is this script's own PID —
  # stable for the whole wrapper lifetime (matches the .tend.lock owner pid).
  # Purely additive: existing substring greps (`grep -q '<text>'`, no `$`
  # anchor) against heartbeat lines are unaffected by trailing content.
  local line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1 [pid=$$]"
  mkdir -p "$(dirname "$HEARTBEAT_LOG")"
  echo "$line" >>"$HEARTBEAT_LOG"
  echo "$line" >&2
}

# Launchd wrapper holds .tend.lock; tell the agent to skip SKILL.md T-0 so it does
# not self-abort on the wrapper's own lock (root cause of the 2026-06 tend stall).
LOCK_DIRECTIVE="Launchd-managed run: TEND_LOCK_MANAGED=1 is set and .orchestrate/.tend.lock is already held by your run-job.sh wrapper (released on exit). Per SKILL.md T-0, SKIP the lock block entirely — do NOT check lock age and do NOT exit with 'tend already running'. Proceed directly to T-1."

# Shell-capability probe (20260724-inbox-7A301): run-job.sh cannot introspect the
# dispatched agent session's own tool-permission grants pre-dispatch — that decision
# happens inside the session, not in this script. The observed failure mode is a
# session whose Shell/Bash tool gets rejected mid-session; it still exits 0 with some
# benign text, which classify_agent_result's plain "non-empty log = ok" check then
# misclassifies as `ok` — silently burning a full tend cycle on a session that could
# do nothing. Mitigation: embed a per-cycle random token in the prompt (shell_probe_
# directive) instructing the session to run `echo $SHELL_PROBE_TOKEN` via its own
# Shell/Bash tool as its very first action and, only if that succeeds, include a fixed
# marker line containing the token in its response. shell_probe_failed() then greps the
# session log for that marker; its absence on an otherwise-ok-looking (exit 0,
# non-empty) log means the session ran but never demonstrated it could execute a shell
# command this cycle. SHELL_PROBE_TOKEN is regenerated every tend invocation (see the
# `tend)` case branch below) so a stale token from a previous cycle's log can never
# satisfy this cycle's check, and is left unset for inbox-log-analyzer (which does not
# call tend_prompt()/tend_prompt_claude()), so shell_probe_failed() is a no-op there.
shell_probe_directive() {
  printf 'Shell-capability preflight (run-job.sh): before doing anything else this session, attempt to run this exact command via your own Shell/Bash tool: echo %s\nIf that command actually runs, include this exact line in your response: SHELL_PROBE_CONFIRMED: %s — then proceed with the task normally. If your Shell/Bash tool call is rejected, blocked, unavailable, or errors for any reason, do NOT include that line — just note the failure and stop.' "$SHELL_PROBE_TOKEN" "$SHELL_PROBE_TOKEN"
}

shell_probe_failed() {
  local log_file="$1"
  [[ -n "${SHELL_PROBE_TOKEN:-}" ]] || return 1   # probe not active for this dispatch
  [[ -s "$log_file" ]] || return 1                # empty log -> handled by the existing silent-session-limit path
  grep -qF "SHELL_PROBE_CONFIRMED: ${SHELL_PROBE_TOKEN}" "$log_file" 2>/dev/null && return 1
  return 0
}

tend_prompt() {
  local base
  case "$TEND_MODE" in
    go\ auto|go_auto) base="/task-orchestrate tend go auto" ;;
    notify|tend|"")   base="/task-orchestrate tend" ;;
    *)
      echo "run-job.sh: unknown TEND_MODE='$TEND_MODE' in $CONF (expected 'go auto' or 'notify')" >&2
      exit 1
      ;;
  esac
  printf '%s\n\n%s\n\n%s' "$base" "$LOCK_DIRECTIVE" "$(shell_probe_directive)"
}

tend_prompt_claude() {
  local base
  case "$TEND_MODE" in
    go\ auto|go_auto) base="tend go auto" ;;
    notify|tend|"")   base="tend" ;;
    *)
      echo "run-job.sh: unknown TEND_MODE='$TEND_MODE' in $CONF (expected 'go auto' or 'notify')" >&2
      exit 1
      ;;
  esac
  printf '%s\n\n%s\n\n%s' "$base" "$LOCK_DIRECTIVE" "$(shell_probe_directive)"
}

# cursor-agent requires permissions.deny (array, may be empty) in project cli.json
ensure_cursor_cli() {
  local cli="$ROOT/.cursor/cli.json"
  local sync="$ROOT/scripts/sync-cursor-claude-permissions.sh"
  if [[ ! -f "$cli" && ! -f "$sync" ]]; then
    return 0
  fi
  if python3 -c "import json; d=json.load(open('$cli')); assert isinstance(d.get('permissions',{}).get('deny'), list)" 2>/dev/null; then
    return 0
  fi
  if [[ -f "$sync" ]]; then
    echo "run-job.sh: repairing invalid $cli via sync-cursor-claude-permissions.sh" >&2
    bash "$sync"
    return 0
  fi
  echo "run-job.sh: $cli missing permissions.deny — cursor-agent will fail" >&2
  return 1
}

# Wall-clock cap on a single CLI invocation. A hung claude/cursor session
# (network stall, stuck tool call, MCP connection issue) previously blocked
# run-job.sh — and therefore the tend lock, held by this process's live PID —
# indefinitely; see the 2026-07 ECAF stall investigation (20260711-inbox-0C7B).
AGENT_TIMEOUT_SECS="${AGENT_TIMEOUT_SECS:-1200}"

# Classify agent output: ok | session_limit | connection_lost | timeout | error
classify_agent_result() {
  local code="$1"
  local log_file="$2"
  if [[ "$code" -eq 124 ]]; then
    echo timeout
    return
  fi
  if [[ "$code" -eq 0 ]]; then
    if shell_probe_failed "$log_file"; then
      echo shell_incapable
      return
    fi
    # Exit 0 with no output = silent session-limit pattern in newer agent versions
    [[ -s "$log_file" ]] && { echo ok; return; }
    echo session_limit
    return
  fi
  if grep -qi 'session limit' "$log_file" 2>/dev/null; then
    echo session_limit
    return
  fi
  if grep -qi 'Connection lost' "$log_file" 2>/dev/null; then
    echo connection_lost
    return
  fi
  echo error
}

session_limit_reset_hint() {
  local log_file="$1"
  local hint
  hint="$(grep -oi 'resets [^·]*' "$log_file" 2>/dev/null | head -1 | sed 's/^resets //')"
  if [[ -n "$hint" ]]; then
    printf '%s' "$hint"
  else
    printf 'unknown'
  fi
}

# Invoke one agent binary; routes ALL output to a per-session log so prose never
# pollutes heartbeat.log (which receives only structured [ISO] lines via log_heartbeat).
# Bounded by AGENT_TIMEOUT_SECS via a watcher subshell — macOS ships no
# timeout(1)/gtimeout by default, so a hung CLI process is reaped manually
# rather than blocking this script (and the tend lock) forever. Uses `wait "$pid"`
# (blocks until real exit, immune to zombie-PID false positives) rather than a
# `kill -0` poll loop — `kill -0` returns true for an already-exited-but-unreaped
# zombie PID, which made an earlier version of this wrapper time out EVERY
# invocation regardless of how fast the child actually finished (caught by the
# Phase 3 dry-run in 20260711-inbox-0C7B, scenario 1).
invoke_agent() {
  local bin="$1"
  shift
  local agent_log
  agent_log="$ROOT/.orchestrate/logs/$(date -u +%Y%m%d-%H%M%S)-agent.log"
  mkdir -p "$(dirname "$agent_log")"
  local timeout_marker
  timeout_marker="$(mktemp -u "${TMPDIR:-/tmp}/run-job-timeout.XXXXXX")"
  rm -f "$timeout_marker"

  set +e
  "$bin" "$@" > "$agent_log" 2>&1 &
  local pid=$!

  # Redirect the watcher's fds away from whatever invoke_agent's caller has
  # open (e.g. a `$(...)` command-substitution pipe). Without this, killing
  # the watcher subshell on the happy path does NOT kill its still-sleeping
  # `sleep "$AGENT_TIMEOUT_SECS"` grandchild — SIGTERM only reaches the
  # subshell process, not the child it forked to run sleep — so the orphaned
  # sleep keeps the inherited stdout pipe open for its full duration and a
  # caller capturing invoke_agent's output via `$(...)` blocks until it
  # exits, even though `wait "$pid"` already returned immediately (caught by
  # the Phase 3 dry-run in 20260711-inbox-0C7B, scenario 2 — fast-exiting
  # agent took the full timeout window instead of returning immediately).
  ( sleep "$AGENT_TIMEOUT_SECS"
    if kill -0 "$pid" 2>/dev/null; then
      touch "$timeout_marker"
      kill -TERM "$pid" 2>/dev/null
      sleep 2
      kill -KILL "$pid" 2>/dev/null
    fi
  ) < /dev/null > /dev/null 2>&1 &
  local watcher=$!

  wait "$pid" 2>/dev/null
  local code="$?"

  # Job finished on its own — stop the watcher before it can fire late.
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null

  if [[ -f "$timeout_marker" ]]; then
    code=124
    log_heartbeat "run-job — $bin timed out after ${AGENT_TIMEOUT_SECS}s (agent_log=$agent_log); killed"
  fi
  rm -f "$timeout_marker"
  set -e
  AGENT_RESULT="$(classify_agent_result "$code" "$agent_log")"
  AGENT_RESET_HINT="$(session_limit_reset_hint "$agent_log")"
  # Keep the session log for post-mortem (do not remove)
}

run_with_fallback() {
  local primary="$1"
  local cursor_prompt="$2"
  local claude_prompt="$3"
  local secondary
  secondary="$([[ "$primary" == cursor ]] && echo claude || echo cursor)"

  if [[ "$primary" == cursor ]]; then
    maybe_open_cursor_ide
    if ! ensure_cursor_cli; then
      if [[ "$CURSOR_FALLBACK" == "never" ]]; then
        log_heartbeat "run-job — cursor cli.json invalid; tend deferred (CURSOR_FALLBACK=never)"
        return 0
      fi
      log_heartbeat "run-job — cursor cli.json invalid; falling back to claude"
      primary=claude
      secondary=cursor
    elif ! cursor_ide_running; then
      if [[ "$CURSOR_FALLBACK" == "never" ]]; then
        log_heartbeat "run-job — Cursor IDE required but not running; tend deferred"
        return 0
      fi
      log_heartbeat "run-job — Cursor not running; falling back to claude"
      primary=claude
      secondary=cursor
    fi
  fi

  if [[ "$primary" == cursor ]]; then
    invoke_agent "$CURSOR_BIN" -p --trust "$cursor_prompt"
  else
    invoke_agent "$CLAUDE_BIN" -p "$claude_prompt"
  fi

  case "$AGENT_RESULT" in
    ok) return 0 ;;
    shell_incapable)
      if [[ "$CURSOR_FALLBACK" == "never" ]]; then
        log_heartbeat "run-job — $primary session has no shell capability; deferred (CURSOR_FALLBACK=never)"
        return 0
      fi
      log_heartbeat "run-job — $primary session has no shell capability; fallback to $secondary"
      ;;
    session_limit)
      log_heartbeat "run-job — $primary hit session limit (resets ${AGENT_RESET_HINT}); trying $secondary"
      ;;
    connection_lost)
      log_heartbeat "run-job — $primary connection lost; trying $secondary"
      ;;
    timeout)
      log_heartbeat "run-job — $primary timed out; trying $secondary"
      ;;
    *)
      log_heartbeat "run-job — $primary failed (exit classification: $AGENT_RESULT); see $ROOT/.orchestrate/logs/*-agent.log"
      return 1
      ;;
  esac

  if [[ "$secondary" == cursor ]]; then
    maybe_open_cursor_ide
    if ! ensure_cursor_cli || ! cursor_ide_running; then
      log_heartbeat "run-job — $secondary unavailable; inbox/tend deferred"
      return 0
    fi
    invoke_agent "$CURSOR_BIN" -p --trust "$cursor_prompt"
  else
    invoke_agent "$CLAUDE_BIN" -p "$claude_prompt"
  fi

  case "$AGENT_RESULT" in
    ok) return 0 ;;
    shell_incapable)
      log_heartbeat "run-job — $secondary session has no shell capability; deferred"
      return 0
      ;;
    session_limit)
      log_heartbeat "run-job — both runners session-limited (resets ${AGENT_RESET_HINT}); inbox queued until reset"
      return 0
      ;;
    connection_lost)
      log_heartbeat "run-job — both runners connection-lost; will retry next cycle"
      return 0
      ;;
    timeout)
      log_heartbeat "run-job — $secondary also timed out; will retry next cycle"
      return 0
      ;;
    *)
      log_heartbeat "run-job — $secondary failed (exit classification: $AGENT_RESULT); see $ROOT/.orchestrate/logs/*-agent.log"
      return 1
      ;;
  esac
}

dispatch() {
  local cursor_prompt="$1"
  local claude_prompt="$2"
  case "$RUNNER" in
    cursor) run_with_fallback cursor "$cursor_prompt" "$claude_prompt" ;;
    claude) run_with_fallback claude "$cursor_prompt" "$claude_prompt" ;;
    *)
      echo "run-job.sh: unknown RUNNER='$RUNNER' in $CONF (expected cursor or claude)" >&2
      exit 1
      ;;
  esac
}

# CROSS-2 (20260727-inbox-7D4A): a materialized task file's `depends_on:` may
# resolve to ANOTHER TASK's real registry ID — drain-inbox.sh's
# resolve_depends_on() (CROSS-1) writes this when a ticket's `blocked_by_ticket:`
# header or `**Blocked by:**` prose names a real sibling — rather than a
# same-file phase number. mark_pending_tasks_as_running() is the actual
# pre-dispatch gate (RS01): it runs in bash, before any agent session (and
# before SKILL.md's own T-4 batch-collection logic) ever sees the registry, so
# it is the one place that can reliably stop a dependent task from being
# flipped pending→running (and thus dispatched) while its prerequisite is
# still outstanding. This is the exact gap behind the 20260727-inbox-1F27
# incident: VERIFY was dispatched in the same cycle as its gated, unapproved
# IMPL prerequisite because nothing here (or in T-4) ever read depends_on as a
# cross-task reference.
#
# A depends_on: value is treated as a cross-task ref only if it matches the
# registry ID SHAPE gen_task_id() produces (YYYYMMDD-inbox-XXXX, 4 hex chars).
# A bare integer ("1", "2") or "none" is a same-file phase number (or no
# dependency) and is left alone — this function only ever adds a NEW skip
# condition, it never touches same-file phase-level scheduling.
#
# Returns 0 (blocked) and prints "<dep_id>\t<dep_status>" to stdout when the
# referenced task is not yet `complete`; returns 1 (not blocked — safe to
# dispatch) otherwise, including when there is no task file yet, no
# depends_on: line, or the dependency has already completed.
cross_task_depends_on_blocked() {
  local id="$1" proj="$2" tasks_dir="$3"
  local tf="$tasks_dir/${id}.md"
  [[ -f "$tf" ]] || return 1
  local dep
  dep="$(grep -m1 -E '^depends_on:[[:space:]]*\S' "$tf" 2>/dev/null \
    | sed -E 's/^depends_on:[[:space:]]*//')"
  [[ -z "$dep" || "$dep" == "none" ]] && return 1
  [[ "$dep" =~ ^[0-9]{8}-inbox-[0-9A-Fa-f]{4}$ ]] || return 1
  local dep_status
  dep_status="$(awk -F'|' -v dep="$dep" '
    $0 ~ ("\\| " dep " \\|") {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6); print $6; exit
    }
  ' "$proj" 2>/dev/null)"
  [[ "$dep_status" == "complete" ]] && return 1
  printf '%s\t%s\n' "$dep" "${dep_status:-unknown}"
  return 0
}

# RS01: Mark all `pending` registry rows as `running` before agent dispatch so the
# dashboard reflects the correct state immediately (the agent marks them running
# too, but this is faster and prevents the stale-pending flash).
mark_pending_tasks_as_running() {
  local proj="$ROOT/.orchestrate/project.md"
  [[ -f "$proj" ]] || return 0
  local tasks_dir="$ROOT/.orchestrate/tasks"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # CROSS-2: collect pending IDs whose depends_on: resolves to an incomplete
  # cross-task ref — these must be excluded from this pass (left `pending`,
  # not flipped to `running`/dispatched). Comma-bracketed membership string
  # (",ID1,ID2,") avoids partial-ID substring collisions in the awk pass below.
  local blocked_ids=","
  local pending_ids
  pending_ids="$(awk -F'|' '
    /^\|[[:space:]]*[0-9]/ && NF==8 {
      st=$6; gsub(/^[[:space:]]+|[[:space:]]+$/,"",st)
      if (st=="pending") { id=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",id); print id }
    }
  ' "$proj" 2>/dev/null)"
  local pid block_info dep dep_status
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    block_info="$(cross_task_depends_on_blocked "$pid" "$proj" "$tasks_dir" || true)"
    [[ -z "$block_info" ]] && continue
    blocked_ids="${blocked_ids}${pid},"
    dep="${block_info%%$'\t'*}"
    dep_status="${block_info#*$'\t'}"
    if [[ "$dep_status" == "awaiting_go" ]]; then
      log_heartbeat "tend-auto — skip dispatch ${pid}: depends_on ${dep} is gated/awaiting_go (needs human go on ${dep} before ${pid} can run)"
    else
      log_heartbeat "tend-auto — skip dispatch ${pid}: depends_on ${dep} not complete (status: ${dep_status})"
    fi
  done <<< "$pending_ids"

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-md.XXXXXX")"
  # Registry row schema: | ID | summary | mode | phase | status | last_activity |
  # → awk -F'|' fields: $2=ID  $6=status  $7=last_activity  $8=<empty trailing>.
  # Only well-formed rows (NF==8) are touched: flip status $6 pending→running and
  # stamp last_activity in $7. (Historic bug: wrote $8, appending a phantom field
  # PAST the trailing pipe — the malformed '| running | ts | ts' corruption that
  # then defeated reset_stale_running_tasks. See repair_registry_rows.) A row
  # whose ID is in blocked_ids (CROSS-2) is left pending regardless.
  awk -F'|' -v OFS='|' -v now="$now" -v blocked="$blocked_ids" '
    /^\|[[:space:]]*[0-9]/ && NF==8 {
      id=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",id)
      st=$6; gsub(/^[[:space:]]+|[[:space:]]+$/,"",st)
      if (st=="pending" && index(blocked, "," id ",") == 0) { $6=" running "; $7=" " now " " }
    }
    { print }
  ' "$proj" > "$tmp" && mv "$tmp" "$proj"
}

# Repair malformed registry rows: a concurrent writer (pre-lock-fix) could append
# a phantom timestamp field PAST the trailing pipe, yielding rows like
# '| ... | running | <last_activity> | <phantom_ts>' with no trailing pipe. Such
# rows defeat reset_stale_running_tasks (its sed expects '| running | ts |') and
# deadlock the registry. This normalizer keeps the 6 real columns ($2..$7) and
# restores the trailing pipe, dropping any phantom field. No-op on valid rows
# (NF==8 with an empty $8). Atomic temp+mv write.
repair_registry_rows() {
  local proj="$ROOT/.orchestrate/project.md"
  [[ -f "$proj" ]] || return 0
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-md.XXXXXX")"
  # STRUCTURAL self-heal: collapse phantom columns / restore the trailing pipe so
  # every data row is NF==8 with an empty $8.
  awk -F'|' '
    /^\|[[:space:]]*[0-9]/ && NF>=8 {
      trailing=$8; gsub(/[[:space:]]/,"",trailing)
      if (NF>8 || trailing!="") {
        line=$1
        for (i=2; i<=7; i++) line=line "|" $i
        print line "|"; next
      }
    }
    { print }
  ' "$proj" > "$tmp" && mv "$tmp" "$proj"

  # DOMAIN guard (field-shift detection): NF==8 is necessary but NOT sufficient.
  # A field-shift corruption (e.g. an off-by-one awk update that overwrites the
  # mode column with a phase number) is structurally clean — NF==8, empty $8 — so
  # the rewrite above can't repair it (the value is genuinely wrong). Detect rows
  # whose mode ($4) ∉ {auto,gated} or status ($6) ∉ the known status set and warn
  # a human via the heartbeat (matches rescue.sh BAD_ROWS / monitor
  # checkRegistryInvariant). Detection only — never rewrites a domain-bad value.
  local bad_domain
  bad_domain="$(awk -F'|' '
    /^\|[[:space:]]*[0-9]/ && NF==8 {
      t=$8; gsub(/[[:space:]]/,"",t); if (t!="") next   # structural breach: counted/handled above
      m=$4; gsub(/^[[:space:]]+|[[:space:]]+$/,"",m)
      s=$6; gsub(/^[[:space:]]+|[[:space:]]+$/,"",s)
      mode_ok = (m=="auto" || m=="gated")
      status_ok = (s=="pending" || s=="running" || s=="awaiting_go" || s=="awaiting_critic" || s=="complete" || s=="failed" || s=="needs_human")
      if (!mode_ok || !status_ok) c++
    }
    END{print c+0}' "$proj" 2>/dev/null | head -1 | tr -dc '0-9')"
  if [[ "${bad_domain:-0}" -gt 0 ]]; then
    log_heartbeat "run-job — WARNING ${bad_domain} registry row(s) have mode/status out of domain (field-shift corruption; NF==8 but bad enum value — manual fix needed)"
  fi
}

# D328 Bug 1: Detect ghost `running` tasks — tasks stuck in running with
# last_activity older than STALE_RUNNING_SECS and no ✓ complete phase in their
# task file — and reset them to needs_human with an auto-reset hint.
STALE_RUNNING_SECS=600  # 10 minutes
# A510: no-task-file grace. A `running` row that has NOT yet written its task
# file gets a LONGER grace than STALE_RUNNING_SECS before it can be ghost-reset,
# because a slow-to-start job (dispatched, agent alive, but still spinning up
# before it creates .orchestrate/tasks/<ID>.md) has no fresh-mtime signal for the
# 19D7 guard to protect it — so it would fall straight through to reset + churn
# bump and, at 3×, park with a false investigate-churn ticket. See guard below.
NO_FILE_GRACE_SECS=1800  # 30 minutes
reset_stale_running_tasks() {
  local proj="$ROOT/.orchestrate/project.md"
  [[ -f "$proj" ]] || return 0
  local now_epoch
  now_epoch="$(date +%s)"

  while IFS='|' read -r _ task_id _ _ _ status last_activity _; do
    task_id="${task_id// /}"
    status="${status// /}"
    last_activity="${last_activity// /}"
    [[ "$status" == "running" ]] || continue
    [[ -z "$task_id" || "$task_id" == "ID" || "$task_id" =~ ^-+$ ]] && continue

    # Parse last_activity ISO timestamp to epoch
    local la_epoch=0
    if [[ -n "$last_activity" ]]; then
      la_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$last_activity" +%s 2>/dev/null || echo 0)"
    fi
    local age=$(( now_epoch - la_epoch ))
    [[ $age -lt $STALE_RUNNING_SECS ]] && continue

    local task_file="$ROOT/.orchestrate/tasks/${task_id}.md"

    # 527A: count phase progress instead of a bare ✓-complete grep. The old check
    # ("any ✓ complete phase anywhere in the file ⇒ permanently not a ghost") meant
    # a task whose dispatching session died right after completing phase N-1 of N
    # could never be ghost-reset — the grep matched forever regardless of how stale
    # the file got. Now a FULLY complete file (complete_count >= total_phases) is
    # still an unconditional skip (finalize-completed-tasks.sh's job to flip it to
    # complete — this is only a defensive guard in case that hasn't run yet). A
    # PARTIALLY complete file (some but not all phases done) is no longer
    # auto-protected — it falls through to the same 19D7 mtime-freshness guard below
    # that already governs zero-progress files, so a partial file whose last write
    # is within STALE_RUNNING_SECS is still treated as alive, but one stalled far
    # past that threshold is ghost-reset like any other dead row.
    local complete_count=0 total_phases=0
    if [[ -f "$task_file" ]]; then
      # NOTE: `grep -c PATTERN FILE` prints "0" to stdout AND exits 1 when the file
      # exists but has zero matches — a naive `|| echo 0` fallback then appends a
      # SECOND "0", corrupting the variable into a two-line "0\n0" that breaks the
      # numeric `-ge` test below. Suppress the fallback's own output and default
      # via parameter expansion instead.
      complete_count="$(grep -c '✓ complete' "$task_file" 2>/dev/null || true)"
      complete_count="${complete_count:-0}"
      total_phases="$(grep -oE '^total_phases:[[:space:]]*[0-9]+' "$task_file" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)"
      total_phases="${total_phases:-0}"
      if [[ "$total_phases" -gt 0 && "$complete_count" -ge "$total_phases" ]]; then
        continue  # fully complete — finalize-completed-tasks.sh's job, not this one
      fi
    fi

    # A510 no-file grace guard: a `running` row with NO task file yet is a job that
    # was dispatched but has not created .orchestrate/tasks/<ID>.md — either a
    # genuinely-dead ghost OR a slow-but-alive session still spinning up (the agent
    # can hold `running` for many minutes before its first task-file write). Unlike
    # the 19D7 case there is no fresh mtime to prove liveness, so ONLY the elapsed
    # age can distinguish them. Require the longer NO_FILE_GRACE_SECS before resetting:
    # under grace → treat as slow-but-alive, skip the reset AND the cg_increment churn
    # bump (this is the root trigger of the AEE0/3666 churn cascade); past grace →
    # fall through and reset as a genuinely-dead ghost (no regression). Rows WITH a
    # task file are unaffected and keep the STALE_RUNNING_SECS + 19D7 mtime semantics.
    if [[ ! -f "$task_file" && $age -lt $NO_FILE_GRACE_SECS ]]; then
      continue  # no task file yet, still within grace — slow-but-alive, not a ghost
    fi

    # 19D7 liveness guard: a task file modified within the stale threshold means an
    # agent is actively writing phase blocks (raw_output/human_resolution/etc.) — a
    # live session, not a dead one. last_activity only updates at phase checkpoints,
    # so a long single-phase agent can look stale by last_activity while its task
    # file is fresh; resetting it here bumps the churn counter and (mid-flight)
    # parks a task that is about to complete, cascading false-positive
    # investigate-churn tickets. Skip the reset when the file is fresh = alive.
    if [[ -f "$task_file" ]]; then
      local tf_mtime tf_age
      tf_mtime="$(date -r "$task_file" +%s 2>/dev/null || echo 0)"
      tf_age=$(( now_epoch - tf_mtime ))
      if [[ "$tf_mtime" -gt 0 && "$tf_age" -lt "$STALE_RUNNING_SECS" ]]; then
        continue  # fresh task file — agent is alive
      fi
    fi

    # Reset to needs_human and inject resolution hint into task file.
    # Atomic temp+mv write (was `sed -i ''` in place — non-atomic, unsafe under a
    # concurrent reader). Match the row by ID ($2) and flip status $6 running→
    # needs_human, stamping last_activity $7.
    #
    # 14C8 (split-brain fix): the detection loop above matches ANY grep-matched stale
    # `running` row (NF-tolerant positional read), but this mutation historically
    # guarded on NF==8. So a phantom-extra-column row (NF>8 — the
    # `| … | running | <last_activity> | <phantom_ts> |` corruption) was DETECTED but
    # never flipped, while the heartbeat below still logged a ghost-reset. That
    # split-brain left the row stuck `running` (T-4 re-queues only `needs_human` rows)
    # and made the heartbeat lie. Fix: accept NF>=8 and self-heal phantom columns in
    # the same pass (collapse to the 6 real columns + restored trailing pipe), and log
    # the ghost-reset heartbeat ONLY when the flip actually happened (awk signals via
    # exit code; a detected-but-unflipped row logs a distinct SKIPPED line instead).
    local hint
    if [[ "$complete_count" -gt 0 ]]; then
      hint="Auto-reset: task stuck in running for ${age}s, stalled after phase ${complete_count}/${total_phases:-?} (tend session likely died)"
    else
      hint="Auto-reset: task stuck in running for ${age}s with no phase progress (tend session likely died)"
    fi
    local now_iso
    now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local rs_tmp rs_rc=0
    rs_tmp="$(mktemp "${TMPDIR:-/tmp}/project-md.XXXXXX")"
    awk -F'|' -v OFS='|' -v id="$task_id" -v ts="$now_iso" '
      /^\|[[:space:]]*[0-9]/ && NF>=8 {
        rid=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",rid)
        st=$6;  gsub(/^[[:space:]]+|[[:space:]]+$/,"",st)
        if (rid==id && st=="running") {
          $6=" needs_human "; $7=" " ts " "
          if (NF>8) { NF=8; $8="" }   # drop phantom column(s), restore trailing pipe
          flipped=1
        }
      }
      { print }
      END { exit (flipped ? 0 : 2) }
    ' "$proj" > "$rs_tmp" || rs_rc=$?
    if [[ $rs_rc -eq 0 ]]; then
      mv "$rs_tmp" "$proj"
      if [[ -f "$task_file" ]]; then
        # Prepend human_resolution hint to the first incomplete phase block
        sed -i '' "/^### Phase/a\\
human_resolution: ${hint}" "$task_file" 2>/dev/null || true
      fi
      # Churn guard: this ghost-reset is a re-processing of ${task_id}. Bump the
      # shared counter; if it has now churned ${CG_THRESHOLD:-3}× without
      # converging, park it (needs_human + bypass markers) and file an async
      # investigation job instead of letting it loop forever. cg_park_if_churned
      # returns 0 only when it actually parked.
      if type cg_increment >/dev/null 2>&1; then
        # ED94: skip the churn bump when THIS reset was a transient infra death
        # (agent log shows only a connection error, zero progress) — such a run
        # hit no poison and made no progress, so it must not count toward the
        # poison-park threshold. Falls back to a bare bump if the wrapper is
        # absent (mirror lag).
        if type cg_increment_unless_transient >/dev/null 2>&1; then
          cg_increment_unless_transient "$task_id" "$la_epoch" >/dev/null 2>&1 || true
        else
          cg_increment "$task_id" >/dev/null 2>&1 || true
        fi
        if cg_park_if_churned "$task_id" 2>/dev/null; then
          log_heartbeat "run-job — churn-guard parked ${task_id} after ${CG_THRESHOLD:-3} re-processings (ghost-reset path)"
          continue
        fi
      fi
      if [[ "$complete_count" -gt 0 ]]; then
        log_heartbeat "run-job — ghost-reset ${task_id}: running→needs_human (stale after phase ${complete_count}/${total_phases:-?})"
      else
        log_heartbeat "run-job — ghost-reset ${task_id}: running→needs_human (${age}s stale, no ✓ phase)"
      fi
    else
      rm -f "$rs_tmp"
      log_heartbeat "run-job — ghost-reset SKIPPED ${task_id}: stale running row did not flip (malformed/raced); awaiting repair_registry_rows"
    fi
  done < <(grep -E '^\|[[:space:]]*[0-9]' "$proj" 2>/dev/null || true)
}

# E721: auto-finalize watchdog. Completion is NOT atomic — a tend/agent session
# can write every phase block to ✓ complete (and possibly archive the task file)
# but die before flipping the registry row running→complete. T-4 re-queues only
# `needs_human`, so such a row sits `running` forever. This bash analog of the
# SKILL Completion sequence reaps those done-but-running rows: flips the row to
# complete, archives to orchestrate-history/ + MANIFEST (no dup if already
# archived), deletes the stale task file. Idempotent. Runs in the tend preflight
# AFTER repair_registry_rows (so malformed rows are normalized first) and BEFORE
# reset_stale_running_tasks (so a finished-but-running ghost is completed, not
# bounced to needs_human). Guard on -x, log on failure (continue tend).
finalize_completed_tasks() {
  local script="$ROOT/.orchestrate/bin/finalize-completed-tasks.sh"
  if [[ -x "$script" ]]; then
    bash "$script" "$ROOT" || log_heartbeat "run-job — finalize-completed-tasks.sh failed (continuing tend)"
  fi
}

cleanup_stale_inbox() {
  local script="$ROOT/.orchestrate/bin/cleanup-stale-inbox.sh"
  if [[ -x "$script" ]]; then
    bash "$script" "$ROOT" || log_heartbeat "run-job — cleanup-stale-inbox.sh failed (continuing tend)"
  fi
}

# 3C1D: deterministic bash mirror of the SKILL T-4 "orphaned running row" check
# (see requeue-orphaned-running.sh header for the full root-cause writeup). Runs
# BEFORE reset_stale_running_tasks so a `running` row with no task file and no
# dispatch heartbeat line is requeued to `pending` at the 300s threshold instead
# of falling through to the 1800s no-file-grace path (which only reaches
# `needs_human`, requiring yet another agent cycle to re-queue).
requeue_orphaned_running() {
  local script="$ROOT/.orchestrate/bin/requeue-orphaned-running.sh"
  if [[ -f "$script" ]]; then
    bash "$script" "$ROOT" || log_heartbeat "run-job — requeue-orphaned-running.sh failed (continuing tend)"
  fi
}

# 4FA5: awaiting_go analog of the above — a dashboard "approved go auto" click
# on a gated row can leave it `awaiting_go` forever if the task file never gets
# materialized (see detect-orphaned-awaiting-go.sh header). Never auto-requeues
# (would bypass an explicit human gate); it only surfaces the row via heartbeat
# + a one-time desktop notification so a human notices.
detect_orphaned_awaiting_go() {
  local script="$ROOT/.orchestrate/bin/detect-orphaned-awaiting-go.sh"
  if [[ -f "$script" ]]; then
    bash "$script" "$ROOT" || log_heartbeat "run-job — detect-orphaned-awaiting-go.sh failed (continuing tend)"
  fi
}

drain_inbox() {
  local script="$ROOT/.orchestrate/bin/drain-inbox.sh"
  if [[ -x "$script" ]]; then
    bash "$script" "$ROOT" || log_heartbeat "run-job — drain-inbox.sh failed (continuing tend)"
  fi
}

tend_need_action() {
  local script="$ROOT/.orchestrate/bin/tend-need-action.sh"
  local need=1
  if [[ -x "$script" ]]; then
    # Capture raw output first (ignoring exit code with || true) before filtering.
    # The inline pipeline '| grep | cut || echo 1' misfires under set -o pipefail:
    # when the script exits 1 (action needed), pipefail marks the pipe failed so
    # '|| echo 1' fires AND cut's output is already captured, yielding need="1\n1"
    # which fails the '== "1"' check — causing false idle reports.
    local raw
    raw="$(bash "$script" "$ROOT" 2>/dev/null)" || true
    need="$(printf '%s\n' "$raw" | grep '^NEED_ACTION=' | cut -d= -f2)" || true
    [[ -z "$need" ]] && need=1
  fi
  [[ "$need" == "1" ]]
}

log_tend_idle() {
  case "$TEND_MODE" in
    go\ auto|go_auto) log_heartbeat "tend go auto — idle" ;;
    *)                log_heartbeat "tend — idle" ;;
  esac
}

# Count only `pending` rows — used as the loop guard in go-auto mode.
# awaiting_go/needs_human/running are not executable by tend go auto.
pending_task_count() {
  local proj="$ROOT/.orchestrate/project.md"
  [[ -f "$proj" ]] || { echo 0; return; }
  awk -F'|' '
    /^\|/ && $2 !~ /^[[:space:]]*ID[[:space:]]*$/ && $2 !~ /^-+$/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6)
      if ($6 == "pending") n++
    }
    END { print n + 0 }
  ' "$proj"
}

# Acquire the tend lock at the shell level so it is always released on exit,
# regardless of whether the agent session can execute shell commands.
# Sets TEND_LOCK_MANAGED=1 so the SKILL's T-0 skips its own lock logic.
#
# Concurrency model (fixes the 2026-06 concurrent-tend race that corrupted
# project.md): acquisition is atomic via a noclobber exclusive create, and the
# lock records the owning PID. A second launchd cycle that fires while a long
# go-auto drain (up to MAX_TEND_LOOPS agent sessions, easily >300s) is still
# running finds the lock held by a LIVE pid and skips — it never steals a lock
# whose owner is alive, no matter how old the lock is. The old age-only rule
# (steal at >360s) let the 300s launchd cycle barge into a long live cycle, so
# two writers raced on the registry. A lock is now reclaimed only when its owner
# PID is dead (crashed session) AND the lock has aged past LOCK_STALE_GRACE.
# refresh_tend_lock() touches the lock between dispatch sessions so a healthy
# long cycle also stays fresh for rescue.sh / SKILL T-0 mtime checks.
#
# flock vs noclobber (C319 decision): we deliberately keep the `set -o noclobber`
# exclusive-create lock rather than switching to flock(1). Rationale:
#   - macOS ships no `flock` binary (it is util-linux); this lock must run on the
#     dev Macs and under launchd without extra deps, so flock would need a polyfill.
#   - flock's advisory lock is held by an open fd and released when the process
#     exits — it cannot survive across the multiple short-lived agent SESSIONS a
#     single go-auto drain spawns, which is exactly the window we must protect.
#   - The noclobber create is itself atomic, and we add PID-liveness + grace-based
#     reclaim (above), giving the same mutual exclusion plus crash recovery that a
#     bare flock would not. Registry writes are additionally made atomic (temp+mv)
#     and self-healing (repair_registry_rows / rescue normalizer), so a lost lock
#     degrades to a repairable row, never a deadlock. Decision: keep noclobber.
LOCK_STALE_GRACE=120   # seconds a DEAD owner's lock must age before reclaim

acquire_tend_lock() {
  local lock="$ROOT/.orchestrate/.tend.lock"
  TEND_LOCK_FILE="$lock"
  mkdir -p "$(dirname "$lock")"

  while true; do
    # Atomic test-and-set: noclobber makes '>' fail if the file already exists,
    # so only one racer can create it. Content = "<pid> <iso-acquired>".
    if ( set -o noclobber; printf '%s %s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lock" ) 2>/dev/null; then
      # shellcheck disable=SC2064
      trap "rm -f '$lock'" EXIT
      export TEND_LOCK_MANAGED=1
      return 0
    fi

    # Lock held — decide whether the owner is alive.
    local owner_pid age
    owner_pid="$(awk 'NR==1{print $1}' "$lock" 2>/dev/null)"
    age=$(( $(date +%s) - $(date -r "$lock" +%s 2>/dev/null || echo 0) ))

    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
      # 14C8: a session can wedge WHILE still holding the lock (the owner is
      # alive to `kill -0` but is no longer making progress). The task it was
      # running then sits `running` forever, because the lock-gated ghost reaper
      # in the tend preflight below never runs on any cycle that exits here — the
      # ghost's own lock-holder blocks its reaping. Reap stale `running` ghosts
      # (≥STALE_RUNNING_SECS, no ✓ phase) BEFORE skipping, so a wedged-owner
      # ghost is reset to needs_human + re-queued by T-4 without waiting for
      # rescue.sh to break the lock. reset_stale_running_tasks touches only stale
      # rows (atomic temp+mv) and never touches the lock, so it is safe to run
      # while another (live) session holds it.
      reset_stale_running_tasks
      log_heartbeat "run-job — tend lock held by live pid $owner_pid (${age}s); skipping cycle (reaped stale ghosts first)"
      exit 0
    fi

    # Owner dead/unknown. Only reclaim once the lock has gone stale, to avoid
    # racing a just-started session that has not yet stamped its PID.
    if [[ $age -lt $LOCK_STALE_GRACE ]]; then
      log_heartbeat "run-job — tend lock owner ${owner_pid:-?} not alive but fresh (${age}s); skipping cycle"
      exit 0
    fi

    log_heartbeat "run-job — reclaiming stale lock (owner ${owner_pid:-?} dead, ${age}s old)"
    rm -f "$lock"
    # loop and retry the atomic create
  done
}

# Touch the lock so a long-running healthy cycle is never seen as stale by a
# concurrent launchd cycle, rescue.sh, or SKILL T-0 (all compare mtime age).
refresh_tend_lock() {
  [[ -n "${TEND_LOCK_FILE:-}" && -f "${TEND_LOCK_FILE:-}" ]] && touch "$TEND_LOCK_FILE" 2>/dev/null || true
}

case "$JOB" in
  tend)
    acquire_tend_lock
    # Self-heal any malformed rows left by a pre-lock-fix concurrent writer so the
    # ghost-reset / requeue logic below can act on them (normalizer is a no-op on
    # valid rows). Must run before reset_stale_running_tasks.
    repair_registry_rows
    # E721: reap done-but-running rows (Completion is not atomic) AFTER the row
    # normalizer and BEFORE the stale-running reaper, so a finished-but-running
    # ghost is finalized to `complete` instead of being bounced to needs_human.
    finalize_completed_tasks
    cleanup_stale_inbox
    drain_inbox
    requeue_orphaned_running
    detect_orphaned_awaiting_go

    # D328 Bug 1: Detect and reset ghost running tasks. Runs BEFORE the
    # need-action gate (cheap bash, no tokens) so a stale `running` ghost is
    # reset to `needs_human` — and re-queued if it's an auto job — even on a
    # cycle that would otherwise be idle. `running` no longer gates dispatch.
    reset_stale_running_tasks

    # BC0E: auto-requeue needs_human rows when to_clear / requeue_when_exists signals are met
    requeue_script="$ROOT/.orchestrate/bin/requeue-unblocked.sh"
    if [[ -x "$requeue_script" ]]; then
      bash "$requeue_script" "$ROOT" || log_heartbeat "run-job — requeue-unblocked.sh failed (continuing tend)"
    fi

    if ! tend_need_action; then
      log_tend_idle
      exit 0
    fi

    # go-auto: loop until no pending tasks remain or max iterations reached.
    # Each session handles a parallel batch; if tasks remain after a session
    # (e.g. session limit, new inbox items), fire another session immediately
    # rather than waiting 5 min for the next launchd cycle.
    MAX_TEND_LOOPS=5
    tend_loop=0
    # Per-cycle random token for the shell-capability probe (see shell_probe_directive /
    # shell_probe_failed above). Regenerated every tend invocation so a stale token from
    # a previous cycle's log can never satisfy this cycle's check.
    SHELL_PROBE_TOKEN="orchestrate_shell_probe_$(date +%s)_$$_${RANDOM}"
    cursor_prompt="$(tend_prompt)" || exit 1
    claude_prompt="$(tend_prompt_claude)" || exit 1

    # RS01: mark pending tasks as running before dispatch so dashboard is accurate.
    if [[ "$TEND_MODE" == "go auto" || "$TEND_MODE" == "go_auto" ]]; then
      mark_pending_tasks_as_running
    fi

    refresh_tend_lock
    dispatch "$cursor_prompt" "$claude_prompt"
    tend_loop=1

    if [[ "$TEND_MODE" == "go auto" || "$TEND_MODE" == "go_auto" ]]; then
      while true; do
        refresh_tend_lock   # keep the lock fresh across long multi-session drains
        drain_inbox  # pick up any new inbox items between sessions
        pcount="$(pending_task_count)"
        [[ "$pcount" -eq 0 ]] && break
        if [[ $tend_loop -ge $MAX_TEND_LOOPS ]]; then
          log_heartbeat "run-job — queue drain reached max loops ($MAX_TEND_LOOPS); $pcount task(s) deferred to next cycle"
          break
        fi
        log_heartbeat "run-job — queue drain loop $((tend_loop + 1))/$MAX_TEND_LOOPS ($pcount pending remaining)"
        refresh_tend_lock
        dispatch "$cursor_prompt" "$claude_prompt"
        tend_loop=$(( tend_loop + 1 ))
      done
    fi
    ;;
  inbox-log-analyzer)
    dispatch "/inbox-log-analyzer" "/inbox-log-analyzer"
    ;;
  *)
    echo "run-job.sh: unknown job '$JOB' (expected tend or inbox-log-analyzer)" >&2
    exit 1
    ;;
esac
