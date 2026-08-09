import { describe, it, expect } from '@ohos/hypium';
import {
  MOONLIGHT_APP_CACHE_TABLE,
  MOONLIGHT_CLOUD_TABLE,
  MOONLIGHT_LOCAL_RECORD_COLUMNS,
  MOONLIGHT_LOCAL_TABLE,
  MOONLIGHT_RECORD_COLUMNS
} from '../main/ets/model/MoonlightRecord';
import { cloudSyncTableNames } from '../main/ets/services/CloudSyncPolicy';
import {
  MOONLIGHT_APP_CACHE_COLUMNS,
  MOONLIGHT_OWNER_STORE_SCHEMA_VERSION,
  MOONLIGHT_SCHEMA_MIGRATION_ID,
  moonlightAppCacheTableCreateSql,
  moonlightCloudTableCreateSql,
  moonlightLocalTableCreateSql,
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

    it('keeps_overlay_and_cache_permanently_local_only', 0, (): void => {
      expect(moonlightStorageTableIsLocalOnly(MOONLIGHT_LOCAL_TABLE)).assertTrue();
      expect(moonlightStorageTableIsLocalOnly(MOONLIGHT_APP_CACHE_TABLE)).assertTrue();
      expect(moonlightStorageTableIsLocalOnly(MOONLIGHT_CLOUD_TABLE)).assertFalse();
      expect(moonlightStorageTableMayEventuallyBeDistributed(MOONLIGHT_CLOUD_TABLE))
        .assertTrue();
      expect(moonlightStorageTableMayEventuallyBeDistributed(MOONLIGHT_LOCAL_TABLE))
        .assertFalse();
    });

    it('keeps_cloud_registration_closed_without_AGC_receipts', 0, (): void => {
      const tables: string[] = cloudSyncTableNames();
      expect(tables.length).assertEqual(8);
      expect(tables.indexOf(MOONLIGHT_CLOUD_TABLE)).assertEqual(-1);
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
