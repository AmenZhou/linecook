#!/usr/bin/env bash
# drain-inbox.sh — T-2 inbox drain (bash): register in project.md, mv to processed/
# Processes inbox/gated/ first, then root inbox/*.md. Skips deferred_at files.
set -euo pipefail

ROOT="${1:-.}"
INBOX="$ROOT/.orchestrate/inbox"
GATED="$INBOX/gated"
PROCESSED="$INBOX/processed"
PROJ="$ROOT/.orchestrate/project.md"
HEARTBEAT="$ROOT/.orchestrate/logs/heartbeat.log"
# shellcheck source=followup-dedup.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/followup-dedup.sh"
# AT-1: idempotency sidecar for the gated "needs go" notification. A sidecar
# (not a registry column) keeps the 8-field registry-row invariant intact.
GATED_NOTIFIED="$ROOT/.orchestrate/logs/gated-notified.tsv"

# CROSS-1: in-batch map of "referenced ticket's original inbox basename" ->
# "its real registered ID", built up as this drain-inbox.sh run processes
# files. Lets a ticket's `blocked_by_ticket:` header (breakdown-to-inbox's
# structural marker, SKILL.md Step 6) resolve to a real depends_on: ID when
# the referenced ticket has ALREADY been drained earlier in this same run.
# Scoped to this one process (mktemp + EXIT trap) — deliberately does NOT
# persist across drain-inbox.sh invocations, since a ref from a prior run has
# no reliable basename->ID record to look up (see resolve_depends_on()).
BLOCKED_BY_MAP="$(mktemp "${TMPDIR:-/tmp}/drain-inbox-blocked-by.XXXXXX")"
trap 'rm -f "$BLOCKED_BY_MAP"' EXIT

mkdir -p "$PROCESSED" "$(dirname "$HEARTBEAT")"

log_inbox() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" >>"$HEARTBEAT"
}

ensure_project_md() {
  if [[ -f "$PROJ" ]]; then
    return 0
  fi
  local name
  name="$(basename "$ROOT")"
  cat >"$PROJ" <<EOF
# Orchestrate — $name
last_updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

## Shared Context

## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
EOF
}

registry_has_id() {
  local id="$1"
  grep -qF "| $id |" "$PROJ" 2>/dev/null
}

gen_task_id() {
  local file="$1"
  local base prefix slug n=0
  base="$(basename "$file" .md)"
  prefix="$(date +%Y%m%d)-inbox-"
  if command -v md5 >/dev/null 2>&1; then
    slug="$(printf '%s' "$base" | md5 -q | cut -c1-4 | tr '[:lower:]' '[:upper:]')"
  else
    slug="$(printf '%s' "$base" | cksum | awk '{print $1}' | tail -c 5)"
  fi
  local id="${prefix}${slug}"
  while registry_has_id "$id"; do
    n=$(( n + 1 ))
    id="${prefix}${slug}${n}"
  done
  printf '%s' "$id"
}

extract_title() {
  local file="$1"
  local title
  title="$(grep -m1 '^# ' "$file" 2>/dev/null | sed 's/^# //' || true)"
  if [[ -z "$title" ]]; then
    title="$(basename "$file" .md)"
  fi
  title="${title//|/-}"
  printf '%.100s' "$title"
}

# Extract the body of a named section from an inbox ticket. Tickets in this
# project use two different section-marker conventions — the canonical
# `## Heading` template (SKILL.md's documented inbox file format) and the
# richer self-generated `**Heading**` style (INV/IMPL/VERIFY-shaped tickets,
# e.g. Description/Acceptance Criteria/Design) — so a section start is either
# form, matched case-insensitively against the given (possibly `|`-alternated)
# heading-name pattern, and the section ends at the next heading of either
# form or EOF.
extract_section() {
  local file="$1" pat="$2"
  awk -v pat="$pat" '
    {
      line=$0
      gsub(/^[ \t]+|[ \t]+$/,"",line)
      is_md = (line ~ /^##[ \t]/)
      is_bold = (line ~ /^\*\*[^*]+\*\*$/)
      is_heading = is_md || is_bold
      htext = line
      if (is_md) { sub(/^##[ \t]+/,"",htext) }
      if (is_bold) { sub(/^\*\*/,"",htext); sub(/\*\*$/,"",htext) }
      if (is_heading) {
        if (found) exit
        if (tolower(htext) ~ tolower(pat)) { found=1; next }
        next
      }
      if (found) print
    }
  ' "$file" 2>/dev/null
}

# A source AC bullet that wraps across two physical lines (no leading `-`/`*`
# on the continuation line — plain markdown soft-wrap) must not be truncated
# at the line break when materializing the task file. Merges any non-blank,
# non-bullet-start line into the preceding bullet; blank lines terminate a
# bullet's continuation (do not merge across them); lines before the first
# bullet (section intro prose) are dropped, matching the prior `grep '^[-*] '`
# behavior for that case.
merge_wrapped_bullets() {
  awk '
    function flush() { if (buf != "") { print buf; buf="" } }
    /^[-*] / { flush(); buf=$0; next }
    /^[ \t]*$/ { flush(); next }
    buf != "" {
      line=$0
      gsub(/^[ \t]+/,"",line)
      buf = buf " " line
      next
    }
    { next }
    END { flush() }
  '
}

# ORPH-1: materialize a minimal .orchestrate/tasks/<id>.md for a freshly-
# registered row so a registered row is never left without a task file. Prior
# to this, the task file was only ever written lazily, by convention, when a
# live agent session first dispatched the task (SKILL.md's "On go/go auto"
# stub-write step) — if that dispatch died before its first write, the row
# orphaned (running, no file, no dispatch heartbeat), got reset to `pending`
# by requeue-orphaned-running.sh (a status-column flip only, no file), and
# re-entered the exact same unmaterialized state, repeating until
# churn-guard.sh parked it `needs_human` after 3 cycles. See
# reports/orchestrate/orph-1-inv_plan.md for the full root-cause trace.
# Idempotent: does nothing if a task file already exists at that path (e.g. a
# human hand-authored one, or a re-drain of an already-registered ID).
materialize_task_file() {
  local file="$1" id="$2" summary="$3" mode="$4" depends_on="${5:-none}"
  local task_file="$ROOT/.orchestrate/tasks/${id}.md"
  [[ -f "$task_file" ]] && return 0

  local goal acs followup_hdr kind_hdr blocked_by_hdr
  goal="$(extract_section "$file" "^(goal|description)$")"
  if [[ -z "$goal" ]]; then
    goal="$(cat "$file" 2>/dev/null)"
  fi
  acs="$(extract_section "$file" "^acceptance criteria$" | merge_wrapped_bullets || true)"

  # Preserve followup_for:/kind: headers verbatim as literal top-level lines —
  # enqueue-review-and-tests.sh / enqueue-wiki-sync.sh grep the constructed task
  # file (not the original inbox file) for these to anti-recursion-gate; dropping
  # them here causes a followup ticket to spawn a followup-of-itself (see
  # 20260726-inbox-EED4 incident: a wiki-sync ticket got its own wiki-sync
  # follow-up filed because its materialized task file had lost `followup_for:`).
  followup_hdr="$(grep -m1 -E '^followup_for:' "$file" 2>/dev/null || true)"
  kind_hdr="$(grep -m1 -E '^kind:' "$file" 2>/dev/null || true)"
  # CROSS-1: preserve blocked_by_ticket: verbatim too, same rationale — it's the
  # provenance record of WHY depends_on ended up non-"none" (or, when the
  # reference didn't resolve this batch, a debugging trail for why it's still
  # "none" despite the prose saying otherwise).
  blocked_by_hdr="$(grep -m1 -E '^blocked_by_ticket:' "$file" 2>/dev/null || true)"

  mkdir -p "$(dirname "$task_file")"
  {
    printf 'id: %s\n' "$id"
    [[ -n "$followup_hdr" ]] && printf '%s\n' "$followup_hdr"
    [[ -n "$kind_hdr" ]] && printf '%s\n' "$kind_hdr"
    [[ -n "$blocked_by_hdr" ]] && printf '%s\n' "$blocked_by_hdr"
    printf 'task: %s\n' "$summary"
    printf 'mode: %s\n' "$mode"
    printf 'total_phases: 1\n'
    printf 'source: inbox (materialized at registration by drain-inbox.sh)\n'
    printf '\n## Goal\n%s\n' "$goal"
    printf '\n## Phases\n\n### Phase 1: %s [inline · execution]\n' "$summary"
    printf 'status: pending\n'
    printf 'depends_on: %s\n' "$depends_on"
    printf 'acceptance_criteria:\n'
    if [[ -n "$acs" ]]; then
      printf '%s\n' "$acs"
    else
      printf -- '- Task goal (see ## Goal above) is satisfied\n'
    fi
  } > "$task_file"
}

# CROSS-1: resolve a `blocked_by_ticket:` header (breakdown-to-inbox's
# structural marker for a real cross-ticket ordering dependency — see
# SKILL.md Step 6) to the real registered ID of the referenced ticket. Only
# resolves if that ticket has ALREADY been drained earlier in THIS SAME
# drain-inbox.sh run (recorded in BLOCKED_BY_MAP, keyed by the referenced
# ticket's original inbox basename — a value breakdown-to-inbox controls and
# can reference exactly, since it writes both files itself). If the header is
# absent/empty, or the ref isn't in the map (not part of this batch, e.g. it
# arrives in a later file this run, or was already registered in a prior run
# with no live basename->ID record), depends_on stays "none" — never invent
# an ID for a ticket we haven't actually observed being registered.
#
# CROSS-2 (20260727-inbox-7D4A): the structural `blocked_by_ticket:` header is
# only ever emitted by breakdown-to-inbox. Self-generated INV/IMPL/VERIFY-style
# tickets (this project's own stress-test workstream) instead write a
# markdown-bold prose line — `**Blocked by:** CH-TABLE-SEED-IMPL.` — which the
# header regex above never matches, so depends_on silently stayed "none" even
# though the ticket text named its blocker (the exact gap that let
# 20260727-inbox-1F27 get dispatched before its gated prerequisite 20260727-
# inbox-9AB4 was approved). When no `blocked_by_ticket:` header is present,
# fall back to parsing this prose line and resolve the referenced title/slug
# via `resolve_title_ref()` against project.md's registry — which covers BOTH
# a same-batch sibling (its row is appended by `append_registry_row` before
# this file is drained, since files are processed in glob order) and an
# already-registered sibling from a prior run (same registry, no batch-scoped
# map needed for a title lookup). Still never invents an ID: no match (or
# ref is literally "none") leaves depends_on "none".
resolve_depends_on() {
  local file="$1" ref id
  ref="$(grep -m1 -E '^blocked_by_ticket:[[:space:]]*\S' "$file" 2>/dev/null \
    | sed -E 's/^blocked_by_ticket:[[:space:]]*//')"
  if [[ -n "$ref" ]]; then
    id="$(awk -F'\t' -v ref="$ref" '$1 == ref { print $2; exit }' "$BLOCKED_BY_MAP" 2>/dev/null)"
    if [[ -n "$id" ]]; then
      echo "$id"
    else
      echo "none"
    fi
    return
  fi

  # No structural header — try the **Blocked by:** prose convention. Only the
  # first blocker is honored (depends_on is single-valued, matching the
  # existing blocked_by_ticket: contract); a comma-separated list of multiple
  # blockers (e.g. "CH-TABLE-SEED-INV, CH-TABLE-IMPL") resolves to the first.
  ref="$(grep -m1 -oE '\*\*Blocked by:\*\*[[:space:]]*[^.\n]*' "$file" 2>/dev/null \
    | sed -E 's/^\*\*Blocked by:\*\*[[:space:]]*//')"
  ref="${ref%%,*}"
  ref="$(printf '%s' "$ref" | sed -E 's/^[[:space:]`]+//; s/[[:space:]`.]+$//')"
  if [[ -z "$ref" ]] || [[ "$ref" =~ ^[Nn]one$ ]]; then
    echo "none"
    return
  fi
  id="$(resolve_title_ref "$ref")"
  if [[ -n "$id" ]]; then
    echo "$id"
  else
    echo "none"
  fi
}

# Match a **Blocked by:** prose reference (a ticket title or its leading
# "slug" — the portion of the title before an em-dash separator, e.g.
# "CH-TABLE-SEED-IMPL" for the title "CH-TABLE-SEED-IMPL — Seed real row
# data...") against project.md's registry `summary` column. Tries an exact
# full-title match first, then a slug-prefix match (the ref must match the
# summary from its start AND be followed by whitespace or end-of-string, so a
# shorter ref like "CH-TABLE-SEED" does NOT falsely match "CH-TABLE-SEED-IMPL"
# mid-word). Never invents an ID — no match prints nothing.
resolve_title_ref() {
  local ref="$1"
  awk -F'|' -v ref="$ref" '
    NF >= 8 && $0 ~ /^\|[[:space:]]*[0-9]/ {
      summary=$3; gsub(/^[[:space:]]+|[[:space:]]+$/, "", summary)
      id=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
      if (summary == ref) { print id; exit }
      n = length(ref)
      if (n > 0 && substr(summary, 1, n) == ref) {
        nextch = substr(summary, n + 1, 1)
        if (nextch == "" || nextch == " ") { print id; exit }
      }
    }
  ' "$PROJ" 2>/dev/null
}

# Record this drained file's basename -> real ID so a LATER file in this same
# batch whose `blocked_by_ticket:` references this basename can resolve it.
record_batch_id() {
  local ref="$1" id="$2"
  printf '%s\t%s\n' "$ref" "$id" >> "$BLOCKED_BY_MAP"
}

# Risky-op patterns (Gating Criteria). Scanned across the whole task file so a
# risky op described in Goal, Context, or Acceptance Criteria is caught.
# Two classes, because case sensitivity differs:
#   CI — unambiguous shell/infra ops, safe to match case-insensitively.
#   CS — SQL DML keywords, matched UPPERCASE-only (case-sensitive). Real SQL in a
#        task spec is uppercase; lowercase English words "update/delete/drop/alter"
#        are NOT risky ops, so matching them case-insensitively wrongly gates every
#        "update the docs" / "delete the old reference" task. Keep these uppercase.
RISKY_OP_RE_CI='kubectl (apply|scale|delete|patch|rollout)|rm -rf|rm -f|git push --force|force.push|force-push|delete branch|branch deletion|send email|post to slack|trigger deploy|deploy pipeline'
RISKY_OP_RE_CS='INSERT |UPDATE |DELETE |DROP |ALTER |TRUNCATE'
# A RISKY_OP_RE_CI match in a clause that ALSO carries a prohibition marker is a
# constraint ("never rm -rf", "do NOT force-push", "without sending email", the
# contractions "don't/won't/isn't/can't", and "cannot"), not imperative intent —
# that clause must NOT gate. Word-bounded, case-insensitive. The contraction
# spellings (`[a-z]+n't`, `cannot`) are listed explicitly because the apostrophe
# sits between letters, so the leading `[^a-z]` boundary used for the bare words
# can never match them.
NEGATION_RE="(^|[^a-z])(never|not|n't|no|avoid|without|must not|don't|won't|isn't|can't|cannot)([^a-z]|\$)"

has_gate_reason() {
  # Explicit human override: a non-empty `gate_reason:` line forces a gate.
  grep -qE '^gate_reason:[[:space:]]*\S' "$1" 2>/dev/null
}

file_has_risky_op() {
  # CI ops: gate only on a NON-negated risky CLAUSE (skip prohibitions/constraints).
  # Markdown frequently packs several sentences onto one physical line, so a
  # whole-line negation drop (the old grep -ivE) would shadow a real imperative
  # risky op that lives in a DIFFERENT clause on the same line — a [SECURITY]
  # false-negative ("This is not optional. Run rm -rf .../dist"). Split each line
  # into clauses on sentence/`;`/`:`/`,` boundaries and gate if ANY clause carries
  # a risky op without its own negation marker (the comma boundary scopes cases
  # like "Do not stop, but git push --force ..."). Matching is case-insensitive
  # (awk tolower) to mirror the original grep -i.
  if awk -v risky="$RISKY_OP_RE_CI" -v neg="$NEGATION_RE" '
    {
      line = tolower($0)
      n = split(line, clause, /[.;:,]+/)
      for (i = 1; i <= n; i++) {
        c = clause[i]
        if (c ~ risky && c !~ neg) { found = 1; exit }
      }
    }
    END { exit found ? 0 : 1 }
  ' "$1" 2>/dev/null; then
    return 0
  fi
  # SQL DML (uppercase, case-sensitive) is unchanged — whole-file match.
  grep -qE "$RISKY_OP_RE_CS" "$1" 2>/dev/null && return 0
  return 1
}

# Gating is risk-based, not location-based. A file under gated/ or marked
# `mode: gated` is only a hint — it gates only when it carries an explicit
# `gate_reason:` line OR its content describes a genuine risky op. Safe tasks
# (e.g. inbox-log-analyzer enhancements) are de-gated to auto so the tend job
# can run them without waiting for a human "go".
inbox_mode_for() {
  local file="$1"
  if has_gate_reason "$file"; then
    echo gated
    return
  fi
  if file_has_risky_op "$file"; then
    echo gated
    return
  fi
  echo auto
}

status_for_mode() {
  local mode="$1"
  if [[ "$mode" == gated ]]; then
    echo awaiting_go
  else
    echo pending
  fi
}

append_registry_row() {
  local id="$1" summary="$2" mode="$3" status="$4" iso="$5"
  local row="| $id | $summary | $mode | 1 | $status | $iso |"
  if grep -q '^## Task Registry' "$PROJ"; then
    local last
    last="$(grep -n '^|' "$PROJ" | tail -1 | cut -d: -f1)"
    if [[ -n "$last" ]]; then
      # macOS sed: insert after last table row
      sed -i '' "${last}a\\
${row}
" "$PROJ"
    else
      echo "$row" >>"$PROJ"
    fi
  else
    echo "$row" >>"$PROJ"
  fi
  sed -i '' "s/^last_updated:.*/last_updated: $iso/" "$PROJ" 2>/dev/null || true
}

move_to_processed() {
  local src="$1"
  local base dest
  base="$(basename "$src")"
  dest="$PROCESSED/$base"
  if [[ -f "$dest" ]]; then
    if cmp -s "$src" "$dest" 2>/dev/null; then
      rm -f "$src"
    else
      mv -f "$src" "$dest"
    fi
  else
    mv -f "$src" "$dest"
  fi
}

# AT-1: emit the "gated — needs go" desktop notice exactly once per task ID, in
# pure bash (zero AI tokens). Idempotent via the gated-notified.tsv sidecar — if
# the ID is already recorded, do nothing (no second notify, no second line).
# AT-2 relies on this: the SKILL.md T-4 awaiting_go scan no longer notifies at all,
# because the one-time human signal is owned here at registration time.
notify_gated_once() {
  local id="$1" summary="$2"
  [[ -n "$id" ]] || return 0
  if [[ -f "$GATED_NOTIFIED" ]] && \
     awk -F'\t' -v id="$id" '$1 == id { found = 1 } END { exit !found }' "$GATED_NOTIFIED"; then
    return 0
  fi
  if command -v osascript >/dev/null 2>&1; then
    local safe="${summary//\"/\'}"
    osascript -e "display notification \"$safe\" with title \"Orchestrate: gated task needs your go\" subtitle \"$id\"" >/dev/null 2>&1 || true
  fi
  printf '%s\t%s\n' "$id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$GATED_NOTIFIED"
}

drain_file() {
  local file="$1"
  local rel="$2"

  [[ -f "$file" ]] || return 1
  grep -qE '^deferred_at:' "$file" 2>/dev/null && return 1

  local base processed_path
  base="$(basename "$file")"
  processed_path="$PROCESSED/$base"
  if [[ -f "$processed_path" ]] && cmp -s "$file" "$processed_path" 2>/dev/null; then
    rm -f "$file"
    return 1
  fi

  local pair fu kind
  pair="$(extract_followup_pair "$file" 2>/dev/null || true)"
  if [[ -n "$pair" ]]; then
    fu="${pair%%$'\t'*}"
    kind="${pair#*$'\t'}"
    if followup_pair_already_satisfied "$ROOT" "$fu" "$kind"; then
      move_to_processed "$file"
      log_inbox "inbox — skipped (dedup followup_for=$fu kind=$kind) from $rel"
      return 1
    fi
  fi

  ensure_project_md

  local iso id summary mode status depends_on ref_base
  iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  id="$(gen_task_id "$file")"
  summary="$(extract_title "$file")"
  mode="$(inbox_mode_for "$file")"
  status="$(status_for_mode "$mode")"
  depends_on="$(resolve_depends_on "$file")"
  ref_base="$(basename "$file" .md)"

  append_registry_row "$id" "$summary" "$mode" "$status" "$iso"
  materialize_task_file "$file" "$id" "$summary" "$mode" "$depends_on"
  record_batch_id "$ref_base" "$id"
  move_to_processed "$file"

  if [[ "$mode" == gated ]]; then
    notify_gated_once "$id" "$summary"
    log_inbox "inbox — registered (gated) \"$summary\" from $rel"
  elif [[ "$rel" == gated/* ]]; then
    log_inbox "inbox — de-gated \"$summary\" (no risky op) from $rel"
  else
    log_inbox "inbox — registered \"$summary\" from $rel"
  fi
  return 0
}

DRAINED=0
ensure_project_md

if [[ -d "$GATED" ]]; then
  for f in "$GATED"/*.md; do
    [[ -f "$f" ]] || continue
    if drain_file "$f" "gated/$(basename "$f")"; then
      DRAINED=$(( DRAINED + 1 ))
    fi
  done
fi

for f in "$INBOX"/*.md; do
  [[ -f "$f" ]] || continue
  if drain_file "$f" "$(basename "$f")"; then
    DRAINED=$(( DRAINED + 1 ))
  fi
done

echo "DRAINED=$DRAINED" >&2
