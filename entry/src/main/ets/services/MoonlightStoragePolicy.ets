import {
  MOONLIGHT_APP_CACHE_TABLE,
  MOONLIGHT_CLOUD_TABLE,
  MOONLIGHT_LOCAL_RECORD_COLUMNS,
  MOONLIGHT_LOCAL_TABLE,
  MOONLIGHT_RECORD_COLUMNS
} from '../model/MoonlightRecord';

/** Version of the owner-scoped RDB schema that first contains Moonlight. */
export const MOONLIGHT_OWNER_STORE_SCHEMA_VERSION: number = 5;
export const MOONLIGHT_SCHEMA_MIGRATION_ID: string =
  'moonlightrecordv1_schema_19col_v1';

/**
 * Version 5 is a durable completion receipt, not evidence that an upgrade was
 * merely attempted. Keep the installed version unchanged until every
 * additive Moonlight table and the owner-scoped receipt are readable. This
 * makes a v4 -> v5 upgrade restart-safe without touching any legacy table.
 */
export function moonlightOwnerStoreVersionAfterMigration(
  currentVersion: number,
  cloudTableReady: boolean,
  localTableReady: boolean,
  appCacheTableReady: boolean,
  receiptReady: boolean
): number {
  if (currentVersion >= MOONLIGHT_OWNER_STORE_SCHEMA_VERSION) {
    return currentVersion;
  }
  return cloudTableReady && localTableReady && appCacheTableReady &&
    receiptReady ? MOONLIGHT_OWNER_STORE_SCHEMA_VERSION : currentVersion;
}

export interface MoonlightStorageColumn {
  name: string;
  sqlType: string;
  primaryKey: boolean;
}

function column(name: string, sqlType: string,
  primaryKey: boolean = false): MoonlightStorageColumn {
  return { name: name, sqlType: sqlType, primaryKey: primaryKey };
}

export const MOONLIGHT_RECORD_SCHEMA: MoonlightStorageColumn[] = [
  column('id', 'TEXT', true),
  column('userid', 'TEXT'),
  column('recordtype', 'TEXT'),
  column('ownerid', 'TEXT'),
  column('ownertype', 'TEXT'),
  column('secretkind', 'TEXT'),
  column('payload', 'TEXT'),
  column('ciphertext', 'TEXT'),
  column('envelopeversion', 'INTEGER'),
  column('cryptoversion', 'INTEGER'),
  column('keyversion', 'INTEGER'),
  column('aadversion', 'INTEGER'),
  column('payloadhashsha256', 'TEXT'),
  column('syncversion', 'INTEGER'),
  column('schemaversion', 'INTEGER'),
  column('resetepoch', 'INTEGER'),
  column('createdat', 'INTEGER'),
  column('updatedat', 'INTEGER'),
  column('deletedat', 'INTEGER')
];

export const MOONLIGHT_LOCAL_RECORD_SCHEMA: MoonlightStorageColumn[] = [
  ...MOONLIGHT_RECORD_SCHEMA,
  column('localonly', 'INTEGER')
];

/**
 * Rebuildable catalog/artwork index. It is deliberately not an envelope table
 * and is never eligible for cloud registration or portable backup.
 */
export const MOONLIGHT_APP_CACHE_SCHEMA: MoonlightStorageColumn[] = [
  column('id', 'TEXT', true),
  column('userid', 'TEXT'),
  column('hostid', 'TEXT'),
  column('appid', 'TEXT'),
  column('title', 'TEXT'),
  column('iconetag', 'TEXT'),
  column('iconhashsha256', 'TEXT'),
  column('artworklocalpath', 'TEXT'),
  column('catalogetag', 'TEXT'),
  column('cataloghashsha256', 'TEXT'),
  column('available', 'INTEGER'),
  column('sortorder', 'INTEGER'),
  column('lastcatalogat', 'INTEGER'),
  column('expiresat', 'INTEGER'),
  column('lastaccessedat', 'INTEGER'),
  column('sizebytes', 'INTEGER')
];

export function moonlightStorageSchemasEqual(
  actual: MoonlightStorageColumn[],
  expected: MoonlightStorageColumn[]
): boolean {
  if (actual.length !== expected.length) { return false; }
  for (let i = 0; i < expected.length; i++) {
    if (actual[i].name !== expected[i].name ||
        actual[i].sqlType.trim().toUpperCase() !==
          expected[i].sqlType.trim().toUpperCase() ||
        actual[i].primaryKey !== expected[i].primaryKey) {
      return false;
    }
  }
  return true;
}

function schemaFingerprint(
  table: string, schema: MoonlightStorageColumn[]
): string {
  const fields: string[] = [];
  for (let i = 0; i < schema.length; i++) {
    fields.push(schema[i].name + ':' +
      schema[i].sqlType.trim().toUpperCase() + ':' +
      (schema[i].primaryKey ? '1' : '0'));
  }
  return table + '(' + fields.join(',') + ')';
}

/** Durable receipt fingerprint for all three additive v5 tables. */
export function moonlightStorageSchemaFingerprint(): string {
  return [
    schemaFingerprint(MOONLIGHT_CLOUD_TABLE, MOONLIGHT_RECORD_SCHEMA),
    schemaFingerprint(MOONLIGHT_LOCAL_TABLE, MOONLIGHT_LOCAL_RECORD_SCHEMA),
    schemaFingerprint(MOONLIGHT_APP_CACHE_TABLE, MOONLIGHT_APP_CACHE_SCHEMA)
  ].join('|');
}

export const MOONLIGHT_APP_CACHE_COLUMNS: string[] = [
  'id', 'userid', 'hostid', 'appid', 'title', 'iconetag', 'iconhashsha256',
  'artworklocalpath', 'catalogetag', 'cataloghashsha256', 'available',
  'sortorder', 'lastcatalogat', 'expiresat', 'lastaccessedat', 'sizebytes'
];

export const MOONLIGHT_RECORD_INTEGER_COLUMNS: string[] = [
  'envelopeversion', 'cryptoversion', 'keyversion', 'aadversion',
  'syncversion', 'schemaversion', 'resetepoch', 'createdat', 'updatedat',
  'deletedat'
];

export const MOONLIGHT_CACHE_INTEGER_COLUMNS: string[] = [
  'available', 'sortorder', 'lastcatalogat', 'expiresat', 'lastaccessedat',
  'sizebytes'
];

function schemaColumnNames(schema: MoonlightStorageColumn[]): string[] {
  const result: string[] = [];
  for (let i = 0; i < schema.length; i++) { result.push(schema[i].name); }
  return result;
}

function sameOrderedStrings(left: string[], right: string[]): boolean {
  if (left.length !== right.length) { return false; }
  for (let i = 0; i < left.length; i++) {
    if (left[i] !== right[i]) { return false; }
  }
  return true;
}

/** Single source of truth check used by migration and tests. */
export function moonlightStorageSchemaContractIsExact(): boolean {
  return sameOrderedStrings(
    schemaColumnNames(MOONLIGHT_RECORD_SCHEMA), MOONLIGHT_RECORD_COLUMNS) &&
    sameOrderedStrings(
      schemaColumnNames(MOONLIGHT_LOCAL_RECORD_SCHEMA),
      MOONLIGHT_LOCAL_RECORD_COLUMNS) &&
    sameOrderedStrings(
      schemaColumnNames(MOONLIGHT_APP_CACHE_SCHEMA),
      MOONLIGHT_APP_CACHE_COLUMNS);
}

function createTableSql(table: string,
  schema: MoonlightStorageColumn[]): string {
  const definitions: string[] = [];
  for (let i = 0; i < schema.length; i++) {
    definitions.push(schema[i].name + ' ' + schema[i].sqlType +
      (schema[i].primaryKey ? ' PRIMARY KEY' : ''));
  }
  return 'CREATE TABLE IF NOT EXISTS ' + table + ' (' +
    definitions.join(', ') + ')';
}

export function moonlightCloudTableCreateSql(): string {
  return createTableSql(MOONLIGHT_CLOUD_TABLE, MOONLIGHT_RECORD_SCHEMA);
}

export function moonlightLocalTableCreateSql(): string {
  return createTableSql(MOONLIGHT_LOCAL_TABLE, MOONLIGHT_LOCAL_RECORD_SCHEMA);
}

export function moonlightAppCacheTableCreateSql(): string {
  return createTableSql(MOONLIGHT_APP_CACHE_TABLE, MOONLIGHT_APP_CACHE_SCHEMA);
}

export function moonlightStorageTableIsLocalOnly(table: string): boolean {
  return table === MOONLIGHT_LOCAL_TABLE || table === MOONLIGHT_APP_CACHE_TABLE;
}

/** Eligibility is not registration; runtime admission remains independently gated. */
export function moonlightStorageTableMayEventuallyBeDistributed(
  table: string
): boolean {
  return table === MOONLIGHT_CLOUD_TABLE;
}
