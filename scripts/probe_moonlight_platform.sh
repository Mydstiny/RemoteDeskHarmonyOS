#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

# shellcheck source=macos_env.sh
. "$script_dir/macos_env.sh"

sdk_native_root="${OHOS_SDK_HOME}/native"
toolchain_file="${sdk_native_root}/build/cmake/ohos.toolchain.cmake"
probe_root="${TMPDIR:-/private/tmp}/remotedesk-moonlight-platform-probe"

if [ ! -f "$toolchain_file" ]; then
  printf '%s\n' "Moonlight probe: missing OHOS toolchain: $toolchain_file" >&2
  exit 1
fi

for abi in arm64-v8a x86_64; do
  build_dir="$probe_root/$abi"
  cmake -S "$project_root/entry/src/main/cpp" -B "$build_dir" \
    -DCMAKE_TOOLCHAIN_FILE="$toolchain_file" \
    -DCMAKE_BUILD_TYPE=Debug \
    -DOHOS_ARCH="$abi" \
    -DOHOS_STL=c++_shared \
    -DMOONLIGHT_BUILD_PLATFORM_PROBE=ON
  cmake --build "$build_dir" --target moonlight_platform_link_probe --parallel
  probe_binary="$build_dir/moonlight-probe/moonlight_platform_link_probe"
  if [ ! -f "$probe_binary" ]; then
    printf '%s\n' "Moonlight probe: missing output for $abi: $probe_binary" >&2
    exit 1
  fi
  printf '%s\n' "Moonlight probe: $abi PASS ($probe_binary)"
done
