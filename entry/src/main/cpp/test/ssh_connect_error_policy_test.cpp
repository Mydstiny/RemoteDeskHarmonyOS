#include "ssh/ssh_connect_error_policy.h"
#include "test_runner.h"

#include <cerrno>

namespace {

remotedesk::net::ResolveResult resolution(
    remotedesk::net::ResolveStatus status, int gaiError = EAI_FAIL) {
    remotedesk::net::ResolveResult result;
    result.status = status;
    result.gaiError = gaiError;
    return result;
}

remotedesk::net::ConnectResult connection(
    remotedesk::net::ConnectStatus status, int error = 0, int descriptor = -1) {
    remotedesk::net::ConnectResult result;
    result.status = status;
    result.lastError = error;
    result.descriptor = descriptor;
    return result;
}

} // namespace

RDP_TEST_CASE(ssh_connect_error_policy_preserves_resolver_failure_classes) {
    RDP_ASSERT(SshConnectErrorPolicy::fromResolution(resolution(
        remotedesk::net::ResolveStatus::Ready)) == ERR_SSH_SUCCESS);
    RDP_ASSERT(SshConnectErrorPolicy::fromResolution(resolution(
        remotedesk::net::ResolveStatus::Failed, EAI_NONAME)) == ERR_SSH_DNS_RESOLVE);
    RDP_ASSERT(SshConnectErrorPolicy::fromResolution(resolution(
        remotedesk::net::ResolveStatus::TimedOut)) == ERR_SSH_DNS_TIMEOUT);
    RDP_ASSERT(SshConnectErrorPolicy::fromResolution(resolution(
        remotedesk::net::ResolveStatus::Cancelled)) == ERR_SSH_DNS_CANCELLED);
    RDP_ASSERT(SshConnectErrorPolicy::fromResolution(resolution(
        remotedesk::net::ResolveStatus::ResourceExhausted)) ==
        ERR_SSH_DNS_RESOURCE_EXHAUSTED);
    RDP_ASSERT(SshConnectErrorPolicy::fromResolution(resolution(
        remotedesk::net::ResolveStatus::Failed, EAI_MEMORY)) ==
        ERR_SSH_DNS_RESOURCE_EXHAUSTED);
}

RDP_TEST_CASE(ssh_connect_error_policy_preserves_tcp_failure_classes) {
    RDP_ASSERT(SshConnectErrorPolicy::fromConnection(connection(
        remotedesk::net::ConnectStatus::Connected, 0, 42)) == ERR_SSH_SUCCESS);
    RDP_ASSERT(SshConnectErrorPolicy::fromConnection(connection(
        remotedesk::net::ConnectStatus::Connected)) == ERR_SSH_SOCKET_CONNECT);
    RDP_ASSERT(SshConnectErrorPolicy::fromConnection(connection(
        remotedesk::net::ConnectStatus::TimedOut)) == ERR_SSH_CONNECT_TIMEOUT);
    RDP_ASSERT(SshConnectErrorPolicy::fromConnection(connection(
        remotedesk::net::ConnectStatus::Cancelled)) == ERR_SSH_CONNECT_CANCELLED);
    RDP_ASSERT(SshConnectErrorPolicy::fromConnection(connection(
        remotedesk::net::ConnectStatus::Failed, ECONNREFUSED)) ==
        ERR_SSH_CONNECT_REFUSED);
    RDP_ASSERT(SshConnectErrorPolicy::fromConnection(connection(
        remotedesk::net::ConnectStatus::Failed, ENETUNREACH)) ==
        ERR_SSH_CONNECT_NO_ROUTE);
    RDP_ASSERT(SshConnectErrorPolicy::fromConnection(connection(
        remotedesk::net::ConnectStatus::Failed, EHOSTUNREACH)) ==
        ERR_SSH_CONNECT_NO_ROUTE);
    RDP_ASSERT(SshConnectErrorPolicy::fromConnection(connection(
        remotedesk::net::ConnectStatus::Failed, EIO)) == ERR_SSH_SOCKET_CONNECT);
}
