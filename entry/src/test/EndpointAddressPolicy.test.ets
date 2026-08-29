import { describe, expect, it } from '@ohos/hypium';
import {
  endpointIdentityV2,
  EndpointAddressResult,
  endpointTransportHost,
  formatEndpointHostPort,
  parseEndpointAuthority,
  parseEndpointHost
} from '../main/ets/services/EndpointAddressPolicy';

export default function endpointAddressPolicyTest(): void {
  describe('EndpointAddressPolicy', (): void => {
    it('canonicalizes_ascii_dns_ipv4_and_root_dot_without_resolving', 0, (): void => {
      const dns: EndpointAddressResult = parseEndpointHost('RDP.Office.Example.COM.');
      expect(dns.ok).assertTrue();
      expect(dns.endpoint.family).assertEqual('hostname');
      expect(dns.endpoint.canonicalHost).assertEqual('rdp.office.example.com');

      const ipv4: EndpointAddressResult = parseEndpointHost('192.168.31.177');
      expect(ipv4.ok).assertTrue();
      expect(ipv4.endpoint.family).assertEqual('ipv4');
      expect(ipv4.endpoint.canonicalHost).assertEqual('192.168.31.177');

      expect(parseEndpointHost('192.168.031.177').error).assertEqual('invalid_ipv4');
      expect(parseEndpointHost('主机.example').error).assertEqual('invalid_hostname');
    });

    it('canonicalizes_ipv6_with_rfc5952_first_longest_zero_run', 0, (): void => {
      const parsed: EndpointAddressResult =
        parseEndpointHost('[2001:0DB8:0000:0000:0001:0000:0000:0001]');
      expect(parsed.ok).assertTrue();
      expect(parsed.endpoint.family).assertEqual('ipv6');
      expect(parsed.endpoint.canonicalHost).assertEqual('2001:db8::1:0:0:1');

      const loopback: EndpointAddressResult = parseEndpointHost('0:0:0:0:0:0:0:1');
      expect(loopback.ok).assertTrue();
      expect(loopback.endpoint.canonicalHost).assertEqual('::1');
    });

    it('keeps_link_local_scope_separate_and_rejects_nonportable_scope', 0, (): void => {
      const scoped: EndpointAddressResult = parseEndpointHost('fe80::20%wlan0');
      expect(scoped.ok).assertTrue();
      expect(scoped.endpoint.canonicalHost).assertEqual('fe80::20');
      expect(scoped.endpoint.scope).assertEqual('wlan0');
      expect(endpointTransportHost(scoped.endpoint)).assertEqual('fe80::20%wlan0');

      expect(parseEndpointHost('fe80::20').error).assertEqual('scope_required');
      expect(parseEndpointHost('fe80::20%3').error).assertEqual('scope_not_portable');
      expect(parseEndpointHost('2001:db8::20%wlan0').error).assertEqual('scope_not_allowed');
    });

    it('rejects_nonconnectable_or_ambiguous_literal_forms', 0, (): void => {
      expect(parseEndpointHost('::').error).assertEqual('address_not_connectable');
      expect(parseEndpointHost('ff02::1%wlan0').error).assertEqual('address_not_connectable');
      expect(parseEndpointHost('::ffff:192.0.2.20').error).assertEqual('address_not_connectable');
      expect(parseEndpointHost(':::1').error).assertEqual('invalid_ipv6');
      expect(parseEndpointHost('rdp.example:3389').error).assertEqual('invalid_ipv6');
      expect(parseEndpointHost('https://rdp.example').error).assertEqual('invalid_syntax');
      expect(parseEndpointHost('user@rdp.example').error).assertEqual('invalid_syntax');
    });

    it('parses_authority_with_separate_port_and_brackets_ipv6_only_on_output', 0,
      (): void => {
        const ipv6: EndpointAddressResult = parseEndpointAuthority('[2001:db8::20]:3390', 3389);
        expect(ipv6.ok).assertTrue();
        expect(ipv6.endpoint.canonicalHost).assertEqual('2001:db8::20');
        expect(ipv6.endpoint.port).assertEqual(3390);
        expect(formatEndpointHostPort(ipv6.endpoint)).assertEqual('[2001:db8::20]:3390');

        const raw: EndpointAddressResult = parseEndpointAuthority('2001:db8::20', 3389);
        expect(raw.ok).assertTrue();
        expect(formatEndpointHostPort(raw.endpoint)).assertEqual('[2001:db8::20]:3389');

        const dns: EndpointAddressResult = parseEndpointAuthority('RDP.EXAMPLE.:3391', 3389);
        expect(dns.ok).assertTrue();
        expect(formatEndpointHostPort(dns.endpoint)).assertEqual('rdp.example:3391');
        expect(parseEndpointAuthority('[2001:db8::20]:3390junk', 3389).error)
          .assertEqual('invalid_port');
      });

    it('uses_a_versioned_length_prefixed_identity_without_ipv6_delimiter_collision', 0,
      (): void => {
        const parsed: EndpointAddressResult = parseEndpointAuthority('[2001:db8::20]:3389', 3389);
        expect(parsed.ok).assertTrue();
        expect(endpointIdentityV2(parsed.endpoint, 'rdp.example')).assertEqual(
          'endpoint-v2|family=4:ipv6|host=12:2001:db8::20|scope=0:|port=3389|' +
          'server=11:rdp.example');
      });
  });
}
