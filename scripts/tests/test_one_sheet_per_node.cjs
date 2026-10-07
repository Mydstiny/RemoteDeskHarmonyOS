'use strict';
/*
 * One bindSheet per node (2026-10-07). A node holds a single sheet: chaining two .bindSheet() on it makes the closed
 * binding dismiss the open one the moment it appears, while its flag stays true (so later taps do nothing). This hit
 * the remote AI workspace (projects and sessions never opened) and the VNC settings page.
 */
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

const ETS = path.resolve(__dirname, '../../entry/src/main/ets');
function walk(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    return entry.isDirectory() ? walk(full) : entry.name.endsWith('.ets') ? [full] : [];
  });
}
// Between two bindSheets on different nodes there is a closing brace of a component (not the `})` of an options
// object), a new component, a condition, a ForEach or a builder call.
const NEW_NODE = /\n\s*(\}(?!\))|[A-Z][A-Za-z]*\(|if |ForEach|this\.[a-zA-Z]+\(\))/;
const chained = [];
let sheets = 0;
for (const file of walk(ETS)) {
  const source = fs.readFileSync(file, 'utf8');
  const positions = [...source.matchAll(/\.bindSheet\(/g)].map((match) => match.index);
  sheets += positions.length;
  for (let i = 1; i < positions.length; i++) {
    if (!NEW_NODE.test(source.slice(positions[i - 1], positions[i]))) {
      chained.push(path.relative(ETS, file) + ':' + (source.slice(0, positions[i]).split('\n').length));
    }
  }
}
assert.ok(sheets > 20, 'the scan sees the project sheets');
assert.deepEqual(chained, [], 'a node chains two bindSheets: ' + chained.join(', '));

// The fixed pages keep one sheet per node.
const workspace = fs.readFileSync(path.join(ETS, 'pages/RemoteAiWorkspace.ets'), 'utf8');
const build = workspace.slice(workspace.indexOf('  build() {'));
// Projects and sessions became the workspace's home list: details and approval remain, on separate nodes.
assert.equal((build.match(/\.bindSheet\(/g) || []).length, 2);
assert.ok(build.indexOf('Stack() {') < build.indexOf('.bindSheet($$this.showApproval'));
console.log('PASS one bindSheet per node across ' + sheets + ' sheets');
