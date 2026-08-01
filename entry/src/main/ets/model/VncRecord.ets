import { cryptoFramework } from '@kit.CryptoArchitectureKit';

/**
 * VncRecord — the typed row used by the isolated VNC data domain.
 *
 * The cloud contract is deliberately a single table. `recordtype` carries the
 * logical type while the local table keeps the same envelope plus a local-only
 * flag. No existing protocol model is used as a VNC owner.
 */

export type VncRecordType = 'settings' | 'host' | 'gateway' | 'secret' | 'trust';
export type VncOwnerType = 'account' | 'host' | 'gateway' | '';
export type VncSecretKind = 'vnc_password' | 'repeater_token' | 'gateway_token' |
  'client_certificate' | '';

export interface VncRecordJSON {
  id: string;
  userId: string;
  recordType: VncRecordType;
  ownerId: string;
  ownerType: VncOwnerType;
  secretKind: VncSecretKind;
  payload: string;
  ciphertext: string;
  envelopeVersion: number;
  cryptoVersion: number;
  keyVersion: number;
  aadVersion: number;
  payloadHashSha256: string;
  syncVersion: number;
  schemaVersion: number;
  resetEpoch: number;
  createdAt: number;
  updatedAt: number;
  deletedAt: number;
}

export class VncRecord {
  id: string = '';
  userId: string = '';
  recordType: VncRecordType = 'settings';
  ownerId: string = '';
  ownerType: VncOwnerType = '';
  secretKind: VncSecretKind = '';
  payload: string = '{}';
  ciphertext: string = '';
  envelopeVersion: number = 0;
  cryptoVersion: number = 0;
  keyVersion: number = 0;
  aadVersion: number = 0;
  payloadHashSha256: string = '';
  syncVersion: number = 0;
  schemaVersion: number = 1;
  resetEpoch: number = 0;
  createdAt: number = Date.now();
  updatedAt: number = 0;
  deletedAt: number = 0;

  isDeleted(): boolean {
    return this.deletedAt > 0;
  }

  toJSON(): VncRecordJSON {
    return {
      id: this.id,
      userId: this.userId,
      recordType: this.recordType,
      ownerId: this.ownerId,
      ownerType: this.ownerType,
      secretKind: this.secretKind,
      payload: this.payload,
      ciphertext: this.ciphertext,
      envelopeVersion: this.envelopeVersion,
      cryptoVersion: this.cryptoVersion,
      keyVersion: this.keyVersion,
      aadVersion: this.aadVersion,
      payloadHashSha256: this.payloadHashSha256,
      syncVersion: this.syncVersion,
      schemaVersion: this.schemaVersion,
      resetEpoch: this.resetEpoch,
      createdAt: this.createdAt,
      updatedAt: this.updatedAt,
      deletedAt: this.deletedAt
    };
  }

  static fromJSON(json: VncRecordJSON): VncRecord {
    const record = new VncRecord();
    if (json.id !== undefined) { record.id = json.id; }
    if (json.userId !== undefined) { record.userId = json.userId; }
    if (json.recordType !== undefined) { record.recordType = json.recordType; }
    if (json.ownerId !== undefined) { record.ownerId = json.ownerId; }
    if (json.ownerType !== undefined) { record.ownerType = json.ownerType; }
    if (json.secretKind !== undefined) { record.secretKind = json.secretKind; }
    if (json.payload !== undefined) { record.payload = json.payload; }
    if (json.ciphertext !== undefined) { record.ciphertext = json.ciphertext; }
    if (json.envelopeVersion !== undefined) { record.envelopeVersion = json.envelopeVersion; }
    if (json.cryptoVersion !== undefined) { record.cryptoVersion = json.cryptoVersion; }
    if (json.keyVersion !== undefined) { record.keyVersion = json.keyVersion; }
    if (json.aadVersion !== undefined) { record.aadVersion = json.aadVersion; }
    if (json.payloadHashSha256 !== undefined) { record.payloadHashSha256 = json.payloadHashSha256; }
    if (json.syncVersion !== undefined) { record.syncVersion = json.syncVersion; }
    if (json.schemaVersion !== undefined) { record.schemaVersion = json.schemaVersion; }
    if (json.resetEpoch !== undefined) { record.resetEpoch = json.resetEpoch; }
    if (json.createdAt !== undefined) { record.createdAt = json.createdAt; }
    if (json.updatedAt !== undefined) { record.updatedAt = json.updatedAt; }
    if (json.deletedAt !== undefined) { record.deletedAt = json.deletedAt; }
    return record;
  }

  static generateId(prefix: string = 'vnc'): string {
    const now = Date.now().toString(36);
    const randomBytes: Uint8Array = new Uint8Array(cryptoFramework.createRandom().generateRandomSync(12).data);
    let random: string = '';
    for (let i = 0; i < randomBytes.length; i++) {
      random += randomBytes[i].toString(16).padStart(2, '0');
    }
    return prefix + '_' + now + '_' + random;
  }
}
