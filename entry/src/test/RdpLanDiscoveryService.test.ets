import { describe, it, expect } from '@ohos/hypium';
import {
  DiscoveredRdpHost,
  rdpLanCandidateAddresses,
  rdpLanProbeRecognized,
  resolveRdpLanIdentityAmbiguity
} from '../main/ets/services/RdpLanDiscoveryService';

export default function rdpLanDiscoveryServiceTest() {
  describe('RdpLanDiscoveryService_Subnet', () => {
    it('scans the entered host local subnet without self network or broadcast', 0, () => {
      const values: string[] = rdpLanCandidateAddresses('192.168.10.20', 24);
      expect(values.length).assertEqual(253);
      expect(values.indexOf('192.168.10.20')).assertEqual(-1);
      expect(values.indexOf('192.168.10.0')).assertEqual(-1);
      expect(values.indexOf('192.168.10.255')).assertEqual(-1);
      expect(values.indexOf('192.168.10.21') >= 0).assertTrue();
    });

    it('bounds broad prefixes to the local slash24', 0, () => {
      const values: string[] = rdpLanCandidateAddresses('10.20.30.40', 8);
      expect(values.length).assertEqual(253);
      expect(values.indexOf('10.20.30.41') >= 0).assertTrue();
      expect(values.indexOf('10.20.31.1')).assertEqual(-1);
    });

    it('honors a narrower subnet and rejects invalid addresses', 0, () => {
      const values: string[] = rdpLanCandidateAddresses('192.168.1.130', 25);
      expect(values.length).assertEqual(125);
      expect(values[0]).assertEqual('192.168.1.129');
      expect(rdpLanCandidateAddresses('not-an-ip', 24).length).assertEqual(0);
      expect(rdpLanCandidateAddresses('203.0.113.8', 24).length).assertEqual(0);
      expect(rdpLanCandidateAddresses('fe80::20', 64).length).assertEqual(0);
      expect(rdpLanCandidateAddresses('2001:db8::20', 64).length).assertEqual(0);
    });
  });

  describe('RdpLanDiscoveryService_Identity', () => {
    it('allows dynamic refresh only for a fingerprint with one address', 0, () => {
      const hosts: DiscoveredRdpHost[] = [
        {
          stableId: 'aa', deviceName: 'one', host: '192.168.1.10', port: 3389,
          fingerprintSha256: 'AA', dynamicCapable: true
        },
        {
          stableId: 'aa', deviceName: 'two', host: '192.168.1.11', port: 3389,
          fingerprintSha256: 'aa', dynamicCapable: true
        },
        {
          stableId: 'bb', deviceName: 'three', host: '192.168.1.12', port: 3389,
          fingerprintSha256: 'BB', dynamicCapable: true
        }
      ];
      const resolved: DiscoveredRdpHost[] = resolveRdpLanIdentityAmbiguity(hosts);
      expect(resolved[0].dynamicCapable).assertFalse();
      expect(resolved[1].dynamicCapable).assertFalse();
      expect(resolved[0].stableId === resolved[1].stableId).assertFalse();
      expect(resolved[2].dynamicCapable).assertTrue();
      expect(resolved[2].stableId).assertEqual('bb');
    });

    it('rejects open non-RDP ports and accepts Standard RDP Security', 0, () => {
      expect(rdpLanProbeRecognized('completed', 0)).assertTrue();
      expect(rdpLanProbeRecognized('inconclusive', -18)).assertTrue();
      expect(rdpLanProbeRecognized('inconclusive', -19)).assertFalse();
      expect(rdpLanProbeRecognized('inconclusive', -20)).assertFalse();
      expect(rdpLanProbeRecognized('inconclusive', -21)).assertFalse();
      expect(rdpLanProbeRecognized('inconclusive', -22)).assertFalse();
      expect(rdpLanProbeRecognized('unavailable', -18)).assertFalse();
    });
  });
}
