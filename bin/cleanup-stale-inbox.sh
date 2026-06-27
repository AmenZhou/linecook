#!/usr/bin/env bash
# cleanup-stale-inbox.sh — T-1 stale inbox auto-cleanup before tend NEED_ACTION scan
# Moves root inbox duplicates and registry-complete leftovers to processed/;
# removes stale task files for complete registry rows.
set -euo pipefail

ROOT="${1:-.}"
INBOX="$ROOT/.orchestrate/inbox"
PROCESSED="$INBOX/processed"
PROJ="$ROOT/.orchestrate/project.md"
HEARTBEAT="$ROOT/.orchestrate/logs/heartbeat.log"
TASKS="$ROOT/.orchestrate/tasks"

mkdir -p "$PROCESSED"

log_cleanup() {
  local msg="$1"
  mkdir -p "$(dirname "$HEARTBEAT")"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] tend — stale inbox cleanup: $msg" >>"$HEARTBEAT"
}

# Collect complete registry task IDs (table rows only)
complete_ids=()
if [[ -f "$PROJ" ]]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^\| ]] || continue
    [[ "$line" =~ \|[[:space:]]*complete[[:space:]]*\| ]] || continue
    id="$(echo "$line" | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}')"
    [[ -n "$id" && "$id" != "ID" && "$id" != ----* ]] && complete_ids+=("$id")
  done <"$PROJ"
fi

is_complete_id() {
  local needle="$1"
  for id in "${complete_ids[@]}"; do
    [[ "$id" == "$needle" ]] && return 0
  done
  return 1
}

extract_task_ids() {
  local file="$1"
  grep -oE 'Task ID: [0-9]{8}(-inbox-[A-Z0-9]+|[0-9]{6}-[0-9]+)' "$file" 2>/dev/null | sed 's/Task ID: //' || true
  grep -oE '^processed_as: [0-9]{8}(-inbox-[A-Z0-9]+|[0-9]{6}-[0-9]+)' "$file" 2>/dev/null | sed 's/processed_as: //' || true
  grep -oE '20[0-9]{5}(-inbox-[A-Z0-9]+|[0-9]{6}-[0-9]+)' "$file" 2>/dev/null || true
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

# Top-level inbox/*.md only (not gated/ or processed/)
for f in "$INBOX"/*.md; do
  [[ -f "$f" ]] || continue

  if grep -qE '^deferred_at:' "$f" 2>/dev/null; then continue; fi

  base="$(basename "$f")"

  if [[ -f "$PROCESSED/$base" ]]; then
    move_to_processed "$f"
    log_cleanup "moved duplicate $base (processed/ copy exists)"
    continue
  fi

  if grep -qE '^processed_as:' "$f" 2>/dev/null; then
    move_to_processed "$f"
    log_cleanup "moved processed_as marker $base"
    continue
  fi

  stale=0
  while IFS= read -r tid; do
    if [[ -z "$tid" ]]; then continue; fi
    if is_complete_id "$tid"; then
      move_to_processed "$f"
      log_cleanup "moved registry-complete $base (task $tid)"
      stale=1
      break
    fi
  done < <(extract_task_ids "$f")
  if [[ "$stale" -eq 1 ]]; then continue; fi
done

# Remove stale task files whose registry row is already complete
if [[ -d "$TASKS" ]]; then
  for tf in "$TASKS"/*.md; do
    [[ -f "$tf" ]] || continue
    tid="$(basename "$tf" .md)"
    if is_complete_id "$tid"; then
      rm -f "$tf"
      log_cleanup "removed stale task file $tid.md (registry complete)"
    fi
  done
fi
