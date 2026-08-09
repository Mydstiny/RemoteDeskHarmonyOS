/**
 * Keeps a bounded VT byte-equivalent transcript per SSH host.
 *
 * The native SSH session stays alive while a tab is hidden, but its WebView is
 * replaced by the router. Replaying the recent transcript prevents a quiet
 * shell from coming back as an empty page with only a cursor.
 */
const MAX_TRANSCRIPT_CHARS: number = 2 * 1024 * 1024;

export class SshTerminalTranscriptStore {
  private static instance: SshTerminalTranscriptStore;
  private chunks: Map<string, Array<string>> = new Map<string, Array<string>>();
  private sizes: Map<string, number> = new Map<string, number>();

  static getInstance(): SshTerminalTranscriptStore {
    if (!SshTerminalTranscriptStore.instance) {
      SshTerminalTranscriptStore.instance = new SshTerminalTranscriptStore();
    }
    return SshTerminalTranscriptStore.instance;
  }

  append(hostId: string, value: string): void {
    const key: string = hostId.trim();
    if (key.length === 0 || value.length === 0) { return; }
    let hostChunks: Array<string> | undefined = this.chunks.get(key);
    if (hostChunks === undefined) {
      hostChunks = [];
      this.chunks.set(key, hostChunks);
      this.sizes.set(key, 0);
    }
    hostChunks.push(value);
    let size: number = (this.sizes.get(key) ?? 0) + value.length;
    while (size > MAX_TRANSCRIPT_CHARS && hostChunks.length > 1) {
      const removed: string | undefined = hostChunks.shift();
      if (removed !== undefined) { size -= removed.length; }
    }
    this.sizes.set(key, size);
  }

  snapshot(hostId: string): string {
    const hostChunks: Array<string> | undefined = this.chunks.get(hostId.trim());
    return hostChunks === undefined ? '' : hostChunks.join('');
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
