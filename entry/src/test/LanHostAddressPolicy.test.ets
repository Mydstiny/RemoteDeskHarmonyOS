import { describe, it, expect } from '@ohos/hypium';
import {
  lanHostCanSelectDynamic,
  lanHostLocalOnlyStorageIsValid,
  lanLocalExtensionMayEnterPortableBackup,
  lanRestrictedAdminSecretOwnedByScope,
  lanHostMayUseRemoteHostsCloudTable,
  lanHostNeedsAddressRefresh,
  lanHostRefreshCandidateMatches,
  lanHostUsesDynamicAddressStorage,
  lanHostUsesLocalOnlyStorage,
  remoteHostEndpointIsDevicePrivateForTransfer,
  normalizeLanHostAddressMode
} from '../main/ets/services/LanHostAddressPolicy';

export default function lanHostAddressPolicyTest() {
  describe('LanHostAddressPolicy', () => {
    it('keeps legacy and manual records on the existing cloud path', 0, () => {
      expect(normalizeLanHostAddressMode(undefined)).assertEqual('manual');
      expect(lanHostMayUseRemoteHostsCloudTable({
        protocol: 'rdp', host: '10.0.0.1', lanAddressMode: 'manual',
        lanDiscoveryIdentity: '', lanLastResolvedAt: 0
      })).assertTrue();
      expect(lanHostMayUseRemoteHostsCloudTable({
        protocol: 'rustdesk', host: '10.0.0.2', lanAddressMode: 'static',
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
        protocol: 'rdp', host: '192.168.1.20', lanAddressMode: 'dynamic',
        lanDiscoveryIdentity: 'AA:BB', lanLastResolvedAt: 1000
      };
      expect(lanHostNeedsAddressRefresh(dynamic, 2000, 1000)).assertTrue();
      expect(lanHostNeedsAddressRefresh(dynamic, 1999, 1000)).assertFalse();
      expect(lanHostMayUseRemoteHostsCloudTable(dynamic)).assertFalse();
    });

    it('matches refreshes by exact normalized identity and protocol', 0, () => {
      const host = {
        protocol: 'rustdesk', host: '192.168.1.20', lanAddressMode: 'dynamic',
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

    it('keeps_only_interface_scoped_ssh_endpoints_in_device_local_storage', 0,
      (): void => {
        const scoped = {
          protocol: 'ssh', host: 'fe80::20%wlan0', lanAddressMode: 'manual',
          lanDiscoveryIdentity: '', lanLastResolvedAt: 0
        };
        expect(lanHostUsesLocalOnlyStorage(scoped)).assertTrue();
        expect(lanHostUsesDynamicAddressStorage(scoped)).assertFalse();
        expect(lanHostLocalOnlyStorageIsValid(scoped)).assertTrue();
        expect(lanHostMayUseRemoteHostsCloudTable(scoped)).assertFalse();
        expect(lanHostNeedsAddressRefresh(scoped, 1000, 0)).assertFalse();

        const global = {
          protocol: 'ssh', host: '2001:db8::20', lanAddressMode: 'manual',
          lanDiscoveryIdentity: '', lanLastResolvedAt: 0
        };
        expect(lanHostUsesLocalOnlyStorage(global)).assertFalse();
        expect(lanHostMayUseRemoteHostsCloudTable(global)).assertTrue();
        expect(remoteHostEndpointIsDevicePrivateForTransfer(
          'ssh', 'fe80::20%12')).assertTrue();
        expect(remoteHostEndpointIsDevicePrivateForTransfer(
          'ssh', '[fe80::20%25wlan0]')).assertTrue();
        expect(remoteHostEndpointIsDevicePrivateForTransfer(
          'rdp', 'fe80::20%wlan0')).assertTrue();
      });

    it('keeps dynamic Restricted Admin secrets inside the active account', 0, () => {
      expect(lanRestrictedAdminSecretOwnedByScope(true, '', 'owner-a')).assertTrue();
      expect(lanRestrictedAdminSecretOwnedByScope(false, 'owner-a', 'owner-a')).assertTrue();
      expect(lanRestrictedAdminSecretOwnedByScope(false, 'owner-b', 'owner-a')).assertFalse();
      expect(lanRestrictedAdminSecretOwnedByScope(false, 'owner-a', '')).assertFalse();
    });
  });
}
