#!/usr/bin/env bash
# test-append-manifest-line.sh — regression for task 20260725-inbox-72BB.
#
# Background: prior tend sessions repeatedly hand-typed a bracket-timestamp
# variant (`[YYYYMMDD-HHMMSS] ID — summary · project · tags: ... [filename]`)
# directly into orchestrate-history/MANIFEST.md instead of the canonical
# pipe-delimited format, because no script owned this write path. This test
# verifies append-manifest-line.sh always produces a well-formed line and
# refuses malformed input instead of writing anything.
set -euo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$PROJECT_ROOT/bin" ]] || { echo "FATAL: $PROJECT_ROOT/bin not found — PROJECT_ROOT path computation is broken (expected .../task-orchestrate/bin)" >&2; exit 1; }
HELPER="${HELPER:-$PROJECT_ROOT/bin/append-manifest-line.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=""
cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"; }
trap cleanup EXIT

seed_manifest() {
  local dir="$1"
  mkdir -p "$dir/orchestrate-history"
  cat > "$dir/orchestrate-history/MANIFEST.md" << 'EOF'
# Orchestrate History MANIFEST

One line per archived run. grep-friendly: `grep "exec-1\|phase2" MANIFEST.md`
Format: `YYYY-MM-DD | filename | task summary | tag1, tag2, ...`
---
2026-01-01 | 20260101-000000-existing-task.md | pre-existing entry | orchestrate, seed
EOF
}

echo ""
echo "── append-manifest-line.sh — test suite ───────"

echo ""
echo "1. Happy path — appends a well-formed canonical line"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/aml-test.XXXXXX")"
seed_manifest "$TMP"
if bash "$HELPER" "$TMP" 2026-07-25 20260725-999999-test-task.md "test summary" "orchestrate, tests"; then
  ok "helper exits 0 on a valid append"
else
  fail "helper exited non-zero on a valid append"
fi

LAST_LINE="$(tail -1 "$TMP/orchestrate-history/MANIFEST.md")"
if [[ "$LAST_LINE" == "2026-07-25 | 20260725-999999-test-task.md | test summary | orchestrate, tests" ]]; then
  ok "appended line matches exact canonical format"
else
  fail "appended line malformed: $LAST_LINE"
fi

echo ""
echo "2. Pre-existing content untouched"
FIRST_ENTRY="$(sed -n '6p' "$TMP/orchestrate-history/MANIFEST.md")"
if [[ "$FIRST_ENTRY" == "2026-01-01 | 20260101-000000-existing-task.md | pre-existing entry | orchestrate, seed" ]]; then
  ok "pre-existing entry left untouched"
else
  fail "pre-existing entry was modified: $FIRST_ENTRY"
fi

echo ""
echo "3. Never produces a malformed line (matches SKILL.md test-task-orchestrate.sh's check)"
BAD_LINES="$(grep -vE '^#|^$|^---$|^[0-9]{4}-[0-9]{2}-[0-9]{2} \|' "$TMP/orchestrate-history/MANIFEST.md" | grep -E '^[[:space:]]*(\||-|[0-9]{8}-)' || true)"
[[ -z "$BAD_LINES" ]] && ok "no malformed lines after append" || fail "malformed lines present: $BAD_LINES"

echo ""
echo "4. Rejects invalid date format without writing"
cp "$TMP/orchestrate-history/MANIFEST.md" "$TMP/before.md"
if bash "$HELPER" "$TMP" 07-25-2026 20260725-bad.md "bad date" "tag" 2>/dev/null; then
  fail "helper accepted an invalid date ('07-25-2026')"
else
  ok "helper refused an invalid date ('07-25-2026')"
fi
diff -q "$TMP/before.md" "$TMP/orchestrate-history/MANIFEST.md" >/dev/null && \
  ok "file untouched after invalid-date rejection" || \
  fail "file was modified despite invalid-date rejection"

echo ""
echo "5. Rejects a filename containing a literal pipe"
if bash "$HELPER" "$TMP" 2026-07-25 "bad|file.md" "summary" "tag" 2>/dev/null; then
  fail "helper accepted a filename containing '|'"
else
  ok "helper refused a filename containing '|'"
fi
diff -q "$TMP/before.md" "$TMP/orchestrate-history/MANIFEST.md" >/dev/null && \
  ok "file untouched after pipe-in-filename rejection" || \
  fail "file was modified despite pipe-in-filename rejection"

echo ""
echo "6. Rejects a summary containing a literal pipe"
if bash "$HELPER" "$TMP" 2026-07-25 "file.md" "bad | summary" "tag" 2>/dev/null; then
  fail "helper accepted a summary containing '|'"
else
  ok "helper refused a summary containing '|'"
fi
diff -q "$TMP/before.md" "$TMP/orchestrate-history/MANIFEST.md" >/dev/null && \
  ok "file untouched after pipe-in-summary rejection" || \
  fail "file was modified despite pipe-in-summary rejection"

echo ""
echo "6b. Rejects a summary containing a literal newline (would split into multiple lines)"
NEWLINE_SUMMARY="$(printf 'evil summary\nfake injected line')"
if bash "$HELPER" "$TMP" 2026-07-25 "file.md" "$NEWLINE_SUMMARY" "tag" 2>/dev/null; then
  fail "helper accepted a summary containing a newline"
else
  ok "helper refused a summary containing a newline"
fi
diff -q "$TMP/before.md" "$TMP/orchestrate-history/MANIFEST.md" >/dev/null && \
  ok "file untouched after newline-in-summary rejection" || \
  fail "file was modified despite newline-in-summary rejection"

echo ""
echo "7. Missing MANIFEST.md refuses cleanly"
EMPTY_TMP="$(mktemp -d "${TMPDIR:-/tmp}/aml-test-empty.XXXXXX")"
if bash "$HELPER" "$EMPTY_TMP" 2026-07-25 file.md summary tag 2>/dev/null; then
  fail "helper accepted a root with no MANIFEST.md"
else
  ok "helper refused a root with no MANIFEST.md"
fi
rm -rf "$EMPTY_TMP"

echo ""
echo "8. Multiple appends stay well-formed and ordered"
bash "$HELPER" "$TMP" 2026-07-26 20260726-second.md "second entry" "orchestrate" >/dev/null
LAST_TWO="$(tail -2 "$TMP/orchestrate-history/MANIFEST.md")"
EXPECTED="2026-07-25 | 20260725-999999-test-task.md | test summary | orchestrate, tests
2026-07-26 | 20260726-second.md | second entry | orchestrate"
[[ "$LAST_TWO" == "$EXPECTED" ]] && ok "sequential appends preserve order and format" || \
  fail "sequential appends produced unexpected content: $LAST_TWO"

echo ""
echo "── append-manifest-line.sh: $PASS passed, $FAIL failed ───"
[[ "$FAIL" -eq 0 ]]
