---
name: task-orchestrate
description: Unified project orchestrator. Maintains a project-scoped control plane (.orchestrate/) with shared context across all tasks and a task registry. Phases, critic, and quality gates are unchanged. Use for any task: simple fire-and-forget or complex multi-phase work. Execution is manual and synchronous — plan a task, review it, say "go", it runs immediately in that same session. (The async background-watchdog/inbox-queue model this skill used to also support was removed 2026-08-09 — see "Removed: async tend/inbox infrastructure" below.)
inline: false
investigation_model_tier: sonnet
planning_model_tier: sonnet
retry_model_escalation: true
---

<!--
Provenance: extracted from the private ai-toolbox repository (https://github.com/AmenZhou/ai-toolbox),
which is not publicly available. Embedded in linecook under this repo's MIT license — see /LICENSE.
Adapted for this repo: personal project paths and an illustrative task-ID anecdote were generalized
or trimmed — see the 3 edit points noted inline. This skill's sibling files (GUIDE.md, README.md,
launchd .plist files, test-launch-agent.js) are intentionally NOT embedded — they describe an async
tend/inbox-drain/launchd model this file's own "Removed" section below documents as gone; embedding
them would reintroduce stale instructions this file explicitly warns against. SKILL.md alone is the
current, accurate source of truth for this skill.
-->

You are the **orchestrator**: you plan, approve, and execute — running phases inline with your own tools when that's efficient, spawning agents only when truly needed. You also maintain a project-scoped control plane and watch your own task registry for stalls.

**Spawn an agent only when:**
1. A phase is too large to fit in the main context (~10+ tool calls or 3+ files to create/rewrite)
2. Genuine parallelism is needed
3. A skill's embedded instructions make isolation valuable

For everything else, run inline.

---

## Removed: async tend/inbox infrastructure (2026-08-09)

This skill used to also support an **async background-watchdog model**: a `tend`/`tend go auto`
mode that ran as an OS-level launchd heartbeat, drained an `.orchestrate/inbox/` drop-zone, and
dispatched queued tasks unattended, plus a `monitor/` web dashboard. That entire apparatus — the
`.orchestrate/bin/*.sh` helper scripts, the `monitor/` dashboard app, the Tend Mode (T-0–T-6) and
Inbox Mode sections that documented it, and the Heartbeat Setup instructions — was **removed from
this skill's source on 2026-08-09**, not merely left dormant. It was archived in every project
that had deployed it, after it turned out Claude Code CLI can't run non-interactively, so a
launchd-triggered session hangs waiting for a "go" prompt no one can answer — and a follow-up
investigation found **zero projects anywhere with a live deployment, zero non-empty inbox
drop-zones, and zero orchestrate-related launchd jobs system-wide** — the async model had no
consumers left to justify keeping.

**Everything here is git history, not gone.** `git log -- skills/task-orchestrate/bin/
skills/task-orchestrate/monitor/` finds it if a future project needs the async model restored.

**Current model — manual, synchronous, always:** plan a task (any non-empty input below), review
the plan, say "go" or "go auto", and it runs immediately in that same session — no queue, no
watchdog, no background dispatch. Completion's §6b-direct and §6d are the direct, self-contained
mechanisms that replaced what the removed async infrastructure used to defer to a later cycle.

---

## Invocation Modes

Detect which mode applies from the input:

| Input | Mode |
|-------|------|
| `resume` alone | Resume — list active tasks and wait for user pick |
| Any other non-empty string | New task — plan and execute |
| Empty / no input | If project.md exists: show registry status. Else: ask for task. |

---

## Project Structure

All state lives under `.orchestrate/` in the **current working directory**. Create this layout on first use in any project:

```
.orchestrate/
  project.md          # control plane: shared context + task registry
  tasks/              # per-task phase files (one per active task)
  logs/                # phase logs, verify logs (per-task, written during Execution Loop)
```

### project.md

```markdown
# Orchestrate — {project name or cwd basename}
last_updated: <ISO>

## Shared Context
<!-- Durable project knowledge carried across tasks.
     Append discoveries here at task completion.
     Every new task reads this before planning. -->

## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
```

Status values: `pending` · `running` · `awaiting_go` · `awaiting_critic` · `complete` · `failed` · `needs_human`

**Cancelled vs failed:** The registry enum has no `cancelled` value (NF==8 DOMAIN unchanged). A human cancelling a gated (`awaiting_go`) task sets registry status **`failed`** but also stamps durable **`cancelled_at:`** + **`cancel_reason:`** markers into `.orchestrate/tasks/{ID}.md` (mirrors the `bypassed_at:` pattern) — this distinguishes a deliberate cancellation from a genuine **`failed`** row (no marker → review required) when reading the registry later.

### Per-task file — `.orchestrate/tasks/{ID}.md`

Same schema as the former `.task-orchestrate-state-{ID}.md`. The `id`, `task`, `complexity`, `mode`, `total_phases`, `phases` block and OPERATING RULES are identical — only the file location changes.

---

## Permission Check

Read `.claude/settings.json` (project) and `~/.claude/settings.json` (global). Check `permissions.allow` for: `Bash(mv:*)`, `Bash(rm:*)`, `Bash(git push:*)`.

**All present:** proceed silently.

**Any missing:** surface once before presenting the plan:
```
⚠ Auto mode may be interrupted — missing permissions: <list>
Type "grant" · "grant global" · "skip"
```
On "grant"/"grant global": merge missing entries into settings, confirm `✓ Permissions updated`.

---

## State File & Resume

**New task:** Generate ID `YYYYMMDD-HHMMSS`. Create `.orchestrate/tasks/{ID}.md`. Ensure `.orchestrate/project.md` exists (create with template if not). Register row in project.md registry.

**Hand-minting a suffix ID mid-cycle** (e.g. a follow-up task registered while another is still in flight): use `openssl rand -hex 2` (or read `/dev/urandom` directly), never bare `$RANDOM` — collision-prone, especially when minting more than one ID in the same shell invocation. Immediately `grep` the live registry for the freshly minted ID before trusting it's unique.

**Resume:** Scan `.orchestrate/tasks/` for active task files.
- None found → ask "What task would you like to orchestrate?"
- One or more found → list `[ID] <task> — phase X/Y (<status>)`. Files with `mode: pending` older than 7 days are abandoned — list separately, offer to delete.
- **Always wait for user to pick an ID** — never auto-load.
- On resume: restore `mode`. If `pending`, re-present plan. If `auto`, continue immediately.
- `awaiting_critic` on resume: check `captured_output`. If present: skip pre-critic write, go directly to inline assessment. If absent: reset to `pending`, increment retries, re-invoke.

**`resume` must be the full input.** Any other input is a new task.

---

## Phase Classification

Classify task complexity: **Lightweight** (2–3) · **Moderate** (4–5) · **Complex** (6). Merge consecutive same-type phases; cap at 6.

### Step 1 — Phase type

| Keywords | Type |
|---|---|
| research, analyze, plan, design, document | instructional |
| implement, build, write code, fix, create, test, verify | execution |
| review, architect, assess, evaluate | reasoning |
| fetch, lookup, list, run, query, git | simple |

Precedence: reasoning > execution > simple > instructional.

### Step 2 — Executor

| Condition | Executor | Model Tier |
|---|---|---|
| simple or instructional phase | **inline** | — |
| execution — narrow (≤2 files, clear spec, ≤5 tool calls) | **inline** | — |
| skill phase where skill declares `inline: true` | **inline · /skill-name** | — |
| research / investigation / challenging analysis (keywords: `investigate`, `research`, `plan`, `design`, `analyze`, `discovery`, `derive`, `INV`, `PLAN`) | **agent/premium** | **Sonnet or higher** |
| execution — moderate or broad (3+ files, iterative) | **agent/Sonnet** | **Sonnet** |
| reasoning phase | **agent/premium** | **Sonnet or higher** |
| any phase that must run in parallel | **agent/*** | *match primary phase tier* |
| skill phase without `inline: true` | **agent/** at tier | *per condition above* |

**Model Tier Specifics:**
- **Sonnet:** Default for investigation, planning, reasoning phases; also for moderate/broad execution that iterates
- **Haiku:** Use for simple, instructional, and narrow execution phases (cost optimization)
- **Opus:** Consider for particularly complex multi-step reasoning; optional upgrade on retry
- **Claude Code:** Specify `model: "sonnet"` (or `model: "opus"`) in Agent() calls; will degrade to Haiku if Sonnet unavailable
- **Cursor:** Before running phases marked for premium tier, switch Cursor to Sonnet in Settings (⌘ + Shift + J)

### Step 3 — Derive per phase

- `depends_on`: phase numbers that must complete first
- `acceptance_criteria`: 2–3 done-statements for execution/reasoning phases

---

## Plan Presentation

Read `## Shared Context` from `project.md` before planning — it contains durable decisions and constraints from prior tasks. Incorporate relevant context into the plan (phase design, executor choices, acceptance criteria).

Immediately after reading Shared Context and before drafting the plan, pull a bounded slice of cross-project wiki knowledge: invoke `/wiki-context-pack "<task title/goal>" --budget 1500` once per task (not re-fetched per phase), and write the result verbatim into the task file under a new `## Wiki Context` section so later phases can reuse it without re-querying. Skip this pull entirely when the task's title/Goal matches a wiki-related job (`wiki-*`, `*-wiki-ingest`, `daily-wiki-digest`, or any ticket whose Design section is itself about wiki maintenance) — avoids recursive/wasteful calls. If `wiki-context-pack` errors, returns empty, or the vault isn't configured, degrade gracefully: proceed with planning unchanged and write `## Wiki Context\n(unavailable — proceeded without it)`.

**Mandatory execution phases:** Phases 1 through N-1 are execution work. Phase N is always `Test & Verify` `[inline · execution]` with acceptance criteria: (1) all output files declared in prior phases exist on disk, (2) detected test suite passes or "no test runner detected", (3) when the task's ACs or summary name a project-local smoke script, run it (see Project-local smoke scripts). Omit only for tasks that produce zero file changes (pure queries, documentation with no outputs).

**Mandatory Completion phase (Phase N+1):** Every task MUST include Phase N+1: `Completion [inline · ceremony]` with checklist acceptance criteria:
- [ ] §6b-direct review complete (verdict: PASS | PARTIAL | FAIL)
- [ ] §6d wiki ingestion (page: ___ | not persisted: reason)
- [ ] Shared Context updated (or "n/a — no new findings")
- [ ] Improvement Suggestions filed (or "none: reason")

This is not negotiable. No task is truly complete without Completion. Phase N+1 is where these mandatory post-execution steps are documented and verified. Do not archive, do not mark registry `complete`, do not move to the next task until all four checkboxes are checked.

**Reconcile-and-document literal/numeric ACs:** when a ticket's hard count/literal AC (e.g. `ls web/*.html | wc -l == 11`) conflicts with verified project reality (the real value is 10), do NOT fail the phase or silently pass on the asserted number. Instead reconcile-and-document: run the check, record the *actual* value with evidence in `test_evidence`/verify.log, treat the AC as met at the corrected value, and note the off-by-one (the ticket's total was a guessed/remembered count, not an enumerated sum).

```
TASK PLAN — `<summary>`  Complexity: Lightweight|Moderate|Complex (N execution phases + Completion)
Phase 1: `<name>` [inline · simple] → `<output>`
Phase 2: `<name>` [inline · execution] → `<output>`
Phase 3: `<name>` [/skill-name · agent/Sonnet] [parallel with 4] → `<output>`
Phase N-1: `<name>` [agent/premium] → `<output>`   ← research/investigation
Phase N: `Test & Verify` [inline · execution] → `verify.log`   ← execution final
Phase N+1: `Completion` [inline · ceremony] → (see template below)   ← MANDATORY POST-EXECUTION
```

**Completion phase template (always Phase N+1):**
```markdown
### Phase N+1: Completion [inline · ceremony]
status: pending
- [ ] §6b-direct review complete (verdict: PASS | PARTIAL | FAIL)
- [ ] §6d wiki ingestion (page: ___ | not persisted: reason)
- [ ] Shared Context updated (or "n/a — no new findings")
- [ ] Improvement Suggestions filed (or "none: reason")
```

Surface pre-execution questions:
```
❓ Before we start:
1. <biggest risk or ambiguity>
2. <scope or assumption>
3. <dependency or side-effect>

⚠ MCP services involved: <list>   ← omit if none

Answer inline, then: "go" (gated) · "go auto" (ungated) · describe changes · "abort"
```

If no questions and no MCP: `▶ Plan looks clear — type "go" or "go auto" to proceed.`

Write task file to `.orchestrate/tasks/{ID}.md`. Register row in `project.md` with `status: awaiting_go`.

---

## On "go" / "go auto"

Update task file `mode` immediately:
- `"go"` → `mode: gated`
- `"go auto"` → `mode: auto`
- `"go auto, approve MCP: <list>"` → `mode: auto`, `mcp_preauthorized: [<list>]`
- Free-form → treat as plan revision, re-present.

**Cross-task `depends_on:` gate:** if the task file declares a `depends_on:` on another task's registry ID, read that row from `project.md` directly before proceeding — if it isn't `complete`, do **not** update this row to `running`; report back which task (`<dep_id>`, its status) is blocking and stop. Otherwise proceed.

Update project.md registry row: `status: running`.

**Immediately after this write — before any phase research/work:** write `.orchestrate/tasks/{ID}.md` (a stub is fine: header + phase list from the plan, phases `pending`). Do not defer this until Phase 1's Step A capture. Since another interactive session could concurrently be working the same project (see the Pre-execution duplicate-completion guard below), writing the stub promptly is what lets a concurrent session recognize this task is already claimed rather than duplicating it.

---

## Execution Loop

**Self-refresh at start of each turn:** re-read this skill file and the task file. Skip only if this is the first turn after Skill tool was just invoked.

**Pre-execution duplicate-completion guard:** before selecting/running the next phase for this ID, do a cheap check for whether `orchestrate-history/` already contains an archive for it — this matters because execution is interactive, not exclusive: another concurrent session (a second terminal, another human) can legitimately be working the same project at the same time.
```bash
ls .orchestrate/../orchestrate-history/*-"{ID}"-*.md 2>/dev/null   # or: grep -l "{ID}" orchestrate-history/*.md 2>/dev/null
```
- **No hit:** proceed normally — this is the common case; the check costs one `ls`/`grep`.
- **Hit:** this ID is already done — a concurrent session, or (rarer) this same session's own prior work, already completed and archived it. Do **not** run (or continue) the phase loop for it. Skip straight to the Completion sequence's reconcile behavior: confirm the registry row reflects `complete` (flip it if it still shows `running`), confirm a MANIFEST line exists for the archive (do not create a duplicate), then move on to the next task.
- **Why this catches more than a once-at-claim check:** `Self-refresh at start of each turn` above already re-enters this section once per phase/turn, so this guard naturally re-fires at every phase boundary for a multi-phase task, not just once before Phase 1 — a concurrent session's completion landing mid-task is caught at the next phase boundary rather than only at this session's own Completion step.

**Ready phases** = all `depends_on` entries are `✓ complete` AND status is `pending`.

### Inline phase execution

**Verify a ticket's stated causal narrative before acting on it:** if a task's Goal/Context asserts a specific causal claim about why something is in its current state — especially "X was deliberately done/removed by completed task `<ID>`" or "Y is redundant because of Z precedence" — spot-check that claim against the referenced task's actual archive (`orchestrate-history/`, or its live `.orchestrate/tasks/{ID}.md` if still present) before treating it as ground truth for planning the fix. A ticket can cite specific, real task IDs and still be wrong about what those tasks actually did — e.g. citing a task as having "completed" a removal when its archived phase shows `✗ failed (blocked — ...)`/bypassed and never executed. Acting on an unverified narrative can compound the original error (e.g. permanently removing something that was never actually superseded) instead of fixing it.

**Re-verify a ticket's cited symptom/repro before acting on it, too:** the same skepticism applies when a ticket justifies a fix with a live repro instead of a causal narrative — e.g. "confirmed live: `<repro command>` fails with `<symptom>`". That note was true when the task was planned, but another same-day task can land a fix for the exact same symptom before this one is picked up, making the cited output stale by execution time. Before applying the described fix, re-run the cited repro/symptom command live and confirm it still reproduces — do not assume a "confirmed live" note in the ticket body is still true at dispatch time. If it no longer reproduces, treat the ticket as already resolved (verify, don't blindly apply the fix) rather than reapplying a now-unnecessary change.

**human_resolution:** Before running (or retrying) a phase, check the phase block in the task file for a `human_resolution:` line. If present, prepend this to your context for the phase:
> "Human resolved this block with: `<text>`. Proceed using this answer."
After the phase completes `✓ complete`, strip the `human_resolution:` line from the task file (rewrite the phase block without that line).

Run the phase directly with your own tools. When done, produce:

```
## PHASE OUTPUT
files_changed: [list or "none"]
summary: <one sentence>
confidence: high | medium | low
blockers: [list or "none"]
acceptance_criteria_met: [✓ criterion 1 | ✗ criterion 2] or "n/a (simple/instructional)"
test_evidence: <commands actually run to verify behavior, e.g. "7/7 dry-run pass; make test ALL SUITES PASSED; launchctl list: LastExitStatus=0"> or "n/a (no code changes)"
```

Evaluate against acceptance criteria inline. Assign: **PASS** · **PARTIAL: \<gap\>** · **FAIL: \<reason\>**.

**AC gate:** any `✗` in `acceptance_criteria_met` classifies the phase as PARTIAL or FAIL — never PASS, regardless of confidence.

If `files_changed` non-empty: run Bash lint/build/test. Downgrade to PARTIAL if fails.

**Top-level files_changed (mandatory when non-empty):** If this phase's `files_changed` is non-empty, append/update a top-level `files_changed: <paths>` line in the task file itself (union across all phases run so far — not only inside this phase's `## PHASE OUTPUT` block's `files_changed` field or prose). This mirrors the Agent phase execution instruction below — Completion's §6b-direct independent review and §6d's wiki-persistence decision both need this top-level line to classify the change without re-deriving it from every phase log; omitting it risks a real code change silently reading as "no code changes" at Completion time.

**External-repo commit hygiene (inline or Agent-dispatched phases alike):** Before editing any file outside this project's own root (e.g. a fix applied under a different repo in a sibling project directory), run `git -C <target-repo-root> status --short -- <file>` FIRST, before making the edit. If that pre-edit check already shows an uncommitted diff on that file **not authored by this phase**, do not silently layer a new edit on top of it — flag the pre-existing backlog in `test_evidence`/`blockers` (name the file and note a prior uncommitted diff exists) so it surfaces at the moment it's found, rather than compounding until a dedicated audit catches it later. After making the change, run `git -C <target-repo-root> status --short -- <file>` again, then either commit locally in that repo with a descriptive message (`git -C <target-repo-root> commit -m "<message>"` — local commit only, never `git push` without explicit approval) or record in `test_evidence` exactly why it was left uncommitted (e.g. "batching with an in-flight follow-up", "awaiting human review before commit"). Without this, a real fix can sit uncommitted indefinitely with no signal from the task file that it's incomplete from a repo-hygiene standpoint.

**Phase log write (mandatory — atomic, single call):** Append the full PHASE OUTPUT block to `.orchestrate/logs/{ID}-phase{N}.log` in ONE call — write the header and body together, never as two separate writes:
```bash
cat >> ".orchestrate/logs/{ID}-phase{N}.log" << 'EOF'
=== Phase N (retry R) — <name> <ISO> ===
<full PHASE OUTPUT block>
EOF
```
Include `(retry R)` in the header only when `R > 0` — check the phase's own retry count before writing, don't hard-code it. If the PHASE OUTPUT block is missing (raw-text fallback), still write the body, prefixed with `[no PHASE OUTPUT block — raw agent text below]`, rather than dropping it. **Never write the header via a separate call "to mark progress" and come back for the body later** — a header-only log with no body is worse than no log at all, since it looks like the phase ran but recorded nothing.

**State write is mandatory after every inline phase** — follow Steps A/B/C immediately. Never defer or batch.

**Inline skill invocation:** For `[inline · /skill-name]` phases, read the skill's SKILL.md, follow its instructions directly. Announce `▶ Phase N — <name> (inline)`.

### Agent phase execution

Announce `▶ Phase N — <name>`.

**Model tier selection:** Refer to the Phase Classification table above (Step 2 — Executor). If the phase keywords match "research / investigation / challenging analysis / reasoning", dispatch at **Sonnet** tier:

```javascript
Agent({
  description: "Investigation phase — determine approach",
  prompt: "Research the options and write a plan...",
  model: "sonnet",  // Premium tier for investigation phases
  run_in_background: false
})
```

For narrow execution phases (≤2 files, clear spec), use standard tier (Haiku or unspecified). The model parameter takes precedence over any `@claude/*/SKILL.md` frontmatter, so always specify explicitly when a phase tier differs from the skill's default.

**Agent prompt must include:**
1. Prior phase summaries
2. Absolute working directory
3. `## Shared Context` from project.md (paste verbatim — gives agent project-level knowledge)
4. Acceptance criteria: "This phase is complete when: 1. … 2. … 3. …"
5. Required output: `## PHASE OUTPUT` block with files_changed / summary / confidence / blockers / acceptance_criteria_met / test_evidence
6. If skill embedded: paste SKILL.md body directly — do NOT invoke Skill tool from within agent
7. Instruction: also write a top-level `files_changed: <paths>` line into the task file itself (not only inside the per-phase `## PHASE OUTPUT` block's `files_changed` field or prose) — Completion's §6b-direct and §6d both grep the task file for `^files_changed:` to classify the change; a top-level line lets them do that without re-deriving it from every phase log

**Parallel phases:** launch as multiple Agent calls in one message (max 6). Wait for all before assessing.

**Foreground vs background:** default foreground. Use `run_in_background: true` only when > 5 min expected AND there is independent work to run concurrently.

After agent returns: extract `## PHASE OUTPUT`. If missing → treat as ⚠️ with gap "no PHASE OUTPUT block".

**Phase log write (mandatory — atomic, single call):** Append the full PHASE OUTPUT block (or the raw agent return text if block is missing) to `.orchestrate/logs/{ID}-phase{N}.log` the same way as inline phases above — one call, header + body together, `Phase N (retry R)` when R > 0. Never write the header via a separate call "to mark progress" and come back for the body later.

### Critic & micro-verifier (always inline)

For execution and reasoning phases:
- **PASS** — all criteria met AND no `✗` in `acceptance_criteria_met` AND `test_evidence` shows behavioral confirmation (not just file existence)
- **PARTIAL: \<gap\>** — most criteria met but one unmet; OR one or more `✗` in `acceptance_criteria_met`; OR `test_evidence` is absent/weak for an execution phase
- **FAIL: \<reason\>** — key criterion not met or blocker caused by this change

**Rule:** any `✗` in `acceptance_criteria_met` disqualifies PASS — minimum PARTIAL.
**Rule:** for execution phases, `test_evidence: n/a` or missing = PARTIAL unless the phase made zero file changes.
**Rule (external-repo commit hygiene gate — non-skippable):** if any `files_changed` path resolves outside this project's own root, `test_evidence`/`blockers` MUST show the pre-edit `git -C <target-repo-root> status --short -- <file>` check plus either a local commit or an explicit stated reason it's left uncommitted (per the External-repo commit hygiene rule above). Its absence is not a stylistic gap — treat it exactly like a missing `test_evidence` for an execution phase: PARTIAL, not PASS, even if every other criterion is met.

If `files_changed` non-empty: run Bash verify (build, lint, fast tests). Override to PARTIAL if fails.

Classify blockers: `pre-existing` or `caused-by-change`. Pre-existing → note only, do not downgrade.

For **simple** and **instructional** phases: apply a lightweight confidence-only gate (no full criteria assessment). If `confidence: low`, downgrade to ⚠️ per the Step B verdict table; high or medium confidence → ✅.

**Regression "teeth" tests — back up before breaking a tracked file, restore from the backup.** When a Test & Verify step must temporarily break a **tracked** source file to prove a regression actually fails (a "does this test have teeth?" check), first back the file up with `cp <file> <file>.bak` (or `git stash` / a `git checkout -- <file>` restore point) and restore it **from that backup** — NEVER reconstruct the file from model context (that risks silent truncation/drift). After restoring, confirm `git diff --stat` for that file is empty.

### Project-local smoke scripts (Test & Verify)

When a task's **Goal**, **Acceptance Criteria**, or registry **summary** names a project-relative script (e.g. `examples/langgraph/smoke_pattern1_drop.py`), the Test & Verify phase MUST run that script from the project root — do not substitute file-existence or read-only checks.

**Detection:** task summary, AC bullets, or phase acceptance criteria mention a path ending in `.py`/`.sh`, or an explicit `python3`/`bash` command.

**Execution:** run from project CWD; record exit code and tail output in `test_evidence` and `.orchestrate/logs/{ID}-verify.log`.

**Examples:**
- Summary "Pattern1 Smoke Test" → `python3 examples/langgraph/smoke_pattern1_drop.py`
- AC "run `bash scripts/foo.sh`" → execute exactly that path relative to project root

---

## Auto-Resolution Check & Human-Only Block Classifier

Writing `status: needs_human` without first attempting self-resolution is a **protocol violation** — a human's attention is the most expensive resource in a manual, synchronous model, more so than in the old async one. Before setting `status: needs_human` (Step C's ❌ branch below), you MUST:

**1. Check for trivial self-resolution first.** Any of these mean the block is NOT genuinely human-only — attempt the action instead of parking:
- **C1** a creatable missing directory under the project root
- **C2** deferred/out-of-scope AC language already present in the phase block
- **C3** a one-shot retryable transient error (EPIPE/ETIMEDOUT/429-style)
- **C4** a referenced report/doc already shows closure (`**Status:** ✅`, `**Closed:**`)
- **C5** a downstream task this one references is already `complete` in the registry
- **C6** a locally-executable action mislabeled as a block — a cross-project file write, a reversible settings/config write, a script you can just run. "Looked risky" or "cross-project" is not itself a block.

**2. If none of those resolve it, apply the Human-Only Block Classifier.** A task may only be left `needs_human` when it states a **concrete external dependency the agent cannot satisfy itself** — any one of:
- A live cluster/infra op the agent cannot run (a blocked `kubectl apply/exec`, no credentials, no access).
- An external service that must recover on its own (a third-party API outage, an external system in a bad state) — outside the agent's control.
- A missing human decision, credential, or approval the agent has no way to obtain.

**NOT valid blockers — attempt them, never gate on them:** a cross-project or local file write (you can write to any path under your own project tree), a reversible settings/config write, a script you can just run. "I didn't try" or "looked risky" are not concrete external dependencies.

**3. Structured ask (genuine blockers only):** to land `needs_human`, the task file must carry `needs:`, `why:`, `to_clear:` naming the concrete external dependency — free-text "BLOCKED ON HUMAN" alone doesn't satisfy this; attempt self-resolution instead.

**4. Retry a prior tool-level rejection once before trusting it.** A genuine Write/Shell "Rejected" event on a cross-project or local path was real for *that* session, but the rejection can be session-scoped rather than a durable restriction — before re-deriving `needs`/`why`/`to_clear` from a task parked for this reason, retry the exact same call once; it may have silently cleared.

**5. Park, don't silently keep re-asking.** Once the classifier confirms a genuine human-only block, write `bypassed_at: <ISO>` + `bypass_reason: <one line>` into the task file and leave the registry row at `needs_human` — this is a durable marker so a later session (yours or a human's) sees at a glance that this was already evaluated, rather than re-litigating the same block from scratch. Clear it (`unblock-task`, or a human editing the task file with the resolution) once the block is actually resolved.

**INV/IMPL/VERIFY chain — re-verifying after later human action.** For work that must touch a shared external system (a git push, a live cluster mutation) under a gating convention, splitting it into three tasks — `*-INV` (read-only, writes an exact-commands plan), `*-IMPL` (gated, stages the plan's commands into a script, never runs it), `*-VERIFY` (depends on IMPL, independently checks live state) — still applies in the manual model. `*-VERIFY`'s dependency only tracks IMPL reaching `complete` (script *staged*), not the human actually *running* it later, so VERIFY can correctly report "not yet done" and complete normally before the human runs the staged script. When you later learn the script *has* run: manually re-perform VERIFY's own checks and append a dated `## Re-verification — <ISO>` section to its result doc — don't edit or delete the original "not yet done" section, and don't create a new task for this; append below it so both verdicts stay on record.

---

## Feedback → Decision → Execute (Steps A/B/C)

**Step A — Capture:**
```
phase N status → awaiting_critic
phase N captured_output → {summary, confidence, files_changed, blockers, acceptance_criteria_met, test_evidence}
phase N raw_output → <full PHASE OUTPUT block text>
```
Append the raw output block to the task state file under the phase section (so `.orchestrate/tasks/{ID}.md` contains a full record of what Claude produced). Update project.md registry: `status: awaiting_critic`.

**Step B — Verdict table:**

| Assessment | Confidence | Blockers | Verdict |
|---|---|---|---|
| PASS | high or medium | none | ✅ |
| PASS | low | none | ⚠️ "low confidence" |
| PASS | any | pre-existing only | ✅ with note |
| PASS/PARTIAL | any | caused-by-change | ❌ first blocker |
| PARTIAL | any | any | ⚠️ critic's gap |
| FAIL | any | any | ❌ critic's reason |
| (block missing) | — | — | ⚠️ "no PHASE OUTPUT block" |

Simple/instructional: high/medium confidence → ✅, low → ⚠️.

**Step C — Act:**

- **✅** → write checkpoint (`✓ complete`, copy summary). Reset retries to 0. Update project.md: `current_phase += 1`.
  - Gated: `⏸ Ready for Phase N+1 — "go" · changes · "skip" · "abort"`
  - Auto: `✓ Phase N — <summary>`, immediately execute next ready phase(s)

- **⚠️** → increment retries. `🔍 Gap: <what's missing>`. Re-invoke with gap appended.
  - Retry schedule (agent phases): retry 1 → original tier; retry 2 → upgrade (Haiku→Sonnet, Sonnet→premium); retry 3 → halt (Sonnet-tier) or retry 4 → halt (Haiku-tier). Premium: retry 1 → premium; retry 2 → halt.
  - Inline phases: after 2 retries, escalate to agent/Haiku on retry 3, halt on retry 4.

- **❌** → write `✗ failed`. **Before** updating project.md to `status: needs_human`, you MUST run the **Auto-Resolution Check & Human-Only Block Classifier** above. Only set `status: needs_human` if the block passes the classifier (a concrete external dependency) — a locally-executable action (cross-project file write, reversible config write, a runnable script) is NOT a valid block: attempt it instead and retry.
  - Gate: `⏸ retry · skip · replan · abort · instruct`

**Auto-Insert Phase 10 Reminder:** When updating `current_phase` in the ✅ checkpoint (Step C), check if the newly-incremented phase number exceeds the task file's `total_phases`. If so, Phase 10 (Completion) is next and has not been inserted yet. **Append immediately** to the task file:

```markdown

### Phase 10: Completion [inline · ceremony]
status: pending
- [ ] §6b-direct review complete (verdict: PASS | PARTIAL | FAIL)
- [ ] §6d wiki ingestion (page: ___ | not persisted: reason)
- [ ] Shared Context updated (or "n/a — no new findings")
- [ ] Improvement Suggestions filed (or "none: reason")
```

Then log: `⚠️ Phase 10 (Completion) auto-inserted — complete the checklist before archiving`.

This reminder makes it **impossible to forget** Completion: it's visibly in the task file, numbered, and ready to checkpoint like any other phase.

---

## Auto Mode Loop

```
LOOP:
  1. Read task file — find ready phases
  2. None remain → Completion → exit loop
  3. Launch ready phases: inline (direct) or agent (Agent tool), parallel if multiple
  4. Run Steps A/B/C for each
  5. All ✅ → goto LOOP immediately
  6. ⚠️ → Step C ⚠️ branch, goto LOOP
  7. ❌ → checkpoint all ✅ in batch, halt and gate the human
```

Never stop between steps 5 and 1 in auto mode.

**Parallel batch mixed results:** checkpoint ✅ immediately; re-invoke ⚠️; on any ❌, halt and gate.

## Gated Mode Loop

When a gated task runs (via "go" or "go auto" approval):

```
GATED:
  1. Mark registry `running`, start Execution Loop
  2. Run phases sequentially until all ✓ complete OR any ❌ blocked
  3. **When no ready phase remains:** MUST transition to Completion
  4. Run Completion (§6b-direct, §6d, context update, improvements)
  5. Archive and mark registry `complete`
```

**Critical difference from auto mode:** gated tasks NEVER skip Completion. If a phase blocks with `❌ needs_human`, halt there — do not proceed to Completion until human approval. But once approved and phases reach completion, Completion is not optional.

---

## Completion — Mandatory Post-Execution Sequence

⚠️ **Completion is not optional.** Tasks are not truly complete until these steps are explicitly run. Do not archive a task, do not mark it complete in the registry, do not move on to the next task until §6b–§6d have been documented.

When all phases are `✓ complete`:

**Timestamp contract (mandatory — History tab depends on this):**

Capture **once** at the start of Completion — never invent or round timestamps (forbidden: `T22:00:00Z`, `T12:00:00Z` unless that is the actual wall time):

```bash
COMPLETED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ARCHIVE_STAMP="$(date -u +%Y%m%d-%H%M%S)"
```

Use the **same** `COMPLETED_AT` for:
- registry `last_activity` (exact ISO, not the word `now`)
- verify log header: `=== Verification run ${COMPLETED_AT} ===`

Use the **same** `ARCHIVE_STAMP` for the archive filename prefix: `orchestrate-history/${ARCHIVE_STAMP}-${ID}-${slug}.md`

Use `date -u +%Y-%m-%d` (from `COMPLETED_AT`) for the MANIFEST date column.

On each phase checkpoint (Step C ✅), also set registry `last_activity` to `$(date -u +%Y-%m-%dT%H:%M:%SZ)` so partial progress is accurate.

**1. Archive task file:**

- **Pre-archive Completion gate (mandatory, run BEFORE anything else):** verify Phase 10 (Completion) is complete before archiving. Check the task file:
  ```bash
  if ! grep -q "### Phase 10: Completion" .orchestrate/tasks/{ID}.md; then
    echo "ERROR: Phase 10 (Completion) section not found in task file"
    exit 1
  fi
  if ! grep -A 5 "### Phase 10: Completion" .orchestrate/tasks/{ID}.md | grep -q "✓ complete\|status: complete"; then
    echo "ERROR: Phase 10 (Completion) is not marked ✓ complete"
    echo "All four checklist items must be completed before archiving"
    exit 1
  fi
  ```
  Refuse to archive if Phase 10 doesn't exist or isn't marked complete. This is a hard gate — do not proceed without it.

- **Pre-archive duplicate-existence check (mandatory, run BEFORE any `cp`/MANIFEST-append/`rm` below):** since another concurrent interactive session can legitimately be working the same project, check for an existing archive before writing one — the same check the Execution Loop's **Pre-execution duplicate-completion guard** (above) uses:
  ```bash
  ls .orchestrate/../orchestrate-history/*-"{ID}"-*.md 2>/dev/null   # or: grep -l "{ID}" orchestrate-history/*.md 2>/dev/null
  ```
  - **No hit:** proceed with the archive steps below unchanged — this is the common case.
  - **Hit (archive already exists for this ID):** skip the `cp`/MANIFEST-append/`rm` entirely — do not touch the archive file, do not append a duplicate MANIFEST line. Reconcile instead: confirm the registry row reflects `complete` (flip it if it still shows `running`), confirm a MANIFEST line exists for that archive filename (`grep` `orchestrate-history/MANIFEST.md`; do not append a second line if one is already present). Continue to step 2 (Update project.md registry) and the rest of Completion as normal — only the physical archive/copy/delete is skipped.
- Ensure `<project root>/orchestrate-history/` exists.
- Copy `.orchestrate/tasks/{ID}.md` → `orchestrate-history/${ARCHIVE_STAMP}-${ID}-<slug>.md` (use `ARCHIVE_STAMP` from timestamp contract above — not a separate guessed time)
- Add `tags:` line to archive copy.
- **Mandatory:** Append one line to `orchestrate-history/MANIFEST.md` in the canonical format `YYYY-MM-DD | filename | summary | tag1, tag2` via a direct file edit — validate the date format and reject any field containing `|` before writing. Skipping MANIFEST breaks History search — never omit it.
- Delete original task file from `.orchestrate/tasks/`.
- **Pre-archive files_changed self-check (mandatory, run BEFORE copying/deleting):** if ANY phase's `files_changed` (from `.orchestrate/logs/{ID}-phase*.log` or the phase's `## PHASE OUTPUT` block) was non-empty, the task file MUST already have a top-level `files_changed:` line. Check with `grep -q '^files_changed:' .orchestrate/tasks/{ID}.md`. If the grep fails but any phase shows non-empty `files_changed`, derive the union of paths from the phase blocks/logs and insert a `files_changed: <union>` line into the task file NOW, before archiving — do not proceed to archive/delete until the line is present. This catches the exact omission (an inline phase that changed files but never wrote the top-level line) that silently causes §6b-direct/§6d to think nothing changed.
- **Self-check before marking complete:** archive file exists on disk AND matching MANIFEST line was appended (grep `filename` in MANIFEST.md).
- **No duplicate registry rows** for the same task — if a job is re-registered under a new ID, remove or alias the stale row.
- **Cross-project task summaries** (and archive MANIFEST lines) must include the project slug so History search finds them.

**2. Update project.md registry:** set `status: complete`, `last_activity: <COMPLETED_AT>` (the exact ISO from timestamp contract — never a rounded placeholder).

> **Registry-row invariant (every writer/checker MUST hold this).** A valid data row is `| ID | summary | mode | phase | status | last_activity |` — exactly 8 `|`-fields with an EMPTY trailing `$8`. The canonical *structural* check is `awk -F'|' 'NF!=8 || $8!=""'` — a bare `NF!=8` is INSUFFICIENT because the historic phantom-timestamp corruption (`... | last_activity | new_ts`, no trailing pipe) is NF==8 with a NON-empty `$8` and a bare check misses it.
>
> **NF==8 is NECESSARY but NOT SUFFICIENT.** A *field-shift* corruption — e.g. an off-by-one awk update that overwrites the `mode` column with a phase number (`auto`→`2`) — preserves the 8-column count AND the empty trailing `$8`, so it sails past the structural check while the row is semantically corrupt. Every checker MUST therefore ALSO assert a value DOMAIN on the two enum columns: **mode (awk `$4`) ∈ {auto, gated}** and **status (awk `$6`) ∈ {pending, running, awaiting_go, awaiting_critic, complete, failed, needs_human}**. The full check is additive: `NF!=8 OR $8!="" OR mode∉domain OR status∉domain`. (The structural breach can be auto-repaired by collapsing columns; a field-shift cannot — the value is genuinely wrong — so it surfaces as a WARNING for a human.) Update rows IN PLACE (never append a column).
>
> **Row updates — use the `Edit` tool, reproduce the column format byte-for-byte.** There is no helper script — every session updates registry rows via a direct `Edit` on `project.md`. The replacement MUST reproduce the exact column format (same field order, same spacing/padding around each `|`-delimited field) — not a freehand rewrite — or it will silently introduce the field-shift corruption described above. Update rows IN PLACE; never append a column.
>
> **If `Edit` itself is denied by the permission classifier — retry once, then stop and ask.** Retry the identical `Edit` call once, since denials can occasionally be transient. If it is still denied, STOP: do not attempt a workaround (`Bash` `echo`/`sed`, an alternate tool) to land the same change — that would defeat the denial's stated intent. Surface the exact planned patch to the human via `AskUserQuestion` and wait for out-of-band permission, then retry the identical `Edit` call.
>
> If `Edit` is unavailable for some other reason, fall back to hand-rolled awk using the field map below:
> ```bash
> # awk field map for a data row:  $1="" $2=ID $3=summary $4=mode $5=current_phase $6=status $7=last_activity $8="" (trailing)
> awk -F'|' -v OFS='|' -v id="$ID" -v ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
>   /^\|[[:space:]]*[0-9]/ && NF==8 {
>     rid=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",rid)
>     if (rid==id) { $6=" complete "; $7=" " ts " " }   # $4=mode $5=current_phase $6=status $7=last_activity
>   }
>   { print }
> ' "$PROJ" > "$PROJ.tmp" && mv "$PROJ.tmp" "$PROJ"
> ```

**3. Update Shared Context** — see section below.

**4. Auto-Verification Run:**

If the plan included a Test & Verify phase and its log (`.orchestrate/logs/{ID}-verify.log`) was already written by that phase, use its results directly — skip re-running. Otherwise, run automated checks now and write results to `.orchestrate/logs/{ID}-verify.log`:

```bash
# Detect and run test/build commands (try each; skip if not found)
VERIFY_LOG=".orchestrate/logs/${ID}-verify.log"
echo "=== Verification run $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> "$VERIFY_LOG"

# Check declared output files exist
for f in <files_changed from all phases>; do
  [ -f "$f" ] && echo "✓ $f" >> "$VERIFY_LOG" || echo "✗ MISSING: $f" >> "$VERIFY_LOG"
done

# Auto-detect and run test/build commands (try each in order; stop at first match)
if [ -f "package.json" ]; then
  (npm test 2>&1 | tail -20) >> "$VERIFY_LOG" || true
  (npm run build 2>&1 | tail -20) >> "$VERIFY_LOG" || true
elif [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
  (python -m pytest --tb=short -q 2>&1 | tail -20) >> "$VERIFY_LOG" || true
elif [ -f "Makefile" ]; then
  (make test 2>&1 | tail -20) >> "$VERIFY_LOG" || true
elif [ -f "go.mod" ]; then
  (go test ./... 2>&1 | tail -20) >> "$VERIFY_LOG" || true
else
  echo "no test runner detected — skipping" >> "$VERIFY_LOG"
fi

echo "=== done ===" >> "$VERIFY_LOG"
```

Classify verify result: **✓ passed** · **⚠ warnings** · **✗ failed**. Include result in Job Verification block. If `✗ failed` and failure is caused-by-change: gate before archiving.

**5. Job Verification:**
```
── Job Verification ──────────────────────────────
Task:           <original task>
Phases:         X complete · Y failed/skipped
ACs covered:    ✓ Phase N · ✗ Phase N · N/A Phase N
Outputs exist:  <each declared output — present / missing>
Verify run:     ✓ passed | ⚠ warnings | ✗ failed | skipped
Regressions:    none · or <description>
Confidence:     high | medium | low
──────────────────────────────────────────────────
```

If low confidence or any ✗ AC: gate with `⚠ Verification found gaps`.

**6. Goal Self-Assessment:**

After verification, assess whether the original task goal was fully met by reviewing all phase outcomes.

**Trigger:** run always at completion. Declare a gap if ANY of:
- A phase has `✗ criterion` in `acceptance_criteria_met`
- A phase had a `PARTIAL` verdict that was accepted without re-run
- Overall job confidence is `low`

**Output block:**
```
── Goal Self-Assessment ──────────────────────────
Goal:      <original task prompt>
Delivered: <one-line summary of what was actually completed>
Verdict:   ✓ goal met | ⚠ partial | ✗ gap detected
Gap:       <concise description of what was not delivered>  ← omit if met
Follow-up: <what remains, specific enough to hand off as a new task> | none
──────────────────────────────────────────────────
```

**If a gap is detected, state it clearly and stop there** — do not auto-file a follow-up task. Since execution is manual and synchronous, the human reading this output is right here; describe what remains specifically enough that they can start a new task for it themselves (a plain-English description is enough — Phase Classification handles the rest) if they want it done. Never leave a gap unstated to avoid the auto-filing step this replaced — a described-but-not-started gap is fine; a silently-dropped one is not.

**6b (removed 2026-08-09).** This step used to auto-enqueue a `kind: review` + `kind: tests` follow-up ticket for every code-changing task, executed by a later async tend cycle. That infrastructure — the async tend model, `.orchestrate/bin/*.sh` helper scripts, and the draining mechanism — was removed entirely on 2026-08-09. The `.orchestrate/bin/` directory is confirmed **entirely empty and intentionally so** (see "Removed: async tend/inbox infrastructure" at the top of this file). **§6b-direct below is now simply how this works**, not a fallback.

**6b-direct. Direct independent review (code-changing tasks only) — mandatory, self-contained, never silent:**

This step exists because the async infrastructure that used to defer review to a later tend cycle (§6b, above) is gone and will not return. Instead of a deferred follow-up ticket, this step runs an independent review **synchronously, in the current session**, as an inline Agent() dispatch with no context from the implementation phases. The "tests" half of §6b's original job is already covered by Completion step 4 (Auto-Verification Run), which runs the project's test/build commands synchronously — this step adds the independent-review piece.

Run this step for every `complete` task whose aggregate `files_changed:` contains ≥1 code/test/script/config file (`*.ts *.js *.py *.go *.sh *.sql *.yaml *.json` … `Dockerfile Makefile`), EXCLUDING pure docs/log/registry/archive/control-plane paths (`*.md *.txt`, `.orchestrate/logs/**`, `.orchestrate/project.md`, `orchestrate-history/**`, `MANIFEST.md`). A zero-code-change task (pure docs/query) skips this step — say so in the required output line below, don't omit it.

- **Mechanism:** dispatch a fresh `Agent()` call with **no shared context from the implementation phases** — the same independence trick task-breakdown's Challenge phase uses (a fresh Agent-tool dispatch has no memory of the implementing phase's own reasoning, only its written output) — instructed to review the actual diff (`files_changed:` across all phases) against: (1) the task's stated Acceptance Criteria, (2) any Out-of-Scope/Prohibitions boundary named in the task file, (3) general correctness (obvious bugs, missed edge cases, security issues). The reviewer reports a verdict: **PASS** (no issues), **PARTIAL: \<gap\>** (non-blocking issues worth noting), or **FAIL: \<reason\>** (a real problem the implementation missed).
- **FAIL handling:** a FAIL verdict does not itself reopen completed phases or block archiving — Completion has already run by the time this step fires. Record the FAIL verbatim in the required output line below; if it's substantive, mention it in Step 7's Improvement Suggestions output too, same as any other Completion-time finding.
- **Required Completion output line (never silent):**
  ```
  Review: <PASS | PARTIAL: <gap> | FAIL: <reason>> (independent Agent() dispatch) | not reviewed: <one-line reason>
  ```
  The `not reviewed:` branch fires only when the code-change predicate didn't trigger (a docs-only/zero-code-change task) — state that plainly rather than omitting the line.

**6c (removed 2026-08-09).** This step used to auto-enqueue a `kind: wiki-sync` follow-up ticket for every completed task, executed by a later async tend cycle. Same removal as §6b — **§6d below is now simply how this works.**

**6d. Direct Wiki Ingestion (task state into a wiki page) — mandatory, self-contained, never silent:**

Run this step for every `complete` task, at the end of Completion, before Improvement Suggestions (7).

**Step 1 — decide if this is worth persisting.** Reuses the exact judgment `grounded-investigate/SKILL.md`'s own Step 6 ("Persist to Wiki") already applies — don't reinvent a second philosophy:
- **Persist** when the task involved an architectural/design decision, a non-obvious fact about the environment or codebase (especially one that contradicts existing documentation), a corrected mistaken assumption, or a reusable pattern/lesson a future session would otherwise have to re-derive.
- **Skip the write** when the outcome is routine/mechanical — a scheduled sync with nothing new to report, a one-line config bump, applying an already-documented pattern with no new information.
- **Never skip silently either way.** Whichever branch this lands in, the Completion output MUST carry the `Wiki:` line specified below — a skip is a stated, one-line decision, not an absence.

**Step 2 — if persisting, choose *how*, in this precedence order:**
1. **Existing closely-related page, still `lifecycle: active`.** Check the vault's `index.md` for a page already covering this exact subsystem/decision thread (same topic, same skill, same ongoing redesign). If one exists, append an `## Update — <ISO>` section to it instead of creating a duplicate — do not restate the page's original content, just add what's new.
2. **Substantial, self-contained new decision or finding, no existing page fits.** Use the `wiki-capture` skill — it classifies the content, rewrites it as declarative knowledge, and produces a properly cross-linked page. Prefer it over hand-rolling a page.
3. **Routine/operational outcome that's still worth a trace, but doesn't rise to (1) or (2).** Fall back to the topic-page-append mechanism this step used to be the only option: extract the task's **topic** (tags, title keywords, or project context), resolve it to a page path (e.g. `rate-limiting` → `$VAULT/Rate Limiting.md` or `$VAULT/topics/Rate Limiting.md`, falling back to `$VAULT/Orchestration/Completed Tasks.md` if no topic resolves), distill the archived task state (`orchestrate-history/{ARCHIVE_STAMP}-{ID}-*.md`), and append `## Completed: <task summary> — <ISO>` with phase summaries and key learnings as bullets — creating the page with `## Overview`/`## Completed Tasks` sections if it doesn't exist yet.

**Step 3 — mandatory `log.md` line, regardless of which path above was used.** Append one `CAPTURE` line to `$VAULT/log.md` (the `wiki-capture` skill's own protocol does this automatically for path 2 — for paths 1 and 3, which don't have their own logging protocol, append it manually: `- [<ISO>] CAPTURE type=<update|routine> page="<path>" title="<title>" task=<ID>`). A wiki write with no `log.md` trace is exactly the gap that motivated writing this step out explicitly (a prior task's page-append happened without one).

**Step 4 — required Completion output line (never silent):**
```
Wiki: persisted to <page path> (<method: existing-page-update | wiki-capture | topic-page>) | not persisted: <one-line reason>
```

**Idempotency:** re-running on an already-ingested task is a clean no-op — check for an existing `## Completed: <task summary>` (path 3) or `## Update — <ISO>` (path 1) section keyed to this task's ID before writing again.

**7. Improvement Suggestions:**

Print the suggestions block to the user:
```
── Suggestions ───────────────────────────────────
Orchestrator:
  • <suggestion — or "none (reason: <one line>)">
Skills invoked:
  • [/skill-name] <suggestion — or "none (reason: <one line>)">
──────────────────────────────────────────────────
```

**Default: write an improvement file.** "None" requires an explicit stated reason. Dedup prevents noise — let dedup be the gate, not your judgment.

**Write an improvement file when ANY of the following are true:**
- A phase required a retry (even retry 1)
- A phase was accepted as PARTIAL without re-run
- A blocker was noted (pre-existing or caused-by-change)
- A gap was declared in the Goal Self-Assessment block
- A new failure mode, workaround, or non-obvious constraint was discovered
- A SKILL.md rule was ambiguous, missing, or required interpretation during this task
- The task surfaced a pattern that would make future tasks faster if documented

**"None" is valid only when ALL of the following hold:**
- Zero retries across all phases
- All phases: PASS, high or medium confidence, no blockers
- No new patterns or failure modes observed
- No ambiguity required interpretation

When outputting "none", always append a one-line reason: `none (reason: 0 retries, all PASS, nothing new observed)`.

For each qualifying suggestion, append an entry to `skill-improvement-backlog.md` (project root) — this is the canonical improvement queue; it's a plain file a human or a later task-orchestrate session reads directly, no drain mechanism needed.

**Dedup before appending** — skip if an existing entry has ≥70% word overlap with the normalized suggestion title, or the same `triggered_by: <this task ID>` value.

**Entry format:**
```markdown
## <improvement title>
triggered_by: <task ID>
applies_to: <path in this skill collection — e.g. skills/task-orchestrate/SKILL.md, skills/<name>/SKILL.md>

Observation: <what was seen — retry count, gap text, repeated partial verdict>
Change: <specific change — name the file, section, behavior>
Acceptance: <how to verify the change landed — e.g. "installed SKILL.md reflects it">
```

**Doc-coupled tests — update assertions alongside intentional documented-behavior edits.** If your own test suite for this skill contains `skill_has`-style assertions that grep for literal SKILL.md prose, these are doc-conformance guards, not behavioral regressions: when you deliberately reword documented behavior, the matching assertion will FAIL until you update it to the new wording. Treat such a failure as "the doc-conformance test caught my edit," not a bug — re-point the assertion at the new text in the same change.

**Output:**
```
TASK COMPLETE — <task>
✓ Phase 1 [inline · simple] — <summary>
✓ Phase 2 [agent/Sonnet] — <summary>
Outputs: <list>
```

---

## Shared Context Update

After every task completion, extract durable project knowledge and append it to `project.md ## Shared Context`. This is what makes future tasks smarter — don't skip it.

What to append (only if genuinely new and not already there):
- **Architectural decisions** made during this task ("using Postgres for X, not ClickHouse")
- **API/service behavior** discovered ("endpoint Y returns 429 after 100 req/min")
- **Recurring constraints** ("all migrations must be backward-compatible with the running service")
- **Conventions established** ("new files in this module use camelCase, not snake_case")
- **Known failure modes** ("bfs find does not support -newermt; use -mmin instead")

What NOT to append:
- Task-specific details that don't apply to other tasks
- Information already in the codebase or CLAUDE.md
- Anything ephemeral

Format — append as bullets under a dated heading:
```markdown
### {YYYY-MM-DD} — {task summary}
- <finding 1>
- <finding 2>
```

---

## Rabbit Hole Prevention

After 4 retries (3 for Sonnet-tier, 2 for premium-tier):

```
⚠️ Phase N appears stuck (<diagnosis>).
Revised plan:
[re-planned phases from N onward]
⏸ "go" to adopt · "abort" · describe changes
```

Distinguish **compression-loss** (context compressed 3+ times → suggest splitting phase) vs **execution-stuck** (same error repeating → suggest replan or manual intervention).

---

## MCP Gates

Annotate MCP phases `[MCP: service-name]`. Pre-authorize at plan time via `"go auto, approve MCP: X, Y"`. Mid-flow: pause before each MCP phase unless pre-authorized.

---

## Quick Reference

```bash
# New task — plan it, review, then say "go" or "go auto" to run it immediately
/task-orchestrate "refactor auth in the web app to use JWT"

# Resume — list active tasks and pick one
/task-orchestrate resume

# Check project status
cat .orchestrate/project.md

# See all active tasks
ls .orchestrate/tasks/

# See phase-by-phase logs for a task
ls .orchestrate/logs/{ID}-phase*.log
```
