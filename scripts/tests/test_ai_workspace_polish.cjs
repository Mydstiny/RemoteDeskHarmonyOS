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
// Sending (every engine): the text leaves the composer at once, flies up with a spring and lands near the top; the
// row below it holds the place the reply fills; a failed send puts the text back.
assert.ok(page.includes('const LANDING_GAP: number = 12;'));
const begin = page.slice(page.indexOf('private beginSend('), page.indexOf('private failSend('));
assert.ok(begin.includes('curves.springMotion(') && begin.includes('this.pendingSend = {') && begin.includes("this.draft = ''"));
assert.ok(page.includes('if (this.landingSpacer > 0) {\n            ListItem() { Column().width(\'100%\').height(this.landingSpacer) }'));
assert.ok(page.includes('}.transition(this.entryEffect(entry))'));
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
console.log('PASS remote AI composer centring, shimmer, pull to refresh and model sheet sizing');
