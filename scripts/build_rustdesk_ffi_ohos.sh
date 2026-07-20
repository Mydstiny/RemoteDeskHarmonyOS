#!/bin/bash
# Build the complete RustDesk FFI dependency chain for HarmonyOS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TARGET_ARCH="${1:-all}"
OHOS_SDK="${DEVECO_SDK_HOME:-C:/Program Files/Huawei/DevEco Studio/sdk}"
OHOS_LLVM="$OHOS_SDK/default/openharmony/native/llvm/bin"
OHOS_SYSROOT="$OHOS_SDK/default/openharmony/native/sysroot"

case "$TARGET_ARCH" in
    arm64|arm64-v8a)
        ABIS=("arm64-v8a:aarch64-unknown-linux-ohos")
        OPUS_TARGET="arm64-v8a"
        ;;
    x86_64)
        ABIS=("x86_64:x86_64-unknown-linux-ohos")
        OPUS_TARGET="x86_64"
        ;;
    all)
        ABIS=("arm64-v8a:aarch64-unknown-linux-ohos" "x86_64:x86_64-unknown-linux-ohos")
        OPUS_TARGET="all"
        ;;
    *)
        echo "Usage: $0 [arm64-v8a|x86_64|all]"
        exit 1
        ;;
esac

bash "$SCRIPT_DIR/build_opus_ohos.sh" "$OPUS_TARGET"

for ABI_TARGET in "${ABIS[@]}"; do
    ABI="${ABI_TARGET%%:*}"
    TARGET="${ABI_TARGET##*:}"
    OPUS_LIB_DIR="$PROJECT_DIR/libs/opus-ohos/$ABI"
    LIB="$PROJECT_DIR/rustdesk_ffi/target/$TARGET/release/librustdesk_ffi.a"
    TARGET_ENV="${TARGET//-/_}"
    TARGET_CC="$OHOS_LLVM/clang.exe"
    TARGET_CXX="$OHOS_LLVM/clang++.exe"
    TARGET_AR="$OHOS_LLVM/llvm-ar.exe"
    if [ "$ABI" = "arm64-v8a" ]; then
        CLANG_TARGET="aarch64-linux-ohos"
    else
        CLANG_TARGET="x86_64-linux-ohos"
    fi
    TARGET_CFLAGS="--target=$CLANG_TARGET '--sysroot=$OHOS_SYSROOT' -D__MUSL__ -fPIC"

    if [ ! -f "$TARGET_CC" ] || [ ! -f "$TARGET_CXX" ] || [ ! -f "$TARGET_AR" ]; then
        echo "ERROR: OHOS target toolchain is incomplete for $TARGET under $OHOS_LLVM"
        exit 1
    fi

    (
        cd "$PROJECT_DIR/rustdesk_ffi"
        env \
            "CC_${TARGET_ENV}=$TARGET_CC" \
            "CXX_${TARGET_ENV}=$TARGET_CXX" \
            "AR_${TARGET_ENV}=$TARGET_AR" \
            "CFLAGS_${TARGET_ENV}=$TARGET_CFLAGS" \
            "CXXFLAGS_${TARGET_ENV}=$TARGET_CFLAGS" \
            CC_SHELL_ESCAPED_FLAGS=1 \
            OPUS_LIB_DIR="$OPUS_LIB_DIR" \
            cargo build --release --target "$TARGET"
    )
    nm -g --defined-only "$LIB" | grep -Eq ' rustdesk_get_transfer_status$'
    nm -g --defined-only "$LIB" | grep -Eq ' rustdesk_get_clipboard$'
done

echo "RustDesk FFI build complete for $TARGET_ARCH"
