#include "ssh_proxy_target_policy.h"

namespace remotedesk::ssh {

ProxyTargetResult PrepareProxyTarget(
    const std::string& routeType,
    const std::string& host,
    std::uint16_t port) {
    ProxyTargetResult result;
    if (routeType != "direct" && routeType != "http_connect" &&
        routeType != "socks5" && routeType != "ssh_jump") {
        result.error = ProxyTargetError::UnsupportedRoute;
        return result;
    }
    const endpoint::ParseResult parsed = endpoint::ParseFields(
        host, port, endpoint::ParseMode::Persisted);
    if (!parsed.ok) {
        result.error = ProxyTargetError::InvalidEndpoint;
        return result;
    }
    if (routeType != "direct" && !parsed.endpoint.scope().empty()) {
        result.error = ProxyTargetError::RemoteScopeForbidden;
        return result;
    }
    result.ok = true;
    result.error = ProxyTargetError::None;
    result.endpoint = parsed.endpoint;
    result.transportHost = endpoint::TransportHost(parsed.endpoint);
    result.uriAuthority = endpoint::FormatUriAuthority(parsed.endpoint);
    return result;
}

} // namespace remotedesk::ssh
