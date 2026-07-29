#!/usr/bin/env bash
# test-churn-guard.sh — churn guard: block tasks re-processed 3× (poison-task net).
#
# Drives a task through 3 requeue cycles and asserts:
#   - the shared counter increments on every requeue (task-file AND no-file ghost)
#   - the 3rd cycle parks it as blocked (needs_human + bypassed_at + bypass_reason)
#   - an async investigation job is auto-filed (source:self, mode:auto, triggered_by)
#   - a second run does NOT double-file (dedup on triggered_by)
#   - the counter resets to 0 on complete (cg_reset)
#   - registry NF==8 invariant is preserved across the park
set -uo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$PROJECT_ROOT/bin" ]] || { echo "FATAL: $PROJECT_ROOT/bin not found — PROJECT_ROOT path computation is broken (expected .../task-orchestrate/bin)" >&2; exit 1; }
CG="${CG:-$PROJECT_ROOT/bin/churn-guard.sh}"
CG_SRC="${CG_SRC:-$CG}"
REQUEUE="${REQUEUE:-$PROJECT_ROOT/bin/requeue-unblocked.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=""
cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"; }
trap cleanup EXIT

echo ""
echo "── churn guard — block tasks re-processed 3× — test suite ───"

echo ""
echo "0. Prerequisites"
[[ -f "$CG" ]] && ok "churn-guard.sh found" || { fail "churn-guard.sh missing at $CG"; exit 1; }
if [[ -f "$CG_SRC" ]] && cmp -s "$CG_SRC" "$CG" 2>/dev/null; then
  ok "installed churn-guard.sh matches ai-toolbox source"
elif [[ -f "$CG_SRC" ]]; then
  fail "installed churn-guard.sh stale vs ai-toolbox source — run sync"
fi
bash -n "$CG" 2>/dev/null && ok "churn-guard.sh bash syntax valid" || fail "churn-guard.sh syntax error"

# ── temp control plane ──────────────────────────────────────────────────────
TMP="$(mktemp -d "${TMPDIR:-/tmp}/churn-test.XXXXXX")"
W="$TMP/work"
mkdir -p "$W/.orchestrate/logs" "$W/.orchestrate/tasks" "$W/.orchestrate/bin" \
  "$W/.orchestrate/inbox/processed"
cp "$CG" "$REQUEUE" "$W/.orchestrate/bin/" 2>/dev/null || true
CGW="$W/.orchestrate/bin/churn-guard.sh"

status_of() {
  local id="$1"
  awk -F'|' -v id="$id" '$0 ~ "\\| "id" \\|" { gsub(/^[ \t]+|[ \t]+$/,"",$6); print $6; exit }' \
    "$W/.orchestrate/project.md"
}
malformed_rows() {
  awk -F'|' '/^\|[[:space:]]*[0-9A-Za-z]/ && $2 !~ /^[[:space:]]*ID[[:space:]]*$/ && $2 !~ /^-+$/ {
    t=$8; gsub(/[[:space:]]/,"",t); if (NF!=8 || t!="") c++ } END{print c+0}' \
    "$W/.orchestrate/project.md"
}

# ── Case A: task WITH a task file, driven through 3 increments ───────────────
ID=20260628-poison
cat > "$W/.orchestrate/tasks/$ID.md" <<EOF
# $ID — poison task
source: self
mode: auto
### Phase 1
status: pending
EOF
cat > "$W/.orchestrate/project.md" <<EOF
# Orchestrate — churn-test
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| $ID | poison task | auto | 1 | needs_human | 2026-01-01T00:00:00Z |
EOF

echo ""
echo "1. Counter increments on each requeue (task-file case)"
c1="$(bash "$CGW" cg_increment "$W" "$ID")"
c2="$(bash "$CGW" cg_increment "$W" "$ID")"
if [[ "$c1" == "1" && "$c2" == "2" ]]; then
  ok "increment 1,2 (task file + sidecar) — got $c1,$c2"
else
  fail "expected 1,2 — got $c1,$c2"
fi

echo ""
echo "2. requeue_count: line persisted in the task file"
if grep -qE '^requeue_count:[[:space:]]*2' "$W/.orchestrate/tasks/$ID.md"; then
  ok "task file carries requeue_count: 2"
else
  fail "requeue_count line missing/wrong: $(grep requeue_count "$W/.orchestrate/tasks/$ID.md" || echo none)"
fi

echo ""
echo "3. Below threshold (count=2): park_if_churned does NOT park"
if bash "$CGW" cg_park_if_churned "$W" "$ID" 2>/dev/null; then
  fail "parked at count=2 (should be below threshold 3)"
else
  ok "not parked below threshold"
fi
[[ "$(status_of "$ID")" == "needs_human" ]] && ok "registry still needs_human (untouched, not bypassed)" \
  || fail "registry status unexpectedly $(status_of "$ID")"
grep -q '^bypassed_at:' "$W/.orchestrate/tasks/$ID.md" && fail "bypass marker written too early" \
  || ok "no bypass marker yet (below threshold)"

echo ""
echo "4. 3rd cycle reaches threshold → parked as blocked"
c3="$(bash "$CGW" cg_increment "$W" "$ID")"
[[ "$c3" == "3" ]] && ok "increment reached 3" || fail "expected 3 — got $c3"
if bash "$CGW" cg_park_if_churned "$W" "$ID" 2>/dev/null; then
  ok "park_if_churned parked at threshold (returned 0)"
else
  fail "park_if_churned did NOT park at count=3"
fi
[[ "$(status_of "$ID")" == "needs_human" ]] && ok "registry forced to needs_human" \
  || fail "registry not needs_human: $(status_of "$ID")"
if grep -q '^bypassed_at:' "$W/.orchestrate/tasks/$ID.md" \
   && grep -qE '^bypass_reason:.*churn — re-processed 3×' "$W/.orchestrate/tasks/$ID.md"; then
  ok "bypassed_at: + bypass_reason: churn — re-processed 3× written"
else
  fail "bypass markers missing: $(grep -E '^(bypassed_at|bypass_reason):' "$W/.orchestrate/tasks/$ID.md" || echo none)"
fi

echo ""
echo "5. Investigation inbox job auto-filed (source:self, mode:auto, triggered_by)"
INV="$(ls "$W/.orchestrate/inbox/"investigate-churn-$ID-*.md 2>/dev/null | head -1)"
if [[ -n "$INV" ]] \
   && grep -qE '^source:[[:space:]]*self' "$INV" \
   && grep -qE '^mode:[[:space:]]*auto' "$INV" \
   && grep -qE "^triggered_by:[[:space:]]*$ID" "$INV"; then
  ok "investigation job filed with correct header"
else
  fail "investigation job missing/malformed: ${INV:-none}"
fi

echo ""
echo "6. Heartbeat carries the churn-guard blocked line"
if grep -qE "churn-guard — blocked $ID after 3 re-processings; filed investigate-churn-$ID" \
   "$W/.orchestrate/logs/heartbeat.log" 2>/dev/null; then
  ok "heartbeat blocked-line present"
else
  fail "heartbeat blocked-line missing: $(grep churn-guard "$W/.orchestrate/logs/heartbeat.log" 2>/dev/null || echo none)"
fi

echo ""
echo "7. Second run does NOT double-file (dedup on triggered_by)"
before="$(ls "$W/.orchestrate/inbox/"investigate-churn-$ID-*.md 2>/dev/null | wc -l | tr -d ' ')"
bash "$CGW" cg_park_if_churned "$W" "$ID" >/dev/null 2>&1 || true
after="$(ls "$W/.orchestrate/inbox/"investigate-churn-$ID-*.md 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$before" == "1" && "$after" == "1" ]]; then
  ok "no double-file (before=$before after=$after)"
else
  fail "double-filed: before=$before after=$after"
fi

echo ""
echo "8. Registry NF==8 invariant preserved across park"
mr="$(malformed_rows)"
[[ "$mr" == "0" ]] && ok "0 malformed rows (NF==8 with empty trailing field)" \
  || fail "$mr malformed registry row(s) after park"

echo ""
echo "9. cg_reset (on complete) zeros the counter + clears requeue_count line"
bash "$CGW" cg_reset "$W" "$ID"
rc="$(bash "$CGW" cg_count "$W" "$ID")"
[[ "$rc" == "0" ]] && ok "counter reset to 0" || fail "counter not reset: $rc"
grep -q '^requeue_count:' "$W/.orchestrate/tasks/$ID.md" \
  && fail "requeue_count line still present after reset" \
  || ok "requeue_count line removed on reset"

# ── Case B: NO task file (ghost-reset auto job) — sidecar-only counter ───────
echo ""
echo "10. No-task-file (ghost) case: sidecar counter + park creates bypass file"
GID=20260628-ghost
cat > "$W/.orchestrate/project.md" <<EOF
# Orchestrate — churn-test
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| $GID | stalled auto job (no file) | auto | 1 | running | 2026-01-01T00:00:00Z |
EOF
g1="$(bash "$CGW" cg_increment "$W" "$GID")"
g2="$(bash "$CGW" cg_increment "$W" "$GID")"
g3="$(bash "$CGW" cg_increment "$W" "$GID")"
if [[ "$g1$g2$g3" == "123" ]]; then
  ok "ghost counter increments 1,2,3 via sidecar (no task file)"
else
  fail "ghost increments wrong: $g1,$g2,$g3"
fi
[[ ! -f "$W/.orchestrate/tasks/$GID.md" ]] && ok "no task file existed before park" \
  || fail "unexpected pre-existing ghost task file"
if bash "$CGW" cg_park_if_churned "$W" "$GID" 2>/dev/null; then
  ok "ghost parked at threshold"
else
  fail "ghost not parked at count=3"
fi
if [[ -f "$W/.orchestrate/tasks/$GID.md" ]] \
   && grep -qE '^bypass_reason:.*churn — re-processed 3×' "$W/.orchestrate/tasks/$GID.md"; then
  ok "park created a bypass task file for the ghost"
else
  fail "ghost bypass file missing/malformed"
fi
[[ "$(status_of "$GID")" == "needs_human" ]] && ok "ghost registry forced to needs_human" \
  || fail "ghost registry not needs_human: $(status_of "$GID")"
[[ -n "$(ls "$W/.orchestrate/inbox/"investigate-churn-$GID-*.md 2>/dev/null)" ]] \
  && ok "ghost investigation job filed" || fail "ghost investigation job missing"
[[ "$(malformed_rows)" == "0" ]] && ok "ghost park preserved NF==8 invariant" \
  || fail "ghost park broke invariant: $(malformed_rows) bad row(s)"

# ── Case C: end-to-end via requeue-unblocked.sh (real requeue site) ──────────
echo ""
echo "11. End-to-end: requeue-unblocked.sh parks after 3 re-queues (real site)"
EID=20260628-loop
cat > "$W/.orchestrate/tasks/$EID.md" <<EOF
# $EID — looping task
source: self
mode: auto
human_resolution: retry it
### Phase 1
status: pending
EOF
cat > "$W/.orchestrate/project.md" <<EOF
# Orchestrate — churn-test
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| $EID | looping task | auto | 1 | needs_human | 2026-01-01T00:00:00Z |
EOF
parked_cycle=0
for cyc in 1 2 3 4; do
  bash "$W/.orchestrate/bin/requeue-unblocked.sh" "$W" >/dev/null 2>&1 || true
  if [[ "$(status_of "$EID")" == "pending" ]]; then
    # re-block (simulate another failed run) so it re-queues next cycle
    sed -i '' "s/| $EID | looping task | auto | 1 | pending |/| $EID | looping task | auto | 1 | needs_human |/" \
      "$W/.orchestrate/project.md" 2>/dev/null || \
      sed -i "s/| $EID | looping task | auto | 1 | pending |/| $EID | looping task | auto | 1 | needs_human |/" \
      "$W/.orchestrate/project.md" 2>/dev/null || true
  fi
  if grep -q "churn-guard parked $EID" "$W/.orchestrate/logs/heartbeat.log" 2>/dev/null && [[ "$parked_cycle" == "0" ]]; then
    parked_cycle="$cyc"
  fi
done
if [[ "$parked_cycle" == "3" ]]; then
  ok "requeue-unblocked.sh parked on the 3rd cycle (cycles 1-2 re-queued)"
else
  fail "park happened on cycle $parked_cycle (expected 3)"
fi
[[ "$(status_of "$EID")" == "needs_human" ]] && ok "final status needs_human (parked)" \
  || fail "final status $(status_of "$EID")"
einv="$(ls "$W/.orchestrate/inbox/"investigate-churn-$EID-*.md 2>/dev/null | wc -l | tr -d ' ')"
[[ "$einv" == "1" ]] && ok "exactly 1 investigation job filed (no double-file across cycles)" \
  || fail "expected 1 investigation file, got $einv"
[[ "$(malformed_rows)" == "0" ]] && ok "end-to-end preserved NF==8 invariant" \
  || fail "end-to-end broke invariant: $(malformed_rows) bad row(s)"

echo ""
echo "── Case C: 19D7 outcome-aware investigate-churn suppression ────────────────"
# A mid-flight reset can bump a task's churn counter to the threshold even though
# the task is actively completing. When the target has reached `complete`, its
# churn count was a false positive — no investigate-churn ticket should linger.

CID=20260628-midflight
cat > "$W/.orchestrate/project.md" <<EOF
# Orchestrate — churn-test
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| $CID | mid-flight completed task | auto | 1 | complete | 2026-01-01T00:00:00Z |
EOF

echo ""
echo "12. cg_file_investigation does NOT file when target row is already complete"
bash "$CGW" cg_file_investigation "$W" "$CID" >/dev/null 2>&1 || true
c11="$(ls "$W/.orchestrate/inbox/"investigate-churn-$CID-*.md 2>/dev/null | wc -l | tr -d ' ')"
[[ "$c11" == "0" ]] && ok "no investigation filed for complete target (suppressed)" \
  || fail "filed $c11 investigation ticket(s) for a complete target"

echo ""
echo "13. cg_close_investigation auto-closes a live ticket when target completes"
# Simulate a ticket filed while the task was still running (status not complete),
# then the task completes and cg_reset → cg_close_investigation moves it out.
cat > "$W/.orchestrate/project.md" <<EOF
# Orchestrate — churn-test
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| $CID | mid-flight completed task | auto | 1 | needs_human | 2026-01-01T00:00:00Z |
EOF
bash "$CGW" cg_file_investigation "$W" "$CID" >/dev/null 2>&1 || true
filed="$(ls "$W/.orchestrate/inbox/"investigate-churn-$CID-*.md 2>/dev/null | wc -l | tr -d ' ')"
# Now the task completes; cg_reset (called on complete) closes the ticket.
bash "$CGW" cg_reset "$W" "$CID" >/dev/null 2>&1 || true
active="$(ls "$W/.orchestrate/inbox/"investigate-churn-$CID-*.md 2>/dev/null | wc -l | tr -d ' ')"
proc="$(ls "$W/.orchestrate/inbox/processed/"investigate-churn-$CID-*.md 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$filed" == "1" && "$active" == "0" && "$proc" == "1" ]]; then
  ok "ticket filed while running, then auto-closed to processed/ on complete"
else
  fail "filed=$filed active=$active processed=$proc (expected 1/0/1)"
fi
if [[ "$proc" == "1" ]] && grep -q '^closed_reason:' "$W/.orchestrate/inbox/processed/"investigate-churn-$CID-*.md 2>/dev/null; then
  ok "closed ticket carries closed_reason marker"
else
  fail "closed ticket missing closed_reason marker"
fi

echo ""
echo "14. cg_close_investigation closes a DRAINED investigate-churn REGISTRY row"
# Regression (AEE0): the churn ticket can be drained into its own registry row and
# moved to processed/ BEFORE the target completes. cg_close_investigation's live-
# inbox scan then finds nothing, so the moot investigation runs as a full task.
# When the target is complete, the drained row must also be auto-closed to complete.
TGT=20260704-inbox-3666
INVID=20260704-inbox-AEE0
cat > "$W/.orchestrate/project.md" <<EOF
# Orchestrate — churn-test
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| $TGT | Run inbox-log-analyzer | auto | 1 | complete | 2026-01-01T00:00:00Z |
| $INVID | Investigate churn — $TGT re-processed 3× | auto | 1 | needs_human | 2026-01-01T00:00:00Z |
EOF
# ghost task file for the drained investigation (as a real ghost-reset would have)
printf '# %s — parked by churn guard\nsource: self\nmode: auto\n' "$INVID" > "$W/.orchestrate/tasks/$INVID.md"
bash "$CGW" cg_close_investigation "$W" "$TGT" >/dev/null 2>&1 || true
if [[ "$(status_of "$INVID")" == "complete" ]]; then
  ok "drained investigate-churn row auto-closed to complete when target complete"
else
  fail "drained investigation row status=$(status_of "$INVID") (expected complete)"
fi
[[ ! -f "$W/.orchestrate/tasks/$INVID.md" ]] && ok "ghost task file for closed investigation removed" \
  || fail "ghost task file not removed"
[[ "$(malformed_rows)" == "0" ]] && ok "drained-row close preserved NF==8 invariant" \
  || fail "drained-row close broke invariant: $(malformed_rows) bad row(s)"
# Idempotent: a second call is a clean no-op (row already complete → skipped)
bash "$CGW" cg_close_investigation "$W" "$TGT" >/dev/null 2>&1 || true
[[ "$(status_of "$INVID")" == "complete" && "$(malformed_rows)" == "0" ]] \
  && ok "second close call is an idempotent no-op" \
  || fail "second close call mutated a terminal row"

echo ""
echo "15. cg_close_investigation does NOT close sibling 'Review of/Tests for' follow-up rows"
# Regression (4474): the 6b auto-enqueue files follow-up rows summarized
# `Review of Investigate churn — <target> …` and `Tests for Investigate churn —
# <target> …`. An UNANCHORED substring match (index()>0) wrongly matched these active
# rows and rm'd their task files. The match must be ANCHORED to the summary prefix
# (index()==1), so only the genuine `Investigate churn — <target> …` row is closed.
TGT=20260704-inbox-3666
INVID=20260704-inbox-AEE0
REVID=20260704-inbox-4474
TSTID=20260704-inbox-B32D
cat > "$W/.orchestrate/project.md" <<EOF
# Orchestrate — churn-test
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| $TGT | Run inbox-log-analyzer | auto | 1 | complete | 2026-01-01T00:00:00Z |
| $INVID | Investigate churn — $TGT re-processed 3× | auto | 1 | needs_human | 2026-01-01T00:00:00Z |
| $REVID | Review of Investigate churn — $TGT re-processed 3× | auto | 1 | running | 2026-01-01T00:00:00Z |
| $TSTID | Tests for Investigate churn — $TGT re-processed 3× | auto | 1 | running | 2026-01-01T00:00:00Z |
EOF
printf '# %s — parked by churn guard\nsource: self\nmode: auto\n' "$INVID" > "$W/.orchestrate/tasks/$INVID.md"
printf '# %s review\nmode: auto\n' "$REVID" > "$W/.orchestrate/tasks/$REVID.md"
printf '# %s tests\nmode: auto\n' "$TSTID" > "$W/.orchestrate/tasks/$TSTID.md"
bash "$CGW" cg_close_investigation "$W" "$TGT" >/dev/null 2>&1 || true
[[ "$(status_of "$INVID")" == "complete" ]] \
  && ok "genuine investigate-churn row still auto-closed with siblings present" \
  || fail "genuine investigation row status=$(status_of "$INVID") (expected complete)"
[[ "$(status_of "$REVID")" == "running" ]] \
  && ok "'Review of Investigate churn' sibling row left untouched (running)" \
  || fail "sibling review row wrongly changed to $(status_of "$REVID")"
[[ "$(status_of "$TSTID")" == "running" ]] \
  && ok "'Tests for Investigate churn' sibling row left untouched (running)" \
  || fail "sibling tests row wrongly changed to $(status_of "$TSTID")"
[[ -f "$W/.orchestrate/tasks/$REVID.md" && -f "$W/.orchestrate/tasks/$TSTID.md" ]] \
  && ok "sibling task files preserved (not rm'd)" \
  || fail "a sibling task file was wrongly deleted"
[[ ! -f "$W/.orchestrate/tasks/$INVID.md" ]] \
  && ok "only the genuine investigation ghost task file removed" \
  || fail "genuine investigation ghost task file not removed"

echo ""
echo "── Case D: ED94 transient-infra ghost-reset not counted ────────────────────"
# A ghost-reset caused by a transient infra death (agent log shows ONLY a connection
# error, ZERO progress) hit no poison and made no progress — it must NOT count toward
# the poison-park threshold (retried like a C3 one-shot transient). A run that made
# real progress, or died on no recognized transient error, still counts as today.
DID=20260705-transient
mkdir -p "$W/.orchestrate/logs"

echo ""
echo "16. Transient-only agent log ⇒ cg_increment_unless_transient skips the bump"
# clear any prior counters/logs from earlier cases for a clean count
rm -f "$W/.orchestrate/logs/requeue-counts.tsv" 2>/dev/null || true
: > "$W/.orchestrate/logs/heartbeat.log"
: > "$W/.orchestrate/logs/20260705-000000-agent.log"
printf 'Starting run...\nAPI Error: Connection closed mid-response\n' \
  > "$W/.orchestrate/logs/20260705-000000-agent.log"
r_t="$(bash "$CGW" cg_increment_unless_transient "$W" "$DID")"
c_t="$(bash "$CGW" cg_count "$W" "$DID")"
if [[ "$r_t" == "transient" && "$c_t" == "0" ]]; then
  ok "transient log: bump skipped (returned '$r_t', count=$c_t)"
else
  fail "expected transient/0 — got '$r_t'/$c_t"
fi
if grep -qE "churn-guard — transient-infra ghost-reset for $DID, not counted" \
   "$W/.orchestrate/logs/heartbeat.log" 2>/dev/null; then
  ok "heartbeat 'transient-infra ghost-reset … not counted' line written"
else
  fail "transient heartbeat line missing: $(grep churn-guard "$W/.orchestrate/logs/heartbeat.log" 2>/dev/null || echo none)"
fi

echo ""
echo "17. A run that made progress (## PHASE OUTPUT) still counts"
GDID=20260705-progress
printf 'work in progress\n## PHASE OUTPUT\nsummary: did real work then died\n' \
  > "$W/.orchestrate/logs/20260705-010000-agent.log"   # newer mtime → latest
r_p="$(bash "$CGW" cg_increment_unless_transient "$W" "$GDID")"
c_p="$(bash "$CGW" cg_count "$W" "$GDID")"
if [[ "$r_p" == "1" && "$c_p" == "1" ]]; then
  ok "progress log: counted normally (returned '$r_p', count=$c_p)"
else
  fail "expected 1/1 — got '$r_p'/$c_p"
fi

echo ""
echo "18. A death with no recognized transient error still counts (conservative)"
NDID=20260705-noerr
printf 'ordinary output, clean-ish, no recognized transient error\n' \
  > "$W/.orchestrate/logs/20260705-020000-agent.log"   # newer mtime → latest
r_n="$(bash "$CGW" cg_increment_unless_transient "$W" "$NDID")"
c_n="$(bash "$CGW" cg_count "$W" "$NDID")"
if [[ "$r_n" == "1" && "$c_n" == "1" ]]; then
  ok "no-transient-error log: counted normally (returned '$r_n', count=$c_n)"
else
  fail "expected 1/1 — got '$r_n'/$c_n"
fi

echo ""
echo "19. A genuinely non-converging task still parks at the threshold"
# latest log is non-transient (progress) so every bump counts; drive to threshold
PDID=20260705-poison
cat > "$W/.orchestrate/project.md" <<EOF
# Orchestrate — churn-test
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| $PDID | non-converging task | auto | 1 | needs_human | 2026-01-01T00:00:00Z |
EOF
printf 'progress then fail\n## PHASE OUTPUT\nsummary: partial\n' \
  > "$W/.orchestrate/logs/20260705-030000-agent.log"   # newest → latest, non-transient
bash "$CGW" cg_increment_unless_transient "$W" "$PDID" >/dev/null
bash "$CGW" cg_increment_unless_transient "$W" "$PDID" >/dev/null
p3="$(bash "$CGW" cg_increment_unless_transient "$W" "$PDID")"
[[ "$p3" == "3" ]] && ok "non-transient bumps reach 3" || fail "expected 3 — got $p3"
if bash "$CGW" cg_park_if_churned "$W" "$PDID" 2>/dev/null; then
  ok "non-converging task still parked at threshold (unchanged behavior)"
else
  fail "non-converging task did NOT park at count=3"
fi
[[ "$(status_of "$PDID")" == "needs_human" ]] && ok "parked row forced to needs_human" \
  || fail "parked row status=$(status_of "$PDID")"
[[ "$(malformed_rows)" == "0" ]] && ok "transient-guard park preserved NF==8 invariant" \
  || fail "park broke invariant: $(malformed_rows) bad row(s)"

echo ""
echo "── Case E: BC7C since-based agent-log attribution for async detectors ──────"
# rescue.sh fires on its own schedule, potentially long after a row went stale —
# unlike run-job.sh's synchronous reset_stale_running_tasks, "the latest
# *-agent.log on disk right now" is NOT reliably the log for the dispatch attempt
# that made THIS row stale; an unrelated, later, successful cycle can have written
# a newer log in between. cg__agent_log_since/SINCE_EPOCH fixes the attribution.

echo ""
echo "20. cg__agent_log_since picks the EARLIEST log at/after since_epoch, not the newest overall"
rm -f "$W/.orchestrate/logs"/*-agent.log
: > "$W/.orchestrate/logs/aaa-agent.log"
sleep 1
: > "$W/.orchestrate/logs/bbb-agent.log"
sleep 1
: > "$W/.orchestrate/logs/ccc-agent.log"
since_epoch="$(date -r "$W/.orchestrate/logs/bbb-agent.log" +%s)"
picked="$(bash "$CGW" cg__agent_log_since "$W" "$since_epoch")"
if [[ "$picked" == *bbb-agent.log ]]; then
  ok "cg__agent_log_since($since_epoch) picked bbb (earliest at/after cutoff), not ccc (overall latest)"
else
  fail "expected bbb-agent.log — got '$picked'"
fi

echo ""
echo "21. cg_increment_unless_transient(SINCE_EPOCH) correctly exempts an old async transient crash even once a newer unrelated non-transient log exists"
rm -f "$W/.orchestrate/logs/requeue-counts.tsv" 2>/dev/null || true
: > "$W/.orchestrate/logs/heartbeat.log"
rm -f "$W/.orchestrate/logs"/*-agent.log
printf 'Starting run...\nAPI Error: Connection closed mid-response\n' > "$W/.orchestrate/logs/crash-agent.log"
stale_since="$(date -r "$W/.orchestrate/logs/crash-agent.log" +%s)"
sleep 1
printf 'ordinary unrelated successful session, no transient error, no progress marker\n' > "$W/.orchestrate/logs/later-unrelated-agent.log"
# WITHOUT since_epoch: naive "latest on disk" attribution picks the later unrelated
# log and wrongly counts the bump — documents the exact bug this case guards against.
r_naive="$(bash "$CGW" cg_increment_unless_transient "$W" "20260706-async-transient-naive")"
[[ "$r_naive" == "1" ]] && ok "sanity: naive (no SINCE_EPOCH) attribution miscounts the async crash as real (the bug being fixed)" \
  || fail "sanity expectation changed — got '$r_naive' (re-check test assumptions)"
# WITH since_epoch = the crash log's own mtime: correctly attributes to the crash
# log (not the later unrelated one) and exempts the bump as transient.
ADID=20260706-async-transient
r_since="$(bash "$CGW" cg_increment_unless_transient "$W" "$ADID" "$stale_since")"
c_since="$(bash "$CGW" cg_count "$W" "$ADID")"
if [[ "$r_since" == "transient" && "$c_since" == "0" ]]; then
  ok "SINCE_EPOCH attribution correctly exempts the async transient crash (returned '$r_since', count=$c_since)"
else
  fail "expected transient/0 — got '$r_since'/$c_since"
fi

echo ""
echo "── Case F: AD25 shell_incapable dispatch-starvation not counted ────────────"
# A ghost-reset caused by dispatch-side shell-capability starvation (BOTH runners
# failed run-job.sh's shell probe that cycle — run_with_fallback's "no shell
# capability; deferred" heartbeat line) means no session that cycle ever
# demonstrated it could run a Bash command, so it could not have reached the
# task's own phase work either. It must NOT count toward churn like a genuine
# phase failure (20260728-inbox-36DC / AD25 investigation: a perfectly healthy
# task was parked purely from 3 consecutive dispatch-starvation cycles).

echo ""
echo "22. shell_incapable-only ghost-reset ⇒ cg_increment_unless_transient skips the bump"
rm -f "$W/.orchestrate/logs/requeue-counts.tsv" 2>/dev/null || true
rm -f "$W/.orchestrate/logs"/*-agent.log
: > "$W/.orchestrate/logs/heartbeat.log"
SID=20260707-shellincapable
since_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "2026-07-07T00:00:00Z" +%s)"
printf '[2026-07-07T00:05:00Z] run-job — cursor session has no shell capability; fallback to claude [pid=1]\n' >> "$W/.orchestrate/logs/heartbeat.log"
printf '[2026-07-07T00:05:10Z] run-job — claude session has no shell capability; deferred [pid=1]\n' >> "$W/.orchestrate/logs/heartbeat.log"
r_si="$(bash "$CGW" cg_increment_unless_transient "$W" "$SID" "$since_epoch")"
c_si="$(bash "$CGW" cg_count "$W" "$SID")"
if [[ "$r_si" == "shell_incapable" && "$c_si" == "0" ]]; then
  ok "shell_incapable-only reset: bump skipped (returned '$r_si', count=$c_si)"
else
  fail "expected shell_incapable/0 — got '$r_si'/$c_si"
fi
if grep -qE "churn-guard — dispatch-starvation \(shell_incapable\) ghost-reset for $SID, not counted" \
   "$W/.orchestrate/logs/heartbeat.log" 2>/dev/null; then
  ok "heartbeat 'dispatch-starvation ... not counted' line written"
else
  fail "shell_incapable heartbeat line missing: $(grep churn-guard "$W/.orchestrate/logs/heartbeat.log" 2>/dev/null || echo none)"
fi

echo ""
echo "23. 3 consecutive shell_incapable-only cycles do NOT park at CG_THRESHOLD"
bash "$CGW" cg_increment_unless_transient "$W" "$SID" "$since_epoch" >/dev/null
bash "$CGW" cg_increment_unless_transient "$W" "$SID" "$since_epoch" >/dev/null
c_si3="$(bash "$CGW" cg_count "$W" "$SID")"
[[ "$c_si3" == "0" ]] && ok "counter stays 0 after 3 shell_incapable-only cycles" \
  || fail "expected counter 0 after 3 shell_incapable cycles — got $c_si3"
if bash "$CGW" cg_park_if_churned "$W" "$SID" 2>/dev/null; then
  fail "shell_incapable-only task wrongly parked at threshold"
else
  ok "shell_incapable-only task NOT parked (correctly stayed below threshold)"
fi

echo ""
echo "24. Real progress in the window still counts even with a shell_incapable heartbeat line present"
PSID=20260707-shellincapable-but-progress
rm -f "$W/.orchestrate/logs"/*-agent.log
printf 'did real work\n## PHASE OUTPUT\nsummary: reached phase work despite an unrelated shell_incapable cycle\n' \
  > "$W/.orchestrate/logs/20260707-000100-agent.log"
r_psi="$(bash "$CGW" cg_increment_unless_transient "$W" "$PSID" "$since_epoch")"
c_psi="$(bash "$CGW" cg_count "$W" "$PSID")"
if [[ "$r_psi" == "1" && "$c_psi" == "1" ]]; then
  ok "progress log disqualifies shell_incapable classification: counted normally (returned '$r_psi', count=$c_psi)"
else
  fail "expected 1/1 — got '$r_psi'/$c_psi"
fi

echo ""
echo "25. A shell_incapable heartbeat line OUTSIDE the since-window (before last_activity) does NOT suppress the bump"
rm -f "$W/.orchestrate/logs"/*-agent.log
OSID=20260707-old-shellincapable
: > "$W/.orchestrate/logs/heartbeat.log"
printf '[2026-07-01T00:00:00Z] run-job — cursor session has no shell capability; fallback to claude [pid=1]\n' >> "$W/.orchestrate/logs/heartbeat.log"
printf '[2026-07-01T00:00:10Z] run-job — claude session has no shell capability; deferred [pid=1]\n' >> "$W/.orchestrate/logs/heartbeat.log"
later_since="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "2026-07-05T00:00:00Z" +%s)"
r_old="$(bash "$CGW" cg_increment_unless_transient "$W" "$OSID" "$later_since")"
c_old="$(bash "$CGW" cg_count "$W" "$OSID")"
if [[ "$r_old" == "1" && "$c_old" == "1" ]]; then
  ok "out-of-window shell_incapable line ignored: counted normally (returned '$r_old', count=$c_old)"
else
  fail "expected 1/1 — got '$r_old'/$c_old"
fi

echo ""
echo "26. A genuinely non-converging task (no shell_incapable signal) still parks at threshold — unweakened"
GSID=20260707-genuine-poison
cat > "$W/.orchestrate/project.md" <<EOF
# Orchestrate — churn-test
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| $GSID | genuinely non-converging task | auto | 1 | needs_human | 2026-01-01T00:00:00Z |
EOF
: > "$W/.orchestrate/logs/heartbeat.log"
rm -f "$W/.orchestrate/logs"/*-agent.log
printf 'progress then fail\n## PHASE OUTPUT\nsummary: partial\n' \
  > "$W/.orchestrate/logs/20260707-010000-agent.log"
bash "$CGW" cg_increment_unless_transient "$W" "$GSID" >/dev/null
bash "$CGW" cg_increment_unless_transient "$W" "$GSID" >/dev/null
g3="$(bash "$CGW" cg_increment_unless_transient "$W" "$GSID")"
[[ "$g3" == "3" ]] && ok "genuine non-converging bumps reach 3" || fail "expected 3 — got $g3"
if bash "$CGW" cg_park_if_churned "$W" "$GSID" 2>/dev/null; then
  ok "genuinely non-converging task still parks at threshold (real churn detection unweakened)"
else
  fail "genuinely non-converging task did NOT park at count=3"
fi
[[ "$(malformed_rows)" == "0" ]] && ok "Case F park preserved NF==8 invariant" \
  || fail "Case F park broke invariant: $(malformed_rows) bad row(s)"

echo ""
echo "── Results ───────────────────────────────────────"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "──────────────────────────────────────────────────"
[[ "$FAIL" -eq 0 ]] && echo "  ALL TESTS PASSED" && exit 0
echo "  SOME TESTS FAILED — see above" && exit 1
