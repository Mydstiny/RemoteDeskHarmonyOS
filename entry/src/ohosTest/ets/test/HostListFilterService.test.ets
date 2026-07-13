/**
 * HostListFilterService.test.ets - HostListPage list filtering rules (T-200)
 */
import { describe, it, expect } from '@ohos/hypium';
import { RemoteHost } from '../../../main/ets/model/RemoteHost';
import {
  filterHostsByProtocol,
  visibleHostsForHostListMode,
  searchHosts
} from '../../../main/ets/services/HostListFilterService';

function makeHost(id: string, label: string, host: string, protocol: string): RemoteHost {
  const item = new RemoteHost();
  item.id = id;
  item.label = label;
  item.host = host;
  item.protocol = protocol;
  return item;
}

export default function hostListFilterServiceTest(): void {
  describe('HostListFilterService', (): void => {
    it('search_should_match_label_or_host_case_insensitive', 0, (): void => {
      const hosts: RemoteHost[] = [
        makeHost('1', 'Office Windows', 'dorm.liups.net', 'rdp'),
        makeHost('2', 'Mac Studio', '47.116.203.64', 'rustdesk'),
        makeHost('3', 'Linux SSH', 'shell.example.com', 'ssh')
      ];

      expect(searchHosts(hosts, 'WINDOWS').length).assertEqual(1);
      expect(searchHosts(hosts, 'windows')[0].id).assertEqual('1');
      expect(searchHosts(hosts, '47.116')[0].id).assertEqual('2');
      expect(searchHosts(hosts, '').length).assertEqual(3);
    });

    it('protocol_filter_should_keep_matching_protocol_or_all_when_empty', 0, (): void => {
      const hosts: RemoteHost[] = [
        makeHost('1', 'Office Windows', 'dorm.liups.net', 'rdp'),
        makeHost('2', 'Mac Studio', '47.116.203.64', 'rustdesk'),
        makeHost('3', 'Linux SSH', 'shell.example.com', 'ssh')
      ];

      expect(filterHostsByProtocol(hosts, 'rdp').length).assertEqual(1);
      expect(filterHostsByProtocol(hosts, 'rdp')[0].id).assertEqual('1');
      expect(filterHostsByProtocol(hosts, 'ssh')[0].id).assertEqual('3');
      expect(filterHostsByProtocol(hosts, '').length).assertEqual(3);
    });

    it('visible_hosts_should_keep_first_saved_host_across_mobile_and_pc_filters', 0, (): void => {
      const hosts: RemoteHost[] = [
        makeHost('1', 'Office Windows', 'dorm.liups.net', 'rdp'),
        makeHost('2', 'Mac Studio', '47.116.203.64', 'rustdesk')
      ];

      expect(visibleHostsForHostListMode(hosts, '', false, 'sm', '', 0).length).assertEqual(2);
      expect(visibleHostsForHostListMode(hosts, '', true, 'xl', '', 0)[0].id).assertEqual('1');
      expect(visibleHostsForHostListMode(hosts, '', true, 'xl', '', 1)[0].id).assertEqual('2');
      expect(visibleHostsForHostListMode(hosts, 'studio', true, 'xl', '', 1)[0].id).assertEqual('2');
      expect(visibleHostsForHostListMode(hosts, 'studio', true, 'xl', '', 0).length).assertEqual(0);
    });
  });
}
