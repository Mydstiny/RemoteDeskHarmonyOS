'use strict';
// Remote AI polish (2026-10-07): the composer's one line sits in the middle of its row, 正在思考 has light flowing
// across it, the conversation list takes a pull from anywhere, and the model sheet is sized to its content.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const ETS = path.resolve(__dirname, '../../entry/src/main/ets');
const page = fs.readFileSync(path.join(ETS, 'pages/RemoteAiWorkspace.ets'), 'utf8');
const shimmer = fs.readFileSync(path.join(ETS, 'components/ai/AiShimmerText.ets'), 'utf8');

// Line height plus padding equal the minimum height, so the placeholder is centred (it rode ~3 vp high).
assert.ok(page.includes('.lineHeight(this.composerLine())'));
assert.ok(page.includes('.constraintSize({ minHeight: this.composerLine() + 2 * this.composerPad()'));
assert.ok(page.includes('.padding({ left: 6, right: 6, top: this.composerPad(), bottom: this.composerPad() })'));
assert.ok(page.includes('.placeholderFont({ size: this.textSize + 1'));
assert.ok(!page.includes('minHeight: 40, maxHeight'));

// 正在思考 (and Claude's 正在工作…) shimmer; the old opacity pulse is gone.
assert.equal((page.match(/AiShimmerText\(\{/g) || []).length, 3);
assert.ok(!page.includes('this.pulse'));
assert.ok(shimmer.includes('.blendMode(BlendMode.SRC_ATOP)') && shimmer.includes('BlendApplyType.OFFSCREEN'));
assert.ok(shimmer.includes('iterations: -1'));
assert.ok(shimmer.includes("return '#00' +"), 'the clear stop is #00RRGGBB');
assert.ok(!shimmer.includes("height('100%')"), 'a 100% band stretched the 正在思考 row to the whole list');

// Pull to refresh: the list fills Refresh and keeps its spring edge even when short.
assert.ok(page.includes(".edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })"));
assert.ok(page.includes("}.width('100%').height('100%').padding({ left: 16, right: 16 }).scrollBar(BarState.Auto)"));

// Messages sit above the composer (the conversation stacks from the end); the home list starts at the top.
assert.ok(page.includes(".stackFromEnd(this.sessionId !== '')"));

// The model sheet fits its content instead of a fixed large sheet with blank space below.
assert.ok(page.includes('.bindSheet($$this.showModelPicker, this.modelSheet(), { height: SheetSize.FIT_CONTENT'));
const sheet = page.slice(page.indexOf('@Builder private modelSheet()'), page.indexOf('@Builder private modelCard()'));
assert.ok(!sheet.includes(".height('100%')") && !sheet.includes('.layoutWeight(1)'));
assert.ok(sheet.includes('.constraintSize({ maxHeight: Math.max(240, this.pageHeight * 0.78) })'));
// Pi's directory listing reads as 列出目录, not a generic tool.
const timeline = fs.readFileSync(path.join(ETS, 'services/ai/AiTimeline.ets'), 'utf8');
assert.ok(timeline.includes("case 'LS':\n      return { icon: 'doc', verb: '列出目录'"));
assert.ok(timeline.includes("case 'ls': return 'LS';"));
// Sending (every engine), as in Messages: the composer becomes the bubble where it stands, narrows to the bubble's
// size with its right edge fixed, then rises with a spring into its place at the foot of the conversation while the
// rows above lift; the list's own bubble stays hidden until the flyer lands. A failed send puts the text back.
const begin = page.slice(page.indexOf('private beginSend('), page.indexOf('private failSend('));
assert.ok(begin.includes('this.pendingSend = {') && begin.includes("this.draft = ''") && begin.includes('this.followBottom = true;'));
assert.ok(begin.includes('this.flyX = from.x - this.rootX; this.flyY = from.y - this.rootY; this.flyW = from.w; this.flyH = from.h;'),
  'the flight starts from the composer input itself');
assert.ok(begin.includes('this.flyW = target.w; this.flyH = target.h; this.flyX = tx;') && begin.includes('from.y - this.rootY + from.h - target.h'),
  'it first takes the bubble size beside the composer (one line narrows, several lines keep the width)');
assert.ok(begin.includes('curves.springMotion(0.42, 0.8)') && begin.includes('this.flyY = ty; this.listLift = 0;'), 'then rises with the rows above');
assert.ok(begin.includes('this.flyTextW = Math.max(20, target.w - 28);'), 'the text keeps its final width and never re-wraps mid-flight');
assert.ok(page.includes('.opacity(this.flyingRow(item) ? 0 : 1)') && page.includes('if (this.flyingRow(item)) { this.flyTarget = this.rectOf(next); }'));
assert.ok(page.includes('.onAreaChange((_old: Area, next: Area): void => { this.composerRect = this.rectOf(next); })'));
assert.ok(page.includes('.translate({ y: this.listLift })') && page.includes('      this.sendFlyer()\n    }.width(\'100%\').height(\'100%\')'));
// Messages and replies alike sit at the foot of the conversation: nothing is held at the top any more.
assert.ok(!/landing|LANDING_GAP|holdLanding|settleLanding/.test(page), 'the top landing is gone');
assert.ok(page.includes('.stackFromEnd(this.sessionId !== \'\')'));
assert.ok(page.includes('}.transition(this.entryEffect(entry, index))'));
// Only rows that arrived with the latest update animate; rows that were already shown (re-keyed while streaming,
// renamed when a reply finishes, or read again) never do, and a row that goes is gone at once.
assert.ok(page.includes('if (index < this.entryBase || !this.fresh(\'t:\' + entry.key)) { return TransitionEffect.IDENTITY; }'));
assert.ok(page.includes('this.entryBase = reread ? Number.MAX_SAFE_INTEGER : this.entryCount;'));
assert.ok(page.includes('TransitionEffect.IDENTITY);'), 'rows fade in only; a row that goes is gone at once');
assert.ok(page.includes("this.fresh('s:' + row.session.id)"), 'a listed conversation animates once, not on every update');
// Background pauses the connection instead of closing it; a paused one resumes in place.
assert.ok(page.includes('this.controller.pause();') && page.includes('if (await this.controller.resume()) { this.sync(); return; }'));
const ctl = fs.readFileSync(path.join(ETS, 'services/ai/AiWorkspaceController.ets'), 'utf8');
assert.ok(ctl.includes("const target: AiTranscript = older ? this.transcript : new AiTranscript();"), 'a re-read conversation is swapped in whole');
assert.ok(!ctl.slice(ctl.indexOf('async ensureControl()'), ctl.indexOf('private forgetLease()')).includes('this.release()'), 'a lapsed lease is not released before it is taken again');
// pi-gui holding the conversation: a notice and a way on in a copy.
assert.ok(page.includes('if (this.sessionId !== \'\' && this.openIn !== \'\') { this.openInNotice() }'));
assert.ok(page.includes("await this.controller.forkToContinue("));
const send = page.slice(page.indexOf('private async send('), page.indexOf('private async attach('));
assert.ok(send.includes('this.beginSend(text);') && send.includes('this.failSend(text);'));
assert.ok(send.indexOf('this.beginSend(text);') < send.indexOf("await this.run("), 'the bubble leaves before the network answers');
const start = page.slice(page.indexOf('private async startChat('), page.indexOf('private modelChipLabel('));
assert.ok(start.includes('this.beginSend(text);') && start.includes('this.failSend(text);'));
// The engine's copy replaces the bubble shown at once.
assert.ok(page.includes('this.userCount(this.items, this.pendingSend.text) > this.pendingBefore) { this.pendingSend = null; }'));

// / commands: suggestions above the composer; the app's own run here, the engine's (Pi templates/skills) fill in.
for (const name of ['/compact', '/model', '/stop', '/diff', '/new', '/reconnect']) assert.ok(page.includes("name: '" + name + "'"), name);
assert.ok(page.includes('if (this.slashSuggestions().length > 0) { this.commandPanel() }'));
assert.ok(send.includes('const command = this.localCommandFor(text);'));
assert.ok(page.includes("if (!command.local) { this.draft = command.name + ' '; return; }"));
const controller = fs.readFileSync(path.join(ETS, 'services/ai/AiWorkspaceController.ets'), 'utf8');
assert.ok(controller.includes("snapshot['commands']"));
// Dragging the list stops pinning its end.
assert.ok(page.includes('if (source !== ScrollSource.DRAG) { return; }') && page.includes('this.pinBottomUntil = 0;'));
// With the keyboard up, + and the permission menu open once it is down and keep the composer open meanwhile.
assert.ok(page.includes('.bindMenu(this.plusMenuShown, this.plusMenu(), { onDisappear: (): void => { this.menuClosed(); } })'));
assert.ok(page.includes('.bindMenu(this.permissionMenuShown, this.permissionMenu(), { onDisappear: (): void => { this.menuClosed(); } })'));
assert.ok(page.includes("return this.composerFocused || this.draft !== '' || this.composerHold;"));
assert.ok(page.includes('getFocusController().clearFocus()'));
// One working line: none below a row that already shows the turn at work; the Claude ✳ animates only itself.
assert.ok(page.includes('if (this.showWorkingRow()) { ListItem() { this.workingRow() } }'));
assert.ok(page.includes('AiSpinStar({') && !page.includes('.rotate({ angle: this.spin })'));
// Opening and leaving a conversation slide; the page itself slides in and out.
// Only navigation slides (open, back, continue in a copy); a reconnect or resume changes no view.
assert.ok(page.includes("if (sessionChanged && this.slideNext !== 0 && (c.sessionId !== '') === (this.slideNext > 0)) {"));
for (const name of ['private async chooseSession(', 'private async newSession(', 'private async backToList(']) {
  const body = page.slice(page.indexOf(name), page.indexOf(name) + 400);
  assert.ok(body.includes('this.slideNext = '), name);
}
assert.ok(page.includes('.translate({ x: this.viewShift }).opacity(this.viewOpacity)'));
assert.ok(page.includes('PageTransitionEnter({ type: RouteType.Push'));
// Every search bar is on the system's 沉浸光感 material where the device has it (SearchBarSurface), its old look elsewhere.
const surface = fs.readFileSync(path.join(ETS, 'common/SearchBarSurface.ets'), 'utf8');
assert.ok(surface.includes('deviceInfo.sdkApiVersion >= 26 && uiMaterial.isImmersiveMaterialSupported()'), 'guarded for API 23 devices');
assert.ok(surface.includes('instance.systemMaterial(new uiMaterial.ImmersiveMaterial({') && surface.includes('interactive: true'));
for (const file of ['pages/HostListPage.ets', 'components/AboutSettingsSheet.ets', 'pages/RemoteAiWorkspace.ets',
  'pages/MoonlightAppCatalogPage.ets', 'components/ProWorkspaceEditorPanel.ets', 'components/diagnosticAi/DiagnosticAiSettingsSheet.ets',
  'components/pro/org/HostOrganizationManager.ets', 'components/pro/workspace/WorkspaceAddFlow.ets',
  'components/ssh/search/SshTerminalSearchBar.ets', 'components/ssh/command/SshCommandPalette.ets', 'components/ssh/log/SshSessionLogSheet.ets']) {
  const text = fs.readFileSync(path.join(ETS, file), 'utf8');
  assert.ok(text.includes('SearchBarSurface<'), file + ' search bar uses the shared surface');
  for (const match of text.matchAll(/Search\(\{[^\n]*\n?[^\n]*/g)) assert.ok(!/\.backgroundColor\(/.test(match[0]), file + ': no own background on Search');
}
console.log('PASS remote AI composer centring, shimmer, pull to refresh and model sheet sizing');
