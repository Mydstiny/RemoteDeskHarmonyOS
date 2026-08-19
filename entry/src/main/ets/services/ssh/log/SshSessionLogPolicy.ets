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

export interface SshSessionLogExportResultV1 {
  ok: boolean;
  text: string;
  recordCount: number;
  redactedCount: number;
  truncated: boolean;
}

export const SSH_SESSION_LOG_SCHEMA_VERSION: number = 1;
export const SSH_SESSION_LOG_DEFAULT_QUOTA_BYTES: number = 10 * 1024 * 1024;
export const SSH_SESSION_LOG_MIN_QUOTA_BYTES: number = 256 * 1024;
export const SSH_SESSION_LOG_MAX_QUOTA_BYTES: number = 64 * 1024 * 1024;
export const SSH_SESSION_LOG_DEFAULT_RETENTION_DAYS: number = 30;
export const SSH_SESSION_LOG_MAX_RETENTION_DAYS: number = 365;
export const SSH_SESSION_LOG_CHUNK_MAX_BYTES: number = 64 * 1024;
export const SSH_SESSION_LOG_CHUNK_MAX_RECORDS: number = 128;
export const SSH_SESSION_LOG_MAX_BOOKMARKS: number = 500;
export const SSH_SESSION_LOG_MAX_SEARCH_RESULTS: number = 200;
export const SSH_SESSION_LOG_MAX_EXPORT_BYTES: number = 2 * 1024 * 1024;

const MAX_HOST_ID: number = 96;
const MAX_RECORD_ID: number = 160;
const MAX_CHUNK_ID: number = 160;
const MAX_TEXT: number = 8192;
const MAX_NOTE: number = 512;
const DAY_MS: number = 24 * 60 * 60 * 1000;

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

/** Strip OSC/CSI and non-printable control bytes before persistence/search. */
export function sanitizeSshSessionLogText(value: string, redactSensitive: boolean = true): string {
  let text: string = typeof value === 'string' ? value : '';
  if (text.length === 0) { return ''; }
  // OSC (including BEL and ST terminated variants) and CSI/SS3 sequences.
  text = text.replace(/\u001B\][^\u0007]*(?:\u0007|\u001B\\)/g, '');
  text = text.replace(/\u001B\[[0-?]*[ -\/]*[@-~]/g, '');
  text = text.replace(/\u001B[@-_]/g, '');
  // Incomplete fragments at a chunk boundary must not leave an ESC byte in
  // the durable/search representation.
  text = text.replace(/\u001B/g, '');
  text = text.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, '');
  // A record marked sensitive is never partially persisted. For ordinary
  // output, mask the common `password=...`/`token:...` accidental leak form.
  if (redactSensitive) {
    text = text.replace(/(password|passphrase|token|secret|private[_ -]?key)\s*[:=]\s*[^\s\r\n]+/gi,
      '$1=[redacted]');
    text = text.replace(/(sshpass\s+-p\s+)[^\s\r\n]+/gi, '$1[redacted]');
  }
  return text.slice(0, MAX_TEXT);
}

function searchableText(text: string): string {
  return text.replace(/\s+/g, ' ').trim().toLowerCase().slice(0, MAX_TEXT);
}

export function sshSessionLogCaptureAllowed(context: SshSessionLogCaptureContextV1): boolean {
  return context.enabled && !context.paused && !context.passwordPrompt && !context.mfaPrompt &&
    !context.passphrasePrompt && !context.rawMode && !context.fullscreenMode &&
    !context.secretExpansion && identityValid(context);
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
    byteSize: Math.max(1, text.length)
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
    if (bookmarkForRecord(document, chunk.records[recordIndex].id) !== undefined) { return true; }
  }
  return false;
}

function totalBytes(document: SshSessionLogDocumentV1): number {
  return document.chunks.reduce((sum: number, chunk: SshSessionLogChunkV1): number =>
    sum + Math.max(0, chunk.byteSize), 0);
}

/** Apply retention and quota without deleting a chunk that has a bookmark. */
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
    const removable: number = next.chunks.findIndex(
      (chunk: SshSessionLogChunkV1): boolean => !chunkPinned(next, chunk));
    if (removable < 0) { break; }
    bytes -= next.chunks[removable].byteSize;
    const removedId: string = next.chunks[removable].id;
    next.chunks.splice(removable, 1);
    // A bookmark is allowed to keep a chunk; bookmarks that lose their record
    // for another reason are removed, never left as dangling UI links.
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
  const next: SshSessionLogDocumentV1 = cloneDocument(document);
  if (!next.settings.enabled || next.settings.paused) { return next; }
  const record: SshSessionLogRecordV1 | null = normalizeSshSessionLogRecord(
    source, next.settings.redactSensitive);
  if (record === null) { return next; }
  let chunk: SshSessionLogChunkV1 | undefined = next.chunks[next.chunks.length - 1];
  if (chunk === undefined || !sameIdentityValues(chunk.hostId, chunk.sessionId, chunk.generation,
    record.hostId, record.sessionId, record.generation) ||
    chunk.byteSize + record.byteSize > SSH_SESSION_LOG_CHUNK_MAX_BYTES ||
    chunk.records.length >= SSH_SESSION_LOG_CHUNK_MAX_RECORDS) {
    const chunkId: string = record.hostId + ':' + record.sessionId.toString(36) + ':' +
      record.generation.toString(36) + ':' + record.timestamp.toString(36) + ':' +
      next.chunks.length.toString(36);
    chunk = {
      id: chunkId.slice(0, MAX_CHUNK_ID),
      hostId: record.hostId,
      sessionId: record.sessionId,
      generation: record.generation,
      createdAt: record.timestamp,
      updatedAt: record.timestamp,
      byteSize: 0,
      records: []
    };
    next.chunks.push(chunk);
  }
  chunk.records.push(record);
  chunk.byteSize += record.byteSize;
  chunk.updatedAt = record.timestamp;
  return pruneSshSessionLogDocument(next, Math.max(nowMs, record.timestamp));
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
  const token: string = stringValue(query, 256).trim().toLowerCase();
  const host: string = normalizeHostId(hostId);
  const results: Array<SshSessionLogSearchHitV1> = [];
  for (let chunkIndex: number = document.chunks.length - 1;
    chunkIndex >= 0 && results.length < SSH_SESSION_LOG_MAX_SEARCH_RESULTS; chunkIndex--) {
    const chunk: SshSessionLogChunkV1 = document.chunks[chunkIndex];
    if (host.length > 0 && chunk.hostId !== host) { continue; }
    if (identity !== undefined && !sameIdentityValues(chunk.hostId, chunk.sessionId,
      chunk.generation, identity.hostId, identity.sessionId, identity.generation)) { continue; }
    for (let recordIndex: number = chunk.records.length - 1;
      recordIndex >= 0 && results.length < SSH_SESSION_LOG_MAX_SEARCH_RESULTS; recordIndex--) {
      const record: SshSessionLogRecordV1 = chunk.records[recordIndex];
      if (token.length > 0 && record.searchText.indexOf(token) < 0) { continue; }
      const bookmark: SshSessionLogBookmarkV1 | undefined = bookmarkForRecord(document, record.id);
      results.push({ record, bookmarked: bookmark !== undefined,
        bookmarkId: bookmark === undefined ? '' : bookmark.id });
    }
  }
  return results;
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
      if (output.length + line.length > SSH_SESSION_LOG_MAX_EXPORT_BYTES) {
        truncated = true;
        break;
      }
      output += line;
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
