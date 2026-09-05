#include "extensions/connection_port_policy.h"
#include "test_runner.h"

using remotedesk::extensions::ConnectionPortPolicyInput;
using remotedesk::extensions::HasInvalidActiveOptionalPort;

RDP_TEST_CASE(connection_ports_ignore_inactive_cross_protocol_zero_sentinels) {
    ConnectionPortPolicyInput rustDesk;
    rustDesk.protocol = "rustdesk";
    rustDesk.hasGatewayPort = true;
    rustDesk.gatewayPort = 0;
    rustDesk.hasRustDeskDirectPort = true;
    rustDesk.rustDeskDirectPort = 21118;
    rustDesk.hasVncGatewayPort = true;
    rustDesk.vncGatewayPort = 0;
    rustDesk.rustDeskDirect = true;
    RDP_ASSERT(!HasInvalidActiveOptionalPort(rustDesk));

    ConnectionPortPolicyInput vnc;
    vnc.protocol = "vnc";
    vnc.vncTransport = "direct_tcp";
    vnc.hasGatewayPort = true;
    vnc.gatewayPort = 0;
    vnc.hasRustDeskDirectPort = true;
    vnc.rustDeskDirectPort = 0;
    vnc.hasRustDeskRelayPort = true;
    vnc.rustDeskRelayPort = 0;
    vnc.hasVncGatewayPort = true;
    vnc.vncGatewayPort = 0;
    RDP_ASSERT(!HasInvalidActiveOptionalPort(vnc));

    ConnectionPortPolicyInput rdp;
    rdp.protocol = "rdp";
    rdp.hasGatewayPort = true;
    rdp.gatewayPort = 0;
    rdp.hasRustDeskDirectPort = true;
    rdp.rustDeskDirectPort = 0;
    rdp.hasVncGatewayPort = true;
    rdp.vncGatewayPort = 0;
    RDP_ASSERT(!HasInvalidActiveOptionalPort(rdp));
}

RDP_TEST_CASE(connection_ports_reject_only_the_active_route_port) {
    ConnectionPortPolicyInput rdp;
    rdp.protocol = "rdp";
    rdp.rdpGatewayHost = "gateway.example";
    rdp.hasGatewayPort = true;
    rdp.gatewayPort = 0;
    RDP_ASSERT(HasInvalidActiveOptionalPort(rdp));

    ConnectionPortPolicyInput directRustDesk;
    directRustDesk.protocol = "rustdesk";
    directRustDesk.rustDeskDirect = true;
    directRustDesk.hasRustDeskDirectPort = true;
    directRustDesk.rustDeskDirectPort = 65536;
    directRustDesk.hasRustDeskRelayPort = true;
    directRustDesk.rustDeskRelayPort = 0;
    RDP_ASSERT(HasInvalidActiveOptionalPort(directRustDesk));

    ConnectionPortPolicyInput relayRustDesk;
    relayRustDesk.protocol = "rustdesk";
    relayRustDesk.hasRustDeskDirectPort = true;
    relayRustDesk.rustDeskDirectPort = 0;
    relayRustDesk.hasRustDeskRelayPort = true;
    relayRustDesk.rustDeskRelayPort = 0;
    RDP_ASSERT(HasInvalidActiveOptionalPort(relayRustDesk));

    ConnectionPortPolicyInput vncGateway;
    vncGateway.protocol = "vnc";
    vncGateway.vncTransport = "ultravnc_repeater";
    vncGateway.hasVncGatewayPort = true;
    vncGateway.vncGatewayPort = 0;
    RDP_ASSERT(HasInvalidActiveOptionalPort(vncGateway));
}

RDP_TEST_CASE(connection_ports_accept_valid_active_boundaries) {
    ConnectionPortPolicyInput rdp;
    rdp.protocol = "rdp";
    rdp.rdpGatewayHost = "gateway.example";
    rdp.hasGatewayPort = true;
    rdp.gatewayPort = 1;
    RDP_ASSERT(!HasInvalidActiveOptionalPort(rdp));
    rdp.gatewayPort = 65535;
    RDP_ASSERT(!HasInvalidActiveOptionalPort(rdp));

    ConnectionPortPolicyInput legacySsh;
    legacySsh.protocol = "ssh";
    legacySsh.sshProxyType = "legacy_gateway";
    legacySsh.hasGatewayPort = true;
    legacySsh.gatewayPort = 443;
    RDP_ASSERT(!HasInvalidActiveOptionalPort(legacySsh));
}
