/**
 * SSH transport route policy.
 *
 * Keep route names in one small, dependency-free policy so the NAPI boundary,
 * native transport and host-key preflight do not silently disagree about what
 * an SSH endpoint means.
 */
#ifndef SSH_ROUTE_POLICY_H
#define SSH_ROUTE_POLICY_H

#include <string>

inline bool sshRouteTypeIsKnown(const std::string& type) {
    return type.empty() || type == "direct" || type == "http_connect" ||
           type == "socks5" || type == "frp_tcp" || type == "ssh_jump";
}

inline bool sshRouteTypeUsesRawTcpEndpoint(const std::string& type) {
    return type == "direct" || type == "frp_tcp";
}

inline bool sshRouteTypeNeedsProxyEndpoint(const std::string& type) {
    return type == "http_connect" || type == "socks5" ||
           type == "frp_tcp" || type == "ssh_jump";
}

#endif
