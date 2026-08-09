#include "test_runner.h"
#include "ssh/ssh_pty_recovery_policy.h"

RDP_TEST_CASE(ssh_pty_recovery_retries_only_transient_failures) {
    RDP_ASSERT(SshPtyRecoveryPolicy::retryable(
        SshPtyFailureClass::TRANSIENT_TRANSPORT));
    RDP_ASSERT(SshPtyRecoveryPolicy::retryable(
        SshPtyFailureClass::TRANSIENT_CHANNEL));
    RDP_ASSERT(!SshPtyRecoveryPolicy::retryable(
        SshPtyFailureClass::SERVER_REJECTED));
    RDP_ASSERT(!SshPtyRecoveryPolicy::retryable(
        SshPtyFailureClass::PERMANENT));
}

RDP_TEST_CASE(ssh_pty_recovery_has_two_rebuilds_after_first_attempt) {
    RDP_ASSERT(SshPtyRecoveryPolicy::hasRetryBudget(0));
    RDP_ASSERT(SshPtyRecoveryPolicy::hasRetryBudget(1));
    RDP_ASSERT(!SshPtyRecoveryPolicy::hasRetryBudget(2));
}
