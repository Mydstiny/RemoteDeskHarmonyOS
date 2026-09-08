/** Real native addon + TLS server: trust, mTLS, framing, cancellation and teardown. */
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, mkdirSync, realpathSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { createServer } from 'node:tls';
import { Worker } from 'node:worker_threads';
import { randomUUID } from 'node:crypto';
const root = resolve(import.meta.dirname, '../..');
const work = mkdtempSync(join(tmpdir(), 'remotedesk-ai-tls-'));
const opensslRoot = process.env.OPENSSL_ROOT || (process.platform === 'darwin'
  ? execFileSync('brew', ['--prefix', 'openssl@3'], { encoding: 'utf8' }).trim() : '/usr');
const openssl = join(opensslRoot, 'bin/openssl');
const run = (args) => execFileSync(openssl, args, { cwd: work, stdio: ['ignore', 'pipe', 'pipe'] });
const native = join(work, 'ai.node');
let passed = 0;
const report = (name) => { passed++; console.log('PASS', name); };
try {
  mkdirSync(join(work, 'napi'));
  writeFileSync(join(work, 'napi/native_api.h'), '#include <node_api.h>\n');
  writeFileSync(join(work, 'module.cpp'), '#include <node_api.h>\nnamespace RemoteAiNapi { napi_value Init(napi_env,napi_value); }\nNAPI_MODULE(ai,RemoteAiNapi::Init)\n');
  const include = process.env.AI_TEST_NODE_INCLUDE || resolve(dirname(realpathSync(process.execPath)), '../include/node');
  execFileSync(process.env.CXX || 'c++', ['-std=c++17', '-shared', '-fPIC', '-pthread', '-Wall', '-Wextra', '-Werror',
    ...(process.platform === 'darwin' ? ['-undefined', 'dynamic_lookup'] : []),
    '-I', work, '-I', include, '-I', join(opensslRoot, 'include'),
    join(root, 'entry/src/main/cpp/ai/ai_tls.cpp'), join(root, 'entry/src/main/cpp/ai/ai_napi.cpp'),
    join(work, 'module.cpp'), '-L', join(opensslRoot, 'lib'), '-lssl', '-lcrypto', '-o', native], { stdio: 'pipe' });
  const api = createRequire(import.meta.url)(native);
  for (const name of ['ca', 'other']) run(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', name + '.key',
    '-out', name + '.pem', '-days', '1', '-subj', '/CN=RemoteDesk fixture ' + name,
    '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign']);
  const generated = await api.aiGenerateIdentity({ id: randomUUID() });
  writeFileSync(join(work, 'client.key'), generated.privateKey, { mode: 0o600 });
  writeFileSync(join(work, 'client.csr'), generated.csr);
  run(['req', '-in', 'client.csr', '-verify', '-noout']);
  assert.match(run(['pkey', '-in', 'client.key', '-text', '-noout']).toString(), /3072 bit/);
  report('native RSA3072 CSR proof of possession');
  writeFileSync(join(work, 'client.ext'), 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n');
  run(['x509', '-req', '-in', 'client.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key', '-set_serial', '10',
    '-days', '1', '-extfile', 'client.ext', '-out', 'client.pem']);
  let serial = 20;
  function certificate(name, san, days = '1', purpose = 'serverAuth') {
    run(['req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', name + '.key', '-out', name + '.csr', '-subj', '/CN=localhost']);
    writeFileSync(join(work, name + '.ext'), 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=' + purpose + '\n' + (san ? 'subjectAltName=' + san + '\n' : ''));
    run(['x509', '-req', '-in', name + '.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key', '-set_serial', String(serial++),
      '-days', days === '-1' ? '1' : days, '-extfile', name + '.ext', '-out', name + '.pem']);
    if (days === '-1') {
      writeFileSync(join(work, 'index.txt'), ''); writeFileSync(join(work, 'serial'), '1000\n');
      writeFileSync(join(work, 'expired.cnf'), '[ca]\ndefault_ca=issuer\n[issuer]\ndatabase=index.txt\nserial=serial\ncertificate=ca.pem\nprivate_key=ca.key\nnew_certs_dir=.\ndefault_md=sha256\npolicy=names\nx509_extensions=extensions\n[names]\ncommonName=supplied\n[extensions]\nbasicConstraints=critical,CA:FALSE\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n');
      run(['ca', '-batch', '-config', 'expired.cnf', '-in', name + '.csr', '-out', name + '.pem', '-startdate', '20000101000000Z', '-enddate', '20000102000000Z']);
    }

  }
  certificate('server', 'DNS:localhost,IP:127.0.0.1');
  certificate('wrong', 'DNS:wrong.invalid');
  certificate('cn', '');
  certificate('expired', 'DNS:localhost', '-1');
  certificate('wildcard', 'DNS:*.fixture.invalid');
  const pem = (name) => readFileSync(join(work, name), 'utf8');
  const base = { address: '127.0.0.1', serverName: 'localhost', ca: pem('ca.pem'),
    certificate: pem('client.pem'), privateKey: pem('client.key'), path: '/v1/rpc', body: '{}', timeoutMs: 2000 };
  async function server(name, action, { tls12 = false, requestCert = true } = {}) {
    const sockets = new Set();
    const srv = createServer({ key: pem(name + '.key'), cert: pem(name + '.pem'), ca: pem('ca.pem'),
      minVersion: tls12 ? 'TLSv1.2' : 'TLSv1.3', maxVersion: tls12 ? 'TLSv1.2' : 'TLSv1.3',
      requestCert, rejectUnauthorized: requestCert }, socket => {
      sockets.add(socket); socket.on('close', () => sockets.delete(socket)); socket.on('error', () => {});
      let buffer = '';
      socket.on('data', bytes => { buffer += bytes; if (buffer.includes('\r\n\r\n')) { socket.removeAllListeners('data'); action(socket); } });
    });
    srv.on('tlsClientError', () => {});
    await new Promise((resolve, reject) => { srv.once('error', reject); srv.listen(0, '127.0.0.1', resolve); });
    return { port: srv.address().port, close: async () => { for (const s of sockets) s.destroy(); await new Promise(r => srv.close(r)); } };
  }
  const send = (port, extra = {}, onChunk) => api.aiTlsRequest({ ...base, port, id: randomUUID(), ...extra }, onChunk);
  const good = await server('server', socket => socket.end('HTTP/1.1 200 OK\r\nContent-Length: 15\r\n\r\n{"result":true}'));
  try {
    const response = await send(good.port); assert.equal(response.status, 200);
    assert.equal(Buffer.from(response.body).toString(), '{"result":true}'); report('CA-only TLS1.3 + mTLS RPC');
    await assert.rejects(send(good.port, { ca: pem('other.pem') }), /AI_TLS_IDENTITY_REJECTED|AI_CLIENT_CERTIFICATE_REJECTED/);
    report('wrong CA rejected');
    await assert.rejects(send(good.port, { serverName: '.localhost' }), /AI_ENDPOINT_INVALID/); report('reference DNS suffix pattern rejected');
    await assert.rejects(send(good.port, { serverName: 'localhost%zone' }), /AI_ENDPOINT_INVALID/); report('DNS zone truncation rejected');
    await assert.rejects(send(good.port, { serverName: 'wrong.invalid' }), /AI_TLS_IDENTITY_REJECTED/); report('wrong DNS SAN rejected');
    assert.equal((await send(good.port, { serverName: '127.0.0.1' })).status, 200); report('IP SAN accepted');
    await assert.rejects(send(good.port, { serverName: '127.0.0.2' }), /AI_TLS_IDENTITY_REJECTED/); report('wrong IP SAN rejected');
    await assert.rejects(send(good.port, { privateKey: pem('server.key') }), /AI_IDENTITY_INVALID/); report('client certificate private-key mismatch rejected');
    await assert.rejects(send(good.port, { certificate: pem('server.pem'), privateKey: pem('server.key') }), /AI_CLIENT_CERTIFICATE_REJECTED/); report('server-only certificate rejected for client identity');
    await assert.rejects(send(good.port, { address: 'localhost' }), /AI_HOST_NOT_FOUND/); report('native DNS forbidden; no blocking resolver');
    await assert.rejects(send(good.port, { path: '/v1/rpc\r\nBad: yes' }), /AI_REQUEST_PATH_INVALID/); report('HTTP path injection rejected');
    const pair = await send(good.port, { path: '/v1/pair', certificate: '', privateKey: '' }).catch(e => e);
    assert.ok(pair instanceof Error); report('server mTLS rejection preserved');
  } finally { await good.close(); }
  for (const name of ['wrong', 'cn', 'expired', 'wildcard']) {
    const bad = await server(name, () => assert.fail('application bytes reached invalid server'));
    try { await assert.rejects(send(bad.port, name === 'wildcard' ? { serverName: 'one.fixture.invalid' } : {}), /AI_TLS_IDENTITY_REJECTED/); report(name + ' identity rejected before HTTP'); }
    finally { await bad.close(); }
  }
  const legacy = await server('server', () => assert.fail('TLS1.2 connected'), { tls12: true });
  try { await assert.rejects(send(legacy.port), /AI_TLS_IDENTITY_REJECTED/); report('TLS1.2 rejected'); }
  finally { await legacy.close(); }
  const framingCases = [
    ['chunked fragmented', 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n', 'abcde'],
    ['duplicate length', 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\nab', /AI_HTTP_DUPLICATE_LENGTH/],
    ['ambiguous framing', 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n', /AI_HTTP_AMBIGUOUS_LENGTH/],
    ['oversize body', 'HTTP/1.1 200 OK\r\nContent-Length: 16000001\r\n\r\n', /AI_HTTP_LENGTH_INVALID/],
    ['truncated body', 'HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nab', /AI_HTTP_TRUNCATED/],
    ['invalid chunk', 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n', /AI_HTTP_LENGTH_INVALID/],
  ];
  for (const [name, wire, expected] of framingCases) {
    const srv = await server('server', socket => { for (const byte of Buffer.from(wire)) socket.write(Buffer.of(byte)); socket.end(); });
    try {
      if (typeof expected === 'string') assert.equal(Buffer.from((await send(srv.port)).body).toString(), expected);
      else await assert.rejects(send(srv.port), expected);
      report(name);
    } finally { await srv.close(); }
  }
  const streamPath = '/v1/events?cursor=0&runtime=fixture';
  const eventBody = 'id: 1\ndata: {"cursor":1,"event":{"text":"中文"}}\n\n';
  const stream = await server('server', socket => socket.end('HTTP/1.1 200 OK\r\nContent-Length: ' + Buffer.byteLength(eventBody) + '\r\n\r\n' + eventBody));
  try {
    let received = '';
    await send(stream.port, { path: streamPath, body: '' }, bytes => received += Buffer.from(bytes).toString());
    assert.equal(received, eventBody); report('all SSE chunks precede terminal Promise');
    await assert.rejects(send(stream.port, { path: streamPath, body: '' }, () => { throw new Error('consumer failed'); }), /AI_STREAM_CALLBACK_FAILED/);
    report('throwing stream callback rejected without uncaught exception');
  } finally { await stream.close(); }
  const idle = await server('server', socket => socket.write('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'));
  try {
    const id = randomUUID();
    const pending = send(idle.port, { id, path: streamPath, body: '' }, () => {});
    setTimeout(() => api.aiCancelRequest({ id }), 100);
    await assert.rejects(pending, /AI_REQUEST_CANCELLED/); report('idle stream cancellation drains native worker');
    await assert.rejects(send(idle.port, { timeoutMs: 150 }), /AI_REQUEST_TIMEOUT_RECONCILE/); report('bounded idle timeout');
    const worker = new Worker(`const {parentPort,workerData}=require('node:worker_threads'); const a=require(workerData.native); a.aiTlsRequest(workerData.request,()=>{}).catch(()=>{}); parentPort.postMessage('started');`, {
      eval: true, workerData: { native, request: { ...base, id: randomUUID(), port: idle.port, path: streamPath, body: '', timeoutMs: 60000 } },
    });
    await new Promise((r, j) => { worker.once('message', r); worker.once('error', j); });
    const start = Date.now(); await worker.terminate(); assert.ok(Date.now() - start < 3000); report('environment teardown cancels and joins live SSE');
  } finally { await idle.close(); }
  console.log(`Native AI transport: ${passed} checks passed`);
} finally { rmSync(work, { recursive: true, force: true }); }
