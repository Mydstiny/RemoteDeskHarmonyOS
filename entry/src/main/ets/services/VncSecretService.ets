import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { VncRecord, VncSecretKind, VncOwnerType } from '../model/VncRecord';
import { CloudStore } from './CloudStore';
import { DataCrypto } from './DataCrypto';
import {
  VNC_AAD_VERSION,
  VNC_CRYPTO_VERSION,
  VNC_CLOUD_TABLE,
  VNC_KEY_VERSION,
  VNC_LEGACY_SECRET_ENVELOPE_VERSION,
  VNC_SECRET_ENVELOPE_VERSION,
  VNC_PLAIN_SECRET_ENVELOPE_VERSION,
  vncPayloadHashSha256
} from './VncRecordPolicy';
import { vncSecretMetadataPayload } from './VncModelPolicy';
import {
  decodePlainVncSecret,
  decideVncSecretStorage,
  encodePlainVncSecret,
  isPlainVncSecretEnvelope,
  vncSecretStorageModeFromPayload,
  VncSecretStorageMode
} from './VncSecretStoragePolicy';

const VNC_PREFS_NAME: string = 'RemoteDesktopVncPrefs';
const VNC_PLAIN_CONSENT_PREFIX: string = 'vncPlainSecretConsent|';

export type VncSecretLoadState = 'available' | 'missing' | 'locked' | 'consent_required' | 'invalid';

export interface VncSecretLoadResult {
  state: VncSecretLoadState;
  plaintext: string;
}

export interface VncSecretSaveResult {
  ok: boolean;
  message: string;
  recordId: string;
  code: string;
}

/**
 * VNC secret owner. Plaintext is accepted only for the duration of the
 * encrypt call and is never put in payload, Preferences, logs or a normal
 * protocol record.
 */
export class VncSecretService {
  private static instance: VncSecretService;
  private readonly cloud: CloudStore = CloudStore.getInstance();
  private context: common.Context | null = null;

  static getInstance(): VncSecretService {
    if (!VncSecretService.instance) { VncSecretService.instance = new VncSecretService(); }
    return VncSecretService.instance;
  }

  init(context: common.Context): void { this.context = context; }

  private recordId(ownerId: string, kind: VncSecretKind): string {
    return 'vncsecret_' + kind + '_' + ownerId;
  }

  save(userId: string, ownerId: string, ownerType: VncOwnerType, kind: VncSecretKind,
    plaintext: string, label: string, allowPlaintext: boolean = false,
    localOnly: boolean = false): VncSecretSaveResult {
    const result: VncSecretSaveResult = {
      ok: false, message: '', recordId: this.recordId(ownerId, kind), code: 'invalid'
    };
    const ownerKindValid: boolean = (ownerType === 'host' && kind === 'vnc_password') ||
      (ownerType === 'gateway' && (kind === 'repeater_token' || kind === 'gateway_token' ||
        kind === 'client_certificate'));
    if (userId.trim() === '' || ownerId.trim() === '' || !ownerKindValid || plaintext.length === 0) {
      result.message = 'VNC 凭据字段不完整';
      return result;
    }
    const crypto: DataCrypto = DataCrypto.getInstance();
    const decision = decideVncSecretStorage( true, crypto.isSetupComplete(), crypto.isReady(), allowPlaintext);
    if (!decision.allowed) {
      result.code = decision.code;
      result.message = decision.message;
      return result;
    }
    const storageMode: VncSecretStorageMode = decision.mode as VncSecretStorageMode;
    const record = this.find(userId, result.recordId);
    const next: VncRecord = record === null ? new VncRecord() : VncRecord.fromJSON(record.toJSON());
    const now: number = Date.now();
    next.id = result.recordId;
    next.userId = userId;
    next.recordType = 'secret';
    next.ownerId = ownerId;
    next.ownerType = ownerType;
    next.secretKind = kind;
    next.payload = vncSecretMetadataPayload(kind, label, storageMode);
    if (storageMode === 'encrypted_v3') {
      const resetEpoch: number = this.cloud.getVncResetEpoch();
      next.resetEpoch = resetEpoch;
      next.ciphertext = crypto.encryptVncFieldV3(
        userId, VNC_CLOUD_TABLE, next.id, 'ciphertext', plaintext,
        resetEpoch, 1);
      next.envelopeVersion = VNC_SECRET_ENVELOPE_VERSION;
      next.cryptoVersion = VNC_CRYPTO_VERSION;
      next.keyVersion = VNC_KEY_VERSION;
      next.aadVersion = VNC_AAD_VERSION;
    } else {
      next.ciphertext = encodePlainVncSecret(plaintext);
      if (next.ciphertext === '') {
        result.code = 'invalid';
        result.message = 'VNC 凭据长度或编码无效';
        return result;
      }
      next.envelopeVersion = VNC_PLAIN_SECRET_ENVELOPE_VERSION;
      next.cryptoVersion = 0;
      next.keyVersion = 0;
      next.aadVersion = 0;
    }
    next.syncVersion = Math.max(0, next.syncVersion) + 1;
    next.createdAt = next.createdAt > 0 ? next.createdAt : now;
    next.updatedAt = now;
    next.deletedAt = 0;
    next.payloadHashSha256 = vncPayloadHashSha256(next.payload);
    if (!this.cloud.upsertVncRecord(next, localOnly)) {
      result.message = this.cloud.getLastMutationResult().message || 'VNC 凭据保存失败';
      return result;
    }
    if (storageMode === 'plain_explicit_v1') { this.setPlainConsent(userId, result.recordId, true); }
    else { this.setPlainConsent(userId, result.recordId, false); }
    result.ok = true;
    result.code = 'none';
    return result;
  }

  load(userId: string, ownerId: string, kind: VncSecretKind): string {
    const loaded: VncSecretLoadResult = this.loadResult(userId, ownerId, kind);
    return loaded.state === 'available' ? loaded.plaintext : '';
  }

  loadResult(userId: string, ownerId: string, kind: VncSecretKind): VncSecretLoadResult {
    const missing: VncSecretLoadResult = { state: 'missing', plaintext: '' };
    const id: string = this.recordId(ownerId, kind);
    const record: VncRecord | null = this.find(userId, id);
    if (record === null || record.deletedAt > 0 || record.ciphertext === '') { return missing; }
    const storageMode: VncSecretStorageMode | '' = vncSecretStorageModeFromPayload(record.payload);
    if (storageMode === 'plain_explicit_v1') {
      if (!this.hasPlainConsent(userId, id)) {
        return { state: 'consent_required', plaintext: '' };
      }
      const plaintext: string | null = decodePlainVncSecret(record.ciphertext);
      return plaintext === null ? { state: 'invalid', plaintext: '' } :
        { state: 'available', plaintext };
    }
    if (storageMode !== 'encrypted_v3' &&
      storageMode !== 'encrypted_v2') {
      return { state: 'invalid', plaintext: '' };
    }
    const crypto: DataCrypto = DataCrypto.getInstance();
    if (!crypto.isReady()) {
      return { state: 'locked', plaintext: '' };
    }
    try {
      if (storageMode === 'encrypted_v3' &&
        record.envelopeVersion === VNC_SECRET_ENVELOPE_VERSION) {
        return {
          state: 'available',
          plaintext: crypto.decryptVncFieldV3(
            userId, VNC_CLOUD_TABLE, record.id, 'ciphertext',
            record.ciphertext, record.resetEpoch)
        };
      }
      if (storageMode !== 'encrypted_v2' ||
        record.envelopeVersion !== VNC_LEGACY_SECRET_ENVELOPE_VERSION) {
        return { state: 'invalid', plaintext: '' };
      }
      return {
        state: 'available',
        plaintext: crypto.decryptLegacyVncFieldV2(
          'remotedesktop|vnc', VNC_CLOUD_TABLE, record.id,
          'ciphertext', record.ciphertext)
      };
    } catch (_e) {
      return { state: 'invalid', plaintext: '' };
    }
  }

  /** Check presence without decrypting or materializing the secret. */
  has(userId: string, ownerId: string, kind: VncSecretKind): boolean {
    const record: VncRecord | null = this.find(userId, this.recordId(ownerId, kind));
    if (record === null || record.deletedAt > 0 || record.ciphertext === '') { return false; }
    const mode: VncSecretStorageMode | '' = vncSecretStorageModeFromPayload(record.payload);
    if (mode === 'encrypted_v3') {
      return record.envelopeVersion === VNC_SECRET_ENVELOPE_VERSION;
    }
    if (mode === 'encrypted_v2') {
      return record.envelopeVersion ===
        VNC_LEGACY_SECRET_ENVELOPE_VERSION;
    }
    return mode === 'plain_explicit_v1' && record.envelopeVersion === VNC_PLAIN_SECRET_ENVELOPE_VERSION &&
      isPlainVncSecretEnvelope(record.ciphertext);
  }

  remove(userId: string, ownerId: string, kind: VncSecretKind,
    localOnly: boolean = false): boolean {
    const id: string = this.recordId(ownerId, kind);
    const record: VncRecord | null = this.find(userId, id);
    if (record === null) { return true; }
    const removed: boolean = this.cloud.deleteVncRecord(userId, id, localOnly);
    if (removed) { this.setPlainConsent(userId, id, false); }
    return removed;
  }

  grantPlaintextConsent(userId: string, ownerId: string, kind: VncSecretKind): boolean {
    const id: string = this.recordId(ownerId, kind);
    const record: VncRecord | null = this.find(userId, id);
    if (record === null || record.deletedAt > 0 ||
      vncSecretStorageModeFromPayload(record.payload) !== 'plain_explicit_v1') { return false; }
    this.setPlainConsent(userId, id, true);
    return true;
  }

  private find(userId: string, id: string): VncRecord | null {
    // Secret lifecycle operations must not be hidden by the current logical
    // sync-scope projection. Otherwise turning the scope off would make an
    // existing password impossible to forget locally, and a locked device
    // could not create the corresponding tombstone.
    const records: VncRecord[] = this.cloud.loadAllVncRecordsRaw(true)
      .filter((record: VncRecord): boolean => record.userId === userId);
    for (let i = 0; i < records.length; i++) {
      if (records[i].id === id && records[i].recordType === 'secret') { return records[i]; }
    }
    return null;
  }

  private consentKey(userId: string, id: string): string {
    return VNC_PLAIN_CONSENT_PREFIX + userId.replaceAll('|', '%7C') + '|' + id.replaceAll('|', '%7C');
  }

  private hasPlainConsent(userId: string, id: string): boolean {
    if (this.context === null) { return false; }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: VNC_PREFS_NAME });
      return prefs.getSync(this.consentKey(userId, id), false) as boolean;
    } catch (_e) { return false; }
  }

  private setPlainConsent(userId: string, id: string, enabled: boolean): void {
    if (this.context === null) { return; }
    try {
      const prefs = preferences.getPreferencesSync(this.context, { name: VNC_PREFS_NAME });
      if (enabled) { prefs.putSync(this.consentKey(userId, id), true); }
      else { prefs.deleteSync(this.consentKey(userId, id)); }
      prefs.flushSync();
    } catch (_e) {}
  }
}
