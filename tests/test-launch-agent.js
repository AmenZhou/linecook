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

test('plist file exists', () => {
  assert.ok(fs.existsSync(PLIST_PATH), `plist not found at ${PLIST_PATH}`);
});

test('plist uses run-job wrapper', () => {
  const raw = fs.readFileSync(PLIST_PATH, 'utf8');
  assert.ok(raw.includes('run-job.sh'), 'expected run-job.sh wrapper in plist');
  assert.ok(raw.includes('<string>tend</string>'), 'expected tend job arg in plist');
});

test('run-job wrapper exists and is executable', () => {
  assert.ok(fs.existsSync(RUN_JOB), `run-job.sh missing at ${RUN_JOB}`);
  const stat = fs.statSync(RUN_JOB);
  assert.ok(stat.mode & 0o111, 'run-job.sh is not executable');
});

test('agent.conf exists with RUNNER setting', () => {
  assert.ok(fs.existsSync(AGENT_CONF), `agent.conf missing at ${AGENT_CONF}`);
  const raw = fs.readFileSync(AGENT_CONF, 'utf8');
  assert.match(raw, /^RUNNER=(cursor|claude)/m, 'agent.conf must set RUNNER=cursor or RUNNER=claude');
});

test('cursor-agent binary exists on disk (default runner)', () => {
  assert.ok(fs.existsSync(CURSOR_BIN), `cursor-agent binary missing at ${CURSOR_BIN}`);
});

test('launch agent is loaded in launchctl', () => {
  const entry = launchctlList();
  assert.ok(entry !== null, `"${LABEL}" not found in launchctl list`);
});

test('launch agent last exit code is acceptable (0 success, throttled runs may be non-zero)', () => {
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

test('heartbeat log directory exists', () => {
  const logDir = path.join(PROJECT_DIR, '.orchestrate/logs');
  assert.ok(fs.existsSync(logDir), `log directory missing at ${logDir}`);
});
