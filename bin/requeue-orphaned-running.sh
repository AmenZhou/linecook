#!/usr/bin/env bash
# requeue-orphaned-running.sh — deterministic bash mirror of the SKILL.md T-4
# "running tasks (orphaned-row check)" rule.
#
# Root cause (investigated by task 20260716-inbox-3C1D): a registry row is
# marked `running` by (at least) two uncoordinated writers — the bash bulk
# pre-mark `mark_pending_tasks_as_running()` in run-job.sh, and the agent
# session's own per-batch "mark running before dispatch" step (SKILL.md T-4)
# — and BOTH mark `running` strictly before the task file is created and the
# `tend-auto — dispatching "<title>" ({ID})` heartbeat line is written. If the
# ensuing agent CLI invocation fails outright (session_limit/timeout/connection
# error/crash) or a sibling stateless tend session races in mid-batch-prep, the
# row is left `running` with no task file and no dispatch line — orphaned.
#
# Previously the ONLY recovery paths were:
#   (a) an LLM T-4 scan during some OTHER agent-dispatched cycle happening to
#       notice the stale row (opportunistic — never fires if nothing else is
#       actionable, since a bare `running` row does not itself trigger
#       NEED_ACTION), or
#   (b) reset_stale_running_tasks's NO_FILE_GRACE_SECS (1800s) bash fallback,
#       which flips the row to `needs_human` (not `pending`), only THEN making
#       it agent-actionable via the ghost-reset heartbeat line, requiring a
#       FURTHER agent cycle to re-queue it to `pending`.
# Both paths take on the order of 30-35 minutes end to end, and (a) firing
# from two overlapping stateless sessions is exactly what produced the
# same-second double "re-queued orphaned running row" log lines observed for
# 20260715-inbox-3D70.
#
# This script closes the gap deterministically, in bash, every cycle: same
# staleness threshold as the LLM rule (300s), same detection criteria (no task
# file AND no dispatch heartbeat line), same corrective action (requeue to
# `pending`) — but it needs no live agent session to fire, and because it is a
# single bash pass under the tend lock, it cannot double-fire the way two
# independent LLM sessions could.
#
# 20260725-inbox-4C3D: the reset target respects the row's `mode` column —
# `mode: auto` rows requeue to `pending` as always, but `mode: gated` rows
# requeue to `awaiting_go` instead. Resetting a gated row straight to `pending`
# would silently drop its human-approval gate: the row could then be swept
# into the very next `tend go auto` auto-execution batch with no human `go`.
#
# Wired into run-job.sh tend preflight (primary; AFTER repair_registry_rows +
# finalize_completed_tasks, BEFORE reset_stale_running_tasks — so an orphan is
# caught at 300s instead of falling through to the 1800s no-file-grace path)
# and rescue.sh (safety net, same ordering).
set -euo pipefail

ROOT="${1:-$(pwd)}"
PROJ="$ROOT/.orchestrate/project.md"
HEARTBEAT="$ROOT/.orchestrate/logs/heartbeat.log"

[[ -f "$PROJ" ]] || exit 0

ORPHAN_STALE_SECS="${ORPHAN_STALE_SECS:-300}"

log_orphan() {
  mkdir -p "$(dirname "$HEARTBEAT")" 2>/dev/null || true
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" >> "$HEARTBEAT" 2>/dev/null || true
}

# Share the re-queue counter with run-job.sh / rescue.sh / requeue-unblocked.sh
# so a row that keeps orphaning is parked after CG_THRESHOLD re-processings
# instead of looping forever.
CG_ROOT="$ROOT"
CG_LIB="$ROOT/.orchestrate/bin/churn-guard.sh"
[[ -f "$CG_LIB" ]] && source "$CG_LIB"

trim_ws() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

requeue_orphaned_running_rows() {
  [[ -f "$PROJ" ]] || return 0
  local now_epoch
  now_epoch="$(date +%s)"

  local row_id mode status last_activity
  while IFS='|' read -r _ row_id _ mode _ status last_activity _; do
    row_id="$(trim_ws "$row_id")"
    mode="$(trim_ws "$mode")"
    status="$(trim_ws "$status")"
    last_activity="$(trim_ws "$last_activity")"
    [[ -z "$row_id" || "$row_id" == "ID" || "$row_id" =~ ^-+$ ]] && continue
    [[ "$status" == "running" ]] || continue

    # Has a task file → genuinely in progress (or already handled elsewhere).
    local task_file="$ROOT/.orchestrate/tasks/${row_id}.md"
    [[ -f "$task_file" ]] && continue

    # Has a dispatch heartbeat line for this ID → genuinely in progress; the
    # batch that owns it hasn't reached the task-file-creation step yet.
    if grep -qE "tend-auto — dispatching \".*\" \(${row_id}\)" "$HEARTBEAT" 2>/dev/null; then
      continue
    fi

    # Staleness gate: only fire once last_activity is old enough that this
    # cannot be a dispatch genuinely still in its mark-running-before-dispatch
    # window within the current cycle.
    local la_epoch=0
    if [[ -n "$last_activity" ]]; then
      la_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$last_activity" +%s 2>/dev/null || echo 0)"
    fi
    local age=$(( now_epoch - la_epoch ))
    [[ $age -lt $ORPHAN_STALE_SECS ]] && continue

    # Gated rows must never be silently re-queued straight to `pending` — that
    # would drop the human-approval gate and let the row get swept into the
    # next `tend go auto` auto-execution batch unattended (20260725-inbox-4C3D).
    # `mode: auto` rows keep resetting to `pending`; `mode: gated` rows reset to
    # `awaiting_go` instead, same as their normal (non-orphaned) gated state.
    local reset_status="pending"
    [[ "$mode" == "gated" ]] && reset_status="awaiting_go"

    local now_iso tmp rc=0
    now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    tmp="$(mktemp "${TMPDIR:-/tmp}/project-md.XXXXXX")"
    awk -F'|' -v OFS='|' -v id="$row_id" -v ts="$now_iso" -v new_status="$reset_status" '
      /^\|[[:space:]]*[0-9]/ && NF==8 {
        rid=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",rid)
        st=$6;  gsub(/^[[:space:]]+|[[:space:]]+$/,"",st)
        if (rid==id && st=="running") { $6=" " new_status " "; $7=" " ts " "; flipped=1 }
      }
      { print }
      END { exit (flipped ? 0 : 2) }
    ' "$PROJ" > "$tmp" || rc=$?

    if [[ $rc -ne 0 ]]; then
      rm -f "$tmp"
      log_orphan "requeue-orphaned-running SKIPPED ${row_id}: row did not flip (malformed/raced); awaiting repair_registry_rows"
      continue
    fi
    mv "$tmp" "$PROJ"

    local parked=0
    if type cg_increment >/dev/null 2>&1; then
      if type cg_increment_unless_transient >/dev/null 2>&1; then
        cg_increment_unless_transient "$row_id" "$la_epoch" >/dev/null 2>&1 || true
      else
        cg_increment "$row_id" >/dev/null 2>&1 || true
      fi
      if cg_park_if_churned "$row_id" 2>/dev/null; then
        parked=1
        log_orphan "churn-guard parked ${row_id} after ${CG_THRESHOLD:-3} re-processings (orphaned-running-row path)"
      fi
    fi
    if [[ "$parked" -ne 1 ]]; then
      if [[ "$reset_status" == "awaiting_go" ]]; then
        log_orphan "tend-auto — re-queued orphaned running row ${row_id} to awaiting_go (mode: gated, no task file, no dispatch heartbeat)"
      else
        log_orphan "tend-auto — re-queued orphaned running row ${row_id} (no task file, no dispatch heartbeat)"
      fi
    fi
  done < <(grep -E '^\|[[:space:]]*[0-9]' "$PROJ" 2>/dev/null || true)
}

requeue_orphaned_running_rows
