'use strict';

const { test, before, after, describe } = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');
const { intervalLabel, buildLaunchdAgents, tendThrottleHint, parseTendHealth, readTendMode, readAgentConf, readRunner, readAgentStatus, isCursorIdeRunning, isTendGoAuto, taskApprovalInfo, parseInboxMeta, isCompletedInboxFile, manifestMatchesRegistry, archiveDateFromFilename, resolveHistoryDatetime, isPlaceholderTimestamp, isFutureTimestamp, buildCompletionHints, findHistoryEntry, loadHistoryEntries, buildHistoryRows, historyStats, historyCoverage, extractTaskIdFromFilename, collectTaskLogContent, synthesizeHistoryStub, findInboxSourceForTask, approveRegistryTask, listKubeReviews, approveKubeReview } = require('../server');

const TEST_PORT = 7843;
let tmpDir;
let serverProcess;

function get(pathname) {
  return new Promise((resolve, reject) => {
    http.get(`http://127.0.0.1:${TEST_PORT}${pathname}`, (res) => {
      let body = '';
      res.on('data', c => body += c);
      res.on('end', () => {
        const ct = res.headers['content-type'] || '';
        if (ct.includes('application/json')) {
          try { resolve({ status: res.statusCode, body: JSON.parse(body) }); }
          catch (_) { resolve({ status: res.statusCode, body }); }
        } else {
          resolve({ status: res.statusCode, body });
        }
      });
    }).on('error', reject);
  });
}

function post(pathname, payload) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(payload);
    const req = http.request({
      hostname: '127.0.0.1',
      port: TEST_PORT,
      path: pathname,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(data),
      },
    }, (res) => {
      let body = '';
      res.on('data', c => body += c);
      res.on('end', () => {
        try { resolve({ status: res.statusCode, body: JSON.parse(body) }); }
        catch (_) { resolve({ status: res.statusCode, body }); }
      });
    });
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

before(async () => {
  // Fixture: minimal .orchestrate layout
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'monitor-test-'));
  const orch = path.join(tmpDir, '.orchestrate');
  fs.mkdirSync(path.join(orch, 'tasks'), { recursive: true });
  fs.mkdirSync(path.join(orch, 'logs'), { recursive: true });
  fs.mkdirSync(path.join(orch, 'inbox', 'processed'), { recursive: true });
  fs.mkdirSync(path.join(orch, 'inbox', 'gated'), { recursive: true });

  fs.writeFileSync(path.join(orch, 'agent.conf'), [
    'RUNNER=claude',
    'TEND_MODE="go auto"',
    'CURSOR_FALLBACK=auto',
  ].join('\n') + '\n');

  fs.writeFileSync(path.join(orch, 'inbox', 'pending-job.md'),
    '# Pending Job\n\n## Goal\nFix the thing.\n',
  );

  fs.writeFileSync(path.join(orch, 'inbox', 'gated', 'gated-job.md'),
    'mode: gated\n\n# Gated Job\n\n## Goal\nReview before run.\n',
  );

  fs.writeFileSync(path.join(orch, 'inbox', 'processed', 'done-job.md'),
    '# Done Job\n\n## Goal\nAlready processed.\n',
  );

  fs.writeFileSync(path.join(orch, 'inbox', 'stale-processed-as.md'),
    'processed_as: 20260620-inbox-RCF\n',
  );

  fs.writeFileSync(path.join(orch, 'inbox', 'stale-duplicate-root.md'),
    '# Stale Duplicate\n\n## Goal\nAlready done — copy lives in processed/.\n',
  );
  fs.writeFileSync(path.join(orch, 'inbox', 'processed', 'stale-duplicate-root.md'),
    '# Stale Duplicate\n\n## Goal\nAlready done — canonical copy.\n',
  );

  fs.writeFileSync(path.join(orch, 'inbox', 'stale-registry-complete.md'),
    '# SBMT follow-up\n\n## Goal\nAlready done.\n\n- Task ID: 20260620-inbox-SBMT\n',
  );

  fs.writeFileSync(path.join(orch, 'project.md'), [
    '# Orchestrate — test',
    '',
    '## Task Registry',
    '| ID | summary | mode | current_phase | status | last_activity |',
    '|----|---------|------|---------------|--------|---------------|',
    '| test-001 | test task | auto | 1 | running | 2026-01-01T00:00:00Z |',
    '| test-gated | gated task | gated | — | awaiting_go | 2026-01-01T00:00:00Z |',
    '| test-blocked | stuck task | auto | 2 | needs_human | 2026-01-01T00:00:00Z |',
    '| 20260619-inbox-5B | sy_promotion — 5 borough census race KMZ maps | auto | 3 | complete | 2026-06-19T17:20:00Z |',
    '| 20260619-inbox-RMB | sy_promotion duplicate registry row | auto | 3 | complete | 2026-06-19T17:20:00Z |',
    '| 20260620-inbox-SBMT | Shell(make) allow for headless tend verify runs | auto | 1 | complete | 2026-06-19T22:00:00Z |',
  ].join('\n'));

  fs.writeFileSync(path.join(orch, 'tasks', 'test-001.md'), '# Task test-001\nphase 1 details');

  const historyDir = path.join(tmpDir, 'orchestrate-history');
  fs.mkdirSync(historyDir, { recursive: true });
  fs.writeFileSync(path.join(historyDir, 'MANIFEST.md'), [
    '# Orchestrate History Manifest',
    '',
    '2026-06-19 | 20260619-172105-20260619-inbox-5B-5-borough-kmz.md | sy_promotion — 5 borough census race KMZ maps | census, sy-promotion',
  ].join('\n'));
  fs.writeFileSync(
    path.join(historyDir, '20260619-172105-20260619-inbox-5B-5-borough-kmz.md'),
    '# sy_promotion — 5 borough census race KMZ maps\n\nKMZ export details for all five boroughs.',
  );

  fs.writeFileSync(path.join(orch, 'logs', 'heartbeat.log'),
    '[2026-01-01T00:00:00Z] tend — idle\n' +
    '[2026-01-01T00:05:00Z] inbox-analyzer — scanned 2 logs, found 0 issues\n',
  );

  // Start server in tmpDir with TEST_PORT
  serverProcess = spawn(process.execPath, [
    path.join(__dirname, '..', 'server.js'),
  ], {
    cwd: tmpDir,
    env: { ...process.env, PORT: String(TEST_PORT) },
    stdio: 'pipe',
  });

  // Wait for server to be ready
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('server start timeout')), 5000);
    serverProcess.stdout.on('data', (chunk) => {
      if (chunk.toString().includes('listening')) {
        clearTimeout(timeout);
        resolve();
      }
    });
    serverProcess.on('error', (err) => { clearTimeout(timeout); reject(err); });
  });
});

after(() => {
  if (serverProcess) serverProcess.kill();
  if (tmpDir) fs.rmSync(tmpDir, { recursive: true, force: true });
});

test('/ serves index.html', async () => {
  const { status, body } = await get('/');
  assert.equal(status, 200);
  assert.ok(typeof body === 'string' && body.includes('task-orchestrate monitor'),
    'index.html should contain page title');
  assert.ok(body.includes('approval-banner'), 'index should include approval banner');
  assert.ok(body.includes('function approveGatedTask'), 'index should include gated approval handler');
  assert.ok(body.includes('fetchKubeReviews'), 'index should include kube reviews fetch');
  assert.ok(body.includes('data-tab="kube"'), 'index should include Kube tab');
  assert.ok(body.includes('await fetchTasks();'), 'approveGatedTask should refresh via fetchTasks()');
  assert.ok(!body.includes('await loadTasks();'), 'approveGatedTask must not call undefined loadTasks()');
});

test('/api/tasks returns registry rows and task content', async () => {
  const { status, body } = await get('/api/tasks');
  assert.equal(status, 200);
  assert.ok(Array.isArray(body.registry));
  assert.equal(body.registry.length, 6);
  assert.equal(body.tendMode, 'go auto');
  assert.equal(body.registry[0].id, 'test-001');
  assert.equal(body.registry[0].status, 'running');
  assert.equal(body.registry[0].needsApproval, false);
  const gated = body.registry.find(r => r.id === 'test-gated');
  assert.ok(gated);
  // Gated fix 2026-06-21: awaiting_go always needs approval regardless of tend mode
  assert.equal(gated.needsApproval, true);
  assert.equal(gated.approvalReason, 'awaiting_go');
  const blocked = body.registry.find(r => r.id === 'test-blocked');
  assert.ok(blocked);
  assert.equal(blocked.needsApproval, true);
  assert.equal(blocked.approvalReason, 'needs_human');
  assert.ok(body.attention);
  assert.equal(body.attention.taskCount, 2); // now includes gated + blocked
  assert.equal(body.attention.tasks.length, 2);
  assert.ok(body.tasks['test-001'].includes('phase 1 details'));
});

test('POST /api/task-approve auto promotes awaiting_go to pending', async () => {
  const { status, body } = await post('/api/task-approve', { id: 'test-gated', mode: 'auto' });
  assert.equal(status, 200);
  assert.equal(body.success, true);
  assert.equal(body.status, 'pending');
  assert.equal(body.mode, 'auto');
  const tasks = await get('/api/tasks');
  const gated = tasks.body.registry.find(r => r.id === 'test-gated');
  assert.ok(gated);
  assert.equal(gated.status, 'pending');
  assert.equal(gated.needsApproval, false);
});

test('/api/inbox returns pending inbox files excluding processed/', async () => {
  const { status, body } = await get('/api/inbox');
  assert.equal(status, 200);
  assert.ok(Array.isArray(body.items));
  assert.equal(body.items.length, 2);
  assert.equal(body.tendMode, 'go auto');
  const pending = body.items.find(i => i.filename === 'pending-job.md');
  assert.ok(pending);
  assert.equal(pending.title, 'Pending Job');
  assert.equal(pending.needsApproval, false);
  assert.equal(pending.mode, 'auto');
  const gated = body.items.find(i => i.filename === 'gated/gated-job.md');
  assert.ok(gated);
  // Gated fix 2026-06-21: gated inbox items always need approval
  assert.equal(gated.needsApproval, true);
  assert.equal(gated.mode, 'gated');
  assert.equal(gated.approvalReason, 'inbox_gated');
  assert.ok(body.attention);
  assert.equal(body.attention.approvalCount, 1); // gated-job.md now requires approval
  assert.ok(!body.items.some(i => i.filename.includes('processed/')),
    'processed/ subdirectory files must not appear in /api/inbox');
  assert.ok(!body.items.some(i => i.filename === 'stale-processed-as.md'),
    'processed_as stubs at inbox root must not appear in /api/inbox');
  assert.ok(!body.items.some(i => i.filename === 'stale-duplicate-root.md'),
    'inbox root duplicate of processed/ copy must not appear in /api/inbox');
  assert.ok(!body.items.some(i => i.filename === 'stale-registry-complete.md'),
    'inbox file referencing registry-complete task ID must not appear in /api/inbox');
  const filenames = body.items.map(i => i.filename).sort();
  assert.deepEqual(filenames, ['gated/gated-job.md', 'pending-job.md']);
});

test('/api/tasks exposes tendHealth and tendIssues in attention', async () => {
  const { status, body } = await get('/api/tasks');
  assert.equal(status, 200);
  assert.ok(body.tendHealth);
  assert.equal(typeof body.tendHealth.ok, 'boolean');
  assert.ok(body.attention);
  assert.ok(Array.isArray(body.attention.tendIssues));
  assert.equal(body.tendHealth.ok, true);
  assert.equal(body.attention.tendIssues.length, 0);
});

test('/api/tasks surfaces tendIssues when session limited', async () => {
  const hbPath = path.join(tmpDir, '.orchestrate', 'logs', 'heartbeat.log');
  const prior = fs.readFileSync(hbPath, 'utf8');
  fs.appendFileSync(hbPath,
    '[2026-06-19T17:46:44Z] run-job — both runners session-limited (resets 5:10pm); inbox queued\n',
  );
  try {
    const { status, body } = await get('/api/tasks');
    assert.equal(status, 200);
    assert.equal(body.tendHealth.ok, false);
    assert.equal(body.tendHealth.status, 'throttled');
    assert.equal(body.attention.tendIssues.length, 1);
    assert.equal(body.attention.tendIssues[0].status, 'throttled');
  } finally {
    fs.writeFileSync(hbPath, prior);
  }
});

test('/api/history dedupes duplicate registry alias and returns archive content', async () => {
  const { status, body } = await get('/api/history');
  assert.equal(status, 200);
  assert.ok(Array.isArray(body.rows));
  assert.ok(body.stats);
  assert.equal(typeof body.stats.total, 'number');
  assert.ok(Array.isArray(body.stats.missingCompleteIds));
  assert.equal(body.stats.missingCompleteIds.length, 0);
  const boroughRows = body.rows.filter(r => /sy.promotion.*borough/i.test(r.summary || ''));
  assert.equal(boroughRows.length, 1, '5B+RMB duplicate registry rows must collapse to one history row');
  assert.ok(boroughRows[0].content.includes('KMZ export details'));
  assert.equal(boroughRows[0].filename, '20260619-172105-20260619-inbox-5B-5-borough-kmz.md');
  assert.equal(boroughRows[0].dateIso, '2026-06-19T17:20:00Z');
  assert.equal(boroughRows[0].hasArchive, true);
  assert.ok(!body.rows.some(r => r.filename === '20260619-inbox-RMB' && !r.content),
    'alias-only stub row must not appear when canonical archive is linked');
  const completeIds = body.rows.map(r => r.taskId).filter(Boolean);
  assert.ok(completeIds.includes('20260620-inbox-SBMT'),
    'registry-only complete row must appear in /api/history rows');
});

test('/api/heartbeat returns log lines', async () => {
  const { status, body } = await get('/api/heartbeat');
  assert.equal(status, 200);
  assert.ok(Array.isArray(body.lines));
  assert.ok(body.lines.some(l => l.includes('inbox-analyzer')));
});

test('unknown route returns 404', async () => {
  const { status } = await get('/api/no-such-route');
  assert.equal(status, 404);
});

describe('taskApprovalInfo', () => {
  test('awaiting_go needs approval when TEND_MODE=notify', () => {
    const info = taskApprovalInfo({ status: 'awaiting_go' }, 'notify');
    assert.equal(info.needsApproval, true);
    assert.equal(info.approvalReason, 'awaiting_go');
  });
  test('awaiting_go always needs approval even when TEND_MODE=go auto (gated fix 2026-06-21)', () => {
    const info = taskApprovalInfo({ status: 'awaiting_go' }, 'go auto');
    assert.equal(info.needsApproval, true);
    assert.equal(info.approvalReason, 'awaiting_go');
  });
  test('running does not need approval', () => {
    const info = taskApprovalInfo({ status: 'running' });
    assert.equal(info.needsApproval, false);
  });
  test('needs_human is blocked', () => {
    const info = taskApprovalInfo({ status: 'needs_human' });
    assert.equal(info.needsApproval, true);
    assert.equal(info.approvalReason, 'needs_human');
  });
});

describe('parseInboxMeta', () => {
  test('detects mode: gated under notify tend', () => {
    const meta = parseInboxMeta('mode: gated\n\n# Title', 'notify');
    assert.equal(meta.mode, 'gated');
    assert.equal(meta.needsApproval, true);
  });
  test('gated inbox always needs approval even under go auto tend (gated fix 2026-06-21)', () => {
    const meta = parseInboxMeta('mode: gated\n\n# Title', 'go auto');
    assert.equal(meta.mode, 'gated');
    assert.equal(meta.needsApproval, true);
    assert.equal(meta.approvalReason, 'inbox_gated');
  });
  test('deferred_at always needs approval', () => {
    const meta = parseInboxMeta('deferred_at: 2026-01-01T00:00:00Z\nmode: gated\n', 'go auto');
    assert.equal(meta.mode, 'deferred');
    assert.equal(meta.needsApproval, true);
    assert.equal(meta.approvalReason, 'inbox_deferred');
  });
  test('default is auto', () => {
    const meta = parseInboxMeta('# Title\n\n## Goal\nx');
    assert.equal(meta.mode, 'auto');
    assert.equal(meta.needsApproval, false);
  });
});

describe('isCompletedInboxFile', () => {
  test('processed_as marks completed', () => {
    assert.equal(isCompletedInboxFile('processed_as: 20260619-inbox-CR\n\n# Title', 'job.md'), true);
  });
  test('blocked-pending-user marks completed', () => {
    assert.equal(isCompletedInboxFile('status: blocked-pending-user\n\n# Title', 'job.md'), true);
  });
  test('pending job is not completed', () => {
    assert.equal(isCompletedInboxFile('# Pending Job\n\n## Goal\nFix.\n', 'pending-job.md'), false);
  });
  test('deferred without processed_as still shows', () => {
    assert.equal(isCompletedInboxFile('deferred_at: 2026-01-01T00:00:00Z\n\n# Title', 'job.md'), false);
  });
  test('root file with same basename in processed/ is stale', () => {
    const inboxDir = path.join(tmpDir, '.orchestrate', 'inbox');
    assert.equal(
      isCompletedInboxFile('# Duplicate\n\n## Goal\nDone.\n', 'stale-duplicate-root.md', inboxDir),
      true,
    );
  });
  test('registry-complete task ID in content is stale', () => {
    const complete = new Set(['20260620-inbox-SBMT']);
    assert.equal(
      isCompletedInboxFile(
        '# SBMT follow-up\n\nTask ID: 20260620-inbox-SBMT\n',
        'stale-registry-complete.md',
        null,
        complete,
      ),
      true,
    );
    assert.equal(
      isCompletedInboxFile('# New work\n\n## Goal\nFresh.\n', 'fresh-job.md', null, complete),
      false,
    );
  });
});

describe('readTendMode', () => {
  test('defaults to go auto when agent.conf missing', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orch-tendmode-'));
    try {
      assert.equal(readTendMode(dir), 'go auto');
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
  test('reads TEND_MODE from agent.conf', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orch-tendmode-'));
    try {
      fs.mkdirSync(path.join(dir, '.orchestrate'), { recursive: true });
      fs.writeFileSync(path.join(dir, '.orchestrate', 'agent.conf'), 'TEND_MODE=notify\n');
      assert.equal(readTendMode(dir), 'notify');
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe('readAgentStatus', () => {
  test('cursor runner flags IDE requirement', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orch-agent-'));
    const prev = process.env.CURSOR_IDE_RUNNING;
    try {
      fs.mkdirSync(path.join(dir, '.orchestrate'), { recursive: true });
      fs.writeFileSync(path.join(dir, '.orchestrate', 'agent.conf'), 'RUNNER=cursor\nTEND_MODE="go auto"\n');
      process.env.CURSOR_IDE_RUNNING = '0';
      const s = readAgentStatus(dir);
      assert.equal(s.runner, 'cursor');
      assert.equal(s.cursorRequired, true);
      assert.equal(s.cursorIdeRunning, false);
      assert.equal(s.cursorOk, false);
      process.env.CURSOR_IDE_RUNNING = '1';
      const s2 = readAgentStatus(dir);
      assert.equal(s2.cursorOk, true);
    } finally {
      if (prev === undefined) delete process.env.CURSOR_IDE_RUNNING;
      else process.env.CURSOR_IDE_RUNNING = prev;
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('claude runner does not require Cursor IDE', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orch-agent-'));
    const prev = process.env.CURSOR_IDE_RUNNING;
    try {
      fs.mkdirSync(path.join(dir, '.orchestrate'), { recursive: true });
      fs.writeFileSync(path.join(dir, '.orchestrate', 'agent.conf'), 'RUNNER=claude\n');
      process.env.CURSOR_IDE_RUNNING = '0';
      const s = readAgentStatus(dir);
      assert.equal(s.runner, 'claude');
      assert.equal(s.cursorRequired, false);
      assert.equal(s.cursorOk, true);
    } finally {
      if (prev === undefined) delete process.env.CURSOR_IDE_RUNNING;
      else process.env.CURSOR_IDE_RUNNING = prev;
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('readRunner returns runner from agent.conf', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orch-agent-'));
    try {
      fs.mkdirSync(path.join(dir, '.orchestrate'), { recursive: true });
      fs.writeFileSync(path.join(dir, '.orchestrate', 'agent.conf'), 'RUNNER=cursor\n');
      assert.equal(readRunner(dir), 'cursor');
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});

test('/api/agent-status returns runner and IDE fields', async () => {
  const { status, body } = await get('/api/agent-status');
  assert.equal(status, 200);
  assert.ok('runner' in body);
  assert.ok('tendMode' in body);
  assert.ok('cursorIdeRunning' in body);
  assert.ok('cursorRequired' in body);
  assert.ok('cursorOk' in body);
});

// ── launchd unit tests ────────────────────────────────────────────────────────

const MINIMAL_PLIST = (label, interval) => `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${label}</string>
  <key>StartInterval</key><integer>${interval}</integer>
</dict></plist>`;

describe('intervalLabel', () => {
  test('sub-minute returns Ns', () => assert.equal(intervalLabel(30), '30s'));
  test('5 min', () => assert.equal(intervalLabel(300), '5 min'));
  test('1 hr', () => assert.equal(intervalLabel(3600), '1 hr'));
  test('2 hr rounds', () => assert.equal(intervalLabel(7200), '2 hr'));
  test('90 min rounds to 2 hr', () => assert.equal(intervalLabel(5400), '2 hr'));
});

describe('buildLaunchdAgents', () => {
  test('empty dir returns []', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orch-launchd-'));
    try {
      assert.deepEqual(buildLaunchdAgents(dir, ''), []);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('nonexistent dir returns []', () => {
    assert.deepEqual(buildLaunchdAgents('/tmp/no-such-orch-dir-xyzzy', ''), []);
  });

  test('status: pid="-" exitStatus="0" → ok', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orch-launchd-'));
    try {
      fs.writeFileSync(path.join(dir, 'com.orchestrate.fake.plist'), MINIMAL_PLIST('com.orchestrate.fake', 300));
      const [a] = buildLaunchdAgents(dir, '- 0 com.orchestrate.fake\n');
      assert.equal(a.status, 'ok');
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('status: pid="-" exitStatus="1" → failed', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orch-launchd-'));
    try {
      fs.writeFileSync(path.join(dir, 'com.orchestrate.fake.plist'), MINIMAL_PLIST('com.orchestrate.fake', 300));
      const [a] = buildLaunchdAgents(dir, '- 1 com.orchestrate.fake\n');
      assert.equal(a.status, 'failed');
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('status: pid="123" → running', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orch-launchd-'));
    try {
      fs.writeFileSync(path.join(dir, 'com.orchestrate.fake.plist'), MINIMAL_PLIST('com.orchestrate.fake', 300));
      const [a] = buildLaunchdAgents(dir, '123 0 com.orchestrate.fake\n');
      assert.equal(a.status, 'running');
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('status: label not in launchctl output → unknown', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orch-launchd-'));
    try {
      fs.writeFileSync(path.join(dir, 'com.orchestrate.fake.plist'), MINIMAL_PLIST('com.orchestrate.fake', 300));
      const [a] = buildLaunchdAgents(dir, '- 0 com.other.service\n');
      assert.equal(a.status, 'unknown');
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('correct shape: {label, interval, lastRun, status, logPath}', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orch-launchd-'));
    try {
      fs.writeFileSync(path.join(dir, 'com.orchestrate.fake.plist'), MINIMAL_PLIST('com.orchestrate.fake', 300));
      const [a] = buildLaunchdAgents(dir, '- 0 com.orchestrate.fake\n');
      assert.ok('label' in a, 'has label');
      assert.ok('interval' in a, 'has interval');
      assert.ok('lastRun' in a, 'has lastRun');
      assert.ok('status' in a, 'has status');
      assert.ok('logPath' in a, 'has logPath');
      assert.equal(a.label, 'com.orchestrate.fake');
      assert.equal(a.interval, '5 min');
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('includes extra label from LAUNCHD_WATCH when plist exists', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orch-launchd-'));
    try {
      fs.writeFileSync(path.join(dir, 'com.orchestrate.fake.plist'), MINIMAL_PLIST('com.orchestrate.fake', 300));
      fs.writeFileSync(path.join(dir, 'com.inbox-zero.catchup.plist'), MINIMAL_PLIST('com.inbox-zero.catchup', 3600));
      const agents = buildLaunchdAgents(dir, '- 0 com.orchestrate.fake\n- 0 com.inbox-zero.catchup\n', '', null, ['com.inbox-zero.catchup']);
      assert.equal(agents.length, 2);
      const emailJob = agents.find(a => a.label === 'com.inbox-zero.catchup');
      assert.ok(emailJob, 'com.inbox-zero.catchup must be present');
      assert.equal(emailJob.interval, '1 hr');
      assert.equal(emailJob.status, 'ok');
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('silently skips extra label when plist does not exist', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orch-launchd-'));
    try {
      fs.writeFileSync(path.join(dir, 'com.orchestrate.fake.plist'), MINIMAL_PLIST('com.orchestrate.fake', 300));
      const agents = buildLaunchdAgents(dir, '- 0 com.orchestrate.fake\n', '', null, ['com.nonexistent.job']);
      assert.equal(agents.length, 1, 'nonexistent extra label must be skipped silently');
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('does not duplicate com.orchestrate.* job when also listed in extraLabels', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orch-launchd-'));
    try {
      fs.writeFileSync(path.join(dir, 'com.orchestrate.fake.plist'), MINIMAL_PLIST('com.orchestrate.fake', 300));
      const agents = buildLaunchdAgents(dir, '', '', null, ['com.orchestrate.fake']);
      assert.equal(agents.length, 1, 'com.orchestrate.fake must not be duplicated');
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe('tendThrottleHint', () => {
  test('detects session limit reset from both-runners heartbeat', () => {
    const hb = '[2026-06-19T17:46:44Z] run-job — both runners session-limited (resets 5:10pm (America/New_York)); inbox queued until reset\n';
    assert.equal(tendThrottleHint(hb), '5:10pm (America/New_York)');
  });

  test('detects reset from vendor agent output line', () => {
    const hb = "You've hit your session limit · resets 5:10pm (America/New_York)\n";
    assert.equal(tendThrottleHint(hb), '5:10pm (America/New_York)');
  });

  test('detects single-runner fallback line', () => {
    const hb = '[2026-06-19T17:36:41Z] run-job — claude hit session limit (resets 5:10pm); trying cursor\n';
    assert.equal(tendThrottleHint(hb), '5:10pm');
  });

  test('returns null when no throttle line', () => {
    assert.equal(tendThrottleHint('[2026-06-19T17:20:03Z] tend-auto — completed\n'), null);
  });

  test('ignores Session limitation task prose (not agent quota)', () => {
    const hb = [
      '**Session limitation:** Shell tool was rejected in this session',
      '[2026-06-19T18:30:00Z] tend — cycle complete (1 task executed, 0 pending)',
    ].join('\n');
    assert.equal(tendThrottleHint(hb), null);
  });

  test('clears throttle hint when tend succeeded after session limit', () => {
    const hb = [
      '[2026-06-19T17:46:44Z] run-job — both runners session-limited (resets 5:10pm (America/New_York)); inbox queued',
      '[2026-06-19T18:30:00Z] tend — cycle complete (1 task executed, 0 pending)',
    ].join('\n');
    assert.equal(tendThrottleHint(hb), null);
  });
});

describe('parseTendHealth', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'orch-tend-health-'));
  const orch = path.join(tmp, '.orchestrate');
  fs.mkdirSync(path.join(orch, 'logs'), { recursive: true });
  fs.writeFileSync(path.join(tmp, '.orchestrate', 'agent.conf'), 'RUNNER=cursor\n');

  test('detects session limit throttling', () => {
    const hb = '[2026-06-19T17:46:44Z] run-job — both runners session-limited (resets 5:10pm (America/New_York)); inbox queued\n';
    const r = parseTendHealth(tmp, hb, '', { pid: '-', exitStatus: '0' });
    assert.equal(r.ok, false);
    assert.equal(r.status, 'throttled');
    assert.ok(r.resetHint);
  });

  test('detects connection lost', () => {
    const hb = '[2026-06-19T18:00:00Z] run-job — both runners connection-lost; will retry next cycle\n';
    const r = parseTendHealth(tmp, hb, '', null);
    assert.equal(r.status, 'degraded');
  });

  test('detects cli.json misconfiguration', () => {
    const hb = '[2026-06-19T18:00:00Z] run-job — cursor cli.json invalid; tend deferred (CURSOR_FALLBACK=never)\n';
    const r = parseTendHealth(tmp, hb, '', null);
    assert.equal(r.status, 'misconfigured');
  });

  test('detects Cursor IDE not running', () => {
    const hb = '[2026-06-19T18:00:00Z] run-job — Cursor IDE required but not running; tend deferred\n';
    const r = parseTendHealth(tmp, hb, '', null);
    assert.equal(r.status, 'blocked');
  });

  test('detects launchd hard failure', () => {
    const r = parseTendHealth(tmp, '', '', { pid: '-', exitStatus: '1' });
    assert.equal(r.status, 'failed');
  });

  test('detects run-job syntax error in stderr', () => {
    const err = '/Users/haimengzhou/apps/ai-console/.orchestrate/bin/run-job.sh: line 203: syntax error near unexpected token `)\'\n';
    const r = parseTendHealth(tmp, '', err, { pid: '-', exitStatus: '0' });
    assert.equal(r.status, 'failed');
    assert.match(r.message, /syntax error/i);
  });

  test('detects stale tend lock', () => {
    const lockDir = fs.mkdtempSync(path.join(os.tmpdir(), 'orch-tend-lock-'));
    const lockPath = path.join(lockDir, '.orchestrate', '.tend.lock');
    fs.mkdirSync(path.dirname(lockPath), { recursive: true });
    fs.writeFileSync(lockPath, 'locked\n');
    const stale = new Date(Date.now() - 400_000);
    fs.utimesSync(lockPath, stale, stale);
    const hb = '[2026-01-01T00:00:00Z] tend — idle\n';
    const r = parseTendHealth(lockDir, hb, '', { pid: '-', exitStatus: '0' });
    assert.equal(r.status, 'stuck');
    fs.rmSync(lockDir, { recursive: true, force: true });
  });

  test('returns ok when logs are clean', () => {
    const hb = '[2026-06-19T17:20:03Z] tend-auto — completed\n';
    const r = parseTendHealth(tmp, hb, '', { pid: '-', exitStatus: '0' });
    assert.equal(r.ok, true);
    assert.equal(r.status, 'ok');
  });

  test('returns ok when tend succeeded after session limit', () => {
    const hb = [
      '[2026-06-19T17:46:44Z] run-job — both runners session-limited (resets 5:10pm (America/New_York)); inbox queued',
      '[2026-06-19T18:30:00Z] tend — cycle complete (1 task executed, 0 pending)',
    ].join('\n');
    const r = parseTendHealth(tmp, hb, '', { pid: '-', exitStatus: '0' });
    assert.equal(r.ok, true);
    assert.equal(r.status, 'ok');
  });

  test('ignores Session limitation prose in task dump', () => {
    const hb = [
      '**Session limitation:** Shell tool was rejected in this session',
      '[2026-06-19T18:30:00Z] tend — cycle complete (1 task executed, 0 pending)',
    ].join('\n');
    const r = parseTendHealth(tmp, hb, '', { pid: '-', exitStatus: '0' });
    assert.equal(r.ok, true);
    assert.equal(r.status, 'ok');
  });

  test('ignores stale syntax error when run-job.sh passes bash -n now', () => {
    const scriptDir = path.join(tmp, '.orchestrate', 'bin');
    fs.mkdirSync(scriptDir, { recursive: true });
    fs.writeFileSync(path.join(scriptDir, 'run-job.sh'), '#!/usr/bin/env bash\necho ok\n');
    const err = 'run-job.sh: line 203: syntax error near unexpected token `)\'\n';
    const hb = '[2026-06-19T18:30:00Z] tend — cycle complete (1 task executed, 0 pending)\n';
    const r = parseTendHealth(tmp, hb, err, { pid: '-', exitStatus: '0' });
    assert.equal(r.ok, true);
    assert.equal(r.status, 'ok');
  });

  test('ignores stale connection lost when tend succeeded later', () => {
    const err = 'Connection lost, reconnecting to https://agentn.global.api5.cursor.sh (attempt 1)...\n';
    const hb = '[2026-06-19T18:30:00Z] tend — cycle complete (1 task executed, 0 pending)\n';
    const r = parseTendHealth(tmp, hb, err, { pid: '-', exitStatus: '0' });
    assert.equal(r.ok, true);
    assert.equal(r.status, 'ok');
  });

  after(() => {
    fs.rmSync(tmp, { recursive: true, force: true });
  });
});

test('/api/tend-status returns health shape', async () => {
  const { status, body } = await get('/api/tend-status');
  assert.equal(status, 200);
  assert.ok('ok' in body);
  assert.ok('status' in body);
  assert.ok('message' in body);
  assert.ok('runner' in body);
});

describe('buildLaunchdAgents tend throttle', () => {
  test('marks tend ok as throttled when heartbeat shows session limit', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orch-launchd-'));
    try {
      fs.writeFileSync(path.join(dir, 'com.orchestrate.tend.plist'), MINIMAL_PLIST('com.orchestrate.tend', 300));
      const hb = '[2026-06-19T17:46:44Z] run-job — both runners session-limited (resets 5:10pm (America/New_York)); inbox queued until reset\n';
      const tendHealth = parseTendHealth(tmpDir, hb, '', { pid: '-', exitStatus: '0' });
      const [a] = buildLaunchdAgents(dir, '- 0 com.orchestrate.tend\n', hb, tendHealth);
      assert.equal(a.status, 'throttled (5:10pm (America/New_York))');
      assert.ok(a.tendHealth);
      assert.equal(a.tendHealth.status, 'throttled');
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('marks tend failed when tendHealth reports syntax error', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orch-launchd-'));
    try {
      fs.writeFileSync(path.join(dir, 'com.orchestrate.tend.plist'), MINIMAL_PLIST('com.orchestrate.tend', 300));
      const err = 'run-job.sh: line 203: syntax error near unexpected token\n';
      const tendHealth = parseTendHealth(tmpDir, '', err, { pid: '-', exitStatus: '2' });
      const [a] = buildLaunchdAgents(dir, '- 2 com.orchestrate.tend\n', '', tendHealth);
      assert.equal(a.status, 'failed');
      assert.equal(a.tendHealth.status, 'failed');
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});

test('/api/launchd returns array with correct shape', async () => {
  const { status, body } = await get('/api/launchd');
  assert.equal(status, 200);
  assert.ok(Array.isArray(body), 'body should be an array');
  assert.ok(body.length >= 1, 'should have at least 1 launchd agent on this machine');
  for (const item of body) {
    assert.ok('label' in item, 'item has label');
    assert.ok('interval' in item, 'item has interval');
    assert.ok('lastRun' in item, 'item has lastRun');
    assert.ok('status' in item, 'item has status');
    assert.ok('logPath' in item, 'item has logPath');
  }
});

describe('manifestMatchesRegistry', () => {
  test('matches prefix-style archive filenames', () => {
    assert.equal(
      manifestMatchesRegistry('20260617-inbox-1-inbox-log-analyzer-skill.md', '20260617-inbox-1'),
      true,
    );
  });

  test('matches timestamped archive filenames', () => {
    assert.equal(
      manifestMatchesRegistry('20260619-130100-inbox-AD-analyzer-daily-run.md', '20260619-inbox-AD'),
      true,
    );
  });

  test('rejects unrelated filenames', () => {
    assert.equal(
      manifestMatchesRegistry('20260619-130200-inbox-AP-agent-permissions-hardening.md', '20260619-inbox-AD'),
      false,
    );
  });

  test('matches timestamp-prefixed archives with embedded task id', () => {
    assert.equal(
      manifestMatchesRegistry('20260619-171925-20260619-inbox-CF-cursor-fallback.md', '20260619-inbox-CF'),
      true,
    );
  });
});

describe('resolveHistoryDatetime', () => {
  test('prefers last_activity over archive filename timestamp', () => {
    assert.equal(
      resolveHistoryDatetime('20260619-172105-20260619-inbox-5B-5-borough-kmz.md', '2026-06-19', '2026-06-19T17:20:00Z'),
      '2026-06-19T17:20:00Z',
    );
  });

  test('uses archive filename timestamp when last_activity absent', () => {
    assert.equal(
      resolveHistoryDatetime('20260619-172105-20260619-inbox-5B-5-borough-kmz.md', '2026-06-19', ''),
      '2026-06-19T17:21:05Z',
    );
  });

  test('prefers last_activity over batch archive timestamp (tend batch writes)', () => {
    assert.equal(
      resolveHistoryDatetime('20260619-131306-20260619-inbox-DA2-daily-analyzer-run-2.md', '2026-06-19', '2026-06-20T00:15:00Z'),
      '2026-06-20T00:15:00Z',
    );
  });

  test('uses noon UTC for date-only manifest values', () => {
    assert.equal(resolveHistoryDatetime('orphan-slug.md', '2026-06-17', ''), '2026-06-17T12:00:00Z');
  });

  test('uses noon UTC for date-only filename prefix when last_activity absent', () => {
    assert.equal(resolveHistoryDatetime('20260617-inbox-2-monitor-ui-redesign.md', '', ''), '2026-06-17T12:00:00Z');
  });

  test('prefers last_activity over date-only filename prefix (registry stub)', () => {
    assert.equal(
      resolveHistoryDatetime('20260617-inbox-3', '', '2026-06-17T23:05:00Z'),
      '2026-06-17T23:05:00Z',
    );
  });

  test('prefers last_activity for date-only archive filenames', () => {
    assert.equal(
      resolveHistoryDatetime('20260617-inbox-1-analyzer-daily-run.md', '2026-06-17', '2026-06-17T13:01:00Z'),
      '2026-06-17T13:01:00Z',
    );
  });

  test('does not apply date-only noon to bare registry task id without last_activity', () => {
    assert.equal(resolveHistoryDatetime('20260617-inbox-3', '', ''), '');
  });

  test('uses completion hint when last_activity is placeholder noon', () => {
    assert.equal(
      resolveHistoryDatetime(
        '20260620-inbox-DA3-analyzer-daily-run.md',
        '2026-06-20',
        '2026-06-20T12:00:00Z',
        '2026-06-20T12:00:01Z',
      ),
      '2026-06-20T12:00:01Z',
    );
  });

  test('prefers real last_activity over completion hint', () => {
    assert.equal(
      resolveHistoryDatetime('f.md', '2026-06-20', '2026-06-20T15:30:00Z', '2026-06-20T12:00:01Z'),
      '2026-06-20T15:30:00Z',
    );
  });

  test('isPlaceholderTimestamp detects noon UTC and date-only', () => {
    assert.equal(isPlaceholderTimestamp('2026-06-20T12:00:00Z'), true);
    assert.equal(isPlaceholderTimestamp('2026-06-20'), true);
    assert.equal(isPlaceholderTimestamp('2026-06-20T15:30:00Z'), false);
  });

  test('isFutureTimestamp detects timestamps more than 5 minutes ahead', () => {
    const future = new Date(Date.now() + 10 * 60 * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
    const past = '2020-01-01T12:00:00Z';
    assert.equal(isFutureTimestamp(future), true);
    assert.equal(isFutureTimestamp(past), false);
  });

  test('skips future archive filename timestamp when last_activity absent', () => {
    const future = new Date(Date.now() + 60 * 60 * 1000);
    const y = future.getUTCFullYear();
    const m = String(future.getUTCMonth() + 1).padStart(2, '0');
    const d = String(future.getUTCDate()).padStart(2, '0');
    const h = String(future.getUTCHours()).padStart(2, '0');
    const min = String(future.getUTCMinutes()).padStart(2, '0');
    const sec = String(future.getUTCSeconds()).padStart(2, '0');
    const fn = `${y}${m}${d}-${h}${min}${sec}-20260621-inbox-AA6C.md`;
    assert.equal(resolveHistoryDatetime(fn, `${y}-${m}-${d}`, ''), '');
  });

  test('rejects future last_activity and uses non-future completion hint', () => {
    const future = new Date(Date.now() + 60 * 60 * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
    assert.equal(
      resolveHistoryDatetime('20260621-160200-20260621-inbox-AA6C.md', '2026-06-21', future, '2026-06-21T15:45:14Z'),
      '2026-06-21T15:45:14Z',
    );
  });

  test('AA6C/7510 batch archive: prefers real last_activity over filename ts', () => {
    assert.equal(
      resolveHistoryDatetime(
        '20260621-160200-20260621-inbox-AA6C-langgraph-readme.md',
        '2026-06-21',
        '2026-06-21T15:45:14Z',
      ),
      '2026-06-21T15:45:14Z',
    );
    assert.equal(
      resolveHistoryDatetime(
        '20260621-160200-20260621-inbox-7510-kube-pretooluse-hook.md',
        '2026-06-21',
        '2026-06-21T15:45:15Z',
      ),
      '2026-06-21T15:45:15Z',
    );
  });
});

describe('buildHistoryRows', () => {
  test('links registry row to timestamped manifest entry with archive content', () => {
    const registry = [{
      id: '20260619-inbox-AD',
      summary: 'Run inbox-log-analyzer (daily 9am enqueue)',
      status: 'complete',
      last_activity: '2026-06-19T13:01:00Z',
    }];
    const manifest = [{
      date: '2026-06-19',
      filename: '20260619-130100-inbox-AD-analyzer-daily-run.md',
      summary: 'Run inbox-log-analyzer daily scan — 9 new logs, 0 findings',
      tags: 'inbox-log-analyzer, tend-auto',
    }];
    const entries = {
      '20260619-130100-inbox-AD-analyzer-daily-run.md': '# Run inbox-log-analyzer\n\nphase details here',
    };

    const rows = buildHistoryRows(registry, manifest, entries, '');
    assert.equal(rows.length, 1);
    assert.equal(rows[0].filename, '20260619-130100-inbox-AD-analyzer-daily-run.md');
    assert.ok(rows[0].content.includes('phase details here'));
    assert.equal(rows[0].dateIso, '2026-06-19T13:01:00Z');
  });

  test('links registry row to on-disk archive when MANIFEST entry is missing', () => {
    const registry = [{
      id: '20260619-inbox-CF',
      summary: 'Add Claude fallback to run-job.sh when Cursor not running',
      status: 'complete',
      last_activity: '2026-06-19T12:55:00Z',
    }];
    const manifest = [];
    const entries = {
      '20260619-171925-20260619-inbox-CF-cursor-fallback.md': '# CF archive\n\ncursor fallback details',
    };

    const rows = buildHistoryRows(registry, manifest, entries, '');
    assert.equal(rows.length, 1);
    assert.equal(rows[0].filename, '20260619-171925-20260619-inbox-CF-cursor-fallback.md');
    assert.ok(rows[0].content.includes('cursor fallback details'));
    assert.equal(rows[0].dateIso, '2026-06-19T12:55:00Z');
  });

  test('prefers registry last_activity over batch archive filename for History dateIso', () => {
    const registry = [{
      id: '20260619-inbox-TR',
      summary: 'Add test runner to sy_promotion_merchant_scraper',
      status: 'complete',
      last_activity: '2026-06-20T12:00:00Z',
    }];
    const manifest = [{
      date: '2026-06-19',
      filename: '20260619-131306-20260619-inbox-TR-sy-promotion-test-runner.md',
      summary: 'sy_promotion test runner',
      tags: 'sy-promotion, pytest',
    }];
    const entries = {
      '20260619-131306-20260619-inbox-TR-sy-promotion-test-runner.md': '# TR archive\n',
    };

    const rows = buildHistoryRows(registry, manifest, entries, '');
    assert.equal(rows.length, 1);
    assert.equal(rows[0].dateIso, '2026-06-20T12:00:00Z');
  });
});

describe('archiveDateFromFilename', () => {
  test('extracts date from timestamped archive name', () => {
    assert.equal(
      archiveDateFromFilename('20260619-171925-20260619-inbox-CF-cursor-fallback.md'),
      '2026-06-19',
    );
  });
});

describe('findHistoryEntry', () => {
  test('prefers manifest match over disk', () => {
    const manifest = [{
      date: '2026-06-19',
      filename: '20260619-130100-inbox-AD-analyzer-daily-run.md',
      summary: 'manifest AD',
      tags: 'a',
    }];
    const filenames = [
      '20260619-130100-inbox-AD-analyzer-daily-run.md',
      '20260619-131306-20260619-inbox-AD-daily-analyzer-run.md',
    ];
    const entry = findHistoryEntry('20260619-inbox-AD', manifest, filenames);
    assert.equal(entry.filename, '20260619-130100-inbox-AD-analyzer-daily-run.md');
  });

  test('resolves duplicate registry alias RMB to 5B archive', () => {
    const manifest = [{
      date: '2026-06-19',
      filename: '20260619-172105-20260619-inbox-5B-5-borough-kmz.md',
      summary: 'sy_promotion — 5 borough census race KMZ maps',
      tags: 'census, sy-promotion',
    }];
    const filenames = ['20260619-172105-20260619-inbox-5B-5-borough-kmz.md'];
    const entry = findHistoryEntry('20260619-inbox-RMB', manifest, filenames);
    assert.equal(entry.filename, '20260619-172105-20260619-inbox-5B-5-borough-kmz.md');
  });
});

describe('buildHistoryRows dedupe', () => {
  test('skips duplicate registry alias row when archive already linked', () => {
    const registry = [
      { id: '20260619-inbox-5B', summary: '5 borough KMZs', status: 'complete', last_activity: '2026-06-19T17:20:00Z' },
      { id: '20260619-inbox-RMB', summary: '5 borough KMZs dup', status: 'complete', last_activity: '2026-06-19T17:20:00Z' },
    ];
    const manifest = [{
      date: '2026-06-19',
      filename: '20260619-172105-20260619-inbox-5B-5-borough-kmz.md',
      summary: 'sy_promotion — 5 borough census race KMZ maps',
      tags: 'sy-promotion',
    }];
    const entries = {
      '20260619-172105-20260619-inbox-5B-5-borough-kmz.md': '# archive',
    };
    const rows = buildHistoryRows(registry, manifest, entries, '');
    assert.equal(rows.length, 1);
    assert.equal(rows[0].filename, '20260619-172105-20260619-inbox-5B-5-borough-kmz.md');
    assert.equal(rows[0].taskId, '20260619-inbox-5B');
  });

  test('prefers canonical registry ID when alias row is processed first', () => {
    const registry = [
      { id: '20260619-inbox-RMB', summary: '5 borough KMZs dup', status: 'complete', last_activity: '2026-06-19T17:20:00Z' },
      { id: '20260619-inbox-5B', summary: '5 borough KMZs', status: 'complete', last_activity: '2026-06-19T17:20:00Z' },
    ];
    const manifest = [{
      date: '2026-06-19',
      filename: '20260619-172105-20260619-inbox-5B-5-borough-kmz.md',
      summary: 'sy_promotion — 5 borough census race KMZ maps',
      tags: 'sy-promotion',
    }];
    const entries = {
      '20260619-172105-20260619-inbox-5B-5-borough-kmz.md': '# archive',
    };
    const rows = buildHistoryRows(registry, manifest, entries, '');
    assert.equal(rows.length, 1);
    assert.equal(rows[0].taskId, '20260619-inbox-5B');
  });

  test('includes date-only daily analyzer archive for registry row', () => {
    const registry = [{
      id: '20260620-inbox-DA3',
      summary: 'Run inbox-log-analyzer (daily enqueue)',
      status: 'complete',
      last_activity: '2026-06-20T12:00:00Z',
    }];
    const manifest = [{
      date: '2026-06-20',
      filename: '20260620-inbox-DA3-analyzer-daily-run.md',
      summary: 'Run inbox-log-analyzer daily scan — 0 new findings',
      tags: 'inbox-log-analyzer, tend-auto',
    }];
    const entries = {
      '20260620-inbox-DA3-analyzer-daily-run.md': '# DA3 daily run\n\n0 findings',
    };
    const rows = buildHistoryRows(registry, manifest, entries, '');
    assert.equal(rows.length, 1);
    assert.equal(rows[0].taskId, '20260620-inbox-DA3');
    assert.equal(rows[0].dateIso, '2026-06-20T12:00:00Z');
    assert.ok(rows[0].content.includes('0 findings'));
  });

  test('synthesizes non-empty content for registry-only complete rows from logs', () => {
    const logsDir = path.join(tmpDir, '.orchestrate', 'logs');
    fs.writeFileSync(path.join(logsDir, '20260619-inbox-IA3-tend.log'),
      '=== Tend-driven execution ===\nsummary: scanned logs\n=== done ===\n');
    const registry = [{
      id: '20260619-inbox-IA3',
      summary: 'Run inbox-log-analyzer',
      status: 'complete',
      last_activity: '2026-06-19T22:30:00Z',
    }];
    const rows = buildHistoryRows(registry, [], {}, logsDir);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].hasArchive, false);
    assert.ok(rows[0].content.includes('Run inbox-log-analyzer'));
    assert.ok(rows[0].content.includes('scanned logs'));
  });

  test('includes on-disk archive not listed in MANIFEST', () => {
    const registry = [];
    const manifest = [];
    const entries = {
      '20260619-orphan-disk-only.md': '# orphan archive\n\nrecovered from disk scan',
    };
    const rows = buildHistoryRows(registry, manifest, entries, '');
    assert.equal(rows.length, 1);
    assert.equal(rows[0].filename, '20260619-orphan-disk-only.md');
    assert.ok(rows[0].content.includes('recovered from disk scan'));
    assert.equal(rows[0].hasArchive, true);
  });
});

describe('extractTaskIdFromFilename', () => {
  test('extracts inbox task id from timestamped archive name', () => {
    assert.equal(
      extractTaskIdFromFilename('20260619-172105-20260619-inbox-5B-5-borough-kmz.md'),
      '20260619-inbox-5B',
    );
  });
});

describe('buildHistoryRows — duplicate taskId prevention', () => {
  test('does not create duplicate rows when MANIFEST has two archives for same task', () => {
    const registry = [{
      id: '20260619-inbox-AD',
      summary: 'Run inbox-log-analyzer daily scan',
      status: 'complete',
      last_activity: '2026-06-19T13:01:00Z',
    }];
    // MANIFEST has both an old-format and a batch-format archive for the same task
    const manifest = [
      {
        date: '2026-06-19',
        filename: '20260619-130100-inbox-AD-analyzer-daily-run.md',
        summary: 'Run inbox-log-analyzer — 9 new logs, 0 findings',
        tags: 'inbox-log-analyzer',
      },
      {
        date: '2026-06-19',
        filename: '20260619-131306-20260619-inbox-AD-daily-analyzer-run.md',
        summary: 'Run inbox-log-analyzer daily scan — tend batch archive',
        tags: 'inbox-log-analyzer, tend-auto',
      },
    ];
    const entries = {
      '20260619-130100-inbox-AD-analyzer-daily-run.md': '# AD archive old\n\ncontent',
      '20260619-131306-20260619-inbox-AD-daily-analyzer-run.md': '# AD archive batch\n\ncontent',
    };

    const rows = buildHistoryRows(registry, manifest, entries, '');
    assert.equal(rows.length, 1, 'two MANIFEST entries for same task must produce exactly 1 history row');
    assert.equal(rows[0].taskId, '20260619-inbox-AD');
  });

  test('does not create duplicate rows when disk has two archives for same task', () => {
    const registry = [{
      id: '20260620-inbox-NHH',
      summary: 'Tend auto-resolve needs_human',
      status: 'complete',
      last_activity: '2026-06-20T19:05:00Z',
    }];
    const manifest = [
      {
        date: '2026-06-20',
        filename: '20260620-190000-inbox-NHH-needs-human-auto-resolve.md',
        summary: 'Tend: auto-resolve stale needs_human',
        tags: 'tend, needs_human',
      },
    ];
    // Disk also has the batch archive not in MANIFEST
    const entries = {
      '20260620-190000-inbox-NHH-needs-human-auto-resolve.md': '# NHH archive\n\ncontent',
      '20260619-131306-20260620-inbox-NHH-tend-auto-resolve-stale-needs-human.md': '# NHH batch\n\ncontent',
    };

    const rows = buildHistoryRows(registry, manifest, entries, '');
    assert.equal(rows.length, 1, 'manifest entry + orphan disk entry for same task must produce 1 row');
    assert.equal(rows[0].taskId, '20260620-inbox-NHH');
  });

  test('all complete registry IDs appear exactly once in history rows', () => {
    const registry = [
      { id: '20260619-inbox-AD', summary: 'task A', status: 'complete', last_activity: '2026-06-19T13:01:00Z' },
      { id: '20260620-inbox-FIX', summary: 'task B', status: 'complete', last_activity: '2026-06-20T12:00:01Z' },
      { id: '20260620-inbox-STUB', summary: 'task C no archive', status: 'complete', last_activity: '2026-06-20T10:00:00Z' },
    ];
    const manifest = [
      { date: '2026-06-19', filename: '20260619-130100-inbox-AD-analyzer-daily-run.md', summary: 'AD', tags: '' },
      { date: '2026-06-19', filename: '20260619-131306-20260619-inbox-AD-daily-analyzer-run.md', summary: 'AD batch', tags: '' },
      { date: '2026-06-20', filename: '20260620-inbox-FIX-fix-inbox-filter.md', summary: 'FIX', tags: '' },
      { date: '2026-06-20', filename: '20260619-131306-20260620-inbox-FIX-page-completed.md', summary: 'FIX batch', tags: '' },
    ];
    const entries = {};
    for (const e of manifest) entries[e.filename] = `# ${e.summary}\n`;

    const rows = buildHistoryRows(registry, manifest, entries, '');
    const taskIds = rows.map(r => r.taskId).filter(Boolean);
    const uniqueIds = new Set(taskIds);
    assert.equal(uniqueIds.size, taskIds.length, 'no two rows should share the same taskId');

    // All 3 complete registry IDs must be present
    for (const reg of registry) {
      assert.ok(
        rows.some(r => r.taskId === reg.id || manifestMatchesRegistry(r.filename, reg.id)),
        `registry ID ${reg.id} must appear in history rows`,
      );
    }
  });

  test('/api/history returns no duplicate taskIds in integration', async () => {
    const { status, body } = await get('/api/history');
    assert.equal(status, 200);
    const rows = body.rows || [];
    const taskIds = rows.map(r => r.taskId).filter(Boolean);
    const counts = {};
    for (const id of taskIds) counts[id] = (counts[id] || 0) + 1;
    const dupes = Object.entries(counts).filter(([, v]) => v > 1).map(([k]) => k);
    assert.deepEqual(dupes, [], `duplicate taskIds found in /api/history: ${dupes.join(', ')}`);
  });
});

describe('historyStats', () => {
  test('counts archive vs registry-only rows', () => {
    const registry = [
      { id: 'a', status: 'complete' },
      { id: 'b', status: 'complete' },
    ];
    const rows = [
      { taskId: 'a', hasArchive: true },
      { taskId: 'b', hasArchive: false },
      { hasArchive: true },
    ];
    const stats = historyStats(rows, registry);
    assert.equal(stats.total, 3);
    assert.equal(stats.withArchive, 2);
    assert.equal(stats.registryOnly, 1);
    assert.deepEqual(stats.missingCompleteIds, []);
  });

  test('reports missing complete registry IDs', () => {
    const registry = [
      { id: '20260620-inbox-DA3', status: 'complete' },
      { id: '20260619-inbox-RMB', status: 'complete' },
    ];
    const rows = [{ taskId: 'other', hasArchive: true }];
    const missing = historyCoverage(registry, rows);
    assert.ok(missing.includes('20260620-inbox-DA3'));
    assert.ok(!missing.includes('20260619-inbox-RMB'));
  });
});

describe('readAgentConf', () => {
  test('reads runner, tendMode, cursorFallback from agent.conf', () => {
    const conf = readAgentConf(tmpDir);
    assert.equal(conf.runner, 'claude');
    assert.equal(conf.tendMode, 'go auto');
    assert.equal(conf.cursorFallback, 'auto');
    assert.equal(typeof conf.cursorIdeRunning, 'boolean');
  });

  test('parses LAUNCHD_WATCH as array of labels', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'orch-conf-'));
    try {
      fs.mkdirSync(path.join(dir, '.orchestrate'));
      fs.writeFileSync(path.join(dir, '.orchestrate', 'agent.conf'),
        'RUNNER=claude\nLAUNCHD_WATCH=com.inbox-zero.catchup,com.myapp.nightly\n');
      const conf = readAgentConf(dir);
      assert.deepEqual(conf.launchdWatch, ['com.inbox-zero.catchup', 'com.myapp.nightly']);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('launchdWatch defaults to [] when LAUNCHD_WATCH absent', () => {
    const conf = readAgentConf(tmpDir);
    assert.deepEqual(conf.launchdWatch, []);
  });

  test('CURSOR_IDE_RUNNING env overrides IDE check', () => {
    const prev = process.env.CURSOR_IDE_RUNNING;
    process.env.CURSOR_IDE_RUNNING = '1';
    assert.equal(isCursorIdeRunning(), true);
    process.env.CURSOR_IDE_RUNNING = '0';
    assert.equal(isCursorIdeRunning(), false);
    if (prev === undefined) delete process.env.CURSOR_IDE_RUNNING;
    else process.env.CURSOR_IDE_RUNNING = prev;
  });
});

describe('/api/agent-conf', () => {
  test('GET returns agent.conf fields', async () => {
    const { status, body } = await get('/api/agent-conf');
    assert.equal(status, 200);
    assert.equal(body.runner, 'claude');
    assert.equal(body.tendMode, 'go auto');
    assert.equal(body.cursorFallback, 'auto');
  });

  test('POST updates RUNNER safely', async () => {
    const { status, body } = await post('/api/agent-conf', { runner: 'cursor' });
    assert.equal(status, 200);
    assert.equal(body.runner, 'cursor');
    const disk = fs.readFileSync(path.join(tmpDir, '.orchestrate', 'agent.conf'), 'utf8');
    assert.match(disk, /^RUNNER=cursor/m);
  });

  test('POST rejects invalid runner', async () => {
    const { status, body } = await post('/api/agent-conf', { runner: 'bogus' });
    assert.equal(status, 400);
    assert.match(body.error, /cursor or claude/);
  });
});

describe('/api/agent-status', () => {
  test('includes enriched IDE fields beyond /api/agent-conf', async () => {
    const conf = await get('/api/agent-conf');
    const status = await get('/api/agent-status');
    assert.equal(conf.status, 200);
    assert.equal(status.status, 200);
    assert.equal(status.body.runner, conf.body.runner);
    assert.equal(status.body.tendMode, conf.body.tendMode);
    assert.ok('cursorRequired' in status.body);
    assert.ok('cursorOk' in status.body);
    assert.equal(status.body.cursorOk, !status.body.cursorRequired || status.body.cursorIdeRunning);
  });

  test('HTTP reflects cursorRequired when RUNNER=cursor', async () => {
    await post('/api/agent-conf', { runner: 'cursor' });
    const { status, body } = await get('/api/agent-status');
    assert.equal(status, 200);
    assert.equal(body.runner, 'cursor');
    assert.equal(body.cursorRequired, true);
    assert.equal(body.cursorOk, body.cursorIdeRunning);
    await post('/api/agent-conf', { runner: 'claude' });
  });
});

// ── findInboxSourceForTask ─────────────────────────────────────────────────────
describe('findInboxSourceForTask', () => {
  test('finds inbox file from heartbeat log registration line', () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'find-inbox-test-'));
    const logsDir = path.join(tmp, '.orchestrate', 'logs');
    const inboxDir = path.join(tmp, '.orchestrate', 'inbox', 'processed');
    fs.mkdirSync(logsDir, { recursive: true });
    fs.mkdirSync(inboxDir, { recursive: true });
    fs.writeFileSync(path.join(logsDir, 'heartbeat.log'),
      '[2026-06-21T14:05:14Z] inbox — registered (gated) "Hello Work" from gated/hello-work-20260621T140351.md\n');
    fs.writeFileSync(path.join(inboxDir, 'hello-work-20260621T140351.md'),
      'mode: gated\n\n# Hello Work\n\n## Goal\nTest task.\n\n## Acceptance Criteria\n- AC1\n');
    const result = findInboxSourceForTask(logsDir, path.join(tmp, '.orchestrate', 'inbox'), 'Hello Work');
    assert.ok(result, 'should find the inbox file');
    assert.ok(result.content.includes('## Goal'), 'content should include Goal section');
    assert.equal(result.filename, 'hello-work-20260621T140351.md');
    fs.rmSync(tmp, { recursive: true, force: true });
  });

  test('returns null when no matching heartbeat line', () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'find-inbox-miss-'));
    const logsDir = path.join(tmp, 'logs');
    const inboxDir = path.join(tmp, 'inbox');
    fs.mkdirSync(logsDir, { recursive: true });
    fs.mkdirSync(inboxDir, { recursive: true });
    fs.writeFileSync(path.join(logsDir, 'heartbeat.log'), '[2026-06-21T14:05:14Z] tend go auto — idle\n');
    const result = findInboxSourceForTask(logsDir, inboxDir, 'Nonexistent Task');
    assert.equal(result, null);
    fs.rmSync(tmp, { recursive: true, force: true });
  });
});

// ── approveRegistryTask ───────────────────────────────────────────────────────
describe('approveRegistryTask', () => {
  function makeTestProject(tmp, status = 'awaiting_go', mode = 'gated') {
    const orchestrateDir = path.join(tmp, '.orchestrate');
    const logsDir = path.join(orchestrateDir, 'logs');
    fs.mkdirSync(logsDir, { recursive: true });
    fs.writeFileSync(path.join(orchestrateDir, 'project.md'),
      `# Orchestrate — test\nlast_updated: 2026-01-01T00:00:00Z\n\n## Shared Context\n\n## Task Registry\n| ID | summary | mode | current_phase | status | last_activity |\n|----|---------|------|---------------|--------|---------------|\n| test-gated | Test Task | ${mode} | 1 | ${status} | 2026-01-01T00:00:00Z |\n`);
  }

  test('approve auto: sets status=pending mode=auto', () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'approve-test-'));
    makeTestProject(tmp);
    const result = approveRegistryTask(tmp, 'test-gated', 'auto');
    assert.equal(result.success, true);
    assert.equal(result.status, 'pending');
    assert.equal(result.mode, 'auto');
    const content = fs.readFileSync(path.join(tmp, '.orchestrate', 'project.md'), 'utf8');
    assert.ok(/\|\s*test-gated\s*\|[^|]*\|\s*auto\s*\|[^|]*\|\s*pending\s*\|/.test(content), 'registry should show auto+pending');
    fs.rmSync(tmp, { recursive: true, force: true });
  });

  test('cancel: sets status=failed', () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'cancel-test-'));
    makeTestProject(tmp);
    const result = approveRegistryTask(tmp, 'test-gated', 'cancel');
    assert.equal(result.success, true);
    assert.equal(result.status, 'failed');
    const content = fs.readFileSync(path.join(tmp, '.orchestrate', 'project.md'), 'utf8');
    assert.ok(/\|\s*test-gated\s*\|[^|]*\|\s*gated\s*\|[^|]*\|\s*failed\s*\|/.test(content), 'registry should show failed');
    fs.rmSync(tmp, { recursive: true, force: true });
  });

  test('returns error when task not awaiting_go', () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'approve-err-test-'));
    makeTestProject(tmp, 'running');
    const result = approveRegistryTask(tmp, 'test-gated', 'auto');
    assert.ok(result.error, 'should return error for non-awaiting_go task');
    fs.rmSync(tmp, { recursive: true, force: true });
  });

  test('appends approval entry to heartbeat.log', () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'approve-hb-test-'));
    makeTestProject(tmp);
    approveRegistryTask(tmp, 'test-gated', 'auto');
    const hb = fs.readFileSync(path.join(tmp, '.orchestrate', 'logs', 'heartbeat.log'), 'utf8');
    assert.ok(hb.includes('dashboard — approved go auto gated task test-gated'), 'heartbeat should record approval');
    fs.rmSync(tmp, { recursive: true, force: true });
  });
});

// ── kube reviews ──────────────────────────────────────────────────────────────
describe('kube reviews', () => {
  function seedPendingReview(tmp, id = 'test-kube-001') {
    const pendingDir = path.join(tmp, '.orchestrate', 'kube-reviews', 'pending');
    fs.mkdirSync(pendingDir, { recursive: true });
    const review = {
      id,
      created_at: '2026-06-21T17:00:00Z',
      command: 'kubectl scale deployment/foo --replicas=3',
      script_path: '/tmp/kube-cmd.abc123.sh',
      tier: 'live_mutating',
      project_root: tmp,
      status: 'pending',
    };
    fs.writeFileSync(path.join(pendingDir, `${id}.json`), JSON.stringify(review, null, 2));
    return review;
  }

  test('listKubeReviews returns pending reviews', () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'kube-list-'));
    seedPendingReview(tmp);
    const data = listKubeReviews(tmp);
    assert.equal(data.pendingCount, 1);
    assert.equal(data.pending[0].command, 'kubectl scale deployment/foo --replicas=3');
    fs.rmSync(tmp, { recursive: true, force: true });
  });

  test('approveKubeReview moves to processed and writes token', () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'kube-approve-'));
    fs.mkdirSync(path.join(tmp, '.orchestrate', 'logs'), { recursive: true });
    seedPendingReview(tmp, 'kube-approve-1');
    const result = approveKubeReview(tmp, 'kube-approve-1', 'approve');
    assert.equal(result.success, true);
    assert.equal(result.status, 'approved');
    assert.ok(!fs.existsSync(path.join(tmp, '.orchestrate', 'kube-reviews', 'pending', 'kube-approve-1.json')));
    assert.ok(fs.existsSync(path.join(tmp, '.orchestrate', 'kube-reviews', 'processed', 'kube-approve-1.json')));
    const token = fs.readFileSync(path.join(tmp, '.orchestrate', 'kube-reviews', 'approved', 'kube-approve-1.token'), 'utf8');
    assert.ok(token.includes('/tmp/kube-cmd.abc123.sh'));
    fs.rmSync(tmp, { recursive: true, force: true });
  });

  test('dismissKubeReview moves to processed without token', () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'kube-dismiss-'));
    fs.mkdirSync(path.join(tmp, '.orchestrate', 'logs'), { recursive: true });
    seedPendingReview(tmp, 'kube-dismiss-1');
    const result = approveKubeReview(tmp, 'kube-dismiss-1', 'dismiss');
    assert.equal(result.success, true);
    assert.equal(result.status, 'dismissed');
    assert.ok(!fs.existsSync(path.join(tmp, '.orchestrate', 'kube-reviews', 'approved', 'kube-dismiss-1.token')));
    fs.rmSync(tmp, { recursive: true, force: true });
  });

  test('GET /api/kube-reviews returns pending list', async () => {
    const pendingDir = path.join(tmpDir, '.orchestrate', 'kube-reviews', 'pending');
    fs.mkdirSync(pendingDir, { recursive: true });
    fs.writeFileSync(path.join(pendingDir, 'api-test-kube.json'), JSON.stringify({
      id: 'api-test-kube',
      created_at: '2026-06-21T17:00:00Z',
      command: 'helm uninstall foo',
      script_path: '/tmp/kube-cmd.test.sh',
      tier: 'live_mutating',
      status: 'pending',
    }, null, 2));
    const { status, body } = await get('/api/kube-reviews');
    assert.equal(status, 200);
    assert.ok(body.pending.some(r => r.id === 'api-test-kube'));
    assert.equal(body.attention.pendingCount, body.pending.length);
    fs.unlinkSync(path.join(pendingDir, 'api-test-kube.json'));
  });

  test('POST /api/kube-approve dismisses review', async () => {
    const pendingDir = path.join(tmpDir, '.orchestrate', 'kube-reviews', 'pending');
    fs.mkdirSync(pendingDir, { recursive: true });
    fs.writeFileSync(path.join(pendingDir, 'api-dismiss-kube.json'), JSON.stringify({
      id: 'api-dismiss-kube',
      created_at: '2026-06-21T17:00:00Z',
      command: 'kubectl delete pod foo',
      script_path: '/tmp/kube-cmd.dismiss.sh',
      tier: 'live_mutating',
      status: 'pending',
    }, null, 2));
    const { status, body } = await post('/api/kube-approve', { id: 'api-dismiss-kube', action: 'dismiss' });
    assert.equal(status, 200);
    assert.equal(body.status, 'dismissed');
    assert.ok(!fs.existsSync(path.join(pendingDir, 'api-dismiss-kube.json')));
    assert.ok(fs.existsSync(path.join(tmpDir, '.orchestrate', 'kube-reviews', 'processed', 'api-dismiss-kube.json')));
  });
});
