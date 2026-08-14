# Claude Code Permissions & Safety Hooks — Template Guide

**Last Updated:** 2026-08-14  
**Author:** Configuration system  
**Purpose:** Generalized template for documenting Claude Code permission models and hook systems

---

## Quick Start: Adapting This Guide

This is a **template guide** for organizations documenting Claude Code permissions and hooks. To use:

1. **Replace placeholders:**
   - `<project-root>` → Your project directory (e.g., `/home/user/projects`)
   - `<user-home>` → Home directory (e.g., `/home/user`)
   - `<project-name>` → Your project (e.g., `my-app-dsp`)
   - `<db-host>` → Database hostname
   - `<approval-api>` → Approval endpoint (e.g., `http://localhost:7842`)

2. **Add project-specific hooks:** Delete sections that don't apply (e.g., PostgreSQL if you don't use it), add sections for your hooks.

3. **Document your settings hierarchy:** Show global, project, and local layers.

4. **Add examples:** Replace our examples with your command patterns.

---

## Document Summary

**Scope:** Complete documentation of Claude Code's permission model, hooks, and configuration (generalized).

**What's Covered:**
✅ Global permission config (allow/deny/ask)  
✅ Settings hierarchy (global/project/local layers)  
✅ Hook system architecture and common patterns  
✅ Example hooks (Kubernetes, PostgreSQL, path restriction)  
✅ Scope-check helper pattern  
✅ Design principles  
✅ Debugging guide  

**Customization Notes:**
- This guide documents **common hook patterns**; add/remove hooks as needed
- **Scope boundaries** (e.g., `~/apps`) are examples; adapt to your project layout
- **Approval URLs** are examples; adapt to your infrastructure

---

## Quick Overview

Claude Code enforces a multi-layered safety model:

1. **Explicit Allow/Deny** — `settings.json` declares which tools/patterns are always allowed or hard-blocked
2. **Request Gate** — patterns in the `ask` list require user confirmation before executing
3. **Dynamic Hooks** — PreToolUse/PostToolUse hooks intercept tool calls to add context, enforce scope, or block based on state

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

### Design Principles

- **Explicit over implicit:** Defaults are closed (deny-by-default)
- **Scope over blanket:** Scoped hooks let safe cases through without asking
- **Advisory over blocking:** Nudges encourage best practices without gatekeeping
- **Tier precedence:** `deny > ask > allow` (regardless of order in settings)

### Typical Allow List

**Always permitted:**
- `Bash`, `Edit`, `Write`, `Read` — core file operations
- `Glob`, `Grep` — search operations
- `WebFetch`, `WebSearch` — external data
- `Agent` — subagent spawning

### Typical Deny List

**Never executed:**
- `Bash(rm -rf /*)` — destructive from root
- `Bash(rm -rf ~*)` — destructive from home

**Principle:** Catastrophic operations are never permitted, not just gated.

### Typical Ask List Categories

**Destructive file ops:**
- `Bash(rm -rf *)`, `Bash(find * -delete*)`, `Bash(dd *)`, `Bash(mkfs*)`

**Infrastructure changes:**
- Kubernetes: `kubectl scale`, `patch`, `apply`, `delete`, `rollout`
- Terraform/Pulumi: `terraform apply`, `pulumi up`
- Git: `git push`, `git reset`, `git rebase`, `git branch -D`

**Package management:**
- `npm publish`, `npm install -g`, `pip install`, `brew install`

**Process control:**
- `sudo`, `kill`, `pkill`, `killall`, `chown`

**Credentials/Secrets:**
- `Read`/`Write`/`Edit` to `.env*`, `.ssh/**`, `.aws/**`, `.credentials`, `*.pem`, `*.key`

---

## Layer 2: Hook System Architecture

**File:** `~/.claude/settings.json` → `hooks` section

Hooks intercept tool calls at two points:

- **PreToolUse** — Before execution; can allow/deny/ask
- **PostToolUse** — After execution; can log or trigger side effects

### Hook Matcher Model

A hook matches on:
- **Tool name:** `Bash`, `Read`, `Write`, `Edit`, `Grep`, `Glob`, `AskUserQuestion`
- **Pattern:** Optional regex on tool input
- **Examples:** `Bash(kubectl scale *)`, `Read(//**/.env*)`

### Execution Order

Hooks execute in declaration order. First hook to return a non-pass verdict (allow/deny/ask) stops the chain.

---

## Common Hook Patterns

### Pattern 1: Tiered Safety Gating

**Use case:** Command that ranges from safe (read-only) to dangerous (live mutation)

**Example: Kubernetes**

```
Tier 1: Read-only (auto-allow)
  - kubectl get, describe, logs, explain, config view, diff

Tier 2: Preview only (auto-allow)
  - kubectl ... --dry-run

Tier 3: Live mutating (blocked → requires approval)
  - kubectl apply, scale, patch, rollout, delete
```

**Implementation:**
1. Hook detects command tier (regex matching)
2. For Tier 1-2, return `allow`
3. For Tier 3:
   - Create review script `/tmp/cmd-XXXXXX.sh`
   - Queue approval request
   - Return `deny`
   - Agent can approve (via API token) and retry

**Where to adapt:**
- Change regex patterns to match your commands
- Update approval endpoint URL
- Modify tier categorization for your use cases

### Pattern 2: Path Boundary Enforcement

**Use case:** Restrict file operations to safe zones

**Example: Allowed zones**
- `~/projects/**` — project work area
- `~/.claude/**` — configuration
- `/tmp/**`, `/private/tmp/**` — temporary files
- System paths: `/usr/**`, `/opt/**`, `/bin/**`, `/System/**`

**Denied zones:**
- Personal directories: `~/Downloads`, `~/Desktop`, `~/Documents`
- System config: `/etc/**`, `/var/**`

**Scope-check sub-pattern:**
- `rm`/`mv` inside safe zone → auto-allow
- `rm`/`mv` outside → ask for confirmation

### Pattern 3: Advisory Nudges

**Use case:** Encourage best practices without blocking

**Examples:**
- Wiki-first research gate: Remind before `AskUserQuestion`
- TypeScript reminder: Best practices on `.ts` edits
- Search intercept: Query knowledge graph before grep

**Key:** Always exit `0` (non-blocking), print to stderr for visibility

---

## Configuration Files

### Settings Hierarchy

Claude Code applies permissions in **stacked order**:

1. **Global user settings** — `~/.claude/settings.json`
2. **Project settings** — `.claude/settings.json` in current project
3. **Local overrides** — `~/.claude/settings.local.json` (machine-specific, not in git)
4. **Tier precedence** — `deny > ask > allow`

### Typical File Layout

```
~/.claude/
├── settings.json              (global permissions, hooks, config)
├── settings.local.json        (private overrides, MCP credentials)
├── hooks/
│   ├── kube-pretooluse.sh     (K8s tiered gating)
│   ├── pg-pretooluse.sh       (PostgreSQL tiered gating)
│   ├── restrict-paths.sh      (path boundary enforcement)
│   ├── ts-pretooluse.sh       (language-specific reminder)
│   ├── *-scope-check.py       (sub-validators)
│   └── ...

<project-root>/.claude/
├── settings.json              (project-specific scoped permissions)
└── hooks/
    └── [project hooks, sourced from elsewhere]
```

### Example: Project Layer

**File:** `<project-root>/.claude/settings.json`

```json
{
  "permissions": {
    "allow": [
      "Bash(rm *.bak-*)",
      "Bash(rm tmp-*)",
      "Bash(chmod +x:*)",
      "Bash(pytest*)",
      "Edit(<project-root>/.orchestrate/**)",
      "Edit(<project-root>/docs/**)"
    ]
  }
}
```

**Purpose:** Auto-allow safe project-specific operations without global confirmation.

---

## Adding Custom Hooks

### Recipe: New Hook

1. **Write hook script** at `~/.claude/hooks/my-hook.sh`:
   ```bash
   #!/usr/bin/env bash
   # Hook reads JSON from stdin, outputs JSON to stdout
   INPUT=$(cat)
   COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
   
   # Your logic here
   if [[ condition ]]; then
     echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'
   else
     echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"reason"}}'
   fi
   ```

2. **Add to `settings.json`:**
   ```json
   "hooks": {
     "PreToolUse": [
       {
         "matcher": "Bash",
         "hooks": [
           {"type": "command", "command": "~/.claude/hooks/my-hook.sh"}
         ]
       }
     ]
   }
   ```

3. **Test manually:**
   ```bash
   echo '{"tool_name":"Bash","tool_input":{"command":"my command"}}' \
     | ~/.claude/hooks/my-hook.sh
   ```

### Recipe: Scope-Check Helper

For nuanced `ask`/`allow` decisions, use Python sub-validators:

1. **Write Python script** at `~/.claude/hooks/my-check.py`:
   ```python
   import sys
   cmd = sys.argv[1] if len(sys.argv) > 1 else ''
   # Your analysis
   if dangerous_pattern in cmd:
       print("ASK\nReason: dangerous pattern detected")
   else:
       print("OK")
   ```

2. **Call from hook:**
   ```bash
   result=$(python3 ~/.claude/hooks/my-check.py "$CMD")
   verdict="${result%%$'\n'*}"
   reason="${result#*$'\n'}"
   if [[ "$verdict" == "ASK" ]]; then
     # escalate to ask
   fi
   ```

---

## Debugging Hooks

### View Hook Execution

```bash
# Run with verbose output
claude -c "your-command" 2>&1 | grep "hook:"
```

### Test Manually

Hooks read JSON and output JSON:

```bash
echo '{"tool_name":"Bash","tool_input":{"command":"test"}}' \
  | ~/.claude/hooks/my-hook.sh
```

### Check Approval State

If using approval tokens:

```bash
ls -la <project-root>/.orchestrate/*/reviews/pending/
ls -la <project-root>/.orchestrate/*/reviews/approved/
```

---

## Design Checklist

When designing permissions and hooks:

- [ ] **Explicit defaults:** Start closed, explicitly allow safe patterns
- [ ] **Scope over blanket:** Use scope-check sub-validators to differentiate safe from risky
- [ ] **Tier hierarchy:** Read-only → Preview → Live, with approval at the edge
- [ ] **Fail-open on errors:** Unrecognized patterns should pass through, not block
- [ ] **Audit trail:** Log important decisions (approvals, high-risk operations)
- [ ] **Human-friendly output:** Clear messages on why something was blocked/asked
- [ ] **Testing:** Manually test hooks with edge cases before deployment

---

## Glossary

- **Ask Gate** — Permission pattern requiring user confirmation
- **Hook** — PreToolUse/PostToolUse interceptor running before/after tool execution
- **Matcher** — Tool name or pattern determining hook applicability
- **Scope Check** — Sub-validator (often Python) that narrows an ask gate
- **Tier** — Level of operation safety (read-only, preview, live)
- **Review Token** — Approval marker for a specific command; enables approval + retry

---

## Related Resources

- [Claude Code Documentation](https://claude.ai/docs) — Official Claude Code guide
- [JSON Schema: claude-code-settings](https://json.schemastore.org/claude-code-settings.json) — Settings structure
- [Hook Protocol](https://claude.ai/docs/hooks) — Detailed hook format and examples
- [Bash Hook Development](https://claude.ai/docs/hooks/bash) — Bash-specific patterns

---

## Contributing

To improve this template:

1. Test hooks in your environment
2. Document what worked and what didn't
3. Share patterns (tiered gating, scope-check, approval workflows)
4. Generalize examples so they work for others

**Template maintainers:** This document is a living guide. Add sections as you discover new patterns, and mark outdated sections with `[DEPRECATED]`.

