#!/bin/bash
# =============================================================================
# build_freerdp_ohos.sh — FreeRDP 3.x OHOS 交叉编译脚本
#
# 在 Windows (Git Bash)、macOS 或 Linux 上运行。
# 需要 OHOS SDK (DevEco Studio) 和 CMake + Ninja。
#
# 输出:
#   build/freerdp-ohos/libs/<arch>/libfreerdp3.a
#   build/freerdp-ohos/libs/<arch>/libwinpr3.a
#   build/freerdp-ohos/libs/<arch>/libfreerdp-client-channels.a
#   libs/freerdp-ohos/<arch>/ 同步一份给 DevEco/IDE clean 后继续使用
#
# 用法:
#   export DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk"
#   ./scripts/build_freerdp_ohos.sh [arm64|x86_64|all]
#
# 可复现性复核可为两次 clean build 分别设置绝对路径：
#   REMOTEDESK_FREERDP_WORK_DIR、REMOTEDESK_FREERDP_OUTPUT_DIR、
#   REMOTEDESK_FREERDP_PREBUILT_DIR。可选的
#   REMOTEDESK_FREERDP_EXPECTED_REVISION 会在编译前锁定源码 revision。
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FREERDP_SRC="$PROJECT_DIR/freerdp"
FREERDP_BASE_REVISION="dae8276ac7361b8d14f7b87d41163fe03dbb944e"
FREERDP_PATCHED_TREE="54cc9b12e3040bba73773a5439d4f8023d46ac7a"
FREERDP_PATCH_DIR="$PROJECT_DIR/patches/freerdp-ohos"
FREERDP_PATCH_FILES=(
    "$FREERDP_PATCH_DIR/0001-fix-omit-TLS-SNI-for-IP-literals.patch"
    "$FREERDP_PATCH_DIR/0002-Add-bounded-dual-stack-TCP-racing.patch"
    "$FREERDP_PATCH_DIR/0003-Add-gateway-safe-dual-stack-routing.patch"
    "$FREERDP_PATCH_DIR/0004-Fix-thread-termination-on-OHOS.patch"
)
BUILD_OUTPUT_DIR="${REMOTEDESK_FREERDP_OUTPUT_DIR:-$PROJECT_DIR/build/freerdp-ohos}"
PREBUILT_DIR="${REMOTEDESK_FREERDP_PREBUILT_DIR:-$PROJECT_DIR/libs/freerdp-ohos}"
if [ -n "${REMOTEDESK_FREERDP_WORK_DIR:-}" ]; then
    BUILD_WORK_DIR="$REMOTEDESK_FREERDP_WORK_DIR"
else
    BUILD_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/remotedesk-freerdp-ohos.XXXXXX")"
    trap 'rm -rf "$BUILD_WORK_DIR"' EXIT
fi
. "$SCRIPT_DIR/resolve_ohos_sdk.sh"

require_safe_root() {
    local LABEL="$1"
    local ROOT="$2"
    case "$ROOT" in
        /*) ;;
        *) echo "ERROR: $LABEL must be an absolute path: $ROOT"; exit 1 ;;
    esac
    case "/$ROOT/" in
        *"/../"*) echo "ERROR: $LABEL must not contain '..': $ROOT"; exit 1 ;;
    esac
    case "$ROOT" in
        /|"$PROJECT_DIR"|"$FREERDP_SRC"|"$SCRIPT_DIR")
            echo "ERROR: unsafe $LABEL: $ROOT"
            exit 1
            ;;
    esac
}

require_safe_root "FreeRDP work root" "$BUILD_WORK_DIR"
require_safe_root "FreeRDP output root" "$BUILD_OUTPUT_DIR"
require_safe_root "FreeRDP prebuilt root" "$PREBUILT_DIR"
mkdir -p "$BUILD_WORK_DIR" "$BUILD_OUTPUT_DIR" "$PREBUILT_DIR"
FREERDP_PATCH_REPOSITORY="$BUILD_WORK_DIR/source-repository"
FREERDP_BUILD_SRC="$BUILD_WORK_DIR/source"

# ---- 前置检查 ----
if [ ! -d "$FREERDP_SRC" ]; then
    echo "ERROR: FreeRDP source not found at $FREERDP_SRC"
    echo "Run: git submodule update --init --recursive freerdp"
    exit 1
fi

FREERDP_REVISION="$(git -C "$FREERDP_SRC" rev-parse HEAD)"
if [ -n "$(git -C "$FREERDP_SRC" status --porcelain)" ]; then
    echo "ERROR: FreeRDP source worktree is dirty; commit it before producing attributable artifacts."
    exit 1
fi
if [ "$FREERDP_REVISION" != "$FREERDP_BASE_REVISION" ]; then
    echo "ERROR: FreeRDP public base mismatch: expected $FREERDP_BASE_REVISION, got $FREERDP_REVISION"
    exit 1
fi
if [ -n "${REMOTEDESK_FREERDP_EXPECTED_REVISION:-}" ] &&
   [ "$FREERDP_REVISION" != "$REMOTEDESK_FREERDP_EXPECTED_REVISION" ]; then
    echo "ERROR: FreeRDP revision mismatch: expected $REMOTEDESK_FREERDP_EXPECTED_REVISION, got $FREERDP_REVISION"
    exit 1
fi
for PATCH_FILE in "${FREERDP_PATCH_FILES[@]}"; do
    if [ ! -f "$PATCH_FILE" ]; then
        echo "ERROR: FreeRDP patch is missing: $PATCH_FILE"
        exit 1
    fi
done

# Keep the gitlink remotely reachable and reconstruct the reviewed OHOS source
# in the already-isolated build root. The final tree check makes patch order,
# content and application semantics one attributable build input.
rm -rf "$FREERDP_PATCH_REPOSITORY" "$FREERDP_BUILD_SRC"
git clone --quiet --shared --no-checkout "$FREERDP_SRC" "$FREERDP_PATCH_REPOSITORY"
git -C "$FREERDP_PATCH_REPOSITORY" checkout --quiet --detach "$FREERDP_BASE_REVISION"
for PATCH_FILE in "${FREERDP_PATCH_FILES[@]}"; do
    git -C "$FREERDP_PATCH_REPOSITORY" apply --index --whitespace=error-all "$PATCH_FILE"
done
FREERDP_ACTUAL_TREE="$(git -C "$FREERDP_PATCH_REPOSITORY" write-tree)"
if [ "$FREERDP_ACTUAL_TREE" != "$FREERDP_PATCHED_TREE" ]; then
    echo "ERROR: FreeRDP patched tree mismatch: expected $FREERDP_PATCHED_TREE, got $FREERDP_ACTUAL_TREE"
    exit 1
fi
# Build from an exported tree with no repository metadata. This preserves the
# established FREERDP_GIT_REVISION="n/a" artifact contract while provenance is
# still anchored by the verified base revision, patch bytes and final tree ID.
mkdir -p "$FREERDP_BUILD_SRC"
git -C "$FREERDP_PATCH_REPOSITORY" archive "$FREERDP_ACTUAL_TREE" |
    tar -xf - -C "$FREERDP_BUILD_SRC"
echo "FreeRDP public base: $FREERDP_REVISION"
echo "FreeRDP patched tree: $FREERDP_ACTUAL_TREE"

# OHOS SDK
OHOS_SDK="$(resolve_ohos_sdk)"
OHOS_NATIVE="$(ohos_native_root "$OHOS_SDK")"
OHOS_TOOLCHAIN="$OHOS_NATIVE/build/cmake/ohos.toolchain.cmake"
OHOS_LLVM="$OHOS_NATIVE/llvm"
OHOS_AR="$(find_ohos_tool "$OHOS_LLVM/bin" llvm-ar || true)"
OHOS_NM="$(find_ohos_tool "$OHOS_LLVM/bin" llvm-nm || true)"
OHOS_STRINGS="$(find_ohos_tool "$OHOS_LLVM/bin" llvm-strings || true)"

if [ ! -f "$OHOS_TOOLCHAIN" ]; then
    echo "ERROR: OHOS toolchain not found at $OHOS_TOOLCHAIN"
    echo "Set DEVECO_SDK_HOME to your DevEco Studio SDK path."
    exit 1
fi

if [ -z "$OHOS_AR" ]; then
    echo "ERROR: llvm-ar not found at $OHOS_AR"
    exit 1
fi
if [ -z "$OHOS_NM" ]; then
    echo "ERROR: llvm-nm not found under $OHOS_LLVM/bin"
    exit 1
fi
if [ -z "$OHOS_STRINGS" ]; then
    echo "ERROR: llvm-strings not found under $OHOS_LLVM/bin"
    exit 1
fi

# 预编译 OpenSSL (与主工程 CMakeLists.txt 使用同一套)
OPENSSL_DIR="$PROJECT_DIR/libs/openssl/install"

archive_contains_host_path() {
    local ARCHIVE="$1"
    local LINE
    local FOUND=0
    while IFS= read -r LINE; do
        case "$LINE" in
            *"$PROJECT_DIR"*|*"$BUILD_WORK_DIR"*|*"$OHOS_SDK"*|*"/Users/"*|*"RemoteDeskHarmonyOS"*|*"remotedesk-freerdp-ohos."*|*":/Users/"*|*":\\Users\\"*)
                FOUND=1
                ;;
        esac
    done < <("$OHOS_STRINGS" -a "$ARCHIVE")
    [ "$FOUND" -eq 1 ]
}

verify_archive_paths() {
    local ARCHIVE
    for ARCHIVE in "$@"; do
        if archive_contains_host_path "$ARCHIVE"; then
            echo "ERROR: host or temporary build path leaked into $ARCHIVE"
            exit 1
        fi
    done
}

# ---- Build function ----
build_arch() {
    local ARCH="$1"          # arm64-v8a or x86_64
    # Keep Ninja/CMake's high-churn object tree outside synced workspaces.
    # Desktop file providers can otherwise create "name 2.o" conflict copies
    # while parallel compilation is running and those copies may enter .a files.
    local BUILD="$BUILD_WORK_DIR/$ARCH"
    # Keep generated build-config headers and compiled string constants independent
    # from the developer machine's checkout path.
    local INSTALL="/opt/freerdp-ohos/$ARCH"

    echo "========================================"
    echo " Building FreeRDP for OHOS $ARCH"
    echo "========================================"

    # 验证 OpenSSL 产物
    if [ ! -f "$OPENSSL_DIR/$ARCH/lib/libssl.a" ]; then
        echo "ERROR: OpenSSL not found at $OPENSSL_DIR/$ARCH/lib/libssl.a"
        echo "Build OpenSSL first or check libs/openssl/install/$ARCH/"
        exit 1
    fi
    echo "OpenSSL: $OPENSSL_DIR/$ARCH"

    # 映射 OHOS_ARCH → sysroot lib 目录名
    case "$ARCH" in
        arm64-v8a) OHOS_TRIPLE="aarch64-linux-ohos" ;;
        x86_64)    OHOS_TRIPLE="x86_64-linux-ohos" ;;
        *)         echo "ERROR: unknown ARCH=$ARCH"; exit 1 ;;
    esac

    OHOS_SYSROOT="$OHOS_NATIVE/sysroot"
    ZLIB_INC="$OHOS_SYSROOT/usr/include"
    ZLIB_LIB="$OHOS_SYSROOT/usr/lib/$OHOS_TRIPLE/libz.so"
    FFMPEG_DIR="$PROJECT_DIR/libs/ffmpeg-ohos/$ARCH"

    if [ ! -f "$ZLIB_LIB" ]; then
        echo "ERROR: zlib not found at $ZLIB_LIB"
        exit 1
    fi
    echo "zlib: $ZLIB_LIB"

    if [ ! -f "$FFMPEG_DIR/lib/libavcodec.a" ] ||
       [ ! -f "$FFMPEG_DIR/lib/libavutil.a" ] ||
       [ ! -f "$FFMPEG_DIR/lib/libswscale.a" ]; then
        echo "ERROR: FFmpeg not found at $FFMPEG_DIR"
        echo "Build FFmpeg first or check libs/ffmpeg-ohos/$ARCH/"
        exit 1
    fi
    echo "FFmpeg: $FFMPEG_DIR"

    rm -rf "$BUILD"
    mkdir -p "$BUILD"
    cd "$BUILD"

    export PKG_CONFIG_PATH="$FFMPEG_DIR/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

    # OHOS clang stores the absolute source filename in ThinLTO bitcode module
    # identifiers even when all prefix-map flags are present.  These archives
    # are linked into the app later, so disable archive-level IPO to keep the
    # vendored inputs reproducible and free of developer-machine paths.
    cmake "$FREERDP_BUILD_SRC" \
        -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$OHOS_TOOLCHAIN" \
        -DOHOS_ARCH="$ARCH" \
        -DCMAKE_SYSROOT="$OHOS_SYSROOT" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        -DWITH_CLIENT_COMMON=ON \
        -DWITH_CLIENT=OFF \
        -DWITH_CLIENT_SDL=OFF \
        -DWITH_SERVER=OFF \
        -DWITH_PROXY=OFF \
        -DWITH_SAMPLE=OFF \
        -DWITH_MANPAGES=OFF \
        -DWITH_CHANNELS=ON \
        -DWITH_CLIENT_CHANNELS=ON \
        -DWITH_SERVER_CHANNELS=OFF \
        -DCHANNEL_AINPUT=ON \
        -DCHANNEL_AINPUT_CLIENT=ON \
        -DCHANNEL_AUDIN=OFF \
        -DCHANNEL_CLIPRDR=ON \
        -DCHANNEL_CLIPRDR_CLIENT=ON \
        -DCHANNEL_DISP=ON \
        -DCHANNEL_DISP_CLIENT=ON \
        -DCHANNEL_DRDYNVC=ON \
        -DCHANNEL_DRDYNVC_CLIENT=ON \
        -DCHANNEL_DRIVE=ON \
        -DCHANNEL_DRIVE_CLIENT=ON \
        -DCHANNEL_ECHO=OFF \
        -DCHANNEL_ENCOMSP=OFF \
        -DCHANNEL_GEOMETRY=OFF \
        -DCHANNEL_LOCATION=OFF \
        -DCHANNEL_PARALLEL=OFF \
        -DCHANNEL_PRINTER=OFF \
        -DCHANNEL_RAIL=OFF \
        -DCHANNEL_RDPDR=ON \
        -DCHANNEL_RDPDR_CLIENT=ON \
        -DCHANNEL_RDPEI=ON \
        -DCHANNEL_RDPEI_CLIENT=ON \
        -DCHANNEL_RDPGFX=ON \
        -DCHANNEL_RDPGFX_CLIENT=ON \
        -DCHANNEL_RDPSND=ON \
        -DCHANNEL_RDPSND_CLIENT=ON \
        -DCHANNEL_REMDESK=OFF \
        -DCHANNEL_SERIAL=OFF \
        -DCHANNEL_SMARTCARD=OFF \
        -DCHANNEL_URBDRC=OFF \
        -DCHANNEL_VIDEO=OFF \
        -DWITH_THIRD_PARTY=OFF \
        -DWITH_DEBUG_ALL=OFF \
        -DWITH_PROFILER=OFF \
        -DWITH_GPROF=OFF \
        -DWITH_X11=OFF \
        -DWITH_WAYLAND=OFF \
        -DWITH_DIRECTFB=OFF \
        -DWITH_FFMPEG=ON \
        -DWITH_VIDEO_FFMPEG=ON \
        -DWITH_DSP_FFMPEG=OFF \
        -DWITH_OPENH264=OFF \
        -DWITH_GSTREAMER=OFF \
        -DWITH_VAAPI=OFF \
        -DWITH_VAAPI_H264_ENCODING=OFF \
        -DWITH_CUPS=OFF \
        -DWITH_FUSE=OFF \
        -DWITH_PCSC=OFF \
        -DWITH_PULSE=OFF \
        -DWITH_ALSA=OFF \
        -DWITH_OSS=OFF \
        -DWITH_MEDIA_FOUNDATION=OFF \
        -DWITH_SWSCALE=ON \
        -DWITH_CAIRO=OFF \
        -DWITH_JPEG=OFF \
        -DWITH_OPENCL=OFF \
        -DWITH_WEBVIEW=OFF \
        -DWITH_KRB5=OFF \
        -DWITH_SSE2=OFF \
        -DWITH_IPP=OFF \
        -DWITH_CLIENT_INTERFACE=OFF \
        -DWITH_SERVER_INTERFACE=OFF \
        -DWITH_AAD=OFF \
        -DWITH_LIBRESSL=OFF \
        -DWITH_MBEDTLS=OFF \
        -DWITH_INTERNAL_MD4=ON \
        -DWITH_INTERNAL_RC4=ON \
        -DWITH_MACAUDIO=OFF \
        -DWITH_WINMM=OFF \
        -DWITH_WIN8=OFF \
        -DWITH_UNICODE_BUILTIN=ON \
        -DWITH_FREERDP_DEPRECATED=ON \
        -DOPENSSL_ROOT_DIR="$OPENSSL_DIR/$ARCH" \
        -DOPENSSL_INCLUDE_DIR="$OPENSSL_DIR/$ARCH/include" \
        -DOPENSSL_SSL_LIBRARY="$OPENSSL_DIR/$ARCH/lib/libssl.a" \
        -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_DIR/$ARCH/lib/libcrypto.a" \
        -DOPENSSL_USE_STATIC_LIBS=ON \
        -DAVCODEC_INCLUDE_DIRS="$FFMPEG_DIR/include" \
        -DAVCODEC_LIBRARIES="$FFMPEG_DIR/lib/libavcodec.a" \
        -DAVUTIL_INCLUDE_DIRS="$FFMPEG_DIR/include" \
        -DAVUTIL_LIBRARIES="$FFMPEG_DIR/lib/libavutil.a" \
        -DSWSCALE_INCLUDE_DIRS="$FFMPEG_DIR/include" \
        -DSWSCALE_LIBRARIES="$FFMPEG_DIR/lib/libswscale.a" \
        -DZLIB_INCLUDE_DIR="$ZLIB_INC" \
        -DZLIB_LIBRARY="$ZLIB_LIB" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL" \
        -DCMAKE_MESSAGE_LOG_LEVEL=STATUS

    # 修复 Windows CMake 在 build-config.h 中生成的 backslash 路径
    # (Clang 将 \U \D \R 等解释为 C 转义序列 → 编译错误)
    if [ -f "$BUILD/include/freerdp/build-config.h" ]; then
        if [ "$(uname -s)" = "Darwin" ]; then
            sed -i '' 's|\\|/|g' "$BUILD/include/freerdp/build-config.h"
        else
            sed -i 's|\\|/|g' "$BUILD/include/freerdp/build-config.h"
        fi
        echo "Fixed backslash paths in build-config.h"
    fi

    cmake --build . --target \
        freerdp \
        winpr \
        freerdp-client \
        drdynvc-client \
        rdpsnd-client \
        rdpsnd-common \
        rdpsnd-client-fake \
        rdpdr-client \
        drive-client \
        cliprdr-client \
        rdpei-client \
        ainput-client \
        disp-client \
        rdpgfx-client \
        -- -j"$(jobs_count)"

    local SETTINGS_KEYS="$BUILD/include/freerdp/settings_keys.h"
    local BUILD_CONFIG="$BUILD/include/freerdp/config.h"
    if ! grep -F "FreeRDP_GatewayConnectHostname = 2027" "$SETTINGS_KEYS" >/dev/null; then
        echo "ERROR: generated settings_keys.h is missing FreeRDP_GatewayConnectHostname"
        exit 1
    fi
    for required_define in CHANNEL_DISP_CLIENT CHANNEL_DRIVE_CLIENT; do
        if ! grep -E "^#define ${required_define}[[:space:]]*$" "$BUILD_CONFIG" >/dev/null; then
            echo "ERROR: generated config.h is missing $required_define"
            exit 1
        fi
    done

    # 收集产物
    local OUTPUT="$BUILD_OUTPUT_DIR/libs/$ARCH"
    rm -rf "$OUTPUT"
    mkdir -p "$OUTPUT"

    # Copy only the canonical targets; broad find-based copies can mask a
    # file-provider conflict copy with the same logical archive name.
    cp -v "$BUILD/libfreerdp/libfreerdp3.a" "$OUTPUT/"
    cp -v "$BUILD/winpr/libwinpr/libwinpr3.a" "$OUTPUT/"

    # FreeRDP 的客户端 common 与静态通道不会被合入 libfreerdp3.a。
    # 这里把 freerdp_client_load_addins 所需对象和 rdpsnd/rdpdr/drive/cliprdr/drdynvc/rdpei/ainput/disp
    # 通道入口打成单独静态库，主工程链接后才能真正加载音频/剪贴板/设备/动态显示通道。
    local CONFLICT_COPY
    CONFLICT_COPY="$(find "$BUILD" -type f \( \
        -name "* 2.*" -o -name "* 3.*" -o -name "* 4.*" \
        \) -print -quit)"
    if [ -n "$CONFLICT_COPY" ]; then
        echo "ERROR: conflict-copy artifact detected in isolated build: $CONFLICT_COPY"
        exit 1
    fi

    local CHANNEL_LIB="$OUTPUT/libfreerdp-client-channels.a"
    local CHANNEL_OBJECTS=()
    local OBJECT_DIRS=(
        "$BUILD/client/common/CMakeFiles/freerdp-client.dir"
        "$BUILD/channels/drdynvc/client/CMakeFiles/drdynvc-client.dir"
        "$BUILD/channels/rdpsnd/client/CMakeFiles/rdpsnd-client.dir"
        "$BUILD/channels/rdpsnd/common/CMakeFiles/rdpsnd-common.dir"
        "$BUILD/channels/rdpsnd/client/fake/CMakeFiles/rdpsnd-client-fake.dir"
        "$BUILD/channels/rdpdr/client/CMakeFiles/rdpdr-client.dir"
        "$BUILD/channels/drive/client/CMakeFiles/drive-client.dir"
        "$BUILD/channels/cliprdr/client/CMakeFiles/cliprdr-client.dir"
        "$BUILD/channels/rdpei/client/CMakeFiles/rdpei-client.dir"
        "$BUILD/channels/ainput/client/CMakeFiles/ainput-client.dir"
        "$BUILD/channels/disp/client/CMakeFiles/disp-client.dir"
        "$BUILD/channels/rdpgfx/client/CMakeFiles/rdpgfx-client.dir"
    )
    for dir in "${OBJECT_DIRS[@]}"; do
        if [ -d "$dir" ]; then
            while IFS= read -r obj; do
                CHANNEL_OBJECTS+=("$obj")
            done < <(find "$dir" -name "*.o" -print | LC_ALL=C sort)
        fi
    done
    if [ "${#CHANNEL_OBJECTS[@]}" -eq 0 ]; then
        echo "ERROR: no FreeRDP client/channel objects found"
        exit 1
    fi
    rm -f "$CHANNEL_LIB"
    # Explicit deterministic mode plus stable member ordering makes the
    # vendored archive checksum reproducible across clean builds.
    "$OHOS_AR" rcsD "$CHANNEL_LIB" "${CHANNEL_OBJECTS[@]}"
    for required_symbol in drive_DeviceServiceEntry disp_DVCPluginEntry rdpdr_VirtualChannelEntryEx; do
        if ! "$OHOS_NM" "$CHANNEL_LIB" | grep " $required_symbol$" >/dev/null; then
            echo "ERROR: $CHANNEL_LIB is missing required symbol $required_symbol"
            exit 1
        fi
    done
    verify_archive_paths \
        "$OUTPUT/libfreerdp3.a" \
        "$OUTPUT/libwinpr3.a" \
        "$OUTPUT/libfreerdp-client-channels.a"
    if "$OHOS_NM" -u "$OUTPUT/libwinpr3.a" | grep -F "pthread_cancel" >/dev/null; then
        echo "ERROR: $OUTPUT/libwinpr3.a references unsupported OHOS symbol pthread_cancel"
        exit 1
    fi

    # 同步到 libs/ 下作为 IDE 可复用预编译依赖，避免 DevEco clean 删除 build/ 后丢库。
    local PREBUILT="$PREBUILT_DIR/$ARCH"
    local PREBUILT_STAGE="$BUILD_WORK_DIR/prebuilt-$ARCH"
    rm -rf "$PREBUILT_STAGE"
    mkdir -p "$PREBUILT_STAGE/winpr"
    cp -v "$OUTPUT/libfreerdp3.a" "$PREBUILT_STAGE/"
    cp -v "$OUTPUT/libwinpr3.a" "$PREBUILT_STAGE/"
    cp -v "$OUTPUT/libfreerdp-client-channels.a" "$PREBUILT_STAGE/"
    cp -R "$BUILD/include" "$PREBUILT_STAGE/"
    cp -R "$BUILD/winpr/include" "$PREBUILT_STAGE/winpr/"
    # CMake install/test metadata is host-specific and not consumed by the app.
    find "$PREBUILT_STAGE" -type f \( \
        -name "cmake_install*.cmake" -o \
        -name "CTestTestfile*.cmake" \
    \) -delete
    rm -rf "$PREBUILT"
    mv "$PREBUILT_STAGE" "$PREBUILT"

    # 验证产物
    if [ -f "$OUTPUT/libfreerdp3.a" ] &&
       [ -f "$OUTPUT/libwinpr3.a" ] &&
       [ -f "$OUTPUT/libfreerdp-client-channels.a" ]; then
        echo "FreeRDP $ARCH build complete: $OUTPUT/"
        ls -lh "$OUTPUT/"
    else
        echo "ERROR: FreeRDP $ARCH build failed — missing .a files"
        exit 1
    fi
}

# ---- Main ----
ARCH="${1:-all}"

case "$ARCH" in
    arm64|aarch64)
        build_arch arm64-v8a
        ;;
    x86_64|amd64)
        build_arch x86_64
        ;;
    all)
        build_arch arm64-v8a
        build_arch x86_64
        ;;
    *)
        echo "Usage: $0 [arm64|x86_64|all]"
        exit 1
        ;;
esac

echo "========================================"
echo " FreeRDP OHOS cross-compilation DONE"
echo " Libraries: $BUILD_OUTPUT_DIR/libs/"
echo " IDE prebuilt: $PREBUILT_DIR/"
echo "========================================"
