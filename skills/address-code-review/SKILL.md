---
name: address-code-review
description: Address outstanding code-review feedback on a branch end-to-end. Pulls inline review comments from the open PR (GitHub `gh`) / MR (GitLab `glab`) — or the local review doc smart-code-review writes when there is no PR/MR — then validates each comment (valid / already-done / out-of-scope / wontfix), makes the actual code changes for the valid ones, and replies to each inline thread stating how it was resolved or why it was declined. Triggers on `/address-code-review`, "address review comments", "resolve PR comments", "respond to MR feedback", "work the review feedback", "reply to the review threads".
version: 1.0.0
inline: true
---

<!--
Provenance: extracted from the private ai-toolbox repository (https://github.com/AmenZhou/ai-toolbox),
which is not publicly available. Embedded in linecook under this repo's MIT license — see /LICENSE.
Adapted for this repo: the 3 references to a specific self-managed GitLab host were replaced with
neutral phrasing — the detection logic itself was already host-agnostic (computed dynamically from
`git remote get-url origin`), so this is a cosmetic scrub only. Also restructured from a flat
`address-code-review.md` file into this `address-code-review/SKILL.md` directory layout so it matches
Claude Code's `<name>/SKILL.md` discovery convention directly — no symlink workaround needed.
-->

# Address Code Review

Take a branch with outstanding code-review feedback and work it to done: **pull** the inline
comments, **validate** each one, **address** the valid ones in code, and **reply** to every thread.
This is the consumer side of `smart-code-review` (SCR-1) — it reuses the same R-1 command
reference and the same local-doc schema so the two skills stay consistent.

> **Tooling:** `gh` / `glab` / `jq` only — no third-party libraries. `gh`/`glab` live at
> `/opt/homebrew/bin` (`export PATH="/opt/homebrew/bin:$PATH"` if not already on PATH).
>
> **Safety defaults (per the user's global rules):**
> - Phase 3 makes **only** the change a finding calls for — no scope creep, no premature
>   abstraction, no extra error handling/validation beyond what was asked.
> - **Ask before any destructive operation** (`rm`/`mv`, overwriting an unrelated file,
>   force-push, rebase) — never do it silently.
> - **Default behavior is reply-only:** do **not** resolve threads, and do **not**
>   force-push/rebase. Resolving a thread is a separate explicit step, only if the user asks.
> - Phase 2's verdict is shown to the user **before** Phase 3 edits — never silently apply a
>   change for a comment judged `out-of-scope` / `wontfix` / `already-done`.

---

## Phase 0 — Detect Source

Detect the forge from the origin remote host (R-1's platform rule), then locate the review source.

```bash
origin_host=$(git remote get-url origin 2>/dev/null \
  | sed -E 's#^(https?://|git@)([^/:]+).*#\2#')

case "$origin_host" in
  github.com|*.github.com)  platform=github ;;   # use gh
  gitlab.com|gitlab.*)      platform=gitlab ;;   # use glab  (covers a self-managed GitLab host)
  *)                        platform=local  ;;   # no PR/MR host -> local-doc fallback
esac
echo "$platform"
```

- GitHub host (`github.com`, GHES `*.github.com`) ⇒ **`gh`**.
- Any GitLab host — including a self-managed instance — ⇒ **`glab`** (pass
  `--hostname <host>` to `glab api` for non-`gitlab.com` instances; `<host>` = `$origin_host`).
- Anything else ⇒ the **local-doc fallback** at `.code-review/inline-comments.md`.

Then confirm a review source actually exists:

```bash
# GitHub: is there an open PR for this branch?
gh auth status && gh pr view --json number,headRefOid,baseRefName,headRefName,url 2>/dev/null
# GitLab:
glab auth status && glab mr view --output json 2>/dev/null | jq '{project_id, iid, web_url}'
# local: does SCR-1's review doc exist?
test -f .code-review/inline-comments.md && echo "local doc found"
```

**Decision:**
- `platform=github` with an open PR ⇒ Phase 1 (GitHub).
- `platform=gitlab` with an open MR ⇒ Phase 1 (GitLab).
- No PR/MR but `.code-review/inline-comments.md` exists ⇒ Phase 1 (local doc).
- Neither a PR/MR nor a local doc ⇒ see Error Handling ("no PR/MR and no local doc").

Record `platform`, the PR `<n>` / MR `<iid>` / doc path, and `<host>` — every later phase reuses them.

---

## Phase 1 — Pull Comments

List every outstanding inline comment with its `file`, `line`, `body`, author, and stable
thread id. Commands are taken **verbatim** from R-1's reference doc.

### 1a — GitHub (`platform=github`)

REST gives file/line/body/author/thread-linkage:

```bash
gh api "repos/{owner}/{repo}/pulls/<n>/comments" --paginate \
  --jq '.[] | {
    id,                       # review-comment id (REST databaseId)
    in_reply_to_id,           # set => this is a reply in a thread
    review_id: .pull_request_review_id,
    file: .path,
    line: (.line // .original_line),
    side,
    commit_id,
    author: .user.login,
    body
  }'
```

(`line` is `null` on outdated comments — fall back to `original_line`.)

REST does **not** expose `resolved` or a stable thread id. Get those from GraphQL
`reviewThreads` and join on `databaseId` == REST `id`:

```bash
gh api graphql -f owner='{owner}' -f repo='{repo}' -F num=<n> -f query='
query($owner:String!,$repo:String!,$num:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$num){
      reviewThreads(first:100){
        nodes{
          id                       # stable thread id (e.g. PRRT_...)
          isResolved
          isOutdated
          path
          line
          comments(first:100){ nodes{
            databaseId             # == REST comment id
            author{login}
            body
          }}
        }
      }
    }
  }
}' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | {
  thread_id: .id, resolved: .isResolved, outdated: .isOutdated,
  file: .path, line, comments: [.comments.nodes[] | {id: .databaseId, author: .author.login, body}]
}'
```

For each thread, the **root** comment is the first one (its REST `id` / `databaseId` is the
reply target in Phase 4). Skip threads already `isResolved: true` unless the user asks to revisit them.

### 1b — GitLab (`platform=gitlab`)

```bash
glab api "projects/:id/merge_requests/<iid>/discussions" --hostname <host> --paginate \
  | jq '.[] | {
      discussion_id: .id,                         # stable thread id (40-char hash)
      notes: [ .notes[] | {
        note_id:  .id,
        author:   .author.username,
        body:     .body,
        resolved: .resolved,                       # true|false (MR notes only)
        resolvable: .resolvable,
        file:     (.position.new_path // .position.old_path),
        line:     (.position.new_line // .position.old_line)
      }]
    }'
```

Each discussion's `id` is the reply target in Phase 4. Non-diff (general) notes have
`position: null` — skip those that aren't actionable code feedback. Skip discussions whose
notes are already `resolved: true` unless asked to revisit.

### 1c — Local doc (`platform=local`)

Parse SCR-1's review doc — one fenced ```` ```yaml ```` block per finding, keyed by a stable `id`:

```bash
cat .code-review/inline-comments.md
```

Each block has the field contract: `id` (e.g. `f-0001` — the durable join key), `file`, `line`,
`severity`, `body`, `status` (`open` | `resolved` | `wontfix`), `reply` (empty until filled).
Treat each `status: open` block as one comment to work; its `id` is where Phase 4 writes the reply.

**Output of Phase 1** — a numbered worklist:
```
Pulled N comments from <PR #42 | MR !17 | .code-review/inline-comments.md>:
  1. src/foo.ts:42  (thread PRRT_x / disc abc123 / id f-0001)  — "Off-by-one: loop should stop at len-1"
  2. src/auth.ts:8  (...)                                        — "JWT secret hardcoded"
  ...
```

---

## Phase 2 — Validate Each Comment

For each comment, read the cited `file:line` in the current working tree and assign a **verdict**
plus a short rationale. Do not edit code in this phase.

| Verdict | Meaning |
|---------|---------|
| **valid** | The comment is correct and the code needs the change. → addressed in Phase 3. |
| **already-done** | The concern is already handled (e.g. fixed in a later commit, or the reviewer misread). → no edit; reply explains where it's handled. |
| **out-of-scope** | Real point, but outside this branch's/ticket's scope. → no edit; reply defers it (suggest a follow-up). |
| **wontfix** | Deliberately not doing it (disagree, or the cost/benefit doesn't justify). → no edit; reply gives the reasoning. |

**Output of Phase 2 — verdict table, shown to the user BEFORE any Phase 3 edit:**
```
## Validation
1. src/foo.ts:42   [valid]        Off-by-one confirmed — loop reads slice[len], should stop at len-1.
2. src/auth.ts:8   [valid]        Secret is hardcoded; move to env.
3. src/api.ts:17   [already-done] Error handling added in commit f3c7ef2.
4. src/util.ts:90  [out-of-scope] Caching rewrite — file a follow-up, not this branch.
5. README.md:5     [wontfix]      Style preference; current wording matches house style.

Plan: address (1) and (2) in code; reply to all 5.
Proceed? [I'll address the 'valid' items and reply to every thread.]
```

Only the **valid** items become code edits. The others are reply-only. If a `valid` fix would
require a destructive op or a large refactor, flag it here and ask before proceeding (per the
global "ask before destructive ops" / "no premature abstraction" rules).

---

## Phase 3 — Address Valid Items

For each **valid** comment, make the **minimal** change the finding calls for:

1. Read the file around `file:line`.
2. Apply the smallest change that resolves the finding — nothing more. No drive-by refactors,
   no new abstractions for a single call site, no extra error handling/validation beyond what
   the comment asked for.
3. Follow the repo's existing conventions (style, naming, test layout).
4. If the change touches behavior, run the repo's tests for the affected area
   (`cd <repo>` first if working on another repo) and note pass/fail.

**Rules:**
- **Ask before any destructive op** (`rm`, `mv`, overwriting an unrelated file). Never do it silently.
- Do **not** force-push or rebase (default-off). If the user wants the fixes pushed, push the
  branch with a normal `git push` only after the user confirms.
- Keep one logical change per finding so each reply can point at a concrete edit.

**Output of Phase 3:**
```
## Changes
1. src/foo.ts:42  — changed `i <= len` to `i < len`  (fix off-by-one)
2. src/auth.ts:8  — moved secret to process.env.JWT_SECRET; added to .env.example
Tests: `npm test -- auth` → 12 passed.
```

---

## Phase 4 — Reply to Each Thread

Reply to **every** comment from Phase 1 (addressed and declined alike), stating how it was
resolved or why it was declined. Commands are **verbatim** from R-1's reference doc.
**Default is reply-only — do NOT resolve the thread** unless the user explicitly asks.

Reply text convention:
- valid → `Fixed in <commit/working-tree>: <what changed>.`
- already-done → `Already handled in <commit/where>.`
- out-of-scope → `Out of scope for this branch — filing a follow-up. <reason>.`
- wontfix → `Won't fix: <reason>.`

### 4a — GitHub PR (`platform=github`)

Reply by pointing a new review comment at the **root** comment's id (its REST `id` /
`databaseId` from Phase 1a):

```bash
gh api --method POST "repos/{owner}/{repo}/pulls/<n>/comments" \
  -f body="<reply text>" \
  -F in_reply_to=<root_comment_id>   # the REST id / databaseId of the comment to reply to
```

### 4b — GitLab MR (`platform=gitlab`)

Reply by posting a note into the discussion (its `discussion_id` from Phase 1b):

```bash
glab api --method POST \
  "projects/:id/merge_requests/<iid>/discussions/<discussion_id>/notes" --hostname <host> \
  -f body="<reply text>"
```

(GitLab commands are doc-sourced in R-1 — the self-managed GitLab host's token was expired at
authoring time — and are embedded as-is.)

### 4c — Local doc (`platform=local`)

There is no thread to reply to — instead write the resolution **back into the same finding block**
in `.code-review/inline-comments.md`, matched by its stable `id`, filling the `reply` slot and
updating `status` (per R-1's schema):

- valid (addressed) → `status: resolved`, `reply: | Fixed: <what changed>.`
- already-done → `status: resolved`, `reply: | Already handled in <where>.`
- out-of-scope → leave `status: open`, `reply: | Out of scope — follow-up filed.`
- wontfix → `status: wontfix`, `reply: | Won't fix: <reason>.`

```yaml
id: f-0001
file: src/foo.ts
line: 42
severity: bug
body: |
  Off-by-one: loop should stop at `len - 1`, this reads past the slice end.
status: resolved
reply: |
  Fixed: changed `i <= len` to `i < len`.
```

Match on `id` (durable join key) — never on file/line, which may have drifted after Phase 3 edits.

### Reporting

```
## Replies
Platform: github | PR #42 (https://github.com/.../pull/42)
  ✓ src/foo.ts:42   replied — Fixed: off-by-one corrected.
  ✓ src/auth.ts:8   replied — Fixed: secret moved to env.
  ✓ src/api.ts:17   replied — Already handled in f3c7ef2.
  ✓ src/util.ts:90  replied — Out of scope; follow-up suggested.
  ✓ README.md:5     replied — Won't fix: matches house style.
Threads resolved: 0 (reply-only is the default).
```
or on the local-doc path:
```
## Replies
Local doc .code-review/inline-comments.md — updated 5 finding blocks (reply+status).
```

---

## Error Handling

| Situation | Response |
|-----------|----------|
| No PR/MR **and** no local doc (`.code-review/inline-comments.md` absent) | Stop with: "No review source found — no open PR/MR for this branch and no `.code-review/inline-comments.md`. Run `/smart-code-review` first to generate findings, or point me at the review." Do not invent comments. |
| `gh`/`glab` not installed or unauthenticated (`auth status` fails) | If a local doc exists, fall back to `platform=local` and work the doc. Otherwise report the auth gap (e.g. "GitLab token expired — `glab auth login --hostname <host>`") and stop — do not attempt forge calls. |
| Thread / comment / discussion id not found (Phase 4 reply 404s) | Re-list (Phase 1) to refresh ids; the comment may have been deleted or resolved. If still missing, skip that reply and report it in the Replies summary rather than failing the whole run. |
| Reply POST fails (401/403/422) | Non-fatal — record the intended reply in the report and, if a local doc exists, write it into the matching finding block so it isn't lost. |
| A `valid` fix needs a destructive op or large refactor | Pause in Phase 2/3 and ask the user before editing (global "ask before destructive ops" / "no premature abstraction" rules). |
| Comment line is outdated (`line: null`, GitHub) | Use `original_line`; locate the code by content, not the stale line number. |
| User asks to also resolve threads | Only then resolve — GitHub: GraphQL `resolveReviewThread(threadId: <PRRT_...>)`; GitLab: `PUT .../discussions/<discussion_id>?resolved=true`. Default remains reply-only. |
