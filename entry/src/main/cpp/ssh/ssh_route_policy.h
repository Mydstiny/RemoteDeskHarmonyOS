/**
 * SSH transport route policy.
 *
 * Keep route names in one small, dependency-free policy so the NAPI boundary,
 * native transport and host-key preflight do not silently disagree about what
 * an SSH endpoint means.
 */
#ifndef SSH_ROUTE_POLICY_H
#define SSH_ROUTE_POLICY_H

#include <cstdint>
#include <string>
#include <vector>

inline constexpr int kSshProxyUnsupportedError = -19;
inline constexpr size_t kSshMaxJumpHops = 3;

enum class SshRouteKind : uint8_t {
    Direct = 0,
    HttpConnect,
    Socks5,
    FrpTcp,
    SshJump,
    FrpVisitor,
    FrpStcp,
    FrpSudp,
    FrpXtcp,
};

struct SshJumpHop {
    std::string host;
    int port = 22;
    std::string username;
    std::string authMethod = "password";
    std::string expectedHostKeyRawBase64;
    std::string expectedHostKeyFingerprintSha256;
    uint32_t connectTimeoutMs = 10000;
};

/** Frozen route shape. Secrets are supplied through the transient handoff. */
struct SshRoute {
    uint32_t schemaVersion = 1;
    SshRouteKind kind = SshRouteKind::Direct;
    std::string endpointHost;
    int endpointPort = 22;
    std::vector<SshJumpHop> hops;
    std::string controlId;
    uint32_t connectTimeoutMs = 10000;
};

/** Per-hop secret material. This object only lives in a session handoff. */
struct SshJumpHopHandoff {
    std::string password;
    std::string privateKeyPem;
    std::string privateKeyPassphrase;
    std::vector<std::string> keyboardInteractiveResponses;
};

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

inline SshRouteKind sshRouteKindFromType(const std::string& type) {
    if (type == "http_connect") return SshRouteKind::HttpConnect;
    if (type == "socks5") return SshRouteKind::Socks5;
    if (type == "frp_tcp") return SshRouteKind::FrpTcp;
    if (type == "ssh_jump") return SshRouteKind::SshJump;
    if (type == "frp_visitor") return SshRouteKind::FrpVisitor;
    if (type == "frp_stcp") return SshRouteKind::FrpStcp;
    if (type == "frp_sudp") return SshRouteKind::FrpSudp;
    if (type == "frp_xtcp") return SshRouteKind::FrpXtcp;
    return SshRouteKind::Direct;
}

inline bool sshRouteHopsValid(const SshRoute& route) {
    if (route.schemaVersion == 0 || route.schemaVersion > 1) return false;
    if (route.hops.size() > kSshMaxJumpHops) return false;
    if (route.kind != SshRouteKind::SshJump && !route.hops.empty()) return false;
    if (route.kind == SshRouteKind::SshJump && route.hops.empty()) return false;
    for (const SshJumpHop& hop : route.hops) {
        if (hop.host.empty() || hop.port <= 0 || hop.port > 65535 ||
            hop.username.empty() || hop.connectTimeoutMs == 0 ||
            (hop.authMethod != "password" && hop.authMethod != "publickey" &&
             hop.authMethod != "kbd-interactive" &&
             hop.authMethod != "keyboard-interactive")) {
            return false;
        }
    }
    return route.endpointHost.empty() ||
        (route.endpointPort > 0 && route.endpointPort <= 65535);
}

#endif
