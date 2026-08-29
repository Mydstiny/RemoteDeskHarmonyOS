#pragma once

#include <cstdint>
#include <string>

namespace remotedesk::endpoint {

enum class AddressFamily {
    Hostname,
    Ipv4,
    Ipv6,
};

enum class AddressError {
    None,
    Empty,
    InvalidSyntax,
    InvalidHostname,
    InvalidIpv4,
    InvalidIpv6,
    InvalidPort,
    ScopeRequired,
    ScopeNotAllowed,
    ScopeNotPortable,
    AddressNotConnectable,
};

struct Address {
    std::uint32_t version = 2;
    std::string canonicalHost;
    AddressFamily family = AddressFamily::Hostname;
    std::uint16_t port = 0;
    std::string scope;
};

struct ParseResult {
    bool ok = false;
    Address endpoint;
    AddressError error = AddressError::InvalidSyntax;
};

ParseResult ParseHost(const std::string& input);
ParseResult ParseAuthority(const std::string& input, std::uint16_t defaultPort);

std::string TransportHost(const Address& endpoint);
std::string FormatHostPort(const Address& endpoint);
std::string IdentityV2(const Address& endpoint, const std::string& canonicalServerName = {});

} // namespace remotedesk::endpoint
