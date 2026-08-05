#include "test_runner.h"
#include "ssh/ssh_route_policy.h"

RDP_TEST_CASE(ssh_route_policy_distinguishes_raw_frp_endpoint) {
    RDP_ASSERT(sshRouteTypeIsKnown("frp_tcp"));
    RDP_ASSERT(sshRouteTypeUsesRawTcpEndpoint("frp_tcp"));
    RDP_ASSERT(sshRouteTypeNeedsProxyEndpoint("frp_tcp"));
    RDP_ASSERT(!sshRouteTypeUsesRawTcpEndpoint("http_connect"));
}

RDP_TEST_CASE(ssh_route_policy_keeps_jump_route_explicit) {
    RDP_ASSERT(sshRouteTypeIsKnown("ssh_jump"));
    RDP_ASSERT(sshRouteTypeNeedsProxyEndpoint("ssh_jump"));
    RDP_ASSERT(!sshRouteTypeUsesRawTcpEndpoint("ssh_jump"));
    RDP_ASSERT(!sshRouteTypeIsKnown("legacy_gateway"));
}
