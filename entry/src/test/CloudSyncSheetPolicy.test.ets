import { describe, it, expect } from '@ohos/hypium';
import {
  CLOUD_SYNC_SHEET_ACTIONS,
  CLOUD_SYNC_SHEET_DETAILS,
  CLOUD_SYNC_SHEET_DOWNLOAD_CONFIRM,
  CLOUD_SYNC_SHEET_UNAVAILABLE,
  CLOUD_SYNC_SHEET_UPLOAD_CONFIRM,
  cloudSyncSheetSpec
} from '../main/ets/services/CloudSyncSheetPolicy';

export default function cloudSyncSheetPolicyTest() {
  describe('CloudSyncSheetPolicy', (): void => {
    it('offers_two_explicit_actions_before_any_destructive_confirmation', 0, (): void => {
      const spec = cloudSyncSheetSpec(CLOUD_SYNC_SHEET_ACTIONS);
      expect(spec.primaryLabel).assertEqual('上传当前设备所有信息到云端');
      expect(spec.secondaryLabel).assertEqual('下载云端数据到本地');
      expect(spec.primaryDestructive).assertFalse();
      expect(spec.secondaryDestructive).assertTrue();
      expect(spec.canDismiss).assertTrue();
    });

    it('makes_cloud_replacement_a_danger_action_with_a_safe_back_path', 0, (): void => {
      const spec = cloudSyncSheetSpec(CLOUD_SYNC_SHEET_UPLOAD_CONFIRM);
      expect(spec.title).assertEqual('覆盖云端存档？');
      expect(spec.primaryLabel).assertEqual('覆盖并上传');
      expect(spec.primaryDestructive).assertTrue();
      expect(spec.secondaryLabel).assertEqual('返回');
      expect(spec.canDismiss).assertTrue();
    });

    it('makes_local_replacement_a_danger_action_with_a_safe_back_path', 0, (): void => {
      const spec = cloudSyncSheetSpec(CLOUD_SYNC_SHEET_DOWNLOAD_CONFIRM);
      expect(spec.title).assertEqual('覆盖本地数据？');
      expect(spec.primaryLabel).assertEqual('覆盖并下载');
      expect(spec.primaryDestructive).assertTrue();
      expect(spec.secondaryLabel).assertEqual('返回');
    });

    it('shows_huawei_cloud_space_and_system_sync_guidance_when_service_is_unavailable', 0, (): void => {
      const spec = cloudSyncSheetSpec(CLOUD_SYNC_SHEET_UNAVAILABLE);
      expect(spec.title).assertEqual('云同步暂不可用');
      expect(spec.message.indexOf('华为云空间') >= 0).assertTrue();
      expect(spec.message.indexOf('云同步') >= 0).assertTrue();
      expect(spec.primaryLabel).assertEqual('我知道了');
      expect(spec.canDismiss).assertTrue();
    });

    it('provides_a_dismissible_read_only_cloud_sync_detail_sheet', 0, (): void => {
      const spec = cloudSyncSheetSpec(CLOUD_SYNC_SHEET_DETAILS);
      expect(spec.title).assertEqual('云同步详情');
      expect(spec.message).assertEqual('查看云同步正常使用所需的条件。');
      expect(spec.primaryLabel).assertEqual('');
      expect(spec.secondaryLabel).assertEqual('');
      expect(spec.primaryDestructive).assertFalse();
      expect(spec.secondaryDestructive).assertFalse();
      expect(spec.canDismiss).assertTrue();
    });
  });
}
