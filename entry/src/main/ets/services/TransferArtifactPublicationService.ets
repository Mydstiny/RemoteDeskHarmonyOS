import { util } from '@kit.ArkTS';
import { RemoteSessionExactDisconnectIdentity } from './RemoteSessionTerminationPolicy';
import { TransferArtifactBatch } from './TransferArtifactStore';

interface ArtifactPublicationLease {
  id: string;
  batch: TransferArtifactBatch;
  kind: 'native' | 'system';
  nativeKey: string;
  systemTag: string;
  systemChangeCount: number;
}

/** Process service callers retain the exact publication identity across page disposal.
 * Other runtimes/restarts cannot retire leases absent from their registry; the durable
 * batch metadata continues to expose those publications as unknown and non-cleanable.
 */
export class TransferArtifactPublicationService {
  private static instance: TransferArtifactPublicationService = new TransferArtifactPublicationService();
  private leases: Map<string, ArtifactPublicationLease> = new Map<string, ArtifactPublicationLease>();
  static getInstance(): TransferArtifactPublicationService { return TransferArtifactPublicationService.instance; }

  private nativeKey(owner: RemoteSessionExactDisconnectIdentity): string {
    const values: number[] = [owner.sessionId, owner.generation, owner.ownerToken, owner.facadeGeneration,
      owner.rendererHandle, owner.decoderHandle, owner.audioPlayerHandle];
    if (values.some((value: number): boolean => !Number.isSafeInteger(value)) ||
      values.slice(0, 4).some((value: number): boolean => value <= 0) ||
      values.slice(4).some((value: number): boolean => value < -1)) { throw new Error('transfer_publication_owner_invalid'); }
    return JSON.stringify(values);
  }
  private register(batch: TransferArtifactBatch, kind: 'native' | 'system', key: string): string {
    if (this.leases.size >= 512) { throw new Error('transfer_publication_capacity'); }
    const id: string = util.generateRandomUUID(false);
    batch.retainPublication(id, kind);
    this.leases.set(id, { id, batch, kind, nativeKey: key,
      systemTag: kind === 'system' ? 'remotedesk:remote-text:v1:artifact:' + id : '', systemChangeCount: -1 });
    return id;
  }
  /** Call before native offer admission. Every published offer remains held through teardown. */
  registerNativeOffer(batch: TransferArtifactBatch, owner: RemoteSessionExactDisconnectIdentity): string {
    return this.register(batch, 'native', this.nativeKey(owner));
  }
  /** Only an exact successful native teardown authorizes retiring its offers. */
  completeNativeTeardown(owner: RemoteSessionExactDisconnectIdentity, successful: boolean): number {
    if (!successful) { return 0; }
    let key: string = '';
    try { key = this.nativeKey(owner); } catch (_error) { return 0; }
    let released: number = 0;
    for (const lease of Array.from(this.leases.values())) {
      if (lease.kind !== 'native' || lease.nativeKey !== key) { continue; }
      try {
        if (lease.batch.releasePublication(lease.id)) { this.leases.delete(lease.id); released++; }
      } catch (_error) { /* Persistence or lock failure retains the exact lease for retry. */ }
    }
    return released;
  }
  /** Separate namespace: native teardown can never retire a system clipboard lease. */
  registerSystemClipboard(batch: TransferArtifactBatch): string { return this.register(batch, 'system', ''); }
  systemClipboardTag(id: string): string {
    const lease: ArtifactPublicationLease | undefined = this.leases.get(id);
    return lease !== undefined && lease.kind === 'system' ? lease.systemTag : '';
  }
  confirmSystemClipboard(id: string, tag: string, changeCount: number): boolean {
    const lease: ArtifactPublicationLease | undefined = this.leases.get(id);
    if (lease === undefined || lease.kind !== 'system' || lease.systemTag !== tag ||
      !Number.isSafeInteger(changeCount) || changeCount < 0) { return false; }
    lease.systemChangeCount = changeCount; return true;
  }
  /** A different observed tag and counter prove the system no longer publishes this lease. */
  observeSystemClipboard(tag: string, changeCount: number): number {
    if (!Number.isSafeInteger(changeCount) || changeCount < 0) { return 0; }
    let released: number = 0;
    for (const lease of Array.from(this.leases.values())) {
      if (lease.kind === 'system' && lease.systemChangeCount >= 0 &&
        lease.systemChangeCount !== changeCount && lease.systemTag !== tag &&
        this.releaseSystemClipboard(lease.id, true)) { released++; }
    }
    return released;
  }
  /** Explicitly successful replacement/clear is also sufficient when read access is unavailable. */
  releaseSystemClipboard(id: string, replacementConfirmed: boolean): boolean {
    const lease: ArtifactPublicationLease | undefined = this.leases.get(id);
    if (!replacementConfirmed || lease === undefined || lease.kind !== 'system') { return false; }
    try {
      if (!lease.batch.releasePublication(id)) { return false; }
      this.leases.delete(id); return true;
    } catch (_error) { return false; }
  }
}
