# Design Pattern: Allow-List + Safety-Gate Hooks

**Date:** 2026-08-16  
**Status:** Production-Ready  
**Pattern Type:** Security/Permissions  

---

## One-Line Summary

Replace blanket deny lists with **scoped allow lists + runtime hooks** that differentiate safe from risky operations.

---

## Problem

Naive permission models rely on deny lists:

```json
{
  "permissions": {
    "deny": ["Bash(rm -rf /*)", "Bash(rm -rf ~*)"],
    "allow": ["Bash"]
  }
}
```

**Issues:**
- Deny lists are reactive (you must know every attack)
- Blanket allow/deny doesn't differentiate safe (`rm *.bak`) from risky (`rm /etc/passwd`)
- No runtime context (hooks can't inspect command state, environment, or project boundaries)

---

## Solution: Layered Pattern

### Layer 1: Explicit Allow + Hard Denies (Settings)

**Allow:** Only core tools → `Bash`, `Read`, `Edit`, `Write`, `Grep`, `Glob`, `Agent`

**Deny:** Catastrophic operations only → `rm -rf /`, `chmod u+s`, `git push --force`, system shutdown

```json
{
  "permissions": {
    "allow": ["Bash", "Edit", "Read", ...],
    "deny": [
      "Bash(rm -rf /*)",
      "Bash(chmod u+s *)",
      "Bash(git push --force)",
      "Bash(shutdown*)"
    ]
  }
}
```

**Design:** Start closed, deny only truly catastrophic, allow only general tools.

### Layer 2: Ask Gate (Settings)

**Ask list** for high-risk patterns requiring confirmation:

```json
{
  "ask": [
    "Bash(rm -rf *)",           // generic recursive delete
    "Bash(kubectl scale *)",    // K8s mutation
    "Read(//**/.aws/**)",       // credential access
    "Edit(//**/.env*)"          // secret mutation
  ]
}
```

**Design:** Patterns that *might* be OK, but should be user-confirmed.

### Layer 3: Smart Hooks (PreToolUse)

Hooks intercept before execution and can:
- **Allow** safe cases (no confirmation needed)
- **Ask** risky cases (require confirmation)
- **Deny** catastrophic cases (block entirely)
- **Inject context** (e.g., knowledge graphs before search)

#### Hook Example: Path-Scoped rm/mv

**Blanket deny approach (naive):**
```json
{
  "deny": ["Bash(rm -rf *)"],  // blocks everything
  "deny": ["Bash(mv * /**)"]
}
```

**Better: Scope-check hook**

```bash
# restrict-paths.sh + rm-mv-scope-check.py

rm ~/apps/ads/build/*.tmp   # ✅ inside ~/apps → auto-allow
rm /tmp/experimental        # ✅ /tmp exception → auto-allow
rm ~/Downloads/old.zip      # ❌ outside ~/apps → ask

mv ~/apps/file /etc/passwd  # ❌ moves to system → ask
mv ~/apps/file ~/apps/dest  # ✅ inside ~/apps → auto-allow
```

**Design:** Hook checks scope, auto-allows safe cases, asks only on risky.

#### Hook Example: Tiered Kubernetes

```bash
# kube-pretooluse.sh

kubectl get pods                           # ✅ Tier 1: read-only → auto-allow
kubectl apply -f config.yaml --dry-run    # ✅ Tier 2: preview → auto-allow
kubectl apply -f config.yaml              # ❌ Tier 3: live → ask + approval workflow
```

**Design:** Same command, different tiers of risk. Hook categorizes, allows safe, gates risky.

---

## Trade-Offs: When to Use Each Layer

| Scenario | Use | Rationale |
|----------|-----|-----------|
| **Never OK** (e.g., `rm -rf /`, `chmod u+s`) | **Deny list** | Catastrophic ops should never execute, no context changes that |
| **Usually risky, rare OK** (e.g., `rm -rf *`) | **Ask list** | Generic pattern, but scope might make it safe |
| **Context-dependent** (e.g., `rm *.tmp`) | **Hook + scope-check** | Hook inspects path/state; auto-allows safe, asks risky |
| **Advisory** (e.g., "use wiki first") | **Advisory hook** | Non-blocking nudge; prints to stderr |
| **Infrastructure** (K8s, DB) | **Tiered hook** | Read-only auto, preview auto, live mutations ask + approval |

---

## Implementation Checklist

### Step 1: Audit Current Deny List
- What's in `deny`? Keep only catastrophic ops (DoS, privilege escalation, data destruction)
- Move generic patterns (e.g., `Bash(rm -rf *)`) to `ask` instead

### Step 2: Build Scope-Check Helpers
- Path-scoped checks: `~/apps/**` (allow), outside (ask)
- Tiered checks: read-only (allow), dry-run (allow), live (ask + approval)
- Permission checks: safe perms (allow), setuid/world-writable (ask)

**Patterns:**
```python
# rm-mv-scope-check.py
def check_rm(cmd):
    if is_inside('~/apps', target_path(cmd)):
        return 'OK'  # auto-allow
    else:
        return 'ASK'  # requires confirmation
```

### Step 3: Create PreToolUse Hooks
- Call scope-check helpers
- Return `allow`, `ask`, or `deny`
- Print context to stderr for visibility

```bash
# Hook template
if is_safe($cmd); then
  echo '{"permissionDecision":"allow"}'
else
  echo '{"permissionDecision":"ask","reason":"risky target"}'
fi
```

### Step 4: Test & Iterate
- Test safe cases execute without asking
- Test risky cases trigger ask
- Test denial cases block entirely

---

## Design Principles

### 1. Explicit > Implicit
Start with deny-by-default. Only explicitly listed patterns execute.

### 2. Scope > Blanket
Scoped hooks auto-allow safe cases without confirmation, while still gating risky variants.

```json
// ❌ Blanket deny (blocks all rm)
"deny": ["Bash(rm -rf *)"]

// ✅ Scoped hook (allows rm in ~/apps, asks outside)
"allow": ["Bash"],
// + hook runs rm-mv-scope-check.py
```

### 3. Advisory > Blocking
Nudges (wiki-first, TypeScript reminders) print to stderr but don't block execution.

### 4. Tiers > Equivalence
Categorize operations by risk (read-only, preview, live) and gate each tier independently.

```
read-only    → ✅ auto-allow (kubectl get, SELECT)
preview      → ✅ auto-allow (--dry-run, BEGIN/ROLLBACK)
live         → ❌ ask + approval workflow
```

### 5. Approval Tokens
For live operations, store approval tokens in `.orchestrate/*/approved/` keyed by command hash.

- Agent can verify safety first (`--dry-run`, `kubectl diff`)
- Approve if safe (curl POST approval API)
- Retry original (hook checks token, allows)

---

## Example: Kubernetes + PostgreSQL

### Settings (Layer 1)

```json
{
  "permissions": {
    "allow": ["Bash", "Read", "Edit", ...],
    "deny": [
      "Bash(sudo -i*)",
      "Bash(rm -rf /*)"
    ],
    "ask": [
      "Bash(kubectl scale *)",
      "Bash(kubectl patch *)",
      "Bash(psql -c DELETE*)"
    ]
  }
}
```

### Hooks (Layer 2 & 3)

```bash
# kube-pretooluse.sh
if kubectl_is_read_only($cmd); then
  return 'allow'
elif kubectl_is_dry_run($cmd); then
  return 'allow'
else  # live mutation
  create_review_script $cmd
  return 'ask'  # + approval workflow
fi

# pg-pretooluse.sh
if psql_is_select($cmd); then
  return 'allow'
elif psql_is_begin_rollback($cmd); then
  return 'allow'
else  # live mutation
  create_review_script $cmd
  return 'ask'  # + approval workflow
fi
```

### Result

```bash
# Interactive session, user wants to scale deployment
kubectl scale deployment/api --replicas=5

# Hook fires: detects live mutation (Tier 3)
# → creates /tmp/kube-cmd-XXXXXX.sh (review script)
# → returns 'ask', blocks execution

# Agent verifies safety first (auto-allowed)
kubectl scale deployment/api --replicas=5 --dry-run=client  # Tier 2: preview

# Agent approves (curl POST approval token)
# Retry original — hook sees approval token, allows
kubectl scale deployment/api --replicas=5  # ✅ now allowed
```

---

## Measuring Success

✅ **Good signals:**
- Safe operations execute immediately (no confirmation)
- Risky operations ask before executing
- Catastrophic operations never execute
- Hooks provide context (knowledge graphs, approval workflows)

❌ **Bad signals:**
- Too many asks (users ignore / bypass)
- False negatives (risky ops slip through)
- Silent failures (hooks block without reason)
- Slow approval loop (justifies skipping safety)

---

## Related Documentation

- **Claude Code Permissions & Safety Hooks** (Reference) — Full config details
- **Permission Settings Audit (2026-07-07)** — Historical decisions
- **Orchestrate Approval Tokens** — Implementation of approval workflow
- **Scope-Check Patterns** — Python helpers for scoped validation

---

## Version History

| Date | Change |
|------|--------|
| 2026-08-16 | Initial design pattern capture |
