/**
 * HostSyncService.test.ets - host list refresh notifications
 */
import { describe, it, expect } from '@ohos/hypium';
import { RemoteHost } from '../../../main/ets/model/RemoteHost';
import { HostSyncService } from '../../../main/ets/services/HostSyncService';

function makeHost(id: string): RemoteHost {
  const host = new RemoteHost();
  host.id = id;
  host.label = 'Listener Regression Host';
  host.protocol = 'rdp';
  host.host = '127.0.0.1';
  host.port = 3389;
  return host;
}

export default function hostSyncServiceTest(): void {
  describe('HostSyncService', (): void => {
    it('should_notify_registered_listener_when_hosts_change', 0, (): void => {
      const srv = HostSyncService.getInstance();
      const hostId = 'host-sync-listener-regression';
      let calls = 0;
      const unsubscribe = srv.onDataChange((): void => {
        calls++;
      });

      srv.removeHost(hostId);
      calls = 0;
      srv.addHost(makeHost(hostId));

      expect(calls).assertEqual(1);

      unsubscribe();
      srv.removeHost(hostId);
    });
  });
}
