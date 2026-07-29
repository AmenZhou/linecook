#!/usr/bin/env bash
# test-followup-dedup.sh — unit tests for bin/followup-dedup.sh
#
# followup-dedup.sh is a sourced library (not executable) exporting 4
# functions used by drain-inbox.sh to dedup (followup_for, kind) pairs:
#   - extract_followup_pair(file)
#   - _pair_in_files(fu, kind, files...)          [internal helper]
#   - followup_pair_exists(root, fu, kind)
#   - followup_pair_already_satisfied(root, fu, kind)
#
# This suite sources the library directly and drives each function against
# temp fixture files/trees — no exec of the file (it has no shebang-driven
# entrypoint of its own).
set -uo pipefail

PASS=0
FAIL=0
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$REPO_ROOT/bin"
FOLLOWUP_DEDUP_SRC="${FOLLOWUP_DEDUP_SRC:-$BIN_DIR/followup-dedup.sh}"

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

[[ -f "$FOLLOWUP_DEDUP_SRC" ]] || { echo "FATAL: $FOLLOWUP_DEDUP_SRC not found" >&2; exit 1; }
# shellcheck disable=SC1090
source "$FOLLOWUP_DEDUP_SRC"

TMP=""
cleanup() { [[ -n "$TMP" && -d "$TMP" ]] && rm -rf "$TMP"; return 0; }  # return 0: an EXIT trap must never clobber the script's exit status
trap cleanup EXIT

new_tmp() {
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/followup-dedup-test.XXXXXX")"
}

echo "1. extract_followup_pair — both followup_for and kind present"
new_tmp
f="$TMP/complete.md"
cat > "$f" << 'EOF'
---
id: 20260728-inbox-AAAA
followup_for: 20260720-inbox-1111
kind: review
---
body
EOF
out="$(extract_followup_pair "$f")"
rc=$?
if [[ $rc -eq 0 && "$out" == $'20260720-inbox-1111\treview' ]]; then
  ok "extract_followup_pair prints correct 'id<TAB>kind' pair and returns 0"
else
  fail "extract_followup_pair — got rc=$rc out='$out', want rc=0 out='20260720-inbox-1111<TAB>review'"
fi

echo ""
echo "2. extract_followup_pair — missing kind: returns non-zero, prints nothing"
new_tmp
f="$TMP/missing-kind.md"
cat > "$f" << 'EOF'
---
id: 20260728-inbox-BBBB
followup_for: 20260720-inbox-1111
---
body
EOF
out="$(extract_followup_pair "$f")"
rc=$?
if [[ $rc -ne 0 && -z "$out" ]]; then
  ok "extract_followup_pair on file missing kind: returns non-zero, prints nothing"
else
  fail "extract_followup_pair (missing kind) — got rc=$rc out='$out', want rc!=0 out=''"
fi

echo ""
echo "2b. extract_followup_pair — missing followup_for: returns non-zero, prints nothing"
new_tmp
f="$TMP/missing-followup-for.md"
cat > "$f" << 'EOF'
---
id: 20260728-inbox-CCCC
kind: review
---
body
EOF
out="$(extract_followup_pair "$f")"
rc=$?
if [[ $rc -ne 0 && -z "$out" ]]; then
  ok "extract_followup_pair on file missing followup_for: returns non-zero, prints nothing"
else
  fail "extract_followup_pair (missing followup_for) — got rc=$rc out='$out', want rc!=0 out=''"
fi

echo ""
echo "3. extract_followup_pair — nonexistent file path returns 1"
new_tmp
extract_followup_pair "$TMP/does-not-exist.md" >/tmp/followup-dedup-test-out.$$ 2>&1
rc=$?
out="$(cat /tmp/followup-dedup-test-out.$$)"
rm -f /tmp/followup-dedup-test-out.$$
if [[ $rc -eq 1 && -z "$out" ]]; then
  ok "extract_followup_pair on nonexistent file returns 1, prints nothing"
else
  fail "extract_followup_pair (nonexistent file) — got rc=$rc out='$out', want rc=1 out=''"
fi

echo ""
echo "4. followup_pair_exists — matching pair present / absent"
new_tmp
mkdir -p "$TMP/.orchestrate/inbox/gated" "$TMP/.orchestrate/inbox/processed" \
         "$TMP/.orchestrate/tasks" "$TMP/orchestrate-history"
cat > "$TMP/.orchestrate/inbox/gated/dup.md" << 'EOF'
---
id: 20260728-inbox-DDDD
followup_for: 20260721-inbox-2222
kind: tests
---
body
EOF
if followup_pair_exists "$TMP" "20260721-inbox-2222" "tests"; then
  ok "followup_pair_exists finds a matching pair in inbox/gated/"
else
  fail "followup_pair_exists did not find the matching pair in inbox/gated/"
fi
if followup_pair_exists "$TMP" "20260721-inbox-9999" "tests"; then
  fail "followup_pair_exists false-positived on a followup_for with no matching file anywhere"
else
  ok "followup_pair_exists returns 1 when no matching file exists anywhere"
fi

echo ""
echo "5. followup_pair_already_satisfied — history vs processed vs live inbox"
new_tmp
mkdir -p "$TMP/.orchestrate/inbox/processed" "$TMP/orchestrate-history"
cat > "$TMP/orchestrate-history/20260710-hist-EEEE.md" << 'EOF'
---
id: 20260710-hist-EEEE
followup_for: 20260701-inbox-3333
kind: wiki-sync
---
body
EOF
if followup_pair_already_satisfied "$TMP" "20260701-inbox-3333" "wiki-sync"; then
  ok "followup_pair_already_satisfied returns 0 for a pair present only in orchestrate-history/"
else
  fail "followup_pair_already_satisfied missed a pair present in orchestrate-history/"
fi

new_tmp
mkdir -p "$TMP/.orchestrate/inbox/processed" "$TMP/orchestrate-history"
cat > "$TMP/.orchestrate/inbox/processed/20260711-proc-FFFF.md" << 'EOF'
---
id: 20260711-proc-FFFF
followup_for: 20260702-inbox-4444
kind: review
---
body
EOF
if followup_pair_already_satisfied "$TMP" "20260702-inbox-4444" "review"; then
  ok "followup_pair_already_satisfied returns 0 for a pair present only in inbox/processed/"
else
  fail "followup_pair_already_satisfied missed a pair present in inbox/processed/"
fi

new_tmp
mkdir -p "$TMP/.orchestrate/inbox" "$TMP/.orchestrate/inbox/processed" "$TMP/orchestrate-history"
cat > "$TMP/.orchestrate/inbox/20260712-live-GGGG.md" << 'EOF'
---
id: 20260712-live-GGGG
followup_for: 20260703-inbox-5555
kind: review
---
body
EOF
if followup_pair_already_satisfied "$TMP" "20260703-inbox-5555" "review"; then
  fail "followup_pair_already_satisfied false-positived on a pair present only in live inbox/ (not processed, not history)"
else
  ok "followup_pair_already_satisfied returns 1 for a pair present only in live inbox/ (correct — distinguishes from followup_pair_exists)"
fi

echo ""
echo "6. _pair_in_files — kind substring edge case must not false-positive"
new_tmp
mkdir -p "$TMP/.orchestrate/inbox"
cat > "$TMP/.orchestrate/inbox/20260713-sub-HHHH.md" << 'EOF'
---
id: 20260713-sub-HHHH
followup_for: 20260704-inbox-6666
kind: review-2
---
body
EOF
if followup_pair_exists "$TMP" "20260704-inbox-6666" "review"; then
  fail "followup_pair_exists false-positived: 'kind: review-2' matched a lookup for 'kind: review'"
else
  ok "followup_pair_exists correctly does NOT match 'kind: review-2' against a lookup for 'kind: review'"
fi
if followup_pair_exists "$TMP" "20260704-inbox-6666" "review-2"; then
  ok "followup_pair_exists correctly DOES match 'kind: review-2' against a lookup for 'kind: review-2' (exact match still works)"
else
  fail "followup_pair_exists failed to match the exact 'kind: review-2' pair"
fi

echo ""
echo "── followup-dedup.sh: $PASS passed, $FAIL failed ───"
[[ "$FAIL" -eq 0 ]]
