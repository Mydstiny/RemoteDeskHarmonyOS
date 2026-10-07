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

// The model sheet fits its content instead of a fixed large sheet with blank space below.
assert.ok(page.includes('.bindSheet($$this.showModelPicker, this.modelSheet(), { height: SheetSize.FIT_CONTENT'));
const sheet = page.slice(page.indexOf('@Builder private modelSheet()'), page.indexOf('@Builder private modelCard()'));
assert.ok(!sheet.includes(".height('100%')") && !sheet.includes('.layoutWeight(1)'));
assert.ok(sheet.includes('.constraintSize({ maxHeight: Math.max(240, this.pageHeight * 0.78) })'));
// Pi's directory listing reads as 列出目录, not a generic tool.
const timeline = fs.readFileSync(path.join(ETS, 'services/ai/AiTimeline.ets'), 'utf8');
assert.ok(timeline.includes("case 'LS':\n      return { icon: 'doc', verb: '列出目录'"));
assert.ok(timeline.includes("case 'ls': return 'LS';"));
console.log('PASS remote AI composer centring, shimmer, pull to refresh and model sheet sizing');
