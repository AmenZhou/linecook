# task-orchestrate — Use Cases & Guidance

A unified project orchestrator that plans and executes tasks in structured phases, keeps shared context across all work in a project, and watches for stalls automatically. One skill replaces what used to require both `/task-orchestrate` and `/task-supervisor`.

---

## Mental Model

Think of it as three things in one:

1. **Planner** — breaks your task into phases, routes each to the right executor (inline or agent), sets acceptance criteria, runs a critic on each result
2. **Project memory** — maintains `.orchestrate/project.md` per project with shared context that carries forward across every task you ever run there
3. **Watchdog** — a `tend` mode that runs every 5 minutes via launchd, drains the inbox, advances stalled auto-mode tasks, and notifies you when gated tasks need your `go`

---

## First Time Setup

**Install the heartbeat (once per machine):**

```bash
PROJECT_DIR="$HOME/apps/my-project"   # adjust to your project root
bash skills/task-orchestrate/bin/install-launchd.sh
```

Set `RUNNER=cursor` or `RUNNER=claude` in `.orchestrate/agent.conf` to choose the headless agent.

After this, you never need to start a loop or supervisor again. The watchdog runs in the background permanently.

**Initialize a project (first task in any repo):**

The `.orchestrate/` directory is created automatically the first time you run a task in that directory. Nothing to do manually.

---

## Core Workflow

### Running a task

```
/task-orchestrate "your task description"
```

The orchestrator:
1. Reads `## Shared Context` from `project.md` (if it exists) — uses prior decisions to inform the plan
2. Classifies complexity and breaks the task into 2–6 phases
3. Presents the plan and asks clarifying questions
4. Waits for your `go` or `go auto`

**`go`** — gated mode: pauses after each phase for your review before continuing.
**`go auto`** — auto mode: runs all phases end-to-end, only stops on a hard failure.

### What happens after you walk away (auto mode)

The launchd heartbeat fires every 5 minutes. If the task stalled at `awaiting_critic` (e.g. the session closed mid-phase), `tend` picks it up, runs the critic inline, and continues. You get a push notification when it acts.

### Reviewing results

```bash
cat .orchestrate/project.md       # registry + shared context
ls .orchestrate/tasks/            # active task files
tail -f .orchestrate/logs/heartbeat.log   # what tend did
```

---

## Use Cases

### 1. Single focused task with oversight

Use gated mode when you want to review each phase before the next one starts — code review, database migrations, anything where a bad phase would be costly to undo.

```
/task-orchestrate "add Stripe webhook handling to the payments service"
> go
```

After each phase completes: `⏸ Ready for Phase 2 — "go" · changes · "skip" · "abort"`

If you close the session before typing `go`, tend will push-notify you that the phase is ready. It will not advance a gated session — that requires your explicit `go`.

---

### 2. Long task you want to run unattended

Use auto mode for well-scoped work you trust to run end-to-end. Walk away; the heartbeat keeps it moving.

```
/task-orchestrate "migrate the DSP campaign service to the new billing API"
> go auto
```

The orchestrator runs all phases, handles critic assessments inline, and only stops to notify you if a phase hard-fails. You come back to either `TASK COMPLETE` or a specific failure waiting for your decision.

---

### 3. Multiple tasks in one project

Run several tasks in the same project directory. Each shares the same `project.md` so they benefit from accumulated context.

```bash
cd ~/apps/my-project

/task-orchestrate "add dark mode support"
> go auto

/task-orchestrate "fix the accessibility issues from the a11y audit"
> go auto
```

When the first task completes, it appends what it learned to `## Shared Context` — e.g. "Tailwind dark: prefix is configured globally, individual component overrides are not needed". The second task reads this before planning and adjusts accordingly.

---

### 4. Queue tasks via inbox (fire and forget)

Drop tasks into `.orchestrate/inbox/` without even opening a session. The next tend cycle picks them up, registers them, and notifies you.

```bash
echo "write unit tests for the auth module — target 80% coverage" \
  > .orchestrate/inbox/auth-tests.md

echo "generate a migration script to add indexes to DSP campaigns table" \
  > .orchestrate/inbox/campaign-indexes.md
```

Next time tend fires (within 5 minutes): you get a push notification listing the queued tasks. Go to a session and type `go` or `go auto` to start each one.

---

### 5. Cross-project orchestration from a shared directory

From a parent directory, the heartbeat processes all projects at once. You can queue tasks across multiple repos:

```bash
echo "refactor auth" > ~/apps/project-a/.orchestrate/inbox/auth.md
echo "add rate limiting" > ~/apps/project-b/.orchestrate/inbox/rate-limit.md
```

Both get picked up by the same tend cycle.

---

### 6. Resuming after a break

```
/task-orchestrate resume
```

Lists all active tasks across `.orchestrate/tasks/`. Pick one by ID to continue. If it was in auto mode, it resumes immediately. If gated, it shows you the current phase and waits for `go`.

---

## Shared Context — What It Is and Why It Matters

`## Shared Context` in `project.md` is the key feature that makes the orchestrator smarter over time. After every task completes, the orchestrator extracts durable findings and appends them.

**What gets recorded:**
- Architectural decisions ("we use Postgres for X, not ClickHouse — see decision doc")
- API/service behavior discovered ("the billing API returns 429 after 100 req/min")
- Recurring constraints ("all DB migrations must be backward-compatible with the live service")
- Conventions established ("new files in this module use camelCase")
- Known failure modes ("bfs find does not support -newermt; use -mmin")

**What it's used for:**
Every new task's planning phase reads Shared Context first. The orchestrator incorporates it into phase design, acceptance criteria, and agent prompts. An agent working on phase 3 receives the Shared Context verbatim so it doesn't re-learn what a prior task already figured out.

**What it isn't:** a log of what happened. Task-specific details that won't apply to future work don't belong here. That's what the archive (`orchestrate-history/`) is for.

---

## Gated vs Auto Mode

| | Gated (`go`) | Auto (`go auto`) |
|--|--------------|------------------|
| After each ✅ phase | Pauses for your `go` | Continues immediately |
| On ⚠️ gap | Retries automatically, then pauses | Retries automatically, continues if resolved |
| On ❌ failure | Pauses, waits for `retry / skip / replan / abort` | Same — both modes halt on hard failure |
| Tend watchdog | Notifies you phase is ready, never advances | Advances `awaiting_critic` stalls automatically |

**Rule of thumb:** use `go auto` for tasks where you've done similar work before and trust the plan. Use `go` for new territory, risky changes, or anything touching production.

---

## When the Orchestrator Stops Itself (needs_human)

The orchestrator gates you (in both modes) when:
- A phase hard-fails after retries
- A blocker is caused by this task's own changes (not pre-existing)
- The rabbit-hole limit is hit (4 retries on the same phase)

You'll see: `⏸ retry · skip · replan · abort · instruct`

- **retry** — re-run the phase as-is
- **skip** — mark it failed, continue (shows dependent phases that will be skipped)
- **replan** — generate a revised plan for the remaining phases
- **abort** — archive and stop
- **instruct** — you provide a correction, orchestrator re-runs with it

---

## File Reference

| File | Purpose |
|------|---------|
| `.orchestrate/project.md` | Control plane: shared context + task registry |
| `.orchestrate/tasks/{ID}.md` | Active task: phase plan, status, captured output |
| `.orchestrate/inbox/` | Drop zone: `.md` files here are registered by next tend |
| `.orchestrate/inbox/processed/` | Inbox items after registration |
| `.orchestrate/logs/heartbeat.log` | One line per tend cycle |
| `orchestrate-history/` | Archived completed task files |
| `orchestrate-history/MANIFEST.md` | One-line index of all archived tasks |
| `.orchestrate/.tend.lock` | Concurrency lock (auto-deleted after each cycle) |

---

## Quick Reference

```bash
# Start a task
/task-orchestrate "your task here"

# Resume any active task
/task-orchestrate resume

# Run watchdog manually
/task-orchestrate tend

# Queue a task without opening a session
echo "task prompt" > .orchestrate/inbox/task-name.md

# Check project status
cat .orchestrate/project.md

# Watch heartbeat activity
tail -f .orchestrate/logs/heartbeat.log

# Search past tasks
grep -r "keyword" ~/apps/my-project/orchestrate-history/
cat ~/apps/my-project/orchestrate-history/MANIFEST.md
```

---

## Migrating from the Old Two-Skill Setup

If you have existing `.task-orchestrate-state-*.md` files in a project:

```bash
# Create the new layout
mkdir -p .orchestrate/tasks .orchestrate/inbox .orchestrate/logs

# Move existing state files
mv .task-orchestrate-state-*.md .orchestrate/tasks/ 2>/dev/null

# Create project.md (the orchestrator will seed Shared Context from history)
/task-orchestrate resume
```

If you were using `task-supervisor`: that skill is deprecated. The `.supervisor-state.md` file can be deleted — active tasks should be re-registered via inbox or direct invocation.

---

## Related

- [Orchestrate inbox workflow](../../../ai-console/docs/orchestrate-inbox-workflow.md) — mermaid diagram, gated vs auto paths, ranked improvements
