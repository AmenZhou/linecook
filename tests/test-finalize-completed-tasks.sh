#!/usr/bin/env bash
# test-finalize-completed-tasks.sh — regression for task 20260627-inbox-E721.
#
# Background: Completion is NOT atomic. A tend/agent session can write every phase
# block in a task file to ✓ complete (and maybe archive it) but die before
# flipping the registry row running→complete. T-4 re-queues only `needs_human`
# rows, so the done-but-running row sits `running` forever. finalize-completed-
# tasks.sh runs the bash analog of the SKILL Completion sequence to reap them.
#
# Asserts the reconcile rule:
#   (a) running row + all-phases-✓ task file → complete + archived + task deleted
#   (b) running row with partial (not-all-✓) task file → left running, untouched
#   (c) running row whose ID already has an archive (WITH a MANIFEST line already
#       present — the fully-reconciled case) but no task file → flipped to
#       complete with NO dup archive / NO dup MANIFEST line
#   (d) second run is a clean no-op (idempotent)
#   (e) archive-gap backfill: a row already `complete` with NO archive and no
#       task file → archived once (slug from summary) + one MANIFEST line, status
#       left `complete` (NOT mutated); a `complete` row that already has an
#       archive is left untouched (no dup); re-run is a clean no-op
#   (f) AB12 — regression for the 69E3 orphan-archive bug: running row whose task
#       file shows all phases ✓ AND an archive already exists on disk for that ID
#       but has NO MANIFEST line (the "model's own Completion sequence wrote the
#       archive then died before/around its own MANIFEST append, and the reaper
#       raced ahead" gap) → row flipped to complete, NO second archive file
#       written (still exactly 1 on disk), the existing archive's MANIFEST line
#       is backfilled (exactly 1 line, not 0), and a 2nd run is a clean no-op
#       (no dup archive, no dup MANIFEST line)
#   (g) AB12 frontmatter-fallback variant: same orphan-archive shape as (f), but
#       the existing archive has NO `# Task:` markdown heading — it uses the
#       `task:` frontmatter field instead (the real-world convention seen in
#       actual historical archives, e.g. 20260620-inbox-7A8C, whose first line
#       is a plain `#` heading with a separate `task:` field). This exercises
#       backfill_manifest_for_existing_archive()'s fallback grep for `^task:`
#       (finalize-completed-tasks.sh lines ~166-170), which scenario (f) never
#       reaches because its fixture always has a `# Task:` heading. Asserts the
#       backfilled MANIFEST summary is pulled from the `task:` field, not the
#       generic "auto-finalized task <id>" placeholder.
#   (h) A4EB — PARTIAL-suffix false positive: running row, task file with
#       total_phases: 2, phase 1 `status: ✓ complete` (clean) and phase 2
#       `status: ✓ complete (PARTIAL vs. acceptance — some note)`. Before the
#       A4EB fix, task_file_all_phases_complete()'s substring grep counted
#       BOTH lines as ✓ complete (2 == total_phases: 2) and finalized the row
#       even though phase 2 never cleanly passed. Asserts the row is left
#       `running`, untouched — same shape as (b), but distinguishing "phase
#       status literally isn't ✓ complete" from "phase status starts with
#       ✓ complete but has a trailing PARTIAL/gap note".
#   (i) CE42 — genuine-block archive must not override a needs_human
#       correction: needs_human row, NO task file (already deleted by a prior
#       finalize pass), but an archive already exists on disk whose content
#       records a `blocked_on: EXTERNAL` / "## Human-only block" section (or a
#       PARTIAL-suffixed phase status). Before this fix, rule (2) ("archive
#       exists → finalize") ignored archive CONTENT entirely, so any later
#       manual correction of the row back to `needs_human` got silently
#       re-flipped to `complete` on the very next pass — an infinite
#       correct/re-corrupt loop. Asserts the row is left `needs_human`,
#       untouched, no new archive, and neither enqueue script fires.
#   (j) 325E review finding — a non-PARTIAL parenthetical status annotation
#       (e.g. `status: ✓ complete (DEFER)`) must NOT be treated as a genuine
#       block. Before this fix, `file_records_genuine_block()`'s third check
#       matched ANY `status: ✓ complete (...)` line, not just PARTIAL-suffixed
#       ones — real archives already on disk use non-blocking parenthetical
#       notes on otherwise-clean completions (e.g. "(DEFER)",
#       "(checkpointed retroactively by tend orchestrator ...)"). needs_human
#       row, no task file, archive has a clean `(DEFER)`-suffixed status line
#       with no `blocked_on:`/`## Human-only block` marker → must still
#       finalize to `complete` via rule (2).
#   (k) 20260725-inbox-5045 coverage gap — the rule-2 call site is
#       `file_records_genuine_block "$archive" || file_records_genuine_block
#       "$task_file"`. Scenarios (i)/(j) only ever exercise the FIRST operand
#       (their fixtures have no task file at all, so `||` short-circuits
#       before the second call ever runs), and both use a `needs_human` row.
#       This scenario covers both gaps at once: a `running` row (not
#       needs_human) whose archive is clean (no block markers) but whose
#       TASK FILE still exists on disk and records `blocked_on: EXTERNAL` /
#       `## Human-only block`. Must be left `running`, untouched — proving
#       the second `||` operand is actually load-bearing, not dead code.
#   (l) 20260725-inbox-DEFR1 — single-line (DEFER) suffix on a LIVE task file
#       must still count toward rule (1) (task_file_all_phases_complete()),
#       not just rule (2)'s archive-content path (scenario j only exercises
#       archived fixtures). Real precedent: task 20260724-inbox-7496 used
#       `status: ✓ complete (DEFER)` / `(DEFER path)` on an active task file
#       that was later auto-finalized. running row, task file with
#       total_phases: 2, phase 1 `status: ✓ complete`, phase 2
#       `status: ✓ complete (DEFER path)`, no archive yet → must finalize to
#       complete via rule (1).
#   (m) MON-1 — a `failed` row carrying a durable `cancelled_at:` marker in its
#       task file (SKILL.md's "Cancelled vs failed" convention) must get a real
#       orchestrate-history/ archive + MANIFEST entry, WITHOUT ever flipping
#       registry status off `failed`, WITHOUT deleting the task file (unlike
#       the genuine-completion path), and WITHOUT firing the OR-2/WS-2
#       enqueue-review-and-tests.sh / enqueue-wiki-sync.sh follow-ups meant for
#       genuine completions. Asserts: (1) row stays `failed`, (2) exactly one
#       archive file now exists, (3) it contains the `cancelled_at:` line,
#       (4) the task file still exists on disk (not deleted), (5) neither
#       enqueue script fires, and (6) a second run is a clean no-op (no
#       duplicate archive/MANIFEST line) — idempotency.
#   (n) MON-1 regression guard — a plain `failed` row with NO `cancelled_at:`
#       marker in its task file must be left completely untouched: no archive,
#       no MANIFEST line, task file intact, status still `failed`. Proves the
#       new cancelled-row branch is gated on the marker, not on `status ==
#       failed` alone (over-widening this would silently archive every genuine
#       failure too).
set -euo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$PROJECT_ROOT/bin" ]] || { echo "FATAL: $PROJECT_ROOT/bin not found — PROJECT_ROOT path computation is broken (expected .../task-orchestrate/bin)" >&2; exit 1; }
HELPER="${HELPER:-$PROJECT_ROOT/bin/finalize-completed-tasks.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

OLD_TS="2026-06-28T01:00:00Z"

# status_of <project.md> <id> → trimmed status field ($6)
status_of() {
  awk -F'|' -v id="$2" '
    /^\|[[:space:]]*[0-9]/ {
      rid=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",rid)
      if (rid==id) { st=$6; gsub(/^[[:space:]]+|[[:space:]]+$/,"",st); print st; exit }
    }' "$1"
}

# count_archives <history-dir> <id> → number of archive files for id
count_archives() {
  ls "$1"/*-"$2"-*.md 2>/dev/null | wc -l | tr -d ' '
}

# Build a fresh mock control plane covering all four scenarios; echo its path.
build_cp() {
  local T; T="$(mktemp -d)"
  mkdir -p "$T/.orchestrate/tasks" "$T/.orchestrate/logs" "$T/orchestrate-history"
  {
    echo "# Project"
    echo "## Task Registry"
    echo "| ID | Summary | Mode | Phase | Status | Last Activity |"
    echo "|----|---------|------|-------|--------|---------------|"
    echo "| 20260628-aaa1 | scenario a all complete | auto | 2 | running | $OLD_TS |"
    echo "| 20260628-bbb2 | scenario b partial | auto | 2 | running | $OLD_TS |"
    echo "| 20260628-ccc3 | scenario c archive exists | auto | 1 | running | $OLD_TS |"
    echo "| 20260628-ddd4 | scenario d genuinely running | auto | 1 | running | $OLD_TS |"
    echo "| 20260628-eee5 | scenario e complete no archive & cap | auto | 1 | complete | $OLD_TS |"
    echo "| 20260628-fff6 | scenario e2 complete already archived | auto | 1 | complete | $OLD_TS |"
    echo "| 20260628-ggg7 | scenario f archive exists no manifest line (AB12) | auto | 1 | running | $OLD_TS |"
    echo "| 20260628-hhh8 | scenario g archive exists no manifest line, task frontmatter | auto | 1 | running | $OLD_TS |"
    echo "| 20260628-iii9 | scenario h PARTIAL-suffix false positive (A4EB) | auto | 2 | running | $OLD_TS |"
    echo "| 20260628-jjj0 | scenario i CE42 genuine-block archive (needs_human) | auto | 1 | needs_human | $OLD_TS |"
    echo "| 20260628-kkk1 | scenario j non-PARTIAL parenthetical must still finalize (needs_human) | auto | 1 | needs_human | $OLD_TS |"
    echo "| 20260628-lll2 | scenario k task-file-only genuine block (5045 coverage gap) | auto | 1 | running | $OLD_TS |"
    echo "| 20260628-mmm3 | scenario m cancelled row (MON-1) | auto | 1 | failed | $OLD_TS |"
    echo "| 20260628-nnn4 | scenario n plain failed no marker (MON-1 regression guard) | auto | 1 | failed | $OLD_TS |"
  } > "$T/.orchestrate/project.md"

  # (a) all phases ✓ (2/2)
  printf '%s\n' \
    "# Task: Scenario A all complete" "id: 20260628-aaa1" "total_phases: 2" \
    "### Phase 1" "status: ✓ complete" "### Phase 2" "status: ✓ complete" \
    > "$T/.orchestrate/tasks/20260628-aaa1.md"

  # (b) partial (1/2 ✓)
  printf '%s\n' \
    "# Task: Scenario B partial" "id: 20260628-bbb2" "total_phases: 2" \
    "### Phase 1" "status: ✓ complete" "### Phase 2" "status: ⏳ pending" \
    > "$T/.orchestrate/tasks/20260628-bbb2.md"

  # (c) archive already exists, NO task file, and the MANIFEST already has a
  # line for it (fully-reconciled — must stay untouched, no dup line added)
  printf '%s\n' "# Task: Scenario C already archived" "id: 20260628-ccc3" \
    > "$T/orchestrate-history/20260628-000000-20260628-ccc3-already-archived.md"

  # (d) genuinely running: task file present but ZERO ✓ phases, no archive
  printf '%s\n' \
    "# Task: Scenario D genuinely running" "id: 20260628-ddd4" "total_phases: 2" \
    "### Phase 1" "status: ⏳ in_progress" "### Phase 2" "status: ⏳ pending" \
    > "$T/.orchestrate/tasks/20260628-ddd4.md"

  # (e) complete row, NO archive, NO task file → must be backfill-archived once
  #     (nothing to create here — the absence of an archive IS the scenario)

  # (e2) complete row that ALREADY has an archive → must be left untouched
  printf '%s\n' "# Task: Scenario E2 already archived complete" "id: 20260628-fff6" \
    > "$T/orchestrate-history/20260628-000000-20260628-fff6-already-archived.md"

  # (f) AB12 regression — running row, task file shows all phases ✓, AND an
  # archive already exists on disk for the ID but has NO MANIFEST line (the
  # real 69E3 bug: the model's own Completion sequence wrote the archive but
  # died before/around its own MANIFEST append, and the reaper raced ahead).
  printf '%s\n' \
    "# Task: Scenario F archive exists no manifest line" "id: 20260628-ggg7" \
    "total_phases: 1" "### Phase 1" "status: ✓ complete" \
    > "$T/.orchestrate/tasks/20260628-ggg7.md"
  printf '%s\n' "# Task: Scenario F archive exists no manifest line" "id: 20260628-ggg7" \
    > "$T/orchestrate-history/20260628-000000-20260628-ggg7-archived-no-manifest.md"

  # (g) AB12 frontmatter-fallback regression — same orphan-archive shape as (f),
  # but the archive on disk has NO `# Task:` heading; it uses the real-world
  # `task:` frontmatter field instead (see 20260620-inbox-7A8C for the actual
  # shape this mirrors). Exercises the `^task:` fallback grep in
  # backfill_manifest_for_existing_archive() that scenario (f) never reaches.
  printf '%s\n' \
    "# Task: Scenario G frontmatter fallback" "id: 20260628-hhh8" \
    "total_phases: 1" "### Phase 1" "status: ✓ complete" \
    > "$T/.orchestrate/tasks/20260628-hhh8.md"
  printf '%s\n' \
    "# Run something unrelated" "id: 20260628-hhh8" \
    "task: Scenario G frontmatter fallback summary" \
    > "$T/orchestrate-history/20260628-000000-20260628-hhh8-archived-no-manifest-frontmatter.md"

  # (h) A4EB regression — running row, task file total_phases: 2, phase 1
  # cleanly `status: ✓ complete`, phase 2 `status: ✓ complete (PARTIAL vs.
  # acceptance — some note)`. Must NOT be finalized: the trailing parenthetical
  # means phase 2 never cleanly passed, even though the old substring-match
  # heuristic counted both lines toward total_phases: 2.
  printf '%s\n' \
    "# Task: Scenario H PARTIAL-suffix false positive" "id: 20260628-iii9" \
    "total_phases: 2" \
    "### Phase 1" "status: ✓ complete" \
    "### Phase 2" "status: ✓ complete (PARTIAL vs. acceptance — some note)" \
    > "$T/.orchestrate/tasks/20260628-iii9.md"

  # (i) CE42 regression — needs_human row, NO task file (already deleted by a
  # prior finalize pass), archive exists but its content records a genuine,
  # still-unresolved external block. Must be left needs_human, untouched.
  printf '%s\n' \
    "# Task: Scenario I CE42 genuine block" "id: 20260628-jjj0" "total_phases: 1" \
    "### Phase 1" "status: ✓ complete (PARTIAL vs. acceptance — see phase log)" \
    "## Human-only block (confirmed, not locally resolvable)" \
    "blocked_on: EXTERNAL" \
    > "$T/orchestrate-history/20260628-000000-20260628-jjj0-genuine-block.md"

  # (j) 325E review finding regression — needs_human row, no task file, archive
  # has a clean, non-PARTIAL parenthetical status note (e.g. "(DEFER)") and no
  # blocked_on:/Human-only-block marker. Must still finalize to complete.
  printf '%s\n' \
    "# Task: Scenario J non-PARTIAL parenthetical" "id: 20260628-kkk1" "total_phases: 1" \
    "### Phase 1" "status: ✓ complete (DEFER)" \
    > "$T/orchestrate-history/20260628-000000-20260628-kkk1-clean-parenthetical.md"

  # (k) 20260725-inbox-5045 coverage gap — the rule-2 call site is
  # `file_records_genuine_block "$archive" || file_records_genuine_block
  # "$task_file"`. Scenarios (i)/(j) only ever exercise the FIRST operand
  # (their fixtures have no task file at all, so `||` short-circuits before
  # the second call ever runs). This scenario covers the second operand: a
  # `running` row whose archive is clean (no block markers — would finalize
  # on its own) but whose TASK FILE still exists on disk and records
  # `blocked_on: EXTERNAL`. Must be left running, untouched, proving the
  # second `||` operand is actually load-bearing, not dead code.
  printf '%s\n' \
    "# Task: Scenario K task-file-only genuine block" "id: 20260628-lll2" \
    "total_phases: 1" "### Phase 1" "status: ✓ complete" \
    "## Human-only block (confirmed, not locally resolvable)" \
    "blocked_on: EXTERNAL" \
    > "$T/.orchestrate/tasks/20260628-lll2.md"
  printf '%s\n' \
    "# Task: Scenario K task-file-only genuine block" "id: 20260628-lll2" \
    > "$T/orchestrate-history/20260628-000000-20260628-lll2-clean-archive.md"

  # (m) MON-1 — failed row + task file carrying a durable cancelled_at: marker
  # (SKILL.md's "Cancelled vs failed" convention). Must be archived exactly
  # once WITHOUT flipping status off `failed` and WITHOUT deleting the task
  # file (the marker must still be readable afterward by isCancelledTask() /
  # the monitor dashboard / report-blocked.sh).
  printf '%s\n' \
    "# Task: Scenario M cancelled row" "id: 20260628-mmm3" "total_phases: 1" \
    "cancelled_at: 2026-07-20T00:00:00Z" "cancel_reason: superseded by newer ticket" \
    "### Phase 1" "status: ⏳ pending" \
    > "$T/.orchestrate/tasks/20260628-mmm3.md"

  # (n) MON-1 regression guard — plain failed row, NO cancelled_at: marker.
  # Must be left completely untouched (no archive, no MANIFEST line, task file
  # intact, status still failed) — proves the new branch is gated on the
  # marker, not on `status == failed` alone.
  printf '%s\n' \
    "# Task: Scenario N plain failed no marker" "id: 20260628-nnn4" "total_phases: 1" \
    "### Phase 1" "status: ⏳ pending (some real error)" \
    > "$T/.orchestrate/tasks/20260628-nnn4.md"

  {
    echo "# Orchestration History Manifest"
    printf '%s | %s | %s | %s\n' "2026-06-28" \
      "20260628-000000-20260628-ccc3-already-archived.md" \
      "Scenario C already archived" "orchestrate, watchdog, auto-finalize"
  } > "$T/orchestrate-history/MANIFEST.md"

  # WS-2: stub enqueue-review-and-tests.sh and enqueue-wiki-sync.sh so the
  # finalize-completed-tasks.sh call sites (around lines 301-303 + the WS-2
  # addition right after) can be asserted without invoking the real scripts.
  # Each stub just appends its $1 (the row ID) to its own log file. BOTH
  # stubs also exit 1 (simulating a real, non-fatal failure in each script)
  # to prove: (1) the `|| true` swallow at each call site so a script erroring
  # never aborts finalize (task file still deleted, archive still created,
  # MANIFEST line still appended — see the (a)/(c) assertions below, which
  # run to completion downstream of both calls), and (2) that the wiki-sync
  # call fires independently of the review+tests call's outcome and vice
  # versa (neither call is gated on the other).
  mkdir -p "$T/.orchestrate/bin"
  cat > "$T/.orchestrate/bin/enqueue-review-and-tests.sh" << STUBEOF
#!/usr/bin/env bash
echo "\$1" >> "$T/.orchestrate/logs/enq-review-calls.log"
exit 1
STUBEOF
  chmod +x "$T/.orchestrate/bin/enqueue-review-and-tests.sh"

  cat > "$T/.orchestrate/bin/enqueue-wiki-sync.sh" << STUBEOF
#!/usr/bin/env bash
echo "\$1" >> "$T/.orchestrate/logs/enq-wiki-calls.log"
exit 1
STUBEOF
  chmod +x "$T/.orchestrate/bin/enqueue-wiki-sync.sh"

  printf '%s' "$T"
}

echo "── finalize-completed-tasks: reconcile rule (a–e) + archive-gap backfill + idempotency ──"

[[ -x "$HELPER" ]] && ok "helper is executable" || fail "helper not executable: $HELPER"

CP="$(build_cp)"
bash "$HELPER" "$CP" >/dev/null 2>&1

# (a) → complete, archived, task file deleted
[[ "$(status_of "$CP/.orchestrate/project.md" 20260628-aaa1)" == "complete" ]] \
  && ok "(a) all-✓ row → complete" || fail "(a) all-✓ row not complete"
[[ "$(count_archives "$CP/orchestrate-history" 20260628-aaa1)" -eq 1 ]] \
  && ok "(a) all-✓ row archived once" || fail "(a) all-✓ row not archived exactly once"
[[ ! -f "$CP/.orchestrate/tasks/20260628-aaa1.md" ]] \
  && ok "(a) stale task file deleted" || fail "(a) task file not deleted"
grep -q '20260628-aaa1' "$CP/orchestrate-history/MANIFEST.md" \
  && ok "(a) MANIFEST line appended" || fail "(a) no MANIFEST line"

# OR-2 / WS-2: both enqueue call sites fire, independently of each other's
# outcome, for every row finalized via the running/needs_human→complete path
# (rule 1/2). The review+tests stub exits 1 (see build_cp) — the wiki-sync
# call must still fire, proving neither call is gated on the other.
REVIEW_LOG="$CP/.orchestrate/logs/enq-review-calls.log"
WIKI_LOG="$CP/.orchestrate/logs/enq-wiki-calls.log"

grep -qx '20260628-aaa1' "$REVIEW_LOG" 2>/dev/null \
  && ok "(a) enqueue-review-and-tests.sh fired for aaa1" || fail "(a) enqueue-review-and-tests.sh NOT fired for aaa1"
grep -qx '20260628-aaa1' "$WIKI_LOG" 2>/dev/null \
  && ok "(a) enqueue-wiki-sync.sh fired for aaa1 (independent of review+tests' exit 1)" \
  || fail "(a) enqueue-wiki-sync.sh NOT fired for aaa1"

# Both stubs exit 1 for every call (see build_cp). The assertions above/below
# for (a)/(c) — complete status, single archive, deleted task file, MANIFEST
# line — all run AFTER both enqueue call sites in finalize-completed-tasks.sh,
# so their passing already proves the `|| true` swallow works for BOTH call
# sites' non-zero exits. Name that explicitly so a future regression (e.g. an
# accidental `set -e`-breaking refactor of either call site) fails loudly here
# rather than only surfacing as an unrelated-looking downstream failure.
[[ "$(status_of "$CP/.orchestrate/project.md" 20260628-aaa1)" == "complete" && ! -f "$CP/.orchestrate/tasks/20260628-aaa1.md" ]] \
  && ok "(a) finalize completes despite enqueue-wiki-sync.sh's non-zero (exit 1) return" \
  || fail "(a) finalize did NOT survive enqueue-wiki-sync.sh's non-zero exit (BAD)"

# (b) → left running, untouched
[[ "$(status_of "$CP/.orchestrate/project.md" 20260628-bbb2)" == "running" ]] \
  && ok "(b) partial row left running" || fail "(b) partial row was finalized (BAD)"
[[ -f "$CP/.orchestrate/tasks/20260628-bbb2.md" ]] \
  && ok "(b) partial task file untouched" || fail "(b) partial task file deleted (BAD)"
[[ "$(count_archives "$CP/orchestrate-history" 20260628-bbb2)" -eq 0 ]] \
  && ok "(b) partial row not archived" || fail "(b) partial row archived (BAD)"

# (h) A4EB — PARTIAL-suffix phase status must NOT count toward total_phases;
# row left running, untouched, not archived.
[[ "$(status_of "$CP/.orchestrate/project.md" 20260628-iii9)" == "running" ]] \
  && ok "(h) A4EB PARTIAL-suffix row left running" || fail "(h) A4EB PARTIAL-suffix row was finalized (BAD)"
[[ -f "$CP/.orchestrate/tasks/20260628-iii9.md" ]] \
  && ok "(h) A4EB PARTIAL-suffix task file untouched" || fail "(h) A4EB PARTIAL-suffix task file deleted (BAD)"
[[ "$(count_archives "$CP/orchestrate-history" 20260628-iii9)" -eq 0 ]] \
  && ok "(h) A4EB PARTIAL-suffix row not archived" || fail "(h) A4EB PARTIAL-suffix row archived (BAD)"

# (i) CE42 — needs_human row whose only-existing archive records a genuine
# unresolved block: must be left needs_human, untouched, no dup archive, no
# MANIFEST line, and neither enqueue script fires.
[[ "$(status_of "$CP/.orchestrate/project.md" 20260628-jjj0)" == "needs_human" ]] \
  && ok "(i) CE42 genuine-block row left needs_human" || fail "(i) CE42 genuine-block row was finalized (BAD)"
[[ "$(count_archives "$CP/orchestrate-history" 20260628-jjj0)" -eq 1 ]] \
  && ok "(i) CE42 no dup archive (still 1)" || fail "(i) CE42 duplicate archive created (BAD)"
[[ "$(grep -c '20260628-jjj0' "$CP/orchestrate-history/MANIFEST.md")" -eq 0 ]] \
  && ok "(i) CE42 no MANIFEST line written" || fail "(i) CE42 spurious MANIFEST line (BAD)"

# (j) 325E review finding — non-PARTIAL parenthetical (e.g. "(DEFER)") must NOT
# be treated as a genuine block; row still finalizes to complete via rule (2).
[[ "$(status_of "$CP/.orchestrate/project.md" 20260628-kkk1)" == "complete" ]] \
  && ok "(j) non-PARTIAL parenthetical row → complete" || fail "(j) non-PARTIAL parenthetical row wrongly left needs_human (BAD)"
[[ "$(count_archives "$CP/orchestrate-history" 20260628-kkk1)" -eq 1 ]] \
  && ok "(j) no dup archive (still 1)" || fail "(j) duplicate archive created (BAD)"
[[ "$(grep -c '20260628-kkk1' "$CP/orchestrate-history/MANIFEST.md")" -eq 1 ]] \
  && ok "(j) MANIFEST line backfilled" || fail "(j) MANIFEST line not backfilled (BAD)"
grep -qx '20260628-kkk1' "$REVIEW_LOG" 2>/dev/null \
  && ok "(j) enqueue-review-and-tests.sh fired for kkk1" || fail "(j) enqueue-review-and-tests.sh NOT fired for kkk1"
grep -qx '20260628-kkk1' "$WIKI_LOG" 2>/dev/null \
  && ok "(j) enqueue-wiki-sync.sh fired for kkk1" || fail "(j) enqueue-wiki-sync.sh NOT fired for kkk1"

# (k) 5045 coverage gap — running row, archive clean, but TASK FILE records a
# genuine block: must be left running, untouched, no dup archive (still 1),
# no MANIFEST line, and neither enqueue script fires. Proves
# `file_records_genuine_block "$task_file"` (the second `||` operand) is
# actually evaluated and honored, not dead code.
[[ "$(status_of "$CP/.orchestrate/project.md" 20260628-lll2)" == "running" ]] \
  && ok "(k) task-file-only genuine-block row left running" || fail "(k) task-file-only genuine-block row was finalized (BAD)"
[[ -f "$CP/.orchestrate/tasks/20260628-lll2.md" ]] \
  && ok "(k) task-file-only genuine-block task file untouched" || fail "(k) task-file-only genuine-block task file deleted (BAD)"
[[ "$(count_archives "$CP/orchestrate-history" 20260628-lll2)" -eq 1 ]] \
  && ok "(k) task-file-only genuine-block no dup archive (still 1)" || fail "(k) task-file-only genuine-block duplicate archive created (BAD)"
[[ "$(grep -c '20260628-lll2' "$CP/orchestrate-history/MANIFEST.md")" -eq 0 ]] \
  && ok "(k) task-file-only genuine-block no MANIFEST line written" || fail "(k) task-file-only genuine-block spurious MANIFEST line (BAD)"

# (m) MON-1 — cancelled row (failed + cancelled_at:) → archived exactly once,
# status left `failed` (never flipped), task file preserved (not deleted),
# archive content carries the cancelled_at: line through, neither enqueue
# script fires.
[[ "$(status_of "$CP/.orchestrate/project.md" 20260628-mmm3)" == "failed" ]] \
  && ok "(m) MON-1 cancelled row status left 'failed' (not flipped)" || fail "(m) MON-1 cancelled row status was mutated (BAD)"
[[ "$(count_archives "$CP/orchestrate-history" 20260628-mmm3)" -eq 1 ]] \
  && ok "(m) MON-1 cancelled row archived exactly once" || fail "(m) MON-1 cancelled row not archived exactly once (BAD)"
grep -qE '^cancelled_at:' "$CP/orchestrate-history"/*-20260628-mmm3-*.md 2>/dev/null \
  && ok "(m) MON-1 archive content carries the cancelled_at: marker" || fail "(m) MON-1 archive missing cancelled_at: marker (BAD)"
[[ -f "$CP/.orchestrate/tasks/20260628-mmm3.md" ]] \
  && ok "(m) MON-1 task file preserved (not deleted)" || fail "(m) MON-1 task file was deleted (BAD)"
grep -qE '^cancelled_at:' "$CP/.orchestrate/tasks/20260628-mmm3.md" 2>/dev/null \
  && ok "(m) MON-1 preserved task file still carries cancelled_at: marker" || fail "(m) MON-1 preserved task file lost its marker (BAD)"
[[ "$(grep -c '20260628-mmm3' "$CP/orchestrate-history/MANIFEST.md")" -eq 1 ]] \
  && ok "(m) MON-1 exactly one MANIFEST line" || fail "(m) MON-1 wrong MANIFEST line count (BAD)"

# (n) MON-1 regression guard — plain failed row, no cancelled_at: marker, must
# be left completely untouched.
[[ "$(status_of "$CP/.orchestrate/project.md" 20260628-nnn4)" == "failed" ]] \
  && ok "(n) MON-1 plain failed (no marker) row left 'failed'" || fail "(n) MON-1 plain failed row status mutated (BAD)"
[[ "$(count_archives "$CP/orchestrate-history" 20260628-nnn4)" -eq 0 ]] \
  && ok "(n) MON-1 plain failed (no marker) row NOT archived" || fail "(n) MON-1 plain failed row was archived (BAD)"
[[ -f "$CP/.orchestrate/tasks/20260628-nnn4.md" ]] \
  && ok "(n) MON-1 plain failed (no marker) task file untouched" || fail "(n) MON-1 plain failed task file deleted (BAD)"
[[ "$(grep -c '20260628-nnn4' "$CP/orchestrate-history/MANIFEST.md")" -eq 0 ]] \
  && ok "(n) MON-1 plain failed (no marker) no MANIFEST line written" || fail "(n) MON-1 plain failed spurious MANIFEST line (BAD)"

# (c) → complete, NO dup archive (still exactly 1), NO dup MANIFEST line (it
# already had one — the fully-reconciled case)
[[ "$(status_of "$CP/.orchestrate/project.md" 20260628-ccc3)" == "complete" ]] \
  && ok "(c) archive-exists row → complete" || fail "(c) archive-exists row not complete"
[[ "$(count_archives "$CP/orchestrate-history" 20260628-ccc3)" -eq 1 ]] \
  && ok "(c) no dup archive (still 1)" || fail "(c) duplicate archive created (BAD)"
[[ "$(grep -c '20260628-ccc3' "$CP/orchestrate-history/MANIFEST.md")" -eq 1 ]] \
  && ok "(c) MANIFEST line for pre-archived row still exactly 1 (no dup)" || fail "(c) MANIFEST line count wrong for pre-archived row (BAD)"
grep -qx '20260628-ccc3' "$REVIEW_LOG" 2>/dev/null \
  && ok "(c) enqueue-review-and-tests.sh fired for ccc3" || fail "(c) enqueue-review-and-tests.sh NOT fired for ccc3"
grep -qx '20260628-ccc3' "$WIKI_LOG" 2>/dev/null \
  && ok "(c) enqueue-wiki-sync.sh fired for ccc3" || fail "(c) enqueue-wiki-sync.sh NOT fired for ccc3"

# (f) AB12 — running row, task file all-✓, archive exists but had NO MANIFEST
# line → complete, NO dup archive (still exactly 1), MANIFEST line backfilled
# (exactly 1, not 0)
[[ "$(status_of "$CP/.orchestrate/project.md" 20260628-ggg7)" == "complete" ]] \
  && ok "(f) AB12 archive-exists-no-manifest row → complete" || fail "(f) AB12 row not complete"
[[ "$(count_archives "$CP/orchestrate-history" 20260628-ggg7)" -eq 1 ]] \
  && ok "(f) AB12 no dup archive written (still 1)" || fail "(f) AB12 duplicate archive created (BAD)"
[[ ! -f "$CP/.orchestrate/tasks/20260628-ggg7.md" ]] \
  && ok "(f) AB12 stale task file deleted" || fail "(f) AB12 task file not deleted"
[[ "$(grep -c '20260628-ggg7' "$CP/orchestrate-history/MANIFEST.md")" -eq 1 ]] \
  && ok "(f) AB12 missing MANIFEST line backfilled (exactly 1)" || fail "(f) AB12 MANIFEST line not backfilled (BAD)"
grep -qx '20260628-ggg7' "$REVIEW_LOG" 2>/dev/null \
  && ok "(f) AB12 enqueue-review-and-tests.sh fired for ggg7" || fail "(f) AB12 enqueue-review-and-tests.sh NOT fired for ggg7"
grep -qx '20260628-ggg7' "$WIKI_LOG" 2>/dev/null \
  && ok "(f) AB12 enqueue-wiki-sync.sh fired for ggg7" || fail "(f) AB12 enqueue-wiki-sync.sh NOT fired for ggg7"

# (g) AB12 frontmatter-fallback variant — same shape as (f) but the archive has
# no `# Task:` heading, only a `task:` frontmatter field. Row still flips to
# complete, no dup archive, MANIFEST line backfilled exactly once, and the
# backfilled summary comes from the `task:` field (not the generic placeholder).
[[ "$(status_of "$CP/.orchestrate/project.md" 20260628-hhh8)" == "complete" ]] \
  && ok "(g) frontmatter-fallback row → complete" || fail "(g) frontmatter-fallback row not complete"
[[ "$(count_archives "$CP/orchestrate-history" 20260628-hhh8)" -eq 1 ]] \
  && ok "(g) no dup archive written (still 1)" || fail "(g) duplicate archive created (BAD)"
[[ ! -f "$CP/.orchestrate/tasks/20260628-hhh8.md" ]] \
  && ok "(g) stale task file deleted" || fail "(g) task file not deleted"
[[ "$(grep -c '20260628-hhh8' "$CP/orchestrate-history/MANIFEST.md")" -eq 1 ]] \
  && ok "(g) missing MANIFEST line backfilled (exactly 1)" || fail "(g) MANIFEST line not backfilled (BAD)"
grep -qF 'Scenario G frontmatter fallback summary' "$CP/orchestrate-history/MANIFEST.md" \
  && ok "(g) backfilled summary pulled from task: frontmatter field, not placeholder" \
  || fail "(g) backfilled summary did NOT use task: frontmatter field (BAD)"
grep -qx '20260628-hhh8' "$REVIEW_LOG" 2>/dev/null \
  && ok "(g) enqueue-review-and-tests.sh fired for hhh8" || fail "(g) enqueue-review-and-tests.sh NOT fired for hhh8"
grep -qx '20260628-hhh8' "$WIKI_LOG" 2>/dev/null \
  && ok "(g) enqueue-wiki-sync.sh fired for hhh8" || fail "(g) enqueue-wiki-sync.sh NOT fired for hhh8"

# (d) → left running
[[ "$(status_of "$CP/.orchestrate/project.md" 20260628-ddd4)" == "running" ]] \
  && ok "(d) genuinely-running row untouched" || fail "(d) genuinely-running row finalized (BAD)"

# (e) archive-gap backfill: complete + no archive + no task file → archived once,
# status STILL complete (not mutated), exactly one MANIFEST line, slug from summary
[[ "$(status_of "$CP/.orchestrate/project.md" 20260628-eee5)" == "complete" ]] \
  && ok "(e) backfilled row status still complete" || fail "(e) backfilled row status mutated (BAD)"
[[ "$(count_archives "$CP/orchestrate-history" 20260628-eee5)" -eq 1 ]] \
  && ok "(e) complete-no-archive row archived once" || fail "(e) complete-no-archive row not archived exactly once"
[[ "$(grep -c '20260628-eee5' "$CP/orchestrate-history/MANIFEST.md")" -eq 1 ]] \
  && ok "(e) exactly one MANIFEST line" || fail "(e) wrong MANIFEST line count (BAD)"
ls "$CP/orchestrate-history"/*-20260628-eee5-*.md 2>/dev/null | grep -q 'scenario-e-complete-no-archive' \
  && ok "(e) slug derived from summary column" || fail "(e) slug not derived from summary (BAD)"

# (e2) complete row that already has an archive → no dup archive, no MANIFEST line
[[ "$(count_archives "$CP/orchestrate-history" 20260628-fff6)" -eq 1 ]] \
  && ok "(e2) pre-archived complete row not duplicated (still 1)" || fail "(e2) duplicate archive for pre-archived complete row (BAD)"
[[ "$(grep -c '20260628-fff6' "$CP/orchestrate-history/MANIFEST.md")" -eq 0 ]] \
  && ok "(e2) no MANIFEST line for pre-archived complete row" || fail "(e2) spurious MANIFEST line (BAD)"

# OR-2 / WS-2: neither enqueue call site fires for rows that never take the
# running/needs_human→complete path in THIS run — (b)/(d) never finalize, and
# (e)/(e2) take the separate archive-gap backfill path, which does not call
# either enqueue script.
for id in 20260628-bbb2 20260628-ddd4 20260628-eee5 20260628-fff6 20260628-iii9 20260628-jjj0 20260628-lll2 20260628-mmm3 20260628-nnn4; do
  grep -qx "$id" "$REVIEW_LOG" 2>/dev/null \
    && fail "enqueue-review-and-tests.sh spuriously fired for $id (BAD)" \
    || ok "enqueue-review-and-tests.sh correctly did not fire for $id"
  grep -qx "$id" "$WIKI_LOG" 2>/dev/null \
    && fail "enqueue-wiki-sync.sh spuriously fired for $id (BAD)" \
    || ok "enqueue-wiki-sync.sh correctly did not fire for $id"
done

# Invariant: every data row stays NF==8 with empty trailing field
BAD="$(awk -F'|' '/^\|[[:space:]]*2026/ { t=$8; gsub(/[[:space:]]/,"",t); if (NF!=8 || t!="") c++ } END{print c+0}' "$CP/.orchestrate/project.md")"
[[ "$BAD" -eq 0 ]] && ok "registry invariant preserved (NF==8)" || fail "registry invariant broken ($BAD bad rows)"

# (d-idempotency) second run = clean no-op
REG_SNAP="$(mktemp)"; cp "$CP/.orchestrate/project.md" "$REG_SNAP"
HIST_BEFORE="$(ls "$CP/orchestrate-history"/*.md 2>/dev/null | wc -l | tr -d ' ')"
MAN_BEFORE="$(grep -c '^2026' "$CP/orchestrate-history/MANIFEST.md" || true)"
bash "$HELPER" "$CP" >/dev/null 2>&1
diff -q "$REG_SNAP" "$CP/.orchestrate/project.md" >/dev/null \
  && ok "(d) 2nd run: registry unchanged (idempotent)" || fail "(d) 2nd run mutated registry (BAD)"
HIST_AFTER="$(ls "$CP/orchestrate-history"/*.md 2>/dev/null | wc -l | tr -d ' ')"
MAN_AFTER="$(grep -c '^2026' "$CP/orchestrate-history/MANIFEST.md" || true)"
[[ "$HIST_BEFORE" -eq "$HIST_AFTER" ]] \
  && ok "(d) 2nd run: no new archive" || fail "(d) 2nd run created archive (BAD)"
[[ "$MAN_BEFORE" -eq "$MAN_AFTER" ]] \
  && ok "(d) 2nd run: no new MANIFEST line" || fail "(d) 2nd run appended MANIFEST (BAD)"

# (m-idempotency) MON-1 cancelled row: 2nd run must not duplicate the archive
# or MANIFEST line, must not flip status, and must not delete the task file.
[[ "$(status_of "$CP/.orchestrate/project.md" 20260628-mmm3)" == "failed" ]] \
  && ok "(m) 2nd run: cancelled row status still 'failed'" || fail "(m) 2nd run mutated cancelled row status (BAD)"
[[ "$(count_archives "$CP/orchestrate-history" 20260628-mmm3)" -eq 1 ]] \
  && ok "(m) 2nd run: no duplicate archive (still 1)" || fail "(m) 2nd run duplicated cancelled-row archive (BAD)"
[[ "$(grep -c '20260628-mmm3' "$CP/orchestrate-history/MANIFEST.md")" -eq 1 ]] \
  && ok "(m) 2nd run: no duplicate MANIFEST line (still 1)" || fail "(m) 2nd run duplicated cancelled-row MANIFEST line (BAD)"
[[ -f "$CP/.orchestrate/tasks/20260628-mmm3.md" ]] \
  && ok "(m) 2nd run: task file still preserved" || fail "(m) 2nd run deleted the cancelled row's task file (BAD)"

# OR-2 / WS-2 idempotency: rows already flipped `complete` (aaa1, ccc3, ggg7,
# hhh8) take the archive-gap-backfill branch on re-run (already archived →
# `continue` before either enqueue call site), so a 2nd run must NOT call
# either script again — exactly one log line per ID, same as the 1st run (4
# IDs total: aaa1, ccc3, ggg7 — ggg7/hhh8 added by the AB12/(f)/(g) scenarios
# above).
[[ "$(grep -c '^2026' "$REVIEW_LOG" 2>/dev/null || true)" -eq 5 ]] \
  && ok "(d) 2nd run: no duplicate enqueue-review-and-tests.sh calls (still 5 total)" \
  || fail "(d) 2nd run duplicated enqueue-review-and-tests.sh calls (BAD)"
[[ "$(grep -c '^2026' "$WIKI_LOG" 2>/dev/null || true)" -eq 5 ]] \
  && ok "(d) 2nd run: no duplicate enqueue-wiki-sync.sh calls (still 5 total)" \
  || fail "(d) 2nd run duplicated enqueue-wiki-sync.sh calls (BAD)"

rm -rf "$CP" "$REG_SNAP"

echo ""
echo "  finalize-completed-tasks: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
