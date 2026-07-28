#!/usr/bin/env bash
# append-manifest-line.sh — append exactly one well-formed line to orchestrate-history/MANIFEST.md.
#
# Prior tend sessions have repeatedly hand-typed a bracket-timestamp variant
# (`[YYYYMMDD-HHMMSS] ID — summary · project · tags: ... [filename]`) directly
# into MANIFEST.md instead of the canonical pipe-delimited format, because no
# script owned this write path — every other structured-file append
# (update-registry-row.sh for project.md rows, append-phase-log.sh for phase
# logs) has a canonical helper; MANIFEST.md did not. This is that helper.
#
# Canonical line format:
#   YYYY-MM-DD | filename | summary | tag1, tag2, ...
#
# Usage:
#   append-manifest-line.sh <ROOT> <date:YYYY-MM-DD> <filename> <summary> <tags>
#
# - <ROOT>: project root containing orchestrate-history/MANIFEST.md
# - <date>: must be YYYY-MM-DD
# - <filename>: must not contain a literal `|` or newline (rejected — would corrupt column alignment / line count)
# - <summary>: must not contain a literal `|` or newline
# - <tags>: comma-separated tag list (e.g. "orchestrate, bugfix, finalize-completed-tasks"); must not contain `|` or newline
#
# Idempotent-ish: does not dedup by itself — callers that need dedup (e.g. "does
# this filename already have a MANIFEST line?") should grep for the filename
# first. This script only guarantees the line it appends is well-formed.
set -euo pipefail

die() { echo "append-manifest-line.sh: $*" >&2; exit 1; }

[[ $# -eq 5 ]] || die "usage: <ROOT> <date:YYYY-MM-DD> <filename> <summary> <tags>"

ROOT="$1"; DATE="$2"; FILENAME="$3"; SUMMARY="$4"; TAGS="$5"

MANIFEST="$ROOT/orchestrate-history/MANIFEST.md"
[[ -f "$MANIFEST" ]] || die "MANIFEST.md not found at $MANIFEST"

[[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "invalid date '$DATE' — must be YYYY-MM-DD"
[[ -n "$FILENAME" ]] || die "filename must not be empty"
[[ -n "$SUMMARY" ]] || die "summary must not be empty"

for field in "$FILENAME" "$SUMMARY" "$TAGS"; do
  [[ "$field" == *"|"* ]] && die "field contains a literal '|' — would corrupt column alignment: $field"
  [[ "$field" == *$'\n'* ]] && die "field contains a newline — would split into multiple lines: $field"
done

echo "${DATE} | ${FILENAME} | ${SUMMARY} | ${TAGS}" >> "$MANIFEST"
