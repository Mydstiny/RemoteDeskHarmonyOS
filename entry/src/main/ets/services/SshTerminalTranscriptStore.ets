/**
 * Keeps a bounded VT byte-equivalent transcript per SSH host.
 *
 * The native SSH session stays alive while a tab is hidden, but its WebView is
 * replaced by the router. Replaying the recent transcript prevents a quiet
 * shell from coming back as an empty page with only a cursor.
 */
import { sshUtf8ByteLength } from './ssh/web/SshWebMessagePortPolicy';

export const SSH_TERMINAL_TRANSCRIPT_MAX_BYTES: number = 2 * 1024 * 1024;

interface SshTerminalTranscriptChunk {
  value: string;
  bytes: number;
}

interface SshTerminalTranscriptSuffix {
  value: string;
  bytes: number;
}

/** Keep the newest complete UTF-8 scalars within the supplied byte budget. */
function sshTerminalTranscriptSuffix(value: string, maxBytes: number): SshTerminalTranscriptSuffix {
  let start: number = value.length;
  let bytes: number = 0;
  let index: number = value.length - 1;
  while (index >= 0) {
    const code: number = value.charCodeAt(index);
    let scalarStart: number = index;
    let scalarBytes: number = 3;
    if (code <= 0x7f) {
      scalarBytes = 1;
    } else if (code <= 0x7ff) {
      scalarBytes = 2;
    } else if (code >= 0xdc00 && code <= 0xdfff && index > 0) {
      const previous: number = value.charCodeAt(index - 1);
      if (previous >= 0xd800 && previous <= 0xdbff) {
        scalarStart = index - 1;
        scalarBytes = 4;
      }
    }
    if (bytes + scalarBytes > maxBytes) { break; }
    bytes += scalarBytes;
    start = scalarStart;
    index = scalarStart - 1;
  }
  return { value: value.slice(start), bytes };
}

export class SshTerminalTranscriptStore {
  private static instance: SshTerminalTranscriptStore;
  private chunks: Map<string, Array<SshTerminalTranscriptChunk>> =
    new Map<string, Array<SshTerminalTranscriptChunk>>();
  private sizes: Map<string, number> = new Map<string, number>();
  private readonly maxBytes: number;

  constructor(maxBytes: number = SSH_TERMINAL_TRANSCRIPT_MAX_BYTES) {
    this.maxBytes = Math.max(1, Math.floor(maxBytes));
  }

  static getInstance(): SshTerminalTranscriptStore {
    if (!SshTerminalTranscriptStore.instance) {
      SshTerminalTranscriptStore.instance = new SshTerminalTranscriptStore();
    }
    return SshTerminalTranscriptStore.instance;
  }

  append(hostId: string, value: string): void {
    const key: string = hostId.trim();
    if (key.length === 0 || value.length === 0) { return; }
    let hostChunks: Array<SshTerminalTranscriptChunk> | undefined = this.chunks.get(key);
    if (hostChunks === undefined) {
      hostChunks = [];
      this.chunks.set(key, hostChunks);
      this.sizes.set(key, 0);
    }
    const valueBytes: number = sshUtf8ByteLength(value);
    if (valueBytes > this.maxBytes) {
      const retained: SshTerminalTranscriptSuffix =
        sshTerminalTranscriptSuffix(value, this.maxBytes);
      const replacement: Array<SshTerminalTranscriptChunk> = retained.value.length > 0
        ? [{ value: retained.value, bytes: retained.bytes }] : [];
      this.chunks.set(key, replacement);
      this.sizes.set(key, retained.bytes);
      return;
    }
    hostChunks.push({ value, bytes: valueBytes });
    let size: number = (this.sizes.get(key) ?? 0) + valueBytes;
    while (size > this.maxBytes && hostChunks.length > 0) {
      const removed: SshTerminalTranscriptChunk | undefined = hostChunks.shift();
      if (removed !== undefined) { size -= removed.bytes; }
    }
    this.sizes.set(key, size);
  }

  snapshot(hostId: string): string {
    const hostChunks: Array<SshTerminalTranscriptChunk> | undefined =
      this.chunks.get(hostId.trim());
    if (hostChunks === undefined) { return ''; }
    const values: Array<string> = [];
    for (let index: number = 0; index < hostChunks.length; index++) {
      values.push(hostChunks[index].value);
    }
    return values.join('');
  }

  byteLength(hostId: string): number {
    return this.sizes.get(hostId.trim()) ?? 0;
  }

  clear(hostId: string): void {
    const key: string = hostId.trim();
    if (key.length === 0) { return; }
    this.chunks.delete(key);
    this.sizes.delete(key);
  }

  clearAll(): void {
    this.chunks.clear();
    this.sizes.clear();
  }
}
