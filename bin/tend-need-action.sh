#!/usr/bin/env bash
# tend-need-action.sh — T-1 pre-flight scan (read-only; no lock)
# Exit 0 when idle (NEED_ACTION=0), exit 1 when action required.
#
# Only AGENT-EXECUTABLE work sets NEED_ACTION=1. Tasks that are blocked on a
# human (gated `awaiting_go`, and genuine `needs_human` blockers) are bypassed
# so the launchd tend cycle does not spend AI tokens re-notifying every 5 min.
set -euo pipefail

ROOT="${1:-.}"
PROJ="$ROOT/.orchestrate/project.md"
HEARTBEAT="$ROOT/.orchestrate/logs/heartbeat.log"

count_status() {
  local st="$1"
  [[ -f "$PROJ" ]] || { echo 0; return; }
  # grep returns 1 on no match — must not abort under set -e
  awk -F'|' -v st="$st" '
    /^\|/ && $2 !~ /^[[:space:]]*ID[[:space:]]*$/ && $2 !~ /^-+$/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6)
      if ($6 == st) n++
    }
    END { print n + 0 }
  ' "$PROJ"
}

# Count `needs_human` rows that still need an AGENT pass. A needs_human row is
# agent-actionable when the agent can still advance it without a human:
#   - task file MISSING + a ghost-reset heartbeat line  → auto-job re-queue
#   - task file present + ALL phases ✓ complete          → run Completion inline
#   - task file present + NO human_resolution: line yet  → first-pass auto-resolution check
# A row is HUMAN-BLOCKED (bypass) when its task file already carries a
# human_resolution: line and phases are incomplete — the agent evaluated it and
# deliberately left it blocked; re-waking the agent just burns tokens.
count_needs_human_actionable() {
  [[ -f "$PROJ" ]] || { echo 0; return; }
  local count=0 id tf phases done_phases
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    tf="$ROOT/.orchestrate/tasks/${id}.md"
    if [[ ! -f "$tf" ]]; then
      if grep -q "ghost-reset ${id}: running" "$HEARTBEAT" 2>/dev/null; then
        count=$(( count + 1 ))   # stalled auto job → re-queue
      fi
      continue
    fi
    phases=$(grep -c '^### Phase' "$tf" 2>/dev/null) || phases=0
    done_phases=$(grep -c '✓ complete' "$tf" 2>/dev/null) || done_phases=0
    if [[ "$phases" -gt 0 && "$phases" -eq "$done_phases" ]]; then
      count=$(( count + 1 ))     # completion-eligible
    elif grep -q '^bypassed_at:' "$tf" 2>/dev/null; then
      :                          # parked (any block type) → bypass, never re-process
    elif ! grep -q '^human_resolution:' "$tf" 2>/dev/null; then
      count=$(( count + 1 ))     # not yet evaluated → needs first-pass check
    fi
    # else: bypassed_at OR human_resolution + incomplete phases → genuine blocker → bypass
  done < <(awk -F'|' '
    /^\|/ && $2 !~ /^[[:space:]]*ID[[:space:]]*$/ && $2 !~ /^-+$/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      if ($6 == "needs_human") print $2
    }
  ' "$PROJ")
  echo "$count"
}

# Agent-executable registry work: pending + awaiting_critic + actionable needs_human.
# Excluded on purpose: awaiting_go (gated, notify-only — never auto-executes) and
# running (live session holds the lock; stale ghosts are reset by run-job.sh bash).
PENDING="$(count_status pending)"
AWAITING_CRITIC="$(count_status awaiting_critic)"
NEEDS_HUMAN_ACTIONABLE="$(count_needs_human_actionable)"
registry_actionable=$(( PENDING + AWAITING_CRITIC + NEEDS_HUMAN_ACTIONABLE ))

# Inbox: only auto-mode root files are agent-executable (they drain to `pending`).
# gated/*.md only ever become notify-only `awaiting_go` rows, so they do not count.
inbox_count=0
for f in "$ROOT/.orchestrate/inbox"/*.md; do
  [[ -f "$f" ]] || continue
  grep -qE '^deferred_at:' "$f" 2>/dev/null && continue
  inbox_count=$(( inbox_count + 1 ))
done

NEED_ACTION=0
[[ "$registry_actionable" -gt 0 ]] && NEED_ACTION=1
[[ "$inbox_count" -gt 0 ]] && NEED_ACTION=1

echo "NEED_ACTION=$NEED_ACTION"
echo "REGISTRY_ACTIONABLE=$registry_actionable"
echo "NEEDS_HUMAN_ACTIONABLE=$NEEDS_HUMAN_ACTIONABLE"
echo "INBOX_ACTIVE=$inbox_count"
exit "$NEED_ACTION"
