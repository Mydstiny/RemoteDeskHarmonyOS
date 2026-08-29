import { describe, expect, it } from '@ohos/hypium';
import {
  endpointIdentityV2,
  EndpointAddress,
  EndpointAddressResult,
  EndpointIdentityResult,
  EndpointServerIdentity,
  EndpointServerIdentityResult,
  endpointTransportHost,
  formatEndpointHostPort,
  formatEndpointUriAuthority,
  parseEndpointAuthority,
  parseEndpointFields,
  parseEndpointHost,
  parseEndpointPortText,
  parseEndpointServerIdentity
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
      expect(parseEndpointHost('主机.example').error).assertEqual('invalid_syntax');
    });

    it('canonicalizes_rfc5952_without_compressing_a_single_zero_word', 0, (): void => {
      const equalRuns: EndpointAddressResult =
        parseEndpointHost('[2001:0DB8:0000:0000:0001:0000:0000:0001]');
      expect(equalRuns.ok).assertTrue();
      expect(equalRuns.endpoint.canonicalHost).assertEqual('2001:db8::1:0:0:1');

      expect(parseEndpointHost('2001:db8:0:1:1:1:1:1').endpoint.canonicalHost)
        .assertEqual('2001:db8:0:1:1:1:1:1');
      expect(parseEndpointHost('0:0:1:2:3:4:5:6').endpoint.canonicalHost)
        .assertEqual('::1:2:3:4:5:6');
      expect(parseEndpointHost('1:2:3:4:5:6:0:0').endpoint.canonicalHost)
        .assertEqual('1:2:3:4:5:6::');
      expect(parseEndpointHost('0:0:0:0:0:0:0:1').endpoint.canonicalHost).assertEqual('::1');
    });

    it('separates_persisted_interface_scope_from_runtime_numeric_scope', 0, (): void => {
      const scoped: EndpointAddressResult = parseEndpointHost('fe80::20%wlan0');
      expect(scoped.ok).assertTrue();
      expect(scoped.endpoint.canonicalHost).assertEqual('fe80::20');
      expect(scoped.endpoint.scope).assertEqual('wlan0');
      expect(scoped.endpoint.scopeKind).assertEqual('interface');
      expect(endpointTransportHost(scoped.endpoint)).assertEqual('fe80::20%wlan0');

      const numeric: EndpointAddressResult = parseEndpointHost('fe80::20%3', 'runtime');
      expect(numeric.ok).assertTrue();
      expect(numeric.endpoint.scopeKind).assertEqual('numeric');
      expect(parseEndpointHost('fe80::20%0003', 'runtime').endpoint.scope).assertEqual('3');
      expect(parseEndpointHost('fe80::20%00000000003', 'runtime').error)
        .assertEqual('scope_not_portable');
      expect(parseEndpointHost('fe80::20%4294967295', 'runtime').ok).assertTrue();
      expect(parseEndpointHost('fe80::20%0', 'runtime').error).assertEqual('scope_not_portable');
      expect(parseEndpointHost('fe80::20%4294967296', 'runtime').error)
        .assertEqual('scope_not_portable');
      expect(parseEndpointHost('fe80::20').error).assertEqual('scope_required');
      expect(parseEndpointHost('fe80::20%3').error).assertEqual('scope_not_portable');
      expect(parseEndpointHost('2001:db8::20%wlan0').error).assertEqual('scope_not_allowed');
    });

    it('rejects_whitespace_unicode_bracket_abuse_and_overlong_input', 0, (): void => {
      expect(parseEndpointHost(' rdp.example').error).assertEqual('invalid_syntax');
      expect(parseEndpointHost('rdp.example ').error).assertEqual('invalid_syntax');
      expect(parseEndpointHost('rdp\texample').error).assertEqual('invalid_syntax');
      expect(parseEndpointHost('rdp.example\r\n').error).assertEqual('invalid_syntax');
      expect(parseEndpointHost('\u00a0rdp.example').error).assertEqual('invalid_syntax');
      expect(parseEndpointHost('\ufeffrdp.example').error).assertEqual('invalid_syntax');
      expect(parseEndpointHost('[rdp.example]').error).assertEqual('invalid_syntax');
      expect(parseEndpointHost('[192.168.31.177]').error).assertEqual('invalid_syntax');
      expect(parseEndpointHost('[]').error).assertEqual('invalid_syntax');
      expect(parseEndpointHost('a'.repeat(513)).error).assertEqual('input_too_long');
      expect(parseEndpointHost('é'.repeat(300)).error).assertEqual('invalid_syntax');
    });

    it('rejects_nonconnectable_and_legacy_numeric_literal_forms', 0, (): void => {
      expect(parseEndpointHost('::').error).assertEqual('address_not_connectable');
      expect(parseEndpointHost('ff02::1%wlan0').error).assertEqual('address_not_connectable');
      expect(parseEndpointHost('::ffff:192.0.2.20').error).assertEqual('address_not_connectable');
      expect(parseEndpointHost('0.1.2.3').error).assertEqual('address_not_connectable');
      expect(parseEndpointHost('224.0.0.1').error).assertEqual('address_not_connectable');
      expect(parseEndpointHost('255.255.255.255').error).assertEqual('address_not_connectable');
      expect(parseEndpointHost('0').error).assertEqual('invalid_ipv4');
      expect(parseEndpointHost('2130706433').error).assertEqual('invalid_ipv4');
      expect(parseEndpointHost('0x7f000001').error).assertEqual('invalid_ipv4');
      expect(parseEndpointHost('0x7f000001.').error).assertEqual('invalid_ipv4');
      expect(parseEndpointHost('2130706433.').error).assertEqual('invalid_ipv4');
      expect(parseEndpointHost('017700000001.').error).assertEqual('invalid_ipv4');
      expect(parseEndpointHost('0x7f.1.').error).assertEqual('invalid_ipv4');
      expect(parseEndpointHost('127.1').error).assertEqual('invalid_ipv4');
      expect(parseEndpointHost(':::1').error).assertEqual('invalid_ipv6');
      expect(parseEndpointHost('rdp.example:3389').error).assertEqual('invalid_ipv6');
      expect(parseEndpointHost('https://rdp.example').error).assertEqual('invalid_syntax');
      expect(parseEndpointHost('user@rdp.example').error).assertEqual('invalid_syntax');
    });

    it('parses_port_boundaries_and_formats_socket_and_uri_authorities', 0, (): void => {
      const scoped: EndpointAddressResult = parseEndpointAuthority('[fe80::20%wlan0]:3390', 3389);
      expect(scoped.ok).assertTrue();
      expect(formatEndpointHostPort(scoped.endpoint)).assertEqual('[fe80::20%wlan0]:3390');
      expect(formatEndpointUriAuthority(scoped.endpoint)).assertEqual('[fe80::20%25wlan0]:3390');

      expect(parseEndpointAuthority('rdp.example:1', 3389).endpoint.port).assertEqual(1);
      expect(parseEndpointAuthority('rdp.example:65535', 3389).endpoint.port).assertEqual(65535);
      expect(parseEndpointAuthority('rdp.example:0', 3389).error).assertEqual('invalid_port');
      expect(parseEndpointAuthority('rdp.example:65536', 3389).error).assertEqual('invalid_port');
      expect(parseEndpointAuthority('rdp.example:', 3389).error).assertEqual('invalid_port');
      expect(parseEndpointAuthority('0x7f000001.:3389', 3389).error).assertEqual('invalid_ipv4');
      expect(parseEndpointAuthority('[2001:db8::20]:3390junk', 3389).error)
        .assertEqual('invalid_port');

      const fields: EndpointAddressResult =
        parseEndpointFields('[2001:0DB8:0:0::20]', 3389);
      expect(fields.ok).assertTrue();
      expect(fields.endpoint.canonicalHost).assertEqual('2001:db8::20');
      expect(fields.endpoint.port).assertEqual(3389);
      expect(parseEndpointFields('rdp.example', 0).error).assertEqual('invalid_port');
      expect(parseEndpointPortText('22')).assertEqual(22);
      expect(parseEndpointPortText(' 22')).assertEqual(0);
      expect(parseEndpointPortText('22junk')).assertEqual(0);
    });

    it('builds_only_validated_typed_and_stable_server_identities', 0, (): void => {
      const parsed: EndpointAddressResult = parseEndpointAuthority('[2001:db8::20]:3389', 3389);
      const explicit: EndpointServerIdentityResult = parseEndpointServerIdentity('2001:0db8::20');
      expect(parsed.ok).assertTrue();
      expect(explicit.ok).assertTrue();
      expect(explicit.identity.kind).assertEqual('ip');
      expect(explicit.identity.canonicalName).assertEqual('2001:db8::20');

      const derivedKey: EndpointIdentityResult = endpointIdentityV2(parsed.endpoint);
      const explicitKey: EndpointIdentityResult = endpointIdentityV2(parsed.endpoint, explicit.identity);
      expect(derivedKey.ok).assertTrue();
      expect(derivedKey.identity).assertEqual(explicitKey.identity);
      expect(explicitKey.identity).assertEqual(
        'endpoint-v2|family=4:ipv6|host=12:2001:db8::20|scope=0:|port=3389|' +
        'server-kind=2:ip|server=12:2001:db8::20');

      const wrongKind: EndpointServerIdentity =
        new EndpointServerIdentity('dns', '2001:db8::20');
      expect(endpointIdentityV2(parsed.endpoint, wrongKind).error)
        .assertEqual('invalid_server_identity');
      expect(parseEndpointServerIdentity('主机.example').error)
        .assertEqual('invalid_server_identity');
      expect(parseEndpointServerIdentity('0x7f000001.').error)
        .assertEqual('invalid_server_identity');

      const fabricated: EndpointAddress = new EndpointAddress(
        '2001:0DB8::20', 'ipv6', 3389
      );
      expect(endpointIdentityV2(fabricated).error).assertEqual('invalid_endpoint');

      const otherPort: EndpointAddressResult = parseEndpointAuthority('[2001:db8::20]:3390', 3389);
      expect(endpointIdentityV2(otherPort.endpoint).identity === derivedKey.identity).assertFalse();

      const dnsEndpoint: EndpointAddressResult = parseEndpointAuthority('rdp.example:3389', 3389);
      const otherServer: EndpointServerIdentityResult = parseEndpointServerIdentity('tls.example');
      expect(endpointIdentityV2(dnsEndpoint.endpoint).identity ===
        endpointIdentityV2(dnsEndpoint.endpoint, otherServer.identity).identity).assertFalse();
    });
  });
}
