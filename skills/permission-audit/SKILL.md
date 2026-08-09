---
name: permission-audit
description: Audit Claude Code and Cursor permission settings for safety gaps. Scans configuration files (global + project-level) and detects vulnerability classes — secrets exposure, overly-broad globs, parity drift between Claude/Cursor, and hook regression. Emits both JSON (machine-readable) and Markdown (human-readable) reports with baseline regression detection against 2026-07-07 hardening. Run via `permission-audit [--check-all|--scope|--regressions-only|--fail-on]` for offline, fast auditing of all known permission configs.
version: 1.0.0
investigation_model_tier: haiku
---

<!--
Provenance: extracted from the private ai-toolbox repository (https://github.com/AmenZhou/ai-toolbox),
which is not publicly available. Embedded in linecook under this repo's MIT license — see /LICENSE.
Adapted for this repo: personal project paths generalized to a $PROJECT_ROOT variable, and two
checks (V3 parity sub-check 1, V5 frequency analysis) that depended on companion scripts that only
ever existed in a private personal project — never in this skill's own source — were rewritten so
the skill is coherent and honest about what ships here vs. what you'd need to build yourself. See
"Adaptation Notes" below for the specifics.
-->

# permission-audit

Audit Claude Code and Cursor permission settings for safety gaps across global and project-level configurations. Implements four vulnerability class checks (secrets exposure, overly-broad globs, parity drift, hook regression) and produces both JSON and Markdown reports with baseline regression detection.

## Adaptation Notes

This skill was extracted from a personal, private skill collection. Two of its checks originally
depended on companion scripts (`sync-cursor-claude-permissions.sh` for V3, `permission-log-analyzer.py`
for V5) that lived only in that private project's own `scripts/` directory — they were never part of
this skill's own source, so they aren't included in this embed either. Rather than silently drop the
two checks, this version documents what's changed:

- **V3 (parity drift) sub-check 1** — the "run an existing sync script and parse its diff" step is
  now a **documented recipe** instead of a runnable call (see §V3 below): if your project maintains
  parallel Claude Code and Cursor permission configs, write your own small script that diffs their
  `allow`/`deny` lists, and this check folds that diff in. Sub-check 2 (global `ask` → Cursor `deny`
  mapping) is unaffected — it was always fully self-contained logic, no external script involved.
- **V5 (frequency & consolidation)** — the algorithm is documented in full below so you can implement
  it yourself if you want the feature; `bin/permission-audit.sh --frequency-report` looks for a
  `permission-log-analyzer.py` under `$PROJECT_ROOT/scripts/` and, if it isn't there, prints a pointer
  back to this section and exits cleanly (informational skip, not an error) rather than failing.
- **V1, V2, V4, and the baseline-regression checks** are fully self-contained bash logic with **no**
  external script dependency — these work as shipped, once you point `bin/permission-audit.sh` at
  your own project root (see Invocation below).

**Key features:**
- Scans global (`~/.claude/`, `~/.cursor/`) and all project-level permission files dynamically
- Detects 5 vulnerability/friction classes (V1–V5) per the design plan
- **V5 (NEW):** Frequency & consolidation analysis — reads Claude Code JSONL permission logs, identifies high-frequency patterns, generates scoped allow-rule recommendations (bring-your-own analyzer — see Adaptation Notes above)
- Checks 8 baseline regressions from 2026-07-07 hardening
- Outputs both machine-readable JSON and human-readable Markdown in one run
- Fast offline operation (~2 seconds for V5, ~10–30 seconds for full V1–V5, no network calls)

## Invocation

```bash
# Point the script at your project root (defaults to the current directory)
export PERMISSION_AUDIT_PROJECT_ROOT=/path/to/your-project

# Full audit (default) — V1 through V5
permission-audit --check-all

# Scope narrowing
permission-audit --scope global
permission-audit --scope project:your-project
permission-audit --scope all-projects

# Regression-only (fast baseline check)
permission-audit --regressions-only

# CI-friendly (exit non-zero on high/critical findings)
permission-audit --check-all --fail-on high

# Project parity debugging
permission-audit --parity-check-only

# V5 frequency/consolidation analysis only (fast, 1–2 seconds — requires your own analyzer, see Adaptation Notes)
permission-audit --frequency-report
permission-audit --frequency-report --window 7d      # 7-day window (default: 30d)
permission-audit --frequency-report --all-projects   # Scan all configured projects
permission-audit --frequency-report --window 90d --all-projects  # Full scan
```

## Implementation Steps

### Step 1 — Validate environment and load configuration

- Verify required files exist (global settings + hooks)
- Load JSON for each found settings file (gracefully skip missing optional files)
- Parse all `{allow, deny, ask}` arrays from Claude settings
- Parse `{allow, deny}` arrays from Cursor settings
- Record file paths and timestamps for later reporting

### Step 2 — Enumerate all project-level settings files

Run discovery queries to find all `.claude/settings.json`, `.claude/settings.local.json`, and `.cursor/cli.json` files under your own projects root:

```bash
find <your-projects-root> -maxdepth 2 -type f \
  \( -name "settings.json" -o -name "settings.local.json" \) -path "*/.claude/*"
find <your-projects-root> -maxdepth 2 -type f -name "cli.json" -path "*/.cursor/*"
find <your-projects-root> -maxdepth 2 -type d -name "hooks" -path "*/.claude/*"
```

Partition results into:
- **Global:** `~/.claude/settings.json`, `~/.claude/settings.local.json`, `~/.cursor/cli-config.json`
- **Project-level:** all discovered `<project>/.claude/settings.json`, `<project>/.cursor/cli.json`
- **Hooks:** all discovered `.claude/hooks/` directories

### Step 3 — Run vulnerability class checks (V1–V4) & frequency analysis (V5)

Implement each check class per the design plan (§3):

#### V1 — Secrets exposure

For each secrets-glob pattern (`*.env*`, `.ssh/**`, `.pem`, `.key`, `.aws/**`, `.credentials`), confirm a `deny` rule exists covering `Read`, `Write`, and (Claude only) `Edit` operations.

**Detection logic:**
```
For each secrets_glob in SECRETS_PATTERNS:
  For each op in [Read, Write, Edit (Claude only)]:
    Assert exists deny-rule matching "{op}({secrets_glob})"
      or deny-rule matching "{op}(**/{secrets_glob})"
    If missing → emit V1 finding
```

**Severity:** `critical` (direct exposure to credentials)

#### V2 — Overly-broad glob / allow-all

**Patterns to detect:**
1. Project-level `Bash(rm:*)`, `Bash(mv:*)`, `Bash(rmdir:*)` without scope narrowing
2. Cursor `Shell(rm)`, `Shell(mv)` with no Claude-side hook enforcement
3. Malformed patterns like `Bash(node -e ' *)` (arbitrary code execution with no prompt)
4. Missing critical `deny` rules for dangerous commands (kubectl scale, git push -f, etc.)

**Detection logic:**
```
If file is project-level settings.json:
  For each [rm, mv, rmdir] in dangerous_ops:
    If allow-list contains "{op}:*" or "{op} *" (unscoped)
      AND does NOT match allowed scopes (*.bak-*, tmp-*, .orchestrate/tmp/*)
      → emit V2 finding "unscoped {op}"

For kubectl/git/npm/launchctl/pipe-to-shell commands:
  If allow-list contains the command AND deny-list does NOT
    → emit V2 finding
```

**Severity:** `high` (destructive operation without confirmation)

#### V3 — Parity drift (Claude ↔ Cursor)

**Two sub-checks:**

1. **Project parity:** if your project maintains a script that diffs its `.claude/settings.json`
   against its `.cursor/cli.json` (see Adaptation Notes above — this repo doesn't ship one), run it
   with a `--check` flag and parse its output for mismatches. If you don't have one yet, this
   sub-check is aspirational until you write it — treat it as documentation of what to build, not a
   runnable step.
2. **Global-layer drift:** For each `ask` rule in `~/.claude/settings.json`, verify a corresponding `deny` in `~/.cursor/cli-config.json` (Claude `ask` must map to Cursor `deny`)

**Detection logic:**
```
# Project parity (bring-your-own diff script — see Adaptation Notes)
If your-parity-script --check reports mismatch
  → emit V3 finding "parity drift: [cmd] missing from Cursor"

# Global layer
For each ask-rule in ~/.claude/settings.json:
  If NOT found in ~/.cursor/cli-config.json deny-list
    → emit V3 finding "Claude ask lacks Cursor deny"
```

**Severity:** `medium` (permissions granted differently between tools)

#### V4 — Hook/soft-gate regression

Verify that hooks referenced in `settings.json` `hooks.PreToolUse` exist, are executable, and implement expected functions.

**Detection logic:**
```
For each hook file referenced in hooks.PreToolUse:
  If file does NOT exist → emit V4 finding
  If file NOT executable → emit V4 finding
  If hook is restrict-paths.sh:
    If check_rm_mv_scope() function missing → emit V4 finding
    If rm-mv-scope-check.py missing/not executable → emit V4 finding
  If hook is chmod-scope-check.py/redirect-scope-check.py/search-scope-check.py:
    If file missing/not executable → emit V4 finding
```

**Severity:** `high` (scope-narrowing enforcement missing)

#### V5 — Permission log frequency & consolidation (bring-your-own analyzer — see Adaptation Notes)

Analyze Claude Code JSONL permission event logs to identify high-frequency approval/denial patterns and recommend scoped allow-rule consolidations. This section documents the intended algorithm; this repo does not ship the reference `permission-log-analyzer.py` implementation (see Adaptation Notes above) — implement it yourself against the contract below, or treat V5 as optional/aspirational until you do.

**Detection logic:**
```
For each Claude Code JSONL session transcript (~/.claude/projects/*/*.jsonl):
  Stream-parse JSONL line-by-line
  For each tool_use followed by tool_result (with/without toolDenialKind):
    Extract: tool_name, normalized signature, outcome (denied:*, proceeded:*)
  For each hook_success attachment: mark tool_use_id as "hook auto-decided"

Aggregate events by normalized signature:
  - Count occurrences per signature
  - Count distinct sessions per signature
  - Tally outcome breakdown (permission-rule, user-rejected, automode-blocked, etc.)

Filter to consolidation candidates:
  - Require ≥5 occurrences AND ≥2 distinct sessions (guards against false positives)
  - Exclude: any signature with ≥1 user-rejected outcome (hard veto)
  - Exclude: automode-blocked/automode-unavailable events (Claude classifier, not settings gap)
  - Exclude: hook_auto_decided events (already handled, no friction)

Recommend scoped allow rules:
  - Generate narrowest-matching pattern (e.g., "Bash(grep -n)", not "Bash(*)")
  - Cross-check against existing V2 rules (never recommend an unscoped rm/mv)
  - Output: signature, count, sessions, recommendation, estimated prompt reduction
```

**Output:** JSON + Markdown reports with top-20 consolidation opportunities per window (7d/30d/90d/all). Example:

```json
{
  "id": "V5-001",
  "class": "V5",
  "signature": "Read: /path/to/your-project/.orchestrate/tasks/*.md",
  "count": 1020,
  "distinct_sessions": 283,
  "window_days": 30,
  "outcome_breakdown": {"proceeded:ambiguous": 1020},
  "recommendation": "Read(/path/to/your-project/.orchestrate/tasks/*.md)",
  "estimated_prompt_reduction": 1020
}
```

**Invocation:** `permission-log-analyzer.py --window 30d [--all-projects] [--output-dir <path>]` — your own implementation, expected at `$PROJECT_ROOT/scripts/permission-log-analyzer.py` (see Adaptation Notes)

**Severity:** informational (no security gap; friction/workflow optimization finding)

### Step 4 — Check against 8 baselines from 2026-07-07 hardening

Run a fixed checklist of 8 baseline assertions (hardcoded per the design plan §4) — adjust the
project-specific ones (#2, #3, #8) to your own project's conventions:

| # | Baseline | Regression signature |
|---|----------|---------------------|
| 1 | `~/.claude/settings.json` global deny covers `.env*`, `.aws/**`, `.credentials` for Read+Write+**Edit** | any missing |
| 2 | project `.claude/settings.json` does NOT have unscoped `Bash(rm:*)`, `Bash(mv:*)`, `Bash(rmdir:*)` | any unscoped variant present |
| 3 | project `.claude/settings.json` DOES have scoped replacements: `Bash(rm *.bak-*)`, `Bash(rm tmp-*)`, `Bash(rm .orchestrate/tmp/*)`, `Bash(rmdir .orchestrate/tmp/*)`, `Bash(mv *.bak-* *)`, `Bash(mv tmp-* *)` | any missing |
| 4 | `restrict-paths.sh` has `check_rm_mv_scope()` registered on Bash PreToolUse matcher | function/registration missing |
| 5 | Global deny does NOT have shadowed/dead `Read` rules in project allow | entry present in project allow |
| 6 | `gh pr create *` / `gh release create *` on `ask`, not `deny`; `gh pr merge *` hard `deny` | any in wrong tier |
| 7 | `~/.cursor/cli-config.json` has +26 hardening rules from 2026-08-01 (launchctl, pipe-to-shell, disk redirects, find -delete, git push -f, `.aws`/`.credentials`) | any subset missing |
| 8 | your project-parity script's template + guard list include the tools/rules your own stack needs | any missing from template — not applicable without your own parity script (see Adaptation Notes) |

**Output:** "Baseline regressions" section in report with pass/fail for each check.

### Step 5 — Generate JSON report

Emit findings in the schema defined by the design plan (§6):

```json
{
  "run_at": "2026-08-05T12:34:56Z",
  "scope": "all",
  "files_scanned": [
    "~/.claude/settings.json",
    "~/.claude/settings.local.json",
    "~/.cursor/cli-config.json",
    "/path/to/your-project/.claude/settings.json",
    "/path/to/your-project/.cursor/cli.json",
    ...
  ],
  "findings": [
    {
      "id": "V1-001",
      "class": "V1",
      "severity": "critical",
      "file": "~/.claude/settings.json",
      "field": "permissions.deny[]",
      "value": "Read(**/.env*)",
      "message": "Secrets exposure — .env files not denied for Read",
      "fix": "Add 'Read(**/.env*)' to global deny list"
    },
    ...
  ],
  "summary": {
    "V1": 0,
    "V2": 1,
    "V3": 2,
    "V4": 0,
    "regressions": 0,
    "total_findings": 3
  }
}
```

Write to `reports/permission-audit/<timestamp>_audit.json`.

### Step 6 — Generate Markdown summary report

Emit human-readable report with:
1. Header: timestamp, scope, projects scanned count
2. Summary table: V1–V4 counts, regression count, risk level
3. One section per class (V1–V4), findings sorted by severity descending
4. Baseline regressions pass/fail table
5. Known limitations / out-of-scope footer

Example structure:
```markdown
# Permission Audit Report

**Run:** 2026-08-05 12:34:56 UTC  
**Scope:** all (global + 15 projects)  
**Files scanned:** 18

## Summary

| Class | Count | Severity | Status |
|-------|-------|----------|--------|
| V1    | 0     | critical | PASS   |
| V2    | 1     | high     | FAIL   |
| V3    | 2     | medium   | FAIL   |
| V4    | 0     | high     | PASS   |
| **Regressions** | 0 | - | PASS |

**Risk Level:** MEDIUM (1 high + 2 medium findings)

## V2 — Overly-Broad Globs

### [HIGH] Unscoped rm allow in project-foo/.claude/settings.json
- **File:** project-foo/.claude/settings.json
- **Pattern:** Bash(rm:*)
- **Issue:** Unscoped rm allow allows deletion of any file
- **Baseline ref:** #2 (2026-07-07)
- **Fix:** Replace with scoped patterns: Bash(rm *.bak-*), Bash(rm tmp-*), etc.

...

## Baseline Regressions

| # | Baseline | Result | Status |
|---|----------|--------|--------|
| 1 | Global deny has .env*, .aws/**, .credentials | PASS | ✓ |
| 2 | project no unscoped rm/mv/rmdir | PASS | ✓ |
| 3 | project has scoped rm/mv/rmdir | PASS | ✓ |
| 4 | restrict-paths.sh wired correctly | PASS | ✓ |
| 5 | No shadowed deny rules | PASS | ✓ |
| 6 | gh pr commands in correct tiers | PASS | ✓ |
| 7 | Cursor +26 hardening rules present | PASS | ✓ |
| 8 | project-parity script template complete | FAIL | ✗ |

**Overall:** 7/8 baselines passing. See V3 section for baseline #8 details.

## Known Limitations

- MCP approvals (mcp.json, mcp-approvals.json) not audited
- Prose rules (CLAUDE.md, .cursorrules) not linted
- Project-level Claude↔Cursor parity requires your own diff script (see Adaptation Notes)
- Cursor has no structured permission-event log; V5 Cursor signal would be keyword-scan best-effort only (not yet implemented; excluded from V5 MVP)
```

Write to `reports/permission-audit/<timestamp>_audit.md`.

### Step 7 — Update latest_audit symlinks

After generating both reports, create/update symlinks:
```bash
ln -sf $(basename <timestamp>_audit.json) reports/permission-audit/latest_audit.json
ln -sf $(basename <timestamp>_audit.md) reports/permission-audit/latest_audit.md
```

### Step 8 — Return exit code and summary

Exit with:
- **0** if no critical/high findings and no regressions (clean)
- **1** if `--fail-on high` and findings ≥ requested level exist
- **2** if any regressions detected
- **1** for other errors (malformed JSON, missing required files, etc.)

Print summary to stdout:
```
Permission audit complete.
Findings: V1={n}, V2={n}, V3={n}, V4={n}, Regressions={n}
Risk level: {low|medium|high|critical}
Reports: {reports/permission-audit/<timestamp>_audit.json|md}
```

## Implementation Notes

- **Project parity check is bring-your-own:** this repo doesn't ship a script that diffs Claude vs.
  Cursor project settings (see Adaptation Notes above) — if you have one, invoke it (subprocess) and
  fold its diff into V3 findings rather than reimplementing the field mapping
- **Global-layer parity logic is self-contained:** No existing script audits global `~/.claude/settings.json` ask → `~/.cursor/cli-config.json` deny mapping; implement this in the audit script
- **Project enumeration is dynamic:** Use `find` to discover projects at runtime, not a hardcoded list
- **Do not re-derive baselines:** The 8 baseline checks (§4) are hardcoded; they do not parse the memory file at runtime (staleness risk, unnecessary I/O)
- **Hooks validation must read files:** Confirm hook files exist and are executable; check for specific function/pattern presence where applicable
