/* Host regression for the user-controlled Pro catalog visibility store. */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');

function fixture(initial = {}, failPut = false) {
  const modules = new Map();
  const values = {...initial};
  const prefs = {
    getSync: (key, fallback) => Object.prototype.hasOwnProperty.call(values, key) ? values[key] : fallback,
    putSync: (key, value) => {
      if (failPut) { throw new Error('PREFERENCES_WRITE_FAILED'); }
      values[key] = value;
    },
    flushSync: () => {}
  };
  const root = path.resolve(__dirname, '../../entry/src/main/ets');
  function load(file) {
    const absolute = path.resolve(root, file);
    if (modules.has(absolute)) { return modules.get(absolute).exports; }
    const module = {exports: {}};
    modules.set(absolute, module);
    const source = ts.transpileModule(fs.readFileSync(absolute, 'utf8'), {
      compilerOptions: {target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS}
    }).outputText;
    const requireEts = (id) => {
      if (id === '@kit.ArkData') { return {preferences: {getPreferencesSync: () => prefs}}; }
      if (id === '@kit.AbilityKit') { return {}; }
      if (id.startsWith('.')) { return load(path.relative(root, path.resolve(path.dirname(absolute), id + '.ets'))); }
      throw new Error('Unexpected import ' + id);
    };
    vm.runInNewContext(source, {module, exports: module.exports, require: requireEts}, {filename: absolute});
    return module.exports;
  }
  return {load, values};
}

const appIcon = 'pro.personalization.appIcon';
const persisted = JSON.stringify({[appIcon]: false, 'unknown.feature': false, invalid: 'ignored'});
const e = fixture({proFeatureVisibilityV1: persisted});
const {ProFeatureVisibility} = e.load('services/pro/ProFeatureVisibility.ets');
const visibility = ProFeatureVisibility.getInstance();
const context = {};
let notifications = 0;
visibility.subscribe(() => { notifications++; });
assert.equal(visibility.isVisible(appIcon), false);
visibility.load(context);
assert.equal(visibility.isVisible(appIcon), false);
assert.equal(visibility.isVisible('future.pro.feature'), true);
assert.ok(visibility.proCatalog().some(feature => feature.id === appIcon));
assert.ok(notifications >= 2);

assert.equal(visibility.setVisible(context, appIcon, true), true);
assert.equal(visibility.isVisible(appIcon), true);
const saved = JSON.parse(e.values.proFeatureVisibilityV1);
assert.equal(saved[appIcon], true);

const failed = fixture({proFeatureVisibilityV1: JSON.stringify({[appIcon]: true})}, true);
const failedVisibility = failed.load('services/pro/ProFeatureVisibility.ets').ProFeatureVisibility.getInstance();
let failedNotifications = 0;
failedVisibility.subscribe(() => { failedNotifications++; });
failedVisibility.load(context);
assert.equal(failedVisibility.setVisible(context, appIcon, false), false);
assert.equal(failedVisibility.isVisible(appIcon), true);
assert.equal(failedNotifications >= 2, true);
console.log('PASS Pro visibility defaults, persistence, subscriber updates and failed-write rollback');
