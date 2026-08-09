# Pillar 1: Security (Deny-List + Hooks)

An agent that can run arbitrary commands needs an explicit deny-list, not an honor system — this pillar covers the permission config and hooks that keep destructive or credential-leaking actions from running unreviewed.

## Why it matters

- Default-allow permission configs mean one bad command (`rm -rf`, a stray `kubectl apply`) executes before anyone notices.
- Secrets left out of the deny-list (`.env*`, `.aws/**`, `.credentials`) can be read or committed by an agent that has no reason to know they're sensitive.
- Static permission rules can't catch everything — PreToolUse hooks add a dynamic checkpoint for risky classes of commands (e.g. Kubernetes mutations) that need a human look before they run.
- Permission drift between tools (Claude Code vs. Cursor) quietly reopens gaps that were already closed in one config but not the other.

## Where it lives

| Source | Path (in ai-toolbox) | What it provides |
|---|---|---|
| permission-audit skill | `skills/permission-audit/SKILL.md` | Audits Claude Code / Cursor permission configs for gaps: secrets exposure, overly-broad globs, parity drift, hook regression |
| Safety instructions | `instructions/safety.md` | The deny-list conventions and destructive-operation confirmation rules this pillar follows |

## How to get it

```bash
git clone https://github.com/AmenZhou/ai-toolbox.git
ln -s "$PWD/ai-toolbox/skills/permission-audit" ~/.claude/skills/permission-audit
```

`instructions/safety.md` is not a skill — read it and adapt its rules into your own project's `CLAUDE.md` or global instructions rather than symlinking it.

## What it does for you

`permission-audit` scans your global (`~/.claude/`, `~/.cursor/`) and project-level permission files, checks them against known vulnerability classes (secrets exposure, overly-broad allow globs, Claude/Cursor parity drift, hook regressions), and emits both a machine-readable JSON report and a human-readable Markdown report — including regression detection against a known-good baseline, so you can tell whether a recent change reopened a gap you'd already closed. `instructions/safety.md` supplies the underlying policy it checks against: always ask before deleting or overwriting files, never use destructive commands without confirmation, and scope risky operations instead of blanket-allowing them.

**Back to:** [Assessment & Gap Finding Guide](../ASSESSMENT.md)
