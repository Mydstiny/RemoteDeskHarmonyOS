import { describe, it, expect } from '@ohos/hypium';
import {
  normalizeRdpDnsCandidate,
  rdpDnsFallbackCandidates,
  rdpDnsFallbackEligible,
  rdpDnsFallbackShouldEnumerate,
  rdpDnsFallbackProbeCanReuseTransport,
  rdpDnsFallbackNeedsResolution,
  rdpLocalNameEligible,
  rdpSearchDomainNames
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

    it('asks_the_local_network_only_for_computer_names_and_dot_local', 0, (): void => {
      expect(rdpLocalNameEligible('DESKTOP-1A2B3C')).assertTrue();
      expect(rdpLocalNameEligible('office-pc.')).assertTrue();
      expect(rdpLocalNameEligible('Office-PC.local')).assertTrue();
      expect(rdpLocalNameEligible('rdp.example.test')).assertFalse();
      expect(rdpLocalNameEligible('192.168.1.2')).assertFalse();
      expect(rdpLocalNameEligible('12345')).assertFalse();
      expect(rdpLocalNameEligible('-bad')).assertFalse();
      expect(rdpLocalNameEligible('has space')).assertFalse();
    });

    it('applies_network_search_suffixes_to_computer_names', 0, (): void => {
      expect(rdpSearchDomainNames('office-pc', 'lan corp.example.com,lan; .home.')).assertDeepEquals(
        ['office-pc.lan', 'office-pc.corp.example.com', 'office-pc.home']);
      expect(rdpSearchDomainNames('pc.example.com', 'lan')).assertDeepEquals([]);
      expect(rdpSearchDomainNames('pc', '')).assertDeepEquals([]);
      expect(rdpSearchDomainNames('pc', 'a b c d')).assertDeepEquals(['pc.a', 'pc.b', 'pc.c']);
      expect(rdpSearchDomainNames('pc', 'bad/suffix')).assertDeepEquals([]);
    });

    it('resolves_again_only_when_the_name_or_its_addresses_failed', 0, (): void => {
      expect(rdpDnsFallbackNeedsResolution(-11)).assertTrue();
      expect(rdpDnsFallbackNeedsResolution(-12)).assertTrue();
      expect(rdpDnsFallbackNeedsResolution(-22)).assertFalse();
      expect(rdpDnsFallbackNeedsResolution(0)).assertFalse();
    });
  });
}
