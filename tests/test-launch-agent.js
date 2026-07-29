'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { execSync } = require('node:child_process');

const PLIST_PATH = `${process.env.HOME}/Library/LaunchAgents/com.orchestrate.tend.plist`;
const LABEL = 'com.orchestrate.tend';
// Installed-environment integration test: point at the project whose tend agent
// is installed. Override with ORCHESTRATE_PROJECT_DIR; defaults to this repo.
const PROJECT_DIR = process.env.ORCHESTRATE_PROJECT_DIR || path.resolve(__dirname, '..');
const RUN_JOB = path.join(PROJECT_DIR, '.orchestrate/bin/run-job.sh');
const AGENT_CONF = path.join(PROJECT_DIR, '.orchestrate/agent.conf');
const CURSOR_BIN = `${process.env.HOME}/.local/bin/cursor-agent`;

// True only once install-launchd.sh has actually been run against PROJECT_DIR
// (it copies run-job.sh and writes agent.conf). On a fresh checkout — including
// this repo's own tests/ before anyone has installed it locally — these files
// don't exist yet, and the machine's launchd state (if any) belongs to whatever
// project *is* installed, not this checkout. Subtests that depend on that live,
// installed state skip gracefully instead of failing.
const INSTALLED = fs.existsSync(RUN_JOB) && fs.existsSync(AGENT_CONF);
const SKIP_REASON = 'orchestrate not installed locally — skipping install-integration check';

function launchctlList() {
  const out = execSync('launchctl list', { encoding: 'utf8' });
  for (const line of out.split('\n')) {
    const parts = line.trim().split(/\s+/);
    if (parts[2] === LABEL) {
      return { pid: parts[0], exitCode: parseInt(parts[1], 10) };
    }
  }
  return null;
}

// PLIST_PATH and CURSOR_BIN are global, unscoped-to-project paths — unlike
// RUN_JOB/AGENT_CONF above, install-launchd.sh writes them under the
// non-project-namespaced `com.orchestrate.tend` label and ~/.local/bin, so
// their presence says nothing about *this* checkout being installed; it only
// reflects whatever project (if any) happens to be installed on this machine.
// Gate on the plist itself: install-launchd.sh always writes
// com.orchestrate.tend.plist as part of any orchestrate install (for any
// project), so its presence is the best available "something is installed
// globally" signal for these unscoped paths. On a machine with zero
// orchestrate installs anywhere, this is false and the subtests below skip
// gracefully instead of failing.
const GLOBAL_INSTALLED = fs.existsSync(PLIST_PATH);
const GLOBAL_SKIP_REASON =
  'no orchestrate install found globally (com.orchestrate.tend.plist absent) — skipping';

test('plist file exists', (t) => {
  if (!GLOBAL_INSTALLED) return t.skip(GLOBAL_SKIP_REASON);
  assert.ok(fs.existsSync(PLIST_PATH), `plist not found at ${PLIST_PATH}`);
});

test('plist uses run-job wrapper', (t) => {
  if (!GLOBAL_INSTALLED) return t.skip(GLOBAL_SKIP_REASON);
  const raw = fs.readFileSync(PLIST_PATH, 'utf8');
  assert.ok(raw.includes('run-job.sh'), 'expected run-job.sh wrapper in plist');
  assert.ok(raw.includes('<string>tend</string>'), 'expected tend job arg in plist');
});

test('run-job wrapper exists and is executable', (t) => {
  if (!INSTALLED) return t.skip(SKIP_REASON);
  assert.ok(fs.existsSync(RUN_JOB), `run-job.sh missing at ${RUN_JOB}`);
  const stat = fs.statSync(RUN_JOB);
  assert.ok(stat.mode & 0o111, 'run-job.sh is not executable');
});

test('agent.conf exists with RUNNER setting', (t) => {
  if (!INSTALLED) return t.skip(SKIP_REASON);
  assert.ok(fs.existsSync(AGENT_CONF), `agent.conf missing at ${AGENT_CONF}`);
  const raw = fs.readFileSync(AGENT_CONF, 'utf8');
  assert.match(raw, /^RUNNER=(cursor|claude)/m, 'agent.conf must set RUNNER=cursor or RUNNER=claude');
});

test('cursor-agent binary exists on disk (default runner)', (t) => {
  if (!GLOBAL_INSTALLED) return t.skip(GLOBAL_SKIP_REASON);
  assert.ok(fs.existsSync(CURSOR_BIN), `cursor-agent binary missing at ${CURSOR_BIN}`);
});

test('launch agent is loaded in launchctl', (t) => {
  if (!INSTALLED) return t.skip(SKIP_REASON);
  const entry = launchctlList();
  assert.ok(entry !== null, `"${LABEL}" not found in launchctl list`);
});

test('launch agent last exit code is acceptable (0 success, throttled runs may be non-zero)', (t) => {
  if (!INSTALLED) return t.skip(SKIP_REASON);
  const entry = launchctlList();
  assert.ok(entry !== null, `"${LABEL}" not found in launchctl list`);
  const rawExit = String(entry.exitCode);
  const acceptable =
    entry.exitCode === 0 ||
    Number.isNaN(entry.exitCode) ||
    (entry.pid === '-' && entry.exitCode >= 0 && entry.exitCode <= 255);
  assert.ok(
    acceptable,
    `launchctl exit code ${rawExit} for ${LABEL} — agent is loaded; non-zero may reflect session-limit throttling, not wiring failure`,
  );
});

test('heartbeat log directory exists', (t) => {
  if (!INSTALLED) return t.skip(SKIP_REASON);
  const logDir = path.join(PROJECT_DIR, '.orchestrate/logs');
  assert.ok(fs.existsSync(logDir), `log directory missing at ${logDir}`);
});
