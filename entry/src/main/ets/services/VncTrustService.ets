import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { AccountSessionCoordinator } from './AccountSessionCoordinator';
import { CloudStore } from './CloudStore';
import { VncRecord } from '../model/VncRecord';
import { VncCloudSyncService } from './VncCloudSyncService';
import {
  vncTrustPayload,
  finalizeVncRecord,
  VncTrustCertificateMetadata
} from './VncModelPolicy';
import {
  vncPayloadHashSha256,
  vncPayloadObject,
  vncTrustPayloadIsLegacy
} from './VncRecordPolicy';
import {
  removeVncTrustMarkersForEndpoint,
  removeVncTrustMarkersForOwner,
  vncTrustMarkerKey
} from './VncTrustInvalidationPolicy';

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
  endpointLabel: string;
  commonName: string;
  subject: string;
  issuer: string;
  notBeforeMs: number;
  notAfterMs: number;
  rootTrusted: boolean;
  hostMismatch: boolean;
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

export function vncTrustStoreMatchesCurrent(recordStoreIdentityFingerprint: string,
  currentStoreIdentityFingerprint: string): boolean {
  const recordStore: string = recordStoreIdentityFingerprint.trim().toLowerCase();
  const currentStore: string = currentStoreIdentityFingerprint.trim().toLowerCase();
  return /^[0-9a-f]{64}$/.test(recordStore) &&
    /^[0-9a-f]{64}$/.test(currentStore) && recordStore === currentStore;
}

export interface VncTrustViewState {
  confirmed: boolean;
  cloudCandidate: boolean;
}

export function vncTrustViewStateForStore(recordConfirmed: boolean, localMarkerConfirmed: boolean,
  recordStoreIdentityFingerprint: string, currentStoreIdentityFingerprint: string): VncTrustViewState {
  const confirmed: boolean = vncTrustStoreMatchesCurrent(
    recordStoreIdentityFingerprint, currentStoreIdentityFingerprint) &&
    recordConfirmed && localMarkerConfirmed;
  return {
    confirmed: confirmed,
    cloudCandidate: recordConfirmed && !confirmed
  };
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

export function vncTrustV2ReadBackMatches(record: VncRecord | null, ownerType: 'host' | 'gateway',
  ownerId: string, userId: string, fingerprintSha256: string,
  storeIdentityFingerprint: string, endpointBindingFingerprint: string): boolean {
  if (record === null || record.deletedAt > 0 || record.recordType !== 'trust' ||
    record.ownerType !== ownerType || record.ownerId.trim() !== ownerId.trim() ||
    record.userId.trim() !== userId.trim()) { return false; }
  const values = vncPayloadObject(record.payload);
  if (values === null || values['payloadVersion'] !== 2 || values['confirmed'] !== true) { return false; }
  return values['fingerprintSha256'] === fingerprintSha256.trim().toLowerCase() &&
    values['ownerType'] === ownerType &&
    values['storeIdentityFingerprint'] === storeIdentityFingerprint.trim().toLowerCase() &&
    values['endpointBindingFingerprint'] === endpointBindingFingerprint.trim().toLowerCase();
}

export function vncTrustMigrationNeedsCleanup(legacyId: string, v2Id: string): boolean {
  const oldId: string = legacyId.trim();
  const newId: string = v2Id.trim();
  return oldId !== '' && newId !== '' && oldId !== newId;
}

/**
 * A migration is complete only when the legacy id is no longer an active row.
 * CloudStore normally leaves a tombstone, but accepting an already-absent row
 * keeps the operation idempotent after a previous successful cleanup.
 */
export function vncTrustLegacyRowIsCleaned(records: VncRecord[], legacyId: string): boolean {
  const normalizedId: string = legacyId.trim();
  if (normalizedId === '') { return false; }
  for (let i = 0; i < records.length; i++) {
    if (records[i].id.trim() === normalizedId && records[i].deletedAt <= 0) { return false; }
  }
  return true;
}

/**
 * VNC trust owner. A cloud-restored fingerprint is candidate data only;
 * callers must invoke save after an interactive, current-connection
 * confirmation. The confirmation marker lives in device Preferences and is
 * never written into the cloud/backup payload.
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
  private activeStoreIdentityFingerprint: string = '';

  static getInstance(): VncTrustService {
    if (!VncTrustService.instance) { VncTrustService.instance = new VncTrustService(); }
    return VncTrustService.instance;
  }

  init(context: common.Context): void {
    this.context = context;
    this.userId = this.currentUserId();
    const currentStore: string = this.currentStoreIdentityFingerprint();
    const storeChanged: boolean = this.activeStoreIdentityFingerprint !== '' &&
      this.activeStoreIdentityFingerprint !== currentStore;
    this.activeStoreIdentityFingerprint = currentStore;
    this.loadLocalConfirmations(context);
    if (storeChanged) {
      this.locallyConfirmed = [];
      this.persistLocalConfirmations();
    }
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
        const previousUserId: string = this.userId;
        const previousStore: string = this.activeStoreIdentityFingerprint;
        const nextUserId: string = this.currentUserId();
        const nextStore: string = this.currentStoreIdentityFingerprint();
        this.userId = nextUserId;
        this.activeStoreIdentityFingerprint = nextStore;
        if (this.context !== null) { this.loadLocalConfirmations(this.context); }
        // A physical-store rollover invalidates markers even if the account
        // scope remains the same. Account-scoped markers for a different
        // account remain isolated by their preference key.
        if (previousUserId === nextUserId && previousStore !== '' &&
          previousStore !== nextStore) {
          this.locallyConfirmed = [];
          this.persistLocalConfirmations();
        }
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

  isTrusted(endpoint: VncTrustEndpoint, fingerprintSha256: string): boolean {
    const normalized: string = fingerprintSha256.trim().toLowerCase();
    const trust: VncTrustView | null = this.trustForEndpoint(endpoint);
    return trust !== null && trust.confirmed && trust.fingerprintSha256 === normalized;
  }

  /** Returns the confirmed fingerprint for one exact endpoint, if present. */
  trustedFingerprint(endpoint: VncTrustEndpoint): string {
    return this.trustedFingerprintForEndpoint(endpoint);
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
    let candidate: VncTrustView | null = null;
    for (let i = 0; i < values.length; i++) {
      const value: VncTrustView = values[i];
      if (value.ownerType === endpoint.ownerType && value.ownerId === ownerId &&
        value.userId === userId && value.storeIdentityFingerprint === store &&
        value.endpointBindingFingerprint === binding) {
        // A rotated certificate creates a new row for the same endpoint. A
        // locally confirmed row must win over historical cloud candidates,
        // even if cloud ordering later replays an older row.
        if (value.confirmed) { return value; }
        if (candidate === null) { candidate = value; }
      }
    }
    return candidate;
  }

  trustedFingerprintForEndpoint(endpoint: VncTrustEndpoint): string {
    const trust: VncTrustView | null = this.trustForEndpoint(endpoint);
    return trust !== null && trust.confirmed ? trust.fingerprintSha256 : '';
  }

  saveForEndpoint(endpoint: VncTrustEndpoint, fingerprintSha256: string,
    metadata: VncTrustCertificateMetadata | null = null): VncTrustSaveResult {
    return this.save(endpoint, fingerprintSha256, metadata);
  }

  private save(endpoint: VncTrustEndpoint, fingerprintSha256: string,
    metadata: VncTrustCertificateMetadata | null = null): VncTrustSaveResult {
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
    const previousV2: VncRecord | null = this.findRecord(result.id);
    const legacyRecord: VncRecord | null = this.findLegacyCandidateRecord(ownerType, ownerId,
      resolvedUserId, normalized, result.id);
    const current: VncTrustView | null = this.find(result.id) ||
      this.findLegacyCandidate(ownerType, ownerId, resolvedUserId, normalized);
    const record: VncRecord = new VncRecord();
    const now: number = Date.now();
    record.id = result.id;
    record.userId = resolvedUserId;
    record.recordType = 'trust';
    record.ownerId = ownerId;
    record.ownerType = ownerType;
    record.secretKind = '';
    record.payload = vncTrustPayload(normalized, true, now, ownerType,
      storeIdentityFingerprint, endpointBindingFingerprint, metadata);
    record.createdAt = current === null ? now : current.createdAt;
    record.updatedAt = now;
    record.syncVersion = current === null ? 1 : current.syncVersion + 1;
    finalizeVncRecord(record);
    if (!this.cloud.upsertVncRecord(record)) {
      result.message = this.cloud.getLastMutationResult().message || 'VNC trust 保存失败';
      return result;
    }
    const readBack: VncRecord | null = this.findRecord(result.id);
    if (!vncTrustV2ReadBackMatches(readBack, ownerType, ownerId, resolvedUserId, normalized,
      storeIdentityFingerprint, endpointBindingFingerprint)) {
      this.rollbackV2Mutation(resolvedUserId, result.id, previousV2);
      result.message = 'VNC trust 保存后校验失败';
      return result;
    }
    if (legacyRecord !== null && vncTrustMigrationNeedsCleanup(legacyRecord.id, result.id)) {
      const removedLegacy: boolean = this.cloud.deleteVncRecord(resolvedUserId, legacyRecord.id);
      const legacyReadBack: VncRecord[] = this.cloud.loadVncRecords(resolvedUserId, true);
      if (!removedLegacy || !vncTrustLegacyRowIsCleaned(legacyReadBack, legacyRecord.id)) {
        this.rollbackV2Mutation(resolvedUserId, result.id, previousV2);
        result.message = 'VNC trust 旧记录迁移未完成';
        return result;
      }
    }
    this.locallyConfirmed = removeVncTrustMarkersForEndpoint(
      this.locallyConfirmed, this.currentUserId(), ownerType, ownerId,
      endpointBindingFingerprint, normalized);
    this.rememberLocalConfirmation(ownerType, record.ownerId, normalized, endpointBindingFingerprint);
    this.persistLocalConfirmations();
    result.ok = true;
    this.emitChange();
    return result;
  }

  remove(id: string): boolean {
    const trust: VncTrustView | null = this.find(id);
    const ok: boolean = this.cloud.deleteVncRecord(this.currentUserId(), id);
    if (ok) {
      if (trust !== null) {
        this.forgetLocalConfirmation(trust.ownerType, trust.ownerId, trust.fingerprintSha256,
          trust.endpointBindingFingerprint);
      }
      this.emitChange();
    }
    return ok;
  }

  /**
   * Endpoint owners call this after a committed delete or endpoint mutation.
   * Historical trust rows remain visible as candidates, while every local
   * confirmation for the owner is invalidated before a connection can use it.
   */
  invalidateOwner(ownerType: 'host' | 'gateway', ownerId: string): boolean {
    const normalizedOwner: string = ownerId.trim();
    const currentUser: string = this.currentUserId();
    if (normalizedOwner === '' || currentUser.trim() === '') { return false; }
    const next: string[] = removeVncTrustMarkersForOwner(
      this.locallyConfirmed, currentUser, ownerType, normalizedOwner);
    const changed: boolean = next.length !== this.locallyConfirmed.length;
    if (changed) {
      this.locallyConfirmed = next;
      this.persistLocalConfirmations();
      this.emitChange();
    }
    return changed;
  }

  /** Invalidate one exact endpoint while leaving other owners untouched. */
  invalidateEndpoint(endpoint: VncTrustEndpoint): boolean {
    const currentUser: string = this.currentUserId();
    if (!vncTrustEndpointIsValid(endpoint, currentUser, this.currentStoreIdentityFingerprint())) {
      return false;
    }
    const next: string[] = removeVncTrustMarkersForEndpoint(
      this.locallyConfirmed, currentUser, endpoint.ownerType, endpoint.ownerId,
      endpoint.endpointBindingFingerprint);
    const changed: boolean = next.length !== this.locallyConfirmed.length;
    if (changed) {
      this.locallyConfirmed = next;
      this.persistLocalConfirmations();
      this.emitChange();
    }
    return changed;
  }

  private find(id: string): VncTrustView | null {
    const values: VncTrustView[] = this.list();
    for (let i = 0; i < values.length; i++) { if (values[i].id === id) { return values[i]; } }
    return null;
  }

  private findRecord(id: string): VncRecord | null {
    const records: VncRecord[] = this.cloud.loadVncRecords(this.currentUserId(), true);
    for (let i = 0; i < records.length; i++) {
      if (records[i].id === id && records[i].recordType === 'trust' && records[i].deletedAt <= 0) {
        return records[i];
      }
    }
    return null;
  }

  private rollbackV2Mutation(userId: string, id: string, previous: VncRecord | null): void {
    if (previous !== null) {
      this.cloud.upsertVncRecord(previous);
      return;
    }
    this.cloud.deleteVncRecord(userId, id);
  }

  private findLegacyCandidateRecord(ownerType: 'host' | 'gateway', ownerId: string,
    userId: string, fingerprintSha256: string, newId: string): VncRecord | null {
    const records: VncRecord[] = this.cloud.loadVncRecords(userId, true);
    for (let i = 0; i < records.length; i++) {
      const record: VncRecord = records[i];
      if (record.id === newId || record.deletedAt > 0 || record.recordType !== 'trust' ||
        record.ownerType !== ownerType || record.ownerId.trim() !== ownerId.trim()) { continue; }
      const values = vncPayloadObject(record.payload);
      const fingerprint: string = values !== null && typeof values['fingerprintSha256'] === 'string'
        ? (values['fingerprintSha256'] as string).trim().toLowerCase() : '';
      if (record.userId.trim() === userId.trim() && fingerprint === fingerprintSha256 &&
        vncTrustPayloadIsLegacy(record.payload, ownerType)) {
        return record;
      }
    }
    return null;
  }

  private findLegacyCandidate(ownerType: 'host' | 'gateway', ownerId: string,
    userId: string, fingerprintSha256: string): VncTrustView | null {
    const values: VncTrustView[] = this.list();
    for (let i = 0; i < values.length; i++) {
      const value: VncTrustView = values[i];
      if (value.ownerType === ownerType && value.ownerId === ownerId &&
        value.userId === userId && value.fingerprintSha256 === fingerprintSha256 &&
        value.storeIdentityFingerprint === '' && value.endpointBindingFingerprint === '') {
        return value;
      }
    }
    return null;
  }

  private toView(record: VncRecord): VncTrustView {
    let fingerprint: string = '';
    let confirmed: boolean = false;
    let confirmedAt: number = 0;
    let ownerType: 'host' | 'gateway' = record.ownerType === 'gateway' ? 'gateway' : 'host';
    let storeIdentityFingerprint: string = '';
    let endpointBindingFingerprint: string = '';
    let endpointLabel: string = '';
    let commonName: string = '';
    let subject: string = '';
    let issuer: string = '';
    let notBeforeMs: number = 0;
    let notAfterMs: number = 0;
    let rootTrusted: boolean = false;
    let hostMismatch: boolean = false;
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
      if (typeof values['endpointLabel'] === 'string') { endpointLabel = values['endpointLabel'] as string; }
      if (typeof values['commonName'] === 'string') { commonName = values['commonName'] as string; }
      if (typeof values['subject'] === 'string') { subject = values['subject'] as string; }
      if (typeof values['issuer'] === 'string') { issuer = values['issuer'] as string; }
      if (typeof values['notBeforeMs'] === 'number') { notBeforeMs = values['notBeforeMs'] as number; }
      if (typeof values['notAfterMs'] === 'number') { notAfterMs = values['notAfterMs'] as number; }
      if (typeof values['rootTrusted'] === 'boolean') { rootTrusted = values['rootTrusted'] as boolean; }
      if (typeof values['hostMismatch'] === 'boolean') { hostMismatch = values['hostMismatch'] as boolean; }
    } catch (_e) {}
    const viewState: VncTrustViewState = vncTrustViewStateForStore(
      confirmed,
      this.hasLocalConfirmation(ownerType, record.ownerId, fingerprint, endpointBindingFingerprint,
        storeIdentityFingerprint),
      storeIdentityFingerprint,
      this.currentStoreIdentityFingerprint());
    return {
      id: record.id, userId: record.userId, ownerId: record.ownerId,
      fingerprintSha256: fingerprint,
      // Cloud restore can carry a historical `confirmed` bit, but that bit is
      // only a candidate on a new device. The local confirmation marker is
      // written after an interactive current-connection confirmation.
      ownerType, storeIdentityFingerprint, endpointBindingFingerprint,
      confirmed: viewState.confirmed,
      cloudCandidate: viewState.cloudCandidate,
      confirmedAt, endpointLabel, commonName, subject, issuer, notBeforeMs, notAfterMs,
      rootTrusted, hostMismatch, createdAt: record.createdAt,
      syncVersion: record.syncVersion
    };
  }

  private localTrustKey(ownerType: 'host' | 'gateway', ownerId: string, fingerprintSha256: string,
    endpointBindingFingerprint: string = '', storeIdentityFingerprint: string = ''): string {
    const store: string = (storeIdentityFingerprint === ''
      ? this.currentStoreIdentityFingerprint() : storeIdentityFingerprint).trim().toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(store)) { return ''; }
    const binding: string = endpointBindingFingerprint.trim().toLowerCase();
    return vncTrustMarkerKey({
      userId: this.currentUserId(), storeIdentityFingerprint: store,
      ownerType, ownerId, fingerprintSha256,
      endpointBindingFingerprint: binding
    });
  }

  private hasLocalConfirmation(ownerType: 'host' | 'gateway', ownerId: string, fingerprintSha256: string,
    endpointBindingFingerprint: string = '', storeIdentityFingerprint: string = ''): boolean {
    const key: string = this.localTrustKey(ownerType, ownerId, fingerprintSha256,
      endpointBindingFingerprint, storeIdentityFingerprint);
    if (ownerId.trim() === '' || fingerprintSha256.trim() === '' || key === '') { return false; }
    if (this.locallyConfirmed.indexOf(key) >= 0) { return true; }
    // Accept the prior endpoint-bound marker format during one-way migration;
    // a later successful save writes the ownerType-aware key.
    const legacyKey: string = this.currentUserId() + '|' +
      (storeIdentityFingerprint === '' ? this.currentStoreIdentityFingerprint() : storeIdentityFingerprint)
        .trim().toLowerCase() + '|' + ownerId.trim() + '|' + fingerprintSha256.trim().toLowerCase() +
      (endpointBindingFingerprint.trim() === '' ? '' : '|' + endpointBindingFingerprint.trim().toLowerCase());
    return this.locallyConfirmed.indexOf(legacyKey) >= 0;
  }

  private rememberLocalConfirmation(ownerType: 'host' | 'gateway', ownerId: string, fingerprintSha256: string,
    endpointBindingFingerprint: string = ''): void {
    const key: string = this.localTrustKey(ownerType, ownerId, fingerprintSha256, endpointBindingFingerprint);
    if (key === '') { return; }
    if (this.locallyConfirmed.indexOf(key) < 0) { this.locallyConfirmed.push(key); }
    this.persistLocalConfirmations();
  }

  private forgetLocalConfirmation(ownerType: 'host' | 'gateway', ownerId: string,
    fingerprintSha256: string, endpointBindingFingerprint: string = ''): void {
    const currentUser: string = this.currentUserId();
    const normalizedOwner: string = ownerId.trim();
    const normalizedFingerprint: string = fingerprintSha256.trim().toLowerCase();
    this.locallyConfirmed = removeVncTrustMarkersForEndpoint(
      this.locallyConfirmed, currentUser, ownerType, normalizedOwner,
      endpointBindingFingerprint, normalizedFingerprint);
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
