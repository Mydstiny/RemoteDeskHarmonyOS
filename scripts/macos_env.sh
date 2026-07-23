#!/usr/bin/env bash

if [ -f "${PWD:-.}/scripts/resolve_ohos_sdk.sh" ]; then
    script_dir="${PWD}/scripts"
elif [ -n "${BASH_VERSION:-}" ]; then
    script_name="${BASH_SOURCE[0]}"
    script_dir="$(CDPATH= cd -- "$(dirname -- "$script_name")" && pwd)"
else
    script_name="$0"
    script_dir="$(CDPATH= cd -- "$(dirname -- "$script_name")" && pwd)"
fi

# This file is meant to be sourced from a Mac shell:
#   source scripts/macos_env.sh
. "$script_dir/resolve_ohos_sdk.sh"

sdk_root="$(resolve_ohos_sdk)"
export DEVECO_SDK_HOME="$sdk_root"
export OHOS_SDK_HOME="$sdk_root"

deveco_root="$(CDPATH= cd -- "$sdk_root/.." && pwd)"
prepend_path() {
    if [ -d "$1" ]; then
        case ":${PATH:-}:" in
            *":$1:"*) ;;
            *) PATH="$1:${PATH:-}" ;;
        esac
    fi
}

prepend_path "$deveco_root/tools/node/bin"
prepend_path "$deveco_root/tools/hvigor/bin"
prepend_path "$deveco_root/tools/ohpm/bin"
prepend_path "$sdk_root/default/openharmony/native/llvm/bin"
prepend_path "$sdk_root/default/openharmony/native/build-tools/cmake/bin"
local_pwsh_wrapper="$script_dir/../.tools/bin/pwsh"
local_pwsh="$script_dir/../.tools/pwsh/pwsh"
if [ -x "$local_pwsh_wrapper" ]; then
    prepend_path "$script_dir/../.tools/bin"
    export POWERSHELL_COMMAND="$local_pwsh_wrapper"
elif [ -x "$local_pwsh" ]; then
    prepend_path "$script_dir/../.tools/pwsh"
    export POWERSHELL_COMMAND="$local_pwsh"
fi

if command -v rustup >/dev/null 2>&1; then
    rust_cargo="$(rustup which cargo 2>/dev/null || true)"
    if [ -n "$rust_cargo" ]; then
        prepend_path "$(dirname -- "$rust_cargo")"
    fi
fi
export PATH

printf 'Mac toolchain environment: DEVECO_SDK_HOME=%s\n' "$DEVECO_SDK_HOME"
printf 'Mac toolchain environment: node=%s hvigorw=%s ohpm=%s\n' \
    "$(command -v node 2>/dev/null || printf '%s' unavailable)" \
    "$(command -v hvigorw 2>/dev/null || printf '%s' unavailable)" \
    "$(command -v ohpm 2>/dev/null || printf '%s' unavailable)"
printf 'Mac toolchain environment: cargo=%s rustc=%s\n' \
    "$(command -v cargo 2>/dev/null || printf '%s' unavailable)" \
    "$(command -v rustc 2>/dev/null || printf '%s' unavailable)"
if ! command -v pwsh >/dev/null 2>&1 && ! command -v powershell.exe >/dev/null 2>&1; then
    printf '%s\n' 'Mac toolchain environment: pwsh is unavailable; install PowerShell 7 or set POWERSHELL_COMMAND.' >&2
fi
