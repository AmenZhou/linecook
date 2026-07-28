#!/usr/bin/env bash
# followup-dedup.sh — shared (followup_for, kind) pair dedup helpers for
# enqueue-review-and-tests.sh and drain-inbox.sh.
# Sourced by those scripts; not executed directly.

# Extract followup_for and kind from an inbox or task file.
# Prints "followup_for<TAB>kind" or empty if not a followup ticket.
extract_followup_pair() {
  local file="$1"
  local fu kind
  [[ -f "$file" ]] || return 1
  fu="$(grep -m1 -E '^followup_for:[[:space:]]*\S' "$file" 2>/dev/null \
    | sed -E 's/^followup_for:[[:space:]]*//; s/[[:space:]].*//')"
  kind="$(grep -m1 -E '^kind:[[:space:]]*\S' "$file" 2>/dev/null \
    | sed -E 's/^kind:[[:space:]]*//; s/[[:space:]].*//')"
  [[ -n "$fu" && -n "$kind" ]] || return 1
  printf '%s\t%s' "$fu" "$kind"
}

_pair_in_files() {
  local fu="$1" kind="$2"
  shift 2
  local f
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    if grep -qE "^followup_for:[[:space:]]*${fu}([[:space:]]|\$)" "$f" 2>/dev/null \
       && grep -qE "^kind:[[:space:]]*${kind}([[:space:]]|\$)" "$f" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# Returns 0 when the pair already exists anywhere (enqueue dedup — active inbox too).
followup_pair_exists() {
  local root="$1" fu="$2" kind="$3"
  local inbox="$root/.orchestrate/inbox"
  local gated="$inbox/gated"
  local processed="$inbox/processed"
  local tasks="$root/.orchestrate/tasks"
  local history="$root/orchestrate-history"
  local f

  shopt -s nullglob
  local search=( \
    "$inbox"/*.md "$gated"/*.md "$processed"/*.md \
    "$tasks"/*.md "$history"/*.md )
  shopt -u nullglob

  _pair_in_files "$fu" "$kind" "${search[@]}"
}

# Returns 0 when the pair was already drained or completed (drain-inbox dedup).
# Checks orchestrate-history archives and inbox/processed/ only — a prior drain
# or a completed follow-up task must not be re-registered under a new ID.
followup_pair_already_satisfied() {
  local root="$1" fu="$2" kind="$3"
  local processed="$root/.orchestrate/inbox/processed"
  local history="$root/orchestrate-history"
  local f

  shopt -s nullglob
  local hist=( "$history"/*.md )
  local proc=( "$processed"/*.md )
  shopt -u nullglob

  _pair_in_files "$fu" "$kind" "${hist[@]}" && return 0
  _pair_in_files "$fu" "$kind" "${proc[@]}"
}
