# Architecture

How the Inbox & Orchestrate system fits together, component by component.

## The three pillars

1. **Inbox drop-zone** — a folder (`.orchestrate/inbox/`) you drop task files into.
2. **Harness executor** — the AI (Claude Code or cursor-agent) that runs the task.
3. **launchd heartbeat** — the macOS scheduler that wakes the executor every 5 minutes.

Everything else — the registry, the archive, the monitor — exists to keep those three honest.

## The control plane: `.orchestrate/`

Every project that uses this system gets a `.orchestrate/` directory:

```
.orchestrate/
  project.md          # shared context (durable knowledge) + task registry table
  agent.conf          # RUNNER=claude|cursor, TEND_MODE, fallback behavior
  tasks/              # one .md file per active task (phase blocks + state)
  inbox/              # drop-zone — *.md here = a task to register
    gated/            #   hint that a task may need approval (still risk-checked)
    processed/        #   inbox files moved here after registration
  logs/
    heartbeat.log     # one line per tend cycle
    {ID}-phase{N}.log # full PHASE OUTPUT block per phase
    {ID}-verify.log   # auto-verification output
    {ID}-tend.log     # full execution log for inbox-driven tasks
```

`project.md` is both the **registry** (a markdown table of tasks and their status) and the **shared context** (durable facts carried across every task — architectural decisions, known failure modes, conventions). New tasks read shared context before planning; completed tasks append to it.

## The heartbeat cycle (`run-job.sh`)

`launchd` fires `run-job.sh tend` every 300 seconds. The wrapper:

1. **Lock** — acquires `.orchestrate/.tend.lock` (with `TEND_LOCK_MANAGED=1` so the agent never self-aborts on the wrapper's own lock). Stale locks (>6 min) are cleared.
2. **Pre-flight** (pure bash, no LLM cost on idle cycles):
   - `cleanup-stale-inbox.sh` — moves already-processed/stale inbox files aside.
   - `drain-inbox.sh` — registers `gated/` then root inbox files into `project.md`, moving each to `processed/`.
   - `tend-need-action.sh` — computes `NEED_ACTION`. If `0` (no stalled tasks, no pending inbox), logs `idle` and **exits without invoking the AI**. This is what keeps idle cycles free.
3. **Dispatch** — if `NEED_ACTION=1`, invokes the configured runner (`claude` or `cursor-agent`) with `/task-orchestrate tend go auto`, with automatic fallback to the other runner on session-limit/connection errors.
4. **Rescue** — `rescue.sh` (its own launchd agent) periodically resets tasks stuck in `running` and re-queues ghost-reset auto jobs.

## The execution loop (the skill)

When the harness runs `/task-orchestrate tend go auto`, the skill (`skill/SKILL.md`):

1. Drains any remaining inbox items, registering each as a task row.
2. Collects all `pending` tasks and executes them in **parallel batches of up to 3** (each as a sub-agent).
3. For each task: classifies complexity into 2–6 **phases** (Research → Strategy → Execute → QA-style), runs each phase inline or via an agent, and applies a **critic** gate (PASS / PARTIAL / FAIL) with retry/escalation.
4. `gated` tasks (genuine risky ops) are **never** auto-executed — they notify and wait for a human "go".
5. On completion: archives the task file to `orchestrate-history/`, appends a `MANIFEST.md` line, and updates shared context.

### Self-unblocking

Before marking a task `needs_human`, the skill runs two passes of auto-resolution:

- **First pass** (`first-pass-auto-resolve.sh`) — trivial categories: creatable missing dir, deferred/out-of-scope AC language, one-shot transient errors, closed referenced reports, completed downstream tasks.
- **Second pass** — deferral language in phase ACs, report-file closure markers, downstream task completion.

Genuinely blocked tasks are **parked** (`bypassed_at:` marker) so the tend cycle stops churning on them until a human or `requeue-unblocked.sh` clears them.

## Runner abstraction (`agent.conf`)

```bash
RUNNER=claude            # or cursor
TEND_MODE=go auto        # or notify
CURSOR_FALLBACK=auto     # IDE closed → fall back to claude
```

`run-job.sh` reads this every cycle, so flipping the runner takes effect on the next heartbeat — no `launchctl` reload. The monitor's LaunchD tab and `set-runner.sh` both write this file.

## The monitor

`monitor/server.js` is a zero-dependency Node HTTP server (default `127.0.0.1:7842`) that reads `.orchestrate/` and `orchestrate-history/` directly off disk and serves a single-file dashboard (`index.html`):

- **Active Tasks** — registry table, phase progress, per-phase log viewer.
- **History** — searchable archive (indexed by `MANIFEST.md`, with on-disk scan as a safety net).
- **LaunchD** — runner flip via `POST /api/agent-conf`.

## Companion skills (not bundled)

The full system in the original workspace pairs with optional daily skills that simply **enqueue inbox files** on their own launchd schedules:

- `inbox-log-analyzer` — scans logs, files improvement/bug tasks.
- `orchestrate-daily-wiki-ingest` — ingests yesterday's history into a knowledge wiki.
- `daily-inbox-digest` — 5pm summary of processed jobs.
- `launchagent-watchdog` — checks all `com.orchestrate.*` jobs are alive.

They are not required to run the core inbox + orchestrate loop. `bin/enqueue-analyzer-daily.sh` is included as an example of the enqueue pattern.
