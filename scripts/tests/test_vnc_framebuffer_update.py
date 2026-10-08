#!/usr/bin/env python3
"""Run the actual RFB engine and socket transport on the host, without a device."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CPP = ROOT / 'entry/src/main/cpp'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--openssl-prefix', type=Path, required=True)
    parser.add_argument('--sanitize', action='store_true')
    args = parser.parse_args()
    sources = ['vnc/vnc_rfb_engine.cpp', 'vnc/vnc_transport.cpp',
               'vnc/vnc_rfb_protocol.cpp', 'vnc/vnc_cursor_protocol.cpp',
               'vnc/vnc_des.cpp', 'vnc/vnc_certificate_probe.cpp',
               'common/happy_eyeballs_connector.cpp', 'common/endpoint_address_policy.cpp',
               'common/network_generation_fence.cpp', 'common/safe_log.cpp']
    with tempfile.TemporaryDirectory(prefix='vnc-update-tests-') as folder:
        binary = Path(folder) / 'test'
        flags = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if args.sanitize else []
        subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-O1', '-g',
                        '-DRDP_TESTS_ONLY=1', '-DRDP_NATIVE_CALLBACK_TESTING=1',
                        '-I' + str(CPP), '-I' + str(args.openssl_prefix / 'include'),
                        *flags, str(ROOT / 'scripts/tests/vnc_framebuffer_update_test.cpp'),
                        *[str(CPP / s) for s in sources],
                        '-L' + str(args.openssl_prefix / 'lib'), '-lssl', '-lcrypto',
                        '-lz', '-pthread', '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=60)


if __name__ == '__main__':
    main()
