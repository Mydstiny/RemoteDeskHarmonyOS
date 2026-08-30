#include "test_runner.h"
#include "ssh/ssh_network_lifecycle_policy.h"
#include "ssh/ssh_network_generation_policy.h"
#include "ssh/ssh_session_manager.h"

#include <cassert>

RDP_TEST_CASE(ssh_network_lifecycle_policy_fences_duplicate_generations) {
    RDP_ASSERT(SshNetworkLifecyclePolicy::acceptsGeneration(0, 1));
    RDP_ASSERT(SshNetworkLifecyclePolicy::acceptsGeneration(4, 5));
    RDP_ASSERT(!SshNetworkLifecyclePolicy::acceptsGeneration(5, 5));
    RDP_ASSERT(!SshNetworkLifecyclePolicy::acceptsGeneration(5, 4));
    RDP_ASSERT(!SshNetworkLifecyclePolicy::acceptsGeneration(0, 0));
}

RDP_TEST_CASE(ssh_network_lifecycle_policy_only_recovers_live_connected_owner) {
    RDP_ASSERT(SshNetworkLifecyclePolicy::shouldRequestRecovery(false, true, true));
    RDP_ASSERT(!SshNetworkLifecyclePolicy::shouldRequestRecovery(false, false, true));
    RDP_ASSERT(!SshNetworkLifecyclePolicy::shouldRequestRecovery(false, true, false));
    RDP_ASSERT(SshNetworkLifecyclePolicy::shouldRequestRecovery(true, true, true));
    RDP_ASSERT(SshNetworkLifecyclePolicy::shouldWakeRecovery(true, true));
    RDP_ASSERT(!SshNetworkLifecyclePolicy::shouldWakeRecovery(true, false));
}

RDP_TEST_CASE(ssh_network_generation_policy_cancels_every_stale_route) {
    remotedesk::net::NetworkGenerationFence fence(7, true);
    const remotedesk::net::NetworkGenerationSnapshot captured = fence.snapshot();
    RDP_ASSERT(!SshNetworkGenerationPolicy::shouldCancel(
        false, fence, captured));
    RDP_ASSERT(SshNetworkGenerationPolicy::shouldCancel(
        true, fence, captured));

    RDP_ASSERT(fence.update(true, 8));
    RDP_ASSERT(SshNetworkGenerationPolicy::shouldCancel(
        false, fence, captured));
    const remotedesk::net::NetworkGenerationSnapshot current = fence.snapshot();
    RDP_ASSERT(!SshNetworkGenerationPolicy::shouldCancel(
        false, fence, current));

    RDP_ASSERT(fence.update(false, 9));
    RDP_ASSERT(SshNetworkGenerationPolicy::shouldCancel(
        false, fence, fence.snapshot()));
}

RDP_TEST_CASE(ssh_session_manager_network_notification_runs_outside_manager_lock) {
    SshSessionManager manager;
    SshNativeFacade facade(manager);
    const SshSessionHandle handle {901, "shell", 3};
    bool callbackRan = false;
    assert(facade.registerSession(handle, "network.test", 22, nullptr,
        [&manager, &handle, &callbackRan](bool available, uint64_t generation) {
            callbackRan = available && generation == 11;
            SshSessionSnapshot snapshot;
            assert(manager.snapshot(handle, snapshot));
        }) == SshSessionManagerResult::Ok);

    assert(facade.notifyNetworkAvailability(true, 11) == 1);
    assert(callbackRan);
    assert(facade.notifyNetworkAvailability(false, 0) == 0);
}
