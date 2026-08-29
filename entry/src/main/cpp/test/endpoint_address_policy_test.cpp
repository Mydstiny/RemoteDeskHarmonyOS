#include "common/endpoint_address_policy.h"
#include "test_runner.h"

#include <string>

using namespace remotedesk::endpoint;

RDP_TEST_CASE(endpoint_address_canonicalizes_ascii_dns_ipv4_and_rfc5952) {
    const auto dns = ParseHost("RDP.Office.Example.COM.");
    RDP_ASSERT(dns.ok);
    RDP_ASSERT(dns.endpoint.family() == AddressFamily::Hostname);
    RDP_ASSERT(dns.endpoint.canonicalHost() == "rdp.office.example.com");

    const auto ipv4 = ParseHost("192.168.31.177");
    RDP_ASSERT(ipv4.ok);
    RDP_ASSERT(ipv4.endpoint.family() == AddressFamily::Ipv4);
    RDP_ASSERT(ipv4.endpoint.canonicalHost() == "192.168.31.177");

    const auto equalRuns = ParseHost("[2001:0DB8:0000:0000:0001:0000:0000:0001]");
    RDP_ASSERT(equalRuns.ok);
    RDP_ASSERT(equalRuns.endpoint.canonicalHost() == "2001:db8::1:0:0:1");
    RDP_ASSERT(ParseHost("2001:db8:0:1:1:1:1:1").endpoint.canonicalHost() ==
        "2001:db8:0:1:1:1:1:1");
    RDP_ASSERT(ParseHost("0:0:1:2:3:4:5:6").endpoint.canonicalHost() == "::1:2:3:4:5:6");
    RDP_ASSERT(ParseHost("1:2:3:4:5:6:0:0").endpoint.canonicalHost() == "1:2:3:4:5:6::");
}

RDP_TEST_CASE(endpoint_address_separates_persisted_and_runtime_scopes) {
    const auto scoped = ParseHost("fe80::20%wlan0");
    RDP_ASSERT(scoped.ok);
    RDP_ASSERT(scoped.endpoint.canonicalHost() == "fe80::20");
    RDP_ASSERT(scoped.endpoint.scope() == "wlan0");
    RDP_ASSERT(scoped.endpoint.scopeKind() == ScopeKind::Interface);
    RDP_ASSERT(TransportHost(scoped.endpoint) == "fe80::20%wlan0");

    const auto numeric = ParseHost("fe80::20%3", ParseMode::Runtime);
    RDP_ASSERT(numeric.ok);
    RDP_ASSERT(numeric.endpoint.scopeKind() == ScopeKind::Numeric);
    RDP_ASSERT(ParseHost("fe80::20%0003", ParseMode::Runtime).endpoint.scope() == "3");
    RDP_ASSERT(ParseHost("fe80::20%00000000003", ParseMode::Runtime).error ==
        AddressError::ScopeNotPortable);
    RDP_ASSERT(ParseHost("fe80::20%4294967295", ParseMode::Runtime).ok);
    RDP_ASSERT(ParseHost("fe80::20%0", ParseMode::Runtime).error == AddressError::ScopeNotPortable);
    RDP_ASSERT(ParseHost("fe80::20%4294967296", ParseMode::Runtime).error ==
        AddressError::ScopeNotPortable);
    RDP_ASSERT(ParseHost("fe80::20").error == AddressError::ScopeRequired);
    RDP_ASSERT(ParseHost("fe80::20%3").error == AddressError::ScopeNotPortable);
    RDP_ASSERT(ParseHost("2001:db8::20%wlan0").error == AddressError::ScopeNotAllowed);
}

RDP_TEST_CASE(endpoint_address_rejects_whitespace_unicode_brackets_and_length) {
    RDP_ASSERT(ParseHost(" rdp.example").error == AddressError::InvalidSyntax);
    RDP_ASSERT(ParseHost("rdp.example ").error == AddressError::InvalidSyntax);
    RDP_ASSERT(ParseHost("rdp\texample").error == AddressError::InvalidSyntax);
    RDP_ASSERT(ParseHost("rdp.example\r\n").error == AddressError::InvalidSyntax);
    RDP_ASSERT(ParseHost("\xc2\xa0rdp.example").error == AddressError::InvalidSyntax);
    RDP_ASSERT(ParseHost("\xef\xbb\xbfrdp.example").error == AddressError::InvalidSyntax);
    RDP_ASSERT(ParseHost("[rdp.example]").error == AddressError::InvalidSyntax);
    RDP_ASSERT(ParseHost("[192.168.31.177]").error == AddressError::InvalidSyntax);
    RDP_ASSERT(ParseHost("[]").error == AddressError::InvalidSyntax);
    RDP_ASSERT(ParseHost(std::string(kMaxInputLength + 1U, 'a')).error == AddressError::InputTooLong);
    std::string nonAscii;
    for (std::size_t index = 0U; index < 300U; ++index) {
        nonAscii += "\xc3\xa9";
    }
    RDP_ASSERT(ParseHost(nonAscii).error == AddressError::InvalidSyntax);
}

RDP_TEST_CASE(endpoint_address_rejects_nonconnectable_and_legacy_numeric_forms) {
    RDP_ASSERT(ParseHost("::").error == AddressError::AddressNotConnectable);
    RDP_ASSERT(ParseHost("ff02::1%wlan0").error == AddressError::AddressNotConnectable);
    RDP_ASSERT(ParseHost("::ffff:192.0.2.20").error == AddressError::AddressNotConnectable);
    RDP_ASSERT(ParseHost("0.1.2.3").error == AddressError::AddressNotConnectable);
    RDP_ASSERT(ParseHost("224.0.0.1").error == AddressError::AddressNotConnectable);
    RDP_ASSERT(ParseHost("255.255.255.255").error == AddressError::AddressNotConnectable);
    RDP_ASSERT(ParseHost("0").error == AddressError::InvalidIpv4);
    RDP_ASSERT(ParseHost("2130706433").error == AddressError::InvalidIpv4);
    RDP_ASSERT(ParseHost("0x7f000001").error == AddressError::InvalidIpv4);
    RDP_ASSERT(ParseHost("0x7f000001.").error == AddressError::InvalidIpv4);
    RDP_ASSERT(ParseHost("2130706433.").error == AddressError::InvalidIpv4);
    RDP_ASSERT(ParseHost("017700000001.").error == AddressError::InvalidIpv4);
    RDP_ASSERT(ParseHost("0x7f.1.").error == AddressError::InvalidIpv4);
    RDP_ASSERT(ParseHost("127.1").error == AddressError::InvalidIpv4);
    RDP_ASSERT(ParseHost(":::1").error == AddressError::InvalidIpv6);
    RDP_ASSERT(ParseHost("rdp.example:3389").error == AddressError::InvalidIpv6);
    RDP_ASSERT(ParseHost("https://rdp.example").error == AddressError::InvalidSyntax);
}

RDP_TEST_CASE(endpoint_address_parses_ports_and_formats_socket_and_uri_authority) {
    const auto scoped = ParseAuthority("[fe80::20%wlan0]:3390", 3389U);
    RDP_ASSERT(scoped.ok);
    RDP_ASSERT(FormatHostPort(scoped.endpoint) == "[fe80::20%wlan0]:3390");
    RDP_ASSERT(FormatUriAuthority(scoped.endpoint) == "[fe80::20%25wlan0]:3390");

    RDP_ASSERT(ParseAuthority("rdp.example:1", 3389U).endpoint.port() == 1U);
    RDP_ASSERT(ParseAuthority("rdp.example:65535", 3389U).endpoint.port() == 65535U);
    RDP_ASSERT(ParseAuthority("rdp.example:0", 3389U).error == AddressError::InvalidPort);
    RDP_ASSERT(ParseAuthority("rdp.example:65536", 3389U).error == AddressError::InvalidPort);
    RDP_ASSERT(ParseAuthority("rdp.example:", 3389U).error == AddressError::InvalidPort);
    RDP_ASSERT(ParseAuthority("0x7f000001.:3389", 3389U).error == AddressError::InvalidIpv4);
    RDP_ASSERT(ParseAuthority("[2001:db8::20]:3390junk", 3389U).error == AddressError::InvalidPort);
    const ParseResult fields = ParseFields("[2001:0DB8:0:0::20]", 3389U);
    RDP_ASSERT(fields.ok);
    RDP_ASSERT(fields.endpoint.canonicalHost() == "2001:db8::20");
    RDP_ASSERT(fields.endpoint.port() == 3389U);
    RDP_ASSERT(ParseFields("rdp.example", 0U).error == AddressError::InvalidPort);
}

RDP_TEST_CASE(endpoint_address_builds_only_validated_typed_stable_identity) {
    const auto parsed = ParseAuthority("[2001:db8::20]:3389", 3389U);
    const auto explicitIdentity = ParseServerIdentity("2001:0db8::20");
    RDP_ASSERT(parsed.ok);
    RDP_ASSERT(explicitIdentity.ok);
    RDP_ASSERT(explicitIdentity.identity.kind() == ServerIdentityKind::Ip);
    RDP_ASSERT(explicitIdentity.identity.canonicalName() == "2001:db8::20");

    const auto derivedKey = IdentityV2(parsed.endpoint);
    const auto explicitKey = IdentityV2(parsed.endpoint, explicitIdentity.identity);
    RDP_ASSERT(derivedKey.ok);
    RDP_ASSERT(explicitKey.ok);
    RDP_ASSERT(derivedKey.identity == explicitKey.identity);
    RDP_ASSERT(explicitKey.identity ==
        "endpoint-v2|family=4:ipv6|host=12:2001:db8::20|scope=0:|port=3389|"
        "server-kind=2:ip|server=12:2001:db8::20");

    const ServerIdentity wrongKind(ServerIdentityKind::Dns, "2001:db8::20");
    RDP_ASSERT(IdentityV2(parsed.endpoint, wrongKind).error == IdentityError::InvalidServerIdentity);
    RDP_ASSERT(!ParseServerIdentity("\xe4\xb8\xbb\xe6\x9c\xba.example").ok);
    RDP_ASSERT(!ParseServerIdentity("0x7f000001.").ok);

    const Address fabricated("2001:0DB8::20", AddressFamily::Ipv6, 3389U);
    RDP_ASSERT(IdentityV2(fabricated).error == IdentityError::InvalidEndpoint);

    const auto otherPort = ParseAuthority("[2001:db8::20]:3390", 3389U);
    RDP_ASSERT(IdentityV2(otherPort.endpoint).identity != derivedKey.identity);

    const auto dnsEndpoint = ParseAuthority("rdp.example:3389", 3389U);
    const auto otherServer = ParseServerIdentity("tls.example");
    RDP_ASSERT(IdentityV2(dnsEndpoint.endpoint).identity !=
        IdentityV2(dnsEndpoint.endpoint, otherServer.identity).identity);
}
