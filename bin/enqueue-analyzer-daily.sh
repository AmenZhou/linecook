#!/usr/bin/env bash
# Enqueue a daily inbox-log-analyzer run for tend to pick up.
set -euo pipefail

ROOT="$(pwd)"
INBOX="$ROOT/.orchestrate/inbox"
mkdir -p "$INBOX"
STAMP="$(date +%Y%m%dT%H%M%S)"
FILE="$INBOX/analyzer-daily-run-${STAMP}.md"

cat > "$FILE" << 'EOF'
# Run inbox-log-analyzer

## Goal
Scan `.orchestrate/logs/` for new job logs since last run, detect bugs and enhancements, write structured inbox tasks for each finding.

## Context
Triggered by daily launchd schedule (9am). Skill: /inbox-log-analyzer. State file: `.orchestrate/logs/inbox-analyzer-state.json` tracks already-processed logs.

## Acceptance Criteria
- All unprocessed log files scanned
- Inbox tasks written for any actionable findings
- State file updated
EOF

echo "enqueued $(basename "$FILE")"
if [[ "${ORCHESTRATE_SKIP_TEND:-}" != "1" ]]; then
  "$ROOT/.orchestrate/bin/run-job.sh" tend || true
fi
