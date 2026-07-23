#!/usr/bin/env bash

# Resolve the DevEco/OpenHarmony SDK without requiring a machine-specific path.
resolve_ohos_sdk() {
    user_home="${HOME:-}"

    if [ -n "${OHOS_SDK_HOME:-}" ]; then
        if try_ohos_sdk "$OHOS_SDK_HOME"; then return 0; fi
    fi
    if [ -n "${DEVECO_SDK_HOME:-}" ]; then
        if try_ohos_sdk "$DEVECO_SDK_HOME"; then return 0; fi
    fi

    case "$(uname -s 2>/dev/null || printf '%s' unknown)" in
        Darwin)
            if [ -n "$user_home" ]; then
                if try_ohos_sdk "$user_home/Library/OpenHarmony/Sdk"; then return 0; fi
                if try_ohos_sdk "$user_home/Library/Huawei/DevEco Studio/sdk"; then return 0; fi
                if try_ohos_sdk "$user_home/Library/DevEco-Studio/sdk"; then return 0; fi
            fi
            if try_ohos_sdk "/Applications/DevEco-Studio.app/Contents/sdk"; then return 0; fi
            ;;
        *)
            if try_ohos_sdk "C:/Program Files/Huawei/DevEco Studio/sdk"; then return 0; fi
            if try_ohos_sdk "/c/Program Files/Huawei/DevEco Studio/sdk"; then return 0; fi
            ;;
    esac

    printf '%s\n' 'Unable to locate a DevEco/OpenHarmony SDK.' >&2
    printf '%s\n' 'Set DEVECO_SDK_HOME or OHOS_SDK_HOME to the SDK directory.' >&2
    return 1
}

# Resolve the full DevEco/HarmonyOS SDK used by Hvigor for projects whose
# product runtimeOS is HarmonyOS. This is distinct from the standalone
# OpenHarmony API SDK used by the native cross-compilers.
resolve_harmonyos_sdk() {
    user_home="${HOME:-}"

    if [ -n "${DEVECO_SDK_HOME:-}" ]; then
        if try_harmonyos_sdk "$DEVECO_SDK_HOME"; then return 0; fi
    fi

    case "$(uname -s 2>/dev/null || printf '%s' unknown)" in
        Darwin)
            if [ -n "$user_home" ]; then
                if try_harmonyos_sdk "$user_home/Library/Huawei/DevEco Studio/sdk"; then return 0; fi
                if try_harmonyos_sdk "$user_home/Library/DevEco-Studio/sdk"; then return 0; fi
            fi
            if try_harmonyos_sdk "/Applications/DevEco-Studio.app/Contents/sdk"; then return 0; fi
            ;;
        *)
            if try_harmonyos_sdk "C:/Program Files/Huawei/DevEco Studio/sdk"; then return 0; fi
            if try_harmonyos_sdk "/c/Program Files/Huawei/DevEco Studio/sdk"; then return 0; fi
            ;;
    esac

    printf '%s\n' 'Unable to locate a full DevEco/HarmonyOS SDK.' >&2
    printf '%s\n' 'Set DEVECO_SDK_HOME to the DevEco SDK directory.' >&2
    return 1
}

try_ohos_sdk() {
    candidate="$1"
    candidate="$(printf '%s' "$candidate" | sed 's#\\\\#/#g')"
    if [ -f "$candidate/default/openharmony/native/build/cmake/ohos.toolchain.cmake" ]; then
        printf '%s\n' "$candidate"
        return 0
    fi
    if has_ohos_native_root "$candidate/native"; then
        printf '%s\n' "$candidate"
        return 0
    fi
    if has_ohos_native_root "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
    fi
    for api_dir in "$candidate"/*; do
        [ -d "$api_dir" ] || continue
        api_name="${api_dir##*/}"
        case "$api_name" in
            ''|*[!0-9]*) continue ;;
        esac
        if has_ohos_native_root "$api_dir/native"; then
            printf '%s\n' "$api_dir"
            return 0
        fi
    done
    return 1
}

try_harmonyos_sdk() {
    candidate="$1"
    candidate="$(printf '%s' "$candidate" | sed 's#\\\\#/#g')"
    if [ -f "$candidate/default/sdk-pkg.json" ] && [ -d "$candidate/default/hms" ]; then
        printf '%s\n' "$candidate"
        return 0
    fi
    return 1
}

has_ohos_native_root() {
    native_root="$1"
    [ -f "$native_root/build/cmake/ohos.toolchain.cmake" ] &&
        [ -d "$native_root/llvm" ] &&
        [ -d "$native_root/sysroot" ]
}

ohos_native_root() {
    sdk_root="$1"
    if [ -d "$sdk_root/default/openharmony/native" ] &&
        [ -f "$sdk_root/default/openharmony/native/build/cmake/ohos.toolchain.cmake" ]; then
        printf '%s\n' "$sdk_root/default/openharmony/native"
        return 0
    fi
    if has_ohos_native_root "$sdk_root/native"; then
        printf '%s\n' "$sdk_root/native"
        return 0
    fi
    printf '%s\n' "Unable to locate OpenHarmony native SDK under: $sdk_root" >&2
    return 1
}

find_ohos_tool() {
    local llvm_dir="$1"
    local tool_name="$2"
    local candidate
    for candidate in "$llvm_dir/$tool_name" "$llvm_dir/$tool_name.exe"; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

sha256_file() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        printf '%s\n' 'Neither sha256sum nor shasum is available.' >&2
        return 1
    fi
}

jobs_count() {
    if command -v nproc >/dev/null 2>&1; then
        nproc
    elif command -v sysctl >/dev/null 2>&1; then
        sysctl -n hw.logicalcpu 2>/dev/null || printf '%s\n' 4
    else
        printf '%s\n' 4
    fi
}
