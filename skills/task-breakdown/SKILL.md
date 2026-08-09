---
name: task-breakdown
description: Turn a job (spec, plan doc, rough notes, or the current conversation) into a set of well-structured, right-sized units of work and write them as ONE task-orchestrate task plan — a single `.orchestrate/tasks/{ID}.md` file with every unit expressed as chained phases — so a subsequent task-orchestrate run executes the whole job by working through the plan. Use when the user says "break this down into a task plan", "turn this spec into a task-orchestrate plan", "decompose this job for orchestrate to execute", "plan and orchestrate this", or "split this work into phases for /orch". This is the multi-unit decomposer + task-plan writer. For refining ONE ticket/unit's own description (add ACs / a test plan / flesh it out) defer to the ticket-planning skill instead. Every unit of work becomes four chained phases — Investigation/Plan → Challenge → Implementation → Verification. Open questions answerable by investigation are resolved there; a genuine human-judgment gap surfaces through task-orchestrate's own needs_human machinery at execution time, not a bespoke ask flow. Never starts execution — writes the plan and stops at the orchestrate go-gate.
version: 3.1.0
investigation_model_tier: sonnet
decomposition_model_tier: sonnet
---

<!--
Provenance: extracted from the private ai-toolbox repository (https://github.com/AmenZhou/ai-toolbox),
which is not publicly available. Embedded in linecook under this repo's MIT license — see /LICENSE.
Adapted for this repo: personal project paths generalized to placeholders (Step 1b's control-plane
root, the worked example's fictional target repo), and the Constraints section's self-reference to
ai-toolbox's own private-repo sync workflow was rewritten for a standalone embedded copy — see the
edit points inline.
-->

# task-breakdown

Decompose a job into right-sized units of work, and write the whole decomposition as **one
task-orchestrate task file** — every unit expressed as four chained phases (Investigation/Plan,
Challenge, Implementation, Verification) inside a single `.orchestrate/tasks/{ID}.md` — so that a
subsequent task-orchestrate run (`/orch resume` → pick the ID → "go"/"go auto") executes the whole
job by working through the plan this skill produced.

**Scope boundary:** This skill *decomposes* a job into many units and writes them as **one
task-orchestrate plan**. To refine a single existing unit's own description (add ACs, write a test
plan, flesh it out), use **ticket-planning**. This skill reuses ticket-planning's section format
inline as the basis for each phase's sub-sections, plus one additional section (**Out of Scope /
Prohibitions**) that ticket-planning does not have — it does not invoke ticket-planning at runtime,
so there is no hard runtime dependency.

**HARD RULE:** This skill NEVER starts execution. It writes the task file, registers its row in
`project.md` as `awaiting_go`, and stops there. task-orchestrate always requires an explicit "go"
from the human before any task runs. Do not invoke task-orchestrate's Execution Loop, do not flip
the registry row to `running`, do not run any phase.

**Why this writes a task file, not inbox tickets:** earlier versions of this skill staged each unit
as three separate `-INV`/`-IMPL`/`-VERIFY` tickets in `.orchestrate/inbox/`, relying on a
`tend`/`drain-inbox.sh` background cycle to pick them up and dispatch them independently over time.
That async, registry-scanning apparatus (`drain-inbox.sh`, `check-depends-on.sh`,
`update-registry-row.sh`, `churn-guard.sh`, `tend-need-action.sh`, and the rest of
`.orchestrate/bin/`) does not exist in this project's current `.orchestrate/` — it was archived
after Claude Code CLI proved unable to run non-interactively in a launchd context. The live model is
**manual, immediate execution**: a human runs task-orchestrate, reviews a plan, says "go", and it
runs right then in that same session. A plan staged as many small, separately-registered inbox
tickets has nothing left to drain it asynchronously — writing one complete, ready-to-run
task-orchestrate plan is the design that actually fits how this project executes work today. If a
future project restores the async tend/inbox-drain infrastructure, revisit this — the
ticket-per-unit-per-stage model this skill used to produce is still a reasonable fit for that
architecture, just not this one.

**CORE PRINCIPLE — every unit gets four chained phases: Investigation/Plan → Challenge →
Implementation → Verification.** A unit of work is never expressed as a single phase. Each unit
becomes: an **Investigation/Plan** phase that researches the unit and writes a concrete plan
artifact; a **Challenge** phase (`depends_on:` the INV phase) that independently, adversarially
reviews that plan before Implementation is allowed to rely on it; an **Implementation** phase
(`depends_on:` the Challenge phase) that executes exactly the challenged plan; and a
**Verification** phase (`depends_on:` the Implementation phase) that independently checks the
result against the investigation's acceptance criteria. See Step 2.

**CORE PRINCIPLE — research first, ask only when research can't resolve it.** When decomposition
hits an open question, try to resolve it inside the relevant unit's Investigation/Plan phase
(reading code, docs, config — see Step 2). That covers most unknowns and needs no human input. But
if a question requires **human judgment, a product/business decision, credentials or access the
agent doesn't have, or an irreversible choice between materially different designs**, do **not**
guess and do **not** write a phase that papers over it — **STOP the breakdown and ask the human
directly** (Step 1a). Resolve the answer, then continue decomposing. The go-gate (Step 8) is still
always required before execution, but it is no longer the *only* point at which the human may be
asked something — and a question that slips past authoring time still gets one more independent
check: the **Challenge** phase (Step 2) adversarially re-examines each unit's INV plan at execution
time, and a gap it can't resolve itself surfaces through task-orchestrate's own `needs_human`
machinery, not a second bespoke ask-flow.

---

⚙️ **Model Tier:** The full breakdown process (Steps 1–2) requires Sonnet model tier for accurate decomposition and dependency analysis.
- **Claude Code:** Invoke this skill via `Agent(model: "sonnet")` to ensure high-quality unit decomposition.
- **Cursor:** Before running this skill, switch to Sonnet in Settings (⌘ + Shift + J).

Decomposing a job into right-sized, correctly-ordered units, and turning them into a single
coherent phase plan, is architectural work where premium reasoning significantly improves quality
and reduces rework later.

## Step 1 — Read the source job fully

The job is one of: a spec/plan doc (path or pasted), rough notes, or the current conversation.

- If a path or doc is given, read it completely before decomposing — do not skim.
- If the job is "the current conversation", treat everything discussed so far as the spec.
- Note: existing constraints, target repos/paths, data/counts, CLI interfaces, naming conventions,
  cluster/infra dependencies, and anything that affects gating (Step 5) or ordering (Step 4).

## Step 1b — Scan the live control plane for overlapping work

Before finalizing any unit's phase dependencies (Step 4) or deciding whether Step 1a needs to ask
the human, scan for work that is already enqueued or in flight and might overlap this job. Scan
**three sources**, all relative to the canonical control plane root — wherever `.orchestrate/`
lives in your own project (`<your project root>`):

1. **`.orchestrate/project.md` non-terminal registry rows.** Parse the `## Task Registry` table; a
   row is "live" (in scope for overlap) iff its `status` column is one of `pending`, `running`,
   `awaiting_go`, `needs_human`. `complete`, `failed` rows are excluded — terminal, not a race risk.
   For each live row, also read `.orchestrate/tasks/<ID>.md` if it exists to pull its `**Target:**`
   line and `## Goal` text for heuristics 2–3 below.
2. **`.orchestrate/inbox/*.md` and `.orchestrate/inbox/gated/*.md`, if present.** This skill no
   longer writes here itself, but another producer (a human, or a different skill) may have staged
   something manually. Exclude any file carrying a `deferred_at:` header.

For each unit being planned, check it against each live source-item found above, in this priority
order:

1. **Explicit human-named ticket ID or title (highest confidence — hard-dependency candidate).**
   The source job text literally names a registry task ID (`YYYYMMDD-HHMMSS` shape) or a work-area
   title/slug that exact- or prefix-matches a live row's `summary` column.
2. **Target path overlap (medium confidence — soft conflict only, see Step 4).** The unit's target
   repo path/branch exact- or prefix-matches a live task file's `**Target:**` value.
3. **Shared resource keywords (lowest confidence — soft conflict only, see Step 4).** Quoted
   file/script basenames, table/service names, or a work-area prefix shared with a live row's
   summary. A token match is a "these might be touching the same area" signal, not evidence of a
   real ordering dependency.

Heuristic 1 is deterministic and cheap; heuristics 2–3 are best-effort greps, not semantic
analysis — they exist to surface things for a human to notice, not to make autonomous blocking
decisions. Carry the resulting list of `(live_ref, kind: hard|soft, matched_heuristic)` tuples
forward to Step 4 and Step 7.

**A heuristic-1 hard match here can never be turned into a machine-enforced dependency for this
job's plan** (see Step 4) — this project's `.orchestrate/bin/` has no `check-depends-on.sh` or
equivalent to gate execution on another task's registry status at dispatch time (see the "Why this
writes a task file" note above). It becomes a prominent human-readable warning instead.

**Model Tier Note:** This scanning phase is sophisticated heuristic matching work. Sonnet model
tier ensures reliable detection and classification of overlaps, reducing false positives and false
negatives.

## Step 1a — Stop and ask, but only when investigation genuinely can't resolve it

Most open questions belong inside a unit's **Investigation/Plan** phase (Step 2) — they get
answered by reading code, docs, config, or existing data, with no human involved. Default to that
path. A second, independent check also happens later at execution time: each unit's **Challenge**
phase (Step 2) adversarially re-examines the INV phase's plan and can itself surface a
human-judgment gap that got past authoring time — Step 1a is for questions that block the
*decomposition itself* (you cannot even split the job into sensible units without an answer);
Challenge is for questions specific to *one already-decomposed unit's plan*.

Only interrupt the breakdown and ask the human directly when a question is **not answerable by
investigation** — i.e. it requires:
- a **human judgment or product/business decision** (e.g. "should this feature be opt-in or default-on"),
- **credentials, access, or context the agent does not have** (e.g. a decision that lives in
  someone's head, a system the agent can't reach),
- a choice between **materially different, hard-to-reverse designs** where guessing wrong would
  mean redoing real work (not just re-running a script).

When that happens:
1. Continue decomposing whatever units are *not* blocked by the question (don't hold the whole job
   hostage to one unclear part).
2. Print the specific question(s) to the human, each with the options you see and your
   recommendation.
3. STOP — do not finalize the plan for the blocked unit yet, do not proceed to Step 6/7/8 for the
   blocked portion. Wait for the human's answer, then resume decomposition for that unit only.

This is narrower than "ask about anything unclear" — a question you *could* answer yourself by
reading the repo is not a reason to stop. Reserve stopping for things only the human can actually
settle.

## Step 2 — Decompose into right-sized units, each expressed as four chained phases

Split the job into discrete **units of work**. **Right-sizing heuristic:**

- One unit = one thing a single agent can implement in **one focused phase**.
- **Split** when a unit's Acceptance Criteria would exceed ~5, or the work spans multiple
  subsystems/repos.
- **Merge** trivially-coupled fragments (e.g. "add field" + "add the one test for that field").
- Give each unit a meaningful, work-area ID (e.g. `DS-1`, `P3-3`, `INFRA-1`) plus a short title —
  this ID becomes part of each of its four phase names.

**Model Tier Impact — Critical Phase:** This decomposition step is where correct unit boundaries
and dependency relationships are determined. Sonnet model tier is essential for:
- Breaking work into cohesive, right-sized units (not too fine-grained, not too monolithic)
- Identifying true blocking relationships (data flow, prerequisites)
- Predicting execution order and potential phase-level parallelism
- Reducing the need for refactoring/re-splitting once the plan is executed

**Every unit becomes exactly four phases, chained in this order:**

1. **`<ID>-INV` — Investigation/Plan.** Researches the unit and produces a concrete, written
   implementation plan artifact. This is where open questions get resolved (Step 1a) — by reading
   code/docs/config, not by guessing. Stays read-only / non-mutating: it investigates and plans, it
   does not ship the change.
2. **`<ID>-CHALLENGE` — Adversarial review of the INV plan.** `depends_on:` the INV phase.
   Independently reads the INV phase's plan artifact and tries to **refute** it: is the chosen
   approach actually sound, is there an unstated assumption, is there an option the plan didn't
   consider, are the Acceptance Criteria it hands to Implementation actually complete and
   verifiable? This must be genuinely independent scrutiny, not a rubber stamp — the phase is
   dispatched fresh (per task-orchestrate's own Agent phase execution, each phase is its own
   Agent() call with no shared memory of the INV phase's own reasoning process, only its written
   output), which gives it real independence even within one task file.
   - **If it finds a real, fixable gap:** amend the plan artifact directly with the fix (one
     targeted correction — mirrors grounded-investigate's tie-break move, not a full re-litigation)
     and append a `## Challenge — <ISO>` section to the artifact recording what was found and how
     it was resolved. The phase then passes (✅) — Implementation depends on the *corrected* plan.
   - **If the gap needs human judgment** (a product/business call, missing access, a hard-to-reverse
     design choice — the same bar as Step 1a): do not guess and do not force a resolution. The
     phase fails (❌) with the gap named in `blockers`. This flows into task-orchestrate's existing
     First-Pass Auto-Resolution Check → Human-Only Block Classifier → `needs_human` with a
     structured `needs:`/`why:`/`to_clear:` ask, exactly like any other phase failure — **do not
     invent a second ask-the-human mechanism here**; this is the whole point of making Challenge a
     first-class phase instead of a bespoke check.
   - **If it finds nothing wrong:** record that explicitly too (`## Challenge — <ISO>: no issues
     found, plan confirmed as written`) rather than silently passing with no trace — the same
     "never synthesize a conclusion without writing out what was checked" discipline
     grounded-investigate uses.
3. **`<ID>-IMPL` — Implementation.** `depends_on:` the Challenge phase. Executes *exactly* the
   (possibly Challenge-amended) plan — it does not re-derive the approach. References the plan
   artifact by path instead of re-explaining the reasoning.
4. **`<ID>-VERIFY` — Verification.** `depends_on:` the Implementation phase. Independently checks
   the implementation against the investigation phase's Acceptance Criteria — re-runs tests,
   reviews the actual diff, and diffs the actual changed files against the investigation phase's
   **Out of Scope / Prohibitions** list to confirm nothing on that list was touched. Written as if
   performed by someone other than the implementer: it must not simply trust the implementer's own
   claim of success.

If a unit is truly trivial (e.g. a one-line config change with an obvious, undisputed plan), the
Investigation phase's plan can be short and the Challenge phase's review correspondingly quick —
but all four phases still exist, so Implementation and Verification always have something concrete
to point at and Challenge always gets one independent look before anything ships.

A unit's **Investigation/Plan** phase MUST:
- have **acceptance criteria** that require *a plan recorded in a concrete artifact* (e.g.
  `reports/<area>/<id>-inv_plan.md`) covering: the approach, files/commands involved, and the exact
  acceptance criteria the Implementation phase must satisfy and the Verification phase must check,
- name, in its **Design** sub-section, exactly where to look (files, dashboards, commands) to get
  any answers,
- if it hits a question it cannot resolve itself, follow Step 1a instead of guessing.

## Step 3 — Apply the phase template format (per phase)

Each phase MUST have the header fields (`status`/`depends_on`/`acceptance_criteria`) plus all 6
sub-sections below, in this order, nested under its `### Phase N: <ID>-<STAGE> — <Short title>
[executor · type]` heading. Descriptions must be **self-contained** — a reader must not need to
open another phase's block to understand this one (the Implementation and Verification phases
should still point at the Investigation phase's plan artifact for the full rationale, but their own
Description/Design/Implementation Plan/Test Plan must make sense standalone).

**Count-based acceptance criteria — derive, never guess.** Any AC that hard-asserts a count
(`ls web/*.html | wc -l == 11`, "should be N files", "exactly N rows") MUST be computed by
**enumerating the specific artifacts** the phase itself names — existing baseline + to-be-created —
and asserting their sum. Never carry a standalone remembered/assumed total. Before emitting the AC,
run the self-consistency check `existing_count + new_count == asserted_total`; if it fails, fix the
number. If the baseline count is unknown, do not guess it — make it the job of the unit's
Investigation/Plan phase and assert the sum once that lands.

**"0 failures" ACs — carve out install-integration tests.** Any AC that hard-asserts a blanket pass
across a ported, cloned, or newly-authored test suite MUST first check for tests that depend on
live local state not guaranteed on a fresh checkout — a running service, an installed binary, a
loaded launchd/cron job, network/DB access, etc. Either exclude those tests from the AC's scope
explicitly or add a carve-out clause to the AC text itself.

```markdown
### Phase N: [ID]-[STAGE] — [Short title] [executor · type]
status: pending
depends_on: <phase number(s) this phase needs complete first, or "none">
acceptance_criteria:
- Specific and measurable (not "it works")
- Independently verifiable by someone other than the author
- Scoped to this phase only (no cross-phase ACs)

**Target:** <repo path / branch / cluster, if applicable>

**Description**
What needs to be done and why. Include context, scope, relevant data/counts, CLI interfaces,
naming conventions, and constraints. Self-contained — no "as described in the plan" references
except Implementation/Verification pointing at the Investigation phase's artifact.

**Out of Scope / Prohibitions**
- Explicit boundary: files, systems, or behaviors this phase must NOT touch, even if related or
  tempting to fix along the way while in the area.
- If nothing beyond the acceptance criteria's own boundary needs calling out, write "None beyond
  the acceptance criteria above." — do not leave this section blank or omit it.

**Open Questions**
- Unresolved decisions/blockers. Write "None." if there are none.
- If a question is answerable by investigation, it belongs in the `<ID>-INV` phase, not here.
- If a question needs the human (Step 1a), it must already be resolved before this plan is
  finalized — a written phase should never carry an unanswered human-judgment question. (An
  unanswered question the Challenge phase itself surfaces at execution time is different — that's
  its designed failure mode, not a gap in this section.)

**Design**
Technical approach: architecture/data-model decisions, libraries/patterns to use. (Negative
constraints — what NOT to touch — belong in **Out of Scope / Prohibitions** above, not here; do not
duplicate them.) For the Investigation/Plan phase, describe how to find the answer (what to look
at) and what the plan artifact must contain. For Challenge, describe what to independently try to
refute and where the INV phase's artifact lives. For Implementation, point at the (possibly
Challenge-amended) plan artifact instead of re-deriving the approach. For Verification, describe
how to check independently (re-run tests, diff the actual changed files against the Out of Scope /
Prohibitions list) — not just re-trust the implementer.

**Implementation Plan**
1. Ordered, concrete steps — what to create/modify, what to run, what to check at each step.

**Test Plan**
Specific verification: exact commands / queries / API calls with expected values (prefer
`SELECT count(*) = X` over "verify count is correct"). For the Verification phase this section *is*
most of the phase's substance.
```

## Step 4 — Compute phase numbers and dependencies

- Within a unit, the chain is fixed: `<ID>-INV` (phase *k*) → `<ID>-CHALLENGE` (phase *k+1*,
  `depends_on: k`) → `<ID>-IMPL` (phase *k+2*, `depends_on: k+1`) → `<ID>-VERIFY` (phase *k+3*,
  `depends_on: k+2`).
- Across units, fill `depends_on:` using data/artifact/precondition flow, and point it at the
  **specific phase number** that actually produces or needs the dependency — not automatically the
  upstream unit's final VERIFY phase. E.g. if unit B's Implementation needs unit A's shipped
  change but doesn't need A to be independently *verified* first, `B-IMPL`'s `depends_on:` names
  `A-IMPL`'s phase number directly, not `A-VERIFY`'s. Because every unit's phases live in the same
  file, this precision costs nothing extra — it's a plain phase-number reference either way.

**Model Tier Note:** Deriving correct cross-unit dependencies is a graph-reasoning problem.
Sonnet's reasoning improves accuracy in identifying the correct producing phase, detecting cyclic
dependencies (which indicate a decomposition error), and sequencing phase numbers so the printed
plan reads in a sensible order.

- Detect cycles — if any exist, break them by re-splitting or merging units.
- Assign phase numbers in **wave order**: Wave 1 = phases with no unmet dependencies (typically
  every unit's own `-INV` phase, unless a unit depends on another unit's later stage); later waves
  depend on earlier ones. This is advisory numbering for readability — task-orchestrate's Execution
  Loop determines actual ready-phase order from `depends_on:` at runtime, not from phase number
  order, and can run multiple ready phases in parallel (up to 6 per batch) regardless of numbering.

**Live overlaps are never wired as a dependency (from Step 1b).** A Step 1b hard match against a
row/file *outside this job's own plan* cannot become a real `depends_on:` — there is no phase
number to point at (it's a different task entirely) and no script in this project's
`.orchestrate/bin/` to enforce a cross-task gate at dispatch time (see the skill-level "Why this
writes a task file" note). Carry every hard match found in Step 1b forward to Step 7 as a
**prominent warning block**, and also write it into the task file's `## Context` section so it's
visible to whoever reviews the plan before saying "go" — the human is the enforcement mechanism for
this case, not a script. Heuristic-2/3 soft conflicts from Step 1b are carried to Step 7 the same
way, at lower urgency.

## Step 5 — Classify the whole plan auto vs gated (risk-based, NOT location-based)

Unlike the old per-ticket model, gating is now a **single decision for the whole task file** — its
top-level `mode:` field. Default is **`mode: auto`**. Set **`mode: gated`** only when at least one
unit's Implementation phase involves:

- destructive ops (`rm -rf`, `DROP`/`DELETE`/`TRUNCATE`, force-push),
- Kubernetes / infra mutations (`kubectl apply|scale|delete|patch|rollout`, `helm` mutate),
- sending email / posting to Slack / triggering a deploy,
- or an explicit user request to gate the job.

`gated` means task-orchestrate will pause at every phase checkpoint for a human "go" once execution
starts, not only before the risky unit's Implementation phase — this is coarser than the old
per-ticket gating (where only the risky `-IMPL` ticket itself paused) but matches how this project
actually runs work now: a human is present and synchronous for the whole execution anyway (see the
"Why this writes a task file" note), so the extra pauses on the non-risky units cost a few "go"
replies, not a stalled background job.

**Do NOT gate the whole plan just because one unit's Investigation or Verification phase happens to
*mention* a risky op** (e.g. "confirm this does not force-push") — gate only when a phase's actual
work performs one. A gated Implementation phase's Implementation Plan must stop at a review artifact
(e.g. write the mutating command to `/tmp/kube-cmd-*.sh`) and NOT execute the risky step itself —
it awaits human approval at that phase's checkpoint.

## Step 6 — Write the task file and register it

**No `.orchestrate/inbox/` writes.** Construct `.orchestrate/tasks/{ID}.md` directly, where `{ID}`
is `YYYYMMDD-HHMMSS` (UTC, at the moment of writing — matches task-orchestrate's own "New task" ID
convention).

**Registration uses direct file operations, not a helper script.** This project's current
`.orchestrate/bin/` contains no `update-registry-row.sh` or equivalent (see the skill-level note
above) — read `.orchestrate/project.md`, and append the new row to its `## Task Registry` table
with a normal file edit, matching the table's existing column format exactly
(`| ID | summary | mode | current_phase | status | last_activity |`, `current_phase: 1`,
`status: awaiting_go`, `last_activity:` the same UTC timestamp used for `{ID}`). Do not invent or
assume a helper script.

**Pull wiki context before constructing the task file.** task-orchestrate's own Plan Presentation
section pulls a bounded slice of wiki knowledge for every new task it plans interactively — a
task-breakdown-authored task file must get the same treatment, not skip it just because this skill
bypasses that flow. Do it exactly as task-orchestrate's Plan Presentation does — same invocation,
same budget, same skip condition, same output location — see `task-orchestrate/SKILL.md`'s Plan
Presentation section for the canonical definition; this is a citation, not a restatement: invoke
`/wiki-context-pack "<job title/goal>" --budget 1500` once per job (not once per unit), and write
the result verbatim into the task file under a `## Wiki Context` section (placed after `##
Acceptance Criteria`, before the `## PHASES` separator — see the schema below). Skip when the
job's title/Goal is itself wiki-related, and degrade gracefully (`## Wiki Context\n(unavailable —
proceeded without it)`) if the pull errors or the vault isn't configured — identical conditions to
task-orchestrate's own.

**Task file schema** (confirmed against real files in `orchestrate-history/`):

```markdown
id: {ID}
task: <one-line job title>
mode: auto | gated                # from Step 5
total_phases: <4 × unit count, + 1 for the mandatory final phase>
source: task-breakdown

## Goal
<1–3 sentences: what must be true when the whole job is done.>

## Context
<Constraints, target repos/paths, relationships between units. If Step 1b found any live-overlap
hard or soft matches, list them here explicitly — see Step 4 — so a human reviewing the plan before
"go" sees them without having to re-derive Step 1b's scan.>

## Acceptance Criteria
- <aggregate, job-level done-statements — the per-phase acceptance_criteria are the detailed,
  checkable version; these are the top-level summary>

## Wiki Context
<verbatim /wiki-context-pack output, or "(unavailable — proceeded without it)" — see above>

---

## PHASES

### Phase 1: DS-1-INV — <title> [agent/Sonnet · reasoning]
status: pending
depends_on: none
acceptance_criteria:
- ...

**Target:** ...
**Description** / **Out of Scope / Prohibitions** / **Open Questions** / **Design** /
**Implementation Plan** / **Test Plan** — per Step 3's template

### Phase 2: DS-1-CHALLENGE — <title> [agent/Sonnet · reasoning]
status: pending
depends_on: 1
...

### Phase 3: DS-1-IMPL — <title> [agent/Sonnet · execution]
status: pending
depends_on: 2
...

### Phase 4: DS-1-VERIFY — <title> [inline · execution]
status: pending
depends_on: 3
...

<... continue for every unit ...>

### Phase N: Test & Verify [inline · execution]
status: pending
depends_on: <every unit's final VERIFY phase number>
acceptance_criteria:
- All output files declared across every phase exist on disk
- Detected test suite passes, or "no test runner detected"
- No `files_changed` path outside any unit's declared scope
```

The final `Test & Verify` phase is **mandatory** (per task-orchestrate's own Plan Presentation
rule) and aggregates across every unit — it is a job-level check, distinct from each unit's own
`-VERIFY` phase which only checks that one unit.

**Executor/model-tier assignment** follows task-orchestrate's own Phase Classification table:
INV and CHALLENGE phases are `agent/Sonnet` (investigation and reasoning-type work respectively);
IMPL is `agent/Sonnet` for anything touching 3+ files or iterating, `inline · execution` for a
narrow (≤2 files, clear spec) change; VERIFY and the final Test & Verify are typically
`inline · execution`.

## Step 7 — Print a summary table + dependency graph

Output to the console (do NOT write a separate report file):

```
── Task plan: {ID} ─────────────────────────────────────────────────
| Phase | Unit stage    | Title                          | executor        | depends on |
|-------|---------------|--------------------------------|-----------------|------------|
| 1     | DS-1-INV      | Fixture count + seed plan      | agent/Sonnet    | —          |
| 2     | DS-1-CHALLENGE| Challenge the seed plan        | agent/Sonnet    | 1          |
| 3     | DS-1-IMPL     | Seed MCC fixture accounts      | agent/Sonnet    | 2          |
| 4     | DS-1-VERIFY   | Verify seeded fixtures         | inline          | 3          |
| 5     | P3-9-INV      | Diagnose redis-proxy no-master | agent/Sonnet    | —          |
| 6     | P3-9-CHALLENGE| Challenge the restart plan     | agent/Sonnet    | 5          |
| 7     | P3-9-IMPL     | Restart redis-proxy (review)   | agent/Sonnet    | 6 [gated]  |
| 8     | P3-9-VERIFY   | Confirm proxy healthy          | inline          | 7          |
| 9     | P3-3-INV      | Ramp runbook plan              | agent/Sonnet    | 4, 8       |
| 10    | P3-3-CHALLENGE| Challenge the ramp plan        | agent/Sonnet    | 9          |
| 11    | P3-3-IMPL     | Run unit-cost ramp             | agent/Sonnet    | 10         |
| 12    | P3-3-VERIFY   | Verify ramp results            | inline          | 11         |
| 13    | Test & Verify | Aggregate job verification     | inline          | 4, 8, 12   |

Waves (advisory — task-orchestrate dispatches by depends_on at runtime, not this order):
  Wave 1:  1, 5          (independent -INV phases)
  Wave 2:  2, 6          (their own -CHALLENGE)
  Wave 3:  3, 7          (their own -IMPL — phase 7 pauses for gated approval)
  Wave 4:  4, 8          (their own -VERIFY)
  Wave 5:  9              (needs both DS-1 and P3-9 verified)
  Wave 6:  10 → 11 → 12
  Wave 7:  13
────────────────────────────────────────────────────────────────────
```

**Live overlaps (from Step 1b).** If Step 1b found any hard or soft matches, print a second block
right after the table above — omit entirely when there are none:
```
⚠ Live overlaps — not machine-gated, review before "go" ─────────────
| Unit    | Overlaps            | Status  | Heuristic       | Confidence |
|---------|----------------------|---------|-----------------|------------|
| P3-3-INV| 20260628-inbox-9D5A | running | explicit ID     | hard       |
| DS-1-IMPL| example-app        | pending | target-path     | soft       |
```

Then add a **Recommended next step** line:
```
Recommended next step: `/orch resume`, pick {ID}, then "go auto" — Wave 1's two -INV phases are
read-only investigations; nothing mutates until Wave 3. Phase 7 (P3-9-IMPL) is gated — review
/tmp/kube-cmd-redis-proxy-restart.sh before approving the Redis mutation when execution reaches it.
```

## Step 8 — STOP at the go-gate

**Optional — grill the plan before "go".** Before printing the closing block, offer the human one
more option beyond "go"/"go auto"/abort: typing **"grill"** invokes the `grill-me` skill on the
plan just printed in Step 7, running a live interview with the human to pressure-test the job-level
decomposition (unit boundaries, missed units, wrong dependency ordering) before committing to it.
This is deliberately **not** the same check as the per-unit Challenge phase (Step 2) — Challenge is
an unattended, automated, single-unit check that runs *during* execution with no human present;
grilling here is a human-in-the-loop, whole-plan conversation that runs *before* execution even
starts, entirely at the human's discretion. Never invoke `grill-me` automatically — it is a HITL
skill (a live conversational interview), so calling it from an unattended context would just hang
waiting for a human who isn't there.

**Known dependency gap:** `grill-me` itself only says "Run a `/grilling` session" — as of this
writing `/grilling` (its actual implementation) is not installed in this environment. Typing
"grill" may currently fail or do nothing useful. State this plainly if the human asks for it rather
than pretending the option reliably works: "grill-me is wired in, but its own /grilling dependency
isn't installed yet — this may not do anything." Do not silently skip offering the option just
because it might fail; the human may have installed `/grilling` since this was written.

If the human grills the plan and it surfaces changes, revise the task file and reprint the Step 7
summary before returning to this same go-gate — grilling can repeat as many times as the human
wants before they say "go".

Print exactly:
```
Task plan {ID} written to .orchestrate/tasks/{ID}.md and registered in project.md — status:
awaiting_go. Nothing has been executed. Run `/orch resume`, pick {ID}, then "go" or "go auto" to
execute it — that runs immediately, in that session (no background dispatch in this project).
(Optional: type "grill" instead to run a grill-me interview over this plan first.)
```
Then STOP. Do not invoke task-orchestrate's Execution Loop, do not flip the registry row to
`running`, do not run any phase. The human owns the go decision. The skill's job is to research,
plan, and *recommend* — not to ask the human a question to proceed **at this stage**; any question
that genuinely needed the human was already asked and resolved back in Step 1a, before this point
(a question surfaced later, during execution, by a Challenge phase is task-orchestrate's
`needs_human` machinery, not this skill's job). Grilling (above) is the one exception to "no
questions at this stage" — it is opt-in and human-initiated, not the skill prompting the human.

---

## Worked example (dry — does NOT write a real file)

**Job:** "We need the Phase 3 unit-cost ramp ready, but it depends on seeded MCC fixtures, and the
shared Redis is reporting no master, which blocks the cluster run."

This decomposes into 3 units → 12 unit phases + 1 aggregate Test & Verify = 13 phases, all inside
one task file `.orchestrate/tasks/20260808-140500.md`. `DS-1`'s four phases are shown in full
below; `P3-9` and `P3-3` are summarized in the Step 7 table format (see Step 7 above for the full
13-phase table and dependency waves for this same example).

```markdown
id: 20260808-140500
task: Phase 3 unit-cost ramp — seed fixtures, fix Redis, run the ramp
mode: gated
total_phases: 13
source: task-breakdown

## Goal
Run the Phase 3 unit-cost ramp successfully: MCC fixtures seeded, redis-proxy healthy, ramp
executed and verified against SLA.

## Context
Depends on: seeded MCC fixtures (DS-1), a healthy redis-proxy (P3-9) — both must be verified before
the ramp (P3-3) starts. No live overlaps found in Step 1b.

## Acceptance Criteria
- [ ] MCC fixtures seeded and independently verified (DS-1)
- [ ] redis-proxy confirmed healthy post-restart (P3-9)
- [ ] Unit-cost ramp run and results verified against SLA (P3-3)

---

## PHASES

### Phase 1: DS-1-INV — Resolve MCC fixture count/persona mix and write the seed plan [agent/Sonnet · reasoning]
status: pending
depends_on: none
acceptance_criteria:
- `reports/phase3/ds-1-inv_plan.md` states the required fixture count and persona breakdown,
  citing the ramp spec section / persona config file + line
- The plan names the exact idempotency mechanism (`ON CONFLICT DO NOTHING` on the existing
  `scripts/seed_mcc_fixtures.sh`) and the exact verification query DS-1-IMPL and DS-1-VERIFY must
  both use
- If the spec is silent on the count, the plan states the chosen default and why

**Target:** `/path/to/example-app` (branch `feature/phase-3-prep`)

**Description**
The seed step needs to know how many MCC fixture accounts the unit-cost ramp exercises, which
persona mix, and the exact idempotent seeding approach. This phase resolves all of that read-only
from the ramp spec, the existing persona config, and the current seed script, and writes one
authoritative plan the later phases execute without re-deriving anything.

**Out of Scope / Prohibitions**
- Do not modify `scripts/seed_mcc_fixtures.sh` or any data — this phase is read-only planning.
- Do not seed fixtures into any environment (UAT or otherwise) — that execution is DS-1-IMPL's job.

**Open Questions**
- None — this phase exists to remove the open question, not to carry one.

**Design**
- Read-only: grep the ramp spec and `config/personas.yml`; do NOT modify data or run the seed here.
- Where to look: `docs/phase3/unit_cost_ramp.md` (persona mix), `config/personas.yml` (counts per
  persona), `scripts/seed_mcc_fixtures.sh` (current seed logic, to plan the idempotency guard
  against it).

**Implementation Plan**
1. Read the ramp spec + persona config; extract the required fixture count and per-persona split.
2. Read `seed_mcc_fixtures.sh`; decide exactly how the idempotency guard fits into it.
3. Write the plan (count + breakdown + source citations + exact guard + verification query) to
   `reports/phase3/ds-1-inv_plan.md`.

**Test Plan**
- `test -f reports/phase3/ds-1-inv_plan.md` and it contains an explicit integer fixture count.
- The doc cites at least one source file:line and states an exact `SELECT count(*) ...`
  verification query.

### Phase 2: DS-1-CHALLENGE — Adversarially review the seed plan [agent/Sonnet · reasoning]
status: pending
depends_on: 1
acceptance_criteria:
- The INV plan's fixture count and idempotency guard are independently re-derived from the same
  sources (not re-read from the plan's own conclusion) and confirmed to match, or a discrepancy is
  found and fixed in the plan artifact
- At least one alternative approach or edge case (e.g. "what if the seed script is re-run mid-ramp")
  was explicitly considered and either ruled out with a stated reason or folded into the plan
- A `## Challenge — <ISO>` section exists in `reports/phase3/ds-1-inv_plan.md` recording what was
  checked and the outcome

**Target:** `/path/to/example-app` (branch `feature/phase-3-prep`)

**Description**
Independently try to refute `ds-1-inv_plan.md` before DS-1-IMPL is allowed to depend on it — a
fresh read of the same source material (ramp spec, persona config, seed script), not a re-read of
the plan's own stated conclusion.

**Out of Scope / Prohibitions**
- Do not modify `scripts/seed_mcc_fixtures.sh` or any data — this phase only reviews the plan.
- Do not re-scope beyond DS-1-INV's stated fixture/persona question — no re-litigating unrelated
  parts of the ramp spec.

**Open Questions**
- None — a question this phase can't resolve itself becomes its own ❌/`needs_human`, not an
  open item left here.

**Design**
- Independent re-derivation: read `docs/phase3/unit_cost_ramp.md` and `config/personas.yml`
  directly, compute the expected count/persona split from scratch, compare to what
  `ds-1-inv_plan.md` states.
- If they match and no better approach surfaces: append `## Challenge — <ISO>: no issues found,
  plan confirmed as written.`
- If a real, fixable gap is found (e.g. the plan missed a persona category): amend
  `ds-1-inv_plan.md` directly with the correction, append `## Challenge — <ISO>: <what was wrong,
  what was fixed>`.
- If the gap is a genuine human-judgment call (e.g. the spec is ambiguous about whether a discount
  persona counts): do not guess — fail this phase with the gap named in `blockers`, so
  task-orchestrate's own `needs_human` flow picks it up.

**Implementation Plan**
1. Re-derive the fixture count and persona split from the ramp spec + persona config directly.
2. Compare against `ds-1-inv_plan.md`'s stated numbers and guard mechanism.
3. Record the outcome per the Design section above.

**Test Plan**
- `grep -q "## Challenge —" reports/phase3/ds-1-inv_plan.md` after this phase.
- If a correction was made, the corrected count satisfies
  `existing_count + new_count == asserted_total` (self-consistency check).

### Phase 3: DS-1-IMPL — Seed MCC fixture accounts per the (challenged) DS-1-INV plan [agent/Sonnet · execution]
status: pending
depends_on: 2
acceptance_criteria:
- `scripts/seed_mcc_fixtures.sh` has the idempotency guard from `ds-1-inv_plan.md` (re-running
  does not create duplicates)
- After a run, the verification query from `ds-1-inv_plan.md` returns the count that document
  specifies (post-Challenge, if amended)
- Run output is captured in `reports/phase3/ds-1-impl_run.md`

**Target:** `/path/to/example-app` (branch `feature/phase-3-prep`)

**Description**
Execute exactly the (possibly Challenge-amended) plan in `reports/phase3/ds-1-inv_plan.md` — add
the idempotency guard it specifies to `scripts/seed_mcc_fixtures.sh` and run it against UAT.

**Out of Scope / Prohibitions**
- Do not modify `config/personas.yml` or any persona source config — only apply the idempotency
  guard `ds-1-inv_plan.md` specifies to `scripts/seed_mcc_fixtures.sh`.
- Do not run the unit-cost ramp or touch cluster execution — that is P3-3's scope, not DS-1's.

**Open Questions**
- None — fixture count and approach are fixed by `ds-1-inv_plan.md` (post-Challenge).

**Design**
- Follow `ds-1-inv_plan.md` exactly, including any Challenge amendment; do not re-derive the
  approach or second-guess the resolved count.

**Implementation Plan**
1. Read `reports/phase3/ds-1-inv_plan.md` for the target count `N` and the guard to add.
2. Add the guard to `scripts/seed_mcc_fixtures.sh`.
3. Run the seed against UAT; capture stdout to `reports/phase3/ds-1-impl_run.md`.

**Test Plan**
- Run the seed twice; second run prints `0 inserted`.
- Run the verification query from `ds-1-inv_plan.md` → returns `N`.

### Phase 4: DS-1-VERIFY — Independently verify the seeded fixtures [inline · execution]
status: pending
depends_on: 3
acceptance_criteria:
- Independently re-running the verification query from `ds-1-inv_plan.md` returns `N`
- Re-running `seed_mcc_fixtures.sh` a third time still inserts `0` rows
- `mcc_accounts` rows with `fixture = false` are unchanged in count from before DS-1-IMPL started

**Target:** `/path/to/example-app` (branch `feature/phase-3-prep`)

**Description**
Independently confirm DS-1-IMPL actually did what it claims — do not trust `ds-1-impl_run.md`'s
own output. Re-derive the count from the database, re-check idempotency, and confirm nothing
outside scope was touched.

**Out of Scope / Prohibitions**
- Do not modify `scripts/seed_mcc_fixtures.sh` or insert/delete any rows — this phase only
  observes and queries.
- Do not re-scope the check beyond DS-1-IMPL's declared change — no re-litigating DS-1-INV's
  fixture count or persona mix here (that was Challenge's job, one phase back).

**Open Questions**
- None.

**Design**
- Independent check: query the DB directly rather than reading `ds-1-impl_run.md`'s claimed
  numbers.

**Implementation Plan**
1. Run the verification query from `ds-1-inv_plan.md` directly against UAT.
2. Re-run the seed script once more; confirm `0 inserted`.
3. Diff the non-fixture account count against the pre-DS-1-IMPL baseline.
4. Record the verdict in `reports/phase3/ds-1-verify_result.md`.

**Test Plan**
- `psql -c "<verification query>"` → `N`.
- `bash scripts/seed_mcc_fixtures.sh` → `0 inserted`.
- Non-fixture account count unchanged vs. baseline.
```

`P3-9` (redis-proxy fix, phases 5–8) and `P3-3` (the ramp run, phases 9–12) follow the identical
INV → CHALLENGE → IMPL → VERIFY pattern — see the Step 7 table above for the full 13-phase plan.
Phase 7 (`P3-9-IMPL`) is the only gated phase in this job (it runs `kubectl rollout restart`),
which is why the whole task file's `mode: gated` — its `-INV`, `-CHALLENGE`, and `-VERIFY` phases
still execute without a per-phase pause under a gated task, since gating only adds checkpoints, it
doesn't change what work each phase itself does.

**Closing step (always):**
```
Task plan 20260808-140500 written to .orchestrate/tasks/20260808-140500.md and registered in
project.md — status: awaiting_go. Nothing has been executed. Run `/orch resume`, pick
20260808-140500, then "go" or "go auto" to execute it — that runs immediately, in that session.
(Optional: type "grill" instead to run a grill-me interview over this plan first.)
```

### Variant: when Step 1a triggers instead

If, while planning `P3-3-INV`, the target request rate for the ramp turned out to be undocumented
and undiscoverable in the repo (a product/SLA decision, not a research question), the skill would
stop there instead of guessing — same as before, just phrased in terms of phases rather than
tickets:

```
Open question — needs your input before I can finish planning P3-3:

  P3-3 (unit-cost ramp) needs a target request rate to size the ramp steps. The ramp spec doesn't
  state one and it isn't derivable from existing config — this is a product/SLA decision, not
  something I can research my way to.

  Options: (a) match last quarter's observed peak (~4.2k rps), (b) use a new SLA target if one
  exists elsewhere, (c) you give me a number.
  Recommendation: (a) — grounded in real data, and the spec gives no other signal.

DS-1 and P3-9's phases (8 of them) are fully planned and ready — I'll finish P3-3's 4 phases and
write the complete task file right after you answer.
```

---

## Constraints

- Source of truth is this repo's `skills/` directory — edit the file directly; there is no
  separate sync step.
- No live cluster, network, or MCP dependency — decomposition + plan-writing are fully offline.
- Never start execution; always stop at the go-gate (Step 8).
- **No `.orchestrate/bin/*.sh` helper dependency.** Task file construction and registry-row
  registration both use direct file reads/edits — this project's current minimal `.orchestrate/`
  has no `drain-inbox.sh`/`update-registry-row.sh`/`check-depends-on.sh` equivalents (see the
  skill-level note above).
- Gate on the **actual risky op**, not on authorship or caution. Over-gating is NOT free — every
  extra `gated` pause costs a human reply, even though it's no longer a background-queue problem.
  A reversible code/test/docs change stays `auto`.
- **Every unit is four phases, always.** Never write a bare implementation phase without its
  Investigation/Plan, Challenge, and Verification siblings (Step 2) — even for units that look
  trivial.
- **Research first, ask only when research can't resolve it.** A question answerable by reading
  code/docs/config belongs in the unit's `-INV` phase, not a prompt to the human. A question that
  needs human judgment, access the agent lacks, or a hard-to-reverse design call STOPS the
  breakdown for that unit and asks the human directly (Step 1a) — do not write a phase that guesses
  at it. Units not blocked by the question still get planned and the go-gate summary still applies
  to them. A question that slips past authoring time gets one more independent check at execution
  time via the Challenge phase, which surfaces through task-orchestrate's own `needs_human`
  machinery rather than a second ask-flow.
