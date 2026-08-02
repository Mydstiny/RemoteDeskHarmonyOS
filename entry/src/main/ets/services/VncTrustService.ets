import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AccountSessionCoordinator } from './AccountSessionCoordinator';
import { CloudStore } from './CloudStore';
import { VncRecord } from '../model/VncRecord';
import { VncCloudSyncService } from './VncCloudSyncService';
import { vncTrustPayload, finalizeVncRecord } from './VncModelPolicy';
import { vncPayloadHashSha256 } from './VncRecordPolicy';

const TRUST_PREFS_NAME: string = 'RemoteDesktopVncTrustPrefs';
const LOCAL_TRUST_CONFIRMATIONS_KEY: string = 'locallyConfirmedVncTrust';
const VNC_STORE_FINGERPRINT_PREFIX: string = 'RemoteDeskHarmonyOS:vnctls-store:v1:';

export interface VncTrustView {
  id: string;
  userId: string;
  ownerId: string;
  ownerType: 'host' | 'gateway';
  storeIdentityFingerprint: string;
  endpointBindingFingerprint: string;
  fingerprintSha256: string;
  confirmed: boolean;
  cloudCandidate: boolean;
  confirmedAt: number;
  createdAt: number;
  syncVersion: number;
}

export interface VncTrustEndpoint {
  ownerType: 'host' | 'gateway';
  ownerId: string;
  userId: string;
  storeIdentityFingerprint: string;
  endpointBindingFingerprint: string;
}

export interface VncTrustSaveResult {
  ok: boolean;
  message: string;
  id: string;
}

export function vncStoreIdentityFingerprint(storeIdentity: string): string {
  const normalized: string = storeIdentity.trim();
  return normalized === '' ? '' : vncPayloadHashSha256(VNC_STORE_FINGERPRINT_PREFIX + normalized);
}

/**
 * Endpoint-bound trust is the only write contract. Keep this pure so the
 * host/gateway owner and account/store boundary can be tested without a
 * database or a device runtime.
 */
export function vncTrustEndpointIsValid(endpoint: VncTrustEndpoint,
  currentUserId: string, currentStoreIdentityFingerprint: string): boolean {
  const ownerId: string = endpoint.ownerId.trim();
  const userId: string = endpoint.userId.trim();
  const scope: string = currentUserId.trim();
  const currentStore: string = currentStoreIdentityFingerprint.trim().toLowerCase();
  return (endpoint.ownerType === 'host' || endpoint.ownerType === 'gateway') &&
    ownerId !== '' && userId !== '' && scope !== '' && userId === scope &&
    /^[0-9a-f]{64}$/.test(currentStore) &&
    endpoint.storeIdentityFingerprint.trim().toLowerCase() === currentStore &&
    /^[0-9a-f]{64}$/.test(endpoint.endpointBindingFingerprint.trim().toLowerCase());
}

/**
 * VNC trust owner. A cloud-restored fingerprint is data only; callers must
 * invoke save after an interactive, current-connection confirmation.
 */
export class VncTrustService {
  private static instance: VncTrustService;
  private readonly cloud: CloudStore = CloudStore.getInstance();
  private userId: string = 'device-local';
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
      AccountSessionCoordinator.getInstance().onChange((): void => {
        this.userId = this.currentUserId();
        if (this.context !== null) { this.loadLocalConfirmations(this.context); }
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
    return AccountSessionCoordinator.getInstance().currentScope().ownerScopeId;
  }

  private currentStoreIdentityFingerprint(): string {
    return vncStoreIdentityFingerprint(
      AccountSessionCoordinator.getInstance().currentScope().storeIdentity);
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

  /** Return a candidate or locally-confirmed row for one exact TLS endpoint. */
  trustForEndpoint(endpoint: VncTrustEndpoint): VncTrustView | null {
    const ownerId: string = endpoint.ownerId.trim();
    const userId: string = endpoint.userId.trim();
    const store: string = endpoint.storeIdentityFingerprint.trim().toLowerCase();
    const binding: string = endpoint.endpointBindingFingerprint.trim().toLowerCase();
    if (!vncTrustEndpointIsValid(endpoint, this.currentUserId(),
      this.currentStoreIdentityFingerprint())) {
      return null;
    }
    const values: VncTrustView[] = this.list();
    for (let i = 0; i < values.length; i++) {
      const value: VncTrustView = values[i];
      if (value.ownerType === endpoint.ownerType && value.ownerId === ownerId &&
        value.userId === userId && value.storeIdentityFingerprint === store &&
        value.endpointBindingFingerprint === binding) {
        return value;
      }
    }
    return null;
  }

  trustedFingerprintForEndpoint(endpoint: VncTrustEndpoint): string {
    const trust: VncTrustView | null = this.trustForEndpoint(endpoint);
    return trust !== null && trust.confirmed ? trust.fingerprintSha256 : '';
  }

  saveForEndpoint(endpoint: VncTrustEndpoint, fingerprintSha256: string): VncTrustSaveResult {
    return this.save(endpoint, fingerprintSha256);
  }

  private save(endpoint: VncTrustEndpoint, fingerprintSha256: string): VncTrustSaveResult {
    const normalized: string = fingerprintSha256.trim().toLowerCase();
    const result: VncTrustSaveResult = { ok: false, message: '', id: '' };
    const ownerId: string = endpoint.ownerId.trim();
    const resolvedUserId: string = endpoint.userId.trim();
    const ownerType: 'host' | 'gateway' = endpoint.ownerType;
    const storeIdentityFingerprint: string = endpoint.storeIdentityFingerprint.trim().toLowerCase();
    const endpointBindingFingerprint: string = endpoint.endpointBindingFingerprint.trim().toLowerCase();
    if (!vncTrustEndpointIsValid(endpoint, this.currentUserId(),
      this.currentStoreIdentityFingerprint()) ||
      !/^[0-9a-f]{64}$/.test(normalized)) {
      result.message = 'VNC trust 需要完整 endpoint owner 和有效指纹';
      return result;
    }
    result.id = 'vnctrust_' + ownerType + '_' + ownerId + '_' + normalized;
    const current: VncTrustView | null = this.find(result.id);
    const record: VncRecord = new VncRecord();
    const now: number = Date.now();
    record.id = result.id;
    record.userId = resolvedUserId;
    record.recordType = 'trust';
    record.ownerId = ownerId;
    record.ownerType = ownerType;
    record.secretKind = '';
    record.payload = vncTrustPayload(normalized, true, now, ownerType,
      storeIdentityFingerprint, endpointBindingFingerprint);
    record.createdAt = current === null ? now : current.createdAt;
    record.updatedAt = now;
    record.syncVersion = current === null ? 1 : current.syncVersion + 1;
    finalizeVncRecord(record);
    if (!this.cloud.upsertVncRecord(record)) {
      result.message = this.cloud.getLastMutationResult().message || 'VNC trust 保存失败';
      return result;
    }
    this.rememberLocalConfirmation(record.ownerId, normalized, endpointBindingFingerprint);
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
    let ownerType: 'host' | 'gateway' = record.ownerType === 'gateway' ? 'gateway' : 'host';
    let storeIdentityFingerprint: string = '';
    let endpointBindingFingerprint: string = '';
    try {
      const parsed: Object = JSON.parse(record.payload) as Object;
      const values: Record<string, Object> = parsed as Record<string, Object>;
      if (typeof values['fingerprintSha256'] === 'string') {
        fingerprint = values['fingerprintSha256'] as string;
      }
      if (typeof values['confirmed'] === 'boolean') { confirmed = values['confirmed'] as boolean; }
      if (typeof values['confirmedAt'] === 'number') { confirmedAt = values['confirmedAt'] as number; }
      if (values['ownerType'] === 'host' || values['ownerType'] === 'gateway') {
        ownerType = values['ownerType'] as 'host' | 'gateway';
      }
      if (typeof values['storeIdentityFingerprint'] === 'string') {
        storeIdentityFingerprint = (values['storeIdentityFingerprint'] as string).trim().toLowerCase();
      }
      if (typeof values['endpointBindingFingerprint'] === 'string') {
        endpointBindingFingerprint = (values['endpointBindingFingerprint'] as string).trim().toLowerCase();
      }
    } catch (_e) {}
    const locallyConfirmed: boolean = confirmed && this.hasLocalConfirmation(
      record.ownerId, fingerprint, endpointBindingFingerprint);
    return {
      id: record.id, userId: record.userId, ownerId: record.ownerId,
      fingerprintSha256: fingerprint,
      // Cloud restore can carry a historical `confirmed` bit, but that bit is
      // only a candidate on a new device. The local confirmation marker is
      // written after an interactive current-connection confirmation.
      ownerType, storeIdentityFingerprint, endpointBindingFingerprint,
      confirmed: locallyConfirmed,
      cloudCandidate: confirmed && !locallyConfirmed,
      confirmedAt, createdAt: record.createdAt,
      syncVersion: record.syncVersion
    };
  }

  private localTrustKey(ownerId: string, fingerprintSha256: string,
    endpointBindingFingerprint: string = ''): string {
    const binding: string = endpointBindingFingerprint.trim().toLowerCase();
    return this.currentUserId() + '|' + ownerId.trim() + '|' + fingerprintSha256.trim().toLowerCase() +
      (binding === '' ? '' : '|' + binding);
  }

  private hasLocalConfirmation(ownerId: string, fingerprintSha256: string,
    endpointBindingFingerprint: string = ''): boolean {
    return ownerId.trim() !== '' && fingerprintSha256.trim() !== '' &&
      this.locallyConfirmed.indexOf(this.localTrustKey(ownerId, fingerprintSha256,
        endpointBindingFingerprint)) >= 0;
  }

  private rememberLocalConfirmation(ownerId: string, fingerprintSha256: string,
    endpointBindingFingerprint: string = ''): void {
    const key: string = this.localTrustKey(ownerId, fingerprintSha256, endpointBindingFingerprint);
    if (this.locallyConfirmed.indexOf(key) < 0) { this.locallyConfirmed.push(key); }
    this.persistLocalConfirmations();
  }

  private forgetLocalConfirmation(ownerId: string, fingerprintSha256: string): void {
    const key: string = this.localTrustKey(ownerId, fingerprintSha256);
    const prefix: string = key + '|';
    this.locallyConfirmed = this.locallyConfirmed.filter((value: string): boolean =>
      value !== key && value.indexOf(prefix) !== 0);
    this.persistLocalConfirmations();
  }

  private loadLocalConfirmations(context: common.Context): void {
    this.locallyConfirmed = [];
    try {
      const prefs = preferences.getPreferencesSync(context, { name: TRUST_PREFS_NAME });
      const stored: string = prefs.getSync(this.confirmationPreferenceKey(), '') as string;
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
      prefs.putSync(this.confirmationPreferenceKey(), JSON.stringify(this.locallyConfirmed));
      prefs.flushSync();
    } catch (_e) {
      // Losing the local marker is fail-closed: the next connection asks for
      // confirmation again rather than trusting a cloud-restored fingerprint.
    }
  }

  private confirmationPreferenceKey(): string {
    return LOCAL_TRUST_CONFIRMATIONS_KEY + ':' + this.currentUserId();
  }

  private emitChange(): void {
    const callbacks: Array<() => void> = this.listeners.slice();
    for (let i = 0; i < callbacks.length; i++) { try { callbacks[i](); } catch (_e) {} }
  }
}
