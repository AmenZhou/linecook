---
name: smart-code-review
description: Ticket-aware code review. Fetches associated ticket/requirements (Linear, GitHub issue, PR description) and validates implementation against them. Falls back to a structured branch summary when no ticket is found. Runs an OWASP Top 10 security pass and a standard BUG/FIX/AUTO/CONSIDER code review pass, then posts the kept findings as inline review comments on the detected PR/MR (GitHub `gh` / GitLab `glab`) — or documents them in a local review doc when there is no PR/MR.
version: 1.3.0
inline: true
---

<!--
Provenance: extracted from the private ai-toolbox repository (https://github.com/AmenZhou/ai-toolbox),
which is not publicly available. Embedded in linecook under this repo's MIT license — see /LICENSE.
Adapted for this repo: the 3 references to a specific self-managed GitLab host were replaced with a
neutral placeholder — the detection logic itself was already host-agnostic (computed dynamically
from `git remote get-url origin`), so this is a cosmetic scrub only. Also restructured from a flat
`smart-code-review.md` file into this `smart-code-review/SKILL.md` directory layout so it matches
Claude Code's `<name>/SKILL.md` discovery convention directly — no symlink workaround needed.
-->

# Smart Code Review

Ticket-aware code review. Validates implementation against requirements when a ticket exists; summarizes the branch for manual verification when it doesn't. Always ends with a standard quality review pass.

---

## Phase 0 — Detect Ticket Context

Run these in parallel:

**A. Parse branch name**
```bash
git branch --show-current
```
Match against:
- `[A-Z]+-\d+` — Linear/Jira style (e.g. `INFRA-1`, `DSP-42`)
- `[a-z]+-\d+-` prefix slug (e.g. `infra-1-research-uat-infra` → `INFRA-1`)

**B. Check for an open PR/MR** (platform-aware, per R-1's origin-remote rule)

First detect the forge from the origin remote host:
```bash
origin_host=$(git remote get-url origin 2>/dev/null \
  | sed -E 's#^(https?://|git@)([^/:]+).*#\2#')

case "$origin_host" in
  github.com|*.github.com)  platform=github ;;   # use gh
  gitlab.com|gitlab.*)      platform=gitlab ;;   # use glab  (covers a self-managed GitLab host)
  *)                        platform=local  ;;   # no PR/MR host -> local-doc fallback (Phase 4)
esac
echo "$platform"
```

Then look up the open PR/MR for the current branch on that platform:
```bash
# GitHub:
gh pr view --json title,body,url 2>/dev/null
# GitLab (covers self-managed GitLab instances):
glab mr view --output json 2>/dev/null | jq '{title, body: .description, url: .web_url}'
```
(`gh`/`glab` live at `/opt/homebrew/bin` — `export PATH="/opt/homebrew/bin:$PATH"` if it's not already on PATH.)

Scan the PR/MR body for:
- Linear URLs: `linear.app/*/issue/*` or `linear.app/*/issues/*`
- GitHub issue refs: `#\d+` or `github.com/.*/issues/\d+`
- Explicit requirement sections: `## Requirements`, `## Acceptance Criteria`, `## AC`

Record `platform` and the PR/MR number/url — Phase 4 reuses them to publish findings.

**C. Collect branch diff metadata** (always needed)
```bash
git log main...HEAD --oneline
git diff main...HEAD --stat
```

**Decision:**
- Ticket/requirements found → **Phase 1a** (ticket validation)
- Nothing found → **Phase 1b** (branch summary)

If `gh`/`glab` is unavailable or unauthenticated, skip B (no PR/MR context, `platform=local`) and go straight to Phase 1b.

---

## Phase 1a — Ticket Validation (ticket found)

**Fetch ticket content:**
- Linear URL in PR body → `WebFetch` the Linear issue URL
- GitHub issue ref → `gh issue view <number> --json title,body`
- Requirements block in PR body → use the PR body directly

**Get full diff:**
```bash
git diff main...HEAD
```

**Validate implementation vs. requirements:**

For each requirement / acceptance criterion:
- `✓` — addressed in diff (cite file/line)
- `✗` — not found in diff
- `?` — partially addressed or unclear

Also flag:
- Changes in diff that appear **out of scope** relative to the ticket
- Scope creep, unrelated refactors, or missing pieces

**Output:**
```
## Ticket Validation
Ticket: INFRA-1 — Document UAT infra topology
Source: https://linear.app/...

Requirements check:
  ✓ Topology diagram created — docs/infra_topology.md
  ✓ Phase 2 scaling plan — docs/infra_topology.md#scaling
  ✗ Load balancer config documented — not found in diff
  ? Namespace / resource limits — partially addressed (no limits table)

Out of scope: none detected
```

Then proceed to **Phase 1c**.

---

## Phase 1b — Branch Summary (no ticket found)

Collect and present a structured summary for manual verification:

```bash
git log main...HEAD --oneline          # commit history
git diff main...HEAD --stat            # changed files + line counts
git diff main...HEAD                   # full diff (summarize by area)
```

**Output:**
```
## Branch Summary
Branch: infra-1-research-uat-infra
Base: main | Commits: 4 | Files changed: 6 (+312 / -18)

Commits:
  975fde4 fix(infra): address P0 and P1 review comments
  f3c7ef2 docs(infra): fix issues 1-4 + add phase_a_blockers.md
  cc7a8d7 chore: untrack uat3-ads.yaml (credentials)
  656144f docs(infra): INFRA-1 — document UAT infra topology

Changes by area:
  docs/           infra_topology.md (+280/-10), phase_a_blockers.md (+32)
  .gitignore      uat3-ads.yaml untracked (+2)

Summary:
  - Added UAT infrastructure topology documentation
  - Documented Phase A blockers
  - Removed credentials file from tracking

No ticket found — please verify the above matches your intended scope.
```

Then proceed to **Phase 1c**.

---

## Phase 1c — Documentation & Context Check (always runs)

Verify that the branch includes updates to relevant documentation to preserve context for future developers/AI. This is critical for maintaining the "Command Center" state.

**Checks:**
1. **Changelog:** Check for `CHANGELOG.md`.
2. **Project Status/Index:** Check for files like `INDEX.md`, `PHASE2_PLAN.md`, or ticket-specific files in `tickets/` or `phase2_plan/`.
3. **README/Technical Docs:** Check for `README.md` or files in `docs/`.

**Commands:**
```bash
git diff main...HEAD --name-only | grep -iE "changelog\.md|index\.md|plan\.md|tickets/.*\.md|readme\.md|docs/.*\.md"
```

**Reporting:**
- **Found** → confirm the documentation update is substantial and reflects the code changes (e.g., ticket marked as completed, new feature documented). Report `✓ <filename> updated`.
- **Missing Documentation** → If the change adds features or fixes bugs but NO relevant documentation was updated, report as a `[FIX]` item: `[FIX] Documentation update missing — Ensure INDEX.md, relevant ticket files, or README.md are updated to preserve context.`
- **Missing Changelog** → If `CHANGELOG.md` is missing, report as a `[FIX]` item: `[FIX] CHANGELOG.md not updated — add an entry for this change.`

Do not auto-fix. Adding a changelog or documentation entry requires judgment.

Then proceed to **Phase 2**.

---

## Phase 2 — OWASP Top 10 Security Review (always runs)

Scan all changed files against the OWASP Top 10 (2021). Flag findings as `[SECURITY]` — treated like `[BUG]`: report and wait. Skip categories clearly irrelevant to the diff (e.g. skip A06 if no dependency files changed).

| # | Category | What to look for in the diff |
|---|----------|------------------------------|
| **A01** | Broken Access Control | Missing auth/permission checks on new routes or functions; IDOR patterns (user-supplied IDs used without ownership check); privilege escalation paths; exposed admin endpoints |
| **A02** | Cryptographic Failures | Sensitive data (passwords, tokens, PII) stored or transmitted without encryption; weak algorithms (MD5, SHA1, DES); hardcoded secrets or keys; missing TLS enforcement; insecure random number generation |
| **A03** | Injection | SQL/NoSQL queries built with string concatenation; OS command construction from user input; LDAP/XPath injection; template injection; eval() or exec() on untrusted input |
| **A04** | Insecure Design | Business logic flaws (e.g. rate limits bypassable, price tampering); missing threat model considerations in new flows; trust boundary violations |
| **A05** | Security Misconfiguration | Debug modes, verbose error messages, or stack traces exposed to clients; permissive CORS (`*`); default credentials; unnecessary features enabled; overly broad IAM/RBAC grants in config files |
| **A06** | Vulnerable & Outdated Components | New dependencies added with known CVEs; pinned to outdated major versions; dev dependencies bundled into production |
| **A07** | Auth & Session Failures | Weak password policies; missing brute-force protection; session tokens not invalidated on logout; JWT `alg:none` or weak secrets; remember-me tokens stored insecurely |
| **A08** | Software & Data Integrity | Unsigned or unverified third-party scripts/plugins; deserialization of untrusted data without validation; CI/CD pipeline changes that bypass integrity checks |
| **A09** | Security Logging & Monitoring | Security-relevant events (login, access denied, data export) not logged; logs containing sensitive data (passwords, full card numbers); no alerting on critical failures |
| **A10** | SSRF | User-controlled URLs fetched server-side without allowlist; internal metadata endpoints reachable (e.g. `169.254.169.254`); redirect targets not validated |

**Process:**
1. Read the full diff
2. For each OWASP category, assess whether any changed code introduces or worsens the risk
3. Skip categories with no relevant surface in the diff — note them as `N/A`
4. Assign severity: `critical` (exploitable as-is) · `high` (likely exploitable with moderate effort) · `medium` (requires specific conditions)

**Output format for findings:**
```
[SECURITY][A03][critical] SQL injection — user input concatenated into query — `db/queries.js:42`
[SECURITY][A02][high] JWT secret hardcoded in source — `config/auth.js:8`
```

---

## Phase 3 — Code Quality Review (always runs)

Apply standard review categories to all changed files:

| Category | What | Action |
|----------|------|--------|
| **[BUG]** | Logic errors, data loss, race conditions | Report → wait |
| **[FIX]** | Type gaps, missing error handling, test gaps | Report → wait |
| **[AUTO]** | Unused imports, dead code, console.log, typos | Fix immediately |
| **[CONSIDER]** | Refactors, style opinions, nice-to-have | Mention only |

### AUTO criteria (all must be true)
- Zero risk of breaking behavior
- < 5 seconds to fix
- No judgment call needed

**Process each changed file:**
1. Read the diff for the file
2. Categorize findings
3. Auto-fix `[AUTO]` items immediately
4. Collect `[BUG]`/`[FIX]`/`[CONSIDER]` items

**Standard checks:**
- Can this be simpler? Unnecessary abstraction, over-engineered error handling?
- Dead code, unused exports, commented-out blocks?
- Copy-paste that should be extracted (but avoid premature abstraction)?
- Missing tests for new logic?

---

## Final Output

```
## Security Review (OWASP Top 10)
A01 Broken Access Control:   [SECURITY][critical] <finding> — `file:line`  |  N/A
A02 Cryptographic Failures:  [SECURITY][high] <finding> — `file:line`       |  N/A
A03 Injection:               N/A
A04 Insecure Design:         N/A
A05 Misconfiguration:        [SECURITY][medium] <finding> — `file:line`     |  N/A
A06 Outdated Components:     N/A
A07 Auth Failures:           N/A
A08 Data Integrity:          N/A
A09 Logging & Monitoring:    N/A
A10 SSRF:                    N/A

## Code Review
Total: SECURITY: X | BUG: X | FIX: X | CONSIDER: X  (auto-fixed: Y)

Issues:
1. [SECURITY][A01][critical] <description> — `path/to/file:line`
2. [BUG] <description> — `path/to/file:line`
3. [FIX] <description> — `path/to/file:line`
4. [CONSIDER] <description> — `path/to/file:line`

What to fix?
  a) SECURITY + BUG + FIX [recommended]
  b) SECURITY only
  c) BUG + FIX only
  d) All including CONSIDER
  e) Custom (e.g. "1,3")

I'll assume a) if you don't specify.
```

**STOP. Wait for user selection before applying any SECURITY/BUG/FIX changes.**

---

## Phase 4 — Publish Review (always runs after selection)

After the user answers "What to fix?", **publish the kept findings as inline comments** on the
PR/MR detected in Phase 0 — one comment per finding, anchored at its `file:line`. This does
**not** fix code; it only records the review on the forge (or in a local doc). It is gated on the
fix-selection answer:

- Include exactly the categories the user chose (`a` = SECURITY+BUG+FIX, `b` = SECURITY,
  `c` = BUG+FIX, `d`/all = everything **including CONSIDER**, `e` = the custom subset).
- **Do not post CONSIDER-only items unless option `d`/all was chosen.**

Use the `platform` recorded in Phase 0 (R-1 origin-remote rule). All commands below are the exact
inline-comment commands from R-1's reference doc — no invented flags. `gh`/`glab` are at
`/opt/homebrew/bin` (export PATH if needed).

### 4a — GitHub PR (`platform=github`)

Get the PR number + head SHA, then POST one review comment per kept finding:
```bash
gh pr view --json number,headRefOid,baseRefName,headRefName,url
#   .number      -> <n>
#   .headRefOid  -> <HEAD_SHA> (commit_id; must be the latest commit SHA)
```
```bash
gh api --method POST "repos/{owner}/{repo}/pulls/<n>/comments" \
  -f body="<comment text>" \
  -f commit_id="<HEAD_SHA>" \      # = headRefOid above
  -f path="src/foo.ts" \
  -F line=42 \                     # -F = typed field -> integer
  -f side="RIGHT"                  # RIGHT = new version; LEFT = old
# Multi-line range: add  -F start_line=38 -f start_side="RIGHT"
```
`gh pr review` **cannot** target a line — inline posting always goes through `gh api`.

### 4b — GitLab MR (`platform=gitlab`)

Get project id, iid, and the position SHAs, then POST one positioned discussion per finding:
```bash
glab mr view --output json | jq '{project_id, iid, web_url}'
glab api "projects/:id/merge_requests/<iid>/versions" --hostname <host> \
  | jq '.[0] | {base_sha: .base_commit_sha, head_sha: .head_commit_sha, start_sha: .start_commit_sha}'
```
```bash
glab api --method POST "projects/:id/merge_requests/<iid>/discussions" --hostname <host> \
  -f body="<comment text>" \
  -f position[position_type]=text \
  -f position[base_sha]=<BASE_SHA> \      # from /versions above
  -f position[head_sha]=<HEAD_SHA> \
  -f position[start_sha]=<START_SHA> \
  -f position[new_path]="src/foo.ts" \
  -f position[old_path]="src/foo.ts" \
  -f position[new_line]=42                # line in the new version; use position[old_line] for a deleted line
```
`<host>` is the origin host (e.g. your self-managed GitLab instance's hostname); `glab mr note` cannot target a line, so
positioned comments always go through `glab api`. (GitLab commands are doc-sourced in R-1 — token
was expired at authoring time — and are embedded as-is.)

### 4c — Local-doc fallback (`platform=local`, or posting failed/unauthenticated)

When no PR/MR was detected, **or** a posting call fails (a posting failure is **non-fatal**), write
the kept findings to R-1's shared local-doc schema instead and report the path:
```
.code-review/inline-comments.md            # relative to the repo root being reviewed
```
Create the `.code-review/` dir, then write YAML front-matter for run metadata followed by one fenced
`yaml` block per finding, keyed by a stable `id: f-NNNN`:
````markdown
---
schema: code-review-inline/v1
platform: local
repo: <repo root path>
commit: <git rev-parse HEAD>
generated_at: <ISO-8601 UTC>
---

# Inline review findings

```yaml
id: f-0001                     # stable id: f-<4 digits>, never reused within a run
file: src/foo.ts               # path relative to repo root
line: 42                       # 1-based line in the working tree at `commit`
severity: bug                  # bug | security | perf | style | nit
body: |
  Off-by-one: loop should stop at `len - 1`, this reads past the slice end.
status: open                   # open | resolved | wontfix
reply:                         # filled by /address-code-review / human; empty until then
```
````
This file is consumable by `/address-code-review` (re-finds each finding by its stable `id`).

### Reporting

Report what was published:
```
## Publish Review
Platform: github | Posted 3 inline comments to PR #42  (https://github.com/.../pull/42)
  ✓ [SECURITY][A01] auth check missing — src/routes.ts:88
  ✓ [BUG] off-by-one — src/foo.ts:42
  ✓ [FIX] missing error handling — src/api.ts:17
Skipped (CONSIDER, not selected): 1
```
or, on the local-doc path:
```
## Publish Review
No PR/MR detected (platform=local) — wrote 3 findings to .code-review/inline-comments.md
```

---

## Error Handling

| Situation | Response |
|-----------|----------|
| `gh`/`glab` not installed / unauthenticated | Skip PR/MR lookup (`platform=local`), proceed to Phase 1b; Phase 4 writes the local doc |
| Inline post fails (Phase 4: 401/403/422, missing PR/MR) | Non-fatal — fall back to writing `.code-review/inline-comments.md` and report that path |
| Linear URL requires login | Note "Linear requires auth — paste ticket text to validate" |
| No commits ahead of main | "Branch is up to date with main — nothing to review" |
| Binary or generated files | Skip, note in summary |
| Large diff (> 500 lines) | Process in batches by file area |
