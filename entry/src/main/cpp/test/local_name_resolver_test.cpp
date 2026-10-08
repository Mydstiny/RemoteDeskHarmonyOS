#include "common/local_name_resolver.h"
#include "test_runner.h"

#include <string>
#include <vector>

using remotedesk::net::LocalNameKind;

namespace {

std::vector<uint8_t> Name(const std::vector<std::string>& labels) {
    std::vector<uint8_t> out;
    for (const auto& label : labels) {
        out.push_back(static_cast<uint8_t>(label.size()));
        out.insert(out.end(), label.begin(), label.end());
    }
    out.push_back(0);
    return out;
}

void Append(std::vector<uint8_t>& out, std::initializer_list<int> bytes) {
    for (int value : bytes) { out.push_back(static_cast<uint8_t>(value)); }
}

} // namespace

RDP_TEST_CASE(local_name_classification_matches_what_windows_resolves_off_dns) {
    RDP_ASSERT(remotedesk::net::ClassifyLocalName("DESKTOP-1A2B3C") == LocalNameKind::SingleLabel);
    RDP_ASSERT(remotedesk::net::ClassifyLocalName("office-pc.") == LocalNameKind::SingleLabel);
    RDP_ASSERT(remotedesk::net::ClassifyLocalName("Office-PC.local") == LocalNameKind::MdnsLocal);
    RDP_ASSERT(remotedesk::net::ClassifyLocalName("a.b.LOCAL") == LocalNameKind::MdnsLocal);
    RDP_ASSERT(remotedesk::net::ClassifyLocalName("pc.example.com") == LocalNameKind::None);
    RDP_ASSERT(remotedesk::net::ClassifyLocalName("192.168.1.2") == LocalNameKind::None);
    RDP_ASSERT(remotedesk::net::ClassifyLocalName("-bad") == LocalNameKind::None);
    RDP_ASSERT(remotedesk::net::ClassifyLocalName("has space") == LocalNameKind::None);
    RDP_ASSERT(remotedesk::net::ClassifyLocalName(".local") == LocalNameKind::None);
    RDP_ASSERT(remotedesk::net::ClassifyLocalName("") == LocalNameKind::None);
}

RDP_TEST_CASE(local_name_dns_query_carries_unicast_response_bit) {
    const auto query = remotedesk::net::BuildDnsQuery(0x1234, "pc.local", 1, true);
    std::vector<uint8_t> expected = { 0x12, 0x34, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
    const auto name = Name({ "pc", "local" });
    expected.insert(expected.end(), name.begin(), name.end());
    Append(expected, { 0, 1, 0x80, 0x01 });
    RDP_ASSERT(query == expected);
}

RDP_TEST_CASE(local_name_parses_mdns_answers_with_compression_and_cache_flush) {
    std::vector<uint8_t> response = { 0x00, 0x00, 0x84, 0x00, 0, 1, 0, 3, 0, 0, 0, 0 };
    const auto name = Name({ "Office-PC", "local" });
    response.insert(response.end(), name.begin(), name.end());  // question at offset 12
    Append(response, { 0, 1, 0x80, 0x01 });
    // A 192.168.1.20 with the cache-flush bit, name compressed to offset 12.
    Append(response, { 0xc0, 12, 0, 1, 0x80, 0x01, 0, 0, 0, 120, 0, 4, 192, 168, 1, 20 });
    // AAAA fe80::1 (link-local, dropped).
    Append(response, { 0xc0, 12, 0, 28, 0x80, 0x01, 0, 0, 0, 120, 0, 16,
        0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 });
    // AAAA 2001:db8::5 (kept).
    Append(response, { 0xc0, 12, 0, 28, 0x80, 0x01, 0, 0, 0, 120, 0, 16,
        0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5 });
    std::vector<std::string> addresses;
    RDP_ASSERT(remotedesk::net::ParseDnsAnswers(response.data(), response.size(), 0x4321, true,
        "office-pc.local", addresses));
    RDP_ASSERT(addresses.size() == 2);
    RDP_ASSERT(addresses[0] == "192.168.1.20");
    RDP_ASSERT(addresses[1] == "2001:db8::5");
    // The wrong ID is refused when it must match; an error response yields nothing.
    std::vector<std::string> none;
    RDP_ASSERT(!remotedesk::net::ParseDnsAnswers(response.data(), response.size(), 0x4321, false,
        "office-pc.local", none));
    response[3] = 0x03;  // NXDOMAIN
    RDP_ASSERT(!remotedesk::net::ParseDnsAnswers(response.data(), response.size(), 0, true,
        "office-pc.local", none));
    // A truncated packet never reads past its end.
    std::vector<uint8_t> truncated(response.begin(), response.begin() + 40);
    RDP_ASSERT(!remotedesk::net::ParseDnsAnswers(truncated.data(), truncated.size(), 0, true,
        "office-pc.local", none));
}

RDP_TEST_CASE(local_name_netbios_query_and_response) {
    RDP_ASSERT(remotedesk::net::EncodeNetbiosName("desktop-1", 0x20) == "EEEFFDELFEEPFACNDBCACACACACACACA");
    const auto query = remotedesk::net::BuildNetbiosNameQuery(0x0102, "desktop-1", 0x20);
    RDP_ASSERT(query.size() == 12 + 34 + 4);
    RDP_ASSERT(query[2] == 0x01 && query[3] == 0x10 && query[12] == 32);
    // Positive response: answer RR with two NB entries.
    std::vector<uint8_t> response = { 0x01, 0x02, 0x85, 0x00, 0, 0, 0, 1, 0, 0, 0, 0 };
    response.push_back(32);
    const std::string encoded = remotedesk::net::EncodeNetbiosName("desktop-1", 0x20);
    response.insert(response.end(), encoded.begin(), encoded.end());
    response.push_back(0);
    Append(response, { 0, 0x20, 0, 1, 0, 0, 0x0e, 0x10, 0, 12,
        0, 0, 192, 168, 1, 30, 0, 0, 10, 0, 0, 7 });
    std::vector<std::string> addresses;
    RDP_ASSERT(remotedesk::net::ParseNetbiosNameResponse(response.data(), response.size(), 0x0102, addresses));
    RDP_ASSERT(addresses.size() == 2 && addresses[0] == "192.168.1.30" && addresses[1] == "10.0.0.7");
    std::vector<std::string> none;
    RDP_ASSERT(!remotedesk::net::ParseNetbiosNameResponse(response.data(), response.size(), 0x9999, none));
}

RDP_TEST_CASE(local_name_resolution_skips_names_that_are_not_local) {
    const auto result = remotedesk::net::ResolveLocalHostName("pc.example.com", std::chrono::milliseconds(200));
    RDP_ASSERT(result.addresses.empty() && result.method.empty());
}
