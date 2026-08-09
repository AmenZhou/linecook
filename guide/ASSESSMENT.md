# Claude Code Setup — Assessment & Gap Finding Guide

**Self-assessment tool:** Evaluate your local Claude Code setup across 4 pillars and identify gaps before they cause problems.

Use this guide to:
- 🎯 **Audit** your current setup against best practices
- 🔍 **Find** missing pieces (security, skills, context, quality gates)
- 🛠️ **Decide** what gaps to fix first (prioritized recommendations)
- 📋 **Track** what you've implemented vs. what's missing

---

## How to Use This Guide

**Time:** 15–30 minutes for a full audit

**Process:**
1. Go through each pillar section (Security, Orchestration, LLM Context, Quality)
2. Check off what you have; note what's missing
3. At the end, see "Gap Priority Matrix" to decide what to fix first
4. Reference "Filling Gaps" section for how to implement missing pieces

---

## PILLAR 1: Security (Deny-List + Hooks)

### ✅ Security Checklist

- [ ] `~/.claude/settings.json` exists and has permission definitions
- [ ] Global settings include deny patterns: `.env*`, `.aws/**`, `.credentials`
- [ ] Project `.claude/settings.json` exists for your primary project
- [ ] Destructive ops (`rm`, `mv`, `rmdir`) are scoped, not blanket-allowed
- [ ] PreToolUse hooks configured for kubectl operations
- [ ] Secrets in `.env`, `.aws/config`, `.git-crypt` are in deny-list
- [ ] K8s mutations require review script (`kube-pretooluse.sh` hook installed)
- [ ] Force-push to main is explicitly forbidden

### 🔍 Find Security Gaps

**Check 1: Permission settings file**
```bash
# Does it exist?
cat ~/.claude/settings.json | grep -A 5 "permissions"

# Should show: allow list + deny patterns
# Missing? Create one with deny-list approach
```

**Check 2: Scoped destructive operations**
```bash
# Check if rm is blanket-allowed (BAD) or scoped (GOOD)
grep "rm:" ~/.claude/settings.json
# Good: "rm:*.bak-*,*.tmp-*"
# Bad: "rm:*"
```

**Check 3: Secrets in deny-list**
```bash
grep -E "(env|aws|credentials|git-crypt)" ~/.claude/settings.json
# Should show these patterns denied
```

**Check 4: K8s hooks**
```bash
# Do you have kube-pretooluse.sh?
ls ~/.claude/hooks/ | grep kube
# If missing, K8s mutations won't be reviewed
```

### 📊 Security Gap Severity

| Gap | Impact | Fix Time |
|-----|--------|----------|
| No settings.json | Unlimited access, high risk of accidents | 10 min |
| Blanket `rm` allowed | Can accidentally delete tracked files | 5 min |
| No K8s hook | Can accidentally scale/patch live clusters | 15 min |
| Secrets not in deny-list | Could commit `.env` files | 5 min |
| No PreToolUse hooks | No dynamic safeguards | 20 min |

---

## PILLAR 2: Orchestration (Task-Breakdown + Task-Orchestrate)

### ✅ Orchestration Checklist

- [ ] `/task-breakdown` skill installed and callable
- [ ] `/task-orchestrate` skill installed and callable
- [ ] `.orchestrate/project.md` exists in your primary project
- [ ] `.orchestrate/inbox/` directory exists for task staging
- [ ] `.orchestrate/tasks/` directory exists for task files
- [ ] Can run `/orch resume` and see a task registry
- [ ] Sample task has been executed end-to-end
- [ ] Task files are being archived to `orchestrate-history/`
- [ ] Can invoke `/grill-me` for plan pressure-testing

### 🔍 Find Orchestration Gaps

**Check 1: Skills installed**
```bash
# Try invoking each skill
/task-breakdown --help 2>&1 | head -1
/task-orchestrate --help 2>&1 | head -1

# Should print skill name, not "not found"
```

**Check 2: Project control plane**
```bash
# Does the control plane exist?
cat PROJECT_ROOT/.orchestrate/project.md | head -15

# Should show: Task Registry with ≥1 row
```

**Check 3: Task registry structure**
```bash
# Can you see tasks?
/orch resume
# Should list active/pending/completed tasks
```

**Check 4: Archive & history**
```bash
# Are completed tasks being archived?
ls -la orchestrate-history/ | head -5
wc -l orchestrate-history/MANIFEST.md

# Should show: archived tasks + manifest entries
```

### 📊 Orchestration Gap Severity

| Gap | Impact | Fix Time |
|-----|--------|----------|
| Skills not installed | Can't plan/execute tasks | 10 min |
| No `.orchestrate/` structure | Tasks have no control plane | 15 min |
| Registry not updating | Can't track task progress | 10 min |
| No archive/history | Lost visibility into completed work | 5 min |
| `/grill-me` not installed | Can't pressure-test plans | 5 min |

---

## PILLAR 3: LLM Context (Wiki-First Protocol)

### ✅ LLM Context Checklist

- [ ] Obsidian wiki vault exists at `obsidian/`
- [ ] `index.md` exists and links to major pages
- [ ] `log.md` tracks recent activity with CAPTURE entries
- [ ] `hot.md` summarizes current initiatives (updated regularly)
- [ ] Core concept pages exist (architecture, patterns, decisions)
- [ ] `/wiki-ingest` or `/orchestrate-daily-wiki-ingest` is runnable
- [ ] Wiki pages have frontmatter (title, tags, sources, confidence)
- [ ] Cross-links between related pages work
- [ ] Can run `/wiki-context-pack` to pull relevant context
- [ ] Decision Log exists at `obsidian/decisions/`

### 🔍 Find LLM Context Gaps

**Check 1: Wiki structure**
```bash
# Does the vault exist?
ls -la obsidian/ | head -10

# Should show: index.md, log.md, hot.md, Core/, and other category dirs
```

**Check 2: Index & navigation**
```bash
# Is index.md maintained?
head -30 obsidian/index.md

# Should list major pages, with updated timestamp
```

**Check 3: Recent activity log**
```bash
# Is log.md tracking work?
tail -20 obsidian/log.md

# Should show recent INGEST/CAPTURE/task completion entries
```

**Check 4: Decision Log exists**
```bash
# Do you have architectural decisions documented?
ls obsidian/decisions/ | wc -l

# Should show ≥1 decision page (ideally 5+)
```

**Check 5: Page frontmatter**
```bash
# Do pages have proper frontmatter?
head -15 obsidian/Core/some-page.md

# Should show: title, tags, sources, base_confidence, lifecycle
```

### 📊 LLM Context Gap Severity

| Gap | Impact | Fix Time |
|-----|--------|----------|
| No wiki vault | No context available to agents | 20 min |
| index.md missing | Navigation broken; context fragmented | 15 min |
| log.md stale (>1 week old) | Lost visibility into recent work | 10 min |
| No decision log | Have to re-litigate decisions repeatedly | 30 min |
| Pages lack frontmatter | Can't filter/search; low confidence signal | 20 min |
| `/wiki-ingest` not runnable | History not captured; manual-only work | 25 min |

---

## PILLAR 4: Quality Gates (Investigation + Code Review)

### ✅ Quality Checklist

- [ ] `/grounded-investigate` skill installed and callable
- [ ] Can run `grounded-investigate` on a sample question
- [ ] `/code-review ultra` is available (or equivalent review process)
- [ ] Test suite exists for your primary project
- [ ] Pre-commit hooks configured for linting/type-checking
- [ ] `make test` or `npm test` or equivalent runs tests
- [ ] Failed tests are blocking (not ignored)
- [ ] Code review step is part of completion process
- [ ] Acceptance criteria are measurable (not vague)
- [ ] Verification phase independently checks results

### 🔍 Find Quality Gaps

**Check 1: Investigation skill**
```bash
# Can you run an investigation?
/grounded-investigate "what are the main components of this setup?" 2>&1 | head -5

# Should return structured findings, not "not found"
```

**Check 2: Code review process**
```bash
# Is code review wired up?
# Try /code-review ultra on a branch
# or check if task-orchestrate's Completion §6b-direct is active

grep -n "§6b-direct\|Review:" ~/.claude/skills/task-orchestrate/SKILL.md | head -3

# Should show review mechanism is in place
```

**Check 3: Test suite**
```bash
# Do tests exist?
# For project at PROJECT_ROOT:
find PROJECT_ROOT -name "test*.sh" -o -name "*.test.js" -o -name "test_*.py" | wc -l

# Should show ≥1 test file
```

**Check 4: Pre-commit hooks**
```bash
# Are pre-commit hooks configured?
cat PROJECT_ROOT/.git/hooks/pre-commit 2>/dev/null | head -5

# Should show linting/type-check commands
```

**Check 5: Acceptance criteria measurability**
```bash
# Sample task: check if ACs are measurable
cat orchestrate-history/some-task.md | grep -A 5 "acceptance_criteria"

# Good: "✓ test suite passes 100/100"
# Bad: "✓ it works"
```

### 📊 Quality Gap Severity

| Gap | Impact | Fix Time |
|-----|--------|----------|
| No investigation skill | Can't research root causes | 10 min |
| No code review process | Low-quality changes merge untested | 20 min |
| No test suite | Can't verify changes work | 30 min |
| Pre-commit hooks missing | Broken code lands in git | 15 min |
| Vague acceptance criteria | Can't tell when task is done | 25 min |
| No verification phase | Changes not independently checked | 10 min |

---

## Gap Priority Matrix

**Use this to decide what to fix first.**

### 🚨 CRITICAL (Fix immediately)

- [ ] No security settings → Create `.claude/settings.json` with deny-list
- [ ] Blanket `rm` allowed → Scope to `rm:*.bak-*,*.tmp-*`
- [ ] No K8s hooks → Install `kube-pretooluse.sh`
- [ ] Skills not installed → Run skill installation/sync
- [ ] No test suite → Create `test.sh` or `test.js`
- [ ] Pre-commit hooks absent → Wire linting/type-check

### ⚠️ HIGH (Fix this week)

- [ ] No `.orchestrate/` structure → Create control plane
- [ ] Wiki vault missing → Create `obsidian/` with `index.md`, `log.md`
- [ ] No code review process → Wire §6b-direct or `/code-review ultra`
- [ ] Acceptance criteria are vague → Make them measurable
- [ ] No verification phase → Add independent checks

### 💡 MEDIUM (Fix this month)

- [ ] index.md stale (>1 month old) → Update MOC
- [ ] No decision log → Create `obsidian/decisions/`
- [ ] Pages lack frontmatter → Standardize metadata
- [ ] `/wiki-ingest` not running → Set up daily sync

### 📋 LOW (Nice-to-have)

- [ ] `hot.md` not maintained → Start tracking initiatives
- [ ] No cross-links between pages → Wire relationships
- [ ] Metrics sink not running → Set up performance tracking
- [ ] No `/grill-me` setup → Wire plan pressure-testing

---

## Filling Gaps: Implementation Guide

### Security Gaps

**Gap: No `~/.claude/settings.json`**
```bash
# Create with deny-list approach
mkdir -p ~/.claude
cat > ~/.claude/settings.json << 'EOF'
{
  "permissions": {
    "allow": ["read", "edit", "write", "bash:find", "bash:grep"],
    "deny": [".env*", ".aws/**", ".credentials", "rm -rf", "kubectl apply"]
  }
}
EOF
```

**Gap: Blanket `rm` allowed**
```bash
# Update settings to scope rm
# Change: "deny": ["rm -rf"]
# To: "deny": ["rm:*"]  + allow specific patterns elsewhere
```

### Orchestration Gaps

**Gap: No `.orchestrate/` structure**
```bash
# Create control plane
mkdir -p .orchestrate/{inbox,tasks,logs}

cat > .orchestrate/project.md << 'EOF'
# Orchestrate — $(basename $(pwd))
last_updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

## Shared Context
(durable project knowledge here)

## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
EOF
```

**Gap: Skills not installed**
```bash
# For Claude Code CLI:
claude sync-skills  # or run sync.sh in ai-toolbox

# Verify:
/task-breakdown --help
/task-orchestrate --help
```

### LLM Context Gaps

**Gap: No wiki vault**
```bash
# Create vault structure
mkdir -p obsidian/{Core,concepts,decisions}

cat > obsidian/index.md << 'EOF'
# Index — Project MOC

## Core
- [[Core/Setup]]
- [[Core/Architecture]]

## Decisions
- [[decisions/000 Decision Log]]
EOF

cat > obsidian/log.md << 'EOF'
# Activity Log
- [$(date -u +%Y-%m-%d)] PROJECT CREATED
EOF
```

**Gap: No Decision Log**
```bash
# Create decision tracking
mkdir -p obsidian/decisions

cat > obsidian/decisions/000\ Decision\ Log.md << 'EOF'
# Decision Log

Master index of architectural decisions.

## Structure
- Problem
- Options
- Decision
- Rationale
- Related decisions
EOF
```

### Quality Gaps

**Gap: No test suite**
```bash
# Create minimal test harness
cat > test.sh << 'EOF'
#!/usr/bin/env bash
set -e

echo "Running tests..."
# Add test commands here
echo "✓ All tests passed"
EOF

chmod +x test.sh
```

**Gap: No pre-commit hooks**
```bash
# Create pre-commit hook
cat > .git/hooks/pre-commit << 'EOF'
#!/usr/bin/env bash
set -e

# Lint check
if command -v eslint &> /dev/null; then
  eslint .
fi

# Type check (if TypeScript)
if [ -f tsconfig.json ]; then
  npx tsc --noEmit
fi

echo "✓ Pre-commit checks passed"
EOF

chmod +x .git/hooks/pre-commit
```

---

## Assessment Scorecard

**Use this to track your overall setup maturity.**

```
Security Pillar
  ✓ Settings & deny-list:     [_______] 0–100%
  ✓ Hooks & safeguards:       [_______] 0–100%
  ✓ Secrets protected:        [_______] 0–100%
  TOTAL SECURITY:             [_______] 0–100%

Orchestration Pillar
  ✓ Skills installed:         [_______] 0–100%
  ✓ Control plane:            [_______] 0–100%
  ✓ Task registry:            [_______] 0–100%
  ✓ Archive & history:        [_______] 0–100%
  TOTAL ORCHESTRATION:        [_______] 0–100%

LLM Context Pillar
  ✓ Wiki vault:               [_______] 0–100%
  ✓ Index & navigation:       [_______] 0–100%
  ✓ Activity log:             [_______] 0–100%
  ✓ Decision log:             [_______] 0–100%
  TOTAL LLM CONTEXT:          [_______] 0–100%

Quality Pillar
  ✓ Investigation skill:      [_______] 0–100%
  ✓ Code review:              [_______] 0–100%
  ✓ Test suite:               [_______] 0–100%
  ✓ Pre-commit hooks:         [_______] 0–100%
  ✓ Verification phase:       [_______] 0–100%
  TOTAL QUALITY:              [_______] 0–100%

OVERALL SETUP MATURITY:       [_______] 0–100%
```

**Targets:**
- 🟢 **80–100%:** Mature, well-defended setup
- 🟡 **60–80%:** Functional; some gaps present
- 🔴 **40–60%:** Needs work; critical gaps exist
- ⚫ **0–40%:** Minimal setup; many gaps

---

## Next Steps

1. **Run this assessment** on your setup (15–30 min)
2. **Identify 3–5 critical gaps** from the CRITICAL + HIGH sections
3. **Implement gaps** using the "Filling Gaps" guide above
4. **Re-assess** after 1–2 weeks
5. **Link this assessment** to your project README so future contributors can self-audit

---

**Questions?** See the pillar reference docs in `guide/pillars/` for detailed explanations of each pillar.
