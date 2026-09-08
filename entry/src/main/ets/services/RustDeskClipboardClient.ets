import { RustDeskClipboardSnapshot, RustDeskClipboardEntry, RustDeskClipboardSource, RustDeskClipboardPublication, SessionTransferStatus } from '../types/rdpnapi';
import { ManagedTransferControl } from './ManagedTransferTaskService';
import { ManagedTransferOutcome } from './ManagedTransferTaskPolicy';

export interface RustDeskClipboardNative {
  configureSessionRustDeskFileClipboard(sid: number, generation: number, enabled: boolean): boolean;
  getSessionRustDeskFileClipboard(sid: number, generation: number): RustDeskClipboardSnapshot;
  getSessionRustDeskClipboardEntries(sid: number, generation: number, revision: number): RustDeskClipboardEntry[];
  publishSessionRustDeskClipboardFiles(sid: number, generation: number, sources: RustDeskClipboardSource[]): number;
  getSessionRustDeskClipboardPublication(sid: number, generation: number, id: number): RustDeskClipboardPublication;
  revokeSessionRustDeskClipboardPublication(sid: number, generation: number, id: number): boolean;
  receiveSessionRustDeskClipboardFile(sid: number, generation: number, revision: number, index: number, fd: number): number;
  getSessionFileTransfer(sid: number, generation: number, id: number): SessionTransferStatus;
  cancelSessionFileTransfer(sid: number, generation: number, id: number): boolean;
  releaseSessionFileTransfer(sid: number, generation: number, id: number): boolean;
}
export interface RustDeskClipboardOfferResult { publicationId: number; ready: boolean; drained: boolean; }
export interface RustDeskClipboardReceiveResult { outcome: ManagedTransferOutcome; drained: boolean; }

/** No filesystem ownership here: callers stage a private copy and retain its publication lease.
 * Native duplicates source/sink FDs before returning. All asynchronous observations stay bound
 * to the captured session generation and the exact publication/transfer ID.
 */
export class RustDeskClipboardClient {
  private native: RustDeskClipboardNative;
  private sid: number;
  private generation: number;
  private current: () => boolean;
  constructor(native: RustDeskClipboardNative, sid: number, generation: number, current: () => boolean) {
    this.native = native; this.sid = sid; this.generation = generation; this.current = current;
  }
  private alive(): boolean { try { return this.current(); } catch (_error) { return false; } }
  private async wait(): Promise<void> { await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 250); }); }
  configure(enabled: boolean): boolean {
    return this.alive() && this.native.configureSessionRustDeskFileClipboard(this.sid, this.generation, enabled);
  }
  snapshot(): RustDeskClipboardSnapshot {
    if (!this.alive()) { return { revision: 0, state: 0, capable: false, enabled: false, entryCount: 0, diagnosticCode: 0 }; }
    return this.native.getSessionRustDeskFileClipboard(this.sid, this.generation);
  }
  entries(revision: number): RustDeskClipboardEntry[] {
    if (!this.alive()) { return []; }
    const before: RustDeskClipboardSnapshot = this.snapshot();
    if (!before.capable || !before.enabled || before.state !== 3 || before.revision !== revision) { return []; }
    const entries: RustDeskClipboardEntry[] = this.native.getSessionRustDeskClipboardEntries(this.sid, this.generation, revision);
    const after: RustDeskClipboardSnapshot = this.snapshot();
    if (after.state !== 3 || after.revision !== revision || !after.enabled ||
      entries.length !== before.entryCount || entries.length === 0 || entries.length > 256) { return []; }
    let total: number = 0;
    const names: Map<string, boolean> = new Map<string, boolean>();
    const allPaths: Set<string> = new Set<string>();
    const pathSpellings: Map<string, string> = new Map<string, string>();
    for (let i: number = 0; i < entries.length; i++) {
      const entry: RustDeskClipboardEntry = entries[i];
      const parts: string[] = entry.name.split('/');
      if (entry.index !== i || !Number.isSafeInteger(entry.size) || entry.size < 0 ||
        !Number.isSafeInteger(entry.modifiedTime) || entry.modifiedTime < 0 ||
        (entry.isDirectory && entry.size !== 0) || entry.name.length > 259 || parts.length > 32 ||
        parts.some((part: string): boolean => part.length === 0 || part === '.' || part === '..' ||
          /[\\:*?"<>|\u0000-\u001f\u007f]/.test(part) || part.endsWith('.') || part.endsWith(' '))) { return []; }
      const key: string = entry.name.normalize('NFC').toLowerCase();
      if (names.has(key)) { return []; }
      names.set(key, entry.isDirectory); total += entry.size;
      for (let depth: number = 1; depth <= parts.length; depth++) {
        const spelling: string = parts.slice(0, depth).join('/');
        const pathKey: string = spelling.normalize('NFC').toLowerCase();
        const previous: string | undefined = pathSpellings.get(pathKey);
        // Artifact hierarchy and export retain the exact logical spelling. Reject aliases
        // before creating a directory so a later export cannot silently omit its children.
        if (previous !== undefined && previous !== spelling) { return []; }
        pathSpellings.set(pathKey, spelling);
        allPaths.add(pathKey);
      }
      if (allPaths.size > 1024) { return []; }
      if (total > 2 * 1024 * 1024 * 1024) { return []; }
    }
    for (const path of allPaths) {
      const parts: string[] = path.split('/');
      for (let depth: number = 1; depth < parts.length; depth++) {
        if (names.get(parts.slice(0, depth).join('/')) === false) { return []; }
      }
    }
    return entries;
  }
  async revoke(id: number): Promise<boolean> {
    if (id <= 0) { return true; }
    // Revocation is allowed after UI ownership changes, but only for this captured identity.
    this.native.revokeSessionRustDeskClipboardPublication(this.sid, this.generation, id);
    const deadline: number = Date.now() + 5000;
    while (Date.now() < deadline) {
      const status: RustDeskClipboardPublication = this.native.getSessionRustDeskClipboardPublication(this.sid, this.generation, id);
      if (status.publicationId !== id || status.state === 0) { return false; }
      if (status.drained && (status.state === 5 || status.state === 6)) { return true; }
      await this.wait();
    }
    return false;
  }
  async publish(sources: RustDeskClipboardSource[]): Promise<RustDeskClipboardOfferResult> {
    const failed: RustDeskClipboardOfferResult = { publicationId: 0, ready: false, drained: true };
    if (!this.alive()) { return failed; }
    const snapshot: RustDeskClipboardSnapshot = this.snapshot();
    if (!snapshot.enabled || !snapshot.capable) { return failed; }
    const id: number = this.native.publishSessionRustDeskClipboardFiles(this.sid, this.generation, sources);
    if (id <= 0) { return failed; }
    const deadline: number = Date.now() + 10000;
    while (this.alive() && Date.now() < deadline) {
      const status: RustDeskClipboardPublication = this.native.getSessionRustDeskClipboardPublication(this.sid, this.generation, id);
      if (status.publicationId !== id || status.state === 0 || status.state >= 4) { break; }
      if (status.state === 2 || status.state === 3) { return { publicationId: id, ready: true, drained: false }; }
      await this.wait();
    }
    return { publicationId: id, ready: false, drained: await this.revoke(id) };
  }
  private async drain(id: number): Promise<boolean> {
    this.native.cancelSessionFileTransfer(this.sid, this.generation, id);
    const deadline: number = Date.now() + 5000;
    while (Date.now() < deadline) {
      const status: SessionTransferStatus = this.native.getSessionFileTransfer(this.sid, this.generation, id);
      if (status.transferId !== id || status.rustdeskTransferState === 0) { return false; }
      if ([3, 4, 5, 6].indexOf(status.rustdeskTransferState) >= 0) { return true; }
      await this.wait();
    }
    return false;
  }
  async receive(revision: number, entry: RustDeskClipboardEntry, fd: number,
    control: ManagedTransferControl, writtenBefore: number): Promise<RustDeskClipboardReceiveResult> {
    let id: number = 0; let drained: boolean = true;
    try {
      if (!this.alive() || !control.isCurrent() || entry.isDirectory) {
        return { outcome: { stage: 'cancelled', evidence: 'none' }, drained };
      }
      id = this.native.receiveSessionRustDeskClipboardFile(this.sid, this.generation, revision, entry.index, fd);
      if (id <= 0) { return { outcome: { stage: 'failed', evidence: 'none', diagnosticCode: 'clipboard_receive_rejected' }, drained }; }
      drained = false;
      control.onCancel((): void => { this.native.cancelSessionFileTransfer(this.sid, this.generation, id); });
      while (this.alive() && control.isCurrent()) {
        const status: SessionTransferStatus = this.native.getSessionFileTransfer(this.sid, this.generation, id);
        if (status.transferId !== id || status.rustdeskTransferState === 0) { break; }
        if (status.transferredBytes > entry.size) { break; }
        control.update({ writtenBytes: writtenBefore + status.transferredBytes });
        if ([3, 4, 5, 6].indexOf(status.rustdeskTransferState) >= 0) {
          drained = true;
          const complete: boolean = status.rustdeskTransferState === 6 && status.transferredBytes === entry.size;
          return { outcome: { stage: complete ? 'completed' : 'failed', evidence: complete ? 'metadataVerified' : 'none',
            diagnosticCode: complete ? '' : 'clipboard_receive_incomplete' }, drained };
        }
        await this.wait();
      }
      drained = await this.drain(id);
      return { outcome: { stage: drained ? 'cancelled' : 'paused', evidence: 'none', diagnosticCode: 'clipboard_receive_retired' }, drained };
    } catch (_error) {
      if (id > 0 && !drained) { try { drained = await this.drain(id); } catch (_drainError) { drained = false; } }
      return { outcome: { stage: drained ? 'failed' : 'paused', evidence: 'none', diagnosticCode: 'clipboard_receive_failed' }, drained };
    } finally {
      if (id > 0 && drained) { this.native.releaseSessionFileTransfer(this.sid, this.generation, id); }
    }
  }
}
