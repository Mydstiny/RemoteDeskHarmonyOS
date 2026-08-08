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

RDP_TEST_CASE(ssh_route_policy_validates_bounded_jump_hops) {
    SshRoute route;
    route.kind = SshRouteKind::SshJump;
    route.endpointHost = "target.example";
    route.endpointPort = 22;
    for (size_t index = 0; index < kSshMaxJumpHops; ++index) {
        SshJumpHop hop;
        hop.host = "hop-" + std::to_string(index + 1) + ".example";
        hop.username = "jump";
        route.hops.push_back(std::move(hop));
    }
    RDP_ASSERT(sshRouteHopsValid(route));

    SshJumpHop extra;
    extra.host = "hop-4.example";
    extra.username = "jump";
    route.hops.push_back(std::move(extra));
    RDP_ASSERT(!sshRouteHopsValid(route));

    route.hops.pop_back();
    route.hops[1].authMethod = "unsupported";
    RDP_ASSERT(!sshRouteHopsValid(route));

    route.hops[1].authMethod = "keyboard-interactive";
    RDP_ASSERT(sshRouteHopsValid(route));
    route.schemaVersion = 2;
    RDP_ASSERT(!sshRouteHopsValid(route));
}

RDP_TEST_CASE(ssh_route_policy_keeps_frp_control_plane_modes_explicit) {
    RDP_ASSERT(kSshProxyUnsupportedError == -19);
    RDP_ASSERT(sshRouteTypeIsKnown("frp_visitor"));
    RDP_ASSERT(sshRouteTypeIsKnown("frp_stcp"));
    RDP_ASSERT(sshRouteTypeIsKnown("frp_sudp"));
    RDP_ASSERT(sshRouteTypeIsKnown("frp_xtcp"));
    RDP_ASSERT(sshRouteTypeIsFrp("frp_tcp"));
    RDP_ASSERT(sshRouteTypeIsFrp("frp_visitor"));
    RDP_ASSERT(sshRouteTypeNeedsFrpControlPlane("frp_visitor"));
    RDP_ASSERT(sshRouteTypeNeedsFrpControlPlane("frp_stcp"));
    RDP_ASSERT(sshRouteTypeNeedsFrpControlPlane("frp_sudp"));
    RDP_ASSERT(sshRouteTypeNeedsFrpControlPlane("frp_xtcp"));
    RDP_ASSERT(!sshRouteTypeNeedsFrpControlPlane("frp_tcp"));
    RDP_ASSERT(sshRouteTypeHasNativeTransport("frp_tcp"));
    RDP_ASSERT(!sshRouteTypeHasNativeTransport("frp_visitor"));
}
