#include "common/endpoint_address_policy.h"

#include <arpa/inet.h>

#include <algorithm>
#include <array>
#include <sstream>
#include <string_view>
#include <utility>

namespace remotedesk::endpoint {
namespace {

ParseResult Failed(AddressError error) {
    ParseResult result;
    result.error = error;
    return result;
}

ParseResult Succeeded(
    std::string host,
    AddressFamily family,
    std::string scope = {},
    ScopeKind scopeKind = ScopeKind::None) {
    ParseResult result;
    result.ok = true;
    result.error = AddressError::None;
    result.endpoint = Address(std::move(host), family, 0U, std::move(scope), scopeKind);
    return result;
}

bool IsAsciiAlpha(char ch) {
    return (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z');
}

bool IsAsciiDigit(char ch) {
    return ch >= '0' && ch <= '9';
}

bool IsAsciiAlnum(char ch) {
    return IsAsciiAlpha(ch) || IsAsciiDigit(ch);
}

char AsciiLower(char ch) {
    return ch >= 'A' && ch <= 'Z' ? static_cast<char>(ch + ('a' - 'A')) : ch;
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
        if (!IsAsciiDigit(ch)) {
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
        return byte < 0x21U || byte > 0x7eU;
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
            if (!IsAsciiDigit(ch)) {
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

ScopeKind ParseScope(std::string_view value, ParseMode mode) {
    if (!value.empty() && std::all_of(value.begin(), value.end(), IsAsciiDigit)) {
        if (mode != ParseMode::Runtime || value.size() > 10U) {
            return ScopeKind::None;
        }
        std::uint64_t numeric = 0U;
        for (char ch : value) {
            numeric = numeric * 10U + static_cast<std::uint64_t>(ch - '0');
        }
        return numeric >= 1U && numeric <= 0xffffffffULL ? ScopeKind::Numeric : ScopeKind::None;
    }
    if (value.empty() || value.size() > 32U || !IsAsciiAlpha(value.front())) {
        return ScopeKind::None;
    }
    for (char ch : value) {
        if (!IsAsciiAlnum(ch) && ch != '_' && ch != '.' && ch != '-') {
            return ScopeKind::None;
        }
    }
    return ScopeKind::Interface;
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
            if (!IsAsciiAlnum(ch) && ch != '-') {
                return {};
            }
        }
        start = stop + 1U;
    }
    std::transform(value.begin(), value.end(), value.begin(), AsciiLower);
    return value;
}

bool LegacyNumericHost(std::string_view value) {
    std::size_t start = 0U;
    while (start < value.size()) {
        const std::size_t end = value.find('.', start);
        const std::size_t stop = end == std::string_view::npos ? value.size() : end;
        const std::string_view label = value.substr(start, stop - start);
        const bool decimal = !label.empty() && std::all_of(label.begin(), label.end(), IsAsciiDigit);
        const bool hexadecimal = label.size() > 2U && label[0] == '0' &&
            (label[1] == 'x' || label[1] == 'X') &&
            std::all_of(label.begin() + 2, label.end(), [](char ch) {
                return IsAsciiDigit(ch) || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F');
            });
        if (!decimal && !hexadecimal) {
            return false;
        }
        if (end == std::string_view::npos) {
            return true;
        }
        start = end + 1U;
    }
    return false;
}

bool Ipv4NotConnectable(const std::array<std::uint8_t, 4>& octets) {
    return octets[0] == 0U || octets[0] >= 224U;
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

std::string ServerIdentityKindText(ServerIdentityKind kind) {
    switch (kind) {
        case ServerIdentityKind::None:
            return "none";
        case ServerIdentityKind::Dns:
            return "dns";
        case ServerIdentityKind::Ip:
            return "ip";
    }
    return "none";
}

bool EndpointMatchesCanonicalPolicy(const Address& endpoint) {
    if (endpoint.version() != kAddressVersion || !ValidPort(endpoint.port()) ||
        endpoint.scopeKind() == ScopeKind::Numeric) {
        return false;
    }
    std::string input = endpoint.canonicalHost();
    if (endpoint.family() == AddressFamily::Ipv6 && !endpoint.scope().empty()) {
        input += "%" + endpoint.scope();
    }
    const ParseResult parsed = ParseHost(input, ParseMode::Persisted);
    return parsed.ok && parsed.endpoint.canonicalHost() == endpoint.canonicalHost() &&
        parsed.endpoint.family() == endpoint.family() && parsed.endpoint.scope() == endpoint.scope() &&
        parsed.endpoint.scopeKind() == endpoint.scopeKind();
}

} // namespace

Address::Address(
    std::string canonicalHost,
    AddressFamily family,
    std::uint16_t port,
    std::string scope,
    ScopeKind scopeKind,
    std::uint32_t version)
    : version_(version),
      canonicalHost_(std::move(canonicalHost)),
      family_(family),
      port_(port),
      scope_(std::move(scope)),
      scopeKind_(scopeKind) {}

std::uint32_t Address::version() const noexcept {
    return version_;
}

const std::string& Address::canonicalHost() const noexcept {
    return canonicalHost_;
}

AddressFamily Address::family() const noexcept {
    return family_;
}

std::uint16_t Address::port() const noexcept {
    return port_;
}

const std::string& Address::scope() const noexcept {
    return scope_;
}

ScopeKind Address::scopeKind() const noexcept {
    return scopeKind_;
}

ServerIdentity::ServerIdentity(ServerIdentityKind kind, std::string canonicalName)
    : kind_(kind), canonicalName_(std::move(canonicalName)) {}

ServerIdentityKind ServerIdentity::kind() const noexcept {
    return kind_;
}

const std::string& ServerIdentity::canonicalName() const noexcept {
    return canonicalName_;
}

ParseResult ParseHost(const std::string& input, ParseMode mode) {
    const std::string& source = input;
    if (source.empty()) {
        return Failed(AddressError::Empty);
    }
    if (source.size() > kMaxInputLength) {
        return Failed(AddressError::InputTooLong);
    }
    if (InvalidEndpointCharacters(source)) {
        return Failed(AddressError::InvalidSyntax);
    }

    std::string host = source;
    bool bracketed = false;
    if (source.front() == '[') {
        if (source.size() < 3U || source.back() != ']' || source.find(']') != source.size() - 1U) {
            return Failed(AddressError::InvalidSyntax);
        }
        bracketed = true;
        host = source.substr(1U, source.size() - 2U);
    } else if (source.find('[') != std::string::npos || source.find(']') != std::string::npos) {
        return Failed(AddressError::InvalidSyntax);
    }

    std::string scope;
    ScopeKind scopeKind = ScopeKind::None;
    const std::size_t percent = host.find('%');
    if (percent != std::string::npos) {
        if (host.find('%', percent + 1U) != std::string::npos) {
            return Failed(AddressError::InvalidSyntax);
        }
        scope = host.substr(percent + 1U);
        scopeKind = ParseScope(scope, mode);
        if (scopeKind == ScopeKind::None) {
            return Failed(AddressError::ScopeNotPortable);
        }
        host.resize(percent);
    }

    std::array<std::uint8_t, 4> octets {};
    if (ParseIpv4(host, octets)) {
        if (bracketed) {
            return Failed(AddressError::InvalidSyntax);
        }
        if (!scope.empty()) {
            return Failed(AddressError::ScopeNotAllowed);
        }
        if (Ipv4NotConnectable(octets)) {
            return Failed(AddressError::AddressNotConnectable);
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
        return Succeeded(
            CanonicalIpv6(ipv6), AddressFamily::Ipv6, std::move(scope), scopeKind);
    }

    if (host.find(':') != std::string::npos) {
        return Failed(AddressError::InvalidIpv6);
    }
    if ((host.find('.') != std::string::npos &&
        std::all_of(host.begin(), host.end(), [](char ch) { return ch == '.' || IsAsciiDigit(ch); })) ||
        LegacyNumericHost(host)) {
        return Failed(AddressError::InvalidIpv4);
    }
    if (bracketed) {
        return Failed(AddressError::InvalidSyntax);
    }
    if (!scope.empty()) {
        return Failed(AddressError::ScopeNotAllowed);
    }
    std::string hostname = CanonicalHostname(host);
    return hostname.empty() ? Failed(AddressError::InvalidHostname) :
        Succeeded(std::move(hostname), AddressFamily::Hostname);
}

ParseResult ParseAuthority(const std::string& input, std::uint16_t defaultPort, ParseMode mode) {
    if (!ValidPort(defaultPort)) {
        return Failed(AddressError::InvalidPort);
    }
    const std::string& source = input;
    if (source.empty()) {
        return Failed(AddressError::Empty);
    }
    if (source.size() > kMaxInputLength) {
        return Failed(AddressError::InputTooLong);
    }
    if (InvalidEndpointCharacters(source)) {
        return Failed(AddressError::InvalidSyntax);
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
    ParseResult parsed = ParseHost(hostText, mode);
    if (!parsed.ok) {
        return parsed;
    }
    parsed.endpoint = Address(
        parsed.endpoint.canonicalHost(),
        parsed.endpoint.family(),
        port,
        parsed.endpoint.scope(),
        parsed.endpoint.scopeKind(),
        parsed.endpoint.version());
    return parsed;
}

std::string TransportHost(const Address& endpoint) {
    if (endpoint.family() != AddressFamily::Ipv6 || endpoint.scope().empty()) {
        return endpoint.canonicalHost();
    }
    return endpoint.canonicalHost() + "%" + endpoint.scope();
}

std::string FormatHostPort(const Address& endpoint) {
    const std::string host = TransportHost(endpoint);
    if (endpoint.port() == 0U) {
        return host;
    }
    if (endpoint.family() == AddressFamily::Ipv6) {
        return "[" + host + "]:" + std::to_string(endpoint.port());
    }
    return host + ":" + std::to_string(endpoint.port());
}

std::string FormatUriAuthority(const Address& endpoint) {
    std::string host = endpoint.canonicalHost();
    if (endpoint.family() == AddressFamily::Ipv6 && !endpoint.scope().empty()) {
        host += "%25" + endpoint.scope();
    }
    if (endpoint.port() == 0U) {
        return endpoint.family() == AddressFamily::Ipv6 ? "[" + host + "]" : host;
    }
    return endpoint.family() == AddressFamily::Ipv6 ?
        "[" + host + "]:" + std::to_string(endpoint.port()) :
        host + ":" + std::to_string(endpoint.port());
}

ServerIdentityResult ParseServerIdentity(const std::string& input) {
    ServerIdentityResult result;
    if (input.empty()) {
        result.ok = true;
        result.error = IdentityError::None;
        return result;
    }
    if (input.size() > 253U || InvalidEndpointCharacters(input) ||
        input.find('%') != std::string::npos || input.find('[') != std::string::npos ||
        input.find(']') != std::string::npos) {
        return result;
    }
    std::array<std::uint8_t, 4> octets {};
    if (ParseIpv4(input, octets)) {
        if (Ipv4NotConnectable(octets)) {
            return result;
        }
        result.ok = true;
        result.error = IdentityError::None;
        result.identity = ServerIdentity(ServerIdentityKind::Ip, CanonicalIpv4(octets));
        return result;
    }
    in6_addr ipv6 {};
    if (::inet_pton(AF_INET6, input.c_str(), &ipv6) == 1) {
        if (IN6_IS_ADDR_UNSPECIFIED(&ipv6) || IN6_IS_ADDR_V4MAPPED(&ipv6) ||
            IN6_IS_ADDR_MULTICAST(&ipv6)) {
            return result;
        }
        result.ok = true;
        result.error = IdentityError::None;
        result.identity = ServerIdentity(ServerIdentityKind::Ip, CanonicalIpv6(ipv6));
        return result;
    }
    if (input.find(':') != std::string::npos || LegacyNumericHost(input)) {
        return result;
    }
    std::string hostname = CanonicalHostname(input);
    if (hostname.empty()) {
        return result;
    }
    result.ok = true;
    result.error = IdentityError::None;
    result.identity = ServerIdentity(ServerIdentityKind::Dns, std::move(hostname));
    return result;
}

IdentityResult IdentityV2(const Address& endpoint, const ServerIdentity& serverIdentity) {
    IdentityResult result;
    if (!EndpointMatchesCanonicalPolicy(endpoint)) {
        return result;
    }
    ServerIdentity effective = serverIdentity;
    if (serverIdentity.kind() == ServerIdentityKind::None && serverIdentity.canonicalName().empty()) {
        effective = ServerIdentity(
            endpoint.family() == AddressFamily::Hostname ?
                ServerIdentityKind::Dns : ServerIdentityKind::Ip,
            endpoint.canonicalHost());
    } else {
        const ServerIdentityResult validated = ParseServerIdentity(serverIdentity.canonicalName());
        if (!validated.ok || validated.identity.kind() != serverIdentity.kind() ||
            validated.identity.canonicalName() != serverIdentity.canonicalName()) {
            result.error = IdentityError::InvalidServerIdentity;
            return result;
        }
    }
    result.ok = true;
    result.error = IdentityError::None;
    result.identity = "endpoint-v2|family=" + LengthPrefixed(FamilyText(endpoint.family())) +
        "|host=" + LengthPrefixed(endpoint.canonicalHost()) +
        "|scope=" + LengthPrefixed(endpoint.scope()) +
        "|port=" + std::to_string(endpoint.port()) +
        "|server-kind=" + LengthPrefixed(ServerIdentityKindText(effective.kind())) +
        "|server=" + LengthPrefixed(effective.canonicalName());
    return result;
}

} // namespace remotedesk::endpoint
