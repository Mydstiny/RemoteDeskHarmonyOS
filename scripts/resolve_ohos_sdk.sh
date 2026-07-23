#!/usr/bin/env bash

# Resolve the DevEco/OpenHarmony SDK without requiring a machine-specific path.
resolve_ohos_sdk() {
    user_home="${HOME:-}"

    if [ -n "${DEVECO_SDK_HOME:-}" ]; then
        if try_ohos_sdk "$DEVECO_SDK_HOME"; then return 0; fi
    fi
    if [ -n "${OHOS_SDK_HOME:-}" ]; then
        if try_ohos_sdk "$OHOS_SDK_HOME"; then return 0; fi
    fi

    case "$(uname -s 2>/dev/null || printf '%s' unknown)" in
        Darwin)
            if try_ohos_sdk "/Applications/DevEco-Studio.app/Contents/sdk"; then return 0; fi
            if [ -n "$user_home" ]; then
                if try_ohos_sdk "$user_home/Library/Huawei/DevEco Studio/sdk"; then return 0; fi
                if try_ohos_sdk "$user_home/Library/DevEco-Studio/sdk"; then return 0; fi
            fi
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

try_ohos_sdk() {
    candidate="$1"
    candidate="$(printf '%s' "$candidate" | sed 's#\\\\#/#g')"
    if [ -f "$candidate/default/openharmony/native/build/cmake/ohos.toolchain.cmake" ]; then
        printf '%s\n' "$candidate"
        return 0
    fi
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
