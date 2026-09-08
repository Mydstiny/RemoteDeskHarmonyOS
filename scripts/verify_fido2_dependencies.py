#!/usr/bin/env python3
"""Check committed FIDO library provenance, exact outputs and compliance records."""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def digest(path, algorithm='sha256'):
    return hashlib.new(algorithm, path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(root):
    lock_path = root / 'docs/compliance/FIDO2_DEPENDENCIES.lock.json'
    lock = json.loads(lock_path.read_text())
    require(lock.get('schema') == 1, 'Unsupported source lock')
    require({x['name'] for x in lock['sources']} == {'libfido2', 'libcbor'} and len(lock['sources']) == 2,
            'Expected one pinned source for each library')
    for source in lock['sources']:
        require(source['url'].startswith('https://') and re.fullmatch('[a-f0-9]{64}', source['sha256']),
                'Missing source URL/hash')
        for patch in source['patches']:
            path = Path(patch['path'])
            require(not path.is_absolute() and '..' not in path.parts, 'Unsafe patch path')
            require(digest(root / path) == patch['sha256'], 'Patch hash mismatch')
    sbom = json.loads((root / 'docs/compliance/SBOM.spdx.json').read_text())
    files = {entry['fileName'].removeprefix('./'): entry for entry in sbom['files']}
    packages = {entry['SPDXID']: entry for entry in sbom['packages']}
    artifacts = (root / 'docs/compliance/THIRD_PARTY_ARTIFACTS.sha256').read_text().splitlines()
    expected_config = {'customIoOnly': True, 'implicitDeviceAccess': False, 'hidapi': False, 'pcsc': False,
                       'nfc': False, 'winhello': False, 'lto': False, 'cStandard': 99}
    owned_hashes = {'libfido2': [], 'libcbor': []}
    owned_ids = {'libfido2': set(), 'libcbor': set()}
    count = 0
    for abi in ['arm64-v8a', 'x86_64']:
        base = root / 'libs/fido2-ohos' / abi
        manifest_path = base / 'manifest.json'
        manifest = json.loads(manifest_path.read_text())
        require(manifest['schema'] == 1 and manifest['architecture'] == abi, 'Wrong ABI manifest')
        require(manifest['generator'] == 'scripts/build_fido2_ohos.py' and
                manifest['generatorSha256'] == digest(root / manifest['generator']), 'Stale generator hash')
        require(manifest['sourceLockSha256'] == digest(lock_path) and manifest['sources'] == lock['sources'],
                'Stale source identities')
        require(manifest['configuration'] == expected_config, 'Unexpected dependency build options')
        deps = manifest['dependencies']
        openssl = root / 'libs/openssl/install' / abi
        require(deps['libcryptoSha256'] == digest(openssl / 'lib/libcrypto.a') and
                deps['opensslVersionHeaderSha256'] == digest(openssl / 'include/openssl/opensslv.h'),
                'Stale OpenSSL build input')
        for value in [*manifest['toolchain'].values(), deps['systemZlibSha256']]:
            require(re.fullmatch('[a-f0-9]{64}', value), 'Missing toolchain/system dependency hash')
        require(not any(path.is_symlink() for path in base.rglob('*')), 'Symlink in dependency outputs')
        actual = {path.relative_to(base).as_posix() for path in base.rglob('*') if path.is_file()}
        require(actual == set(manifest['files']) | {'manifest.json'}, 'Unmanifested/missing output files')
        for name, checksum in manifest['files'].items():
            path = Path(name)
            require(not path.is_absolute() and '..' not in path.parts, 'Unsafe manifest path')
            file = base / path
            require(digest(file) == checksum, 'Output byte mismatch: ' + name)
            relative = file.relative_to(root).as_posix()
            require(relative in files, 'Missing SPDX file: ' + relative)
            record = files[relative]
            require(any(x['algorithm'] == 'SHA256' and x['checksumValue'] == checksum for x in record['checksums']),
                    'Stale SPDX checksum: ' + relative)
            owner = 'libfido2' if name.startswith(('include/fido', 'lib/libfido', 'licenses/libfido')) else 'libcbor'
            owned_hashes[owner].append(digest(file, 'sha1'))
            owned_ids[owner].add(record['SPDXID'])
            if file.suffix == '.a':
                require(artifacts.count(checksum + ' *' + relative) == 1, 'Missing/duplicate artifact hash')
                require(file.read_bytes().startswith(b'!<arch>\n'), 'Expected a portable static archive')
            count += 1
        require(not re.search(r'/Users/|[A-Z]:\\Users\\', manifest_path.read_text()), 'Host path in manifest')
    for source in lock['sources']:
        name = source['name']
        pid = 'SPDXRef-Package-ProFido-' + name
        require(pid in packages, 'Missing SPDX library package')
        package = packages[pid]
        require(package['versionInfo'] == source['version'] and package['downloadLocation'] == source['url'] and
                package['licenseDeclared'] == source['license'] and source['sha256'] in package['sourceInfo'],
                'Stale SPDX source/license identity')
        verification = hashlib.sha1(''.join(sorted(owned_hashes[name])).encode()).hexdigest()
        require(package['packageVerificationCode']['packageVerificationCodeValue'] == verification,
                'Stale SPDX package verification code')
        relationships = [x['relatedSpdxElement'] for x in sbom['relationships']
                         if x['spdxElementId'] == pid and x['relationshipType'] == 'CONTAINS']
        require(len(relationships) == len(owned_ids[name]) and set(relationships) == owned_ids[name],
                'Missing/duplicate SPDX containment')
    public = [x for x in sbom.get('hasExtractedLicensingInfos', []) if x['licenseId'] == 'LicenseRef-Public-Domain']
    require(len(public) == 1 and 'public domain' in public[0]['extractedText'].lower(),
            'Missing exact upstream public-domain declarations')
    for path in ['NOTICE', 'THIRD_PARTY_NOTICES.md', 'docs/compliance/SOURCE_OFFER.md']:
        content = (root / path).read_text()
        require('libfido2' in content and 'libcbor' in content, 'Missing notice/source offer: ' + path)
    print('PASS FIDO dependency lock, patch, both ABI manifests, %d files, SPDX and artifact hashes' % count)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository-root', type=Path, default=ROOT)
    verify(parser.parse_args().repository_root.resolve())
