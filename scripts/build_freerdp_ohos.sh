#!/bin/bash
# =============================================================================
# build_freerdp_ohos.sh — FreeRDP 3.x OHOS 交叉编译脚本
#
# 在 Windows (Git Bash) 或 Linux 上运行。
# 需要 OHOS SDK (DevEco Studio) 和 CMake + Ninja。
#
# 输出:
#   build/freerdp-ohos/libs/<arch>/libfreerdp3.a
#   build/freerdp-ohos/libs/<arch>/libwinpr3.a
#   build/freerdp-ohos/libs/<arch>/libfreerdp-client-channels.a
#   libs/freerdp-ohos/<arch>/ 同步一份给 DevEco/IDE clean 后继续使用
#
# 用法:
#   export DEVECO_SDK_HOME="C:/Program Files/Huawei/DevEco Studio/sdk"
#   ./scripts/build_freerdp_ohos.sh [arm64|x86_64|all]
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FREERDP_SRC="$PROJECT_DIR/freerdp"
BUILD_DIR="$PROJECT_DIR/build/freerdp-ohos"
PREBUILT_DIR="$PROJECT_DIR/libs/freerdp-ohos"

# ---- 前置检查 ----
if [ ! -d "$FREERDP_SRC" ]; then
    echo "ERROR: FreeRDP source not found at $FREERDP_SRC"
    echo "Run: git submodule update --init --recursive freerdp"
    exit 1
fi

# OHOS SDK
OHOS_SDK="${DEVECO_SDK_HOME:-C:/Program Files/Huawei/DevEco Studio/sdk}"
OHOS_NATIVE="$OHOS_SDK/default/openharmony/native"
OHOS_TOOLCHAIN="$OHOS_NATIVE/build/cmake/ohos.toolchain.cmake"
OHOS_LLVM="$OHOS_NATIVE/llvm"
OHOS_AR="$OHOS_LLVM/bin/llvm-ar"

if [ ! -f "$OHOS_TOOLCHAIN" ]; then
    echo "ERROR: OHOS toolchain not found at $OHOS_TOOLCHAIN"
    echo "Set DEVECO_SDK_HOME to your DevEco Studio SDK path."
    exit 1
fi

if [ ! -x "$OHOS_AR" ]; then
    echo "ERROR: llvm-ar not found at $OHOS_AR"
    exit 1
fi

# 预编译 OpenSSL (与主工程 CMakeLists.txt 使用同一套)
OPENSSL_DIR="$PROJECT_DIR/libs/openssl/install"

# ---- Build function ----
build_arch() {
    local ARCH="$1"          # arm64-v8a or x86_64
    local BUILD="$BUILD_DIR/$ARCH"
    local INSTALL="$BUILD_DIR/install-$ARCH"

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

    cmake "$FREERDP_SRC" \
        -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$OHOS_TOOLCHAIN" \
        -DOHOS_ARCH="$ARCH" \
        -DCMAKE_SYSROOT="$OHOS_SYSROOT" \
        -DCMAKE_BUILD_TYPE=Release \
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
        -DWITH_SERVER_CHANNELS=OFF \
        -DCHANNEL_AINPUT=ON \
        -DCHANNEL_AINPUT_CLIENT=ON \
        -DCHANNEL_AUDIN=OFF \
        -DCHANNEL_CLIPRDR=ON \
        -DCHANNEL_CLIPRDR_CLIENT=ON \
        -DCHANNEL_DISP=OFF \
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
        sed -i 's|\\|/|g' "$BUILD/include/freerdp/build-config.h"
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
        rdpgfx-client \
        -- -j"$(nproc 2>/dev/null || echo 4)"

    # 收集产物
    mkdir -p "$BUILD_DIR/libs/$ARCH"

    # 从 build tree 找 .a 文件
    find "$BUILD" -name "libfreerdp3.a" -exec cp -v {} "$BUILD_DIR/libs/$ARCH/" \;
    find "$BUILD" -name "libwinpr3.a" -exec cp -v {} "$BUILD_DIR/libs/$ARCH/" \;

    # FreeRDP 的客户端 common 与静态通道不会被合入 libfreerdp3.a。
    # 这里把 freerdp_client_load_addins 所需对象和 rdpsnd/rdpdr/cliprdr/drdynvc/rdpei/ainput
    # 通道入口打成单独静态库，主工程链接后才能真正加载音频/剪贴板/设备通道。
    local CHANNEL_LIB="$BUILD_DIR/libs/$ARCH/libfreerdp-client-channels.a"
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
        "$BUILD/channels/rdpgfx/client/CMakeFiles/rdpgfx-client.dir"
    )
    for dir in "${OBJECT_DIRS[@]}"; do
        if [ -d "$dir" ]; then
            while IFS= read -r -d '' obj; do
                CHANNEL_OBJECTS+=("$obj")
            done < <(find "$dir" -name "*.o" -print0)
        fi
    done
    if [ "${#CHANNEL_OBJECTS[@]}" -eq 0 ]; then
        echo "ERROR: no FreeRDP client/channel objects found"
        exit 1
    fi
    rm -f "$CHANNEL_LIB"
    "$OHOS_AR" rcs "$CHANNEL_LIB" "${CHANNEL_OBJECTS[@]}"

    # 同步到 libs/ 下作为 IDE 可复用预编译依赖，避免 DevEco clean 删除 build/ 后丢库。
    local PREBUILT="$PREBUILT_DIR/$ARCH"
    rm -rf "$PREBUILT"
    mkdir -p "$PREBUILT/winpr"
    cp -v "$BUILD_DIR/libs/$ARCH/libfreerdp3.a" "$PREBUILT/"
    cp -v "$BUILD_DIR/libs/$ARCH/libwinpr3.a" "$PREBUILT/"
    cp -v "$BUILD_DIR/libs/$ARCH/libfreerdp-client-channels.a" "$PREBUILT/"
    cp -R "$BUILD/include" "$PREBUILT/"
    cp -R "$BUILD/winpr/include" "$PREBUILT/winpr/"

    # 验证产物
    if [ -f "$BUILD_DIR/libs/$ARCH/libfreerdp3.a" ] &&
       [ -f "$BUILD_DIR/libs/$ARCH/libwinpr3.a" ] &&
       [ -f "$BUILD_DIR/libs/$ARCH/libfreerdp-client-channels.a" ]; then
        echo "FreeRDP $ARCH build complete: $BUILD_DIR/libs/$ARCH/"
        ls -lh "$BUILD_DIR/libs/$ARCH/"
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
echo " Libraries: $BUILD_DIR/libs/"
echo " IDE prebuilt: $PREBUILT_DIR/"
echo "========================================"
