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

set_pending() {
  local id="$1" reason="$2"
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
      if (NF >= 8) $8 = " " now " "
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

  if grep -qE '^blocked_on:[[:space:]]*EXTERNAL' "$tf" 2>/dev/null; then
    if ! grep -qE '^requeue_when_exists:' "$tf" 2>/dev/null; then
      continue
    fi
  fi

  if grep -qE '^requeue_when_exists:' "$tf" 2>/dev/null; then
    ref="$(grep -E '^requeue_when_exists:' "$tf" | head -1 | sed 's/^requeue_when_exists:[[:space:]]*//')"
    ref="${ref/#\~/$HOME}"
    if closure_in_file "$ref"; then
      set_pending "$task_id" "requeue_when_exists satisfied ($ref)"
      requeue_count=$(( requeue_count + 1 ))
      continue
    fi
  fi

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

  if grep -qE '^human_resolution:' "$tf" && \
     ! grep -qE '^human_resolution:.*BLOCKED ON HUMAN' "$tf"; then
    set_pending "$task_id" "human_resolution injected (non-blocked)"
    requeue_count=$(( requeue_count + 1 ))
  fi

done < <(grep -E '^\|[[:space:]]*[0-9]' "$PROJ" 2>/dev/null || true)

echo "REQUEUED=$requeue_count"
exit 0
