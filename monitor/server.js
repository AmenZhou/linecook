'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const url = require('url');
const { execSync } = require('child_process');
const os = require('os');

const PORT = Number(process.env.PORT) || 7842;
const CWD = process.cwd();
const DIR = __dirname;

// ── helpers ──────────────────────────────────────────────────────────────────

function readFileSafe(filePath) {
  try {
    return fs.readFileSync(filePath, 'utf8');
  } catch (_) {
    return null;
  }
}

function send(res, statusCode, data) {
  const body = JSON.stringify(data);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'no-cache',
  });
  res.end(body);
}

function sendFile(res, filePath) {
  const content = readFileSafe(filePath);
  if (content === null) {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not found');
    return;
  }
  const ext = path.extname(filePath).toLowerCase();
  const mime = ext === '.html' ? 'text/html' : 'text/plain';
  res.writeHead(200, { 'Content-Type': mime, 'Cache-Control': 'no-cache' });
  res.end(content);
}

// ── parsers ───────────────────────────────────────────────────────────────────

/**
 * Parse the ## Task Registry markdown table from project.md.
 * Returns an array of row objects: { id, summary, mode, current_phase, status, last_activity }
 */
function parseRegistry(projectMdContent) {
  const rows = [];
  // Find the Task Registry section and read it to END OF FILE — the registry is the
  // last section and newer rows are appended at the bottom.
  //
  // We intentionally do NOT slice "up to the next `## `/`# ` heading" (the old
  // `/## Task Registry\n([\s\S]*?)(?:\n## |\n# |$)/` regex): a stray heading inserted
  // after — or splitting — the table truncated the capture and silently dropped every
  // newer completion from the History tab (the "newest row is days old" bug). Instead
  // we scan all lines after the header and skip any non-table line (headings/prose
  // between fragments) instead of stopping at it. The registry is the file's last
  // section, so reading to EOF matches the common case and additionally survives a
  // heading that splits or trails the table.
  const headerIdx = projectMdContent.indexOf('## Task Registry');
  if (headerIdx === -1) return rows;
  const lines = projectMdContent.slice(headerIdx).split('\n');

  let headerParsed = false;
  let headers = [];

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('<!--') || trimmed.endsWith('-->')) continue;
    // Skip headings/prose between table fragments instead of stopping at them.
    if (!trimmed.startsWith('|')) continue;

    const cells = trimmed.split('|').map(c => c.trim()).filter((_, i, arr) => i > 0 && i < arr.length - 1);

    if (!headerParsed) {
      // First pipe row = header
      headers = cells.map(h => h.toLowerCase().replace(/\s+/g, '_'));
      headerParsed = true;
      continue;
    }

    // Separator row (---|---|...)
    if (cells.every(c => /^[-:]+$/.test(c))) continue;

    if (headers.length > 0 && cells.length >= headers.length) {
      const row = {};
      headers.forEach((h, i) => { row[h] = cells[i] || ''; });
      rows.push({
        id: row['id'] || '',
        summary: row['summary'] || '',
        mode: row['mode'] || '',
        current_phase: row['current_phase'] || '',
        status: row['status'] || '',
        last_activity: row['last_activity'] || '',
      });
    }
  }
  return rows;
}

/**
 * Build a registry data row that is guaranteed to satisfy the NF==8 invariant
 * (exactly 6 columns: ID | summary | mode | phase | status | last_activity).
 * Every cell is sanitized — embedded `|` (would split into a phantom column) and
 * newlines (would break the row) are replaced, and surrounding space is trimmed.
 * Throws if the result does not parse to exactly 6 cells, so a bad write fails
 * loudly instead of corrupting project.md. All monitor writes MUST route through
 * this helper.
 * @param {[string,string,string,string,string,string]} cells - the 6 column values
 * @returns {string} a single `| ... |` registry row line
 */
function formatRegistryRow(cells) {
  if (!Array.isArray(cells) || cells.length !== 6) {
    throw new Error(`formatRegistryRow: expected 6 cells, got ${Array.isArray(cells) ? cells.length : typeof cells}`);
  }
  const clean = cells.map(c =>
    String(c == null ? '' : c).replace(/\|/g, '/').replace(/[\r\n]+/g, ' ').trim()
  );
  const row = `| ${clean.join(' | ')} |`;
  // Self-verify the invariant the same way awk -F'|' does (NF==8).
  const nf = row.split('|').length;
  if (nf !== 8) {
    throw new Error(`formatRegistryRow: produced NF=${nf} (expected 8) for row: ${row}`);
  }
  return row;
}

/**
 * Continuous invariant guard: scan project.md content for registry data rows that
 * violate the canonical schema. A data row starts with `| <digit` (task IDs are
 * date-stamped) — header/separator rows are skipped.
 *
 * A VALID row splits on `|` into exactly 8 parts with an EMPTY trailing part,
 * i.e. `| ID | summary | mode | phase | status | last_activity |` (leading empty,
 * 6 cells, trailing empty). This matches `repair_registry_rows` in run-job.sh:
 * the historic corruption appends a phantom timestamp PAST the trailing pipe
 * (`... | last_activity | new_ts`) which still yields 8 `|`-parts but a NON-empty
 * trailing field — a bare length check misses it, so we also assert the trailing
 * part is empty (equivalent to awk's `$8 != ""`). NF>8 (extra `|`) and truncated
 * rows are caught by the length check.
 *
 * NF==8 is NECESSARY but NOT SUFFICIENT: a field-shift corruption (e.g. an
 * off-by-one awk update that overwrites the `mode` column with a phase number)
 * preserves the 8-column count and the empty trailing `$8`, so the structural
 * check passes while the row is semantically corrupt. We therefore ALSO assert a
 * value DOMAIN on the two enum columns: mode (parts[3], awk `$4`) ∈ {auto,gated}
 * and status (parts[5], awk `$6`) ∈ the known status set. A row that fails either
 * domain check is flagged even when NF==8 with an empty `$8`.
 * @param {string} projectMdContent
 * @returns {{ healthy: boolean, badRows: string[] }}
 */
const VALID_MODES = new Set(['auto', 'gated']);
const VALID_STATUSES = new Set(['pending', 'running', 'awaiting_go', 'awaiting_critic', 'complete', 'failed', 'needs_human']);
function checkRegistryInvariant(projectMdContent) {
  const badRows = [];
  if (typeof projectMdContent === 'string') {
    for (const line of projectMdContent.split('\n')) {
      if (!/^\|\s*[0-9]/.test(line)) continue;
      const parts = line.split('|');
      // Structural: NF==8 with empty trailing field.
      if (parts.length !== 8 || parts[parts.length - 1].trim() !== '') { badRows.push(line); continue; }
      // Domain: mode ($4 → parts[3]) and status ($6 → parts[5]) must be in range
      // (catches field-shift corruption that preserves NF==8).
      const mode = parts[3].trim();
      const status = parts[5].trim();
      if (!VALID_MODES.has(mode) || !VALID_STATUSES.has(status)) badRows.push(line);
    }
  }
  return { healthy: badRows.length === 0, badRows };
}

/** Statuses that require human action before work continues (when tend is notify-only). */
const APPROVAL_STATUSES = new Set(['awaiting_go', 'needs_human', 'failed', 'awaiting_critic']);

/**
 * Read TEND_MODE from .orchestrate/agent.conf (matches run-job.sh default).
 * @returns {string}
 */
function readTendMode(cwd) {
  return readAgentConf(cwd).tendMode;
}

/**
 * Parse a single key from agent.conf (bash-style KEY=value).
 * @param {string} content
 * @param {string} key
 * @param {string} defaultVal
 * @returns {string}
 */
function parseAgentConfValue(content, key, defaultVal) {
  const re = new RegExp(`^\\s*${key}\\s*=\\s*["']?([^"'\\n#]+)["']?\\s*(?:#.*)?$`, 'm');
  const m = (content || '').match(re);
  if (!m) return defaultVal;
  return m[1].trim().replace(/^["']|["']$/g, '');
}

/**
 * Whether Cursor IDE process is running (overridable via CURSOR_IDE_RUNNING for tests).
 * @returns {boolean}
 */
function isCursorIdeRunning() {
  const override = process.env.CURSOR_IDE_RUNNING;
  if (override !== undefined) {
    return override === '1' || override === 'true';
  }
  try {
    execSync('pgrep -xq Cursor', { stdio: 'ignore', timeout: 2000 });
    return true;
  } catch (_) {
    return false;
  }
}

/**
 * Read runner settings from .orchestrate/agent.conf (matches run-job.sh defaults).
 * @param {string} [cwd]
 * @returns {{ runner: string, tendMode: string, cursorFallback: string, cursorAutoOpen: boolean, cursorIdeRunning: boolean, confPath: string }}
 */
function readAgentConf(cwd) {
  const base = cwd || CWD;
  const confPath = path.join(base, '.orchestrate', 'agent.conf');
  const content = readFileSafe(confPath) || '';
  let tendMode = parseAgentConfValue(content, 'TEND_MODE', 'go auto');
  if (tendMode === 'go_auto') tendMode = 'go auto';
  const launchdWatchRaw = parseAgentConfValue(content, 'LAUNCHD_WATCH', '');
  const launchdWatch = launchdWatchRaw ? launchdWatchRaw.split(',').map(s => s.trim()).filter(Boolean) : [];
  return {
    runner: parseAgentConfValue(content, 'RUNNER', 'cursor'),
    tendMode,
    cursorFallback: parseAgentConfValue(content, 'CURSOR_FALLBACK', 'auto'),
    cursorAutoOpen: parseAgentConfValue(content, 'CURSOR_AUTO_OPEN', 'false') === 'true',
    cursorIdeRunning: isCursorIdeRunning(),
    launchdWatch,
    confPath,
  };
}

/**
 * Update or append a KEY=value line in agent.conf content.
 * @param {string} content
 * @param {string} key
 * @param {string} value
 * @returns {string}
 */
function updateAgentConfLine(content, key, value) {
  const quoted = /\s/.test(value) ? `"${value}"` : value;
  const line = `${key}=${quoted}`;
  const re = new RegExp(`^\\s*${key}\\s*=.*$`, 'm');
  if (re.test(content || '')) {
    return (content || '').replace(re, line);
  }
  const trimmed = (content || '').trimEnd();
  return trimmed ? `${trimmed}\n${line}\n` : `${line}\n`;
}

/**
 * Apply partial updates to agent.conf on disk.
 * @param {string} cwd
 * @param {{ runner?: string, tendMode?: string, cursorFallback?: string, cursorAutoOpen?: boolean }} updates
 */
function writeAgentConf(cwd, updates) {
  const base = cwd || CWD;
  const confPath = path.join(base, '.orchestrate', 'agent.conf');
  let content = readFileSafe(confPath) || '';
  if (!content) {
    const example = path.join(DIR, '..', 'bin', 'agent.conf.example');
    content = readFileSafe(example) || '';
  }
  if (updates.runner !== undefined) {
    content = updateAgentConfLine(content, 'RUNNER', updates.runner);
  }
  if (updates.tendMode !== undefined) {
    content = updateAgentConfLine(content, 'TEND_MODE', updates.tendMode);
  }
  if (updates.cursorFallback !== undefined) {
    content = updateAgentConfLine(content, 'CURSOR_FALLBACK', updates.cursorFallback);
  }
  if (updates.cursorAutoOpen !== undefined) {
    content = updateAgentConfLine(content, 'CURSOR_AUTO_OPEN', updates.cursorAutoOpen ? 'true' : 'false');
  }
  fs.writeFileSync(confPath, content);
  return readAgentConf(base);
}

function readRunner(cwd) {
  return readAgentConf(cwd).runner;
}

/**
 * Agent runner + IDE status for monitor header (/api/agent-status).
 */
function readAgentStatus(cwd) {
  const conf = readAgentConf(cwd);
  const cursorRequired = conf.runner === 'cursor';
  return {
    ...conf,
    cursorRequired,
    cursorOk: !cursorRequired || conf.cursorIdeRunning,
  };
}

function handleAgentStatus(res) {
  send(res, 200, readAgentStatus(CWD));
}

function isTendGoAuto(tendMode) {
  const mode = (tendMode || '').toLowerCase().trim();
  return mode === 'go auto' || mode === 'go_auto';
}

/**
 * Classify whether a registry row needs human approval / is blocked.
 *
 * A deliberately-cancelled task is recorded as registry status `failed` (the
 * enum has no `cancelled` value — see VALID_STATUSES) but carries a durable
 * `cancelled_at:` marker in its task file. The caller sets `row.cancelled=true`
 * for such rows so we can surface a distinct, terminal "Cancelled" label
 * instead of the actionable "Failed — review required". A cancelled row is
 * terminal + non-actionable (needsApproval=false), mirroring a bypassed row.
 * @param {{ status?: string, cancelled?: boolean }} row
 * @param {string} [tendMode] from readTendMode()
 * @returns {{ needsApproval: boolean, approvalReason: string|null, approvalLabel: string|null, cancelled?: boolean }}
 */
function taskApprovalInfo(row, tendMode) {
  const status = (row.status || '').toLowerCase().trim();
  if (status === 'failed' && row.cancelled) {
    // Deliberately cancelled (failed + cancelled_at: marker) — terminal, not a
    // genuine error. Surface a distinct label and do NOT flag for review.
    return {
      needsApproval: false,
      approvalReason: 'cancelled',
      approvalLabel: 'Cancelled',
      cancelled: true,
    };
  }
  if (status === 'awaiting_go') {
    // Gated tasks always need explicit human approval — tend go auto never auto-executes them.
    return {
      needsApproval: true,
      approvalReason: 'awaiting_go',
      approvalLabel: 'Needs your "go"',
    };
  }
  if (status === 'needs_human') {
    return {
      needsApproval: true,
      approvalReason: 'needs_human',
      approvalLabel: 'Blocked — needs human',
    };
  }
  if (status === 'failed') {
    return {
      needsApproval: true,
      approvalReason: 'failed',
      approvalLabel: 'Failed — review required',
    };
  }
  if (status === 'awaiting_critic') {
    return {
      needsApproval: true,
      approvalReason: 'awaiting_critic',
      approvalLabel: 'Awaiting critic review',
    };
  }
  return { needsApproval: false, approvalReason: null, approvalLabel: null };
}

/**
 * Parse inbox file front-matter annotations (e.g. mode: gated, deferred_at:).
 * @param {string} content
 * @param {string} [tendMode] from readTendMode()
 */
function parseInboxMeta(content, tendMode) {
  const text = content || '';
  if (/^deferred_at:/m.test(text)) {
    return {
      mode: 'deferred',
      needsApproval: true,
      approvalReason: 'inbox_deferred',
      approvalLabel: 'Deferred — approve via /task-orchestrate inbox',
    };
  }
  const gated = /^mode:\s*gated\s*$/m.test(text);
  const mode = gated ? 'gated' : 'auto';
  // Gated inbox items always need approval — tend go auto never auto-executes them.
  const approval = gated
    ? {
        needsApproval: true,
        approvalReason: 'inbox_gated',
        approvalLabel: 'Gated — approval required before run',
      }
    : { needsApproval: false, approvalReason: null, approvalLabel: null };
  return { mode, ...approval };
}

/**
 * Match a registry task ID to an orchestrate-history archive filename.
 * Handles both prefix style (20260617-inbox-1-...) and timestamped style
 * (20260619-130100-inbox-AD-...).
 */
function manifestMatchesRegistry(filename, regId) {
  if (!filename || !regId) return false;
  const base = filename.replace(/\.md$/i, '');
  if (base.startsWith(regId)) return true;

  const escapedId = regId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  if (new RegExp(`-${escapedId}(?:-|$)`).test(base)) return true;

  const idMatch = regId.match(/^(\d{8})-(.+)$/);
  if (!idMatch) return base.includes(regId);
  const [, datePart, idSuffix] = idMatch;
  if (!base.startsWith(datePart)) return false;
  const escaped = idSuffix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`^${datePart}(?:-\\d{6})?-${escaped}(?:-|$)`).test(base);
}

/**
 * Known duplicate registry IDs that map to the same archive as another ID.
 */
const HISTORY_REGISTRY_ALIASES = {
  '20260619-inbox-RMB': '20260619-inbox-5B',
};

function resolveRegistryIds(registryId) {
  const ids = [registryId];
  const alias = HISTORY_REGISTRY_ALIASES[registryId];
  if (alias && !ids.includes(alias)) ids.push(alias);
  return ids;
}

/**
 * True when filename is an on-disk archive (date-only prefix, not YYYYMMDD-HHMMSS).
 */
function isDateOnlyArchiveFilename(filename) {
  const name = filename || '';
  if (!/\.md$/i.test(name)) return false;
  if (/^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})/.test(name)) return false;
  return /^(\d{4})(\d{2})(\d{2})-/.test(name);
}

/**
 * True when last_activity looks like a rounded placeholder (noon UTC or date-only).
 */
function isPlaceholderTimestamp(iso) {
  if (!iso) return true;
  if (/^\d{4}-\d{2}-\d{2}$/.test(iso)) return true;
  return /T12:00:00Z$/.test(iso);
}

/**
 * True when iso is more than 5 minutes in the future.
 * Completion agents sometimes invent future timestamps; treat them as unreliable.
 */
function isFutureTimestamp(iso) {
  if (!iso) return false;
  try {
    return new Date(iso).getTime() > Date.now() + 5 * 60 * 1000;
  } catch (_) {
    return false;
  }
}

// Timezone the History "today" boundary is computed in. The dashboard runs in
// Eastern (see the dashboard-history-eastern-timezone change), so both the row
// day-bucket AND the "today" boundary MUST use this same zone — otherwise a
// task completed just before local midnight (whose UTC date has already rolled
// to "tomorrow") gets bucketed to a different day and filtered out of "today".
const HISTORY_TZ = 'America/New_York';

/**
 * Normalize a server-side ISO string to a real Date, treating a timezone-less
 * ISO datetime (e.g. "2026-06-30T03:30:00") as UTC — never as local time.
 * Mirrors the client parseIsoUtc so both sides agree on the instant.
 */
function isoToDate(iso) {
  if (!iso) return null;
  let s = String(iso).trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) s = `${s}T12:00:00Z`;
  else if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(s) && !/[Zz]|[+-]\d{2}:?\d{2}$/.test(s)) s = `${s}Z`;
  const d = new Date(s);
  return isNaN(d.getTime()) ? null : d;
}

/**
 * Eastern (HISTORY_TZ) calendar day for an ISO instant, as YYYY-MM-DD.
 * A task completed at 2026-06-30T03:30:00Z buckets to 2026-06-29 in Eastern.
 */
function historyEasternYmd(iso, tz = HISTORY_TZ) {
  const d = isoToDate(iso);
  if (!d) return '';
  return d.toLocaleDateString('en-CA', { timeZone: tz });
}

/**
 * Whether a row belongs in the default ("today") History view.
 *
 * Boundary-robust rule: a row is "in the default window" when its Eastern day
 * equals today's Eastern day OR its instant is within the last 24h. The 24h
 * grace means a task that just completed never disappears the instant local
 * midnight rolls over — it stays visible until it is genuinely a day old.
 */
function isInDefaultHistoryWindow(iso, nowMs = Date.now(), tz = HISTORY_TZ) {
  const d = isoToDate(iso);
  if (!d) return false;
  const todayYmd = new Date(nowMs).toLocaleDateString('en-CA', { timeZone: tz });
  if (d.toLocaleDateString('en-CA', { timeZone: tz }) === todayYmd) return true;
  const ageMs = nowMs - d.getTime();
  return ageMs >= 0 && ageMs <= 24 * 60 * 60 * 1000;
}

/**
 * Parse ISO timestamp from phase/tend log headers.
 */
function parseIsoFromLogContent(content) {
  if (!content) return '';
  const stamps = [];
  const headerRe = /=== .+? (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) ===/g;
  let m;
  while ((m = headerRe.exec(content)) !== null) stamps.push(m[1]);
  const tendRe = /=== Tend-driven execution — (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) ===/;
  const tend = content.match(tendRe);
  if (tend) stamps.push(tend[1]);
  return stamps.length ? stamps[stamps.length - 1] : '';
}

/**
 * Build taskId → best completion ISO from heartbeat + per-task logs.
 */
function buildCompletionHints(logsDir, heartbeatContent) {
  const hints = {};
  if (heartbeatContent) {
    for (const line of heartbeatContent.split('\n')) {
      const m = line.match(
        /^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\].*\(([^)]+)\)/,
      );
      if (!m) continue;
      const [, iso, taskId] = m;
      if (/tend-auto — (completed|executing)/.test(line) || /inbox — registered/.test(line)) {
        hints[taskId] = iso;
      }
    }
  }
  if (logsDir) {
    let dirEntries = [];
    try {
      dirEntries = fs.readdirSync(logsDir);
    } catch (_) {
      return hints;
    }
    for (const f of dirEntries) {
      if (!f.endsWith('.log')) continue;
      const taskId = f.replace(/-(?:tend|phase\d+|verify)\.log$/, '').replace(/-phase\d+\.log$/, '');
      if (!/^\d{8}/.test(taskId)) continue;
      const iso = parseIsoFromLogContent(readFileSafe(path.join(logsDir, f)));
      if (iso) hints[taskId] = iso;
    }
  }
  return hints;
}

/**
 * Best ISO datetime for a history row.
 * Registry last_activity is when the task finished; archive filename ts is often batch-write time.
 * Precedence: real last_activity > completion hint > placeholder last_activity date >
 * archive filename HHMMSS (same day only) > filename HHMMSS > MANIFEST date noon.
 */
function resolveHistoryDatetime(filename, dateStr, lastActivity, completionHint) {
  const hint =
    completionHint && !isPlaceholderTimestamp(completionHint) && !isFutureTimestamp(completionHint)
      ? completionHint
      : '';

  if (
    lastActivity &&
    !isPlaceholderTimestamp(lastActivity) &&
    !isFutureTimestamp(lastActivity) &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(lastActivity)
  ) {
    return lastActivity.endsWith('Z') ? lastActivity : `${lastActivity}Z`;
  }

  if (hint) return hint;

  const ts = (filename || '').match(/^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})/);
  const filenameIso = ts
    ? `${ts[1]}-${ts[2]}-${ts[3]}T${ts[4]}:${ts[5]}:${ts[6]}Z`
    : '';

  if (lastActivity && isPlaceholderTimestamp(lastActivity) && /^\d{4}-\d{2}-\d{2}T/.test(lastActivity)) {
    const lastDay = lastActivity.slice(0, 10);
    if (filenameIso && !isFutureTimestamp(filenameIso) && filenameIso.slice(0, 10) === lastDay) {
      return filenameIso;
    }
    return lastActivity.endsWith('Z') ? lastActivity : `${lastActivity}Z`;
  }

  if (filenameIso) {
    if (!isFutureTimestamp(filenameIso)) return filenameIso;
    return '';
  }

  if (isDateOnlyArchiveFilename(filename)) {
    const day = filename.match(/^(\d{4})(\d{2})(\d{2})-/);
    if (day) return `${day[1]}-${day[2]}-${day[3]}T12:00:00Z`;
  }
  if (dateStr && /^\d{4}-\d{2}-\d{2}$/.test(dateStr)) return `${dateStr}T12:00:00Z`;
  return dateStr || '';
}

/**
 * Extract YYYY-MM-DD from archive filename prefix (YYYYMMDD or YYYYMMDD-HHMMSS).
 */
function archiveDateFromFilename(filename) {
  if (!filename) return '';
  const m = filename.match(/^(\d{4})(\d{2})(\d{2})/);
  if (!m) return '';
  return `${m[1]}-${m[2]}-${m[3]}`;
}

/**
 * Find the best manifest or on-disk archive entry for a registry task ID.
 */
function findHistoryEntry(registryId, manifest, entryFilenames) {
  for (const id of resolveRegistryIds(registryId)) {
    const manifestMatch = (manifest || []).find(e => manifestMatchesRegistry(e.filename, id));
    if (manifestMatch) return manifestMatch;

    const filenames = entryFilenames || [];
    const diskFilename = filenames.find(f => manifestMatchesRegistry(f, id));
    if (diskFilename) {
      return {
        date: archiveDateFromFilename(diskFilename),
        filename: diskFilename,
        summary: '',
        tags: '',
      };
    }
  }
  return null;
}

/**
 * Load archive file contents keyed by filename. MANIFEST entries first, then any
 * other .md files in orchestrate-history/ so History works when MANIFEST lags.
 */
function loadHistoryEntries(historyDir, manifest) {
  const entries = {};
  const seen = new Set();

  for (const entry of (manifest || [])) {
    if (!entry.filename || seen.has(entry.filename)) continue;
    const filePath = path.join(historyDir, entry.filename);
    const fileContent = readFileSafe(filePath);
    if (fileContent !== null) {
      entries[entry.filename] = fileContent;
      seen.add(entry.filename);
    }
  }

  let dirEntries = [];
  try {
    dirEntries = fs.readdirSync(historyDir);
  } catch (_) {
    return entries;
  }

  for (const filename of dirEntries) {
    if (!filename.endsWith('.md') || filename === 'MANIFEST.md' || seen.has(filename)) continue;
    const fileContent = readFileSafe(path.join(historyDir, filename));
    if (fileContent !== null) {
      entries[filename] = fileContent;
      seen.add(filename);
    }
  }

  return entries;
}

/**
 * Extract inbox task ID from an archive filename when present.
 */
function extractTaskIdFromFilename(filename) {
  if (!filename) return '';
  const base = filename.replace(/\.md$/i, '');
  const inbox = base.match(/\d{8}-inbox-[A-Za-z0-9]+/);
  if (inbox) return inbox[0];
  const stamped = base.match(/^\d{8}-\d{6}-(\d{8}-inbox-[A-Za-z0-9]+)/);
  if (stamped) return stamped[1];
  if (/^\d{8}-inbox-/.test(base)) return base.split('-').slice(0, 3).join('-');
  return '';
}

/**
 * Collect tend/phase/verify logs for a registry task ID (best-effort).
 */
function collectTaskLogContent(logsDir, taskId) {
  if (!taskId || !logsDir) return '';
  let dirEntries = [];
  try {
    dirEntries = fs.readdirSync(logsDir);
  } catch (_) {
    return '';
  }

  const prefixes = [taskId];
  const tsMatch = taskId.match(/^(\d{8}-\d{6})/);
  if (tsMatch && !prefixes.includes(tsMatch[1])) prefixes.push(tsMatch[1]);

  const matches = dirEntries
    .filter(f => f.endsWith('.log') && prefixes.some(p => f.startsWith(p)))
    .sort();

  const parts = [];
  for (const f of matches) {
    const content = readFileSafe(path.join(logsDir, f));
    if (content) parts.push(`--- ${f} ---\n${content.trim()}`);
  }
  return parts.join('\n\n');
}

/**
 * Build expandable History content when no orchestrate-history archive exists.
 */
function synthesizeHistoryStub(reg, logsDir) {
  const logContent = collectTaskLogContent(logsDir, reg.id);
  const header = `# ${reg.summary}\n\ntask_id: ${reg.id}\nstatus: ${reg.status}\nlast_activity: ${reg.last_activity || ''}\n`;
  if (logContent) {
    return `${header}\n## Execution logs (synthesized — no archive file on disk)\n\n${logContent}`;
  }
  return `${header}\n> No orchestrate-history archive was written for this job. Registry marks it complete.`;
}

/**
 * Complete registry IDs with no matching history row (aliases excluded).
 */
function historyCoverage(registry, rows) {
  const list = rows || [];
  const rowTaskIds = new Set(list.map(r => r.taskId).filter(Boolean));
  const missing = [];
  for (const reg of (registry || [])) {
    if (reg.status !== 'complete') continue;
    if (HISTORY_REGISTRY_ALIASES[reg.id]) continue;
    if (rowTaskIds.has(reg.id)) continue;
    if (list.some(r => manifestMatchesRegistry(r.filename, reg.id))) continue;
    missing.push(reg.id);
  }
  return missing;
}

/**
 * Merge complete registry rows with MANIFEST entries and archive file content.
 * Canonical registry IDs are processed before alias IDs so shared archives link
 * to the primary task row, not a duplicate alias row.
 */
function buildHistoryRows(registry, manifest, entries, logsDir, completionHints) {
  const hints = completionHints || {};
  const rows = [];
  const seenFiles = new Set();
  const seenTaskIds = new Set();
  const entryFilenames = Object.keys(entries || {});

  const sortedRegistry = [...(registry || [])].sort((a, b) => {
    const aAlias = HISTORY_REGISTRY_ALIASES[a.id] ? 1 : 0;
    const bAlias = HISTORY_REGISTRY_ALIASES[b.id] ? 1 : 0;
    return aAlias - bAlias;
  });

  for (const reg of sortedRegistry) {
    if (reg.status !== 'complete' && !reg.cancelled) continue;
    const matchEntry = findHistoryEntry(reg.id, manifest, entryFilenames);
    if (matchEntry) {
      if (seenFiles.has(matchEntry.filename)) {
        if (HISTORY_REGISTRY_ALIASES[reg.id]) continue;
        const existing = rows.find(r => r.filename === matchEntry.filename);
        if (existing && existing.taskId !== reg.id
            && HISTORY_REGISTRY_ALIASES[existing.taskId]) {
          existing.taskId = reg.id;
          seenTaskIds.add(reg.id);
          existing.summary = reg.summary || existing.summary;
          existing.dateIso = resolveHistoryDatetime(
            matchEntry.filename, matchEntry.date, reg.last_activity, hints[reg.id],
          );
          existing.date = reg.last_activity || existing.date;
        }
        continue;
      }
      seenFiles.add(matchEntry.filename);
      seenTaskIds.add(reg.id);
      const archiveContent = entries[matchEntry.filename] || '';
      rows.push({
        date: matchEntry.date || reg.last_activity || '',
        dateIso: resolveHistoryDatetime(
          matchEntry.filename, matchEntry.date, reg.last_activity, hints[reg.id],
        ),
        filename: matchEntry.filename,
        summary: matchEntry.summary || reg.summary,
        tags: matchEntry.tags,
        taskId: reg.id,
        status: reg.cancelled ? 'Cancelled' : reg.status,
        hasArchive: !!archiveContent.trim(),
        content: archiveContent,
      });
    } else if (!HISTORY_REGISTRY_ALIASES[reg.id]) {
      seenTaskIds.add(reg.id);
      const stubContent = synthesizeHistoryStub(reg, logsDir);
      rows.push({
        date: reg.last_activity || '',
        dateIso: resolveHistoryDatetime(reg.id, '', reg.last_activity, hints[reg.id]),
        filename: reg.id,
        summary: reg.summary,
        tags: '',
        taskId: reg.id,
        status: reg.cancelled ? 'Cancelled' : reg.status,
        hasArchive: false,
        content: stubContent,
      });
    }
  }

  for (const e of (manifest || [])) {
    if (seenFiles.has(e.filename)) continue;
    const taskId = extractTaskIdFromFilename(e.filename);
    if (taskId && seenTaskIds.has(taskId)) continue;
    seenFiles.add(e.filename);
    if (taskId) seenTaskIds.add(taskId);
    const archiveContent = entries[e.filename] || '';
    const regMatch = (registry || []).find(r => r.id === taskId || manifestMatchesRegistry(e.filename, r.id));
    const lastActivity = regMatch?.last_activity || '';
    const hintId = regMatch?.id || taskId;
    rows.push({
      date: e.date,
      dateIso: resolveHistoryDatetime(e.filename, e.date, lastActivity, hints[hintId]),
      filename: e.filename,
      summary: e.summary,
      tags: e.tags,
      taskId,
      status: 'complete',
      hasArchive: !!archiveContent.trim(),
      content: archiveContent,
    });
  }

  for (const filename of entryFilenames) {
    if (seenFiles.has(filename)) continue;
    const taskId = extractTaskIdFromFilename(filename);
    if (taskId && seenTaskIds.has(taskId)) continue;
    seenFiles.add(filename);
    if (taskId) seenTaskIds.add(taskId);
    const archiveContent = entries[filename] || '';
    const regMatch = (registry || []).find(r => r.id === taskId || manifestMatchesRegistry(filename, r.id));
    const lastActivity = regMatch?.last_activity || '';
    const hintId = regMatch?.id || taskId;
    rows.push({
      date: archiveDateFromFilename(filename),
      dateIso: resolveHistoryDatetime(
        filename, archiveDateFromFilename(filename), lastActivity, hints[hintId],
      ),
      filename,
      summary: filename.replace(/\.md$/i, ''),
      tags: '',
      taskId,
      status: 'complete',
      hasArchive: !!archiveContent.trim(),
      content: archiveContent,
    });
  }

  return rows;
}

function historyStats(rows, registry) {
  const list = rows || [];
  const withArchive = list.filter(r => r.hasArchive).length;
  return {
    total: list.length,
    withArchive,
    registryOnly: list.length - withArchive,
    missingCompleteIds: historyCoverage(registry || [], list),
  };
}

/**
 * Parse MANIFEST.md lines of form: YYYY-MM-DD | filename | summary | tag1, tag2
 */
function parseManifest(content) {
  const entries = [];
  const lineRe = /^(\d{4}-\d{2}-\d{2})\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*(.+)$/;
  for (const line of content.split('\n')) {
    const m = line.match(lineRe);
    if (m) {
      entries.push({
        date: m[1].trim(),
        filename: m[2].trim(),
        summary: m[3].trim(),
        tags: m[4].trim(),
      });
    }
  }
  return entries;
}

// ── gated task helpers ────────────────────────────────────────────────────────

/**
 * Find the processed inbox file content for a gated task.
 * Parses heartbeat.log for the registration line, then reads inbox/processed/.
 * @param {string} logsDir
 * @param {string} inboxDir
 * @param {string} summary — task summary as it appears in heartbeat log
 * @returns {{ content: string, filename: string } | null}
 */
function findInboxSourceForTask(logsDir, inboxDir, summary) {
  if (!summary) return null;
  const heartbeatContent = readFileSafe(path.join(logsDir, 'heartbeat.log')) || '';
  const esc = summary.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  // Match both gated and non-gated registrations
  const re = new RegExp(`\\] inbox — registered (?:\\(gated\\) )?"${esc}" from (?:gated/)?(.+\\.md)`, 'i');
  const lines = heartbeatContent.split('\n').reverse();
  for (const line of lines) {
    const m = line.match(re);
    if (!m) continue;
    const basename = path.basename(m[1]);
    // Try processed/ first (typical after drain), then gated/ and root
    for (const subdir of ['processed', 'gated', '']) {
      const candidate = subdir ? path.join(inboxDir, subdir, basename) : path.join(inboxDir, basename);
      const content = readFileSafe(candidate);
      if (content) return { content, filename: basename };
    }
  }
  return null;
}

/**
 * Extract a short excerpt from the ## Goal section of an inbox file.
 * @param {string|null} inboxContent
 * @returns {string|null}
 */
function getGoalExcerpt(inboxContent) {
  if (!inboxContent) return null;
  const m = inboxContent.match(/^## Goal\s*\n([\s\S]*?)(?=\n## |\n# |$)/m);
  if (!m) return null;
  return m[1].trim().slice(0, 280).replace(/\s+/g, ' ');
}

/**
 * Extract why a needs_human task is blocked.
 * Checks for explicit BLOCKED pattern, then returns first incomplete phase name.
 * @param {string|null} taskContent
 * @returns {string|null}
 */
function getBlockingReason(taskContent) {
  if (!taskContent) return null;
  const blockedMatch = taskContent.match(/BLOCKED until (\S+)/i);
  if (blockedMatch) return `Waiting for ${blockedMatch[1]} to complete`;
  // First phase without ✓ complete
  const allPhases = [...taskContent.matchAll(/### Phase \d+: ([^\n]+)\n([\s\S]*?)(?=### Phase \d+:|## OPERATING|$)/g)];
  for (const pm of allPhases) {
    if (!pm[2].includes('status: ✓ complete')) {
      const name = pm[1].replace(/\s*\[.*$/, '').trim();
      return `Blocked at: ${name}`;
    }
  }
  return null;
}

/**
 * Detect the durable cancellation marker on a task file.
 * A dashboard "Cancel" stamps `cancelled_at:` (+ `cancel_reason:`) into the task
 * file while leaving the registry status at `failed` (the enum has no `cancelled`
 * value). This lets the monitor classify a `failed`+`cancelled_at:` row as
 * "Cancelled" — distinct from a genuine error.
 * @param {string|null} taskContent
 * @returns {boolean}
 */
function isCancelledTask(taskContent) {
  if (!taskContent) return false;
  return /^cancelled_at:/m.test(taskContent);
}

/**
 * Map a raw parseRegistry() array to one carrying a `.cancelled` flag per row,
 * the same way handleTasks() already does inline. Factored out so handleHistory()
 * (MON-1) can reuse the identical `failed` + `cancelled_at:` detection without
 * duplicating the read-and-check logic inline — and so it is unit-testable on
 * its own, the same way isCancelledTask()/taskApprovalInfo() are.
 * @param {Array<object>} registry raw rows from parseRegistry()
 * @param {string} tasksDir absolute path to .orchestrate/tasks
 * @returns {Array<object>} rows with an added `cancelled` boolean
 */
function computeRegistryCancelledFlags(registry, tasksDir) {
  return (registry || []).map(row => {
    const taskContent = row.status === 'failed'
      ? readFileSafe(path.join(tasksDir, `${row.id}.md`))
      : null;
    return { ...row, cancelled: row.status === 'failed' && isCancelledTask(taskContent) };
  });
}

/**
 * Try to find an inbox file matching by summary, with fuzzy fallback on prefix.
 * Extends findInboxSourceForTask with partial-match when title diverged after registration.
 * @param {string} logsDir
 * @param {string} inboxDir
 * @param {string} summary
 * @returns {{ content: string, filename: string } | null}
 */
function findInboxSource(logsDir, inboxDir, summary) {
  const exact = findInboxSourceForTask(logsDir, inboxDir, summary);
  if (exact) return exact;
  // Fuzzy: try summary truncated at first '(' or ':' (handles diverged titles)
  const prefix = summary.split(/[:(]/)[0].trim();
  if (prefix && prefix !== summary) {
    return findInboxSourceForTask(logsDir, inboxDir, prefix);
  }
  return null;
}

/**
 * Stamp a durable cancellation marker onto a task file so a dashboard cancel is
 * recoverable (the registry only records `failed`). Mirrors the bypass-marker
 * pattern in churn-guard.sh: prepend `cancelled_at:` + `cancel_reason:` to the
 * file header, creating a minimal file if the task has none (e.g. a gated task
 * cancelled before it ever ran). Idempotent — strips any prior markers first.
 * @param {string} cwd
 * @param {string} taskId
 * @param {string} now ISO timestamp
 * @param {string} reason one-line cancel reason
 */
function stampCancelMarker(cwd, taskId, now, reason) {
  const taskPath = path.join(cwd, '.orchestrate', 'tasks', `${taskId}.md`);
  const safeReason = (reason || 'cancelled from dashboard').replace(/[\r\n]+/g, ' ').trim();
  let body = readFileSafe(taskPath);
  const header = `cancelled_at: ${now}\ncancel_reason: ${safeReason}`;
  let next;
  if (body === null) {
    // No task file yet — create a minimal one carrying the marker.
    next = `id: ${taskId}\nstatus: failed\n${header}\n`;
  } else {
    // Strip any prior cancel markers, then prepend the fresh ones.
    const cleaned = body.split('\n').filter(l => !/^(cancelled_at|cancel_reason):/.test(l)).join('\n');
    next = `${header}\n${cleaned}`;
  }
  try {
    fs.mkdirSync(path.dirname(taskPath), { recursive: true });
    fs.writeFileSync(taskPath, next);
  } catch (_) { /* best-effort; registry status is the source of truth */ }
}

/**
 * Approve or cancel a gated (awaiting_go) registry task.
 * - mode 'auto': status → pending, mode → auto (tend go auto will execute it)
 * - mode 'cancel': status → failed AND stamp a durable `cancelled_at:` marker on
 *   the task file so the cancel is distinguishable from a genuine failure and is
 *   recoverable. The registry enum stays unchanged (no `cancelled` value).
 * @param {string} cwd
 * @param {string} taskId
 * @param {'auto'|'cancel'} goMode
 * @param {string} [reason] one-line cancel reason (cancel mode only)
 * @returns {{ success: boolean, id: string, status: string } | { error: string }}
 */
function approveRegistryTask(cwd, taskId, goMode, reason) {
  const projectMdPath = path.join(cwd, '.orchestrate', 'project.md');
  let content = readFileSafe(projectMdPath);
  if (!content) return { error: 'project.md not found' };

  const now = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
  let foundRow = null;

  const newLines = content.split('\n').map(line => {
    const trimmed = line.trim();
    if (!trimmed.startsWith('|')) return line;
    const rawCells = trimmed.split('|');
    const cells = rawCells.slice(1, rawCells.length - 1).map(c => c.trim());
    if (cells.length < 6) return line;
    if (cells[0] !== taskId) return line;
    if (cells[4] !== 'awaiting_go') return line;
    foundRow = { id: cells[0], summary: cells[1], originalMode: cells[2] };
    const newMode = goMode === 'cancel' ? cells[2] : goMode === 'gated' ? 'gated' : 'auto';
    const newStatus = goMode === 'cancel' ? 'failed' : 'pending';
    return formatRegistryRow([cells[0], cells[1], newMode, cells[3], newStatus, now]);
  });

  if (!foundRow) return { error: `task ${taskId} not found or not in awaiting_go state` };

  fs.writeFileSync(projectMdPath, newLines.join('\n'));

  // On cancel, stamp a durable marker so the intent is recoverable and the row
  // classifies as "Cancelled" (distinct from a genuine "failed") in the monitor.
  if (goMode === 'cancel') {
    stampCancelMarker(cwd, taskId, now, reason);
  }

  const verb = goMode === 'cancel' ? 'cancelled' : goMode === 'gated' ? 'approved go (gated)' : 'approved go auto';
  try {
    const hbPath = path.join(cwd, '.orchestrate', 'logs', 'heartbeat.log');
    fs.appendFileSync(hbPath, `[${now}] dashboard — ${verb} gated task ${taskId} "${foundRow.summary}"\n`);
  } catch (_) {}

  return {
    success: true,
    id: taskId,
    status: goMode === 'cancel' ? 'failed' : 'pending',
    mode: goMode === 'cancel' ? foundRow.originalMode : goMode,
    ...(goMode === 'cancel' ? { cancelled: true } : {}),
  };
}

/**
 * Reset a needs_human/failed/awaiting_go task back to pending so tend will re-run it.
 * @param {string} cwd
 * @param {string} taskId
 * @returns {{ success: boolean, id: string, status: string } | { error: string }}
 */
function rerunTask(cwd, taskId) {
  const projectMdPath = path.join(cwd, '.orchestrate', 'project.md');
  let content = readFileSafe(projectMdPath);
  if (!content) return { error: 'project.md not found' };
  const now = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
  let found = null;
  const newLines = content.split('\n').map(line => {
    const trimmed = line.trim();
    if (!trimmed.startsWith('|')) return line;
    const rawCells = trimmed.split('|');
    const cells = rawCells.slice(1, rawCells.length - 1).map(c => c.trim());
    if (cells.length < 6 || cells[0] !== taskId) return line;
    if (!['needs_human', 'failed', 'awaiting_go'].includes(cells[4])) return line;
    found = { id: cells[0], summary: cells[1], prevStatus: cells[4] };
    return formatRegistryRow([cells[0], cells[1], 'auto', cells[3], 'pending', now]);
  });
  if (!found) return { error: `task ${taskId} not eligible for rerun (must be needs_human/failed/awaiting_go)` };
  fs.writeFileSync(projectMdPath, newLines.join('\n'));
  try {
    const hbPath = path.join(cwd, '.orchestrate', 'logs', 'heartbeat.log');
    fs.appendFileSync(hbPath, `[${now}] dashboard — rerun queued ${taskId} "${found.summary}" (was ${found.prevStatus})\n`);
  } catch (_) {}
  return { success: true, id: taskId, status: 'pending' };
}

// ── pg review helpers ─────────────────────────────────────────────────────────

const PG_REVIEW_MAX_AGE_MS = 24 * 60 * 60 * 1000; // 24 hours

function cleanupStalePgReviews(cwd) {
  const dirs = pgReviewsPaths(cwd);
  const now = Date.now();
  for (const dir of [dirs.pending, dirs.processed, dirs.approved]) {
    let files;
    try { files = fs.readdirSync(dir); } catch (_) { continue; }
    for (const name of files) {
      const filePath = path.join(dir, name);
      try {
        const stat = fs.statSync(filePath);
        if (now - stat.mtimeMs > PG_REVIEW_MAX_AGE_MS) {
          fs.unlinkSync(filePath);
        }
      } catch (_) { /* ignore */ }
    }
  }
}

function pgReviewsPaths(cwd) {
  const base = path.join(cwd, '.orchestrate', 'pg-reviews');
  return {
    base,
    pending: path.join(base, 'pending'),
    processed: path.join(base, 'processed'),
    approved: path.join(base, 'approved'),
  };
}

function readPgReviewJson(filePath) {
  try {
    const raw = fs.readFileSync(filePath, 'utf8');
    return JSON.parse(raw);
  } catch (_) {
    return null;
  }
}

function listPgReviews(cwd) {
  cleanupStalePgReviews(cwd);
  const dirs = pgReviewsPaths(cwd);
  const pending = [];
  const processed = [];

  for (const bucket of ['pending', 'processed']) {
    const dir = dirs[bucket];
    let entries;
    try {
      entries = fs.readdirSync(dir);
    } catch (_) {
      continue;
    }
    for (const name of entries) {
      if (!name.endsWith('.json')) continue;
      const review = readPgReviewJson(path.join(dir, name));
      if (!review) continue;
      if (bucket === 'pending') pending.push(review);
      else processed.push(review);
    }
  }

  pending.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
  processed.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));

  return {
    pending,
    processed: processed.slice(0, 20),
    pendingCount: pending.length,
  };
}

/**
 * Approve or dismiss a pending pg review. Never executes SQL directly.
 * @param {string} cwd
 * @param {string} id
 * @param {'approve'|'dismiss'} action
 */
function approvePgReview(cwd, id, action) {
  const dirs = pgReviewsPaths(cwd);
  const pendingPath = path.join(dirs.pending, `${id}.json`);
  const review = readPgReviewJson(pendingPath);
  if (!review) return { error: `review ${id} not found in pending` };

  const now = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
  review.status = action === 'approve' ? 'approved' : 'dismissed';
  review.resolved_at = now;

  fs.mkdirSync(dirs.processed, { recursive: true });
  fs.mkdirSync(dirs.approved, { recursive: true });

  fs.writeFileSync(path.join(dirs.processed, `${id}.json`), JSON.stringify(review, null, 2));
  fs.unlinkSync(pendingPath);

  if (action === 'approve') {
    fs.writeFileSync(
      path.join(dirs.approved, `${id}.token`),
      `${review.script_path}\n${now}\n`,
    );
  }

  try {
    const hbPath = path.join(cwd, '.orchestrate', 'logs', 'heartbeat.log');
    fs.appendFileSync(hbPath, `[${now}] dashboard — pg review ${action}d ${id}\n`);
  } catch (_) {}

  return { success: true, id, status: review.status };
}

function handlePgReviews(res) {
  const data = listPgReviews(CWD);
  send(res, 200, {
    ...data,
    attention: { pendingCount: data.pendingCount },
  });
}

async function handlePgApprove(req, res) {
  let payload;
  try {
    payload = await readJsonBody(req);
  } catch (_) {
    send(res, 400, { error: 'invalid JSON body' });
    return;
  }
  const id = (payload.id || '').trim();
  const action = payload.action === 'dismiss' ? 'dismiss' : 'approve';
  if (!id) {
    send(res, 400, { error: 'id required' });
    return;
  }
  try {
    const result = approvePgReview(CWD, id, action);
    send(res, result.error ? 404 : 200, result);
  } catch (e) {
    send(res, 500, { error: e.message || 'internal error' });
  }
}

// ── kube review helpers ───────────────────────────────────────────────────────

const KUBE_REVIEW_MAX_AGE_MS = 24 * 60 * 60 * 1000; // 24 hours

function cleanupStaleKubeReviews(cwd) {
  const dirs = kubeReviewsPaths(cwd);
  const now = Date.now();
  for (const dir of [dirs.pending, dirs.processed, dirs.approved]) {
    let files;
    try { files = fs.readdirSync(dir); } catch (_) { continue; }
    for (const name of files) {
      const filePath = path.join(dir, name);
      try {
        const stat = fs.statSync(filePath);
        if (now - stat.mtimeMs > KUBE_REVIEW_MAX_AGE_MS) {
          fs.unlinkSync(filePath);
        }
      } catch (_) { /* ignore */ }
    }
  }
}

function kubeReviewsPaths(cwd) {
  const base = path.join(cwd, '.orchestrate', 'kube-reviews');
  return {
    base,
    pending: path.join(base, 'pending'),
    processed: path.join(base, 'processed'),
    approved: path.join(base, 'approved'),
  };
}

function readKubeReviewJson(filePath) {
  try {
    const raw = fs.readFileSync(filePath, 'utf8');
    return JSON.parse(raw);
  } catch (_) {
    return null;
  }
}

function listKubeReviews(cwd) {
  cleanupStaleKubeReviews(cwd);
  const dirs = kubeReviewsPaths(cwd);
  const pending = [];
  const processed = [];

  for (const bucket of ['pending', 'processed']) {
    const dir = dirs[bucket];
    let entries;
    try {
      entries = fs.readdirSync(dir);
    } catch (_) {
      continue;
    }
    for (const name of entries) {
      if (!name.endsWith('.json')) continue;
      const review = readKubeReviewJson(path.join(dir, name));
      if (!review) continue;
      if (bucket === 'pending') pending.push(review);
      else processed.push(review);
    }
  }

  pending.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
  processed.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));

  return {
    pending,
    processed: processed.slice(0, 20),
    pendingCount: pending.length,
  };
}

/**
 * Approve or dismiss a pending kube review. Never executes cluster commands.
 * @param {string} cwd
 * @param {string} id
 * @param {'approve'|'dismiss'} action
 */
function approveKubeReview(cwd, id, action) {
  const dirs = kubeReviewsPaths(cwd);
  const pendingPath = path.join(dirs.pending, `${id}.json`);
  const review = readKubeReviewJson(pendingPath);
  if (!review) return { error: `review ${id} not found in pending` };

  const now = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
  review.status = action === 'approve' ? 'approved' : 'dismissed';
  review.resolved_at = now;

  fs.mkdirSync(dirs.processed, { recursive: true });
  fs.mkdirSync(dirs.approved, { recursive: true });

  fs.writeFileSync(path.join(dirs.processed, `${id}.json`), JSON.stringify(review, null, 2));
  fs.unlinkSync(pendingPath);

  if (action === 'approve') {
    fs.writeFileSync(
      path.join(dirs.approved, `${id}.token`),
      `${review.script_path}\n${now}\n`,
    );
  }

  try {
    const hbPath = path.join(cwd, '.orchestrate', 'logs', 'heartbeat.log');
    fs.appendFileSync(hbPath, `[${now}] dashboard — kube review ${action}d ${id}\n`);
  } catch (_) {}

  return { success: true, id, status: review.status };
}

function handleKubeReviews(res) {
  const data = listKubeReviews(CWD);
  send(res, 200, {
    ...data,
    attention: { pendingCount: data.pendingCount },
  });
}

async function handleKubeApprove(req, res) {
  let payload;
  try {
    payload = await readJsonBody(req);
  } catch (_) {
    send(res, 400, { error: 'invalid JSON body' });
    return;
  }
  const id = (payload.id || '').trim();
  const action = payload.action === 'dismiss' ? 'dismiss' : 'approve';
  if (!id) {
    send(res, 400, { error: 'id required' });
    return;
  }
  try {
    const result = approveKubeReview(CWD, id, action);
    send(res, result.error ? 404 : 200, result);
  } catch (e) {
    send(res, 500, { error: e.message || 'internal error' });
  }
}

// ── route handlers ────────────────────────────────────────────────────────────

function handleTasks(res) {
  const projectMdPath = path.join(CWD, '.orchestrate', 'project.md');
  const content = readFileSafe(projectMdPath);

  const tendMode = readTendMode(CWD);

  if (!content) {
    return send(res, 200, {
      tendMode,
      registry: [],
      tasks: {},
      attention: { taskCount: 0, tasks: [] },
    });
  }

  const logsDir = path.join(CWD, '.orchestrate', 'logs');
  const inboxDir = path.join(CWD, '.orchestrate', 'inbox');
  // Pre-load task files so we can compute blockingReason alongside goalExcerpt
  const taskFileCache = {};
  for (const row of parseRegistry(content)) {
    if (!row.id || row.status === 'complete') continue;
    const taskPath = path.join(CWD, '.orchestrate', 'tasks', `${row.id}.md`);
    const tc = readFileSafe(taskPath);
    if (tc !== null) taskFileCache[row.id] = tc;
  }

  const SHOW_GOAL_STATUSES = new Set(['awaiting_go', 'needs_human', 'pending', 'running']);
  const registry = parseRegistry(content).map(row => {
    // A `failed` row carrying a `cancelled_at:` marker is a deliberate cancel,
    // not an error — flag it so taskApprovalInfo surfaces a distinct "Cancelled".
    const cancelled = row.status === 'failed' && isCancelledTask(taskFileCache[row.id] || null);
    const base = { ...row, cancelled, ...taskApprovalInfo({ ...row, cancelled }, tendMode) };
    if (SHOW_GOAL_STATUSES.has(row.status)) {
      const found = findInboxSource(logsDir, inboxDir, row.summary);
      base.goalExcerpt = getGoalExcerpt(found ? found.content : null);
    } else {
      base.goalExcerpt = null;
    }
    base.blockingReason = row.status === 'needs_human'
      ? getBlockingReason(taskFileCache[row.id] || null)
      : null;
    return base;
  });
  const tasks = {};

  for (const id of Object.keys(taskFileCache)) {
    tasks[id] = taskFileCache[id];
  }

  const approvalTasks = registry.filter(r => r.needsApproval && r.status !== 'complete');
  const { tendHealth } = readTendHealthInputs(CWD);
  const tendIssues = tendHealth && !tendHealth.ok ? [tendHealth] : [];
  // Continuous invariant guard — surface registry corruption (NF!=8 OR non-empty
  // trailing $8 rows; see checkRegistryInvariant) to the dashboard so a human is
  // alerted even if rescue.sh has not run yet.
  const inv = checkRegistryInvariant(content);
  const registryHealth = {
    ok: inv.healthy,
    badRowCount: inv.badRows.length,
    badRows: inv.badRows.slice(0, 10),
  };
  send(res, 200, {
    tendMode,
    registry,
    tasks,
    tendHealth,
    registryHealth,
    attention: {
      taskCount: approvalTasks.length,
      tasks: approvalTasks.map(r => ({
        id: r.id,
        summary: r.summary,
        status: r.status,
        mode: r.mode,
        approvalReason: r.approvalReason,
        approvalLabel: r.approvalLabel,
      })),
      tendIssues,
    },
  });
}

function handleHistory(res) {
  const historyDir = path.join(CWD, 'orchestrate-history');
  const manifestPath = path.join(historyDir, 'MANIFEST.md');
  const manifestContent = readFileSafe(manifestPath);

  if (!manifestContent) {
    return send(res, 200, { manifest: [], entries: {}, rows: [] });
  }

  const manifest = parseManifest(manifestContent);
  const entries = loadHistoryEntries(historyDir, manifest);
  const logsDir = path.join(CWD, '.orchestrate', 'logs');
  const heartbeatContent = readFileSafe(path.join(logsDir, 'heartbeat.log')) || '';
  const completionHints = buildCompletionHints(logsDir, heartbeatContent);

  const projectContent = readFileSafe(path.join(CWD, '.orchestrate', 'project.md'));
  const rawRegistry = projectContent ? parseRegistry(projectContent) : [];
  const registry = computeRegistryCancelledFlags(rawRegistry, path.join(CWD, '.orchestrate', 'tasks'));
  const rows = buildHistoryRows(registry, manifest, entries, logsDir, completionHints);

  send(res, 200, { manifest, rows, stats: historyStats(rows, registry) });
}

function handleLogs(res, query) {
  const taskId = (query.id || '').trim();
  if (!taskId) {
    return send(res, 200, { files: [], logs: {} });
  }

  const logsDir = path.join(CWD, '.orchestrate', 'logs');
  let dirEntries;
  try {
    dirEntries = fs.readdirSync(logsDir);
  } catch (_) {
    return send(res, 200, { files: [], logs: {} });
  }

  const matchingFiles = dirEntries.filter(f => f.startsWith(taskId));
  const logs = {};

  for (const filename of matchingFiles) {
    const content = readFileSafe(path.join(logsDir, filename));
    if (content !== null) {
      logs[filename] = content;
    }
  }

  send(res, 200, { files: matchingFiles, logs });
}

/**
 * Extract the inbox file's OWN identity task IDs (used to decide if it was
 * already handled). Identity = structured `Task ID:` / `processed_as:` lines
 * plus the ID embedded in the filename. We deliberately do NOT scan the body
 * prose for loose `YYYYMMDD-inbox-XXXX` tokens: a brand-new task that merely
 * *references* a completed task (e.g. "Motivated by 20260627-inbox-AC12",
 * `triggered_by:` an improvement's parent) would otherwise be misclassified as
 * completed and hidden from the inbox the moment the referenced task finished.
 */
function extractInboxTaskIds(content, filename) {
  const ids = new Set();
  if (content) {
    // Identity markers only — accept a `Task ID:` line even when written as a
    // markdown bullet ("- Task ID: …") or indented, but NOT a bare ID buried in
    // prose (that is a reference, not the file's own identity).
    const taskIdLine = content.match(/^\s*-?\s*Task ID:\s*(\S+)/m);
    if (taskIdLine) ids.add(taskIdLine[1]);
    const processedAs = content.match(/^processed_as:\s*(\S+)/m);
    if (processedAs) ids.add(processedAs[1]);
  }
  const base = path.basename(filename, '.md');
  const fnMatch = base.match(/(20\d{6}(?:-inbox-[A-Z0-9]+|\d{6}-\d+))/);
  if (fnMatch) ids.add(fnMatch[1]);
  return ids;
}

/** True when an inbox file was already handled (completed task, moved to processed/, etc.). */
function isCompletedInboxFile(content, filename, inboxDir, completeTaskIds) {
  if (!content) return true;
  if (/^processed_as:/m.test(content)) return true;
  if (/^status:\s*blocked-pending-user/m.test(content)) return true;
  if (filename.includes('/processed/')) return true;
  if (inboxDir) {
    const processedCopy = path.join(inboxDir, 'processed', path.basename(filename));
    try {
      if (fs.statSync(processedCopy).isFile()) return true;
    } catch (_) {}
  }
  if (completeTaskIds && completeTaskIds.size > 0) {
    for (const id of extractInboxTaskIds(content, filename)) {
      if (completeTaskIds.has(id)) return true;
    }
  }
  return false;
}

function handleInbox(res) {
  const tendMode = readTendMode(CWD);
  const inboxDir = path.join(CWD, '.orchestrate', 'inbox');
  const projectContent = readFileSafe(path.join(CWD, '.orchestrate', 'project.md'));
  const registry = projectContent ? parseRegistry(projectContent) : [];
  const completeTaskIds = new Set(
    registry.filter(r => r.status === 'complete').map(r => r.id),
  );
  const items = [];

  function addInboxFile(relativePath) {
    const content = readFileSafe(path.join(inboxDir, relativePath));
    if (content === null) return;
    if (isCompletedInboxFile(content, relativePath, inboxDir, completeTaskIds)) return;
    const titleMatch = content.match(/^# (.+)$/m);
    const meta = parseInboxMeta(content, tendMode);
    items.push({
      filename: relativePath,
      title: titleMatch ? titleMatch[1].trim() : path.basename(relativePath),
      content,
      mode: meta.mode,
      needsApproval: meta.needsApproval,
      approvalReason: meta.approvalReason,
      approvalLabel: meta.approvalLabel,
    });
  }

  let dirEntries;
  try {
    dirEntries = fs.readdirSync(inboxDir, { withFileTypes: true });
  } catch (_) {
    return send(res, 200, {
      tendMode,
      items: [],
      attention: { inboxCount: 0, approvalCount: 0, approvalItems: [] },
    });
  }

  for (const entry of dirEntries) {
    if (entry.isFile() && entry.name.endsWith('.md')) {
      addInboxFile(entry.name);
      continue;
    }
    if (entry.isDirectory() && entry.name === 'gated') {
      let gatedEntries;
      try {
        gatedEntries = fs.readdirSync(path.join(inboxDir, 'gated'), { withFileTypes: true });
      } catch (_) {
        continue;
      }
      for (const gated of gatedEntries) {
        if (gated.isFile() && gated.name.endsWith('.md')) {
          addInboxFile(path.join('gated', gated.name));
        }
      }
    }
  }

  items.sort((a, b) => a.filename.localeCompare(b.filename));

  const approvalItems = items.filter(i => i.needsApproval);
  send(res, 200, {
    tendMode,
    items,
    attention: {
      inboxCount: items.length,
      approvalCount: approvalItems.length,
      approvalItems: approvalItems.map(i => ({
        filename: i.filename,
        title: i.title,
        approvalReason: i.approvalReason,
        approvalLabel: i.approvalLabel,
      })),
    },
  });
}

function handleHeartbeat(res) {
  const heartbeatPath = path.join(CWD, '.orchestrate', 'logs', 'heartbeat.log');
  const content = readFileSafe(heartbeatPath);
  if (!content) {
    return send(res, 200, { lines: [] });
  }
  const lines = content.split('\n').filter(l => l.trim() !== '');
  const last20 = lines.slice(-20);
  send(res, 200, { lines: last20 });
}

function handleTaskDetails(res, query) {
  const taskId = (query.id || '').trim();
  if (!taskId) return send(res, 400, { error: 'id required' });

  const logsDir = path.join(CWD, '.orchestrate', 'logs');
  const inboxDir = path.join(CWD, '.orchestrate', 'inbox');
  const taskPath = path.join(CWD, '.orchestrate', 'tasks', `${taskId}.md`);
  const taskContent = readFileSafe(taskPath);

  const projectContent = readFileSafe(path.join(CWD, '.orchestrate', 'project.md'));
  const registry = projectContent ? parseRegistry(projectContent) : [];
  const row = registry.find(r => r.id === taskId);

  let inboxContent = null;
  let inboxFilename = null;
  if (row && row.summary) {
    const found = findInboxSourceForTask(logsDir, inboxDir, row.summary);
    if (found) {
      inboxContent = found.content;
      inboxFilename = found.filename;
    }
  }

  send(res, 200, { taskContent, inboxContent, inboxFilename });
}

async function handleTaskRerun(req, res) {
  let payload;
  try { payload = await readJsonBody(req); } catch (_) { send(res, 400, { error: 'invalid JSON body' }); return; }
  const taskId = (payload.id || '').trim();
  if (!taskId) { send(res, 400, { error: 'id required' }); return; }
  const result = rerunTask(CWD, taskId);
  if (result.error) { send(res, 400, result); return; }
  send(res, 200, result);
}

async function handleTaskRunnow(req, res) {
  let payload;
  try { payload = await readJsonBody(req); } catch (_) { send(res, 400, { error: 'invalid JSON body' }); return; }
  const taskId = (payload.id || '').trim();
  if (!taskId) { send(res, 400, { error: 'id required' }); return; }
  const result = rerunTask(CWD, taskId);
  if (result.error) { send(res, 400, result); return; }
  // Fire-and-forget: kick a tend cycle
  try {
    const runJobPath = path.join(CWD, '.orchestrate', 'bin', 'run-job.sh');
    if (fs.existsSync(runJobPath)) {
      require('child_process').spawn('bash', [runJobPath, 'tend'], {
        detached: true, stdio: 'ignore', cwd: CWD,
      }).unref();
    }
  } catch (_) {}
  send(res, 200, { ...result, tended: true });
}

async function handleTaskResolve(req, res) {
  let payload;
  try { payload = await readJsonBody(req); } catch (_) { send(res, 400, { error: 'invalid JSON body' }); return; }
  const taskId = (payload.id || '').trim();
  const resolution = (payload.resolution || '').trim();
  if (!taskId) { send(res, 400, { error: 'id required' }); return; }
  if (!resolution) { send(res, 400, { error: 'resolution text required' }); return; }

  const taskFilePath = path.join(CWD, '.orchestrate', 'tasks', `${taskId}.md`);
  let taskContent;
  try { taskContent = fs.readFileSync(taskFilePath, 'utf8'); } catch (_) {
    send(res, 404, { error: `task file not found: ${taskId}.md` }); return;
  }

  // Find the first ### Phase N section without "status: ✓ complete"
  const phaseRegex = /^(### Phase (\d+):.*?)(?=^### Phase \d+:|^## |$)/gms;
  let blockingPhaseNum = null;
  let updatedContent = taskContent;
  let matchOffset = 0;

  const lines = taskContent.split('\n');
  let inPhase = false;
  let currentPhaseNum = null;
  let insertIdx = -1;
  let phaseComplete = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const phaseHeader = line.match(/^### Phase (\d+):/);
    if (phaseHeader) {
      // Check if previous phase was incomplete
      if (inPhase && !phaseComplete && insertIdx !== -1 && blockingPhaseNum === null) {
        blockingPhaseNum = currentPhaseNum;
        // Insert human_resolution after the status line within this phase
        lines.splice(insertIdx + 1, 0, `human_resolution: ${resolution}`);
        break;
      }
      inPhase = true;
      currentPhaseNum = parseInt(phaseHeader[1], 10);
      phaseComplete = false;
      insertIdx = i;
    } else if (inPhase) {
      if (line.trim().startsWith('status:')) {
        if (line.includes('✓ complete')) {
          phaseComplete = true;
        }
        insertIdx = i;
      }
    }
  }

  // Handle last phase if it was the blocking one
  if (blockingPhaseNum === null && inPhase && !phaseComplete && insertIdx !== -1) {
    blockingPhaseNum = currentPhaseNum;
    lines.splice(insertIdx + 1, 0, `human_resolution: ${resolution}`);
  }

  if (blockingPhaseNum === null) {
    send(res, 400, { error: 'no incomplete phase found in task file' }); return;
  }

  updatedContent = lines.join('\n');
  fs.writeFileSync(taskFilePath, updatedContent);

  const result = rerunTask(CWD, taskId);
  if (result.error) { send(res, 400, result); return; }

  try {
    const runJobPath = path.join(CWD, '.orchestrate', 'bin', 'run-job.sh');
    if (fs.existsSync(runJobPath)) {
      require('child_process').spawn('bash', [runJobPath, 'tend'], {
        detached: true, stdio: 'ignore', cwd: CWD,
      }).unref();
    }
  } catch (_) {}

  const now = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
  try {
    const hbPath = path.join(CWD, '.orchestrate', 'logs', 'heartbeat.log');
    fs.appendFileSync(hbPath, `[${now}] dashboard — resolve injected phase ${blockingPhaseNum} of ${taskId}: "${resolution.slice(0, 80)}"\n`);
  } catch (_) {}

  send(res, 200, { ok: true, phase: blockingPhaseNum, tended: true });
}

async function handleTaskApprove(req, res) {
  let payload;
  try {
    payload = await readJsonBody(req);
  } catch (_) {
    send(res, 400, { error: 'invalid JSON body' });
    return;
  }
  const taskId = (payload.id || '').trim();
  const goMode = payload.mode === 'cancel' ? 'cancel' : payload.mode === 'gated' ? 'gated' : 'auto';
  const reason = typeof payload.reason === 'string' ? payload.reason : undefined;
  if (!taskId) {
    send(res, 400, { error: 'id required' });
    return;
  }
  try {
    const result = approveRegistryTask(CWD, taskId, goMode, reason);
    send(res, result.error ? 404 : 200, result);
  } catch (e) {
    send(res, 500, { error: e.message || 'internal error' });
  }
}

async function handleLaunchdStart(req, res) {
  let payload;
  try { payload = await readJsonBody(req); } catch (_) { send(res, 400, { error: 'invalid JSON body' }); return; }
  const label = (payload.label || '').trim();
  if (!label || !/^[\w.-]+$/.test(label)) { send(res, 400, { error: 'valid label required' }); return; }

  // Clear the tend lock before kickstart so run-job.sh doesn't exit early on "lock held".
  // This is the primary cause of Run Now flashing running→ok without processing tasks.
  let lockCleared = false;
  if (label === 'com.orchestrate.tend') {
    const lockPath = path.join(CWD, '.orchestrate', '.tend.lock');
    try { fs.unlinkSync(lockPath); lockCleared = true; } catch (_) { /* no lock or already gone */ }
  }

  try {
    const uid = require('child_process').execSync('id -u', { encoding: 'utf8' }).trim();
    require('child_process').execSync(`launchctl kickstart -k gui/${uid}/${label}`, { encoding: 'utf8', timeout: 5000 });
    send(res, 200, { ok: true, label, lockCleared });
  } catch (e) {
    send(res, 500, { error: e.message || 'kickstart failed', label });
  }
}

// ── launchd ───────────────────────────────────────────────────────────────────

function extractPlistString(content, key) {
  const re = new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`);
  const m = content.match(re);
  return m ? m[1] : null;
}

function extractPlistInt(content, key) {
  const re = new RegExp(`<key>${key}</key>\\s*<integer>([^<]*)</integer>`);
  const m = content.match(re);
  return m ? parseInt(m[1], 10) : null;
}

function intervalLabel(secs) {
  if (secs < 60) return `${secs}s`;
  if (secs < 3600) return `${Math.round(secs / 60)} min`;
  return `${Math.round(secs / 3600)} hr`;
}

function parseResetHint(raw) {
  if (!raw) return 'soon';
  let s = raw.trim().replace(/;.*$/, '').replace(/·.*$/, '');
  let opens = (s.match(/\(/g) || []).length;
  let closes = (s.match(/\)/g) || []).length;
  while (closes > opens && s.endsWith(')')) {
    s = s.slice(0, -1).trim();
    closes--;
  }
  return s || 'soon';
}

/**
 * True agent quota signals only — excludes task prose like "**Session limitation:** shell blocked".
 */
function isSessionLimitSignal(line) {
  const t = (line || '').trim();
  if (!t || /Session limitation:/i.test(t)) return false;
  if (/^\[\d{4}-\d{2}-\d{2}T[^\]]+\] run-job — .*session/i.test(t)) return true;
  if (/You've hit your session limit/i.test(t)) return true;
  if (/both runners session-limited/i.test(t)) return true;
  return false;
}

function findLatestSessionLimit(heartbeatContent, heartbeatErrContent) {
  const lines = [
    ...(heartbeatErrContent || '').split('\n'),
    ...(heartbeatContent || '').split('\n'),
  ].filter(l => l.trim()).reverse();
  for (const line of lines) {
    if (!isSessionLimitSignal(line)) continue;
    const m = line.match(/resets ([^·;]+)/i);
    return {
      iso: extractHeartbeatIso(line),
      resetHint: m ? parseResetHint(m[1]) : 'soon',
      line,
    };
  }
  return null;
}

function findLatestTendSuccess(heartbeatContent) {
  const lines = (heartbeatContent || '').split('\n').reverse();
  for (const line of lines) {
    if (!/^\[\d{4}-\d{2}-\d{2}T[^\]]+\]/.test(line)) continue;
    if (/tend-auto —|tend — (?:idle|cycle complete)|inbox — registered|tend — completed/i.test(line)) {
      const iso = extractHeartbeatIso(line);
      if (iso) return iso;
    }
  }
  return null;
}

function tendThrottleHint(heartbeatContent, heartbeatErrContent) {
  const limit = findLatestSessionLimit(heartbeatContent, heartbeatErrContent || '');
  if (!limit) return null;
  const success = findLatestTendSuccess(heartbeatContent);
  if (success && limit.iso) {
    if (new Date(success).getTime() >= new Date(limit.iso).getTime()) return null;
  }
  return limit.resetHint;
}

const TEND_HEALTH_PATTERNS = [
  {
    re: /connection lost|both runners connection-lost/i,
    status: 'degraded',
    message: 'Tend degraded — connection lost; will retry next cycle',
  },
  {
    re: /cursor cli\.json invalid|permissions\.deny|Invalid project config/i,
    status: 'misconfigured',
    message: 'Tend misconfigured — fix .cursor/cli.json (run sync-cursor-claude-permissions.sh)',
  },
  {
    re: /Cursor IDE required but not running|Cursor not running|cursor unavailable|secondary unavailable/i,
    status: 'blocked',
    message: 'Tend blocked — open Cursor IDE or switch runner to claude',
  },
  {
    re: /tend deferred/i,
    status: 'blocked',
    message: 'Tend deferred — check runner / IDE configuration',
  },
  {
    re: /syntax error near unexpected token|run-job\.sh:.*syntax/i,
    status: 'failed',
    message: 'Tend failed — run-job.sh syntax error (reinstall from ai-toolbox)',
  },
];

function extractHeartbeatIso(line) {
  const m = (line || '').match(/^\[(\d{4}-\d{2}-\d{2}T[^\]]+)\]/);
  return m ? m[1] : null;
}

function runJobScriptOk(cwd) {
  const script = path.join(cwd, '.orchestrate', 'bin', 'run-job.sh');
  try {
    execSync(`bash -n ${JSON.stringify(script)}`, { stdio: 'ignore' });
    return true;
  } catch (_) {
    return false;
  }
}

/**
 * Derive tend execution health from heartbeat logs, stderr, launchctl, and lock file.
 */
function parseTendHealth(cwd, heartbeatContent, heartbeatErrContent, launchctlTend) {
  const runner = readRunner(cwd);
  const sessionLimit = findLatestSessionLimit(heartbeatContent, heartbeatErrContent);
  if (sessionLimit) {
    const success = findLatestTendSuccess(heartbeatContent);
    const limitTime = sessionLimit.iso ? new Date(sessionLimit.iso).getTime() : 0;
    const successTime = success ? new Date(success).getTime() : 0;
    if (!successTime || limitTime > successTime) {
      return {
        ok: false,
        status: 'throttled',
        message: 'Tend throttled — agent session limit reached',
        runner,
        lastEventAt: sessionLimit.iso || success || null,
        resetHint: sessionLimit.resetHint,
      };
    }
  }

  const successIso = findLatestTendSuccess(heartbeatContent);
  const successTime = successIso ? new Date(successIso).getTime() : 0;

  const lines = [
    ...(heartbeatErrContent || '').split('\n'),
    ...(heartbeatContent || '').split('\n'),
  ].filter(l => l.trim()).reverse();

  let lastEventAt = null;
  for (const line of lines) {
    const iso = extractHeartbeatIso(line);
    if (iso) lastEventAt = iso;

    for (const pat of TEND_HEALTH_PATTERNS) {
      if (!pat.re.test(line)) continue;
      if (pat.status === 'failed' && /syntax error/i.test(pat.message) && runJobScriptOk(cwd)) {
        continue;
      }
      const eventIso = iso || lastEventAt;
      const eventTime = eventIso ? new Date(eventIso).getTime() : 0;
      if (successTime) {
        if (eventTime && eventTime <= successTime) continue;
        if (!eventTime && /connection lost/i.test(line)) continue;
      }
      return {
        ok: false,
        status: pat.status,
        message: pat.message,
        runner,
        lastEventAt: eventIso || lastEventAt,
      };
    }
  }

  if (launchctlTend && launchctlTend.exitStatus !== '-' && launchctlTend.exitStatus !== '0') {
    return {
      ok: false,
      status: 'failed',
      message: `Tend launchd job failed (exit ${launchctlTend.exitStatus})`,
      runner,
      lastEventAt,
    };
  }

  const lockPath = path.join(cwd, '.orchestrate', '.tend.lock');
  try {
    const stat = fs.statSync(lockPath);
    const ageSec = Math.floor((Date.now() - stat.mtimeMs) / 1000);
    if (ageSec > 360) {
      const recentLine = (heartbeatContent || '').split('\n').reverse().find(l =>
        /tend go auto|tend-auto|tend — idle|tend — completed/i.test(l),
      );
      const recentIso = recentLine && extractHeartbeatIso(recentLine);
      const recentAge = recentIso
        ? (Date.now() - new Date(recentIso).getTime()) / 1000
        : Infinity;
      if (recentAge > 600) {
        return {
          ok: false,
          status: 'stuck',
          message: `Tend lock stale (${ageSec}s) — clear .orchestrate/.tend.lock`,
          runner,
          lastEventAt,
        };
      }
    }
  } catch (_) {}

  return { ok: true, status: 'ok', message: 'Tend healthy', runner, lastEventAt };
}

// Read `launchctl list`, or a test-injected fixture. tendHealth (and the /api/tasks,
// /api/tend-status, /api/launchd handlers that surface it) must not depend on the live
// host launchd state, or a nonzero LastExitStatus on the real com.orchestrate.tend job
// makes hermetic tmpDir-fixture tests fail non-deterministically. Setting
// ORCH_TEST_LAUNCHCTL forces a controlled listing (empty string = no jobs known).
function readLaunchctlList() {
  if (process.env.ORCH_TEST_LAUNCHCTL != null) return process.env.ORCH_TEST_LAUNCHCTL;
  try {
    return execSync('launchctl list 2>/dev/null', { encoding: 'utf8', timeout: 3000 });
  } catch (_) {
    return '';
  }
}

function readTendHealthInputs(cwd) {
  const logsDir = path.join(cwd, '.orchestrate', 'logs');
  const heartbeatContent = readFileSafe(path.join(logsDir, 'heartbeat.log')) || '';
  const heartbeatErrContent = readFileSafe(path.join(logsDir, 'heartbeat-err.log')) || '';
  const lctlOutput = readLaunchctlList();
  const lctlMap = {};
  for (const line of (lctlOutput || '').split('\n')) {
    const parts = line.trim().split(/\s+/);
    if (parts.length === 3) {
      const [pid, exitStatus, label] = parts;
      lctlMap[label] = { pid, exitStatus };
    }
  }
  const tendHealth = parseTendHealth(
    cwd,
    heartbeatContent,
    heartbeatErrContent,
    lctlMap['com.orchestrate.tend'],
  );
  return { heartbeatContent, tendHealth };
}

// Plist label prefixes that are surfaced first-class in the dashboard LaunchD
// tab without needing an explicit LAUNCHD_WATCH entry in agent.conf.
const LAUNCHD_PREFIXES = ['com.orchestrate.', 'com.inbox-zero.'];

function buildLaunchdAgents(launchDir, lctlOutput, heartbeatContent, tendHealth, extraLabels) {
  let plistFiles = [];
  try {
    plistFiles = fs.readdirSync(launchDir)
      .filter(f => f.endsWith('.plist') && LAUNCHD_PREFIXES.some(p => f.startsWith(p)))
      .map(f => path.join(launchDir, f));
  } catch (_) {}

  // Include extra labels from LAUNCHD_WATCH in agent.conf
  for (const label of (extraLabels || [])) {
    const plistPath = path.join(launchDir, `${label}.plist`);
    if (!plistFiles.includes(plistPath)) {
      try {
        fs.accessSync(plistPath, fs.constants.R_OK);
        plistFiles.push(plistPath);
      } catch (_) {}
    }
  }

  // Parse launchctl list: columns are PID ExitStatus Label
  const lctlMap = {};
  for (const line of (lctlOutput || '').split('\n')) {
    const parts = line.trim().split(/\s+/);
    if (parts.length === 3) {
      const [pid, exitStatus, label] = parts;
      lctlMap[label] = { pid, exitStatus };
    }
  }

  return plistFiles.map(plistPath => {
    const content = readFileSafe(plistPath) || '';
    const label = extractPlistString(content, 'Label') || path.basename(plistPath, '.plist');

    // Schedule
    let interval = 'unknown';
    const si = extractPlistInt(content, 'StartInterval');
    if (si !== null) {
      interval = intervalLabel(si);
    } else if (content.includes('StartCalendarInterval')) {
      interval = 'calendar';
    }

    // Log path → mtime for lastRun
    const rawLogPath = extractPlistString(content, 'StandardOutPath');
    const logPath = rawLogPath ? rawLogPath.replace(/^~/, os.homedir()) : null;
    let lastRun = null;
    if (logPath) {
      try {
        lastRun = fs.statSync(logPath).mtime.toISOString();
      } catch (_) {}
    }

    // Status from launchctl
    const lctl = lctlMap[label];
    let status = 'unknown';
    if (lctl) {
      if (lctl.pid !== '-') {
        status = 'running';
      } else if (lctl.exitStatus === '0') {
        status = 'ok';
      } else if (lctl.exitStatus !== '-') {
        status = 'failed';
      }
    }

    let tendHealthRow = null;
    if (label === 'com.orchestrate.tend') {
      tendHealthRow = tendHealth || null;
      if (tendHealthRow && !tendHealthRow.ok) {
        status = tendHealthRow.resetHint
          ? `${tendHealthRow.status} (${tendHealthRow.resetHint})`
          : tendHealthRow.status;
      }
    }

    return { label, interval, lastRun, status, logPath, tendHealth: tendHealthRow };
  });
}

function handleAgentConfGet(res) {
  send(res, 200, readAgentConf(CWD));
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (e) {
        reject(e);
      }
    });
    req.on('error', reject);
  });
}

async function handleAgentConfPost(req, res) {
  let payload;
  try {
    payload = await readJsonBody(req);
  } catch (_) {
    send(res, 400, { error: 'invalid JSON body' });
    return;
  }

  const updates = {};
  if (payload.runner !== undefined) {
    const runner = String(payload.runner).toLowerCase().trim();
    if (runner !== 'cursor' && runner !== 'claude') {
      send(res, 400, { error: 'runner must be cursor or claude' });
      return;
    }
    updates.runner = runner;
  }
  if (payload.tendMode !== undefined) {
    const mode = String(payload.tendMode).trim();
    if (!['go auto', 'go_auto', 'notify', 'tend', ''].includes(mode)) {
      send(res, 400, { error: 'tendMode must be go auto or notify' });
      return;
    }
    updates.tendMode = mode === 'go_auto' ? 'go auto' : (mode || 'go auto');
  }
  if (payload.cursorFallback !== undefined) {
    const fb = String(payload.cursorFallback).toLowerCase().trim();
    if (fb !== 'auto' && fb !== 'never') {
      send(res, 400, { error: 'cursorFallback must be auto or never' });
      return;
    }
    updates.cursorFallback = fb;
  }
  if (payload.cursorAutoOpen !== undefined) {
    updates.cursorAutoOpen = Boolean(payload.cursorAutoOpen);
  }

  if (!Object.keys(updates).length) {
    send(res, 400, { error: 'no valid fields to update' });
    return;
  }

  try {
    const conf = writeAgentConf(CWD, updates);
    send(res, 200, conf);
  } catch (e) {
    send(res, 500, { error: e.message || 'failed to write agent.conf' });
  }
}

function handleTendStatus(res) {
  const { tendHealth } = readTendHealthInputs(CWD);
  send(res, 200, tendHealth);
}

function handleLaunchd(res) {
  // ORCH_TEST_LAUNCHD_DIR lets tests inject a fixture LaunchAgents dir so the
  // /api/launchd HTTP response is driven by seeded plists, not the live host's
  // ~/Library/LaunchAgents (which a tmpDir fixture cannot isolate). Mirrors the
  // ORCH_TEST_LAUNCHCTL escape hatch used for launchctl list output.
  const launchDir = process.env.ORCH_TEST_LAUNCHD_DIR != null
    ? process.env.ORCH_TEST_LAUNCHD_DIR
    : path.join(os.homedir(), 'Library', 'LaunchAgents');
  const { heartbeatContent, tendHealth } = readTendHealthInputs(CWD);
  const { launchdWatch } = readAgentConf(CWD);
  const lctlOutput = readLaunchctlList();
  send(res, 200, buildLaunchdAgents(launchDir, lctlOutput, heartbeatContent, tendHealth, launchdWatch));
}

// ── server ────────────────────────────────────────────────────────────────────

const server = http.createServer(async (req, res) => {
  const parsed = url.parse(req.url, true);
  const pathname = parsed.pathname;

  if (pathname === '/api/agent-conf' && req.method === 'GET') {
    handleAgentConfGet(res);
    return;
  }
  if (pathname === '/api/agent-conf' && req.method === 'POST') {
    await handleAgentConfPost(req, res);
    return;
  }
  if (pathname === '/api/task-approve' && req.method === 'POST') {
    await handleTaskApprove(req, res);
    return;
  }
  if (pathname === '/api/task-rerun' && req.method === 'POST') {
    await handleTaskRerun(req, res);
    return;
  }
  if (pathname === '/api/task-runnow' && req.method === 'POST') {
    await handleTaskRunnow(req, res);
    return;
  }
  if (pathname === '/api/task-resolve' && req.method === 'POST') {
    await handleTaskResolve(req, res);
    return;
  }
  if (pathname === '/api/kube-approve' && req.method === 'POST') {
    await handleKubeApprove(req, res);
    return;
  }
  if (pathname === '/api/pg-approve' && req.method === 'POST') {
    await handlePgApprove(req, res);
    return;
  }
  if (pathname === '/api/launchd-start' && req.method === 'POST') {
    await handleLaunchdStart(req, res);
    return;
  }

  if (req.method !== 'GET') {
    res.writeHead(405, { 'Content-Type': 'text/plain' });
    res.end('Method Not Allowed');
    return;
  }

  if (pathname === '/') {
    sendFile(res, path.join(DIR, 'index.html'));
  } else if (pathname === '/api/launchd') {
    handleLaunchd(res);
  } else if (pathname === '/api/tend-status') {
    handleTendStatus(res);
  } else if (pathname === '/api/tasks') {
    handleTasks(res);
  } else if (pathname === '/api/history') {
    handleHistory(res);
  } else if (pathname === '/api/logs') {
    handleLogs(res, parsed.query);
  } else if (pathname === '/api/inbox') {
    handleInbox(res);
  } else if (pathname === '/api/kube-reviews') {
    handleKubeReviews(res);
  } else if (pathname === '/api/pg-reviews') {
    handlePgReviews(res);
  } else if (pathname === '/api/heartbeat') {
    handleHeartbeat(res);
  } else if (pathname === '/api/agent-status') {
    handleAgentStatus(res);
  } else if (pathname === '/api/task-details') {
    handleTaskDetails(res, parsed.query);
  } else {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not found');
  }
});

if (require.main === module) {
  // Exit on file change so launchd (KeepAlive) restarts with fresh code after sync.sh
  fs.watch(__filename, { persistent: false }, () => {
    console.log('server.js changed — restarting');
    process.exit(0);
  });

  cleanupStaleKubeReviews(CWD);
  cleanupStalePgReviews(CWD);

  server.listen(PORT, '127.0.0.1', () => {
    console.log(`task-orchestrate monitor listening on http://127.0.0.1:${PORT}`);
    console.log(`Working directory: ${CWD}`);
  });

  server.on('error', (err) => {
    console.error('Server error:', err.message);
    process.exit(1);
  });
}

module.exports = {
  intervalLabel,
  buildLaunchdAgents,
  tendThrottleHint,
  isSessionLimitSignal,
  findLatestSessionLimit,
  findLatestTendSuccess,
  parseTendHealth,
  readTendHealthInputs,
  parseRegistry,
  formatRegistryRow,
  checkRegistryInvariant,
  readTendMode,
  readAgentConf,
  readRunner,
  readAgentStatus,
  parseAgentConfValue,
  isCursorIdeRunning,
  updateAgentConfLine,
  writeAgentConf,
  isTendGoAuto,
  taskApprovalInfo,
  isCancelledTask,
  computeRegistryCancelledFlags,
  stampCancelMarker,
  parseInboxMeta,
  isCompletedInboxFile,
  extractInboxTaskIds,
  manifestMatchesRegistry,
  resolveRegistryIds,
  resolveHistoryDatetime,
  HISTORY_TZ,
  isoToDate,
  historyEasternYmd,
  isInDefaultHistoryWindow,
  isPlaceholderTimestamp,
  isFutureTimestamp,
  buildCompletionHints,
  parseIsoFromLogContent,
  HISTORY_REGISTRY_ALIASES,
  archiveDateFromFilename,
  findHistoryEntry,
  loadHistoryEntries,
  buildHistoryRows,
  historyStats,
  historyCoverage,
  extractTaskIdFromFilename,
  collectTaskLogContent,
  synthesizeHistoryStub,
  APPROVAL_STATUSES,
  findInboxSourceForTask,
  getGoalExcerpt,
  approveRegistryTask,
  rerunTask,
  kubeReviewsPaths,
  listKubeReviews,
  approveKubeReview,
  pgReviewsPaths,
  listPgReviews,
  approvePgReview,
};
