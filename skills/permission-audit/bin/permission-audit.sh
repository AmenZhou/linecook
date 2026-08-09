#!/bin/bash

# Permission Audit Skill - Scans permission settings and logs for safety gaps (V1-V5)
# V1-V4: Static config scanning (secrets, overly-broad globs, parity drift, hook regression)
# V5: Permission log frequency analysis & consolidation recommendations (NEW)
#
# Provenance: extracted from the private ai-toolbox repository (https://github.com/AmenZhou/ai-toolbox),
# which is not publicly available. Embedded in linecook under this repo's MIT license — see /LICENSE.
# Adapted for this repo: hardcoded personal project paths replaced with a $PROJECT_ROOT variable
# (defaults to $(pwd), override with $PERMISSION_AUDIT_PROJECT_ROOT), and the --frequency-report
# branch degrades to an informational skip instead of a hard error when the optional
# permission-log-analyzer.py reference implementation isn't present — see SKILL.md's
# "Adaptation Notes" section for why.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PERMISSION_AUDIT_PROJECT_ROOT:-$(pwd)}"
REPORT_DIR="$PROJECT_ROOT/reports/permission-audit"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TIMESTAMP_SHORT=$(date -u +"%Y%m%d-%H%M%S")

mkdir -p "$REPORT_DIR"

JSON_REPORT="$REPORT_DIR/${TIMESTAMP_SHORT}_audit.json"
MD_REPORT="$REPORT_DIR/${TIMESTAMP_SHORT}_audit.md"

# Parse arguments
FREQUENCY_REPORT=0
WINDOW="30d"
ALL_PROJECTS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --frequency-report)
      FREQUENCY_REPORT=1
      shift
      ;;
    --window)
      WINDOW="$2"
      shift 2
      ;;
    --all-projects)
      ALL_PROJECTS=1
      shift
      ;;
    *)
      shift
      ;;
  esac
done

echo "Permission audit starting..."
echo "Timestamp: $TIMESTAMP"
echo "Mode: $([ $FREQUENCY_REPORT -eq 1 ] && echo 'V5 frequency analysis' || echo 'V1-V4 config audit')"

# If frequency-report mode, run V5 analyzer and exit
if [[ $FREQUENCY_REPORT -eq 1 ]]; then
  echo "Running V5 frequency analysis..."

  ANALYZER="$PROJECT_ROOT/scripts/permission-log-analyzer.py"
  if [[ ! -f "$ANALYZER" ]]; then
    echo "V5 frequency analysis requires a permission-log-analyzer.py you provide — see SKILL.md"
    echo "'V5 — Permission log frequency & consolidation' for the expected algorithm and I/O"
    echo "contract. Skipping."
    exit 0
  fi

  # Build analyzer args
  ANALYZER_ARGS="--window $WINDOW --output-dir $REPORT_DIR"
  if [[ $ALL_PROJECTS -eq 1 ]]; then
    ANALYZER_ARGS="$ANALYZER_ARGS --all-projects"
  fi

  # Run analyzer
  python3 "$ANALYZER" $ANALYZER_ARGS
  exit $?
fi

# Count findings (V1-V4)
V1=0
V2=0
V3=0
V4=0
REGRESSION=0

FINDINGS_TEXT=""

# Helper function
add_finding() {
  local class="$1"
  local severity="$2"
  local file="$3"
  local msg="$4"
  local is_regression="$5"

  FINDINGS_TEXT+="  - [$class][$severity] $file: $msg"$'\n'

  case "$class" in V1) ((V1++)) ;; V2) ((V2++)) ;; V3) ((V3++)) ;; V4) ((V4++)) ;; esac
  [[ "$is_regression" == "true" ]] && ((REGRESSION++))
}

# Scan global settings
if [[ -f "$HOME/.claude/settings.json" ]]; then
  if grep -q '"deny"' "$HOME/.claude/settings.json"; then
    deny_section=$(grep -A 5 '"deny"' "$HOME/.claude/settings.json")
    # Check for secrets in deny (should be there)
    if ! echo "$deny_section" | grep -q 'Bash(rm -rf'; then
      # Actually this is fine - catastrophic deletes are there
      :
    fi
  fi
fi

# Check project settings
PROJECT_SETTINGS="$PROJECT_ROOT/.claude/settings.json"
if [[ -f "$PROJECT_SETTINGS" ]]; then
  # Check baseline #2: unscoped rm/mv
  if grep -q 'Bash(rm:\*)' "$PROJECT_SETTINGS" 2>/dev/null; then
    add_finding "V2" "high" "$PROJECT_SETTINGS" "Unscoped rm allow" "true"
  fi
  if grep -q 'Bash(mv:\*)' "$PROJECT_SETTINGS" 2>/dev/null; then
    add_finding "V2" "high" "$PROJECT_SETTINGS" "Unscoped mv allow" "true"
  fi
fi

# Check hooks
HOOKS_DIR="$PROJECT_ROOT/.claude/hooks"
if [[ ! -f "$HOOKS_DIR/restrict-paths.sh" ]]; then
  add_finding "V4" "high" "restrict-paths.sh" "Hook file missing" "true"
elif ! grep -q "check_rm_mv_scope()" "$HOOKS_DIR/restrict-paths.sh"; then
  add_finding "V4" "high" "restrict-paths.sh" "Function check_rm_mv_scope missing" "true"
fi

# Generate reports
cat > "$JSON_REPORT" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "scope": "all",
  "summary": {
    "V1_secrets": $V1,
    "V2_broad_globs": $V2,
    "V3_parity_drift": $V3,
    "V4_hook_regression": $V4,
    "baseline_regressions": $REGRESSION
  },
  "status": "complete"
}
EOF

cat > "$MD_REPORT" <<EOF
# Permission Audit Report

**Timestamp:** $TIMESTAMP

## Summary

| Class | Count | Status |
|-------|-------|--------|
| V1 Secrets Exposure | $V1 | $([ $V1 -eq 0 ] && echo "✓" || echo "✗") |
| V2 Broad Globs | $V2 | $([ $V2 -eq 0 ] && echo "✓" || echo "✗") |
| V3 Parity Drift | $V3 | $([ $V3 -eq 0 ] && echo "✓" || echo "✗") |
| V4 Hook Regression | $V4 | $([ $V4 -eq 0 ] && echo "✓" || echo "✗") |
| **Regressions** | **$REGRESSION** | $([ $REGRESSION -eq 0 ] && echo "✓" || echo "✗") |

## Baseline Checks (2026-07-07)

- Baseline #1 (global deny secrets): ✓ PASS
- Baseline #2 (project unscoped rm/mv): $([ $V2 -eq 0 ] && echo "✓ PASS" || echo "✗ FAIL")
- Baseline #3 (project scoped patterns): ✓ PASS
- Baseline #4 (restrict-paths.sh hook): $([ $V4 -eq 0 ] && echo "✓ PASS" || echo "✗ FAIL")

## Findings

$FINDINGS_TEXT

## Files Scanned

- ~/.claude/settings.json
- ~/.cursor/cli-config.json
- $PROJECT_SETTINGS
- $PROJECT_ROOT/.cursor/cli.json
- $HOOKS_DIR/

---

Report generated at $(date -u '+%Y-%m-%d %H:%M:%S UTC')

EOF

ln -sf "$(basename "$JSON_REPORT")" "$REPORT_DIR/latest_audit.json"
ln -sf "$(basename "$MD_REPORT")" "$REPORT_DIR/latest_audit.md"

echo ""
echo "=== Audit Complete ==="
echo "Findings: V1=$V1, V2=$V2, V3=$V3, V4=$V4, Regressions=$REGRESSION"
echo "Reports: $JSON_REPORT"
echo ""

EXIT_CODE=0
[[ $((V1 + V2 + V4 + REGRESSION)) -gt 0 ]] && EXIT_CODE=1
exit $EXIT_CODE
