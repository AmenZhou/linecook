# linecook

> *Clip a ticket, it works the rail.*

<p align="center">
  <img src="docs/assets/hero.jpg" alt="A robot line cook, BOTTY, works a kitchen pass — the linecook project packages a Claude Code setup guide and a legacy autonomous task-runner." width="100%">
</p>

**Claude Code Setup — Assessment & Gap Finding guide.**

linecook ships a self-audit guide for your local [Claude Code](https://claude.com/claude-code) setup: a single markdown document that walks you through 4 pillars — security, orchestration, LLM context, and quality gates — and tells you what's missing before it causes a problem.

Start here: **[`guide/ASSESSMENT.md`](guide/ASSESSMENT.md)**

---

## The Assessment Guide

[`guide/ASSESSMENT.md`](guide/ASSESSMENT.md) is a 15–30 minute self-audit. For each of the 4 pillars it gives you:

- A checklist of what a solid setup has
- Shell commands to check whether *you* have it
- A prioritized **Gap Priority Matrix** (Critical / High / Medium / Low) once you're done
- An **Assessment Scorecard** to track what's implemented vs. missing over time

No install, no server, no dependency on this repo staying on disk — it's a document you read and act on.

---

## 4-Pillar Reference

Each pillar has its own doc with a deeper checklist, gap-finding commands, and links to the skill/tool that fills the gap.

| Pillar | Covers | Doc |
|---|---|---|
| 1. Security | Deny-list permissions, PreToolUse hooks, secrets protection | [`guide/pillars/01-security.md`](guide/pillars/01-security.md) |
| 2. Orchestration | task-breakdown + task-orchestrate, control plane, go-gate | [`guide/pillars/02-orchestration.md`](guide/pillars/02-orchestration.md) |
| 3. LLM Context | Wiki-first protocol, wiki-query/wiki-context-pack/wiki-ingest | [`guide/pillars/03-llm-context.md`](guide/pillars/03-llm-context.md) |
| 4. Quality Gates | grounded-investigate, smart-code-review, address-code-review | [`guide/pillars/04-quality-gates.md`](guide/pillars/04-quality-gates.md) |

Each pillar doc links back to the Assessment Guide, and each pillar lists its own install steps for the tools it references — most come from [`ai-toolbox`](https://github.com/AmenZhou/ai-toolbox), though Pillar 3's wiki tools are a separate `obsidian-wiki` pip package (see that doc for the split). linecook itself doesn't install or run those tools — it's the guide that tells you which ones you're missing.

---

## Why this guide exists

Local Claude Code setups accumulate gaps quietly — a missing deny-list pattern, no orchestration skill, no context strategy, no review gate — and those gaps usually surface as an incident rather than a warning. This guide exists to make the audit explicit and repeatable:

1. **Structured** — 4 pillars instead of a vague "is my setup good?" feeling.
2. **Actionable** — every checklist item pairs with a command to check it and a doc for how to fix it.
3. **Prioritized** — the Gap Priority Matrix tells you what to fix first, not just what's missing.

---

## Getting the guide

There's no install step — clone the repo and read the markdown.

```bash
git clone https://github.com/AmenZhou/linecook.git
cd linecook
open guide/ASSESSMENT.md   # or just read it in your editor
```

---

## Repository layout

```
linecook/
├── README.md                  # this file
├── LICENSE
├── .gitignore
├── guide/
│   ├── ASSESSMENT.md          # the hero doc — Assessment & Gap Finding guide (self-audit across 4 pillars)
│   └── pillars/
│       ├── 01-security.md         # deny-list + hooks (permission-audit skill)
│       ├── 02-orchestration.md    # task-breakdown + task-orchestrate skills
│       ├── 03-llm-context.md      # wiki-first protocol + wiki-* tools
│       └── 04-quality-gates.md    # grounded-investigate + smart-code-review + address-code-review
└── docs/
    └── assets/
        └── hero.jpg            # header illustration
```

---

## Legacy: Background Automation

Earlier versions of linecook were an autonomous inbox-and-launchd job runner — drop a task file in `.orchestrate/inbox/`, a macOS `launchd` heartbeat picked it up, and a harness ran it through structured phases to an archive. That full system (installer, `bin/` scripts, `launchd/` plists, the Node.js monitor dashboard, and its test suites) has been moved out of this branch's history and lives on [`archive/background-automation`](../../tree/archive/background-automation). Check out that branch if you want the original autonomous-inbox tool rather than the setup guide.

---

## Provenance

Originally packaged from a personal Claude Code `task-orchestrate` skill and its `.orchestrate/` control plane into a standalone, self-contained, installable system. As of the `guide-ai-setup` restructuring, the repo's primary artifact is the Assessment & Gap Finding guide; the original inbox/orchestrate automation lives on [`archive/background-automation`](../../tree/archive/background-automation).

## License

MIT — see [LICENSE](LICENSE).
