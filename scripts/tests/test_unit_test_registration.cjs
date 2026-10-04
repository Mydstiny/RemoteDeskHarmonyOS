/* Every unit-test file must be registered, otherwise ohosTest@OhosTestCompileArkTS
 * never compiles it and the device runner never runs it.
 * - entry/src/test/List.test.ets imports and calls each entry/src/test suite once;
 * - entry/src/ohosTest/ets/test/List.test.ets imports and calls each ohosTest-dir
 *   suite (a call inside a focused scope is enough: integration suites that need a
 *   real server run only on request) and runs the shared list exactly once;
 * - *.test.ets files live only at the top level of both directories.
 * `--self-test` checks that commented-out, missing and duplicate entries fail.
 * Comment stripping is regex-based: keep `//` out of string literals in the Lists. */
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

function stripComments(source) {
  return source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
}

function walkTests(dir, top, errors, label) {
  const names = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name !== 'cpp') { walkTests(full, false, errors, label); }
    } else if (entry.name.endsWith('.test.ets') && entry.name !== 'List.test.ets') {
      if (top) {
        names.push(entry.name.slice(0, -'.ets'.length));
      } else {
        errors.push(label + ' has a test file outside the top level: ' + path.relative(dir, full));
      }
    }
  }
  return names.sort();
}

function defaultImports(source, prefix, errors, label) {
  const result = new Map();
  const escaped = prefix.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&');
  const pattern = new RegExp("^\\s*import (\\w+) from '" + escaped + "([^']+)';", 'gm');
  let match;
  while ((match = pattern.exec(source)) !== null) {
    if (result.has(match[2])) { errors.push(label + ' imports ' + match[2] + ' twice'); }
    result.set(match[2], match[1]);
  }
  return result;
}

function callCount(source, identifier) {
  return (source.match(new RegExp('\\b' + identifier + '\\(', 'g')) || []).length;
}

function check(root) {
  const errors = [];
  const unitDir = path.join(root, 'entry/src/test');
  const deviceDir = path.join(root, 'entry/src/ohosTest/ets/test');
  const unitLabel = 'entry/src/test/List.test.ets';
  const deviceLabel = 'entry/src/ohosTest/ets/test/List.test.ets';

  const unitTests = walkTests(unitDir, true, errors, 'entry/src/test');
  const unitList = stripComments(fs.readFileSync(path.join(unitDir, 'List.test.ets'), 'utf8'));
  const unitImports = defaultImports(unitList, './', errors, unitLabel);
  for (const name of unitTests) {
    const identifier = unitImports.get(name);
    if (identifier === undefined) {
      errors.push(unitLabel + ' does not import ' + name);
    } else if (callCount(unitList, identifier) !== 1) {
      errors.push(unitLabel + ' must call ' + identifier + '() exactly once');
    }
  }
  for (const name of unitImports.keys()) {
    if (!fs.existsSync(path.join(unitDir, name + '.ets'))) {
      errors.push(unitLabel + ' imports missing file ' + name);
    }
  }

  const deviceTests = walkTests(deviceDir, true, errors, 'entry/src/ohosTest/ets/test');
  const deviceList = stripComments(fs.readFileSync(path.join(deviceDir, 'List.test.ets'), 'utf8'));
  const deviceImports = defaultImports(deviceList, './', errors, deviceLabel);
  for (const name of deviceTests) {
    const identifier = deviceImports.get(name);
    if (identifier === undefined) {
      errors.push(deviceLabel + ' does not import ' + name);
    } else if (callCount(deviceList, identifier) < 1) {
      errors.push(deviceLabel + ' never calls ' + identifier + '()');
    }
  }
  const shared = defaultImports(deviceList, '../../../test/', errors, deviceLabel).get('List.test');
  if (shared === undefined) {
    errors.push(deviceLabel + ' does not import the shared entry/src/test list');
  } else if (callCount(deviceList, shared) !== 1) {
    errors.push(deviceLabel + ' must run the shared list exactly once');
  }
  return { errors, unitCount: unitTests.length, deviceCount: deviceTests.length };
}

function selfTest(root) {
  const cases = [
    ['commented-out call', 'entry/src/test/List.test.ets', (s) => s.replace(/^(\s*)(\w+Test\(\);)/m, '$1// $2')],
    ['commented-out import', 'entry/src/test/List.test.ets', (s) => s.replace(/^import /m, '// import ')],
    ['missing shared list call', 'entry/src/ohosTest/ets/test/List.test.ets', (s) => s.replace(/localUnitTestSuite\(\);/, '/* localUnitTestSuite(); */')],
    ['duplicate import', 'entry/src/test/List.test.ets', (s) => s.replace(/^(import \w+)( from '[^']+';)$/m, '$1$2\n$1Again$2')]
  ];
  const failures = [];
  for (const [label, file, mutate] of cases) {
    const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'unit-registration-'));
    try {
      for (const dir of ['entry/src/test', 'entry/src/ohosTest/ets/test']) {
        fs.cpSync(path.join(root, dir), path.join(temp, dir), { recursive: true });
      }
      const target = path.join(temp, file);
      const before = fs.readFileSync(target, 'utf8');
      const after = mutate(before);
      if (after === before) { failures.push(label + ': mutation did not apply'); continue; }
      fs.writeFileSync(target, after);
      if (check(temp).errors.length === 0) { failures.push(label + ': not rejected'); }
    } finally {
      fs.rmSync(temp, { recursive: true, force: true });
    }
  }
  const nested = fs.mkdtempSync(path.join(os.tmpdir(), 'unit-registration-'));
  try {
    for (const dir of ['entry/src/test', 'entry/src/ohosTest/ets/test']) {
      fs.cpSync(path.join(root, dir), path.join(nested, dir), { recursive: true });
    }
    fs.writeFileSync(path.join(nested, 'entry/src/test/helpers/Hidden.test.ets'), 'export default function hidden(): void {}\n');
    if (check(nested).errors.length === 0) { failures.push('nested test file: not rejected'); }
  } finally {
    fs.rmSync(nested, { recursive: true, force: true });
  }
  return failures;
}

const root = path.resolve(__dirname, '../..');
const result = check(root);
if (result.errors.length > 0) {
  for (const error of result.errors) { console.log('FAIL ' + error); }
  process.exit(1);
}
if (process.argv.includes('--self-test')) {
  const failures = selfTest(root);
  for (const failure of failures) { console.log('SELF-TEST FAIL ' + failure); }
  if (failures.length > 0) { process.exit(1); }
  console.log('self-test: commented-out call/import, missing shared run, duplicate import and nested file rejected');
}
console.log('unit test registration: ' + result.unitCount + ' shared suites, ' +
  result.deviceCount + ' device suites registered');
