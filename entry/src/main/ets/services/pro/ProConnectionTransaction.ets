import { ProConnectionEnvelope, parseProConnectionEnvelope } from './ProConnectionEnvelope';
export type ProConnectionTransferPhase = 'offered' | 'connecting' | 'ready' | 'failed' | 'cancelled' | 'expired';
export interface ProConnectionReceipt {
  version: number;
  transferId: string;
  owner: string;
  result: string;
}
/** Local transaction state does not authorize the target or prove a network connection. */
export class ProConnectionTransaction {
  private readonly serialized: string;
  private phase: ProConnectionTransferPhase = 'offered';
  private expiresAt: number;
  constructor(envelope: ProConnectionEnvelope) {
    this.serialized = JSON.stringify(envelope);
    this.expiresAt = envelope.expiresAt;
  }
  state(now: number = Date.now()): ProConnectionTransferPhase {
    if ((this.phase === 'offered' || this.phase === 'connecting') && now >= this.expiresAt) {
      this.phase = 'expired';
    }
    return this.phase;
  }
  envelope(now: number = Date.now()): ProConnectionEnvelope | null {
    return parseProConnectionEnvelope(this.serialized, now);
  }
  begin(currentOwner: string, featureAllowed: boolean, confirmed: boolean, now: number = Date.now()): boolean {
    const value = this.envelope(now);
    if (this.state(now) !== 'offered' || value === null || !confirmed ||
        (value.purpose === 'continuation' && (!featureAllowed || currentOwner !== value.owner))) { return false; }
    this.phase = 'connecting';
    return true;
  }
  // Called only after the destination adapter observes native connectivity AND restores declared state.
  ready(currentOwner: string, featureAllowed: boolean, now: number = Date.now()): ProConnectionReceipt | null {
    const value = this.envelope(now);
    if (this.state(now) !== 'connecting' || value === null ||
        (value.purpose === 'continuation' && (!featureAllowed || currentOwner !== value.owner))) { return null; }
    this.phase = 'ready';
    return { version: 1, transferId: value.transferId, owner: value.owner, result: 'ready' };
  }
  acceptReceipt(serialized: string, currentOwner: string, featureAllowed: boolean, now: number = Date.now()): boolean {
    const value = this.envelope(now);
    if (value === null || serialized.length > 512 || this.state(now) !== 'connecting' ||
        !featureAllowed || (value.purpose === 'continuation' && currentOwner !== value.owner)) { return false; }
    try {
      const raw = JSON.parse(serialized) as Object;
      if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) { return false; }
      const keys = Object.keys(raw);
      if (keys.length !== 4 || !keys.every((key: string): boolean =>
        ['version', 'transferId', 'owner', 'result'].indexOf(key) >= 0)) { return false; }
      const receipt = raw as ProConnectionReceipt;
      if (receipt.version !== 1 || receipt.transferId !== value.transferId ||
          receipt.owner !== value.owner || receipt.result !== 'ready') { return false; }
      this.phase = 'ready';
      return true;
    } catch (_error) { return false; }
  }
  cancel(): void {
    if (this.phase === 'offered' || this.phase === 'connecting') { this.phase = 'cancelled'; }
  }
  fail(): void {
    if (this.phase === 'offered' || this.phase === 'connecting') { this.phase = 'failed'; }
  }
  mayOfferSourceClose(now: number = Date.now()): boolean {
    return this.state(now) === 'ready' && now < this.expiresAt;
  }
}
