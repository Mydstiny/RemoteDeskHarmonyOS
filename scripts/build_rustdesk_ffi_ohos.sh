#!/bin/bash
# Build the complete RustDesk FFI dependency chain for HarmonyOS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TARGET_ARCH="${1:-all}"

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

    (
        cd "$PROJECT_DIR/rustdesk_ffi"
        OPUS_LIB_DIR="$OPUS_LIB_DIR" cargo build --release --target "$TARGET"
    )
    nm -g --defined-only "$LIB" | grep -Eq ' rustdesk_get_transfer_status$'
    nm -g --defined-only "$LIB" | grep -Eq ' rustdesk_get_clipboard$'
done

echo "RustDesk FFI build complete for $TARGET_ARCH"
