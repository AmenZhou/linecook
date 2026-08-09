<!--
Provenance: extracted from the private ai-toolbox repository (https://github.com/AmenZhou/ai-toolbox),
which is not publicly available. Embedded in linecook under this repo's MIT license — see /LICENSE.
-->

## Wiki-First Research Protocol

When a question cannot be answered by reading code, docs, or config in the current context, follow a hierarchical lookup sequence before deciding how to investigate:

1. **Check the wiki** — run `wiki-query` or look up existing knowledge
2. **Check project memory** — read `memory/*.md` and session context
3. **Check CLAUDE.md** — read project config and instructions
4. **Route investigation** — use the decision tree below to choose the right path

### Investigation Routing: Choosing the Right Path

After the four lookups above fail to answer the question, choose your investigation path based on complexity, urgency, and confidence needs.

#### Quick Decision Checklist

- **Complex question requiring cross-file patterns or root-cause analysis?** → Invoke `grounded-investigate`
- **Simple question with clear answer in 1–2 files + time-urgent (<1min)?** → Lightweight investigation (grep/read)
- **Conceptual question about general knowledge?** → Direct LLM response
- **Requires human judgment or missing context?** → Ask the user

#### Decision Matrix

| Question Type | Complexity | Path | Cost | Latency |
|---|---|---|---|---|
| "How does X work?" (cross-file) | High | grounded-investigate | ~8k tokens | 60–90s |
| "Where is X located?" | Low | lightweight | ~200 tokens | <5s |
| "What's the difference between X and Y?" | Low | direct LLM | ~300 tokens | <2s |
| "Should we do X or Y?" | N/A | ask user | 0 tokens | hours–days |

#### When to Invoke Grounded-Investigate

Use `grounded-investigate` when:

1. **Cross-file patterns** — Question requires reading ≥3 related files
2. **Root-cause analysis** — Tracing why something failed
3. **Ambiguity resolution** — Competing interpretations need code evidence
4. **Architectural understanding** — Understanding system-wide behavior
5. **High-confidence need** — Safety-critical or high-reuse-value questions
6. **Time available** — Can spend 1–2 minutes on research

**Examples:**
- "What's the full task lifecycle from inbox staging to completion?"
- "Why do tend-lock deadlocks happen?"
- "How do permission hooks interact with task execution?"
- "When should I use inbox/ vs inbox/gated/ for new tasks?" (ambiguity with safety implications)

#### When NOT to Invoke Grounded-Investigate

Don't use it when:

1. **Simple fact lookup** — Question has a clear answer in ≤2 files
2. **Time-critical** — Need answer in <1 minute
3. **Conceptual** — Question is about general knowledge, not this codebase
4. **Design decision** — Requires human judgment, not research
5. **Token budget tight** — Can't afford 5k+ tokens for this question

#### Trade-Off: Grounded-Investigate vs. Asking the User

| Dimension | Grounded-Investigate | Ask User |
|---|---|---|
| Latency | 60–90 seconds | Hours to days (user availability) |
| Cost | ~8k tokens | 0 tokens (user's time) |
| Confidence | High (evidence-based) | Very high (authoritative) |
| Coverage | Wide (cross-file search) | Perfect (for that user) |
| Autonomy | Fully autonomous | Requires human input |
| Best for | Technical deep-dives, root-cause analysis | Design decisions, business logic, missing context |
