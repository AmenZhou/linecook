#!/usr/bin/env bash
# test-update-registry-row.sh — regression for task 20260708-inbox-25CA.
#
# Background: hand-rolled positional awk updates to project.md's registry table
# have repeatedly gotten the field indices wrong (e.g. writing a phase number
# into the mode column, or a timestamp into the status column) while NF stays 8
# with an empty trailing $8 — the structural invariant check misses it; the
# domain check catches it only after the fact. update-registry-row.sh removes
# the need to hand-derive field positions: callers pass named values, the
# script maps them onto the correct columns and refuses on bad input instead of
# writing anything.
set -euo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -d "$PROJECT_ROOT/bin" ]] || { echo "FATAL: $PROJECT_ROOT/bin not found — PROJECT_ROOT path computation is broken (expected .../task-orchestrate/bin)" >&2; exit 1; }
HELPER="${HELPER:-$PROJECT_ROOT/bin/update-registry-row.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=""
cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"; }
trap cleanup EXIT

seed_registry() {
  local dir="$1"
  mkdir -p "$dir/.orchestrate"
  cat > "$dir/.orchestrate/project.md" << 'EOF'
# Orchestrate — update-registry-row test
## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
| 20260101-target | Task with a multi-word summary | auto | 1 | pending | 2026-01-01T00:00:00Z |
| 20260101-other | another row untouched | gated | 4 | awaiting_go | 2026-01-01T00:02:00Z |
EOF
}

# Count malformed data rows (same NF==8 + domain invariant SKILL.md/test-registry-invariant.sh use).
count_bad_rows() {
  awk -F'|' '
    /^\|[[:space:]]*[0-9]/ {
      t=$8; gsub(/[[:space:]]/,"",t)
      m=$4; gsub(/^[[:space:]]+|[[:space:]]+$/,"",m)
      s=$6; gsub(/^[[:space:]]+|[[:space:]]+$/,"",s)
      mode_ok = (m=="auto" || m=="gated")
      status_ok = (s=="pending" || s=="running" || s=="awaiting_go" || s=="awaiting_critic" || s=="complete" || s=="failed" || s=="needs_human")
      if (NF!=8 || t!="" || !mode_ok || !status_ok) c++
    }
    END{print c+0}' "$1" 2>/dev/null || echo 0
}

echo ""
echo "── update-registry-row.sh — test suite ───────"

echo ""
echo "1. Happy path — flips mode/current_phase/status/last_activity by name"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/urr-test.XXXXXX")"
seed_registry "$TMP"
if bash "$HELPER" "$TMP" 20260101-target gated 3 complete 2026-07-08T15:00:00Z; then
  ok "helper exits 0 on a valid update"
else
  fail "helper exited non-zero on a valid update"
fi

ROW="$(grep '20260101-target' "$TMP/.orchestrate/project.md")"
if echo "$ROW" | grep -qE '\| gated \| 3 \| complete \| 2026-07-08T15:00:00Z \|$'; then
  ok "target row correctly updated (mode=gated, phase=3, status=complete, ts set)"
else
  fail "target row not updated as expected: $ROW"
fi

if echo "$ROW" | grep -qE '^\| 20260101-target \| Task with a multi-word summary \|'; then
  ok "summary column left untouched"
else
  fail "summary column was unexpectedly modified: $ROW"
fi

[[ "$(count_bad_rows "$TMP/.orchestrate/project.md")" -eq 0 ]] && \
  ok "no malformed rows after update (NF==8 + domain invariant holds)" || \
  fail "malformed rows detected after update"

echo ""
echo "2. Unaffected rows are byte-identical"
OTHER_ROW="$(grep '20260101-other' "$TMP/.orchestrate/project.md")"
if [[ "$OTHER_ROW" == "| 20260101-other | another row untouched | gated | 4 | awaiting_go | 2026-01-01T00:02:00Z |" ]]; then
  ok "unrelated row untouched"
else
  fail "unrelated row was modified: $OTHER_ROW"
fi

echo ""
echo "3. Idempotent — rerunning with same args produces byte-identical output"
cp "$TMP/.orchestrate/project.md" "$TMP/before.md"
bash "$HELPER" "$TMP" 20260101-target gated 3 complete 2026-07-08T15:00:00Z
if diff -q "$TMP/before.md" "$TMP/.orchestrate/project.md" >/dev/null; then
  ok "rerun with identical args produces byte-identical file"
else
  fail "rerun with identical args changed the file"
fi

echo ""
echo "4. No phantom columns introduced (NF stays 8 across repeated updates)"
bash "$HELPER" "$TMP" 20260101-target auto 5 running 2026-07-08T16:00:00Z >/dev/null
NF_CHECK="$(awk -F'|' '/20260101-target/{print NF}' "$TMP/.orchestrate/project.md")"
[[ "$NF_CHECK" -eq 8 ]] && ok "row still has NF==8 after a second distinct update" || \
  fail "row has NF=$NF_CHECK after a second update (expected 8)"

echo ""
echo "5. Bad-enum rejection — invalid mode refuses without touching the file"
cp "$TMP/.orchestrate/project.md" "$TMP/before2.md"
if bash "$HELPER" "$TMP" 20260101-other 2 1 complete 2026-07-08T17:00:00Z 2>/dev/null; then
  fail "helper accepted an invalid mode ('2')"
else
  ok "helper refused an invalid mode ('2')"
fi
diff -q "$TMP/before2.md" "$TMP/.orchestrate/project.md" >/dev/null && \
  ok "file untouched after invalid-mode rejection" || \
  fail "file was modified despite invalid-mode rejection"

echo ""
echo "6. Bad-enum rejection — invalid status refuses without touching the file"
if bash "$HELPER" "$TMP" 20260101-other gated 1 finished 2026-07-08T17:00:00Z 2>/dev/null; then
  fail "helper accepted an invalid status ('finished')"
else
  ok "helper refused an invalid status ('finished')"
fi
diff -q "$TMP/before2.md" "$TMP/.orchestrate/project.md" >/dev/null && \
  ok "file untouched after invalid-status rejection" || \
  fail "file was modified despite invalid-status rejection"

echo ""
echo "7. Unknown ID refuses without touching the file"
if bash "$HELPER" "$TMP" 99999999-nope auto 1 complete 2026-07-08T17:00:00Z 2>/dev/null; then
  fail "helper accepted an unknown ID"
else
  ok "helper refused an unknown ID"
fi
diff -q "$TMP/before2.md" "$TMP/.orchestrate/project.md" >/dev/null && \
  ok "file untouched after unknown-ID rejection" || \
  fail "file was modified despite unknown-ID rejection"

echo ""
echo "8. Missing project.md refuses cleanly"
EMPTY_TMP="$(mktemp -d "${TMPDIR:-/tmp}/urr-test-empty.XXXXXX")"
if bash "$HELPER" "$EMPTY_TMP" 20260101-target auto 1 complete 2026-07-08T17:00:00Z 2>/dev/null; then
  fail "helper accepted a root with no project.md"
else
  ok "helper refused a root with no project.md"
fi
rm -rf "$EMPTY_TMP"

echo ""
echo "── update-registry-row.sh: $PASS passed, $FAIL failed ───"
[[ "$FAIL" -eq 0 ]]
