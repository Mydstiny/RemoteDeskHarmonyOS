#include "moonlight/runtime/MoonlightHttpRequestFormatting.h"
#include "test_runner.h"

#include <string>

namespace {

using namespace remotedesk::moonlight;

constexpr const char* kSuffix =
    "\r\nAccept: application/xml, */*\r\nConnection: close\r\n\r\n";

} // namespace

RDP_TEST_CASE(moonlight_http_request_formats_hostname_authority_with_port) {
    std::string wire;
    RDP_ASSERT(buildMoonlightHttp11GetRequest(
        "sunshine.local", 47989U, "/serverinfo?uniqueid=client", wire));
    RDP_ASSERT(wire == std::string("GET /serverinfo?uniqueid=client HTTP/1.1\r\n") +
                           "Host: sunshine.local:47989" + kSuffix);
}

RDP_TEST_CASE(moonlight_http_request_formats_ipv4_and_custom_https_ports) {
    std::string wire;
    RDP_ASSERT(buildMoonlightHttp11GetRequest(
        "192.0.2.20", 48084U, "/applist?uuid=request", wire));
    RDP_ASSERT(wire == std::string("GET /applist?uuid=request HTTP/1.1\r\n") +
                           "Host: 192.0.2.20:48084" + kSuffix);
}

RDP_TEST_CASE(moonlight_http_request_brackets_ipv6_authority_and_keeps_port) {
    std::string wire;
    RDP_ASSERT(buildMoonlightHttp11GetRequest(
        "2001:db8::20", 47984U, "/launch?appid=123", wire));
    RDP_ASSERT(wire == std::string("GET /launch?appid=123 HTTP/1.1\r\n") +
                           "Host: [2001:db8::20]:47984" + kSuffix);
}

RDP_TEST_CASE(moonlight_http_request_rejects_header_and_target_injection) {
    std::string wire = "stale";
    RDP_ASSERT(!buildMoonlightHttp11GetRequest(
        "sunshine.local\r\nX-Injected: yes", 47989U, "/serverinfo", wire));
    RDP_ASSERT(wire.empty());

    RDP_ASSERT(!buildMoonlightHttp11GetRequest(
        "sunshine.local", 47989U, "/serverinfo\r\nX-Injected: yes", wire));
    RDP_ASSERT(wire.empty());
}

RDP_TEST_CASE(moonlight_http_request_rejects_invalid_authority_port_and_origin_form) {
    std::string wire;
    RDP_ASSERT(!buildMoonlightHttp11GetRequest("", 47989U, "/serverinfo", wire));
    RDP_ASSERT(!buildMoonlightHttp11GetRequest("[2001:db8::1]", 47989U, "/serverinfo", wire));
    RDP_ASSERT(!buildMoonlightHttp11GetRequest("sunshine.local", 0U, "/serverinfo", wire));
    RDP_ASSERT(!buildMoonlightHttp11GetRequest(
        "sunshine.local", 47989U, "https://sunshine.local/serverinfo", wire));
    RDP_ASSERT(!buildMoonlightHttp11GetRequest(
        "sunshine.local", 47989U, "/serverinfo#fragment", wire));
}

RDP_TEST_CASE(moonlight_tls_sni_uses_dns_transport_address_only) {
    const auto dns = moonlightTlsServerName("sunshine.local");
    RDP_ASSERT(dns.has_value());
    RDP_ASSERT(*dns == "sunshine.local");
    RDP_ASSERT(!moonlightTlsServerName("192.0.2.20").has_value());
    RDP_ASSERT(!moonlightTlsServerName("2001:db8::20").has_value());
    RDP_ASSERT(!moonlightTlsServerName("Gaming PC").has_value());
}
