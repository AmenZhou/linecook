#!/usr/bin/env bash
# detect-orphaned-awaiting-go.sh — awaiting_go analog of requeue-orphaned-running.sh.
#
# Root cause (task 20260717-inbox-4FA5): a dashboard "approve go auto" click on a
# gated (`awaiting_go`) registry row logs `dashboard — approved go auto gated
# task {ID}` and flips... nothing else. If the follow-on step that materializes
# `.orchestrate/tasks/{ID}.md` and starts execution never runs (crash, missed
# dispatch, monitor restart), the row is left `awaiting_go` forever with an
# approval on record and no task file. T-4's protocol deliberately never
# re-scans `awaiting_go` rows (to avoid re-notification spam — see SKILL.md's
# "SKIP entirely" instruction) so this case was invisible: 20260628-inbox-9D5A
# sat approved-but-never-started for 18 days with 3 dependent needs_human tasks
# permanently parked waiting on it.
#
# Unlike the orphaned-`running` case, this script does NOT auto-requeue to
# `pending` — silently re-executing a task a human explicitly gated, without a
# fresh review of current state, would violate the whole point of gating (see
# SKILL.md "Gating is risk-based" — gated tasks always require an explicit
# human go). Instead it surfaces the row every cycle it remains orphaned: one
# heartbeat line always, plus a one-time desktop notification (deduped via a
# sidecar, same pattern as drain-inbox.sh's notify_gated_once) so a human
# notices instead of it staying silent for weeks.
#
# Detection (all three must hold):
#   (a) registry row status == awaiting_go
#   (b) heartbeat.log has a `dashboard — approved go auto gated task {ID}` line
#       (or equivalent interactive `go auto {ID}` / `go {ID}` approval line)
#   (c) .orchestrate/tasks/{ID}.md does NOT exist
#   (d) the approval line's timestamp is at least ORPHAN_AWAITING_GO_STALE_SECS
#       (default 600s) old — generous, since approval-to-materialization should
#       be near-instant in the normal path.
#
# Wired into run-job.sh tend preflight (same neighborhood as
# requeue-orphaned-running.sh) and rescue.sh (safety net), so both the launchd
# cycle and the manual rescue path catch it.
set -euo pipefail

ROOT="${1:-$(pwd)}"
PROJ="$ROOT/.orchestrate/project.md"
HEARTBEAT="$ROOT/.orchestrate/logs/heartbeat.log"
NOTIFIED="$ROOT/.orchestrate/logs/awaiting-go-orphan-notified.tsv"

[[ -f "$PROJ" ]] || exit 0

ORPHAN_AWAITING_GO_STALE_SECS="${ORPHAN_AWAITING_GO_STALE_SECS:-600}"

log_orphan() {
  mkdir -p "$(dirname "$HEARTBEAT")" 2>/dev/null || true
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" >> "$HEARTBEAT" 2>/dev/null || true
}

notify_once() {
  local id="$1" summary="$2"
  mkdir -p "$(dirname "$NOTIFIED")" 2>/dev/null || true
  if [[ -f "$NOTIFIED" ]] && \
     awk -F'\t' -v id="$id" '$1 == id { found = 1 } END { exit !found }' "$NOTIFIED"; then
    return 0
  fi
  if command -v osascript >/dev/null 2>&1; then
    local safe="${summary//\"/\'}"
    osascript -e "display notification \"$safe\" with title \"Orchestrate: approved task never started\" subtitle \"$id\"" >/dev/null 2>&1 || true
  fi
  printf '%s\t%s\n' "$id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$NOTIFIED"
}

trim_ws() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

detect_orphaned_awaiting_go_rows() {
  [[ -f "$PROJ" ]] || return 0
  local now_epoch
  now_epoch="$(date +%s)"

  local row_id row_summary status
  while IFS='|' read -r _ row_id row_summary _ _ status _ _; do
    row_id="$(trim_ws "$row_id")"
    row_summary="$(trim_ws "$row_summary")"
    status="$(trim_ws "$status")"
    [[ -z "$row_id" || "$row_id" == "ID" || "$row_id" =~ ^-+$ ]] && continue
    [[ "$status" == "awaiting_go" ]] || continue

    # Task file already materialized → not orphaned (execution may be underway
    # or about to start).
    local task_file="$ROOT/.orchestrate/tasks/${row_id}.md"
    [[ -f "$task_file" ]] && continue

    # Find the approval line for this row (dashboard click, or an interactive
    # `go`/`go auto {ID}` approval note) and its timestamp.
    #
    # NOTE: the terminator after ${row_id} is deliberately NOT a bare `\b` —
    # IDs contain hyphens, which are non-word characters, so `\b` fires at the
    # ID/hyphen boundary and would false-match a *longer* ID that merely
    # starts with this row's ID (e.g. row `20260717-tst` would spuriously
    # match an approval line for `20260717-tst-other`). Requiring the next
    # char to be whitespace, a quote, or end-of-line avoids that false
    # positive while still matching every real approval-line format below.
    local approval_line approval_ts
    approval_line="$(grep -E "(dashboard — approved go auto gated task ${row_id}([[:space:]]|\"|\$)|approved gated task ${row_id}([[:space:]]|\"|\$)|go auto ${row_id}([[:space:]]|\"|\$)|\bgo ${row_id}([[:space:]]|\"|\$))" "$HEARTBEAT" 2>/dev/null | tail -1 || true)"
    [[ -z "$approval_line" ]] && continue

    approval_ts="$(printf '%s' "$approval_line" | sed -n 's/^\[\([^]]*\)\].*/\1/p')"
    [[ -z "$approval_ts" ]] && continue

    local approval_epoch=0
    approval_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$approval_ts" +%s 2>/dev/null || echo 0)"
    [[ "$approval_epoch" -eq 0 ]] && continue

    local age=$(( now_epoch - approval_epoch ))
    [[ $age -lt $ORPHAN_AWAITING_GO_STALE_SECS ]] && continue

    log_orphan "orphan-detect — awaiting_go row ${row_id} approved but no task file materialized (approved ${approval_ts}, ${age}s ago)"
    notify_once "$row_id" "$row_summary"
  done < <(grep -E '^\|[[:space:]]*[0-9]' "$PROJ" 2>/dev/null || true)
}

detect_orphaned_awaiting_go_rows
