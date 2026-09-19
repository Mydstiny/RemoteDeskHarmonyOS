'use strict';

// Each AGC function runs this dedicated deployment. The SDK may log raw error
// objects, so suppress its console output before import. Our callbacks expose
// only bounded business replies or fixed errors; events/secrets are never logged.
const diagnosticLog = console.info.bind(console);
for (const method of ['log', 'info', 'debug', 'warn', 'error']) console[method] = () => {};
let pending;
function runtime() {
  if (!pending) pending = import('./agc/runtime.mjs').then(module => module.createSandboxRuntime({ diagnostic: value => diagnosticLog(JSON.stringify({ event: 'pro_verification_failure', ...value })) }))
    .catch(() => { pending = undefined; throw new Error('sandbox_startup_failed'); });
  return pending;
}
exports.myHandler = function (event, _context, callback) {
  runtime().then(value => value.api.handle(event))
    .then(result => callback(result), () => callback({ version: 1, status: 503, body: '{"error":"verification_unavailable"}' }));
};
// Deploy as a separate function with only a timer trigger. The client function
// never chooses a handler from event input and cannot dispatch this worker.
exports.myWorker = function (_event, _context, callback) {
  runtime().then(value => value.worker()).then(result => callback({ version: 1, status: 200, result }),
    () => callback({ version: 1, status: 503, error: 'worker_unavailable' }));
};
