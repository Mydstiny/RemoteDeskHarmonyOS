#!/bin/bash
# =============================================================================
# build_opus_ohos.sh — libopus 1.5.2 OHOS 交叉编译 (直接 clang, 无 autotools)
#
# 用法:
#   export DEVECO_SDK_HOME="C:/Program Files/Huawei/DevEco Studio/sdk"
#   ./scripts/build_opus_ohos.sh [arm64|x86_64|all]
#
# 输出:
#   libs/opus-ohos/arm64-v8a/libopus.a
#   libs/opus-ohos/x86_64/libopus.a
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OPUS_VER="1.5.2"
OPUS_SRC="$PROJECT_DIR/build/opus-src/opus-${OPUS_VER}"
BUILD_DIR="$PROJECT_DIR/build/opus-ohos"
INSTALL_DIR="$PROJECT_DIR/libs/opus-ohos"
OPUS_TARBALL="opus-${OPUS_VER}.tar.gz"
OPUS_ARCHIVE="$(dirname "$OPUS_SRC")/$OPUS_TARBALL"
OPUS_SHA256="65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1"

# OHOS SDK
OHOS_SDK="${DEVECO_SDK_HOME:-C:/Program Files/Huawei/DevEco Studio/sdk}"
OHOS_LLVM="$OHOS_SDK/default/openharmony/native/llvm/bin"
OHOS_SYSROOT="$OHOS_SDK/default/openharmony/native/sysroot"

if [ ! -f "$OHOS_LLVM/clang.exe" ] && [ ! -f "$OHOS_LLVM/clang" ]; then
    echo "ERROR: OHOS LLVM not found at $OHOS_LLVM"
    echo "Set DEVECO_SDK_HOME to your DevEco Studio SDK path."
    exit 1
fi

# ---- 下载 libopus ----
if [ ! -d "$OPUS_SRC" ]; then
    mkdir -p "$(dirname "$OPUS_SRC")"
    if [ ! -f "$OPUS_ARCHIVE" ]; then
        echo "=== Downloading libopus ${OPUS_VER} ==="
        OPUS_URL="https://downloads.xiph.org/releases/opus/${OPUS_TARBALL}"
        curl --fail --location --output "$OPUS_ARCHIVE" "$OPUS_URL"
    fi
    ACTUAL_SHA256="$(sha256sum "$OPUS_ARCHIVE" | awk '{print $1}')"
    if [ "$ACTUAL_SHA256" != "$OPUS_SHA256" ]; then
        echo "ERROR: unexpected libopus archive checksum: $ACTUAL_SHA256"
        echo "Expected: $OPUS_SHA256"
        exit 1
    fi
    tar xzf "$OPUS_ARCHIVE" -C "$(dirname "$OPUS_SRC")"
    echo "=== libopus source ready ==="
fi

# ---- 直接编译函数 ----
build_opus_clang() {
    local TARGET="$1"       # aarch64-linux-ohos / x86_64-linux-ohos
    local ABI="$2"          # arm64-v8a / x86_64
    local OUTDIR="$INSTALL_DIR/$ABI"
    local WORKDIR="$BUILD_DIR/build/$ABI"

    echo ""
    echo "============================================"
    echo "=== Building libopus for OHOS $ABI ==="
    echo "============================================"

    mkdir -p "$WORKDIR" "$OUTDIR/include"

    # Find clang (with or without .exe)
    local CLANG="$OHOS_LLVM/clang.exe"
    if [ ! -f "$CLANG" ]; then
        CLANG="$OHOS_LLVM/clang"
    fi
    local AR="$OHOS_LLVM/llvm-ar"
    if [ -f "$OHOS_LLVM/llvm-ar.exe" ]; then
        AR="$OHOS_LLVM/llvm-ar.exe"
    fi

    # Common compile flags for OHOS
    local CFLAGS="--target=${TARGET} -fPIC -O2 -D__MUSL__ -DHAVE_CONFIG_H -DFIXED_POINT=1"

    # Create minimal config.h for libopus
    cat > "$WORKDIR/config.h" << 'CONFEOF'
#define OPUS_VERSION "1.5.2"
#define OPUS_BUILD ""
#define OPUS_HAVE_LRINTF 1
#define OPUS_HAVE_LRINT 1
#define PACKAGE_VERSION "1.5.2"
#define PACKAGE_NAME "opus"
#define VAR_ARRAYS 1
#define OPUS_ARM_MAY_HAVE_NEON_INTR 1
#define OPUS_X86_MAY_HAVE_SSE 0
#define OPUS_X86_MAY_HAVE_SSE2 0
#define OPUS_X86_MAY_HAVE_SSE4_1 0
#define OPUS_X86_MAY_HAVE_AVX 0
#define restrict __restrict
CONFEOF

    # Collect all .c files from opus source (celt + silk + src)
    local SRC_FILES=()
    # celt/
    for f in bands celt celt_decoder celt_encoder celt_lpc cwrs entcode entdec entenc fixed_debug kiss_fft laplace mathops mdct modes pitch plc quant_bands rate vq; do
        [ -f "$OPUS_SRC/celt/${f}.c" ] && SRC_FILES+=("$OPUS_SRC/celt/${f}.c")
    done
    # silk/
    for f in A2NLSF CNG HP_variable_cutoff LPC_analysis_filter LPC_fit LPC_inv_pred_gain LP_variable_cutoff NLSF2A NLSF_VQ NLSF_VQ_weights NLSF_decode NLSF_del_dec_quant NLSF_encode NLSF_stabilize NLSF_unpack NSQ NSQ_del_dec PLC Resampler Solver_FIR VAD VQ_WMat_EC ana_filt_bank_1 biquad_alt box_constraints chaos dec_API ctrl_FIX decode_core decode_frame decode_indices decode_parameters decode_pitch decode_pulses enc_API encoder_API_FIX gain_quant independently_irregular_encode inner_prod_alias interpolate interpolate_2nd linear lin2log log2lin pitch_est_tables process_NLSFs quant_LTP_gains resampler_rom resampler_down2 resampler_private_AR2 resampler_private_IIR_FIR resampler_private_down_FIR resampler_private_up2_HQ shell_coder sigm_Q15 sort stereo_decode_pred stereo_encode_pred stereo_find_predictor stereo_LR_to_MS stereo_MS_to_LR stereo_quant_pred sum_sqr_shift tables_gain tables_LTP tables_NLSF_CB_WB tables_NLSF_CB_NB_MB tables_other tables_pitch_lag tables_pulses_per_block typedef; do
        [ -f "$OPUS_SRC/silk/${f}.c" ] && SRC_FILES+=("$OPUS_SRC/silk/${f}.c")
    done
    for f in bwexpander bwexpander_32 check_control_input code_signs control_audio_bandwidth control_codec control_SNR debug decoder_set_fs encode_indices encode_pulses init_decoder init_encoder inner_prod_aligned NLSF_VQ_weights_laroia resampler_down2_3 table_LSF_cos; do
        [ -f "$OPUS_SRC/silk/${f}.c" ] && SRC_FILES+=("$OPUS_SRC/silk/${f}.c")
    done
    # silk/fixed/
    for f in LTP_analysis_filter_FIX LTP_scale_ctrl_FIX apply_sine_window_FIX autocorr_FIX burg_modified_FIX correlation_matrix_FIX encode_frame_FIX find_LPC_FIX find_LTP_FIX find_pitch_lags_FIX find_pred_coefs_FIX k2a_FIX noise_shape_analysis_FIX pitch_analysis_core_FIX prefilter_FIX process_gains_FIX regularize_correlations_FIX residual_energy_FIX schur_FIX schur64_FIX vector_ops_FIX warped_autocorrelation_FIX; do
        [ -f "$OPUS_SRC/silk/fixed/${f}.c" ] && SRC_FILES+=("$OPUS_SRC/silk/fixed/${f}.c")
    done
    # src/
    for f in opus opus_decoder opus_encoder opus_multistream opus_multistream_decoder opus_multistream_encoder opus_projection_decoder opus_projection_encoder repacketizer analysis mlp; do
        [ -f "$OPUS_SRC/src/${f}.c" ] && SRC_FILES+=("$OPUS_SRC/src/${f}.c")
    done

    # Compile each source file
    local OBJ_FILES=()
    for src in "${SRC_FILES[@]}"; do
        local fname=$(basename "$src" .c)
        local obj="$WORKDIR/${fname}.o"
        OBJ_FILES+=("$obj")
        "$CLANG" $CFLAGS -I"$OPUS_SRC" -I"$OPUS_SRC/include" -I"$OPUS_SRC/celt" -I"$OPUS_SRC/silk" -I"$OPUS_SRC/silk/fixed" -I"$WORKDIR" -c "$src" -o "$obj" 2>&1 | head -1
    done

    echo "=== Compiled ${#OBJ_FILES[@]} object files ==="

    # Archive into static library
    "$AR" rcs "$OUTDIR/libopus.a" "${OBJ_FILES[@]}"
    echo "=== libopus for $ABI built: $OUTDIR/libopus.a ==="
    ls -lh "$OUTDIR/libopus.a"
}

# ---- 入口 ----
TARGET_ARCH="${1:-all}"

case "$TARGET_ARCH" in
    arm64|arm64-v8a)
        build_opus_clang "aarch64-linux-ohos" "arm64-v8a"
        ;;
    x86_64)
        build_opus_clang "x86_64-linux-ohos" "x86_64"
        ;;
    all)
        build_opus_clang "aarch64-linux-ohos" "arm64-v8a"
        build_opus_clang "x86_64-linux-ohos" "x86_64"
        ;;
    *)
        echo "Usage: $0 [arm64|x86_64|all]"
        exit 1
        ;;
esac

echo ""
echo "=== libopus build complete ==="
echo "Output: $INSTALL_DIR/"
find "$INSTALL_DIR" -name "libopus.a" -exec ls -lh {} \;
