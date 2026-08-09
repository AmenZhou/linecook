# Pillar 2: Orchestration (Task-Breakdown + Task-Orchestrate)

A two-skill stack for turning a spec into executed work: `task-breakdown` plans it, `task-orchestrate` runs it — with an explicit approval gate between the two.

## Why it matters

- Decomposing complex work into a written plan (right-sized units, explicit phases) catches missing steps and bad dependency ordering before any code gets touched — ad hoc execution catches them mid-flight, if at all.
- A plan artifact is reviewable: you can read the whole decomposition, challenge it, and fix it before a single tool call runs.
- An explicit "go" gate means execution never starts silently — nothing runs until a human approves the plan.

## Where it lives

| Source | Path (in ai-toolbox) | What it provides |
|---|---|---|
| task-breakdown skill | `skills/task-breakdown/SKILL.md` | Turns a spec, plan doc, or rough notes into a single task-orchestrate task plan — every unit of work expressed as four chained phases (Investigation/Plan → Challenge → Implementation → Verification) |
| task-orchestrate skill | `skills/task-orchestrate/SKILL.md` | Executes a task plan: maintains a project-scoped control plane (`.orchestrate/`) and task registry, runs phases inline or via spawned agents, manual go/go-auto and synchronous — no background watchdog, inbox queue, or heartbeat (that async subsystem was removed upstream) |

## How to get it

```bash
git clone https://github.com/AmenZhou/ai-toolbox.git
ln -s "$PWD/ai-toolbox/skills/task-breakdown" ~/.claude/skills/task-breakdown
ln -s "$PWD/ai-toolbox/skills/task-orchestrate" ~/.claude/skills/task-orchestrate
```

## What it does for you

`task-breakdown` reads a job — a spec, plan doc, or the current conversation — and decomposes it into right-sized units of work, each written as an Investigation/Plan → Challenge → Implementation → Verification chain inside one `.orchestrate/tasks/{ID}.md` file. It never starts execution; it stops at the go-gate. `task-orchestrate` then picks up that plan: it plans or resumes a task, presents it for review, and only executes once you say "go" (or "go auto" to skip per-phase confirmation) — running entirely in that same session, synchronously, with no background process to babysit. Both skills describe their current, post-async-removal behavior: manual and in-session only.

**Back to:** [Assessment & Gap Finding Guide](../ASSESSMENT.md)
