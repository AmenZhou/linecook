#!/usr/bin/env bash
# test-task-orchestrate.sh — SKILL.md invariants + control-plane/monitor structure.
# Runs standalone against this repo (no installed copy, no launchd, no workspace).
#   bash tests/test-task-orchestrate.sh
set -euo pipefail

PASS=0
FAIL=0
# Repo root is one level up from tests/.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$REPO_ROOT/bin"
SKILL_SRC="$REPO_ROOT/skill/SKILL.md"
MONITOR_DIR="$REPO_ROOT/monitor"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
skip() { echo "  ⊘ $1 (skipped)"; }

skill_has() {
  local pattern="$1"
  local label="$2"
  if grep -qE "$pattern" "$SKILL_SRC" 2>/dev/null; then
    ok "$label"
  else
    fail "$label"
  fi
}

echo ""
echo "── task-orchestrate — test suite ────────────────"

# ── 1. SKILL doc presence ─────────────────────────────────────────────────────
echo ""
echo "1. SKILL doc presence"

if [ -f "$SKILL_SRC" ]; then
  ok "SKILL.md exists"
else
  fail "SKILL.md missing at $SKILL_SRC"
fi

if [ -f "$REPO_ROOT/skill/GUIDE.md" ]; then
  ok "GUIDE.md exists"
else
  fail "GUIDE.md missing at $REPO_ROOT/skill/GUIDE.md"
fi

# ── 2. SKILL.md invocation modes ─────────────────────────────────────────────
echo ""
echo "2. SKILL.md invocation modes"

skill_has '\| `tend` \|' "invocation table includes tend"
skill_has 'tend go auto' "invocation table includes tend go auto"
skill_has '\| `resume`' "invocation table includes resume"
skill_has 'needs_human' "registry status values documented (needs_human)"

# ── 3. Tend watchdog mechanics ────────────────────────────────────────────────
echo ""
echo "3. Tend watchdog mechanics"

skill_has 'NEED_ACTION=0' "T-1 pre-flight defines NEED_ACTION"
skill_has 'awaiting_critic\|awaiting_go' "T-1 checks stalled task statuses"
skill_has '\.orchestrate/inbox/\*\.md' "T-1 checks inbox glob"
skill_has '360' "T-0 lock uses 360s staleness threshold"
skill_has '## Goal' "inbox file format requires Goal section"
skill_has 'inbox/gated' "T-2 documents inbox/gated/ path"
skill_has '`inbox`' "invocation table includes inbox mode"
skill_has '## Inbox Mode' "SKILL.md has Inbox Mode section"
skill_has 'deferred_at:' "T-2 skips deferred inbox files"
skill_has 'Gated tasks never auto-execute' "T-4 awaiting_go tasks are never auto-executed"
skill_has 'auto-resolved needs_human' "T-4 auto-resolves needs_human when all phases complete"
skill_has 'self-unblocked' "T-4 second-pass auto-resolution logs self-unblocked to heartbeat"
skill_has 'Second-Pass Auto-Resolution Check' "T-4 has second-pass check before surfacing needs_human"
skill_has 'physically move' "T-2 requires physical move to processed/ (not processed_as in place)"
skill_has '## Acceptance Criteria' "inbox file format requires Acceptance Criteria"

# ── 4. Execution + logging invariants ─────────────────────────────────────────
echo ""
echo "4. Execution + logging invariants"

skill_has 'acceptance_criteria_met' "PHASE OUTPUT includes acceptance_criteria_met"
skill_has 'test_evidence' "PHASE OUTPUT includes test_evidence field"
skill_has 'Phase N \(retry' "phase logs label retries distinctly"
skill_has '\{ID\}-phase\{N\}\.log' "phase log path pattern documented"
skill_has '\{ID\}-verify\.log' "verify log path pattern documented"
skill_has 'make test' "verify run detects Makefile test target"
skill_has 'orchestrate-history' "completion archives to orchestrate-history"
skill_has 'reasoning phase.*agent/premium' "executor table maps reasoning phases to agent/premium"
skill_has 'Mandatory final phase.*Test & Verify' "plan requires mandatory Test & Verify final phase"
skill_has 'Background Job Dry-Run' "verify phase mandates dry-run for background jobs"
skill_has 'Project-local smoke scripts' "verify phase mandates running inbox-referenced smoke scripts"
skill_has 'disqualifies PASS' "critic gate: any ✗ in AC → PARTIAL minimum"
skill_has 'Premium: retry 1.*premium; retry 2.*halt' "premium retry cap documented (retry 2 → halt)"
skill_has 'confidence-only gate' "critic applies confidence gate for simple/instructional phases"

# ── 5. T-0 lock simulation (pure-bash, portable) ──────────────────────────────
echo ""
echo "5. T-0 lock simulation"

LOCK="$(mktemp "${TMPDIR:-/tmp}/orch-lock-test.XXXXXX")"
date -u +%Y-%m-%dT%H:%M:%SZ > "$LOCK"
AGE=$(( $(date +%s) - $(date -r "$LOCK" +%s) ))
if [ "$AGE" -lt 360 ]; then
  ok "fresh lock age (${AGE}s) is under 360s threshold"
else
  fail "lock age calculation failed"
fi
rm -f "$LOCK"
ok "lock test file cleaned up"

# ── 6. Launchd plist templates (XML validity + wrapper structure) ─────────────
echo ""
echo "6. Launchd plist templates"

LAUNCHD_DIR="$REPO_ROOT/launchd"
TEND_PLIST="$LAUNCHD_DIR/com.orchestrate.tend.plist"
RESCUE_PLIST="$LAUNCHD_DIR/com.orchestrate.rescue.plist"
MONITOR_PLIST="$LAUNCHD_DIR/com.orchestrate.monitor.plist"
RUN_JOB="$BIN_DIR/run-job.sh"
AGENT_EXAMPLE="$BIN_DIR/agent.conf.example"

# plutil validates plist XML on macOS; fall back to a structural grep elsewhere.
validate_plist() {
  local p="$1"
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$p" >/dev/null 2>&1
  else
    grep -q '<plist' "$p" && grep -q '</plist>' "$p"
  fi
}

for p in "$TEND_PLIST" "$RESCUE_PLIST" "$MONITOR_PLIST"; do
  base="$(basename "$p")"
  if [ -f "$p" ]; then
    ok "$base exists"
    if validate_plist "$p"; then
      ok "$base is valid plist XML"
    else
      fail "$base is not valid plist XML"
    fi
  else
    fail "$base missing at $p"
  fi
done

# tend plist invokes the run-job wrapper via the install-time __RUN_JOB__ placeholder.
if grep -q '__RUN_JOB__' "$TEND_PLIST" 2>/dev/null; then
  ok "tend plist template uses __RUN_JOB__ placeholder for run-job wrapper"
else
  fail "tend plist template missing __RUN_JOB__ placeholder"
fi

if grep -q 'StartInterval' "$TEND_PLIST" 2>/dev/null; then
  ok "tend plist uses StartInterval (time-based trigger)"
else
  fail "tend plist missing StartInterval"
fi

# rescue plist invokes rescue.sh via the __RESCUE_SCRIPT__ placeholder.
if grep -q '__RESCUE_SCRIPT__' "$RESCUE_PLIST" 2>/dev/null; then
  ok "rescue plist template uses __RESCUE_SCRIPT__ placeholder"
else
  fail "rescue plist template missing __RESCUE_SCRIPT__ placeholder"
fi

if grep -q 'StartInterval' "$RESCUE_PLIST" 2>/dev/null; then
  ok "rescue plist uses StartInterval (time-based trigger)"
else
  fail "rescue plist missing StartInterval"
fi

if [ -x "$RUN_JOB" ]; then
  ok "run-job.sh wrapper exists and is executable"
else
  fail "run-job.sh missing or not executable at $RUN_JOB"
fi

if [ -x "$BIN_DIR/install-launchd.sh" ]; then
  ok "install-launchd.sh exists and is executable"
else
  fail "install-launchd.sh missing or not executable at $BIN_DIR/install-launchd.sh"
fi

# ── 7. agent.conf.example (configurable runner) ───────────────────────────────
echo ""
echo "7. agent.conf.example (configurable runner)"

if [ -f "$AGENT_EXAMPLE" ] && grep -qE '^RUNNER=(cursor|claude)' "$AGENT_EXAMPLE"; then
  ok "agent.conf.example sets RUNNER"
else
  fail "agent.conf.example missing or RUNNER not set at $AGENT_EXAMPLE"
fi

if [ -f "$AGENT_EXAMPLE" ] && grep -qE 'TEND_MODE=.*(go auto|go_auto|notify)' "$AGENT_EXAMPLE"; then
  ok "agent.conf.example sets TEND_MODE"
else
  fail "agent.conf.example missing TEND_MODE (expected go auto by default)"
fi

# ── 8. Orchestrate skill — pipeline + runtime defaults ────────────────────────
echo ""
echo "8. Orchestrate skill — pipeline + runtime defaults"

RUN_JOB_SRC="$BIN_DIR/run-job.sh"
ENQUEUE_ANALYZER="$BIN_DIR/enqueue-analyzer-daily.sh"

skill_has '\| `inbox go` \|' "invocation table includes inbox go"
skill_has '\| `inbox go auto` \|' "invocation table includes inbox go auto"
skill_has 'improvements-only' "inbox mode supports improvements-only triage"
skill_has 'source: self' "T-2 handles source: self inbox items"
skill_has 'awaiting_go.*tasks are never auto-executed' "T-4 awaiting_go skipped in tend go auto queue drain"
skill_has 'parallel batches of up to 3' "T-4 tend go auto dispatches parallel batches of 3"
skill_has 'TASK RESULT' "parallel batch subagent returns TASK RESULT block"
skill_has 'tend go auto <ID>' "invocation modes includes targeted single-task mode"
skill_has 'Do \*\*not\*\* append to `skill-improvement-backlog.md`' "completion routes suggestions to inbox not backlog"
skill_has 'improvement-<slug>' "self-improvement files improvement-<slug> inbox items"

if grep -q 'TEND_MODE="\${TEND_MODE:-go auto}"' "$RUN_JOB_SRC" 2>/dev/null; then
  ok "run-job.sh defaults TEND_MODE to go auto"
else
  fail "run-job.sh missing TEND_MODE default (go auto)"
fi

if grep -q 'tend_prompt' "$RUN_JOB_SRC" && grep -q 'go_auto' "$RUN_JOB_SRC"; then
  ok "run-job.sh maps TEND_MODE to tend prompts"
else
  fail "run-job.sh missing TEND_MODE prompt mapping"
fi

if grep -q 'NO --force' "$RUN_JOB_SRC"; then
  ok "run-job.sh documents no --force for unattended tend"
else
  fail "run-job.sh missing no --force safety comment"
fi

if [ -f "$ENQUEUE_ANALYZER" ] && grep -q 'run-job.sh" tend' "$ENQUEUE_ANALYZER"; then
  ok "enqueue-analyzer-daily.sh triggers immediate tend after enqueue"
else
  fail "enqueue-analyzer-daily.sh missing run-job.sh tend trigger"
fi

# T-1 simulation: deferred inbox file must not set NEED_ACTION (isolated temp inbox)
TMP_INBOX=$(mktemp -d "${TMPDIR:-/tmp}/orch-t1-sim.XXXXXX")
mkdir -p "$TMP_INBOX/gated"
DEFERRED="$TMP_INBOX/deferred-test.md"
ACTIVE="$TMP_INBOX/active-test.md"
echo 'deferred_at: 2026-06-19T00:00:00Z' > "$DEFERRED"
echo '# active test' > "$ACTIVE"
NEED=0
for f in "$TMP_INBOX"/*.md "$TMP_INBOX"/gated/*.md; do
  [[ -f "$f" ]] || continue
  grep -qE '^deferred_at:' "$f" 2>/dev/null && continue
  NEED=1
  break
done
if [[ "$NEED" -eq 1 ]]; then
  ok "T-1 deferred_at simulation triggers action when an active file is present"
else
  fail "T-1 deferred_at simulation — active file present but NEED_ACTION stayed 0"
fi

# Re-run with only deferred — NEED should stay 0
rm -f "$ACTIVE"
NEED=0
for f in "$TMP_INBOX"/*.md "$TMP_INBOX"/gated/*.md; do
  [[ -f "$f" ]] || continue
  grep -qE '^deferred_at:' "$f" 2>/dev/null && continue
  NEED=1
  break
done
rm -rf "$TMP_INBOX"
if [[ "$NEED" -eq 0 ]]; then
  ok "T-1 deferred-only inbox does not trigger action"
else
  fail "T-1 deferred-only inbox incorrectly triggers action"
fi

# ── 9. Monitor — History tab + disk fallback ──────────────────────────────────
echo ""
echo "9. Monitor — History tab + disk fallback"

MONITOR_SERVER="$MONITOR_DIR/server.js"
MONITOR_INDEX="$MONITOR_DIR/index.html"

if [[ -f "$MONITOR_SERVER" ]] && grep -q 'loadHistoryEntries' "$MONITOR_SERVER"; then
  ok "monitor server scans orchestrate-history/ for on-disk archives"
else
  fail "monitor server missing loadHistoryEntries disk fallback"
fi

if [[ -f "$MONITOR_SERVER" ]] && grep -q 'findHistoryEntry' "$MONITOR_SERVER"; then
  ok "monitor server links registry rows via findHistoryEntry"
else
  fail "monitor server missing findHistoryEntry"
fi

skill_has 'Self-check before marking complete' "Completion requires MANIFEST self-check"

# ── 10. Monitor — inbox gated/ + History visibility guardrails ────────────────
echo ""
echo "10. Monitor — inbox gated/ + History visibility guardrails"

if [[ -f "$MONITOR_SERVER" ]] && grep -q "entry.name === 'gated'" "$MONITOR_SERVER"; then
  ok "monitor handleInbox scans inbox/gated/ subdirectory"
else
  fail "monitor handleInbox missing inbox/gated/ scan"
fi

if [[ -f "$MONITOR_SERVER" ]] && grep -q 'HISTORY_REGISTRY_ALIASES' "$MONITOR_SERVER"; then
  ok "monitor server defines HISTORY_REGISTRY_ALIASES for duplicate registry IDs"
else
  fail "monitor server missing HISTORY_REGISTRY_ALIASES"
fi

if [[ -f "$MONITOR_SERVER" ]] && grep -q 'seenFiles.has' "$MONITOR_SERVER"; then
  ok "monitor buildHistoryRows dedupes by archive filename (seenFiles)"
else
  fail "monitor buildHistoryRows missing seenFiles dedupe"
fi

if [[ -f "$MONITOR_INDEX" ]] && grep -q "replace(/\\[_-\\]/g, ' ')" "$MONITOR_INDEX"; then
  ok "History search normalizes hyphens/underscores"
else
  fail "History search missing hyphen normalization in index.html"
fi

if [[ -f "$MONITOR_INDEX" ]] && grep -q 'historyDateRange' "$MONITOR_INDEX" && grep -q 'setHistoryDateRange' "$MONITOR_INDEX" && grep -q 'isDailyHistoryRow' "$MONITOR_INDEX"; then
  ok "History tab has date-range filters (Today/7d/30d/All/Daily)"
else
  fail "History tab missing date-range filter chips (historyDateRange)"
fi

if [[ -f "$MONITOR_SERVER" ]] && grep -q 'resolveHistoryDatetime' "$MONITOR_SERVER"; then
  ok "monitor server emits dateIso via resolveHistoryDatetime"
else
  fail "monitor server missing resolveHistoryDatetime for History date column"
fi

if [[ -f "$MONITOR_SERVER" ]] && grep -q 'last_activity is when the task finished' "$MONITOR_SERVER"; then
  ok "resolveHistoryDatetime prefers last_activity before archive filename timestamp"
else
  fail "resolveHistoryDatetime missing last_activity-before-filename-ts fix"
fi

if [[ -f "$MONITOR_SERVER" ]] && grep -q 'buildCompletionHints' "$MONITOR_SERVER"; then
  ok "monitor buildCompletionHints infers completion time from heartbeat/logs"
else
  fail "monitor server missing buildCompletionHints for History timestamps"
fi

if [[ -f "$MONITOR_SERVER" ]] && grep -q 'isFutureTimestamp' "$MONITOR_SERVER" && grep -q 'isFutureTimestamp(filenameIso)' "$MONITOR_SERVER"; then
  ok "resolveHistoryDatetime rejects future archive filename timestamps"
else
  fail "monitor server missing isFutureTimestamp guard on archive filename"
fi

if [[ -f "$MONITOR_INDEX" ]] && grep -q 'parseIsoUtc' "$MONITOR_INDEX"; then
  ok "History client parses dateIso as UTC via parseIsoUtc"
else
  fail "monitor index.html missing parseIsoUtc for History timestamps"
fi

if [[ -f "$SKILL_SRC" ]] && grep -q 'COMPLETED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"' "$SKILL_SRC"; then
  ok "Completion mandates COMPLETED_AT via date -u (no rounded placeholders)"
else
  fail "SKILL.md missing COMPLETED_AT timestamp contract in Completion"
fi

if [[ -f "$MONITOR_SERVER" ]] && grep -q 'isDateOnlyArchiveFilename' "$MONITOR_SERVER"; then
  ok "resolveHistoryDatetime skips date-only noon for bare registry task ids"
else
  fail "monitor server missing isDateOnlyArchiveFilename guard"
fi

if [[ -f "$MONITOR_INDEX" ]] && grep -q 'row.dateIso' "$MONITOR_INDEX"; then
  ok "History client enrichHistoryRows trusts server dateIso when present"
else
  fail "History client missing dateIso-first display logic"
fi

skill_has 'No duplicate registry rows' "Completion §1 warns against duplicate registry rows"
skill_has 'project slug' "Completion §1 requires cross-project summaries include project slug"

# ── 11. Tend session limit — runner fallback + monitor throttle ───────────────
echo ""
echo "11. Tend session limit — runner fallback + monitor throttle"

if [[ -f "$RUN_JOB_SRC" ]] && grep -q 'run_with_fallback' "$RUN_JOB_SRC"; then
  ok "run-job.sh falls back to alternate runner on session limit"
else
  fail "run-job.sh missing run_with_fallback"
fi

if [[ -f "$RUN_JOB_SRC" ]] && grep -q 'log_heartbeat' "$RUN_JOB_SRC" && grep -q 'both runners session-limited' "$RUN_JOB_SRC"; then
  ok "run-job.sh logs both-runners session-limited to heartbeat"
else
  fail "run-job.sh missing heartbeat log for session limit deferral"
fi

if [[ -f "$RUN_JOB_SRC" ]] && grep -q 'classify_agent_result' "$RUN_JOB_SRC"; then
  ok "run-job.sh classifies agent output (ok/session_limit/connection_lost)"
else
  fail "run-job.sh missing classify_agent_result"
fi

if [[ -f "$MONITOR_SERVER" ]] && grep -q 'tendThrottleHint' "$MONITOR_SERVER"; then
  ok "monitor server detects tend session throttle from heartbeat"
else
  fail "monitor server missing tendThrottleHint"
fi

if [[ -f "$MONITOR_SERVER" ]] && grep -q 'throttled' "$MONITOR_SERVER"; then
  ok "monitor launchd status can show throttled when session-limited"
else
  fail "monitor server missing throttled launchd status"
fi

if [[ -f "$MONITOR_INDEX" ]] && grep -q "throttled" "$MONITOR_INDEX"; then
  ok "monitor UI styles throttled launchd badge"
else
  fail "monitor index.html missing throttled badge styling"
fi

if [[ -f "$MONITOR_SERVER" ]] && grep -q 'parseTendHealth' "$MONITOR_SERVER"; then
  ok "monitor server parses tend execution health from heartbeat logs"
else
  fail "monitor server missing parseTendHealth"
fi

if [[ -f "$MONITOR_SERVER" ]] && grep -q '/api/tend-status' "$MONITOR_SERVER"; then
  ok "monitor exposes GET /api/tend-status for tend health"
else
  fail "monitor server missing /api/tend-status route"
fi

if [[ -f "$MONITOR_INDEX" ]] && grep -q 'tend-health-banner' "$MONITOR_INDEX"; then
  ok "monitor dashboard shows tend health attention banner"
else
  fail "monitor index.html missing tend-health-banner"
fi

if bash "$REPO_ROOT/tests/test-run-job.sh" >/dev/null 2>&1; then
  ok "test-run-job.sh suite passes (session limit fallback)"
else
  fail "test-run-job.sh failed — run tests/test-run-job.sh"
fi

if [[ -f "$MONITOR_INDEX" ]] && grep -q 'renderRunnerStatus' "$MONITOR_INDEX"; then
  ok "monitor header shows runner + Cursor IDE status"
else
  fail "monitor index.html missing renderRunnerStatus for runner/IDE badge"
fi

if [[ -f "$MONITOR_SERVER" ]] && grep -q '/api/agent-status' "$MONITOR_SERVER"; then
  ok "monitor exposes /api/agent-status for runner + IDE"
else
  fail "monitor server missing /api/agent-status endpoint"
fi

if [[ -f "$MONITOR_SERVER" ]] && grep -q 'isCursorIdeRunning' "$MONITOR_SERVER"; then
  ok "monitor checks Cursor IDE process (pgrep Cursor)"
else
  fail "monitor server missing isCursorIdeRunning"
fi

if [[ -f "$MONITOR_INDEX" ]] && grep -q 'fetchAgentStatus' "$MONITOR_INDEX" && grep -q 'id="runner-status"' "$MONITOR_INDEX"; then
  ok "monitor header fetches runner + IDE status on refresh"
else
  fail "monitor index.html missing fetchAgentStatus or runner-status badge"
fi

if [[ -f "$MONITOR_INDEX" ]] && grep -q 'IDE ✓' "$MONITOR_INDEX" && grep -q 'IDE ✗' "$MONITOR_INDEX"; then
  ok "monitor runner badge shows IDE up/down labels"
else
  fail "monitor index.html missing IDE ✓/✗ runner badge labels"
fi

# ── 12. Tend health surfacing + inbox processed_as guardrails ─────────────────
echo ""
echo "12. Tend health surfacing + inbox processed_as guardrails"

MONITOR_TEST="$MONITOR_DIR/tests/server.test.js"

if [[ -f "$MONITOR_SERVER" ]] && grep -q 'tendIssues' "$MONITOR_SERVER"; then
  ok "monitor /api/tasks exposes attention.tendIssues"
else
  fail "monitor server missing tendIssues on /api/tasks"
fi

if [[ -f "$MONITOR_SERVER" ]] && grep -q 'isCompletedInboxFile' "$MONITOR_SERVER" && grep -q 'processed_as' "$MONITOR_SERVER"; then
  ok "monitor excludes processed_as inbox stubs from /api/inbox"
else
  fail "monitor server missing processed_as inbox filtering"
fi

if [[ -f "$MONITOR_SERVER" ]] && grep -q 'syntax error near unexpected token' "$MONITOR_SERVER"; then
  ok "monitor parseTendHealth detects run-job syntax errors"
else
  fail "monitor server missing syntax-error tend health pattern"
fi

if [[ -f "$RUN_JOB_SRC" ]] && grep -q 'bash -n.*BASH_SOURCE' "$RUN_JOB_SRC"; then
  ok "run-job.sh self-validates syntax at startup (prevents launchd exit 512)"
else
  fail "run-job.sh missing startup syntax self-check"
fi

if [[ -f "$MONITOR_TEST" ]] && grep -q 'stale tend lock' "$MONITOR_TEST" && grep -q 'tendIssues when session limited' "$MONITOR_TEST"; then
  ok "monitor server.test.js covers stale lock + tendIssues integration"
else
  fail "monitor server.test.js missing stale lock or tendIssues tests"
fi

# Run the monitor's own node test suite when node is available.
if command -v node >/dev/null 2>&1; then
  if node --test "$MONITOR_TEST" >/dev/null 2>&1; then
    ok "monitor server.test.js passes (node --test)"
  else
    fail "monitor server.test.js failed under node --test"
  fi
else
  skip "monitor server.test.js — node not installed"
fi

# ── 13. History timestamps + stale inbox dashboard guardrails ─────────────────
echo ""
echo "13. History timestamps + stale inbox dashboard guardrails"

if [[ -f "$MONITOR_SERVER" ]] && grep -q "path.join(inboxDir, 'processed', path.basename(filename))" "$MONITOR_SERVER"; then
  ok "monitor hides inbox root files duplicated in processed/"
else
  fail "monitor server missing processed/ duplicate basename filter"
fi

if [[ -f "$MONITOR_TEST" ]] && grep -q 'prefers registry last_activity over batch archive filename' "$MONITOR_TEST"; then
  ok "monitor server.test.js covers batch archive vs last_activity History dateIso"
else
  fail "monitor server.test.js missing batch archive History dateIso test"
fi

if [[ -f "$SKILL_SRC" ]] && grep -q 'cleanup-stale-inbox.sh' "$SKILL_SRC"; then
  ok "T-1 documents cleanup-stale-inbox.sh stale inbox auto-cleanup"
else
  fail "SKILL.md missing cleanup-stale-inbox.sh in T-1 pre-flight"
fi

if [[ -x "$BIN_DIR/cleanup-stale-inbox.sh" ]]; then
  ok "cleanup-stale-inbox.sh present and executable"
else
  fail "bin/cleanup-stale-inbox.sh missing or not executable"
fi

if [[ -f "$MONITOR_SERVER" ]] && grep -q 'extractInboxTaskIds' "$MONITOR_SERVER" && grep -q 'completeTaskIds' "$MONITOR_SERVER"; then
  ok "monitor isCompletedInboxFile filters registry-complete task IDs"
else
  fail "monitor server missing registry-complete inbox filter"
fi

if [[ -f "$MONITOR_TEST" ]] && grep -q 'registry-complete task ID must not appear' "$MONITOR_TEST"; then
  ok "monitor server.test.js covers registry-complete inbox filter"
else
  fail "monitor server.test.js missing registry-complete inbox test"
fi

# ── 14. Bypass — park blocked tasks until unblocked ───────────────────────────
echo ""
echo "14. Bypass — park blocked tasks until unblocked"

skill_has 'bypassed_at:' "SKILL.md documents the bypassed_at park marker"
skill_has 'Bypass — park blocked tasks' "SKILL.md has the Bypass section"

if [[ -f "$BIN_DIR/tend-need-action.sh" && -f "$BIN_DIR/requeue-unblocked.sh" ]]; then
  BYP_TMP=$(mktemp -d "${TMPDIR:-/tmp}/orch-bypass.XXXXXX")
  mkdir -p "$BYP_TMP/.orchestrate/tasks" "$BYP_TMP/.orchestrate/logs" "$BYP_TMP/reports"
  cat > "$BYP_TMP/.orchestrate/project.md" <<'PROJEOF'
# Orchestrate — test
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| 20990101-inbox-PARK | parked external block | auto | 1 | needs_human | 2099-01-01T00:00:00Z |
| 20990101-inbox-NEW0 | not yet evaluated | auto | 1 | needs_human | 2099-01-01T00:00:00Z |
PROJEOF
  printf 'id: 20990101-inbox-PARK\nstatus: needs_human\nbypassed_at: 2099-01-01T00:05:00Z\nbypass_reason: external dep\n### Phase 1\nstatus: x failed\n' > "$BYP_TMP/.orchestrate/tasks/20990101-inbox-PARK.md"
  printf 'id: 20990101-inbox-NEW0\nstatus: needs_human\n### Phase 1\nstatus: x failed\n' > "$BYP_TMP/.orchestrate/tasks/20990101-inbox-NEW0.md"

  NHA="$(bash "$BIN_DIR/tend-need-action.sh" "$BYP_TMP" 2>/dev/null | grep '^NEEDS_HUMAN_ACTIONABLE=' | cut -d= -f2 || true)"
  if [[ "$NHA" == "1" ]]; then
    ok "tend-need-action.sh skips bypassed_at task (only un-parked counted)"
  else
    fail "tend-need-action.sh bypass skip — expected NEEDS_HUMAN_ACTIONABLE=1, got '$NHA'"
  fi

  # Unblock the parked task via requeue_when_exists closure → marker stripped + pending
  printf '**Status:** ✅ CONFIRMED\n' > "$BYP_TMP/reports/decision.md"
  printf 'id: 20990101-inbox-PARK\nstatus: needs_human\nrequeue_when_exists: %s/reports/decision.md\nbypassed_at: 2099-01-01T00:05:00Z\nbypass_reason: external dep\n### Phase 1\nstatus: x failed\n' "$BYP_TMP" > "$BYP_TMP/.orchestrate/tasks/20990101-inbox-PARK.md"
  bash "$BIN_DIR/requeue-unblocked.sh" "$BYP_TMP" >/dev/null 2>&1 || true
  if ! grep -qE '^(bypassed_at|bypass_reason):' "$BYP_TMP/.orchestrate/tasks/20990101-inbox-PARK.md" \
     && grep -qE '\| 20990101-inbox-PARK \|.*\| pending \|' "$BYP_TMP/.orchestrate/project.md"; then
    ok "requeue-unblocked.sh clears bypass marker and sets pending"
  else
    fail "requeue-unblocked.sh did not clear marker / set pending"
  fi
  rm -rf "$BYP_TMP"
else
  fail "bypass bin scripts not found under $BIN_DIR"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "── Results ───────────────────────────────────────"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "──────────────────────────────────────────────────"

[ "$FAIL" -eq 0 ] && echo "  ALL TESTS PASSED" && exit 0
echo "  SOME TESTS FAILED — see above" && exit 1
