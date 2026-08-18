#include "moonlight/runtime/MoonlightHttpRequestFormatting.h"

#include <arpa/inet.h>

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

    const bool ipv6Literal = authorityHost.find(':') != std::string_view::npos;
    const std::string portText = std::to_string(port);
    output.reserve(4U + target.size() + 17U + authorityHost.size() + portText.size() +
                   (ipv6Literal ? 2U : 0U) + 63U);
    output.append("GET ");
    output.append(target.data(), target.size());
    output.append(" HTTP/1.1\r\nHost: ");
    if (ipv6Literal) {
        output.push_back('[');
    }
    output.append(authorityHost.data(), authorityHost.size());
    if (ipv6Literal) {
        output.push_back(']');
    }
    output.push_back(':');
    output.append(portText);
    output.append("\r\nAccept: application/xml, */*\r\nConnection: close\r\n\r\n");
    return true;
}

std::optional<std::string> moonlightTlsServerName(
    std::string_view connectAddress) {
    if (!safeAuthorityHost(connectAddress) ||
        connectAddress.find(':') != std::string_view::npos) {
        return std::nullopt;
    }
    const std::string value(connectAddress);
    in_addr ipv4 {};
    if (::inet_pton(AF_INET, value.c_str(), &ipv4) == 1) {
        return std::nullopt;
    }
    return value;
}

} // namespace remotedesk::moonlight
