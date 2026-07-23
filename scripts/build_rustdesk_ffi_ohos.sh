#!/bin/bash
# Build the complete RustDesk FFI dependency chain for HarmonyOS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
. "$SCRIPT_DIR/resolve_ohos_sdk.sh"
TARGET_ARCH="${1:-all}"
OHOS_SDK="$(resolve_ohos_sdk)"
OHOS_NATIVE="$(ohos_native_root "$OHOS_SDK")"
OHOS_LLVM="$OHOS_NATIVE/llvm/bin"
OHOS_SYSROOT="$OHOS_NATIVE/sysroot"

CARGO_BIN="${CARGO:-}"
if [ -z "$CARGO_BIN" ]; then
    CARGO_BIN="$(command -v cargo 2>/dev/null || true)"
fi
if [ -z "$CARGO_BIN" ] && command -v rustup >/dev/null 2>&1; then
    CARGO_BIN="$(rustup which cargo 2>/dev/null || true)"
fi
if [ -z "$CARGO_BIN" ]; then
    echo "ERROR: cargo is not available. Install Rust or source scripts/macos_env.sh."
    exit 1
fi

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
    TARGET_ENV_UPPER="$(printf '%s' "$TARGET_ENV" | tr '[:lower:]' '[:upper:]')"
    TARGET_CC="$(find_ohos_tool "$OHOS_LLVM" clang || true)"
    TARGET_CXX="$(find_ohos_tool "$OHOS_LLVM" clang++ || true)"
    TARGET_AR="$(find_ohos_tool "$OHOS_LLVM" llvm-ar || true)"
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
            "CARGO_TARGET_${TARGET_ENV_UPPER}_LINKER=$TARGET_CXX" \
            "CARGO_TARGET_${TARGET_ENV_UPPER}_RUSTFLAGS=-C link-arg=--target=$CLANG_TARGET -C link-arg=--sysroot=$OHOS_SYSROOT" \
            OPUS_LIB_DIR="$OPUS_LIB_DIR" \
            "$CARGO_BIN" build --release --target "$TARGET"
    )
    # Do not use grep -q here: with pipefail, grep can close the pipe after
    # the first match and make nm exit with SIGPIPE (141) on large archives.
    require_symbol() {
        symbol="$1"
        if ! nm -g --defined-only "$LIB" | grep -E " $symbol\$" >/dev/null; then
            echo "ERROR: required symbol missing from $LIB: $symbol" >&2
            exit 1
        fi
    }
    require_symbol rustdesk_get_transfer_status
    require_symbol rustdesk_get_clipboard
    require_symbol rustdesk_get_display_snapshot
    require_symbol rustdesk_change_display_resolution
    require_symbol rustdesk_send_touch_scale
    require_symbol rustdesk_send_touch_pan
done

echo "RustDesk FFI build complete for $TARGET_ARCH"
