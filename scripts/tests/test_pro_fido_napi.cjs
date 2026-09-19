/* Executes the actual production N-API callbacks against pinned host libraries.
 * Cross-environment tests use Node workers; they do not claim Ark runtime or
 * HarmonyOS USB hardware acceptance. */
const assert = require('node:assert/strict');
const { Worker, isMainThread, parentPort, workerData } = require('node:worker_threads');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(body) {
  for (let i = 0; i < 200; i++) { const value = body(); if (value) return value; await sleep(2); }
  throw new Error('Native worker did not reach expected state within bound');
}
if (!isMainThread) {
  const api = require(workerData.path);
  if (workerData.action === 'foreign') {
    assert.equal(api.proFidoProbePoll(workerData.id).status, 4);
    assert.equal(api.proFidoProbeReply(workerData.id, 1, new Uint8Array(64), true), false);
    api.proFidoProbeCancel(workerData.id);
    assert.equal(api.proFidoProbeStart(), 0);
    parentPort.postMessage('isolated');
  } else {
    const id = api.proFidoProbeStart(); assert.ok(id > 0);
    parentPort.postMessage(id);
    // Worker termination must wake/join native I/O waits without any reply.
    setInterval(() => {}, 1000);
  }
} else {
  (async () => {
    const [debugPath, releasePath] = process.argv.slice(2);
    const api = require(debugPath), release = require(releasePath);
    assert.equal(release.proFidoProbeAvailable(), false);
    assert.equal(release.proFidoProbeStart(), 0);
    assert.equal(release.proFidoProbePoll(1).status, 4);
    assert.equal(release.proFidoProbeReply(1, 1, new Uint8Array(64), true), false);
    assert.equal(release.proFidoProbeCancel(1), undefined);
    assert.equal(api.proFidoProbeAvailable(), true);
    const id = api.proFidoProbeStart(); assert.ok(id > 0);
    assert.equal(api.proFidoProbeStart(), 0);
    for (const bad of [undefined, null, '1', 0, -1, 0.5, NaN, Infinity, 0x100000000]) {
      assert.equal(api.proFidoProbePoll(bad).status, 4);
      assert.equal(api.proFidoProbeReply(bad, 1, new Uint8Array(64), true), false);
      api.proFidoProbeCancel(bad);
    }
    const request = await until(() => { const value = api.proFidoProbePoll(id); return value.requestId ? value : null; });
    assert.equal(request.data.length, 64); assert.equal(request.write, true);
    assert.equal(request.data[4], 0x86); assert.equal(api.proFidoProbePoll(id).requestId, 0);
    for (const data of [new Uint8Array(63), new Uint8Array(65), new Uint16Array(32), {}, null]) {
      assert.equal(api.proFidoProbeReply(id, request.requestId, data, true), false);
    }
    assert.equal(api.proFidoProbeReply(id, request.requestId + 1, request.data, true), false);
    const foreign = new Worker(__filename, { workerData: { path: debugPath, action: 'foreign', id } });
    await new Promise((resolve, reject) => { foreign.once('message', resolve); foreign.once('error', reject); });
    await foreign.terminate();
    assert.equal(api.proFidoProbePoll(id).status, 0, 'foreign environment cancelled the owner');
    assert.equal(api.proFidoProbeReply(id, request.requestId, request.data, true), true);
    assert.equal(api.proFidoProbeReply(id, request.requestId, request.data, true), false);
    const read = await until(() => { const value = api.proFidoProbePoll(id); return value.requestId ? value : null; });
    assert.equal(read.write, false);
    api.proFidoProbeCancel(id);
    assert.equal(api.proFidoProbeReply(id, read.requestId, read.data, true), false);
    assert.equal(api.proFidoProbePoll(id).status, 3);
    const next = await until(() => api.proFidoProbeStart()); assert.ok(next > id);
    const nextRequest = await until(() => { const value = api.proFidoProbePoll(next); return value.requestId ? value : null; });
    // Poll delivers each request once. Keep its snapshot before checking that
    // cancelling an old generation cannot affect this waiting operation.
    api.proFidoProbeCancel(id);
    const stillRunning = api.proFidoProbePoll(next);
    assert.equal(stillRunning.status, 0); assert.equal(stillRunning.requestId, 0);
    assert.equal(api.proFidoProbePoll(id).status, 4);
    assert.equal(api.proFidoProbeReply(next, nextRequest.requestId, new Uint8Array(0), false), true);
    await until(() => api.proFidoProbePoll(next).status === 2);
    // Retire the failed native worker before moving ownership to a new env.
    await sleep(5);
    const ownedWorker = new Worker(__filename, { workerData: { path: debugPath, action: 'owner' } });
    const workerId = await new Promise((resolve, reject) => {
      ownedWorker.once('message', resolve); ownedWorker.once('error', reject);
    });
    assert.ok(workerId > next); assert.equal(api.proFidoProbePoll(workerId).status, 4);
    assert.equal(api.proFidoProbeStart(), 0);
    const started = Date.now(); await ownedWorker.terminate();
    assert.ok(Date.now() - started < 1000, 'environment cleanup blocked waiting for JS');
    const recovered = await until(() => api.proFidoProbeStart()); assert.ok(recovered > workerId);
    api.proFidoProbeCancel(recovered);
    process.stdout.write('PASS actual N-API validation, once-only requests, generation/environment isolation, cleanup and Release stubs\n');
  })().catch(error => { process.stderr.write(error.stack + '\n'); process.exitCode = 1; });
}
