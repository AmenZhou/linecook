#!/usr/bin/env bash
# first-pass-auto-resolve.sh — evaluate trivial/agent-resolvable blockers BEFORE needs_human
# Usage: first-pass-auto-resolve.sh <project_root> <task_id>
# Exit 0 + prints category:reason on stdout when auto-resolvable; exit 1 when not.
set -euo pipefail

ROOT="${1:?usage: first-pass-auto-resolve.sh <root> <task_id>}"
TASK_ID="${2:?}"
TF="$ROOT/.orchestrate/tasks/${TASK_ID}.md"
PROJ="$ROOT/.orchestrate/project.md"

[[ -f "$TF" ]] || exit 1

# Hard guard — never first-pass resolve EXTERNAL infra or gated tasks
if grep -qE '^blocked_on:[[:space:]]*EXTERNAL' "$TF" 2>/dev/null; then
  exit 1
fi
if grep -qE '^escalation_note:' "$TF" 2>/dev/null && \
   grep -qE '^blocked_on:' "$TF" 2>/dev/null; then
  exit 1
fi
head -20 "$TF" | grep -qE '^mode:[[:space:]]*gated' && exit 1

registry_status() {
  local id="$1"
  [[ -f "$PROJ" ]] || { echo ""; return; }
  awk -F'|' -v id="$id" '
    $0 ~ "\\| " id " \\|" {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6)
      print $6
      exit
    }
  ' "$PROJ"
}

# C2 — deferral / closure language in blockers or AC checklist
# The "closed —" alternative is checked separately, on a copy of the file with
# any line mentioning the security fail-safe phrase "fail closed" / "fail-closed" /
# "failed closed" stripped out first — otherwise a legitimate design-principle
# comment like "(fail closed — additive, not a loosening)" false-positives as a
# task-closure statement and would send an unresolved blocker back to pending.
if grep -qiE '(deferred( to)?|out of scope|not a blocker|no action needed|Forbidden)' "$TF" || \
   { grep -viE 'fail(ed)?[-[:space:]]?closed' "$TF" | grep -qiE 'closed[[:space:]]*—'; }; then
  printf '%s\n' "C2:deferral-or-closure-language"
  exit 0
fi

# C4 — referenced report file has closure marker
# Skip known skill-doc / non-report files. SKILL.md (and other task-orchestrate
# skill docs) describe the C4 pattern itself in their own prose — e.g. SKILL.md
# literally contains the strings "**Status:** ✅" and "**Closed:**" while
# explaining what C4 matches — so a naive scan self-matches on SKILL.md's
# documentation, not a real closure report. These paths are never genuine
# report/closure files, so exclude them from the referenced-file scan.
# Defined with () (subshell), not {}, so 'shopt -s nocasematch' is scoped to
# this function's invocation only and never leaks into the calling script —
# the case match below must be case-INSENSITIVE (case-insensitive filesystems
# like default APFS let a wrong-case path resolve to the real SKILL.md even
# though a case-sensitive glob wouldn't match it — see 20260721-inbox-A1CF).
is_skill_doc_ref() (
  shopt -s nocasematch
  case "$1" in
    */SKILL.md|SKILL.md|*/.claude/skills/*|*/ai-toolbox/skills/*|*/.cursor/skills/*)
      return 0 ;;
    *)
      return 1 ;;
  esac
)
while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  ref="${ref/#\~/$HOME}"
  is_skill_doc_ref "$ref" && continue
  if [[ -f "$ref" ]] && grep -qE '\*\*(Closed|Status):\*\*.*(✅|Closed|CONFIRMED)' "$ref" 2>/dev/null; then
    printf '%s\n' "C4:report-closure:$ref"
    exit 0
  fi
done < <(grep -oE '[~/][^ )]+\.(md|txt)' "$TF" 2>/dev/null | sort -u || true)

# C5 — downstream / referenced task already complete in registry
while IFS= read -r ref_id; do
  [[ -z "$ref_id" ]] && continue
  st="$(registry_status "$ref_id")"
  if [[ "$st" == "complete" ]]; then
    printf '%s\n' "C5:downstream-complete:$ref_id"
    exit 0
  fi
done < <(grep -oE '20[0-9]{6}(-inbox)?-[A-Za-z0-9]+' "$TF" 2>/dev/null | sort -u || true)

# C1 — creatable missing directory under project root (safe paths only)
if grep -qiE 'missing dir|ENOENT.*mkdir|no such file.*directory' "$TF"; then
  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    case "$dir" in
      "$ROOT"/*|.orchestrate/*)
        if [[ ! -d "$ROOT/$dir" && ! -d "$dir" ]]; then
          target="${dir/#$ROOT\//}"
          target="${target#.orchestrate/.orchestrate/}"
          mkdir -p "$ROOT/$target" 2>/dev/null && {
            printf '%s\n' "C1:mkdir:$target"
            exit 0
          }
        fi
        ;;
    esac
  done < <(grep -oE '\.orchestrate/[a-zA-Z0-9_./-]+' "$TF" 2>/dev/null || true)
fi

# C3 — one-shot retryable transient (only when retries not exhausted)
if grep -qiE '(EPIPE|ETIMEDOUT|ECONNRESET|429|session limit|connection lost)' "$TF" && \
   ! grep -qE 'retries:[[:space:]]*[3-9]' "$TF" 2>/dev/null; then
  printf '%s\n' "C3:transient-retry-once"
  exit 0
fi

# C6 — locally-executable action mislabeled as a human block.
# Cross-project/local file writes, reversible settings/config writes, and runnable
# scripts are NOT human blockers — the agent can do them itself. These over-fire the
# needs_human gate (see 59FA cross-project write, 1EC4 settings.json write).
# Guard: never apply when the block is a genuine external dependency.
if ! grep -qiE '(kubectl|live cluster|load.?ramp|external service|no.?master|credential|human (decision|approval)|missing (secret|token|password))' "$TF" 2>/dev/null; then
  if grep -qiE '(cross.?project (file )?write|local (file )?write|settings\.json|config write|reversible (settings|config)|agent\.conf|run (a |the )?(local )?script)' "$TF" 2>/dev/null; then
    printf '%s\n' "C6:locally-executable-not-a-block"
    exit 0
  fi
fi

exit 1
