import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { cloudLedgerSchema } from '../cloud-ledger.mjs';

const root = dirname(fileURLToPath(import.meta.url));
const lockBytes = readFileSync(join(root, 'package-lock.json'));
const lock = JSON.parse(lockBytes);
const packages = []; const relationships = [];
let notices = '# AGC runtime dependency notices\n\nServer deployment dependencies only; these are not bundled in the HAP.\n' +
  'Versions and archive integrity are pinned by package-lock.json. Installation uses npm ci --ignore-scripts.\n\n';
for (const [path, item] of Object.entries(lock.packages)) {
  if (path === '') continue;
  if (!item.resolved?.startsWith('https://registry.npmjs.org/') || !item.integrity?.startsWith('sha512-')) {
    throw new Error('Unpinned or unexpected dependency source');
  }
  const directory = join(root, path); const pkg = JSON.parse(readFileSync(join(directory, 'package.json')));
  if (pkg.version !== item.version) throw new Error('Installed dependency differs from lock');
  const id = 'SPDXRef-npm-' + path.replace(/[^A-Za-z0-9.-]/g, '-');
  const license = pkg.license === '(WTFPL OR MIT)' ? 'MIT' : pkg.license;
  if (!['MIT', 'ISC'].includes(license)) throw new Error('Dependency license requires explicit review');
  packages.push({ SPDXID: id, name: pkg.name, versionInfo: pkg.version, downloadLocation: item.resolved,
    filesAnalyzed: false, licenseDeclared: pkg.license, licenseConcluded: license, copyrightText: 'NOASSERTION',
    checksums: [{ algorithm: 'SHA512', checksumValue: Buffer.from(item.integrity.slice(7), 'base64').toString('hex') }] });
  relationships.push({ spdxElementId: 'SPDXRef-DOCUMENT', relationshipType: 'DESCRIBES', relatedSpdxElement: id });
  const licenseFiles = readdirSync(directory).filter(name => /^(licen[sc]e|notice|copying)(\.|$)/i.test(name));
  let text = licenseFiles.map(name => readFileSync(join(directory, name), 'utf8')).join('\n\n');
  if (!text) {
    const readme = readFileSync(join(directory, 'README.md'), 'utf8');
    const section = readme.search(/^(?:#+ )?License\s*$/im);
    if (section < 0) throw new Error('Dependency notice unavailable: ' + pkg.name);
    text = readme.slice(section).trim();
  }
  if (pkg.name === '@hw-agconnect/cloud-server') {
    // The publisher ships the ISC declaration in README/package.json; preserve
    // that declaration and the copyright carried in its source headers.
    text += '\n\nCopyright (c) Huawei Technologies Co., Ltd. 2023.\n\n' +
      'ISC License\n\nPermission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted, ' +
      'provided that the above copyright notice and this permission notice appear in all copies.\n\n' +
      'THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF ' +
      'MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES ' +
      'WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN ' +
      'CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.\n';
  }
  notices += '## ' + pkg.name + ' ' + pkg.version + '\n\nSource: ' + item.resolved + '\n\n' + text.trim() + '\n\n';
}
const sbom = { spdxVersion: 'SPDX-2.3', dataLicense: 'CC0-1.0', SPDXID: 'SPDXRef-DOCUMENT',
  name: 'RemoteDesk-Pro-AGC-Node-dependencies',
  documentNamespace: 'https://github.com/Mydstiny/RemoteDeskHarmonyOS/spdx/pro-agc-' + createHash('sha256').update(lockBytes).digest('hex'),
  creationInfo: { created: '2026-09-07T00:00:00Z', creators: ['Organization: RemoteDeskHarmonyOS'] }, packages, relationships };
writeFileSync(join(root, 'SBOM.spdx.json'), JSON.stringify(sbom, null, 2) + '\n');
writeFileSync(join(root, 'THIRD_PARTY_NOTICES.md'), notices.replace(/\r\n?/g, '\n').trimEnd() + '\n');
writeFileSync(join(root, 'ProLedgerRecord.json'), JSON.stringify(cloudLedgerSchema, null, 2) + '\n');
console.log('Generated pinned AGC dependency inventory and schema for ' + packages.length + ' packages.');
