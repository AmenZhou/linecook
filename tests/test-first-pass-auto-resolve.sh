#!/usr/bin/env bash
# test-first-pass-auto-resolve.sh — regression for task 20260721-inbox-CD34.
#
# Background: first-pass-auto-resolve.sh's C4 check ("referenced report file
# has closure marker") scans every .md/.txt path referenced anywhere in a
# task file and greps that file for "**Closed:**" / "**Status:** ✅" /
# "**dsp-service GO/NO-GO verdict:**". When a task references SKILL.md
# (extremely common — any review/tests follow-up ticket lists its parent's
# full files_changed:, and SKILL.md is often one of them), the check matched
# SKILL.md's OWN documentation prose describing the C4 pattern itself
# (SKILL.md literally contains the strings "**Status:** ✅" and "**Closed:**"
# while explaining what C4 does) — a false positive unrelated to whether the
# actual task is resolved. This was caught by manual verification on tasks
# 20260720-inbox-CA2E and 20260720-inbox-2DD0 before acting on it (would have
# skipped real review/test work if auto-resolved blindly).
#
# Fix asserted here: the C4 referenced-file scan now skips any ref matching
# SKILL.md / known task-orchestrate skill-doc paths (*/SKILL.md, SKILL.md,
# */.claude/skills/*, */ai-toolbox/skills/*, */.cursor/skills/*) BEFORE
# grepping it for closure markers, so its own doc prose can never trigger a
# false C4. The true-positive path (a genuine report file with a real
# closure marker) must still resolve correctly.
#
# Style mirrors test-phase-log-retry-label.sh's mk_root() fixture pattern:
# build a minimal mock .orchestrate/ control plane, drive the real
# first-pass-auto-resolve.sh against it, and assert on stdout/exit code —
# no mocking of the script under test itself.
set -uo pipefail

PASS=0
FAIL=0

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$PROJECT_ROOT/bin" ]] || { echo "FATAL: $PROJECT_ROOT/bin not found — PROJECT_ROOT path computation is broken (expected .../task-orchestrate/bin)" >&2; exit 1; }
FPS="${FPS:-$PROJECT_ROOT/bin/first-pass-auto-resolve.sh}"
FPS_SRC="${FPS_SRC:-$FPS}"
REAL_SKILL_MD="${REAL_SKILL_MD:-$PROJECT_ROOT/skill/SKILL.md}"

TMP=""
cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"; }
trap cleanup EXIT

echo ""
echo "── first-pass-auto-resolve C4 SKILL.md false-positive regression (20260721-inbox-CD34) ───"

echo ""
echo "0. Prerequisites"
[[ -f "$FPS" ]] && ok "first-pass-auto-resolve.sh present" || { fail "first-pass-auto-resolve.sh missing at $FPS"; }
bash -n "$FPS" 2>/dev/null && ok "first-pass-auto-resolve.sh bash syntax valid" || fail "first-pass-auto-resolve.sh syntax error"
if [[ -f "$FPS_SRC" ]] && cmp -s "$FPS_SRC" "$FPS" 2>/dev/null; then
  ok "installed first-pass-auto-resolve.sh matches ai-toolbox source"
elif [[ -f "$FPS_SRC" ]]; then
  fail "installed first-pass-auto-resolve.sh stale vs ai-toolbox source — run sync"
fi

# mk_root — builds a fresh mock .orchestrate/ control plane, echoes its path.
mk_root() {
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/.orchestrate/tasks"
  echo "$tmp"
}

echo ""
echo "1. THE regression: task file referencing the real, live SKILL.md (which itself"
echo "   contains the literal C4 marker strings '**Status:** ✅' and '**Closed:**' in its"
echo "   own prose describing C4) must NOT be classified as a false C4 closure match"
if [[ -f "$REAL_SKILL_MD" ]] && grep -qE '\*\*(Closed|Status):\*\*' "$REAL_SKILL_MD" 2>/dev/null; then
  ok "fixture precondition: real SKILL.md contains the C4 marker substrings (as expected)"
else
  fail "fixture precondition: real SKILL.md not found or lost its C4 marker substrings at $REAL_SKILL_MD"
fi
TMP="$(mk_root)"
ID="20260721-tst-ca2e"
cat > "$TMP/.orchestrate/tasks/${ID}.md" <<EOF
id: $ID
task: review/tests follow-up referencing parent files_changed
mode: auto

## Context
files_changed: $REAL_SKILL_MD, some/unrelated/file.ts
EOF
OUT="$(bash "$FPS" "$TMP" "$ID" 2>/dev/null)"; RC=$?
if [[ "$RC" -eq 0 && "$OUT" == C4:* ]]; then
  fail "SKILL.md reference wrongly classified as C4 closure — false positive NOT fixed ($OUT)"
else
  ok "SKILL.md reference does NOT trigger a false C4 (rc=$RC, out='${OUT:-<empty>}')"
fi
cleanup; TMP=""

echo ""
echo "2. Generic path-pattern skip: a doc file under an ai-toolbox/skills/ tree (not named"
echo "   SKILL.md) that happens to contain the marker strings must also be skipped"
TMP="$(mk_root)"
mkdir -p "$TMP/ai-toolbox/skills/task-orchestrate"
cat > "$TMP/ai-toolbox/skills/task-orchestrate/notes.md" <<'EOF'
This doc describes the pattern: **Status:** ✅ and **Closed:** are markers, not a real report.
EOF
ID="20260721-tst-genericdoc"
cat > "$TMP/.orchestrate/tasks/${ID}.md" <<EOF
id: $ID
task: follow-up referencing a skill-tree doc file
mode: auto

## Context
See $TMP/ai-toolbox/skills/task-orchestrate/notes.md for background.
EOF
OUT="$(bash "$FPS" "$TMP" "$ID" 2>/dev/null)"; RC=$?
if [[ "$RC" -eq 0 && "$OUT" == C4:* ]]; then
  fail "ai-toolbox/skills/ doc wrongly classified as C4 closure ($OUT)"
else
  ok "ai-toolbox/skills/ doc reference does NOT trigger a false C4 (rc=$RC)"
fi
cleanup; TMP=""

echo ""
echo "3. True-positive path preserved: a genuine (non-skill-doc) report file with a real"
echo "   closure marker must still resolve via C4"
TMP="$(mk_root)"
mkdir -p "$TMP/reports"
cat > "$TMP/reports/real-report.md" <<'EOF'
## Report

**Status:** ✅ done, everything verified.
**Closed:** yes
EOF
ID="20260721-tst-truepos"
cat > "$TMP/.orchestrate/tasks/${ID}.md" <<EOF
id: $ID
task: follow-up referencing a genuine closure report
mode: auto

## Context
See report at $TMP/reports/real-report.md
EOF
OUT="$(bash "$FPS" "$TMP" "$ID" 2>/dev/null)"; RC=$?
if [[ "$RC" -eq 0 && "$OUT" == C4:report-closure:*real-report.md ]]; then
  ok "genuine closure report still resolves via C4 (true-positive path not regressed)"
else
  fail "genuine closure report did NOT resolve via C4 as expected (rc=$RC, out='${OUT:-<empty>}')"
fi
cleanup; TMP=""

echo ""
echo "4. FIXED (20260721-inbox-A1CF): is_skill_doc_ref's exact-name patterns"
echo "   (*/SKILL.md, SKILL.md) now match case-INSENSITIVELY (scoped 'shopt -s"
echo "   nocasematch' inside is_skill_doc_ref, via a () subshell so it never leaks"
echo "   into the calling script). Previously, on a case-insensitive filesystem (APFS"
echo "   default on macOS — this dev machine), a task referencing a skill doc via a"
echo "   wrong-case path (e.g. 'skill.md') that lives OUTSIDE the three hardcoded"
echo "   directory trees (.claude/skills/, ai-toolbox/skills/, .cursor/skills/ — those"
echo "   catch any case via directory-prefix match regardless of filename case) bypassed"
echo "   the guard entirely, reproducing the exact CD34 self-referential false positive"
echo "   via a case variant. Real example found on this machine: a SKILL.md shipped by"
echo "   a pip package under .venv-obsidian-wiki/.../_data/skills/<name>/SKILL.md — not"
echo "   under any of the three exempted trees, so only the bare-filename patterns"
echo "   protect it, and those used to be defeated by case variation. This test now"
echo "   asserts the CORRECT (fixed) behavior: the wrong-case ref must be recognized"
echo "   as a skill-doc ref and must NOT trigger a false C4."
TMP="$(mk_root)"
mkdir -p "$TMP/some-plugin"
cat > "$TMP/some-plugin/SKILL.md" <<'EOF'
# Some Plugin Skill
This doc explains C4: **Status:** ✅ and **Closed:** are marker strings, not real closures.
EOF
ID="20260721-tst-casebypass"
cat > "$TMP/.orchestrate/tasks/${ID}.md" <<EOF
id: $ID
task: follow-up referencing a non-tree skill doc via a wrong-case path
mode: auto

## Context
See $TMP/some-plugin/skill.md for background.
EOF
if [[ -f "$TMP/some-plugin/skill.md" ]]; then
  OUT="$(bash "$FPS" "$TMP" "$ID" 2>/dev/null)"; RC=$?
  if [[ "$RC" -eq 0 && "$OUT" == C4:* ]]; then
    fail "wrong-case skill-doc ref outside the exempted trees still false-positives on this case-insensitive fs (rc=$RC, out='$OUT') — is_skill_doc_ref fix did not take effect"
  else
    ok "wrong-case skill-doc ref does NOT trigger a false C4 (rc=$RC, out='${OUT:-<empty>}') — case-insensitivity fix confirmed"
  fi
else
  ok "case-insensitive filesystem precondition not met on this host (lowercase ref did not resolve) — case-bypass scenario not applicable here, skipping"
fi
cleanup; TMP=""

echo ""
echo "5. Coverage gap closed (20260721-inbox-D159 follow-up): test 4 only exercised a"
echo "   wrong-case FILENAME (skill.md) outside the exempted directory trees. It never"
echo "   exercised a wrong-case DIRECTORY-PREFIX ref (e.g. '.Claude/Skills/' instead of"
echo "   '.claude/skills/') for the generic tree-skip patterns (*/.claude/skills/*,"
echo "   */ai-toolbox/skills/*, */.cursor/skills/*). Since is_skill_doc_ref's"
echo "   'shopt -s nocasematch' is scoped to the whole case statement, it should also"
echo "   cover this — verified here so the directory-prefix path is no longer only"
echo "   inferred from the filename-case test."
TMP="$(mk_root)"
mkdir -p "$TMP/.Claude/Skills/task-orchestrate"
cat > "$TMP/.Claude/Skills/task-orchestrate/notes.md" <<'EOF'
This doc describes the pattern: **Status:** ✅ and **Closed:** are markers, not a real report.
EOF
ID="20260721-tst-dirprefixcase"
cat > "$TMP/.orchestrate/tasks/${ID}.md" <<EOF
id: $ID
task: follow-up referencing a skill-tree doc via a wrong-case directory prefix
mode: auto

## Context
See $TMP/.Claude/Skills/task-orchestrate/notes.md for background.
EOF
OUT="$(bash "$FPS" "$TMP" "$ID" 2>/dev/null)"; RC=$?
if [[ "$RC" -eq 0 && "$OUT" == C4:* ]]; then
  fail "wrong-case directory-prefix ref (.Claude/Skills/) wrongly classified as C4 closure ($OUT)"
else
  ok "wrong-case directory-prefix ref (.Claude/Skills/) does NOT trigger a false C4 (rc=$RC, out='${OUT:-<empty>}')"
fi
cleanup; TMP=""

echo ""
echo "6. C2 fix (20260724-inbox-D868): 'fail closed' security terminology must not"
echo "   false-positive the C2 deferral/closure check, but a genuine 'closed —'"
echo "   task-closure statement must still be recognized."
TMP="$(mk_root)"
ID="20260724-tst-failclosed"
cat > "$TMP/.orchestrate/tasks/${ID}.md" <<EOF
id: $ID
task: fix kube hook regex
mode: auto

### Phase 1
Fix must be additive-only: strip only a small explicit allowlist of known global
flags before Tier matching; anything else preceding the verb stays unmatched
(fail closed — additive, not a loosening).
EOF
OUT="$(bash "$FPS" "$TMP" "$ID" 2>/dev/null)"; RC=$?
if [[ "$RC" -eq 0 && "$OUT" == C2:* ]]; then
  fail "'fail closed —' security phrase wrongly classified as C2 closure ($OUT)"
else
  ok "'fail closed —' security phrase does NOT trigger a false C2 (rc=$RC, out='${OUT:-<empty>}')"
fi
cleanup; TMP=""

TMP="$(mk_root)"
ID="20260724-tst-genuineclosed"
cat > "$TMP/.orchestrate/tasks/${ID}.md" <<EOF
id: $ID
task: follow-up ticket
mode: auto

### Phase 1
blockers: this item is closed — superseded by 20260724-inbox-0000
EOF
OUT="$(bash "$FPS" "$TMP" "$ID" 2>/dev/null)"; RC=$?
if [[ "$RC" -eq 0 && "$OUT" == C2:* ]]; then
  ok "genuine 'closed —' deferral statement still resolves via C2 (true-positive path not regressed)"
else
  fail "genuine 'closed —' deferral statement did NOT resolve via C2 as expected (rc=$RC, out='${OUT:-<empty>}')"
fi
cleanup; TMP=""

echo ""
echo "── first-pass-auto-resolve C4 SKILL.md regression: $PASS passed, $FAIL failed ───"
[[ "$FAIL" -eq 0 ]]
