#!/bin/bash
# Helper script to get Retrace storage root path
# Sources from: RETRACE_STORAGE_ROOT env var > UserDefaults (app settings) > default
#
# Usage: source this script, then use $RETRACE_STORAGE_ROOT
#   source "$(dirname "$0")/_get_storage_root.sh"
#   echo "Storage root: $RETRACE_STORAGE_ROOT"

_get_retrace_storage_root() {
    if [ -n "${RETRACE_STORAGE_ROOT:-}" ]; then
        echo "$RETRACE_STORAGE_ROOT"
    else
        # Try to read from UserDefaults (where app stores custom location)
        local custom_path
        custom_path=$(defaults read io.retrace.app customRetraceDBLocation 2>/dev/null || echo "")
        if [ -n "$custom_path" ]; then
            # Expand tilde if present
            echo "${custom_path/#\~/$HOME}"
        else
            echo "$HOME/Library/Application Support/Retrace"
        fi
    fi
}

# Export for use by sourcing scripts
RETRACE_STORAGE_ROOT="$(_get_retrace_storage_root)"
export RETRACE_STORAGE_ROOT
