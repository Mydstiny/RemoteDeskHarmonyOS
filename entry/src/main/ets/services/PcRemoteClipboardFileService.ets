import { ExtensionLoader } from './ExtensionLoader';
import { common } from '@kit.AbilityKit';
import { deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { fileUri } from '@kit.CoreFileKit';
import { ClipboardLease, RemoteClipboardSnapshot } from './ClipboardCoordinator';
import { ManagedTransferTaskService, ManagedTransferControl } from './ManagedTransferTaskService';
import { ManagedTransferOutcome, ManagedTransferProgress } from './ManagedTransferTaskPolicy';
import { TransferArtifact, TransferArtifactBatch, TransferNativeReceiveDirectory, TransferNativeReceivedEntry,
  TransferReceivedArtifactWriter, transferScopeKey, TRANSFER_FILE_LIMIT_BYTES } from './TransferArtifactStore';
import { TransferArtifactPublicationService } from './TransferArtifactPublicationService';
import { RustDeskClipboardClient, RustDeskClipboardReceiveResult } from './RustDeskClipboardClient';
import { SessionRdpClipboardFiles, SessionRdpClipboardFileEntry, SessionRdpClipboardReceive,
  SessionRdpClipboardArtifact, RustDeskClipboardEntry } from '../types/rdpnapi';

class PcRdpReceiveSlot { value: TransferNativeReceiveDirectory | null = null; }
export type PcRemoteClipboardFilePhase = 'idle' | 'preparing' | 'receiving' | 'verifying' | 'publishing' |
  'ready' | 'cached' | 'cancelled' | 'failed';
export type PcRemoteClipboardFileError = 'none' | 'unavailable' | 'invalid_offer' | 'source_changed' |
  'receive_failed' | 'directory_requires_export' | 'publication_failed';
export interface PcRemoteClipboardFileStatus {
  phase: PcRemoteClipboardFilePhase;
  writtenBytes: number;
  totalBytes: number;
  error: PcRemoteClipboardFileError;
}

/** Eager, bounded preparation of real files. No remote path inference or synchronous network provider.
 * A failed publication before any OS write keeps a completed private batch for bounded retries; an incomplete native
 * receive is never treated as delivered and is never reused as a new source sequence.
 * The caller's guard must accept its own remoteTag write while retaining source/epoch/count fencing.
 */
export class PcRemoteClipboardFileService {
  private loader: ExtensionLoader;
  private lease: ClipboardLease;
  private context: common.UIAbilityContext;
  private epoch: number = 0;
  private disposed: boolean = false;
  private deliveredSequence: number = 0;
  // Native receive failures are terminal for that source snapshot. A later
  // sequence is required; only a retained completed batch can retry locally.
  private attemptedSequence: number = 0;
  private processingSequence: number = 0;
  private retrySequence: number = 0;
  private retryBatch: TransferArtifactBatch | null = null;
  private publicationWriteAttempted: boolean = false;
  private publicationRetries: number = 0;
  private publicationRetryAt: number = 0;
  private listener: ((status: PcRemoteClipboardFileStatus) => void) | null = null;
  private authorityWriter: ((operation: () => boolean) => boolean) | null = null;
  private status: PcRemoteClipboardFileStatus = { phase: 'idle', writtenBytes: 0, totalBytes: 0, error: 'none' };
  constructor(loader: ExtensionLoader, lease: ClipboardLease, context: common.UIAbilityContext) {
    this.loader = loader; this.context = context;
    this.lease = { accountScopeId: lease.accountScopeId, accountGeneration: lease.accountGeneration,
      windowId: lease.windowId, hostId: lease.hostId, protocol: lease.protocol, routeIdentity: lease.routeIdentity,
      sessionId: lease.sessionId, attemptId: lease.attemptId, nativeGeneration: lease.nativeGeneration };
  }
  setStatusListener(listener: ((status: PcRemoteClipboardFileStatus) => void) | null): void {
    this.listener = listener;
    try { listener?.(this.getStatus()); } catch (_error) { /* UI observer isolation. */ }
  }
  setAuthorityWriter(writer: (operation: () => boolean) => boolean): void { this.authorityWriter = writer; }
  getStatus(): PcRemoteClipboardFileStatus {
    return { phase: this.status.phase, writtenBytes: this.status.writtenBytes,
      totalBytes: this.status.totalBytes, error: this.status.error };
  }
  dispose(): void {
    this.disposed = true; this.epoch++; this.listener = null;
    this.clearRetryBatch();
  }
  private clearRetryBatch(): void {
    const batch: TransferArtifactBatch | null = this.retryBatch;
    this.retryBatch = null; this.retrySequence = 0;
    if (batch !== null) { try { batch.release('publish-retry'); } catch (_error) {} }
  }
  private retainRetryBatch(batch: TransferArtifactBatch): boolean {
    try { batch.retain('publish-retry'); return true; } catch (_error) { return false; }
  }
  private report(epoch: number, phase: PcRemoteClipboardFilePhase, written: number = 0,
    total: number = 0, error: PcRemoteClipboardFileError = 'none'): void {
    if (epoch !== this.epoch || this.disposed) { return; }
    this.status = { phase, writtenBytes: Number.isSafeInteger(written) && written >= 0 ? written : 0,
      totalBytes: Number.isSafeInteger(total) && total >= 0 ? total : 0, error };
    try { this.listener?.(this.getStatus()); } catch (_error) { /* UI observer isolation. */ }
  }
  private current(epoch: number, sequence: number, guard: () => boolean): boolean {
    try {
      if (this.disposed || this.epoch !== epoch || !guard()) { return false; }
      const now = this.loader.getSessionClipboardSnapshot(this.lease.sessionId);
      return now.sequence === sequence && now.kind === 'files';
    } catch (_error) { return false; }
  }
  private async wait(): Promise<void> {
    await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 250); });
  }
  private validRdpOffer(offer: SessionRdpClipboardFiles, sequence: number): boolean {
    if (offer.sequence !== sequence || offer.state !== 'ready' || !offer.streamSupported ||
      offer.entries.length === 0 || offer.entries.length > 1024 || !Number.isSafeInteger(offer.totalBytes) ||
      offer.totalBytes < 0 || offer.totalBytes > TRANSFER_FILE_LIMIT_BYTES) { return false; }
    const explicit: Map<string, boolean> = new Map<string, boolean>();
    const spellings: Map<string, string> = new Map<string, string>();
    let total: number = 0;
    for (let i: number = 0; i < offer.entries.length; i++) {
      const entry: SessionRdpClipboardFileEntry = offer.entries[i];
      const parts: string[] = entry.relativeName.split('/');
      if (entry.index !== i || entry.relativeName.length > 1024 || parts.length > 32 ||
        !Number.isSafeInteger(entry.size) || entry.size < 0 || (entry.directory && entry.size !== 0) ||
        (offer.totalKnown && !entry.directory && !entry.sizeKnown) ||
        parts.some((part: string): boolean => part.length === 0 || part === '.' || part === '..' ||
          /[\\:*?"<>|\u0000-\u001f\u007f]/.test(part) || part.endsWith('.') || part.endsWith(' '))) { return false; }
      const key: string = entry.relativeName.normalize('NFC').toLowerCase();
      if (explicit.has(key)) { return false; }
      explicit.set(key, entry.directory); total += entry.size;
      if (total > TRANSFER_FILE_LIMIT_BYTES) { return false; }
      for (let depth: number = 1; depth <= parts.length; depth++) {
        const path: string = parts.slice(0, depth).join('/');
        const prefix: string = path.normalize('NFC').toLowerCase();
        const previous: string | undefined = spellings.get(prefix);
        if (previous !== undefined && previous !== path) { return false; }
        spellings.set(prefix, path);
        if (spellings.size > 1024) { return false; }
      }
    }
    for (const path of spellings.keys()) {
      const parts: string[] = path.split('/');
      for (let depth: number = 1; depth < parts.length; depth++) {
        if (explicit.get(parts.slice(0, depth).join('/')) === false) { return false; }
      }
    }
    return !offer.totalKnown || total === offer.totalBytes;
  }
  private async rdpOffer(sequence: number, current: () => boolean): Promise<SessionRdpClipboardFiles | null> {
    if (!current()) { return null; }
    const sid: number = this.lease.sessionId; const generation: number = this.lease.nativeGeneration;
    let offer: SessionRdpClipboardFiles = this.loader.getSessionRdpClipboardFiles(sid, generation);
    if (this.validRdpOffer(offer, sequence) && current()) { return offer; }
    if (!current() || !this.loader.requestSessionRdpClipboardFiles(sid, generation, sequence)) { return null; }
    // Native descriptor acquisition expires after 15 seconds. Allow a final
    // polling interval rather than abandoning a still-valid native request.
    const deadline: number = Date.now() + 16000;
    while (current() && Date.now() < deadline) {
      offer = this.loader.getSessionRdpClipboardFiles(sid, generation);
      if (offer.sequence === sequence && offer.state === 'ready') { return this.validRdpOffer(offer, sequence) ? offer : null; }
      if (offer.sequence === sequence && offer.state === 'failed') { return null; }
      await this.wait();
    }
    return null;
  }
  private rdpCompleted(status: SessionRdpClipboardReceive, offer: SessionRdpClipboardFiles, id: number): boolean {
    if (status.taskId !== id || status.sequence !== offer.sequence || !status.totalKnown ||
      !Number.isSafeInteger(status.totalBytes) || status.totalBytes < 0 || status.totalBytes > TRANSFER_FILE_LIMIT_BYTES ||
      status.transferredBytes !== status.totalBytes || status.artifacts.length !== offer.entries.length) { return false; }
    let total: number = 0; const indices: Set<number> = new Set<number>();
    for (const artifact of status.artifacts) {
      const entry: SessionRdpClipboardFileEntry | undefined = offer.entries[artifact.index];
      if (entry === undefined || indices.has(artifact.index) || artifact.relativeName !==
        'receive-' + id.toString() + '/files/' + entry.relativeName || artifact.directory !== entry.directory ||
        !Number.isSafeInteger(artifact.size) || artifact.size < 0 ||
        ((entry.sizeKnown || entry.directory) && artifact.size !== entry.size)) { return false; }
      indices.add(artifact.index); total += artifact.size;
    }
    return total === status.totalBytes;
  }
  private async drainRdp(id: number): Promise<boolean> {
    const sid: number = this.lease.sessionId; const generation: number = this.lease.nativeGeneration;
    this.loader.cancelSessionRdpClipboardReceive(sid, generation, id);
    const deadline: number = Date.now() + 5000;
    while (Date.now() < deadline) {
      const status: SessionRdpClipboardReceive = this.loader.getSessionRdpClipboardReceive(sid, generation, id);
      if (status.taskId !== id || status.phase === 'unavailable') { return false; }
      if (['completed', 'failed', 'cancelled'].indexOf(status.phase) >= 0) { return true; }
      await this.wait();
    }
    return false;
  }
  private async receiveRdp(offer: SessionRdpClipboardFiles, batch: TransferArtifactBatch,
    control: ManagedTransferControl, current: () => boolean, epoch: number): Promise<ManagedTransferOutcome> {
    const slot: PcRdpReceiveSlot = new PcRdpReceiveSlot(); let id: number = 0;
    let drained: boolean = true; let committed: boolean = false;
    const alive = (): boolean => current() && control.isCurrent();
    const run = async (): Promise<ManagedTransferOutcome> => {
      slot.value = await batch.createNativeReceiveDirectory(alive, offer.totalKnown ? offer.totalBytes : TRANSFER_FILE_LIMIT_BYTES);
      if (!alive()) { return { stage: 'cancelled', evidence: 'none' }; }
      id = this.loader.startSessionRdpClipboardReceive(this.lease.sessionId, this.lease.nativeGeneration,
        offer.sequence, offer.entries.map((entry: SessionRdpClipboardFileEntry): number => entry.index), slot.value.fd);
      if (id <= 0) { return { stage: 'failed', evidence: 'none' }; }
      drained = false;
      control.onCancel((): void => { this.loader.cancelSessionRdpClipboardReceive(this.lease.sessionId, this.lease.nativeGeneration, id); });
      control.update({ stage: 'transferring' });
      while (alive()) {
        const status: SessionRdpClipboardReceive = this.loader.getSessionRdpClipboardReceive(this.lease.sessionId, this.lease.nativeGeneration, id);
        if (status.taskId !== id || status.sequence !== offer.sequence || status.phase === 'unavailable') { break; }
        if (!Number.isSafeInteger(status.transferredBytes) || status.transferredBytes < 0 ||
          status.transferredBytes > TRANSFER_FILE_LIMIT_BYTES) { break; }
        control.update({ writtenBytes: status.transferredBytes, totalBytes: status.totalKnown ? status.totalBytes : 0 });
        this.report(epoch, 'receiving', status.transferredBytes, status.totalKnown ? status.totalBytes : 0);
        if (['completed', 'failed', 'cancelled'].indexOf(status.phase) >= 0) {
          drained = true;
          if (status.phase !== 'completed' || !this.rdpCompleted(status, offer, id)) { return { stage: 'failed', evidence: 'none' }; }
          if (!alive()) { return { stage: 'cancelled', evidence: 'none' }; }
          this.report(epoch, 'verifying', status.transferredBytes, status.totalBytes);
          control.update({ stage: 'verifying' });
          if (!await control.enterCommit() || !alive()) { return { stage: 'cancelled', evidence: 'none' }; }
          await slot.value.commit(status.artifacts.map((entry: SessionRdpClipboardArtifact): TransferNativeReceivedEntry => {
            return { index: entry.index, relativeName: entry.relativeName, directory: entry.directory, size: entry.size };
          }));
          committed = true;
          return { stage: alive() ? 'completed' : 'cancelled', evidence: 'metadataVerified' };
        }
        await this.wait();
      }
      return { stage: 'cancelled', evidence: 'none' };
    };
    let outcome: ManagedTransferOutcome = { stage: 'failed', evidence: 'none' };
    try { outcome = await run(); } catch (_error) { /* Cleanup retains uncertain native writers. */ }
    finally {
      if (id > 0 && !drained) { try { drained = await this.drainRdp(id); } catch (_error) { drained = false; } }
      if (id > 0 && drained) { this.loader.releaseSessionRdpClipboardReceive(this.lease.sessionId, this.lease.nativeGeneration, id); }
      if (slot.value !== null && !committed) { if (drained) { await slot.value.abort(); } else { await slot.value.retainPartial(); } }
    }
    return drained ? outcome : { stage: 'paused', evidence: 'none', diagnosticCode: 'receive_retired' };
  }
  private async receiveRustDesk(client: RustDeskClipboardClient, sequence: number, entries: RustDeskClipboardEntry[],
    batch: TransferArtifactBatch, control: ManagedTransferControl, current: () => boolean, epoch: number): Promise<ManagedTransferOutcome> {
    const alive = (): boolean => current() && control.isCurrent();
    const directories: Set<string> = new Set<string>(); let written: number = 0;
    const total: number = entries.reduce((sum: number, entry: RustDeskClipboardEntry): number => sum + entry.size, 0);
    const observed: ManagedTransferControl = { taskId: control.taskId, attemptId: control.attemptId,
      isCurrent: alive, isCancellationRequested: control.isCancellationRequested, onCancel: control.onCancel,
      enterCommit: control.enterCommit, update: (progress: ManagedTransferProgress): boolean => {
        if (progress.writtenBytes !== undefined && alive()) { this.report(epoch, 'receiving', progress.writtenBytes, total); }
        return control.update(progress);
      } };
    try {
      control.update({ stage: 'transferring' });
      for (const entry of entries) {
        if (!alive()) { return { stage: 'cancelled', evidence: 'none' }; }
        const parts: string[] = entry.name.split('/');
        for (let depth: number = 1; depth <= parts.length - (entry.isDirectory ? 0 : 1); depth++) {
          const parent: string = parts.slice(0, depth).join('/');
          if (!directories.has(parent)) { await batch.createDirectory(parent, alive); directories.add(parent); }
          if (!alive()) { return { stage: 'cancelled', evidence: 'none' }; }
        }
        if (entry.isDirectory) { continue; }
        const slot: TransferReceivedArtifactWriter = await batch.beginNativeReceiveRelative(entry.name, entry.size, alive);
        let drained: boolean = true; let committed: boolean = false;
        try {
          const result: RustDeskClipboardReceiveResult = await client.receive(sequence, entry, slot.fd, observed, written);
          drained = result.drained;
          if (result.outcome.stage !== 'completed') { return result.outcome; }
          if (!alive() || !await control.enterCommit() || !alive()) { return { stage: 'cancelled', evidence: 'none' }; }
          this.report(epoch, 'verifying', written + entry.size, total);
          await slot.commit(entry.modifiedTime); committed = true; written += entry.size;
          if (!alive()) { return { stage: 'cancelled', evidence: 'none' }; }
          this.report(epoch, 'receiving', written, total);
        } finally { if (!committed) { if (drained) { await slot.abort(); } else { await slot.retainPartial(); } } }
      }
      return { stage: 'completed', evidence: 'metadataVerified' };
    } catch (_error) { return { stage: 'failed', evidence: 'none' }; }
  }
  private publish(batch: TransferArtifactBatch, current: () => boolean, tag: string, epoch: number): number {
    this.publicationWriteAttempted = false;
    const publications: TransferArtifactPublicationService = TransferArtifactPublicationService.getInstance();
    let publicationId: string = ''; let writeAttempted: boolean = false;
    try {
      if (!current() || this.authorityWriter === null) { return -1; }
      const artifacts: TransferArtifact[] = batch.getArtifacts();
      // URI directory semantics are not assumed. Preserve the complete hierarchy for cache export.
      if (artifacts.some((artifact: TransferArtifact): boolean => artifact.directory === true ||
        (artifact.relativePath ?? artifact.name).indexOf('/') >= 0)) {
        this.report(epoch, 'cached', this.status.writtenBytes, this.status.totalBytes, 'directory_requires_export'); return -1;
      }
      if (artifacts.length === 0 || artifacts.length > 1024) { return -1; }
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_URI, fileUri.getUriFromPath(artifacts[0].path));
      for (let i: number = 1; i < artifacts.length; i++) {
        data.addRecord(pasteboard.MIMETYPE_TEXT_URI, fileUri.getUriFromPath(artifacts[i].path));
      }
      if (data.getRecordCount() !== artifacts.length || !current()) { return -1; }
      publicationId = publications.registerSystemClipboard(batch, tag);
      const property: pasteboard.PasteDataProperty = data.getProperty(); property.tag = tag; data.setProperty(property);
      this.report(epoch, 'publishing', this.status.writtenBytes, this.status.totalBytes);
      if (!current()) { return -1; }
      let confirmedCount: number = -1;
      const written: boolean = this.authorityWriter((): boolean => {
        if (!current()) { return false; }
        const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
        writeAttempted = true; this.publicationWriteAttempted = true; board.setDataSync(data);
        const count: number = board.getChangeCount();
        const observed: pasteboard.PasteData = board.getDataSync();
        if (observed.getTag() !== tag || observed.getRecordCount() !== artifacts.length || board.getChangeCount() !== count ||
          !publications.confirmSystemClipboard(publicationId, tag, count) || !current()) { return false; }
        publications.observeSystemClipboard(tag, count);
        if (!current()) { return false; }
        confirmedCount = count; return true;
      });
      return written ? confirmedCount : -1;
    } catch (_error) { return -1; }
    finally {
      // A throwing write/read can still have published the URI: retain until an observed replacement.
      if (publicationId.length > 0 && !writeAttempted) { publications.releaseSystemClipboard(publicationId, true); }
    }
  }
  async receiveRemote(snapshot: RemoteClipboardSnapshot, guard: () => boolean, remoteTag: string): Promise<boolean> {
    if (this.disposed || deviceInfo.deviceType !== '2in1' || ['rdp', 'rustdesk'].indexOf(this.lease.protocol) < 0 ||
      remoteTag.length > 128 || !/^remotedesk:remote-text:v1:[a-zA-Z0-9_.:@-]+$/.test(remoteTag) ||
      snapshot.kind !== 'files' || !Number.isSafeInteger(snapshot.sequence) || snapshot.sequence <= this.deliveredSequence ||
      (snapshot.sequence <= this.attemptedSequence &&
        !(this.retryBatch !== null && this.retrySequence === snapshot.sequence))) { return false; }
    const sequence: number = snapshot.sequence;
    if (this.processingSequence === sequence) { return false; }
    if (this.retryBatch !== null && this.retrySequence !== sequence) { this.clearRetryBatch(); }
    const epoch: number = ++this.epoch;
    const current = (): boolean => this.current(epoch, sequence, guard);
    if (!current()) { return false; }
    // A completed receive whose publication failed is safe to retry locally. Do not
    // ask the peer for the bytes again, and never reuse this batch for another sequence.
    if (this.retryBatch !== null && this.retrySequence === sequence) {
      if (Date.now() < this.publicationRetryAt) { return false; }
      this.publicationRetries++;
      this.processingSequence = sequence;
      try {
        const publishedCount: number = this.publish(this.retryBatch, current, remoteTag, epoch);
        if (this.status.phase === 'cached') {
          // Directory trees stay in the private cache for explicit export. They are
          // intentionally not publication-retry candidates.
          this.clearRetryBatch(); return false;
        }
        if (publishedCount < 0 || !current()) {
          if (this.publicationWriteAttempted || this.publicationRetries >= 3 || !current()) {
            this.clearRetryBatch();
          } else { this.publicationRetryAt = Date.now() + 500 * Math.pow(2, this.publicationRetries); }
          this.report(epoch, 'failed', 0, 0, 'publication_failed'); return false;
        }
        const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
        if (board.getChangeCount() !== publishedCount || board.getDataSync().getTag() !== remoteTag || !current()) {
          this.clearRetryBatch();
          this.report(epoch, 'failed', 0, 0, 'publication_failed'); return false;
        }
        this.retryBatch.release('publish-retry'); this.retryBatch = null; this.retrySequence = 0;
        this.deliveredSequence = sequence;
        this.report(epoch, 'ready', this.status.writtenBytes, this.status.totalBytes); return true;
      } catch (_error) {
        this.clearRetryBatch();
        this.report(epoch, 'failed', 0, 0, 'publication_failed'); return false;
      } finally { if (this.processingSequence === sequence) { this.processingSequence = 0; } }
    }
    this.processingSequence = sequence;
    this.attemptedSequence = sequence;
    this.publicationRetries = 0;
    this.report(epoch, 'preparing');
    let batch: TransferArtifactBatch | null = null; let admitted: boolean = false; let publishedCount: number = -1;
    try {
      const rdp: boolean = this.lease.protocol === 'rdp';
      const client: RustDeskClipboardClient = new RustDeskClipboardClient(this.loader, this.lease.sessionId,
        this.lease.nativeGeneration, current);
      const offer: SessionRdpClipboardFiles | null = rdp ? await this.rdpOffer(sequence, current) : null;
      const entries: RustDeskClipboardEntry[] = rdp ? [] : client.entries(sequence);
      if (!current()) { this.report(epoch, 'cancelled', 0, 0, 'source_changed'); return false; }
      if ((rdp && offer === null) || (!rdp && entries.length === 0)) {
        this.report(epoch, 'failed', 0, 0, 'invalid_offer'); return false;
      }
      const total: number = offer !== null ? offer.totalKnown ? offer.totalBytes : 0 :
        entries.reduce((sum: number, entry: RustDeskClipboardEntry): number => sum + entry.size, 0);
      const service: ManagedTransferTaskService = ManagedTransferTaskService.getInstance();
      if (!service.init(this.context) || !current()) { this.report(epoch, 'failed', 0, total, 'unavailable'); return false; }
      const ownedBatch: TransferArtifactBatch = new TransferArtifactBatch(this.context.filesDir,
        transferScopeKey(this.lease.accountScopeId, this.lease.hostId + ':' + this.lease.routeIdentity), 'received');
      batch = ownedBatch;
      const handle = service.enqueue({ accountScopeId: this.lease.accountScopeId, hostId: this.lease.hostId,
        queueKey: this.lease.windowId + ':' + this.lease.sessionId.toString() + ':' + this.lease.nativeGeneration.toString(),
        leaseId: this.lease.nativeGeneration.toString(), protocol: rdp ? 'rdp' : 'rustdesk', direction: 'download',
        fileName: '远端剪贴板文件', totalBytes: total, batchId: ownedBatch.id, sourceKind: 'remote-clipboard',
        isCurrent: current, onFinalize: (): void => { ownedBatch.release(); } },
        async (control: ManagedTransferControl): Promise<ManagedTransferOutcome> => {
          const alive = (): boolean => current() && control.isCurrent();
          this.report(epoch, 'receiving', 0, total);
          const result: ManagedTransferOutcome = offer !== null ?
            await this.receiveRdp(offer, ownedBatch, control, current, epoch) :
            await this.receiveRustDesk(client, sequence, entries, ownedBatch, control, current, epoch);
          if (result.stage !== 'completed' || !alive()) { return result; }
          if (!await control.enterCommit() || !alive()) { return { stage: 'cancelled', evidence: 'metadataVerified' }; }
          // Keep the complete private copy alive when only the system clipboard
          // publication failed. This is the only retryable post-receive state.
          if (!this.retainRetryBatch(ownedBatch)) { return { stage: 'failed', evidence: 'none', diagnosticCode: 'publication_failed' }; }
          this.retryBatch = ownedBatch; this.retrySequence = sequence;
          publishedCount = this.publish(ownedBatch, alive, remoteTag, epoch);
          if (publishedCount < 0) {
            // A write followed by a failed confirmation may already own the OS
            // clipboard. Retain its publication lease, but never write it again.
            if (this.publicationWriteAttempted || !alive()) { this.clearRetryBatch(); }
            else { this.publicationRetryAt = Date.now() + 500; }
          }
          return publishedCount >= 0 ? { stage: 'completed', evidence: 'metadataVerified' } :
            { stage: 'failed', evidence: 'none', diagnosticCode: 'publication_failed' };
        });
      admitted = handle.accepted;
      const result: ManagedTransferOutcome = await handle.result;
      if (!current()) {
        if (this.retrySequence === sequence) { this.clearRetryBatch(); }
        this.report(epoch, 'cancelled', this.status.writtenBytes, total, 'source_changed'); return false;
      }
      if (publishedCount >= 0 && result.stage === 'completed') {
        const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
        if (board.getChangeCount() !== publishedCount || board.getDataSync().getTag() !== remoteTag ||
          board.getChangeCount() !== publishedCount || !current()) {
          if (this.retrySequence === sequence) { this.clearRetryBatch(); }
          this.report(epoch, 'cancelled', this.status.writtenBytes, total, 'source_changed'); return false;
        }
        if (this.retryBatch !== null && this.retrySequence === sequence) {
          this.retryBatch.release('publish-retry'); this.retryBatch = null; this.retrySequence = 0;
        }
        this.deliveredSequence = sequence;
        this.report(epoch, 'ready', this.status.writtenBytes, this.status.totalBytes); return true;
      }
      if (this.status.phase === 'cached') {
        // The complete tree is available for cache/export workflows, but cannot be
        // represented as a flat system clipboard URI set. Do not overwrite this
        // diagnostic with a generic publication failure or retain a retry holder.
        this.clearRetryBatch(); return false;
      }
      this.report(epoch, 'failed', this.status.writtenBytes, total,
        result.stage === 'completed' || result.diagnosticCode === 'publication_failed' ?
          'publication_failed' : 'receive_failed');
      return false;
    } catch (_error) {
      if (this.retrySequence === sequence) { this.clearRetryBatch(); }
      this.report(epoch, current() ? 'failed' : 'cancelled', this.status.writtenBytes,
        this.status.totalBytes, current() ? 'receive_failed' : 'source_changed'); return false;
    } finally {
      if (batch !== null && !admitted) { batch.release(); }
      if (this.processingSequence === sequence) { this.processingSequence = 0; }
    }
  }
}
