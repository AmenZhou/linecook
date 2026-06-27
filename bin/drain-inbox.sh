#!/usr/bin/env bash
# drain-inbox.sh — T-2 inbox drain (bash): register in project.md, mv to processed/
# Processes inbox/gated/ first, then root inbox/*.md. Skips deferred_at files.
set -euo pipefail

ROOT="${1:-.}"
INBOX="$ROOT/.orchestrate/inbox"
GATED="$INBOX/gated"
PROCESSED="$INBOX/processed"
PROJ="$ROOT/.orchestrate/project.md"
HEARTBEAT="$ROOT/.orchestrate/logs/heartbeat.log"

mkdir -p "$PROCESSED" "$(dirname "$HEARTBEAT")"

log_inbox() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" >>"$HEARTBEAT"
}

ensure_project_md() {
  if [[ -f "$PROJ" ]]; then
    return 0
  fi
  local name
  name="$(basename "$ROOT")"
  cat >"$PROJ" <<EOF
# Orchestrate — $name
last_updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

## Shared Context

## Task Registry
| ID | summary | mode | current_phase | status | last_activity |
|----|---------|------|---------------|--------|---------------|
EOF
}

registry_has_id() {
  local id="$1"
  grep -qF "| $id |" "$PROJ" 2>/dev/null
}

gen_task_id() {
  local file="$1"
  local base prefix slug n=0
  base="$(basename "$file" .md)"
  prefix="$(date +%Y%m%d)-inbox-"
  if command -v md5 >/dev/null 2>&1; then
    slug="$(printf '%s' "$base" | md5 -q | cut -c1-4 | tr '[:lower:]' '[:upper:]')"
  else
    slug="$(printf '%s' "$base" | cksum | awk '{print $1}' | tail -c 5)"
  fi
  local id="${prefix}${slug}"
  while registry_has_id "$id"; do
    n=$(( n + 1 ))
    id="${prefix}${slug}${n}"
  done
  printf '%s' "$id"
}

extract_title() {
  local file="$1"
  local title
  title="$(grep -m1 '^# ' "$file" 2>/dev/null | sed 's/^# //' || true)"
  if [[ -z "$title" ]]; then
    title="$(basename "$file" .md)"
  fi
  title="${title//|/-}"
  printf '%.100s' "$title"
}

# Risky-op patterns (Gating Criteria). Scanned across the whole task file so a
# risky op described in Goal, Context, or Acceptance Criteria is caught.
RISKY_OP_RE='kubectl (apply|scale|delete|patch|rollout)|INSERT |UPDATE |DELETE |DROP |ALTER |TRUNCATE|rm -rf|rm -f|git push --force|force.push|force-push|delete branch|branch deletion|send email|post to slack|trigger deploy|deploy pipeline'

has_gate_reason() {
  # Explicit human override: a non-empty `gate_reason:` line forces a gate.
  grep -qE '^gate_reason:[[:space:]]*\S' "$1" 2>/dev/null
}

file_has_risky_op() {
  grep -qiE "$RISKY_OP_RE" "$1" 2>/dev/null
}

# Gating is risk-based, not location-based. A file under gated/ or marked
# `mode: gated` is only a hint — it gates only when it carries an explicit
# `gate_reason:` line OR its content describes a genuine risky op. Safe tasks
# (e.g. inbox-log-analyzer enhancements) are de-gated to auto so the tend job
# can run them without waiting for a human "go".
inbox_mode_for() {
  local file="$1"
  if has_gate_reason "$file"; then
    echo gated
    return
  fi
  if file_has_risky_op "$file"; then
    echo gated
    return
  fi
  echo auto
}

status_for_mode() {
  local mode="$1"
  if [[ "$mode" == gated ]]; then
    echo awaiting_go
  else
    echo pending
  fi
}

append_registry_row() {
  local id="$1" summary="$2" mode="$3" status="$4" iso="$5"
  local row="| $id | $summary | $mode | 1 | $status | $iso |"
  if grep -q '^## Task Registry' "$PROJ"; then
    local last
    last="$(grep -n '^|' "$PROJ" | tail -1 | cut -d: -f1)"
    if [[ -n "$last" ]]; then
      # macOS sed: insert after last table row
      sed -i '' "${last}a\\
${row}
" "$PROJ"
    else
      echo "$row" >>"$PROJ"
    fi
  else
    echo "$row" >>"$PROJ"
  fi
  sed -i '' "s/^last_updated:.*/last_updated: $iso/" "$PROJ" 2>/dev/null || true
}

move_to_processed() {
  local src="$1"
  local base dest
  base="$(basename "$src")"
  dest="$PROCESSED/$base"
  if [[ -f "$dest" ]]; then
    if cmp -s "$src" "$dest" 2>/dev/null; then
      rm -f "$src"
    else
      mv -f "$src" "$dest"
    fi
  else
    mv -f "$src" "$dest"
  fi
}

drain_file() {
  local file="$1"
  local rel="$2"

  [[ -f "$file" ]] || return 1
  grep -qE '^deferred_at:' "$file" 2>/dev/null && return 1

  local base processed_path
  base="$(basename "$file")"
  processed_path="$PROCESSED/$base"
  if [[ -f "$processed_path" ]] && cmp -s "$file" "$processed_path" 2>/dev/null; then
    rm -f "$file"
    return 1
  fi

  ensure_project_md

  local iso id summary mode status
  iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  id="$(gen_task_id "$file")"
  summary="$(extract_title "$file")"
  mode="$(inbox_mode_for "$file")"
  status="$(status_for_mode "$mode")"

  append_registry_row "$id" "$summary" "$mode" "$status" "$iso"
  move_to_processed "$file"

  if [[ "$mode" == gated ]]; then
    log_inbox "inbox — registered (gated) \"$summary\" from $rel"
  elif [[ "$rel" == gated/* ]]; then
    log_inbox "inbox — de-gated \"$summary\" (no risky op) from $rel"
  else
    log_inbox "inbox — registered \"$summary\" from $rel"
  fi
  return 0
}

DRAINED=0
ensure_project_md

if [[ -d "$GATED" ]]; then
  for f in "$GATED"/*.md; do
    [[ -f "$f" ]] || continue
    if drain_file "$f" "gated/$(basename "$f")"; then
      DRAINED=$(( DRAINED + 1 ))
    fi
  done
fi

for f in "$INBOX"/*.md; do
  [[ -f "$f" ]] || continue
  if drain_file "$f" "$(basename "$f")"; then
    DRAINED=$(( DRAINED + 1 ))
  fi
done

echo "DRAINED=$DRAINED" >&2
