import { describe, it, expect } from '@ohos/hypium';
import {
  lanHostCanSelectDynamic,
  lanLocalExtensionMayEnterPortableBackup,
  lanRestrictedAdminSecretOwnedByScope,
  lanHostMayUseRemoteHostsCloudTable,
  lanHostNeedsAddressRefresh,
  lanHostRefreshCandidateMatches,
  normalizeLanHostAddressMode
} from '../main/ets/services/LanHostAddressPolicy';

export default function lanHostAddressPolicyTest() {
  describe('LanHostAddressPolicy', () => {
    it('keeps legacy and manual records on the existing cloud path', 0, () => {
      expect(normalizeLanHostAddressMode(undefined)).assertEqual('manual');
      expect(lanHostMayUseRemoteHostsCloudTable({
        protocol: 'rdp', lanAddressMode: 'manual', lanDiscoveryIdentity: '', lanLastResolvedAt: 0
      })).assertTrue();
      expect(lanHostMayUseRemoteHostsCloudTable({
        protocol: 'rustdesk', lanAddressMode: 'static',
        lanDiscoveryIdentity: 'peer-1', lanLastResolvedAt: 100
      })).assertTrue();
    });

    it('allows dynamic only with a stable RDP or RustDesk discovery identity', 0, () => {
      expect(lanHostCanSelectDynamic('rdp', 'AA:BB')).assertTrue();
      expect(lanHostCanSelectDynamic('rustdesk', '123456789')).assertTrue();
      expect(lanHostCanSelectDynamic('rdp', '   ')).assertFalse();
      expect(lanHostCanSelectDynamic('ssh', 'host-key')).assertFalse();
    });

    it('refreshes only stale device-local dynamic records', 0, () => {
      const dynamic = {
        protocol: 'rdp', lanAddressMode: 'dynamic',
        lanDiscoveryIdentity: 'AA:BB', lanLastResolvedAt: 1000
      };
      expect(lanHostNeedsAddressRefresh(dynamic, 2000, 1000)).assertTrue();
      expect(lanHostNeedsAddressRefresh(dynamic, 1999, 1000)).assertFalse();
      expect(lanHostMayUseRemoteHostsCloudTable(dynamic)).assertFalse();
    });

    it('matches refreshes by exact normalized identity and protocol', 0, () => {
      const host = {
        protocol: 'rustdesk', lanAddressMode: 'dynamic',
        lanDiscoveryIdentity: 'PEER-1', lanLastResolvedAt: 1
      };
      expect(lanHostRefreshCandidateMatches(host, {
        protocol: 'rustdesk', identity: 'PEER-1', host: '192.168.1.20',
        port: 21118, observedAt: 2
      })).assertTrue();
      expect(lanHostRefreshCandidateMatches(host, {
        protocol: 'rustdesk', identity: 'peer-1', host: '192.168.1.20',
        port: 21118, observedAt: 2
      })).assertFalse();
      expect(lanHostRefreshCandidateMatches(host, {
        protocol: 'rustdesk', identity: 'peer-2', host: '192.168.1.21',
        port: 21118, observedAt: 2
      })).assertFalse();
      expect(lanHostRefreshCandidateMatches(host, {
        protocol: 'rdp', identity: 'peer-1', host: '192.168.1.20',
        port: 3389, observedAt: 2
      })).assertFalse();
    });

    it('keeps dynamic LAN rows out of cloud and portable backup', 0, () => {
      expect(lanLocalExtensionMayEnterPortableBackup('dynamiclanhosts')).assertFalse();
      expect(lanLocalExtensionMayEnterPortableBackup('remotehosts')).assertTrue();
    });

    it('keeps dynamic Restricted Admin secrets inside the active account', 0, () => {
      expect(lanRestrictedAdminSecretOwnedByScope(true, '', 'owner-a')).assertTrue();
      expect(lanRestrictedAdminSecretOwnedByScope(false, 'owner-a', 'owner-a')).assertTrue();
      expect(lanRestrictedAdminSecretOwnedByScope(false, 'owner-b', 'owner-a')).assertFalse();
      expect(lanRestrictedAdminSecretOwnedByScope(false, 'owner-a', '')).assertFalse();
    });
  });
}
