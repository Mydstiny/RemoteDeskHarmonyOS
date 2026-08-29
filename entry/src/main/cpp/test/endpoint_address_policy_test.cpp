#include "common/endpoint_address_policy.h"
#include "test_runner.h"

using namespace remotedesk::endpoint;

RDP_TEST_CASE(endpoint_address_canonicalizes_dns_ipv4_and_ipv6) {
    const auto dns = ParseHost("RDP.Office.Example.COM.");
    RDP_ASSERT(dns.ok);
    RDP_ASSERT(dns.endpoint.family == AddressFamily::Hostname);
    RDP_ASSERT(dns.endpoint.canonicalHost == "rdp.office.example.com");

    const auto ipv4 = ParseHost("192.168.31.177");
    RDP_ASSERT(ipv4.ok);
    RDP_ASSERT(ipv4.endpoint.family == AddressFamily::Ipv4);
    RDP_ASSERT(ipv4.endpoint.canonicalHost == "192.168.31.177");

    const auto ipv6 = ParseHost("[2001:0DB8:0000:0000:0001:0000:0000:0001]");
    RDP_ASSERT(ipv6.ok);
    RDP_ASSERT(ipv6.endpoint.family == AddressFamily::Ipv6);
    RDP_ASSERT(ipv6.endpoint.canonicalHost == "2001:db8::1:0:0:1");
}

RDP_TEST_CASE(endpoint_address_keeps_link_local_scope_separate) {
    const auto scoped = ParseHost("fe80::20%wlan0");
    RDP_ASSERT(scoped.ok);
    RDP_ASSERT(scoped.endpoint.canonicalHost == "fe80::20");
    RDP_ASSERT(scoped.endpoint.scope == "wlan0");
    RDP_ASSERT(TransportHost(scoped.endpoint) == "fe80::20%wlan0");

    RDP_ASSERT(ParseHost("fe80::20").error == AddressError::ScopeRequired);
    RDP_ASSERT(ParseHost("fe80::20%3").error == AddressError::ScopeNotPortable);
    RDP_ASSERT(ParseHost("2001:db8::20%wlan0").error == AddressError::ScopeNotAllowed);
}

RDP_TEST_CASE(endpoint_address_rejects_nonconnectable_and_ambiguous_inputs) {
    RDP_ASSERT(ParseHost("::").error == AddressError::AddressNotConnectable);
    RDP_ASSERT(ParseHost("ff02::1%wlan0").error == AddressError::AddressNotConnectable);
    RDP_ASSERT(ParseHost("::ffff:192.0.2.20").error == AddressError::AddressNotConnectable);
    RDP_ASSERT(ParseHost(":::1").error == AddressError::InvalidIpv6);
    RDP_ASSERT(ParseHost("rdp.example:3389").error == AddressError::InvalidIpv6);
    RDP_ASSERT(ParseHost("https://rdp.example").error == AddressError::InvalidSyntax);
}

RDP_TEST_CASE(endpoint_address_formats_authority_and_versioned_identity) {
    const auto parsed = ParseAuthority("[2001:db8::20]:3390", 3389U);
    RDP_ASSERT(parsed.ok);
    RDP_ASSERT(parsed.endpoint.canonicalHost == "2001:db8::20");
    RDP_ASSERT(parsed.endpoint.port == 3390U);
    RDP_ASSERT(FormatHostPort(parsed.endpoint) == "[2001:db8::20]:3390");
    RDP_ASSERT(IdentityV2(parsed.endpoint, "rdp.example") ==
        "endpoint-v2|family=4:ipv6|host=12:2001:db8::20|scope=0:|port=3390|server=11:rdp.example");

    const auto raw = ParseAuthority("2001:db8::20", 3389U);
    RDP_ASSERT(raw.ok);
    RDP_ASSERT(FormatHostPort(raw.endpoint) == "[2001:db8::20]:3389");
    RDP_ASSERT(ParseAuthority("[2001:db8::20]:3390junk", 3389U).error == AddressError::InvalidPort);
}
