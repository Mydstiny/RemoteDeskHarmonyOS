#!/usr/bin/env python3
"""Build and run the RDP security-key broker host test with ASan/UBSan.

The broker is plain C++ and has no FreeRDP, WinPR or libfido2 dependency, so the production source is compiled
directly with the host compiler.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'entry/src/main/cpp/rdp'


def main() -> int:
    # Prefer the host toolchain: scripts/macos_env.sh puts the OpenHarmony cross compiler first on PATH.
    candidates = [os.environ.get('CXX'), '/usr/bin/clang++', shutil.which('clang++'), shutil.which('g++')]
    compiler = next((c for c in candidates if c and Path(c).exists() and 'openharmony' not in c.lower()), None)
    if compiler is None:
        print('SKIP no host C++ compiler', file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix='remotedesk-sk-broker-') as directory:
        binary = Path(directory) / 'broker_test'
        command = [compiler, '-std=c++17', '-g', '-O1', '-Wall', '-Wextra', '-Werror',
                   '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-fno-sanitize-recover=all',
                   '-I', str(SOURCE),
                   str(SOURCE / 'rdp_security_key_broker.cpp'),
                   str(ROOT / 'scripts/tests/rdp_security_key_broker_test.cpp'),
                   '-o', str(binary), '-pthread']
        subprocess.run(command, check=True)
        environment = dict(os.environ, ASAN_OPTIONS='detect_leaks=0', UBSAN_OPTIONS='print_stacktrace=1')
        return subprocess.run([str(binary)], env=environment).returncode


if __name__ == '__main__':
    sys.exit(main())
