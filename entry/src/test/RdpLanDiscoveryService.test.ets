import { describe, it, expect } from '@ohos/hypium';
import { rdpLanCandidateAddresses } from '../main/ets/services/RdpLanDiscoveryService';

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
    });
  });
}
