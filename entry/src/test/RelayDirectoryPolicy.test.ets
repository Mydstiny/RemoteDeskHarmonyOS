import { describe, it, expect } from '@ohos/hypium';
import { relayDirectoryEntry, relayDirectoryMatchesFilter, relayDirectoryOwner } from
  '../main/ets/services/RelayDirectoryPolicy';

export default function relayDirectoryPolicyTest(): void {
  describe('RelayDirectoryPolicy', (): void => {
    it('filters_protocols_without_mixing_owners', 0, (): void => {
      expect(relayDirectoryMatchesFilter('rustdesk', 'vnc')).assertFalse();
      expect(relayDirectoryMatchesFilter('vnc', 'all')).assertTrue();
      expect(relayDirectoryOwner('vnc')).assertEqual('VncGatewayService/vncrecord');
      expect(relayDirectoryOwner('rustdesk')).assertEqual('HostSyncService/rustdeskrelays');
    });

    it('keeps_gateway_entry_non_sensitive_and_read_only', 0, (): void => {
      const entry = relayDirectoryEntry('vnc', 'gateway-1', 'Office', 'relay.example.com:5901',
        '/vnc', true, '可用');
      expect(entry.kind).assertEqual('vnc');
      expect(entry.owner).assertEqual('VncGatewayService/vncrecord');
      expect(entry.endpoint.includes('token')).assertFalse();
    });
  });
}
