/**
 * rdp_gateway_policy.h - RDP endpoint and certificate-stage policy.
 *
 * The route is deliberately explicit.  A port number or an HTTP-looking
 * response must never be used to infer that an endpoint is an RD Gateway.
 */

#pragma once

#include "rdp_certificate_policy.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cerrno>
#include <string>
#include <vector>

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
    std::vector<std::string> riskFlags;
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
    bool targetAllowTimeAnomaly = false;
    bool gatewayAllowUntrustedRoot = false;
    bool gatewayAllowHostMismatch = false;
    bool gatewayAllowTimeAnomaly = false;
    uint64_t generation = 0;
    std::string requestId;
};

struct RdpPreflightResult {
    bool ok = false;
    // `ok` means that a certificate record was observed. It is intentionally
    // independent from the diagnostic outcome of the probe.
    std::string preflightStatus = "unavailable";
    std::vector<std::string> riskFlags;
    std::vector<std::string> gatewayRiskFlags;
    std::vector<std::string> targetRiskFlags;
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

namespace RdpPreflightPolicy {

inline constexpr const char* kCompleted = "completed";
inline constexpr const char* kInconclusive = "inconclusive";
inline constexpr const char* kUnavailable = "unavailable";
inline constexpr const char* kTransportFailed = "transportFailed";

inline constexpr const char* kRiskUntrustedRoot = "UNTRUSTED_ROOT";
inline constexpr const char* kRiskHostnameMismatch = "HOSTNAME_MISMATCH";
inline constexpr const char* kRiskCertificateChanged = "CERTIFICATE_CHANGED";
inline constexpr const char* kRiskCertificateTimeInvalid = "CERTIFICATE_TIME_INVALID";
inline constexpr const char* kRiskCertificateMetadataUnavailable =
    "CERTIFICATE_METADATA_UNAVAILABLE";
inline constexpr const char* kRiskStandardRdpSecurity = "STANDARD_RDP_SECURITY";
inline constexpr const char* kRiskTlsProbeReset = "TLS_PROBE_RESET";
inline constexpr const char* kRiskGatewayCertificate = "GATEWAY_CERTIFICATE_RISK";
inline constexpr const char* kRiskTargetCertificate = "TARGET_CERTIFICATE_RISK";
inline constexpr const char* kRiskUnknownGatewayProtocol = "UNKNOWN_GATEWAY_PROTOCOL";

inline void addUniqueRiskFlag(std::vector<std::string>& flags, const std::string& flag) {
    if (flag.empty() || std::find(flags.begin(), flags.end(), flag) != flags.end()) {
        return;
    }
    flags.push_back(flag);
}

inline void mergeRiskFlags(std::vector<std::string>& destination,
                           const std::vector<std::string>& source) {
    for (const std::string& flag : source) {
        addUniqueRiskFlag(destination, flag);
    }
}

inline bool hasRiskFlag(const std::vector<std::string>& flags, const std::string& flag) {
    return std::find(flags.begin(), flags.end(), flag) != flags.end();
}

inline bool messageContains(const std::string& message, const std::string& value) {
    return message.find(value) != std::string::npos;
}

inline bool messageDescribesTlsProbeReset(const std::string& message) {
    return messageContains(message, "ECONNRESET") ||
        messageContains(message, "Connection reset") ||
        messageContains(message, "connection reset") ||
        messageContains(message, "unexpected EOF") ||
        messageContains(message, "unexpected eof") ||
        messageContains(message, "ZERO_RETURN") ||
        messageContains(message, "zero_return");
}

inline bool messageDescribesProbeTimeout(const std::string& message) {
    return messageContains(message, "ETIMEDOUT") ||
        messageContains(message, "Connection timed out") ||
        messageContains(message, "connection timed out") ||
        messageContains(message, "errno=" + std::to_string(ETIMEDOUT) + ":") ||
        messageContains(message, "errno=" + std::to_string(EAGAIN) + ":") ||
        messageContains(message, "errno=" + std::to_string(EWOULDBLOCK) + ":");
}

struct ProbeFailureClassification {
    std::string status = kUnavailable;
    std::vector<std::string> riskFlags;
};

inline ProbeFailureClassification classifyProbeFailure(int errorCode,
                                                       const std::string& message) {
    ProbeFailureClassification classification;
    const bool reset = messageDescribesTlsProbeReset(message) ||
        messageContains(message, "errno=" + std::to_string(ECONNRESET) + ":");
    const bool timedOut = messageDescribesProbeTimeout(message);
    switch (errorCode) {
        case -11:
        case -31:
            classification.status = kTransportFailed;
            break;
        case -12:
        case -32:
            classification.status = kTransportFailed;
            break;
        case -10:
        case -30:
            classification.status = kUnavailable;
            break;
        case -15:
        case -16:
        case -23:
        case -24:
        case -33:
        case -34:
        case -35:
            classification.status = kUnavailable;
            break;
        case -18:
            classification.status = kInconclusive;
            addUniqueRiskFlag(classification.riskFlags, kRiskStandardRdpSecurity);
            break;
        case -13:
        case -14:
            // TCP is already established when the manual X.224 probe writes
            // or reads its negotiation PDU. Only an actual timeout is a
            // transport failure. Other peer/protocol failures may be handled
            // by FreeRDP differently and therefore remain advisory.
            if (timedOut) {
                classification.status = kTransportFailed;
            } else {
                classification.status = kInconclusive;
                if (reset) {
                    addUniqueRiskFlag(classification.riskFlags, kRiskTlsProbeReset);
                }
            }
            break;
        case -17:
        case -37:
            classification.status = kInconclusive;
            addUniqueRiskFlag(classification.riskFlags, kRiskCertificateMetadataUnavailable);
            break;
        case -19:
        case -20:
        case -21:
        case -22:
        case -25:
        case -36:
            classification.status = kInconclusive;
            if (reset || errorCode == -22 || errorCode == -36) {
                addUniqueRiskFlag(classification.riskFlags, kRiskTlsProbeReset);
            }
            if (errorCode == -25) {
                addUniqueRiskFlag(classification.riskFlags, kRiskCertificateTimeInvalid);
            }
            break;
        case -38:
            classification.status = kInconclusive;
            addUniqueRiskFlag(classification.riskFlags, kRiskCertificateMetadataUnavailable);
            break;
        default:
            classification.status = kUnavailable;
            break;
    }
    return classification;
}

inline ProbeFailureClassification classifyErrorCode(const std::string& errorCode,
                                                    const std::string& message) {
    ProbeFailureClassification classification;
    const bool transportFailure =
        errorCode == "E-RDP-TARGET-DNS" || errorCode == "E-RDP-GATEWAY-DNS" ||
        errorCode == "E-RDP-TARGET-TCP" || errorCode == "E-RDP-GATEWAY-TCP";
    if (transportFailure) {
        classification.status = kTransportFailed;
    } else if (errorCode == "E-RDP-GATEWAY-TUNNEL" ||
               errorCode == "E-RDP-GATEWAY-AUTH") {
        classification.status = kTransportFailed;
    } else if (errorCode == "E-RDP-GATEWAY-AUTH-REQUIRED") {
        // The preflight did not receive credentials needed to inspect the
        // target. This is not an authentication rejection or tunnel failure;
        // let the real connection collect or use credentials after the user
        // acknowledges the incomplete diagnostic.
        classification.status = kInconclusive;
    } else if ((errorCode == "E-RDP-GATEWAY-TLS" || errorCode == "E-RDP-TARGET-TLS") &&
               (messageContains(message, "Unable to create FreeRDP") ||
                messageContains(message, "FreeRDP runtime"))) {
        // The preflight cannot run without its FreeRDP runtime. This is a
        // technical availability failure, not a certificate decision point.
        classification.status = kUnavailable;
    } else if (errorCode == "E-RDP-BASTION-UNSUPPORTED" ||
               errorCode == "E-RDP-GATEWAY-AWARE-UNAVAILABLE" ||
               errorCode == "E-RDP-ENDPOINT" ||
               errorCode == "E-RDP-GATEWAY-SNI") {
        classification.status = kUnavailable;
    } else {
        classification.status = kInconclusive;
    }
    if (errorCode == "E-RDP-BASTION-UNSUPPORTED" ||
        errorCode == "E-RDP-GATEWAY-AWARE-UNAVAILABLE") {
        addUniqueRiskFlag(classification.riskFlags, kRiskUnknownGatewayProtocol);
    }
    const bool gatewayProtocolUnavailable =
        errorCode == "E-RDP-BASTION-UNSUPPORTED" ||
        errorCode == "E-RDP-GATEWAY-AWARE-UNAVAILABLE";
    if (!transportFailure && !gatewayProtocolUnavailable &&
        errorCode != "E-RDP-GATEWAY-TUNNEL" &&
        errorCode != "E-RDP-GATEWAY-AUTH" &&
        (messageDescribesTlsProbeReset(message) ||
        messageContains(message, "TLS handshake failed") ||
        messageContains(message, "tls handshake failed"))) {
        addUniqueRiskFlag(classification.riskFlags, kRiskTlsProbeReset);
        classification.status = kInconclusive;
    }
    return classification;
}

// This is a routing rule, not a certificate-trust rule. Preflight TLS and
// certificate diagnostics must still reach the real FreeRDP callback after an
// explicit user choice. Only failures that make a connection impossible before
// any trust choice can block that handoff.
inline bool preflightAllowsRealConnection(const std::string& status,
                                          const std::string& errorCode,
                                          const std::vector<std::string>& riskFlags = {}) {
    // Certificate/TLS probe diagnostics are advisory even when an older
    // caller incorrectly labels them transportFailed.  The real FreeRDP
    // callback still requires the route-bound user decision; this merely
    // prevents the inspection transport from becoming that decision.
    if (errorCode == "E-RDP-TARGET-TLS" ||
        errorCode == "E-RDP-GATEWAY-TLS" ||
        errorCode == "E-RDP-TARGET-CERT" ||
        errorCode == "E-RDP-GATEWAY-CERT" ||
        errorCode == "E-RDP-CERT" ||
        errorCode == "E-RDP-NEGOTIATION" ||
        errorCode == "E-RDP-PREFLIGHT-NAPI" ||
        errorCode == "E-RDP-PREFLIGHT-EXCEPTION" ||
        errorCode == "E-RDP-BASTION-UNSUPPORTED" ||
        errorCode == "E-RDP-GATEWAY-AWARE-UNAVAILABLE" ||
        errorCode == "E-RDP-GATEWAY-AUTH-REQUIRED") {
        return true;
    }
    if (hasRiskFlag(riskFlags, kRiskTlsProbeReset)) {
      return true;
    }
    if (status == kCompleted || status == kInconclusive) {
        return true;
    }
    if (status == kTransportFailed) {
        return false;
    }
    return errorCode != "E-RDP-TARGET-DNS" &&
        errorCode != "E-RDP-GATEWAY-DNS" &&
        errorCode != "E-RDP-TARGET-TCP" &&
        errorCode != "E-RDP-GATEWAY-TCP" &&
        errorCode != "E-RDP-TARGET-TIMEOUT" &&
        errorCode != "E-RDP-GATEWAY-TUNNEL" &&
        errorCode != "E-RDP-GATEWAY-AUTH" &&
        errorCode != "E-RDP-ENDPOINT" &&
        errorCode != "E-RDP-GATEWAY-SNI" &&
        errorCode != "E-RDP-ADAPTER" &&
        errorCode != "E-RDP-CERT-ROUTE-STALE" &&
        errorCode != "E-RDP-FREERDP-NEGOTIATION";
}

} // namespace RdpPreflightPolicy

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
    const auto field = [](const std::string& value) {
        return std::to_string(value.size()) + ":" + value;
    };
    return std::string("rdp-route-v2|") + field(endpointModeName(route.endpointMode)) +
        field(route.targetHost) + field(std::to_string(route.targetPort)) + field(targetName) +
        field(route.gatewayHost) + field(std::to_string(route.gatewayPort)) +
        field(gatewayName) + field(gatewayTransportName(route.gatewayTransport));
}

template <typename Config>
inline void normalizeRouteConfig(Config& config, const RdpEndpointRoute& route) {
    config.host = route.targetHost;
    config.port = route.targetPort;
    config.targetServerName = route.targetServerName;
    config.gatewayHost = route.gatewayHost;
    config.gatewayPort = route.gatewayPort;
    config.rdpGatewayServerName = route.gatewayServerName;
    config.rdpEndpointMode = endpointModeName(route.endpointMode);
    config.rdpGatewayTransport = gatewayTransportName(route.gatewayTransport);
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

inline bool targetInterfaceScopeIsAllowed(
    RdpEndpointMode endpointMode, bool targetHasInterfaceScope) {
    // An interface scope belongs to this client.  It can select the egress
    // interface for a direct connection, but it has no meaning in the remote
    // namespace where an RD Gateway resolves and connects to the target.
    return !targetHasInterfaceScope || endpointMode != RdpEndpointMode::MicrosoftRdGateway;
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
                             bool allowHostMismatch,
                             bool allowTimeAnomaly = false) {
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
        return allowTimeAnomaly;
    }
    const int64_t nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    if (nowMs < record.notBeforeMs || nowMs > record.notAfterMs) {
        return allowTimeAnomaly;
    }
    return true;
}

inline bool gatewayCertificateAllowsCredentialUse(
    const RdpPreflightRequest& request, const RdpCertificateRecord& gateway) {
    if (!gateway.present) {
        return false;
    }
    const bool gatewayTimeValid = gateway.notBeforeMs > 0 &&
        gateway.notAfterMs > gateway.notBeforeMs;
    const bool gatewayFingerprintMatches = fingerprintMatchesStage(
        gateway, request.expectedGatewayFingerprintSha256);
    if (!gatewayTimeValid &&
        !(request.gatewayAllowTimeAnomaly && gatewayFingerprintMatches)) {
        return false;
    }
    const int64_t nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    if (gatewayTimeValid && (nowMs < gateway.notBeforeMs || nowMs > gateway.notAfterMs) &&
        !(request.gatewayAllowTimeAnomaly && gatewayFingerprintMatches)) {
        return false;
    }
    // Even a publicly trusted Gateway certificate must be bound to a
    // stage-specific pin before the preflight is allowed to send credentials.
    // This keeps the Gateway confirmation decision in the user-facing flow.
    if (!gatewayFingerprintMatches) {
        return false;
    }
    if (gateway.rootTrusted && !gateway.hostMismatch) {
        return true;
    }
    return trustAllowsStage(
        gateway, request.expectedGatewayFingerprintSha256,
        request.gatewayAllowUntrustedRoot, request.gatewayAllowHostMismatch,
        request.gatewayAllowTimeAnomaly);
}

inline bool gatewayTrustAllowsRoute(const RdpPreflightRequest& request,
                                    const RdpCertificateRecord& gateway,
                                    const RdpCertificateRecord& target) {
    return trustAllowsStage(
               gateway, request.expectedGatewayFingerprintSha256,
               request.gatewayAllowUntrustedRoot, request.gatewayAllowHostMismatch,
               request.gatewayAllowTimeAnomaly) &&
        trustAllowsStage(
               target, request.expectedTargetFingerprintSha256,
               request.targetAllowUntrustedRoot, request.targetAllowHostMismatch,
               request.targetAllowTimeAnomaly);
}

} // namespace RdpGatewayPolicy
