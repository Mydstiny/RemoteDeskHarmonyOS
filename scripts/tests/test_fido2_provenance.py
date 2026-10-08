#!/usr/bin/env python3
"""Negative controls for source extraction, byte manifests and SBOM retention."""
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


builder = load('builder', ROOT / 'scripts/build_fido2_ohos.py')
verifier = load('verifier', ROOT / 'scripts/verify_fido2_dependencies.py')


def rejected(body):
    try:
        body()
    except (ValueError, FileNotFoundError):
        return
    raise AssertionError('Invalid dependency input was accepted')


def main():
    verifier.verify(ROOT)
    with tempfile.TemporaryDirectory(prefix='fido-provenance-test-') as directory:
        base = Path(directory)
        for i, names in enumerate([['pkg/../escape'], ['/pkg/file'], ['other/file'],
                                   ['pkg/file', 'pkg/./file'], ['pkg\\file'], ['pkg/link']]):
            archive = base / ('bad-%d.tar' % i)
            with tarfile.open(archive, 'w') as target:
                for name in names:
                    member = tarfile.TarInfo(name)
                    if name.endswith('link'):
                        member.type = tarfile.SYMTYPE; member.linkname = '/etc/passwd'
                        target.addfile(member)
                    else:
                        member.size = 1; target.addfile(member, io.BytesIO(b'x'))
            rejected(lambda: builder.extract_source(archive, base / ('out-%d' % i), 'pkg'))
        copy = base / 'repo'
        paths = ['docs/compliance/FIDO2_DEPENDENCIES.lock.json', 'docs/compliance/SBOM.spdx.json',
                 'docs/compliance/THIRD_PARTY_ARTIFACTS.sha256', 'docs/compliance/SOURCE_OFFER.md',
                 'NOTICE', 'THIRD_PARTY_NOTICES.md', 'scripts/build_fido2_ohos.py']
        for path in paths:
            target = copy / path; target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / path, target)
        shutil.copytree(ROOT / 'patches/libfido2-ohos', copy / 'patches/libfido2-ohos')
        shutil.copytree(ROOT / 'libs/fido2-ohos', copy / 'libs/fido2-ohos')
        # Verification hashes existing OpenSSL inputs; keep them read-only.
        (copy / 'libs/openssl').symlink_to(ROOT / 'libs/openssl', target_is_directory=True)
        verifier.verify(copy)
        binary = copy / 'libs/fido2-ohos/arm64-v8a/lib/libfido2.a'
        saved = binary.read_bytes(); binary.write_bytes(saved + b'changed')
        rejected(lambda: verifier.verify(copy)); binary.write_bytes(saved)
        extra = copy / 'libs/fido2-ohos/arm64-v8a/unmanifested.txt'; extra.write_text('unrelated')
        rejected(lambda: verifier.verify(copy)); extra.unlink()
        manifest = copy / 'libs/fido2-ohos/x86_64/manifest.json'
        saved = manifest.read_bytes(); data = json.loads(saved); data['configuration']['pcsc'] = True
        manifest.write_text(json.dumps(data)); rejected(lambda: verifier.verify(copy)); manifest.write_bytes(saved)
        patch = copy / 'patches/libfido2-ohos/0001-add-explicit-custom-io-build.patch'
        saved = patch.read_bytes(); patch.write_bytes(saved + b'changed')
        rejected(lambda: verifier.verify(copy)); patch.write_bytes(saved)
        pwsh = shutil.which('pwsh')
        if not pwsh:
            raise RuntimeError('PowerShell 7 is required to test SBOM regeneration preservation')
        runner = base / 'regenerate.ps1'
        runner.write_text('param([string]$Generator, [string]$Root)\n'
                          'function cargo { $global:LASTEXITCODE = 0; return \'{"packages": []}\' }\n'
                          'function git { $global:LASTEXITCODE = 0; return "1111111111111111111111111111111111111111" }\n'
                          '& $Generator -RepositoryRoot $Root\n')
        before = json.loads((copy / 'docs/compliance/SBOM.spdx.json').read_text())
        subprocess.run([pwsh, '-NoProfile', '-File', str(runner),
                        '-Generator', str(ROOT / 'scripts/generate_sbom.ps1'), '-Root', str(copy)], check=True)
        after = json.loads((copy / 'docs/compliance/SBOM.spdx.json').read_text())
        for key in ['packages', 'files']:
            owned = [x for x in before[key] if 'ProFido-' in x['SPDXID']]
            assert owned == [x for x in after[key] if 'ProFido-' in x['SPDXID']]
        assert before['hasExtractedLicensingInfos'] == after['hasExtractedLicensingInfos']
        verifier.verify(copy)
    print('PASS 6 unsafe archive cases, 4 provenance tamper cases and actual SBOM regeneration retention')


if __name__ == '__main__':
    main()
