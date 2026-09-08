#!/usr/bin/env python3
"""Build pinned, custom-I/O-only libfido2/libcbor for the two OHOS ABIs.

Hvigor consumes the committed archives; it never downloads these dependencies.
Source extraction and CMake objects live in a disposable build directory.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / 'docs/compliance/FIDO2_DEPENDENCIES.lock.json'
GENERATOR = 'scripts/build_fido2_ohos.py'
TRIPLES = {'arm64-v8a': 'aarch64-linux-ohos', 'x86_64': 'x86_64-linux-ohos'}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def resolve_sdk(explicit):
    candidates = [Path(explicit)] if explicit else []
    for variable in ['DEVECO_SDK_HOME', 'OHOS_NATIVE_HOME', 'OHOS_SDK_HOME']:
        if os.environ.get(variable):
            candidates.append(Path(os.environ[variable]))
    for abi in TRIPLES:
        cache = ROOT / 'entry/.cxx/default/default/debug' / abi / 'CMakeCache.txt'
        if cache.is_file():
            found = re.search(r'^CMAKE_C_COMPILER:[^=]+=(.+)$', cache.read_text(), re.M)
            if found:
                candidates.append(Path(found[1]).resolve().parents[2])
    for candidate in candidates:
        for native in [candidate, candidate / 'default/openharmony/native', candidate / 'native']:
            if (native / 'build/cmake/ohos.toolchain.cmake').is_file():
                return native.resolve()
    raise ValueError('Specify --native-sdk or a configured DevEco SDK environment')


def source_archive(source, cache):
    archive = cache / source['archive']
    if not archive.exists():
        request = urllib.request.Request(source['url'], headers={'User-Agent': 'RemoteDesk-source-build'})
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read(8 * 1024 * 1024 + 1)
        if len(data) > 8 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != source['sha256']:
            raise ValueError('Unverified source archive: ' + source['name'])
        temporary = archive.with_suffix(archive.suffix + '.download')
        temporary.write_bytes(data)
        temporary.replace(archive)
    if digest(archive) != source['sha256']:
        raise ValueError('Cached source hash mismatch: ' + source['name'])
    return archive


def extract_source(archive, destination, expected_directory):
    with tarfile.open(archive) as source:
        members = source.getmembers()
        names = set()
        if len(members) > 5000 or sum(member.size for member in members) > 64 * 1024 * 1024:
            raise ValueError('Source archive exceeds the extraction budget')
        for member in members:
            path = PurePosixPath(member.name)
            if (path.is_absolute() or '..' in path.parts or not path.parts or
                    '\\' in member.name or path.parts[0] != expected_directory or path.as_posix() in names or
                    not (member.isfile() or member.isdir())):
                raise ValueError('Unsafe source archive member')
            names.add(path.as_posix())
        source.extractall(destination, members=members)
    return destination / expected_directory


def command(args, log):
    try:
        subprocess.run([str(arg) for arg in args], check=True, stdout=log, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError:
        log.flush()
        print(Path(log.name).read_text(errors='replace')[-6000:], file=sys.stderr)
        raise


def license_notices(source, output):
    shutil.copy2(source / 'LICENSE', output / 'libfido2-LICENSE.txt')
    sections = []
    for directory in ['src', 'openbsd-compat']:
        for path in sorted((source / directory).rglob('*')):
            if path.suffix not in ['.c', '.h']:
                continue
            match = re.match(r'\s*(?:/\*.*?\*/\s*)+', path.read_text(), re.S)
            if match:
                sections.append(str(path.relative_to(source)) + '\n' + match[0].strip() + '\n')
    (output / 'libfido2-source-notices.txt').write_text('\n'.join(sections))


def build_abi(abi, native, sources, workspace, output, lock):
    cmake_dir = native / 'build-tools/cmake/bin'
    suffix = '.exe' if os.name == 'nt' else ''
    cmake = cmake_dir / ('cmake' + suffix)
    ninja = cmake_dir / ('ninja' + suffix)
    openssl = ROOT / 'libs/openssl/install' / abi
    version_header = openssl / 'include/openssl/opensslv.h'
    version = re.search(r'OPENSSL_VERSION_TEXT\s+"OpenSSL ([0-9]+\.[0-9]+\.[0-9]+)', version_header.read_text())
    if version is None or int(version[1].split('.')[0]) < 3:
        raise ValueError('libfido2 1.17 requires the matching OpenSSL 3.x archive and headers')
    crypto = openssl / 'lib/libcrypto.a'
    zlib = native / 'sysroot/usr/lib' / TRIPLES[abi] / 'libz.so'
    for required in [cmake, ninja, crypto, zlib]:
        if not required.is_file():
            raise ValueError('Missing cross-build input: ' + str(required))
    build_root = workspace / abi
    install = build_root / 'install'
    prefix_flags = ['-Wno-unused-command-line-argument']
    for path, stable in [(workspace, '/fido2-build'), (ROOT, '/remotedesk'), (native, '/ohos-sdk')]:
        variants = {str(path), str(path.resolve())}
        if str(path).startswith('/private/tmp/'):
            variants.add(str(path).replace('/private/tmp/', '/tmp/', 1))
        prefix_flags += ['-ffile-prefix-map=' + value + '=' + stable for value in sorted(variants)]
    flags = subprocess.list2cmdline(prefix_flags) if os.name == 'nt' else shlex.join(prefix_flags)
    common = ['-G', 'Ninja', '-DCMAKE_MAKE_PROGRAM=' + str(ninja),
              '-DCMAKE_TOOLCHAIN_FILE=' + str(native / 'build/cmake/ohos.toolchain.cmake'),
              '-DOHOS_ARCH=' + abi, '-DCMAKE_BUILD_TYPE=Release', '-DBUILD_SHARED_LIBS=OFF',
              '-DCMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=OFF', '-DCMAKE_C_STANDARD=99',
              '-DCMAKE_POSITION_INDEPENDENT_CODE=ON', '-DCMAKE_C_FLAGS=' + flags,
              '-DCMAKE_INSTALL_PREFIX=' + str(install)]
    targets = [
        ('libcbor', ['-DWITH_TESTS=OFF', '-DWITH_EXAMPLES=OFF', '-DBUILD_TESTING=OFF', '-DSANITIZE=OFF']),
        ('libfido2', ['-DUSE_CUSTOM_IO=ON', '-DUSE_EXPLICIT_DEPENDENCIES=ON', '-DBUILD_TESTS=OFF',
                     '-DBUILD_EXAMPLES=OFF', '-DBUILD_MANPAGES=OFF', '-DBUILD_TOOLS=OFF',
                     '-DUSE_HIDAPI=OFF', '-DUSE_PCSC=OFF', '-DNFC_LINUX=OFF', '-DUSE_WINHELLO=OFF',
                     '-DCBOR_INCLUDE_DIRS=' + str(install / 'include'),
                     '-DCBOR_LIBRARIES=' + str(install / 'lib/libcbor.a'),
                     '-DCRYPTO_INCLUDE_DIRS=' + str(openssl / 'include'), '-DCRYPTO_LIBRARIES=' + str(crypto),
                     '-DCRYPTO_VERSION=' + version[1], '-DZLIB_INCLUDE_DIRS=' + str(native / 'sysroot/usr/include'),
                     '-DZLIB_LIBRARIES=' + str(zlib)])]
    build_root.mkdir(parents=True)
    for name, options in targets:
        build = build_root / name
        with (build_root / (name + '.log')).open('w') as log:
            command([cmake, '-S', sources[name], '-B', build, *common, *options], log)
            command([cmake, '--build', build, '--parallel', '6'], log)
            command([cmake, '--install', build], log)

    stage = build_root / 'publish'
    (stage / 'lib').mkdir(parents=True)
    (stage / 'licenses').mkdir()
    shutil.copytree(install / 'include', stage / 'include')
    for name in ['libcbor.a', 'libfido2.a']:
        archive = install / 'lib' / name
        strings = subprocess.check_output([str(native / 'llvm/bin' / ('llvm-strings' + suffix)), '-a', str(archive)])
        markers = [str(ROOT).encode(), str(workspace).encode(), b'/Users/',
                   b'/tmp/remotedesk-fido2-', b'\\Users\\']
        leaked = [line for line in strings.splitlines() if any(marker in line for marker in markers)]
        if leaked:
            raise ValueError('Host path leaked into ' + name + ': ' +
                             repr(leaked[0].decode(errors='replace')[:240]))
        shutil.copy2(archive, stage / 'lib' / name)
    license_notices(sources['libfido2'], stage / 'licenses')
    shutil.copy2(sources['libcbor'] / 'LICENSE.md', stage / 'licenses/libcbor-LICENSE.txt')
    manifest = {'schema': 1, 'generator': GENERATOR, 'architecture': abi,
                'generatorSha256': digest(__file__),
                'toolchain': {'clangSha256': digest(native / 'llvm/bin' / ('clang' + suffix)),
                              'cmakeToolchainSha256': digest(native / 'build/cmake/ohos.toolchain.cmake')},
                'sourceLockSha256': digest(LOCK), 'sources': lock['sources'],
                'configuration': {'customIoOnly': True, 'implicitDeviceAccess': False,
                                  'hidapi': False, 'pcsc': False, 'nfc': False, 'winhello': False,
                                  'lto': False, 'cStandard': 99},
                'dependencies': {'opensslVersion': version[1], 'libcryptoSha256': digest(crypto),
                                 'opensslVersionHeaderSha256': digest(version_header), 'systemZlibSha256': digest(zlib)},
                'files': {str(path.relative_to(stage)).replace('\\', '/'): digest(path)
                          for path in sorted(stage.rglob('*')) if path.is_file()}}
    (stage / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    destination = output / abi
    if destination.is_symlink():
        raise ValueError('Refusing a symlink output directory')
    if destination.exists():
        previous = json.loads((destination / 'manifest.json').read_text())
        if previous.get('generator') != GENERATOR or previous.get('architecture') != abi:
            raise ValueError('Refusing to replace an output without matching provenance')
        expected = set(previous['files']) | {'manifest.json'}
        actual = {str(path.relative_to(destination)).replace('\\', '/') for path in destination.rglob('*') if path.is_file()}
        if actual != expected or any(path.is_symlink() for path in destination.rglob('*')):
            raise ValueError('Refusing to replace outputs containing unrelated files')
        if any(digest(destination / name) != checksum for name, checksum in previous['files'].items()):
            raise ValueError('Refusing to replace locally modified dependency outputs')
    with tempfile.TemporaryDirectory(prefix='.stage-' + abi + '-', dir=output) as directory:
        staging = Path(directory)
        incoming, previous = staging / 'incoming', staging / 'previous'
        shutil.copytree(stage, incoming)
        if destination.exists():
            destination.rename(previous)
        try:
            incoming.rename(destination)
        except BaseException:
            if previous.exists():
                previous.rename(destination)
            raise
    print(abi + ': libfido2/libcbor custom-I/O archives and byte manifest verified', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('abi', nargs='?', choices=['all', *TRIPLES], default='all')
    parser.add_argument('--native-sdk', type=Path)
    parser.add_argument('--cache-dir', type=Path, default=ROOT / 'build/fido2-downloads')
    parser.add_argument('--output-dir', type=Path, default=ROOT / 'libs/fido2-ohos')
    args = parser.parse_args()
    native = resolve_sdk(args.native_sdk)
    output = args.output_dir.resolve()
    if output == ROOT or output in ROOT.parents or output == native or output in native.parents:
        raise ValueError('Unsafe dependency output root')
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    lock = json.loads(LOCK.read_text())
    with tempfile.TemporaryDirectory(prefix='remotedesk-fido2-') as directory:
        workspace = Path(directory)
        sources = {}
        for source in lock['sources']:
            archive = source_archive(source, args.cache_dir)
            extracted = extract_source(archive, workspace, source['directory'])
            for patch in source['patches']:
                path = ROOT / patch['path']
                if digest(path) != patch['sha256']:
                    raise ValueError('Dependency patch hash mismatch')
                subprocess.run(['git', 'apply', '--check', '--whitespace=error-all', str(path)], cwd=extracted, check=True)
                subprocess.run(['git', 'apply', '--whitespace=error-all', str(path)], cwd=extracted, check=True)
            sources[source['name']] = extracted
        for abi in TRIPLES if args.abi == 'all' else [args.abi]:
            build_abi(abi, native, sources, workspace, output, lock)


if __name__ == '__main__':
    main()
