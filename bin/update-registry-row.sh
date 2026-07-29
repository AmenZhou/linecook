#!/usr/bin/env bash
# update-registry-row.sh — update exactly one Task Registry row BY COLUMN NAME.
#
# Every completion/reap path (finalize-completed-tasks.sh, churn-guard.sh,
# run-job.sh, and this skill's own inline Completion step) has historically
# hand-rolled a positional awk update of project.md's registry table and, more
# than once, gotten the field indices wrong — e.g. writing a phase number into
# the mode column or a timestamp into the status column. NF stays 8 with an
# empty trailing $8, so the structural invariant check does not catch it; only
# the DOMAIN check (mode/status enum) does, after the fact. This helper removes
# the need to hand-derive field positions at all: callers pass named values,
# this script maps them onto the correct columns.
#
# Registry row shape (awk -F'|' on a data row):
#   $1=""(pre-pipe)  $2=ID  $3=summary  $4=mode  $5=current_phase
#   $6=status        $7=last_activity  $8=""(trailing, must stay empty)
#
# Usage:
#   update-registry-row.sh <ROOT> <ID> <mode> <current_phase> <status> <last_activity>
#
# - <ROOT>: project root containing .orchestrate/project.md
# - Leaves the row's `summary` column untouched (this helper only ever needs to
#   flip mode/current_phase/status/last_activity — summary is set once at
#   registration and never rewritten here).
# - Refuses (exit 1, no write) if <mode> or <status> is outside the known enum,
#   or if <ID> has no matching row — the file is never touched on a bad call.
# - Idempotent: calling twice with the same arguments produces byte-identical
#   output the second time.
set -euo pipefail

VALID_MODES="auto gated"
VALID_STATUSES="pending running awaiting_go awaiting_critic complete failed needs_human"

die() { echo "update-registry-row.sh: $*" >&2; exit 1; }

[[ $# -eq 6 ]] || die "usage: <ROOT> <ID> <mode> <current_phase> <status> <last_activity>"

ROOT="$1"; ID="$2"; MODE="$3"; PHASE="$4"; STATUS="$5"; LAST_ACTIVITY="$6"

PROJ="$ROOT/.orchestrate/project.md"
[[ -f "$PROJ" ]] || die "project.md not found at $PROJ"

_in_set() {
  local needle="$1" hay="$2" w
  for w in $hay; do [[ "$w" == "$needle" ]] && return 0; done
  return 1
}

_in_set "$MODE" "$VALID_MODES" || die "invalid mode '$MODE' — must be one of: $VALID_MODES"
_in_set "$STATUS" "$VALID_STATUSES" || die "invalid status '$STATUS' — must be one of: $VALID_STATUSES"
[[ "$PHASE" =~ ^[0-9]+$ ]] || die "invalid current_phase '$PHASE' — must be a non-negative integer"

grep -qE "^\|[[:space:]]*${ID}[[:space:]]*\|" "$PROJ" || die "no registry row found for ID '$ID'"

TMP="$(mktemp "${TMPDIR:-/tmp}/update-registry-row.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

set +e
awk -F'|' -v OFS='|' -v id="$ID" -v mode="$MODE" -v phase="$PHASE" -v status="$STATUS" -v ts="$LAST_ACTIVITY" '
  /^\|[[:space:]]*[0-9]/ && NF==8 {
    rid=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",rid)
    if (rid==id) {
      $4=" " mode " "
      $5=" " phase " "
      $6=" " status " "
      $7=" " ts " "
      found=1
    }
  }
  { print }
  END { exit(found?0:2) }
' "$PROJ" > "$TMP"
AWK_STATUS=$?
set -e

[[ "$AWK_STATUS" -eq 0 ]] || die "row matched by grep but not updated by awk (unexpected NF!=8?)"

mv "$TMP" "$PROJ"
trap - EXIT
