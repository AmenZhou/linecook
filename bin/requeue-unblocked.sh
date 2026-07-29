#!/usr/bin/env bash
# requeue-unblocked.sh — auto-requeue needs_human rows when to_clear / requeue signals are satisfied
# Usage: requeue-unblocked.sh <project_root>
# Logs requeues to stdout (caller appends to heartbeat.log).
set -euo pipefail

ROOT="${1:?usage: requeue-unblocked.sh <root>}"
PROJ="$ROOT/.orchestrate/project.md"
TASKS="$ROOT/.orchestrate/tasks"
HEARTBEAT="$ROOT/.orchestrate/logs/heartbeat.log"

[[ -f "$PROJ" ]] || exit 0

# Churn guard: share the re-queue counter with run-job.sh / rescue.sh so a task
# re-queued 3× from ANY site is parked rather than churning. CG_ROOT pins it here.
CG_ROOT="$ROOT"
if [[ -f "$ROOT/.orchestrate/bin/churn-guard.sh" ]]; then
  # shellcheck disable=SC1090
  source "$ROOT/.orchestrate/bin/churn-guard.sh"
fi

registry_row() {
  local id="$1" field="$2"  # field: status|mode
  awk -F'|' -v id="$id" -v want="$field" '
    $0 ~ "\\| " id " \\|" {
      if (want == "status") { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6); print $6 }
      if (want == "mode")   { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4); print $4 }
      exit
    }
  ' "$PROJ"
}

set_pending() {
  local id="$1" reason="$2"
  # Churn guard: a re-queue (needs_human → pending) is a re-processing. Bump the
  # shared counter; if ${id} has now churned ${CG_THRESHOLD:-3}× without
  # converging, park it (needs_human + bypass markers) + file an investigation job
  # INSTEAD of re-queueing, so a poison task does not loop forever.
  if type cg_increment >/dev/null 2>&1; then
    cg_increment "$id" >/dev/null 2>&1 || true
    if cg_park_if_churned "$id" 2>/dev/null; then
      local pnow line
      pnow="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      line="[${pnow}] tend-auto — churn-guard parked ${id} after ${CG_THRESHOLD:-3} re-queues (requeue-unblocked path); not re-queued"
      echo "$line" >>"$HEARTBEAT"
      echo "$line"
      return 0
    fi
  fi
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-md.XXXXXX")"
  awk -F'|' -v OFS='|' -v id="$id" -v now="$now" '
    $0 ~ "\\| " id " \\|" {
      for (i=1; i<=NF; i++) {
        f = $i; gsub(/^[[:space:]]+|[[:space:]]+$/, "", f)
        if (f == "needs_human") $i = " pending "
      }
      # Registry-write rule (Shared Context 2026-06-27): stamp last_activity in $7,
      # NEVER $8. Writing $8 appended a phantom field PAST the trailing pipe (NF==8
      # with a non-empty $8, no trailing pipe) — the corruption signature that
      # defeats reset_stale_running_tasks. Self-heal any phantom column in the same
      # pass: keep $7, force NF=8 with an EMPTY trailing $8 so the trailing pipe is
      # restored. No-op shape change on already-valid rows.
      if (NF >= 7) { $7 = " " now " " }
      if (NF > 8) { NF = 8 }
      $8 = ""
    }
    { print }
  ' "$PROJ" > "$tmp" && mv "$tmp" "$PROJ"
  # Clear the bypass marker so the parked task is re-evaluated on the next cycle.
  local tf="$TASKS/${id}.md"
  if [[ -f "$tf" ]] && grep -qE '^(bypassed_at|bypass_reason):' "$tf" 2>/dev/null; then
    local tftmp
    tftmp="$(mktemp "${TMPDIR:-/tmp}/taskfile.XXXXXX")"
    grep -vE '^(bypassed_at|bypass_reason):' "$tf" > "$tftmp" && mv "$tftmp" "$tf"
  fi
  local line="[${now}] tend-auto — requeue-unblocked ${id}: ${reason}"
  echo "$line" >>"$HEARTBEAT"
  echo "$line"
}

closure_in_file() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  grep -qE '\*\*(Closed|Status):\*\*.*(✅|Closed|CONFIRMED)' "$f" 2>/dev/null || \
    grep -qE '^[|][[:space:]]*\*\*Date confirmed\*\*' "$f" 2>/dev/null
}

requeue_count=0

while IFS='|' read -r _ task_id _ _ _ status _; do
  task_id="${task_id// /}"
  status="${status// /}"
  [[ "$status" == "needs_human" ]] || continue
  [[ -z "$task_id" || "$task_id" == "ID" ]] && continue

  tf="$TASKS/${task_id}.md"
  [[ -f "$tf" ]] || continue

  # Skip EXTERNAL blockers unless an explicit requeue signal is satisfied
  if grep -qE '^blocked_on:[[:space:]]*EXTERNAL' "$tf" 2>/dev/null; then
    if ! grep -qE '^requeue_when_exists:' "$tf" 2>/dev/null; then
      continue
    fi
  fi

  # Explicit requeue_when_exists: <path>
  if grep -qE '^requeue_when_exists:' "$tf" 2>/dev/null; then
    ref="$(grep -E '^requeue_when_exists:' "$tf" | head -1 | sed 's/^requeue_when_exists:[[:space:]]*//')"
    ref="${ref/#\~/$HOME}"
    if closure_in_file "$ref"; then
      set_pending "$task_id" "requeue_when_exists satisfied ($ref)"
      requeue_count=$(( requeue_count + 1 ))
      continue
    fi
  fi

  # Structured to_clear references a decision file — check for filled decision table
  if grep -qE '^to_clear:' "$tf" 2>/dev/null || grep -qE '^## to_clear' "$tf" 2>/dev/null; then
  while IFS= read -r ref; do
    ref="${ref/#\~/$HOME}"
    if closure_in_file "$ref"; then
      set_pending "$task_id" "to_clear signal satisfied ($ref)"
      requeue_count=$(( requeue_count + 1 ))
      break
    fi
  done < <(grep -oE '[~/][^ )`]+launch_target_decision\.md' "$tf" 2>/dev/null || \
           grep -oE 'reports/phase3/[a-zA-Z0-9_./-]+\.md' "$tf" 2>/dev/null || true)
  fi

  # Human injected resolution that is NOT a BLOCKED marker → requeue
  if grep -qE '^human_resolution:' "$tf" && \
     ! grep -qE '^human_resolution:.*BLOCKED ON HUMAN' "$tf"; then
    set_pending "$task_id" "human_resolution injected (non-blocked)"
    requeue_count=$(( requeue_count + 1 ))
  fi

done < <(grep -E '^\|[[:space:]]*[0-9]' "$PROJ" 2>/dev/null || true)

echo "REQUEUED=$requeue_count"
exit 0
