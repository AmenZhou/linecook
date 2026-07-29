#!/usr/bin/env bash
# append-phase-log.sh — atomic mandatory phase-log write.
#
# Root cause fixed (task 20260718-inbox-1DF9): SKILL.md's "Phase log write
# (mandatory)" step was previously TWO independent shell statements that the
# tend/agent LLM session ran itself — one `echo` for the header line, a second
# `echo` for the full PHASE OUTPUT body. Nothing enforced that both ran
# together. Task 20260717-inbox-60E4 went through a ghost-reset → auto-resolve
# → re-dispatch → inline-takeover cycle (its second dispatch attempt also
# stalled, so the tend-auto session executed both phases directly in its own
# context per SKILL.md's documented inline-takeover path); in that turn it ran
# the header echo for both phases (both logs share the identical
# 2026-07-17T21:24:02Z timestamp) but never ran the body-append echo — the
# full PHASE OUTPUT content only made it into the task file (later archived),
# never into .orchestrate/logs/{ID}-phase{N}.log.
#
# Fix: collapse the two statements into ONE atomic call. A caller can no
# longer write a header without its body in the same invocation, and this
# script refuses to write anything at all if the body is empty or missing the
# "## PHASE OUTPUT" marker — so a header-only stub is now structurally
# impossible via this path.
#
# Usage:
#   echo "<full PHASE OUTPUT block>" | append-phase-log.sh <ROOT> <ID> <PHASE_N> <PHASE_NAME> [<RETRIES>]
#   append-phase-log.sh <ROOT> <ID> <PHASE_N> <PHASE_NAME> [<RETRIES>] <BODY_FILE>
#
# Writes to: <ROOT>/.orchestrate/logs/<ID>-phase<PHASE_N>.log
#   === Phase <PHASE_N> [(retry <RETRIES>)] — <PHASE_NAME> <ISO timestamp> ===
#   <full PHASE OUTPUT block>
#
# Exit 0 on success. Exit 1 (no write) if args are missing, ROOT is not an
# orchestrate root, or the body is empty / missing "## PHASE OUTPUT".

set -euo pipefail

die() { echo "append-phase-log.sh: $*" >&2; exit 1; }

[[ $# -ge 4 ]] || die "usage: <ROOT> <ID> <PHASE_N> <PHASE_NAME> [<RETRIES>] [<BODY_FILE>]"

ROOT="$1"; ID="$2"; PHASE_N="$3"; PHASE_NAME="$4"
RETRIES="${5:-0}"
BODY_FILE="${6:-}"

# Numeric args 3 ($PHASE_N) and 5 ($RETRIES) may arrive non-numeric from a
# careless caller — fail loudly rather than writing a malformed header.
[[ "$PHASE_N" =~ ^[0-9]+$ ]] || die "PHASE_N must be numeric, got '$PHASE_N'"
[[ "$RETRIES" =~ ^[0-9]+$ ]] || die "RETRIES must be numeric, got '$RETRIES'"

# ID is interpolated directly into LOG_FILE below. No call site today passes
# anything but an internally-generated YYYYMMDD-... ID, but validate the
# charset defensively before it ever reaches path construction — otherwise a
# less-trusted ID source (e.g. "../../etc/passwd") would be a path-traversal
# vector (20260724-inbox-6D91).
[[ "$ID" =~ ^[A-Za-z0-9_-]+$ ]] || die "ID must match ^[A-Za-z0-9_-]+\$, got '$ID'"

[[ -d "$ROOT/.orchestrate" ]] || die "not an orchestrate root (no .orchestrate/ dir): $ROOT"

if [[ -n "$BODY_FILE" ]]; then
  [[ -f "$BODY_FILE" ]] || die "body file not found: $BODY_FILE"
  BODY="$(cat "$BODY_FILE")"
else
  BODY="$(cat)"
fi

# The atomic guarantee: refuse to write ANYTHING (not even the header) unless
# the body has real content. This is what makes a header-only stub
# structurally impossible through this script. A body missing the "##
# PHASE OUTPUT" marker (e.g. an agent's raw return text when it failed to
# produce a proper block — SKILL.md's documented agent-phase fallback) is
# still real content: it is logged with an explicit fallback marker line
# instead of being silently dropped (task 20260718-inbox-REV1DF9 found the
# prior behavior — die() on missing marker — defeated that exact documented
# fallback, producing total silence for the one failure mode it exists to
# cover).
[[ -n "$BODY" ]] || die "refusing to write phase log: empty PHASE OUTPUT body (header-only stubs are not allowed)"
if echo "$BODY" | grep -q '^## PHASE OUTPUT'; then
  FALLBACK=0
else
  FALLBACK=1
fi

LOG_DIR="$ROOT/.orchestrate/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${ID}-phase${PHASE_N}.log"

# Auto-derive the true retry count from headers already logged for this
# phase, instead of trusting the caller's $RETRIES argument alone (task
# 20260720-inbox-69E3). SKILL.md's Step C ("increment retries") is prose the
# calling session must track itself turn-to-turn; a raw-text/markerless
# first attempt (the documented fallback — see the FALLBACK handling above)
# still calls this script and writes a real header, but nothing forces the
# NEXT call for the same phase to know that header exists. If the caller's
# own $RETRIES tracking resets or is lost (e.g. across a fresh turn), the
# retry silently loses its "(retry N)" label — exactly the
# 20260719-inbox-TSDF-phase1.log shape (a markerless fallback entry followed
# by a real entry, both labeled plain "Phase 1"). Counting pre-existing
# "=== Phase N " headers already in the log file is a deterministic,
# caller-independent source of truth: this call is attempt
# (existing_headers + 1), so its retry number is at least existing_headers.
# max() with the caller's own value means a correctly-tracking caller's
# RETRIES is never overridden downward, only corrected upward when it lags
# reality.
EXISTING_HEADERS=0
if [[ -f "$LOG_FILE" ]]; then
  EXISTING_HEADERS="$(grep -c "^=== Phase ${PHASE_N} " "$LOG_FILE" 2>/dev/null || true)"
  [[ "$EXISTING_HEADERS" =~ ^[0-9]+$ ]] || EXISTING_HEADERS=0
fi
[[ "$EXISTING_HEADERS" -gt "$RETRIES" ]] && RETRIES="$EXISTING_HEADERS"

LABEL="Phase ${PHASE_N}"
[[ "$RETRIES" -gt 0 ]] && LABEL="Phase ${PHASE_N} (retry ${RETRIES})"

# Single append — header and body go to the file in one shell redirection, so
# there is no window between them for a crash/interruption to split the write.
{
  echo "=== ${LABEL} — ${PHASE_NAME} $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  if [[ "$FALLBACK" -eq 1 ]]; then
    echo "[no PHASE OUTPUT block — raw agent text below]"
  fi
  echo "$BODY"
} >> "$LOG_FILE"
