# Claude Code Permissions & Safety Hooks

**Last Updated:** 2026-08-14  
**Author:** Configuration system  
**Purpose:** Document the permission model, hook system, and safety guardrails in Claude Code

---

## Document Summary

**Scope:** Complete documentation of Claude Code's permission model, safety hooks, and configuration.

**What's Covered:**
✅ Global permission config (allow/deny/ask)  
✅ Settings hierarchy (global/project/local layers)  
✅ 7 active PreToolUse hooks (kube, pg, graphify, restrict-paths, wiki-research, typescript, rtk)  
✅ 4 scope-check helper scripts (rm-mv, redirect, search, chmod)  
✅ 1 PostToolUse hook (graphify usage logging)  
✅ Design principles and interaction examples  
✅ Debugging guide  

**Known Gaps:**
⚠️ `chmod-scope-check.py` and `redirect-scope-check.py` exist but NOT symlinked → currently inactive  
⚠️ `fix-settings-hooks.sh` and `install-kube-hook.sh` are helpers, not active hooks  

**Tools Covered:**
- `Bash` — 7 active hooks + 4 scope-check sub-validators
- `Read/Write/Edit` — path restriction + typescript reminder
- `Grep/Glob` — graphify search intercept + scope restriction
- `AskUserQuestion` — wiki research gate
- `Agent`, `WebFetch`, `WebSearch` — in allow list, no specific hooks

---

## Quick Reference: Hook Coverage

| Tool/Operation | Hooks Active | Safety Level | Approval Model |
|---|---|---|---|
| `kubectl` (read-only) | kube-pretooluse | Auto-allow | None |
| `kubectl` (dry-run) | kube-pretooluse | Auto-allow | None |
| `kubectl` (live mutating) | kube-pretooluse | Blocked | Agent approval token |
| `psql` (read-only) | pg-pretooluse | Auto-allow | None |
| `psql` (BEGIN/ROLLBACK preview) | pg-pretooluse | Auto-allow | None |
| `psql` (live mutating) | pg-pretooluse | Blocked | Agent approval token |
| `rm` / `mv` inside ~/apps | restrict-paths.sh | Auto-allow | None |
| `rm` / `mv` outside ~/apps | restrict-paths.sh | Blocked | Requires ask-gate confirmation |
| `grep` / `find` / `rg` | graphify-search-intercept | Auto-allow + context | None (advisory) |
| File Write/Read outside ~/apps | restrict-paths.sh | Blocked | Requires ask-gate confirmation |
| `.env`, `.aws`, `.ssh`, `.key` access | settings.json `ask` | Blocked | Requires user confirmation |
| Redirection `>` outside ~/apps | redirect-scope-check | Blocked | Requires ask-gate confirmation |
| `chmod` (unsafe perms) | chmod-scope-check | Blocked | Requires ask-gate confirmation |
| Background search (unscoped) | search-scope-check | Blocked (background only) | Requires ask-gate confirmation |
| `AskUserQuestion` before wiki | wiki-research-gate | Auto-allow | None (nudge only) |
| TypeScript file edits | ts-pretooluse | Auto-allow | None (reminder only) |
| All command output | rtk hook claude | Auto-optimize | None (advisory) |

**Legend:**
- **Auto-allow:** Executes immediately, no confirmation
- **Blocked:** Queued for review, requires approval or user confirmation
- **Advisory:** Non-blocking nudge, execution proceeds regardless
- **Agent approval token:** Command hash stored in `.orchestrate/*/approved/`, reused on retry

---

## Quick Overview

Claude Code enforces a multi-layered safety model:

1. **Explicit Allow/Deny** — `settings.json` declares which tools/patterns are always allowed or hard-blocked
2. **Request Gate** — patterns in the `ask` list require user confirmation before executing
3. **Dynamic Hooks** — PreToolUse/PostToolUse hooks intercept tool calls to add context, enforce scope, or block based on state

This document covers the three layers with examples and design rationale.

---

## Layer 1: Permission Configuration

**File:** `~/.claude/settings.json`

### Structure

```json
{
  "permissions": {
    "allow": ["Bash", "Edit", "Read", "Glob", "Grep", ...],
    "deny": ["Bash(rm -rf /*)", "Bash(rm -rf ~*)"],
    "ask": ["Bash(rm -rf *)", "Bash(kubectl scale *)", ...]
  }
}
```

### Allow List

**Always permitted** (no confirmation needed, no hook gate):
- `Bash`, `Edit`, `Write`, `Read` — core file operations
- `Glob`, `Grep` — search operations
- `WebFetch`, `WebSearch` — external data
- `Agent` — subagent spawning
- `Bash(kubectl exec:*)` — read-only kubectl container access

### Deny List (Hard Block)

**Never executed**, even on user request:
- `Bash(rm -rf /*)` — destructive from root
- `Bash(rm -rf ~*)` — destructive from home

This reflects the design principle: **catastrophic operations are never permitted, not just gated**.

### Ask List (Confirmation Gate)

These patterns require explicit user confirmation:

#### Destructive File Ops
- `Bash(rm -rf *)` — recursive delete (generic)
- `Bash(find * -delete*)` — find-based deletion
- `Bash(find * -exec*)` — find-exec (may mutate)
- `Bash(dd *)` — direct device writes
- `Bash(mkfs*)` — filesystem creation

#### Kubernetes
- `Bash(kubectl scale *)`, `patch`, `apply`, `delete`, `rollout` — live cluster changes
- `Bash(kubectl exec -i*)`, `-t*` — interactive container access
- `Bash(kubectl port-forward *)` — port forwarding (side-channel risk)
- `Bash(terraform apply *)`, `Bash(pulumi up *)` — IaC mutations

#### Package Management
- `Bash(npm publish *)` — package publication
- `Bash(npm install -g:*)` — global package install
- `Bash(pip install:*)` — Python package install
- `Bash(brew install:*)` — system package install

#### Git
- `Bash(git push:*)`, `git push --force`, `git push * -f` — upstream changes
- `Bash(git reset:*)`, `git rebase:*`, `git checkout --*` — history mutation
- `Bash(git branch -D*)` — branch deletion
- `Bash(git config --global *)`, `--system`, `--unset*` — config mutation

#### Other High-Risk
- `Bash(sudo:*)`, `kill`, `pkill`, `killall` — process control
- `Bash(chown *)` — ownership changes
- `Bash(gh pr create:*)`, `gh pr merge`, `gh release create` — GitHub mutations
- `Bash(curl | bash)`, `wget | bash` — arbitrary script execution
- `Bash(launchctl load/unload/bootout *)` — system service control

#### Credential/Secret Read
- `Read(//**/.ssh/**)` — SSH keys
- `Read(//**/.env*)` — environment files with secrets
- `Read(//**/.aws/**)` — AWS credentials
- `Read(//**/.credentials)` — credential files
- `Read(//**/*.pem)`, `*.key` — private keys

#### Credential/Secret Write/Edit
- `Write`/`Edit` to `.env*`, `.aws/**`, `.ssh/**`, `.credentials`, `*.pem`, `*.key`

---

## Layer 2: Hook System

**File:** `~/.claude/settings.json` → `hooks` section

Hooks intercept tool calls and can:
- Inject context (e.g., knowledge graph results before grep)
- Block or escalate to `ask`
- Provide metadata or warnings
- Redirect or transform commands

### Hook Matcher Model

A hook matches on:
- **Tool name:** `Bash`, `Read`, `Write`, `Edit`, `Grep`, `Glob`, `AskUserQuestion`
- **Pattern:** Optional regex on the tool input
- **Examples:** `Bash(kubectl scale *)`, `Read(//**/.env*)`

### Hook Execution Timing

- **PreToolUse** — Before the tool executes; can allow/deny/ask
- **PostToolUse** — After the tool executes; can log or trigger side effects

Hooks execute in declaration order. First hook to return a non-pass verdict (allow/deny/ask) stops the chain.

---

## Layer 3: Active Safety Hooks

### 1. **Kubernetes PreToolUse Hook** (`kube-pretooluse.sh`)

**Purpose:** Tiered Kubernetes safety gating  
**Matcher:** `Bash`  
**Behavior:** Non-blocking; outputs context to stderr

#### Tier 1: Read-Only (Auto-Allow)
```bash
kubectl get|describe|logs|top|explain|config view|diff
helm list|status|get|show|history|template
```

#### Tier 2: Preview Only (Auto-Allow, No Mutation)
```bash
kubectl ... --dry-run=client
kubectl ... --dry-run=server
helm upgrade ... --dry-run
```

#### Tier 2.5: Read-Only Container Access (Auto-Allow)
```bash
# Only if inner command is read-only (no redirects, expansions, interactive flags)
kubectl exec [-it] -- cat /var/log/app.log
kubectl exec -- grep error /var/log/app.log | wc -l
```

**Blocked:** `-i` or `-t` flags (interactive), or inner commands like `sh`, `bash`, `rm`, etc.

#### Tier 3: Live Mutating (Requires Approval)
```bash
kubectl scale|patch|apply|delete|rollout ...
kubectl exec (with -i/-t flags)
```

**Behavior:**
1. Creates `/tmp/kube-cmd-*.sh` review script
2. Stores pending review in `.orchestrate/kube-reviews/pending/`
3. Blocks execution, prints review ID and approval URL
4. Agent can then:
   - Run `--dry-run` first (auto-allowed to verify)
   - Approve via curl POST to local approval API
   - Retry the original command (hook checks approval token)

**Agent Approval Workflow:**
```bash
# Verify safety first (auto-allowed)
kubectl apply -f config.yaml --dry-run=client

# Approve if safe
curl -sX POST http://127.0.0.1:7842/api/kube-approve \
  -H "Content-Type: application/json" \
  -d '{"id":"cmd-abc123","action":"approve"}'

# Retry original — hook sees approval token and allows
kubectl apply -f config.yaml
```

#### Tier 4: Live Helm (Requires Approval)
```bash
helm uninstall|delete|upgrade|install|rollback
```

Same approval workflow as Tier 3.

---

### 2. **Path Restriction Hook** (`restrict-paths.sh`)

**Purpose:** Limit file access to ~/apps and ~/.claude (with safe exceptions)  
**Matcher:** `Read`, `Write`, `Edit`, `Bash`, `Grep`, `Glob`  
**Behavior:** Hard-deny outside allowed zones (exits 0 with deny decision)

#### Allowed Paths

✅ **Always allowed:**
- `~/apps/**` — project work area
- `~/.claude/**` — hooks, settings, memory, transcripts
- `/tmp/**`, `/private/tmp/**` — temporary files
- `/usr/**`, `/opt/**`, `/bin/**`, `/sbin/**` — system binaries
- `/System/**`, `/Library/**`, `/dev/**` — macOS system
- `/var/folders/**` — system temp

❌ **Blocked:**
- `~/Downloads`, `~/Desktop`, `~/Documents` etc. — personal directories
- `/etc/**`, `/var/**` (except `/var/folders/`) — system config
- Any path outside the above

#### Sub-Checks on Bash

When running Bash commands, additional scope checks apply:

**rm/mv scope check:**
- Auto-allowed inside `~/apps`
- Outside `~/apps` → ask for confirmation
- Pattern matching via `rm-mv-scope-check.py`

**Search scope check (background sessions only):**
- `grep`, `find`, `rg` must be narrowed to a `~/apps/<project>` subdirectory
- Prevents background jobs from scanning entire filesystem
- Interactive sessions (TEND_LOCK_MANAGED != 1) are exempt

**Redirect/tee scope check:**
- `cmd > /path/to/file` writes only allowed inside `~/apps`, `/tmp`, or /dev sinks
- Prevents redirection leaks outside the work area

**chmod scope check:**
- Safe subset auto-allowed: non-recursive, non-setuid/setgid, inside `~/apps`
- Dangerous perms (world-writable, setuid, recursive) → ask

---

### 3. **Graphify Search Intercept** (`graphify-search-intercept.sh`)

**Purpose:** Query knowledge graphs before grep/find to provide structural context  
**Matcher:** `Bash`  
**Behavior:** Advisory; always exits 0 (non-blocking)

**Triggered by:** `grep`, `rg`, `find`, `fd`, `ag`, `git grep`

**How it works:**
1. Extracts search query from command (strips flags, keeps content terms)
2. Detects which graph applies (ads/dsp or ads-stress-test based on path)
3. Runs `graphify query <terms> --budget 600` (fast, 70x cheaper than grep)
4. Prints results to stderr as context before grep/find executes

**Example:**
```bash
$ grep -r "assertMccPermission" ads/dsp

# Hook fires, prints:
📊 graphify (ads-dsp): assertMccPermission
- assertMccPermission (function) @ ads/dsp/lib/auth.ts:24
  ↓ used by: mccValidator (1 other use)
  ↓ called from: validateMCC @ ads/dsp/lib/validate.ts:15
# ... more structural context ...

# Then regular grep continues as normal
```

**Graphs Available:**
- `graphify-ads-dsp/graphify-out/graph.json` — 3,484 files, 13,204 nodes
- `graphify-ads-stress-test/graphify-out/graph.json` — 173 files, 1,764 nodes

**Graph Updates:** Auto-triggered on git commit (via hook), or manual:
```bash
graphify update /Users/haimengzhou/apps/ads/dsp --graph graphify-ads-dsp/graphify-out/graph.json
```

---

### 4. **Wiki-Research Gate** (`wiki-research-gate.sh`)

**Purpose:** Advisory nudge to use wiki-query before AskUserQuestion  
**Matcher:** `AskUserQuestion`  
**Behavior:** Advisory reminder; always exits 0 (non-blocking)

Prints to stderr:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⚠️  Wiki-Research Gate: Before asking this question, did you try:
  • wiki-query for existing knowledge?
  • grounded-investigate for cross-validated facts?
  • grep/code-read for implementation details?
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Question: [extracted from tool input]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Proceeding to ask anyway (gate is advisory, not blocking).
```

**Rationale:** User/project memory prefer investigative autonomy over immediate asks. This nudge encourages checking the wiki and investigation tools first.

---

### 5. **PostgreSQL PreToolUse Hook** (`pg-pretooluse.sh`)

**Purpose:** Tiered PostgreSQL safety gating (mirrors Kubernetes pattern)  
**Matcher:** `Bash`  
**Behavior:** Non-blocking; outputs context to stderr

#### Tier 1: Read-Only (Auto-Allow)
```bash
psql -c "SELECT * FROM users"
psql -c "EXPLAIN ANALYZE ..."
psql -c "\d users"  # meta-commands
SELECT * FROM pg_stat_activity
```

**Detected by:**
- Meta-commands: `\d`, `\l`, `\dt`, `\df`, etc. (introspection)
- `pg_stat_activity` queries (monitoring)
- Pure read-only checks: no INSERT/UPDATE/DELETE/DROP/TRUNCATE/ALTER/CREATE/GRANT/REVOKE keywords

#### Tier 2: Dry-Run Preview (Auto-Allow, No Mutation)
```bash
psql -c "BEGIN; DELETE FROM users WHERE id=5; ROLLBACK;"
```

Wrapped in `BEGIN` + `ROLLBACK` allows safe verification without side effects.

#### Tier 3: Live Mutating SQL (Requires Approval)
```bash
psql -c "INSERT INTO users VALUES (...)"
psql -c "DROP TABLE legacy_data"
psql -c "ALTER TABLE users ADD COLUMN ..."
```

**Special Safety:** `DELETE` without `WHERE` clause is **always blocked**, even in BEGIN/ROLLBACK, to prevent accidental mass deletion.

**Behavior** (identical to Kubernetes):
1. Creates `/tmp/pg-cmd-*.sh` review script
2. Stores pending review in `.orchestrate/pg-reviews/pending/`
3. Blocks execution, prints review ID
4. Agent can approve via curl POST, then retry (hook validates approval token)

#### Approval Workflow
```bash
# Verify with dry-run (auto-allowed)
psql -c "BEGIN; DELETE FROM table WHERE id=5; ROLLBACK;"

# Approve if safe
curl -sX POST http://127.0.0.1:7842/api/pg-approve \
  -H "Content-Type: application/json" \
  -d '{"id":"cmd-abc123","action":"approve"}'

# Retry original — hook allows
psql -c "DELETE FROM table WHERE id=5;"
```

**Postgres Targets Detected:**
- Direct `psql` commands
- Environment variables: `ADS_DB_HOST`, `USER_DB_HOST`
- Host IP: `64.71.171.49` (production database)

---

### 6. **TypeScript Reminder** (`ts-pretooluse.sh`)

**Purpose:** Inject TypeScript best-practices reminder on .ts/.tsx edits  
**Matcher:** `Write`, `Edit`  
**Behavior:** Advisory; always exits 0

Fires on any edit to `*.ts`, `*.tsx`, or `*.d.ts` files:

```
Reminder for this .ts/.tsx edit: 
- prefer strict typing (no implicit any)
- name types/interfaces clearly
- handle errors explicitly (no silent catches)
- avoid unnecessary casts (as)
- keep functions small and pure where practical
- add/adjust tests for new logic
- defer to the repo's own CLAUDE.md/style where it conflicts
```

---

### 7. **RTK Output Optimizer** (`rtk hook claude`)

**Purpose:** Compress & filter command output for token efficiency  
**Matcher:** `Bash`  
**Behavior:** Post-tool advisory; non-blocking

RTK is a high-performance CLI proxy that intelligently filters system command output before reaching Claude's context window. Installed at `/opt/homebrew/bin/rtk`.

**Optimizations per Command:**

| Command | Optimization | Benefit |
|---------|--------------|---------|
| `ls` | Token-optimized output | Remove extra spacing/colors |
| `tree` | Compact tree formatting | Reduce recursive verbosity |
| `cat` / `read` | Intelligent filtering | Strip boilerplate, keep essentials |
| `git` | Compact diff/log output | Only changed lines, no noise |
| `gh` / `glab` | Token-compressed output | GitHub/GitLab API responses |
| `kubectl` | Compact YAML/table output | Kubernetes objects compressed |
| `docker` | Condensed build/test output | Only failures/summary |
| `find` | Compact tree output | Groups results, reduces volume |
| `grep` / `rg` | Strips whitespace, groups by file | Multi-file searches stay readable |
| `diff` | Ultra-condensed changes | Only affected lines visible |
| `json` | Compact values or keys-only | JSON output reduced 70-90% |
| `psql` | Strips table borders, compresses | Database output readable but tiny |
| `aws` | Force JSON, compress large lists | AWS CLI verbosity eliminated |
| `env` | Filtered environment variables | Only relevant vars shown |

**Integrated into Hook Chain:**

RTK runs as the **last hook in the Bash PreToolUse chain**. By the time it fires, other hooks (kube-pretooluse, pg-pretooluse, graphify, restrict-paths) have already validated safety. RTK then optimizes what goes to Claude.

**Examples:**

```bash
# Regular ls: verbose output
$ ls -la ~/apps/ads | head -10
total 416
drwxr-xr-x  23 haimeng  staff   736 Aug 14 10:22 .
drwxr-xr-x  42 haimeng  staff  1344 Aug 11 09:49 ..
-rw-r--r--   1 haimeng  staff  2048 Aug 14 10:20 CLAUDE.md
-rw-r--r--   1 haimeng  staff   512 Aug 14 10:20 CLAUDE.local.md

# With rtk: token-compressed
$ rtk ls -la ~/apps/ads | head -10
drwxr-xr-x 23 haimeng staff 736 Aug14 10:22 .
drwxr-xr-x 42 haimeng staff 1344 Aug11 09:49 ..
-rw-r--r-- 1 haimeng staff 2048 Aug14 10:20 CLAUDE.md
-rw-r--r-- 1 haimeng staff 512 Aug14 10:20 CLAUDE.local.md

# kubectl with rtk: extremely compact
$ kubectl get pods --all-namespaces
# Normal: 50+ lines of table headers, formatting
# With rtk: 3-5 lines, only name/namespace/status
```

**Token Savings:** Typically **60–90% reduction** for large outputs (logs, diffs, kubectl, AWS API responses).

**When Used:**
- Automatically invoked on all Bash commands (via hook chain)
- User can also call directly: `rtk ls`, `rtk git log`, `rtk find . -name "*.rs"`
- Transparent — output is piped through RTK optimization before Claude sees it

---

### 6. **PostToolUse: Tool Usage Logging**

**Purpose:** Log graphify command usage for observability  
**Matcher:** `Bash`  
**Behavior:** Async (non-blocking); runs after command completes

Appends to `~/apps/ai-console/logs/tool-usage.log`:
```
[2026-08-14T10:23:45Z] Bash | graphify query "symbolName" --graph path
```

Used to track and optimize graphify queries.

---

## Interaction Examples

### Example 1: Kubernetes Safe-First Workflow

```bash
# User asks to apply config
kubectl apply -f my-config.yaml

# Hook fires: detects kubectl apply (Tier 3: live mutating)
# → creates /tmp/kube-cmd-XXXXXX.sh
# → stores in .orchestrate/kube-reviews/pending/
# → blocks execution, prints review ID

# Agent (Claude) runs to verify safety first
kubectl apply -f my-config.yaml --dry-run=client  # Tier 2: preview, auto-allowed

# Agent approves if dry-run looks safe
curl -sX POST http://127.0.0.1:7842/api/kube-approve ...

# Retry original — hook checks approval token, allows
kubectl apply -f my-config.yaml  # Now auto-allowed
```

### Example 2: Path Scoping on rm/mv

```bash
# User in ~/apps/ads, asks to clean up
rm *.bak-20260810  # inside ~/apps/ads

# Hook fires on Bash(rm...)
# → rm-mv-scope-check.py verifies target is under ~/apps
# → auto-allowed, no confirmation

# Later, user in different context
rm /tmp/experimental-file  # target is /tmp (allowed exception)

# Hook auto-allows (is_allowed_path checks for /tmp/*)
```

### Example 3: Graphify Before Search

```bash
# User asks for search
grep -r "submitOrder" ads/dsp

# Hook fires: graphify-search-intercept.sh
# → extracts query: "submitOrder"
# → detects path: ads/dsp → use DSP graph
# → runs graphify query "submitOrder" --budget 600
# → prints structural context to stderr

# Then regular grep continues
```

### Example 4: Blocked Credential Access

```bash
# User asks to read AWS config
cat ~/.aws/credentials

# Hook fires on Read(//**/.aws/**)
# → ask list triggered
# → user prompted for confirmation
# → if denied, tool doesn't execute

# If user explicitly confirms, it runs
```

---

## Design Principles

### 1. **Explicit Over Implicit**

Permission defaults are **closed** (deny-by-default). Only explicitly listed allow/ask patterns execute.

**Corollary:** Wildcard patterns in settings.json are rare. Most specific scopes are coded in hooks (Python scripts).

### 2. **Scope > Blanket**

**Scoped permission:** `Bash(rm:*)` asks for confirmation (from `restrict-paths.sh`'s sub-check)  
**Blanket permission:** `Bash(rm:*)` in global allow would bypass scope entirely

→ Scoped hooks let safe cases through (e.g., rm inside ~/apps) without asking, while still gating risky cases.

### 3. **Advisory Over Blocking**

Hooks like `wiki-research-gate` and `ts-pretooluse` **nudge** without blocking. They're behavioral guides, not gatekeepers.

**Why:** Reduces permission friction while still encouraging best practices.

### 4. **Agent-Approved Tokens**

Kubernetes hook stores approval tokens in `.orchestrate/kube-reviews/approved/`, keyed by command hash. Agent workflows can:
- Run safe previews first (`--dry-run`, `kubectl diff`)
- Approve if safe
- Retry original (hook validates token)

→ Reduces human confirmation bottleneck for justified commands.

### 5. **Tight Integration with Project State**

Hooks read from project `.orchestrate/` directories and environment. This keeps configuration context-aware:
- Kubernetes approval queue is project-scoped
- Path restrictions respect ~/apps boundary
- Search scoping is aware of background session state

---

## Configuration Files

### Settings Hierarchy (Evaluated Left-to-Right)

Claude Code applies permissions in **stacked order**:

1. **Global user settings** — `~/.claude/settings.json` (broadest scope)
2. **Project settings** — `.claude/settings.json` in current project (project-scoped additions)
3. **Local overrides** — `~/.claude/settings.local.json` (user machine-specific, not in git)
4. **Tier precedence** — `deny > ask > allow` (regardless of stacking order)

| File | Purpose | Layer | Managed By |
|------|---------|-------|-----------|
| `~/.claude/settings.json` | Master permission config: allow/deny/ask lists, global hooks, model, theme | Global | Manual (edit directly) |
| `/Users/haimengzhou/apps/ai-console/.claude/settings.json` | Project overrides: scoped rm/mv/chmod, orchestrate edits, test runs, skills | Project | Git-tracked |
| `~/.claude/settings.local.json` | Machine-private MCP credentials, sensitive tool allows, skill IDs | Local | Manual (not in git) |
| `~/.claude/hooks/kube-pretooluse.sh` | Kubernetes tiered gating | Global | Symlink to ai-console |
| `~/.claude/hooks/pg-pretooluse.sh` | PostgreSQL tiered gating | Global | Symlink to ai-console |
| `~/.claude/hooks/restrict-paths.sh` | Path boundary enforcement | Global | Symlink to ai-console |
| `~/.claude/hooks/ts-pretooluse.sh` | TypeScript best-practices reminder | Global | Symlink to ai-console |
| `~/.claude/hooks/graphify-search-intercept.sh` | Knowledge graph before search | Global | Created locally (not in ai-console) |
| `~/.claude/hooks/wiki-research-gate.sh` | Wiki research nudge | Global | Created locally (not in ai-console) |
| `~/.claude/hooks/*-scope-check.py` | Sub-checks (rm-mv, redirect, search, chmod) | Global | Symlinks to ai-console (⚠️ chmod/redirect missing) |
| `/Users/haimengzhou/apps/ai-console/.claude/hooks/` | Source of truth for most hooks | Canonical | Git-tracked |
| `~/.claude/mcp.json` | Model Context Protocol servers (auth, tool specs) | Global | Claude UI managed |

### Current Project Layer (ai-console)

**File:** `.claude/settings.json`

**Project-specific auto-allows:**
- `Bash(rm *.bak-*)`, `Bash(rm tmp-*)` — Cleanup old backups/temp files
- `Bash(rmdir .orchestrate/tmp/*)` — Clean orchestrate temp
- `Bash(chmod +x:*)` — Make scripts executable (scoped to +x only)
- `Bash(pytest*)`, `Bash(docker-compose *)` — Run tests and compose stacks
- `Edit` to `.orchestrate/`, `orchestrate-history/`, docs/, skills/ — Orchestrate workflow edits

**Private layer (settings.local.json):**
- GitLab API credentials and MCP permissions
- Custom skill allows (wayfinder, grill-me)
- HTTP server permits for local dashboards
- Custom grep/ls optimizations via rtk

### Editing Settings

Direct edits to `~/.claude/settings.json` take effect immediately (no reload needed).

**Safe edits:**
- Adding new patterns to `ask` list
- Adjusting hook command paths
- Enabling/disabling hook matchers

**High-risk edits:**
- Removing entries from `deny` list
- Adding broad wildcards to `allow`
- Changing hook logic

### Adding a New Hook

1. Write the hook script in `/Users/haimengzhou/apps/ai-console/.claude/hooks/`
2. Symlink it from `~/.claude/hooks/`:
   ```bash
   ln -s /Users/haimengzhou/apps/ai-console/.claude/hooks/my-hook.sh \
         ~/.claude/hooks/my-hook.sh
   ```
3. Add to `settings.json`:
   ```json
   "PreToolUse": [
     {
       "matcher": "Bash",
       "hooks": [
         {"type": "command", "command": "/Users/haimengzhou/.claude/hooks/my-hook.sh"}
       ]
     }
   ]
   ```
4. Commit to ai-console repo

---

### 8. **Scope-Check Helper Scripts** (called by restrict-paths.sh)

**Purpose:** Fine-grained validation of command safety within ~/apps boundary  
**Matcher:** Bash (via restrict-paths.sh sub-checks)  
**Behavior:** Validates path scope; returns `ASK` or `OK` verdict

These Python scripts are called by `restrict-paths.sh` to enforce the **scoped > blanket** permission pattern. They allow common safe operations without confirmation, while asking only on risky variants.

#### `rm-mv-scope-check.py`

**What it does:** Validates `rm` and `mv` targets  
**Pattern:**
- Inside `~/apps` → `OK` (auto-allow)
- Outside `~/apps` → `ASK` (requires confirmation)

**Examples:**
```bash
# Auto-allowed (inside ~/apps)
rm ~/apps/ads/build/*.tmp
rm ~/apps/ai-console/logs/*.bak-*

# Asks for confirmation (outside ~/apps)
rm /tmp/experimental-file  # actually OK (is_allowed_path exempts /tmp)
rm ~/Downloads/old-backup.zip  # asks
```

#### `redirect-scope-check.py`

**What it does:** Validates output redirection targets (`>`, `>>`, `&>`, `tee`)  
**Pattern:**
- Target in `~/apps`, `/tmp`, `/private/tmp`, or `/dev/null` → `OK`
- Target outside → `ASK`

**Examples:**
```bash
# Auto-allowed
echo result > ~/apps/ads/output.txt
cmd 2>&1 >> ~/apps/logs/debug.log
tee /tmp/scratch.txt

# Asks for confirmation
echo secret > ~/.aws/backup.txt  # outside allowed zones
curl ... | tee /var/log/custom.log
```

**Why this matters:** Closes the gap where `cmd > /path` falls through to blanket `Bash` allow (settings.json's `Bash(> *)` only matches commands *starting* with `>`).

#### `search-scope-check.py`

**What it does:** Validates filesystem search scope in background sessions only  
**Pattern:**
- Narrowed to `~/apps/<project>` subdir → `OK`
- Unscoped or rooted at `~/apps` or above → `DENY` (background only)

**Examples:**
```bash
# Background session (TEND_LOCK_MANAGED=1):
grep -r "symbolName" ~/apps/ads  # OK - narrowed to ads/
find ~/apps . -name "*.rs"  # DENY - rooted at ~/apps, not a subdir

# Interactive session (TEND_LOCK_MANAGED not set):
grep -r "anything" /  # OK - interactive sessions exempt
find ~ -name "*.log"  # OK - no restriction
```

**Why this matters:** Prevents background jobs (tend sessions) from scanning the entire filesystem, which could DOS the system or leak information.

#### `chmod-scope-check.py`

**What it does:** Validates chmod safety  
**Auto-allowed:**
- Non-recursive (`-R` not present)
- Safe permissions: `755`, `644`, `+x`, etc.
- Target inside `~/apps`

**Asks for confirmation:**
- Setuid/setgid: `u+s`, `g+s`, `4xxx`, `2xxx`
- World-writable: `o+w`, `777`, `a+w`
- Recursive: `-R` flag
- Target outside `~/apps`

**Examples:**
```bash
# Auto-allowed
chmod +x ~/apps/ads/scripts/build.sh
chmod 755 ~/apps/build-output/

# Asks for confirmation
chmod u+s ~/apps/suid-binary  # setuid
chmod 777 ~/apps/shared/  # world-writable
chmod -R 755 ~/apps/**/*.sh  # recursive
```

**Why this matters:** Prevents accidental privilege escalation or overly permissive file modes. Settings.json previously had `Bash(chmod *)` in `ask`, but scoped check lets safe cases through.

---

## Known Gaps & TODO

### Missing Symlinks (Inactive)

⚠️ **These scope-check scripts exist but are NOT symlinked to `~/.claude/hooks/`:**

- `chmod-scope-check.py` — Exists at `/Users/haimengzhou/apps/ai-console/.claude/hooks/` but not active
- `redirect-scope-check.py` — Exists at `/Users/haimengzhou/apps/ai-console/.claude/hooks/` but not active

**Current behavior:** `restrict-paths.sh` calls them but they're not found (fail-open via `|| return 0`), so the checks are **silently skipped**.

**Impact:**
- `chmod` operations don't trigger ask-gate for setuid/setgid/world-writable/recursive
- Redirect/tee writes outside ~/apps don't trigger ask-gate

**Fix needed:**
```bash
ln -s /Users/haimengzhou/apps/ai-console/.claude/hooks/chmod-scope-check.py \
      ~/.claude/hooks/chmod-scope-check.py
ln -s /Users/haimengzhou/apps/ai-console/.claude/hooks/redirect-scope-check.py \
      ~/.claude/hooks/redirect-scope-check.py
```

### Setup/Utility Scripts (Not Active Hooks)

These exist in ai-console but are **not symlinked** or **called by active hooks** — they're helpers:

| Script | Purpose | Status |
|--------|---------|--------|
| `fix-settings-hooks.sh` | Repair broken hook paths in settings.json | Manual/setup only |
| `install-kube-hook.sh` | Initial Kubernetes hook setup | Manual/setup only |
| `restrict-paths.sh.bak-*` | Backups (can delete) | Archive only |

---

## Debugging Hooks

### View Hook Execution

Hooks print to stderr by default:

```bash
# Run Claude Code with verbose output
claude -c "git status" 2>&1 | grep "hook:"
```

### Test a Hook Manually

Hooks read JSON from stdin and print JSON to stdout:

```bash
# Simulate a kubectl apply command
echo '{"tool_name":"Bash","tool_input":{"command":"kubectl apply -f config.yaml"}}' \
  | /Users/haimengzhou/.claude/hooks/kube-pretooluse.sh
```

### Check Hook Approval State

View pending Kubernetes approvals:

```bash
ls -la .orchestrate/kube-reviews/pending/
ls -la .orchestrate/kube-reviews/approved/
```

---

## Related Documentation

- **CLAUDE.md** — User instructions, including permission model overview
- **Security-Review** — Audit of credential access patterns
- **Permission Settings Audit (2026-07-07)** — Historical decisions on scope narrowing
- **Auto-Allow Plus Hook-Safeguard Pattern** — Design pattern for permission + hook layering

---

## Other Settings (Non-Permission/Hook)

The `~/.claude/settings.json` file also contains configuration orthogonal to permissions/hooks:

| Setting | Current Value | Purpose |
|---------|---------------|---------|
| `model` | `haiku` | Default Claude model for Claude Code |
| `fallbackModel` | `["sonnet"]` | Model to use if primary unavailable |
| `effortLevel` | `high` | Extended thinking reasoning effort |
| `theme` | `light` | Editor color theme |
| `tui` | `fullscreen` | Terminal UI mode |
| `env` | (empty) | Environment variables to set in shell |
| `enabledPlugins` | `ponytail@ponytail` | Enabled plugin marketplace |
| `extraKnownMarketplaces` | ponytail GitHub source | Plugin marketplace definitions |

These settings don't affect the permission/hook system and are not detailed in this guide (see Claude Code docs for full reference).

---

## Glossary

- **Ask Gate** — Permission pattern in `ask` list; requires user confirmation
- **Hook** — PreToolUse/PostToolUse interceptor; runs before/after tool execution
- **Matcher** — Tool name or pattern; determines which tools a hook applies to
- **Scope Check** — Sub-validation (via Python script) that narrows an `ask` gate
- **Tier (Kube)** — Level of Kubernetes operation safety (read-only, preview, live, etc.)
- **Review Token** — Approval marker for a specific kubectl command; stores risk level

