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
assert.deepEqual(p.smartGroup(hosts, 'recent', '', now), ['h1', 'h2']);
assert.equal(p.subnetMatches('192.168.31.77', '192.168.31.0/24'), true);
assert.equal(p.subnetMatches('192.168.32.1', '192.168.31.0/24'), false);
assert.equal(p.subnetMatches('10.1.2.3', '10.0.0.0/8'), true);
assert.equal(p.subnetForAddress('192.168.31.10'), '192.168.31.0/24'); assert.equal(p.subnetForAddress('a.example'), '');
assert.equal(p.subnetSuggestions(hosts)[0], '192.168.31.0/24');
assert.equal(JSON.stringify(p.parseHostFilterKey('group:abc')), JSON.stringify({ kind: 'group', value: 'abc' }));
assert.equal(p.parseHostFilterKey('group:').kind, 'all'); assert.equal(p.parseHostFilterKey('bogus').kind, 'all');
assert.equal(p.hostFilterKey({ kind: 'tag', value: '生产' }), 'tag:生产');
const m = p.emptyMembership();
assert.equal(p.hostMatchesFilter(hosts[0], m, { kind: 'unassigned', value: '' }, now), true);
assert.equal(p.hostMatchesFilter(hosts[0], { groupId: 'g', tags: ['a'], updatedAt: 0 }, { kind: 'tag', value: 'a' }, now), true);
let by = p.assignGroupIn({ h1: { groupId: '', tags: ['keep'], updatedAt: 0 } }, ['h1', 'vnc:7'], 'g', now);
assert.equal(by.h1.groupId, 'g'); assert.equal(by.h1.tags.join(), 'keep'); assert.equal(by['vnc:7'].groupId, 'g');
by = p.addTagsIn(by, ['h1'], ['生产', 'keep'], now); assert.equal(by.h1.tags.join(), 'keep,生产');
by = p.renameTagIn(by, 'keep', '生产', now); assert.equal(by.h1.tags.join(), '生产');
assert.equal(JSON.stringify(p.tagUsage(by)), JSON.stringify([{ tag: '生产', count: 1 }]));
by = p.assignGroupIn(by, ['vnc:7'], '', now); assert.equal(by['vnc:7'], undefined);
assert.equal(p.danglingRefs({ ...by, gone: { groupId: 'g', tags: [], updatedAt: 0 } }, ['h1']).join(), 'gone');
assert.equal(JSON.stringify(Object.keys(p.pruneMembership({ ...by, gone: { groupId: 'g', tags: [], updatedAt: 0 } }, ['h1']))), '["h1"]');
assert.equal(p.groupMemberCounts(by, ['h1']).g, 1);
const gs = [0, 1, 2].map(i => ({ id: 'g' + i, name: 'G' + i, color: '#007DFF', icon: '📁', order: i, createdAt: 0, updatedAt: 0 }));
assert.equal(p.moveGroupIn(gs, 'g2', -1, now).map(g => g.id).join(), 'g0,g2,g1');
assert.equal(p.moveGroupIn(gs, 'g0', -1, now).map(g => g.id).join(), 'g0,g1,g2');
assert.equal(p.nextGroupName([{ ...gs[0], name: '分组 1' }]), '分组 2');
assert.equal(p.HOST_GROUP_COLORS.length, 12); assert.equal(p.HOST_GROUP_ICONS.length, 24);
assert.deepEqual(p.smartGroup(hosts, 'online', '', now), ['h1', 'h3']);
assert.deepEqual(p.smartGroup(hosts, 'subnet', '192.168.31.', now), ['h1', 'h2', 'h3']);
assert.equal(p.duplicateHostGroups(hosts.concat([host('h4', 'ssh', '192.168.31.10', 22, 'root')])).length, 1);
const b = load('entry/src/main/ets/services/pro/org/HostBatchEditPolicy.ets');
const diffs = b.batchEditDiff([{ id: 'h1', protocol: 'ssh', values: { port: 22 } }, { id: 'h2', protocol: 'rdp', values: { port: 3389 } }],
  [{ field: 'port', value: 2222, enabled: true }, { field: 'rdpColorDepth', value: 24, enabled: true }, { field: 'password', value: 'x', enabled: true }]);
assert.equal(diffs.length, 4); assert.equal(diffs[0].skipped, true); assert.equal(diffs[1].skipped, true); assert.equal(diffs[2].skipped, false);
assert.equal(diffs[3].skipped, false); assert.equal(diffs[3].newValue, '24 位');
assert.equal(b.batchEditDiff([{ id: 'h', protocol: 'rdp', values: { port: 3389 } }], [{ field: 'port', value: 3389, enabled: true }])[0].unchanged, true);
assert.equal(b.batchEditDiff([{ id: 'h', protocol: 'rdp', values: { port: 22 } }], [{ field: 'port', value: 70000, enabled: true }]).length, 0);
assert.equal(b.validBatchValue('sshKeyId', ''), false); assert.equal(b.validBatchValue('sshKeyId', 'k1'), true);
assert.equal(b.batchEditDiff([{ id: 'r', protocol: 'rustdesk', values: { port: 1 } }],
  [{ field: 'port', value: 2, enabled: true }])[0].skipped, true);
assert.equal(b.batchFieldAllowed('password'), false); assert.equal(b.batchFieldAllowed('sshKeyData'), false);
assert.equal(b.isSensitiveBatchField('password'), true); assert.equal(b.isSensitiveBatchField('port'), false);
const e = load('entry/src/main/ets/services/pro/org/HostExportPolicy.ets');
const exported = e.exportHosts([{ ...hosts[0], password: 'secret', privateKey: 'pem' }], snapshot.groups, now);
assert.equal(e.exportContainsSensitiveFields(exported), false);
assert.equal(e.parseHostExport(exported).hosts[0].id, 'h1');
assert.equal(e.dedupeImportedHosts([hosts[0], host('new', 'ssh', '10.0.0.1', 22, 'root')], hosts).length, 1);
assert.match(e.hostExportFileName(Date.UTC(2026, 9, 1, 12)), /^RemoteDesk-hosts-202610\d\d\.json$/);
assert.equal(e.hostImportSupported('rdp'), true); assert.equal(e.hostImportSupported('rustdesk'), false);
assert.equal(e.parseHostExport(JSON.stringify({ schemaVersion: 1, exportedAt: 1, groups: [{ id: 1 }],
  hosts: [{ id: 'x', protocol: 'ssh', host: 5, port: 'bad', label: 'L', password: 'p' }, null] })).hosts[0].host, '');
assert.equal(e.parseHostExport('{"schemaVersion":1,"groups":[],"hosts":[{"protocol":"ssh","label":"a","port":22,"host":"h","username":"u","privateKey":"k"}]}').hosts[0].privateKey, undefined);
assert.equal(e.parseHostExport('not json'), null);
console.log('PASS Pro host organization, batch-edit and export policies');
