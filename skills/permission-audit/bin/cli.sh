#!/bin/bash
# Permission-audit CLI entry point
# Delegates to the main audit script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT="$SCRIPT_DIR/permission-audit.sh"

# Pass all arguments through
exec bash "$MAIN_SCRIPT" "$@"
