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

**Cancelled vs failed:** The registry enum has no `cancelled` value (NF==8 DOMAIN unchanged). A dashboard **Cancel** on a gated (`awaiting_go`) task sets registry status **`failed`** but also stamps durable **`cancelled_at:`** + **`cancel_reason:`** markers into `.orchestrate/tasks/{ID}.md` (mirrors the `bypassed_at:` pattern). The monitor classifies `failed`+`cancelled_at:` as **"Cancelled"** (grey badge, terminal, non-actionable) — distinct from a genuine **`failed`** row (no marker → "Failed — review required"). `bin/tend-need-action.sh` excludes all `failed` rows from `NEED_ACTION`, including cancelled ones — they are never re-surfaced or re-queued.

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

# Actionable registry work? (table rows only — not Shared Context prose)
# NOTE: awaiting_go (gated) is EXCLUDED on purpose — it is notify-only, never
# auto-executes, and its one human notice already fired in bash at registration
# (drain-inbox.sh notify_gated_once). Waking the agent for a gated-only registry
# would spend tokens with nothing to do. This matches the authoritative bash gate
# in tend-need-action.sh (registry_actionable = pending + awaiting_critic +
# actionable needs_human).
grep -qE '^\|[^|]+\|[^|]+\|[^|]+\| (awaiting_critic) \|' "$PROJ" 2>/dev/null && NEED_ACTION=1

# Inbox has non-deferred AUTO items? Only root inbox/*.md count — gated/*.md drain
# to notify-only awaiting_go rows (handled once in bash), so they do NOT raise action.
for f in .orchestrate/inbox/*.md; do
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
- **Gating is risk-based, not location-based.** A file is registered `mode: gated`, status `awaiting_go` **only when its content meets the Gating Criteria below (a genuine risky op) OR it carries an explicit `gate_reason:` line** (the human override). A bare `mode: gated` marker or placement under `.orchestrate/inbox/gated/` is a *hint*, not a hard gate: if the task involves no risky op and has no `gate_reason:`, **de-gate** it — register `mode: auto`, status `pending` — and log the de-gate. Do **not** gate a task just because it is safe but happened to be filed under `gated/` (e.g. inbox-log-analyzer enhancement findings). Genuinely-gated tasks under **`tend`** or **`tend go auto`**: register in T-2 — `drain-inbox.sh` emits the single "needs your go" notice in bash at drain (once per ID, idempotent via the `gated-notified.tsv` sidecar) — never auto-execute. The AI does **not** re-notify them on subsequent cycles (see T-4 `awaiting_go`).

**Inbox layout:**
| Path | Gating decision | `tend` | `tend go auto` (launchd) |
|------|-----------------|--------|-------------------------|
| `.orchestrate/inbox/*.md` | auto unless risky-op or `gate_reason:` | drain → notify | drain → execute |
| `.orchestrate/inbox/gated/*.md` | gated only if risky-op or `gate_reason:`; else **de-gated to auto** | drain → notify once (bash) | de-gated → execute · genuinely-gated → notify once at drain (bash); never auto-exec, never re-notified |

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

**`awaiting_go` (mode: gated):** **SKIP entirely — do NOT read the task file, do NOT send a PushNotification, do NOT write a per-cycle log line.** The one-time "gated — needs your go" human notice is owned by **bash at registration** (`drain-inbox.sh` `notify_gated_once` fires once per ID via `osascript` and stamps the `.orchestrate/logs/gated-notified.tsv` sidecar). Re-notifying here on every dispatched cycle was a pure token + notification-spam leak (R-1, `.orchestrate/notes/r-1_gated_token_paths.md`) — it is removed. The registry-row summary is all you read; never open `.orchestrate/tasks/{ID}.md` for an `awaiting_go` row during the per-cycle scan. Gated tasks still never auto-execute regardless of tend mode — they require an explicit human `go <ID>` or `go auto <ID>` (delivered via the dashboard or an interactive session), which is unchanged.
  - *Fallback (host without `osascript`):* `drain-inbox.sh` still records the sidecar marker but emits no desktop notice; in that case only — and only for a row missing from the sidecar — send a single `PushNotification`, then rely on the marker so it is never re-sent.

**`pending` tasks (from inbox drain this cycle OR already registered):**
- **Mode `tend`:** Send `PushNotification`: `📋 [{N} new task(s) queued — type "go" or "go auto" to start]`. Log.
- **Mode `tend go auto`:** Execute pending tasks in **parallel batches of up to 3**. `awaiting_go` tasks are never auto-executed — skip during batch collection.

  **Parallel batch execution protocol:**
  1. Collect ALL `pending` task IDs from the registry (not just drained this cycle), **plus** any `running` row that has neither a `.orchestrate/tasks/{ID}.md` file nor a `tend-auto — dispatching "..." ({ID})` heartbeat line. Those rows were bash-pre-marked `running` by `run-job.sh`'s `mark_pending_tasks_as_running()` (RS01) moments before this session was dispatched — on a fresh T-4 scan they are unclaimed work, not a sibling's in-progress task (the tend lock guarantees no live sibling exists). Skip `awaiting_go`, `needs_human`, `complete`, `failed`, and any `running` row that DOES have a task file or dispatch line (genuinely in progress — the batch that owns it will finish it). **Defense-in-depth (20260725-inbox-4C3D): also skip any row whose `mode` column is `gated`, even if its `status` reads `pending`.** A `pending`+`gated` row should never exist — `requeue-orphaned-running.sh`'s stale-orphan reset now respects `mode` and sends gated rows to `awaiting_go`, not `pending` — but if one is ever found anyway (hand-edit, other bug), do not fold it into the auto-execution batch; leave it for a human `go`/`go auto <ID>`. **Cross-task `depends_on:` (CROSS-2, 20260727-inbox-7D4A):** a task file's `depends_on:` may hold ANOTHER TASK's real registry ID (from `drain-inbox.sh`'s `resolve_depends_on()`, CROSS-1 — set from a `blocked_by_ticket:` header or `**Blocked by:**` prose) rather than a same-file phase number. `mark_pending_tasks_as_running()` already enforces this in bash — before flipping a `pending` row to `running`, it checks whether the task file's `depends_on:` matches the registry-ID shape (`YYYYMMDD-inbox-XXXX`) and, if so, looks up that other row's `status`; a row referencing a not-yet-`complete` task is left `pending` and a skip is logged (naming the blocker and, if it's `gated`/`awaiting_go`, saying so explicitly) instead of being dispatched. Since this bash gate runs before T-4 even sees the registry, a row this session's T-4 scan finds `pending` has already cleared this check — no separate LLM-side re-check is required, but never hand-dispatch a task around this gate (e.g. via `go auto <ID>`) without first confirming its `depends_on:` target is `complete`.
  2. Take the first batch of up to 3 IDs.
  3. For each task in the batch: mark as `running` in project.md (sequential, before dispatch) by calling `.orchestrate/bin/update-registry-row.sh <ROOT> <ID> <mode> <current_phase> running <now-ISO>` to refresh `last_activity` at the moment of claim, create `.orchestrate/tasks/{ID}.md` plan file if missing. If the source inbox file carries `followup_for:`/`kind:` header lines, copy them verbatim as literal top-level lines at the very top of the constructed task file (not just into Context prose) — downstream anti-recursion checks in `enqueue-review-and-tests.sh`/`enqueue-wiki-sync.sh` grep the task file, not the original inbox file, for these headers. Append to heartbeat.log: `[<ISO>] tend-auto — dispatching "<task title>" ({ID}) [batch N] [session=<SHELL_PROBE_TOKEN>]` — the literal token value from this session's own shell-capability preflight directive (see `shell_probe_directive()` in `run-job.sh`), or `[session=no-token]` if this session was never given one (e.g. an interactively-invoked session, not dispatched via `run-job.sh`). Session/PID attribution (20260725-inbox-6B7E): this ties the line to the specific top-level session that wrote it, distinguishing it from a sibling top-level session, an Agent-tool subagent it spawned, or an out-of-band session — see `heartbeat.log`'s `[pid=$$]` suffix (added to every `run-job.sh`-written line by `log_heartbeat()`) for the complementary wrapper-process-level signal.
  4. Launch the batch as **parallel Agent calls** (max 3 simultaneous). Each agent prompt must include:
     - Full task file content (`.orchestrate/tasks/{ID}.md`)
     - SKILL.md Execution Loop instructions (paste relevant sections)
     - Absolute working directory
     - `## Shared Context` from project.md (verbatim)
     - Instruction: "Run the full auto execution loop for this task. When all phases are done, end your response with a `## TASK RESULT` block: `status: complete|needs_human|failed`, `summary: <one line>`, `phases_done: N`."
     - Instruction: "Do NOT update project.md — the parent session handles registry writes."
     - Instruction: "Write a top-level `files_changed: <paths>` line into the task file itself (or `files_changed: none` if nothing changed) — `enqueue-review-and-tests.sh` greps the task file for `^files_changed:` to classify the change; leaving it only inside phase-block prose risks the 6b review/tests follow-up being silently skipped."
  5. After **all agents in the batch return**: for each agent result — read `## TASK RESULT`, update project.md row (`running` → final status), run Completion sequence (archive, MANIFEST) for any `complete` tasks. Log each outcome.
  6. **Blocked tasks never block the batch:** if an agent returns `needs_human` or `failed`, checkpoint its result immediately and continue — do not wait or retry within this batch. Log: `[<ISO>] tend-auto — task <ID> blocked (needs_human); continuing queue`.
  7. If more `pending` tasks remain after the batch, repeat from step 2 with the next batch.

  **Mode `tend go auto <ID>`:** Execute ONLY task `<ID>`. Skip T-1/T-2 (run-job.sh already did cleanup/drain). Skip T-4 general scan. Find `.orchestrate/tasks/{ID}.md`, run the full auto execution loop — the loop's own **Pre-execution duplicate-completion guard** (see Execution Loop below) fires before phase work begins, same as every other entry path — update project.md row on completion. Used when run-job.sh pre-assigns tasks to parallel agent sessions.

**`needs_human` tasks:**
- Read task file at `.orchestrate/tasks/{ID}.md`. If the file is missing:
  - **Ghost-reset auto-job re-queue:** if the registry row is `mode: auto` AND `.orchestrate/logs/heartbeat.log` contains a `ghost-reset {ID}: running→needs_human` line (the job was stalled and reset by `run-job.sh`, never wrote a task file), set the registry row to `status: pending`, append `[<ISO>] tend-auto — re-queued ghost-reset auto job {ID} (no task file, stalled run)` to heartbeat.log, and let the next pending scan execute it. These are stalled automatable jobs (idempotent daily runs like wiki-ingest / inbox-log-analyzer), not genuine human blockers. **Churn guard:** before re-queueing, the bash requeue sites bump a shared counter (`bin/churn-guard.sh` `cg_increment`); a job re-processed `CG_THRESHOLD` (default 3) times without converging is **parked** instead of re-queued — see **Churn guard** below.
  - Otherwise (no ghost-reset line, or `mode: gated`), skip. Genuine human-blocked tasks have task files with `human_resolution: BLOCKED ON HUMAN` and no ghost-reset line — they never match the re-queue rule.
  - **Verify on-disk state before redoing work (ghost-reset re-execution):** when picking up a re-queued task that carries `requeue_count >= 1` (task file or sidecar) and shows zero prior phase output, do a quick on-disk check for that phase's declared outputs/edits (`grep`/`diff` the target file(s)) before repeating the work — a connection-lost or session-death event can occur AFTER a phase's substantive edit but BEFORE its checkpoint write, so `status: pending` phases can be misleading. If the check confirms the change is already in place, checkpoint the phase as complete on that evidence rather than blindly reapplying it (task `20260718-inbox-A893` found its SKILL.md edit already applied byte-identical across all mirrors after exactly this kind of ghost-reset).
- Count phase sections (`### Phase N`). If **every** phase has `status: ✓ complete`, run the normal **Completion** sequence inline: update registry row to `complete`, archive task file to `orchestrate-history/`, append MANIFEST entry, delete task file from `.orchestrate/tasks/`.
- Append to heartbeat.log: `[<ISO>] tend — auto-resolved needs_human "<task title>" ({ID}) — all phases complete`
- If any phase is incomplete or missing `✓ complete`: run the **Second-Pass Auto-Resolution Check** before leaving the task blocked.

**First-Pass Auto-Resolution Check (MANDATORY before writing `needs_human`):**

Writing `status: needs_human` without first running this check is a **protocol violation**. Before setting registry `status: needs_human` during execution (Step C ❌ branch), you MUST:

1. Run `.orchestrate/bin/first-pass-auto-resolve.sh <ROOT> <ID>`. If exit 0, inject `human_resolution: Auto-resolved (first-pass) — <reason>`, set registry to `pending`, log `[<ISO>] tend-auto — first-pass self-unblocked <ID>: <reason>`, and retry — do **not** write `needs_human`.
2. If exit 1, apply the **Human-Only Block Classifier** below. The task may be left `needs_human` ONLY if it passes the classifier (a genuine external dependency). Record the self-resolution attempt and its result in the task file before parking.

Trivial categories (enumerated): **C1** creatable missing dir under project root · **C2** deferred/out-of-scope AC language · **C3** one-shot retryable transient (EPIPE/ETIMEDOUT/429) · **C4** referenced report closure (`**Status:** ✅`, `**Closed:**`) · **C5** downstream referenced task `complete` in registry · **C6** locally-executable action mislabeled as a block (cross-project file write, reversible settings/config write, a script the agent can run) — these are NOT human blockers; attempt the action instead.

**Hard guard (skip first-pass):** `blocked_on: EXTERNAL`, `escalation_note:` + `blocked_on:`, or task `mode: gated`.

**Human-Only Block Classifier (MANDATORY gate on both branches):**

A task may only be left `needs_human` when its file states a **concrete external dependency the agent cannot satisfy itself**. Valid human-only blockers (any one):
- A live cluster / infra op the agent cannot run (e.g. `kubectl apply/exec`, load-ramp — kube hook blocks it, no kubectl in env).
- An external service that must recover (e.g. Redis HA no-master, third-party API outage) — outside the agent's control.
- A missing human decision, credential, or approval the agent has no way to obtain.

**NOT valid blockers — attempt them, never gate on them:**
- A **cross-project file write** or any **local file write** (the agent can write to any path under `~/apps/`).
- A **reversible settings/config write** (e.g. `settings.json`, `.orchestrate/agent.conf`, any local config that can be edited and reverted).
- **A script the agent can just run** locally (it being "cross-project" or "looks risky" is not a block — run it).
- "I didn't try", "looked risky", "cross-project write", "config write" — none of these are concrete external dependencies. Attempt the action first.

**Transient tool-level rejection (retry before trusting a prior park):** a genuine Write/Shell **Rejected** event on a cross-project or local path (the tool call itself was refused, not the agent second-guessing) is real for *that* session, so parking `needs_human` at the time was correct — but the rejection can be **session-scoped, not a durable project ACL**. Tasks `20260724-inbox-7496`/`089C` both parked on an actual Rejected Write/Shell call to `~/apps/another-project`; a later tend session's identical Write call succeeded with no settings change in between. When picking up a task parked for this reason, the first move should be to **retry the exact same Write/Shell call once** before re-deriving `needs`/`why`/`to_clear` from the task file — it may have silently cleared.

**Structured human ask (genuine blockers):** to land `needs_human`, the task file MUST carry `needs:`, `why:`, `to_clear:` (or `## needs` / `## why` / `## to_clear` sections) naming the concrete external dependency from the valid list above. Free-text `BLOCKED ON HUMAN`, "cross-project write", or "config write" alone fails the clear-human-ask criterion — the agent must attempt self-resolution instead.

**Auto-finalize done-but-running rows (Completion is not atomic):** the running-row Completion path. A tend/agent session can write every phase block in `.orchestrate/tasks/{ID}.md` to `status: ✓ complete` (and may even archive the task file) but die BEFORE flipping the registry row `running → complete`. T-4 re-queues only `needs_human` rows, so the done-but-running row would otherwise sit `running` forever. `.orchestrate/bin/finalize-completed-tasks.sh` runs the bash analog of the Completion sequence to reap them: for each `running`/`needs_human` row it finalizes to `complete` when EITHER (1) the task file exists and the count of `status: ✓ complete` phase blocks equals `total_phases:` (conservative — never finalize partial work), OR (2) an archive for the ID already exists in `orchestrate-history/`. On finalize it flips the row to `complete` IN PLACE (preserving the NF==8 invariant), archives to `orchestrate-history/{STAMP}-{ID}-{slug}.md` + a MANIFEST line if not already archived (no dup), deletes the stale task file, and logs an `auto-finalize — completed {ID}` heartbeat line. Idempotent (a second run is a clean no-op). It runs from **`run-job.sh` preflight** AFTER `repair_registry_rows` and BEFORE `reset_stale_running_tasks` (so a finished-but-running ghost is completed, not bounced to `needs_human`), and from **`rescue.sh`** as a safety net (before its stale-running reset). Regression: `.orchestrate/tests/test-finalize-completed-tasks.sh`.

**Auto-requeue on unblock:** `run-job.sh` preflight runs `.orchestrate/bin/requeue-unblocked.sh` after `reset_stale_running_tasks`. Requeues when `requeue_when_exists:` path has closure markers, `to_clear` decision file is filled, or `human_resolution:` is injected without `BLOCKED ON HUMAN`.

**Second-Pass Auto-Resolution Check (MANDATORY — T-4 `needs_human` branch):**

Before writing `needs_human` and skipping a task with incomplete phases, you MUST attempt self-resolution and prove the block is genuinely human-only. Skipping this check is a protocol violation. First run `.orchestrate/bin/first-pass-auto-resolve.sh <ROOT> <ID>` (it also catches **C6** locally-executable mislabeled blocks — cross-project file writes, reversible config writes, runnable scripts); if exit 0, self-unblock per the First-Pass rule. Then check these signals for automatic resolution. Read the task file's blocking phase blocks and project context:

1. **Deferral language in phase ACs:** Scan the failed/incomplete phase's `acceptance_criteria_met:` block and blockers field for markers: "deferred", "deferred to", "deferred — <team>", "not a blocker", "closed", "no action needed", "Forbidden", "out of scope". If **all** incomplete ACs contain explicit deferral or closure language → auto-resolvable.

2. **Report file closure:** If the task file or any phase block references a file path (e.g. `reports/phase3/hrbaca_capacity_report.md`), read that file. If it contains a `**Closed:**`, `**Status:** ✅`, or `**dsp-service GO/NO-GO verdict:**` section → auto-resolvable.

3. **Downstream task completion:** Scan project.md registry for any task whose summary or ID is referenced in this task's file (e.g. "superseded by", "closes with", "see also `<ID>`"). If the referenced task is `complete` → auto-resolvable.

**If ANY signal confirms auto-resolution:**
- Inject into the blocking phase block in the task file: `human_resolution: Auto-resolved — all ACs satisfied or explicitly deferred per <evidence summary>. No human action required.`
- Update project.md registry row: `status: pending`
- Append to heartbeat.log: `[<ISO>] tend-auto — self-unblocked <ID>: <one-line reason>`
- The task will be re-executed on the next T-4 pending scan or next tend cycle.

**If none of the signals confirm:** apply the **Human-Only Block Classifier** (above) before parking. The task may be left `needs_human` ONLY if the block is a concrete external dependency (live cluster/infra op, external service recovery, missing human decision/credential) recorded in structured `needs:`/`why:`/`to_clear:` form. A locally-executable action — cross-project file write, reversible settings/config write, a runnable script — is NOT a valid block: attempt it and set the row back to `pending`. Only when the classifier confirms a genuine human-only block: **park it — do not re-evaluate every cycle:** write `bypassed_at: <ISO>` and `bypass_reason: <one-line why it cannot move on>` into the task file (header or blocking phase block), and leave the registry row at `needs_human`. See **Bypass — park blocked tasks** below.

**`running` tasks with no task file — claim, don't wait:** a `running` row with (no `.orchestrate/tasks/{ID}.md` file) AND (no `tend-auto — dispatching "..." ({ID})` line anywhere in heartbeat.log for that ID), found during THIS session's own T-4 scan, is this session's own unclaimed work, not an orphan to wait out. `run-job.sh`'s `mark_pending_tasks_as_running()` (RS01) always flips pending→running immediately before dispatching the very agent session meant to execute it, and the tend lock guarantees no other live session could be the true owner — so there is no "sibling dispatch" to race. **Do not apply a staleness gate here and do not treat it as "someone else's job, leave it untouched."** Fold it directly into the pending-task batch collection (step 1 above) and dispatch it now, same as any `pending` row — at the moment of claiming, also call `.orchestrate/bin/update-registry-row.sh <ROOT> <ID> <mode> <current_phase> running <now-ISO>` to refresh `last_activity` (matching step 3's pending→running refresh), in addition to the `tend-auto — dispatching "<title>" ({ID})` heartbeat line — once dispatched/executing inline, the Execution Loop's **Pre-execution duplicate-completion guard** (below) still runs before phase work begins, so a row that turns out to already be archived (e.g. completed by whatever wrote it before this session's claim) is caught and reconciled rather than re-executed.
- **Root-cause incident:** three consecutive tasks (`20260714-inbox-3563`, `20260714-inbox-2F9F`, `20260719-inbox-7887`) churned to a 3x park purely because 3 consecutive dispatched agent sessions each independently reasoned "`last_activity` is under a minute old, must be a sibling pre-assigned dispatch session — leave it untouched," then concluded idle. There never was a sibling; every one of those sessions WAS the intended owner and simply declined to claim its own row. Waiting fixed nothing — the next cycle's bash preflight (`requeue-orphaned-running.sh` reset → `mark_pending_tasks_as_running()` re-mark) always re-stamped the row `running` with a fresh timestamp microseconds before the next agent started, so it never once appeared "stale enough" to any live session. The task itself was never poisoned or blocked; it was simply never dispatched.
- A `running` row that already has a task file or a matching dispatch heartbeat line IS genuinely in progress — skip it; let the batch that owns it finish.
- **Residual lock-bypass race (accepted, narrow):** this claim-now rule has a small TOCTOU window between a session reading a `running`/no-file/no-heartbeat row during its T-4 scan and that same session writing its own task-file/heartbeat claim signal — if the tend lock were ever bypassed or two sessions raced past it, both could observe the row as unclaimed and both claim it, since there is no atomic claim-then-verify step, only the "write the claim signal immediately" convention. This is accepted as a pre-existing, narrow risk: it requires an actual tend-lock bypass to manifest, which is already a broken precondition the whole tend system assumes doesn't happen, and the prior staleness-wait behavior offered no real protection against a true lock-bypass race either — it only delayed action while leaving the same double-claim window open. If this is ever observed in practice, the fix would be an atomic per-ID claim lock (e.g. `mkdir .orchestrate/locks/{ID}.claim` as an exclusivity check before dispatch) rather than reintroducing the staleness gate this rule was designed to remove.

**Bash backstop (3C1D) — safety net only, not the primary path:** `.orchestrate/bin/requeue-orphaned-running.sh` (300s staleness gate, reset `running`→`pending`) still runs in `run-job.sh`'s tend preflight and in `rescue.sh`, and still matters for the one case a live agent session cannot see: no agent session ran at all this cycle (the dispatched CLI crashed or never started before reading the registry). A bash-only pass has no way to know whether a live session is about to claim the row, so it is right to wait before resetting it. A live agent mid-T-4-scan has no such uncertainty — per the rule above, it claims a no-file/no-dispatch-line `running` row immediately rather than mirroring this same 300s wait. Do not reintroduce a staleness check into the LLM path — that is precisely the RS01 dispatch-starvation bug (see incident above), not a safety improvement.

**All other statuses** (`complete`, `failed`): skip.

**Bypass — park blocked tasks (do not re-process every cycle):**

Any task the orchestrator has evaluated and confirmed cannot progress — a genuine human blocker, `blocked_on: EXTERNAL`, an unmet dependency, or a non-retryable failure — is **parked** with a durable marker so the tend cycle stops churning on it. This generalizes the human-only `human_resolution: BLOCKED ON HUMAN` bypass to **all** block types.

- **Write on block:** the Second-Pass fall-through above writes `bypassed_at: <ISO>` + `bypass_reason: <one line>` into the task file. Park only *after* first-pass and second-pass auto-resolution have both failed — never park a locally-resolvable "block" (cross-project file write, reversible config write, a script the agent can run); attempt those instead.
- **Skip while parked:** `bin/tend-need-action.sh` treats any `needs_human`/`failed` row whose task file carries `bypassed_at:` as **non-actionable** — it does not raise `NEED_ACTION`, so the launchd cycle never wakes the agent for it. Completion-eligible rows (all phases `✓ complete`) and ghost-reset re-queues remain actionable.
- **Clear on unblock:** the only exit from a parked state is an explicit unblock signal, which **removes** `bypassed_at:`/`bypass_reason:` and sets the row to `pending`:
  - `unblock-task` (human injects a resolution)
  - `bin/requeue-unblocked.sh` (`requeue_when_exists:` closure, `to_clear:` decision filled, or non-`BLOCKED ON HUMAN` `human_resolution:` injected)
  - a human edits the task file (file mtime newer than `bypassed_at:`) — re-evaluate once
  - a depended-on task reaches `complete`

**Churn guard — block tasks re-processed 3× (poison-task safety net):**

A task can otherwise loop forever: `running → needs_human/ghost-reset → pending → running …` with nothing detecting that the **same** task keeps cycling back into the queue. `bin/churn-guard.sh` is the single shared owner of a re-queue counter, sourced by every requeue/re-dispatch site (`run-job.sh` `reset_stale_running_tasks`, `bin/requeue-unblocked.sh` `set_pending`, `rescue.sh` stale-running reset) so the logic and storage exist once.

- **Counter (two layers, `max()` wins):** a `requeue_count: N` line in `.orchestrate/tasks/{ID}.md` when the file exists, PLUS a sidecar `.orchestrate/logs/requeue-counts.tsv` keyed by `{ID}` — the sidecar is the only home for ghost-reset auto jobs that have **no task file**. Every requeue/re-dispatch calls `cg_increment {ID}`; the counter resets to 0 only on `complete` (`cg_reset {ID}`).
- **Block at threshold:** when the counter reaches `CG_THRESHOLD` (default 3), `cg_park_if_churned {ID}` **parks** the task instead of re-queueing — registry row forced to `needs_human` (NF==8-safe, self-heals phantom columns), and `bypassed_at:` + `bypass_reason: churn — re-processed 3×` written to the task file (a minimal file is created for ghosts). `tend-need-action.sh` then treats it as non-actionable, so the launchd cycle stops waking the agent for it.
- **Async investigation job:** on crossing the threshold an inbox file `investigate-churn-{ID}-{ISO}.md` is auto-filed (`source: self`, `mode: auto`, `triggered_by: {ID}`) whose Goal is "root-cause why {ID} re-processed 3× without converging and propose/apply a fix", Context auto-populated from the registry row + relevant heartbeat lines. **Deduped:** skipped if any inbox file (active or `processed/`) already carries `triggered_by: {ID}`.
- **Heartbeat:** a `[<ISO>] churn-guard — blocked {ID} after 3 re-processings; filed investigate-churn-{ID}` line is appended on park.
- **Clear:** the park clears through the same unblock paths as any bypass (above); `cg_reset` zeros the counter on `complete`.

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
5. Show structured preview; on approve, write to `.orchestrate/inbox/<slug>-<ISO>.md` (or `.orchestrate/inbox/gated/<slug>-<ISO>.md` if gated).

Default new human items to `mode: auto` unless user says "gated" (or write to `inbox/gated/`).

---

## State File & Resume

**New task:** Generate ID `YYYYMMDD-HHMMSS`. Create `.orchestrate/tasks/{ID}.md`. Ensure `.orchestrate/project.md` exists (create with template if not). Register row in project.md registry.

**Carrying forward `followup_for:`/`kind:` headers:** If the source inbox file being drained into this task carries `followup_for:`/`kind:` header lines, copy them verbatim as literal top-level lines at the very top of the constructed task file — not merely paraphrased into `## Context` prose. Downstream anti-recursion checks (`enqueue-review-and-tests.sh`, `enqueue-wiki-sync.sh`) grep the constructed task file, not the original inbox file, for these headers.

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

Immediately after reading Shared Context and before drafting the plan, pull a bounded slice of cross-project wiki knowledge: invoke `/wiki-context-pack "<task title/goal>" --budget 1500` once per task (not re-fetched per phase), and write the result verbatim into the task file under a new `## Wiki Context` section so later phases can reuse it without re-querying. Skip this pull entirely when the task's title/Goal matches a wiki-related job (`wiki-*`, `*-wiki-ingest`, `daily-wiki-digest`, or any ticket whose Design section is itself about wiki maintenance) — avoids recursive/wasteful calls. If `wiki-context-pack` errors, returns empty, or the vault isn't configured, degrade gracefully: proceed with planning unchanged and write `## Wiki Context\n(unavailable — proceeded without it)`.

**Mandatory final phase:** Every plan must include a final `Test & Verify` phase `[inline · execution]`, numbered as Phase N (= total phases). Its acceptance criteria: (1) all output files declared in prior phases exist on disk, (2) detected test suite passes or "no test runner detected", (3) for any background script or launchd job changed: dry-run against a controlled environment passes in both happy-path and failure/recovery scenarios (see Background Job Dry-Run), (4) when inbox ACs or summary name a project-local smoke script, run it (see Project-local smoke scripts). Omit only for tasks that produce zero file changes (pure queries, documentation with no outputs).

**Reconcile-and-document literal/numeric ACs:** when a ticket's hard count/literal AC (e.g. `ls web/*.html | wc -l == 11`) conflicts with verified project reality (the real value is 10), do NOT fail the phase or silently pass on the asserted number. Instead reconcile-and-document: run the check, record the *actual* value with evidence in `test_evidence`/verify.log, treat the AC as met at the corrected value, and note the off-by-one (the ticket's total was a guessed/remembered count, not an enumerated sum).

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

**Immediately after this write — before any phase research/work:** write `.orchestrate/tasks/{ID}.md` (a stub is fine: header + phase list from the plan, phases `pending`) or append a `tend-auto — dispatching "<title>" ({ID})` heartbeat line. Do not defer either until Phase 1's Step A capture. This applies to every path that marks a row `running` — the gated `go`/`go auto` transition here, the T-4 batch-dispatch mark-before-launch step, and a tend session that chooses to execute a pre-assigned task's phases directly inline in its own context rather than spawning a subagent for it. Without one of these two signals promptly in place, `requeue-orphaned-running.sh` (and the T-4 "orphaned-row check" below) cannot distinguish a row that is genuinely being worked inline from a crashed/failed dispatch, and will correctly-per-its-own-rules requeue it to `pending` out from under you once its 300s staleness gate passes — a real incident (task 4FA5) where an inline execution session spent ~9 minutes on research before its first task-file write and got its own row requeued mid-task by a concurrent tend cycle.

---

## Execution Loop

**Self-refresh at start of each turn:** re-read this skill file and the task file. Skip only if this is the first turn after Skill tool was just invoked.

**Pre-execution duplicate-completion guard (mandatory, run before evaluating Ready phases — 20260725-inbox-6B7E):** before selecting/running the next phase for this ID, do a cheap check for whether `orchestrate-history/` already contains an archive for it — reusing the same archive-existence pattern `finalize-completed-tasks.sh`'s `find_archive_for_id()` implements (anchor on `-{ID}-` in the filename, after the timestamp prefix):
```bash
ls .orchestrate/../orchestrate-history/*-"{ID}"-*.md 2>/dev/null   # or: grep -l "{ID}" orchestrate-history/*.md 2>/dev/null
```
- **No hit:** proceed normally — this is the common case; the check costs one `ls`/`grep`.
- **Hit:** this ID is already done — a sibling top-level session, an earlier cycle, or (rarer) this same session's own prior work already completed and archived it. Do **not** run (or continue) the phase loop for it. Skip straight to the Completion sequence's reconcile behavior: confirm the registry row reflects `complete` (flip it if it still shows `running`), confirm a MANIFEST line exists for the archive (do not create a duplicate — see `finalize-completed-tasks.sh`'s `backfill_manifest_for_existing_archive` for the same idempotency pattern), then append `[<ISO>] tend-auto — pre-execution duplicate detected {ID}; already archived (<archive filename>); skipped re-execution [session=<SHELL_PROBE_TOKEN or no-token>]` to heartbeat.log instead of a normal dispatch/completion line, and move on to the next task.
- **Why this catches more than a once-at-claim check:** `Self-refresh at start of each turn` above already re-enters this section once per phase/turn, so this guard naturally re-fires at every phase boundary for a multi-phase task, not just once before Phase 1 — a sibling completion that lands mid-task is caught at the next phase boundary rather than only when this session reaches its own Completion step. (See the 20260724-inbox-7F72/0DE3 regression walkthrough in `20260725-inbox-6B7E`'s phase log for a worked example, including the honest caveat that a check run in the same instant as claim/dispatch can still miss if the sibling has not finished archiving yet — the value is in re-checking cheaply at every subsequent phase boundary rather than only at final Completion.)
- **Scope:** this is a pure read-then-skip short-circuit, not a claim mechanism — it does not change `acquire_tend_lock()` exclusivity or `mark_pending_tasks_as_running()` (RS01), and it is not the heavier atomic per-ID claim-lock (`mkdir .orchestrate/locks/{ID}.claim`) described in the Residual lock-bypass race note below, which remains out of scope.
- Applies uniformly to every entry point that reaches this Execution Loop for a claimed ID: T-4's parallel batch dispatch (the subagent runs this the moment its own loop starts), `tend go auto <ID>` mode's direct single-ID execution, and the "claim, don't wait" inline-execution path.

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

**Top-level files_changed (mandatory when non-empty):** If this phase's `files_changed` is non-empty, append/update a top-level `files_changed: <paths>` line in the task file itself (union across all phases run so far — not only inside this phase's `## PHASE OUTPUT` block's `files_changed` field or prose). This mirrors the Agent phase execution instruction below — `enqueue-review-and-tests.sh`'s `collect_files()` greps the task file for `^files_changed:` and falls back to phase logs only if that's absent; omitting this top-level line lets a real code change silently skip the 6b/6c review-and-tests enqueue (see task 20260724-213946, where an all-inline task made a real code change but the "no code changes — nothing enqueued" fallback fired because no top-level line was written).

**Phase log write (mandatory — atomic, single call):** Append the full PHASE OUTPUT block to `.orchestrate/logs/{ID}-phase{N}.log` via the atomic helper, in ONE call:
```bash
echo "<full PHASE OUTPUT block>" | bash .orchestrate/bin/append-phase-log.sh "$ROOT" "{ID}" "N" "<name>" "${RETRIES:-0}"
```
This writes the `=== Phase N (retry R) — <name> <ISO> ===` header (R only when > 0) AND the body to `.orchestrate/logs/{ID}-phase{N}.log` in a single invocation, and refuses to write anything if the body is empty. A body missing `## PHASE OUTPUT` (the raw-text fallback below) is still written, marked with a `[no PHASE OUTPUT block — raw agent text below]` line instead of being dropped. **Never split this into a separate header `echo` followed later by a body append** — that exact split (a header written to mark progress, with the body append deferred and then never run) is the root cause behind task 20260717-inbox-60E4's phase1/phase2 logs containing only header lines with no PHASE OUTPUT (see task 20260718-inbox-1DF9). This applies to every path that completes a phase, including a tend session that takes over a stalled/re-dispatched task and executes its phases inline in its own context.

Passing `${RETRIES:-0}` is still required, but the script also **auto-derives** the retry number from headers already present in that phase's log file and uses whichever is higher — so if your own `$RETRIES` tracking resets or is lost across a turn (e.g. after a markerless raw-text fallback attempt), the next call for the same phase N still gets labeled `(retry N)` correctly instead of silently repeating a plain `Phase N` header (task 20260720-inbox-69E3).

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
7. Instruction: also write a top-level `files_changed: <paths>` line into the task file itself (not only inside the per-phase `## PHASE OUTPUT` block's `files_changed` field or prose) — `enqueue-review-and-tests.sh`'s `collect_files()` greps the task file for `^files_changed:` and falls back to phase logs only if that's absent; a top-level line lets it classify the change without guessing

**Parallel phases:** launch as multiple Agent calls in one message (max 6). Wait for all before assessing.

**Foreground vs background:** default foreground. Use `run_in_background: true` only when > 5 min expected AND there is independent work to run concurrently.

After agent returns: extract `## PHASE OUTPUT`. If missing → treat as ⚠️ with gap "no PHASE OUTPUT block".

**Phase log write (mandatory — atomic, single call):** Append the full PHASE OUTPUT block (or the raw agent return text if block is missing) to `.orchestrate/logs/{ID}-phase{N}.log` using the same `.orchestrate/bin/append-phase-log.sh` helper as inline phases above — one call, header + body together, `Phase N (retry R)` when R > 0. Never write the header via a separate `echo` first "to mark progress" and come back for the body later — that split is the exact 60E4 root cause (task 20260718-inbox-1DF9).

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

**Regression "teeth" tests — back up before breaking a tracked file, restore from the backup.** When a Test & Verify or tests-follow-up step must temporarily break a **tracked** source file to prove a regression actually fails (a "does this test have teeth?" check), first back the file up with `cp <file> <file>.bak` (or `git stash` / a `git checkout -- <file>` restore point) and restore it **from that backup** — NEVER reconstruct the file from model context (that risks silent truncation/drift and, for a control-plane `bin/` script, near-corruption). After restoring, confirm `git diff --stat` for that file is empty.

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

- **❌** → write `✗ failed`. **Before** updating project.md to `status: needs_human`, you MUST run the **First-Pass Auto-Resolution Check** and the **Human-Only Block Classifier** (see T-4 below). Only set `status: needs_human` if the block passes the classifier (a concrete external dependency) — a locally-executable action (cross-project file write, reversible config write, a runnable script) is NOT a valid block: attempt it instead and retry.
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
- heartbeat lines: `[${COMPLETED_AT}] tend-auto — completed "<task title>" ({ID}) — archived [session=<SHELL_PROBE_TOKEN>]` (or `[session=no-token]` if this session has none — see the T-4 step 3 dispatching-line note above for the same convention; 20260725-inbox-6B7E)
- verify log header: `=== Verification run ${COMPLETED_AT} ===`

Use the **same** `ARCHIVE_STAMP` for the archive filename prefix: `orchestrate-history/${ARCHIVE_STAMP}-${ID}-${slug}.md`

Use `date -u +%Y-%m-%d` (from `COMPLETED_AT`) for the MANIFEST date column.

On each phase checkpoint (Step C ✅), also set registry `last_activity` to `$(date -u +%Y-%m-%dT%H:%M:%SZ)` so partial progress is accurate.

**1. Archive task file:**
- **Pre-archive duplicate-existence check (mandatory, run BEFORE any `cp`/`append-manifest-line.sh`/`rm` below — 20260725-inbox-F338):** a concurrent bash backstop (`finalize-completed-tasks.sh`, invoked from `run-job.sh`/`rescue.sh` preflight) can archive+delete this same task file in the window between this session's last phase check and reaching Completion. The unconditional `cp` below has no existence check, so when the backstop wins that race, the `cp` silently fails, the `echo "tags: ..." >>` step below still creates a new near-empty file at a *different* `ARCHIVE_STAMP`, and `append-manifest-line.sh` still appends a real MANIFEST line pointing at that near-empty duplicate — a genuine corrupt/duplicate archive entry (see 20260725-inbox-CE53). Guard against this the same way the Execution Loop's **Pre-execution duplicate-completion guard** (above) guards phase re-entry:
  ```bash
  ls .orchestrate/../orchestrate-history/*-"{ID}"-*.md 2>/dev/null   # or: grep -l "{ID}" orchestrate-history/*.md 2>/dev/null
  ```
  - **No hit:** proceed with the archive steps below unchanged — this is the common case.
  - **Hit (archive already exists for this ID):** skip the `cp`/MANIFEST-append/`rm` entirely — do not touch the archive file, do not run `append-manifest-line.sh` again. Reconcile instead: confirm the registry row reflects `complete` (flip it via `update-registry-row.sh` if it still shows `running`), confirm a MANIFEST line exists for that archive filename (`grep` `orchestrate-history/MANIFEST.md`; do not append a second line if one is already present). Append `[<ISO>] tend-auto — pre-archive duplicate detected {ID}; already archived (<archive filename>); reconciled` to heartbeat.log instead of the normal completion archive line, then continue to step 2 (Update project.md registry) and the rest of Completion as normal — only the physical archive/copy/delete is skipped.
- Ensure `~/apps/ai-console/orchestrate-history/` exists.
- Copy `.orchestrate/tasks/{ID}.md` → `orchestrate-history/${ARCHIVE_STAMP}-${ID}-<slug>.md` (use `ARCHIVE_STAMP` from timestamp contract above — not a separate guessed time)
- Add `tags:` line to archive copy.
- **Mandatory:** Append one line to `orchestrate-history/MANIFEST.md` via `.orchestrate/bin/append-manifest-line.sh <ROOT> <date:YYYY-MM-DD> <filename> <summary> <tags>` (canonical format `YYYY-MM-DD | filename | summary | tag1, tag2`) — never hand-roll an `echo >>` or any other bracket/timestamp variant; the helper validates the date and rejects fields containing `|`. Skipping MANIFEST breaks History tab tags/search; the monitor also scans on-disk archives as a safety net, but MANIFEST is the canonical index — never omit it.
- Delete original task file from `.orchestrate/tasks/`.
- **Pre-archive files_changed self-check (mandatory, run BEFORE copying/deleting):** if ANY phase's `files_changed` (from `.orchestrate/logs/{ID}-phase*.log` or the phase's `## PHASE OUTPUT` block) was non-empty, the task file MUST already have a top-level `files_changed:` line. Check with `grep -q '^files_changed:' .orchestrate/tasks/{ID}.md`. If the grep fails but any phase shows non-empty `files_changed`, derive the union of paths from the phase blocks/logs and insert a `files_changed: <union>` line into the task file NOW, before archiving — do not proceed to archive/delete until the line is present. This catches the exact omission (an inline phase that changed files but never wrote the top-level line) that silently causes 6b/6c review-and-tests to skip with "no code changes — nothing enqueued" (see task 20260724-213946).
- **Self-check before marking complete:** archive file exists on disk AND matching MANIFEST line was appended (grep `filename` in MANIFEST.md).
- **No duplicate registry rows** for the same inbox execution — if a job is re-registered under a new ID, remove or alias the stale row; use `HISTORY_REGISTRY_ALIASES` in monitor when IDs must coexist temporarily.
- **Cross-project task summaries** (and archive MANIFEST lines) must include the project slug (e.g. `sy-promotion`) so History search finds them.

**2. Update project.md registry:** set `status: complete`, `last_activity: <COMPLETED_AT>` (the exact ISO from timestamp contract — never a rounded placeholder).

> **Registry-row invariant (every writer/checker MUST hold this).** A valid data row is `| ID | summary | mode | phase | status | last_activity |` — exactly 8 `|`-fields with an EMPTY trailing `$8`. The canonical *structural* check is `awk -F'|' 'NF!=8 || $8!=""'` — a bare `NF!=8` is INSUFFICIENT because the historic phantom-timestamp corruption (`... | last_activity | new_ts`, no trailing pipe) is NF==8 with a NON-empty `$8` and a bare check misses it.
>
> **NF==8 is NECESSARY but NOT SUFFICIENT.** A *field-shift* corruption — e.g. an off-by-one awk update that overwrites the `mode` column with a phase number (`auto`→`2`) — preserves the 8-column count AND the empty trailing `$8`, so it sails past the structural check while the row is semantically corrupt. Every checker MUST therefore ALSO assert a value DOMAIN on the two enum columns: **mode (awk `$4`) ∈ {auto, gated}** and **status (awk `$6`) ∈ {pending, running, awaiting_go, awaiting_critic, complete, failed, needs_human}**. The full check is additive: `NF!=8 OR $8!="" OR mode∉domain OR status∉domain`. (The structural breach can be auto-repaired by collapsing columns; a field-shift cannot — the value is genuinely wrong — so it surfaces as a WARNING for a human.) Update rows IN PLACE (never append a column). Reference impls: `repair_registry_rows` (run-job.sh), `checkRegistryInvariant` (monitor server.js), `.orchestrate/tests/test-registry-invariant.sh`.
>
> **Row-update — use the helper, not hand-rolled awk.** `.orchestrate/bin/update-registry-row.sh <ROOT> <ID> <mode> <current_phase> <status> <last_activity>` sets fields BY COLUMN NAME (never by positional literal), validates mode/status against the domain enums before writing, refuses cleanly (no write) on an unknown ID or bad enum, and is idempotent. This removes the need to hand-derive `awk` field positions — the exact mistake that has repeatedly produced field-shift corruption (a phase number landing in the mode column, a timestamp in the status column) while still passing the bare `NF==8` structural check:
> ```bash
> .orchestrate/bin/update-registry-row.sh "$ROOT" "$ID" auto "$PHASE" complete "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
> ```
> Regression: `.orchestrate/tests/test-update-registry-row.sh`. If the helper is ever unavailable, fall back to hand-rolled awk using the field map below — but prefer the helper:
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

**6b. Auto-enqueue review + tests follow-ups (code-changing tasks only):**

Every task that **changed code** must get an INDEPENDENT review pass and test pass in a *fresh* tend cycle — this **supplements** (does not replace) the inline critic + Test & Verify gate (R-1 Decision 3). Run this sub-step always at Completion, after Goal Self-Assessment and before Improvement Suggestions.

- **Trigger (code-change predicate, R-1 Decision 2):** fire only when the aggregate `files_changed:` across all phase blocks contains ≥1 code/test/script/config file (`*.ts *.js *.py *.go *.sh *.sql *.yaml *.json` … `Dockerfile Makefile *.plist`), EXCLUDING pure docs/log/registry/archive/control-plane paths (`*.md *.txt`, `.orchestrate/logs/**`, `.orchestrate/project.md`, `orchestrate-history/**`, `MANIFEST.md`, `.orchestrate/notes/**`, `.orchestrate/inbox/**`). A zero-code-change task (pure docs/query) enqueues NEITHER ticket.
- **Anti-recursion (R-1 Decision 4):** if THIS task itself carries a `followup_for:` header (it IS a review/tests ticket), enqueue NOTHING — terminal. This check takes precedence over the trigger.
- **Mechanism:** the deterministic shell path is authoritative — `.orchestrate/bin/finalize-completed-tasks.sh` calls `enqueue-review-and-tests.sh <ID>` from its reaper (so unattended `tend` always enforces it even if this model session dies mid-Completion). The model path simply mirrors that: run `ENQ_ROOT=<root> ENQ_INBOX_ROOT=<root> bash .orchestrate/bin/enqueue-review-and-tests.sh <ID>`. The helper writes exactly one `kind: review` + one `kind: tests` ticket to the canonical ai-console inbox with headers `followup_for: <ID>` + `kind: …` + `mode: auto` + `source: self`, **dedups** against inbox/registry/history by the `(followup_for, kind)` pair (idempotent — safe if both the model and the bash backstop fire), and writes NO `gate_reason:` / no risky-op literals so the tickets drain to `pending` and tend go auto runs them (R-1 Decisions 5/7).
- Append to heartbeat.log (the helper does this): `[<ISO>] enqueue — filed followup-review-<ID>-<stamp> …` (or `skip <ID> …` for docs-only / `followup_for:` / dedup).

**6c. Auto-enqueue wiki-sync (every completed task):**

Every completed task should get its outcome captured into the Obsidian wiki via a *fresh* tend cycle, not wait for the daily batch job — this **supplements** (does not replace or modify) `orchestrate-daily-wiki-ingest`, which keeps writing the operational `Orchestration/Daily/` activity log for every task unconditionally. Run this sub-step always at Completion, alongside 6b, before Improvement Suggestions.

- **Trigger:** fires for **every** completed task, subject only to the two anti-recursion guards below — there is no longer a code-change/research-keyword gate (removed 2026-07-25, WIKI-1: a code-changing task with no research signal, e.g. a plain bug fix, previously got a review+tests follow-up but no wiki-sync follow-up, so its outcome was never captured except in the daily operational log). The enqueued ticket's own Instructions (see Mechanism) still tell the executing agent to judge substantiveness and skip writing a page for trivial content — the *ticket* always gets filed, but a *wiki page* is only written when the content warrants it.
- **Anti-recursion:** if the source task itself carries a `followup_for:` header (it IS already a follow-up ticket), enqueue NOTHING — terminal. Also skips when the task's title/tags match a wiki-* job itself (`wiki-ingest`, `wiki-capture`, `wiki-update`, `orchestrate-daily-wiki-ingest`, `daily-wiki-digest`) to avoid recursive wiki-of-wiki noise.
- **Mechanism:** the deterministic shell path is authoritative — `.orchestrate/bin/finalize-completed-tasks.sh` calls `enqueue-wiki-sync.sh <ID>` from its reaper (structurally mirrors `enqueue-review-and-tests.sh`, independent of and additional to it — any code-changing task fires both a review+tests ticket and a wiki-sync ticket, since 6b's code-change gate and 6c's now-unconditional trigger are independent checks). The model path mirrors that: run `ENQ_ROOT=<root> ENQ_INBOX_ROOT=<root> bash .orchestrate/bin/enqueue-wiki-sync.sh <ID>`. The helper writes exactly one `kind: wiki-sync` ticket to the canonical ai-console inbox with headers `followup_for: <ID>` + `kind: wiki-sync` + `mode: auto` + `source: self`, **dedups** against inbox/registry/history by the `(followup_for, kind=wiki-sync)` pair, and writes NO `gate_reason:` / no risky-op literals so the ticket drains to `pending` and tend go auto runs it.
- Append to heartbeat.log (the helper does this): `[<ISO>] enqueue — filed followup-wiki-sync-<ID>-<stamp> …` (or `skip <ID> …` for `followup_for:` / wiki-job / dedup — there is no code-change/no-keyword skip path anymore, since WIKI-1 removed that gate).

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
Applies to: <path in ai-toolbox>  ·  Installed at: ~/.claude/skills/<name>/SKILL.md (SKILL.md edits only — see Script-divergence below; a bin script has no ~/.claude mirror)

## Acceptance Criteria
- SKILL.md section "<X>" updated as described (or: bin script `<script>` updated)
- For a SKILL.md edit: sync.sh run, installed `~/.claude/skills/<name>/SKILL.md` reflects the change. For a bin script: change mirrored to the project `.orchestrate/bin/<script>` (sync.sh does NOT copy `bin/` — no ~/.claude bin mirror exists)
- make test passes (or "no test runner detected")
```

**Categories** (set `Applies to:` accordingly):
- Orchestrator → `ai-toolbox/skills/task-orchestrate/SKILL.md`
- Invoked skill → `ai-toolbox/skills/<name>/SKILL.md`
- Orchestrate bin script (`.orchestrate/bin/*.sh` — rescue.sh, run-job.sh, drain-inbox.sh, etc.) → `ai-toolbox/skills/task-orchestrate/bin/<script>`
- Project → project-specific paths (tests, `.orchestrate/`, docs)

**Script-divergence — live-copy count differs by file type:**
- A **SKILL.md** has **3 live copies**: the ai-toolbox source (`skills/<name>/SKILL.md`), the `~/.claude/skills/<name>/SKILL.md` installed by `sync.sh`, and the project skill dir (`.cursor/.claude` skills) when `RUNNER=cursor`.
- A **bin script** has only **2 live copies**: the ai-toolbox source (`skills/task-orchestrate/bin/<script>`) and the project copy (`.orchestrate/bin/<script>`, installed by `install-launchd.sh`). **`sync.sh` syncs only `SKILL.md`, never `bin/`** — so there is NO `~/.claude/.../bin/` mirror. Do not assert a phantom `~/.claude/skills/task-orchestrate/bin/<script>` copy for bin scripts; mirror edits between the ai-toolbox source and `.orchestrate/bin/` only.

**Delimited-field validation — reject embedded newlines, not just the delimiter.** Any new helper script that validates a free-text field destined for a single-line delimited record (a MANIFEST.md row, a registry row, etc.) must reject an embedded newline in the same validation pass as the delimiter character (`|`) — a value containing `\n` silently splits into multiple physical lines instead of being rejected, even though the delimiter check alone passes it. Its regression test suite must include a newline-in-field case alongside the delimiter-in-field case (`append-manifest-line.sh`'s test suite missed this until an independent review caught it — see `20260725-inbox-R72B`).

**Pattern-class bug fixes — grep sibling scripts, not just the file you're touching.** When a bug fix in one `.orchestrate/bin/*.sh` script addresses a *pattern class* (an un-anchored substring match standing in for an exact-line match, an unescaped delimiter, an off-by-one field index, etc.) rather than a one-off logic error, grep the rest of `.orchestrate/bin/` for the same literal pattern/regex before treating the fix as complete. The same bug can be duplicated across sibling scripts that read the same task-file or registry-row convention. `finalize-completed-tasks.sh`'s `task_file_all_phases_complete()` was fixed once for an un-anchored `grep -c '✓ complete'` substring match that false-positived on `status: ✓ complete (PARTIAL vs. acceptance — ...)` lines — but `tend-need-action.sh`'s `count_needs_human_actionable()`, which reads the exact same task-file convention, had the identical bug and was never touched by that fix. It resurfaced independently a day later on a live tend cycle, on the same task ID, nearly causing a repeat of the exact wrong auto-completion that had already been corrected once (`20260725-inbox-TNAP1`, following `20260725-inbox-CE42`/`20260725-054542`).

**Doc-coupled tests — update assertions alongside intentional T-1/T-4 (or any documented-behavior) edits.** `.orchestrate/tests/test-task-orchestrate.sh` contains `skill_has` assertions that grep for **literal SKILL.md prose** (e.g. the exact strings `awaiting_go (gated) is EXCLUDED` from the T-1 NEED_ACTION example, `**SKIP entirely` from the T-4 `awaiting_go` block, and `Gated tasks still never auto-execute`). These are doc-conformance guards, not behavioral regressions: when you deliberately reword a documented T-1/T-4 behavior, the matching `skill_has` pattern will FAIL until you update it to the new wording. Treat such a failure as "the doc-conformance test caught my edit," not a bug — re-point the assertion at the new text in the same change.

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

Requires skills synced to `$PROJECT_DIR/.cursor/skills/` when using `RUNNER=cursor` (run `sync.sh` from ai-toolbox).

To run tend manually at any time: type `tend` in any session.
To unload: `launchctl unload ~/Library/LaunchAgents/com.orchestrate.tend.plist`

**Note:** The heartbeat runs from `WorkingDirectory` (your project root). Tend reads `.orchestrate/` relative to that directory. For a project-specific tend, `cd` into the project and type `tend` manually.

---

## Quick Reference

```bash
# New task
/task-orchestrate "refactor auth in gjw-web-fe to use JWT"

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
No rate limiting exists today. The express app entry point is src/app.ts. We use express-rate-limit in ads_rate_limit already — same pattern applies here.

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
