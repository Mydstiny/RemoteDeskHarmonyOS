import { describe, it, expect } from '@ohos/hypium';
import { cloudSyncDetailSpec } from '../main/ets/services/CloudSyncGuidancePolicy';

export default function cloudSyncGuidancePolicyTest(): void {
  describe('CloudSyncGuidancePolicy', (): void => {
    it('describes_ready_cloud_without_claiming_system_switch_state', 0, (): void => {
      const detail = cloudSyncDetailSpec(true);
      expect(detail.statusAvailable).assertTrue();
      expect(detail.statusText).assertEqual('应用端云数据库已就绪');
      expect(detail.prerequisites.length).assertEqual(4);
    });

    it('describes_unavailable_cloud_as_an_app_connection_state', 0, (): void => {
      const detail = cloudSyncDetailSpec(false);
      expect(detail.statusAvailable).assertFalse();
      expect(detail.statusText).assertEqual('应用暂未建立端云连接，请检查使用条件');
      expect(detail.statusText.indexOf('已关闭')).assertEqual(-1);
    });

    it('lists_the_required_cloud_sync_prerequisites_in_order', 0, (): void => {
      const prerequisites: string[] = cloudSyncDetailSpec(true).prerequisites;
      expect(prerequisites[0]).assertEqual('登录与其他设备相同的华为账号');
      expect(prerequisites[1]).assertEqual('已开通华为云空间服务');
      expect(prerequisites[2]).assertEqual('系统设置中的云同步开关已打开');
      expect(prerequisites[3]).assertEqual('设备网络可用');
    });
  });
}
