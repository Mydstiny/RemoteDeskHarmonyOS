/**
 * vnc_transport_policy.h - native VNC transport enablement contract.
 *
 * The ArkTS gateway policy is not a sufficient security boundary because a
 * native caller can construct ConnectionConfig directly. Keep the native
 * allowlist equally narrow until a versioned gateway contract is deployed.
 */
#ifndef VNC_TRANSPORT_POLICY_H
#define VNC_TRANSPORT_POLICY_H

#include "common/endpoint_address_policy.h"

#include <string>

inline bool vncNativeTransportIsAvailable(const std::string& transport) {
    return transport == "direct_tcp" || transport == "ultravnc_repeater";
}

/** A HarmonyOS VNC client is a viewer; mode2 is the repeater's server side. */
inline bool vncNativeRepeaterViewerModeIsAvailable(const std::string& mode) {
    return mode == "mode12";
}

inline bool vncEndpointIsIpLiteral(const std::string& value) {
    const auto parsed = remotedesk::endpoint::ParseHost(
        value, remotedesk::endpoint::ParseMode::Runtime);
    return parsed.ok &&
        (parsed.endpoint.family() == remotedesk::endpoint::AddressFamily::Ipv4 ||
         parsed.endpoint.family() == remotedesk::endpoint::AddressFamily::Ipv6);
}

/**
 * Normalize the socket endpoint while deriving the default certificate
 * identity from the scope-free canonical host. A link-local interface scope
 * is a routing attribute and must never become an IP SAN identity.
 */
inline bool vncNormalizeCertificateEndpoint(
    std::string& transportHost,
    int port,
    std::string& defaultServerName) {
    defaultServerName.clear();
    if (port < 1 || port > 65535) {
        return false;
    }
    const auto parsed = remotedesk::endpoint::ParseFields(
        transportHost, static_cast<std::uint16_t>(port),
        remotedesk::endpoint::ParseMode::Persisted);
    if (!parsed.ok) {
        return false;
    }
    transportHost = remotedesk::endpoint::TransportHost(parsed.endpoint);
    defaultServerName = parsed.endpoint.canonicalHost();
    return true;
}

inline bool vncResolveCertificateIdentity(
    const std::string& transportHost,
    const std::string& configuredServerName,
    std::string& identity,
    bool& sendSni) {
    identity.clear();
    sendSni = false;
    if (!configuredServerName.empty()) {
        const auto parsedIdentity =
            remotedesk::endpoint::ParseServerIdentity(configuredServerName);
        if (!parsedIdentity.ok) {
            return false;
        }
        identity = parsedIdentity.identity.canonicalName();
        sendSni = parsedIdentity.identity.kind() ==
            remotedesk::endpoint::ServerIdentityKind::Dns;
        return true;
    }

    const auto parsedHost = remotedesk::endpoint::ParseHost(
        transportHost, remotedesk::endpoint::ParseMode::Persisted);
    if (!parsedHost.ok) {
        return false;
    }
    identity = parsedHost.endpoint.canonicalHost();
    sendSni = parsedHost.endpoint.family() ==
        remotedesk::endpoint::AddressFamily::Hostname;
    return true;
}

inline bool vncFormatWebSocketAuthority(
    const std::string& transportHost,
    int port,
    std::string& authority) {
    authority.clear();
    if (port < 1 || port > 65535) {
        return false;
    }
    const auto parsed = remotedesk::endpoint::ParseFields(
        transportHost, static_cast<std::uint16_t>(port),
        remotedesk::endpoint::ParseMode::Persisted);
    if (!parsed.ok) {
        return false;
    }
    authority = remotedesk::endpoint::FormatUriAuthority(parsed.endpoint);
    return true;
}

#endif // VNC_TRANSPORT_POLICY_H
