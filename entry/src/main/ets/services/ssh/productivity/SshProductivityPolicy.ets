/** Pure policy for local SSH snippets, command history and shell markers. */

export type SshSnippetScope = 'global' | 'group' | 'host';

export interface SshSnippetVariableV1 {
  name: string;
  label: string;
  defaultValue: string;
  secretRef: string;
}

export interface SshSnippetV1 {
  id: string;
  title: string;
  description: string;
  template: string;
  scope: SshSnippetScope;
  scopeId: string;
  variables: Array<SshSnippetVariableV1>;
  insertOnly: boolean;
  updatedAt: number;
}

export interface SshStartupCommandV1 {
  hostId: string;
  snippetId: string;
  enabled: boolean;
}

export interface SshCommandHistoryV1 {
  id: string;
  hostId: string;
  command: string;
  createdAt: number;
  exitCode: number | null;
  pinned: boolean;
}

export interface SshProductivitySettingsV1 {
  historyEnabled: boolean;
  completionEnabled: boolean;
  completionNotificationEnabled: boolean;
  shellIntegrationEnabled: boolean;
  disabledHistoryHostIds: Array<string>;
}

export interface SshProductivityDocumentV1 {
  schemaVersion: 1;
  snippets: Array<SshSnippetV1>;
  startupCommands: Array<SshStartupCommandV1>;
  history: Array<SshCommandHistoryV1>;
  settings: SshProductivitySettingsV1;
}

export interface SshSnippetValue {
  name: string;
  value: string;
  secret: boolean;
}

export interface SshSnippetRenderResult {
  ok: boolean;
  insertion: string;
  preview: string;
  containsSecret: boolean;
  missingVariables: Array<string>;
}

export interface SshHistoryCaptureContext {
  hostId: string;
  command: string;
  nowMs: number;
  enabled: boolean;
  hostDisabled: boolean;
  passwordPrompt: boolean;
  rawMode: boolean;
  fullscreenMode: boolean;
  secretExpansion: boolean;
}

export type SshShellEventKind =
  | 'prompt_start'
  | 'command_start'
  | 'command_executed'
  | 'command_finished';

export interface SshShellEvent {
  kind: SshShellEventKind;
  exitCode: number | null;
  protocol: 'osc133' | 'osc633';
}

export interface SshShellParseResult {
  events: Array<SshShellEvent>;
  malformed: number;
}

export interface SshStartupFence {
  hostId: string;
  sessionId: number;
  generation: number;
  authenticated: boolean;
  hostKeyVerified: boolean;
}

export interface SshLocalCommandSubmit {
  command: string;
  rejectedSensitiveControl: boolean;
}

export const SSH_PRODUCTIVITY_SCHEMA_VERSION: number = 1;
export const SSH_PRODUCTIVITY_MAX_SNIPPETS: number = 200;
export const SSH_PRODUCTIVITY_MAX_HISTORY: number = 2000;
const MAX_TEXT: number = 4096;
const MAX_MARKER: number = 512;
const OSC_PREFIX: string = '\u001B]';
const TMUX_PREFIX: string = '\u001BPtmux;';

function text(value: Object, max: number): string {
  return typeof value === 'string' ? (value as string).trim().slice(0, max) : '';
}

function finiteTimestamp(value: Object): number {
  return typeof value === 'number' && Number.isFinite(value as number) && (value as number) >= 0 ?
    Math.floor(value as number) : 0;
}

function validId(value: string): boolean {
  return value.length > 0 && value.length <= 96;
}

function uniqueStrings(values: Array<string>, max: number): Array<string> {
  const result: Array<string> = [];
  for (let index: number = 0; index < values.length && result.length < max; index++) {
    const value: string = text(values[index], 96);
    if (value.length > 0 && result.indexOf(value) < 0) { result.push(value); }
  }
  return result;
}

export function emptySshProductivityDocument(): SshProductivityDocumentV1 {
  return {
    schemaVersion: 1,
    snippets: [],
    startupCommands: [],
    history: [],
    settings: {
      historyEnabled: false,
      completionEnabled: false,
      completionNotificationEnabled: false,
      shellIntegrationEnabled: false,
      disabledHistoryHostIds: []
    }
  };
}

export function normalizeSshSnippet(source: SshSnippetV1): SshSnippetV1 | null {
  const id: string = text(source.id, 96);
  const title: string = text(source.title, 120);
  const template: string = typeof source.template === 'string' ?
    source.template.slice(0, MAX_TEXT) : '';
  if (!validId(id) || title.length === 0 || template.length === 0 ||
    /[\u0000-\u001F\u007F]/.test(template) ||
    (source.scope !== 'global' && source.scope !== 'group' && source.scope !== 'host')) {
    return null;
  }
  const scopeId: string = source.scope === 'global' ? '' : text(source.scopeId, 96);
  if (source.scope !== 'global' && scopeId.length === 0) { return null; }
  const variables: Array<SshSnippetVariableV1> = [];
  const names: Array<string> = [];
  if (!Array.isArray(source.variables)) { return null; }
  for (let index: number = 0; index < source.variables.length && variables.length < 32; index++) {
    const item: SshSnippetVariableV1 = source.variables[index];
    if (item === null || typeof item !== 'object') { continue; }
    const name: string = text(item.name, 64);
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name) || names.indexOf(name) >= 0) { continue; }
    const secretRef: string = text(item.secretRef, 160);
    variables.push({
      name,
      label: text(item.label, 120) || name,
      // A secret reference and a plaintext default are mutually exclusive.
      defaultValue: secretRef.length > 0 ? '' :
        (typeof item.defaultValue === 'string' ? item.defaultValue.slice(0, 1024) : ''),
      secretRef
    });
    names.push(name);
  }
  return {
    id,
    title,
    description: text(source.description, 300),
    template,
    scope: source.scope,
    scopeId,
    variables,
    insertOnly: source.insertOnly !== false,
    updatedAt: finiteTimestamp(source.updatedAt)
  };
}

export function renderSshSnippet(snippet: SshSnippetV1,
  values: Array<SshSnippetValue>): SshSnippetRenderResult {
  const normalized: SshSnippetV1 | null = normalizeSshSnippet(snippet);
  if (normalized === null) {
    return { ok: false, insertion: '', preview: '', containsSecret: false,
      missingVariables: [] };
  }
  let insertion: string = normalized.template;
  let preview: string = normalized.template;
  let containsSecret: boolean = false;
  const missingVariables: Array<string> = [];
  for (let index: number = 0; index < normalized.variables.length; index++) {
    const variable: SshSnippetVariableV1 = normalized.variables[index];
    const supplied: SshSnippetValue | undefined = values.find(
      (item: SshSnippetValue): boolean => item.name === variable.name);
    const resolved: string = supplied === undefined ? variable.defaultValue : supplied.value;
    const secret: boolean = variable.secretRef.length > 0 ||
      (supplied !== undefined && supplied.secret);
    if (resolved.length === 0 || /[\u0000-\u001F\u007F]/.test(resolved)) {
      missingVariables.push(variable.name);
    }
    const token: string = '${' + variable.name + '}';
    insertion = insertion.split(token).join(resolved);
    preview = preview.split(token).join(secret && resolved.length > 0 ? '••••••' : resolved);
    containsSecret = containsSecret || (secret && resolved.length > 0);
  }
  return {
    ok: missingVariables.length === 0,
    insertion,
    preview,
    containsSecret,
    missingVariables
  };
}

export function captureSshHistory(context: SshHistoryCaptureContext,
  sequence: number): SshCommandHistoryV1 | null {
  const hostId: string = text(context.hostId, 96);
  const command: string = context.command.trim().slice(0, MAX_TEXT);
  if (!context.enabled || context.hostDisabled || context.passwordPrompt || context.rawMode ||
    context.fullscreenMode || context.secretExpansion || hostId.length === 0 ||
    command.length === 0 || /[\u0000-\u0008\u000B\u000C\u000E-\u001F]/.test(command)) {
    return null;
  }
  return {
    id: hostId + ':' + Math.floor(context.nowMs).toString(36) + ':' + sequence.toString(36),
    hostId,
    command,
    createdAt: Math.max(0, Math.floor(context.nowMs)),
    exitCode: null,
    pinned: false
  };
}

export function appendSshHistory(document: SshProductivityDocumentV1,
  record: SshCommandHistoryV1): SshProductivityDocumentV1 {
  const next: SshProductivityDocumentV1 = decodeSshProductivityDocument(
    encodeSshProductivityDocument(document)) ?? emptySshProductivityDocument();
  next.history = next.history.filter((item: SshCommandHistoryV1): boolean =>
    !(item.hostId === record.hostId && item.command === record.command));
  next.history.push(record);
  while (next.history.length > SSH_PRODUCTIVITY_MAX_HISTORY) {
    const removable: number = next.history.findIndex(
      (item: SshCommandHistoryV1): boolean => !item.pinned);
    if (removable < 0) { break; }
    next.history.splice(removable, 1);
  }
  return next;
}

export function startupCommandMayRun(fence: SshStartupFence,
  alreadyExecutedKey: string): boolean {
  const key: string = fence.hostId.trim() + ':' + fence.sessionId.toString() + ':' +
    fence.generation.toString();
  return fence.hostId.trim().length > 0 && fence.sessionId > 0 && fence.generation > 0 &&
    fence.authenticated && fence.hostKeyVerified && key !== alreadyExecutedKey;
}

export function sshStartupExecutionKey(fence: SshStartupFence): string {
  return fence.hostId.trim() + ':' + fence.sessionId.toString() + ':' +
    fence.generation.toString();
}

function shellEvent(protocol: 'osc133' | 'osc633', payload: string): SshShellEvent | null {
  const parts: Array<string> = payload.split(';');
  const code: string = parts.length > 0 ? parts[0] : '';
  let kind: SshShellEventKind;
  if (code === 'A') { kind = 'prompt_start'; }
  else if (code === 'B') { kind = 'command_start'; }
  else if (code === 'C') { kind = 'command_executed'; }
  else if (code === 'D') { kind = 'command_finished'; }
  else { return null; }
  let exitCode: number | null = null;
  if (kind === 'command_finished' && parts.length > 1 && /^-?\d{1,6}$/.test(parts[1])) {
    exitCode = Number(parts[1]);
  }
  return { kind, exitCode, protocol };
}

/** Incremental observer; terminal rendering must still receive the original bytes. */
export class SshShellIntegrationParser {
  private pending: string = '';

  push(chunk: string): SshShellParseResult {
    const source: string = this.pending + chunk;
    this.pending = '';
    const events: Array<SshShellEvent> = [];
    let malformed: number = 0;
    let cursor: number = 0;
    while (cursor < source.length) {
      const oscStart: number = source.indexOf(OSC_PREFIX, cursor);
      const tmuxStart: number = source.indexOf(TMUX_PREFIX, cursor);
      let start: number = oscStart;
      let tmux: boolean = false;
      if (tmuxStart >= 0 && (oscStart < 0 || tmuxStart < oscStart)) {
        start = tmuxStart;
        tmux = true;
      }
      if (start < 0) {
        this.pending = this.partialPrefixSuffix(source.slice(cursor));
        break;
      }
      if (tmux) {
        const tmuxEnd: number = this.findTmuxTerminator(source, start + TMUX_PREFIX.length);
        if (tmuxEnd < 0) {
          const remaining: string = source.slice(start);
          if (remaining.length <= MAX_MARKER * 2 + TMUX_PREFIX.length) {
            this.pending = remaining;
          } else {
            malformed++;
          }
          break;
        }
        const encodedBody: string = source.slice(start + TMUX_PREFIX.length, tmuxEnd);
        if (encodedBody.length > MAX_MARKER * 2) {
          malformed++;
        } else {
          const decodedBody: string = encodedBody.split('\u001B\u001B').join('\u001B');
          malformed += this.parseCompleteOsc(decodedBody, events);
        }
        cursor = tmuxEnd + 2;
        continue;
      }
      const bel: number = source.indexOf('\u0007', start + OSC_PREFIX.length);
      const st: number = source.indexOf('\u001B\\', start + OSC_PREFIX.length);
      let end: number = -1;
      let terminatorLength: number = 1;
      if (bel >= 0 && (st < 0 || bel < st)) { end = bel; }
      else if (st >= 0) { end = st; terminatorLength = 2; }
      if (end < 0) {
        const remaining: string = source.slice(start);
        if (remaining.length <= MAX_MARKER) { this.pending = remaining; }
        else { malformed++; }
        break;
      }
      if (end - start > MAX_MARKER) {
        malformed++;
        cursor = end + terminatorLength;
        continue;
      }
      const body: string = source.slice(start + OSC_PREFIX.length, end);
      const event: SshShellEvent | null = this.eventFromBody(body);
      if (event !== null) { events.push(event); }
      cursor = end + terminatorLength;
    }
    return { events, malformed };
  }

  reset(): void { this.pending = ''; }

  private eventFromBody(body: string): SshShellEvent | null {
    if (body.startsWith('133;')) { return shellEvent('osc133', body.slice(4)); }
    if (body.startsWith('633;')) { return shellEvent('osc633', body.slice(4)); }
    return null;
  }

  private parseCompleteOsc(source: string, events: Array<SshShellEvent>): number {
    let malformed: number = 0;
    let cursor: number = 0;
    while (cursor < source.length) {
      const start: number = source.indexOf(OSC_PREFIX, cursor);
      if (start < 0) { break; }
      const bel: number = source.indexOf('\u0007', start + OSC_PREFIX.length);
      const st: number = source.indexOf('\u001B\\', start + OSC_PREFIX.length);
      let end: number = -1;
      let terminatorLength: number = 1;
      if (bel >= 0 && (st < 0 || bel < st)) { end = bel; }
      else if (st >= 0) { end = st; terminatorLength = 2; }
      if (end < 0 || end - start > MAX_MARKER) {
        malformed++;
        break;
      }
      const event: SshShellEvent | null = this.eventFromBody(
        source.slice(start + OSC_PREFIX.length, end));
      if (event !== null) { events.push(event); }
      cursor = end + terminatorLength;
    }
    return malformed;
  }

  private findTmuxTerminator(source: string, from: number): number {
    for (let index: number = from; index + 1 < source.length; index++) {
      if (source.charAt(index) === '\u001B' && source.charAt(index + 1) === '\\' &&
        (index === from || source.charAt(index - 1) !== '\u001B')) {
        return index;
      }
    }
    return -1;
  }

  private partialPrefixSuffix(source: string): string {
    const prefixes: Array<string> = [OSC_PREFIX, TMUX_PREFIX];
    let result: string = '';
    for (let prefixIndex: number = 0; prefixIndex < prefixes.length; prefixIndex++) {
      const prefix: string = prefixes[prefixIndex];
      const maxLength: number = Math.min(source.length, prefix.length - 1);
      for (let length: number = maxLength; length > result.length; length--) {
        if (source.endsWith(prefix.slice(0, length))) {
          result = source.slice(source.length - length);
          break;
        }
      }
    }
    return result;
  }
}

/** Tracks only locally admitted printable input; remote output can never create history. */
export class SshLocalCommandTracker {
  private buffer: string = '';
  private rejectedSensitiveControl: boolean = false;

  push(data: string, safe: boolean): Array<SshLocalCommandSubmit> {
    const result: Array<SshLocalCommandSubmit> = [];
    if (!safe) {
      this.reset();
      return result;
    }
    for (let index: number = 0; index < data.length; index++) {
      const char: string = data.charAt(index);
      const code: number = data.charCodeAt(index);
      if (char === '\r' || char === '\n') {
        const command: string = this.buffer.trim();
        if (command.length > 0) {
          result.push({ command, rejectedSensitiveControl: this.rejectedSensitiveControl });
        }
        this.buffer = '';
        this.rejectedSensitiveControl = false;
      } else if (code === 8 || code === 127) {
        if (this.buffer.length > 0) { this.buffer = this.buffer.slice(0, -1); }
      } else if (code === 27 || (code < 32 && code !== 9)) {
        // Escape/control sequences are not reconstructable commands. Fail closed.
        this.rejectedSensitiveControl = true;
      } else if (this.buffer.length < MAX_TEXT) {
        this.buffer += char;
      }
    }
    return result;
  }

  reset(): void {
    this.buffer = '';
    this.rejectedSensitiveControl = false;
  }
}

export function encodeSshProductivityDocument(document: SshProductivityDocumentV1): string {
  const normalized: SshProductivityDocumentV1 = emptySshProductivityDocument();
  const snippetIds: Array<string> = [];
  for (let index: number = 0; index < document.snippets.length &&
    normalized.snippets.length < SSH_PRODUCTIVITY_MAX_SNIPPETS; index++) {
    const snippet: SshSnippetV1 | null = normalizeSshSnippet(document.snippets[index]);
    if (snippet !== null && snippetIds.indexOf(snippet.id) < 0) {
      snippetIds.push(snippet.id);
      normalized.snippets.push(snippet);
    }
  }
  normalized.startupCommands = document.startupCommands.slice(0, 200).map(
    (item: SshStartupCommandV1): SshStartupCommandV1 => ({
      hostId: text(item.hostId, 96),
      snippetId: text(item.snippetId, 96),
      enabled: item.enabled === true
    })).filter((item: SshStartupCommandV1): boolean => item.hostId.length > 0 &&
      item.snippetId.length > 0);
  normalized.history = document.history.slice(-SSH_PRODUCTIVITY_MAX_HISTORY).map(
    (item: SshCommandHistoryV1): SshCommandHistoryV1 => ({
      id: text(item.id, 160), hostId: text(item.hostId, 96),
      command: typeof item.command === 'string' ? item.command.slice(0, MAX_TEXT) : '',
      createdAt: finiteTimestamp(item.createdAt),
      exitCode: item.exitCode === null || !Number.isFinite(item.exitCode) ? null :
        Math.floor(item.exitCode),
      pinned: item.pinned === true
    })).filter((item: SshCommandHistoryV1): boolean => item.id.length > 0 &&
      item.hostId.length > 0 && item.command.trim().length > 0);
  normalized.settings = {
    historyEnabled: document.settings.historyEnabled === true,
    completionEnabled: document.settings.completionEnabled === true,
    completionNotificationEnabled: document.settings.completionNotificationEnabled === true,
    shellIntegrationEnabled: document.settings.shellIntegrationEnabled === true,
    disabledHistoryHostIds: uniqueStrings(document.settings.disabledHistoryHostIds, 500)
  };
  return JSON.stringify(normalized);
}

export function decodeSshProductivityDocument(raw: string): SshProductivityDocumentV1 | null {
  try {
    const source: Object = JSON.parse(raw) as Object;
    if (source === null || typeof source !== 'object') { return null; }
    const item = source as SshProductivityDocumentV1;
    if (item.schemaVersion !== 1 || !Array.isArray(item.snippets) ||
      !Array.isArray(item.startupCommands) || !Array.isArray(item.history) ||
      item.settings === null || typeof item.settings !== 'object' ||
      !Array.isArray(item.settings.disabledHistoryHostIds)) { return null; }
    return JSON.parse(encodeSshProductivityDocument(item)) as SshProductivityDocumentV1;
  } catch (_err) {
    return null;
  }
}

export function snippetVisibleForScope(snippet: SshSnippetV1, hostId: string,
  groupId: string): boolean {
  if (snippet.scope === 'global') { return true; }
  if (snippet.scope === 'host') { return snippet.scopeId === hostId.trim(); }
  return snippet.scopeId === groupId.trim();
}

export function searchSshProductivity(document: SshProductivityDocumentV1,
  query: string, hostId: string, groupId: string): Array<string> {
  const token: string = query.trim().toLowerCase().slice(0, 256);
  const result: Array<string> = [];
  for (let index: number = document.snippets.length - 1; index >= 0 && result.length < 100; index--) {
    const snippet: SshSnippetV1 = document.snippets[index];
    if (!snippetVisibleForScope(snippet, hostId, groupId)) { continue; }
    const haystack: string = (snippet.title + ' ' + snippet.description).toLowerCase();
    if (token.length === 0 || haystack.indexOf(token) >= 0) { result.push('snippet:' + snippet.id); }
  }
  for (let index: number = document.history.length - 1; index >= 0 && result.length < 100; index--) {
    const item: SshCommandHistoryV1 = document.history[index];
    if (item.hostId !== hostId.trim()) { continue; }
    if (token.length === 0 || item.command.toLowerCase().indexOf(token) >= 0) {
      result.push('history:' + item.id);
    }
  }
  return result;
}
