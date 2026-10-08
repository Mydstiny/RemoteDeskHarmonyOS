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

check('SFTP is a popup on every device, with the redesigned pieces and every operation kept', () => {
  const policy = read('services/ssh/sftp/SshSftpWorkspacePolicy.ets');
  assert.match(policy, /export function resolveSshSftpPresentation\(_workbenchEnabled: boolean,\s*_desktop: boolean\): SshSftpPresentation \{\s*return 'sheet';\s*\}/);
  assert.match(page, /private closeSftpPanel\(\): void \{[\s\S]{0,200}?if \(this\.sshWorkbenchEnabled && !this\.sftpUsesRootBindSheet\(\)\) \{/);
  const sftp = page.slice(page.indexOf('// ==================== SFTP (popup on every device)'), page.indexOf('  SftpTransferSheet(rootSheetMountToken: number = 0) {'));
  // No text-button toolbars left; icon tools, file rows, a selection bar and an inline name editor instead.
  assert.doesNotMatch(sftp, /Button\('(上级|刷新|根目录|新建目录|跳转|重命名|进入目录|删除选中项)'\)/);
  for (const piece of ['SftpIconButton({', 'SftpFileRow({', 'SftpActionButton({', 'SftpEmptyState({']) { assert.ok(sftp.includes(piece), piece); }
  // Every operation the old buttons ran is still reachable.
  for (const call of ['this.refreshSftp(this.parentRemotePath(this.sftpPath))', "this.refreshSftp('/')", 'this.gotoSftpPath()',
    'this.refreshSftp(this.sftpPath)', "this.beginSftpName('mkdir')", "this.beginSftpName('rename')", 'void this.makeSftpDir()',
    'void this.renameSftpSelected()', 'this.deleteSftpSelected()', 'this.openSftpSelectedDir()', 'void this.uploadSftpFile()',
    'this.downloadSftpSelected()', 'this.pauseSftpTransfer()', 'void this.resumeSftpTransfer()', 'this.cancelSftpTransfer()',
    'this.retrySftpTransfer()', 'void this.enqueueSftpRemoteBatch(false)', 'void this.enqueueSftpRemoteBatch(true)',
    'this.transferSftpLocalSelectionToCurrent()', 'this.transferSftpCurrentSelectionToLocal()', 'void this.makeSftpPeerDir()',
    'void this.renameSftpPeerSelected()', 'this.deleteSftpPeerSelected()', 'void this.refreshSftpPeer(this.sftpPeerPathInput)',
    'this.useSftpLocalEndpoint()', 'this.openSftpPeerPicker()', 'this.changeSftpPeerHost()', 'void this.openSftpLocalParent()',
    'void this.authorizeLocalProvider()', 'this.cancelRecoveredSftpTask(task)', 'void this.recoverSftpTask(task)']) {
    assert.ok(sftp.includes(call), call);
  }
  // A selected folder opens on a second tap; files dragged in upload from the popup too.
  const ui = read('components/ssh/sftp/SftpUi.ets');
  assert.match(ui, /if \(this\.isDirectory && this\.selected\) \{ this\.onOpen\(\); return; \}/);
  assert.match(page, /\.overlay\(this\.SftpDropHint\(\)\)\s*\.allowDrop\(rootSheetMountToken > 0 && /);
  assert.match(page, /if \(!\(this\.sftpWorkbenchSurfaceActive\(\) \|\| this\.showSftpSheet\) \|\| this\.sftpBusy \|\|/);
});

check('SSH chrome: tints are #AARRGGBB, a single tab is not repeated, symbol back button, key press motion, menu icons', () => {
  for (const file of ['pages/SshTerminal.ets', 'components/ssh/command/SshCommandPalette.ets', 'components/ssh/workspace/SshWorkspaceSideBar.ets',
    'components/ssh/search/SshTerminalSearchBar.ets', 'components/ssh/workspace/SshWorkspacePaneChrome.ets', 'components/ssh/broadcast/SshBroadcastSheet.ets',
    'components/ssh/profile/SshTerminalProfileSheet.ets', 'components/ssh/productivity/SshProductivitySheet.ets', 'components/ssh/sftp/SftpUi.ets']) {
    assert.doesNotMatch(read(file), /accentColor \+ '[0-9A-Fa-f]{2}'/, file + ': an alpha after the RGB digits is a different colour');
  }
  assert.match(page, /private sshStandaloneTabStripVisible\(\): boolean \{\s*return \(this\.sshTabViews\.length > 1 \|\| this\.sftpWorkspaceTabState\.open \|\|/);
  assert.match(page, /SymbolGlyph\(\$r\('sys\.symbol\.chevron_left'\)\)\.fontSize\(20\)\.fontColor\(\[this\.chromeText\(0\.9\)\]\)/);
  assert.doesNotMatch(page, /Text\('<'\)\.fontSize\(20\)/);
  const keys = read('components/VirtualKeyBar.ets');
  assert.equal((keys.match(/\.scale\(\{ x: this\.isPressed\(/g) || []).length, 3, 'keys, arrows and Enter shrink when pressed');
  assert.match(page, /private sshHeaderActionIcon\(action: SshHeaderAction\): Resource \{/);
  assert.match(page, /SymbolGlyph\(this\.sshHeaderActionIcon\(action\)\)/);
});

check('the SSH authentication sheet follows its measured content instead of a fixed tall height', () => {
  assert.match(page, /bindSheet\(\$\$this\.showSshAuthPromptSheet, this\.SshAuthPromptSheet\(\), \{[\s\S]{0,400}?height: this\.sshAuthPromptSheetHeight\(\),/);
  const sizing = page.slice(page.indexOf('private sshAuthPromptSheetHeight(): number {'), page.indexOf('private sshAuthPromptSheetHeight(): number {') + 700);
  assert.ok(sizing.includes('this.sshAuthPromptContentH + (this.isDesktopDevice ? 0 : 24)'), 'content plus the drag bar');
  assert.ok(sizing.includes('this.kbHeight'), 'within the room above the keyboard');
  assert.ok(!sizing.includes('SheetSize.FIT_CONTENT'), 'still a bounded height (API 23 closes a FIT_CONTENT sheet early)');
  // Measured on an inner column, which wraps the content even when the Sheet stretches its root.
  assert.match(page, /\/\/ Measured on this inner column[^\n]*\n\s*Column\(\) \{\s*if \(this\.sshAuthPrompt !== null\) \{/);
});

check('应用分身 says it cannot use Pro instead of offering a purchase that fails (plan B)', () => {
  const policy = read('services/pro/ProClonePolicy.ets');
  assert.ok(policy.includes("export const PRO_CLONE_UNSUPPORTED_LABEL: string = '应用分身暂不支持 Pro';"));
  assert.match(policy, /return isClone && effectiveState === 'free' \? PRO_CLONE_UNSUPPORTED_LABEL : label;/);
  const sheet = read('components/ProPurchaseSheet.ets');
  assert.match(sheet, /\} else if \(this\.clone\) \{[\s\S]{0,300}?Text\(PRO_CLONE_UNSUPPORTED_LABEL\)[\s\S]{0,200}?Text\(PRO_CLONE_NOTICE\)/);
  const cloneFooter = sheet.slice(sheet.indexOf('} else if (this.clone) {'), sheet.indexOf('} else {', sheet.indexOf('} else if (this.clone) {')));
  assert.ok(!cloneFooter.includes("this.operate("), 'no buy or restore in a clone');
  assert.ok(sheet.includes('Text(PRO_CLONE_TRIAL_NOTICE)'));
  assert.ok(sheet.includes('this.proLabel = proCloneLabel(this.clone, snapshot.effectiveState, snapshot.label);'));
  assert.ok(read('pages/HostListPage.ets').includes('this.proStatusLabel = proCloneLabel(AppCloneContext.getInstance().isClone(), pro.effectiveState, pro.label);'));
  const reader = read('services/pro/ProFeatureStatusReader.ets');
  assert.ok(reader.includes("if (status.label === '需要 Pro') { status.detail = proCloneLockedDetail(AppCloneContext.getInstance().isClone(), status.detail); }"));
  assert.ok(fs.existsSync(path.resolve(__dirname, '../../docs/codex/plans/2026-10-08-app-clone-pro-plan.md')), 'plan A is recorded');
});
