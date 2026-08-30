/** Native VNC transport allowlist tests. */
#include "test_runner.h"
#include "vnc/vnc_transport.h"
#include "vnc/vnc_certificate_probe.h"
#include "vnc/vnc_transport_policy.h"

#include <string>

RDP_TEST_CASE(vnc_native_transport_allows_direct_and_repeater_only) {
    RDP_ASSERT(vncNativeTransportIsAvailable("direct_tcp"));
    RDP_ASSERT(vncNativeTransportIsAvailable("ultravnc_repeater"));
    RDP_ASSERT(!vncNativeTransportIsAvailable("websocket_gateway"));
    RDP_ASSERT(!vncNativeTransportIsAvailable("public_relay"));
    RDP_ASSERT(!vncNativeTransportIsAvailable("ssh_tunnel"));
    RDP_ASSERT(!vncNativeTransportIsAvailable("unexpected"));
    RDP_ASSERT(vncNativeRepeaterViewerModeIsAvailable("mode12"));
    RDP_ASSERT(!vncNativeRepeaterViewerModeIsAvailable("mode2"));
    RDP_ASSERT(!vncNativeRepeaterViewerModeIsAvailable("unexpected"));
    RDP_ASSERT(vncEndpointIsIpLiteral("192.0.2.20"));
    RDP_ASSERT(vncEndpointIsIpLiteral("2001:db8::20"));
    RDP_ASSERT(vncEndpointIsIpLiteral("fe80::20%wlan0"));
    RDP_ASSERT(!vncEndpointIsIpLiteral("vnc.example"));
}

RDP_TEST_CASE(vnc_scoped_ipv6_uses_transport_scope_but_scope_free_tls_identity) {
    std::string identity;
    bool sendSni = true;
    RDP_ASSERT(vncResolveCertificateIdentity(
        "[fe80::20%wlan0]", "", identity, sendSni));
    RDP_ASSERT(identity == "fe80::20");
    RDP_ASSERT(!sendSni);

    RDP_ASSERT(vncResolveCertificateIdentity(
        "fe80::20%wlan0", "vnc.example", identity, sendSni));
    RDP_ASSERT(identity == "vnc.example");
    RDP_ASSERT(sendSni);
    RDP_ASSERT(!vncResolveCertificateIdentity(
        "fe80::20%wlan0", "bad%identity", identity, sendSni));
}

RDP_TEST_CASE(vnc_websocket_authority_formats_ipv6_and_rfc6874_scope) {
    std::string authority;
    RDP_ASSERT(vncFormatWebSocketAuthority("2001:db8::20", 443, authority));
    RDP_ASSERT(authority == "[2001:db8::20]:443");
    RDP_ASSERT(vncFormatWebSocketAuthority("fe80::20%wlan0", 443, authority));
    RDP_ASSERT(authority == "[fe80::20%25wlan0]:443");
    RDP_ASSERT(vncFormatWebSocketAuthority("vnc.example", 443, authority));
    RDP_ASSERT(authority == "vnc.example:443");
    RDP_ASSERT(!vncFormatWebSocketAuthority("fe80::20%7", 443, authority));
}

RDP_TEST_CASE(vnc_transport_rejects_unknown_before_network_access) {
    VncTransport transport;
    VncTransportConfig config;
    config.transport = "future_transport";
    config.host = "invalid.invalid";
    config.port = 5900;
    std::string error;
    RDP_ASSERT(!transport.connect(config, error));
    RDP_ASSERT(!transport.isOpen());
}

RDP_TEST_CASE(vnc_certificate_pin_normalization_is_strict_and_canonical) {
    std::string normalized;
    RDP_ASSERT(vncNormalizeCertificateFingerprint(
        "sha256:AA:bb:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd",
        normalized));
    RDP_ASSERT(vncCertificateFingerprintIsCanonical(normalized));
    RDP_ASSERT(!vncCertificateFingerprintIsCanonical(normalized.substr(0, 63)));
    RDP_ASSERT(!vncCertificateFingerprintIsCanonical("A" + normalized.substr(1)));
    RDP_ASSERT(!vncNormalizeCertificateFingerprint("sha256:not-a-pin", normalized));
}

RDP_TEST_CASE(vnc_certificate_probe_rejects_invalid_input_and_honors_cancel) {
    VncCertificateProbeConfig invalid;
    invalid.host = "";
    const VncCertificateInfo invalidResult = probeVncCertificate(invalid);
    RDP_ASSERT(!invalidResult.ok);
    RDP_ASSERT(invalidResult.errorCode ==
               static_cast<int>(VncCertificateProbeErrorCode::InvalidInput));

    auto cancelled = std::make_shared<std::atomic_bool>(true);
    VncCertificateProbeConfig cancelledConfig;
    cancelledConfig.host = "127.0.0.1";
    cancelledConfig.cancelled = cancelled;
    const VncCertificateInfo cancelledResult = probeVncCertificate(cancelledConfig);
    RDP_ASSERT(!cancelledResult.ok);
    RDP_ASSERT(cancelledResult.errorCode ==
               static_cast<int>(VncCertificateProbeErrorCode::Cancelled));
}
