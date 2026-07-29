#!/usr/bin/env bash
# test-detect-orphaned-awaiting-go.sh — regression for task 20260717-inbox-4FA5.
#
# Background: registry row 20260628-inbox-9D5A was dashboard-approved
# (`dashboard — approved go auto gated task 20260628-inbox-9D5A`) on
# 2026-06-29T14:12:25Z but `.orchestrate/tasks/20260628-inbox-9D5A.md` was
# never written — the approval had nothing to execute against. T-4 never
# re-scans `awaiting_go` rows (by design, to avoid re-notification spam), so
# this sat silent for 18 days with 3 dependent needs_human tasks parked on it.
#
# Fix asserted here: detect-orphaned-awaiting-go.sh mirrors
# requeue-orphaned-running.sh's detection shape (approval-line + no-task-file +
# staleness gate) but never auto-requeues to pending — re-executing a gated
# task without a fresh human review would defeat the point of gating. It only
# ever surfaces the row (heartbeat line every cycle + one-time notification).
set -euo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$PROJECT_ROOT/bin" ]] || { echo "FATAL: $PROJECT_ROOT/bin not found — PROJECT_ROOT path computation is broken (expected .../task-orchestrate/bin)" >&2; exit 1; }
SCRIPT="${SCRIPT:-$PROJECT_ROOT/bin/detect-orphaned-awaiting-go.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

OLD_TS="$(date -u -v-20M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '20 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
FRESH_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# run_detect <registry-row> <heartbeat-lines-or-""> -> echoes:
#   <count-of-orphan-detect-heartbeat-lines>|<count-of-notified-sidecar-rows>
run_detect() {
  local row="$1"; local hb_extra="${2:-}"
  local TMP; TMP="$(mktemp -d)"
  mkdir -p "$TMP/.orchestrate/tasks" "$TMP/.orchestrate/logs" "$TMP/.orchestrate/bin"
  {
    echo "# Orchestrate"
    echo "## Task Registry"
    echo "| ID | summary | mode | current_phase | status | last_activity |"
    echo "|----|---------|------|---------------|--------|---------------|"
    echo "$row"
  } > "$TMP/.orchestrate/project.md"
  [[ -n "$hb_extra" ]] && printf '%s\n' "$hb_extra" > "$TMP/.orchestrate/logs/heartbeat.log"
  bash "$SCRIPT" "$TMP" >/dev/null 2>&1 || true
  local orphan_hb notified
  orphan_hb="$(grep -c 'orphan-detect — awaiting_go row 20260717-tst' "$TMP/.orchestrate/logs/heartbeat.log" 2>/dev/null || true)"
  notified="$(grep -c '^20260717-tst' "$TMP/.orchestrate/logs/awaiting-go-orphan-notified.tsv" 2>/dev/null || true)"
  echo "${orphan_hb:-0}|${notified:-0}"
  rm -rf "$TMP"
}

echo ""
echo "── detect-orphaned-awaiting-go (4FA5) — test suite ───"

[[ -f "$SCRIPT" ]] && ok "detect-orphaned-awaiting-go.sh present" || fail "script missing at $SCRIPT"

echo ""
echo "1. Stale approval, no task file → orphan detected + notified"
r="$(run_detect "| 20260717-tst | a gated job | gated | 1 | awaiting_go | $OLD_TS |" \
  "[$OLD_TS] dashboard — approved go auto gated task 20260717-tst \"a gated job\"")"
[[ "$(echo "$r" | cut -d'|' -f1)" -ge 1 ]] && ok "orphan-detect heartbeat written" || fail "no orphan-detect heartbeat (got: $r)"
[[ "$(echo "$r" | cut -d'|' -f2)" -eq 1 ]] && ok "notified sidecar written once" || fail "notified sidecar not written (got: $r)"

echo ""
echo "2. Fresh approval (< 600s), no task file → NOT flagged"
r="$(run_detect "| 20260717-tst | a gated job | gated | 1 | awaiting_go | $FRESH_TS |" \
  "[$FRESH_TS] dashboard — approved go auto gated task 20260717-tst \"a gated job\"")"
[[ "$(echo "$r" | cut -d'|' -f1)" -eq 0 ]] && ok "fresh approval not flagged (staleness gate)" || fail "spuriously flagged fresh approval (got: $r)"

echo ""
echo "3. No approval line at all (never approved) → NOT flagged"
r="$(run_detect "| 20260717-tst | a gated job | gated | 1 | awaiting_go | $OLD_TS |" "")"
[[ "$(echo "$r" | cut -d'|' -f1)" -eq 0 ]] && ok "never-approved row not flagged" || fail "spuriously flagged never-approved row (got: $r)"

echo ""
echo "4. Stale approval WITH a task file already present → NOT flagged (genuinely in progress)"
make_task_file() { printf '# Task\nid: 20260717-tst\n' > "$1/.orchestrate/tasks/20260717-tst.md"; }
TMP4="$(mktemp -d)"
mkdir -p "$TMP4/.orchestrate/tasks" "$TMP4/.orchestrate/logs" "$TMP4/.orchestrate/bin"
{
  echo "# Orchestrate"
  echo "## Task Registry"
  echo "| ID | summary | mode | current_phase | status | last_activity |"
  echo "|----|---------|------|---------------|--------|---------------|"
  echo "| 20260717-tst | a gated job | gated | 1 | awaiting_go | $OLD_TS |"
} > "$TMP4/.orchestrate/project.md"
printf '[%s] dashboard — approved go auto gated task 20260717-tst "a gated job"\n' "$OLD_TS" > "$TMP4/.orchestrate/logs/heartbeat.log"
make_task_file "$TMP4"
bash "$SCRIPT" "$TMP4" >/dev/null 2>&1 || true
hb4="$(grep -c 'orphan-detect — awaiting_go row 20260717-tst' "$TMP4/.orchestrate/logs/heartbeat.log" 2>/dev/null || true)"
hb4="${hb4:-0}"
[[ "$hb4" -eq 0 ]] && ok "row with task file not flagged" || fail "spuriously flagged row with task file present"
rm -rf "$TMP4"

echo ""
echo "5. Repeated runs against the same orphan → heartbeat fires every cycle, notification only once"
TMP5="$(mktemp -d)"
mkdir -p "$TMP5/.orchestrate/tasks" "$TMP5/.orchestrate/logs" "$TMP5/.orchestrate/bin"
{
  echo "# Orchestrate"
  echo "## Task Registry"
  echo "| ID | summary | mode | current_phase | status | last_activity |"
  echo "|----|---------|------|---------------|--------|---------------|"
  echo "| 20260717-tst | a gated job | gated | 1 | awaiting_go | $OLD_TS |"
} > "$TMP5/.orchestrate/project.md"
printf '[%s] dashboard — approved go auto gated task 20260717-tst "a gated job"\n' "$OLD_TS" > "$TMP5/.orchestrate/logs/heartbeat.log"
bash "$SCRIPT" "$TMP5" >/dev/null 2>&1 || true
bash "$SCRIPT" "$TMP5" >/dev/null 2>&1 || true
bash "$SCRIPT" "$TMP5" >/dev/null 2>&1 || true
hb5="$(grep -c 'orphan-detect — awaiting_go row 20260717-tst' "$TMP5/.orchestrate/logs/heartbeat.log" 2>/dev/null || true)"
notified5="$(grep -c '^20260717-tst' "$TMP5/.orchestrate/logs/awaiting-go-orphan-notified.tsv" 2>/dev/null || true)"
hb5="${hb5:-0}"; notified5="${notified5:-0}"
[[ "$hb5" -eq 3 ]] && ok "heartbeat fires every cycle (3/3)" || fail "expected 3 heartbeat lines, got $hb5"
[[ "$notified5" -eq 1 ]] && ok "notification sidecar deduped to 1 row" || fail "expected 1 notified row, got $notified5"
rm -rf "$TMP5"

echo ""
echo "6. Regex false-match guard: row ID is a prefix of a DIFFERENT approved ID → NOT flagged"
# Regression for a real bug found during coverage review: the approval-line
# regex used a bare \b terminator after \${row_id}. Since '-' is a non-word
# char, \b fires at the ID/hyphen boundary, so row "20260717-tst" would
# spuriously match an approval line actually written for "20260717-tst-other"
# (this codebase's own follow-up ticket IDs are literally
# "<parent-id>-tests" / "<parent-id>-review-XXXX", so this is not
# hypothetical). Fixed by requiring whitespace/quote/EOL after the ID.
r="$(run_detect "| 20260717-tst | short id job | gated | 1 | awaiting_go | $OLD_TS |" \
  "[$OLD_TS] dashboard — approved go auto gated task 20260717-tst-other \"other job\"")"
[[ "$(echo "$r" | cut -d'|' -f1)" -eq 0 ]] && ok "prefix-ID row not falsely matched by a longer ID's approval line" || fail "substring false-match regression (got: $r)"
[[ "$(echo "$r" | cut -d'|' -f2)" -eq 0 ]] && ok "no false notification for prefix-ID row" || fail "spurious notification for prefix-ID row (got: $r)"

echo ""
echo "7. Alternate approval-line formats (interactive, not dashboard) are also detected"
r="$(run_detect "| 20260717-tst | a gated job | gated | 1 | awaiting_go | $OLD_TS |" \
  "[$OLD_TS] go auto 20260717-tst")"
[[ "$(echo "$r" | cut -d'|' -f1)" -ge 1 ]] && ok "'go auto {ID}' interactive approval format detected" || fail "'go auto {ID}' format not detected (got: $r)"
r="$(run_detect "| 20260717-tst | a gated job | gated | 1 | awaiting_go | $OLD_TS |" \
  "[$OLD_TS] go 20260717-tst")"
[[ "$(echo "$r" | cut -d'|' -f1)" -ge 1 ]] && ok "bare 'go {ID}' interactive approval format detected" || fail "bare 'go {ID}' format not detected (got: $r)"

echo ""
echo "8. ORPHAN_AWAITING_GO_STALE_SECS env override is respected"
TS30S="$(date -u -v-30S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 seconds ago' +%Y-%m-%dT%H:%M:%SZ)"
TMP8="$(mktemp -d)"
mkdir -p "$TMP8/.orchestrate/tasks" "$TMP8/.orchestrate/logs" "$TMP8/.orchestrate/bin"
{
  echo "# Orchestrate"
  echo "## Task Registry"
  echo "| ID | summary | mode | current_phase | status | last_activity |"
  echo "|----|---------|------|---------------|--------|---------------|"
  echo "| 20260717-tst | a gated job | gated | 1 | awaiting_go | $TS30S |"
} > "$TMP8/.orchestrate/project.md"
printf '[%s] dashboard — approved go auto gated task 20260717-tst "a gated job"\n' "$TS30S" > "$TMP8/.orchestrate/logs/heartbeat.log"
bash "$SCRIPT" "$TMP8" >/dev/null 2>&1 || true
hb8_default="$(grep -c 'orphan-detect — awaiting_go row 20260717-tst' "$TMP8/.orchestrate/logs/heartbeat.log" 2>/dev/null || true)"
hb8_default="${hb8_default:-0}"
[[ "$hb8_default" -eq 0 ]] && ok "30s-old approval NOT flagged under default 600s gate" || fail "expected 0 heartbeat lines under default gate, got $hb8_default"
ORPHAN_AWAITING_GO_STALE_SECS=10 bash "$SCRIPT" "$TMP8" >/dev/null 2>&1 || true
hb8_override="$(grep -c 'orphan-detect — awaiting_go row 20260717-tst' "$TMP8/.orchestrate/logs/heartbeat.log" 2>/dev/null || true)"
hb8_override="${hb8_override:-0}"
[[ "$hb8_override" -ge 1 ]] && ok "same 30s-old approval IS flagged once ORPHAN_AWAITING_GO_STALE_SECS=10 override applied" || fail "override not respected (got $hb8_override)"
rm -rf "$TMP8"

echo ""
echo "── Results: $PASS passed, $FAIL failed ───"
[[ $FAIL -eq 0 ]]
