#include "rdp/rdp_network_action_gate.h"
#include "rdp/rdp_network_recovery_policy.h"
#include "rdp/rdp_platform_retirement_gate.h"
#include "rdp/rdp_reconnect_credential_policy.h"
#include "rdp/rdp_teardown_retirement_fence.h"
#include "test_runner.h"

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>

RDP_TEST_CASE(rdp_teardown_retirement_fence_resumes_exact_recovery_once) {
    RdpNetworkRecoveryPolicy policy;
    RdpTeardownRetirementFence fence;
    policy.admitConnectionOwner();
    const auto action = policy.onNetworkChanged(true, 1);
    RDP_ASSERT(action.accepted);
    fence.admit(41);

    std::atomic<int> reconnectAttempts {0};
    std::atomic<RdpTeardownRetirementWaitResult> result {
        RdpTeardownRetirementWaitResult::TimedOut};
    std::thread worker([&]() {
        const auto waitResult = fence.waitUntilRetired(
            41, std::chrono::steady_clock::now() +
                    std::chrono::seconds(1),
            [&]() { return policy.isCurrent(action.token, true); });
        result.store(waitResult, std::memory_order_release);
        if (waitResult == RdpTeardownRetirementWaitResult::Retired &&
            policy.isCurrent(action.token, true)) {
            reconnectAttempts.fetch_add(1, std::memory_order_relaxed);
        }
    });

    RDP_ASSERT_EQ(fence.pendingGeneration(), static_cast<uint64_t>(41));
    RDP_ASSERT(fence.retire(41));
    worker.join();

    RDP_ASSERT(result.load(std::memory_order_acquire) ==
        RdpTeardownRetirementWaitResult::Retired);
    RDP_ASSERT_EQ(reconnectAttempts.load(std::memory_order_acquire), 1);
    RDP_ASSERT(!fence.retire(41));
    RDP_ASSERT_EQ(reconnectAttempts.load(std::memory_order_acquire), 1);
}

RDP_TEST_CASE(rdp_teardown_retirement_fence_cancels_on_explicit_disconnect) {
    RdpNetworkRecoveryPolicy policy;
    RdpTeardownRetirementFence fence;
    policy.admitConnectionOwner();
    const auto action = policy.onNetworkChanged(true, 2);
    RDP_ASSERT(action.accepted);
    fence.admit(42);

    std::mutex barrierMutex;
    std::condition_variable barrier;
    bool waiting = false;
    std::atomic<RdpTeardownRetirementWaitResult> result {
        RdpTeardownRetirementWaitResult::TimedOut};
    std::thread worker([&]() {
        {
            std::lock_guard<std::mutex> lock(barrierMutex);
            waiting = true;
        }
        barrier.notify_all();
        result.store(fence.waitUntilRetired(
            42, std::chrono::steady_clock::now() +
                    std::chrono::seconds(1),
            [&]() { return policy.isCurrent(action.token, true); }),
            std::memory_order_release);
    });
    {
        std::unique_lock<std::mutex> lock(barrierMutex);
        barrier.wait(lock, [&]() { return waiting; });
    }
    policy.retireConnectionOwner();
    fence.interrupt();
    worker.join();

    RDP_ASSERT(result.load(std::memory_order_acquire) ==
        RdpTeardownRetirementWaitResult::Cancelled);
    RDP_ASSERT_EQ(fence.pendingGeneration(), static_cast<uint64_t>(42));
    RDP_ASSERT(fence.retire(42));
}

RDP_TEST_CASE(rdp_teardown_retirement_fence_times_out_without_losing_owner) {
    RdpNetworkRecoveryPolicy policy;
    RdpTeardownRetirementFence fence;
    policy.admitConnectionOwner();
    const auto action = policy.onNetworkChanged(true, 3);
    RDP_ASSERT(action.accepted);
    fence.admit(43);

    const auto result = fence.waitUntilRetired(
        43, std::chrono::steady_clock::now() +
                std::chrono::milliseconds(1),
        [&]() { return policy.isCurrent(action.token, true); });

    RDP_ASSERT(result == RdpTeardownRetirementWaitResult::TimedOut);
    RDP_ASSERT_EQ(fence.pendingGeneration(), static_cast<uint64_t>(43));
    RDP_ASSERT(fence.retire(43));
}

RDP_TEST_CASE(rdp_network_recovery_rejects_stale_and_unowned_events) {
    RdpNetworkRecoveryPolicy policy;

    RDP_ASSERT(!policy.onNetworkChanged(true, 4).accepted);
    policy.admitConnectionOwner();
    RDP_ASSERT(!policy.onNetworkChanged(false, 4).accepted);

    const auto unavailable = policy.onNetworkChanged(false, 5);
    RDP_ASSERT(unavailable.accepted);
    RDP_ASSERT(unavailable.cancelTransport);
    RDP_ASSERT(!unavailable.reconnectNow);
    RDP_ASSERT(policy.isCurrent(unavailable.token));
    RDP_ASSERT(!policy.isCurrent(unavailable.token, true));

    const auto restored = policy.onNetworkChanged(true, 6);
    RDP_ASSERT(restored.accepted);
    RDP_ASSERT(restored.reconnectNow);
    RDP_ASSERT(!policy.isCurrent(unavailable.token));
    RDP_ASSERT(policy.isCurrent(restored.token, true));
}

RDP_TEST_CASE(rdp_network_recovery_explicit_disconnect_retires_queued_action) {
    RdpNetworkRecoveryPolicy policy;
    policy.admitConnectionOwner();
    const auto action = policy.onNetworkChanged(true, 10);
    RDP_ASSERT(action.accepted);

    std::mutex barrierMutex;
    std::condition_variable barrier;
    bool workerReady = false;
    bool workerReleased = false;
    std::atomic<bool> reconnectAdmitted {true};
    std::thread worker([&]() {
        {
            std::lock_guard<std::mutex> lock(barrierMutex);
            workerReady = true;
        }
        barrier.notify_all();
        {
            std::unique_lock<std::mutex> lock(barrierMutex);
            barrier.wait(lock, [&]() { return workerReleased; });
        }
        reconnectAdmitted.store(
            policy.isCurrent(action.token, true), std::memory_order_release);
    });
    {
        std::unique_lock<std::mutex> lock(barrierMutex);
        barrier.wait(lock, [&]() { return workerReady; });
    }
    policy.retireConnectionOwner();
    {
        std::lock_guard<std::mutex> lock(barrierMutex);
        workerReleased = true;
    }
    barrier.notify_all();
    worker.join();

    RDP_ASSERT(!reconnectAdmitted.load(std::memory_order_acquire));
}

RDP_TEST_CASE(rdp_network_recovery_new_explicit_connect_invalidates_old_action) {
    RdpNetworkRecoveryPolicy policy;
    policy.admitConnectionOwner();
    const auto oldAction = policy.onNetworkChanged(true, 20);
    RDP_ASSERT(oldAction.accepted);

    policy.admitConnectionOwner();
    RDP_ASSERT(!policy.isCurrent(oldAction.token));
    const auto nextAction = policy.onNetworkChanged(true, 21);
    RDP_ASSERT(policy.isCurrent(nextAction.token, true));
}

RDP_TEST_CASE(rdp_network_recovery_retirement_token_protects_secret_cleanup) {
    RdpNetworkRecoveryPolicy policy;
    policy.admitConnectionOwner();
    const uint64_t retired = policy.retireConnectionOwner();
    RDP_ASSERT(policy.isRetired(retired));

    policy.admitConnectionOwner();
    RDP_ASSERT(!policy.isRetired(retired));
}

RDP_TEST_CASE(rdp_network_recovery_action_never_publishes_terminal_disconnect) {
    RdpNetworkRecoveryPolicy policy;
    policy.admitConnectionOwner();
    const auto action = policy.onNetworkChanged(true, 90);

    RDP_ASSERT(action.accepted);
    RDP_ASSERT(!action.publishDisconnectedOnTeardown);
}

RDP_TEST_CASE(rdp_platform_retirement_gate_blocks_duplicate_cleanup) {
    RdpPlatformRetirementGate gate;
    std::mutex barrierMutex;
    std::condition_variable barrier;
    bool instanceDetached = false;
    bool duplicateChecked = false;
    std::atomic<bool> duplicateReleasedOwner {true};

    std::thread duplicateCleanup([&]() {
        {
            std::unique_lock<std::mutex> lock(barrierMutex);
            barrier.wait(lock, [&]() { return instanceDetached; });
        }
        duplicateReleasedOwner.store(
            gate.canReleaseAbsentInstanceOwner(),
            std::memory_order_release);
        {
            std::lock_guard<std::mutex> lock(barrierMutex);
            duplicateChecked = true;
        }
        barrier.notify_all();
    });

    // The production cleanup marks the detached raw context before clearing
    // instance_. A concurrent PostDisconnect/worker cleanup can then observe
    // an empty slot, but must not clear the generation owner while final
    // platform retirement remains behind its barrier.
    gate.markPending();
    {
        std::lock_guard<std::mutex> lock(barrierMutex);
        instanceDetached = true;
    }
    barrier.notify_all();
    {
        std::unique_lock<std::mutex> lock(barrierMutex);
        barrier.wait(lock, [&]() { return duplicateChecked; });
    }
    duplicateCleanup.join();

    RDP_ASSERT(gate.pending());
    RDP_ASSERT(!duplicateReleasedOwner.load(std::memory_order_acquire));
}

RDP_TEST_CASE(rdp_network_action_gate_blocks_stale_abort_after_explicit_connect) {
    RdpNetworkRecoveryPolicy policy;
    RdpNetworkActionGate gate;
    policy.admitConnectionOwner();
    const auto staleAction = policy.onNetworkChanged(true, 100);
    RDP_ASSERT(staleAction.accepted);

    std::mutex barrierMutex;
    std::condition_variable barrier;
    bool workerReleased = false;
    std::atomic<int> abortCalls {0};
    std::thread worker([&]() {
        {
            std::unique_lock<std::mutex> lock(barrierMutex);
            barrier.wait(lock, [&]() { return workerReleased; });
        }
        (void)gate.runIfCurrent(
            policy, staleAction.token, false,
            [&]() { abortCalls.fetch_add(1, std::memory_order_relaxed); });
    });

    {
        std::lock_guard<std::recursive_mutex> operationLock(gate.mutex());
        policy.admitConnectionOwner();
        {
            std::lock_guard<std::mutex> lock(barrierMutex);
            workerReleased = true;
        }
        barrier.notify_all();
    }
    worker.join();

    RDP_ASSERT_EQ(abortCalls.load(std::memory_order_acquire), 0);
}

RDP_TEST_CASE(rdp_reconnect_credentials_reauth_and_retirement_cleanup) {
    RdpNetworkRecoveryPolicy policy;
    ConnectionConfig config {};
    config.rdpAuthMode = RdpAuthenticationMode::Password;
    config.password = "standard-password";
    config.rdpRestrictedAdminHash = "old-hash";

    policy.admitConnectionOwner();
    RDP_ASSERT(RdpReconnectCredentialPolicy::retireOwnerAndClear(
        config, policy));
    RDP_ASSERT(config.password.empty());
    RDP_ASSERT(config.rdpRestrictedAdminHash.empty());

    config.rdpAuthMode = RdpAuthenticationMode::RestrictedAdmin;
    config.rdpRestrictedAdminHash = "replacement-hash";
    RDP_ASSERT(RdpReconnectCredentialPolicy::requiresUserResubmission(config));
}

RDP_TEST_CASE(rdp_reconnect_credential_cleanup_cannot_erase_new_owner) {
    RdpNetworkRecoveryPolicy policy;
    ConnectionConfig config {};
    config.rdpAuthMode = RdpAuthenticationMode::Password;
    config.password = "new-owner-password";

    policy.admitConnectionOwner();
    const uint64_t staleRetirement = policy.retireConnectionOwner();
    policy.admitConnectionOwner();

    RDP_ASSERT(!RdpReconnectCredentialPolicy::clearIfStillRetired(
        config, policy, staleRetirement));
    RDP_ASSERT(config.password == "new-owner-password");
    RdpReconnectCredentialPolicy::clear(config);
}

RDP_TEST_CASE(rdp_skeleton_terminal_network_failure_scrubs_reconnect_credentials) {
    RdpNetworkRecoveryPolicy policy;
    ConnectionConfig config {};
    config.rdpAuthMode = RdpAuthenticationMode::Password;
    config.password = "recoverable-password";
    config.rdpRestrictedAdminHash = "restricted-admin-hash";

    policy.admitConnectionOwner();
    const auto action = policy.onNetworkChanged(true, 120);
    RDP_ASSERT(action.accepted);
    RDP_ASSERT(!action.publishDisconnectedOnTeardown);

    // The fallback adapter cannot reconnect. Its terminal recovery path must
    // retire the owner and scrub every retained credential before ERROR.
    RDP_ASSERT(RdpReconnectCredentialPolicy::retireOwnerAndClear(
        config, policy));
    RDP_ASSERT(config.password.empty());
    RDP_ASSERT(config.rdpRestrictedAdminHash.empty());
}
