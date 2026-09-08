import { AiTranscriptItem } from './AiModels';
import { aiArray, aiNumber, aiRecord, aiString } from './AiWirePolicy';

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
export class AiTranscript {
  items: AiTranscriptItem[] = [];
  private dshEvents: Map<number, Record<string, Object>> = new Map();
  clear(): void { this.items = []; this.dshEvents.clear(); }
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
