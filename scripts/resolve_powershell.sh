#!/usr/bin/env bash

# Return a PowerShell executable for hooks and finish-check without requiring
# a system-wide install. The repository-local path is intentionally ignored.
resolve_powershell_command() {
    local user_home="${HOME:-}"
    local candidate
    local system_pwsh

    if [ -n "${POWERSHELL_COMMAND:-}" ] && [ -x "$POWERSHELL_COMMAND" ]; then
        # The repository-local runtime needs the wrapper to import the built-in
        # management modules when invoked with -NoProfile from a temporary worktree.
        case "$POWERSHELL_COMMAND" in
            */.tools/pwsh/pwsh)
                candidate="$(CDPATH= cd -- "$(dirname -- "$POWERSHELL_COMMAND")/../bin" && pwd)/pwsh"
                if [ -x "$candidate" ]; then
                    printf '%s\n' "$candidate"
                    return 0
                fi
                ;;
        esac
        printf '%s\n' "$POWERSHELL_COMMAND"
        return 0
    fi
    system_pwsh="$(command -v pwsh 2>/dev/null || true)"
    if [ -n "$system_pwsh" ]; then
        case "$system_pwsh" in
            */.tools/pwsh/pwsh)
                candidate="$(CDPATH= cd -- "$(dirname -- "$system_pwsh")/../bin" && pwd)/pwsh"
                if [ -x "$candidate" ]; then
                    printf '%s\n' "$candidate"
                    return 0
                fi
                ;;
        esac
        printf '%s\n' "$system_pwsh"
        return 0
    fi
    if command -v powershell.exe >/dev/null 2>&1; then
        command -v powershell.exe
        return 0
    fi
    for candidate in \
        ".tools/bin/pwsh" \
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
