import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AuthService } from './AuthService';
import { CloudStore } from './CloudStore';
import { VncRecord } from '../model/VncRecord';
import { VncCloudSyncService } from './VncCloudSyncService';
import { vncTrustPayload, finalizeVncRecord } from './VncModelPolicy';

const TRUST_PREFS_NAME: string = 'RemoteDesktopVncTrustPrefs';
const LOCAL_TRUST_CONFIRMATIONS_KEY: string = 'locallyConfirmedVncTrust';

export interface VncTrustView {
  id: string;
  userId: string;
  ownerId: string;
  fingerprintSha256: string;
  confirmed: boolean;
  confirmedAt: number;
  createdAt: number;
  syncVersion: number;
}

export interface VncTrustSaveResult {
  ok: boolean;
  message: string;
  id: string;
}

/**
 * VNC trust owner. A cloud-restored fingerprint is data only; callers must
 * invoke save after an interactive, current-connection confirmation.
 */
export class VncTrustService {
  private static instance: VncTrustService;
  private readonly cloud: CloudStore = CloudStore.getInstance();
  private userId: string = 'local';
  private initialized: boolean = false;
  private listenerBound: boolean = false;
  private listeners: Array<() => void> = [];
  private context: common.Context | null = null;
  private locallyConfirmed: string[] = [];

  static getInstance(): VncTrustService {
    if (!VncTrustService.instance) { VncTrustService.instance = new VncTrustService(); }
    return VncTrustService.instance;
  }

  init(context: common.Context): void {
    this.context = context;
    this.userId = this.currentUserId();
    this.loadLocalConfirmations(context);
    // A remote reset can arrive before the VNC page is opened. Clear stale
    // confirmation markers when the service is initialized later; otherwise a
    // recreated record with the same fingerprint could be trusted implicitly.
    if (this.cloud.getCryptoStatus() === 'reset') {
      this.clearLocalConfirmationState(context);
    }
    VncCloudSyncService.getInstance().init(context);
    if (!this.listenerBound) {
      this.listenerBound = true;
      this.cloud.onCloudChange((): void => { this.emitChange(); });
      this.cloud.onCryptoReset((): void => {
        this.locallyConfirmed = [];
        this.persistLocalConfirmations();
        this.emitChange();
      });
    }
    this.initialized = true;
  }

  /** Clear device-local trust confirmation after a completed crypto reset. */
  clearLocalConfirmationState(context: common.Context): void {
    this.context = context;
    this.userId = this.currentUserId();
    this.locallyConfirmed = [];
    this.persistLocalConfirmations();
    this.emitChange();
  }

  isReady(): boolean { return this.initialized && this.cloud.isReady(); }

  currentUserId(): string {
    const unionId: string = AuthService.getInstance().getUnionId();
    return unionId.trim() === '' ? 'local' : unionId.trim();
  }

  onChange(listener: () => void): () => void {
    if (this.listeners.indexOf(listener) < 0) { this.listeners.push(listener); }
    return (): void => {
      const index: number = this.listeners.indexOf(listener);
      if (index >= 0) { this.listeners.splice(index, 1); }
    };
  }

  list(): VncTrustView[] {
    const result: VncTrustView[] = [];
    const records: VncRecord[] = this.cloud.loadVncRecords(this.currentUserId());
    for (let i = 0; i < records.length; i++) {
      if (records[i].recordType === 'trust' && records[i].deletedAt <= 0) {
        result.push(this.toView(records[i]));
      }
    }
    return result;
  }

  isTrusted(ownerId: string, fingerprintSha256: string): boolean {
    const normalized: string = fingerprintSha256.trim().toLowerCase();
    const values: VncTrustView[] = this.list();
    for (let i = 0; i < values.length; i++) {
      if (values[i].ownerId === ownerId && values[i].fingerprintSha256 === normalized && values[i].confirmed) {
        return true;
      }
    }
    return false;
  }

  /** Returns the single confirmed fingerprint for an owner, if present. */
  trustedFingerprint(ownerId: string): string {
    const values: VncTrustView[] = this.list();
    for (let i = 0; i < values.length; i++) {
      if (values[i].ownerId === ownerId && values[i].confirmed) {
        return values[i].fingerprintSha256;
      }
    }
    return '';
  }

  save(ownerId: string, fingerprintSha256: string): VncTrustSaveResult {
    const normalized: string = fingerprintSha256.trim().toLowerCase();
    const result: VncTrustSaveResult = { ok: false, message: '', id: '' };
    if (ownerId.trim() === '' || normalized.length < 32) {
      result.message = 'VNC trust 需要主机 ID 和有效指纹';
      return result;
    }
    result.id = 'vnctrust_' + ownerId.trim() + '_' + normalized;
    const current: VncTrustView | null = this.find(result.id);
    const record: VncRecord = new VncRecord();
    const now: number = Date.now();
    record.id = result.id;
    record.userId = this.currentUserId();
    record.recordType = 'trust';
    record.ownerId = ownerId.trim();
    record.ownerType = 'host';
    record.secretKind = '';
    record.payload = vncTrustPayload(normalized, true, now);
    record.createdAt = current === null ? now : current.createdAt;
    record.updatedAt = now;
    record.syncVersion = current === null ? 1 : current.syncVersion + 1;
    finalizeVncRecord(record);
    if (!this.cloud.upsertVncRecord(record)) {
      result.message = this.cloud.getLastMutationResult().message || 'VNC trust 保存失败';
      return result;
    }
    this.rememberLocalConfirmation(record.ownerId, normalized);
    result.ok = true;
    this.emitChange();
    return result;
  }

  remove(id: string): boolean {
    const trust: VncTrustView | null = this.find(id);
    const ok: boolean = this.cloud.deleteVncRecord(this.currentUserId(), id);
    if (ok) {
      if (trust !== null) { this.forgetLocalConfirmation(trust.ownerId, trust.fingerprintSha256); }
      this.emitChange();
    }
    return ok;
  }

  private find(id: string): VncTrustView | null {
    const values: VncTrustView[] = this.list();
    for (let i = 0; i < values.length; i++) { if (values[i].id === id) { return values[i]; } }
    return null;
  }

  private toView(record: VncRecord): VncTrustView {
    let fingerprint: string = '';
    let confirmed: boolean = false;
    let confirmedAt: number = 0;
    try {
      const parsed: Object = JSON.parse(record.payload) as Object;
      const values: Record<string, Object> = parsed as Record<string, Object>;
      if (typeof values['fingerprintSha256'] === 'string') {
        fingerprint = values['fingerprintSha256'] as string;
      }
      if (typeof values['confirmed'] === 'boolean') { confirmed = values['confirmed'] as boolean; }
      if (typeof values['confirmedAt'] === 'number') { confirmedAt = values['confirmedAt'] as number; }
    } catch (_e) {}
    return {
      id: record.id, userId: record.userId, ownerId: record.ownerId,
      fingerprintSha256: fingerprint,
      // Cloud restore can carry a historical `confirmed` bit, but that bit is
      // only a candidate on a new device. The local confirmation marker is
      // written after an interactive current-connection confirmation.
      confirmed: confirmed && this.hasLocalConfirmation(record.ownerId, fingerprint),
      confirmedAt, createdAt: record.createdAt,
      syncVersion: record.syncVersion
    };
  }

  private localTrustKey(ownerId: string, fingerprintSha256: string): string {
    return this.currentUserId() + '|' + ownerId.trim() + '|' + fingerprintSha256.trim().toLowerCase();
  }

  private hasLocalConfirmation(ownerId: string, fingerprintSha256: string): boolean {
    return ownerId.trim() !== '' && fingerprintSha256.trim() !== '' &&
      this.locallyConfirmed.indexOf(this.localTrustKey(ownerId, fingerprintSha256)) >= 0;
  }

  private rememberLocalConfirmation(ownerId: string, fingerprintSha256: string): void {
    const key: string = this.localTrustKey(ownerId, fingerprintSha256);
    if (this.locallyConfirmed.indexOf(key) < 0) { this.locallyConfirmed.push(key); }
    this.persistLocalConfirmations();
  }

  private forgetLocalConfirmation(ownerId: string, fingerprintSha256: string): void {
    const key: string = this.localTrustKey(ownerId, fingerprintSha256);
    this.locallyConfirmed = this.locallyConfirmed.filter((value: string): boolean => value !== key);
    this.persistLocalConfirmations();
  }

  private loadLocalConfirmations(context: common.Context): void {
    this.locallyConfirmed = [];
    try {
      const prefs = preferences.getPreferencesSync(context, { name: TRUST_PREFS_NAME });
      const stored: string = prefs.getSync(LOCAL_TRUST_CONFIRMATIONS_KEY, '') as string;
      if (stored === '') { return; }
      const parsed: string[] = JSON.parse(stored) as string[];
      if (!Array.isArray(parsed)) { return; }
      for (let i = 0; i < parsed.length; i++) {
        if (typeof parsed[i] === 'string' && parsed[i].trim() !== '' &&
          this.locallyConfirmed.indexOf(parsed[i]) < 0) {
          this.locallyConfirmed.push(parsed[i]);
        }
      }
    } catch (_e) {
      this.locallyConfirmed = [];
    }
  }

  private persistLocalConfirmations(): void {
    if (this.context === null) { return; }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: TRUST_PREFS_NAME });
      prefs.putSync(LOCAL_TRUST_CONFIRMATIONS_KEY, JSON.stringify(this.locallyConfirmed));
      prefs.flushSync();
    } catch (_e) {
      // Losing the local marker is fail-closed: the next connection asks for
      // confirmation again rather than trusting a cloud-restored fingerprint.
    }
  }

  private emitChange(): void {
    const callbacks: Array<() => void> = this.listeners.slice();
    for (let i = 0; i < callbacks.length; i++) { try { callbacks[i](); } catch (_e) {} }
  }
}
