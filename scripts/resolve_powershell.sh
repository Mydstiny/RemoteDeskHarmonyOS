#!/usr/bin/env bash

# Return a PowerShell executable for hooks and finish-check without requiring
# a system-wide install. The repository-local path is intentionally ignored.
resolve_powershell_command() {
    local user_home="${HOME:-}"
    local candidate

    if [ -n "${POWERSHELL_COMMAND:-}" ] && [ -x "$POWERSHELL_COMMAND" ]; then
        printf '%s\n' "$POWERSHELL_COMMAND"
        return 0
    fi
    if command -v pwsh >/dev/null 2>&1; then
        command -v pwsh
        return 0
    fi
    if command -v powershell.exe >/dev/null 2>&1; then
        command -v powershell.exe
        return 0
    fi
    for candidate in \
        ".tools/pwsh/pwsh" \
        "/opt/homebrew/bin/pwsh" \
        "/usr/local/bin/pwsh" \
        "$user_home/.local/bin/pwsh" \
        "$user_home/.dotnet/tools/pwsh"; do
        case "$candidate" in
            .tools/*) candidate="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' .)/$candidate" ;;
        esac
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}
