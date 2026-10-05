import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { distributedDataObject } from '@kit.ArkData';
import {
  bytesToHex, parsePasskeyRequest, parsePasskeyResponse, PasskeyRequest, PasskeyResponse, passkeyRequestCurrent
} from './ProPasskeyCodec';
import { sha256, utf8 } from './ProPasskeyKeys';

interface ChannelFields { request: string; response: string; cancel: string; }
interface ChannelObject extends distributedDataObject.DataObject { request: string; response: string; cancel: string; }

const SYNC_PERMISSION: Permissions = 'ohos.permission.DISTRIBUTED_DATASYNC';
const DATA_OBJECT_CAPABILITY: string = 'SystemCapability.DistributedDataManager.DataObject.DistributedObject';
const MAX_REMEMBERED_IDS: number = 200;

/** One shared object per Huawei account: every device of the account derives the same session from its scope. */
export function passkeySessionId(owner: string): string {
  return 'rd_' + bytesToHex(sha256(utf8('RemoteDesk:passkey:v1:' + owner))).slice(0, 32);
}

/**
 * Prototype transport between devices of the same Huawei account: the official distributed data object, which only
 * syncs inside the account's trusted device network. One request and one response at a time; a device that joins
 * late never answers the request already in the object, and requests carry a freshness window. A sender that gives
 * up names the request in `cancel`, so the phone takes its dialog down.
 */
export class ProPasskeyChannel {
  private static instance: ProPasskeyChannel = new ProPasskeyChannel();
  static getInstance(): ProPasskeyChannel { return ProPasskeyChannel.instance; }

  private object: ChannelObject | null = null;
  private session: string = '';
  private change: ((session: string, fields: string[]) => void) | null = null;
  private generation: number = 0;
  private onRequest: ((request: PasskeyRequest) => void) | null = null;
  private onWithdraw: ((id: string) => void) | null = null;
  private pending: Map<string, (response: PasskeyResponse | null) => void> = new Map();
  /** A user let go of the channel while requests were still out: leave once the last one settles. */
  private leaveWhenIdle: boolean = false;
  private sent: string[] = [];
  private seen: string[] = [];

  static supported(): boolean {
    try { return canIUse(DATA_OBJECT_CAPABILITY); } catch (_error) { return false; }
  }

  async requestPermission(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, [SYNC_PERMISSION]);
      return result.authResults.length === 1 && result.authResults[0] === 0;
    } catch (_error) {
      return false;
    }
  }

  joined(): boolean { return this.object !== null; }

  async join(context: common.Context, owner: string): Promise<boolean> {
    const session = passkeySessionId(owner);
    this.leaveWhenIdle = false;
    if (this.object !== null && this.session === session) { return true; }
    this.leave();
    if (owner === '' || !ProPasskeyChannel.supported()) { return false; }
    const generation = this.generation;
    const source: ChannelFields = { request: '', response: '', cancel: '' };
    let object: ChannelObject;
    try { object = distributedDataObject.create(context, source) as ChannelObject; }
    catch (_error) { return false; }
    const change = (sessionId: string, fields: string[]): void => {
      if (generation !== this.generation || this.object !== object || sessionId !== session) { return; }
      try { this.changed(object, fields); } catch (_error) { /* malformed remote fields stay inside the callback */ }
    };
    this.object = object;
    this.session = session;
    this.change = change;
    try {
      object.on('change', change);
      await object.setSessionId(session);
      if (generation !== this.generation || this.object !== object) {
        void object.setSessionId('').catch((): void => {});
        return false;
      }
      // Whatever request already sits in the shared object predates this device; never answer it.
      const existing = typeof object.request === 'string' ? parsePasskeyRequest(object.request) : null;
      if (existing !== null) { this.remember(this.seen, existing.id); }
      return true;
    } catch (_error) {
      if (generation === this.generation) { this.leave(); }
      return false;
    }
  }

  /** Leaves now, or after the requests still out have settled; a receiver keeps the channel open. */
  release(): void {
    if (this.onRequest !== null) { return; }
    if (this.pending.size > 0) { this.leaveWhenIdle = true; return; }
    this.leave();
  }

  private settled(): void {
    if (!this.leaveWhenIdle || this.pending.size > 0 || this.onRequest !== null) { return; }
    // A withdrawal written just now needs a moment to sync before this device leaves.
    const generation = this.generation;
    setTimeout((): void => {
      if (generation === this.generation && this.leaveWhenIdle && this.pending.size === 0 && this.onRequest === null) {
        this.leave();
      }
    }, 500);
  }

  leave(): void {
    this.leaveWhenIdle = false;
    this.generation++;
    // Requests still out settle first, while the object can still tell the other devices.
    const waiting = Array.from(this.pending.values());
    this.pending.clear();
    waiting.forEach((finish: (response: PasskeyResponse | null) => void): void => { finish(null); });
    const object = this.object;
    const change = this.change;
    this.object = null;
    this.change = null;
    this.session = '';
    if (object === null) { return; }
    try { if (change !== null) { object.off('change', change); } } catch (_error) {}
    try { void object.setSessionId('').catch((): void => {}); } catch (_error) {}
  }

  /** Receives requests from other devices while set; null stops answering. */
  listen(onRequest: ((request: PasskeyRequest) => void) | null, onWithdraw: ((id: string) => void) | null = null): void {
    this.onRequest = onRequest;
    this.onWithdraw = onRequest === null ? null : onWithdraw;
    if (onRequest !== null) { this.leaveWhenIdle = false; }
  }

  respond(response: PasskeyResponse): boolean {
    const object = this.object;
    if (object === null) { return false; }
    try { object.response = JSON.stringify(response); return true; } catch (_error) { return false; }
  }

  /** Sends a request to the account's other devices and resolves with the first matching response, or null. */
  send(request: PasskeyRequest): Promise<PasskeyResponse | null> {
    const object = this.object;
    if (object === null) { return Promise.resolve(null); }
    this.remember(this.sent, request.id);
    return new Promise<PasskeyResponse | null>((resolve: (response: PasskeyResponse | null) => void): void => {
      let timer: number = -1;
      // However the request settles (an answer, a timeout, a withdrawal, leaving), the other devices are told, so a
      // dialog for it still open elsewhere comes down.
      const finish = (response: PasskeyResponse | null): void => {
        if (timer >= 0) { clearTimeout(timer); timer = -1; }
        this.markCancelled(request.id);
        this.clearRequest(request.id);
        resolve(response);
        this.settled();
      };
      timer = setTimeout((): void => { if (this.pending.delete(request.id)) { finish(null); } }, request.ttlMs);
      this.pending.set(request.id, finish);
      try { object.request = JSON.stringify(request); }
      catch (_error) {
        if (this.pending.delete(request.id)) { finish(null); }
      }
    });
  }

  /**
   * The sender no longer wants an answer (its user cancelled, the remote request ended): the request settles with
   * null at once and the other devices are told, so a dialog for it comes down.
   */
  withdraw(id: string): void {
    const finish = this.pending.get(id);
    if (finish === undefined) { return; }
    this.pending.delete(id);
    finish(null);
  }

  private markCancelled(id: string): void {
    const object = this.object;
    if (object === null) { return; }
    try { object.cancel = id; } catch (_error) { /* the request still expires on the other device */ }
  }

  private changed(object: ChannelObject, fields: string[]): void {
    if (fields.length === 0 || fields.indexOf('request') >= 0) {
      const request = typeof object.request === 'string' ? parsePasskeyRequest(object.request) : null;
      const listener = this.onRequest;
      if (request !== null && listener !== null && this.sent.indexOf(request.id) < 0 &&
          this.seen.indexOf(request.id) < 0 && passkeyRequestCurrent(request, Date.now())) {
        this.remember(this.seen, request.id);
        listener(request);
      }
    }
    if (fields.length === 0 || fields.indexOf('cancel') >= 0) {
      const id: string = typeof object.cancel === 'string' ? object.cancel : '';
      const listener = this.onWithdraw;
      if (id !== '' && listener !== null) { listener(id); }
    }
    if (fields.length === 0 || fields.indexOf('response') >= 0) {
      const text: string = typeof object.response === 'string' ? object.response : '';
      Array.from(this.pending.keys()).forEach((id: string): void => {
        const response = parsePasskeyResponse(text, id);
        const resolve = this.pending.get(id);
        if (response !== null && resolve !== undefined) {
          this.pending.delete(id);
          resolve(response);
        }
      });
    }
  }

  private clearRequest(id: string): void {
    const object = this.object;
    if (object === null) { return; }
    try {
      const current = parsePasskeyRequest(object.request);
      if (current !== null && current.id === id) { object.request = ''; }
    } catch (_error) {}
  }

  private remember(list: string[], id: string): void {
    list.push(id);
    if (list.length > MAX_REMEMBERED_IDS) { list.splice(0, list.length - MAX_REMEMBERED_IDS); }
  }
}
