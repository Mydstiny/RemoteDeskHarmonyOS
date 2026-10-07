'use strict';
// Executes production policy and component methods; platform boundaries are mocked.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.AI_TYPESCRIPT_PATH || 'typescript');
const policyPath = 'entry/src/main/ets/services/ai/AiHostInstallPolicy.ets';
const panelPath = 'entry/src/main/ets/components/ai/AiHostInstallPanel.ets';
function compile(source, context) {
  vm.runInContext(ts.transpileModule(source, { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } }).outputText, context);
}
const moduleHost = { exports: {} };
compile(fs.readFileSync(policyPath, 'utf8'), vm.createContext({ module: moduleHost, exports: moduleHost.exports,
  require: () => { throw Error('Public install policy must not load runtime services'); } }));
const policy = moduleHost.exports;
function panel() {
  const state = { copied: [], opened: [], failCopy: false, properties: null, manual: Promise.resolve() };
  const original = fs.readFileSync(panelPath, 'utf8');
  const source = (original.slice(0, original.indexOf('  build() {')) + '\n}')
    .replace(/^import .*;\n/gm, '').replace(/^@Component\s*$/gm, '')
    .replace(/@(?:StorageProp|Watch)\([^\n]*?\)\s*/g, '').replace(/@(?:State|Prop)\s+/g, '')
    .replace('export struct AiHostInstallPanel', 'class AiHostInstallPanel');
  const context = vm.createContext({ ...policy,
    pasteboard: { MIMETYPE_TEXT_PLAIN: 'text/plain', ShareOption: { LOCALDEVICE: 1 },
      createData: (type, text) => ({ type, text, getProperty: () => ({ shareOption: 2 }),
        setProperty: property => { state.properties = property; } }),
      getSystemPasteboard: () => ({ setDataSync: data => {
        if (state.failCopy) throw Error('Platform copy failed');
        assert.equal(state.properties.shareOption, 1); state.copied.push(data);
      } }) },
    getContext: () => ({ startAbility: want => { state.opened.push(want); return state.manual; } })
  });
  compile(source + '\nglobalThis.Target = AiHostInstallPanel;', context);
  state.page = new context.Target(); state.page.aboutToAppear(); return state;
}
const cases = [
  ['every plugin installs from its reviewed pinned source commit, without an invented release asset', () => {
    const evidence = fs.readFileSync('docs/codex/plans/2026-09-07-remote-ai-agent-install.md', 'utf8') +
      fs.readFileSync('docs/codex/plans/2026-10-07-pi-plugin.md', 'utf8');
    for (const backend of ['codex', 'dsh', 'pi']) {
      const release = policy.aiInstallRelease(backend);
      assert.equal(release.asset, ''); assert.equal(release.sha256, '');
      assert.match(release.commit, /^[0-9a-f]{40}$/);
      for (const field of ['repository', 'version', 'commit']) assert.ok(evidence.includes(release[field]), backend + ' ' + field);
      assert.ok(policy.aiInstallManualUrl(backend).endsWith(release.commit + (backend === 'pi' ? '/README.md' : '/docs/operations.md')));
      for (const mode of ['local', 'lan']) {
        const prompt = policy.aiInstallPrompt(backend, mode);
        for (const field of ['repository', 'version', 'engine', 'commit']) assert.ok(prompt.includes(release[field]));
        assert.ok(prompt.includes('从固定提交的源码安装') && prompt.includes('检出以上完整提交哈希'));
        assert.equal(prompt.includes('尚无发行包'), backend === 'pi', 'only Pi has no release package at all');
        assert.ok(!prompt.includes('资产：') && !prompt.includes('资产 SHA256') && !prompt.includes('/releases/tag/'));
        assert.ok(prompt.includes(policy.aiInstallManualUrl(backend)));
        for (const other of ['codex', 'dsh', 'pi'].filter(value => value !== backend)) {
          assert.ok(!prompt.includes(policy.aiInstallRelease(other).commit), backend + ' names only its own commit');
        }
        if (backend === 'pi') {
          assert.ok(prompt.includes('已登录的模型提供方') && prompt.includes('不读取、不复制 Pi 的凭据'));
          assert.ok(!prompt.includes('Anthropic') && !prompt.includes('Claude'));
          assert.ok(!prompt.includes('docs/agent-deploy.md') && prompt.includes(release.commit + '/docs/compatibility.md'));
          assert.ok(prompt.includes('复制到新对话继续'));
        } else {
          assert.ok(prompt.includes(release.commit + '/docs/agent-deploy.md'));
        }
        if (backend === 'dsh') assert.ok(prompt.includes('npm ci --omit=dev'));
      }
    }
  }],
  ['the Gitee mirror is named only once it exists, after GitHub, with the same commit', () => {
    if (policy.AI_PLUGIN_GITEE_OWNER === '') {
      for (const backend of ['codex', 'dsh', 'pi']) {
        assert.equal(policy.aiInstallMirror(backend), '');
        assert.ok(!policy.aiInstallPrompt(backend, 'lan').includes('gitee.com'));
      }
      return;
    }
    for (const backend of ['codex', 'dsh', 'pi']) {
      const mirror = policy.aiInstallMirror(backend), release = policy.aiInstallRelease(backend);
      assert.match(mirror, /^https:\/\/gitee\.com\/[A-Za-z0-9_.-]+\/remotedesk-(codex|dsh|pi)-plugin$/);
      const prompt = policy.aiInstallPrompt(backend, 'lan');
      assert.ok(prompt.indexOf('https://github.com/' + release.repository) < prompt.indexOf(mirror), 'GitHub first');
      assert.ok(prompt.includes('优先使用 GitHub') && prompt.includes(mirror + '.git') && prompt.includes('哈希不一致就停止'));
    }
  }],
  ['prompts carry each plugin install, service, panel, recovery and pairing steps', () => {
    const ports = { codex: [9443, 9543, 'remotedesk-codex.mjs'], dsh: [9444, 9544, 'remotedesk-dsh.mjs'], pi: [9445, 9545, 'remotedesk-pi.mjs'] };
    for (const backend of ['codex', 'dsh', 'pi']) {
      const [port, panelPort, bin] = ports[backend];
      const local = policy.aiInstallPrompt(backend, 'local'), lan = policy.aiInstallPrompt(backend, 'lan');
      assert.ok(local.includes('init --state ~/.remotedesk/' + backend + ' --host 127.0.0.1 --hosts localhost,127.0.0.1 --port ' + port));
      assert.ok(lan.includes('--host <局域网 IP> --hosts <局域网 IP>,localhost,127.0.0.1 --port ' + port));
      for (const prompt of [local, lan]) {
        assert.ok(prompt.includes('node bin/' + bin + ' panel --state <state> --port ' + panelPort));
        assert.ok(prompt.includes('node bin/' + bin + ' stop --state <state>') && prompt.includes('recover --action inspect'));
        assert.ok(prompt.includes('service --action uninstall') && prompt.includes('--action install'));
        assert.ok(prompt.includes('「全部项目（含电脑 App 里的项目）」'));
      }
      assert.ok(lan.includes('设置 → 远程 AI → 添加主机') && lan.includes('扫描电脑上的配对二维码') && lan.includes('端口 ' + port));
      assert.ok(local.includes('本轮不配对') && !local.includes('扫描电脑上的配对二维码'));
    }
    assert.ok(policy.aiInstallPrompt('codex', 'lan').includes('CODEX_HOME 改为 ~/.codex'));
    assert.ok(policy.aiInstallPrompt('pi', 'lan').includes('pi-gui') && policy.aiInstallPrompt('pi', 'lan').includes('修改前询问'));
    assert.ok(policy.aiInstallPrompt('dsh', 'lan').includes('~/.dsh/profiles/remotedesk'));
  }],
  ['unknown inputs fail and returned metadata cannot mutate authority', () => {
    assert.throws(() => policy.aiInstallRelease('unknown'));
    assert.throws(() => policy.aiInstallPrompt('codex', 'public'));
    const release = policy.aiInstallRelease('codex'); release.sha256 = 'tampered';
    assert.notEqual(policy.aiInstallRelease('codex').sha256, 'tampered');
  }],
  ['local default and selected LAN instructions retain authorization boundaries', () => {
    const state = panel(); assert.equal(state.page.mode, 'local'); assert.equal(state.page.preview, '');
    for (const backend of ['codex', 'dsh']) {
      const local = policy.aiInstallPrompt(backend, 'local');
      assert.ok(local.includes('仅监听电脑回环地址')); assert.ok(local.includes('本轮不进行手机连接'));
      const lan = policy.aiInstallPrompt(backend, 'lan');
      assert.ok(lan.includes('先确认电脑上的监听网卡与端口')); assert.ok(lan.includes('不开放公网'));
      assert.ok(!lan.includes('连接方式：仅本机准备'));
      for (const prompt of [local, lan]) {
        assert.ok(prompt.includes('电脑项目目录尚未指定')); assert.ok(prompt.includes('不自动换 ID 重发'));
        assert.ok(prompt.includes('保持 TLS/mTLS')); assert.ok(prompt.includes('原生审批'));
        assert.ok(!prompt.includes(process.cwd()));
      }
    }
    assert.ok(policy.aiInstallPrompt('dsh', 'local').includes('不接管或重复启动原有 web profile'));
  }],
  ['no copy before preview; copied bytes equal every selected preview', () => {
    const state = panel(), page = state.page; page.copyPreview(); assert.equal(state.copied.length, 0);
    for (const backend of ['codex', 'dsh']) for (const mode of ['local', 'lan']) {
      page.selectBackend(backend); page.selectMode(mode); page.showPreview();
      const preview = page.preview; page.copyPreview();
      assert.equal(state.copied.at(-1).text, preview); assert.equal(state.copied.at(-1).type, 'text/plain');
      assert.ok(page.status.startsWith('已复制')); assert.ok(!/安装成功|已连接/.test(page.status));
    }
    assert.equal(state.opened.length, 0);
  }],
  ['changing options invalidates preview and stale content cannot be copied', () => {
    const state = panel(), page = state.page; page.showPreview(); const old = page.preview;
    page.selectBackend('dsh'); assert.equal(page.preview, ''); page.copyPreview();
    page.preview = old; page.copyPreview(); assert.equal(state.copied.length, 0);
    page.showPreview(); page.selectMode('lan'); assert.equal(page.preview, ''); assert.equal(page.status, '');
    page.copyPreview(); assert.equal(state.copied.length, 0);
  }],
  ['clipboard failures report failure without discarding the preview', () => {
    const state = panel(), page = state.page; page.showPreview(); state.failCopy = true;
    page.copyPreview(); assert.ok(page.status.startsWith('复制失败')); assert.equal(state.copied.length, 0);
    assert.equal(page.preview, policy.aiInstallPrompt('codex', 'local'));
    state.failCopy = false; page.copyPreview(); assert.ok(page.status.startsWith('已复制'));
  }],
  ['background and disposed callbacks perform no clipboard or browser operation', async () => {
    for (const reason of ['background', 'dispose']) {
      const state = panel(), page = state.page; page.showPreview();
      if (reason === 'background') page.inBackground = true; else page.aboutToDisappear();
      page.selectBackend('dsh'); page.selectMode('lan'); page.showPreview(); page.copyPreview(); await page.openManual();
      assert.equal(page.backend, 'codex'); assert.equal(page.mode, 'local');
      assert.equal(state.copied.length + state.opened.length, 0);
    }
  }],
  ['manual opens only the selected immutable document through the browser', async () => {
    const state = panel(), page = state.page;
    for (const backend of ['codex', 'dsh']) {
      page.selectBackend(backend); await page.openManual();
      const want = state.opened.at(-1); assert.equal(want.uri, policy.aiInstallManualUrl(backend));
      assert.equal(want.action, 'ohos.want.action.viewData');
    }
    assert.equal(state.copied.length, 0);
  }],
  ['browser rejection reports fallback but late errors cannot overwrite new selection', async () => {
    for (const reason of ['none', 'backend', 'mode', 'dispose']) {
      let reject; const state = panel(), page = state.page;
      state.manual = new Promise((_resolve, fail) => { reject = fail; });
      const operation = page.openManual();
      if (reason === 'backend') page.selectBackend('dsh');
      if (reason === 'mode') page.selectMode('lan');
      if (reason === 'dispose') page.aboutToDisappear();
      reject(Error('No browser')); await operation;
      if (reason === 'none') assert.ok(page.status.startsWith('无法打开浏览器')); else assert.equal(page.status, '');
    }
  }]
];
(async () => {
  for (const [name, run] of cases) { await run(); console.log('PASS ' + name); }
  console.log('PASS ' + cases.length + ' production install-policy/lifecycle groups; no network or device acceptance');
})().catch(error => { console.error(error); process.exitCode = 1; });
