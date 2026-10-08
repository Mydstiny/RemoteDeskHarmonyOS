'use strict';

/*
 * SSH session polish (2026-10-08): the command palette floats above the terminal instead of a native Sheet that the
 * keyboard squeezed, PiP is armed again after every background cycle, and the About sheet's contact text and links.
 * Source contracts: these are ArkUI pages.
 */
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

const ETS = path.resolve(__dirname, '../../entry/src/main/ets');
const read = (file) => fs.readFileSync(path.join(ETS, file), 'utf8');

function check(name, body) {
  try { body(); console.log('PASS', name); } catch (error) { console.error('FAIL', name); console.error(error); process.exitCode = 1; }
}

const page = read('pages/SshTerminal.ets');

check('the command palette is a floating layer bounded by the keyboard, not a Sheet', () => {
  assert.doesNotMatch(page, /bindSheet\(\$\$this\.showSshCommandPalette/, 'no native Sheet for the palette');
  assert.match(page, /if \(this\.showSshCommandPalette\) \{\s*Column\(\)[\s\S]{0,400}?\.onClick\(\(\): void => \{ this\.closeSshCommandPalette\(\); \}\)/,
    'a mask that closes it');
  assert.match(page, /if \(this\.showSshCommandPalette\) \{\s*Row\(\) \{\s*this\.sshCommandPaletteSheet\(\)/);
  assert.match(page, /position\(\{ x: this\.sshCommandPaletteCardX\(\), y: this\.sshCommandPaletteTopVp\(\) \}\)/);
  // The list gets the room above the keyboard, under the card's top.
  assert.match(page, /private sshCommandPaletteListMaxVp\(\): number \{[\s\S]*?this\.sshCommandPalettePageH\(\) - this\.sshCommandPaletteTopVp\(\) - this\.kbHeight/);
  assert.match(page, /maxBodyHeightVp: this\.sshCommandPaletteListMaxVp\(\)/);
  // A chosen action still runs after the exit, through the same fenced path as before.
  assert.match(page, /@State @Watch\('onSshCommandPaletteVisibilityChange'\) showSshCommandPalette: boolean = false;/);
  assert.match(page, /private onSshCommandPaletteVisibilityChange\(\): void \{\s*if \(this\.showSshCommandPalette\) \{ return; \}\s*setTimeout\(\(\): void => \{\s*if \(!this\.showSshCommandPalette\) \{ this\.onSshCommandPaletteDisappear\(\); \}\s*\}, SSH_COMMAND_PALETTE_MOTION_MS\);/);
  const palette = read('components/ssh/command/SshCommandPalette.ets');
  // One search capsule (icon, input, clear) beside a close button; the input itself has no second surface.
  assert.match(palette, /SymbolGlyph\(\$r\('sys\.symbol\.magnifyingglass'\)\)/);
  assert.match(palette, /TextInput\(\{ text: this\.query, placeholder: '搜索主机、会话或动作' \}\)[\s\S]{0,700}?\.backgroundColor\(Color\.Transparent\)/);
  assert.doesNotMatch(palette, /TextInput[\s\S]{0,700}?\.shadow\(searchGlassShadow/, 'the shadow is on the capsule, not the input');
  assert.match(palette, /accessibilityText\('清除搜索'\)/);
  assert.doesNotMatch(palette, /Text\('⌕'\)|Button\('×'\)/);
});

check('PiP is armed again after each background cycle, in front only', () => {
  assert.match(page, /if \(!this\.sshContextualGuideInBackground\(\)\) \{\s*this\.scheduleSshContextualGuide\(\);[\s\S]{0,200}?this\.scheduleSshPipRearm\(\);/);
  assert.match(page, /'SSH PiP stopped reason=' \+ reason\);[\s\S]{0,240}?this\.scheduleSshPipRearm\(\);/);
  const rearm = page.slice(page.indexOf('private scheduleSshPipRearm(): void {'), page.indexOf('private clearSshPipRearm(): void {'));
  for (const guard of ['this.terminalClosing', 'this.sessionWindowId.length > 0', 'this.sshContextualGuideInBackground()',
    '!this.connected', 'this.sessionId <= 0', 'this.sshPipService.isPreparedOrPreparing()']) {
    assert.ok(rearm.includes(guard), guard);
  }
  assert.match(page, /aboutToDisappear\(\): void \{\s*this\.clearSshPipRearm\(\);/);
  // An explicit stop never re-arms: the service drops the stop handler before stopping.
  const service = read('services/SshTerminalPipService.ets');
  assert.match(service, /private async stopInternal\(\): Promise<boolean> \{[\s\S]{0,300}?this\.stoppedHandler = null;/);
});

check('About: the developer note, GitHub and Gitee', () => {
  const about = read('components/AboutSettingsSheet.ets');
  assert.ok(about.includes('作者为独立学生开发者，鞭策 AI 辅助开发，资金有限，测试条件不完善，测试设备不够全。'));
  assert.ok(about.includes('任何问题可以通过“反馈”里面的渠道向作者反映。'));
  assert.ok(!about.includes('考研'));
  assert.ok(about.includes("this.openUrl('https://github.com/Mydstiny/RemoteDeskHarmonyOS');"));
  assert.ok(about.includes("this.openUrl('https://gitee.com/Lijiong_Space/RemoteDeskHarmonyOS');"));
});

check('Pro is described as a one-time purchase; intro and update buttons float over their lists', () => {
  assert.ok(read('services/ProTrialStory.ets').includes('Pro 是买断制：一次购买、永久使用，不是订阅，不会自动续费。'));
  assert.ok(!read('services/ProTrialStory.ets').includes('Pro 订阅'));
  for (const file of ['components/guide/ProShowcase.ets', 'components/guide/GuideShowcase.ets']) {
    const text = read(file);
    assert.ok(text.includes('Stack({ alignContent: Alignment.Bottom }) {\n      Scroll() {'), file + ' floats its button over the list');
  }
  assert.match(read('components/guide/ProShowcase.ets'), /padding\(\{ top: 4, bottom: 12 \+ FLOATING_ACTION_ROOM \}\)/);
  assert.match(read('components/guide/GuideShowcase.ets'), /padding\(\{ top: 16, bottom: 12 \+ WHATS_NEW_ACTION_ROOM \}\)/);
});
