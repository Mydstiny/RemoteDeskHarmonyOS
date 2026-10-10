#!/bin/bash
# =============================================================================
# build_openssl_ohos.sh — OpenSSL 3.4.1 OHOS 静态库交叉编译脚本
#
# 在 macOS 或 Linux 上运行，需要 OHOS SDK (DevEco Studio) 与 perl/make。
#
# 输出（只替换这三类文件，其余头文件与上游 3.4.1 逐字节一致）:
#   libs/openssl/install/<abi>/lib/libcrypto.a
#   libs/openssl/install/<abi>/lib/libssl.a
#   libs/openssl/install/<abi>/include/openssl/configuration.h
#
# 用法:
#   ./scripts/build_openssl_ohos.sh [arm64-v8a|x86_64|all]
#
# 配置说明: 与最初在 Windows 上编译的静态库使用同一组 no-* 选项，唯一差别
# 是不再关闭 DES。FreeRDP 在服务器要求 FIPS 加密级别的旧版 RDP 安全层
# （Standard RDP Security）时用 3DES 加解密；OpenSSL 3 不提供 TLS 3DES 套件，
# 所以这不改变任何 TLS / SSH 协商结果（见 docs/codex/DECISIONS.md D-026）。
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OPENSSL_VERSION="3.4.1"
OPENSSL_SHA256="002a2d6b30b58bf4bea46c43bdd96365aaf8daa6c428782aa4feee06da197df3"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
# OpenSSL 3.4.1 的发布日，让 "built on" 字符串可复现。
SOURCE_DATE_EPOCH=1739232000
INSTALL_ROOT="$PROJECT_DIR/libs/openssl/install"
OPTIONS=(
    no-shared no-asm no-tests
    no-aria no-bf no-blake2 no-camellia no-cast no-chacha no-cmac
    no-dh no-dsa no-dso no-ec2m no-engine no-idea no-md4 no-mdc2 no-ocb
    no-rc2 no-rc4 no-rmd160 no-scrypt no-seed no-siphash no-siv
    no-sm2 no-sm3 no-sm4 no-whirlpool no-argon2
)

. "$SCRIPT_DIR/resolve_ohos_sdk.sh"
OHOS_NATIVE_HOME="$(ohos_native_root "$(resolve_ohos_sdk)")"
export OHOS_NATIVE_HOME
for tool in clang llvm-ar llvm-ranlib llvm-strings; do
    if [ ! -x "$OHOS_NATIVE_HOME/llvm/bin/$tool" ]; then
        echo "ERROR: missing $OHOS_NATIVE_HOME/llvm/bin/$tool"
        exit 1
    fi
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/remotedesk-openssl-ohos.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

# The archive embeds the compiler command; wrappers keep the SDK path out of it.
mkdir -p "$WORK_DIR/bin"
for pair in "ohos-clang:aarch64-linux-ohos" "ohos-clang-x86_64:x86_64-linux-ohos"; do
    name="${pair%%:*}"; triple="${pair#*:}"
    cat > "$WORK_DIR/bin/$name" <<EOF
#!/bin/sh
exec "\$OHOS_NATIVE_HOME/llvm/bin/clang" --target=$triple --sysroot="\$OHOS_NATIVE_HOME/sysroot" "\$@"
EOF
    chmod +x "$WORK_DIR/bin/$name"
done

ARCHIVE="$WORK_DIR/openssl-${OPENSSL_VERSION}.tar.gz"
echo "Downloading OpenSSL ${OPENSSL_VERSION}"
curl -fsSL -o "$ARCHIVE" "$OPENSSL_URL"
ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$OPENSSL_SHA256" ]; then
    echo "ERROR: OpenSSL archive hash mismatch: $ACTUAL_SHA256"
    exit 1
fi
tar -xzf "$ARCHIVE" -C "$WORK_DIR"
SRC="$WORK_DIR/openssl-${OPENSSL_VERSION}"

build_abi() {
    local abi="$1" target cc build
    case "$abi" in
        arm64-v8a) target=linux-aarch64; cc=ohos-clang; build=build-arm64 ;;
        x86_64) target=linux-x86_64; cc=ohos-clang-x86_64; build=build-x86_64 ;;
        *) echo "ERROR: unknown ABI $abi"; exit 1 ;;
    esac
    echo "Building OpenSSL ${OPENSSL_VERSION} for $abi"
    # Out-of-tree build inside the source tree, as the original archives were
    # built: generated headers then name their templates relative to "..".
    mkdir "$SRC/$build"
    (
        cd "$SRC/$build"
        export PATH="$WORK_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        export CC="$cc" AR="$OHOS_NATIVE_HOME/llvm/bin/llvm-ar" RANLIB="$OHOS_NATIVE_HOME/llvm/bin/llvm-ranlib"
        export SOURCE_DATE_EPOCH
        perl ../Configure "$target" "--prefix=/opt/remotedesk-openssl/$abi" \
            "--openssldir=/opt/remotedesk-openssl/$abi/ssl" "${OPTIONS[@]}" > configure.log 2>&1
        make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" build_libs > build.log 2>&1
    ) || { echo "ERROR: OpenSSL build failed for $abi (log in $SRC/$build)"; trap - EXIT; exit 1; }

    local archive
    for archive in "$SRC/$build/libcrypto.a" "$SRC/$build/libssl.a"; do
        # Strings go to a file first: with pipefail, grep -q closing the pipe
        # early would turn a found leak into a SIGPIPE "no match".
        "$OHOS_NATIVE_HOME/llvm/bin/llvm-strings" -a "$archive" > "$WORK_DIR/strings.txt"
        if grep -e "$WORK_DIR" -e "$PROJECT_DIR" -e '/Users/' -e '/home/' -e '\\Users\\' \
            "$WORK_DIR/strings.txt" > /dev/null; then
            echo "ERROR: $(basename "$archive") embeds a local path"
            exit 1
        fi
    done
    mkdir -p "$INSTALL_ROOT/$abi/lib" "$INSTALL_ROOT/$abi/include/openssl"
    cp "$SRC/$build/libcrypto.a" "$INSTALL_ROOT/$abi/lib/libcrypto.a"
    cp "$SRC/$build/libssl.a" "$INSTALL_ROOT/$abi/lib/libssl.a"
    cp "$SRC/$build/include/openssl/configuration.h" "$INSTALL_ROOT/$abi/include/openssl/configuration.h"
    echo "Installed $abi"
}

case "${1:-all}" in
    arm64-v8a|arm64) build_abi arm64-v8a ;;
    x86_64) build_abi x86_64 ;;
    all) build_abi arm64-v8a; build_abi x86_64 ;;
    *) echo "Usage: $0 [arm64-v8a|x86_64|all]"; exit 1 ;;
esac
echo "Done. Update docs/compliance/THIRD_PARTY_ARTIFACTS.sha256 for the replaced archives."
