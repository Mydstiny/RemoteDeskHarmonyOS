/** The single-table Moonlight cloud envelope and its local-only mirror row. */

export type MoonlightRecordType = 'settings' | 'host' | 'profile' | 'trust' | 'secret';
export type MoonlightOwnerType = 'account' | 'host' | 'profile' | '';
export type MoonlightSecretKind = 'client_identity' | '';

export const MOONLIGHT_CLOUD_TABLE: string = 'moonlightrecordv1';
export const MOONLIGHT_LOCAL_TABLE: string = 'moonlightlocalrecords';
export const MOONLIGHT_APP_CACHE_TABLE: string = 'moonlightappcache';
export const MOONLIGHT_SCHEMA_VERSION: number = 1;

export const MOONLIGHT_RECORD_COLUMNS: string[] = [
  'id', 'userid', 'recordtype', 'ownerid', 'ownertype', 'secretkind', 'payload', 'ciphertext',
  'envelopeversion', 'cryptoversion', 'keyversion', 'aadversion', 'payloadhashsha256',
  'syncversion', 'schemaversion', 'resetepoch', 'createdat', 'updatedat', 'deletedat'
];

export const MOONLIGHT_LOCAL_RECORD_COLUMNS: string[] = [
  'id', 'userid', 'recordtype', 'ownerid', 'ownertype', 'secretkind', 'payload', 'ciphertext',
  'envelopeversion', 'cryptoversion', 'keyversion', 'aadversion', 'payloadhashsha256',
  'syncversion', 'schemaversion', 'resetepoch', 'createdat', 'updatedat', 'deletedat', 'localonly'
];

export interface MoonlightRecordJSON {
  id: string;
  userId: string;
  recordType: MoonlightRecordType;
  ownerId: string;
  ownerType: MoonlightOwnerType;
  secretKind: MoonlightSecretKind;
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

export interface MoonlightLocalRecordJSON extends MoonlightRecordJSON {
  localOnly: number;
}

export class MoonlightRecord {
  id: string = '';
  userId: string = '';
  recordType: MoonlightRecordType = 'settings';
  ownerId: string = '';
  ownerType: MoonlightOwnerType = 'account';
  secretKind: MoonlightSecretKind = '';
  payload: string = '{}';
  ciphertext: string = '';
  envelopeVersion: number = 0;
  cryptoVersion: number = 0;
  keyVersion: number = 0;
  aadVersion: number = 0;
  payloadHashSha256: string = '';
  syncVersion: number = 0;
  schemaVersion: number = MOONLIGHT_SCHEMA_VERSION;
  resetEpoch: number = 0;
  createdAt: number = 0;
  updatedAt: number = 0;
  deletedAt: number = 0;

  isDeleted(): boolean {
    return this.deletedAt > 0;
  }

  toJSON(): MoonlightRecordJSON {
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

  static fromJSON(json: MoonlightRecordJSON): MoonlightRecord {
    const record = new MoonlightRecord();
    record.id = json.id;
    record.userId = json.userId;
    record.recordType = json.recordType;
    record.ownerId = json.ownerId;
    record.ownerType = json.ownerType;
    record.secretKind = json.secretKind;
    record.payload = json.payload;
    record.ciphertext = json.ciphertext;
    record.envelopeVersion = json.envelopeVersion;
    record.cryptoVersion = json.cryptoVersion;
    record.keyVersion = json.keyVersion;
    record.aadVersion = json.aadVersion;
    record.payloadHashSha256 = json.payloadHashSha256;
    record.syncVersion = json.syncVersion;
    record.schemaVersion = json.schemaVersion;
    record.resetEpoch = json.resetEpoch;
    record.createdAt = json.createdAt;
    record.updatedAt = json.updatedAt;
    record.deletedAt = json.deletedAt;
    return record;
  }
}

export class MoonlightLocalRecord extends MoonlightRecord {
  localOnly: number = 1;

  toLocalJSON(): MoonlightLocalRecordJSON {
    const base: MoonlightRecordJSON = this.toJSON();
    return {
      id: base.id,
      userId: base.userId,
      recordType: base.recordType,
      ownerId: base.ownerId,
      ownerType: base.ownerType,
      secretKind: base.secretKind,
      payload: base.payload,
      ciphertext: base.ciphertext,
      envelopeVersion: base.envelopeVersion,
      cryptoVersion: base.cryptoVersion,
      keyVersion: base.keyVersion,
      aadVersion: base.aadVersion,
      payloadHashSha256: base.payloadHashSha256,
      syncVersion: base.syncVersion,
      schemaVersion: base.schemaVersion,
      resetEpoch: base.resetEpoch,
      createdAt: base.createdAt,
      updatedAt: base.updatedAt,
      deletedAt: base.deletedAt,
      localOnly: this.localOnly
    };
  }

  static fromLocalJSON(json: MoonlightLocalRecordJSON): MoonlightLocalRecord {
    const base: MoonlightRecord = MoonlightRecord.fromJSON(json);
    const record = new MoonlightLocalRecord();
    record.id = base.id;
    record.userId = base.userId;
    record.recordType = base.recordType;
    record.ownerId = base.ownerId;
    record.ownerType = base.ownerType;
    record.secretKind = base.secretKind;
    record.payload = base.payload;
    record.ciphertext = base.ciphertext;
    record.envelopeVersion = base.envelopeVersion;
    record.cryptoVersion = base.cryptoVersion;
    record.keyVersion = base.keyVersion;
    record.aadVersion = base.aadVersion;
    record.payloadHashSha256 = base.payloadHashSha256;
    record.syncVersion = base.syncVersion;
    record.schemaVersion = base.schemaVersion;
    record.resetEpoch = base.resetEpoch;
    record.createdAt = base.createdAt;
    record.updatedAt = base.updatedAt;
    record.deletedAt = base.deletedAt;
    record.localOnly = json.localOnly;
    return record;
  }
}

export function moonlightExpectedOwnerType(recordType: MoonlightRecordType): MoonlightOwnerType {
  if (recordType === 'profile' || recordType === 'trust') { return 'host'; }
  return 'account';
}

export function moonlightExpectedSecretKind(recordType: MoonlightRecordType): MoonlightSecretKind {
  return recordType === 'secret' ? 'client_identity' : '';
}

export function moonlightLocalOnlyFlagIsValid(value: number): boolean {
  return value === 0 || value === 1;
}
