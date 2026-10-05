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
    const index = items.findIndex((item: AiTranscriptItem): boolean => item.id === 'claude:stream:' + turnId +
      ':' + (streams.get(turnId) ?? 0).toString());
    if (index >= 0) { items.splice(index, 1); }
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
      const current = items.find((item: AiTranscriptItem): boolean => item.id === streamId);
      if (current !== undefined) { current.text = current.text + text; }
      else { items.push(aiClaudeItem(streamId, 'assistant', 'assistant', text, 'running', turnId)); }
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
  items.forEach((item: AiTranscriptItem): void => {
    const status = turnStates.get(item.turnId);
    if (status !== undefined && item.state === 'running') { item.state = status === 'completed' ? 'completed' : status; }
  });
  return items;
}

export class AiTranscript {
  items: AiTranscriptItem[] = [];
  private dshEvents: Map<number, Record<string, Object>> = new Map();
  private claudeEvents: Map<number, Record<string, Object>> = new Map();
  clear(): void { this.items = []; this.dshEvents.clear(); this.claudeEvents.clear(); }
  claudeEvent(event: Record<string, Object>): void {
    const seq = aiNumber(event['seq'], -1);
    if (!Number.isSafeInteger(seq) || seq < 0) { return; }
    this.claudeEvents.set(seq, event);
    const ordered: Record<string, Object>[] = [];
    Array.from(this.claudeEvents.keys()).sort((a: number, b: number): number => a - b).forEach((key: number): void => {
      const value = this.claudeEvents.get(key);
      if (value !== undefined) { ordered.push(value); }
    });
    this.items = aiClaudeItems(ordered);
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
    const type = aiString(raw['type']);
    const id = aiString(raw['id']);
    if (id === '') { return; }
    const role = type === 'userMessage' ? 'user' : type === 'agentMessage' ? 'assistant' : 'execution';
    let text = aiContentText(raw['text'] ?? raw['content']);
    if (role === 'execution') {
      text = type === 'reasoning' ? aiContentText(raw['summary']) : JSON.stringify(raw, null, 2);
    }
    this.put({ id, role, title: type, text, state: aiString(raw['status'], state), turnId });
  }
  dshEvent(event: Record<string, Object>): void {
    const seq = aiNumber(event['seq'], -1);
    if (!Number.isSafeInteger(seq) || seq < 0) { return; }
    this.dshEvents.set(seq, event);
    const items: AiTranscriptItem[] = [];
    const seqs = Array.from(this.dshEvents.keys()).sort((a: number, b: number): number => a - b);
    for (const current of seqs) {
      const row = this.dshEvents.get(current);
      if (row === undefined || row['data'] === undefined) { continue; }
      const type = aiString(row['type']);
      const data = aiRecord(row['data']);
      let replacementStart = -1;
      const surface = row['surfaceOp'];
      if (surface !== undefined && typeof surface === 'object') {
        const replace = aiRecord(surface);
        if (replace['op'] === 'replace') {
          const start = 'dsh:' + aiNumber(replace['start'], -1), end = 'dsh:' + aiNumber(replace['end'], -1);
          const first = items.findIndex((item: AiTranscriptItem): boolean => item.id === start);
          const last = items.findIndex((item: AiTranscriptItem): boolean => item.id === end);
          if (first < 0 || last < first) { throw new Error('AI_SURFACE_RANGE_INVALID'); }
          replacementStart = first; items.splice(first, last - first + 1);
        }
      }
      if (type === 'assistant/chunk') {
        const chunk = aiRecord(data['chunk']);
        const text = aiString(chunk['text'] ?? chunk['delta']);
        if (text !== '') { items.push({ id: 'dsh:' + current, role: 'assistant', title: 'assistant', text,
          state: 'running', turnId: aiNumber(data['turn']).toString() }); }
      } else if (type === 'user/message' || type === 'assistant/message' || type === 'tool/call' || type === 'tool/result') {
        const turnId = aiNumber(data['turn']).toString();
        if (type === 'assistant/message') {
          const sources = aiArray(row['sourceEventSeqs']).map((value: Object): number => aiNumber(value));
          for (let i = items.length - 1; i >= 0; i--) {
            if (sources.includes(Number(items[i].id.slice(4)))) { items.splice(i, 1); }
          }
        }
        const role = type === 'user/message' ? 'user' : type === 'assistant/message' ? 'assistant' : 'execution';
        const item: AiTranscriptItem = { id: 'dsh:' + current, role, title: role === 'execution' ? aiString(data['name'], type) : role,
          text: role === 'execution' ? JSON.stringify(data, null, 2) : aiContentText(data['message'] ?? data),
          state: data['interrupted'] === true ? 'interrupted' : 'completed', turnId };
        if (replacementStart >= 0) { items.splice(replacementStart, 0, item); } else { items.push(item); }
      }
    }
    this.items = items;
  }
}
