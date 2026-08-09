# Pillar 3: LLM Context (Wiki-First Protocol)

A lookup discipline for checking what's already known — wiki, then project memory, then CLAUDE.md — before an agent re-derives an answer from scratch or interrupts you to ask something already on record.

## Why it matters

- Re-investigating a question that's already answered in the wiki wastes tokens and time on work that was already done.
- Asking the user something that's already sitting in project memory or CLAUDE.md is avoidable friction — the answer should be found, not requested.
- A consistent lookup order (wiki → memory → CLAUDE.md → investigate/ask) means agents behave predictably instead of picking a random starting point each time.

## Where it lives

**ai-toolbox-sourced:**

| Source | Path (in ai-toolbox) | What it provides |
|---|---|---|
| Wiki-first instructions | `instructions/wiki-first.md` | The lookup sequence (wiki → project memory → CLAUDE.md → route investigation) plus the decision tree for when to invoke `grounded-investigate` vs. a lightweight lookup vs. asking the user |

**NOT ai-toolbox-sourced (pip-symlinked from the `obsidian_wiki` package):**

| Tool | Where installed | Source |
|---|---|---|
| wiki-query | `~/.claude/skills/wiki-query` | `obsidian_wiki` pip package |
| wiki-context-pack | `~/.claude/skills/wiki-context-pack` | `obsidian_wiki` pip package |
| wiki-ingest | `~/.claude/skills/wiki-ingest` | `obsidian_wiki` pip package |

## How to get it

```bash
git clone https://github.com/AmenZhou/ai-toolbox.git   # for instructions/wiki-first.md
pip install obsidian-wiki                                # for wiki-query / wiki-context-pack / wiki-ingest — a separate package, not ai-toolbox
```

## What it does for you

These two provenances do different jobs and are installed differently — don't go looking for the wiki tools inside an `ai-toolbox` clone, they aren't there. `instructions/wiki-first.md` is the protocol: it tells an agent to check the wiki, then project memory, then CLAUDE.md before deciding whether a question needs a full `grounded-investigate` pass, a quick grep, a direct answer, or a question back to the user — read it and fold it into your own instructions file. `wiki-query`, `wiki-context-pack`, and `wiki-ingest` are the actual tools that protocol calls out to: `wiki-query` answers a question from the compiled wiki, `wiki-context-pack` produces a token-bounded context slice for a downstream agent, and `wiki-ingest` distills new documents into wiki pages. All three ship with the `obsidian-wiki` Python package (install via `pip install obsidian-wiki`, or your own fork) — they are maintained separately from ai-toolbox, not built there.

**Back to:** [Assessment & Gap Finding Guide](../ASSESSMENT.md)
