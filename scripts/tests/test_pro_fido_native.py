#!/usr/bin/env python3
"""Build pinned host libraries and execute the production probe and N-API adapter.

Requires host C/C++ compilers, CMake/Ninja, OpenSSL 3 development files, and a
Node runtime with its headers. No USB device or HarmonyOS emulator is used.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('fido_builder', ROOT / 'scripts/build_fido2_ohos.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--openssl-prefix', type=Path, required=True)
    parser.add_argument('--cmake', default=shutil.which('cmake'))
    parser.add_argument('--ninja', default=shutil.which('ninja'))
    parser.add_argument('--node', default=shutil.which('node'))
    parser.add_argument('--node-headers', type=Path, required=True)
    parser.add_argument('--cache-dir', type=Path, default=ROOT / 'build/fido2-downloads')
    parser.add_argument('--sanitize', choices=['none', 'address'], default='none')
    args = parser.parse_args()
    if sys.platform not in ['darwin', 'linux']:
        parser.error('Host runner currently supports macOS and Linux')
    if not args.cmake or not args.ninja or not args.node:
        parser.error('CMake, Ninja and Node are required')
    crypto = args.openssl_prefix / 'lib/libcrypto.a'
    version = re.search(r'OPENSSL_VERSION_TEXT\s+"OpenSSL ([0-9]+\.[0-9]+\.[0-9]+)',
                        (args.openssl_prefix / 'include/openssl/opensslv.h').read_text())
    if not crypto.is_file() or version is None or not version[1].startswith('3.'):
        parser.error('Use an OpenSSL 3 prefix with headers and a host static libcrypto.a')
    cc, cxx = os.environ.get('CC', 'cc'), os.environ.get('CXX', 'c++')
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    lock = json.loads(builder.LOCK.read_text())
    with tempfile.TemporaryDirectory(prefix='remotedesk-fido-host-test-') as directory:
        workspace = Path(directory)
        sources = {}
        for source in lock['sources']:
            archive = builder.source_archive(source, args.cache_dir)
            extracted = builder.extract_source(archive, workspace, source['directory'])
            for patch in source['patches']:
                patch_path = ROOT / patch['path']
                if builder.digest(patch_path) != patch['sha256']:
                    raise ValueError('Patch checksum mismatch')
                subprocess.run(['git', 'apply', '--whitespace=error-all', str(patch_path)], cwd=extracted, check=True)
            sources[source['name']] = extracted
        install = workspace / 'install'
        common = ['-G', 'Ninja', '-DCMAKE_MAKE_PROGRAM=' + args.ninja,
                  '-DCMAKE_C_COMPILER=' + cc, '-DCMAKE_CXX_COMPILER=' + cxx,
                  '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=OFF',
                  '-DCMAKE_C_STANDARD=99', '-DBUILD_SHARED_LIBS=OFF', '-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
                  '-DCMAKE_INSTALL_PREFIX=' + str(install)]
        if sys.platform == 'darwin':
            sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
            common.append('-DCMAKE_OSX_SYSROOT=' + sdk)
            zlib_headers = sdk + '/usr/include'
        else:
            zlib_headers = '/usr/include'
        configurations = [
            ('libcbor', ['-DWITH_TESTS=OFF', '-DWITH_EXAMPLES=OFF', '-DBUILD_TESTING=OFF', '-DSANITIZE=OFF']),
            ('libfido2', ['-DUSE_CUSTOM_IO=ON', '-DUSE_EXPLICIT_DEPENDENCIES=ON', '-DBUILD_TESTS=OFF',
                         '-DBUILD_EXAMPLES=OFF', '-DBUILD_MANPAGES=OFF', '-DBUILD_TOOLS=OFF',
                         '-DNFC_LINUX=OFF', '-DUSE_WINHELLO=OFF', '-DUSE_HIDAPI=OFF', '-DUSE_PCSC=OFF',
                         '-DCBOR_INCLUDE_DIRS=' + str(install / 'include'),
                         '-DCBOR_LIBRARIES=' + str(install / 'lib/libcbor.a'),
                         '-DCRYPTO_INCLUDE_DIRS=' + str(args.openssl_prefix / 'include'),
                         '-DCRYPTO_LIBRARIES=' + str(crypto), '-DCRYPTO_VERSION=' + version[1],
                         '-DZLIB_INCLUDE_DIRS=' + zlib_headers, '-DZLIB_LIBRARIES=-lz'])]
        with (workspace / 'build.log').open('w') as log:
            for name, options in configurations:
                build = workspace / ('build-' + name)
                builder.command([args.cmake, '-S', sources[name], '-B', build, *common, *options], log)
                builder.command([args.cmake, '--build', build, '--parallel', '6'], log)
                builder.command([args.cmake, '--install', build], log)
            flags = ['-std=c++17', '-O2', '-Wall', '-Wextra', '-Werror', '-pthread',
                     '-I' + str(ROOT / 'entry/src/main/cpp/pro'), '-I' + str(install / 'include'),
                     '-I' + str(args.openssl_prefix / 'include')]
            libraries = [install / 'lib/libfido2.a', install / 'lib/libcbor.a', crypto, '-lz']
            if sys.platform == 'linux':
                libraries.append('-ldl')
            implementation = ROOT / 'entry/src/main/cpp/pro/fido_probe_transport.cpp'
            test = workspace / 'probe-test'
            sanitizer = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if args.sanitize == 'address' else []
            builder.command([cxx, *flags, *sanitizer, implementation,
                             ROOT / 'scripts/tests/pro_fido_probe_transport_test.cpp', *libraries, '-o', test], log)
            subprocess.run([str(test)], check=True, timeout=30)
            # Node and HarmonyOS use the same relevant N-API C interface. This
            # adapter compiles the production callbacks without substituting them.
            shim = workspace / 'shim/napi'
            shim.mkdir(parents=True)
            (shim / 'native_api.h').write_text('#include <node_api.h>\n')
            module = workspace / 'addon.cpp'
            module.write_text('#include <node_api.h>\nnamespace ProFidoNapi { napi_value Init(napi_env, napi_value); }\n'
                              'NAPI_MODULE(pro_fido_test, ProFidoNapi::Init)\n')
            shared = ['-bundle', '-undefined', 'dynamic_lookup'] if sys.platform == 'darwin' else ['-shared', '-fPIC']
            addons = []
            for debug in [True, False]:
                addon = workspace / ('probe-debug.node' if debug else 'probe-release.node')
                debug_flags = ['-DREMOTEDESK_DEBUG_FIDO_PROBE=1', implementation, *libraries] if debug else []
                builder.command([cxx, *flags, *shared, '-I' + str(shim.parent), '-I' + str(args.node_headers),
                                 ROOT / 'entry/src/main/cpp/pro/fido_probe_napi.cpp', module,
                                 *debug_flags, '-o', addon], log)
                addons.append(addon)
            subprocess.run([args.node, str(ROOT / 'scripts/tests/test_pro_fido_napi.cjs'),
                            *map(str, addons)], check=True, timeout=30)


if __name__ == '__main__':
    main()
