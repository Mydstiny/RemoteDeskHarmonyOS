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

function aiClaudeItem(id: string, kind: string, title: string, text: string, state: string, turnId: string):
  AiTranscriptItem {
  const role = kind === 'user' ? 'user' : kind === 'assistant' ? 'assistant' : 'execution';
  return { id, role, title, text, state, turnId, kind, detail: '', output: '' };
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
  const addTool = (id: string, name: string, input: Object | undefined, turnId: string, state: string): void => {
    const existing = tools.get(id);
    if (existing !== undefined) { return; }
    const item = aiClaudeItem('claude:tool:' + id, 'tool', name === '' ? '工具' : name, '', state, turnId);
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
        const item = aiClaudeItem(streamId, 'assistant', 'assistant', text, 'running', turnId);
        streamItems.set(streamId, item);
        items.push(item);
      }
    } else if (type === 'assistant/message') {
      if (data['message'] !== undefined && typeof data['message'] === 'string') {
        const kind = aiString(data['kind'], 'text');
        if (aiString(data['message']) === '') { continue; }
        if (kind === 'thinking') {
          items.push(aiClaudeItem(id, 'thinking', '思考', aiString(data['message']), 'completed', turnId));
        } else {
          dropStream(turnId);
          items.push(aiClaudeItem(id, 'assistant', 'assistant', aiString(data['message']), 'completed', turnId));
        }
        continue;
      }
      // History: one event per stored message, whose content holds every block.
      aiBlocks(aiContentOf(data['message'])).forEach((block: Record<string, Object>,
        index: number): void => {
        const blockType = aiString(block['type']);
        if (blockType === 'text' && aiString(block['text']) !== '') {
          items.push(aiClaudeItem(id + ':' + index.toString(), 'assistant', 'assistant', aiString(block['text']),
            'completed', turnId));
        } else if (blockType === 'thinking' && aiString(block['thinking']) !== '') {
          items.push(aiClaudeItem(id + ':' + index.toString(), 'thinking', '思考', aiString(block['thinking']),
            'completed', turnId));
        } else if (blockType === 'tool_use') {
          // Stored history does not say whether the tool finished; its tool_result, if any, will.
          addTool(aiString(block['id']), aiString(block['name']), block['input'], turnId, '');
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
      if (texts.length > 0) { items.push(aiClaudeItem(id, 'user', 'user', texts.join('\n'), 'completed', turnId)); }
    } else if (type === 'tool/call') {
      addTool(aiString(data['id']), aiString(data['name']), data['input'], turnId, 'running');
    } else if (type === 'tool/result') {
      // A tool the local user or policy refused; it never ran.
      const item = aiClaudeItem(id, 'tool', aiString(data['name'], '工具'), '', 'declined', turnId);
      item.output = aiString(data['message']);
      items.push(item);
    } else if (type === 'turn/end') {
      const status = aiString(data['status'], 'completed');
      turnStates.set(turnId, status);
      if (status === 'failed' && aiString(data['result']) !== '') {
        const notice = aiClaudeItem(id, 'notice', '执行失败', aiString(data['result']), 'failed', turnId);
        items.push(notice);
      }
    } else if (type === 'error') {
      items.push(aiClaudeItem(id, 'notice', '错误', aiErrorText(aiString(data['code'])), 'failed', turnId));
    } else if (type === 'session/compacted') {
      items.push(aiClaudeItem(id, 'notice', '上下文已压缩', '', 'completed', turnId));
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
  if ((type !== 'add' && type !== 'delete') || body.startsWith('@@') || body.includes('\n@@') ||
    body.startsWith('diff --git')) {
    return body;
  }
  const sign = type === 'add' ? '+' : '-';
  const lines = (body.endsWith('\n') ? body.slice(0, body.length - 1) : body).split('\n');
  return '@@ ' + (type === 'add' ? '新文件' : '已删除') + ' @@\n' +
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
  const kind = aiString(aiRecord(reason)['kind'], 'completed');
  if (kind === 'completed' || kind === 'max-tokens') { return 'completed'; }
  return kind === 'aborted' || kind === 'interrupted' ? 'interrupted' : 'failed';
}

/**
 * DSH session events (ordered by seq) to transcript items. Surface replacements (compaction) cut the item range
 * they name; a tool result is folded into its call through `toolCallId`, and its own event stays as a hidden
 * placeholder so later replacements can still name it. A finished turn leaves nothing running.
 */
export function aiDshItems(events: Record<string, Object>[]): AiTranscriptItem[] {
  const items: AiTranscriptItem[] = [];
  const calls: Map<string, AiTranscriptItem> = new Map();
  const turnStates: Map<string, string> = new Map();
  for (const row of events) {
    const current = aiNumber(row['seq'], -1);
    if (row['data'] === undefined || row['data'] === null) { continue; }
    const type = aiString(row['type']);
    const data = aiRecord(row['data']);
    let replacementStart = -1;
    const surface = row['surfaceOp'];
    if (surface !== undefined && surface !== null && typeof surface === 'object') {
      const replace = aiRecord(surface);
      if (replace['op'] === 'replace') {
        const start = 'dsh:' + aiNumber(replace['start'], -1), end = 'dsh:' + aiNumber(replace['end'], -1);
        const first = items.findIndex((item: AiTranscriptItem): boolean => item.id === start);
        const last = items.findIndex((item: AiTranscriptItem): boolean => item.id === end);
        if (first < 0 || last < first) { throw new Error('AI_SURFACE_RANGE_INVALID'); }
        replacementStart = first; items.splice(first, last - first + 1);
      }
    }
    const turnId = aiNumber(data['turn']).toString();
    const add = (item: AiTranscriptItem): void => {
      if (replacementStart >= 0) { items.splice(replacementStart, 0, item); } else { items.push(item); }
    };
    if (type === 'assistant/chunk') {
      const chunk = aiRecord(data['chunk']);
      const text = aiString(chunk['text'] ?? chunk['delta']);
      if (text !== '') { items.push({ id: 'dsh:' + current, role: 'assistant', title: 'assistant', text,
        state: 'running', turnId, kind: 'assistant', detail: '', output: '' }); }
    } else if (type === 'user/message' || type === 'assistant/message') {
      if (type === 'assistant/message') {
        const sources = aiArray(row['sourceEventSeqs']).map((value: Object): number => aiNumber(value));
        for (let i = items.length - 1; i >= 0; i--) {
          if (sources.includes(Number(items[i].id.slice(4)))) { items.splice(i, 1); }
        }
      }
      const role = type === 'user/message' ? 'user' : 'assistant';
      add({ id: 'dsh:' + current, role, title: role, text: aiContentText(data['message'] ?? data),
        state: data['interrupted'] === true ? 'interrupted' : 'completed', turnId, kind: role, detail: '', output: '' });
    } else if (type === 'tool/call') {
      const item: AiTranscriptItem = { id: 'dsh:' + current, role: 'execution', title: aiString(data['name'], '工具'),
        text: '', state: 'running', turnId, kind: 'tool',
        detail: aiDshArguments(data['arguments'] ?? data['input'] ?? data['args']), output: '' };
      const callId = aiString(data['callId']);
      if (callId !== '') { calls.set(callId, item); }
      add(item);
    } else if (type === 'tool/result') {
      const message = aiRecord(data['message']);
      const block = aiArray(message['content']).map((value: Object): Record<string, Object> => aiRecord(value))
        .find((value: Record<string, Object>): boolean => aiString(value['type']) === 'tool-result');
      const callId = block !== undefined ? aiString(block['toolCallId']) : aiString(aiRecord(message['source'])['callId']);
      const output = block !== undefined ? aiContentText(block['content']) : aiContentText(message['content']);
      const state = (block !== undefined && block['isError'] === true) || data['error'] !== undefined ? 'failed' : 'completed';
      const call = calls.get(callId);
      if (call !== undefined) {
        call.output = output;
        call.state = state;
        add({ id: 'dsh:' + current, role: 'execution', title: '', text: '', state, turnId, kind: 'merged', detail: '',
          output: '' });
      } else {
        add({ id: 'dsh:' + current, role: 'execution', title: '工具结果', text: '', state, turnId, kind: 'tool',
          detail: '', output });
      }
    } else if (type === 'turn/end') {
      turnStates.set(turnId, aiDshTurnState(data['reason']));
    }
  }
  const result = items.filter((item: AiTranscriptItem): boolean => item.kind !== 'merged');
  result.forEach((item: AiTranscriptItem): void => {
    const status = turnStates.get(item.turnId);
    if (status !== undefined && item.state === 'running') { item.state = status; }
  });
  return result;
}

/** The text a user/message event typed (tool results and images do not count). */
function aiUserText(event: Record<string, Object>): string {
  const texts: string[] = [];
  aiBlocks(aiContentOf(aiRecord(event['data'])['message'])).forEach((block: Record<string, Object>): void => {
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
    this.pending = '';
  }

  /** Shows a sent prompt until a later engine event for the same turn (or with the same text) stands for it. */
  echo(text: string, turnId: string): void {
    const trimmed = text.trim();
    if (trimmed === '') { return; }
    this.echoCount++;
    this.echoes.push({ item: { id: 'echo:' + this.echoCount.toString(), role: 'user', title: 'user', text, state: 'completed',
      turnId, kind: 'user', detail: '', output: '' }, text: trimmed, after: this.claudeArrived });
    this.flush();
    this.items = this.withEchoes(this.items);
  }

  private withEchoes(items: AiTranscriptItem[]): AiTranscriptItem[] {
    const result = items.filter((item: AiTranscriptItem): boolean => !item.id.startsWith('echo:'));
    for (const echo of this.echoes) {
      // Before the first item of its turn; a turn the engine has not reported yet ends the list, in sending order.
      const at = echo.item.turnId === '' ? -1 :
        result.findIndex((item: AiTranscriptItem): boolean => item.turnId === echo.item.turnId && item !== echo.item &&
          !item.id.startsWith('echo:'));
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
        // The same words first; otherwise the prompt that opened this turn (the engine may add to its text).
        let at = this.echoes.findIndex((echo: AiEcho): boolean => echo.after <= index && echo.text === text);
        if (at < 0) {
          at = this.echoes.findIndex((echo: AiEcho): boolean => echo.after <= index && echo.item.turnId !== '' &&
            echo.item.turnId === turn);
        }
        if (at >= 0) { this.echoes.splice(at, 1); }
      }
    }
    this.pending = 'claude';
    if (!defer) { this.flush(); }
  }

  /** Records a DSH event; `defer` leaves the mapping to the next flush(). */
  dshEvent(event: Record<string, Object>, defer: boolean = false): void {
    const seq = aiNumber(event['seq'], -1);
    if (!Number.isSafeInteger(seq) || seq < 0) { return; }
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
      const ordered: Record<string, Object>[] = [];
      Array.from(this.dshEvents.keys()).sort((a: number, b: number): number => a - b).forEach((key: number): void => {
        const value = this.dshEvents.get(key);
        if (value !== undefined) { ordered.push(value); }
      });
      try { this.items = aiDshItems(ordered); }
      catch (error) { return error instanceof Error ? error.message : 'AI_SURFACE_RANGE_INVALID'; }
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
