#!/usr/bin/env bash
# test-requeue-orphaned-running.sh — regression for task 20260716-inbox-3C1D.
#
# Background: registry rows kept landing in "running, no task file, no dispatch
# heartbeat" 9x over 6 days. Root cause: mark_pending_tasks_as_running() (bash
# bulk pre-mark) and the agent session's own per-batch "mark running before
# dispatch" step both set `running` before the task file / dispatch heartbeat
# line exist, with no atomicity between the steps. Recovery previously relied
# entirely on an LLM T-4 scan happening to run during some OTHER
# agent-dispatched cycle, or a ~30-35 minute bash fallback via
# reset_stale_running_tasks's NO_FILE_GRACE_SECS path (which only reaches
# needs_human, requiring yet another cycle to re-queue to pending).
#
# Fix asserted here: requeue-orphaned-running.sh mirrors the LLM rule
# deterministically in bash — same 300s staleness gate, same no-task-file/
# no-dispatch-line detection, same re-queue-to-pending action — so the row is
# corrected same-cycle without needing a live agent session for an unrelated
# reason to stumble onto it.
set -euo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$PROJECT_ROOT/bin" ]] || { echo "FATAL: $PROJECT_ROOT/bin not found — PROJECT_ROOT path computation is broken (expected .../task-orchestrate/bin)" >&2; exit 1; }
SCRIPT="${SCRIPT:-$PROJECT_ROOT/bin/requeue-orphaned-running.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

OLD_TS="$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
FRESH_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# run_requeue <registry-row> [extra-setup-fn]
# Builds a mock control plane, runs the script against it, and echoes:
#   <final-status>|<count-of-requeue-heartbeat-lines>|<nf-of-row>
run_requeue() {
  local row="$1"; local setup_fn="${2:-}"
  local TMP; TMP="$(mktemp -d)"
  mkdir -p "$TMP/.orchestrate/tasks" "$TMP/.orchestrate/logs" "$TMP/.orchestrate/bin"
  {
    echo "# Orchestrate"
    echo "## Task Registry"
    echo "| ID | summary | mode | current_phase | status | last_activity |"
    echo "|----|---------|------|---------------|--------|---------------|"
    echo "$row"
  } > "$TMP/.orchestrate/project.md"
  [[ -n "$setup_fn" ]] && "$setup_fn" "$TMP"
  bash "$SCRIPT" "$TMP" >/dev/null 2>&1 || true
  local status nf hb
  status="$(grep '20260716-tst' "$TMP/.orchestrate/project.md" | awk -F'|' '{gsub(/ /,"",$6); print $6}')"
  nf="$(grep '20260716-tst' "$TMP/.orchestrate/project.md" | awk -F'|' '{print NF}')"
  hb="$(grep -c 're-queued orphaned running row 20260716-tst' "$TMP/.orchestrate/logs/heartbeat.log" 2>/dev/null || echo 0)"
  echo "${status}|${hb}|${nf}"
  rm -rf "$TMP"
}

echo ""
echo "── requeue-orphaned-running (3C1D) — test suite ───"

[[ -f "$SCRIPT" ]] && ok "requeue-orphaned-running.sh present" || fail "script missing at $SCRIPT"

echo ""
echo "1. Stale running row, no task file, no dispatch line → requeued to pending"
r="$(run_requeue "| 20260716-tst | a stale wiki ingest job | auto | 1 | running | $OLD_TS |")"
[[ "${r%%|*}" == "pending" ]] && ok "flipped to pending" || fail "status='${r%%|*}' (expected pending)"
[[ "$(echo "$r" | cut -d'|' -f2)" -ge 1 ]] && ok "orphaned-row heartbeat written" || fail "no orphaned-row heartbeat"
[[ "$(echo "$r" | cut -d'|' -f3)" -eq 8 ]] && ok "row stays NF==8" || fail "row NF != 8"

echo ""
echo "2. Fresh running row (< 300s), no task file, no dispatch line → NOT requeued"
r="$(run_requeue "| 20260716-tst | just-marked job | auto | 1 | running | $FRESH_TS |")"
[[ "${r%%|*}" == "running" ]] && ok "fresh row left running (staleness gate)" || fail "status='${r%%|*}' (expected running)"
[[ "$(echo "$r" | cut -d'|' -f2)" -eq 0 ]] && ok "no spurious heartbeat for fresh row" || fail "spurious requeue for fresh row"

echo ""
echo "3. Stale running row WITH a task file → NOT requeued (genuinely in progress)"
make_task_file() { printf '# Task\nid: 20260716-tst\n' > "$1/.orchestrate/tasks/20260716-tst.md"; }
r="$(run_requeue "| 20260716-tst | job with task file | auto | 1 | running | $OLD_TS |" make_task_file)"
[[ "${r%%|*}" == "running" ]] && ok "row with task file left running" || fail "status='${r%%|*}' (expected running — task file present)"
[[ "$(echo "$r" | cut -d'|' -f2)" -eq 0 ]] && ok "no spurious heartbeat for row with task file" || fail "spurious requeue for row with task file"

echo ""
echo "4. Stale running row WITH a dispatch heartbeat line → NOT requeued (batch in progress)"
make_dispatch_line() { echo "[$OLD_TS] tend-auto — dispatching \"job with dispatch line\" (20260716-tst) [batch 1]" >> "$1/.orchestrate/logs/heartbeat.log"; }
r="$(run_requeue "| 20260716-tst | job with dispatch line | auto | 1 | running | $OLD_TS |" make_dispatch_line)"
[[ "${r%%|*}" == "running" ]] && ok "row with dispatch line left running" || fail "status='${r%%|*}' (expected running — dispatch line present)"

echo ""
echo "5. Non-running rows are ignored (pending/complete untouched)"
r="$(run_requeue "| 20260716-tst | already pending | auto | 1 | pending | $OLD_TS |")"
[[ "${r%%|*}" == "pending" ]] && ok "pending row left pending (not a running row)" || fail "status='${r%%|*}' (expected pending, untouched)"

echo ""
echo "6. Stale running row, mode: gated → requeued to awaiting_go, NOT pending (20260725-inbox-4C3D)"
r="$(run_requeue "| 20260716-tst | a stale gated job | gated | 1 | running | $OLD_TS |")"
[[ "${r%%|*}" == "awaiting_go" ]] && ok "gated row flipped to awaiting_go (not pending)" || fail "status='${r%%|*}' (expected awaiting_go)"
[[ "$(echo "$r" | cut -d'|' -f2)" -ge 1 ]] && ok "orphaned-row heartbeat written for gated reset" || fail "no orphaned-row heartbeat for gated reset"
[[ "$(echo "$r" | cut -d'|' -f3)" -eq 8 ]] && ok "row stays NF==8" || fail "row NF != 8"

echo ""
echo "7. Churn guard: 3rd orphan requeue parks the row instead of looping forever"
CGTMP="$(mktemp -d)"
mkdir -p "$CGTMP/.orchestrate/tasks" "$CGTMP/.orchestrate/logs" "$CGTMP/.orchestrate/bin" "$CGTMP/.orchestrate/inbox/processed"
CG_SRC="$PROJECT_ROOT/bin/churn-guard.sh"
if [[ -f "$CG_SRC" ]]; then
  cp "$CG_SRC" "$CGTMP/.orchestrate/bin/churn-guard.sh"
  {
    echo "# Orchestrate"
    echo "## Task Registry"
    echo "| ID | summary | mode | current_phase | status | last_activity |"
    echo "|----|---------|------|---------------|--------|---------------|"
    echo "| 20260716-chr | poison orphan job | auto | 1 | running | $OLD_TS |"
  } > "$CGTMP/.orchestrate/project.md"
  # Pre-seed a churn count of 2 so this run is the 3rd re-processing.
  printf '20260716-chr\t2\n' > "$CGTMP/.orchestrate/logs/requeue-counts.tsv"
  bash "$SCRIPT" "$CGTMP" >/dev/null 2>&1 || true
  cg_status="$(grep '20260716-chr' "$CGTMP/.orchestrate/project.md" | awk -F'|' '{gsub(/ /,"",$6); print $6}')"
  cg_parked_hb="$(grep -c 'churn-guard parked 20260716-chr' "$CGTMP/.orchestrate/logs/heartbeat.log" 2>/dev/null || echo 0)"
  [[ "$cg_status" == "needs_human" ]] && ok "3rd re-processing parked to needs_human (not looped back to pending)" || fail "status='$cg_status' (expected needs_human — churn guard not applied)"
  [[ "$cg_parked_hb" -ge 1 ]] && ok "churn-guard park heartbeat written" || fail "no churn-guard park heartbeat"
else
  fail "churn-guard.sh not found at $CG_SRC — cannot exercise churn-guard integration"
fi
rm -rf "$CGTMP"

echo ""
echo "── requeue-orphaned-running: $PASS passed, $FAIL failed ───"
[[ "$FAIL" -eq 0 ]]
