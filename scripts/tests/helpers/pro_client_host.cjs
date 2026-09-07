// Host adapters execute the actual ArkTS modules. Node RSA/SQLite validate
// protocol and transaction behavior; native CryptoFramework/RDB remain device gates.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { DatabaseSync } = require('node:sqlite');
const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../../..');
const base = path.join(root, 'entry/src/main/ets/services/pro');

function proClientHost(options = {}) {
  const state = { now: 1788753534000, uptime: 100000, verifies: 0, opens: 0, requests: [], nativeRequests: [], timers: new Map(),
    beforeSql: () => {}, onHttp: async () => { throw new Error('offline'); }, ...options.state };
  const database = new DatabaseSync(':memory:');
  const rdb = {
    get version() { return database.prepare('PRAGMA user_version').get().user_version; },
    set version(value) { database.exec('PRAGMA user_version=' + value); },
    beginTransaction() { database.exec('BEGIN'); }, commit() { database.exec('COMMIT'); },
    rollBack() { database.exec('ROLLBACK'); }, async close() {},
    async executeSql(sql, bindings = []) { await state.beforeSql(sql, bindings); database.prepare(sql).run(...bindings); },
    async querySql(sql, bindings = []) {
      await state.beforeSql(sql, bindings);
      const statement = database.prepare(sql); const rows = statement.all(...bindings);
      const columns = statement.columns().map(column => column.name); let index = -1; let closed = false;
      function value(column) { assert.equal(closed, false); return rows[index][columns[column]]; }
      return { goToFirstRow() { index = 0; return rows.length > 0; },
        goToNextRow() { return ++index < rows.length; },
        getString: column => String(value(column)), getLong: column => Number(value(column)), close() { closed = true; } };
    }
  };
  const util = {
    Base64Helper: class {
      decodeSync(value) { return new Uint8Array(Buffer.from(value, 'base64')); }
      encodeToStringSync(value) { return Buffer.from(value).toString('base64'); }
    },
    TextDecoder: { create: (...args) => ({ decodeToString: data => new TextDecoder(...args).decode(data) }) },
    TextEncoder: class {
      encodeInto(value) { return new TextEncoder().encode(value); }
      encode(value) { return new TextEncoder().encode(value); }
    }
  };
  const cryptoFramework = {
    createAsyKeyGenerator(algorithm) {
      assert.equal(algorithm, 'RSA2048');
      return { async convertKey(pub, pri) {
        assert.equal(pri, null);
        const pubKey = crypto.createPublicKey({ key: Buffer.from(pub.data), format: 'der', type: 'spki' });
        assert.equal(pubKey.asymmetricKeyType, 'rsa'); assert.equal(pubKey.asymmetricKeyDetails.modulusLength, 2048);
        return { pubKey };
      } };
    },
    createVerify(algorithm) {
      assert.equal(algorithm, 'RSA2048|PKCS1|SHA256'); let publicKey;
      return { async init(key) { publicKey = key; }, async verify(data, signature) {
        state.verifies++; return crypto.verify('RSA-SHA256', Buffer.from(data.data), publicKey, Buffer.from(signature.data));
      } };
    },
    createRandom: () => ({ generateRandom: async length => ({ data: new Uint8Array(crypto.randomBytes(length)) }) }),
    createMd(algorithm) {
      assert.equal(algorithm, 'SHA256'); const hash = crypto.createHash('sha256');
      return { updateSync: value => hash.update(Buffer.from(value.data)), digestSync: () => ({ data: new Uint8Array(hash.digest()) }) };
    }
  };
  const http = { RequestMethod: { POST: 'POST' }, HttpDataType: { STRING: 'string' },
    createHttp() {
      const request = { destroyed: 0, destroy() { request.destroyed++; }, async request(url, configuration) {
        const call = { url, configuration, request }; state.requests.push(call); return state.onHttp(call);
      } }; return request;
    }
  };
  state.onAuthorization = async request => ({ state: request.state,
    data: { unionID: 'test-union', authorizationCode: 'fixture-code-' + state.nativeRequests.length } });
  const authentication = {
    HuaweiIDProvider: class { createAuthorizationWithHuaweiIDRequest() { return {}; } },
    AuthenticationController: class {
      constructor(context) { assert.ok(context); }
      async executeRequest(request) { state.nativeRequests.push(request); return state.onAuthorization(request); }
    }
  };
  const defaults = {
    'BuildProfile': { DEBUG: options.debug !== false, VERSION_CODE: 100 },
    '@kit.ArkTS': { util }, '@kit.CryptoArchitectureKit': { cryptoFramework },
    '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: 26, deviceType: '2in1' },
      systemDateTime: { TimeType: { STARTUP: 0 }, getUptime: () => state.uptime } },
    '@kit.NetworkKit': { http }, '@kit.AbilityKit': {}, '@kit.AccountKit': { authentication },
    '@kit.ArkData': { relationalStore: { SecurityLevel: { S3: 3 }, async getRdbStore(_context, config) {
      assert.equal(config.name, 'remotedesk_pro_private_v1.db'); assert.equal(config.encrypt, true);
      assert.equal(config.securityLevel, 3); state.opens++; return rdb;
    } } }
  };
  const modules = new Map(); const mocks = options.mocks || {};
  function load(name) {
    const filename = path.isAbsolute(name) ? name : path.resolve(base, name.endsWith('.ets') ? name : name + '.ets');
    if (mocks[filename]) return mocks[filename];
    if (modules.has(filename)) return modules.get(filename).exports;
    const module = { exports: {} }; modules.set(filename, module);
    const source = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
    }).outputText;
    vm.runInNewContext(source, { module, exports: module.exports, Uint8Array, Map, Set,
      Date: class extends Date { static now() { return state.now; } },
      setTimeout(callback, delay) { const id = Symbol(); state.timers.set(id, { callback, delay }); return id; },
      clearTimeout(id) { state.timers.delete(id); },
      require(id) {
        if (mocks[id]) return mocks[id];
        if (defaults[id]) return defaults[id];
        if (!id.startsWith('.')) throw new Error('Unexpected platform import: ' + id);
        return load(path.resolve(path.dirname(filename), id + '.ets'));
      }
    }, { filename });
    return module.exports;
  }
  return { load, state, database, rdb, close: () => database.close() };
}
function sessionReply(input, owner, now) {
  const body = Buffer.from(JSON.stringify({ challenge: input.challenge, owner })).toString('base64url');
  return { sessionToken: 'eyJhbGciOiJIUzI1NiJ9.' + body + '.' + crypto.randomBytes(32).toString('base64url'),
    owner, challenge: input.challenge, expiresAt: now + 600000 };
}
module.exports = { proClientHost, base, sessionReply };
