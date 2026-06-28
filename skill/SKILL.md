---
name: task-orchestrate
description: Unified project orchestrator with built-in watchdog. Maintains a project-scoped control plane (.orchestrate/) with shared context across all tasks, a task registry, and an inbox drop-zone. Phases, critic, and quality gates are unchanged. Built-in "tend" mode replaces the separate task-supervisor skill. Use for any task: simple fire-and-forget or complex multi-phase work. The watchdog runs as an OS-level heartbeat — no separate /loop needed.
inline: false
---

You are the **orchestrator**: you plan, approve, and execute — running phases inline with your own tools when that's efficient, spawning agents only when truly needed. You also maintain a project-scoped control plane and watch your own task registry for stalls.

**Spawn an agent only when:**
1. A phase is too large to fit in the main context (~10+ tool calls or 3+ files to create/rewrite)
2. Genuine parallelism is needed
3. A skill's embedded instructions make isolation valuable

For everything else, run inline.

**Note on task-supervisor:** That skill is deprecated. Supervision is now built in here via `tend` mode.

---

## Invocation Modes

Detect which mode applies from the input:

| Input | Mode |
|-------|------|
| `tend` | Watchdog — scan registry, drain inbox, notify on pending tasks |
| `tend go auto` | Watchdog + auto-execute — drain inbox, register tasks, execute `pending` tasks in parallel batches of up to 3; `awaiting_go` (gated) tasks always require explicit human "go" (launchd default) |
| `tend go auto <ID>` | Execute only task `<ID>` in auto mode; skip T-1/T-2 drain and T-4 general scan; used by parallel dispatch when run-job.sh pre-assigns a task |
| `inbox` | Show pending inbox items, wait for triage |
| `inbox go` | Triage inbox, then execute approved items (gated — phase checkpoints) |
| `inbox go auto` | Triage inbox, then execute all approved items unattended |
| `inbox "<plain text>"` | Structure plain text into an inbox file, then show triage UI |
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
  inbox/              # drop-zone: a .md file here = a task to register
  logs/
    heartbeat.log     # one line per tend cycle
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

## Tend Mode (built-in watchdog)

Invoked by the word `tend` or by the OS-level heartbeat (see Heartbeat Setup). Runs a lightweight cycle over the project registry. **Token cost on idle cycle: this file only.**

### T-0 — Lock

When invoked via `run-job.sh` (launchd), the environment variable `TEND_LOCK_MANAGED=1` is set and the lock is already held by the shell wrapper — skip this block entirely. The shell wrapper guarantees correct timestamps and release-on-exit regardless of whether agent shell access is available.

When invoked directly (e.g. `/task-orchestrate tend` in a Claude session), `TEND_LOCK_MANAGED` is unset — run the full block below.

```bash
if [ -z "${TEND_LOCK_MANAGED:-}" ]; then
  LOCK=.orchestrate/.tend.lock
  if [ -f "$LOCK" ]; then
    AGE=$(( $(date +%s) - $(date -r "$LOCK" +%s) ))
    [ $AGE -lt 360 ] && echo "Tend already running (${AGE}s). Exiting." && exit 0
    rm -f "$LOCK"
  fi
  date -u +%Y-%m-%dT%H:%M:%SZ > "$LOCK"
  trap 'rm -f "$LOCK"' EXIT
fi
```

### T-1 — Pre-flight (bash, no LLM context on idle)

**Stale inbox cleanup (run first):** Before NEED_ACTION scan, `run-job.sh` invokes (in order):
1. `.orchestrate/bin/cleanup-stale-inbox.sh` — stale root inbox + task files
2. `.orchestrate/bin/drain-inbox.sh` — **bash T-2 drain** (gated/ first, then root); registers rows and `mv` to `processed/`
3. `.orchestrate/bin/tend-need-action.sh` — if `NEED_ACTION=0`, logs idle and **skips agent dispatch**

When the agent session runs (NEED_ACTION=1), T-2 inbox drain may already be done — skip re-registration; proceed to T-4 registry scan.

`cleanup-stale-inbox.sh` behavior:
- Moves root `inbox/*.md` to `processed/` when the same basename already exists in `processed/`
- Moves root files whose embedded task ID (e.g. `Task ID:` line) matches a `complete` registry row
- Removes stale `.orchestrate/tasks/{ID}.md` when registry row is `complete`

```bash
bash .orchestrate/bin/cleanup-stale-inbox.sh "$(pwd)"

PROJ=.orchestrate/project.md
NEED_ACTION=0

# Stalled tasks in registry? (table rows only — not Shared Context prose)
grep -qE '^\|[^|]+\|[^|]+\|[^|]+\| (awaiting_critic|awaiting_go) \|' "$PROJ" 2>/dev/null && NEED_ACTION=1

# Inbox has non-deferred items? (auto path or gated path)
for f in .orchestrate/inbox/*.md .orchestrate/inbox/gated/*.md; do
  [ -f "$f" ] || continue
  grep -qE '^deferred_at:' "$f" 2>/dev/null && continue
  NEED_ACTION=1
  break
done

# Pending tasks in registry? (only relevant when mode is `tend go auto`)
# In go-auto mode, registered-but-unstarted tasks should also trigger execution.
# Check the invocation input: if it contains "go auto", scan for pending rows too.
if echo "$INPUT" | grep -q "go auto"; then
  grep -qE "\|\s*pending\s*\|" "$PROJ" 2>/dev/null && NEED_ACTION=1
fi
```

Where `$INPUT` is the full invocation string passed to the skill (e.g. `"tend go auto"`).

If `NEED_ACTION=0`: append `[<ISO>] tend — idle` to `.orchestrate/logs/heartbeat.log` and exit.

### T-2 — Drain inbox

**Stale in-place markers (run first):** Scan `.orchestrate/inbox/*.md` (top level only). For any file whose content matches `^processed_as:` **or** that was registered in a prior cycle but never moved: `mv` it to `.orchestrate/inbox/processed/<filename>`. Never leave completed inbox files in the top-level inbox directory.

**Registration rule:** After registering an inbox file in `project.md`, **physically move** it to `.orchestrate/inbox/processed/` using `mv` (or equivalent file move). **Do not** prepend `processed_as:` and leave the file in place — that pattern is deprecated and causes dashboard clutter.

**Inbox file format** (required for all enqueued tasks — human or automated):

```markdown
# <short task title>

## Goal
<1–3 sentences: what must be true when this task is done. Be specific — name files, endpoints, or behaviors.>

## Context
<Relevant background: which files are involved, what's already been tried, constraints, related tasks by ID.>

## Acceptance Criteria
- <measurable done-statement 1>
- <measurable done-statement 2>
```

When reading an inbox file:
- **Skip** files containing a `deferred_at:` line (anywhere before `## Goal`) — user deferred via inbox triage; leave in place until explicitly approved.
- If the file contains `source: self`: register as `mode: auto` unless the improvement **Goal** explicitly mentions a risky operation (see Gating Criteria below). Risky-op `source: self` files register as `mode: gated`, status `awaiting_go`. Non-risky `source: self` improvements auto-execute under `tend go auto`.
- If the file is plain text (no `## Goal` section): treat the entire content as the goal, but flag at registration: `⚠ inbox file <name> has no structured context — plan phase may need clarification`.
- If the file has the structured format: extract Goal as task summary, Context as shared background for the plan phase, ACs as phase acceptance criteria seeds.
- **Gating is risk-based, not location-based.** A file is registered `mode: gated`, status `awaiting_go` **only when its content meets the Gating Criteria below (a genuine risky op) OR it carries an explicit `gate_reason:` line** (the human override). A bare `mode: gated` marker or placement under `.orchestrate/inbox/gated/` is a *hint*, not a hard gate: if the task involves no risky op and has no `gate_reason:`, **de-gate** it — register `mode: auto`, status `pending` — and log the de-gate. Do **not** gate a task just because it is safe but happened to be filed under `gated/` (e.g. inbox-log-analyzer enhancement findings). Genuinely-gated tasks under **`tend`** or **`tend go auto`**: register in T-2, send PushNotification — never auto-execute.

**Inbox layout:**
| Path | Gating decision | `tend` | `tend go auto` (launchd) |
|------|-----------------|--------|-------------------------|
| `.orchestrate/inbox/*.md` | auto unless risky-op or `gate_reason:` | drain → notify | drain → execute |
| `.orchestrate/inbox/gated/*.md` | gated only if risky-op or `gate_reason:`; else **de-gated to auto** | drain → notify | de-gated → execute · genuinely-gated → notify (never auto-exec) |

**Gating Criteria — `mode: gated` only when the task explicitly involves (any one is sufficient):**
1. Live kubectl mutations (scale, patch, rollout, apply, delete) — also blocked by kube hook
2. DB mutations (INSERT, UPDATE, DELETE, DROP, ALTER, TRUNCATE) — also blocked by pg hook
3. `rm`/`mv` of tracked files or production data
4. External irreversible service calls (send email, post to Slack, trigger deploy pipeline)
5. Git force-push or branch deletion

`source: self` alone does not gate. SKILL.md edits + `make test` are safe and reversible — default `auto`. **Automated findings (e.g. inbox-log-analyzer enhancements) filed under `gated/` do not gate unless they describe a risky op above** — de-gate them to `pending`. The only way to force a gate on a safe task is an explicit `gate_reason: <why>` line written by a human.

**Interactive gating:** Plain `tend` (no `go auto`) still skips execution — sends PushNotification. Use `/task-orchestrate inbox` to triage before drain, or `/task-orchestrate go auto <ID>` for one-off interactive runs.

For each `.md` file in `.orchestrate/inbox/gated/` (process first):
1. Skip if `deferred_at:` present — leave file in place.
2. Read the file — extract title/goal. **Evaluate against the Gating Criteria.** If it involves a risky op **or** has a `gate_reason:` line → register `mode: gated`, status `awaiting_go`. Otherwise **de-gate**: register `mode: auto`, status `pending`, and append `[<ISO>] inbox — de-gated "<task title>" (no risky op) from gated/<filename>` to heartbeat.log.
3. Move file to `.orchestrate/inbox/processed/`.
4. For genuinely-gated files only, append to heartbeat.log: `[<ISO>] inbox — registered (gated) "<task title>" from gated/<filename>`

For each `.md` file in `.orchestrate/inbox/` (not in `gated/` subdirectory):
1. Skip if `deferred_at:` present — leave file in place.
2. Read the file — extract title/goal.
3. Register it in the project registry (`pending` for auto, `awaiting_go` for gated — gate only per the Gating Criteria: risky-op or `gate_reason:`; `source: self` alone does not gate).
3. Move file to `.orchestrate/inbox/processed/`.
4. Append to `.orchestrate/logs/heartbeat.log`: `[<ISO>] inbox — registered "<task title>" from <filename>`
5. **If mode is `tend`:** do not start execution — queued tasks wait for `go`/`go auto`.
   **If mode is `tend go auto`:** proceed — auto tasks (`pending`) will be executed in T-4; gated tasks (`awaiting_go`) will only be notified, not executed.

When a background inbox task is later executed (via `go auto` in tend mode), write a per-task log file at `.orchestrate/logs/{ID}-tend.log`:
```
=== Tend-driven execution — <ISO> ===
source: inbox/<original-filename>
task: <prompt>
<append each PHASE OUTPUT block as phases complete>
=== done ===
```

### T-3 — Load tools

`ToolSearch: "select:PushNotification"` — load only now that action is confirmed needed.

### T-4 — Scan registry

For each task in the registry:

**`awaiting_critic` (mode: auto):** Read its task file (`.orchestrate/tasks/{ID}.md`). Re-read this SKILL.md's Critic section. Run critic assessment inline. Write verdict + checkpoint. If ✅ and mode auto: continue execution loop. Append action to heartbeat.log.

**`awaiting_go` (mode: gated):**
- **Always (both `tend` and `tend go auto`):** Do NOT advance. Send `PushNotification`: `⏸ [{ID}] "{summary}" — gated, needs your "go"`. Log it. Gated tasks never auto-execute regardless of tend mode — they require explicit human `go <ID>` or `go auto <ID>`.

**`pending` tasks (from inbox drain this cycle OR already registered):**
- **Mode `tend`:** Send `PushNotification`: `📋 [{N} new task(s) queued — type "go" or "go auto" to start]`. Log.
- **Mode `tend go auto`:** Execute pending tasks in **parallel batches of up to 3**. `awaiting_go` tasks are never auto-executed — skip during batch collection.

  **Parallel batch execution protocol:**
  1. Collect ALL `pending` task IDs from the registry (not just drained this cycle). Skip `awaiting_go`, `needs_human`, `running`, `complete`, `failed`.
  2. Take the first batch of up to 3 IDs.
  3. For each task in the batch: mark as `running` in project.md (sequential, before dispatch), create `.orchestrate/tasks/{ID}.md` plan file if missing. Append to heartbeat.log: `[<ISO>] tend-auto — dispatching "<task title>" ({ID}) [batch N]`.
  4. Launch the batch as **parallel Agent calls** (max 3 simultaneous). Each agent prompt must include:
     - Full task file content (`.orchestrate/tasks/{ID}.md`)
     - SKILL.md Execution Loop instructions (paste relevant sections)
     - Absolute working directory
     - `## Shared Context` from project.md (verbatim)
     - Instruction: "Run the full auto execution loop for this task. When all phases are done, end your response with a `## TASK RESULT` block: `status: complete|needs_human|failed`, `summary: <one line>`, `phases_done: N`."
     - Instruction: "Do NOT update project.md — the parent session handles registry writes."
  5. After **all agents in the batch return**: for each agent result — read `## TASK RESULT`, update project.md row (`running` → final status), run Completion sequence (archive, MANIFEST) for any `complete` tasks. Log each outcome.
  6. **Blocked tasks never block the batch:** if an agent returns `needs_human` or `failed`, checkpoint its result immediately and continue — do not wait or retry within this batch. Log: `[<ISO>] tend-auto — task <ID> blocked (needs_human); continuing queue`.
  7. If more `pending` tasks remain after the batch, repeat from step 2 with the next batch.

  **Mode `tend go auto <ID>`:** Execute ONLY task `<ID>`. Skip T-1/T-2 (run-job.sh already did cleanup/drain). Skip T-4 general scan. Find `.orchestrate/tasks/{ID}.md`, run the full auto execution loop, update project.md row on completion. Used when run-job.sh pre-assigns tasks to parallel agent sessions.

**`needs_human` tasks:**
- Read task file at `.orchestrate/tasks/{ID}.md`. If the file is missing:
  - **Ghost-reset auto-job re-queue:** if the registry row is `mode: auto` AND `.orchestrate/logs/heartbeat.log` contains a `ghost-reset {ID}: running→needs_human` line (the job was stalled and reset by `run-job.sh`, never wrote a task file), set the registry row to `status: pending`, append `[<ISO>] tend-auto — re-queued ghost-reset auto job {ID} (no task file, stalled run)` to heartbeat.log, and let the next pending scan execute it. These are stalled automatable jobs (idempotent daily runs like wiki-ingest / inbox-log-analyzer), not genuine human blockers.
  - Otherwise (no ghost-reset line, or `mode: gated`), skip. Genuine human-blocked tasks have task files with `human_resolution: BLOCKED ON HUMAN` and no ghost-reset line — they never match the re-queue rule.
- Count phase sections (`### Phase N`). If **every** phase has `status: ✓ complete`, run the normal **Completion** sequence inline: update registry row to `complete`, archive task file to `orchestrate-history/`, append MANIFEST entry, delete task file from `.orchestrate/tasks/`.
- Append to heartbeat.log: `[<ISO>] tend — auto-resolved needs_human "<task title>" ({ID}) — all phases complete`
- If any phase is incomplete or missing `✓ complete`: run the **Second-Pass Auto-Resolution Check** before leaving the task blocked.

**First-Pass Auto-Resolution Check (before writing `needs_human`):**

Before setting registry `status: needs_human` during execution (Step C ❌ branch), run `.orchestrate/bin/first-pass-auto-resolve.sh <ROOT> <ID>`. If exit 0, inject `human_resolution: Auto-resolved (first-pass) — <reason>`, set registry to `pending`, log `[<ISO>] tend-auto — first-pass self-unblocked <ID>: <reason>`, and retry — do **not** write `needs_human`.

Trivial categories (enumerated): **C1** creatable missing dir under project root · **C2** deferred/out-of-scope AC language · **C3** one-shot retryable transient (EPIPE/ETIMEDOUT/429) · **C4** referenced report closure (`**Status:** ✅`, `**Closed:**`) · **C5** downstream referenced task `complete` in registry.

**Hard guard (skip first-pass):** `blocked_on: EXTERNAL`, `escalation_note:` + `blocked_on:`, or task `mode: gated`.

**Structured human ask (genuine blockers):** task file must carry `needs:`, `why:`, `to_clear:` (or `## needs` / `## why` / `## to_clear` sections). Free-text `BLOCKED ON HUMAN` alone fails the clear-human-ask criterion.

**Auto-requeue on unblock:** `run-job.sh` preflight runs `.orchestrate/bin/requeue-unblocked.sh` after `reset_stale_running_tasks`. Requeues when `requeue_when_exists:` path has closure markers, `to_clear` decision file is filled, or `human_resolution:` is injected without `BLOCKED ON HUMAN`.

**Second-Pass Auto-Resolution Check (T-4 `needs_human` branch):**

Before writing `needs_human` and skipping a task with incomplete phases, check these signals for automatic resolution. Read the task file's blocking phase blocks and project context:

1. **Deferral language in phase ACs:** Scan the failed/incomplete phase's `acceptance_criteria_met:` block and blockers field for markers: "deferred", "deferred to", "deferred — <team>", "not a blocker", "closed", "no action needed", "Forbidden", "out of scope". If **all** incomplete ACs contain explicit deferral or closure language → auto-resolvable.

2. **Report file closure:** If the task file or any phase block references a file path (e.g. `reports/phase3/capacity_report.md`), read that file. If it contains a `**Closed:**`, `**Status:** ✅`, or `**service GO/NO-GO verdict:**` section → auto-resolvable.

3. **Downstream task completion:** Scan project.md registry for any task whose summary or ID is referenced in this task's file (e.g. "superseded by", "closes with", "see also `<ID>`"). If the referenced task is `complete` → auto-resolvable.

**If ANY signal confirms auto-resolution:**
- Inject into the blocking phase block in the task file: `human_resolution: Auto-resolved — all ACs satisfied or explicitly deferred per <evidence summary>. No human action required.`
- Update project.md registry row: `status: pending`
- Append to heartbeat.log: `[<ISO>] tend-auto — self-unblocked <ID>: <one-line reason>`
- The task will be re-executed on the next T-4 pending scan or next tend cycle.

**If none of the signals confirm:** the task is genuinely blocked. **Park it — do not re-evaluate every cycle:** write `bypassed_at: <ISO>` and `bypass_reason: <one-line why it cannot move on>` into the task file (header or blocking phase block), and leave the registry row at `needs_human`. See **Bypass — park blocked tasks** below.

**All other statuses:** skip.

**Bypass — park blocked tasks (do not re-process every cycle):**

Any task the orchestrator has evaluated and confirmed cannot progress — a genuine human blocker, `blocked_on: EXTERNAL`, an unmet dependency, or a non-retryable failure — is **parked** with a durable marker so the tend cycle stops churning on it. This generalizes the human-only `human_resolution: BLOCKED ON HUMAN` bypass to **all** block types.

- **Write on block:** the Second-Pass fall-through above writes `bypassed_at: <ISO>` + `bypass_reason: <one line>` into the task file. Park only *after* first-pass and second-pass auto-resolution have both failed — never park a locally-resolvable "block" (cross-project file write, reversible config write, a script the agent can run); attempt those instead.
- **Skip while parked:** `bin/tend-need-action.sh` treats any `needs_human`/`failed` row whose task file carries `bypassed_at:` as **non-actionable** — it does not raise `NEED_ACTION`, so the launchd cycle never wakes the agent for it. Completion-eligible rows (all phases `✓ complete`) and ghost-reset re-queues remain actionable.
- **Clear on unblock:** the only exit from a parked state is an explicit unblock signal, which **removes** `bypassed_at:`/`bypass_reason:` and sets the row to `pending`:
  - `unblock-task` (human injects a resolution)
  - `bin/requeue-unblocked.sh` (`requeue_when_exists:` closure, `to_clear:` decision filled, or non-`BLOCKED ON HUMAN` `human_resolution:` injected)
  - a human edits the task file (file mtime newer than `bypassed_at:`) — re-evaluate once
  - a depended-on task reaches `complete`

### T-5 — Update shared context (after any completions this cycle)

If any tasks moved to `complete` this cycle: see **Shared Context Update** section below.

### T-6 — Release lock

Lock is released by the `trap` from T-0.

---

## Inbox Mode

Invoked by `inbox`, `inbox go`, `inbox go auto`, or `inbox "<plain text>"`. Operates on live files in `.orchestrate/inbox/` and `.orchestrate/inbox/gated/` — **not** on registry rows already in `awaiting_go` (use `resume` + `go auto <ID>` for those).

### Scan and display

Collect all `.md` files in `inbox/` and `inbox/gated/`, excluding files with `deferred_at:`.

Split into two lists:
1. **General inbox** — files without `source: self`
2. **Skill improvements** — files with `source: self`

Display:
```
── Inbox (N pending) ────────────────────────────────
[1] <filename>
    <title from first # line>
    mode: auto|gated  complexity: lightweight|moderate|complex (infer from Goal length/scope)

── Skill Improvements (M pending) ───────────────────
[4] improvement-<slug>-<ISO>.md
    <title>
    triggered_by: <task ID>

── Commands ─────────────────────────────────────────
approve [n…]   skip [n…]   edit [n]   all   improvements-only
or type plain text to add a new item
```

Number items sequentially across both sections (general first, then improvements).

If `inbox` alone (no `go`): display and wait for triage input — do not execute.

If `inbox go` or `inbox go auto`: after triage (or if user passed `all` implicitly with `inbox go auto`), register approved items and execute per their mode.

### Triage commands

| Command | Action |
|---------|--------|
| `all` | Approve every non-deferred pending item |
| `approve 1 3` | Approve listed numbers — move to registration + execution queue |
| `skip 2` | Prepend `deferred_at: <ISO>` as first line of file; item stays in inbox, hidden from display |
| `edit 1` | User revises item in natural language; rewrite file body; re-display updated item |
| `improvements-only` | Show only `source: self` section; triage commands apply to that subset |
| Plain text (no command prefix) | Structure into inbox format (see below), show preview, ask `[1] approve [2] edit [3] abort` |

**After approve:** for each approved file — run T-2 registration (move to `processed/`, register in `project.md`), then execute:
- `inbox go`: gated items → plan + `mode: gated` execution; auto items → plan + ask for go/go auto
- `inbox go auto`: execute all approved items in auto mode (including gated files once registered)

### Plain-text structuring (lightweight inline)

When user provides plain text (via `inbox "..."` or bare text after display):
1. Infer `# title` from first sentence.
2. Infer `## Goal` from user text (1–3 sentences).
3. Infer `## Context` from `.orchestrate/project.md ## Shared Context` if relevant.
4. Generate 2 `## Acceptance Criteria` bullets.
5. Show structured preview; on approve, write to `.orchestrate/inbox/<slug>-<ISO>.md` (or `inbox/gated/` if user requests gated).

Default new human items to `mode: auto` unless user says "gated" (or write to `inbox/gated/`).

---

## State File & Resume

**New task:** Generate ID `YYYYMMDD-HHMMSS`. Create `.orchestrate/tasks/{ID}.md`. Ensure `.orchestrate/project.md` exists (create with template if not). Register row in project.md registry.

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

| Condition | Executor |
|---|---|
| simple or instructional phase | **inline** |
| execution — narrow (≤2 files, clear spec, ≤5 tool calls) | **inline** |
| skill phase where skill declares `inline: true` | **inline · /skill-name** |
| research / investigation / challenging analysis | **agent/premium** |
| execution — moderate or broad (3+ files, iterative) | **agent/Sonnet** |
| reasoning phase | **agent/premium** |
| any phase that must run in parallel | **agent/*** |
| skill phase without `inline: true` | **agent/** at tier |

### Step 3 — Derive per phase

- `depends_on`: phase numbers that must complete first
- `acceptance_criteria`: 2–3 done-statements for execution/reasoning phases

---

## Plan Presentation

Read `## Shared Context` from `project.md` before planning — it contains durable decisions and constraints from prior tasks. Incorporate relevant context into the plan (phase design, executor choices, acceptance criteria).

**Mandatory final phase:** Every plan must include a final `Test & Verify` phase `[inline · execution]`, numbered as Phase N (= total phases). Its acceptance criteria: (1) all output files declared in prior phases exist on disk, (2) detected test suite passes or "no test runner detected", (3) for any background script or launchd job changed: dry-run against a controlled environment passes in both happy-path and failure/recovery scenarios (see Background Job Dry-Run), (4) when inbox ACs or summary name a project-local smoke script, run it (see Project-local smoke scripts). Omit only for tasks that produce zero file changes (pure queries, documentation with no outputs).

```
TASK PLAN — `<summary>`  Complexity: Lightweight|Moderate|Complex (N phases)
Phase 1: `<name>` [inline · simple] → `<output>`
Phase 2: `<name>` [inline · execution] → `<output>`
Phase 3: `<name>` [/skill-name · agent/Sonnet] [parallel with 4] → `<output>`
Phase 5: `<name>` [agent/premium] → `<output>`   ← research/investigation
Phase N: `Test & Verify` [inline · execution] → `verify.log`   ← always final
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

Update project.md registry row: `status: running`.

---

## Execution Loop

**Self-refresh at start of each turn:** re-read this skill file and the task file. Skip only if this is the first turn after Skill tool was just invoked.

**Ready phases** = all `depends_on` entries are `✓ complete` AND status is `pending`.

### Inline phase execution

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

**Phase log write (mandatory):** Append the full PHASE OUTPUT block to `.orchestrate/logs/{ID}-phase{N}.log`:
```bash
mkdir -p .orchestrate/logs
# Include retry counter when R > 0 so retries are visually distinct from the original run
LABEL="Phase N"
[ "${RETRIES:-0}" -gt 0 ] && LABEL="Phase N (retry ${RETRIES})"
echo "=== ${LABEL} — <name> $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> .orchestrate/logs/{ID}-phase{N}.log
echo "<full PHASE OUTPUT block>" >> .orchestrate/logs/{ID}-phase{N}.log
```

**State write is mandatory after every inline phase** — follow Steps A/B/C immediately. Never defer or batch.

**Inline skill invocation:** For `[inline · /skill-name]` phases, read the skill's SKILL.md, follow its instructions directly. Announce `▶ Phase N — <name> (inline)`.

### Agent phase execution

Announce `▶ Phase N — <name>`.

**Agent prompt must include:**
1. Prior phase summaries
2. Absolute working directory
3. `## Shared Context` from project.md (paste verbatim — gives agent project-level knowledge)
4. Acceptance criteria: "This phase is complete when: 1. … 2. … 3. …"
5. Required output: `## PHASE OUTPUT` block with files_changed / summary / confidence / blockers / acceptance_criteria_met / test_evidence
6. If skill embedded: paste SKILL.md body directly — do NOT invoke Skill tool from within agent

**Parallel phases:** launch as multiple Agent calls in one message (max 6). Wait for all before assessing.

**Foreground vs background:** default foreground. Use `run_in_background: true` only when > 5 min expected AND there is independent work to run concurrently.

After agent returns: extract `## PHASE OUTPUT`. If missing → treat as ⚠️ with gap "no PHASE OUTPUT block".

**Phase log write (mandatory):** Append the full PHASE OUTPUT block (or the raw agent return text if block is missing) to `.orchestrate/logs/{ID}-phase{N}.log` — same retry-aware format as inline phases above (`Phase N (retry R)` when R > 0).

### Critic & micro-verifier (always inline)

For execution and reasoning phases:
- **PASS** — all criteria met AND no `✗` in `acceptance_criteria_met` AND `test_evidence` shows behavioral confirmation (not just file existence)
- **PARTIAL: \<gap\>** — most criteria met but one unmet; OR one or more `✗` in `acceptance_criteria_met`; OR `test_evidence` is absent/weak for an execution phase
- **FAIL: \<reason\>** — key criterion not met or blocker caused by this change

**Rule:** any `✗` in `acceptance_criteria_met` disqualifies PASS — minimum PARTIAL.
**Rule:** for execution phases, `test_evidence: n/a` or missing = PARTIAL unless the phase made zero file changes.

If `files_changed` non-empty: run Bash verify (build, lint, fast tests). Override to PARTIAL if fails.

Classify blockers: `pre-existing` or `caused-by-change`. Pre-existing → note only, do not downgrade.

For **simple** and **instructional** phases: apply a lightweight confidence-only gate (no full criteria assessment). If `confidence: low`, downgrade to ⚠️ per the Step B verdict table; high or medium confidence → ✅.

### Background Job Dry-Run (mandatory when applicable)

**When required:** The Test & Verify phase MUST include a dry-run for any task that creates or modifies:
- Shell scripts in `.orchestrate/bin/` (rescue.sh, run-job.sh, drain-inbox.sh, etc.)
- LaunchD plist files (`*.plist`)
- Any script that runs unattended or is invoked by launchd

**What a dry-run is:** run the script against a `mktemp -d` controlled temp directory with the minimum required state (mock project.md, stale heartbeat, seed inbox file, etc.) — not against the live project directory.

**Minimum scenarios (cover at least 2):**
- **Happy path:** correct inputs → expected output (correct log entries, correct file moves)
- **Failure/recovery:** stuck/error state → script detects and recovers (e.g. stale lock cleared, inbox drained, run-job kicked)

**LaunchD changes:** additionally run `launchctl list <label>` and assert `LastExitStatus = 0`.

**test_evidence format for background jobs:**
```
test_evidence: dry-run 3/3 scenarios pass; launchctl list com.orchestrate.rescue: LastExitStatus=0; make test ALL SUITES PASSED
```

If a script has no controllable inputs (reads only live system state), document why dry-run is not feasible and use `launchctl list` + log inspection instead.

### Project-local smoke scripts (Test & Verify)

When an inbox task's **Goal**, **Acceptance Criteria**, or registry **summary** names a project-relative script (e.g. `examples/langgraph/smoke_pattern1_drop.py`), the Test & Verify phase MUST run that script from the project root — do not substitute file-existence or read-only checks.

**Detection:** task summary, inbox AC bullets, or phase acceptance criteria mention a path ending in `.py`/`.sh`, or an explicit `python3`/`bash` command.

**Execution:** run from project CWD; record exit code and tail output in `test_evidence` and `.orchestrate/logs/{ID}-verify.log`.

**Examples:**
- Summary "Pattern1 Smoke Test" → `python3 examples/langgraph/smoke_pattern1_drop.py`
- AC "run `bash scripts/foo.sh`" → execute exactly that path relative to project root

**Side effects:** smoke scripts that write to `.orchestrate/inbox/` may enqueue a follow-up tend cycle — note created paths in the verify log.

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

- **❌** → write `✗ failed`. Update project.md: `status: needs_human`.
  - **Gated / interactive auto:** Gate: `⏸ retry · skip · replan · abort · instruct`
  - **Tend-auto (invoked from `tend go auto`):** Do NOT gate. Log the block and move on:
    `[<ISO>] tend-auto — task <ID> blocked (needs_human); continuing queue`
    Exit the current task's execution loop. If running as a parallel batch subagent, return `## TASK RESULT` with `status: needs_human`. If running inline T-4, proceed to the next `pending` task or next batch.

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
  7. ❌ →
       Gated/interactive: checkpoint all ✅ in batch, halt and gate user
       Tend-auto: checkpoint all ✅, mark task needs_human, log block, exit loop
                  (T-4 continues to next pending task)
```

Never stop between steps 5 and 1 in auto mode.

**Parallel batch mixed results:** checkpoint ✅ immediately; re-invoke ⚠️; on any ❌:
- **Gated/interactive:** halt and gate.
- **Tend-auto:** mark failed task `needs_human`, log, do not block the parallel batch — remaining parallel tasks that complete ✅ are checkpointed normally, then T-4 continues queue drain.

---

## Completion

When all phases are `✓ complete`:

**Timestamp contract (mandatory — History tab depends on this):**

Capture **once** at the start of Completion — never invent or round timestamps (forbidden: `T22:00:00Z`, `T12:00:00Z` unless that is the actual wall time):

```bash
COMPLETED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ARCHIVE_STAMP="$(date -u +%Y%m%d-%H%M%S)"
```

Use the **same** `COMPLETED_AT` for:
- registry `last_activity` (exact ISO, not the word `now`)
- heartbeat lines: `[${COMPLETED_AT}] tend-auto — completed …`
- verify log header: `=== Verification run ${COMPLETED_AT} ===`

Use the **same** `ARCHIVE_STAMP` for the archive filename prefix: `orchestrate-history/${ARCHIVE_STAMP}-${ID}-${slug}.md`

Use `date -u +%Y-%m-%d` (from `COMPLETED_AT`) for the MANIFEST date column.

On each phase checkpoint (Step C ✅), also set registry `last_activity` to `$(date -u +%Y-%m-%dT%H:%M:%SZ)` so partial progress is accurate.

**1. Archive task file:**
- Ensure the `orchestrate-history/` directory exists (at your central history location).
- Copy `.orchestrate/tasks/{ID}.md` → `orchestrate-history/${ARCHIVE_STAMP}-${ID}-<slug>.md` (use `ARCHIVE_STAMP` from timestamp contract above — not a separate guessed time)
- Add `tags:` line to archive copy.
- **Mandatory:** Append one line to `orchestrate-history/MANIFEST.md` using exact format `YYYY-MM-DD | filename | summary | tag1, tag2`. Skipping MANIFEST breaks History tab tags/search; the monitor also scans on-disk archives as a safety net, but MANIFEST is the canonical index — never omit it.
- Delete original task file from `.orchestrate/tasks/`.
- **Self-check before marking complete:** archive file exists on disk AND matching MANIFEST line was appended (grep `filename` in MANIFEST.md).
- **No duplicate registry rows** for the same inbox execution — if a job is re-registered under a new ID, remove or alias the stale row; use `HISTORY_REGISTRY_ALIASES` in monitor when IDs must coexist temporarily.
- **Cross-project task summaries** (and archive MANIFEST lines) must include the project slug (e.g. `sy-promotion`) so History search finds them.

**2. Update project.md registry:** set `status: complete`, `last_activity: <COMPLETED_AT>` (the exact ISO from timestamp contract — never a rounded placeholder).

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

# Background job behavioral verification (when applicable)
# For any modified script in .orchestrate/bin/ or launchd plist: dry-run + launchctl check
for f in <files_changed from all phases>; do
  case "$f" in
    */.orchestrate/bin/*.sh)
      # Dry-run: run against a temp dir and assert clean exit
      TMP_DRY="$(mktemp -d)"
      if bash "$f" "$TMP_DRY" >/dev/null 2>&1; then
        echo "✓ dry-run $f (temp env)" >> "$VERIFY_LOG"
      else
        echo "⚠ dry-run $f exited non-zero (check if it requires specific env)" >> "$VERIFY_LOG"
      fi
      rm -rf "$TMP_DRY"
      ;;
    */LaunchAgents/com.orchestrate.*.plist|*.plist)
      LABEL="$(grep -A1 '<key>Label</key>' "$f" 2>/dev/null | tail -1 | sed 's/<[^>]*>//g;s/[[:space:]]//g' || true)"
      if [ -n "$LABEL" ]; then
        STATUS="$(launchctl list "$LABEL" 2>/dev/null | grep 'LastExitStatus' | tr -d '[:space:]"' || echo 'not loaded')"
        echo "launchctl $LABEL: $STATUS" >> "$VERIFY_LOG"
      fi
      ;;
  esac
done

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
Follow-up: enqueued → inbox/<filename> | none
──────────────────────────────────────────────────
```

**If gap detected** — enqueue a follow-up inbox file automatically:

**Dedup before writing** — skip if ANY of:
- An existing file anywhere in `inbox/`, `inbox/gated/`, or `inbox/processed/` has a `parent_task: <this-task-ID>` line
- An existing file title has ≥70% word overlap with the proposed follow-up title

**Path:** `.orchestrate/inbox/followup-<slug>-<YYYYMMDDTHHMMSS>.md` (auto mode, inherits parent runner)

**Template:**
```markdown
parent_task: <parent-task-ID>

# Follow-up: <original task summary> — <gap in 3-5 words>

## Goal
<What remains to be done. Be specific — name files, endpoints, or behaviors that are still undelivered.>

## Context
Follow-up to task `<parent-ID>` — `<original task summary>`.
Delivered: <what the parent task completed>
Gap: <what was left undelivered or only partially done>

## Acceptance Criteria
- <unmet AC from parent, verbatim or refined>
- <additional AC if the gap introduces new requirements>
```

Append to heartbeat.log: `[<ISO>] follow-up — enqueued followup-<slug> from task <ID>`

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

For each qualifying suggestion, write an inbox file instead of any external backlog:

**Dedup before writing** — skip if ANY of:
- An existing file in `inbox/`, `inbox/gated/`, or `inbox/processed/` has ≥70% word overlap with the normalized suggestion title (lowercase, strip punctuation, compare token sets)
- An existing file has the same `triggered_by: <this task ID>` value

**Path:** `.orchestrate/inbox/improvement-<slug>-<YYYYMMDDTHHMMSS>.md`

**Template:**
```markdown
mode: auto
source: self
triggered_by: <task ID>

# <improvement title>

## Goal
<specific change — name the file, section, behavior>

## Context
Triggered by task `<ID>` — <task summary>.
Observation: <what was seen — retry count, gap text, repeated partial verdict>
Applies to: <path in your skill source>  ·  Installed at: ~/.claude/skills/<name>/SKILL.md

## Acceptance Criteria
- SKILL.md section "<X>" updated as described
- skill source updated; installed copy reflects the change
- make test passes (or "no test runner detected")
```

**Categories** (set `Applies to:` accordingly):
- Orchestrator → `skill/SKILL.md`
- Invoked skill → `<skill>/SKILL.md`
- Project → project-specific paths (tests, `.orchestrate/`, docs)

Append to heartbeat.log:
- Filed: `[<ISO>] self-improve — filed improvement-<slug> from task <ID>`
- Dedup skipped: `[<ISO>] self-improve — skipped (dedup) improvement-<slug> from task <ID>`
- None: `[<ISO>] self-improve — none from task <ID> (reason: <one line>)`

Do **not** append to `skill-improvement-backlog.md` — inbox is the canonical improvement queue.

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

## Heartbeat Setup

The tend watchdog runs on an OS-level schedule so it can't be forgotten. Install once per machine (not per project):

```bash
PROJECT_DIR="$HOME/apps/my-project"   # adjust to your project root
bash skills/task-orchestrate/bin/install-launchd.sh
```

This installs `com.orchestrate.tend` and `com.orchestrate.inbox-analyzer`, copies `.orchestrate/bin/run-job.sh`, and creates `.orchestrate/agent.conf` if missing.

**Switch runner (cursor ↔ claude):** use the monitor LaunchD tab (flip buttons) or CLI — no launchctl reload needed:

```bash
bash .orchestrate/bin/set-runner.sh claude   # or cursor
```

Or POST `{"runner":"claude"}` to `/api/agent-conf` on the monitor (`http://127.0.0.1:7842`).

**Cursor IDE dependency:** When `RUNNER=cursor`, `cursor-agent` requires **Cursor IDE running** (`pgrep -xq Cursor`). Set in `.orchestrate/agent.conf`:

```bash
RUNNER=cursor
CURSOR_FALLBACK=auto    # default — IDE closed → fall back to claude
# CURSOR_FALLBACK=never # IDE closed → defer tend (heartbeat note, exit 0)
# CURSOR_AUTO_OPEN=true # optional: `open -a Cursor` once before IDE check
```

`run-job.sh` still falls back to the alternate runner on session limit / connection errors when `CURSOR_FALLBACK=auto`.

Requires skills available at `$PROJECT_DIR/.cursor/skills/` when using `RUNNER=cursor`.

To run tend manually at any time: type `tend` in any session.
To unload: `launchctl unload ~/Library/LaunchAgents/com.orchestrate.tend.plist`

**Note:** The heartbeat runs from `WorkingDirectory` (your project root). Tend reads `.orchestrate/` relative to that directory. For a project-specific tend, `cd` into the project and type `tend` manually.

---

## Quick Reference

```bash
# New task
/task-orchestrate "refactor auth in the web frontend to use JWT"

# Resume
/task-orchestrate resume

# Run watchdog manually
/task-orchestrate tend

# Drop a task into the inbox — use structured format for best results
cat > .orchestrate/inbox/rate-limit.md << 'EOF'
# Add rate limiting to all API endpoints

## Goal
Add per-IP rate limiting (100 req/min) to every route in src/routes/. Return 429 with Retry-After header on breach.

## Context
No rate limiting exists today. The express app entry point is src/app.ts. We use express-rate-limit in a sibling service already — same pattern applies here.

## Acceptance Criteria
- All routes return 429 after 100 req/min per IP
- Retry-After header set correctly
- Unit tests cover the limit boundary
EOF

# Check project status
cat .orchestrate/project.md

# See all active tasks
ls .orchestrate/tasks/

# Activity log
tail -f .orchestrate/logs/heartbeat.log
```
