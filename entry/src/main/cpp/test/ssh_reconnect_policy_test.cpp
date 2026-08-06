#include "test_runner.h"
#include "ssh/ssh_reconnect_policy.h"

RDP_TEST_CASE(ssh_reconnect_policy_uses_bounded_exponential_backoff) {
    RDP_ASSERT(SshReconnectPolicy::kKeepaliveSeconds == 30);
    RDP_ASSERT(SshReconnectPolicy::kKeepaliveFailureThreshold == 3);
    RDP_ASSERT(SshReconnectPolicy::exponentialDelayMilliseconds(0) == 1000);
    RDP_ASSERT(SshReconnectPolicy::exponentialDelayMilliseconds(1) == 2000);
    RDP_ASSERT(SshReconnectPolicy::exponentialDelayMilliseconds(6) == 30000);
    RDP_ASSERT(SshReconnectPolicy::jitteredDelayMilliseconds(0, 0) == 800);
    RDP_ASSERT(SshReconnectPolicy::jitteredDelayMilliseconds(0, 1000) == 1200);
}

RDP_TEST_CASE(ssh_reconnect_policy_enforces_attempt_and_window_limits) {
    RDP_ASSERT(SshReconnectPolicy::canAttempt(0, 0));
    RDP_ASSERT(SshReconnectPolicy::canAttempt(7, 599999));
    RDP_ASSERT(!SshReconnectPolicy::canAttempt(8, 0));
    RDP_ASSERT(!SshReconnectPolicy::canAttempt(0, 600000));
    RDP_ASSERT(!SshReconnectPolicy::keepaliveFailureTriggersRecovery(2));
    RDP_ASSERT(SshReconnectPolicy::keepaliveFailureTriggersRecovery(3));
}
