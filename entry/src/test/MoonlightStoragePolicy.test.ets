import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  MOONLIGHT_APP_CACHE_TABLE,
  MOONLIGHT_CLOUD_TABLE,
  MOONLIGHT_LOCAL_RECORD_COLUMNS,
  MOONLIGHT_LOCAL_TABLE,
  MOONLIGHT_RECORD_COLUMNS
} from '../main/ets/model/MoonlightRecord';
import {
  cloudSyncTableNames,
  coreCloudSyncTableNames,
  optionalCloudSyncTableNames
} from '../main/ets/services/CloudSyncPolicy';
import {
  MOONLIGHT_APP_CACHE_COLUMNS,
  MOONLIGHT_APP_CACHE_SCHEMA,
  MOONLIGHT_LOCAL_RECORD_SCHEMA,
  MOONLIGHT_OWNER_STORE_SCHEMA_VERSION,
  MOONLIGHT_RECORD_SCHEMA,
  MOONLIGHT_SCHEMA_MIGRATION_ID,
  MoonlightStorageColumn,
  moonlightAppCacheTableCreateSql,
  moonlightCloudTableCreateSql,
  moonlightLocalTableCreateSql,
  moonlightOwnerStoreVersionAfterMigration,
  moonlightStorageSchemaFingerprint,
  moonlightStorageSchemaIsCompatible,
  moonlightStorageSchemasEqual,
  moonlightStorageSchemaContractIsExact,
  moonlightStorageTableIsLocalOnly,
  moonlightStorageTableMayEventuallyBeDistributed
} from '../main/ets/services/MoonlightStoragePolicy';

export default function moonlightStoragePolicyTest(): void {
  describe('MoonlightStoragePolicy', (): void => {
    it('locks_the_19_20_16_column_contract', 0, (): void => {
      expect(MOONLIGHT_RECORD_COLUMNS.length).assertEqual(19);
      expect(MOONLIGHT_LOCAL_RECORD_COLUMNS.length).assertEqual(20);
      expect(MOONLIGHT_APP_CACHE_COLUMNS.length).assertEqual(16);
      expect(moonlightStorageSchemaContractIsExact()).assertTrue();
      expect(moonlightStorageSchemaFingerprint()).assertContain(
        'moonlightrecordv1(id:TEXT:1');
      expect(moonlightStorageSchemaFingerprint()).assertContain(
        'moonlightlocalrecords(id:TEXT:1');
      expect(moonlightStorageSchemaFingerprint()).assertContain(
        'moonlightappcache(id:TEXT:1');
    });

    it('rejects_same_named_tables_with_wrong_type_or_primary_key', 0,
      (): void => {
        const wrongType: MoonlightStorageColumn[] =
          MOONLIGHT_RECORD_SCHEMA.map(
            (value: MoonlightStorageColumn): MoonlightStorageColumn => {
              return {
                name: value.name,
                sqlType: value.name === 'syncversion' ?
                  'TEXT' : value.sqlType,
                primaryKey: value.primaryKey
              };
            });
        const wrongPrimaryKey: MoonlightStorageColumn[] =
          MOONLIGHT_RECORD_SCHEMA.map(
            (value: MoonlightStorageColumn): MoonlightStorageColumn => {
              return {
                name: value.name,
                sqlType: value.sqlType,
                primaryKey: false
              };
            });
        expect(moonlightStorageSchemasEqual(
          MOONLIGHT_RECORD_SCHEMA, MOONLIGHT_RECORD_SCHEMA)).assertTrue();
        expect(moonlightStorageSchemasEqual(
          wrongType, MOONLIGHT_RECORD_SCHEMA)).assertFalse();
        expect(moonlightStorageSchemasEqual(
          wrongPrimaryKey, MOONLIGHT_RECORD_SCHEMA)).assertFalse();
        expect(moonlightStorageSchemasEqual(
          MOONLIGHT_LOCAL_RECORD_SCHEMA,
          MOONLIGHT_RECORD_SCHEMA)).assertFalse();
        const withLegacyExtra: MoonlightStorageColumn[] =
          MOONLIGHT_RECORD_SCHEMA.concat([{
            name: 'legacyhint', sqlType: 'TEXT', primaryKey: false
          }]);
        expect(moonlightStorageSchemaIsCompatible(
          withLegacyExtra, MOONLIGHT_RECORD_SCHEMA)).assertTrue();
        expect(moonlightStorageSchemaIsCompatible(
          wrongType, MOONLIGHT_RECORD_SCHEMA)).assertFalse();
        expect(moonlightStorageSchemaIsCompatible(
          MOONLIGHT_RECORD_SCHEMA.slice(0, 18),
          MOONLIGHT_RECORD_SCHEMA)).assertFalse();
        expect(MOONLIGHT_APP_CACHE_SCHEMA.length).assertEqual(16);
      });

    it('creates_idempotent_tables_with_only_id_as_primary_key', 0, (): void => {
      const cloud: string = moonlightCloudTableCreateSql();
      const local: string = moonlightLocalTableCreateSql();
      const cache: string = moonlightAppCacheTableCreateSql();
      expect(cloud.indexOf('CREATE TABLE IF NOT EXISTS moonlightrecordv1') === 0)
        .assertTrue();
      expect(local.indexOf('CREATE TABLE IF NOT EXISTS moonlightlocalrecords') === 0)
        .assertTrue();
      expect(cache.indexOf('CREATE TABLE IF NOT EXISTS moonlightappcache') === 0)
        .assertTrue();
      expect(cloud.indexOf('id TEXT PRIMARY KEY') > 0).assertTrue();
      expect(cloud.indexOf('userid TEXT PRIMARY KEY')).assertEqual(-1);
    });

    it('keeps_the_v4_to_v5_upgrade_additive_and_non_destructive', 0,
      (): void => {
        const statements: string[] = [
          moonlightCloudTableCreateSql(),
          moonlightLocalTableCreateSql(),
          moonlightAppCacheTableCreateSql()
        ];
        for (let i = 0; i < statements.length; i++) {
          const normalized: string = statements[i].toUpperCase();
          expect(normalized.indexOf('CREATE TABLE IF NOT EXISTS '))
            .assertEqual(0);
          expect(normalized.indexOf('DROP TABLE')).assertEqual(-1);
          expect(normalized.indexOf('DELETE FROM')).assertEqual(-1);
          expect(normalized.indexOf('ALTER TABLE')).assertEqual(-1);
          expect(normalized.indexOf('CREATE TABLE AS')).assertEqual(-1);
        }
        // Version 4 is the last deployed owner-store contract. Version 5 adds
        // only the three Moonlight-owned tables above; legacy table SQL and
        // rows are not migration inputs or replacement targets.
        expect(MOONLIGHT_OWNER_STORE_SCHEMA_VERSION).assertEqual(5);
      });

    it('advances_v4_only_after_all_tables_and_receipt_are_ready', 0,
      (): void => {
        const incomplete: boolean[][] = [
          [false, true, true, true],
          [true, false, true, true],
          [true, true, false, true],
          [true, true, true, false]
        ];
        for (let i = 0; i < incomplete.length; i++) {
          expect(moonlightOwnerStoreVersionAfterMigration(
            4, incomplete[i][0], incomplete[i][1],
            incomplete[i][2], incomplete[i][3])).assertEqual(4);
        }
        expect(moonlightOwnerStoreVersionAfterMigration(
          4, true, true, true, true)).assertEqual(5);
      });

    it('never_downgrades_an_existing_v5_receipt_on_optional_repair', 0,
      (): void => {
        expect(moonlightOwnerStoreVersionAfterMigration(
          5, false, false, false, false)).assertEqual(5);
      });

    it('keeps_overlay_and_cache_permanently_local_only', 0, (): void => {
      expect(moonlightStorageTableIsLocalOnly(MOONLIGHT_LOCAL_TABLE)).assertTrue();
      expect(moonlightStorageTableIsLocalOnly(MOONLIGHT_APP_CACHE_TABLE)).assertTrue();
      expect(moonlightStorageTableIsLocalOnly(MOONLIGHT_CLOUD_TABLE)).assertFalse();
      expect(moonlightStorageTableMayEventuallyBeDistributed(MOONLIGHT_CLOUD_TABLE))
        .assertTrue();
      expect(moonlightStorageTableMayEventuallyBeDistributed(MOONLIGHT_LOCAL_TABLE))
        .assertFalse();
    });

    it('isolates_optional_cloud_registration_from_the_legacy_baseline', 0, (): void => {
      const tables: string[] = cloudSyncTableNames();
      expect(tables.length).assertEqual(9);
      expect(coreCloudSyncTableNames().length).assertEqual(8);
      expect(coreCloudSyncTableNames().indexOf(MOONLIGHT_CLOUD_TABLE))
        .assertEqual(-1);
      expect(optionalCloudSyncTableNames().join(','))
        .assertEqual(MOONLIGHT_CLOUD_TABLE);
      expect(tables.indexOf(MOONLIGHT_CLOUD_TABLE)).assertEqual(8);
      expect(tables.indexOf(MOONLIGHT_LOCAL_TABLE)).assertEqual(-1);
      expect(tables.indexOf(MOONLIGHT_APP_CACHE_TABLE)).assertEqual(-1);
    });

    it('pins_the_owner_store_revision_and_migration_receipt_identity', 0, (): void => {
      expect(MOONLIGHT_OWNER_STORE_SCHEMA_VERSION).assertEqual(5);
      expect(MOONLIGHT_SCHEMA_MIGRATION_ID)
        .assertEqual('moonlightrecordv1_schema_19col_v1');
    });
  });
}
