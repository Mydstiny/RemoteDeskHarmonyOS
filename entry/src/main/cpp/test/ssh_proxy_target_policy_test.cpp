#include "test_runner.h"
#include "ssh/ssh_proxy_target_policy.h"

using remotedesk::ssh::PrepareProxyTarget;
using remotedesk::ssh::ProxyTargetError;

RDP_TEST_CASE(ssh_proxy_target_formats_http_connect_ipv6_authority) {
    const auto target = PrepareProxyTarget("http_connect", "2001:0DB8::20", 2222);
    RDP_ASSERT(target.ok);
    RDP_ASSERT(target.transportHost == "2001:db8::20");
    RDP_ASSERT(target.uriAuthority == "[2001:db8::20]:2222");
}

RDP_TEST_CASE(ssh_proxy_target_rejects_scoped_remote_authorities) {
    const auto http = PrepareProxyTarget("http_connect", "fe80::20%wlan0", 22);
    RDP_ASSERT(!http.ok);
    RDP_ASSERT(http.error == ProxyTargetError::RemoteScopeForbidden);
    const auto socks = PrepareProxyTarget("socks5", "fe80::20%wlan0", 22);
    RDP_ASSERT(!socks.ok);
    RDP_ASSERT(socks.error == ProxyTargetError::RemoteScopeForbidden);
    const auto jump = PrepareProxyTarget("ssh_jump", "fe80::20%wlan0", 22);
    RDP_ASSERT(!jump.ok);
    RDP_ASSERT(jump.error == ProxyTargetError::RemoteScopeForbidden);
}

RDP_TEST_CASE(ssh_proxy_target_keeps_scope_for_direct_local_transport) {
    const auto direct = PrepareProxyTarget("direct", "fe80::20%wlan0", 22);
    RDP_ASSERT(direct.ok);
    RDP_ASSERT(direct.transportHost == "fe80::20%wlan0");
    RDP_ASSERT(direct.uriAuthority == "[fe80::20%25wlan0]:22");
}

RDP_TEST_CASE(ssh_key_auth_jump_preflight_rejects_scoped_remote_target) {
    const auto target = PrepareProxyTarget("ssh_jump", "fe80::20%wlan0", 22);
    RDP_ASSERT(!target.ok);
    RDP_ASSERT(target.error == ProxyTargetError::RemoteScopeForbidden);
}

RDP_TEST_CASE(ssh_host_key_probe_jump_preflight_canonicalizes_remote_target) {
    const auto target = PrepareProxyTarget("ssh_jump", "2001:0DB8::20", 2222);
    RDP_ASSERT(target.ok);
    RDP_ASSERT(target.transportHost == "2001:db8::20");
    RDP_ASSERT(target.uriAuthority == "[2001:db8::20]:2222");
}
