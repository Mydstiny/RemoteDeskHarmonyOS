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
  /** Lines beyond the phone's limit were left out (the full change stays on the computer). */
  truncated?: boolean;
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

/** DSH names its tools in lower case (bash, read, edit, …); they read like the Claude Code tools they mirror. */
function canonicalTool(name: string): string {
  switch (name) {
    case 'bash':
    case 'pwsh': return 'Bash';
    case 'read':
    case 'read_image': return 'Read';
    case 'write': return 'Write';
    case 'edit': return 'Edit';
    case 'grep': return 'Grep';
    case 'glob':
    case 'find': return 'Glob';
    case 'ls': return 'LS';
    case 'web_fetch': return 'WebFetch';
    case 'web_search': return 'WebSearch';
    case 'todo_write': return 'TodoWrite';
    case 'job_output': return 'BashOutput';
    default: return name;
  }
}

function firstQuery(input: Record<string, Object>): string {
  const queries = input['queries'];
  if (Array.isArray(queries)) {
    const first = (queries as Object[]).find((value: Object): boolean => typeof value === 'string');
    if (first !== undefined) { return first as string; }
  }
  return str(input['query']);
}

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

/** A path of a '--- ' or '+++ ' header: no trailing timestamp, no 'a/' or 'b/' prefix. */
function headerPath(text: string, prefix: string): string {
  const path = text.split('\t')[0];
  return path.startsWith(prefix) ? path.slice(prefix.length) : path;
}

/** The new path of a `diff --git a/x b/y` header, found without a backtracking pattern. */
function gitHeaderPath(line: string): string {
  const at = line.lastIndexOf(' b/');
  return at > 11 ? line.slice(at + 3) : line.slice(11);
}

/** The old and new line counts of a hunk header ('@@ -1,3 +1,4 @@'), or null when it has none. */
function hunkCounts(line: string): number[] | null {
  const match = /^@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@/.exec(line);
  if (match === null) { return null; }
  return [match[1] === undefined ? 1 : Number(match[1]), match[2] === undefined ? 1 : Number(match[2])];
}

/**
 * Parses a unified diff (git or plain) into files with counted, classified lines. Inside a hunk its line counts
 * decide where the content ends, so content lines that look like headers ('--- x', '+++ y') stay content.
 */
export function aiDiffFiles(diff: string): AiDiffFile[] {
  const files: AiDiffFile[] = [];
  let current: AiDiffFile | null = null;
  let total = 0;
  let oldLeft = 0;
  let newLeft = 0;
  // `git diff --binary` follows 'GIT binary patch' with encoded data up to the next file.
  let binary = false;
  const open = (path: string): AiDiffFile => {
    const file: AiDiffFile = { path, added: 0, removed: 0, lines: [] };
    files.push(file);
    return file;
  };
  let full = false;
  // Only a line that would be shown counts toward the limit; headers and skipped binary data do not.
  const room = (file: AiDiffFile): boolean => {
    if (total < MAX_DIFF_LINES) { return true; }
    file.truncated = true;
    full = true;
    return false;
  };
  const lines = diff.split('\n');
  // The '--- ' path of a plain diff, for a deleted file whose '+++ ' is /dev/null.
  let fromPath = '';
  for (let index = 0; index < lines.length; index++) {
    if (full) { break; }
    const line = lines[index];
    const raw = line.endsWith('\r') ? line.slice(0, line.length - 1) : line;
    // Hunk content always starts with ' ', '+', '-' or '\\': only '+++ ' and '--- ' can be either.
    const inHunk = oldLeft > 0 || newLeft > 0;
    if (raw.startsWith('diff --git ')) {
      current = open(gitHeaderPath(raw));
      oldLeft = 0; newLeft = 0; binary = false;
      continue;
    }
    if (binary) { continue; }
    if (!inHunk && raw === 'GIT binary patch') {
      binary = true;
      if (current === null) { current = open(''); }
      if (!room(current)) { break; }
      current.lines.push({ kind: 'context', text: '（二进制文件）' });
      total++;
      continue;
    }
    if (!inHunk && raw.startsWith('+++ ')) {
      const named = headerPath(raw.slice(4), 'b/');
      const path = named === '/dev/null' ? fromPath : named;
      if (current === null) { current = open(path); }
      else if (path !== '' && path !== '/dev/null' && current.lines.length === 0) { current.path = path; }
      continue;
    }
    // A file header is '--- ' directly followed by '+++ '; anything else outside a hunk is content.
    if (!inHunk && raw.startsWith('--- ') && index + 1 < lines.length && lines[index + 1].startsWith('+++ ')) {
      fromPath = headerPath(raw.slice(4), 'a/');
      // Without git headers, the header after a file's lines starts the next file.
      if (current !== null && current.lines.length > 0) { current = null; }
      continue;
    }
    if (raw.startsWith('index ') || raw.startsWith('new file mode') ||
      raw.startsWith('deleted file mode') || raw.startsWith('similarity index') || raw.startsWith('rename ') ||
      raw.startsWith('Binary files')) {
      continue;
    }
    if (current === null) { current = open(''); }
    const shown = raw.startsWith('@@') || raw.startsWith('+') || raw.startsWith('-') || raw.startsWith(' ') ||
      (raw !== '' && !raw.startsWith('\\')) || (raw === '' && oldLeft > 0 && newLeft > 0);
    if (shown && !room(current)) { break; }
    if (raw.startsWith('@@')) {
      const counts = hunkCounts(raw);
      oldLeft = counts !== null ? counts[0] : 0;
      newLeft = counts !== null ? counts[1] : 0;
      current.lines.push({ kind: 'hunk', text: raw });
    } else if (raw.startsWith('+')) {
      current.added++; current.lines.push({ kind: 'add', text: raw.slice(1) }); newLeft--;
    } else if (raw.startsWith('-')) {
      current.removed++; current.lines.push({ kind: 'del', text: raw.slice(1) }); oldLeft--;
    } else if (raw.startsWith(' ')) {
      current.lines.push({ kind: 'context', text: raw.slice(1) }); oldLeft--; newLeft--;
    } else if (raw.startsWith('\\')) {
      continue;
    } else if (raw !== '') {
      current.lines.push({ kind: 'context', text: raw }); oldLeft--; newLeft--;
    } else if (oldLeft > 0 && newLeft > 0) {
      // A context line whose leading space was trimmed away.
      current.lines.push({ kind: 'context', text: '' }); oldLeft--; newLeft--;
    } else {
      continue;
    }
    total++;
  }
  return files.filter((file: AiDiffFile): boolean => file.lines.length > 0 || file.path !== '');
}

/**
 * Identifies the content of a set of diffs (paths, lines, counts), so a view of them is rebuilt when it changes.
 * Every character is hashed until a budget of a million; beyond it a line contributes its ends and an even sample.
 */
export function aiDiffSignature(files: AiDiffFile[]): string {
  let hash = 0x811c9dc5;
  let lines = 0;
  let budget = 1000000;
  const step = (code: number): void => { hash = Math.imul(hash ^ code, 0x01000193) >>> 0; };
  const mix = (text: string): void => {
    if (text.length <= budget) {
      for (let i = 0; i < text.length; i++) { step(text.charCodeAt(i)); }
      budget -= text.length;
    } else {
      const stride = Math.max(1, Math.floor(text.length / 256));
      for (let i = 0; i < text.length && i < 256; i++) { step(text.charCodeAt(i)); }
      for (let i = 0; i < text.length; i += stride) { step(text.charCodeAt(i)); }
      for (let i = Math.max(0, text.length - 256); i < text.length; i++) { step(text.charCodeAt(i)); }
    }
    step(text.length & 0xffff);
    step((text.length >>> 16) & 0xffff);
  };
  files.forEach((file: AiDiffFile): void => {
    mix(file.path);
    mix(file.added.toString() + '/' + file.removed.toString() + (file.truncated === true ? '/cut' : ''));
    file.lines.forEach((line: AiDiffLine): void => { mix(line.kind); mix(line.text); lines++; });
  });
  return files.length.toString() + ':' + lines.toString() + ':' + hash.toString(16);
}

/**
 * A before/after replacement shown as a diff: removed lines, then added lines (no alignment). Counts cover every
 * line; at most MAX_DIFF_LINES of them are kept for display.
 */
export function aiReplacementDiff(path: string, before: string, after: string): AiDiffFile {
  const file: AiDiffFile = { path, added: 0, removed: 0, lines: [] };
  const take = (text: string, kind: string): void => {
    if (text === '') { return; }
    const lines = text.split('\n');
    if (kind === 'del') { file.removed += lines.length; } else { file.added += lines.length; }
    const room = MAX_DIFF_LINES - file.lines.length;
    if (lines.length > room) { file.truncated = true; }
    lines.slice(0, Math.max(0, room)).forEach((line: string): void => { file.lines.push({ kind, text: line }); });
  };
  take(before, 'del');
  take(after, 'add');
  return file;
}

/** The diff a tool step carries: Codex file changes, Claude and DSH Edit/MultiEdit/Write inputs. */
export function aiItemDiff(item: AiTranscriptItem): AiDiffFile[] {
  const input = record(item.detail ?? '');
  const name = canonicalTool(item.title);
  if (name === 'str_replace_editor') {
    const command = str(input['command']);
    if (command === 'create') { return [aiReplacementDiff(str(input['path']), '', str(input['file_text']))]; }
    if (command === 'str_replace' || command === 'insert') {
      return [aiReplacementDiff(str(input['path']), str(input['old_str']), str(input['new_str']))];
    }
    return [];
  }
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
        file.added += part.added;
        file.removed += part.removed;
        const room = MAX_DIFF_LINES - file.lines.length - 1;
        if (part.truncated === true || part.lines.length > room) { file.truncated = true; }
        if (room > 0) {
          file.lines.push({ kind: 'hunk', text: '@@' });
          file.lines = file.lines.concat(part.lines.slice(0, room));
        }
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
  const name = canonicalTool(item.title);
  const path = str(input['file_path']) || str(input['path']) || str(input['notebook_path']);
  switch (name) {
    case 'Bash':
    case 'commandExecution':
      return { icon: 'terminal', verb: '运行', target: firstLine(str(input['command']) || item.text), stats: '' };
    case 'BashOutput':
      return { icon: 'terminal', verb: '查看输出', target: str(input['bash_id']) || str(input['job_id']) || str(input['id']),
        stats: '' };
    case 'Read':
      return { icon: 'doc', verb: '读取', target: aiShortPath(path), stats: '' };
    case 'Write': {
      const lines = lineCount(str(input['content']));
      return { icon: 'edit', verb: '写入', target: aiShortPath(path), stats: lines > 0 ? '+' + lines.toString() : '' };
    }
    case 'str_replace_editor':
      if (str(input['command']) === 'view') { return { icon: 'doc', verb: '读取', target: aiShortPath(path), stats: '' }; }
      return aiEditView(item, path);
    case 'Edit':
    case 'MultiEdit':
    case 'NotebookEdit':
    case 'fileChange':
      return aiEditView(item, path);
    case 'Glob':
      return { icon: 'search', verb: '查找文件', target: str(input['pattern']), stats: '' };
    case 'LS':
      return { icon: 'doc', verb: '列出目录', target: aiShortPath(path) || '项目目录', stats: '' };
    case 'Grep':
      return { icon: 'search', verb: '搜索', target: str(input['pattern']), stats: '' };
    case 'WebFetch':
      return { icon: 'globe', verb: '打开网页', target: str(input['url']), stats: '' };
    case 'WebSearch':
    case 'webSearch':
      return { icon: 'globe', verb: '搜索网页', target: firstQuery(input) || item.text, stats: '' };
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

function aiEditView(item: AiTranscriptItem, path: string): AiToolView {
  const files = aiItemDiff(item);
  let added = 0;
  let removed = 0;
  files.forEach((file: AiDiffFile): void => { added += file.added; removed += file.removed; });
  const target = files.length > 1 ? files.length.toString() + ' 个文件' :
    aiShortPath(files.length === 1 && files[0].path !== '' ? files[0].path : path || item.text);
  return { icon: 'edit', verb: '修改', target, stats: aiDiffStats(added, removed) };
}

/** Display state of a step: running, ok, failed or neither (unknown / not reported). */
export function aiStepState(state: string): string {
  if (state === 'running' || state === 'inProgress' || state === 'in_progress') { return 'running'; }
  if (state === 'completed' || state === 'success') { return 'ok'; }
  if (state === 'failed' || state === 'error' || state === 'declined' || state === 'interrupted' || state === 'aborted') {
    return 'failed';
  }
  return '';
}

/** Items that read as conversation (Codex style 对话 tab); everything else belongs to the log. */
export function aiConversationItem(item: AiTranscriptItem): boolean {
  const kind = item.kind ?? (item.role === 'execution' ? 'tool' : item.role);
  return kind === 'user' || kind === 'assistant' || kind === 'notice';
}

/**
 * One row of the conversation as the Codex and Claude apps show it: a message, or a run of consecutive steps (tool
 * calls and thinking) folded into one summary line that opens to the single steps.
 */
export interface AiStepEntry { key: string; item: AiTranscriptItem | null; steps: AiTranscriptItem[]; }
export function aiIsStep(item: AiTranscriptItem): boolean {
  const kind = item.kind ?? (item.role === 'execution' ? 'tool' : item.role);
  return kind === 'tool' || kind === 'thinking';
}
export function aiStepEntries(items: AiTranscriptItem[]): AiStepEntry[] {
  const entries: AiStepEntry[] = [];
  let run: AiTranscriptItem[] = [];
  const close = (): void => {
    if (run.length > 0) { entries.push({ key: 'g:' + run[0].id, item: null, steps: run }); run = []; }
  };
  for (const item of items) {
    if (aiIsStep(item)) { run.push(item); continue; }
    close();
    entries.push({ key: 'i:' + item.id, item, steps: [] });
  }
  close();
  return entries;
}
/**
 * The newest row already shows the turn at work (正在思考 with its shimmer, a step's spinner): the 正在思考 /
 * 正在工作 line below the transcript would say it a second time.
 */
export function aiLastEntryRunning(entries: AiStepEntry[]): boolean {
  if (entries.length === 0) { return false; }
  const last = entries[entries.length - 1];
  return last.item === null && last.steps.some((step: AiTranscriptItem): boolean => aiStepState(step.state) === 'running');
}
/** 已运行 4 条命令、已浏览 3 个文件 — what a run of steps did, in the order the kinds first appear. */
export function aiStepSummary(steps: AiTranscriptItem[]): string {
  const order: string[] = [];
  const counts: Map<string, number> = new Map();
  let thinking = 0;
  for (const step of steps) {
    if ((step.kind ?? '') === 'thinking') { thinking++; continue; }
    const icon = aiToolView(step).icon;
    if (!counts.has(icon)) { order.push(icon); }
    counts.set(icon, (counts.get(icon) ?? 0) + 1);
  }
  const parts: string[] = order.map((icon: string): string => {
    const n = (counts.get(icon) ?? 0).toString();
    switch (icon) {
      case 'terminal': return '已运行 ' + n + ' 条命令';
      case 'edit': return '已修改 ' + n + ' 个文件';
      case 'doc': return '已浏览 ' + n + ' 个文件';
      case 'search': return '搜索 ' + n + ' 次';
      case 'globe': return '浏览网页 ' + n + ' 次';
      case 'agent': return '派出 ' + n + ' 个子任务';
      case 'list': return '更新待办';
      default: return '调用 ' + n + ' 个工具';
    }
  });
  if (parts.length === 0) { return thinking > 0 ? '已思考' : ''; }
  return parts.join('、');
}
/** The icon a folded run shows: the kind it did most (commands over edits over reading). */
export function aiStepGroupIcon(steps: AiTranscriptItem[]): string {
  const counts: Map<string, number> = new Map();
  for (const step of steps) {
    if ((step.kind ?? '') === 'thinking') { continue; }
    const icon = aiToolView(step).icon;
    counts.set(icon, (counts.get(icon) ?? 0) + 1);
  }
  let best = 'thinking', most = 0;
  counts.forEach((count: number, icon: string): void => { if (count > most) { most = count; best = icon; } });
  return best;
}
