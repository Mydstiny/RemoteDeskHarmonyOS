import { AiTranscriptItem } from './AiModels';

/** How one tool step reads in a timeline row: an icon key, a verb, its target and a short result note. */
export interface AiToolView {
  /** 'terminal' | 'doc' | 'edit' | 'search' | 'globe' | 'list' | 'agent' | 'tool' */
  icon: string;
  verb: string;
  target: string;
  /** e.g. '+12 −3'; '' when there is nothing to count */
  stats: string;
}

export interface AiDiffLine {
  /** 'add' | 'del' | 'context' | 'hunk' */
  kind: string;
  text: string;
}

export interface AiDiffFile {
  path: string;
  added: number;
  removed: number;
  lines: AiDiffLine[];
}

const MAX_TARGET: number = 120;
const MAX_DIFF_LINES: number = 4000;

function record(text: string): Record<string, Object> {
  if (text.trim() === '' || !text.trim().startsWith('{')) { return {}; }
  try {
    const value: Object = JSON.parse(text) as Object;
    return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, Object> : {};
  } catch (_error) {
    return {};
  }
}

function str(value: Object | undefined): string { return typeof value === 'string' ? value : ''; }

function firstLine(text: string): string {
  const line = text.split('\n').find((value: string): boolean => value.trim() !== '') ?? '';
  const trimmed = line.trim();
  return trimmed.length > MAX_TARGET ? trimmed.slice(0, MAX_TARGET - 1) + '…' : trimmed;
}

/** The last two path segments are what people recognise on a phone. */
export function aiShortPath(path: string): string {
  const parts = path.split('/').filter((part: string): boolean => part !== '');
  return parts.length <= 2 ? path : '…/' + parts.slice(parts.length - 2).join('/');
}

function lineCount(text: string): number {
  if (text === '') { return 0; }
  return text.split('\n').length - (text.endsWith('\n') ? 1 : 0);
}

export function aiDiffStats(added: number, removed: number): string {
  if (added === 0 && removed === 0) { return ''; }
  return '+' + added.toString() + ' −' + removed.toString();
}

/** Parses a unified diff (git or plain) into files with counted, classified lines. */
export function aiDiffFiles(diff: string): AiDiffFile[] {
  const files: AiDiffFile[] = [];
  let current: AiDiffFile | null = null;
  let total = 0;
  const open = (path: string): AiDiffFile => {
    const file: AiDiffFile = { path, added: 0, removed: 0, lines: [] };
    files.push(file);
    return file;
  };
  for (const raw of diff.split('\n')) {
    if (total >= MAX_DIFF_LINES) { break; }
    if (raw.startsWith('diff --git ')) {
      const match = /^diff --git a\/(.+) b\/(.+)$/.exec(raw);
      current = open(match !== null ? match[2] : raw.slice(11));
      continue;
    }
    if (raw.startsWith('+++ ')) {
      const path = raw.slice(4).replace(/^b\//, '');
      if (current === null) { current = open(path); }
      else if (path !== '/dev/null' && current.lines.length === 0) { current.path = path; }
      continue;
    }
    if (raw.startsWith('--- ') || raw.startsWith('index ') || raw.startsWith('new file mode') ||
      raw.startsWith('deleted file mode') || raw.startsWith('similarity index') || raw.startsWith('rename ') ||
      raw.startsWith('Binary files')) {
      continue;
    }
    if (current === null) { current = open(''); }
    if (raw.startsWith('@@')) { current.lines.push({ kind: 'hunk', text: raw }); }
    else if (raw.startsWith('+')) { current.added++; current.lines.push({ kind: 'add', text: raw.slice(1) }); }
    else if (raw.startsWith('-')) { current.removed++; current.lines.push({ kind: 'del', text: raw.slice(1) }); }
    else if (raw.startsWith(' ')) { current.lines.push({ kind: 'context', text: raw.slice(1) }); }
    else if (raw !== '' && !raw.startsWith('\\')) { current.lines.push({ kind: 'context', text: raw }); }
    else { continue; }
    total++;
  }
  return files.filter((file: AiDiffFile): boolean => file.lines.length > 0 || file.path !== '');
}

/** A before/after replacement shown as a diff: removed lines, then added lines (no alignment). */
export function aiReplacementDiff(path: string, before: string, after: string): AiDiffFile {
  const file: AiDiffFile = { path, added: 0, removed: 0, lines: [] };
  if (before !== '') {
    before.split('\n').forEach((line: string): void => { file.lines.push({ kind: 'del', text: line }); file.removed++; });
  }
  if (after !== '') {
    after.split('\n').forEach((line: string): void => { file.lines.push({ kind: 'add', text: line }); file.added++; });
  }
  return file;
}

/** The diff a tool step carries: Codex file changes, Claude Edit/MultiEdit/Write inputs. */
export function aiItemDiff(item: AiTranscriptItem): AiDiffFile[] {
  const input = record(item.detail ?? '');
  const name = item.title;
  if (name === 'Edit') {
    return [aiReplacementDiff(str(input['file_path']), str(input['old_string']), str(input['new_string']))];
  }
  if (name === 'Write') {
    return [aiReplacementDiff(str(input['file_path']), '', str(input['content']))];
  }
  if (name === 'MultiEdit') {
    const file: AiDiffFile = { path: str(input['file_path']), added: 0, removed: 0, lines: [] };
    const edits = input['edits'];
    if (Array.isArray(edits)) {
      (edits as Object[]).forEach((value: Object): void => {
        if (value === null || typeof value !== 'object' || Array.isArray(value)) { return; }
        const edit = value as Record<string, Object>;
        const part = aiReplacementDiff('', str(edit['old_string']), str(edit['new_string']));
        file.lines.push({ kind: 'hunk', text: '@@' });
        file.lines = file.lines.concat(part.lines);
        file.added += part.added;
        file.removed += part.removed;
      });
    }
    return [file];
  }
  if (name === 'fileChange') { return aiDiffFiles(item.output ?? ''); }
  return [];
}

/** One-line summary of a tool step, for Claude, Codex and DSH tool names. */
export function aiToolView(item: AiTranscriptItem): AiToolView {
  const input = record(item.detail ?? '');
  const name = item.title;
  const path = str(input['file_path']) || str(input['path']) || str(input['notebook_path']);
  switch (name) {
    case 'Bash':
    case 'commandExecution':
      return { icon: 'terminal', verb: '运行', target: firstLine(str(input['command']) || item.text), stats: '' };
    case 'BashOutput':
      return { icon: 'terminal', verb: '查看输出', target: str(input['bash_id']), stats: '' };
    case 'Read':
      return { icon: 'doc', verb: '读取', target: aiShortPath(path), stats: '' };
    case 'Write': {
      const lines = lineCount(str(input['content']));
      return { icon: 'edit', verb: '写入', target: aiShortPath(path), stats: lines > 0 ? '+' + lines.toString() : '' };
    }
    case 'Edit':
    case 'MultiEdit':
    case 'NotebookEdit':
    case 'fileChange': {
      const files = aiItemDiff(item);
      let added = 0;
      let removed = 0;
      files.forEach((file: AiDiffFile): void => { added += file.added; removed += file.removed; });
      const target = files.length > 1 ? files.length.toString() + ' 个文件' :
        aiShortPath(files.length === 1 && files[0].path !== '' ? files[0].path : path || item.text);
      return { icon: 'edit', verb: '修改', target, stats: aiDiffStats(added, removed) };
    }
    case 'Glob':
      return { icon: 'search', verb: '查找文件', target: str(input['pattern']), stats: '' };
    case 'Grep':
      return { icon: 'search', verb: '搜索', target: str(input['pattern']), stats: '' };
    case 'WebFetch':
      return { icon: 'globe', verb: '打开网页', target: str(input['url']), stats: '' };
    case 'WebSearch':
    case 'webSearch':
      return { icon: 'globe', verb: '搜索网页', target: str(input['query']) || item.text, stats: '' };
    case 'TodoWrite':
    case 'todoList':
      return { icon: 'list', verb: '更新待办', target: '', stats: '' };
    case 'Task':
      return { icon: 'agent', verb: '子任务', target: firstLine(str(input['description'])), stats: '' };
    case 'mcpToolCall':
      return { icon: 'tool', verb: '调用工具', target: item.text, stats: '' };
    default:
      return { icon: 'tool', verb: name === '' ? '工具' : name, target: firstLine(item.text), stats: '' };
  }
}

/** Display state of a step: running, ok, failed or neither (unknown / not reported). */
export function aiStepState(state: string): string {
  if (state === 'running' || state === 'inProgress' || state === 'in_progress') { return 'running'; }
  if (state === 'completed' || state === 'success') { return 'ok'; }
  if (state === 'failed' || state === 'error' || state === 'declined' || state === 'interrupted') { return 'failed'; }
  return '';
}

/** Items that read as conversation (Codex style 对话 tab); everything else belongs to the log. */
export function aiConversationItem(item: AiTranscriptItem): boolean {
  const kind = item.kind ?? (item.role === 'execution' ? 'tool' : item.role);
  return kind === 'user' || kind === 'assistant' || kind === 'notice';
}
