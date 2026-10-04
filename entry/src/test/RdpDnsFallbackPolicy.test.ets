import { describe, it, expect } from '@ohos/hypium';
import {
  normalizeRdpDnsCandidate,
  rdpDnsFallbackCandidates,
  rdpDnsFallbackEligible,
  rdpDnsFallbackShouldEnumerate,
  rdpDnsFallbackProbeCanReuseTransport
} from '../main/ets/services/RdpDnsFallbackPolicy';

export default function rdpDnsFallbackPolicyTest() {
  describe('RdpDnsFallbackPolicy', (): void => {
    it('keeps_only_numeric_runtime_candidates', 0, (): void => {
      expect(normalizeRdpDnsCandidate('192.0.2.10')).assertEqual('192.0.2.10');
      expect(normalizeRdpDnsCandidate('[2001:db8::10]')).assertEqual('2001:db8::10');
      expect(normalizeRdpDnsCandidate('rdp.example.test')).assertEqual('');
    });

    it('deduplicates_and_bounds_candidates', 0, (): void => {
      expect(rdpDnsFallbackCandidates([
        '192.0.2.10', '192.0.2.10', 'rdp.example.test',
        '2001:db8::10', '192.0.2.11'
      ], 2)).assertDeepEquals(['192.0.2.10', '2001:db8::10']);
    });

    it('allows_fallback_only_for_hostname_direct_routes', 0, (): void => {
      expect(rdpDnsFallbackEligible('rdp.example.test', -11, 'direct_rdp')).assertTrue();
      expect(rdpDnsFallbackEligible('rdp.example.test', -11, 'transparent_tcp_rdp')).assertTrue();
      expect(rdpDnsFallbackEligible('192.0.2.10', -11, 'direct_rdp')).assertFalse();
      expect(rdpDnsFallbackEligible('rdp.example.test', -12, 'direct_rdp')).assertFalse();
      expect(rdpDnsFallbackEligible('rdp.example.test', -11, 'microsoft_rd_gateway')).assertFalse();
    });

    it('enumerates_hostname_routes_even_when_native_probe_did_not_fail_dns', 0, (): void => {
      expect(rdpDnsFallbackShouldEnumerate('rdp.example.test', 'direct_rdp')).assertTrue();
      expect(rdpDnsFallbackShouldEnumerate('rdp.example.test', 'transparent_tcp_rdp')).assertTrue();
      expect(rdpDnsFallbackShouldEnumerate('192.0.2.10', 'direct_rdp')).assertFalse();
      expect(rdpDnsFallbackShouldEnumerate('rdp.example.test', 'microsoft_rd_gateway')).assertFalse();
    });

    it('reuses_a_candidate_only_after_tcp_reached_the_service', 0, (): void => {
      expect(rdpDnsFallbackProbeCanReuseTransport(-18)).assertTrue();
      expect(rdpDnsFallbackProbeCanReuseTransport(-25)).assertTrue();
      expect(rdpDnsFallbackProbeCanReuseTransport(-11)).assertFalse();
      expect(rdpDnsFallbackProbeCanReuseTransport(-12)).assertFalse();
      expect(rdpDnsFallbackProbeCanReuseTransport(-39)).assertFalse();
    });
  });
}
