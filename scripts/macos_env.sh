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

ohos_sdk_root="$(resolve_ohos_sdk)"
harmonyos_sdk_root="$(resolve_harmonyos_sdk)"
ohos_native="$(ohos_native_root "$ohos_sdk_root")"
export DEVECO_SDK_HOME="$harmonyos_sdk_root"
export OHOS_SDK_HOME="$ohos_sdk_root"
export OHOS_NATIVE_HOME="$ohos_native"

if [ -d "$harmonyos_sdk_root/../tools/node" ]; then
    deveco_root="$(CDPATH= cd -- "$harmonyos_sdk_root/.." && pwd)"
else
    deveco_root="/Applications/DevEco-Studio.app/Contents"
fi
prepend_path() {
    if [ -d "$1" ]; then
        case ":${PATH:-}:" in
            *":$1:"*) ;;
            *) PATH="$1:${PATH:-}" ;;
        esac
    fi
}

# DevEco bundles a JDK used by Hvigor, but it is not always registered with
# macOS Java discovery. Prefer an explicit user JAVA_HOME, then the bundled JBR.
if [ -z "${JAVA_HOME:-}" ] || [ ! -x "$JAVA_HOME/bin/java" ]; then
    if [ -x "$deveco_root/jbr/Contents/Home/bin/java" ]; then
        JAVA_HOME="$deveco_root/jbr/Contents/Home"
    elif [ -x /usr/libexec/java_home ]; then
        JAVA_HOME="$(/usr/libexec/java_home 2>/dev/null || true)"
    fi
fi
if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
    export JAVA_HOME
    prepend_path "$JAVA_HOME/bin"
fi

prepend_path "$deveco_root/tools/node/bin"
prepend_path "$deveco_root/tools/hvigor/bin"
prepend_path "$deveco_root/tools/ohpm/bin"
# DevEco's hdc is shipped in the SDK toolchains directory, not in the
# application-level tools directory. Prefer the full HarmonyOS SDK hdc used by
# DevEco, while keeping the standalone API 23 toolchain available as a fallback.
harmonyos_toolchains="$harmonyos_sdk_root/default/openharmony/toolchains"
ohos_toolchains="$ohos_sdk_root/toolchains"
prepend_path "$ohos_toolchains"
prepend_path "$harmonyos_toolchains"
prepend_path "$ohos_native/llvm/bin"
prepend_path "$ohos_native/build-tools/cmake/bin"
export CC_aarch64_unknown_linux_ohos="$ohos_native/llvm/bin/clang"
export CXX_aarch64_unknown_linux_ohos="$ohos_native/llvm/bin/clang++"
export AR_aarch64_unknown_linux_ohos="$ohos_native/llvm/bin/llvm-ar"
export CFLAGS_aarch64_unknown_linux_ohos="--target=aarch64-linux-ohos --sysroot=$ohos_native/sysroot -D__MUSL__ -fPIC"
export CXXFLAGS_aarch64_unknown_linux_ohos="$CFLAGS_aarch64_unknown_linux_ohos"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER="$ohos_native/llvm/bin/clang++"
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_RUSTFLAGS="-C link-arg=--target=aarch64-linux-ohos -C link-arg=--sysroot=$ohos_native/sysroot"
export CC_x86_64_unknown_linux_ohos="$ohos_native/llvm/bin/clang"
export CXX_x86_64_unknown_linux_ohos="$ohos_native/llvm/bin/clang++"
export AR_x86_64_unknown_linux_ohos="$ohos_native/llvm/bin/llvm-ar"
export CFLAGS_x86_64_unknown_linux_ohos="--target=x86_64-linux-ohos --sysroot=$ohos_native/sysroot -D__MUSL__ -fPIC"
export CXXFLAGS_x86_64_unknown_linux_ohos="$CFLAGS_x86_64_unknown_linux_ohos"
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_OHOS_LINKER="$ohos_native/llvm/bin/clang++"
export CARGO_TARGET_X86_64_UNKNOWN_LINUX_OHOS_RUSTFLAGS="-C link-arg=--target=x86_64-linux-ohos -C link-arg=--sysroot=$ohos_native/sysroot"
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
printf 'Mac toolchain environment: OHOS_SDK_HOME=%s\n' "$OHOS_SDK_HOME"
printf 'Mac toolchain environment: node=%s hvigorw=%s ohpm=%s\n' \
    "$(command -v node 2>/dev/null || printf '%s' unavailable)" \
    "$(command -v hvigorw 2>/dev/null || printf '%s' unavailable)" \
    "$(command -v ohpm 2>/dev/null || printf '%s' unavailable)"
printf 'Mac toolchain environment: hdc=%s\n' \
    "$(command -v hdc 2>/dev/null || printf '%s' unavailable)"
printf 'Mac toolchain environment: java=%s JAVA_HOME=%s\n' \
    "$(command -v java 2>/dev/null || printf '%s' unavailable)" \
    "${JAVA_HOME:-unset}"
printf 'Mac toolchain environment: cargo=%s rustc=%s\n' \
    "$(command -v cargo 2>/dev/null || printf '%s' unavailable)" \
    "$(command -v rustc 2>/dev/null || printf '%s' unavailable)"
if ! command -v pwsh >/dev/null 2>&1 && ! command -v powershell.exe >/dev/null 2>&1; then
    printf '%s\n' 'Mac toolchain environment: pwsh is unavailable; install PowerShell 7 or set POWERSHELL_COMMAND.' >&2
fi
