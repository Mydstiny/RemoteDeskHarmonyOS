import { AiTranscriptItem } from './AiModels';
import { aiArray, aiErrorText, aiNumber, aiRecord, aiString } from './AiWirePolicy';

export function aiContentText(value: Object | undefined | null, depth: number = 0): string {
  if (value === undefined || value === null || depth > 8) { return ''; }
  if (typeof value === 'string') { return value; }
  if (Array.isArray(value)) { return aiArray(value).map((item: Object): string => aiContentText(item, depth + 1)).filter((text: string): boolean => text !== '').join('\n'); }
  if (typeof value !== 'object') { return ''; }
  const record = aiRecord(value);
  if (typeof record['text'] === 'string') { return aiString(record['text']); }
  if (record['content'] !== undefined) { return aiContentText(record['content'], depth + 1); }
  return '';
}
/** The value as a record, or an empty one: remote events with a malformed field are skipped, never thrown. */
function aiObject(value: Object | undefined | null): Record<string, Object> {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value) ?
    value as Record<string, Object> : {};
}

function aiBlocks(value: Object | undefined): Record<string, Object>[] {
  if (value === undefined || value === null) { return []; }
  if (typeof value === 'string') {
    const text: Record<string, Object> = { 'type': 'text', 'text': value };
    return [text];
  }
  return aiArray(value).filter((block: Object): boolean => block !== null && typeof block === 'object' &&
    !Array.isArray(block)).map((block: Object): Record<string, Object> => aiRecord(block));
}

/** A stored message object carries its blocks in `content`; live events carry the content itself. */
function aiContentOf(value: Object | undefined): Object | undefined {
  if (value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value)) {
    const record = value as Record<string, Object>;
    return record['content'] !== undefined ? record['content'] : value;
  }
  return value;
}

function aiJson(value: Object | undefined): string {
  if (value === undefined || value === null) { return ''; }
  if (typeof value === 'string') { return value; }
  try { return JSON.stringify(value, null, 2); } catch (_error) { return ''; }
}

function aiClaudeItem(id: string, kind: string, title: string, text: string, state: string, turnId: string,
  order: number): AiTranscriptItem {
  const role = kind === 'user' ? 'user' : kind === 'assistant' ? 'assistant' : 'execution';
  return { id, role, title, text, state, turnId, kind, detail: '', output: '', order };
}

/**
 * Claude Agent events (live and history) to transcript items. Live turns stream text chunks and then repeat the
 * whole message, so a finished message replaces the chunks before it; tool results arrive as user messages made of
 * tool_result blocks and are attached to their tool call; history carries tool_use and thinking inside messages.
 */
export function aiClaudeItems(events: Record<string, Object>[]): AiTranscriptItem[] {
  const items: AiTranscriptItem[] = [];
  const tools: Map<string, AiTranscriptItem> = new Map();
  const streams: Map<string, number> = new Map();
  const streamItems: Map<string, AiTranscriptItem> = new Map();
  const dropped: Set<AiTranscriptItem> = new Set();
  const turnStates: Map<string, string> = new Map();
  const addTool = (id: string, name: string, input: Object | undefined, turnId: string, state: string,
    order: number): void => {
    const existing = tools.get(id);
    if (existing !== undefined) { return; }
    const item = aiClaudeItem('claude:tool:' + id, 'tool', name === '' ? '工具' : name, '', state, turnId, order);
    item.detail = aiJson(input);
    tools.set(id, item);
    items.push(item);
  };
  const dropStream = (turnId: string): void => {
    const streamId = 'claude:stream:' + turnId + ':' + (streams.get(turnId) ?? 0).toString();
    const current = streamItems.get(streamId);
    if (current !== undefined) { dropped.add(current); streamItems.delete(streamId); }
    streams.set(turnId, (streams.get(turnId) ?? 0) + 1);
  };
  for (const event of events) {
    const seq = aiNumber(event['seq'], -1);
    const type = aiString(event['type']);
    const rawData = event['data'];
    if (rawData === undefined || rawData === null || typeof rawData !== 'object' || Array.isArray(rawData)) { continue; }
    const data = rawData as Record<string, Object>;
    const turnId = aiString(event['turn']);
    const id = 'claude:' + seq.toString();
    if (type === 'assistant/chunk') {
      const rawChunk = data['chunk'];
      const text = rawChunk !== undefined && rawChunk !== null && typeof rawChunk === 'object' && !Array.isArray(rawChunk) ?
        aiString((rawChunk as Record<string, Object>)['text']) : '';
      if (text === '') { continue; }
      const streamId = 'claude:stream:' + turnId + ':' + (streams.get(turnId) ?? 0).toString();
      const current = streamItems.get(streamId);
      if (current !== undefined) { current.text = current.text + text; }
      else {
        const item = aiClaudeItem(streamId, 'assistant', 'assistant', text, 'running', turnId, seq);
        streamItems.set(streamId, item);
        items.push(item);
      }
    } else if (type === 'assistant/message') {
      if (data['message'] !== undefined && typeof data['message'] === 'string') {
        const kind = aiString(data['kind'], 'text');
        if (aiString(data['message']) === '') { continue; }
        if (kind === 'thinking') {
          items.push(aiClaudeItem(id, 'thinking', '思考', aiString(data['message']), 'completed', turnId, seq));
        } else {
          dropStream(turnId);
          items.push(aiClaudeItem(id, 'assistant', 'assistant', aiString(data['message']), 'completed', turnId, seq));
        }
        continue;
      }
      // History: one event per stored message, whose content holds every block.
      aiBlocks(aiContentOf(data['message'])).forEach((block: Record<string, Object>,
        index: number): void => {
        const blockType = aiString(block['type']);
        if (blockType === 'text' && aiString(block['text']) !== '') {
          items.push(aiClaudeItem(id + ':' + index.toString(), 'assistant', 'assistant', aiString(block['text']),
            'completed', turnId, seq));
        } else if (blockType === 'thinking' && aiString(block['thinking']) !== '') {
          items.push(aiClaudeItem(id + ':' + index.toString(), 'thinking', '思考', aiString(block['thinking']),
            'completed', turnId, seq));
        } else if (blockType === 'tool_use') {
          // Stored history does not say whether the tool finished; its tool_result, if any, will.
          addTool(aiString(block['id']), aiString(block['name']), block['input'], turnId, '', seq);
        }
      });
    } else if (type === 'user/message') {
      const texts: string[] = [];
      aiBlocks(aiContentOf(data['message'])).forEach((block: Record<string, Object>): void => {
        const blockType = aiString(block['type']);
        if (blockType === 'tool_result') {
          const tool = tools.get(aiString(block['tool_use_id']));
          if (tool !== undefined) {
            tool.output = aiContentText(block['content']);
            tool.state = block['is_error'] === true ? 'failed' : 'completed';
          }
        } else if (blockType === 'text') {
          const text = aiString(block['text']);
          if (text !== '') { texts.push(text); }
        } else if (blockType === 'image') {
          texts.push('［图片］');
        }
      });
      if (texts.length > 0) { items.push(aiClaudeItem(id, 'user', 'user', texts.join('\n'), 'completed', turnId, seq)); }
    } else if (type === 'tool/call') {
      addTool(aiString(data['id']), aiString(data['name']), data['input'], turnId, 'running', seq);
    } else if (type === 'tool/result') {
      // A tool the local user or policy refused; it never ran.
      const item = aiClaudeItem(id, 'tool', aiString(data['name'], '工具'), '', 'declined', turnId, seq);
      item.output = aiString(data['message']);
      items.push(item);
    } else if (type === 'turn/end') {
      const status = aiString(data['status'], 'completed');
      turnStates.set(turnId, status);
      if (status === 'failed' && aiString(data['result']) !== '') {
        const notice = aiClaudeItem(id, 'notice', '执行失败', aiString(data['result']), 'failed', turnId, seq);
        items.push(notice);
      }
    } else if (type === 'error') {
      items.push(aiClaudeItem(id, 'notice', '错误', aiErrorText(aiString(data['code'])), 'failed', turnId, seq));
    } else if (type === 'session/compacted') {
      items.push(aiClaudeItem(id, 'notice', '上下文已压缩', '', 'completed', turnId, seq));
    }
  }
  // A finished turn leaves nothing running: its stream and unanswered tools end with the turn.
  const result = dropped.size === 0 ? items : items.filter((item: AiTranscriptItem): boolean => !dropped.has(item));
  result.forEach((item: AiTranscriptItem): void => {
    const status = turnStates.get(item.turnId);
    if (status !== undefined && item.state === 'running') { item.state = status === 'completed' ? 'completed' : status; }
  });
  return result;
}

/**
 * A Codex file change as unified diff text. Added and deleted files carry the file content itself rather than a
 * diff, so every line becomes an added (or removed) line; lines that happen to start with + or - stay content.
 */
function aiCodexChangeBody(change: Record<string, Object>): string {
  const body = aiString(change['diff']);
  const kind = change['kind'];
  const type = typeof kind === 'string' ? kind as string : kind !== undefined && kind !== null && typeof kind === 'object' &&
    !Array.isArray(kind) ? aiString((kind as Record<string, Object>)['type']) : '';
  // Added and deleted files always carry their content, which may itself be a patch: never read as a diff.
  if (type !== 'add' && type !== 'delete') { return body; }
  const sign = type === 'add' ? '+' : '-';
  const lines = body === '' ? [] : (body.endsWith('\n') ? body.slice(0, body.length - 1) : body).split('\n');
  // The hunk counts tell the parser where content ends, so content lines that look like headers stay content.
  const count = lines.length.toString();
  return (type === 'add' ? '@@ -0,0 +1,' + count + ' @@' : '@@ -1,' + count + ' +0,0 @@') + '\n' +
    lines.map((line: string): string => sign + line).join('\n');
}

/** One Codex app-server thread item to a transcript item (user/agent text, reasoning, commands, file changes, tools). */
export function aiCodexItem(raw: Record<string, Object>, turnId: string, state: string = ''): AiTranscriptItem {
  const type = aiString(raw['type']);
  const id = aiString(raw['id']);
  const status = aiString(raw['status'], state);
  if (type === 'userMessage' || type === 'agentMessage') {
    const role = type === 'userMessage' ? 'user' : 'assistant';
    return { id, role, title: type, text: aiContentText(raw['text'] ?? raw['content']), state: status, turnId,
      kind: role, detail: '', output: '' };
  }
  if (type === 'reasoning') {
    const summary = aiContentText(raw['summary']);
    return { id, role: 'execution', title: '思考', text: summary !== '' ? summary : aiContentText(raw['content']),
      state: status, turnId, kind: 'thinking', detail: '', output: '' };
  }
  if (type === 'commandExecution') {
    const command = aiContentText(raw['command']);
    const detail: Record<string, Object> = { 'command': command, 'cwd': aiString(raw['cwd']) };
    if (typeof raw['exitCode'] === 'number') { detail['exitCode'] = raw['exitCode']; }
    return { id, role: 'execution', title: type, text: command, state: status, turnId, kind: 'tool',
      detail: JSON.stringify(detail), output: aiString(raw['aggregatedOutput']) };
  }
  if (type === 'fileChange') {
    const paths: string[] = [];
    const diff: string[] = [];
    aiArray(raw['changes']).forEach((value: Object): void => {
      if (value === null || typeof value !== 'object' || Array.isArray(value)) { return; }
      const change = value as Record<string, Object>;
      const path = aiString(change['path']);
      paths.push(path);
      const body = aiCodexChangeBody(change);
      diff.push(body.startsWith('diff --git') ? body : 'diff --git a/' + path + ' b/' + path + '\n' + body);
    });
    return { id, role: 'execution', title: type, text: paths.join('\n'), state: status, turnId, kind: 'tool',
      detail: '', output: diff.join('\n') };
  }
  if (type === 'mcpToolCall') {
    const server = aiString(raw['server']);
    const tool = aiString(raw['tool']);
    let detail = '';
    try { detail = JSON.stringify(raw['arguments'] ?? {}, null, 2); } catch (_error) { detail = ''; }
    const error = raw['error'];
    let errorText = '';
    if (error !== undefined && error !== null) {
      errorText = typeof error === 'object' && !Array.isArray(error) ?
        aiString((error as Record<string, Object>)['message']) : '';
      if (errorText === '') { errorText = aiContentText(error) || JSON.stringify(error); }
    }
    return { id, role: 'execution', title: type, text: server !== '' ? server + ' · ' + tool : tool, state: status,
      turnId, kind: 'tool', detail, output: errorText !== '' ? errorText : aiContentText(raw['result']) };
  }
  if (type === 'webSearch') {
    return { id, role: 'execution', title: type, text: aiString(raw['query']), state: status, turnId, kind: 'tool',
      detail: '', output: '' };
  }
  let detail = '';
  try { detail = JSON.stringify(raw, null, 2); } catch (_error) { detail = ''; }
  return { id, role: 'execution', title: type, text: aiContentText(raw['text'] ?? raw['content']), state: status,
    turnId, kind: 'tool', detail, output: '' };
}

/** A DSH tool call's arguments arrive as the model's raw JSON string; shown pretty-printed when they parse. */
function aiDshArguments(value: Object | undefined): string {
  if (value === undefined || value === null) { return ''; }
  if (typeof value === 'string') {
    const text = value as string;
    if (!text.trim().startsWith('{') && !text.trim().startsWith('[')) { return text; }
    try { return JSON.stringify(JSON.parse(text) as Object, null, 2); } catch (_error) { return text; }
  }
  return aiJson(value);
}

function aiDshTurnState(reason: Object | undefined): string {
  const kind = aiString(aiObject(reason)['kind'], 'completed');
  if (kind === 'completed' || kind === 'max-tokens') { return 'completed'; }
  return kind === 'aborted' || kind === 'interrupted' ? 'interrupted' : 'failed';
}

/** The text of the given block type ('text' or 'reasoning') in DSH message content. */
function aiDshText(content: Object | undefined, type: string): string {
  if (typeof content === 'string') { return type === 'text' ? content as string : ''; }
  return aiArray(content).map((value: Object): Record<string, Object> => aiObject(value))
    .filter((block: Record<string, Object>): boolean => aiString(block['type']) === type)
    .map((block: Record<string, Object>): string => aiString(block['text']))
    .filter((text: string): boolean => text !== '').join('\n');
}

/** What DSH context a user/message carries, by its source kind, when the source names no summary. */
const DSH_CONTEXT_LABELS: Map<string, string> = new Map<string, string>([
  ['agent-instructions', '项目说明（AGENTS.md）'],
  ['skill-invocation', '技能'],
  ['skill-catalog', '技能目录'],
  ['agent-message', '子代理消息'],
  ['subagent-settled', '子代理已完成'],
  ['goal', '目标继续'],
  ['session-reference', '引用的会话'],
  ['webhook', 'Webhook 通知']
]);

/** Whether `text` at `at` opens a markup tag ('<name ...>' or '</name>'), and where it ends, or -1. */
function aiTagEnd(text: string, at: number): number {
  if (text.charAt(at) !== '<') { return -1; }
  let i = at + 1;
  if (text.charAt(i) === '/') { i++; }
  if (!/[A-Za-z]/.test(text.charAt(i))) { return -1; }
  const close = text.indexOf('>', i);
  if (close < 0 || close - at > 82) { return -1; }
  const inner = text.slice(i, close);
  return inner.indexOf('<') >= 0 || inner.indexOf('\n') >= 0 ? -1 : close + 1;
}

/**
 * A line without the markup tags around it ('<system-reminder>…</system-reminder>'); tags inside are text. At most
 * eight tags go from each end, so remote text full of tags stays linear.
 */
function aiUntagged(line: string): string {
  let text = line.trim();
  for (let count = 0, end = aiTagEnd(text, 0); count < 8 && end > 0; count++, end = aiTagEnd(text, 0)) {
    text = text.slice(end).trim();
  }
  for (let count = 0, open = text.lastIndexOf('<'); count < 8 && open >= 0 && aiTagEnd(text, open) === text.length;
    count++, open = text.lastIndexOf('<')) {
    text = text.slice(0, open).trim();
  }
  return text;
}

/** The first line that says something, without surrounding markup tags. */
function aiFirstLine(text: string): string {
  for (const raw of text.split('\n')) {
    const line = aiUntagged(raw);
    if (line !== '') { return line.length > 120 ? line.slice(0, 119) + '…' : line; }
  }
  return '';
}

/** The given field of each entry of a source list, as DSH's client shows them ('a.md、b.md'). */
function aiSourceNames(list: Object | undefined, field: string): string {
  return aiArray(list).map((value: Object): string => aiString(aiObject(value)[field])).filter((name: string): boolean =>
    name !== '').slice(0, 3).join('、');
}

function aiDshContextLabel(kind: string, source: Record<string, Object>, text: string): string {
  const summary = aiString(source['summary']);
  if (summary !== '') { return summary; }
  if (kind === 'skill-invocation' && aiString(source['name']) !== '') { return '技能：' + aiString(source['name']); }
  if (kind === 'agent-instructions' && aiSourceNames(source['changes'], 'path') !== '') {
    return '项目说明：' + aiSourceNames(source['changes'], 'path');
  }
  if (kind === 'session-reference' && aiSourceNames(source['references'], 'label') !== '') {
    return '引用的会话：' + aiSourceNames(source['references'], 'label');
  }
  const named = DSH_CONTEXT_LABELS.get(kind);
  if (named !== undefined) { return named; }
  const line = aiFirstLine(text);
  if (line !== '') { return line; }
  return kind === 'plugin' && aiString(source['plugin']) !== '' ? '插件 ' + aiString(source['plugin']) : kind;
}

/** A row that grows while DSH streams one step's answer or reasoning. */
interface AiDshStream {
  item: AiTranscriptItem;
  seqs: number[];
}

/**
 * DSH session events to transcript items, one event at a time in seq order (history pages, then live events), so a
 * long session is not mapped again for every event. Surface replacements (compaction) cut the item range they name;
 * a tool result joins its call through toolCallId and leaves a hidden placeholder that later replacements can still
 * name; streamed answer text and reasoning each grow one row until the assembled message replaces them; context a
 * plugin injected reads as a step, not as the user's words; a finished turn leaves nothing running.
 */
export class AiDshMapper {
  /** Every item, hidden placeholders included. */
  private list: AiTranscriptItem[] = [];
  private calls: Map<string, AiTranscriptItem> = new Map();
  private streams: Map<string, AiDshStream> = new Map();
  private running: Map<string, AiTranscriptItem[]> = new Map();
  /** Items named exactly 'dsh:<seq>', by seq (a message's source events are looked up, not searched for). */
  private bySeq: Map<number, AiTranscriptItem> = new Map();
  /** seq of the last event added; later events must come after it (see AiTranscript.flush). */
  last: number = -1;

  items(): AiTranscriptItem[] { return this.list.filter((item: AiTranscriptItem): boolean => item.kind !== 'merged'); }

  /** Where the items of event `seq` begin (first) or end (!first) in the list, or -1. */
  private position(seq: number, first: boolean): number {
    const id = 'dsh:' + seq.toString();
    const prefix = id + ':';
    const matches = (item: AiTranscriptItem): boolean => item.id === id || item.id.startsWith(prefix);
    if (first) { return this.list.findIndex(matches); }
    for (let i = this.list.length - 1; i >= 0; i--) { if (matches(this.list[i])) { return i; } }
    return -1;
  }

  /** Removes an item; the ones removed are usually recent, so the search starts at the end. */
  private remove(item: AiTranscriptItem): void {
    const index = this.list.lastIndexOf(item);
    if (index >= 0) { this.list.splice(index, 1); }
  }

  private track(item: AiTranscriptItem): void {
    const items = this.running.get(item.turnId);
    if (items === undefined) { this.running.set(item.turnId, [item]); } else { items.push(item); }
  }

  add(row: Record<string, Object>): void {
    const seq = aiNumber(row['seq'], -1);
    if (seq > this.last) { this.last = seq; }
    const raw = row['data'];
    if (raw === undefined || raw === null || typeof raw !== 'object' || Array.isArray(raw)) { return; }
    const data = raw as Record<string, Object>;
    const type = aiString(row['type']);
    let at = -1;
    const surface = aiObject(row['surfaceOp']);
    if (surface['op'] === 'replace') {
      const first = this.position(aiNumber(surface['start'], -1), true);
      const last = this.position(aiNumber(surface['end'], -1), false);
      if (first < 0 || last < first) { throw new Error('AI_SURFACE_RANGE_INVALID'); }
      at = first;
      this.list.splice(first, last - first + 1);
    }
    const put = (item: AiTranscriptItem): void => {
      if (at >= 0) { this.list.splice(at, 0, item); at++; } else { this.list.push(item); }
      if (item.id === 'dsh:' + seq.toString()) { this.bySeq.set(seq, item); }
    };
    const turnId = aiNumber(data['turn']).toString();
    const step = aiNumber(data['step']).toString();
    const id = 'dsh:' + seq.toString();
    if (type === 'assistant/chunk') {
      const chunk = aiObject(data['chunk']);
      const chunkType = aiString(chunk['type']);
      const kind = chunkType === 'reasoning-delta' ? 'thinking' : chunkType === 'text-delta' || chunkType === '' ?
        'assistant' : '';
      const text = aiString(chunk['text'], aiString(chunk['delta']));
      if (kind === '' || text === '') { return; }
      const key = turnId + ':' + step + ':' + kind;
      const stream = this.streams.get(key);
      if (stream !== undefined) {
        stream.item.text = stream.item.text + text;
        stream.seqs.push(seq);
        return;
      }
      const item: AiTranscriptItem = { id, role: kind === 'thinking' ? 'execution' : 'assistant',
        title: kind === 'thinking' ? '思考' : 'assistant', text, state: 'running', turnId, kind, detail: '', output: '' };
      this.streams.set(key, { item, seqs: [seq] });
      this.list.push(item);
      this.bySeq.set(seq, item);
      this.track(item);
    } else if (type === 'assistant/message') {
      // The assembled message replaces the rows streamed for it.
      const sources = new Set<number>(aiArray(row['sourceEventSeqs']).map((value: Object): number => aiNumber(value, -1)));
      const prefix = turnId + ':' + step + ':';
      Array.from(this.streams.keys()).forEach((key: string): void => {
        const stream = this.streams.get(key);
        if (stream !== undefined && (key.startsWith(prefix) || stream.seqs.some((value: number): boolean => sources.has(value)))) {
          this.remove(stream.item);
          this.bySeq.delete(stream.seqs[0]);
          this.streams.delete(key);
        }
      });
      sources.forEach((source: number): void => {
        const item = this.bySeq.get(source);
        if (item !== undefined) { this.remove(item); this.bySeq.delete(source); }
      });
      const message = data['message'];
      const content = typeof message === 'string' ? message : aiObject(message)['content'];
      const state = data['interrupted'] === true ? 'interrupted' : 'completed';
      const reasoning = aiDshText(content, 'reasoning');
      const text = aiDshText(content, 'text');
      if (reasoning !== '') {
        put({ id: id + ':r', role: 'execution', title: '思考', text: reasoning, state, turnId, kind: 'thinking',
          detail: '', output: '' });
      }
      put(text !== '' ? { id, role: 'assistant', title: 'assistant', text, state, turnId, kind: 'assistant', detail: '',
        output: '' } : { id, role: 'execution', title: '', text: '', state, turnId, kind: 'merged', detail: '', output: '' });
    } else if (type === 'user/message') {
      // The event's data is the message itself ({id, role, content, source}); older logs wrapped it in `message`.
      const message = data['message'];
      const record = message !== undefined && message !== null && typeof message === 'object' && !Array.isArray(message) ?
        message as Record<string, Object> : data;
      const text = typeof message === 'string' ? message as string : aiContentText(record['content'] ?? record);
      const source = aiObject(record['source']);
      const kind = aiString(source['kind']);
      if (kind !== '' && kind !== 'user') {
        // Anything a person did not type (AGENTS.md, skills, sub-agent results, goals, notices) is context, as DSH's
        // own client reads it: every source but 'user'. Older logs without a source are the user's words.
        put({ id, role: 'execution', title: '上下文', text: aiDshContextLabel(kind, source, text), state: 'completed',
          turnId, kind: 'tool', detail: '', output: text.length > 20000 ? text.slice(0, 20000) : text });
      } else {
        put({ id, role: 'user', title: 'user', text, state: data['interrupted'] === true ? 'interrupted' : 'completed',
          turnId, kind: 'user', detail: '', output: '' });
      }
    } else if (type === 'tool/call') {
      const item: AiTranscriptItem = { id, role: 'execution', title: aiString(data['name'], '工具'), text: '',
        state: 'running', turnId, kind: 'tool', detail: aiDshArguments(data['arguments'] ?? data['input'] ?? data['args']),
        output: '' };
      const callId = aiString(data['callId']);
      if (callId !== '') { this.calls.set(callId, item); }
      put(item);
      this.track(item);
    } else if (type === 'tool/result') {
      const message = aiObject(data['message']);
      const block = aiArray(message['content']).map((value: Object): Record<string, Object> => aiObject(value))
        .find((value: Record<string, Object>): boolean => aiString(value['type']) === 'tool-result');
      const callId = block !== undefined ? aiString(block['toolCallId']) : aiString(aiObject(message['source'])['callId']);
      const output = block !== undefined ? aiContentText(block['content']) : aiContentText(message['content']);
      const state = (block !== undefined && block['isError'] === true) || data['error'] !== undefined ? 'failed' : 'completed';
      const call = this.calls.get(callId);
      if (call !== undefined) {
        call.output = output;
        call.state = state;
        put({ id, role: 'execution', title: '', text: '', state, turnId, kind: 'merged', detail: '', output: '' });
      } else {
        put({ id, role: 'execution', title: '工具结果', text: '', state, turnId, kind: 'tool', detail: '', output });
      }
    } else if (type === 'turn/end') {
      const status = aiDshTurnState(data['reason']);
      (this.running.get(turnId) ?? []).forEach((item: AiTranscriptItem): void => {
        if (item.state === 'running') { item.state = status; }
      });
      this.running.delete(turnId);
      Array.from(this.streams.keys()).filter((key: string): boolean => key.startsWith(turnId + ':'))
        .forEach((key: string): void => { this.streams.delete(key); });
    }
  }
}

/** DSH session events (ordered by seq) to transcript items; see AiDshMapper. */
export function aiDshItems(events: Record<string, Object>[]): AiTranscriptItem[] {
  const mapper = new AiDshMapper();
  events.forEach((event: Record<string, Object>): void => { mapper.add(event); });
  return mapper.items();
}

/** The text a user/message event typed (tool results and images do not count). */
function aiUserText(event: Record<string, Object>): string {
  const texts: string[] = [];
  aiBlocks(aiContentOf(aiObject(event['data'])['message'])).forEach((block: Record<string, Object>): void => {
    if (aiString(block['type']) === 'text' && aiString(block['text']).trim() !== '') { texts.push(aiString(block['text'])); }
  });
  return texts.join('\n').trim();
}

/** A prompt shown before the engine reports it: Claude does not echo prompts while the turn runs. */
interface AiEcho {
  item: AiTranscriptItem;
  text: string;
  /** Only engine events that arrive after the prompt was sent can stand for it. */
  after: number;
}

export class AiTranscript {
  items: AiTranscriptItem[] = [];
  private dshEvents: Map<number, Record<string, Object>> = new Map();
  private dsh: AiDshMapper = new AiDshMapper();
  /** DSH seqs recorded since the last flush. */
  private dshFresh: number[] = [];
  /** An event came again with other content, out of order, or the mapper failed: map everything again. */
  private dshRestart: boolean = false;
  /** Arrival positions of engine prompts that already stood for an echo. */
  private claimed: Set<number> = new Set();
  /**
   * Claude events in arrival order (history pages, then live events). The plugin numbers live events apart from
   * the history it read, so `seq` is not a usable order; each event is renumbered by arrival instead.
   */
  private claudeLog: Record<string, Object>[] = [];
  private claudeArrived: number = 0;
  private echoes: AiEcho[] = [];
  private echoCount: number = 0;
  /** 'claude' or 'dsh' when events arrived since items were last mapped. */
  private pending: string = '';

  clear(): void {
    this.items = []; this.dshEvents.clear(); this.claudeLog = []; this.claudeArrived = 0; this.echoes = [];
    this.pending = ''; this.dsh = new AiDshMapper(); this.dshFresh = []; this.dshRestart = false; this.claimed.clear();
  }

  /** Where the event log stands; taken before a prompt is sent, so an engine copy arriving early still counts. */
  mark(): number { return this.claudeArrived; }

  /** Whether an engine prompt (text, turn) can stand for `echo`: the same words, or the turn it opened. */
  private stands(echo: AiEcho, text: string, turn: string, exact: boolean): boolean {
    if (exact) { return echo.text === text; }
    // The engine may add to the prompt (attachments); context it injects on its own never contains the prompt.
    return echo.item.turnId !== '' && echo.item.turnId === turn && text.includes(echo.text);
  }

  /** The oldest echo the engine prompt at `index` stands for, or -1. */
  private echoFor(index: number, text: string, turn: string): number {
    let at = this.echoes.findIndex((echo: AiEcho): boolean => echo.after <= index && this.stands(echo, text, turn, true));
    if (at < 0) {
      at = this.echoes.findIndex((echo: AiEcho): boolean => echo.after <= index && this.stands(echo, text, turn, false));
    }
    return at;
  }

  /**
   * Shows a sent prompt until an engine event from `after` on (see mark()) stands for it: the same words, or the
   * prompt that opened its turn. Each engine prompt stands for one echo at most.
   */
  echo(text: string, turnId: string, after: number = -1): void {
    const trimmed = text.trim();
    if (trimmed === '') { return; }
    const from = after >= 0 ? Math.min(after, this.claudeArrived) : this.claudeArrived;
    this.echoCount++;
    const echo: AiEcho = { item: { id: 'echo:' + this.echoCount.toString(), role: 'user', title: 'user', text,
      state: 'completed', turnId, kind: 'user', detail: '', output: '', order: from }, text: trimmed, after: from };
    // The engine's copy may already be here (it can arrive before the acknowledgement).
    for (const entry of this.claudeLog) {
      const index = aiNumber(entry['seq'], -1);
      if (index < from || this.claimed.has(index) || entry['type'] !== 'user/message') { continue; }
      const engine = aiUserText(entry);
      if (engine !== '' && (this.stands(echo, engine, aiString(entry['turn']), true) ||
        this.stands(echo, engine, aiString(entry['turn']), false))) {
        this.claimed.add(index);
        return;
      }
    }
    this.echoes.push(echo);
    this.flush();
    this.items = this.withEchoes(this.items);
  }

  private withEchoes(items: AiTranscriptItem[]): AiTranscriptItem[] {
    const result = items.filter((item: AiTranscriptItem): boolean => !item.id.startsWith('echo:'));
    for (const echo of this.echoes) {
      // Before the first item of its turn; otherwise where it was sent (a steered prompt has no turn of its own).
      let at = echo.item.turnId === '' ? -1 :
        result.findIndex((item: AiTranscriptItem): boolean => item.turnId === echo.item.turnId && !item.id.startsWith('echo:'));
      if (at < 0) {
        at = result.findIndex((item: AiTranscriptItem): boolean => !item.id.startsWith('echo:') &&
          (item.order ?? -1) >= echo.after);
      }
      if (at >= 0) { result.splice(at, 0, echo.item); } else { result.push(echo.item); }
    }
    return result;
  }

  /** Records a Claude event; `defer` leaves the mapping to the next flush() (history pages, streamed events). */
  claudeEvent(event: Record<string, Object>, defer: boolean = false): void {
    const type = aiString(event['type']);
    const data = event['data'];
    const turn = aiString(event['turn']);
    const index = this.claudeArrived++;
    const logged: Record<string, Object> = { 'seq': index, 'type': type };
    if (data !== undefined && data !== null) { logged['data'] = data; }
    if (turn !== '') { logged['turn'] = turn; }
    if (type === 'assistant/message' && data !== undefined && data !== null && typeof data === 'object' &&
      typeof (data as Record<string, Object>)['message'] === 'string' &&
      aiString((data as Record<string, Object>)['kind'], 'text') !== 'thinking' &&
      aiString((data as Record<string, Object>)['message']) !== '') {
      // The finished message replaces its turn's streamed chunks; they need not be mapped again.
      this.claudeLog = this.claudeLog.filter((entry: Record<string, Object>): boolean =>
        !(entry['type'] === 'assistant/chunk' && aiString(entry['turn']) === turn));
    }
    this.claudeLog.push(logged);
    if (type === 'user/message') {
      const text = aiUserText(event);
      if (text !== '') {
        const at = this.echoFor(index, text, turn);
        if (at >= 0) {
          this.echoes.splice(at, 1);
          this.claimed.add(index);
        }
      }
    }
    this.pending = 'claude';
    if (!defer) { this.flush(); }
  }

  /** Records a DSH event; `defer` leaves the mapping to the next flush(). */
  dshEvent(event: Record<string, Object>, defer: boolean = false): void {
    const seq = aiNumber(event['seq'], -1);
    if (!Number.isSafeInteger(seq) || seq < 0) { return; }
    const known = this.dshEvents.get(seq);
    if (known !== undefined) {
      // A page and the event stream may both carry an event; the same event twice changes nothing.
      if (JSON.stringify(known) === JSON.stringify(event)) { return; }
      this.dshRestart = true;
    } else {
      this.dshFresh.push(seq);
    }
    this.dshEvents.set(seq, event);
    this.pending = 'dsh';
    if (!defer) {
      const problem = this.flush();
      if (problem !== '') { throw new Error(problem); }
    }
  }

  /** Maps events recorded since the last flush; returns the error code when DSH events cannot be placed. */
  flush(): string {
    const pending = this.pending;
    this.pending = '';
    if (pending === 'claude') {
      this.items = this.withEchoes(aiClaudeItems(this.claudeLog));
    } else if (pending === 'dsh') {
      const fresh = this.dshFresh.sort((a: number, b: number): number => a - b);
      this.dshFresh = [];
      try {
        if (this.dshRestart || (fresh.length > 0 && fresh[0] <= this.dsh.last)) {
          // Something arrived out of order: map the whole log again (rare; pages and live events come in order).
          this.dshRestart = false;
          this.dsh = new AiDshMapper();
          Array.from(this.dshEvents.keys()).sort((a: number, b: number): number => a - b).forEach((key: number): void => {
            const value = this.dshEvents.get(key);
            if (value !== undefined) { this.dsh.add(value); }
          });
        } else {
          fresh.forEach((key: number): void => {
            const value = this.dshEvents.get(key);
            if (value !== undefined) { this.dsh.add(value); }
          });
        }
        this.items = this.dsh.items();
      } catch (error) {
        // The mapper stopped part way: the next flush starts over (and reports the same problem if it persists).
        this.dshRestart = true;
        return error instanceof Error ? error.message : 'AI_SURFACE_RANGE_INVALID';
      }
    }
    return '';
  }

  private put(item: AiTranscriptItem, append: boolean = false): void {
    const index = this.items.findIndex((value: AiTranscriptItem): boolean => value.id === item.id);
    if (index >= 0) {
      if (append) { item.text = this.items[index].text + item.text; }
      this.items[index] = item;
    } else { this.items.push(item); }
    this.items = this.items.slice();
  }
  prependIds(ids: string[]): void {
    const ordered: AiTranscriptItem[] = [];
    for (const id of ids) {
      const item = this.items.find((value: AiTranscriptItem): boolean => value.id === id);
      if (item !== undefined && !ordered.some((value: AiTranscriptItem): boolean => value.id === id)) { ordered.push(item); }
    }
    this.items = ordered.concat(this.items.filter((item: AiTranscriptItem): boolean => !ids.includes(item.id)));
  }
  codexItem(raw: Record<string, Object>, turnId: string, state: string = ''): void {
    const id = aiString(raw['id']);
    if (id === '') { return; }
    const item = aiCodexItem(raw, turnId, state);
    this.put(item);
  }
}
