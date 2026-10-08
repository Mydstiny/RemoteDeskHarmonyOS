import { describe, it, expect } from '@ohos/hypium';
import {
  CLOUD_SYNC_SHEET_ACTIONS,
  CLOUD_SYNC_SHEET_BACKUP_CONFIRM,
  CLOUD_SYNC_SHEET_DETAILS,
  CLOUD_SYNC_SHEET_DOWNLOAD_CONFIRM,
  CLOUD_SYNC_SHEET_RESTORE_CONFIRM,
  CLOUD_SYNC_SHEET_UNAVAILABLE,
  CLOUD_SYNC_SHEET_UPLOAD_CONFIRM,
  cloudSyncCryptoParamsDescription,
  cloudSyncManageTablesHint,
  cloudSyncSheetSpec,
  cloudSyncTableDescription,
  cloudSyncTableProtectionLabel,
  masterPasswordStatusText
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
      expect(spec.message.indexOf('VNC') >= 0).assertTrue();
      expect(spec.primaryLabel).assertEqual('覆盖并上传');
      expect(spec.primaryDestructive).assertTrue();
      expect(spec.secondaryLabel).assertEqual('返回');
      expect(spec.canDismiss).assertTrue();
    });

    it('makes_local_replacement_a_danger_action_with_a_safe_back_path', 0, (): void => {
      const spec = cloudSyncSheetSpec(CLOUD_SYNC_SHEET_DOWNLOAD_CONFIRM);
      expect(spec.title).assertEqual('覆盖本地数据？');
      expect(spec.message.indexOf('VNC') >= 0).assertTrue();
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

    it('describes_v3_backup_as_redacted_and_non_destructive', 0, (): void => {
      const spec = cloudSyncSheetSpec(
        CLOUD_SYNC_SHEET_BACKUP_CONFIRM);
      expect(spec.title).assertEqual('导出本地备份？');
      expect(spec.message.indexOf('v3') >= 0).assertTrue();
      expect(spec.message.indexOf('本地数据作用域') >= 0).assertTrue();
      expect(spec.message.indexOf('本机离线作用域') >= 0).assertTrue();
      expect(spec.message.indexOf('密码') >= 0).assertTrue();
      expect(spec.message.indexOf('设备信任') >= 0).assertTrue();
      expect(spec.primaryDestructive).assertFalse();
      expect(spec.canDismiss).assertTrue();
    });

    it('describes_restore_as_a_missing_field_safe_merge', 0, (): void => {
      const spec = cloudSyncSheetSpec(
        CLOUD_SYNC_SHEET_RESTORE_CONFIRM);
      expect(spec.title).assertEqual('合并本地配置？');
      expect(spec.message.indexOf('缺表') >= 0).assertTrue();
      expect(spec.message.indexOf('不会清空') >= 0).assertTrue();
      expect(spec.message.indexOf('不会自动上传') >= 0)
        .assertTrue();
      expect(spec.primaryDestructive).assertFalse();
    });

    it('never_calls_secrets_end_to_end_encrypted_without_a_master_password', 0, (): void => {
      const secretTables: string[] = [
        'remotehosts', 'rdpcredentials', 'rustdeskrelays', 'sshkeys', 'totpentries'
      ];
      for (let i = 0; i < secretTables.length; i++) {
        expect(cloudSyncTableProtectionLabel(secretTables[i], false)).assertEqual('云空间加密');
        expect(cloudSyncTableProtectionLabel(secretTables[i], true)).assertEqual('机密端到端加密');
        expect(cloudSyncTableDescription(secretTables[i], false).indexOf('未做端到端加密') >= 0)
          .assertTrue();
        expect(cloudSyncTableDescription(secretTables[i], false).indexOf('自动同步加密参数') < 0)
          .assertTrue();
      }
      expect(cloudSyncTableProtectionLabel('usersettings', false)).assertEqual('');
      expect(cloudSyncTableDescription('remotehosts', true).indexOf('端到端加密') >= 0).assertTrue();
      expect(cloudSyncManageTablesHint(false).indexOf('未做端到端加密') >= 0).assertTrue();
      expect(cloudSyncManageTablesHint(false).indexOf('自动保护') < 0).assertTrue();
      expect(cloudSyncManageTablesHint(true).indexOf('端到端加密') >= 0).assertTrue();
      expect(cloudSyncCryptoParamsDescription(false).indexOf('未设置主密码') >= 0).assertTrue();
      expect(masterPasswordStatusText(false, false).indexOf('设置后') >= 0).assertTrue();
      expect(masterPasswordStatusText(true, true).indexOf('数据已端到端加密') < 0).assertTrue();
      expect(masterPasswordStatusText(true, false).indexOf('已锁定') >= 0).assertTrue();
    });

    it('keeps_unencrypted_vnc_passwords_described_as_device_only', 0, (): void => {
      // plain_explicit_v1 VNC secrets are forced into vnclocalrecords and
      // never uploaded, so the table gets no cloud-encryption badge.
      expect(cloudSyncTableProtectionLabel('vncrecordv2', false)).assertEqual('');
      expect(cloudSyncTableDescription('vncrecordv2', false).indexOf('只保存在本机') >= 0).assertTrue();
      expect(cloudSyncTableDescription('vncrecordv2', false).indexOf('未做端到端加密') < 0).assertTrue();
      expect(cloudSyncTableProtectionLabel('vncrecordv2', true)).assertEqual('机密端到端加密');
    });
  });
}
