#include "moonlight/runtime/MoonlightHttpRequestFormatting.h"

#include "common/endpoint_address_policy.h"

#include <algorithm>

namespace remotedesk::moonlight {
namespace {

constexpr std::size_t kMaximumAuthorityHostBytes = 255U;
constexpr std::size_t kMaximumTargetBytes = 8U * 1024U;

bool safeAuthorityHost(std::string_view value) noexcept {
    if (value.empty() || value.size() > kMaximumAuthorityHostBytes ||
        value.front() == '[' || value.back() == ']') {
        return false;
    }
    return std::all_of(value.begin(), value.end(), [](unsigned char character) {
        if (character <= 0x20U || character >= 0x7fU) {
            return false;
        }
        switch (character) {
            case '/': case '?': case '#': case '@':
            case '[': case ']':
                return false;
            default:
                return true;
        }
    });
}

bool safeOriginForm(std::string_view value) noexcept {
    if (value.empty() || value.size() > kMaximumTargetBytes || value.front() != '/') {
        return false;
    }
    return std::all_of(value.begin(), value.end(), [](unsigned char character) {
        return character > 0x20U && character < 0x7fU && character != '#';
    });
}

} // namespace

bool buildMoonlightHttp11GetRequest(std::string_view authorityHost,
                                    std::uint16_t port,
                                    std::string_view target,
                                    std::string& output) {
    output.clear();
    if (port == 0U || !safeAuthorityHost(authorityHost) || !safeOriginForm(target)) {
        return false;
    }

    const auto parsed = remotedesk::endpoint::ParseFields(
        std::string(authorityHost), port, remotedesk::endpoint::ParseMode::Runtime);
    if (!parsed.ok) { return false; }
    const std::string authority =
        remotedesk::endpoint::FormatUriAuthority(parsed.endpoint);
    output.reserve(4U + target.size() + 17U + authority.size() + 63U);
    output.append("GET ");
    output.append(target.data(), target.size());
    output.append(" HTTP/1.1\r\nHost: ");
    output.append(authority);
    output.append("\r\nAccept: application/xml, */*\r\nConnection: close\r\n\r\n");
    return true;
}

std::optional<std::string> moonlightTlsServerName(
    std::string_view serverName) {
    if (!safeAuthorityHost(serverName)) {
        return std::nullopt;
    }
    const auto parsed = remotedesk::endpoint::ParseServerIdentity(
        std::string(serverName));
    if (!parsed.ok || parsed.identity.kind() !=
        remotedesk::endpoint::ServerIdentityKind::Dns) {
        return std::nullopt;
    }
    return parsed.identity.canonicalName();
}

std::string moonlightHttpAuthorityHost(std::string_view serverName,
                                       std::string_view connectAddress) {
    if (!safeAuthorityHost(serverName) || !safeAuthorityHost(connectAddress)) {
        return {};
    }
    const auto identity = remotedesk::endpoint::ParseServerIdentity(
        std::string(serverName));
    if (!identity.ok || identity.identity.kind() ==
        remotedesk::endpoint::ServerIdentityKind::None) {
        return {};
    }
    if (identity.identity.kind() == remotedesk::endpoint::ServerIdentityKind::Ip) {
        const auto candidate = remotedesk::endpoint::ParseHost(
            std::string(connectAddress), remotedesk::endpoint::ParseMode::Runtime);
        if (candidate.ok && candidate.endpoint.canonicalHost() ==
            identity.identity.canonicalName()) {
            return std::string(connectAddress);
        }
    }
    return identity.identity.canonicalName();
}

} // namespace remotedesk::moonlight
