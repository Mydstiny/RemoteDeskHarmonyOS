import { VncRecord, VncSecretKind, VncOwnerType } from '../model/VncRecord';
import { CloudStore } from './CloudStore';
import { DataCrypto } from './DataCrypto';
import {
  VNC_AAD_VERSION,
  VNC_CRYPTO_VERSION,
  VNC_CLOUD_TABLE,
  VNC_KEY_VERSION,
  VNC_SECRET_ENVELOPE_VERSION,
  vncPayloadHashSha256
} from './VncRecordPolicy';
import { vncCanonicalJson } from './VncRecordPolicy';

export interface VncSecretSaveResult {
  ok: boolean;
  message: string;
  recordId: string;
}

/**
 * VNC secret owner. Plaintext is accepted only for the duration of the
 * encrypt call and is never put in payload, Preferences, logs or a normal
 * protocol record.
 */
export class VncSecretService {
  private static instance: VncSecretService;
  private readonly cloud: CloudStore = CloudStore.getInstance();

  static getInstance(): VncSecretService {
    if (!VncSecretService.instance) { VncSecretService.instance = new VncSecretService(); }
    return VncSecretService.instance;
  }

  private recordId(ownerId: string, kind: VncSecretKind): string {
    return 'vncsecret_' + kind + '_' + ownerId;
  }

  save(userId: string, ownerId: string, ownerType: VncOwnerType, kind: VncSecretKind,
    plaintext: string, label: string): VncSecretSaveResult {
    const result: VncSecretSaveResult = { ok: false, message: '', recordId: this.recordId(ownerId, kind) };
    const ownerKindValid: boolean = (ownerType === 'host' && kind === 'vnc_password') ||
      (ownerType === 'gateway' && (kind === 'repeater_token' || kind === 'gateway_token' ||
        kind === 'client_certificate'));
    if (userId.trim() === '' || ownerId.trim() === '' || !ownerKindValid || plaintext.length === 0) {
      result.message = 'VNC 凭据字段不完整';
      return result;
    }
    const crypto: DataCrypto = DataCrypto.getInstance();
    if (!crypto.isReady()) {
      result.message = '请先解锁应用加密，再保存 VNC 密码或中继令牌';
      return result;
    }
    const record = this.find(userId, result.recordId);
    const next: VncRecord = record === null ? new VncRecord() : VncRecord.fromJSON(record.toJSON());
    const now: number = Date.now();
    next.id = result.recordId;
    next.userId = userId;
    next.recordType = 'secret';
    next.ownerId = ownerId;
    next.ownerType = ownerType;
    next.secretKind = kind;
    const metadata: Record<string, Object> = {};
    metadata['kind'] = kind;
    metadata['label'] = label.trim();
    next.payload = vncCanonicalJson(metadata);
    next.ciphertext = crypto.encryptField('remotedesktop|vnc', VNC_CLOUD_TABLE, next.id,
      'ciphertext', plaintext, 1, VNC_KEY_VERSION, VNC_AAD_VERSION);
    next.envelopeVersion = VNC_SECRET_ENVELOPE_VERSION;
    next.cryptoVersion = VNC_CRYPTO_VERSION;
    next.keyVersion = VNC_KEY_VERSION;
    next.aadVersion = VNC_AAD_VERSION;
    next.syncVersion = Math.max(0, next.syncVersion) + 1;
    next.createdAt = next.createdAt > 0 ? next.createdAt : now;
    next.updatedAt = now;
    next.deletedAt = 0;
    next.payloadHashSha256 = vncPayloadHashSha256(next.payload);
    if (!this.cloud.upsertVncRecord(next)) {
      result.message = this.cloud.getLastMutationResult().message || 'VNC 凭据保存失败';
      return result;
    }
    result.ok = true;
    return result;
  }

  load(userId: string, ownerId: string, kind: VncSecretKind): string {
    const id: string = this.recordId(ownerId, kind);
    const record: VncRecord | null = this.find(userId, id);
    if (record === null || record.deletedAt > 0 || record.ciphertext === '') { return ''; }
    const crypto: DataCrypto = DataCrypto.getInstance();
    if (!crypto.isReady() || record.envelopeVersion !== VNC_SECRET_ENVELOPE_VERSION) { return ''; }
    try {
      return crypto.decryptField('remotedesktop|vnc', VNC_CLOUD_TABLE, record.id, 'ciphertext', record.ciphertext);
    } catch (_e) {
      return '';
    }
  }

  /** Check presence without decrypting or materializing the secret. */
  has(userId: string, ownerId: string, kind: VncSecretKind): boolean {
    const record: VncRecord | null = this.find(userId, this.recordId(ownerId, kind));
    return record !== null && record.deletedAt <= 0 && record.ciphertext !== '' &&
      record.envelopeVersion === VNC_SECRET_ENVELOPE_VERSION;
  }

  remove(userId: string, ownerId: string, kind: VncSecretKind): boolean {
    const id: string = this.recordId(ownerId, kind);
    const record: VncRecord | null = this.find(userId, id);
    if (record === null) { return true; }
    return this.cloud.deleteVncRecord(userId, id);
  }

  private find(userId: string, id: string): VncRecord | null {
    const records: VncRecord[] = this.cloud.loadVncRecords(userId, true);
    for (let i = 0; i < records.length; i++) {
      if (records[i].id === id && records[i].recordType === 'secret') { return records[i]; }
    }
    return null;
  }
}
