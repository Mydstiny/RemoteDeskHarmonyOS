/**
 * Pure, local-only policy for opt-in SSH session logs.
 *
 * The terminal transcript is still the short-lived renderer replay buffer.
 * This policy is the durable log boundary: records are sanitized before they
 * can enter a chunk, raw VT/control bytes are never part of the search index,
 * and sensitive/authentication modes fail closed.
 */

export type SshSessionLogDirection = 'input' | 'output' | 'event';
export type SshSessionLogEventKind =
  | 'data'
  | 'command_started'
  | 'command_finished'
  | 'state'
  | 'bookmark';

export interface SshSessionLogIdentityV1 {
  hostId: string;
  sessionId: number;
  generation: number;
}

export interface SshSessionLogRecordV1 extends SshSessionLogIdentityV1 {
  id: string;
  timestamp: number;
  direction: SshSessionLogDirection;
  kind: SshSessionLogEventKind;
  text: string;
  searchText: string;
  byteSize: number;
}

export interface SshSessionLogChunkV1 {
  id: string;
  hostId: string;
  sessionId: number;
  generation: number;
  createdAt: number;
  updatedAt: number;
  byteSize: number;
  records: Array<SshSessionLogRecordV1>;
}

export interface SshSessionLogBookmarkV1 extends SshSessionLogIdentityV1 {
  id: string;
  recordId: string;
  createdAt: number;
  note: string;
  pinned: boolean;
}

export interface SshSessionLogSettingsV1 {
  enabled: boolean;
  paused: boolean;
  redactSensitive: boolean;
  retentionDays: number;
  quotaBytes: number;
}

export interface SshSessionLogDocumentV1 {
  schemaVersion: number;
  chunks: Array<SshSessionLogChunkV1>;
  bookmarks: Array<SshSessionLogBookmarkV1>;
  settings: SshSessionLogSettingsV1;
}

export interface SshSessionLogCaptureContextV1 extends SshSessionLogIdentityV1 {
  enabled: boolean;
  paused: boolean;
  passwordPrompt: boolean;
  mfaPrompt: boolean;
  passphrasePrompt: boolean;
  rawMode: boolean;
  fullscreenMode: boolean;
  secretExpansion: boolean;
}

export interface SshSessionLogSearchHitV1 {
  record: SshSessionLogRecordV1;
  bookmarked: boolean;
  bookmarkId: string;
}

export interface SshSessionLogSearchCursorV1 {
  token: string;
  hostId: string;
  identityEnabled: boolean;
  identityHostId: string;
  identitySessionId: number;
  identityGeneration: number;
  chunkIndex: number;
  recordIndex: number;
  results: Array<SshSessionLogSearchHitV1>;
  done: boolean;
}

export interface SshSessionLogExportResultV1 {
  ok: boolean;
  text: string;
  recordCount: number;
  redactedCount: number;
  truncated: boolean;
}

export type SshSessionLogSanitizeModeV1 =
  | 'normal'
  | 'escape'
  | 'csi'
  | 'osc'
  | 'osc_escape'
  | 'string'
  | 'string_escape'
  | 'resync';

export interface SshSessionLogSanitizeResultV1 {
  text: string;
  mode: SshSessionLogSanitizeModeV1;
}

export type SshSessionLogStreamRedactionPhaseV1 =
  'normal' | 'separator' | 'value_pending' | 'value';

export type SshSessionLogStreamMarkerKindV1 = 'assignment' | 'sshpass';

/** Bounded streaming state; it never retains a secret value. */
export interface SshSessionLogStreamSanitizeStateV1 {
  mode: SshSessionLogSanitizeModeV1;
  redactionPhase: SshSessionLogStreamRedactionPhaseV1;
  redactionCarry: string;
  redactionBoundary: boolean;
  markerKind: SshSessionLogStreamMarkerKindV1;
}

export interface SshSessionLogStreamSanitizeResultV1 {
  text: string;
  state: SshSessionLogStreamSanitizeStateV1;
}

export const SSH_SESSION_LOG_SCHEMA_VERSION: number = 1;
export const SSH_SESSION_LOGS_FLAG_KEY: string = 'sshSessionLogs';
export const SSH_SESSION_LOGS_DEFAULT_ENABLED: boolean = false;
export const SSH_SESSION_LOG_DEFAULT_QUOTA_BYTES: number = 10 * 1024 * 1024;
export const SSH_SESSION_LOG_MIN_QUOTA_BYTES: number = 256 * 1024;
export const SSH_SESSION_LOG_MAX_QUOTA_BYTES: number = 64 * 1024 * 1024;
export const SSH_SESSION_LOG_DEFAULT_RETENTION_DAYS: number = 30;
export const SSH_SESSION_LOG_MAX_RETENTION_DAYS: number = 365;
export const SSH_SESSION_LOG_CHUNK_MAX_BYTES: number = 64 * 1024;
export const SSH_SESSION_LOG_CHUNK_MAX_RECORDS: number = 128;
export const SSH_SESSION_LOG_MAX_BOOKMARKS: number = 500;
export const SSH_SESSION_LOG_MAX_SEARCH_RESULTS: number = 200;
export const SSH_SESSION_LOG_SEARCH_WORK_BUDGET: number = 256;
export const SSH_SESSION_LOG_MAX_EXPORT_BYTES: number = 2 * 1024 * 1024;

const MAX_HOST_ID: number = 96;
const MAX_RECORD_ID: number = 160;
const MAX_CHUNK_ID: number = 160;
const MAX_TEXT: number = 8192;
const MAX_NOTE: number = 512;
const DAY_MS: number = 24 * 60 * 60 * 1000;
const STREAM_REDACTION_MARKERS: Array<string> = [
  'password', 'passphrase', 'token', 'secret',
  'private_key', 'private-key', 'private key', 'sshpass -p'
];

/** Opt-in storage settings cannot bypass the independent rollout gate. */
export function resolveSshSessionLogsEnabled(
  workbenchEnabled: boolean, sessionLogsFlagEnabled: boolean): boolean {
  return workbenchEnabled === true && sessionLogsFlagEnabled === true;
}

/** Revalidate host/page ownership after every system UI await during export. */
export function matchesSshSessionLogExportFence(expectedHostId: string,
  expectedPageGeneration: number, expectedBindingGeneration: number,
  currentHostId: string, currentPageGeneration: number, currentBindingGeneration: number,
  exportEnabled: boolean): boolean {
  const normalizedExpected: string = expectedHostId.trim();
  return exportEnabled === true && normalizedExpected.length > 0 &&
    normalizedExpected === currentHostId.trim() && expectedPageGeneration > 0 &&
    expectedPageGeneration === currentPageGeneration && expectedBindingGeneration > 0 &&
    expectedBindingGeneration === currentBindingGeneration;
}

/** A started but non-durable export may contain a plaintext prefix. */
export function shouldScrubFailedSshSessionLogExport(
  targetOpened: boolean, durable: boolean): boolean {
  return targetOpened === true && durable !== true;
}

function stringValue(value: Object, max: number): string {
  return typeof value === 'string' ? (value as string).slice(0, max) : '';
}

function finiteNumber(value: Object, fallback: number = 0): number {
  return typeof value === 'number' && Number.isFinite(value as number)
    ? Math.floor(value as number) : fallback;
}

function positive(value: Object): number {
  const number: number = finiteNumber(value, 0);
  return number > 0 ? number : 0;
}

function normalizeHostId(value: Object): string {
  return stringValue(value, MAX_HOST_ID).trim();
}

function identityValid(identity: SshSessionLogIdentityV1): boolean {
  return normalizeHostId(identity.hostId).length > 0 && identity.sessionId > 0 &&
    identity.generation > 0;
}

function sameIdentityValues(leftHostId: string, leftSessionId: number, leftGeneration: number,
  rightHostId: string, rightSessionId: number, rightGeneration: number): boolean {
  return leftHostId === rightHostId && leftSessionId === rightSessionId &&
    leftGeneration === rightGeneration;
}

/** Stable key used only for short-lived per-session capture state. */
export function sshSessionLogRuntimeKey(identity: SshSessionLogIdentityV1): string {
  return identity.hostId.trim() + ':' + identity.sessionId.toString() + ':' +
    identity.generation.toString();
}

/** Match only one host's runtime keys, optionally retaining the live session. */
export function shouldClearSshSessionLogRuntimeKey(key: string, hostId: string,
  keepKey: string = ''): boolean {
  const normalizedHostId: string = hostId.trim();
  return normalizedHostId.length > 0 && key !== keepKey &&
    (key === normalizedHostId || key.startsWith(normalizedHostId + ':'));
}

function clampQuota(value: Object): number {
  const candidate: number = finiteNumber(value, SSH_SESSION_LOG_DEFAULT_QUOTA_BYTES);
  return Math.max(SSH_SESSION_LOG_MIN_QUOTA_BYTES,
    Math.min(SSH_SESSION_LOG_MAX_QUOTA_BYTES, candidate));
}

function clampRetention(value: Object): number {
  const candidate: number = finiteNumber(value, SSH_SESSION_LOG_DEFAULT_RETENTION_DAYS);
  return Math.max(1, Math.min(SSH_SESSION_LOG_MAX_RETENTION_DAYS, candidate));
}

export function defaultSshSessionLogSettings(): SshSessionLogSettingsV1 {
  return {
    // Opt-in: an installed app never records a byte by default.
    enabled: false,
    paused: false,
    redactSensitive: true,
    retentionDays: SSH_SESSION_LOG_DEFAULT_RETENTION_DAYS,
    quotaBytes: SSH_SESSION_LOG_DEFAULT_QUOTA_BYTES
  };
}

export function emptySshSessionLogDocument(): SshSessionLogDocumentV1 {
  return {
    schemaVersion: SSH_SESSION_LOG_SCHEMA_VERSION,
    chunks: [],
    bookmarks: [],
    settings: defaultSshSessionLogSettings()
  };
}

export function normalizeSshSessionLogSettings(
  source: SshSessionLogSettingsV1
): SshSessionLogSettingsV1 {
  return {
    enabled: source.enabled === true,
    paused: source.paused === true,
    redactSensitive: source.redactSensitive !== false,
    retentionDays: clampRetention(source.retentionDays),
    quotaBytes: clampQuota(source.quotaBytes)
  };
}

function redactSshSessionLogText(value: string, redactSensitive: boolean): string {
  let text: string = value;
  // A record marked sensitive is never partially persisted. For ordinary
  // output, mask the common `password=...`/`token:...` accidental leak form.
  if (redactSensitive) {
    text = text.replace(/(password|passphrase|token|secret|private[_ -]?key)\s*[:=]\s*[^\s\r\n]+/gi,
      '$1=[redacted]');
    text = text.replace(/(sshpass\s+-p\s+)[^\s\r\n]+/gi, '$1[redacted]');
  }
  return text.slice(0, MAX_TEXT);
}

/**
 * Stateful VT sanitizer. OSC/DCS/SOS/PM/APC payloads may span native output
 * callbacks, so callers retain only this small mode value, never raw control
 * payload. `resync` is used after a sensitive/pause gap and drops the partial
 * line until CR/LF provides a safe visible-text boundary.
 */
export function sanitizeSshSessionLogChunk(value: string,
  initialMode: SshSessionLogSanitizeModeV1 = 'normal',
  redactSensitive: boolean = true): SshSessionLogSanitizeResultV1 {
  let mode: SshSessionLogSanitizeModeV1 = initialMode;
  let visible: string = '';
  for (let index: number = 0; index < value.length; index++) {
    const char: string = value.charAt(index);
    const code: number = value.charCodeAt(index);
    if (mode === 'resync') {
      if (char === '\r' || char === '\n') { mode = 'normal'; }
      continue;
    }
    if (mode === 'escape') {
      if (char === '[') { mode = 'csi'; continue; }
      if (char === ']') { mode = 'osc'; continue; }
      if (char === 'P' || char === 'X' || char === '^' || char === '_') {
        mode = 'string';
        continue;
      }
      if (code === 0x1b) { continue; }
      if (code >= 0x30 && code <= 0x7e) { mode = 'normal'; }
      continue;
    }
    if (mode === 'csi') {
      if (code === 0x1b) { mode = 'escape'; continue; }
      if (code >= 0x40 && code <= 0x7e) { mode = 'normal'; }
      continue;
    }
    if (mode === 'osc' || mode === 'string') {
      if ((mode === 'osc' && code === 0x07) || code === 0x9c) {
        mode = 'normal';
      } else if (code === 0x1b) {
        mode = mode === 'osc' ? 'osc_escape' : 'string_escape';
      }
      continue;
    }
    if (mode === 'osc_escape' || mode === 'string_escape') {
      if (char === '\\' || code === 0x9c) {
        mode = 'normal';
      } else if (code !== 0x1b) {
        mode = mode === 'osc_escape' ? 'osc' : 'string';
      }
      continue;
    }
    if (code === 0x1b) { mode = 'escape'; continue; }
    if (code === 0x9b) { mode = 'csi'; continue; }
    if (code === 0x9d) { mode = 'osc'; continue; }
    if (code === 0x90 || code === 0x98 || code === 0x9e || code === 0x9f) {
      mode = 'string';
      continue;
    }
    if ((code >= 0x00 && code <= 0x08) || code === 0x0b || code === 0x0c ||
      (code >= 0x0e && code <= 0x1f) || (code >= 0x7f && code <= 0x9f)) {
      continue;
    }
    if (visible.length < MAX_TEXT) { visible += char; }
  }
  return { text: redactSshSessionLogText(visible, redactSensitive), mode };
}

/** Strip VT/control payload before persistence/search for standalone values. */
export function sanitizeSshSessionLogText(value: string, redactSensitive: boolean = true): string {
  if (typeof value !== 'string' || value.length === 0) { return ''; }
  return sanitizeSshSessionLogChunk(value, 'normal', redactSensitive).text;
}

export function createSshSessionLogStreamSanitizeState(
  mode: SshSessionLogSanitizeModeV1 = 'normal'
): SshSessionLogStreamSanitizeStateV1 {
  return {
    mode,
    redactionPhase: 'normal',
    redactionCarry: '',
    redactionBoundary: true,
    markerKind: 'assignment'
  };
}

export function sshSessionLogStreamSanitizeStateIsDefault(
  state: SshSessionLogStreamSanitizeStateV1): boolean {
  return state.mode === 'normal' && state.redactionPhase === 'normal' &&
    state.redactionCarry.length === 0 && state.redactionBoundary;
}

function streamMarkerPrefix(candidate: string): boolean {
  const normalized: string = candidate.toLowerCase();
  for (let index: number = 0; index < STREAM_REDACTION_MARKERS.length; index++) {
    if (STREAM_REDACTION_MARKERS[index].startsWith(normalized)) { return true; }
  }
  return false;
}

function exactStreamMarker(candidate: string): string {
  const normalized: string = candidate.toLowerCase();
  for (let index: number = 0; index < STREAM_REDACTION_MARKERS.length; index++) {
    if (STREAM_REDACTION_MARKERS[index] === normalized) {
      return STREAM_REDACTION_MARKERS[index];
    }
  }
  return '';
}

function streamRedactionBoundary(char: string): boolean {
  if (char.length === 0) { return true; }
  const code: number = char.charCodeAt(0);
  return !((code >= 0x30 && code <= 0x39) || (code >= 0x41 && code <= 0x5a) ||
    code === 0x5f || (code >= 0x61 && code <= 0x7a));
}

/**
 * Redact assignment values before a timer can split them into separate
 * records. The only carried text is a possible marker prefix (at most the
 * longest marker); once a delimiter is seen, value characters are discarded.
 */
export function sanitizeSshSessionLogStreamChunk(value: string,
  initialState: SshSessionLogStreamSanitizeStateV1,
  redactSensitive: boolean = true): SshSessionLogStreamSanitizeResultV1 {
  const stripped: SshSessionLogSanitizeResultV1 = sanitizeSshSessionLogChunk(
    value, initialState.mode, false);
  const state: SshSessionLogStreamSanitizeStateV1 = {
    mode: stripped.mode,
    redactionPhase: initialState.redactionPhase,
    redactionCarry: initialState.redactionCarry.slice(-16),
    redactionBoundary: initialState.redactionBoundary === true,
    markerKind: initialState.markerKind === 'sshpass' ? 'sshpass' : 'assignment'
  };
  if (!redactSensitive) {
    const plainState: SshSessionLogStreamSanitizeStateV1 =
      createSshSessionLogStreamSanitizeState(stripped.mode);
    return { text: stripped.text, state: plainState };
  }
  let output: string = '';
  for (let index: number = 0; index < stripped.text.length; index++) {
    const char: string = stripped.text.charAt(index);
    let handled: boolean = false;
    while (!handled) {
      if (state.redactionPhase === 'value') {
        if (/\s/.test(char)) {
          output += char;
          state.redactionPhase = 'normal';
          state.redactionBoundary = true;
        }
        handled = true;
        continue;
      }
      if (state.redactionPhase === 'value_pending') {
        if (char === ' ' || char === '\t') {
          output += char;
        } else if (char === '\r' || char === '\n') {
          output += char;
          state.redactionPhase = 'normal';
          state.redactionBoundary = true;
        } else {
          state.redactionPhase = 'value';
          state.redactionBoundary = false;
        }
        handled = true;
        continue;
      }
      if (state.redactionPhase === 'separator') {
        if (state.markerKind === 'sshpass') {
          if (char === ' ' || char === '\t') {
            output += char + '[redacted]';
            state.redactionPhase = 'value_pending';
            handled = true;
            continue;
          }
        } else if (char === ' ' || char === '\t') {
          output += char;
          handled = true;
          continue;
        } else if (char === ':' || char === '=') {
          output += '=[redacted]';
          state.redactionPhase = 'value_pending';
          handled = true;
          continue;
        }
        state.redactionPhase = 'normal';
        state.markerKind = 'assignment';
        // Re-evaluate this character with the non-boundary created by the
        // already emitted marker, so `passwordless` remains ordinary text.
        continue;
      }

      if (state.redactionCarry.length > 0) {
        const candidate: string = state.redactionCarry + char;
        const exact: string = exactStreamMarker(candidate);
        if (exact.length > 0) {
          output += candidate;
          state.redactionCarry = '';
          state.redactionPhase = 'separator';
          state.markerKind = exact === 'sshpass -p' ? 'sshpass' : 'assignment';
          state.redactionBoundary = false;
          handled = true;
        } else if (streamMarkerPrefix(candidate)) {
          state.redactionCarry = candidate;
          handled = true;
        } else {
          output += state.redactionCarry;
          state.redactionBoundary = streamRedactionBoundary(
            state.redactionCarry.charAt(state.redactionCarry.length - 1));
          state.redactionCarry = '';
        }
        continue;
      }
      if (state.redactionBoundary && streamMarkerPrefix(char)) {
        state.redactionCarry = char;
      } else {
        output += char;
        state.redactionBoundary = streamRedactionBoundary(char);
      }
      handled = true;
    }
  }
  return { text: output.slice(0, MAX_TEXT), state };
}

function searchableText(text: string): string {
  return text.replace(/\s+/g, ' ').trim().toLowerCase().slice(0, MAX_TEXT);
}

/** Count the bytes emitted by UTF-8 without relying on API 26-only globals. */
export function sshSessionLogUtf8ByteLength(value: string): number {
  let bytes: number = 0;
  for (let index: number = 0; index < value.length; index++) {
    const code: number = value.charCodeAt(index);
    if (code <= 0x7f) {
      bytes += 1;
    } else if (code <= 0x7ff) {
      bytes += 2;
    } else if (code >= 0xd800 && code <= 0xdbff && index + 1 < value.length) {
      const next: number = value.charCodeAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        bytes += 4;
        index++;
      } else {
        bytes += 3;
      }
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

export function sshSessionLogCaptureAllowed(context: SshSessionLogCaptureContextV1): boolean {
  return context.enabled && !context.paused && !context.passwordPrompt && !context.mfaPrompt &&
    !context.passphrasePrompt && !context.rawMode && !context.fullscreenMode &&
    !context.secretExpansion && identityValid(context);
}

/**
 * Terminal input is safe to persist only while trusted shell integration says
 * the user is editing a command. After the command-executed marker, any input
 * can be an interactive sudo/su/database password and must fail closed.
 */
export function sshSessionLogInputPhaseAllowed(phase: string): boolean {
  return phase === 'prompt' || phase === 'command';
}

export function normalizeSshSessionLogRecord(
  source: SshSessionLogRecordV1,
  redactSensitive: boolean = true
): SshSessionLogRecordV1 | null {
  const hostId: string = normalizeHostId(source.hostId);
  const id: string = stringValue(source.id, MAX_RECORD_ID).trim();
  const text: string = sanitizeSshSessionLogText(source.text, redactSensitive);
  if (hostId.length === 0 || id.length === 0 || !Number.isFinite(source.sessionId) ||
    !Number.isFinite(source.generation) || !Number.isFinite(source.timestamp) ||
    source.sessionId <= 0 || source.generation <= 0 || source.timestamp < 0 ||
    text.length === 0 ||
    (source.direction !== 'input' && source.direction !== 'output' &&
      source.direction !== 'event') ||
    (source.kind !== 'data' && source.kind !== 'command_started' &&
      source.kind !== 'command_finished' && source.kind !== 'state' &&
      source.kind !== 'bookmark')) {
    return null;
  }
  return {
    id,
    hostId,
    sessionId: Math.floor(source.sessionId),
    generation: Math.floor(source.generation),
    timestamp: Math.floor(source.timestamp),
    direction: source.direction,
    kind: source.kind,
    text,
    searchText: searchableText(text),
    byteSize: Math.max(1, sshSessionLogUtf8ByteLength(text))
  };
}

function cloneDocument(document: SshSessionLogDocumentV1): SshSessionLogDocumentV1 {
  return decodeSshSessionLogDocument(encodeSshSessionLogDocument(document)) ??
    emptySshSessionLogDocument();
}

function bookmarkForRecord(document: SshSessionLogDocumentV1, recordId: string):
  SshSessionLogBookmarkV1 | undefined {
  return document.bookmarks.find((bookmark: SshSessionLogBookmarkV1): boolean =>
    bookmark.recordId === recordId);
}

function chunkPinned(document: SshSessionLogDocumentV1, chunk: SshSessionLogChunkV1): boolean {
  for (let recordIndex: number = 0; recordIndex < chunk.records.length; recordIndex++) {
    const bookmark: SshSessionLogBookmarkV1 | undefined = bookmarkForRecord(
      document, chunk.records[recordIndex].id);
    if (bookmark?.pinned === true) { return true; }
  }
  return false;
}

function leastRecentlyUpdatedRemovableChunkIndex(document: SshSessionLogDocumentV1): number {
  let removable: number = -1;
  for (let index: number = 0; index < document.chunks.length; index++) {
    const candidate: SshSessionLogChunkV1 = document.chunks[index];
    if (chunkPinned(document, candidate)) { continue; }
    if (removable < 0) {
      removable = index;
      continue;
    }
    const current: SshSessionLogChunkV1 = document.chunks[removable];
    if (candidate.updatedAt < current.updatedAt ||
      (candidate.updatedAt === current.updatedAt && candidate.createdAt < current.createdAt)) {
      removable = index;
    }
  }
  return removable;
}

function totalBytes(document: SshSessionLogDocumentV1): number {
  return document.chunks.reduce((sum: number, chunk: SshSessionLogChunkV1): number =>
    sum + Math.max(0, chunk.byteSize), 0);
}

/**
 * Chunk rows are immutable commit candidates. Updating a logical tail chunk
 * gets a new id, so an index-write failure cannot expose the uncommitted row
 * through the previous index after process restart.
 */
function nextSshSessionLogChunkId(record: SshSessionLogRecordV1,
  recordCount: number, chunkOrdinal: number): string {
  const identitySuffix: string = record.id.slice(-72);
  return (identitySuffix + ':chunk:' + record.sessionId.toString(36) + ':' +
    record.generation.toString(36) + ':' + record.timestamp.toString(36) + ':' +
    Math.max(0, chunkOrdinal).toString(36) + ':' + Math.max(1, recordCount).toString(36) + ':' +
    record.hostId.slice(-48)).slice(0, MAX_CHUNK_ID);
}

/** Apply retention and quota without deleting a chunk that has a pinned bookmark. */
export function pruneSshSessionLogDocument(
  document: SshSessionLogDocumentV1,
  nowMs: number
): SshSessionLogDocumentV1 {
  const next: SshSessionLogDocumentV1 = cloneDocument(document);
  const cutoff: number = Math.max(0, nowMs - next.settings.retentionDays * DAY_MS);
  next.chunks = next.chunks.filter((chunk: SshSessionLogChunkV1): boolean =>
    chunk.updatedAt >= cutoff || chunkPinned(next, chunk));
  let bytes: number = totalBytes(next);
  while (bytes > next.settings.quotaBytes) {
    const removable: number = leastRecentlyUpdatedRemovableChunkIndex(next);
    if (removable < 0) { break; }
    bytes -= next.chunks[removable].byteSize;
    const removedId: string = next.chunks[removable].id;
    next.chunks.splice(removable, 1);
    // A pinned bookmark is allowed to keep a chunk; ordinary bookmarks that
    // lose their record are removed, never left as dangling UI links.
    next.bookmarks = next.bookmarks.filter((bookmark: SshSessionLogBookmarkV1): boolean => {
      return bookmark.recordId.length > 0 && next.chunks.some(
        (chunk: SshSessionLogChunkV1): boolean => chunk.id !== removedId && chunk.records.some(
          (record: SshSessionLogRecordV1): boolean => record.id === bookmark.recordId));
    });
  }
  return next;
}

/**
 * Store-owned documents are already normalized. Preserve unchanged chunk and
 * record references on the append hot path while copying the arrays that
 * retention/quota pruning may replace or splice.
 */
function pruneSshSessionLogDocumentIncremental(
  document: SshSessionLogDocumentV1,
  nowMs: number
): SshSessionLogDocumentV1 {
  const next: SshSessionLogDocumentV1 = {
    schemaVersion: SSH_SESSION_LOG_SCHEMA_VERSION,
    chunks: document.chunks.slice(),
    bookmarks: document.bookmarks.slice(),
    settings: normalizeSshSessionLogSettings(document.settings)
  };
  const cutoff: number = Math.max(0, nowMs - next.settings.retentionDays * DAY_MS);
  next.chunks = next.chunks.filter((chunk: SshSessionLogChunkV1): boolean =>
    chunk.updatedAt >= cutoff || chunkPinned(next, chunk));
  let bytes: number = totalBytes(next);
  while (bytes > next.settings.quotaBytes) {
    const removable: number = leastRecentlyUpdatedRemovableChunkIndex(next);
    if (removable < 0) { break; }
    bytes -= next.chunks[removable].byteSize;
    const removedId: string = next.chunks[removable].id;
    next.chunks.splice(removable, 1);
    next.bookmarks = next.bookmarks.filter((bookmark: SshSessionLogBookmarkV1): boolean => {
      return bookmark.recordId.length > 0 && next.chunks.some(
        (chunk: SshSessionLogChunkV1): boolean => chunk.id !== removedId && chunk.records.some(
          (record: SshSessionLogRecordV1): boolean => record.id === bookmark.recordId));
    });
  }
  return next;
}

export function appendSshSessionLogRecord(
  document: SshSessionLogDocumentV1,
  source: SshSessionLogRecordV1,
  nowMs: number
): SshSessionLogDocumentV1 {
  const settings: SshSessionLogSettingsV1 = normalizeSshSessionLogSettings(document.settings);
  if (!settings.enabled || settings.paused) { return document; }
  const record: SshSessionLogRecordV1 | null = normalizeSshSessionLogRecord(
    source, settings.redactSensitive);
  if (record === null) { return document; }
  const next: SshSessionLogDocumentV1 = {
    schemaVersion: SSH_SESSION_LOG_SCHEMA_VERSION,
    chunks: document.chunks.slice(),
    bookmarks: document.bookmarks.slice(),
    settings
  };
  const previousTail: SshSessionLogChunkV1 | undefined =
    next.chunks[next.chunks.length - 1];
  let chunk: SshSessionLogChunkV1;
  if (previousTail === undefined || !sameIdentityValues(
    previousTail.hostId, previousTail.sessionId, previousTail.generation,
    record.hostId, record.sessionId, record.generation) ||
    previousTail.byteSize + record.byteSize > SSH_SESSION_LOG_CHUNK_MAX_BYTES ||
    previousTail.records.length >= SSH_SESSION_LOG_CHUNK_MAX_RECORDS) {
    chunk = {
      id: nextSshSessionLogChunkId(record, 1, next.chunks.length),
      hostId: record.hostId,
      sessionId: record.sessionId,
      generation: record.generation,
      createdAt: record.timestamp,
      updatedAt: record.timestamp,
      byteSize: 0,
      records: []
    };
    next.chunks.push(chunk);
  } else {
    chunk = {
      id: nextSshSessionLogChunkId(
        record, previousTail.records.length + 1, Math.max(0, next.chunks.length - 1)),
      hostId: previousTail.hostId,
      sessionId: previousTail.sessionId,
      generation: previousTail.generation,
      createdAt: previousTail.createdAt,
      updatedAt: record.timestamp,
      byteSize: previousTail.byteSize,
      records: previousTail.records.slice()
    };
    next.chunks[next.chunks.length - 1] = chunk;
  }
  chunk.records.push(record);
  chunk.byteSize += record.byteSize;
  chunk.updatedAt = record.timestamp;
  return pruneSshSessionLogDocumentIncremental(next, Math.max(nowMs, record.timestamp));
}

export function addSshSessionLogBookmark(
  document: SshSessionLogDocumentV1,
  identity: SshSessionLogIdentityV1,
  recordId: string,
  note: string,
  pinned: boolean,
  nowMs: number
): SshSessionLogDocumentV1 | null {
  const next: SshSessionLogDocumentV1 = cloneDocument(document);
  const normalizedRecordId: string = stringValue(recordId, MAX_RECORD_ID).trim();
  const recordExists: boolean = next.chunks.some((chunk: SshSessionLogChunkV1): boolean =>
    sameIdentityValues(chunk.hostId, chunk.sessionId, chunk.generation,
      identity.hostId, identity.sessionId, identity.generation) && chunk.records.some(
      (record: SshSessionLogRecordV1): boolean => record.id === normalizedRecordId));
  if (!identityValid(identity) || normalizedRecordId.length === 0 || !recordExists) { return null; }
  const existing: SshSessionLogBookmarkV1 | undefined = bookmarkForRecord(next, normalizedRecordId);
  if (existing !== undefined) {
    existing.note = stringValue(note, MAX_NOTE).trim();
    existing.pinned = pinned === true;
    return next;
  }
  if (next.bookmarks.length >= SSH_SESSION_LOG_MAX_BOOKMARKS) { return null; }
  next.bookmarks.push({
    id: normalizedRecordId + ':' + Math.max(0, Math.floor(nowMs)).toString(36),
    recordId: normalizedRecordId,
    hostId: normalizeHostId(identity.hostId),
    sessionId: Math.floor(identity.sessionId),
    generation: Math.floor(identity.generation),
    createdAt: Math.max(0, Math.floor(nowMs)),
    note: stringValue(note, MAX_NOTE).trim(),
    pinned: pinned === true
  });
  return next;
}

export function removeSshSessionLogBookmark(
  document: SshSessionLogDocumentV1,
  bookmarkId: string
): SshSessionLogDocumentV1 {
  const next: SshSessionLogDocumentV1 = cloneDocument(document);
  const normalized: string = stringValue(bookmarkId, MAX_RECORD_ID).trim();
  next.bookmarks = next.bookmarks.filter((bookmark: SshSessionLogBookmarkV1): boolean =>
    bookmark.id !== normalized);
  return next;
}

export function searchSshSessionLog(
  document: SshSessionLogDocumentV1,
  query: string,
  hostId: string = '',
  identity?: SshSessionLogIdentityV1
): Array<SshSessionLogSearchHitV1> {
  let cursor: SshSessionLogSearchCursorV1 = createSshSessionLogSearchCursor(
    document, query, hostId, identity);
  while (!cursor.done) {
    cursor = continueSshSessionLogSearch(document, cursor, 4096);
  }
  return cursor.results;
}

export function createSshSessionLogSearchCursor(document: SshSessionLogDocumentV1,
  query: string, hostId: string = '', identity?: SshSessionLogIdentityV1):
  SshSessionLogSearchCursorV1 {
  const identityHostId: string = identity === undefined ? '' : normalizeHostId(identity.hostId);
  const identitySessionId: number = identity === undefined ? 0 : Math.floor(identity.sessionId);
  const identityGeneration: number = identity === undefined ? 0 : Math.floor(identity.generation);
  return {
    token: stringValue(query, 256).trim().toLowerCase(),
    hostId: normalizeHostId(hostId),
    identityEnabled: identity !== undefined,
    identityHostId,
    identitySessionId,
    identityGeneration,
    chunkIndex: document.chunks.length - 1,
    recordIndex: -1,
    results: [],
    done: document.chunks.length === 0
  };
}

/** Scan a bounded amount of work so callers can yield between large-log slices. */
export function continueSshSessionLogSearch(document: SshSessionLogDocumentV1,
  cursor: SshSessionLogSearchCursorV1,
  workBudget: number = SSH_SESSION_LOG_SEARCH_WORK_BUDGET):
  SshSessionLogSearchCursorV1 {
  if (cursor.done) { return cursor; }
  const next: SshSessionLogSearchCursorV1 = {
    token: cursor.token,
    hostId: cursor.hostId,
    identityEnabled: cursor.identityEnabled,
    identityHostId: cursor.identityHostId,
    identitySessionId: cursor.identitySessionId,
    identityGeneration: cursor.identityGeneration,
    chunkIndex: cursor.chunkIndex,
    recordIndex: cursor.recordIndex,
    results: cursor.results.slice(),
    done: cursor.done
  };
  const normalizedBudget: number = Number.isFinite(workBudget) ? Math.floor(workBudget) : 256;
  const budget: number = Math.max(1, Math.min(4096, normalizedBudget));
  let work: number = 0;
  while (next.chunkIndex >= 0 &&
    next.results.length < SSH_SESSION_LOG_MAX_SEARCH_RESULTS && work < budget) {
    const chunk: SshSessionLogChunkV1 | undefined = document.chunks[next.chunkIndex];
    if (chunk === undefined) {
      next.chunkIndex--;
      next.recordIndex = -1;
      work++;
      continue;
    }
    if (next.recordIndex < 0) {
      next.recordIndex = chunk.records.length - 1;
      work++;
    }
    const hostRejected: boolean = next.hostId.length > 0 && chunk.hostId !== next.hostId;
    const identityRejected: boolean = next.identityEnabled && !sameIdentityValues(
      chunk.hostId, chunk.sessionId, chunk.generation, next.identityHostId,
      next.identitySessionId, next.identityGeneration);
    if (hostRejected || identityRejected || next.recordIndex < 0) {
      next.chunkIndex--;
      next.recordIndex = -1;
      continue;
    }
    while (next.recordIndex >= 0 &&
      next.results.length < SSH_SESSION_LOG_MAX_SEARCH_RESULTS && work < budget) {
      const record: SshSessionLogRecordV1 = chunk.records[next.recordIndex];
      next.recordIndex--;
      work++;
      if (next.token.length > 0 && record.searchText.indexOf(next.token) < 0) { continue; }
      const bookmark: SshSessionLogBookmarkV1 | undefined =
        bookmarkForRecord(document, record.id);
      next.results.push({
        record,
        bookmarked: bookmark !== undefined,
        bookmarkId: bookmark === undefined ? '' : bookmark.id
      });
    }
    if (next.recordIndex < 0) {
      next.chunkIndex--;
      next.recordIndex = -1;
    }
  }
  next.done = next.chunkIndex < 0 ||
    next.results.length >= SSH_SESSION_LOG_MAX_SEARCH_RESULTS;
  return next;
}

export function exportSshSessionLog(
  document: SshSessionLogDocumentV1,
  hostId: string,
  identity?: SshSessionLogIdentityV1,
  redact: boolean = true
): SshSessionLogExportResultV1 {
  const host: string = normalizeHostId(hostId);
  if (host.length === 0) {
    return { ok: false, text: '', recordCount: 0, redactedCount: 0, truncated: false };
  }
  let output: string = '';
  let count: number = 0;
  let redactedCount: number = 0;
  let truncated: boolean = false;
  let outputBytes: number = 0;
  for (let chunkIndex: number = 0; chunkIndex < document.chunks.length; chunkIndex++) {
    const chunk: SshSessionLogChunkV1 = document.chunks[chunkIndex];
    if (chunk.hostId !== host || (identity !== undefined && !sameIdentityValues(
      chunk.hostId, chunk.sessionId, chunk.generation, identity.hostId,
      identity.sessionId, identity.generation))) {
      continue;
    }
    for (let recordIndex: number = 0; recordIndex < chunk.records.length; recordIndex++) {
      const record: SshSessionLogRecordV1 = chunk.records[recordIndex];
      const text: string = sanitizeSshSessionLogText(record.text, redact);
      if (text.length === 0) { redactedCount++; continue; }
      const line: string = new Date(record.timestamp).toISOString() + ' [' + record.direction + '] ' +
        text + '\n';
      const lineBytes: number = sshSessionLogUtf8ByteLength(line);
      if (outputBytes + lineBytes > SSH_SESSION_LOG_MAX_EXPORT_BYTES) {
        truncated = true;
        break;
      }
      output += line;
      outputBytes += lineBytes;
      count++;
    }
    if (truncated) { break; }
  }
  return { ok: true, text: output, recordCount: count, redactedCount, truncated };
}

export function encodeSshSessionLogDocument(document: SshSessionLogDocumentV1): string {
  const normalized: SshSessionLogDocumentV1 = emptySshSessionLogDocument();
  normalized.settings = normalizeSshSessionLogSettings(document.settings);
  for (let chunkIndex: number = 0; chunkIndex < document.chunks.length; chunkIndex++) {
    const source: SshSessionLogChunkV1 = document.chunks[chunkIndex];
    const records: Array<SshSessionLogRecordV1> = [];
    for (let recordIndex: number = 0; recordIndex < source.records.length; recordIndex++) {
      const record: SshSessionLogRecordV1 | null = normalizeSshSessionLogRecord(
        source.records[recordIndex], normalized.settings.redactSensitive);
      if (record !== null && records.length < SSH_SESSION_LOG_CHUNK_MAX_RECORDS) {
        records.push(record);
      }
    }
    if (records.length === 0) { continue; }
    const first: SshSessionLogRecordV1 = records[0];
    const last: SshSessionLogRecordV1 = records[records.length - 1];
    normalized.chunks.push({
      id: stringValue(source.id, MAX_CHUNK_ID).trim(),
      hostId: first.hostId,
      sessionId: first.sessionId,
      generation: first.generation,
      createdAt: Math.max(0, finiteNumber(source.createdAt, first.timestamp)),
      updatedAt: Math.max(0, finiteNumber(source.updatedAt, last.timestamp)),
      byteSize: records.reduce((sum: number, item: SshSessionLogRecordV1): number =>
        sum + item.byteSize, 0),
      records
    });
  }
  for (let index: number = 0; index < document.bookmarks.length &&
    normalized.bookmarks.length < SSH_SESSION_LOG_MAX_BOOKMARKS; index++) {
    const source: SshSessionLogBookmarkV1 = document.bookmarks[index];
    const recordExists: boolean = normalized.chunks.some((chunk: SshSessionLogChunkV1): boolean =>
      chunk.records.some((record: SshSessionLogRecordV1): boolean => record.id === source.recordId));
    if (!recordExists) { continue; }
    normalized.bookmarks.push({
      id: stringValue(source.id, MAX_RECORD_ID).trim(),
      recordId: stringValue(source.recordId, MAX_RECORD_ID).trim(),
      hostId: normalizeHostId(source.hostId),
      sessionId: positive(source.sessionId),
      generation: positive(source.generation),
      createdAt: Math.max(0, finiteNumber(source.createdAt)),
      note: stringValue(source.note, MAX_NOTE).trim(),
      pinned: source.pinned === true
    });
  }
  return JSON.stringify(normalized);
}

export function decodeSshSessionLogDocument(raw: string): SshSessionLogDocumentV1 | null {
  try {
    const source: Object = JSON.parse(raw) as Object;
    if (source === null || typeof source !== 'object') { return null; }
    const item = source as SshSessionLogDocumentV1;
    if (item.schemaVersion !== SSH_SESSION_LOG_SCHEMA_VERSION ||
      !Array.isArray(item.chunks) || !Array.isArray(item.bookmarks) ||
      item.settings === null || typeof item.settings !== 'object') { return null; }
    return JSON.parse(encodeSshSessionLogDocument(item)) as SshSessionLogDocumentV1;
  } catch (_err) {
    return null;
  }
}
