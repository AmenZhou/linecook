# Pillar 4: Quality Gates (Investigation + Code Review)

Evidence-based investigation before you conclude something, and reviewed code before it ships — plus a follow-through step that actually acts on what review finds instead of leaving it in a comment thread.

## Why it matters

- An unverified answer that turns out wrong is expensive to unwind — dual-method investigation cross-checks itself with two independent methods before concluding anything, instead of trusting a single grep or a single guess.
- Code review that stops at "here are the findings" doesn't fix anything by itself; without a follow-through step, valid findings sit unaddressed and threads go unanswered.
- Ticket-aware review catches drift between what was asked for and what was built, not just generic code smells.

## Where it lives

| Source | Path (in ai-toolbox) | What it provides |
|---|---|---|
| grounded-investigate skill | `skills/grounded-investigate/SKILL.md` | Wiki-first, dual-method investigation — two genuinely independent methods, tie-breaking on disagreement, results persisted back to the wiki |
| smart-code-review skill | `skills/smart-code-review.md` | Ticket-aware review: validates the implementation against the fetched ticket/PR requirements, runs an OWASP Top 10 pass and a BUG/FIX/AUTO/CONSIDER pass, posts findings inline on the PR/MR (or a local review doc when there is no PR/MR) |
| address-code-review skill | `skills/address-code-review.md` | Works the review feedback end-to-end: pulls inline comments, validates each as valid/already-done/out-of-scope/wontfix, makes the code changes for the valid ones, and replies to every thread |

## How to get it

```bash
git clone https://github.com/AmenZhou/ai-toolbox.git
ln -s "$PWD/ai-toolbox/skills/grounded-investigate" ~/.claude/skills/grounded-investigate
# smart-code-review.md and address-code-review.md are flat files in ai-toolbox (not <name>/SKILL.md
# directories like every other skill here) — Claude Code only discovers skills at
# ~/.claude/skills/<name>/SKILL.md, so create the directory and symlink the file into it as SKILL.md:
mkdir -p ~/.claude/skills/smart-code-review && ln -s "$PWD/ai-toolbox/skills/smart-code-review.md" ~/.claude/skills/smart-code-review/SKILL.md
mkdir -p ~/.claude/skills/address-code-review && ln -s "$PWD/ai-toolbox/skills/address-code-review.md" ~/.claude/skills/address-code-review/SKILL.md
```

## What it does for you

These three skills form one closed loop instead of three disconnected tools. `grounded-investigate` answers a question — "why does X happen," "is X actually true" — by pulling wiki context first, then running two independent methods (and, for code questions, the actual test suite) before concluding anything, surfacing both sides explicitly if the methods disagree. `smart-code-review` reviews a branch against its ticket/PR requirements plus a security and quality pass, and posts the findings as inline comments. `address-code-review` is the consumer side: it pulls those same inline comments back, decides which are actually valid, makes the corresponding code changes, and replies to each thread with how it was resolved — so review findings turn into shipped fixes instead of an unread comment list.

**Back to:** [Assessment & Gap Finding Guide](../ASSESSMENT.md)
