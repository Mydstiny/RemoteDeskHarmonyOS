import { expect } from '@ohos/hypium';
import {
  auditedDescribe as describe,
  auditedIt as it
} from '../main/ets/services/FocusedTestRegistrationAudit';
import {
  MOONLIGHT_LOCAL_RECORD_COLUMNS,
  MOONLIGHT_RECORD_COLUMNS
} from '../main/ets/model/MoonlightRecord';
import {
  cloudTableColumns,
  moonlightCloudRowHasExactColumns,
  normalizeMoonlightCloudRowExact,
  projectMoonlightLocalRowForCloud
} from '../main/ets/services/CloudTableAdapter';

function exactCloudRow(): Record<string, string> {
  const row: Record<string, string> = {};
  for (let i = 0; i < MOONLIGHT_RECORD_COLUMNS.length; i++) {
    row[MOONLIGHT_RECORD_COLUMNS[i]] = 'value-' + i.toString();
  }
  return row;
}

function exactLocalRow(localOnly: string): Record<string, string> {
  const row: Record<string, string> = exactCloudRow();
  row['localonly'] = localOnly;
  return row;
}

export default function moonlightCloudTableAdapterTest(): void {
  describe('MoonlightCloudTableAdapter', (): void => {
    it('exposes_the_exact_19_columns_in_order', 0, (): void => {
      const actual: string[] = cloudTableColumns('moonlightrecordv1');
      expect(actual.length).assertEqual(MOONLIGHT_RECORD_COLUMNS.length);
      for (let i = 0; i < actual.length; i++) {
        expect(actual[i]).assertEqual(MOONLIGHT_RECORD_COLUMNS[i]);
      }
    });

    it('round_trips_an_exact_cloud_envelope_without_interpreting_payload', 0, (): void => {
      const row: Record<string, string> = exactCloudRow();
      const normalized: Record<string, string> | null =
        normalizeMoonlightCloudRowExact(row);
      expect(normalized === null).assertFalse();
      expect((normalized as Record<string, string>)['payload'])
        .assertEqual(row['payload']);
      expect(Object.keys(normalized as Record<string, string>).length)
        .assertEqual(19);
    });

    it('rejects_missing_and_unknown_cloud_columns', 0, (): void => {
      const missing: Record<string, string> = exactCloudRow();
      delete missing['deletedat'];
      expect(moonlightCloudRowHasExactColumns(missing)).assertFalse();
      expect(normalizeMoonlightCloudRowExact(missing) === null).assertTrue();
      const extra: Record<string, string> = exactCloudRow();
      extra['mutationid'] = 'must-live-in-payload-meta';
      expect(moonlightCloudRowHasExactColumns(extra)).assertFalse();
      expect(normalizeMoonlightCloudRowExact(extra) === null).assertTrue();
    });

    it('projects_only_explicitly_cloud_eligible_local_rows', 0, (): void => {
      expect(MOONLIGHT_LOCAL_RECORD_COLUMNS.length).assertEqual(20);
      expect(projectMoonlightLocalRowForCloud(exactLocalRow('1')) === null)
        .assertTrue();
      const projected: Record<string, string> | null =
        projectMoonlightLocalRowForCloud(exactLocalRow('0'));
      expect(projected === null).assertFalse();
      expect(Object.keys(projected as Record<string, string>).length)
        .assertEqual(19);
      const malformed: Record<string, string> = exactLocalRow('0');
      malformed['extra'] = 'no';
      expect(projectMoonlightLocalRowForCloud(malformed) === null).assertTrue();
    });
  });
}
