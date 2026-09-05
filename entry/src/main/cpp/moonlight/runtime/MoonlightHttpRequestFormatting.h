#ifndef REMOTEDESK_MOONLIGHT_HTTP_REQUEST_FORMATTING_H
#define REMOTEDESK_MOONLIGHT_HTTP_REQUEST_FORMATTING_H

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace remotedesk::moonlight {

// Builds the exact origin-form HTTP/1.1 GET request used by the Moonlight
// Host API. The authority always includes the selected transport port because
// GameStream/Sunshine control endpoints use non-default and configurable ports.
bool buildMoonlightHttp11GetRequest(std::string_view authorityHost,
                                    std::uint16_t port,
                                    std::string_view target,
                                    std::string& output);

// Selects the validated HTTP authority identity independently of the socket
// candidate. When an IP identity matches a scoped connection candidate, the
// zone is restored for URI/Host formatting without becoming part of TLS
// identity.
std::string moonlightHttpAuthorityHost(std::string_view serverName,
                                       std::string_view connectAddress);

// Returns a validated DNS server identity suitable for TLS SNI. IP literals
// (including IPv6) intentionally produce no SNI. A Sunshine display name is
// never a transport identity.
std::optional<std::string> moonlightTlsServerName(
    std::string_view serverName);

} // namespace remotedesk::moonlight

#endif // REMOTEDESK_MOONLIGHT_HTTP_REQUEST_FORMATTING_H
