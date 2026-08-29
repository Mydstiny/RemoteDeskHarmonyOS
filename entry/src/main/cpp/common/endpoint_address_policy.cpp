#include "common/endpoint_address_policy.h"

#include <arpa/inet.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <sstream>
#include <string_view>
#include <vector>

namespace remotedesk::endpoint {
namespace {

ParseResult Failed(AddressError error) {
    ParseResult result;
    result.error = error;
    return result;
}

ParseResult Succeeded(std::string host, AddressFamily family, std::string scope = {}) {
    ParseResult result;
    result.ok = true;
    result.error = AddressError::None;
    result.endpoint.canonicalHost = std::move(host);
    result.endpoint.family = family;
    result.endpoint.scope = std::move(scope);
    return result;
}

std::string Trim(std::string_view value) {
    std::size_t first = 0;
    while (first < value.size() && std::isspace(static_cast<unsigned char>(value[first])) != 0) {
        ++first;
    }
    std::size_t last = value.size();
    while (last > first && std::isspace(static_cast<unsigned char>(value[last - 1])) != 0) {
        --last;
    }
    return std::string(value.substr(first, last - first));
}

bool ValidPort(std::uint32_t value) {
    return value >= 1U && value <= 65535U;
}

std::uint16_t ParsePort(std::string_view value) {
    if (value.empty() || value.size() > 5U) {
        return 0;
    }
    std::uint32_t parsed = 0;
    for (char ch : value) {
        if (ch < '0' || ch > '9') {
            return 0;
        }
        parsed = parsed * 10U + static_cast<std::uint32_t>(ch - '0');
    }
    return ValidPort(parsed) ? static_cast<std::uint16_t>(parsed) : 0;
}

bool InvalidEndpointCharacters(std::string_view value) {
    if (value.find("://") != std::string_view::npos ||
        value.find('/') != std::string_view::npos ||
        value.find('\\') != std::string_view::npos ||
        value.find('@') != std::string_view::npos ||
        value.find('?') != std::string_view::npos ||
        value.find('#') != std::string_view::npos) {
        return true;
    }
    return std::any_of(value.begin(), value.end(), [](char ch) {
        const auto byte = static_cast<unsigned char>(ch);
        return byte <= 0x20U || byte == 0x7fU;
    });
}

bool ParseIpv4(std::string_view value, std::array<std::uint8_t, 4>& octets) {
    std::size_t start = 0;
    for (std::size_t index = 0; index < octets.size(); ++index) {
        const std::size_t end = value.find('.', start);
        if ((index < octets.size() - 1U && end == std::string_view::npos) ||
            (index == octets.size() - 1U && end != std::string_view::npos)) {
            return false;
        }
        const std::size_t stop = end == std::string_view::npos ? value.size() : end;
        const std::string_view part = value.substr(start, stop - start);
        if (part.empty() || part.size() > 3U || (part.size() > 1U && part.front() == '0')) {
            return false;
        }
        std::uint32_t parsed = 0;
        for (char ch : part) {
            if (ch < '0' || ch > '9') {
                return false;
            }
            parsed = parsed * 10U + static_cast<std::uint32_t>(ch - '0');
        }
        if (parsed > 255U) {
            return false;
        }
        octets[index] = static_cast<std::uint8_t>(parsed);
        start = stop + 1U;
    }
    return true;
}

std::string CanonicalIpv4(const std::array<std::uint8_t, 4>& octets) {
    return std::to_string(octets[0]) + "." + std::to_string(octets[1]) + "." +
        std::to_string(octets[2]) + "." + std::to_string(octets[3]);
}

std::array<std::uint16_t, 8> Ipv6Words(const in6_addr& address) {
    std::array<std::uint16_t, 8> words {};
    for (std::size_t index = 0; index < words.size(); ++index) {
        words[index] = static_cast<std::uint16_t>(
            (static_cast<std::uint16_t>(address.s6_addr[index * 2U]) << 8U) |
            static_cast<std::uint16_t>(address.s6_addr[index * 2U + 1U]));
    }
    return words;
}

std::string CanonicalIpv6(const in6_addr& address) {
    const auto words = Ipv6Words(address);
    std::size_t bestStart = words.size();
    std::size_t bestLength = 0;
    std::size_t index = 0;
    while (index < words.size()) {
        if (words[index] != 0U) {
            ++index;
            continue;
        }
        const std::size_t start = index;
        while (index < words.size() && words[index] == 0U) {
            ++index;
        }
        const std::size_t length = index - start;
        if (length >= 2U && length > bestLength) {
            bestStart = start;
            bestLength = length;
        }
    }

    std::ostringstream output;
    output << std::hex << std::nouppercase;
    index = 0;
    while (index < words.size()) {
        if (index == bestStart) {
            output << "::";
            index += bestLength;
            continue;
        }
        const std::string current = output.str();
        if (!current.empty() && current.back() != ':') {
            output << ':';
        }
        output << words[index];
        ++index;
    }
    return output.str();
}

std::string ParseScope(std::string_view value) {
    if (value.empty() || value.size() > 32U ||
        !std::isalpha(static_cast<unsigned char>(value.front()))) {
        return {};
    }
    for (char ch : value) {
        const auto byte = static_cast<unsigned char>(ch);
        if (std::isalnum(byte) == 0 && ch != '_' && ch != '.' && ch != '-') {
            return {};
        }
    }
    return std::string(value);
}

std::string CanonicalHostname(std::string value) {
    if (!value.empty() && value.back() == '.') {
        value.pop_back();
    }
    if (value.empty() || value.size() > 253U || value.front() == '.' || value.back() == '.' ||
        value.find("..") != std::string::npos) {
        return {};
    }
    std::size_t start = 0;
    while (start < value.size()) {
        const std::size_t end = value.find('.', start);
        const std::size_t stop = end == std::string::npos ? value.size() : end;
        const std::string_view label(value.data() + start, stop - start);
        if (label.empty() || label.size() > 63U || label.front() == '-' || label.back() == '-') {
            return {};
        }
        for (char ch : label) {
            const auto byte = static_cast<unsigned char>(ch);
            if (byte > 0x7fU || (std::isalnum(byte) == 0 && ch != '-')) {
                return {};
            }
        }
        start = stop + 1U;
    }
    std::transform(value.begin(), value.end(), value.begin(), [](char ch) {
        return static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    });
    return value;
}

std::string FamilyText(AddressFamily family) {
    switch (family) {
        case AddressFamily::Hostname:
            return "hostname";
        case AddressFamily::Ipv4:
            return "ipv4";
        case AddressFamily::Ipv6:
            return "ipv6";
    }
    return "hostname";
}

std::string LengthPrefixed(const std::string& value) {
    return std::to_string(value.size()) + ":" + value;
}

} // namespace

ParseResult ParseHost(const std::string& input) {
    const std::string source = Trim(input);
    if (source.empty()) {
        return Failed(AddressError::Empty);
    }
    if (InvalidEndpointCharacters(source)) {
        return Failed(AddressError::InvalidSyntax);
    }

    std::string host = source;
    if (source.front() == '[') {
        if (source.size() < 3U || source.back() != ']' || source.find(']') != source.size() - 1U) {
            return Failed(AddressError::InvalidSyntax);
        }
        host = source.substr(1U, source.size() - 2U);
    } else if (source.find('[') != std::string::npos || source.find(']') != std::string::npos) {
        return Failed(AddressError::InvalidSyntax);
    }

    std::string scope;
    const std::size_t percent = host.find('%');
    if (percent != std::string::npos) {
        if (host.find('%', percent + 1U) != std::string::npos) {
            return Failed(AddressError::InvalidSyntax);
        }
        scope = ParseScope(std::string_view(host).substr(percent + 1U));
        if (scope.empty()) {
            return Failed(AddressError::ScopeNotPortable);
        }
        host.resize(percent);
    }

    std::array<std::uint8_t, 4> octets {};
    if (ParseIpv4(host, octets)) {
        if (!scope.empty()) {
            return Failed(AddressError::ScopeNotAllowed);
        }
        return Succeeded(CanonicalIpv4(octets), AddressFamily::Ipv4);
    }

    in6_addr ipv6 {};
    if (::inet_pton(AF_INET6, host.c_str(), &ipv6) == 1) {
        if (IN6_IS_ADDR_UNSPECIFIED(&ipv6) || IN6_IS_ADDR_V4MAPPED(&ipv6) ||
            IN6_IS_ADDR_MULTICAST(&ipv6)) {
            return Failed(AddressError::AddressNotConnectable);
        }
        if (IN6_IS_ADDR_LINKLOCAL(&ipv6) && scope.empty()) {
            return Failed(AddressError::ScopeRequired);
        }
        if (!IN6_IS_ADDR_LINKLOCAL(&ipv6) && !scope.empty()) {
            return Failed(AddressError::ScopeNotAllowed);
        }
        return Succeeded(CanonicalIpv6(ipv6), AddressFamily::Ipv6, std::move(scope));
    }

    if (host.find(':') != std::string::npos) {
        return Failed(AddressError::InvalidIpv6);
    }
    if (host.find('.') != std::string::npos &&
        std::all_of(host.begin(), host.end(), [](char ch) { return ch == '.' || (ch >= '0' && ch <= '9'); })) {
        return Failed(AddressError::InvalidIpv4);
    }
    if (!scope.empty()) {
        return Failed(AddressError::ScopeNotAllowed);
    }
    std::string hostname = CanonicalHostname(host);
    return hostname.empty() ? Failed(AddressError::InvalidHostname) :
        Succeeded(std::move(hostname), AddressFamily::Hostname);
}

ParseResult ParseAuthority(const std::string& input, std::uint16_t defaultPort) {
    if (!ValidPort(defaultPort)) {
        return Failed(AddressError::InvalidPort);
    }
    const std::string source = Trim(input);
    if (source.empty()) {
        return Failed(AddressError::Empty);
    }
    std::string hostText = source;
    std::uint16_t port = defaultPort;
    if (source.front() == '[') {
        const std::size_t close = source.find(']');
        if (close <= 1U) {
            return Failed(AddressError::InvalidSyntax);
        }
        hostText = source.substr(0U, close + 1U);
        const std::string_view suffix(source.data() + close + 1U, source.size() - close - 1U);
        if (!suffix.empty()) {
            if (suffix.front() != ':') {
                return Failed(AddressError::InvalidSyntax);
            }
            port = ParsePort(suffix.substr(1U));
            if (port == 0U) {
                return Failed(AddressError::InvalidPort);
            }
        }
    } else {
        const std::size_t firstColon = source.find(':');
        const std::size_t lastColon = source.rfind(':');
        if (firstColon != std::string::npos && firstColon > 0U && firstColon == lastColon) {
            hostText = source.substr(0U, firstColon);
            port = ParsePort(std::string_view(source).substr(firstColon + 1U));
            if (port == 0U) {
                return Failed(AddressError::InvalidPort);
            }
        }
    }
    ParseResult parsed = ParseHost(hostText);
    if (!parsed.ok) {
        return parsed;
    }
    parsed.endpoint.port = port;
    return parsed;
}

std::string TransportHost(const Address& endpoint) {
    if (endpoint.family != AddressFamily::Ipv6 || endpoint.scope.empty()) {
        return endpoint.canonicalHost;
    }
    return endpoint.canonicalHost + "%" + endpoint.scope;
}

std::string FormatHostPort(const Address& endpoint) {
    const std::string host = TransportHost(endpoint);
    if (endpoint.port == 0U) {
        return host;
    }
    if (endpoint.family == AddressFamily::Ipv6) {
        return "[" + host + "]:" + std::to_string(endpoint.port);
    }
    return host + ":" + std::to_string(endpoint.port);
}

std::string IdentityV2(const Address& endpoint, const std::string& canonicalServerName) {
    return "endpoint-v2|family=" + LengthPrefixed(FamilyText(endpoint.family)) +
        "|host=" + LengthPrefixed(endpoint.canonicalHost) +
        "|scope=" + LengthPrefixed(endpoint.scope) +
        "|port=" + std::to_string(endpoint.port) +
        "|server=" + LengthPrefixed(canonicalServerName);
}

} // namespace remotedesk::endpoint
