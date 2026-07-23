# =============================================================================
# build_ffmpeg_softdec_ohos.sh — FFmpeg VP8/VP9/AV1 软件解码库 OHOS 交叉编译
#
# 用法 (Git Bash/macOS):
#   export DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk"
#   ./scripts/build_ffmpeg_softdec_ohos.sh [arm64|x86_64|all]
#
# 输出:
#   libs/ffmpeg-ohos/arm64-v8a/{include,lib/libavcodec.a,lib/libavutil.a,lib/libswscale.a}
#   libs/ffmpeg-ohos/x86_64/{include,lib/libavcodec.a,lib/libavutil.a,lib/libswscale.a}
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FFMPEG_VER="8.1.2"
FFMPEG_SHA256="464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"
SRC_ROOT="$PROJECT_DIR/build/ffmpeg-src"
FFMPEG_SRC="$SRC_ROOT/ffmpeg-${FFMPEG_VER}"
OUT_ROOT="$PROJECT_DIR/libs/ffmpeg-ohos"
BUILD_ROOT="$PROJECT_DIR/build/ffmpeg-ohos"
. "$SCRIPT_DIR/resolve_ohos_sdk.sh"

OHOS_SDK="$(resolve_ohos_sdk)"
# Environment variables supplied by PowerShell commonly use backslashes.
# Normalize before comparing or passing paths into FFmpeg's shell configure.
OHOS_SDK="${OHOS_SDK//\\//}"
# FFmpeg configure 会把 --cc 按空格拆分，SDK 路径必须无空格。
# DevEco 默认安装路径在 Windows 下通常可用 8.3 短路径访问。
if [[ "$OHOS_SDK" == "C:/Program Files/Huawei/DevEco Studio/sdk" ]]; then
    OHOS_SDK="C:/PROGRA~1/Huawei/DEVECO~1/sdk"
fi
OHOS_LLVM="$OHOS_SDK/default/openharmony/native/llvm/bin"
OHOS_SYSROOT="$OHOS_SDK/default/openharmony/native/sysroot"

find_tool() {
    local name="$1"
    if [ -f "$OHOS_LLVM/${name}.exe" ]; then
        echo "$OHOS_LLVM/${name}.exe"
    elif [ -f "$OHOS_LLVM/${name}" ]; then
        echo "$OHOS_LLVM/${name}"
    else
        echo ""
    fi
}

CLANG="$(find_tool clang)"
AR="$(find_tool llvm-ar)"
RANLIB="$(find_tool llvm-ranlib)"
STRIP="$(find_tool llvm-strip)"

if [ -z "$CLANG" ] || [ -z "$AR" ] || [ -z "$RANLIB" ]; then
    echo "ERROR: OHOS LLVM tools not found under: $OHOS_LLVM"
    echo "Set DEVECO_SDK_HOME to your DevEco Studio SDK path."
    exit 1
fi

if [ ! -d "$OHOS_SYSROOT" ]; then
    echo "ERROR: OHOS sysroot not found: $OHOS_SYSROOT"
    exit 1
fi

prepare_source() {
    if [ -d "$FFMPEG_SRC" ]; then
        return
    fi
    mkdir -p "$SRC_ROOT"
    local tarball="$SRC_ROOT/ffmpeg-${FFMPEG_VER}.tar.xz"
    if [ ! -f "$tarball" ]; then
        echo "=== Downloading FFmpeg ${FFMPEG_VER} ==="
        curl -L -o "$tarball" "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VER}.tar.xz"
    fi
    local actual_sha256
    actual_sha256="$(sha256_file "$tarball")"
    if [ "$actual_sha256" != "$FFMPEG_SHA256" ]; then
        echo "ERROR: unexpected FFmpeg archive checksum: $actual_sha256"
        echo "Expected: $FFMPEG_SHA256"
        exit 1
    fi
    echo "=== Extracting FFmpeg ${FFMPEG_VER} ==="
    tar xf "$tarball" -C "$SRC_ROOT"
}

build_ffmpeg() {
    local target="$1"      # aarch64-linux-ohos / x86_64-linux-ohos
    local abi="$2"         # arm64-v8a / x86_64
    local arch="$3"        # aarch64 / x86_64
    local outdir="$OUT_ROOT/$abi"
    local workdir="$BUILD_ROOT/$abi"

    echo ""
    echo "============================================"
    echo "=== Building FFmpeg soft decoder for $abi ==="
    echo "============================================"

    rm -rf "$workdir"
    mkdir -p "$workdir" "$outdir"

    pushd "$workdir" >/dev/null

    local cflags="--target=${target} --sysroot=${OHOS_SYSROOT} -fPIC -O3 -D__MUSL__"
    local ldflags="--target=${target} --sysroot=${OHOS_SYSROOT}"
    local asm_flags=(--enable-asm --enable-inline-asm)
    if [ "$arch" = "aarch64" ]; then
        # AArch64 guarantees Advanced SIMD. FFmpeg's VP9 NEON assembly is the
        # primary throughput path on HarmonyOS phones and tablets.
        asm_flags+=(--enable-neon)
    else
        # Keep the emulator ABI linkable. FFmpeg 8.1.2 x86 NASM objects use
        # absolute references to shared constants when linked into OHOS's
        # shared NAPI library; ARM64 is the production device target and gets
        # the full SIMD path above.
        asm_flags=(--disable-asm)
    fi

    "$FFMPEG_SRC/configure" \
        --prefix="$outdir" \
        --target-os=linux \
        --arch="$arch" \
        --enable-cross-compile \
        --cc="$CLANG" \
        --ar="$AR" \
        --ranlib="$RANLIB" \
        --strip="${STRIP:-$RANLIB}" \
        --extra-cflags="$cflags" \
        --extra-ldflags="$ldflags" \
        --enable-static \
        --disable-shared \
        --enable-pic \
        "${asm_flags[@]}" \
        --disable-autodetect \
        --disable-programs \
        --disable-doc \
        --disable-debug \
        --disable-network \
        --disable-avdevice \
        --disable-avfilter \
        --disable-avformat \
        --disable-swresample \
        --enable-avcodec \
        --enable-avutil \
        --enable-swscale \
        --disable-everything \
        --enable-decoder=vp8 \
        --enable-decoder=vp9 \
        --enable-decoder=av1 \
        --enable-parser=vp8 \
        --enable-parser=vp9 \
        --enable-parser=av1 \
        --disable-iconv \
        --disable-zlib \
        --disable-bzlib \
        --disable-lzma

    local make_cmd="${MAKE:-make}"
    if ! command -v "$make_cmd" >/dev/null 2>&1; then
        if command -v mingw32-make >/dev/null 2>&1; then
            make_cmd="mingw32-make"
        else
            echo "ERROR: make not found. Install MSYS2 make or ensure mingw32-make is in PATH."
            exit 1
        fi
    fi

    local make_shell_args=()
    if [ "$make_cmd" = "mingw32-make" ]; then
        local project_win
        project_win="$(cygpath -m "$PROJECT_DIR")"
        # Strawberry mingw32-make does not understand MSYS /c/... paths.
        # Convert generated FFmpeg make/config paths to Windows style and run recipes through Git sh.
        find "$workdir" -type f -exec sed -i "s|$PROJECT_DIR|$project_win|g" {} +
        if [ "$arch" = "aarch64" ]; then
            # mingw32-make resolves FFmpeg's uppercase .S prerequisites as
            # lowercase .s through VPATH. Mirror them with the expected case;
            # the generated ASFLAGS below preserve C-preprocessor semantics.
            while IFS= read -r -d '' asm_source; do
                local asm_relative="${asm_source#"$FFMPEG_SRC"/}"
                local asm_compat="$workdir/${asm_relative%.S}.s"
                mkdir -p "$(dirname "$asm_compat")"
                cp -f "$asm_source" "$asm_compat"
                find "$(dirname "$asm_source")" -maxdepth 1 -type f -name '*.h' \
                    -exec cp -f {} "$(dirname "$asm_compat")/" \;
            done < <(find "$FFMPEG_SRC" -type f -name '*.S' -print0)
            sed -i '/^ASFLAGS=/ s|$| -x assembler-with-cpp|' "$workdir/ffbuild/config.mak"
        fi
        make_shell_args+=("SHELL=C:/PROGRA~1/Git/usr/bin/sh.exe")
    fi

    "$make_cmd" -j"$(jobs_count)" "${make_shell_args[@]}"
    "$make_cmd" install "${make_shell_args[@]}"

    # mingw32-make + Windows paths can miss header installation even when libs install correctly.
    # Copy public headers explicitly from source and generated build dirs.
    for lib in libavcodec libavutil libswscale; do
        mkdir -p "$outdir/include/$lib"
        cp -f "$FFMPEG_SRC/$lib"/*.h "$outdir/include/$lib/"
        if [ -d "$workdir/$lib" ]; then
            cp -f "$workdir/$lib"/*.h "$outdir/include/$lib/" 2>/dev/null || true
        fi
    done

    popd >/dev/null

    echo "=== FFmpeg $abi built ==="
    ls -lh "$outdir/lib/libavcodec.a" "$outdir/lib/libavutil.a" "$outdir/lib/libswscale.a"
}

prepare_source

target_arch="${1:-all}"
case "$target_arch" in
    arm64|arm64-v8a)
        build_ffmpeg "aarch64-linux-ohos" "arm64-v8a" "aarch64"
        ;;
    x86_64)
        build_ffmpeg "x86_64-linux-ohos" "x86_64" "x86_64"
        ;;
    all)
        build_ffmpeg "aarch64-linux-ohos" "arm64-v8a" "aarch64"
        build_ffmpeg "x86_64-linux-ohos" "x86_64" "x86_64"
        ;;
    *)
        echo "Usage: $0 [arm64|x86_64|all]"
        exit 1
        ;;
esac

echo ""
echo "=== FFmpeg soft decoder build complete ==="
echo "Output: $OUT_ROOT"
find "$OUT_ROOT" -name "libavcodec.a" -o -name "libavutil.a" -o -name "libswscale.a" | sort
