const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
function load(relative) {
  const file = path.join(root, relative);
  const module = { exports: {} };
  const source = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  vm.runInNewContext(source, { module, exports: module.exports, require: id => {
    if (id.startsWith('.')) return load(path.relative(root, path.resolve(path.dirname(file), id + '.ets')));
    throw new Error('unexpected import ' + id);
  }}, { filename: file });
  return module.exports;
}
const p = load('entry/src/main/ets/services/pro/org/HostOrganizationPolicy.ets');
const now = 10_000_000;
const host = (id, protocol, address, port, username, extra = {}) => ({ id, protocol, host: address, port, username, label: id, ...extra });
assert.equal(p.hostRefForProtocol('vnc', '7'), 'vnc:7');
assert.equal(JSON.stringify(p.hostRefParts('vnc:7')), JSON.stringify({ protocol: 'vnc', id: '7' }));
assert.equal(p.normalizeOrganizationName('  Team   A  '), 'Team A');
assert.equal(p.normalizeTags(['prod', 'prod', '  client  ', 'x'.repeat(80)]).join(','), 'prod,client');
const snapshot = p.emptyOrganization(now);
snapshot.groups.push({ id: 'prod', name: '生产', color: '#007DFF', icon: 'folder', order: 0, createdAt: now, updatedAt: now });
snapshot.byHost['h1'] = { groupId: 'prod', tags: ['prod'], updatedAt: now };
assert.equal(JSON.stringify(p.validateOrganization(snapshot)), '[]');
assert.ok(p.validateOrganization({ ...snapshot, groups: Array.from({ length: 101 }, (_, i) => ({ ...snapshot.groups[0], id: 'g' + i })) }).includes('group_limit'));
const hosts = [host('h1', 'ssh', '192.168.31.10', 22, 'root', { lastConnected: now - 1000, nowOnline: true }),
  host('h2', 'ssh', '192.168.31.11', 22, 'root', { lastConnected: now - 20 * 60 * 1000, nowOnline: false }),
  host('h3', 'rdp', '192.168.31.10', 3389, 'root', { nowOnline: true })];
assert.deepEqual(p.smartGroup(hosts, 'recent', '', now), ['h1']);
assert.deepEqual(p.smartGroup(hosts, 'online', '', now), ['h1', 'h3']);
assert.deepEqual(p.smartGroup(hosts, 'subnet', '192.168.31.', now), ['h1', 'h2', 'h3']);
assert.equal(p.duplicateHostGroups(hosts.concat([host('h4', 'ssh', '192.168.31.10', 22, 'root')])).length, 1);
const b = load('entry/src/main/ets/services/pro/org/HostBatchEditPolicy.ets');
const diffs = b.batchEditDiff([{ id: 'h1', protocol: 'ssh', port: 22 }, { id: 'h2', protocol: 'rdp', port: 3389 }],
  [{ field: 'port', value: 2222, enabled: true }, { field: 'rdpGateway', value: 'gw', enabled: true }, { field: 'password', value: 'x', enabled: true }]);
assert.equal(diffs.length, 4); assert.equal(diffs[0].skipped, false); assert.equal(diffs[1].skipped, true);
assert.equal(b.isSensitiveBatchField('password'), true); assert.equal(b.isSensitiveBatchField('port'), false);
const e = load('entry/src/main/ets/services/pro/org/HostExportPolicy.ets');
const exported = e.exportHosts([{ ...hosts[0], password: 'secret', privateKey: 'pem' }], snapshot.groups, now);
assert.equal(e.exportContainsSensitiveFields(exported), false);
assert.equal(e.parseHostExport(exported).hosts[0].id, 'h1');
assert.equal(e.dedupeImportedHosts([hosts[0], host('new', 'ssh', '10.0.0.1', 22, 'root')], hosts).length, 1);
console.log('PASS Pro host organization, batch-edit and export policies');
