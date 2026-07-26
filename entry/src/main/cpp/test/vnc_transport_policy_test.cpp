/** Native VNC transport allowlist tests. */
#include "test_runner.h"
#include "vnc/vnc_transport.h"
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
