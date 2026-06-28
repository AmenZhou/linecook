# linecook

> *Clip a ticket, it works the rail.*

**Inbox & Orchestrate — autonomous background jobs for [Claude Code](https://claude.com/claude-code), driven by text files and your own laptop.**

Drop a markdown file into a folder. A macOS `launchd` heartbeat picks it up, an AI harness runs it through structured phases, and the result lands in an archive. No servers, no dashboards in the cloud, no babysitting — just text files and the machine already on your desk.

> 📊 **Slide deck:** [inbox-orchestrate.vercel.app](https://inbox-orchestrate.vercel.app/) · also bundled at [`docs/slides/inbox-orchestrate.html`](docs/slides/inbox-orchestrate.html)

---

## Think of it like a kitchen

| Kitchen | This system |
|---------|-------------|
| You write an order ticket | You write a task file (`# Goal / # Context / # Acceptance Criteria`) |
| You clip it to the rail | You drop the file in `inbox/` |
| The line cook works the ticket | The AI harness runs the **orchestrate** skill through phases |
| The plate goes out, ticket spiked | The result is archived to `orchestrate-history/` |

You are the one writing tickets. The kitchen runs itself.

---

## Why this exists

1. **Autonomous with a harness** — Claude Code executes an entire workflow (research → plan → build → verify) without human supervision.
2. **Async execution** — tasks run in the background while you focus on something else. Fire and forget.
3. **`launchd` for repeated jobs** — macOS's built-in scheduler gives OS-level reliability for recurring work. No daemon to keep alive, no cron string to babysit. If the laptop is awake, the heartbeat fires.

---

## How it flows

```
   ┌──────────────┐     drop .md      ┌──────────────────────┐
   │   You (or a  │ ───────────────►  │  .orchestrate/inbox/  │
   │  daily cron) │                   └──────────┬───────────┘
   └──────────────┘                              │ every 5 min
                                                 ▼
                        ┌────────────────────────────────────────┐
                        │  launchd heartbeat → run-job.sh          │
                        │   • cleanup-stale-inbox.sh               │
                        │   • drain-inbox.sh   (register tasks)    │
                        │   • tend-need-action.sh (skip if idle)   │
                        └────────────────────┬─────────────────────┘
                                             │ NEED_ACTION=1
                                             ▼
                        ┌────────────────────────────────────────┐
                        │  Harness runs the orchestrate skill     │
                        │   Research → Strategy → Execute → QA     │
                        │   reads/writes .orchestrate/project.md   │
                        └────────────────────┬─────────────────────┘
                                             ▼
                        ┌────────────────────────────────────────┐
                        │  orchestrate-history/  (archive + MANIFEST) │
                        │  monitor dashboard  → http://127.0.0.1:7842 │
                        └────────────────────────────────────────┘
```

The **registry** (`.orchestrate/project.md`) is the system's to-do list and shared memory; the **archive** (`orchestrate-history/`) is its long-term record.

---

## Task lifecycle — a job from drop to archive

| Stage | What happens |
|-------|--------------|
| **1. Dispatch** | You write a markdown task file and drop it in `.orchestrate/inbox/`. |
| **2. Pickup** | `launchd` fires `run-job.sh` → `drain-inbox.sh` registers the task in the registry. |
| **3. Execute** | The harness runs the orchestrate skill through its phases, updating shared context. |
| **4. Complete** | Output archived to `orchestrate-history/`; registry row marked `complete`. |

State machine: `pending → running → awaiting_critic → complete → archived` (with `awaiting_go`, `needs_human`, `failed` as branches).

---

## The inbox task file format

```markdown
# Fix the rate-limit bug in the API service

## Goal
Rate limiter throws 429 after 100 req/s. Make it sliding-window per IP and
return Retry-After. What must be true when done: every route in src/routes/
honors the limit and unit tests cover the boundary.

## Context
Entry point is src/app.ts. We already use express-rate-limit in a sibling service.

## Acceptance Criteria
- All routes return 429 after the limit, with Retry-After header
- Unit tests cover the limit boundary
```

**Modes:**

| Mode | Behavior |
|------|----------|
| `auto` (default) | Runs every phase unattended. Safe, reversible work. |
| `gated` | Pauses before risky ops (DB writes, `rm`/`mv` of tracked files, live `kubectl`, sending email, force-push). Requires an explicit human "go". |

Gating is **risk-based, not location-based** — a safe task filed under `gated/` is de-gated automatically; only genuine risky ops (or an explicit `gate_reason:` line) hold a task for human approval.

---

## Install

Requires macOS (for `launchd`), [Claude Code](https://claude.com/claude-code) (or `cursor-agent`), and Node 18+ (for the monitor only).

```bash
# Install the background watchdog + scripts into a target project
PROJECT_DIR="$HOME/apps/my-project" bash install.sh
```

This will:

1. Create the `.orchestrate/` control plane in your project (registry, inbox, tasks, logs).
2. Copy the runtime scripts into `$PROJECT_DIR/.orchestrate/bin/`.
3. Render and load the `launchd` agents (`com.orchestrate.tend`, `com.orchestrate.rescue`, `com.orchestrate.monitor`).
4. Create `.orchestrate/agent.conf` (choose `RUNNER=claude` or `RUNNER=cursor`).

To run a single cycle manually at any time, type `tend` in a Claude Code session inside the project — or:

```bash
bash $PROJECT_DIR/.orchestrate/bin/run-job.sh tend
```

Switch runner without reloading launchd:

```bash
bash $PROJECT_DIR/.orchestrate/bin/set-runner.sh claude   # or cursor
```

Uninstall:

```bash
launchctl unload ~/Library/LaunchAgents/com.orchestrate.tend.plist
```

---

## The orchestrate skill

The brains of the system is a Claude Code skill ([`skill/SKILL.md`](skill/SKILL.md)). Install it by symlinking into your skills directory:

```bash
ln -s "$PWD/skill" ~/.claude/skills/task-orchestrate
```

Then invoke it directly:

```
/task-orchestrate add rate limiting to all API endpoints and write tests
go auto
```

| Invocation | Mode |
|------------|------|
| `tend` | Watchdog: drain inbox, advance stalled tasks, notify |
| `tend go auto` | Watchdog + auto-execute pending tasks in parallel batches of 3 |
| `inbox` | Show pending inbox items, wait for triage |
| `inbox go auto` | Triage + execute all approved items unattended |
| `resume` | List active tasks, pick one to continue |
| any other text | Plan and execute a new task |

See [`skill/GUIDE.md`](skill/GUIDE.md) for the full walkthrough and [`docs/architecture.md`](docs/architecture.md) for component internals.

---

## Monitor dashboard

A zero-dependency Node.js dashboard ships in [`monitor/`](monitor/):

```bash
cd /path/to/my-project          # where .orchestrate/ lives
node /path/to/linecook/monitor/server.js
# → http://127.0.0.1:7842
```

- **Active Tasks** — live registry, status badges, phase progress, per-phase log viewer (auto-refresh 15s).
- **History** — searchable archive of every completed run from `orchestrate-history/`.
- **LaunchD** — flip the runner between `claude` and `cursor` without touching `launchctl`.

---

## Repository layout

```
linecook/
├── README.md                  # this file
├── install.sh                 # standalone installer for any project
├── LICENSE
├── skill/
│   ├── SKILL.md               # the orchestrate skill (loaded by Claude Code)
│   └── GUIDE.md               # use cases, examples, setup walkthrough
├── bin/                       # runtime scripts (the inbox workflow engine)
│   ├── run-job.sh             #   launchd entrypoint: lock, dispatch, fallback
│   ├── drain-inbox.sh         #   register inbox files into the registry
│   ├── cleanup-stale-inbox.sh #   move processed/stale inbox files aside
│   ├── tend-need-action.sh    #   decide whether a cycle needs the agent
│   ├── rescue.sh              #   recover stuck/stale tasks
│   ├── first-pass-auto-resolve.sh, requeue-unblocked.sh  # self-unblock logic
│   ├── set-runner.sh          #   switch claude ↔ cursor
│   ├── enqueue-analyzer-daily.sh  # daily companion-job enqueuer
│   ├── install-launchd.sh     #   original launchd installer (reference)
│   └── agent.conf.example
├── launchd/                   # plist templates (rendered by install.sh)
│   ├── com.orchestrate.tend.plist
│   ├── com.orchestrate.rescue.plist
│   └── com.orchestrate.monitor.plist
├── monitor/                   # zero-dep Node.js dashboard
│   ├── server.js · index.html · package.json · tests/
├── tests/                     # shell + node test suites
├── examples/inbox/            # sample task files to copy into your inbox
└── docs/
    ├── architecture.md
    └── slides/inbox-orchestrate.html
```

---

## Tests

```bash
bash tests/test-task-orchestrate.sh    # control-plane invariants
bash tests/test-run-job.sh             # launchd dispatch (mock claude/cursor)
node monitor/tests/server.test.js      # dashboard API routes
node tests/test-launch-agent.js        # tend plist registration
```

---

## Provenance

Packaged from a personal Claude Code `task-orchestrate` skill and its `.orchestrate/` control plane into a standalone, self-contained, installable system.

## License

MIT — see [LICENSE](LICENSE).
