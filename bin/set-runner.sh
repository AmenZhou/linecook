#!/usr/bin/env bash
# Flip orchestrate agent runner without launchctl reload.
# Usage: bash .orchestrate/bin/set-runner.sh cursor|claude
set -euo pipefail

RUNNER="${1:?usage: set-runner.sh cursor|claude}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="${ORCHESTRATE_AGENT_CONF:-$ROOT/agent.conf}"

case "$RUNNER" in
  cursor|claude) ;;
  *)
    echo "set-runner.sh: RUNNER must be cursor or claude (got '$RUNNER')" >&2
    exit 1
    ;;
esac

if [[ ! -f "$CONF" ]]; then
  echo "set-runner.sh: $CONF not found" >&2
  exit 1
fi

tmp="$(mktemp)"
if grep -qE '^\s*RUNNER=' "$CONF"; then
  sed -E "s/^\s*RUNNER=.*/RUNNER=$RUNNER        # cursor | claude/" "$CONF" >"$tmp"
else
  cat "$CONF" >"$tmp"
  printf '\nRUNNER=%s        # cursor | claude\n' "$RUNNER" >>"$tmp"
fi
mv "$tmp" "$CONF"
echo "set-runner.sh: RUNNER=$RUNNER in $CONF (no launchctl reload needed)"
