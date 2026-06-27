#!/usr/bin/env bash
# Install com.orchestrate.* launchd agents for a project.
# Usage: PROJECT_DIR=/path/to/project bash install-launchd.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLBOX_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
LAUNCH_AGENTS="${HOME}/Library/LaunchAgents"

if [[ ! -d "$PROJECT_DIR/.orchestrate" ]]; then
  echo "error: $PROJECT_DIR/.orchestrate not found — initialize orchestrate first" >&2
  exit 1
fi

BIN_DIR="$PROJECT_DIR/.orchestrate/bin"
mkdir -p "$BIN_DIR" "$PROJECT_DIR/.orchestrate/logs"
cp "$SCRIPT_DIR/run-job.sh" "$BIN_DIR/run-job.sh"
cp "$SCRIPT_DIR/cleanup-stale-inbox.sh" "$BIN_DIR/cleanup-stale-inbox.sh"
cp "$SCRIPT_DIR/drain-inbox.sh" "$BIN_DIR/drain-inbox.sh"
cp "$SCRIPT_DIR/tend-need-action.sh" "$BIN_DIR/tend-need-action.sh"
cp "$SCRIPT_DIR/set-runner.sh" "$BIN_DIR/set-runner.sh"
cp "$SCRIPT_DIR/rescue.sh" "$BIN_DIR/rescue.sh"
cp "$SCRIPT_DIR/enqueue-analyzer-daily.sh" "$BIN_DIR/enqueue-analyzer-daily.sh"
cp "$TOOLBOX_ROOT/skills/orchestrate-daily-wiki-ingest/bin/enqueue-wiki-ingest-daily.sh" \
  "$BIN_DIR/enqueue-wiki-ingest-daily.sh"
chmod +x "$BIN_DIR/run-job.sh" "$BIN_DIR/cleanup-stale-inbox.sh" "$BIN_DIR/drain-inbox.sh" \
  "$BIN_DIR/tend-need-action.sh" "$BIN_DIR/set-runner.sh" "$BIN_DIR/rescue.sh" \
  "$BIN_DIR/enqueue-analyzer-daily.sh" "$BIN_DIR/enqueue-wiki-ingest-daily.sh"

CONF="$PROJECT_DIR/.orchestrate/agent.conf"
if [[ ! -f "$CONF" ]]; then
  cp "$SCRIPT_DIR/agent.conf.example" "$CONF"
  echo "created default $CONF (RUNNER=cursor)"
fi

render_plist() {
  local src="$1"
  local dest="$2"
  sed \
    -e "s|~/apps/my-project|$PROJECT_DIR|g" \
    -e "s|__PROJECT_DIR__|$PROJECT_DIR|g" \
    -e "s|__RUN_JOB__|$BIN_DIR/run-job.sh|g" \
    -e "s|__RESCUE_SCRIPT__|$BIN_DIR/rescue.sh|g" \
    -e "s|__ENQUEUE_ANALYZER__|$BIN_DIR/enqueue-analyzer-daily.sh|g" \
    -e "s|__ENQUEUE_WIKI_INGEST__|$BIN_DIR/enqueue-wiki-ingest-daily.sh|g" \
    "$src" > "$dest"
}

render_plist "$TOOLBOX_ROOT/skills/task-orchestrate/com.orchestrate.tend.plist" \
  "$LAUNCH_AGENTS/com.orchestrate.tend.plist"
render_plist "$TOOLBOX_ROOT/skills/task-orchestrate/com.orchestrate.rescue.plist" \
  "$LAUNCH_AGENTS/com.orchestrate.rescue.plist"
render_plist "$TOOLBOX_ROOT/skills/inbox-log-analyzer/com.orchestrate.inbox-analyzer.plist" \
  "$LAUNCH_AGENTS/com.orchestrate.inbox-analyzer.plist"
render_plist "$TOOLBOX_ROOT/skills/orchestrate-daily-wiki-ingest/com.orchestrate.wiki-ingest-daily.plist" \
  "$LAUNCH_AGENTS/com.orchestrate.wiki-ingest-daily.plist"

NODE_BIN="${NODE_BIN:-${HOME}/.local/bin/node}"
MONITOR_SERVER="$TOOLBOX_ROOT/skills/task-orchestrate/monitor/server.js"
sed \
  -e "s|~/apps/my-project|$PROJECT_DIR|g" \
  -e "s|__NODE_BIN__|$NODE_BIN|g" \
  -e "s|__MONITOR_SERVER__|$MONITOR_SERVER|g" \
  "$TOOLBOX_ROOT/skills/task-orchestrate/monitor/com.orchestrate.monitor.plist" \
  > "$LAUNCH_AGENTS/com.orchestrate.monitor.plist"

for label in com.orchestrate.tend com.orchestrate.rescue com.orchestrate.inbox-analyzer com.orchestrate.wiki-ingest-daily com.orchestrate.monitor; do
  launchctl unload "$LAUNCH_AGENTS/$label.plist" 2>/dev/null || true
  launchctl load "$LAUNCH_AGENTS/$label.plist"
  echo "loaded $label"
done

echo "done — edit $CONF (RUNNER, TEND_MODE=go auto|notify)"
