#!/usr/bin/env bash
# rescue.sh — self-healing stuck inbox / tend watchdog
# Runs every 10 min via com.orchestrate.rescue launchd agent.
# Pure bash, no agent dependency — detects and fixes stuck tend/inbox states.
#
# Stuck detection:
#   1. Lock is stale (>360s)
#   2. Heartbeat is stale (>600s) AND there are actionable items
#   3. Tend is running (fresh heartbeat) but a pending/awaiting_go task has been
#      waiting >900s — "idle-loop" bug where tend fires but misreports idle
#
# Fix actions:
#   - Clear stale lock
#   - Run cleanup-stale-inbox.sh + drain-inbox.sh (bash)
#   - Kick run-job.sh tend in background to restart agent dispatch
set -euo pipefail

ROOT="${1:-$(pwd)}"
LOCK="$ROOT/.orchestrate/.tend.lock"
HEARTBEAT="$ROOT/.orchestrate/logs/heartbeat.log"
PROJ="$ROOT/.orchestrate/project.md"
BIN="$ROOT/.orchestrate/bin"

log_rescue() {
  local msg="$1"
  mkdir -p "$(dirname "$HEARTBEAT")"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] rescue — $msg" >> "$HEARTBEAT"
}

# --- 1. Skip if tend is actively running (fresh lock) ---
if [[ -f "$LOCK" ]]; then
  LOCK_MTIME="$(date -r "$LOCK" +%s 2>/dev/null || echo 0)"
  LOCK_AGE=$(( $(date +%s) - LOCK_MTIME ))
  if [[ "$LOCK_AGE" -lt 360 ]]; then
    exit 0
  fi
fi

# --- 2. Check heartbeat freshness ---
HEARTBEAT_AGE=99999
if [[ -f "$HEARTBEAT" ]]; then
  LAST_TS="$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' "$HEARTBEAT" | tail -1 2>/dev/null || true)"
  if [[ -n "$LAST_TS" ]]; then
    # macOS and GNU date compat; TZ=UTC required on macOS — date -j ignores 'Z' suffix
    if LAST_EPOCH="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$LAST_TS" '+%s' 2>/dev/null)"; then
      :
    elif LAST_EPOCH="$(date -d "$LAST_TS" '+%s' 2>/dev/null)"; then
      :
    else
      LAST_EPOCH=0
    fi
    HEARTBEAT_AGE=$(( $(date +%s) - LAST_EPOCH ))
  fi
fi

# --- 2a. Reset stale 'running' tasks to 'needs_human' ---
# A task stuck in 'running' for >3600s means the agent session crashed without
# updating the registry. T-4 can't act on 'running' tasks, so reset them to
# 'needs_human' so the next tend cycle auto-resolves (all phases complete) or
# surfaces them for human attention.
if [[ -f "$PROJ" ]]; then
  NOW_RESET="$(date +%s)"
  while IFS='|' read -r _ r_id _ r_mode _ r_status r_last _; do
    r_status="${r_status## }"; r_status="${r_status%% }"
    [[ "$r_status" == "running" ]] || continue
    r_id="${r_id## }"; r_id="${r_id%% }"
    [[ -z "$r_id" || "$r_id" == "ID" || "$r_id" == "---"* ]] && continue
    r_mode="${r_mode## }"; r_mode="${r_mode%% }"
    r_last="${r_last## }"; r_last="${r_last%% }"
    r_ts=0
    # TZ=UTC required on macOS: date -j -f ignores 'Z' suffix and uses local time
    if ! r_ts="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$r_last" '+%s' 2>/dev/null)"; then
      r_ts="$(date -d "$r_last" '+%s' 2>/dev/null || echo 0)"
    fi
    r_age=$(( NOW_RESET - r_ts ))
    if [[ "$r_age" -gt 3600 ]]; then
      r_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      awk -v id="$r_id" -v ts="$r_now" 'BEGIN{FS="|";OFS="|"} /^\|/ {
        n=split($2,a,/[[:space:]]+/); tid=""
        for(i=1;i<=n;i++) if(a[i]!=""){tid=a[i];break}
        n=split($6,b,/[[:space:]]+/); st=""
        for(i=1;i<=n;i++) if(b[i]!=""){st=b[i];break}
        if(tid==id && st=="running"){$6=" needs_human ";$7=" "ts" "}
      } {print}' "$PROJ" > "${PROJ}.tmp" && mv "${PROJ}.tmp" "$PROJ" || true
      # Emit the exact "ghost-reset <ID>: running→needs_human" token that
      # tend-need-action.sh:42 recognizes, so an AUTO job with no task file is
      # re-queued instead of left parked in needs_human. run-job.sh:302 uses the
      # same form. Gated rows are genuine human blockers — keep them descriptive
      # and NOT re-queue-eligible (avoids spurious dispatch / token spend).
      if [[ "$r_mode" == "auto" ]]; then
        log_rescue "ghost-reset $r_id: running→needs_human (${r_age}s stale, rescue)"
      else
        log_rescue "reset stale running task $r_id (${r_age}s) → needs_human (gated; not auto-requeued)"
      fi
    fi
  done < <(grep '^|' "$PROJ" 2>/dev/null)
fi

# --- 3. Compute actionable items (must happen before early-exit decisions) ---
INBOX_COUNT=0
for f in "$ROOT/.orchestrate/inbox"/*.md "$ROOT/.orchestrate/inbox/gated"/*.md; do
  [[ -f "$f" ]] || continue
  grep -qE '^deferred_at:' "$f" 2>/dev/null && continue
  INBOX_COUNT=$(( INBOX_COUNT + 1 ))
done

REGISTRY_ACTIONABLE=0
OLDEST_PENDING_AGE=0
if [[ -f "$PROJ" ]]; then
  # needs_human is a parked state the watchdog cannot progress on its own, so it
  # must NOT count toward the stuck-tend heuristic — otherwise rescue treats
  # human-blocked rows as "actionable" forever and logs a false RECOVERED every
  # cycle. Auto-resolvable needs_human rows are still handled by tend's own
  # scheduled second-pass check, not by rescue.
  for st in pending awaiting_go running; do
    n="$(awk -F'|' -v st="$st" '
      /^\|/ && $2 !~ /^[[:space:]]*ID[[:space:]]*$/ && $2 !~ /^-+$/ {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6)
        if ($6 == st) n++
      }
      END { print n + 0 }
    ' "$PROJ" 2>/dev/null || echo 0)"
    REGISTRY_ACTIONABLE=$(( REGISTRY_ACTIONABLE + n ))
  done

  # Find the oldest task stuck as pending/awaiting_go (not needs_human/running).
  # Used to detect the "idle-loop" bug: tend fires every 5 min but never executes
  # a registered pending task because tend-need-action.sh transiently returned 0.
  NOW="$(date +%s)"
  while IFS='|' read -r _ _id _ _ _ status last_act _; do
    status="${status## }"; status="${status%% }"
    [[ "$status" == "pending" || "$status" == "awaiting_go" ]] || continue
    last_act="${last_act## }"; last_act="${last_act%% }"
    ts=0
    # TZ=UTC required on macOS: date -j -f ignores 'Z' suffix and uses local time
    if ! ts="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$last_act" '+%s' 2>/dev/null)"; then
      ts="$(date -d "$last_act" '+%s' 2>/dev/null || echo 0)"
    fi
    age=$(( NOW - ts ))
    [[ "$age" -gt "$OLDEST_PENDING_AGE" ]] && OLDEST_PENDING_AGE="$age"
  done < <(grep '^|' "$PROJ" 2>/dev/null)
fi

# --- 4. Exit when truly healthy: tend running + nothing to do ---
if [[ "$HEARTBEAT_AGE" -lt 600 && "$INBOX_COUNT" -eq 0 && "$REGISTRY_ACTIONABLE" -eq 0 ]]; then
  exit 0
fi

# --- 5. Nothing actionable anywhere: log stale heartbeat and exit ---
if [[ "$INBOX_COUNT" -eq 0 && "$REGISTRY_ACTIONABLE" -eq 0 ]]; then
  log_rescue "idle check — heartbeat stale ${HEARTBEAT_AGE}s but nothing actionable"
  exit 0
fi

# --- 6. Tend is running but no task has been stuck long enough yet ---
# If heartbeat is fresh and no pending/awaiting_go task has been waiting >900s,
# give tend time to execute naturally (it fires every 5 min).
if [[ "$HEARTBEAT_AGE" -lt 600 && "$OLDEST_PENDING_AGE" -lt 900 ]]; then
  exit 0
fi

# --- 7. STUCK DETECTED — rescue! ---
# Either: heartbeat stale (tend stopped) OR pending task waiting >900s with
# fresh heartbeat (idle-loop: tend runs but misreports idle).
STUCK_REASON="heartbeat_age=${HEARTBEAT_AGE}s oldest_pending_age=${OLDEST_PENDING_AGE}s inbox=${INBOX_COUNT} registry_actionable=${REGISTRY_ACTIONABLE}"
FIXED_ITEMS=()

if [[ -f "$LOCK" ]]; then
  LOCK_MTIME="$(date -r "$LOCK" +%s 2>/dev/null || echo 0)"
  LOCK_AGE=$(( $(date +%s) - LOCK_MTIME ))
  rm -f "$LOCK"
  FIXED_ITEMS+=("cleared stale lock (${LOCK_AGE}s old)")
fi

if [[ -x "$BIN/cleanup-stale-inbox.sh" ]]; then
  bash "$BIN/cleanup-stale-inbox.sh" "$ROOT" 2>/dev/null || true
  FIXED_ITEMS+=("ran cleanup-stale-inbox")
fi

if [[ -x "$BIN/drain-inbox.sh" ]]; then
  DRAIN_OUT="$(bash "$BIN/drain-inbox.sh" "$ROOT" 2>&1 || true)"
  DRAINED="$(printf '%s' "$DRAIN_OUT" | grep '^DRAINED=' | cut -d= -f2 || echo 0)"
  if [[ "${DRAINED:-0}" -gt 0 ]]; then
    FIXED_ITEMS+=("drained $DRAINED inbox item(s)")
  fi
fi

SUMMARY="$(IFS=', '; echo "${FIXED_ITEMS[*]:-nothing needed}")"
log_rescue "RECOVERED stuck tend — ${STUCK_REASON} — ${SUMMARY}"

# Kick run-job.sh tend in background to restart agent dispatch without waiting
# for the next launchd tick (5-min interval).
RUNJOB="$BIN/run-job.sh"
if [[ -x "$RUNJOB" ]]; then
  nohup bash "$RUNJOB" tend >> "$HEARTBEAT" 2>&1 &
  log_rescue "kicked run-job.sh tend (pid $!)"
fi
