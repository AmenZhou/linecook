---
name: grounded-investigate
investigation_model_tier: sonnet
description: >
  Wiki-first, dual-method investigation skill. Always pulls Obsidian wiki context (index.md, hot.md)
  before doing anything else, then answers the question using two or more genuinely independent
  methods — never a single grep or a single guess — before concluding anything. For code-related
  questions it runs the actual test suite and debugs from real failures rather than reasoning about
  code from memory. When two methods disagree, it never silently picks one — it attempts one
  tie-breaking check and, if still unresolved, surfaces both findings explicitly. Use this skill
  whenever the user says "investigate X", "why does X happen", "find out if X is true", "debug X and
  tell me why", "cross-check this finding", "what's really going on with X", "is X actually true or
  just assumed", or asks any question where a wrong or unverified answer would be costly — even if
  they don't say the word "investigate". Prefer this over ad hoc grepping or a single web search
  whenever the question deserves more than one source of evidence. After concluding, it persists the
  cross-validated result back to the Obsidian wiki so future investigations build on it instead of
  re-deriving it.
---

<!--
Provenance: extracted from the private ai-toolbox repository (https://github.com/AmenZhou/ai-toolbox),
which is not publicly available. Embedded in linecook under this repo's MIT license — see /LICENSE.
Note: the "Before You Start" and "Persist to Wiki" sections below reference `llm-wiki/SKILL.md` and
companion wiki skills (wiki-capture, wiki-quick-chat-capture, wiki-ingest, wiki-setup) that are not
part of this embed — they live in a separate `obsidian-wiki` pip package, not this repo. See
guide/pillars/03-llm-context.md for that setup. The skill already degrades gracefully when wiki
tooling isn't present ("Run `wiki-setup` to initialize your wiki... continue without wiki grounding").
-->

# Grounded Investigate — Wiki-First, Dual-Method Investigation

You are running a disciplined investigation, not answering from memory or a single lookup. Every
conclusion in this skill must be backed by **at least two independent methods** that were compared
explicitly before you wrote a single word of conclusion. If you find yourself writing a conclusion
before you've run Method B, stop and go back — that is the one failure mode this skill exists to
prevent.

## Before You Start (wiki context — always, no exceptions)

This step runs **unconditionally**, even for a purely code-related question with no obvious wiki
angle. Skipping it because the question "looks like a code question" is exactly the shortcut this
skill forbids.

⚙️ **Model Tier:** This skill's dual-method investigation (Steps 2–4) uses Sonnet model for premium reasoning.
- **Claude Code:** When this skill is invoked, use `Agent(model: "sonnet")` for the full investigation loop to ensure cross-validation accuracy.
- **Cursor:** Before running this skill, switch to Sonnet in Settings (⌘ + Shift + J). You may switch back to Haiku after completion.

The dual-method design depends on independent reasoning in each method and sophisticated comparison in Step 4. Premium tier improves the reliability of agreement/disagreement assessment.

1. **Resolve config** — follow the **Config Resolution Protocol** in `llm-wiki/SKILL.md`: walk up from
   CWD for a `.env` containing `OBSIDIAN_VAULT_PATH`, else fall back to `~/.obsidian-wiki/config`, else
   tell the user "Run `wiki-setup` to initialize your wiki." and continue the investigation without
   wiki grounding if the user wants to proceed anyway (note this gap explicitly in the final report).
   This yields `OBSIDIAN_VAULT_PATH` and `OBSIDIAN_LINK_FORMAT`.
2. **Read `$OBSIDIAN_VAULT_PATH/index.md`** — establishes what's already known and settled, so the
   investigation doesn't re-derive ground the wiki already covers.
3. **Read `$OBSIDIAN_VAULT_PATH/hot.md`** if present — surfaces recent, in-flight context relevant to
   the question.
4. Apply `llm-wiki/SKILL.md`'s **Retrieval Primitives** table: escalate from `index.md`/frontmatter
   grep → a page's `summary:` field → targeted `Grep` → full `Read` only as a last resort. This keeps
   wiki-grounding cheap even on a large vault — don't `Read` whole pages when a grep or a summary field
   answers the question.

Carry forward anything the wiki already states as settled fact — it can serve as one input into Method
A or B below, but it never substitutes for actually running the two independent methods in Steps 2-3.

## Step 1 — Scope the Investigation

1. Restate the question being investigated in one sentence. If you can't restate it cleanly, the
   question is underspecified — ask the user one clarifying question before proceeding.
2. **Classify the question:**
   - **Code-related** — it references a repository/file path, a function/class/symbol name, an error
     message or stack trace, or asks about the behavior of running code.
   - **Knowledge/fact question** — anything else (a factual claim, a concept, "is X true", "what
     happened with Y").
   - When ambiguous, default to **code-related** if any project directory is in scope — a scoped test
     run is cheap relative to missing real evidence.

## Step 2 — Method A

Run the first of the two independent methods, per the question's classification.

**Model Tier Note:** This step and Step 3 are high-cognition investigation phases. Sonnet model tier ensures robust method design and independent reasoning. Each method must be genuinely independent; premium reasoning improves that independence.

**Knowledge/fact question:**
- Method A = **wiki/vault lookup** — using the Retrieval Primitives from "Before You Start," search the
  vault specifically for existing settled knowledge that bears on this exact question (not just the
  general context already skimmed above — a targeted second pass aimed at this question).

**Code-related question — the test-running/debugging branch:**
1. **Locate relevant tests** — find the test file(s)/suite scoped to the symbol or behavior under
   investigation (grep test directories for the symbol name; check the project's test-runner config for
   how to scope a single file or pattern).
2. **Run them** — execute the scoped test command, capture full stdout/stderr, note pass/fail counts.
3. **Parse pass/fail and error output** — read failure output for stack traces, assertion diffs, and
   error messages. Never treat a bare "tests failed" without reading *why* as evidence of anything.
4. **Debug from failures** — when a failure's cause isn't obvious from the error alone, add temporary
   debug output, isolate the failing assertion, or re-run narrower (a single test case) to localize the
   cause. This stops at diagnosis — **fixing the code is out of scope** for this skill unless the
   invoking task explicitly asks for a fix.
5. **Record evidence** — capture the exact command run, the pass/fail result, and the specific
   log/stack-trace lines that support the finding. This becomes Method A's finding in Step 4, not a
   footnote.

**If no test infrastructure exists** for the code in question: skip this branch and say so explicitly
in the report ("no test suite found for X, falling back to static-only methods") — never skip it
silently. In that case Method B (Step 3) should be a second **static** method rather than a second
dynamic one.

## Step 3 — Method B

Run the second, genuinely independent method — it must draw on a different evidence source than
Method A, not a rephrasing of the same lookup.

**Knowledge/fact question:**
- Method B = fresh **web research** (`WebSearch`/`WebFetch`, bounded to 2-3 targeted queries — not a
  full multi-round research loop), **or**, if the question is about this session's own codebase, a
  fresh `grep` / `graphify query` / direct code read performed independently of what the wiki already
  claims — don't just re-confirm the wiki's own wording.

**Code-related question:**
- Method B = an independent **static** method — read the actual implementation/config directly (not by
  inferring from test names or wiki notes) and reason from first principles. Method A exercised running
  code; Method B must exercise reading code, so the two are genuinely independent evidence sources.

**When ≥3 independent angles are cheap** (e.g. the question has both a code and a documentation
component), run both pairs — more corroboration is always acceptable, never required beyond two.

## Step 4 — Cross-Validate

1. **Write out each method's finding side-by-side, explicitly, before concluding anything.** Never
   synthesize a single conclusion first and then backfill "supporting" evidence — that inverts the
   whole point of running two methods.

**Model Tier Impact:** Cross-validation and disagreement resolution (especially the tie-breaking step below) are high-cognition reasoning tasks where Sonnet model tier significantly improves accuracy. If using Claude Code, ensure Agent dispatch specified `model: "sonnet"` at the start of this skill. If using Cursor, ensure the session is running at Sonnet tier.

2. **Agreement path:** if the two findings agree (or one strictly subsumes/refines the other with no
   contradiction), report the combined finding, citing both methods as corroboration.
3. **Disagreement path — the critical requirement of this skill:**
   - Do **not** pick one finding and discard the other.
   - Attempt **one targeted tie-breaking check** — a third, cheap, independent probe aimed specifically
     at the point of disagreement (e.g. re-run the failing test in isolation, or re-grep with a
     narrower pattern).
   - If the tie-break resolves it: report the resolved finding, and note that the initial methods
     disagreed before resolution — that disagreement is itself useful signal, not to be thrown away.
   - If the tie-break does **not** resolve it: the report **must** surface both findings explicitly
     under an unmissable `## Disagreement` heading — stating what each method found, why they diverge,
     and what would resolve it (e.g. "needs a human decision" or "needs access this session doesn't
     have"). Borrow `llm-wiki/SKILL.md`'s `^[ambiguous]` provenance-marker vocabulary and `disputed`
     lifecycle-state naming for how you describe the disagreement, not its wiki-write mechanics.
   - **Never** collapse an unresolved disagreement into a single confident-sounding sentence. If you
     catch yourself writing "the answer is X" while a `## Disagreement` section should exist instead,
     stop and write the disagreement section.

## Step 5 — Report

Produce the conclusion using this template:

```markdown
## Investigation: <one-sentence question>

### Methods Used
- Method A: <what was done, what evidence source>
- Method B: <what was done, what evidence source>

### Findings
- Method A found: <finding>
- Method B found: <finding>

### Agreement / Disagreement
<state explicitly which — if disagreement, this is where the ## Disagreement section goes instead,
per Step 4>

### Confidence
<high / medium / low, with one line on why>

### Sources
<wiki pages consulted, commands run, files read, URLs fetched>
```

## Step 6 — Persist to Wiki (ingest the result)

The investigation isn't finished when the report prints. A cross-validated finding is exactly the
kind of settled knowledge the wiki exists to hold — persist it so the next run reads it in "Before You
Start" instead of re-deriving the same ground. The Step 5 report stays what you show the user; this
step is the durable side-effect that makes the next investigation start smarter.

1. **Decide what's worth persisting.**
   - **Persist** when the finding is cross-validated (both methods actually ran and agreed or were
     reconciled), **or** when an unresolved `## Disagreement` was surfaced — a known-open question is
     valuable to record, not hide.
   - **Skip** for a provisional single-method finding, or a trivial lookup already fully covered by an
     existing wiki page — but say so in one line in the report ("not persisted: single-method /
     provisional / already in `[[page]]`"). Never skip silently.

2. **If wiki grounding was skipped** in "Before You Start" (no vault configured), skip this step too and
   note it in the report ("no wiki configured — result not persisted; run `wiki-setup` to enable").
   Never invent a vault path.

3. **Prefer the existing wiki skills over hand-rolling a page.** In order of preference:
   - `wiki-capture` — save this investigation as a structured, declarative wiki page (best fit: a
     finished, self-contained finding).
   - `wiki-quick-chat-capture` / `wiki-ingest` — stage into `_raw/` when the finding is worth keeping
     but not yet worth a polished page, or when a later `wiki-ingest` pass should promote it.
   - Fall back to a **direct page write** into `$OBSIDIAN_VAULT_PATH` only if those skills aren't
     reachable this session.

4. **However it's written, the persisted page must**, per `llm-wiki/SKILL.md` conventions:
   - Carry frontmatter with a `summary:`, `tags:`, and a `lifecycle:` state — `settled` for an agreed
     cross-validated finding, `disputed` for an unresolved `## Disagreement`.
   - Record provenance so downstream tools know it came from an investigation (tool/source =
     `grounded-investigate`; borrow llm-wiki's provenance-marker vocabulary).
   - Contain the Step 5 report content rewritten as **declarative knowledge**, not a chat transcript —
     Methods, Findings, Agreement/Disagreement, Confidence, Sources.
   - **Cross-link** to every wiki page consulted in "Before You Start" so the new page isn't an orphan.
   - Land in the correct vault category — reuse an existing project/topic folder if one fits, else the
     appropriate `misc/` topic area.

5. **Update the wiki's entry points** so the finding is discoverable: add a one-line pointer to
   `index.md`, and to `hot.md` if the finding is recent/in-flight — exactly the two files that "Before
   You Start" reads first, so the loop actually closes.

6. **Report what was persisted** — end the run by telling the user where it landed (page path/title and
   lifecycle state), or that persistence was intentionally skipped and why.

## Dispatch Mode

**Default: sequential, in one agent** — run Method A, then Method B, then compare. This is the default
because (a) there is no dedicated multi-agent "Workflow tool" to depend on in this environment, and
(b) skills should degrade gracefully when subagents aren't available.

**Optional: parallel Agent-tool dispatch** — when the invoking environment has the `Agent` tool
available, you MAY dispatch Method A and Method B as two independent Agent-tool subagents launched in
the same message, mirroring the `Agent` tool's own documented "independent second opinion" pattern, for
speed — provided each subagent is genuinely blind to the other's findings until the comparison step in
Step 4. Do not let one subagent see the other's output before both have reported back.

**Model tier for parallel dispatch:** When dispatching Method A and Method B as parallel subagents, specify `model: "sonnet"` on both Agent calls. Independent reasoning benefits from consistent premium tier across both methods — a Haiku-dispatched Method A and Sonnet-dispatched Method B can produce asymmetric reasoning quality, undermining independence.

Both dispatch paths funnel into the same Step 4 comparison-and-disagreement logic. The dispatch
mechanism is an implementation optimization, not a change to the cross-validation contract.

## What NOT to Do

- **Never report a single-method finding as settled.** If Method B wasn't actually run, the report must
  say so plainly ("only one method was used — treat this as provisional") rather than presenting it
  with the confidence of a cross-validated finding.
- **Never silently pick a side on disagreement.** An unresolved disagreement always gets its own
  `## Disagreement` section — it is never smoothed over into a single sentence.
- **Never skip the wiki-context step**, even for code-only questions where it feels irrelevant. If the
  wiki genuinely has nothing relevant, say so in one line and move on — but the lookup itself is never
  skipped.
- **Never treat "tests failed" as evidence without reading why** — a red test run with no error output
  read is not a method, it's a coin flip.
- **Never let a hard-won cross-validated finding evaporate.** Persist it to the wiki (Step 6) unless it's
  single-method/provisional or the wiki is unconfigured — and when you skip persistence, say so in one
  line rather than dropping it silently.
