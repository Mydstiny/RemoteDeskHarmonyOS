/**
 * rdp_gateway_policy_test.cpp - RDP route and staged trust policy tests.
 */

#include "test_runner.h"
#include "rdp/rdp_certificate_validation.h"
#include "rdp/rdp_connection_identity_policy.h"
#include "rdp/rdp_gateway_policy.h"

#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rsa.h>
#include <openssl/x509v3.h>

#include <memory>
#include <string>

namespace {

struct PkeyDeleter {
    void operator()(EVP_PKEY* key) const {
        if (key != nullptr) EVP_PKEY_free(key);
    }
};

struct CertificateDeleter {
    void operator()(X509* certificate) const {
        if (certificate != nullptr) X509_free(certificate);
    }
};

struct StoreDeleter {
    void operator()(X509_STORE* store) const {
        if (store != nullptr) X509_STORE_free(store);
    }
};

using PkeyPtr = std::unique_ptr<EVP_PKEY, PkeyDeleter>;
using CertificatePtr = std::unique_ptr<X509, CertificateDeleter>;
using StorePtr = std::unique_ptr<X509_STORE, StoreDeleter>;

PkeyPtr makeCertificateTestKey() {
    EVP_PKEY* key = nullptr;
    EVP_PKEY_CTX* context = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, nullptr);
    if (context == nullptr || EVP_PKEY_keygen_init(context) != 1 ||
        EVP_PKEY_CTX_set_rsa_keygen_bits(context, 2048) != 1 ||
        EVP_PKEY_keygen(context, &key) != 1) {
        if (context != nullptr) EVP_PKEY_CTX_free(context);
        if (key != nullptr) EVP_PKEY_free(key);
        return {};
    }
    EVP_PKEY_CTX_free(context);
    return PkeyPtr(key);
}

bool addCertificateExtension(X509* certificate, X509* issuer, int nid,
                             const char* value) {
    X509V3_CTX context;
    X509V3_set_ctx_nodb(&context);
    X509V3_set_ctx(&context, issuer == nullptr ? certificate : issuer,
                   certificate, nullptr, nullptr, 0);
    X509_EXTENSION* extension = X509V3_EXT_conf_nid(
        nullptr, &context, nid, const_cast<char*>(value));
    if (extension == nullptr) {
        return false;
    }
    const bool added = X509_add_ext(certificate, extension, -1) == 1;
    X509_EXTENSION_free(extension);
    return added;
}

CertificatePtr makeCertificate(EVP_PKEY* key, const char* commonName, long serial,
                               X509* issuer, EVP_PKEY* issuerKey, bool certificateAuthority,
                               const char* subjectAltName = nullptr) {
    CertificatePtr certificate(X509_new());
    if (!certificate || key == nullptr || commonName == nullptr ||
        X509_set_version(certificate.get(), 2) != 1 ||
        ASN1_INTEGER_set(X509_get_serialNumber(certificate.get()), serial) != 1 ||
        X509_gmtime_adj(X509_get_notBefore(certificate.get()), -60) == nullptr ||
        X509_gmtime_adj(X509_get_notAfter(certificate.get()), 3600) == nullptr ||
        X509_set_pubkey(certificate.get(), key) != 1) {
        return {};
    }
    X509_NAME* name = X509_get_subject_name(certificate.get());
    if (name == nullptr || X509_NAME_add_entry_by_txt(
        name, "CN", MBSTRING_ASC,
        reinterpret_cast<const unsigned char*>(commonName), -1, -1, 0) != 1 ||
        X509_set_issuer_name(certificate.get(), issuer == nullptr
            ? name : X509_get_subject_name(issuer)) != 1) {
        return {};
    }
    const char* basicConstraints = certificateAuthority
        ? "critical,CA:TRUE" : "critical,CA:FALSE";
    const char* keyUsage = certificateAuthority
        ? "critical,keyCertSign,cRLSign" : "critical,digitalSignature,keyEncipherment";
    if (!addCertificateExtension(certificate.get(), issuer, NID_basic_constraints,
                                 basicConstraints) ||
        !addCertificateExtension(certificate.get(), issuer, NID_key_usage, keyUsage) ||
        (subjectAltName != nullptr && !addCertificateExtension(
            certificate.get(), issuer, NID_subject_alt_name, subjectAltName))) {
        return {};
    }
    EVP_PKEY* signer = issuerKey == nullptr ? key : issuerKey;
    if (X509_sign(certificate.get(), signer, EVP_sha256()) <= 0) {
        return {};
    }
    return certificate;
}

std::string serializeCertificateChain(X509* leaf, X509* intermediate = nullptr) {
    BIO* bio = BIO_new(BIO_s_mem());
    if (bio == nullptr) {
        return {};
    }
    bool written = leaf != nullptr && PEM_write_bio_X509(bio, leaf) == 1;
    if (written && intermediate != nullptr) {
        written = PEM_write_bio_X509(bio, intermediate) == 1;
    }
    BUF_MEM* buffer = nullptr;
    BIO_get_mem_ptr(bio, &buffer);
    std::string pem;
    if (written && buffer != nullptr && buffer->data != nullptr && buffer->length > 0) {
        pem.assign(buffer->data, buffer->length);
    }
    BIO_free(bio);
    return pem;
}

} // namespace

RDP_TEST_CASE(rdp_gateway_policy_parses_explicit_endpoint_modes) {
    RdpEndpointMode mode = RdpEndpointMode::DirectRdp;
    RDP_ASSERT(RdpGatewayPolicy::parseEndpointMode("direct_rdp", mode));
    RDP_ASSERT(mode == RdpEndpointMode::DirectRdp);
    RDP_ASSERT(RdpGatewayPolicy::parseEndpointMode("microsoft_rd_gateway", mode));
    RDP_ASSERT(mode == RdpEndpointMode::MicrosoftRdGateway);
    RDP_ASSERT(RdpGatewayPolicy::parseEndpointMode("vendor_https_bastion", mode));
    RDP_ASSERT(mode == RdpEndpointMode::VendorHttpsBastion);
    RDP_ASSERT(RdpGatewayPolicy::parseEndpointMode("azure_bastion", mode));
    RDP_ASSERT(mode == RdpEndpointMode::AzureBastion);
    RDP_ASSERT(RdpGatewayPolicy::parseEndpointMode("unknown_gateway", mode));
    RDP_ASSERT(mode == RdpEndpointMode::UnknownGateway);
    RDP_ASSERT(!RdpGatewayPolicy::parseEndpointMode("guess_from_port", mode));
}

RDP_TEST_CASE(rdp_gateway_policy_maps_gateway_transport_without_guessing) {
    RdpGatewayTransport transport = RdpGatewayTransport::Auto;
    RDP_ASSERT(RdpGatewayPolicy::parseGatewayTransport("rpc", transport));
    RDP_ASSERT(RdpGatewayPolicy::transportFlags(transport).rpc);
    RDP_ASSERT(!RdpGatewayPolicy::transportFlags(transport).http);

    RDP_ASSERT(RdpGatewayPolicy::parseGatewayTransport("no-websockets", transport));
    const auto noWebsockets = RdpGatewayPolicy::transportFlags(transport);
    RDP_ASSERT(!noWebsockets.rpc && noWebsockets.http && !noWebsockets.websockets);

    RDP_ASSERT(RdpGatewayPolicy::parseGatewayTransport("websocket", transport));
    const auto websocket = RdpGatewayPolicy::transportFlags(transport);
    RDP_ASSERT(!websocket.rpc && websocket.http && websocket.websockets);
    RDP_ASSERT(!RdpGatewayPolicy::parseGatewayTransport("probe_http_then_guess", transport));
}

RDP_TEST_CASE(rdp_preflight_request_explicitly_clears_every_identity_copy) {
    RdpPreflightRequest request;
    request.username = "DOMAIN\\session-user";
    request.password = "session-password";
    request.domain = "DOMAIN";
    request.cancelled = []() { return false; };
    RdpPreflightRequest copied = request;

    request.clearCredentialMaterial();
    RDP_ASSERT(request.username.empty());
    RDP_ASSERT(request.password.empty());
    RDP_ASSERT(request.domain.empty());
    RDP_ASSERT(!request.cancelled);
    RDP_ASSERT(copied.username == "DOMAIN\\session-user");
    RDP_ASSERT(copied.password == "session-password");
    RDP_ASSERT(copied.domain == "DOMAIN");

    copied.clearCredentialMaterial();
    RDP_ASSERT(copied.username.empty());
    RDP_ASSERT(copied.password.empty());
    RDP_ASSERT(copied.domain.empty());
    RDP_ASSERT(!copied.cancelled);
}

RDP_TEST_CASE(rdp_gateway_policy_separates_requested_and_observed_transport) {
    RdpPreflightResult result;
    RdpGatewayPolicy::initializeGatewayTransportResult(
        result, RdpGatewayTransport::Auto);
    RDP_ASSERT(result.gatewayTransportRequested == "auto");
    RDP_ASSERT(result.gatewayTransportSelected == "auto");
    RDP_ASSERT(result.gatewayTransportNegotiated == "unknown");

    // A test recording may publish a branch only when it has explicit
    // evidence. Invalid or absent observations remain fail-closed as unknown.
    RDP_ASSERT(RdpGatewayPolicy::setNegotiatedGatewayTransport(result, "rpc"));
    RDP_ASSERT(result.gatewayTransportNegotiated == "rpc");
    RDP_ASSERT(!RdpGatewayPolicy::setNegotiatedGatewayTransport(result, "auto"));
    RDP_ASSERT(result.gatewayTransportNegotiated == "unknown");

    RdpGatewayPolicy::RdpGatewayTransportObservation observation;
    RDP_ASSERT(!RdpGatewayPolicy::gatewayProtocolEvidenceIsComplete(observation));
    observation.gatewayTlsEstablished = true;
    observation.targetTlsEstablished = true;
    observation.targetRdpOverTunnel = true;
    observation.negotiatedTransport = "unknown";
    RDP_ASSERT(!RdpGatewayPolicy::gatewayProtocolEvidenceIsComplete(observation));
    observation.negotiatedTransport = "http";
    RDP_ASSERT(RdpGatewayPolicy::gatewayProtocolEvidenceIsComplete(observation));
    observation.gatewayReceivedRdpX224 = true;
    RDP_ASSERT(!RdpGatewayPolicy::gatewayProtocolEvidenceIsComplete(observation));
}

RDP_TEST_CASE(rdp_gateway_policy_does_not_send_credentials_before_gateway_identity_is_safe) {
    const int64_t nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    RdpPreflightRequest request;
    RdpCertificateRecord gateway;
    gateway.present = true;
    gateway.fingerprintSha256 =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    gateway.notBeforeMs = nowMs - 60000;
    gateway.notAfterMs = nowMs + 60000;

    gateway.rootTrusted = true;
    gateway.hostMismatch = false;
    RDP_ASSERT(!RdpGatewayPolicy::gatewayCertificateAllowsCredentialUse(request, gateway));
    request.expectedGatewayFingerprintSha256 = gateway.fingerprintSha256;
    RDP_ASSERT(RdpGatewayPolicy::gatewayCertificateAllowsCredentialUse(request, gateway));

    gateway.rootTrusted = false;
    RDP_ASSERT(!RdpGatewayPolicy::gatewayCertificateAllowsCredentialUse(request, gateway));
    request.gatewayAllowUntrustedRoot = true;
    RDP_ASSERT(RdpGatewayPolicy::gatewayCertificateAllowsCredentialUse(request, gateway));

    gateway.hostMismatch = true;
    RDP_ASSERT(!RdpGatewayPolicy::gatewayCertificateAllowsCredentialUse(request, gateway));
    request.gatewayAllowHostMismatch = true;
    RDP_ASSERT(RdpGatewayPolicy::gatewayCertificateAllowsCredentialUse(request, gateway));

    gateway.notAfterMs = nowMs - 1;
    RDP_ASSERT(!RdpGatewayPolicy::gatewayCertificateAllowsCredentialUse(request, gateway));
}

RDP_TEST_CASE(rdp_gateway_policy_route_identity_binds_all_route_fields) {
    RdpEndpointRoute route;
    route.endpointMode = RdpEndpointMode::MicrosoftRdGateway;
    route.targetHost = "target.internal";
    route.targetPort = 3389;
    route.targetServerName = "target.internal";
    route.gatewayHost = "gateway.internal";
    route.gatewayPort = 443;
    route.gatewayServerName = "gateway.internal";
    route.gatewayTransport = RdpGatewayTransport::NoWebsockets;

    const std::string identity = RdpGatewayPolicy::routeIdentity(route);
    RDP_ASSERT(identity.rfind("rdp-route-v2|", 0U) == 0U);

    route.gatewayPort = 8443;
    RDP_ASSERT(identity != RdpGatewayPolicy::routeIdentity(route));
}

RDP_TEST_CASE(rdp_gateway_policy_route_identity_has_no_ipv6_delimiter_collision) {
    RdpEndpointRoute first;
    first.endpointMode = RdpEndpointMode::DirectRdp;
    first.targetHost = "2001:db8::1";
    first.targetPort = 3389;
    first.targetServerName = "443:1::2";
    first.gatewayPort = 0;

    RDP_ASSERT(RdpGatewayPolicy::routeIdentity(first) ==
        "rdp-route-v2|10:direct_rdp11:2001:db8::14:33898:443:1::20:1:00:4:auto");

    RdpEndpointRoute second = first;
    second.targetHost = "2001:db8::1:3389";
    second.targetPort = 443;
    second.targetServerName = "1::2";

    RDP_ASSERT(RdpGatewayPolicy::routeIdentity(first) !=
        RdpGatewayPolicy::routeIdentity(second));
}

RDP_TEST_CASE(rdp_gateway_policy_rejects_unsupported_routes_as_not_supported) {
    RDP_ASSERT(RdpGatewayPolicy::isSupportedRdpRoute(RdpEndpointMode::DirectRdp));
    RDP_ASSERT(RdpGatewayPolicy::isSupportedRdpRoute(RdpEndpointMode::TransparentTcpRdp));
    RDP_ASSERT(RdpGatewayPolicy::isSupportedRdpRoute(RdpEndpointMode::MicrosoftRdGateway));
    RDP_ASSERT(!RdpGatewayPolicy::isSupportedRdpRoute(RdpEndpointMode::VendorHttpsBastion));
    RDP_ASSERT(!RdpGatewayPolicy::isSupportedRdpRoute(RdpEndpointMode::AzureBastion));
    RDP_ASSERT(!RdpGatewayPolicy::isSupportedRdpRoute(RdpEndpointMode::UnknownGateway));
}

RDP_TEST_CASE(rdp_gateway_policy_rejects_restricted_admin_without_gateway_credentials) {
    RDP_ASSERT(RdpGatewayPolicy::restrictedAdminGatewayRouteIsSupported(
        RdpEndpointMode::DirectRdp, true));
    RDP_ASSERT(!RdpGatewayPolicy::restrictedAdminGatewayRouteIsSupported(
        RdpEndpointMode::MicrosoftRdGateway, true));
    RDP_ASSERT(RdpGatewayPolicy::restrictedAdminGatewayRouteIsSupported(
        RdpEndpointMode::MicrosoftRdGateway, false));
}

RDP_TEST_CASE(rdp_gateway_policy_keeps_interface_scopes_in_the_client_namespace) {
    RDP_ASSERT(RdpGatewayPolicy::targetInterfaceScopeIsAllowed(
        RdpEndpointMode::DirectRdp, true));
    RDP_ASSERT(RdpGatewayPolicy::targetInterfaceScopeIsAllowed(
        RdpEndpointMode::TransparentTcpRdp, true));
    RDP_ASSERT(RdpGatewayPolicy::targetInterfaceScopeIsAllowed(
        RdpEndpointMode::MicrosoftRdGateway, false));
    RDP_ASSERT(!RdpGatewayPolicy::targetInterfaceScopeIsAllowed(
        RdpEndpointMode::MicrosoftRdGateway, true));
}

RDP_TEST_CASE(rdp_route_normalization_publishes_scope_free_certificate_identities) {
    struct RouteConfig {
        std::string host;
        int port = 0;
        std::string targetServerName;
        std::string gatewayHost;
        int gatewayPort = 0;
        std::string rdpGatewayServerName;
        std::string rdpEndpointMode;
        std::string rdpGatewayTransport;
    } config;
    RdpEndpointRoute route;
    route.endpointMode = RdpEndpointMode::DirectRdp;
    route.targetHost = "fe80::1%en0";
    route.targetPort = 3389;
    route.targetServerName = "fe80::1";
    route.gatewayPort = 443;

    RdpGatewayPolicy::normalizeRouteConfig(config, route);

    RDP_ASSERT(config.host == "fe80::1%en0");
    RDP_ASSERT(config.targetServerName == "fe80::1");
    RDP_ASSERT(config.rdpEndpointMode == "direct_rdp");
    RDP_ASSERT(config.rdpGatewayTransport == "auto");
}

RDP_TEST_CASE(rdp_gateway_policy_does_not_cross_match_gateway_and_target_pins) {
    const int64_t nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    RdpCertificateRecord gateway;
    gateway.present = true;
    gateway.fingerprintSha256 =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    gateway.rootTrusted = true;
    gateway.serverName = "gateway";
    gateway.notBeforeMs = nowMs - 60000;
    gateway.notAfterMs = nowMs + 60000;

    RdpCertificateRecord target;
    target.present = true;
    target.fingerprintSha256 =
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    target.rootTrusted = true;
    target.serverName = "target";
    target.notBeforeMs = nowMs - 60000;
    target.notAfterMs = nowMs + 60000;

    RDP_ASSERT(RdpGatewayPolicy::trustAllowsStage(
        gateway, gateway.fingerprintSha256, false, false));
    RDP_ASSERT(!RdpGatewayPolicy::trustAllowsStage(
        gateway, target.fingerprintSha256, false, false));
    RDP_ASSERT(RdpGatewayPolicy::trustAllowsStage(
        target, target.fingerprintSha256, false, false));
    RDP_ASSERT(!RdpGatewayPolicy::trustAllowsStage(
        target, gateway.fingerprintSha256, false, false));
}

RDP_TEST_CASE(rdp_gateway_policy_separates_pin_rotation_and_validity_failures) {
    const int64_t nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    RdpCertificateRecord gateway;
    gateway.present = true;
    gateway.rootTrusted = true;
    gateway.notBeforeMs = nowMs - 60000;
    gateway.notAfterMs = nowMs + 60000;
    gateway.fingerprintSha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    RdpCertificateRecord target;
    target.present = true;
    target.rootTrusted = true;
    target.notBeforeMs = nowMs - 60000;
    target.notAfterMs = nowMs + 60000;
    target.fingerprintSha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    // Both pins match.
    RDP_ASSERT(RdpGatewayPolicy::trustAllowsStage(
        gateway, gateway.fingerprintSha256, false, false));
    RDP_ASSERT(RdpGatewayPolicy::trustAllowsStage(
        target, target.fingerprintSha256, false, false));
    // Rotating either stage cannot be hidden by the other stage's pin.
    RDP_ASSERT(!RdpGatewayPolicy::trustAllowsStage(
        gateway, target.fingerprintSha256, false, false));
    RDP_ASSERT(!RdpGatewayPolicy::trustAllowsStage(
        target, gateway.fingerprintSha256, false, false));

    gateway.notAfterMs = nowMs - 1;
    RDP_ASSERT(!RdpGatewayPolicy::trustAllowsStage(
        gateway, gateway.fingerprintSha256, true, true));
    gateway.notAfterMs = nowMs + 60000;
    target.notBeforeMs = nowMs + 60000;
    RDP_ASSERT(!RdpGatewayPolicy::trustAllowsStage(
        target, target.fingerprintSha256, true, true));
}

RDP_TEST_CASE(rdp_gateway_policy_rejects_missing_or_invalid_stage_records) {
    const int64_t nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    RdpCertificateRecord certificate;
    certificate.present = false;
    certificate.rootTrusted = true;
    certificate.notBeforeMs = nowMs - 60000;
    certificate.notAfterMs = nowMs + 60000;

    RDP_ASSERT(!RdpGatewayPolicy::trustAllowsStage(
        certificate,
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        false, false));

    certificate.present = true;
    certificate.fingerprintSha256.clear();
    RDP_ASSERT(!RdpGatewayPolicy::trustAllowsStage(
        certificate,
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        false, false));
}

RDP_TEST_CASE(rdp_preflight_policy_keeps_probe_risks_nonfatal) {
    const auto standard = RdpPreflightPolicy::classifyProbeFailure(
        -18, "RDP server selected Standard RDP Security");
    RDP_ASSERT(standard.status == RdpPreflightPolicy::kInconclusive);
    RDP_ASSERT(RdpPreflightPolicy::hasRiskFlag(
        standard.riskFlags, RdpPreflightPolicy::kRiskStandardRdpSecurity));

    const auto reset = RdpPreflightPolicy::classifyProbeFailure(
        -22, "RDP TLS handshake failed (errno=104:Connection reset by peer)");
    RDP_ASSERT(reset.status == RdpPreflightPolicy::kInconclusive);
    RDP_ASSERT(RdpPreflightPolicy::hasRiskFlag(
        reset.riskFlags, RdpPreflightPolicy::kRiskTlsProbeReset));

    const auto eof = RdpPreflightPolicy::classifyProbeFailure(
        -22, "RDP TLS handshake failed (sslError=ZERO_RETURN)");
    RDP_ASSERT(eof.status == RdpPreflightPolicy::kInconclusive);
    RDP_ASSERT(RdpPreflightPolicy::hasRiskFlag(
        eof.riskFlags, RdpPreflightPolicy::kRiskTlsProbeReset));

    const auto dns = RdpPreflightPolicy::classifyProbeFailure(
        -11, "Unable to resolve RDP host");
    RDP_ASSERT(dns.status == RdpPreflightPolicy::kTransportFailed);
    RDP_ASSERT(dns.riskFlags.empty());

    const auto timeout = RdpPreflightPolicy::classifyProbeFailure(
        -14, "Unable to read RDP negotiation response (errno=110:Connection timed out)");
    RDP_ASSERT(timeout.status == RdpPreflightPolicy::kTransportFailed);

    const auto postConnectNegotiationFailure = RdpPreflightPolicy::classifyProbeFailure(
        -13, "Unable to send RDP negotiation request (errno=32:Broken pipe)");
    RDP_ASSERT(postConnectNegotiationFailure.status == RdpPreflightPolicy::kInconclusive);

    const auto negotiationReset = RdpPreflightPolicy::classifyProbeFailure(
        -14, "Unable to read RDP negotiation response (errno=104:Connection reset by peer)");
    RDP_ASSERT(negotiationReset.status == RdpPreflightPolicy::kInconclusive);
    RDP_ASSERT(RdpPreflightPolicy::hasRiskFlag(
        negotiationReset.riskFlags, RdpPreflightPolicy::kRiskTlsProbeReset));

    const auto noCertificate = RdpPreflightPolicy::classifyProbeFailure(
        -17, "RDP host did not provide a certificate");
    RDP_ASSERT(noCertificate.status == RdpPreflightPolicy::kInconclusive);
    RDP_ASSERT(RdpPreflightPolicy::hasRiskFlag(
        noCertificate.riskFlags, RdpPreflightPolicy::kRiskCertificateMetadataUnavailable));

    const auto unknownGateway = RdpPreflightPolicy::classifyErrorCode(
        "E-RDP-BASTION-UNSUPPORTED", "RDP endpoint mode is not supported");
    RDP_ASSERT(unknownGateway.status == RdpPreflightPolicy::kUnavailable);
    RDP_ASSERT(RdpPreflightPolicy::hasRiskFlag(
        unknownGateway.riskFlags, RdpPreflightPolicy::kRiskUnknownGatewayProtocol));

    const auto runtimeUnavailable = RdpPreflightPolicy::classifyErrorCode(
        "E-RDP-GATEWAY-TLS", "Unable to create FreeRDP preflight instance");
    RDP_ASSERT(runtimeUnavailable.status == RdpPreflightPolicy::kUnavailable);

    const auto gatewayAuthRequired = RdpPreflightPolicy::classifyErrorCode(
        "E-RDP-GATEWAY-AUTH-REQUIRED",
        "RD Gateway authentication is required before the target certificate can be read");
    RDP_ASSERT(gatewayAuthRequired.status == RdpPreflightPolicy::kInconclusive);

    RDP_ASSERT(RdpPreflightPolicy::preflightAllowsRealConnection(
        standard.status, "E-RDP-NEGOTIATION"));
    RDP_ASSERT(RdpPreflightPolicy::preflightAllowsRealConnection(
        reset.status, "E-RDP-TARGET-TLS"));
    RDP_ASSERT(RdpPreflightPolicy::preflightAllowsRealConnection(
        RdpPreflightPolicy::kTransportFailed, "E-RDP-TARGET-TLS"));
    RDP_ASSERT(RdpPreflightPolicy::preflightAllowsRealConnection(
        RdpPreflightPolicy::kTransportFailed, "E-RDP-NEGOTIATION"));
    RDP_ASSERT(RdpPreflightPolicy::preflightAllowsRealConnection(
        RdpPreflightPolicy::kTransportFailed, "E-RDP-GATEWAY-CERT"));
    RDP_ASSERT(RdpPreflightPolicy::preflightAllowsRealConnection(
        unknownGateway.status, "E-RDP-BASTION-UNSUPPORTED"));
    RDP_ASSERT(!RdpPreflightPolicy::preflightAllowsRealConnection(
        timeout.status, "E-RDP-TARGET-TIMEOUT"));
    RDP_ASSERT(RdpPreflightPolicy::preflightAllowsRealConnection(
        postConnectNegotiationFailure.status, "E-RDP-NEGOTIATION"));
    RDP_ASSERT(RdpPreflightPolicy::preflightAllowsRealConnection(
        gatewayAuthRequired.status, "E-RDP-GATEWAY-AUTH-REQUIRED"));
    RDP_ASSERT(RdpPreflightPolicy::preflightAllowsRealConnection(
        negotiationReset.status, "E-RDP-TARGET-TIMEOUT", negotiationReset.riskFlags));
}

RDP_TEST_CASE(rdp_preflight_policy_time_anomaly_requires_explicit_stage_decision) {
    const int64_t nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    const std::string fingerprint(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    RdpCertificateRecord gateway;
    gateway.present = true;
    gateway.rootTrusted = true;
    gateway.fingerprintSha256 = fingerprint;
    gateway.notBeforeMs = nowMs - 120000;
    gateway.notAfterMs = nowMs - 60000;
    RdpPreflightRequest request;
    request.expectedGatewayFingerprintSha256 = fingerprint;
    RDP_ASSERT(!RdpGatewayPolicy::trustAllowsStage(gateway, fingerprint, false, false));
    request.gatewayAllowTimeAnomaly = true;
    RDP_ASSERT(RdpGatewayPolicy::trustAllowsStage(
        gateway, fingerprint, false, false, true));
    RDP_ASSERT(RdpGatewayPolicy::gatewayCertificateAllowsCredentialUse(
        request, gateway));
}

RDP_TEST_CASE(rdp_gateway_policy_requires_both_stage_pins_and_isolates_rotation) {
    const int64_t nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    const std::string gatewayFingerprint(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const std::string targetFingerprint(
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    const std::string rotatedGatewayFingerprint(
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc");
    const std::string rotatedTargetFingerprint(
        "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd");

    RdpCertificateRecord gateway;
    gateway.present = true;
    gateway.stage = "gateway";
    gateway.rootTrusted = true;
    gateway.notBeforeMs = nowMs - 60000;
    gateway.notAfterMs = nowMs + 60000;
    gateway.fingerprintSha256 = gatewayFingerprint;

    RdpCertificateRecord target;
    target.present = true;
    target.stage = "target";
    target.rootTrusted = true;
    target.notBeforeMs = nowMs - 60000;
    target.notAfterMs = nowMs + 60000;
    target.fingerprintSha256 = targetFingerprint;

    RdpPreflightRequest request;
    request.route.endpointMode = RdpEndpointMode::MicrosoftRdGateway;
    request.expectedGatewayFingerprintSha256 = gatewayFingerprint;
    request.expectedTargetFingerprintSha256 = targetFingerprint;
    RDP_ASSERT(RdpGatewayPolicy::gatewayTrustAllowsRoute(request, gateway, target));

    request.expectedGatewayFingerprintSha256 = rotatedGatewayFingerprint;
    RDP_ASSERT(!RdpGatewayPolicy::gatewayTrustAllowsRoute(request, gateway, target));
    request.expectedGatewayFingerprintSha256 = gatewayFingerprint;
    request.expectedTargetFingerprintSha256 = rotatedTargetFingerprint;
    RDP_ASSERT(!RdpGatewayPolicy::gatewayTrustAllowsRoute(request, gateway, target));
    request.expectedGatewayFingerprintSha256 = rotatedGatewayFingerprint;
    RDP_ASSERT(!RdpGatewayPolicy::gatewayTrustAllowsRoute(request, gateway, target));

    // A Gateway rotation changes only the Gateway record; the target pin can
    // still be evaluated independently after the Gateway record is replaced.
    gateway.fingerprintSha256 = rotatedGatewayFingerprint;
    request.expectedGatewayFingerprintSha256 = rotatedGatewayFingerprint;
    request.expectedTargetFingerprintSha256 = targetFingerprint;
    RDP_ASSERT(RdpGatewayPolicy::gatewayTrustAllowsRoute(request, gateway, target));

    // Likewise, target rotation does not make the Gateway pin invalid.
    target.fingerprintSha256 = rotatedTargetFingerprint;
    request.expectedTargetFingerprintSha256 = rotatedTargetFingerprint;
    RDP_ASSERT(RdpGatewayPolicy::gatewayTrustAllowsRoute(request, gateway, target));
}

RDP_TEST_CASE(rdp_client_hostname_is_not_an_endpoint_or_server_identity) {
    RDP_ASSERT(RdpConnectionIdentityPolicy::clientHostnameIsValid(""));
    RDP_ASSERT(RdpConnectionIdentityPolicy::clientHostnameIsValid("HARMONY-CLIENT"));
    RDP_ASSERT(RdpConnectionIdentityPolicy::clientHostnameIsValid("client.example.test"));
    RDP_ASSERT(!RdpConnectionIdentityPolicy::clientHostnameIsValid("2001:db8::10"));
    RDP_ASSERT(!RdpConnectionIdentityPolicy::clientHostnameIsValid("client name"));
    RDP_ASSERT(!RdpConnectionIdentityPolicy::clientHostnameIsValid("-client"));
    RDP_ASSERT(!RdpConnectionIdentityPolicy::clientHostnameIsValid("client-.example"));
    RDP_ASSERT(!RdpConnectionIdentityPolicy::clientHostnameIsValid("client.example."));
    RDP_ASSERT(!RdpConnectionIdentityPolicy::clientHostnameIsValid(
        std::string(254, 'a')));
}

RDP_TEST_CASE(rdp_certificate_validation_distinguishes_ip_san_from_dns_san) {
    const PkeyPtr key = makeCertificateTestKey();
    const CertificatePtr certificate = makeCertificate(
        key.get(), "gateway.internal", 10, nullptr, nullptr, false,
        "IP:127.0.0.1,DNS:gateway.internal");
    RDP_ASSERT(key != nullptr);
    RDP_ASSERT(certificate != nullptr);
    RDP_ASSERT(RdpCertificateValidation::hostnameMatches(
        certificate.get(), "127.0.0.1"));
    RDP_ASSERT(!RdpCertificateValidation::hostnameMatches(
        certificate.get(), "127.0.0.2"));
    RDP_ASSERT(RdpCertificateValidation::hostnameMatches(
        certificate.get(), "gateway.internal"));
    RDP_ASSERT(!RdpCertificateValidation::hostnameMatches(
        certificate.get(), "target.internal"));

    const std::string pem = serializeCertificateChain(certificate.get());
    bool parsed = false;
    RDP_ASSERT(RdpCertificateValidation::hostnameMatchesPem(
        reinterpret_cast<const unsigned char*>(pem.data()), pem.size(),
        "gateway.internal", parsed));
    RDP_ASSERT(parsed);
    parsed = false;
    RDP_ASSERT(!RdpCertificateValidation::hostnameMatchesPem(
        reinterpret_cast<const unsigned char*>(pem.data()), pem.size(),
        "target.internal", parsed));
    RDP_ASSERT(parsed);
    parsed = true;
    static const unsigned char malformed[] = "not a certificate";
    RDP_ASSERT(!RdpCertificateValidation::hostnameMatchesPem(
        malformed, sizeof(malformed) - 1, "gateway.internal", parsed));
    RDP_ASSERT(!parsed);
}

RDP_TEST_CASE(rdp_certificate_validation_uses_intermediate_pem_chain) {
    const PkeyPtr rootKey = makeCertificateTestKey();
    const PkeyPtr intermediateKey = makeCertificateTestKey();
    const PkeyPtr leafKey = makeCertificateTestKey();
    const CertificatePtr root = makeCertificate(
        rootKey.get(), "RDP Test Root", 20, nullptr, nullptr, true);
    const CertificatePtr intermediate = makeCertificate(
        intermediateKey.get(), "RDP Test Intermediate", 21,
        root.get(), rootKey.get(), true);
    const CertificatePtr leaf = makeCertificate(
        leafKey.get(), "target.internal", 22,
        intermediate.get(), intermediateKey.get(), false,
        "DNS:target.internal");
    RDP_ASSERT(rootKey != nullptr && intermediateKey != nullptr && leafKey != nullptr);
    RDP_ASSERT(root != nullptr && intermediate != nullptr && leaf != nullptr);

    const StorePtr store(X509_STORE_new());
    RDP_ASSERT(store != nullptr);
    RDP_ASSERT(X509_STORE_add_cert(store.get(), root.get()) == 1);
    const std::string leafOnly = serializeCertificateChain(leaf.get());
    const std::string fullChain = serializeCertificateChain(
        leaf.get(), intermediate.get());
    RDP_ASSERT(!leafOnly.empty() && !fullChain.empty());
    RDP_ASSERT(!RdpCertificateValidation::rootTrustedFromPemWithStore(
        reinterpret_cast<const unsigned char*>(leafOnly.data()),
        leafOnly.size(), store.get()));
    RDP_ASSERT(RdpCertificateValidation::rootTrustedFromPemWithStore(
        reinterpret_cast<const unsigned char*>(fullChain.data()),
        fullChain.size(), store.get()));
}
