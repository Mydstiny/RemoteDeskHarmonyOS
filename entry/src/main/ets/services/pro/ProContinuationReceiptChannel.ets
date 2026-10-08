import { common } from '@kit.AbilityKit';
import { distributedDataObject } from '@kit.ArkData';
interface ReceiptFields { receipt: string; acknowledged: string; }
interface ReceiptObject extends distributedDataObject.DataObject { receipt: string; acknowledged: string; }
/** Official trusted-network data object carries a bounded readiness receipt, never credentials. */
export class ProContinuationReceiptChannel {
  private object: ReceiptObject | null = null;
  private change: ((session: string, fields: string[]) => void) | null = null;
  private timer: number = -1;
  private generation: number = 0;
  private expiresAt: number = 0;
  async join(context: common.Context, session: string, expiresAt: number,
    onReceipt: (value: string) => boolean, onAcknowledged: () => void): Promise<boolean> {
    this.close();
    if (!/^rd_[a-f0-9]{32}$/.test(session) || expiresAt <= Date.now() ||
        expiresAt - Date.now() > 120000 ||
        !canIUse('SystemCapability.DistributedDataManager.DataObject.DistributedObject')) { return false; }
    const generation = this.generation;
    const source: ReceiptFields = { receipt: '', acknowledged: '' };
    let object: ReceiptObject;
    try { object = distributedDataObject.create(context, source) as ReceiptObject; }
    catch (_error) { return false; }
    const change = (sessionId: string, _fields: string[]): void => {
      if (generation !== this.generation || this.object !== object || sessionId !== session || Date.now() >= expiresAt) {
        return;
      }
      try {
        if (typeof object.receipt === 'string' && object.receipt.length > 0 && object.receipt.length <= 512 &&
            onReceipt(object.receipt)) { object.acknowledged = session; }
        if (object.acknowledged === session) { onAcknowledged(); }
      } catch (_error) { /* invalid remote fields cannot escape into the platform callback */ }
    };
    this.object = object; this.change = change; this.expiresAt = expiresAt;
    try {
      object.on('change', change);
      this.timer = setTimeout((): void => { if (generation === this.generation) { this.close(); } }, expiresAt - Date.now());
      await object.setSessionId(session);
      if (generation !== this.generation || this.object !== object) {
        // A late join belongs only to its old object, never a newer transaction.
        void object.setSessionId('').catch((): void => {});
        return false;
      }
      change(session, []);
      return true;
    } catch (_error) {
      if (generation === this.generation) { this.close(); }
      return false;
    }
  }
  send(receipt: string): boolean {
    if (this.object === null || Date.now() >= this.expiresAt || receipt.length === 0 || receipt.length > 512) { return false; }
    try { this.object.receipt = receipt; return true; } catch (_error) { return false; }
  }
  close(): void {
    this.generation++;
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    const object = this.object; const change = this.change;
    this.object = null; this.change = null; this.expiresAt = 0;
    if (object === null) { return; }
    try { if (change !== null) { object.off('change', change); } } catch (_error) {}
    try { void object.setSessionId('').catch((): void => {}); } catch (_error) {}
  }
}
