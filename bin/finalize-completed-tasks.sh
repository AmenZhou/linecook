#!/usr/bin/env bash
# finalize-completed-tasks.sh — auto-finalize watchdog (Completion is not atomic).
#
# Reconciles registry rows stuck at `running` (or `needs_human`) whose work is
# actually DONE, by running the bash analog of the SKILL Completion sequence:
# flip the row to `complete`, ensure it is archived to orchestrate-history/ +
# MANIFEST, and delete the stale .orchestrate/tasks/{ID}.md.
#
# A tend/agent session can die mid-Completion: it may have written every phase
# block to ✓ complete in the task file (and possibly archived it) but crashed
# before flipping the registry row from running→complete. T-4 only re-queues
# `needs_human` rows, so such a row sits `running` forever. This helper closes
# that gap from pure bash — no agent, no tokens.
#
# Reconcile rule — for each registry data row whose status is `running` or
# `needs_human`, finalize to `complete` when EITHER:
#   (1) its .orchestrate/tasks/{ID}.md exists AND every phase block is
#       `status: ✓ complete` AND the count of ✓ complete phase blocks equals the
#       file's `total_phases:` (conservative — never finalize partial work); OR
#   (2) an archive file matching the ID already exists in orchestrate-history/
#       (the "died mid-Completion after archiving" case).
#
# On finalize: set row status=complete + last_activity=<now> IN PLACE preserving
# NF==8; if no archive exists, archive the task file to
# orchestrate-history/{STAMP}-{ID}-{slug}.md + append a MANIFEST line; if an
# archive already exists do NOT duplicate — instead only backfill a MANIFEST
# line for that existing archive if one is missing (the "model's own
# Completion sequence wrote the archive but died before/around its own
# MANIFEST append, and the reaper raced ahead" gap — see AB12); delete the
# stale task file; append an auto-finalize line to heartbeat.log. Idempotent:
# a second run is a clean no-op.
#
# Archive-gap backfill (PURE ADDITIVE — status is NOT touched): the tend-auto
# path can flip a row straight to `status: complete` without ever archiving it,
# leaving a `complete` row with NO orchestrate-history/ file and NO MANIFEST
# line — a gap no other safety net reaps (this reaper previously skipped
# already-`complete` rows). For each registry row whose status is ALREADY
# `complete` but has NO archive file, archive it once:
#   - use its task file's phase record if one still exists, ELSE reconstruct a
#     minimal record from the registry row (ID, summary, mode, status,
#     last_activity), with the slug derived from the summary column;
#   - append exactly one MANIFEST line; do NOT mutate the registry row.
# Idempotent: once an archive exists for the ID, a re-run creates no duplicate
# file and no duplicate MANIFEST line.
#
# Wired into run-job.sh tend preflight (primary; after repair_registry_rows,
# before reset_stale_running_tasks) and rescue.sh (safety net).
set -euo pipefail

ROOT="${1:-$(pwd)}"
PROJ="$ROOT/.orchestrate/project.md"
TASKS_DIR="$ROOT/.orchestrate/tasks"
HISTORY_DIR="$ROOT/orchestrate-history"
MANIFEST="$HISTORY_DIR/MANIFEST.md"
HEARTBEAT="$ROOT/.orchestrate/logs/heartbeat.log"

[[ -f "$PROJ" ]] || exit 0

log_fin() {
  local line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1"
  mkdir -p "$(dirname "$HEARTBEAT")" 2>/dev/null || true
  echo "$line" >> "$HEARTBEAT" 2>/dev/null || true
}

# 19D7: source the churn guard so finalizing a row to `complete` can reset its
# re-queue counter and auto-close any false-positive investigate-churn ticket
# (cg_reset → cg_close_investigation). Sourcing only defines functions (the
# standalone dispatch is guarded by BASH_SOURCE==0). No-op if absent.
CG_ROOT="$ROOT"
CG_LIB="$ROOT/.orchestrate/bin/churn-guard.sh"
[[ -f "$CG_LIB" ]] && source "$CG_LIB"

# Find an existing archive file for an ID (returns first match path, or empty).
# Archive naming is {STAMP}-{ID}-{slug}.md, so anchor on -{ID}- after the stamp.
find_archive_for_id() {
  local id="$1"
  [[ -d "$HISTORY_DIR" ]] || return 0
  local f
  for f in "$HISTORY_DIR"/*-"${id}"-*.md; do
    [[ -f "$f" ]] || continue
    printf '%s\n' "$f"
    return 0
  done
  return 0
}

# Decide whether a task file represents fully-completed work (all phases ✓).
# Conservative: requires total_phases: to be present AND the number of
# `status: ✓ complete` phase-block lines to equal it.
task_file_all_phases_complete() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  local total complete
  total="$(grep -E '^total_phases:' "$file" 2>/dev/null | head -1 | sed -E 's/^total_phases:[[:space:]]*//' | tr -dc '0-9')"
  [[ -n "$total" && "$total" -gt 0 ]] || return 1
  # grep -c prints its count to stdout AND exits 1 when the count is 0; the
  # `|| echo 0` would then append a SECOND "0" → a multiline value that breaks
  # the arithmetic test. Sanitize to the first run of digits instead.
  # A single-line `(DEFER...)` suffix is a real, clean completion (task
  # 20260724-inbox-7496 used it in production) and must count as done —
  # PARTIAL-suffixed lines must not (see file_records_genuine_block() below).
  # A multi-line suffix (e.g. "(checkpointed retroactively by tend
  # orchestrator — ..." wrapping onto following lines) is NOT matched here —
  # accepted, conservative limitation: it under-counts (false-negative,
  # "not yet evaluated") rather than over-counting, which is the safe failure
  # direction. See 20260725-inbox-DEFR1.
  complete="$(grep -cE '^status:[[:space:]]*✓ complete[[:space:]]*(\(DEFER[^)]*\))?[[:space:]]*$' "$file" 2>/dev/null | head -1 | tr -dc '0-9')"
  [[ -n "$complete" ]] || complete=0
  [[ "$complete" -eq "$total" ]]
}

# Detect whether a file (task file OR an already-written archive) records a
# genuine, still-unresolved human block. Rule (2) ("an archive already exists
# for this ID → finalize to complete") must never override this, even though
# the archive is real and on disk — an archive can legitimately record a
# PARTIAL/blocked outcome (e.g. a human-only external dependency), not just a
# clean finish that died before the registry flip. Without this check, any
# later correction of the registry row back to `needs_human` gets silently
# re-flipped to `complete` on the very next finalize pass, because "archive
# exists" alone was being treated as sufficient (20260725-inbox-CE42: a
# `blocked_on: EXTERNAL` skill-install task kept getting re-completed by this
# exact gap, racing a human's manual correction every cycle).
file_records_genuine_block() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  grep -qE '^blocked_on:[[:space:]]*EXTERNAL' "$file" 2>/dev/null && return 0
  grep -qE '^## Human-only block' "$file" 2>/dev/null && return 0
  # Only a PARTIAL-suffixed status line signals a genuine unresolved gap — other
  # parenthetical annotations (e.g. "(DEFER)", "(checkpointed retroactively by
  # tend orchestrator ...)") are real, clean completions with an explanatory
  # note, not blocks. A bare `\(` match over-fires on these (found by review
  # 20260725-inbox-325E against real archives already on disk, e.g.
  # 20260724-inbox-7496's "✓ complete (DEFER)" and 20260725-inbox-6B7E's
  # "✓ complete (checkpointed retroactively ...)").
  grep -qE '^status:[[:space:]]*✓ complete[[:space:]]*\(PARTIAL' "$file" 2>/dev/null && return 0
  return 1
}

# Derive a filesystem-safe slug for the archive filename. Prefers the task
# file's `# Task:` title; falls back to the optional $3 summary string (used for
# rows with no task file — the registry summary column).
derive_slug() {
  local file="$1" id="$2" fallback="${3:-}"
  local slug=""
  if [[ -f "$file" ]]; then
    slug="$(grep -m1 -E '^# Task:' "$file" 2>/dev/null | sed -E 's/^# Task:[[:space:]]*//')"
  fi
  [[ -n "$slug" ]] || slug="$fallback"
  # Lowercase, strip non-alnum to hyphens, collapse, trim.
  slug="$(printf '%s' "$slug" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-60)"
  [[ -n "$slug" ]] && printf '%s\n' "$slug" || printf '%s\n' "auto-finalized"
}

# Flip a single registry row ID running|needs_human → complete, in place,
# preserving NF==8 (and self-healing any phantom column). Atomic temp+mv.
# Returns 0 only if a row was actually flipped.
finalize_registry_row() {
  local id="$1"
  local now_iso
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local tmp rc=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/project-md.XXXXXX")"
  awk -F'|' -v OFS='|' -v id="$id" -v ts="$now_iso" '
    /^\|[[:space:]]*[0-9]/ && NF>=8 {
      rid=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",rid)
      st=$6;  gsub(/^[[:space:]]+|[[:space:]]+$/,"",st)
      if (rid==id && (st=="running" || st=="needs_human")) {
        $6=" complete "; $7=" " ts " "
        if (NF>8) { NF=8; $8="" }
        flipped=1
      }
    }
    { print }
    END { exit (flipped ? 0 : 2) }
  ' "$PROJ" > "$tmp" || rc=$?
  if [[ $rc -eq 0 ]]; then
    mv "$tmp" "$PROJ"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Backfill a MANIFEST line for an archive file that already exists on disk but
# has no MANIFEST entry — the "died mid-Completion after archiving, then the
# reaper independently raced ahead of the MANIFEST write" gap (e.g. 69E3: the
# model's own Completion sequence wrote the archive file but died before/around
# appending its MANIFEST line). PURE ADDITIVE — never touches the archive file
# itself, and no-ops (idempotent) once a line for its basename exists.
backfill_manifest_for_existing_archive() {
  local id="$1" archive_path="$2"
  local base
  base="$(basename "$archive_path")"
  grep -qF "$base" "$MANIFEST" 2>/dev/null && return 0  # already listed — no-op
  # Task files/archives use either a `# Task:` markdown heading (reaper-written
  # ones) or a `task:` frontmatter field (the common real-task convention, e.g.
  # 69E3) — try both, preferring the heading when present.
  local summary
  summary="$(grep -m1 -E '^# Task:' "$archive_path" 2>/dev/null | sed -E 's/^# Task:[[:space:]]*//')"
  if [[ -z "$summary" ]]; then
    summary="$(grep -m1 -E '^task:' "$archive_path" 2>/dev/null | sed -E 's/^task:[[:space:]]*//; s/^"(.*)"$/\1/')"
  fi
  [[ -n "$summary" ]] || summary="auto-finalized task $id"
  printf '%s | %s | %s | orchestrate, watchdog, auto-finalize, manifest-backfill\n' \
    "$(date -u +%Y-%m-%d)" "$base" "$summary" >> "$MANIFEST"
  log_fin "manifest-backfill — existing archive $base for $id had no MANIFEST line → backfilled"
}

# Archive a task file to orchestrate-history/ + append MANIFEST line, ONLY if no
# archive for the ID already exists. Adds a `tags:` line if absent. Returns the
# archive basename on stdout when it creates one (empty if it reused an existing).
archive_task_file() {
  local id="$1" file="$2"
  local existing
  existing="$(find_archive_for_id "$id")"
  if [[ -n "$existing" ]]; then
    # Already archived (e.g. by the model's own Completion sequence before it
    # died pre-registry-flip) — never write a duplicate archive file. Just
    # make sure MANIFEST.md references the archive that's already there.
    backfill_manifest_for_existing_archive "$id" "$existing"
    return 0
  fi
  [[ -f "$file" ]] || return 0  # nothing to archive (rule-2 with no task file)
  mkdir -p "$HISTORY_DIR"
  local stamp slug base dest
  stamp="$(date -u +%Y%m%d-%H%M%S)"
  slug="$(derive_slug "$file" "$id")"
  base="${stamp}-${id}-${slug}.md"
  dest="$HISTORY_DIR/$base"
  {
    if ! grep -qE '^tags:' "$file" 2>/dev/null; then
      echo "tags: orchestrate, watchdog, completion, auto-finalize"
    fi
    cat "$file"
  } > "$dest"
  # Append MANIFEST line (create header-less append; MANIFEST already exists).
  local summary
  summary="$(grep -m1 -E '^# Task:' "$file" 2>/dev/null | sed -E 's/^# Task:[[:space:]]*//')"
  [[ -n "$summary" ]] || summary="auto-finalized task $id"
  printf '%s | %s | %s | orchestrate, watchdog, auto-finalize\n' \
    "$(date -u +%Y-%m-%d)" "$base" "$summary" >> "$MANIFEST"
  printf '%s\n' "$base"
}

# Archive an already-`complete` registry row that has NO archive file (the
# complete-but-unarchived gap). PURE ADDITIVE — never mutates the registry row.
# Uses the task file's phase record if it still exists, else reconstructs a
# minimal record from the registry fields. Idempotent via find_archive_for_id.
# Returns the archive basename on stdout when it creates one (empty otherwise).
# Args: id summary mode status last_activity
archive_complete_row() {
  local id="$1" summary="$2" mode="$3" status="$4" last_activity="$5"
  local existing
  existing="$(find_archive_for_id "$id")"
  [[ -z "$existing" ]] || return 0  # already archived — never duplicate

  local file="$TASKS_DIR/${id}.md"
  mkdir -p "$HISTORY_DIR"
  local stamp slug base dest
  stamp="$(date -u +%Y%m%d-%H%M%S)"
  slug="$(derive_slug "$file" "$id" "$summary")"
  base="${stamp}-${id}-${slug}.md"
  dest="$HISTORY_DIR/$base"

  if [[ -f "$file" ]]; then
    # Prefer the existing task file's full phase record.
    {
      if ! grep -qE '^tags:' "$file" 2>/dev/null; then
        echo "tags: orchestrate, watchdog, completion, auto-finalize, archive-backfill"
      fi
      cat "$file"
    } > "$dest"
  else
    # No task file — reconstruct a minimal record from the registry row.
    {
      echo "tags: orchestrate, watchdog, completion, auto-finalize, archive-backfill"
      echo "# Task: ${summary:-auto-finalized task $id}"
      echo "id: $id"
      echo "mode: ${mode:-auto}"
      echo "status: ${status:-complete}"
      echo "last_activity: ${last_activity:-}"
      echo ""
      echo "_Archive backfilled by finalize-completed-tasks.sh — the registry row was"
      echo "already \`complete\` but had no orchestrate-history/ record. No task file"
      echo "remained, so this minimal record was reconstructed from the registry row._"
    } > "$dest"
  fi

  local man_summary="${summary:-auto-finalized task $id}"
  printf '%s | %s | %s | orchestrate, watchdog, auto-finalize, archive-backfill\n' \
    "$(date -u +%Y-%m-%d)" "$base" "$man_summary" >> "$MANIFEST"
  printf '%s\n' "$base"
}

trim_ws() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

finalize_completed_tasks() {
  [[ -f "$PROJ" ]] || return 0
  # Read candidate rows positionally — NF-tolerant. Capture summary/mode/
  # last_activity too (needed to reconstruct an archive for an unarchived
  # `complete` row that has no task file).
  local row_id summary mode status last_activity
  while IFS='|' read -r _ row_id summary mode _ status last_activity _; do
    row_id="${row_id// /}"
    status="${status// /}"
    summary="$(trim_ws "$summary")"
    mode="$(trim_ws "$mode")"
    last_activity="$(trim_ws "$last_activity")"
    [[ -z "$row_id" || "$row_id" == "ID" || "$row_id" =~ ^-+$ ]] && continue

    # Archive-gap backfill: an already-`complete` row with no archive gets
    # archived once (PURE ADDITIVE — registry row is never mutated).
    if [[ "$status" == "complete" ]]; then
      # 19D7: an already-complete row (e.g. finished via the agent Completion
      # path) may still carry a mid-flight-reset false-positive investigate-churn
      # ticket — close it. Idempotent; no-op when no active ticket exists.
      if type cg_close_investigation >/dev/null 2>&1; then
        cg_close_investigation "$row_id" 2>/dev/null || true
      fi
      [[ -n "$(find_archive_for_id "$row_id")" ]] && continue  # already archived
      local bf_created
      bf_created="$(archive_complete_row "$row_id" "$summary" "$mode" "$status" "$last_activity")"
      if [[ -n "$bf_created" ]]; then
        log_fin "archive-backfill — complete row $row_id had no archive → archived $bf_created"
      fi
      continue
    fi

    # Cancelled-row archival (MON-1): a `failed` row carrying a durable
    # cancelled_at: marker in its task file (SKILL.md's "Cancelled vs failed"
    # convention) gets a real orchestrate-history/ archive + MANIFEST entry —
    # WITHOUT ever flipping registry status off `failed` (that would
    # misrepresent a deliberate cancel as a success). Reuses archive_task_file()
    # unchanged (idempotent via its own find_archive_for_id check) — the only
    # new logic is the guard and the deliberate absence of a registry flip /
    # task-file deletion / OR-2 / WS-2 follow-up enqueues.
    if [[ "$status" == "failed" ]]; then
      local task_file="$TASKS_DIR/${row_id}.md"
      if [[ -f "$task_file" ]] && grep -qE '^cancelled_at:' "$task_file" 2>/dev/null; then
        local c_created
        c_created="$(archive_task_file "$row_id" "$task_file")"
        if [[ -n "$c_created" ]]; then
          log_fin "auto-finalize — archived cancelled row $row_id (status left 'failed'; task file preserved) → archived $c_created"
        fi
      fi
      continue
    fi

    [[ "$status" == "running" || "$status" == "needs_human" ]] || continue

    local task_file="$TASKS_DIR/${row_id}.md"
    local archive
    archive="$(find_archive_for_id "$row_id")"

    local should_finalize=0
    if [[ -n "$archive" ]]; then
      if file_records_genuine_block "$archive" || file_records_genuine_block "$task_file"; then
        should_finalize=0                        # archive/task file records an unresolved block — never auto-finalize
      else
        should_finalize=1                        # rule (2): already archived, and it records a clean finish
      fi
    elif task_file_all_phases_complete "$task_file"; then
      should_finalize=1                          # rule (1): all phases ✓
    fi
    [[ "$should_finalize" -eq 1 ]] || continue

    # Flip the registry row first (the durable signal). If it does not flip
    # (malformed/raced row), skip the rest so we never half-finalize.
    if ! finalize_registry_row "$row_id"; then
      log_fin "auto-finalize SKIPPED $row_id: row did not flip (malformed/raced); awaiting repair_registry_rows"
      continue
    fi

    # 19D7: the row is now `complete` — reset its churn counter and auto-close any
    # active investigate-churn ticket (a mid-flight-reset false positive). Guarded
    # on function presence so an absent/older churn-guard.sh never breaks finalize.
    if type cg_reset >/dev/null 2>&1; then
      cg_reset "$row_id" 2>/dev/null || true
    fi

    # Archive if not already archived (never duplicates).
    local created
    created="$(archive_task_file "$row_id" "$task_file")"

    # OR-2: auto-enqueue an independent review + tests follow-up for code-changing
    # tasks (R-1 Decision 1b — bash backstop for died-mid-Completion). Runs BEFORE
    # the task file is deleted so files_changed is readable. The helper self-skips
    # docs-only and followup_for: source tasks and dedups across inbox/registry/
    # history, so a no-op is harmless — never abort finalize on its non-zero exit.
    local enq="$ROOT/.orchestrate/bin/enqueue-review-and-tests.sh"
    if [[ -x "$enq" ]]; then
      ENQ_ROOT="$ROOT" ENQ_INBOX_ROOT="$ROOT" bash "$enq" "$row_id" >/dev/null 2>&1 || true
    fi

    # WS-2: independent auto-enqueue of a `kind: wiki-sync` follow-up for
    # every completed task (enqueue-wiki-sync.sh, built in WS-1; broadened
    # from research-shaped/zero-code-change-only by WIKI-1 2026-07-25).
    # Mirrors the OR-2 call above but is its own script and its own
    # call — never gated on, or gating, the review+tests call's outcome, so a
    # docs-only task that skips review+tests still gets its wiki-sync call
    # attempted (and vice versa for a code-changing task). Not gated on -x:
    # the script may ship non-executable — every call site invokes it via
    # `bash`, never direct exec.
    local enq_wiki="$ROOT/.orchestrate/bin/enqueue-wiki-sync.sh"
    ENQ_ROOT="$ROOT" ENQ_INBOX_ROOT="$ROOT" bash "$enq_wiki" "$row_id" >/dev/null 2>&1 || true

    # Delete the stale task file (idempotent — -f).
    rm -f "$task_file"

    if [[ -n "$created" ]]; then
      log_fin "auto-finalize — completed $row_id (all phases ✓; registry was running) → archived $created"
    else
      log_fin "auto-finalize — completed $row_id (registry was $status; archive already existed) → reconciled"
    fi
  done < <(grep -E '^\|[[:space:]]*[0-9]' "$PROJ" 2>/dev/null || true)
}

finalize_completed_tasks
