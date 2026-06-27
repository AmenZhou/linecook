#!/usr/bin/env bash
# test-run-job.sh — unit tests for .orchestrate/bin/run-job.sh dispatch logic
# Uses mock cursor/claude binaries; does not invoke real agents.
set -euo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_JOB_SRC="${RUN_JOB_SRC:-/Users/haimengzhou/apps/ai-toolbox/skills/task-orchestrate/bin/run-job.sh}"
RUN_JOB="${RUN_JOB:-$PROJECT_ROOT/.orchestrate/bin/run-job.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=""
cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"; return 0; }  # return 0: an EXIT trap must never clobber the script's exit status
trap cleanup EXIT

setup_mocks() {
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/run-job-test.XXXXXX")"
  MOCK_CURSOR="$TMP/cursor-agent"
  MOCK_CLAUDE="$TMP/claude"
  LOG_CURSOR="$TMP/cursor.log"
  LOG_CLAUDE="$TMP/claude.log"
  CONF="$TMP/agent.conf"
  WORK="$TMP/work"
  mkdir -p "$WORK"

  cat > "$MOCK_CURSOR" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$LOG_CURSOR"
echo "cursor-agent mock: \$*"
EOF
  cat > "$MOCK_CLAUDE" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$LOG_CLAUDE"
echo "claude mock: \$*"
EOF
  chmod +x "$MOCK_CURSOR" "$MOCK_CLAUDE"
}

write_conf() {
  local runner="$1"
  cat > "$CONF" << EOF
RUNNER=$runner
CURSOR_BIN=$MOCK_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
}

run_job() {
  local job="$1"
  rm -f "$LOG_CURSOR" "$LOG_CLAUDE"
  (cd "$WORK" && ORCHESTRATE_AGENT_CONF="$CONF" bash "$RUN_JOB" "$job")
}

assert_cursor_args() {
  local expected="$1"
  if [[ ! -f "$LOG_CURSOR" ]]; then
    fail "cursor mock not invoked — expected: $expected"
    return
  fi
  local got
  got="$(tr '\n' ' ' < "$LOG_CURSOR" | sed 's/  */ /g;s/ $//')"
  if [[ "$got" == *"$expected"* ]]; then
    ok "cursor dispatched: $expected"
  else
    fail "cursor args mismatch — got '$got', want '$expected'"
  fi
  if [[ -f "$LOG_CLAUDE" ]]; then
    fail "claude mock should not run when RUNNER=cursor"
  fi
}

assert_claude_args() {
  local expected="$1"
  if [[ ! -f "$LOG_CLAUDE" ]]; then
    fail "claude mock not invoked — expected: $expected"
    return
  fi
  local got
  got="$(tr '\n' ' ' < "$LOG_CLAUDE" | sed 's/  */ /g;s/ $//')"
  if [[ "$got" == *"$expected"* ]]; then
    ok "claude dispatched: $expected"
  else
    fail "claude args mismatch — got '$got', want '$expected'"
  fi
  if [[ -f "$LOG_CURSOR" ]]; then
    fail "cursor mock should not run when RUNNER=claude"
  fi
}

assert_exit_fail() {
  local job="$1"
  local label="$2"
  set +e
  run_job "$job" >/dev/null 2>&1
  local code=$?
  set -e
  if [[ "$code" -ne 0 ]]; then
    ok "$label (exit $code)"
  else
    fail "$label — expected non-zero exit"
  fi
}

echo ""
echo "── run-job.sh dispatch — test suite ─────────────"

echo ""
echo "0. Prerequisites"
if [[ -f "$RUN_JOB" ]]; then
  ok "run-job.sh found at $RUN_JOB"
else
  fail "run-job.sh missing at $RUN_JOB"
  echo "  aborting — cannot run dispatch tests"
  exit 1
fi

if [[ -f "$RUN_JOB_SRC" ]] && cmp -s "$RUN_JOB_SRC" "$RUN_JOB" 2>/dev/null; then
  ok "installed run-job.sh matches ai-toolbox source"
elif [[ -f "$RUN_JOB_SRC" ]]; then
  fail "installed run-job.sh stale — run install-launchd.sh"
fi

if grep -q 'cleanup_stale_inbox' "$RUN_JOB" && [[ -x "$PROJECT_ROOT/.orchestrate/bin/cleanup-stale-inbox.sh" ]]; then
  ok "run-job.sh invokes cleanup-stale-inbox.sh before tend"
else
  fail "run-job.sh missing cleanup_stale_inbox hook or cleanup script not executable"
fi

setup_mocks

echo ""
echo "1. RUNNER=cursor tend"
write_conf cursor
run_job tend
assert_cursor_args "-p --trust /task-orchestrate tend go auto"

echo ""
echo "2. RUNNER=claude tend"
write_conf claude
run_job tend
assert_claude_args "-p tend go auto"

echo ""
echo "2b. TEND_MODE=notify (override)"
cat > "$CONF" << EOF
RUNNER=cursor
TEND_MODE=notify
CURSOR_BIN=$MOCK_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
run_job tend
assert_cursor_args "-p --trust /task-orchestrate tend"

echo ""
echo "2c. TEND_MODE default (no setting in conf — go auto)"
cat > "$CONF" << EOF
RUNNER=cursor
CURSOR_BIN=$MOCK_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
run_job tend
assert_cursor_args "-p --trust /task-orchestrate tend go auto"

echo ""
echo "2d. TEND_MODE=go_auto alias"
cat > "$CONF" << EOF
RUNNER=claude
TEND_MODE=go_auto
CURSOR_BIN=$MOCK_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
run_job tend
assert_claude_args "-p tend go auto"

echo ""
echo "2e. invalid TEND_MODE rejected"
cat > "$CONF" << EOF
RUNNER=cursor
TEND_MODE=bogus
CURSOR_BIN=$MOCK_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
assert_exit_fail tend "invalid TEND_MODE rejected"

echo ""
echo "2f. session limit on primary falls back to secondary runner"
SESSION_LIMIT_CURSOR="$TMP/cursor-session-limit"
cat > "$SESSION_LIMIT_CURSOR" << EOF
#!/usr/bin/env bash
echo "You've hit your session limit · resets 5:10pm"
exit 1
EOF
chmod +x "$SESSION_LIMIT_CURSOR"
cat > "$CONF" << EOF
RUNNER=cursor
CURSOR_BIN=$SESSION_LIMIT_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
run_job tend
if [[ -f "$LOG_CLAUDE" ]]; then
  ok "session limit on cursor fell back to claude"
else
  fail "expected claude fallback after cursor session limit"
fi

echo ""
echo "2g. both runners session-limited exits 0 with heartbeat note"
BOTH_LIMIT_CLAUDE="$TMP/claude-session-limit"
cat > "$BOTH_LIMIT_CLAUDE" << EOF
#!/usr/bin/env bash
echo "You've hit your session limit · resets 5:10pm"
exit 1
EOF
chmod +x "$BOTH_LIMIT_CLAUDE"
cat > "$CONF" << EOF
RUNNER=cursor
CURSOR_BIN=$SESSION_LIMIT_CURSOR
CLAUDE_BIN=$BOTH_LIMIT_CLAUDE
EOF
HEARTBEAT="$WORK/.orchestrate/logs/heartbeat.log"
mkdir -p "$(dirname "$HEARTBEAT")"
rm -f "$HEARTBEAT"
set +e
run_job tend >/dev/null 2>&1
code=$?
set -e
if [[ "$code" -eq 0 ]]; then
  ok "both runners session-limited exit 0"
else
  fail "both runners session-limited should exit 0, got $code"
fi
if grep -qE 'both runners session-limited|deferred' "$HEARTBEAT" 2>/dev/null; then
  ok "heartbeat logs session limit deferral"
else
  fail "heartbeat missing session limit deferral line"
fi

echo ""
echo "2h. connection lost on primary falls back to secondary"
CONN_LOST_CURSOR="$TMP/cursor-conn-lost"
cat > "$CONN_LOST_CURSOR" << EOF
#!/usr/bin/env bash
echo "Connection lost, reconnecting to https://agentn.global.api5.cursor.sh (attempt 1)..."
exit 1
EOF
chmod +x "$CONN_LOST_CURSOR"
cat > "$CONF" << EOF
RUNNER=cursor
CURSOR_BIN=$CONN_LOST_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
rm -f "$LOG_CLAUDE" "$LOG_CURSOR"
run_job tend
if [[ -f "$LOG_CLAUDE" ]]; then
  ok "connection lost on cursor fell back to claude"
else
  fail "expected claude fallback after cursor connection lost"
fi

echo ""
echo "2i. primary session limit logs reset hint to heartbeat"
HEARTBEAT2="$WORK/.orchestrate/logs/heartbeat.log"
rm -f "$HEARTBEAT2"
cat > "$CONF" << EOF
RUNNER=claude
CURSOR_BIN=$SESSION_LIMIT_CURSOR
CLAUDE_BIN=$BOTH_LIMIT_CLAUDE
EOF
run_job tend >/dev/null 2>&1 || true
if grep -q 'resets 5:10pm' "$HEARTBEAT2" 2>/dev/null; then
  ok "heartbeat includes session limit reset hint"
else
  fail "heartbeat missing session limit reset hint"
fi

echo ""
echo "2j. CURSOR_FALLBACK=never defers when Cursor IDE not running"
HEARTBEAT3="$WORK/.orchestrate/logs/heartbeat.log"
rm -f "$HEARTBEAT3" "$LOG_CLAUDE" "$LOG_CURSOR"
cat > "$CONF" << EOF
RUNNER=cursor
CURSOR_FALLBACK=never
CURSOR_BIN=$MOCK_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
CURSOR_IDE_RUNNING=0 run_job tend >/dev/null 2>&1
if [[ ! -f "$LOG_CLAUDE" && ! -f "$LOG_CURSOR" ]]; then
  ok "CURSOR_FALLBACK=never — no agent invoked when IDE down"
else
  fail "CURSOR_FALLBACK=never should not invoke agents when IDE down"
fi
if grep -q 'Cursor IDE required but not running' "$HEARTBEAT3" 2>/dev/null; then
  ok "heartbeat logs IDE-required deferral"
else
  fail "heartbeat missing IDE-required deferral line"
fi

echo ""
echo "2k. CURSOR_FALLBACK=auto falls back when Cursor IDE not running"
rm -f "$HEARTBEAT3" "$LOG_CLAUDE" "$LOG_CURSOR"
cat > "$CONF" << EOF
RUNNER=cursor
CURSOR_FALLBACK=auto
CURSOR_BIN=$MOCK_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
CURSOR_IDE_RUNNING=0 run_job tend
if [[ -f "$LOG_CLAUDE" ]]; then
  ok "CURSOR_FALLBACK=auto — claude invoked when IDE down"
else
  fail "CURSOR_FALLBACK=auto should fall back to claude when IDE down"
fi

echo ""
echo "2l. exit-0 with no stdout output treated as silent session limit → claude fallback"
SILENT_CURSOR="$TMP/cursor-silent"
HEARTBEAT_SL="$WORK/.orchestrate/logs/heartbeat.log"
cat > "$SILENT_CURSOR" << 'INNEREOF'
#!/usr/bin/env bash
# exits 0 but produces no stdout — simulates new cursor-agent silent session-limit
INNEREOF
chmod +x "$SILENT_CURSOR"
rm -f "$HEARTBEAT_SL" "$LOG_CLAUDE"
cat > "$CONF" << EOF
RUNNER=cursor
CURSOR_FALLBACK=auto
CURSOR_IDE_RUNNING=1
CURSOR_BIN=$SILENT_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
CURSOR_IDE_RUNNING=1 run_job tend >/dev/null 2>&1 || true
if [[ -f "$LOG_CLAUDE" ]]; then
  ok "silent exit-0 cursor → fell back to claude"
else
  fail "silent exit-0 cursor should trigger fallback to claude"
fi
if grep -q 'session limit' "$HEARTBEAT_SL" 2>/dev/null; then
  ok "heartbeat logs silent session limit"
else
  fail "heartbeat missing silent session limit entry"
fi

echo ""
echo "3. RUNNER=cursor inbox-log-analyzer"
write_conf cursor
run_job inbox-log-analyzer
assert_cursor_args "-p --trust /inbox-log-analyzer"

echo ""
echo "4. RUNNER=claude inbox-log-analyzer"
write_conf claude
run_job inbox-log-analyzer
assert_claude_args "-p /inbox-log-analyzer"

echo ""
echo "5. Error handling"
write_conf bogus
assert_exit_fail tend "unknown RUNNER rejected"

write_conf cursor
assert_exit_fail "not-a-job" "unknown job rejected"

echo ""
echo "5b. run-job.sh syntax self-check"
if bash -n "$RUN_JOB_SRC" 2>/dev/null; then
  ok "ai-toolbox run-job.sh bash syntax valid"
else
  fail "ai-toolbox run-job.sh has bash syntax errors"
fi
if bash -n "$RUN_JOB" 2>/dev/null; then
  ok "installed run-job.sh bash syntax valid"
else
  fail "installed run-job.sh has bash syntax errors"
fi
if grep -q 'bash -n.*BASH_SOURCE' "$RUN_JOB_SRC" 2>/dev/null; then
  ok "run-job.sh self-validates syntax at startup"
else
  fail "run-job.sh missing startup syntax self-check"
fi

echo ""
echo "6. install-launchd.sh source"
INSTALL="/Users/haimengzhou/apps/ai-toolbox/skills/task-orchestrate/bin/install-launchd.sh"
if [[ -f "$INSTALL" ]]; then
  ok "install-launchd.sh exists"
  if bash -n "$INSTALL" 2>/dev/null; then
    ok "install-launchd.sh bash syntax valid"
  else
    fail "install-launchd.sh has bash syntax errors"
  fi
else
  fail "install-launchd.sh missing at $INSTALL"
fi

TEND_PLIST="/Users/haimengzhou/apps/ai-toolbox/skills/task-orchestrate/com.orchestrate.tend.plist"
if grep -q '__RUN_JOB__' "$TEND_PLIST" 2>/dev/null; then
  ok "tend plist template uses __RUN_JOB__ placeholder"
else
  fail "tend plist template missing __RUN_JOB__"
fi

echo ""
echo "7. tend idle skip (no agent when queue empty)"
setup_idle_work() {
  IDLE_WORK="$TMP/idle-work"
  mkdir -p "$IDLE_WORK/.orchestrate/inbox/gated" "$IDLE_WORK/.orchestrate/inbox/processed" \
    "$IDLE_WORK/.orchestrate/logs" "$IDLE_WORK/.orchestrate/bin"
  cp "$PROJECT_ROOT/.orchestrate/bin/"{run-job.sh,drain-inbox.sh,tend-need-action.sh,cleanup-stale-inbox.sh} \
    "$IDLE_WORK/.orchestrate/bin/"
  chmod +x "$IDLE_WORK/.orchestrate/bin/"*.sh
  cat > "$IDLE_WORK/.orchestrate/project.md" << 'EOF'
# Orchestrate — idle-test
last_updated: 2026-01-01T00:00:00Z

## Shared Context

## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| test-done | done task | auto | 1 | complete | 2026-01-01T00:00:00Z |
EOF
  cat > "$IDLE_CONF" << EOF
RUNNER=cursor
TEND_MODE="go auto"
CURSOR_BIN=$MOCK_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
EOF
}
IDLE_CONF="$TMP/idle-agent.conf"
setup_idle_work
rm -f "$LOG_CURSOR" "$LOG_CLAUDE"
if (cd "$IDLE_WORK" && ORCHESTRATE_AGENT_CONF="$IDLE_CONF" bash "$IDLE_WORK/.orchestrate/bin/run-job.sh" tend); then
  if [[ ! -f "$LOG_CURSOR" ]]; then
    ok "tend skips cursor-agent when registry and inbox are idle"
  else
    fail "cursor-agent invoked on idle queue — got: $(cat "$LOG_CURSOR" 2>/dev/null)"
  fi
else
  fail "run-job tend exited non-zero on idle worktree"
fi

if grep -q 'tend go auto — idle' "$IDLE_WORK/.orchestrate/logs/heartbeat.log" 2>/dev/null; then
  ok "idle tend appends tend go auto — idle to heartbeat"
else
  fail "heartbeat missing tend go auto — idle line"
fi

echo ""
echo "8. tend_need_action pipefail guard — pending task MUST dispatch agent"
# Regression test: the '| grep | cut || echo 1' pattern inside tend_need_action()
# was unsafe under set -o pipefail. When tend-need-action.sh exits 1 (action needed),
# pipefail marks the pipe failed → '|| echo 1' fires AND cut's output was already
# captured → need="1\n1" → [[ "1\n1" == "1" ]] fails → false idle. Fix: capture raw
# output first, then filter separately.
ACTIVE_WORK="$TMP/active-work"
mkdir -p "$ACTIVE_WORK/.orchestrate/inbox/gated" "$ACTIVE_WORK/.orchestrate/inbox/processed" \
  "$ACTIVE_WORK/.orchestrate/logs" "$ACTIVE_WORK/.orchestrate/bin"
cp "$PROJECT_ROOT/.orchestrate/bin/"{run-job.sh,drain-inbox.sh,tend-need-action.sh,cleanup-stale-inbox.sh} \
  "$ACTIVE_WORK/.orchestrate/bin/"
chmod +x "$ACTIVE_WORK/.orchestrate/bin/"*.sh
cat > "$ACTIVE_WORK/.orchestrate/project.md" << 'EOF'
# Orchestrate — active-test
last_updated: 2026-01-01T00:00:00Z

## Shared Context

## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| test-active | pending task | auto | 1 | pending | 2026-01-01T00:00:00Z |
EOF
ACTIVE_CONF="$TMP/active-agent.conf"
LOG_ACTIVE_CURSOR="$TMP/active-cursor.log"
LOG_ACTIVE_CLAUDE="$TMP/active-claude.log"
MOCK_ACTIVE_CURSOR="$TMP/mock-active-cursor.sh"
MOCK_ACTIVE_CLAUDE="$TMP/mock-active-claude.sh"
cat > "$MOCK_ACTIVE_CURSOR" << EOF
#!/usr/bin/env bash
echo "cursor-agent called with: \$*" > "$LOG_ACTIVE_CURSOR"
exit 0
EOF
cat > "$MOCK_ACTIVE_CLAUDE" << EOF
#!/usr/bin/env bash
echo "claude called with: \$*" > "$LOG_ACTIVE_CLAUDE"
exit 0
EOF
chmod +x "$MOCK_ACTIVE_CURSOR" "$MOCK_ACTIVE_CLAUDE"
cat > "$ACTIVE_CONF" << EOF
RUNNER=cursor
TEND_MODE="go auto"
CURSOR_BIN=$MOCK_ACTIVE_CURSOR
CLAUDE_BIN=$MOCK_ACTIVE_CLAUDE
CURSOR_IDE_RUNNING=1
EOF
rm -f "$LOG_ACTIVE_CURSOR" "$LOG_ACTIVE_CLAUDE"
if (cd "$ACTIVE_WORK" && ORCHESTRATE_AGENT_CONF="$ACTIVE_CONF" bash "$ACTIVE_WORK/.orchestrate/bin/run-job.sh" tend); then
  if [[ -f "$LOG_ACTIVE_CURSOR" ]] || [[ -f "$LOG_ACTIVE_CLAUDE" ]]; then
    ok "tend dispatches agent when registry has pending task (pipefail guard works)"
  else
    fail "tend logged idle despite pending task — pipefail bug in tend_need_action() may have regressed"
  fi
else
  fail "run-job tend exited non-zero with pending task"
fi

if ! grep -q 'tend go auto — idle' "$ACTIVE_WORK/.orchestrate/logs/heartbeat.log" 2>/dev/null; then
  ok "heartbeat does NOT contain idle when task is pending"
else
  fail "heartbeat shows idle despite pending task — pipefail bug in tend_need_action()"
fi

echo ""
echo "9. cleanup-stale-inbox.sh set -e safety (non-stale inbox file)"
# Regression: [[ cond ]] && continue returns exit 1 when cond is false under set -e,
# killing the script on every inbox file that is not moved (lines 68, 86, 94).
CLEAN_WORK="$TMP/cleanup-work"
mkdir -p "$CLEAN_WORK/.orchestrate/inbox/processed" "$CLEAN_WORK/.orchestrate/logs" \
  "$CLEAN_WORK/.orchestrate/tasks"
cat > "$CLEAN_WORK/.orchestrate/project.md" << 'EOF'
# Orchestrate — cleanup-test
last_updated: 2026-01-01T00:00:00Z

## Shared Context

## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| test-done | done task | auto | 1 | complete | 2026-01-01T00:00:00Z |
EOF
cat > "$CLEAN_WORK/.orchestrate/inbox/active-item.md" << 'EOF'
# Active inbox item (not stale)

## Goal
Should not crash cleanup-stale-inbox under set -e
EOF
if bash "$PROJECT_ROOT/.orchestrate/bin/cleanup-stale-inbox.sh" "$CLEAN_WORK"; then
  ok "cleanup-stale-inbox exits 0 with active non-stale inbox file"
else
  fail "cleanup-stale-inbox exited non-zero — set -e && continue bug may have regressed"
fi

echo ""
echo "10. awaiting_go task — tend is IDLE (notify-only, does NOT gate dispatch)"
# Behavior change e26282d (2026-06-25): awaiting_go is gated/notify-only and no longer
# gates dispatch — tend-need-action.sh excludes it "on purpose" so the launchd cycle does
# not spend AI tokens re-notifying gated tasks every 5 min. When ONLY awaiting_go tasks
# exist (no pending/inbox/awaiting_critic), tend must report idle and NOT invoke an agent.
GATED_WORK="$TMP/gated-work"
mkdir -p "$GATED_WORK/.orchestrate/inbox/gated" "$GATED_WORK/.orchestrate/inbox/processed" \
  "$GATED_WORK/.orchestrate/logs" "$GATED_WORK/.orchestrate/bin"
cp "$PROJECT_ROOT/.orchestrate/bin/"{run-job.sh,drain-inbox.sh,tend-need-action.sh,cleanup-stale-inbox.sh} \
  "$GATED_WORK/.orchestrate/bin/"
chmod +x "$GATED_WORK/.orchestrate/bin/"*.sh
cat > "$GATED_WORK/.orchestrate/project.md" << 'EOF'
# Orchestrate — gated-test
last_updated: 2026-01-01T00:00:00Z

## Shared Context

## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| test-gated | gated hello work task | gated | 1 | awaiting_go | 2026-01-01T00:00:00Z |
EOF
GATED_CONF="$TMP/gated-agent.conf"
LOG_GATED_CURSOR="$TMP/gated-cursor.log"
LOG_GATED_CLAUDE="$TMP/gated-claude.log"
MOCK_GATED_CURSOR="$TMP/mock-gated-cursor.sh"
MOCK_GATED_CLAUDE="$TMP/mock-gated-claude.sh"
cat > "$MOCK_GATED_CURSOR" << EOF
#!/usr/bin/env bash
echo "cursor-agent called with: \$*" > "$LOG_GATED_CURSOR"
exit 0
EOF
cat > "$MOCK_GATED_CLAUDE" << EOF
#!/usr/bin/env bash
echo "claude called with: \$*" > "$LOG_GATED_CLAUDE"
exit 0
EOF
chmod +x "$MOCK_GATED_CURSOR" "$MOCK_GATED_CLAUDE"
cat > "$GATED_CONF" << EOF
RUNNER=cursor
TEND_MODE="go auto"
CURSOR_BIN=$MOCK_GATED_CURSOR
CLAUDE_BIN=$MOCK_GATED_CLAUDE
CURSOR_IDE_RUNNING=1
EOF
rm -f "$LOG_GATED_CURSOR" "$LOG_GATED_CLAUDE"
if (cd "$GATED_WORK" && ORCHESTRATE_AGENT_CONF="$GATED_CONF" bash "$GATED_WORK/.orchestrate/bin/run-job.sh" tend); then
  if [[ ! -f "$LOG_GATED_CURSOR" && ! -f "$LOG_GATED_CLAUDE" ]]; then
    ok "tend does NOT dispatch agent when only awaiting_go tasks exist (notify-only, e26282d)"
  else
    fail "agent dispatched for awaiting_go-only registry — e26282d excludes awaiting_go from NEED_ACTION"
  fi
else
  fail "run-job tend exited non-zero with awaiting_go task"
fi

if grep -q 'tend go auto — idle' "$GATED_WORK/.orchestrate/logs/heartbeat.log" 2>/dev/null; then
  ok "heartbeat logs idle when only awaiting_go tasks exist (no token spend re-notifying)"
else
  fail "heartbeat missing idle line for awaiting_go-only registry"
fi

echo ""
echo "11. drain-inbox.sh — gated/ file registers as awaiting_go, not pending"
# Guard: drain-inbox.sh must register inbox/gated/ files with status=awaiting_go.
# If the status is pending instead, tend go auto would execute the task automatically,
# defeating the gate (the bug that B9D8 Hello Work exposed on 2026-06-21).
DRAIN_WORK="$TMP/drain-gated-work"
mkdir -p "$DRAIN_WORK/.orchestrate/inbox/gated" "$DRAIN_WORK/.orchestrate/inbox/processed" \
  "$DRAIN_WORK/.orchestrate/logs"
cat > "$DRAIN_WORK/.orchestrate/inbox/gated/test-gated-task.md" << 'EOF'
mode: gated

# Test Gated Task

## Goal
This task should be registered as awaiting_go, never as pending.

## Acceptance Criteria
- Registry row shows status awaiting_go
EOF
if bash "$PROJECT_ROOT/.orchestrate/bin/drain-inbox.sh" "$DRAIN_WORK"; then
  if grep -qE '\|\s*awaiting_go\s*\|' "$DRAIN_WORK/.orchestrate/project.md" 2>/dev/null; then
    ok "drain-inbox registers gated/ file as awaiting_go"
  else
    fail "drain-inbox did not set awaiting_go — got: $(grep '^|' "$DRAIN_WORK/.orchestrate/project.md" 2>/dev/null | tail -1 || echo '(no rows)')"
  fi
  if ! grep -qE '\|\s*pending\s*\|' "$DRAIN_WORK/.orchestrate/project.md" 2>/dev/null; then
    ok "drain-inbox did NOT register gated/ file as pending"
  else
    fail "drain-inbox set status=pending for a gated/ file — gated tasks must be awaiting_go"
  fi
else
  fail "drain-inbox.sh exited non-zero on gated inbox file"
fi

if [[ -f "$DRAIN_WORK/.orchestrate/inbox/processed/test-gated-task.md" ]]; then
  ok "drain-inbox moved gated/ file to processed/"
else
  fail "drain-inbox did not move gated/ file to processed/"
fi

if grep -q 'registered (gated)' "$DRAIN_WORK/.orchestrate/logs/heartbeat.log" 2>/dev/null; then
  ok "drain-inbox heartbeat contains 'registered (gated)' label"
else
  fail "drain-inbox heartbeat missing 'registered (gated)' — log line format may have changed"
fi

# §10 — pending_task_count and queue drain loop present in run-job.sh
echo ""
echo "── §10 Queue drain loop assertions ──────────────"

if grep -q 'pending_task_count' "$RUN_JOB_SRC" 2>/dev/null; then
  ok "run-job.sh has pending_task_count() function"
else
  fail "run-job.sh missing pending_task_count() — parallel queue drain not wired"
fi

if grep -q 'MAX_TEND_LOOPS' "$RUN_JOB_SRC" 2>/dev/null; then
  ok "run-job.sh has MAX_TEND_LOOPS guard for queue drain loop"
else
  fail "run-job.sh missing MAX_TEND_LOOPS — loop may be unbounded"
fi

if grep -q 'queue drain loop' "$RUN_JOB_SRC" 2>/dev/null; then
  ok "run-job.sh logs queue drain loop iterations"
else
  fail "run-job.sh missing 'queue drain loop' log line"
fi

echo ""
echo "12. tend preflight runs requeue-unblocked.sh WITHOUT 'local outside function' abort"
# Regression (BC0E, 2026-06-25): the requeue-unblocked.sh hook was added to the
# top-level `tend)` case branch as `local requeue_script=...`. `local` is only valid
# inside a function — at top level bash errors "local: can only be used in a function"
# and, under `set -e`, ABORTS run-job.sh before dispatch. Result: every tend cycle
# died silently at that line for ~2 days; pending tasks never executed and rescue
# crash-looped (kick → same abort → kick). This test runs the full preflight (with a
# real requeue-unblocked.sh present so line 393 executes) and asserts:
#   (a) no "can only be used in a function" appears on stderr, and
#   (b) the agent is still dispatched for a pending task.
PREFLIGHT_WORK="$TMP/preflight-work"
mkdir -p "$PREFLIGHT_WORK/.orchestrate/inbox/gated" "$PREFLIGHT_WORK/.orchestrate/inbox/processed" \
  "$PREFLIGHT_WORK/.orchestrate/logs" "$PREFLIGHT_WORK/.orchestrate/bin" "$PREFLIGHT_WORK/.orchestrate/tasks"
cp "$PROJECT_ROOT/.orchestrate/bin/"{run-job.sh,drain-inbox.sh,tend-need-action.sh,cleanup-stale-inbox.sh} \
  "$PREFLIGHT_WORK/.orchestrate/bin/"
# Copy requeue-unblocked.sh if it exists so the real preflight line is exercised;
# otherwise install a no-op stand-in so the [[ -x ]] guard path is still taken.
if [[ -f "$PROJECT_ROOT/.orchestrate/bin/requeue-unblocked.sh" ]]; then
  cp "$PROJECT_ROOT/.orchestrate/bin/requeue-unblocked.sh" "$PREFLIGHT_WORK/.orchestrate/bin/"
else
  printf '#!/usr/bin/env bash\nexit 0\n' > "$PREFLIGHT_WORK/.orchestrate/bin/requeue-unblocked.sh"
fi
chmod +x "$PREFLIGHT_WORK/.orchestrate/bin/"*.sh
cat > "$PREFLIGHT_WORK/.orchestrate/project.md" << 'EOF'
# Orchestrate — preflight-test
last_updated: 2026-01-01T00:00:00Z

## Shared Context

## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| test-pending | pending task | auto | 1 | pending | 2026-01-01T00:00:00Z |
EOF
PREFLIGHT_CONF="$TMP/preflight-agent.conf"
LOG_PRE_CURSOR="$TMP/preflight-cursor.log"
MOCK_PRE_CURSOR="$TMP/mock-preflight-cursor.sh"
cat > "$MOCK_PRE_CURSOR" << EOF
#!/usr/bin/env bash
echo "cursor-agent called with: \$*" > "$LOG_PRE_CURSOR"
exit 0
EOF
chmod +x "$MOCK_PRE_CURSOR"
cat > "$PREFLIGHT_CONF" << EOF
RUNNER=cursor
TEND_MODE="go auto"
CURSOR_BIN=$MOCK_PRE_CURSOR
CLAUDE_BIN=$MOCK_CLAUDE
CURSOR_IDE_RUNNING=1
EOF
PREFLIGHT_ERR="$TMP/preflight-stderr.log"
rm -f "$LOG_PRE_CURSOR" "$PREFLIGHT_ERR"
(cd "$PREFLIGHT_WORK" && ORCHESTRATE_AGENT_CONF="$PREFLIGHT_CONF" \
  bash "$PREFLIGHT_WORK/.orchestrate/bin/run-job.sh" tend) >/dev/null 2>"$PREFLIGHT_ERR" || true
if ! grep -q 'can only be used in a function' "$PREFLIGHT_ERR" 2>/dev/null; then
  ok "tend preflight has no 'local outside function' error (BC0E regression)"
else
  fail "run-job.sh aborts with 'local: can only be used in a function' — BC0E bug regressed: $(grep -m1 'can only be used' "$PREFLIGHT_ERR")"
fi
if [[ -f "$LOG_PRE_CURSOR" ]]; then
  ok "tend dispatches agent after requeue preflight (no silent abort)"
else
  fail "agent not dispatched — preflight aborted before dispatch ($(tail -1 "$PREFLIGHT_ERR" 2>/dev/null))"
fi

# Static guard: no `local` may appear in a top-level case branch. Strip function
# bodies (name() { ... }) and assert no `local` survives in the remaining top-level code.
NO_LOCAL_TOPLEVEL="$(awk '
  /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ { depth=1; next }
  depth>0 {
    n=gsub(/\{/,"{"); m=gsub(/\}/,"}"); depth+=n-m;
    if (depth<=0) depth=0;
    next
  }
  /(^|[[:space:];])local[[:space:]]/ { print NR": "$0 }
' "$RUN_JOB_SRC")"
if [[ -z "$NO_LOCAL_TOPLEVEL" ]]; then
  ok "no 'local' keyword outside a function in run-job.sh source"
else
  fail "'local' used outside a function (will abort under set -e):\n$NO_LOCAL_TOPLEVEL"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 68A1: concurrent-tend lock race + registry-corruption regression tests
# ─────────────────────────────────────────────────────────────────────────────
echo "13. lock race + registry off-by-one (task 68A1)"
LOCKTMP="$(mktemp -d "${TMPDIR:-/tmp}/run-job-lock.XXXXXX")"
mkdir -p "$LOCKTMP/.orchestrate"
# Extract the pure-bash funcs under test from the run-job.sh under test; stub log_heartbeat.
FUNCS="$LOCKTMP/funcs.sh"
{
  echo 'log_heartbeat(){ :; }'
  grep -E '^LOCK_STALE_GRACE=' "$RUN_JOB"
  sed -n '/^acquire_tend_lock()/,/^}/p;/^refresh_tend_lock()/,/^}/p;/^mark_pending_tasks_as_running()/,/^}/p;/^repair_registry_rows()/,/^}/p' "$RUN_JOB"
} > "$FUNCS"
LPROJ="$LOCKTMP/.orchestrate/project.md"

# 13a. mark_pending_tasks_as_running stamps last_activity in $7, never the phantom $8
cat > "$LPROJ" << 'PEOF'
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| 20260627-mp01 | pending row | auto | 1 | pending |  |
PEOF
( export ROOT="$LOCKTMP"; source "$FUNCS"; mark_pending_tasks_as_running ) || true
if awk -F'|' '/mp01/{s=$6;a=$7;t=$8;gsub(/ /,"",s);gsub(/ /,"",t);gsub(/^[ ]+|[ ]+$/,"",a); exit !(s=="running" && a ~ /Z$/ && t=="" && NF==8)}' "$LPROJ"; then
  ok "mark_pending stamps last_activity in \$7 (no phantom \$8 — corruption root cause)"
else
  fail "mark_pending off-by-one regressed: $(grep mp01 "$LPROJ")"
fi

# 13b. repair_registry_rows normalizes a malformed phantom-field row to NF==8 + trailing pipe
printf '## Task Registry\n| ID | summary | mode | current_phase | status | last_activity |\n|----|----|----|----|----|----|\n| 20260627-rr01 | corrupt | auto | 1 | running | 2026-06-27T11:00:00Z | 2026-06-27T11:05:00Z \n' > "$LPROJ"
( export ROOT="$LOCKTMP"; source "$FUNCS"; repair_registry_rows ) || true
if awk -F'|' '/rr01/{exit !(NF==8)}' "$LPROJ" && grep -qE '\| 20260627-rr01 \|.*\| running \| 2026-06-27T11:00:00Z \|$' "$LPROJ"; then
  ok "repair_registry_rows drops phantom field, restores trailing pipe (NF==8)"
else
  fail "repair_registry_rows did not normalize malformed row: $(grep rr01 "$LPROJ")"
fi

# acquire_tend_lock helper: returns "ACQUIRED" on stdout iff the lock was taken.
# (acquire calls exit 0 on backoff, so the trailing echo only runs on success.)
acquire_result() { ( export ROOT="$LOCKTMP"; source "$FUNCS"; acquire_tend_lock && echo ACQUIRED ) 2>/dev/null || true; }
LK="$LOCKTMP/.orchestrate/.tend.lock"

# 13c. NEVER steal a lock whose owner PID is alive — even with an ancient mtime
#      (this is the exact race: a 300s launchd cycle barging into a long live cycle)
rm -f "$LK"
sleep 30 & LIVEPID=$!
printf '%s %s\n' "$LIVEPID" "2020-01-01T00:00:00Z" > "$LK"; touch -t 202001010000 "$LK"
if [[ "$(acquire_result)" != *ACQUIRED* ]] && grep -q "^$LIVEPID " "$LK" 2>/dev/null; then
  ok "acquire_tend_lock backs off a LIVE owner regardless of age (race fixed)"
else
  fail "acquire_tend_lock stole a live owner's lock — concurrent-tend race not fixed"
fi
kill "$LIVEPID" 2>/dev/null || true; wait "$LIVEPID" 2>/dev/null || true

# 13d. reclaim a DEAD owner's lock once it is stale (age > LOCK_STALE_GRACE)
sleep 1 & DEADPID=$!; kill "$DEADPID" 2>/dev/null || true; wait "$DEADPID" 2>/dev/null || true
printf '%s %s\n' "$DEADPID" "2020-01-01T00:00:00Z" > "$LK"; touch -t 202001010000 "$LK"
if [[ "$(acquire_result)" == *ACQUIRED* ]]; then
  ok "acquire_tend_lock reclaims a dead+stale owner's lock"
else
  fail "acquire_tend_lock failed to reclaim a dead+stale lock (would deadlock tend)"
fi

# 13e. do NOT reclaim a DEAD owner's lock while still fresh (< grace) — avoids racing a just-started session
printf '%s %s\n' "$DEADPID" "2026-06-27T00:00:00Z" > "$LK"   # fresh mtime (just written)
if [[ "$(acquire_result)" != *ACQUIRED* ]]; then
  ok "acquire_tend_lock waits out the grace window before reclaiming a dead lock"
else
  fail "acquire_tend_lock reclaimed a dead lock before the grace window"
fi

echo ""
echo "── Results ───────────────────────────────────────"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "──────────────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]] && echo "  ALL TESTS PASSED" && exit 0
echo "  SOME TESTS FAILED — see above" && exit 1
