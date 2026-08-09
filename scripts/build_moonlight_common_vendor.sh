#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

# shellcheck source=macos_env.sh
. "$script_dir/macos_env.sh"

sdk_native_root="${OHOS_SDK_HOME}/native"
toolchain_file="${sdk_native_root}/build/cmake/ohos.toolchain.cmake"
openssl_root="$project_root/libs/openssl/install"
source_dir="$project_root/entry/src/main/cpp/moonlight/vendor-build"
temporary_root=${TMPDIR:-/private/tmp}
build_root=$(mktemp -d "${temporary_root%/}/remotedesk-moonlight-common.XXXXXX")
llvm_ar="${sdk_native_root}/llvm/bin/llvm-ar"
ninja="${sdk_native_root}/build-tools/cmake/bin/ninja"

if [ ! -f "$toolchain_file" ] || [ ! -x "$llvm_ar" ] || [ ! -x "$ninja" ]; then
  printf '%s\n' "Moonlight vendor build: incomplete API 23 native toolchain" >&2
  exit 1
fi

python3 "$script_dir/verify_moonlight_vendor.py"

for abi in arm64-v8a x86_64; do
  build_dir="$build_root/$abi"
  cmake -S "$source_dir" -B "$build_dir" \
    -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$ninja" \
    -DCMAKE_TOOLCHAIN_FILE="$toolchain_file" \
    -DCMAKE_BUILD_TYPE=Release \
    -DOHOS_ARCH="$abi" \
    -DOHOS_STL=c++_shared \
    -DREMOTEDESK_OPENSSL_ROOT="$openssl_root"
  cmake --build "$build_dir" --target moonlight_vendor_static --parallel

  common_archive="$build_dir/moonlight-common-c-build/libmoonlight-common-c.a"
  enet_archive="$build_dir/moonlight-common-c-build/enet/libenet.a"
  if [ ! -f "$common_archive" ] || [ ! -f "$enet_archive" ]; then
    printf '%s\n' "Moonlight vendor build: missing static output for $abi" >&2
    exit 1
  fi
  members=$($llvm_ar t "$common_archive")
  for required in Connection.c.o PlatformCrypto.c.o VideoStream.c.o AudioStream.c.o InputStream.c.o rs.c.o; do
    if ! printf '%s\n' "$members" | grep -q "^${required}$"; then
      printf '%s\n' "Moonlight vendor build: $abi archive misses $required" >&2
      exit 1
    fi
  done

  common_sha=$(shasum -a 256 "$common_archive" | cut -d ' ' -f 1)
  enet_sha=$(shasum -a 256 "$enet_archive" | cut -d ' ' -f 1)
  expected_common_sha=$(python3 "$script_dir/verify_moonlight_vendor.py" \
    --print-build-receipt "$abi" libmoonlight-common-c.a)
  expected_enet_sha=$(python3 "$script_dir/verify_moonlight_vendor.py" \
    --print-build-receipt "$abi" libenet.a)
  if [ "$common_sha" != "$expected_common_sha" ] || [ "$enet_sha" != "$expected_enet_sha" ]; then
    printf '%s\n' \
      "Moonlight vendor build: deterministic receipt mismatch for $abi" \
      "  common-c actual=$common_sha expected=$expected_common_sha" \
      "  enet actual=$enet_sha expected=$expected_enet_sha" >&2
    exit 1
  fi
  printf '%s\n' \
    "Moonlight vendor build: $abi PASS" \
    "  common-c sha256=$common_sha" \
    "  enet sha256=$enet_sha"
done

printf '%s\n' "Moonlight vendor build root: $build_root"
