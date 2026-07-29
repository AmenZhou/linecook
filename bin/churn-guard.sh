#!/usr/bin/env bash
# churn-guard.sh — shared re-queue counter + "blocked after 3×" park mechanism.
#
# A poison task can loop forever: running → ghost-reset/needs_human → pending →
# running … with nothing detecting that the SAME task has been re-queued N times.
# This helper is the single owner of that counter, sourced by every requeue/
# re-dispatch site (run-job.sh, requeue-unblocked.sh, rescue.sh) so the logic and
# the storage exist exactly once.
#
# Counter storage (two layers, max() wins — survives the no-task-file case):
#   1. `requeue_count: N` line in `.orchestrate/tasks/<ID>.md` (when the file exists)
#   2. sidecar TSV `.orchestrate/logs/requeue-counts.tsv` keyed by ID
#      (ghost-reset auto jobs have NO task file — the sidecar is their only home)
#
# Threshold: on the 3rd re-processing the task is PARKED ("blocked") via the
# existing bypass mechanism — registry row left/forced to needs_human + the task
# file (created if absent) carries `bypassed_at:` + `bypass_reason: churn —
# re-processed 3×`, so tend-need-action.sh treats it as non-actionable and the
# launchd cycle stops waking the agent for it. An async investigation inbox job is
# auto-filed (source: self, mode: auto, triggered_by: <ID>), deduped.
#
# All registry writes keep the NF==8 invariant (exactly 6 cells with an EMPTY
# trailing $8). Every function is idempotent and safe to call repeatedly.
#
# Usage as a library:   source churn-guard.sh   (CG_ROOT must be set, or pass ROOT)
# Usage standalone (tests):   churn-guard.sh <fn> <ROOT> <ID> [args]

# Resolve ROOT: explicit CG_ROOT, else caller's ROOT, else cwd.
cg__root() { printf '%s' "${CG_ROOT:-${ROOT:-$(pwd)}}"; }

CG_THRESHOLD="${CG_THRESHOLD:-3}"

cg__sidecar() { printf '%s' "$(cg__root)/.orchestrate/logs/requeue-counts.tsv"; }
cg__taskfile() { printf '%s' "$(cg__root)/.orchestrate/tasks/${1}.md"; }
cg__heartbeat() { printf '%s' "$(cg__root)/.orchestrate/logs/heartbeat.log"; }

cg__sidecar_count() {
  local id="$1" sc
  sc="$(cg__sidecar)"
  [[ -f "$sc" ]] || { echo 0; return; }
  awk -F'\t' -v id="$id" '$1==id { print $2+0; found=1 } END { if (!found) print 0 }' "$sc" | tail -1
}

cg__taskfile_count() {
  local id="$1" tf n
  tf="$(cg__taskfile "$id")"
  [[ -f "$tf" ]] || { echo 0; return; }
  n="$(grep -E '^requeue_count:[[:space:]]*[0-9]+' "$tf" 2>/dev/null | head -1 | sed -E 's/^requeue_count:[[:space:]]*//')"
  echo "${n:-0}"
}

# cg_count <ID> — current re-queue count = max(task-file, sidecar).
cg_count() {
  local id="$1" a b
  a="$(cg__taskfile_count "$id")"
  b="$(cg__sidecar_count "$id")"
  if [[ "${a:-0}" -ge "${b:-0}" ]]; then echo "${a:-0}"; else echo "${b:-0}"; fi
}

cg__set_sidecar() {
  local id="$1" val="$2" sc tmp
  sc="$(cg__sidecar)"
  mkdir -p "$(dirname "$sc")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/cg-sidecar.XXXXXX")"
  if [[ -f "$sc" ]]; then
    awk -F'\t' -v id="$id" '$1!=id { print }' "$sc" > "$tmp" 2>/dev/null || true
  fi
  printf '%s\t%s\n' "$id" "$val" >> "$tmp"
  mv "$tmp" "$sc"
}

cg__set_taskfile() {
  local id="$1" val="$2" tf tmp
  tf="$(cg__taskfile "$id")"
  [[ -f "$tf" ]] || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/cg-tf.XXXXXX")"
  if grep -qE '^requeue_count:' "$tf" 2>/dev/null; then
    sed -E "s/^requeue_count:.*/requeue_count: ${val}/" "$tf" > "$tmp" && mv "$tmp" "$tf"
  else
    # Insert after the first line (title) so it lands in the header region.
    awk -v v="$val" 'NR==1 { print; print "requeue_count: " v; next } { print }' "$tf" > "$tmp" && mv "$tmp" "$tf"
  fi
}

# cg_increment <ID> — bump the counter in BOTH layers; echo the new count.
cg_increment() {
  local id="$1" cur new
  cur="$(cg_count "$id")"
  new=$(( cur + 1 ))
  cg__set_sidecar "$id" "$new"
  cg__set_taskfile "$id" "$new"   # no-op if task file absent
  echo "$new"
}

# Transient infra-death patterns — a run that died on one of these hit no poison
# and made no progress; it should be retried like a C3 one-shot transient, not
# counted toward the poison-park threshold. Override via CG_TRANSIENT_PATTERN.
CG_TRANSIENT_PATTERN="${CG_TRANSIENT_PATTERN:-API Error: Connection closed mid-response|Connection closed mid-response|Connection error|Connection reset|ECONNRESET|EPIPE|ETIMEDOUT|socket hang up|Error: 429|HTTP 429|Too Many Requests|Request timed out|network error}"

# cg__latest_agent_log — path of the most recently modified per-session agent log
# (`.orchestrate/logs/YYYYMMDD-HHMMSS-agent.log`, written by run-job.sh:run_agent),
# or empty when none exists. This is the "just-reset run's" log at ghost-reset time,
# because reset_stale_running_tasks/rescue run in preflight BEFORE the next agent
# session opens its own log.
cg__latest_agent_log() {
  local root logdir
  if [[ -n "${ZSH_VERSION:-}" ]]; then setopt local_options nullglob; fi
  root="$(cg__root)"
  logdir="$root/.orchestrate/logs"
  [[ -d "$logdir" ]] || return 0
  ls -t "$logdir"/*-agent.log 2>/dev/null | head -1
}

# cg__agent_log_since <since_epoch> — path of the EARLIEST *-agent.log whose
# mtime is >= since_epoch, or empty when none qualifies. Used to attribute an
# async/delayed ghost-reset (rescue.sh, or any detector that runs long after the
# actual failed dispatch) to the log for THAT SPECIFIC stale row, rather than
# "whatever happens to be newest on disk right now" (cg__latest_agent_log).
# BC7C: cg__latest_agent_log's doc comment assumes the detector runs
# synchronously, right after the failing session, so "latest" == "that run's
# log" — true for run-job.sh's own reset_stale_running_tasks, called inline in
# the same preflight. It is NOT true for rescue.sh, a separately-scheduled
# process that can fire hours after the row went stale: by then an unrelated,
# later, successful tend cycle may have written a newer agent log, so
# cg__latest_agent_log picks THAT (unrelated, non-transient, no-progress) log
# instead of the actual crashed dispatch attempt — misclassifying a genuine
# transient-infra death (e.g. a recurring "Connection closed mid-response" CLI
# crash) as a real re-processing and inflating the churn counter toward a false
# park. Using the row's last_activity epoch as `since_epoch` finds the log from
# the dispatch attempt that actually made this row stale.
cg__agent_log_since() {
  local since="$1" root logdir f m best="" best_mtime=0
  if [[ -n "${ZSH_VERSION:-}" ]]; then setopt local_options nullglob; fi
  root="$(cg__root)"
  logdir="$root/.orchestrate/logs"
  [[ -d "$logdir" ]] || return 0
  for f in "$logdir"/*-agent.log; do
    [[ -f "$f" ]] || continue
    m="$(date -r "$f" +%s 2>/dev/null || echo 0)"
    [[ "$m" -ge "$since" ]] || continue
    if [[ -z "$best" || "$m" -lt "$best_mtime" ]]; then
      best="$f"; best_mtime="$m"
    fi
  done
  printf '%s' "$best"
}

# cg_is_transient_reset [LOGFILE] [SINCE_EPOCH] — return 0 (true) when the
# resolved agent log shows ONLY a transient connection/infra error with ZERO
# task progress. Progress evidence (a `## PHASE OUTPUT` block or a `✓ complete`
# checkpoint) DISQUALIFIES "transient" — a run that did real work then failed is a
# genuine re-processing and must count. Returns 1 (false) when the log is absent,
# shows progress, or shows no transient error at all.
#
# Log resolution: an explicit LOGFILE always wins (tests / callers with a known
# log). Otherwise, when SINCE_EPOCH (the stale row's last_activity, epoch
# seconds) is given, use cg__agent_log_since to find the log from the dispatch
# attempt that actually made this row stale — falling back to
# cg__latest_agent_log only when no such log exists or SINCE_EPOCH is omitted
# (preserves the original synchronous-caller behavior in run-job.sh).
cg_is_transient_reset() {
  local log="${1:-}" since="${2:-0}"
  if [[ -z "$log" ]]; then
    if [[ "$since" =~ ^[0-9]+$ && "$since" -gt 0 ]]; then
      log="$(cg__agent_log_since "$since")"
    fi
    [[ -n "$log" ]] || log="$(cg__latest_agent_log)"
  fi
  [[ -n "$log" && -f "$log" ]] || return 1
  # Any progress marker means the run was not a clean transient death — count it.
  if grep -qE '## PHASE OUTPUT|✓ complete' "$log" 2>/dev/null; then
    return 1
  fi
  # Must actually carry a transient connection/infra error to qualify.
  grep -qiE "$CG_TRANSIENT_PATTERN" "$log" 2>/dev/null
}

# cg__heartbeat_shell_incapable_since <since_epoch> — return 0 (true) when
# heartbeat.log carries a "... session has no shell capability; deferred" line
# — the marker run_with_fallback (run-job.sh) writes ONLY after BOTH runners
# (primary + secondary) failed that dispatch cycle's shell-capability probe —
# timestamped at/after since_epoch. Returns 1 when no such line qualifies, or
# heartbeat.log is absent. since_epoch bounds the scan to the window in which
# THIS row went stale; heartbeat.log accumulates unboundedly across unrelated
# tasks/cycles, so an unscoped scan would misattribute some other, older
# shell-incapable cycle to this reset.
cg__heartbeat_shell_incapable_since() {
  local since="$1" hb line ts epoch
  hb="$(cg__heartbeat)"
  [[ -f "$hb" ]] || return 1
  while IFS= read -r line; do
    ts="$(printf '%s' "$line" | grep -oE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\]' | tr -d '[]')"
    [[ -n "$ts" ]] || continue
    epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null || echo 0)"
    [[ "$epoch" -ge "$since" ]] && return 0
  done < <(grep -E 'no shell capability; deferred' "$hb" 2>/dev/null)
  return 1
}

# cg_is_shell_incapable_reset <SINCE_EPOCH> — return 0 (true) when this
# ghost-reset was caused by dispatch-side shell-capability starvation rather
# than the task's own phase work failing. A dispatch cycle where BOTH runners
# fail the shell-probe (see run-job.sh's shell_probe_directive/shell_probe_failed)
# never demonstrates it can run a Bash command, so it cannot have reached ANY
# task's actual phase work that cycle either — the 20260728-inbox-36DC
# investigation found exactly this: 3 consecutive dispatch-starvation cycles
# parked a perfectly healthy task purely on this ghost-reset → requeue loop.
# SINCE_EPOCH (the stale row's last_activity) is REQUIRED (>0) — unlike a
# single agent log, heartbeat.log has no natural "latest" fallback, so an
# unscoped search would risk attributing an unrelated historical
# shell-incapable cycle to today's reset. As an extra guard (mirrors
# cg_is_transient_reset), a resolved agent log showing real progress in the
# window still disqualifies this classification — the task cannot be "no
# session ever reached its phase work" if one visibly did.
cg_is_shell_incapable_reset() {
  local since="${1:-0}"
  [[ "$since" =~ ^[0-9]+$ && "$since" -gt 0 ]] || return 1
  cg__heartbeat_shell_incapable_since "$since" || return 1
  local log
  log="$(cg__agent_log_since "$since")"
  [[ -n "$log" ]] || log="$(cg__latest_agent_log)"
  if [[ -n "$log" && -f "$log" ]] && grep -qE '## PHASE OUTPUT|✓ complete' "$log" 2>/dev/null; then
    return 1   # a session did reach real phase work — genuine reset, must count
  fi
  return 0
}

# cg_increment_unless_transient <ID> [SINCE_EPOCH] — the ghost-reset re-queue
# entry point. Bumps the churn counter UNLESS the just-reset run died on a
# transient infra error with zero progress (cg_is_transient_reset), or the
# reset was caused by dispatch-side shell-capability starvation rather than the
# task's own phase work failing (cg_is_shell_incapable_reset) — in either case
# the counter is left untouched (the run is retried like a one-shot transient)
# and a heartbeat line is logged. Echoes the new count on a real bump,
# `transient`, or `shell_incapable` when skipped. SINCE_EPOCH (optional): the
# stale row's last_activity in epoch seconds — pass this from any detector that
# may run asynchronously/long after the row went stale (rescue.sh) so both
# checks are attributed to the right window; see cg__agent_log_since.
cg_increment_unless_transient() {
  local id="$1" since="${2:-0}"
  if cg_is_transient_reset "" "$since"; then
    local hb iso
    hb="$(cg__heartbeat)"; mkdir -p "$(dirname "$hb")"
    iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "[${iso}] churn-guard — transient-infra ghost-reset for ${id}, not counted" >> "$hb"
    echo "transient"
    return 0
  fi
  if cg_is_shell_incapable_reset "$since"; then
    local hb iso
    hb="$(cg__heartbeat)"; mkdir -p "$(dirname "$hb")"
    iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "[${iso}] churn-guard — dispatch-starvation (shell_incapable) ghost-reset for ${id}, not counted" >> "$hb"
    echo "shell_incapable"
    return 0
  fi
  cg_increment "$id"
}

# cg_reset <ID> — zero the counter on completion (remove sidecar row + zero file line).
cg_reset() {
  local id="$1" sc tmp tf tftmp
  sc="$(cg__sidecar)"
  if [[ -f "$sc" ]]; then
    tmp="$(mktemp "${TMPDIR:-/tmp}/cg-sidecar.XXXXXX")"
    awk -F'\t' -v id="$id" '$1!=id { print }' "$sc" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$sc"
  fi
  tf="$(cg__taskfile "$id")"
  if [[ -f "$tf" ]] && grep -qE '^requeue_count:' "$tf" 2>/dev/null; then
    tftmp="$(mktemp "${TMPDIR:-/tmp}/cg-tf.XXXXXX")"
    grep -vE '^requeue_count:' "$tf" > "$tftmp" && mv "$tftmp" "$tf"
  fi
  # 19D7: a task that reached `complete` has no convergence failure — auto-close
  # any still-active investigate-churn ticket filed by a mid-flight-reset false
  # positive, so tend never spends a cycle diagnosing-then-closing it by hand.
  cg_close_investigation "$id"
}

# cg_close_investigation <ID> — move any still-active investigate-churn ticket for
# <ID> out of the live inbox into processed/, stamping a closure marker. Called on
# completion (via cg_reset) so a false-positive churn ticket never runs. The
# triggered_by line stays intact so cg_file_investigation's dedup still sees it and
# never re-files. Idempotent; no-op when no active ticket exists.
cg_close_investigation() {
  local id="$1" root inbox f base iso
  # zsh (the sourced tend-agent shell) aborts on an unmatched glob; make it expand
  # to nothing instead. Function-local via local_options — auto-restored on return,
  # and a no-op under bash (where the loop is already unmatched-glob-safe).
  if [[ -n "${ZSH_VERSION:-}" ]]; then setopt local_options nullglob; fi
  root="$(cg__root)"
  inbox="$root/.orchestrate/inbox"
  [[ -d "$inbox" ]] || return 0
  iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for f in "$inbox"/investigate-churn-"${id}"-*.md; do
    [[ -f "$f" ]] || continue
    mkdir -p "$inbox/processed"
    base="$(basename "$f")"
    printf '\nclosed_at: %s\nclosed_reason: target %s reached complete — mid-flight-reset false positive\n' \
      "$iso" "$id" >> "$f"
    mv "$f" "$inbox/processed/$base" 2>/dev/null || true
  done
  # 19D7b: the false-positive ticket may already have been DRAINED into its own
  # registry row (an `Investigate churn — <id>` task) with its inbox file moved to
  # processed/ BEFORE the target completed — the live-inbox scan above then finds
  # nothing, and the moot investigation runs as a full task (recursive churn: the
  # investigation can itself stall and ghost-reset, filing yet another ticket). Also
  # auto-complete any non-terminal registry row whose summary names THIS target as an
  # investigate-churn task. The archive-gap backfill in finalize-completed-tasks.sh
  # archives the now-complete row on its next pass.
  cg__close_investigation_row "$id"
}

# cg__close_investigation_row <target> — close a DRAINED investigate-churn registry
# row for <target> once <target> is complete. Finds a non-terminal row whose summary
# reads `Investigate churn — <target> …`, flips it to complete (NF==8-safe), drops
# its ghost task file, and logs. Idempotent: a complete/failed row is skipped, so a
# second call is a clean no-op. No-op when no such row exists.
# 4474 fix: the match MUST be ANCHORED to the start of the summary (index()==1), not a
# substring (index()>0). The 6b auto-enqueue creates sibling follow-up rows summarized
# `Review of Investigate churn — <target> …` and `Tests for Investigate churn —
# <target> …`, which CONTAIN this needle. An unanchored match closed those still-active
# review/tests rows and rm'd their task files (live wrong-row corruption). Anchoring to
# position 1 requires `Investigate churn — <target>` to be the summary PREFIX, excluding
# the `Review of`/`Tests for` prefixes.
cg__close_investigation_row() {
  local target="$1" proj inv_id now tmp hb
  proj="$(cg__root)/.orchestrate/project.md"
  [[ -f "$proj" ]] || return 0
  inv_id="$(awk -F'|' -v t="$target" '
    function trim(s){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",s); return s }
    /^\|[[:space:]]*[0-9A-Za-z]/ && NF>=8 {
      summ=trim($3); st=trim($6); rid=trim($2)
      if (index(summ, "Investigate churn — " t)==1 && st!="complete" && st!="failed") {
        print rid; exit
      }
    }' "$proj")"
  [[ -n "$inv_id" ]] || return 0
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-md.XXXXXX")"
  awk -F'|' -v OFS='|' -v id="$inv_id" -v now="$now" '
    /^\|[[:space:]]*[0-9A-Za-z]/ && NF>=8 {
      rid=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",rid)
      if (rid==id) { $6=" complete "; $7=" " now " "; if (NF>8){NF=8;$8=""} }
    }
    { print }
  ' "$proj" > "$tmp" && mv "$tmp" "$proj"
  rm -f "$(cg__taskfile "$inv_id")" 2>/dev/null || true
  hb="$(cg__heartbeat)"; mkdir -p "$(dirname "$hb")"
  echo "[${now}] churn-guard — auto-closed investigate-churn row ${inv_id} (target ${target} complete — mid-flight-reset false positive)" >> "$hb"
}

# cg__park_registry <ID> — force the registry row to needs_human (NF==8-safe).
# No-op when the row is already needs_human. Atomic temp+mv.
cg__park_registry() {
  local id="$1" proj tmp now
  proj="$(cg__root)/.orchestrate/project.md"
  [[ -f "$proj" ]] || return 0
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-md.XXXXXX")"
  awk -F'|' -v OFS='|' -v id="$id" -v now="$now" '
    /^\|[[:space:]]*[0-9A-Za-z]/ && NF>=8 {
      rid=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",rid)
      st=$6;  gsub(/^[[:space:]]+|[[:space:]]+$/,"",st)
      if (rid==id && st!="complete") {
        $6=" needs_human "; $7=" " now " "
        if (NF>8) { NF=8; $8="" }   # self-heal phantom columns, restore trailing pipe
      }
    }
    { print }
  ' "$proj" > "$tmp" && mv "$tmp" "$proj"
}

# cg__write_bypass <ID> — ensure the task file carries bypassed_at: + bypass_reason:
# so tend-need-action.sh treats the row as parked/non-actionable. Creates a minimal
# task file when the row is a no-task-file ghost (so the bypass marker has a home).
cg__write_bypass() {
  local id="$1" reason="$2" tf now
  tf="$(cg__taskfile "$id")"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$tf")"
  if [[ ! -f "$tf" ]]; then
    {
      printf '# %s — parked by churn guard\n' "$id"
      printf 'source: self\nmode: auto\n'
      printf 'bypassed_at: %s\n' "$now"
      printf 'bypass_reason: %s\n' "$reason"
    } > "$tf"
    return 0
  fi
  # Existing file: refresh/insert the markers idempotently.
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/cg-bypass.XXXXXX")"
  grep -vE '^(bypassed_at|bypass_reason):' "$tf" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$tf"
  awk -v at="$now" -v rs="$reason" '
    NR==1 { print; print "bypassed_at: " at; print "bypass_reason: " rs; next }
    { print }
  ' "$tf" > "${tf}.cgtmp" && mv "${tf}.cgtmp" "$tf"
}

# cg_file_investigation <ID> — write an async investigation inbox job, deduped on
# `triggered_by: <ID>` across inbox/ + processed/. Echoes the path written, or
# nothing when deduped.
cg_file_investigation() {
  local id="$1" root inbox iso dest f
  # zsh sourced-shell safety: the dedup glob below must expand to nothing on no
  # match, not abort. Function-local (auto-restored); no-op under bash.
  if [[ -n "${ZSH_VERSION:-}" ]]; then setopt local_options nullglob; fi
  root="$(cg__root)"
  inbox="$root/.orchestrate/inbox"
  # 19D7 outcome-aware suppression: if the target task has already reached
  # `complete`, its counter hitting the threshold was a mid-flight-reset false
  # positive — there is no convergence failure to investigate. Do not file.
  local proj0 st0 summ0
  proj0="$root/.orchestrate/project.md"
  if [[ -f "$proj0" ]]; then
    st0="$(awk -F'|' -v id="$id" '/^\|/ { rid=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",rid); if(rid==id){ s=$6; gsub(/^[[:space:]]+|[[:space:]]+$/,"",s); print s; exit } }' "$proj0")"
    [[ "$st0" == "complete" ]] && return 0
    # Recursion guard: never file an investigate-churn job for a task that is
    # itself an investigate-churn job. Its fresh ID escapes the triggered_by
    # dedup below, so without this a churning investigation spawns another
    # investigation without bound (the 2026-07-24 auth-outage cascade: one
    # expired-OAuth run-job failure orphaned every dispatched task, and each
    # parked investigate-churn task filed a new one — ~18 tasks in 3 chains).
    summ0="$(awk -F'|' -v id="$id" '/^\|/ { rid=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",rid); if(rid==id){ s=$3; gsub(/^[[:space:]]+|[[:space:]]+$/,"",s); print s; exit } }' "$proj0")"
    case "$summ0" in
      [Ii]nvestigate\ churn*) return 0 ;;
    esac
  fi
  mkdir -p "$inbox" "$inbox/processed" 2>/dev/null || true
  # Dedup: skip if any inbox file (active or processed) already targets this ID.
  for f in "$inbox"/*.md "$inbox"/processed/*.md; do
    [[ -f "$f" ]] || continue
    if grep -qE "^triggered_by:[[:space:]]*${id}\b" "$f" 2>/dev/null; then
      return 0   # already filed
    fi
  done
  iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  dest="$inbox/investigate-churn-${id}-${iso}.md"
  # Pull the registry row + any churn-guard heartbeat lines for Context.
  local proj row hb_lines
  proj="$root/.orchestrate/project.md"
  row="$(grep -E "^\|[[:space:]]*${id}[[:space:]]*\|" "$proj" 2>/dev/null | head -1 || true)"
  hb_lines="$(grep -E "(ghost-reset|requeue|churn).*${id}" "$(cg__heartbeat)" 2>/dev/null | tail -10 || true)"
  {
    printf 'source: self\n'
    printf 'mode: auto\n'
    printf 'triggered_by: %s\n\n' "$id"
    printf '# Investigate churn — %s re-processed %s×\n\n' "$id" "$CG_THRESHOLD"
    printf '## Goal\n'
    printf 'Root-cause why `%s` was re-processed %s× without converging, and propose/apply a fix.\n\n' "$id" "$CG_THRESHOLD"
    printf '## Context\n'
    printf 'The churn guard parked `%s` (needs_human + bypass_reason: churn — re-processed %s×) after it cycled running → needs_human/ghost-reset → pending → running repeatedly without completing.\n\n' "$id" "$CG_THRESHOLD"
    printf 'Registry row at park time:\n```\n%s\n```\n\n' "${row:-<row not found>}"
    printf 'Relevant heartbeat lines:\n```\n%s\n```\n\n' "${hb_lines:-<none>}"
    printf '## Acceptance Criteria\n'
    printf '%s\n' '- Identify the convergence failure (poison input, missing dependency, non-idempotent step, or detection bug).'
    printf '%s\n' '- Propose and, where safe, apply a fix so the task can complete or be correctly closed.'
    printf '%s\n' "- Clear the bypass on \`${id}\` (or document why it must stay parked)."
  } > "$dest"
  echo "$dest"
}

# cg_park_if_churned <ID> [reason] — if the counter has reached CG_THRESHOLD, park
# the task (registry needs_human + bypass markers), file the investigation job
# (deduped), and append a churn-guard heartbeat line. Returns 0 when it parked
# (caller should stop re-queueing), 1 when below threshold (caller proceeds).
# Idempotent: a second call after parking re-detects threshold, re-parks no-op,
# and does NOT double-file (investigation dedup on triggered_by).
cg_park_if_churned() {
  local id="$1"
  local count
  count="$(cg_count "$id")"
  if [[ "${count:-0}" -lt "$CG_THRESHOLD" ]]; then
    return 1
  fi
  local reason="churn — re-processed ${CG_THRESHOLD}×"
  cg__park_registry "$id"
  cg__write_bypass "$id" "$reason"
  local filed
  filed="$(cg_file_investigation "$id")"
  local hb iso
  hb="$(cg__heartbeat)"
  mkdir -p "$(dirname "$hb")"
  iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local invname="investigate-churn-${id}"
  if [[ -n "$filed" ]]; then
    echo "[${iso}] churn-guard — blocked ${id} after ${CG_THRESHOLD} re-processings; filed ${invname}" >> "$hb"
  else
    echo "[${iso}] churn-guard — blocked ${id} after ${CG_THRESHOLD} re-processings; no investigation filed (self-referential churn job or target complete/deduped)" >> "$hb"
  fi
  return 0
}

# Standalone dispatch for tests / scripting.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  fn="${1:?usage: churn-guard.sh <cg_increment|cg_increment_unless_transient|cg_is_transient_reset|cg_is_shell_incapable_reset|cg_count|cg_reset|cg_park_if_churned|cg_file_investigation> <ROOT> <ID> [args]}"
  CG_ROOT="${2:?ROOT required}"
  shift 2
  "$fn" "$@"
fi
