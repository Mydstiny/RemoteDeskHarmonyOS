import { describe, expect, it } from '@ohos/hypium';
import {
  rustDeskRelayHealthAddress,
  rustDeskRelayHealthFamilies
} from '../main/ets/services/RustDeskRelayHealthPolicy';

export default function rustDeskRelayHealthPolicyTest(): void {
  describe('RustDeskRelayHealthPolicy', (): void => {
    it('tries both families for a DNS hostname', 0, (): void => {
      expect(rustDeskRelayHealthFamilies('relay.example.com')).assertDeepEquals([2, 1]);
      expect(rustDeskRelayHealthFamilies('RELAY.EXAMPLE.COM.')).assertDeepEquals([2, 1]);
    });

    it('keeps the family of an IPv4 or IPv6 literal', 0, (): void => {
      expect(rustDeskRelayHealthFamilies('192.0.2.20')).assertDeepEquals([1]);
      expect(rustDeskRelayHealthFamilies('2001:db8::20')).assertDeepEquals([2]);
    });

    it('connects to an unbracketed IPv6 literal and keeps hostnames unchanged', 0, (): void => {
      expect(rustDeskRelayHealthAddress('[2001:db8::20]')).assertEqual('2001:db8::20');
      expect(rustDeskRelayHealthAddress('2001:db8::20')).assertEqual('2001:db8::20');
      expect(rustDeskRelayHealthAddress('192.0.2.20')).assertEqual('192.0.2.20');
      expect(rustDeskRelayHealthAddress('relay.example.com')).assertEqual('relay.example.com');
    });

    it('falls back to both families for invalid imported data', 0, (): void => {
      expect(rustDeskRelayHealthFamilies('https://relay.example.com/path'))
        .assertDeepEquals([2, 1]);
    });
  });
}
