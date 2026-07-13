import { describe, it, expect } from '@ohos/hypium';
import { ConnectionHealth } from '../../../main/ets/model/RemoteHost';
import {
  displayConnectionHealth,
  nextWorkspaceGroupId
} from '../../../main/ets/services/HostWorkspacePolicy';

export default function hostWorkspacePolicyTest(): void {
  describe('HostWorkspacePolicy', (): void => {
    it('unknown_health_should_not_render_a_misleading_status', 0, (): void => {
      expect(displayConnectionHealth(ConnectionHealth.UNKNOWN, 0)).assertEqual('');
      expect(displayConnectionHealth(ConnectionHealth.UNKNOWN, 48)).assertEqual('');
    });

    it('workspace_group_tap_should_toggle_the_active_group_off', 0, (): void => {
      expect(nextWorkspaceGroupId('', 'ops')).assertEqual('ops');
      expect(nextWorkspaceGroupId('ops', 'ops')).assertEqual('');
      expect(nextWorkspaceGroupId('ops-team', 'Ops Team')).assertEqual('');
    });
  });
}
