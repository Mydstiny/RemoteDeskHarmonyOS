/**
 * rdp_gateway_policy.h - RDP endpoint and certificate-stage policy.
 *
 * The route is deliberately explicit.  A port number or an HTTP-looking
 * response must never be used to infer that an endpoint is an RD Gateway.
 */

#pragma once

#include "rdp_certificate_policy.h"

#include <chrono>
#include <cstdint>
#include <string>

enum class RdpEndpointMode {
    DirectRdp,
    TransparentTcpRdp,
    MicrosoftRdGateway,
    VendorHttpsBastion,
    AzureBastion,
    UnknownGateway
};

enum class RdpGatewayTransport {
    Auto,
    Http,
    Rpc,
    Websocket,
    NoWebsockets
};

struct RdpGatewayTransportFlags {
    bool rpc = true;
    bool http = true;
    bool websockets = true;
};

struct RdpEndpointRoute {
    RdpEndpointMode endpointMode = RdpEndpointMode::DirectRdp;
    std::string targetHost;
    int targetPort = 3389;
    std::string targetServerName;
    std::string gatewayHost;
    int gatewayPort = 443;
    std::string gatewayServerName;
    RdpGatewayTransport gatewayTransport = RdpGatewayTransport::Auto;
};

struct RdpCertificateRecord {
    bool present = false;
    bool rootTrusted = false;
    bool hostMismatch = false;
    int flags = 0;
    std::string host;
    int port = 0;
    std::string stage = "target";
    std::string serverName;
    std::string commonName;
    std::string subject;
    std::string issuer;
    std::string fingerprintSha256;
    int64_t notBeforeMs = 0;
    int64_t notAfterMs = 0;
};

struct RdpPreflightRequest {
    RdpEndpointRoute route;
    std::string username;
    std::string password;
    std::string domain;
    // Restricted Admin material is a target-only NTLM hash. It cannot be
    // reused as the Gateway password, so this route is fail-closed until a
    // separate Gateway credential contract exists.
    bool targetRestrictedAdmin = false;
    std::string expectedTargetFingerprintSha256;
    std::string expectedGatewayFingerprintSha256;
    bool targetAllowUntrustedRoot = false;
    bool targetAllowHostMismatch = false;
    bool gatewayAllowUntrustedRoot = false;
    bool gatewayAllowHostMismatch = false;
    uint64_t generation = 0;
    std::string requestId;
};

struct RdpPreflightResult {
    bool ok = false;
    RdpEndpointMode endpointMode = RdpEndpointMode::DirectRdp;
    std::string routeIdentity;
    uint64_t generation = 0;
    std::string requestId;
    std::string stage = "endpoint";
    std::string errorCode;
    std::string errorMessage;
    // `gatewayTransportSelected` is retained for ABI compatibility, but it
    // has always represented the requested policy rather than a wire fact.
    std::string gatewayTransportRequested = "auto";
    std::string gatewayTransportNegotiated = "unknown";
    std::string gatewayTransportSelected = "auto";
    bool requiresGatewayAuth = false;
    bool requiresUserDecision = false;
    RdpCertificateRecord gatewayCertificate;
    RdpCertificateRecord targetCertificate;
};

namespace RdpGatewayPolicy {

inline constexpr const char* kUnknownGatewayTransport = "unknown";

inline bool isKnownNegotiatedGatewayTransport(const std::string& value) {
    return value == kUnknownGatewayTransport || value == "http" ||
        value == "rpc" || value == "websocket";
}

inline bool setNegotiatedGatewayTransport(RdpPreflightResult& result,
                                          const std::string& observed) {
    const std::string value = observed.empty() ? kUnknownGatewayTransport : observed;
    if (!isKnownNegotiatedGatewayTransport(value)) {
        result.gatewayTransportNegotiated = kUnknownGatewayTransport;
        return false;
    }
    result.gatewayTransportNegotiated = value;
    return true;
}

inline const char* gatewayTransportName(RdpGatewayTransport transport);

inline void initializeGatewayTransportResult(RdpPreflightResult& result,
                                             RdpGatewayTransport requested) {
    result.gatewayTransportRequested = gatewayTransportName(requested);
    // Existing consumers read this field as the configured policy. Preserve
    // that behavior while exposing the two meanings explicitly.
    result.gatewayTransportSelected = result.gatewayTransportRequested;
    setNegotiatedGatewayTransport(result, kUnknownGatewayTransport);
}

struct RdpGatewayTransportObservation {
    // This is deliberately a small recording contract. A real FreeRDP
    // transport observer may fill it; absent such evidence the negotiated
    // value remains unknown and must not be inferred from the requested mode.
    bool gatewayTlsEstablished = false;
    bool targetTlsEstablished = false;
    bool targetRdpOverTunnel = false;
    bool gatewayReceivedRdpX224 = false;
    std::string negotiatedTransport = kUnknownGatewayTransport;
};

inline bool gatewayProtocolEvidenceIsComplete(
    const RdpGatewayTransportObservation& observation) {
    return observation.gatewayTlsEstablished && observation.targetTlsEstablished &&
        observation.targetRdpOverTunnel && !observation.gatewayReceivedRdpX224 &&
        observation.negotiatedTransport != kUnknownGatewayTransport &&
        isKnownNegotiatedGatewayTransport(observation.negotiatedTransport);
}

inline const char* endpointModeName(RdpEndpointMode mode) {
    switch (mode) {
        case RdpEndpointMode::DirectRdp: return "direct_rdp";
        case RdpEndpointMode::TransparentTcpRdp: return "transparent_tcp_rdp";
        case RdpEndpointMode::MicrosoftRdGateway: return "microsoft_rd_gateway";
        case RdpEndpointMode::VendorHttpsBastion: return "vendor_https_bastion";
        case RdpEndpointMode::AzureBastion: return "azure_bastion";
        case RdpEndpointMode::UnknownGateway: return "unknown_gateway";
    }
    return "unknown_gateway";
}

inline const char* gatewayTransportName(RdpGatewayTransport transport) {
    switch (transport) {
        case RdpGatewayTransport::Auto: return "auto";
        case RdpGatewayTransport::Http: return "http";
        case RdpGatewayTransport::Rpc: return "rpc";
        case RdpGatewayTransport::Websocket: return "websocket";
        case RdpGatewayTransport::NoWebsockets: return "no-websockets";
    }
    return "auto";
}

inline bool parseEndpointMode(const std::string& value, RdpEndpointMode& out) {
    if (value.empty() || value == "direct_rdp") {
        out = RdpEndpointMode::DirectRdp;
        return true;
    }
    if (value == "transparent_tcp_rdp") {
        out = RdpEndpointMode::TransparentTcpRdp;
        return true;
    }
    if (value == "microsoft_rd_gateway") {
        out = RdpEndpointMode::MicrosoftRdGateway;
        return true;
    }
    if (value == "vendor_https_bastion") {
        out = RdpEndpointMode::VendorHttpsBastion;
        return true;
    }
    if (value == "azure_bastion") {
        out = RdpEndpointMode::AzureBastion;
        return true;
    }
    if (value == "unknown_gateway") {
        out = RdpEndpointMode::UnknownGateway;
        return true;
    }
    return false;
}

inline bool parseGatewayTransport(const std::string& value, RdpGatewayTransport& out) {
    if (value.empty() || value == "auto") {
        out = RdpGatewayTransport::Auto;
        return true;
    }
    if (value == "http") {
        out = RdpGatewayTransport::Http;
        return true;
    }
    if (value == "rpc") {
        out = RdpGatewayTransport::Rpc;
        return true;
    }
    if (value == "websocket") {
        out = RdpGatewayTransport::Websocket;
        return true;
    }
    if (value == "no-websockets") {
        out = RdpGatewayTransport::NoWebsockets;
        return true;
    }
    return false;
}

inline RdpGatewayTransportFlags transportFlags(RdpGatewayTransport transport) {
    switch (transport) {
        case RdpGatewayTransport::Rpc:
            return {true, false, false};
        case RdpGatewayTransport::Http:
            return {false, true, true};
        case RdpGatewayTransport::Websocket:
            return {false, true, true};
        case RdpGatewayTransport::NoWebsockets:
            return {false, true, false};
        case RdpGatewayTransport::Auto:
            return {true, true, true};
    }
    return {};
}

inline std::string routeIdentity(const RdpEndpointRoute& route) {
    const std::string targetName = route.targetServerName.empty()
        ? route.targetHost : route.targetServerName;
    const std::string gatewayName = route.gatewayServerName.empty()
        ? route.gatewayHost : route.gatewayServerName;
    return std::string(endpointModeName(route.endpointMode)) + "|target=" +
        route.targetHost + ":" + std::to_string(route.targetPort) + ":" + targetName +
        "|gateway=" + route.gatewayHost + ":" + std::to_string(route.gatewayPort) + ":" +
        gatewayName + "|transport=" + gatewayTransportName(route.gatewayTransport);
}

inline bool isGatewayRoute(RdpEndpointMode mode) {
    return mode == RdpEndpointMode::MicrosoftRdGateway ||
        mode == RdpEndpointMode::VendorHttpsBastion ||
        mode == RdpEndpointMode::AzureBastion ||
        mode == RdpEndpointMode::UnknownGateway;
}

inline bool restrictedAdminGatewayRouteIsSupported(
    RdpEndpointMode endpointMode, bool targetRestrictedAdmin) {
    return !targetRestrictedAdmin || endpointMode != RdpEndpointMode::MicrosoftRdGateway;
}

inline bool isSupportedRdpRoute(RdpEndpointMode mode) {
    return mode == RdpEndpointMode::DirectRdp ||
        mode == RdpEndpointMode::TransparentTcpRdp ||
        mode == RdpEndpointMode::MicrosoftRdGateway;
}

inline std::string stageForCertificate(const RdpCertificateRecord& record) {
    return record.stage.empty() ? "target" : record.stage;
}

inline bool fingerprintMatchesStage(const RdpCertificateRecord& record,
                                    const std::string& expectedFingerprint) {
    return record.present && RdpCertificatePolicy::FingerprintMatches(
        expectedFingerprint, record.fingerprintSha256);
}

inline bool trustAllowsStage(const RdpCertificateRecord& record,
                             const std::string& expectedFingerprint,
                             bool allowUntrustedRoot,
                             bool allowHostMismatch) {
    // A stage is never trusted merely because the certificate is CA-valid.
    // Both Gateway and target routes require an explicit, stage-specific pin.
    if (!fingerprintMatchesStage(record, expectedFingerprint)) {
        return false;
    }
    if (!record.rootTrusted && !allowUntrustedRoot) {
        return false;
    }
    if (record.hostMismatch && !allowHostMismatch) {
        return false;
    }
    if (record.notBeforeMs <= 0 || record.notAfterMs <= record.notBeforeMs) {
        return false;
    }
    const int64_t nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    if (nowMs < record.notBeforeMs || nowMs > record.notAfterMs) {
        return false;
    }
    return true;
}

inline bool gatewayCertificateAllowsCredentialUse(
    const RdpPreflightRequest& request, const RdpCertificateRecord& gateway) {
    if (!gateway.present || gateway.notBeforeMs <= 0 ||
        gateway.notAfterMs <= gateway.notBeforeMs) {
        return false;
    }
    const int64_t nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    if (nowMs < gateway.notBeforeMs || nowMs > gateway.notAfterMs) {
        return false;
    }
    // A publicly trusted certificate with a matching SAN is safe for the
    // first Gateway authentication attempt. Private/self-signed or mismatched
    // certificates require an already confirmed, route-specific Gateway pin.
    if (gateway.rootTrusted && !gateway.hostMismatch) {
        return true;
    }
    return trustAllowsStage(
        gateway, request.expectedGatewayFingerprintSha256,
        request.gatewayAllowUntrustedRoot, request.gatewayAllowHostMismatch);
}

inline bool gatewayTrustAllowsRoute(const RdpPreflightRequest& request,
                                    const RdpCertificateRecord& gateway,
                                    const RdpCertificateRecord& target) {
    return trustAllowsStage(
               gateway, request.expectedGatewayFingerprintSha256,
               request.gatewayAllowUntrustedRoot, request.gatewayAllowHostMismatch) &&
        trustAllowsStage(
               target, request.expectedTargetFingerprintSha256,
               request.targetAllowUntrustedRoot, request.targetAllowHostMismatch);
}

} // namespace RdpGatewayPolicy
