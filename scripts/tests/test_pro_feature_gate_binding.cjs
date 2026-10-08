/* Execute actual Hvigor-generated gate factory arguments with a child receiver.
 * Build Debug first. Before the fix, enabling Pro loses the parent and crashes
 * on its nested builder; this also protects share/continuation parent state.
 */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.PRO_TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../..');
const generated = process.env.PRO_GATE_GENERATED_ROOT || path.join(root,
  'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/components');
const cases = [
  ['ProAppIconPanel', 'presets', 'pro.personalization.appIcon'],
  ['ProConnectionShareControls', 'controls', 'pro.connection.knockShare'],
  ['ProContinuationControls', 'controls', 'pro.connection.continuation']
];
for (const [name, method, feature] of cases) {
  const text = fs.readFileSync(path.join(generated, name + '.ts'), 'utf8');
  const ast = ts.createSourceFile(name + '.ts', text, ts.ScriptTarget.Latest, true);
  const entries = [];
  function visit(node) {
    if (ts.isNewExpression(node) && node.expression.getText(ast) === 'ProFeatureGate') {
      const params = node.arguments[1];
      entries.push(params.properties.find(prop => prop.name?.getText(ast) === 'content').initializer.getText(ast));
      assert.ok(params.getText(ast).includes(feature));
    }
    ts.forEachChild(node, visit);
  }
  visit(ast); assert.equal(entries.length, 1, name + ' must wire one gate');
  const calls = [], parent = { revision: 0, option() { calls.push(this.revision); } };
  parent[method] = function () { this.option.bind(this)(); };
  const context = vm.createContext({});
  const js = ts.transpileModule('globalThis.make = function () { return (' + entries[0] + '); };', {
    compilerOptions: { target: ts.ScriptTarget.ES2021 }
  }).outputText;
  vm.runInContext(js, context);
  const gate = { content: context.make.call(parent) };
  // Actual generated ProFeatureGate calls content.bind(this) after the branch
  // changes from hidden to visible. Repeat entitlement transitions and remount.
  for (const allowed of [false, true, false, true, true, false, true]) {
    parent.revision++;
    if (allowed) gate.content.bind(gate)();
  }
  assert.deepEqual(calls, [2, 4, 5, 7], name + ': current parent state and receiver must survive gate invocation');
  const remount = { content: context.make.call(parent) };
  remount.content.bind(remount)(); assert.equal(calls.at(-1), 7);
  // Negative control: the previous direct method reference reproduces the
  // missing nested builder rather than silently passing this fixture.
  assert.throws(() => parent[method].bind({})(), /bind/);
  console.log('PASS ' + name + ' generated builder ownership, transitions, remount and old-source negative control');
}
