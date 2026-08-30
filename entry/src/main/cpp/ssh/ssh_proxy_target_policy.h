#pragma once

#include "common/endpoint_address_policy.h"

#include <cstdint>
#include <string>

namespace remotedesk::ssh {

enum class ProxyTargetError {
    None,
    UnsupportedRoute,
    InvalidEndpoint,
    RemoteScopeForbidden,
};

struct ProxyTargetResult {
    bool ok = false;
    ProxyTargetError error = ProxyTargetError::InvalidEndpoint;
    endpoint::Address endpoint;
    std::string transportHost;
    std::string uriAuthority;
};

/**
 * Validate an SSH target before opening the proxy socket.
 *
 * Only a direct connection resolves an interface scope in this device's
 * namespace. HTTP CONNECT, SOCKS5 and the final ProxyJump target are resolved
 * by another endpoint and therefore reject a local IPv6 zone identifier.
 */
ProxyTargetResult PrepareProxyTarget(
    const std::string& routeType,
    const std::string& host,
    std::uint16_t port);

} // namespace remotedesk::ssh
