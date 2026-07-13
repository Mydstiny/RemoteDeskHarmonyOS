import { describe, it, expect } from '@ohos/hypium';
import { ConnectionHealth, RemoteHost } from '../main/ets/model/RemoteHost';
import {
  displayConnectionHealth,
  filterHostsByWorkspace,
  nextWorkspaceGroupId,
  searchHosts
} from '../main/ets/services/HostWorkspacePolicy';

function host(id: string, label: string): RemoteHost {
  const value = new RemoteHost();
  value.id = id;
  value.label = label;
  value.host = id + '.example.test';
  value.username = 'operator';
  return value;
}

export default function hostWorkspacePolicyTest(): void {
  describe('HostWorkspacePolicy', (): void => {
    it('workspace_filter_should_use_normalized_group_ids', 0, (): void => {
      const first = host('first', 'First');
      first.groupId = 'Ops Team';
      const second = host('second', 'Second');
      second.groupId = 'ops-team';
      expect(filterHostsByWorkspace([first, second, host('third', 'Third')], 'ops team').length).assertEqual(2);
    });

    it('workspace_filter_should_keep_source_order', 0, (): void => {
      const first = host('first', 'First');
      const second = host('second', 'Second');
      first.groupId = 'ops';
      second.groupId = 'ops';
      const result = filterHostsByWorkspace([second, first], 'ops');
      expect(result[0].id).assertEqual('second');
      expect(result[1].id).assertEqual('first');
    });

    it('search_should_include_username_without_searching_credentials', 0, (): void => {
      const userMatch = host('user-match', 'Server');
      userMatch.username = 'admin';
      userMatch.password = 'admin-secret';
      expect(searchHosts([userMatch, host('other', 'Other')], 'admin')[0].id).assertEqual('user-match');
      expect(searchHosts([userMatch], 'secret').length).assertEqual(0);
    });

    it('excellent_health_should_show_normal_connection_and_latency', 0, (): void => {
      expect(displayConnectionHealth(ConnectionHealth.EXCELLENT, 34)).assertEqual('连接正常 · 34 ms');
    });

    it('unknown_health_should_not_render_a_misleading_status', 0, (): void => {
      expect(displayConnectionHealth(ConnectionHealth.UNKNOWN, 0)).assertEqual('');
      expect(displayConnectionHealth(ConnectionHealth.UNKNOWN, 48)).assertEqual('');
    });

    it('workspace_group_tap_should_toggle_the_active_group_off', 0, (): void => {
      expect(nextWorkspaceGroupId('', 'ops')).assertEqual('ops');
      expect(nextWorkspaceGroupId('ops', 'ops')).assertEqual('');
      expect(nextWorkspaceGroupId('ops-team', 'Ops Team')).assertEqual('');
      expect(nextWorkspaceGroupId('ops', 'design')).assertEqual('design');
    });
  });
}
