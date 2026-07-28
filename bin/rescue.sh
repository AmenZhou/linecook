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

# Churn guard: share the re-queue counter with run-job.sh / requeue-unblocked.sh
# so a task ghost-reset 3× from ANY reaper is parked rather than churning forever.
CG_ROOT="$ROOT"
if [[ -f "$BIN/churn-guard.sh" ]]; then
  # shellcheck disable=SC1090
  source "$BIN/churn-guard.sh"
fi

# Stale-running threshold — MUST match run-job.sh:reset_stale_running_tasks
# (STALE_RUNNING_SECS). Keeping the two reapers on a single value avoids the
# 14C8 gap where a ghost was older than run-job's 600s bar but younger than
# rescue's old 3600s bar, so neither reaper reset it.
STALE_RUNNING_SECS=600

# A510 no-task-file grace — MUST match run-job.sh:reset_stale_running_tasks
# (NO_FILE_GRACE_SECS). A `running` row that has not yet written its task file
# has no fresh-mtime signal for the 19D7 guard to prove liveness, so a slow-but-
# alive job (dispatched, agent alive, still spinning up) needs a longer grace
# than STALE_RUNNING_SECS before this reaper can treat it as a genuine ghost.
# See the C829 fix note below for why rescue.sh needs this mirrored explicitly.
NO_FILE_GRACE_SECS=1800

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

# --- 2pre. Normalize registry rows (NF==8 invariant) BEFORE any status fix ---
# A registry data row must be exactly `| ID | summary | mode | phase | status |
# last_activity |` → awk -F'|' NF==8 (6 cells + leading/trailing empties). A
# concurrent/legacy writer could append a phantom field past the trailing pipe
# (`| ... | running | <ts> | <ts>`), which defeats the stale-running reset below
# (its matcher expects `| running | ts |`) and deadlocks the registry. Normalize
# first — keeping the 6 real columns ($2..$7) and restoring the trailing pipe —
# so corruption from ANY source (monitor, parallel agents, manual edits) self-heals
# without an agent. No-op on valid rows. Atomic temp+mv write.
if [[ -f "$PROJ" ]]; then
  NORM_TMP="${PROJ}.norm.$$"
  if awk -F'|' -v OFS='|' '
    /^\|[[:space:]]*[0-9]/ && NF>=8 {
      trailing=$8; gsub(/[[:space:]]/,"",trailing)
      if (NF>8 || trailing!="") {
        line=$1
        for (i=2; i<=7; i++) line=line "|" $i
        print line "|"; fixed++; next
      }
    }
    { print }
    END { if (fixed>0) print "NORMALIZED="fixed > "/dev/stderr" }
  ' "$PROJ" > "$NORM_TMP" 2>"${NORM_TMP}.err"; then
    NORM_COUNT="$(grep -oE 'NORMALIZED=[0-9]+' "${NORM_TMP}.err" 2>/dev/null | cut -d= -f2 || echo 0)"
    if [[ "${NORM_COUNT:-0}" -gt 0 ]]; then
      mv "$NORM_TMP" "$PROJ"
      log_rescue "normalized $NORM_COUNT corrupted registry row(s) (registry-invariant self-heal: NF!=8 or non-empty trailing field)"
    else
      rm -f "$NORM_TMP"
    fi
  else
    rm -f "$NORM_TMP"
  fi
  rm -f "${NORM_TMP}.err"

  # Continuous invariant guard: any data row that is STILL malformed after the
  # normalizer is corruption it could not repair. Two corruption classes:
  #   (a) STRUCTURAL — NF!=8 OR non-empty trailing $8 (e.g. truncated row, phantom
  #       column). A valid row is NF==8 with an EMPTY trailing $8.
  #   (b) DOMAIN / field-shift — NF==8 with empty $8 (structurally clean) but a
  #       wrong VALUE in an enum column, e.g. an off-by-one awk update that wrote
  #       the phase number into the mode column. NF==8 is necessary but NOT
  #       sufficient, so we also assert mode ($4) ∈ {auto,gated} and status ($6) ∈
  #       the known status set. The normalizer can't fix a field-shift (the data is
  #       genuinely wrong), so these surface here for a human.
  # (matches repair_registry_rows / monitor checkRegistryInvariant). Log a warning
  # + fire a macOS push notification so a human is alerted. The dashboard surfaces
  # the same condition (see monitor registryHealth).
  BAD_ROWS="$(awk -F'|' '
    /^\|[[:space:]]*[0-9]/ {
      t=$8; gsub(/[[:space:]]/,"",t)
      m=$4; gsub(/^[[:space:]]+|[[:space:]]+$/,"",m)
      s=$6; gsub(/^[[:space:]]+|[[:space:]]+$/,"",s)
      mode_ok = (m=="auto" || m=="gated")
      status_ok = (s=="pending" || s=="running" || s=="awaiting_go" || s=="awaiting_critic" || s=="complete" || s=="failed" || s=="needs_human")
      if (NF!=8 || t!="" || !mode_ok || !status_ok) c++
    }
    END{print c+0}' "$PROJ" 2>/dev/null || echo 0)"
  if [[ "${BAD_ROWS:-0}" -gt 0 ]]; then
    log_rescue "WARNING invariant breach — ${BAD_ROWS} registry row(s) still violate invariant (NF!=8, non-empty trailing field, or mode/status out of domain) after normalize (needs manual fix)"
    if command -v osascript >/dev/null 2>&1; then
      osascript -e "display notification \"${BAD_ROWS} project.md row(s) violate invariant (NF!=8, bad trailing field, or mode/status out of domain) after normalize — manual fix needed\" with title \"orchestrate registry corruption\"" >/dev/null 2>&1 || true
    fi
  fi
fi

# --- 2b. Auto-finalize done-but-running rows (E721) ---
# Safety net for the run-job.sh preflight reaper: Completion is not atomic, so a
# session can finish all phases (and maybe archive the task file) but die before
# flipping the registry row running→complete. Finalize those here too — flip to
# complete + archive (no dup) + delete stale task file. Runs BEFORE the
# stale-running reset so a finished-but-running ghost is completed, not bounced to
# needs_human. Guard on -x, || true (never break rescue). Idempotent.
if [[ -x "$BIN/finalize-completed-tasks.sh" ]]; then
  bash "$BIN/finalize-completed-tasks.sh" "$ROOT" 2>/dev/null || true
fi

# --- 2a-pre. Requeue orphaned 'running' rows (3C1D) ---
# Safety net mirroring run-job.sh's preflight call: a `running` row with no task
# file and no dispatch heartbeat line is orphaned (see requeue-orphaned-running.sh
# header). Runs BEFORE the stale-running reset below so a 300s-stale orphan is
# requeued straight to `pending` instead of waiting out the 1800s no-file-grace
# path to `needs_human`. Guard on -f (not -x): bash executes a script file
# without the executable bit set. || true never breaks rescue.
if [[ -f "$BIN/requeue-orphaned-running.sh" ]]; then
  bash "$BIN/requeue-orphaned-running.sh" "$ROOT" 2>/dev/null || true
fi

# --- 2a-pre2. Detect orphaned 'awaiting_go' rows (4FA5) ---
# Safety net mirroring run-job.sh's preflight call: an approved-but-never-
# materialized `awaiting_go` row (see detect-orphaned-awaiting-go.sh header).
# Never auto-requeues (would bypass an explicit human gate) — only surfaces
# via heartbeat + a one-time desktop notification. Guard on -f, || true never
# breaks rescue.
if [[ -f "$BIN/detect-orphaned-awaiting-go.sh" ]]; then
  bash "$BIN/detect-orphaned-awaiting-go.sh" "$ROOT" 2>/dev/null || true
fi

# --- 2a. Reset stale 'running' tasks to 'needs_human' ---
# A task stuck in 'running' for >STALE_RUNNING_SECS with no completed phase means
# the agent session crashed/wedged without updating the registry. T-4 can't act
# on 'running' tasks, so reset them to 'needs_human' so the next tend cycle
# auto-resolves (all phases complete) or surfaces them for human attention.
# Mirrors run-job.sh:reset_stale_running_tasks (same threshold + ✓-phase guard).
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
    # 527A: phase-progress guard (mirrors run-job.sh). The old check ("any ✓
    # complete phase anywhere in the file ⇒ permanently not a ghost") meant a task
    # whose dispatching session died right after completing phase N-1 of N could
    # never be ghost-reset here either — the grep matched forever regardless of
    # staleness. A FULLY complete file (complete_count >= total_phases) is still an
    # unconditional skip (finalize-completed-tasks.sh's job — defensive guard only).
    # A PARTIALLY complete file falls through to the 19D7 mtime-freshness guard
    # below, same as a zero-progress file.
    r_file="$ROOT/.orchestrate/tasks/${r_id}.md"
    r_complete_count=0; r_total_phases=0
    if [[ -f "$r_file" ]]; then
      # NOTE (mirrors run-job.sh): `grep -c PATTERN FILE` prints "0" to stdout AND
      # exits 1 when the file exists but has zero matches — a naive `|| echo 0`
      # fallback then appends a SECOND "0", corrupting the variable into a
      # two-line "0\n0" that breaks the numeric `-ge` test below. Suppress the
      # fallback's own output and default via parameter expansion instead.
      r_complete_count="$(grep -c '✓ complete' "$r_file" 2>/dev/null || true)"
      r_complete_count="${r_complete_count:-0}"
      r_total_phases="$(grep -oE '^total_phases:[[:space:]]*[0-9]+' "$r_file" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)"
      r_total_phases="${r_total_phases:-0}"
      if [[ "$r_total_phases" -gt 0 && "$r_complete_count" -ge "$r_total_phases" ]]; then
        continue  # fully complete — finalize-completed-tasks.sh's job, not this one
      fi
    fi
    # C829: A510 no-file grace guard (mirrors run-job.sh). A `running` row with NO
    # task file yet is either a genuinely-dead ghost OR a slow-but-alive session
    # still spinning up — unlike the 19D7 case there is no fresh mtime to prove
    # liveness, so only elapsed age can distinguish them. Require the longer
    # NO_FILE_GRACE_SECS before resetting: under grace → skip the reset AND the
    # cg_increment churn bump (a young no-file row is not a re-processing); past
    # grace → fall through and reset as a genuinely-dead ghost like any other.
    if [[ ! -f "$r_file" && "$r_age" -lt "$NO_FILE_GRACE_SECS" ]]; then
      continue  # no task file yet, still within grace — slow-but-alive, not a ghost
    fi
    # 19D7 liveness guard (mirrors run-job.sh): a fresh task-file mtime means an
    # agent is actively writing phase blocks — a live session, not a ghost. Skip
    # the reset on freshness alone so we never churn/park a task about to complete.
    # This is now the ONLY freshness gate for both zero-progress and
    # partial-progress task files.
    if [[ -f "$r_file" ]]; then
      r_mtime="$(date -r "$r_file" +%s 2>/dev/null || echo 0)"
      if [[ "$r_mtime" -gt 0 && $(( NOW_RESET - r_mtime )) -lt "$STALE_RUNNING_SECS" ]]; then
        continue
      fi
    fi
    if [[ "$r_age" -gt "$STALE_RUNNING_SECS" ]]; then
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
      # Churn guard: this stale-running reset is a re-processing of $r_id. Bump the
      # shared counter; if it has churned ${CG_THRESHOLD:-3}× without converging,
      # park it (needs_human + bypass markers) + file an investigation job instead
      # of emitting the re-queue-eligible ghost-reset token. cg_park_if_churned
      # returns 0 only when it actually parked.
      cg_parked_here=0
      if type cg_increment >/dev/null 2>&1; then
        # ED94: skip the churn bump when THIS reset was a transient infra death
        # (agent log shows only a connection error, zero progress) — retried like a
        # C3 one-shot transient, not counted toward the park threshold. Falls back
        # to a bare bump if the wrapper is absent (mirror lag).
        if type cg_increment_unless_transient >/dev/null 2>&1; then
          cg_increment_unless_transient "$r_id" "$r_ts" >/dev/null 2>&1 || true
        else
          cg_increment "$r_id" >/dev/null 2>&1 || true
        fi
        if cg_park_if_churned "$r_id" 2>/dev/null; then
          cg_parked_here=1
          log_rescue "churn-guard parked $r_id after ${CG_THRESHOLD:-3} re-processings (rescue path)"
        fi
      fi
      if [[ "$cg_parked_here" -eq 0 ]]; then
        r_phase_note="${r_age}s stale, rescue"
        [[ "$r_complete_count" -gt 0 ]] && r_phase_note="stale after phase ${r_complete_count}/${r_total_phases:-?}, rescue"
        if [[ "$r_mode" == "auto" ]]; then
          log_rescue "ghost-reset $r_id: running→needs_human (${r_phase_note})"
        else
          log_rescue "reset stale running task $r_id (${r_age}s) → needs_human (gated; not auto-requeued)"
        fi
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
  # awaiting_go is gated/notify-only — kicking tend can never advance it, so it is
  # excluded here too, mirroring tend-need-action.sh (which counts only pending +
  # awaiting_critic + actionable needs_human). Counting it produced a false
  # RECOVERED loop whenever the registry held only gated rows.
  for st in pending running; do
    n="$(awk -F'|' -v st="$st" '
      /^\|/ && $2 !~ /^[[:space:]]*ID[[:space:]]*$/ && $2 !~ /^-+$/ {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6)
        if ($6 == st) n++
      }
      END { print n + 0 }
    ' "$PROJ" 2>/dev/null || echo 0)"
    REGISTRY_ACTIONABLE=$(( REGISTRY_ACTIONABLE + n ))
  done

  # Find the oldest task stuck as pending (not needs_human/running/awaiting_go).
  # Used to detect the "idle-loop" bug: tend fires every 5 min but never executes
  # a registered pending task because tend-need-action.sh transiently returned 0.
  # awaiting_go is excluded — gated rows legitimately wait for a human "go" and
  # must not age into a false stuck-tend recovery.
  NOW="$(date +%s)"
  while IFS='|' read -r _ _id _ _ _ status last_act _; do
    status="${status## }"; status="${status%% }"
    [[ "$status" == "pending" ]] || continue
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
