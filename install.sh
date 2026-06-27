#!/usr/bin/env bash
# Standalone installer for the Inbox & Orchestrate system.
#
# Installs the .orchestrate/ control plane + runtime scripts into a target
# project and loads the launchd watchdog agents (tend, rescue, monitor).
#
# Usage:
#   PROJECT_DIR="$HOME/apps/my-project" bash install.sh
#   (PROJECT_DIR defaults to the current directory)
#
# Requires macOS (launchd). Node 18+ is only needed for the monitor.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
LAUNCH_AGENTS="${HOME}/Library/LaunchAgents"
NODE_BIN="${NODE_BIN:-$(command -v node || echo "${HOME}/.local/bin/node")}"

echo "Installing Inbox & Orchestrate into: $PROJECT_DIR"

# 1. Control plane skeleton ------------------------------------------------
ORCH="$PROJECT_DIR/.orchestrate"
mkdir -p "$ORCH"/{bin,tasks,inbox/gated,inbox/processed,logs}

if [[ ! -f "$ORCH/project.md" ]]; then
  cat > "$ORCH/project.md" <<EOF
# Orchestrate — $(basename "$PROJECT_DIR")
last_updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

## Shared Context
<!-- Durable project knowledge carried across tasks. Appended at task completion. -->

## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
EOF
  echo "created $ORCH/project.md"
fi

# 2. Runtime scripts -------------------------------------------------------
for s in run-job.sh cleanup-stale-inbox.sh drain-inbox.sh tend-need-action.sh \
         set-runner.sh rescue.sh first-pass-auto-resolve.sh requeue-unblocked.sh \
         enqueue-analyzer-daily.sh; do
  [[ -f "$REPO_ROOT/bin/$s" ]] && cp "$REPO_ROOT/bin/$s" "$ORCH/bin/$s"
done
chmod +x "$ORCH/bin/"*.sh

# 3. agent.conf ------------------------------------------------------------
CONF="$ORCH/agent.conf"
if [[ ! -f "$CONF" ]]; then
  cp "$REPO_ROOT/bin/agent.conf.example" "$CONF"
  echo "created $CONF (edit RUNNER / TEND_MODE as needed)"
fi

# 4. Render + load launchd agents -----------------------------------------
render() {
  sed \
    -e "s|~/apps/my-project|$PROJECT_DIR|g" \
    -e "s|__PROJECT_DIR__|$PROJECT_DIR|g" \
    -e "s|__RUN_JOB__|$ORCH/bin/run-job.sh|g" \
    -e "s|__RESCUE_SCRIPT__|$ORCH/bin/rescue.sh|g" \
    -e "s|__NODE_BIN__|$NODE_BIN|g" \
    -e "s|__MONITOR_SERVER__|$REPO_ROOT/monitor/server.js|g" \
    "$1"
}

mkdir -p "$LAUNCH_AGENTS"
for label in com.orchestrate.tend com.orchestrate.rescue com.orchestrate.monitor; do
  src="$REPO_ROOT/launchd/$label.plist"
  [[ -f "$src" ]] || continue
  render "$src" > "$LAUNCH_AGENTS/$label.plist"
  launchctl unload "$LAUNCH_AGENTS/$label.plist" 2>/dev/null || true
  launchctl load "$LAUNCH_AGENTS/$label.plist" && echo "loaded $label"
done

echo
echo "Done. Next steps:"
echo "  • Edit $CONF (RUNNER=claude|cursor, TEND_MODE=go auto|notify)"
echo "  • Symlink the skill:  ln -s \"$REPO_ROOT/skill\" ~/.claude/skills/task-orchestrate"
echo "  • Drop a task:        cp $REPO_ROOT/examples/inbox/*.md $ORCH/inbox/"
echo "  • Run a cycle now:    bash $ORCH/bin/run-job.sh tend"
echo "  • Monitor:            node $REPO_ROOT/monitor/server.js  → http://127.0.0.1:7842"
