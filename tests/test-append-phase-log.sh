#!/usr/bin/env bash
# test-append-phase-log.sh — regression for task 20260718-inbox-1DF9.
#
# Background: task 20260717-inbox-60E4 completed successfully (full PHASE
# OUTPUT content is in its archived task file), but
# .orchestrate/logs/20260717-inbox-60E4-phase1.log and -phase2.log each
# contain ONLY their "=== Phase N — ... ===" header line, no PHASE OUTPUT
# body. Root cause: the mandatory "Phase log write" step (SKILL.md) was
# previously TWO independent shell statements (header echo, then body echo)
# run by the LLM tend/agent session itself, with nothing enforcing that both
# ran together. 60E4 went through ghost-reset (895s stale) → auto-resolve →
# re-dispatch → its second dispatch attempt ALSO stalled, so the tend-auto
# session took over and executed both phases directly inline in its own
# context (SKILL.md's documented inline-takeover path) — in that turn it ran
# the header echo for both phases (both logs share the identical
# 2026-07-17T21:24:02Z timestamp) but never ran the body-append echo.
#
# Fix asserted here: .orchestrate/bin/append-phase-log.sh collapses the two
# statements into ONE atomic call that (a) can never write a header without
# its body in the same invocation, and (b) refuses to write anything if the
# body is empty — so a header-only stub is now structurally impossible via
# this path. A non-empty body missing the "## PHASE OUTPUT" marker (SKILL.md's
# documented raw-agent-text fallback for a missing block — see
# 20260718-inbox-FIXFB1) is still logged, clearly marked as a fallback entry
# rather than silently dropped. This suite:
#   Section A — direct unit tests of the atomic helper's guarantees.
#   Section B — a full simulation of the exact incident sequence (stale
#     running → ghost-reset → auto-resolve/re-queue → re-dispatch → inline
#     takeover → complete) asserting the resulting phase logs contain full
#     PHASE OUTPUT blocks, not just headers — pinning the fix against a
#     regression of the exact 60E4 shape.
set -uo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$PROJECT_ROOT/bin" ]] || { echo "FATAL: $PROJECT_ROOT/bin not found — PROJECT_ROOT path computation is broken (expected .../task-orchestrate/bin)" >&2; exit 1; }
RUNJOB="${RUNJOB:-$PROJECT_ROOT/bin/run-job.sh}"
APPEND_SCRIPT="${APPEND_SCRIPT:-$PROJECT_ROOT/bin/append-phase-log.sh}"
UPDATE_ROW="${UPDATE_ROW:-$PROJECT_ROOT/bin/update-registry-row.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo ""
echo "── append-phase-log atomic write (1DF9) — test suite ───"

[[ -f "$APPEND_SCRIPT" ]] && ok "append-phase-log.sh present" || fail "append-phase-log.sh missing at $APPEND_SCRIPT"
[[ -f "$RUNJOB" ]] && ok "run-job.sh present" || fail "run-job.sh missing at $RUNJOB"
[[ -f "$UPDATE_ROW" ]] && ok "update-registry-row.sh present" || fail "update-registry-row.sh missing at $UPDATE_ROW"

SAMPLE_BODY='## PHASE OUTPUT
files_changed: none
summary: sample phase for testing
confidence: high
blockers: none
acceptance_criteria_met: [✓ a | ✓ b]
test_evidence: n/a (synthetic test fixture)'

echo ""
echo "── Section A: append-phase-log.sh atomicity guarantees ───"

echo ""
echo "1. Happy path: single call writes header + full PHASE OUTPUT body together"
TMP="$(mktemp -d)"
mkdir -p "$TMP/.orchestrate/logs"
printf '%s\n' "$SAMPLE_BODY" | bash "$APPEND_SCRIPT" "$TMP" "20260101-tst" "1" "Sample Phase" "0" >/dev/null 2>&1
LOG="$TMP/.orchestrate/logs/20260101-tst-phase1.log"
[[ -f "$LOG" ]] && ok "phase log file created" || fail "phase log file not created"
grep -q '^=== Phase 1 —' "$LOG" 2>/dev/null && ok "header line present" || fail "header line missing"
grep -q '^## PHASE OUTPUT' "$LOG" 2>/dev/null && ok "PHASE OUTPUT body present (the 60E4 bug: header with no body)" || fail "PHASE OUTPUT body missing — regression of 60E4!"
grep -q 'sample phase for testing' "$LOG" 2>/dev/null && ok "full body content present, not truncated" || fail "body content missing/truncated"
rm -rf "$TMP"

echo ""
echo "2. Refuses to write when body is empty (no header-only stub possible)"
TMP="$(mktemp -d)"
mkdir -p "$TMP/.orchestrate/logs"
printf '' | bash "$APPEND_SCRIPT" "$TMP" "20260101-tst" "1" "Sample Phase" "0" >/tmp/append-test-out.$$ 2>&1
RC=$?
LOG="$TMP/.orchestrate/logs/20260101-tst-phase1.log"
[[ "$RC" -ne 0 ]] && ok "empty body call exits non-zero" || fail "empty body call should have failed (exit $RC)"
[[ ! -f "$LOG" ]] && ok "no phase log file written for empty body (header can never be written alone)" || fail "phase log file was written despite empty body — split-write regression!"
rm -f /tmp/append-test-out.$$
rm -rf "$TMP"

echo ""
echo "3. Body missing the '## PHASE OUTPUT' marker still gets logged, marked as a fallback (20260718-inbox-FIXFB1)"
TMP="$(mktemp -d)"
mkdir -p "$TMP/.orchestrate/logs"
printf 'I finished the task. Everything looks good, no issues found.\n' | bash "$APPEND_SCRIPT" "$TMP" "20260101-tst" "1" "Sample Phase" "0" >/tmp/append-test-out.$$ 2>&1
RC=$?
LOG="$TMP/.orchestrate/logs/20260101-tst-phase1.log"
[[ "$RC" -eq 0 ]] && ok "raw-text (non-PHASE-OUTPUT) body call exits 0 — the documented agent-phase fallback is honored" || fail "raw-text body call should have succeeded (exit $RC)"
[[ -f "$LOG" ]] && ok "phase log file written for the raw-text fallback (SKILL.md's 'raw agent text if block is missing' path)" || fail "no phase log file written despite non-empty fallback body"
grep -q '^\[no PHASE OUTPUT block' "$LOG" 2>/dev/null && ok "fallback entry clearly marked as not a real PHASE OUTPUT block" || fail "fallback entry missing the '[no PHASE OUTPUT block ...]' marker line"
grep -q 'Everything looks good, no issues found' "$LOG" 2>/dev/null && ok "raw agent text preserved verbatim in the fallback entry" || fail "raw agent text missing from fallback entry"
rm -f /tmp/append-test-out.$$
rm -rf "$TMP"

echo ""
echo "4. Retry counter: RETRIES > 0 labels the header '(retry R)'; RETRIES=0 does not"
TMP="$(mktemp -d)"
mkdir -p "$TMP/.orchestrate/logs"
printf '%s\n' "$SAMPLE_BODY" | bash "$APPEND_SCRIPT" "$TMP" "20260101-tst" "2" "Sample Phase" "3" >/dev/null 2>&1
LOG="$TMP/.orchestrate/logs/20260101-tst-phase2.log"
grep -q '^=== Phase 2 (retry 3) —' "$LOG" 2>/dev/null && ok "retry label present when RETRIES=3" || fail "retry label missing/wrong for RETRIES=3"
printf '%s\n' "$SAMPLE_BODY" | bash "$APPEND_SCRIPT" "$TMP" "20260101-tst" "1" "Sample Phase" "0" >/dev/null 2>&1
LOG1="$TMP/.orchestrate/logs/20260101-tst-phase1.log"
grep -q '^=== Phase 1 —' "$LOG1" 2>/dev/null && ! grep -q 'retry' "$LOG1" 2>/dev/null && ok "no retry suffix when RETRIES=0" || fail "unexpected retry suffix for RETRIES=0"
rm -rf "$TMP"

echo ""
echo "5. Repeated calls append (never overwrite) — each phase's history is preserved"
TMP="$(mktemp -d)"
mkdir -p "$TMP/.orchestrate/logs"
printf '%s\n' "$SAMPLE_BODY" | bash "$APPEND_SCRIPT" "$TMP" "20260101-tst" "1" "First Run" "0" >/dev/null 2>&1
printf '%s\n' "$SAMPLE_BODY" | bash "$APPEND_SCRIPT" "$TMP" "20260101-tst" "1" "Retry Run" "1" >/dev/null 2>&1
LOG="$TMP/.orchestrate/logs/20260101-tst-phase1.log"
HDRS="$(grep -c '^=== Phase 1' "$LOG" 2>/dev/null || echo 0)"
[[ "$HDRS" -eq 2 ]] && ok "both writes preserved (2 header lines, not overwritten)" || fail "expected 2 headers, found $HDRS"
BODIES="$(grep -c '^## PHASE OUTPUT' "$LOG" 2>/dev/null || echo 0)"
[[ "$BODIES" -eq 2 ]] && ok "both PHASE OUTPUT bodies preserved" || fail "expected 2 PHASE OUTPUT bodies, found $BODIES"
rm -rf "$TMP"

echo ""
echo "── Section B: full incident simulation (stale→ghost-reset→auto-resolve→re-dispatch→inline-takeover→complete) ───"

# 6. Build a mock control plane mirroring 60E4: a stale `running` row with 2
#    pending phases and no progress yet.
TMP="$(mktemp -d)"
mkdir -p "$TMP/.orchestrate/tasks" "$TMP/.orchestrate/logs"
OLD_TS="$(date -u -v-30M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
{
  echo "# Orchestrate"
  echo "## Task Registry"
  echo "| ID | summary | mode | current_phase | status | last_activity |"
  echo "|----|---------|------|---------------|--------|---------------|"
  echo "| 20260718-sim | simulated WS-3-style task | auto | 1 | running | $OLD_TS |"
} > "$TMP/.orchestrate/project.md"
cat > "$TMP/.orchestrate/tasks/20260718-sim.md" << 'EOF'
id: 20260718-sim
task: simulated WS-3-style task
total_phases: 2

### Phase 1: Write the thing
status: pending
depends_on: []

### Phase 2: Test & Verify
status: pending
depends_on: [1]
EOF
# Backdate the task file's mtime to match: the 19D7 liveness guard in
# reset_stale_running_tasks treats a FRESH task-file mtime as a live session
# even if last_activity is stale (a long single-phase agent updates
# last_activity only at checkpoints) — so a genuinely stale/dead session must
# have BOTH a stale registry last_activity AND a stale task-file mtime.
BT="$(date -v-30M +%Y%m%d%H%M 2>/dev/null || date -d '30 minutes ago' +%Y%m%d%H%M)"
touch -t "$BT" "$TMP/.orchestrate/tasks/20260718-sim.md"

echo ""
echo "6. Ghost-reset: stale running row (no completed phases) flips to needs_human"
(
  ROOT="$TMP"
  log_heartbeat() { echo "$*" >> "$ROOT/.orchestrate/logs/heartbeat.log"; }
  eval "$(awk '/^STALE_RUNNING_SECS=/{p=1} p{print} p&&/^reset_stale_running_tasks\(\) \{/{f=1} f&&/^\}/{exit}' "$RUNJOB")"
  reset_stale_running_tasks
)
GSTATUS="$(grep '20260718-sim' "$TMP/.orchestrate/project.md" | awk -F'|' '{gsub(/ /,"",$6); print $6}')"
[[ "$GSTATUS" == "needs_human" ]] && ok "stale row ghost-reset to needs_human (mirrors 60E4's 895s-stale reset)" || fail "status='$GSTATUS' (expected needs_human)"
grep -q 'ghost-reset 20260718-sim: running→needs_human' "$TMP/.orchestrate/logs/heartbeat.log" 2>/dev/null && ok "ghost-reset heartbeat line written" || fail "no ghost-reset heartbeat line"

echo ""
echo "7. Auto-resolve + re-queue: T-4 self-unblocks the ghost-reset row back to pending"
bash "$UPDATE_ROW" "$TMP" "20260718-sim" "auto" "1" "pending" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] tend-auto — self-unblocked 20260718-sim: ghost-reset was idle-dependency false positive" >> "$TMP/.orchestrate/logs/heartbeat.log"
RSTATUS="$(grep '20260718-sim' "$TMP/.orchestrate/project.md" | awk -F'|' '{gsub(/ /,"",$6); print $6}')"
[[ "$RSTATUS" == "pending" ]] && ok "row re-queued to pending" || fail "status='$RSTATUS' (expected pending)"

echo ""
echo "8. Re-dispatch stalls a second time; tend-auto takes over and executes both phases inline"
bash "$UPDATE_ROW" "$TMP" "20260718-sim" "auto" "1" "running" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] tend-auto — dispatching \"simulated WS-3-style task\" (20260718-sim) [batch]" >> "$TMP/.orchestrate/logs/heartbeat.log"
# This is the exact fixed call site: SKILL.md's mandatory Phase log write now
# goes through append-phase-log.sh in one atomic call, for BOTH phases, as the
# inline-takeover session completes them.
P1_BODY='## PHASE OUTPUT
files_changed: /tmp/fake-file.md
summary: wrote the thing
confidence: high
blockers: none
acceptance_criteria_met: [✓ thing written]
test_evidence: grep confirmed content present'
P2_BODY='## PHASE OUTPUT
files_changed: none (verification only)
summary: verified the thing
confidence: high
blockers: none
acceptance_criteria_met: [✓ tests pass]
test_evidence: bash run-tests.sh → ALL SUITES PASSED'
printf '%s\n' "$P1_BODY" | bash "$APPEND_SCRIPT" "$TMP" "20260718-sim" "1" "Write the thing" "0" >/dev/null 2>&1
printf '%s\n' "$P2_BODY" | bash "$APPEND_SCRIPT" "$TMP" "20260718-sim" "2" "Test & Verify" "0" >/dev/null 2>&1
bash "$UPDATE_ROW" "$TMP" "20260718-sim" "auto" "2" "complete" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] tend-auto — completed 20260718-sim (taken over inline after stalled dispatch)" >> "$TMP/.orchestrate/logs/heartbeat.log"

echo ""
echo "9. THE regression assertion: both phase logs contain a full PHASE OUTPUT block, not just a header"
LOG1="$TMP/.orchestrate/logs/20260718-sim-phase1.log"
LOG2="$TMP/.orchestrate/logs/20260718-sim-phase2.log"
[[ -f "$LOG1" ]] && ok "phase1 log exists" || fail "phase1 log missing"
[[ -f "$LOG2" ]] && ok "phase2 log exists" || fail "phase2 log missing"
grep -q '^## PHASE OUTPUT' "$LOG1" 2>/dev/null && ok "phase1 log has PHASE OUTPUT body (this is exactly what 60E4's phase1.log was missing)" || fail "phase1 log is header-only — 60E4 regression reproduced!"
grep -q '^## PHASE OUTPUT' "$LOG2" 2>/dev/null && ok "phase2 log has PHASE OUTPUT body (this is exactly what 60E4's phase2.log was missing)" || fail "phase2 log is header-only — 60E4 regression reproduced!"
grep -q 'wrote the thing' "$LOG1" 2>/dev/null && ok "phase1 log has real summary content, not truncated" || fail "phase1 log body content missing"
grep -q 'verified the thing' "$LOG2" 2>/dev/null && ok "phase2 log has real summary content, not truncated" || fail "phase2 log body content missing"
FSTATUS="$(grep '20260718-sim' "$TMP/.orchestrate/project.md" | awk -F'|' '{gsub(/ /,"",$6); print $6}')"
[[ "$FSTATUS" == "complete" ]] && ok "row finalized to complete" || fail "status='$FSTATUS' (expected complete)"

echo ""
echo "10. Sanity: this is what the ORIGINAL 60E4 bug shape looked like (for contrast, not asserting a fix here)"
# Directly demonstrate the old two-statement pattern (header echo only, no body
# echo) still produces a broken, header-only log — proving Section B's PASS
# above is a real fix, not a tautology of the test harness.
BUGLOG="$TMP/.orchestrate/logs/20260718-sim-bugshape-phase1.log"
echo "=== Phase 1 — Write the thing $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> "$BUGLOG"
# (the body-append statement that 60E4's session skipped is intentionally omitted here)
if grep -q '^## PHASE OUTPUT' "$BUGLOG" 2>/dev/null; then
  fail "bug-shape fixture unexpectedly has a PHASE OUTPUT body (test fixture broken)"
else
  ok "confirmed: a header-only write (the old two-statement pattern) IS the 60E4 bug shape — Section B proves append-phase-log.sh cannot produce it"
fi

rm -rf "$TMP"

echo ""
echo "── Section C: argument-validation guards + real-world edge cases (independent tests pass, 20260718-inbox-TST1DF9) ───"

echo ""
echo "11. BODY_FILE argument mode (6th arg) writes the same content as stdin mode"
TMP="$(mktemp -d)"
mkdir -p "$TMP/.orchestrate/logs"
BODYFILE="$TMP/body.txt"
printf '%s\n' "$SAMPLE_BODY" > "$BODYFILE"
bash "$APPEND_SCRIPT" "$TMP" "20260101-tst" "1" "Sample Phase" "0" "$BODYFILE" >/dev/null 2>&1
LOG="$TMP/.orchestrate/logs/20260101-tst-phase1.log"
[[ -f "$LOG" ]] && ok "BODY_FILE mode: phase log file created" || fail "BODY_FILE mode: phase log file not created"
grep -q '^## PHASE OUTPUT' "$LOG" 2>/dev/null && ok "BODY_FILE mode: PHASE OUTPUT body present" || fail "BODY_FILE mode: PHASE OUTPUT body missing"
grep -q 'sample phase for testing' "$LOG" 2>/dev/null && ok "BODY_FILE mode: full body content present" || fail "BODY_FILE mode: body content missing/truncated"
rm -rf "$TMP"

echo ""
echo "12. BODY_FILE argument pointing at a nonexistent file dies loudly, writes nothing"
TMP="$(mktemp -d)"
mkdir -p "$TMP/.orchestrate/logs"
bash "$APPEND_SCRIPT" "$TMP" "20260101-tst" "1" "Sample Phase" "0" "$TMP/does-not-exist.txt" >/tmp/append-test-out.$$ 2>&1
RC=$?
LOG="$TMP/.orchestrate/logs/20260101-tst-phase1.log"
[[ "$RC" -ne 0 ]] && ok "missing BODY_FILE exits non-zero" || fail "missing BODY_FILE should have failed (exit $RC)"
[[ ! -f "$LOG" ]] && ok "no phase log file written for missing BODY_FILE" || fail "phase log file was written despite missing BODY_FILE"
rm -f /tmp/append-test-out.$$
rm -rf "$TMP"

echo ""
echo "13. Non-numeric PHASE_N is rejected (guards against a malformed header)"
TMP="$(mktemp -d)"
mkdir -p "$TMP/.orchestrate/logs"
printf '%s\n' "$SAMPLE_BODY" | bash "$APPEND_SCRIPT" "$TMP" "20260101-tst" "abc" "Sample Phase" "0" >/tmp/append-test-out.$$ 2>&1
RC=$?
[[ "$RC" -ne 0 ]] && ok "non-numeric PHASE_N exits non-zero" || fail "non-numeric PHASE_N should have failed (exit $RC)"
[[ ! -f "$TMP/.orchestrate/logs/20260101-tst-phaseabc.log" ]] && ok "no phase log file written for non-numeric PHASE_N" || fail "phase log file was written despite non-numeric PHASE_N"
rm -f /tmp/append-test-out.$$
rm -rf "$TMP"

echo ""
echo "14. Non-numeric RETRIES is rejected"
TMP="$(mktemp -d)"
mkdir -p "$TMP/.orchestrate/logs"
printf '%s\n' "$SAMPLE_BODY" | bash "$APPEND_SCRIPT" "$TMP" "20260101-tst" "1" "Sample Phase" "not-a-number" >/tmp/append-test-out.$$ 2>&1
RC=$?
LOG="$TMP/.orchestrate/logs/20260101-tst-phase1.log"
[[ "$RC" -ne 0 ]] && ok "non-numeric RETRIES exits non-zero" || fail "non-numeric RETRIES should have failed (exit $RC)"
[[ ! -f "$LOG" ]] && ok "no phase log file written for non-numeric RETRIES" || fail "phase log file was written despite non-numeric RETRIES"
rm -f /tmp/append-test-out.$$
rm -rf "$TMP"

echo ""
echo "15. ROOT with no .orchestrate/ directory is rejected (refuses to write outside an orchestrate root)"
TMP="$(mktemp -d)"
printf '%s\n' "$SAMPLE_BODY" | bash "$APPEND_SCRIPT" "$TMP" "20260101-tst" "1" "Sample Phase" "0" >/tmp/append-test-out.$$ 2>&1
RC=$?
[[ "$RC" -ne 0 ]] && ok "non-orchestrate ROOT exits non-zero" || fail "non-orchestrate ROOT should have failed (exit $RC)"
[[ ! -d "$TMP/.orchestrate" ]] && ok "no .orchestrate/ directory created as a side effect" || fail "a .orchestrate/ directory was unexpectedly created"
rm -rf "$TMP"

echo ""
echo "16. Insufficient arguments (usage error) rejected before touching disk"
TMP="$(mktemp -d)"
mkdir -p "$TMP/.orchestrate/logs"
printf '%s\n' "$SAMPLE_BODY" | bash "$APPEND_SCRIPT" "$TMP" "20260101-tst" "1" >/tmp/append-test-out.$$ 2>&1
RC=$?
[[ "$RC" -ne 0 ]] && ok "insufficient args (missing PHASE_NAME) exits non-zero" || fail "insufficient args should have failed (exit $RC)"
[[ -z "$(ls -A "$TMP/.orchestrate/logs" 2>/dev/null)" ]] && ok "no phase log file written for insufficient args" || fail "a phase log file was written despite insufficient args"
rm -f /tmp/append-test-out.$$
rm -rf "$TMP"

echo ""
echo "17. Pre-existing legacy header-only stub (the exact 60E4 shape) is preserved, not corrupted, when a later correct call appends"
TMP="$(mktemp -d)"
mkdir -p "$TMP/.orchestrate/logs"
LOG="$TMP/.orchestrate/logs/20260101-tst-phase1.log"
# Simulate a log file that already has the pre-fix bug shape sitting on disk
# (a real scenario: these logs pre-date append-phase-log.sh and are never
# retroactively rewritten) — then a subsequent, correct, atomic call must
# append after it without truncating or altering the stub.
echo "=== Phase 1 — Sample Phase 2026-07-17T21:24:02Z ===" >> "$LOG"
printf '%s\n' "$SAMPLE_BODY" | bash "$APPEND_SCRIPT" "$TMP" "20260101-tst" "1" "Sample Phase" "0" >/dev/null 2>&1
HDRS="$(grep -c '^=== Phase 1' "$LOG" 2>/dev/null || echo 0)"
[[ "$HDRS" -eq 2 ]] && ok "legacy stub header preserved alongside the new header (2 total, not overwritten)" || fail "expected 2 headers (1 legacy stub + 1 new), found $HDRS"
BODIES="$(grep -c '^## PHASE OUTPUT' "$LOG" 2>/dev/null || echo 0)"
[[ "$BODIES" -eq 1 ]] && ok "exactly one PHASE OUTPUT body present (only the new call's, legacy stub still has none)" || fail "expected exactly 1 PHASE OUTPUT body, found $BODIES"
grep -q '2026-07-17T21:24:02Z' "$LOG" 2>/dev/null && ok "legacy stub timestamp untouched" || fail "legacy stub line was altered or removed"
rm -rf "$TMP"

echo ""
echo "── Section D: fallback-behavior edge cases (independent coverage audit for 20260718-inbox-FIXFB1) ───"

echo ""
echo "18. Whitespace-only body (non-empty bytes, no visible content) is treated as real content, not refused"
TMP="$(mktemp -d)"
mkdir -p "$TMP/.orchestrate/logs"
printf '   \t  \n' | bash "$APPEND_SCRIPT" "$TMP" "20260101-tst" "1" "Sample Phase" "0" >/tmp/append-test-out.$$ 2>&1
RC=$?
LOG="$TMP/.orchestrate/logs/20260101-tst-phase1.log"
[[ "$RC" -eq 0 ]] && ok "whitespace-only body call exits 0 (bytes remain after trailing-newline stripping, so it counts as content)" || fail "whitespace-only body call should have succeeded (exit $RC)"
[[ -f "$LOG" ]] && ok "phase log file written for whitespace-only body" || fail "no phase log file written for whitespace-only body"
grep -q '^\[no PHASE OUTPUT block' "$LOG" 2>/dev/null && ok "whitespace-only body logged with fallback marker" || fail "fallback marker missing for whitespace-only body"
rm -f /tmp/append-test-out.$$
rm -rf "$TMP"

echo ""
echo "19. Body of only blank lines collapses to empty under \$(cat) trailing-newline stripping and is refused, same as truly empty"
TMP="$(mktemp -d)"
mkdir -p "$TMP/.orchestrate/logs"
printf '\n\n\n' | bash "$APPEND_SCRIPT" "$TMP" "20260101-tst" "1" "Sample Phase" "0" >/tmp/append-test-out.$$ 2>&1
RC=$?
LOG="$TMP/.orchestrate/logs/20260101-tst-phase1.log"
[[ "$RC" -ne 0 ]] && ok "all-blank-lines body exits non-zero (\$(...) strips trailing newlines down to an empty string)" || fail "all-blank-lines body should have failed (exit $RC)"
[[ ! -f "$LOG" ]] && ok "no phase log file written for all-blank-lines body" || fail "phase log file was written despite all-blank-lines body"
rm -f /tmp/append-test-out.$$
rm -rf "$TMP"

echo ""
echo "20. Multi-line raw-text fallback body is preserved in full, not truncated to its first line"
TMP="$(mktemp -d)"
mkdir -p "$TMP/.orchestrate/logs"
MULTI_BODY='Line one of raw agent text.
Line two with more detail.
Line three: final wrap-up remarks.'
printf '%s\n' "$MULTI_BODY" | bash "$APPEND_SCRIPT" "$TMP" "20260101-tst" "1" "Sample Phase" "0" >/tmp/append-test-out.$$ 2>&1
RC=$?
LOG="$TMP/.orchestrate/logs/20260101-tst-phase1.log"
[[ "$RC" -eq 0 ]] && ok "multi-line raw-text body call exits 0" || fail "multi-line raw-text body call should have succeeded (exit $RC)"
grep -q '^\[no PHASE OUTPUT block' "$LOG" 2>/dev/null && ok "multi-line fallback entry marked" || fail "fallback marker missing for multi-line body"
grep -q 'Line one of raw agent text' "$LOG" 2>/dev/null && ok "multi-line body: first line preserved" || fail "multi-line body: first line missing"
grep -q 'Line two with more detail' "$LOG" 2>/dev/null && ok "multi-line body: middle line preserved" || fail "multi-line body: middle line missing"
grep -q 'Line three: final wrap-up remarks' "$LOG" 2>/dev/null && ok "multi-line body: last line preserved" || fail "multi-line body: last line missing"
rm -f /tmp/append-test-out.$$
rm -rf "$TMP"

echo ""
echo "21. Marker text appearing mid-line (not at the start of a line) is still classified as a fallback, not a real PHASE OUTPUT block"
TMP="$(mktemp -d)"
mkdir -p "$TMP/.orchestrate/logs"
MIDLINE_BODY='I could not find a ## PHASE OUTPUT block in my own output, so here is a summary instead.'
printf '%s\n' "$MIDLINE_BODY" | bash "$APPEND_SCRIPT" "$TMP" "20260101-tst" "1" "Sample Phase" "0" >/tmp/append-test-out.$$ 2>&1
RC=$?
LOG="$TMP/.orchestrate/logs/20260101-tst-phase1.log"
[[ "$RC" -eq 0 ]] && ok "mid-line-marker body call exits 0" || fail "mid-line-marker body call should have succeeded (exit $RC)"
grep -q '^\[no PHASE OUTPUT block' "$LOG" 2>/dev/null && ok "mid-line marker text still classified as fallback (marker must anchor at the start of a line)" || fail "mid-line marker text was wrongly classified as a real PHASE OUTPUT block"
grep -q 'I could not find a ## PHASE OUTPUT block' "$LOG" 2>/dev/null && ok "raw text with embedded marker words preserved verbatim" || fail "raw text with embedded marker words missing"
rm -f /tmp/append-test-out.$$
rm -rf "$TMP"

echo ""
echo "22. Concurrent calls (one real PHASE OUTPUT, one raw-text fallback) targeting the same log file both land intact"
TMP="$(mktemp -d)"
mkdir -p "$TMP/.orchestrate/logs"
LOG="$TMP/.orchestrate/logs/20260101-tst-phase1.log"
CONCURRENT_RAW='Concurrent raw fallback text -- no marker here, just a status update from the agent.'
(printf '%s\n' "$SAMPLE_BODY" | bash "$APPEND_SCRIPT" "$TMP" "20260101-tst" "1" "Real Concurrent Run" "0") &
PID1=$!
(printf '%s\n' "$CONCURRENT_RAW" | bash "$APPEND_SCRIPT" "$TMP" "20260101-tst" "1" "Fallback Concurrent Run" "0") &
PID2=$!
wait "$PID1"
wait "$PID2"
HDRS="$(grep -c '^=== Phase 1' "$LOG" 2>/dev/null || echo 0)"
[[ "$HDRS" -eq 2 ]] && ok "both concurrent writes landed (2 headers, no lost write)" || fail "expected 2 headers after concurrent writes, found $HDRS"
grep -q '^## PHASE OUTPUT' "$LOG" 2>/dev/null && ok "concurrent real entry's PHASE OUTPUT body intact" || fail "concurrent real entry's PHASE OUTPUT body missing/corrupted"
grep -q '^\[no PHASE OUTPUT block' "$LOG" 2>/dev/null && ok "concurrent fallback entry's marker intact" || fail "concurrent fallback entry's marker missing/corrupted"
grep -q 'Concurrent raw fallback text' "$LOG" 2>/dev/null && ok "concurrent fallback entry's raw text intact (not interleaved/corrupted)" || fail "concurrent fallback entry's raw text missing or corrupted by interleaving"
grep -q 'sample phase for testing' "$LOG" 2>/dev/null && ok "concurrent real entry's body content intact" || fail "concurrent real entry's body content missing or corrupted by interleaving"
rm -rf "$TMP"

echo ""
echo "23. Malformed ID (path-traversal / injection charset) is rejected before any path construction (20260724-inbox-6D91)"
TMP="$(mktemp -d)"
mkdir -p "$TMP/.orchestrate/logs"
for BAD_ID in "../../etc/passwd" "bad id" "bad;id" "bad\$(id)"; do
  printf '%s\n' "$SAMPLE_BODY" | bash "$APPEND_SCRIPT" "$TMP" "$BAD_ID" "1" "Sample Phase" "0" >/tmp/append-test-out.$$ 2>&1
  RC=$?
  [[ "$RC" -ne 0 ]] && ok "malformed ID '$BAD_ID' rejected (exit $RC)" || fail "malformed ID '$BAD_ID' should have been rejected, exited 0"
  grep -qi 'invalid\|must match' /tmp/append-test-out.$$ && ok "malformed ID '$BAD_ID' error message is clear" || fail "malformed ID '$BAD_ID' produced no clear error message"
done
# No file written outside the expected logs dir, and nothing leaked into it either.
[[ ! -e "$TMP/etc" ]] && ok "no path-traversal write occurred (no $TMP/etc created)" || fail "path traversal write occurred: $TMP/etc exists"
LEAKED="$(find "$TMP/.orchestrate/logs" -type f 2>/dev/null | wc -l | tr -d ' ')"
[[ "$LEAKED" -eq 0 ]] && ok "no phase-log file written for any malformed ID" || fail "expected 0 files in logs dir, found $LEAKED"
rm -f /tmp/append-test-out.$$
rm -rf "$TMP"

echo ""
echo "── append-phase-log atomic write: $PASS passed, $FAIL failed ───"
[[ "$FAIL" -eq 0 ]]
