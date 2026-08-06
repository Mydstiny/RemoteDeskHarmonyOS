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

inline constexpr int kSshProxyUnsupportedError = -19;

inline bool sshRouteTypeIsKnown(const std::string& type) {
    return type.empty() || type == "direct" || type == "http_connect" ||
           type == "socks5" || type == "frp_tcp" || type == "frp_visitor" ||
           type == "frp_stcp" || type == "frp_sudp" || type == "frp_xtcp" ||
           type == "ssh_jump";
}

inline bool sshRouteTypeUsesRawTcpEndpoint(const std::string& type) {
    return type == "direct" || type == "frp_tcp";
}

inline bool sshRouteTypeIsFrp(const std::string& type) {
    return type == "frp_tcp" || type == "frp_visitor" || type == "frp_stcp" ||
           type == "frp_sudp" || type == "frp_xtcp";
}

inline bool sshRouteTypeNeedsFrpControlPlane(const std::string& type) {
    return type == "frp_visitor" || type == "frp_stcp" || type == "frp_sudp" ||
           type == "frp_xtcp";
}

inline bool sshRouteTypeHasNativeTransport(const std::string& type) {
    return type.empty() || type == "direct" || type == "http_connect" ||
           type == "socks5" || type == "frp_tcp" || type == "ssh_jump";
}

inline bool sshRouteTypeNeedsProxyEndpoint(const std::string& type) {
    return type == "http_connect" || type == "socks5" ||
           type == "frp_tcp" || type == "frp_visitor" || type == "frp_stcp" ||
           type == "frp_sudp" || type == "frp_xtcp" || type == "ssh_jump";
}

#endif
