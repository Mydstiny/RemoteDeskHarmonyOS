import { describe, it, expect } from '@ohos/hypium';
import {
  cloudServiceGuidanceRequiredForMessage,
  rdbInsertSucceeded,
  rdbSingleRowAffected
} from '../main/ets/services/CloudStoreMutationPolicy';

export default function cloudStoreMutationPolicyTest(): void {
  describe('CloudStoreMutationPolicy', (): void => {
    it('rejects_a_failed_insert_row_id', 0, (): void => {
      expect(rdbInsertSucceeded(-1)).assertFalse();
      expect(rdbInsertSucceeded(12)).assertTrue();
    });

    it('requires_exactly_one_row_for_id_addressed_mutations', 0, (): void => {
      expect(rdbSingleRowAffected(0)).assertFalse();
      expect(rdbSingleRowAffected(1)).assertTrue();
      expect(rdbSingleRowAffected(2)).assertFalse();
    });

    it('does_not_treat_a_regular_network_error_as_huawei_cloud_service_disabled', 0, (): void => {
      expect(cloudServiceGuidanceRequiredForMessage('network timeout')).assertFalse();
      expect(cloudServiceGuidanceRequiredForMessage('Cloud Space not enabled')).assertTrue();
    });
  });
}
