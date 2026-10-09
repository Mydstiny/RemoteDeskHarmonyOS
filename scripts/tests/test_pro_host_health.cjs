/* 主机健康中心 H0 (plan 2026-10-09 §1): every probe result maps to one of eight states and a code from a closed
 * list; stored observations are validated, capped and ordered; stale results are recognised. */
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
    throw new Error('the health policy must stay pure: unexpected import ' + id);
  }}, { filename: file });
  return module.exports;
}
const h = load('entry/src/main/ets/services/pro/health/HostHealthPolicy.ets');
let passed = 0;
function check(name, body) { body(); passed++; console.log('PASS ' + name); }
const same = (actual, status, code) => assert.deepEqual({ ...actual }, { status, code });

check('RDP preflight codes map stage by stage; a reachable certificate is judged against the one confirmed', () => {
  const rdp = (extra) => h.rdpProbeHealth({ ok: false, errorCode: 0, rootTrusted: false, hostMismatch: false,
    fingerprintSha256: 'AA', savedFingerprintSha256: '', ...extra });
  same(rdp({ errorCode: -10 }), 'unknown', 'E-ENDPOINT-INVALID');
  same(rdp({ errorCode: -11 }), 'route_unavailable', 'E-DNS');
  same(rdp({ errorCode: -12 }), 'route_unavailable', 'E-TCP');
  same(rdp({ errorCode: -14 }), 'timeout', 'E-TIMEOUT');
  same(rdp({ errorCode: -39 }), 'unknown', 'E-NETWORK-CHANGED');
  for (const code of [-13, -18, -19, -20, -21]) same(rdp({ errorCode: code }), 'remote_rejected', 'E-NEGOTIATION');
  for (const code of [-15, -16, -22, -23, -24]) same(rdp({ errorCode: code }), 'remote_rejected', 'E-TLS');
  for (const code of [-17, -25]) same(rdp({ errorCode: code }), 'trust_required', 'E-CERT');
  same(rdp({ errorCode: -999 }), 'unknown', 'E-UNKNOWN');
  same(rdp({ ok: true, rootTrusted: true }), 'reachable', 'OK');
  same(rdp({ ok: true }), 'reachable', 'I-CERT-UNCONFIRMED');
  same(rdp({ ok: true, savedFingerprintSha256: ' aa ' }), 'reachable', 'OK');
  same(rdp({ ok: true, rootTrusted: true, savedFingerprintSha256: 'BB' }), 'trust_required', 'E-CERT-CHANGED');
  same(rdp({ ok: true, rootTrusted: true, hostMismatch: true }), 'reachable', 'I-CERT-UNCONFIRMED');
});

check('RD Gateway route codes', () => {
  same(h.rdpGatewayProbeHealth(''), 'reachable', 'OK');
  same(h.rdpGatewayProbeHealth('E-RDP-GATEWAY-DNS'), 'route_unavailable', 'E-GATEWAY-DNS');
  same(h.rdpGatewayProbeHealth('E-RDP-GATEWAY-TLS'), 'remote_rejected', 'E-GATEWAY-TLS');
  same(h.rdpGatewayProbeHealth('E-RDP-GATEWAY-CERT'), 'trust_required', 'E-GATEWAY-CERT');
  same(h.rdpGatewayProbeHealth('E-RDP-TARGET-CERT'), 'trust_required', 'E-CERT');
  same(h.rdpGatewayProbeHealth('E-RDP-GATEWAY-AUTH-REQUIRED'), 'capability_unsupported', 'E-GATEWAY-AUTH-REQUIRED');
  same(h.rdpGatewayProbeHealth('E-RDP-TARGET-TIMEOUT'), 'timeout', 'E-TIMEOUT');
  same(h.rdpGatewayProbeHealth('E-SOMETHING-NEW'), 'unknown', 'E-UNKNOWN');
});

check('VNC certificate probe categories', () => {
  const vnc = (extra) => h.vncProbeHealth({ ok: false, errorCategory: '', rootTrusted: false, hostMismatch: false,
    fingerprintSha256: 'AA', savedFingerprintSha256: '', ...extra });
  same(vnc({ errorCategory: 'invalid_input' }), 'unknown', 'E-ENDPOINT-INVALID');
  same(vnc({ errorCategory: 'resolve_failed' }), 'route_unavailable', 'E-DNS');
  same(vnc({ errorCategory: 'connect_failed' }), 'route_unavailable', 'E-TCP');
  for (const c of ['resolve_timeout', 'connect_timeout', 'tls_timeout']) same(vnc({ errorCategory: c }), 'timeout', 'E-TIMEOUT');
  for (const c of ['tls_handshake_failed', 'tls_version_rejected', 'tls_context_failed']) {
    same(vnc({ errorCategory: c }), 'remote_rejected', 'E-TLS');
  }
  for (const c of ['no_certificate', 'fingerprint_failed', 'metadata_failed', 'certificate_chain_too_deep']) {
    same(vnc({ errorCategory: c }), 'trust_required', 'E-CERT');
  }
  same(vnc({ errorCategory: 'cancelled' }), 'unknown', 'E-UNKNOWN');
  same(vnc({ ok: true, savedFingerprintSha256: 'CC' }), 'trust_required', 'E-CERT-CHANGED');
});

check('SSH host-key probe: codes, timeout wording, and a changed fingerprint', () => {
  const ssh = (extra) => h.sshProbeHealth({ ok: false, errorCode: 0, errorMessage: '', fingerprintSha256: 'SHA256:x',
    savedFingerprintSha256: '', ...extra });
  same(ssh({ errorCode: -1, errorMessage: 'connect failed' }), 'route_unavailable', 'E-TCP');
  same(ssh({ errorCode: -1, errorMessage: 'Connection timed out' }), 'timeout', 'E-TIMEOUT');
  same(ssh({ errorCode: -3 }), 'remote_rejected', 'E-HANDSHAKE');
  same(ssh({ errorCode: -4 }), 'remote_rejected', 'E-HANDSHAKE');
  same(ssh({ errorCode: -5 }), 'capability_unsupported', 'E-ROUTE-UNSUPPORTED');
  same(ssh({ errorCode: -2 }), 'unknown', 'E-UNKNOWN');
  same(ssh({ ok: true }), 'reachable', 'I-SSH-HOSTKEY-UNSAVED');
  same(ssh({ ok: true, savedFingerprintSha256: 'SHA256:x' }), 'reachable', 'OK');
  same(ssh({ ok: true, savedFingerprintSha256: 'SHA256:y' }), 'trust_required', 'E-HOSTKEY-CHANGED');
});

check('RustDesk and Moonlight presence', () => {
  same(h.rustDeskPresenceHealth(1, false, false), 'reachable', 'OK');
  same(h.rustDeskPresenceHealth(2, false, false), 'peer_offline', 'E-PEER-OFFLINE');
  same(h.rustDeskPresenceHealth(0, false, false), 'unknown', 'E-UNKNOWN');
  same(h.rustDeskPresenceHealth(1, true, false), 'capability_unsupported', 'E-PRESENCE-UNSUPPORTED');
  same(h.rustDeskPresenceHealth(0, false, true), 'timeout', 'E-TIMEOUT');
  same(h.moonlightPresenceHealth(true, true, false), 'reachable', 'OK');
  same(h.moonlightPresenceHealth(true, false, false), 'trust_required', 'E-MOONLIGHT-UNPAIRED');
  same(h.moonlightPresenceHealth(false, false, true), 'timeout', 'E-TIMEOUT');
  same(h.moonlightPresenceHealth(false, false, false), 'peer_offline', 'E-PEER-OFFLINE');
});

check('every code is on the closed list and has words; every state has a label; actions follow the code', () => {
  for (const code of h.HOST_HEALTH_CODES) {
    if (code !== 'OK' && code !== 'E-UNKNOWN') assert.ok(h.hostHealthCodeDetail(code).length > 0, code);
  }
  for (const s of ['reachable', 'route_unavailable', 'timeout', 'trust_required', 'remote_rejected', 'peer_offline',
    'capability_unsupported', 'unknown']) {
    assert.ok(h.isHostHealthStatus(s)); assert.ok(h.hostHealthStatusLabel(s).length > 0);
  }
  assert.equal(h.isHostHealthStatus('online'), false);
  assert.equal(h.hostHealthAction({ status: 'trust_required', code: 'E-CERT-CHANGED' }, 'rdp'), 'confirm_certificate');
  assert.equal(h.hostHealthAction({ status: 'trust_required', code: 'E-HOSTKEY-CHANGED' }, 'ssh'), 'review_fingerprint');
  assert.equal(h.hostHealthAction({ status: 'peer_offline', code: 'E-PEER-OFFLINE' }, 'rustdesk'), 'check_relay');
  assert.equal(h.hostHealthAction({ status: 'peer_offline', code: 'E-PEER-OFFLINE' }, 'moonlight'), 'retry');
  assert.equal(h.hostHealthAction({ status: 'reachable', code: 'OK' }, 'ssh'), 'none');
  const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/services/pro/health/HostHealthPolicy.ets'), 'utf8');
  const used = [...source.matchAll(/verdict\('[a-z_]+', '([A-Z0-9-]+)'\)/g)].map(m => m[1]);
  for (const code of used) assert.ok(h.HOST_HEALTH_CODES.includes(code), 'unlisted code ' + code);
});

check('address family', () => {
  assert.equal(h.healthAddressFamily('192.168.31.5'), 'ipv4');
  assert.equal(h.healthAddressFamily('fe80::1'), 'ipv6');
  assert.equal(h.healthAddressFamily(''), 'unknown');
  assert.equal(h.healthAddressFamily('host.example'), 'unknown');
});

check('stored observations are validated, capped at 20 per host and kept newest first', () => {
  const obs = (at, extra = {}) => ({ schemaVersion: 1, hostId: 'h1', protocol: 'ssh', observedAt: at, status: 'reachable',
    code: 'OK', latencyMs: 12.4, route: 'direct', addressFamily: 'ipv4', source: 'probe', ...extra });
  assert.equal(h.normalizeHostHealthObservation(obs(5)).latencyMs, 12);
  for (const bad of [null, 'x', obs(5, { schemaVersion: 2 }), obs(5, { status: 'online' }), obs(5, { code: 'E-NEW' }),
    obs(0), obs(5, { hostId: '' }), obs(5, { route: 'tunnel' }), obs(5, { source: 'cloud' }), obs(5, { latencyMs: NaN })]) {
    assert.equal(h.normalizeHostHealthObservation(bad), null);
  }
  assert.equal(h.normalizeHostHealthObservation(obs(5, { latencyMs: -7 })).latencyMs, -1);
  let history = [];
  for (let i = 1; i <= 25; i++) history = h.appendHostHealthObservation(history, h.normalizeHostHealthObservation(obs(i * 1000)));
  assert.equal(history.length, 20);
  assert.equal(history[0].observedAt, 25000);
  assert.equal(history[19].observedAt, 6000);
  history = h.appendHostHealthObservation(history, h.normalizeHostHealthObservation(obs(25000, { status: 'timeout', code: 'E-TIMEOUT' })));
  assert.equal(history.filter(o => o.observedAt === 25000).length, 1, 'the same instant replaces, not duplicates');
  history = h.appendHostHealthObservation([...history, { ...obs(99000), hostId: 'other' }], h.normalizeHostHealthObservation(obs(26000)));
  assert.ok(history.every(o => o.hostId === 'h1'), 'one host per history');
});

check('staleness and the age label', () => {
  const now = 10 * 24 * 3600 * 1000;
  assert.equal(h.isHostHealthStale(now - 59 * 60000, now), false);
  assert.equal(h.isHostHealthStale(now - 61 * 60000, now), true);
  assert.equal(h.isHostHealthStale(now + 5 * 60000, now), true, 'a future time is not trusted');
  assert.equal(h.isHostHealthStale(0, now), true);
  assert.equal(h.hostHealthAgeLabel(now - 20000, now), '刚刚');
  assert.equal(h.hostHealthAgeLabel(now - 3 * 60000, now), '3 分钟前');
  assert.equal(h.hostHealthAgeLabel(now - 2 * 3600000, now), '2 小时前');
  assert.equal(h.hostHealthAgeLabel(now - 30 * 3600000, now), '昨天');
  assert.equal(h.hostHealthAgeLabel(now - 3 * 86400000, now), '3 天前');
});

check('H1–H3 wiring: probes record per account, deleted hosts lose history, the sheet, the card note and the AI', () => {
  const read = rel => fs.readFileSync(path.join(root, rel), 'utf8');
  const page = read('entry/src/main/ets/pages/HostListPage.ets');
  for (const fn of ['rdpProbeHealth(', 'rdpGatewayProbeHealth(', 'vncProbeHealth(', 'sshProbeHealth(', 'rustDeskPresenceHealth(']) {
    assert.ok(page.includes(fn), fn + ' feeds the health store');
  }
  assert.ok(page.includes('const healthScope: string = HostHealthStore.getInstance().currentScopeId();'));
  assert.ok(page.includes('HostHealthStore.getInstance().removeHost(host.id);'), 'deleting a host deletes its history');
  assert.ok(page.includes("MenuItem({ content: '健康状况' })"));
  assert.ok(page.includes('this.openHostHealth(targets, \'\');'), 'a batch check opens the grouped result');
  assert.ok(page.includes('this.HostHealthNote(host, this.hostHealthRevision)'));
  assert.ok(page.includes('host.lastHealth as number, host.lastLatency, this.hostHealthForAi(host));'));
  const store = read('entry/src/main/ets/services/pro/health/HostHealthStore.ets');
  assert.ok(store.includes("export const HOST_HEALTH_PREFERENCES_NAME: string = 'ProHostHealth';"), 'a local file of its own');
  assert.ok(store.includes("if (!this.enabled() || scopeId !== this.scope.ownerScopeId) { return false; }"),
    'nothing kept without Pro or after an account switch');
  assert.ok(store.includes("return 'v1|' + owner + '|' + hostId;"), 'keys carry the account');
  const bridge = read('entry/src/main/ets/services/diagnosticAi/AiAppDataBridge.ets');
  assert.ok(bridge.includes("(h.healthCheck !== '' ? ' | ' + h.healthCheck : '')"));
  const catalog = read('entry/src/main/ets/services/pro/ProFeatureCatalog.ets');
  assert.ok(catalog.includes("planned('pro.hostHealth', '主机健康中心',") && catalog.includes("case 'pro.hostHealth':"));
});

console.log('host health: ' + passed + ' checks passed');
