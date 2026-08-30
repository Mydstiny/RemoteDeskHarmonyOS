#include "test_runner.h"
#include "ssh/ssh_auth_replay_policy.h"
#include "ssh/ssh_network_lifecycle_policy.h"
#include "ssh/ssh_network_generation_policy.h"
#include "ssh/ssh_session_manager.h"

#include <cassert>
#include <chrono>

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

RDP_TEST_CASE(ssh_network_generation_policy_admits_writes_only_on_current_route) {
    remotedesk::net::NetworkGenerationFence fence(70, true);
    const remotedesk::net::NetworkGenerationSnapshot captured = fence.snapshot();
    int writes = 0;
    RDP_ASSERT(SshNetworkGenerationPolicy::admitWrite(
        fence, captured, []() { return false; }, [&writes]() { ++writes; }));
    RDP_ASSERT_EQ(writes, 1);

    int cancellationChecks = 0;
    RDP_ASSERT(!SshNetworkGenerationPolicy::admitWrite(
        fence, captured,
        [&cancellationChecks]() { return ++cancellationChecks >= 2; },
        [&writes]() { ++writes; }));
    RDP_ASSERT_EQ(writes, 1);

    RDP_ASSERT(fence.update(true, 71));
    RDP_ASSERT(!SshNetworkGenerationPolicy::admitWrite(
        fence, captured, []() { return false; }, [&writes]() { ++writes; }));
    RDP_ASSERT_EQ(writes, 1);
}

RDP_TEST_CASE(ssh_network_generation_retry_uses_only_newer_available_routes) {
    const remotedesk::net::NetworkGenerationSnapshot captured {10, true};
    RDP_ASSERT(SshNetworkGenerationPolicy::retryDecision(
        1, false, false, captured,
        remotedesk::net::NetworkGenerationSnapshot {10, true}) ==
        SshNetworkRetryDecision::Complete);
    RDP_ASSERT(SshNetworkGenerationPolicy::retryDecision(
        1, false, false, captured,
        remotedesk::net::NetworkGenerationSnapshot {11, false}) ==
        SshNetworkRetryDecision::WaitForAvailableNetwork);
    RDP_ASSERT(SshNetworkGenerationPolicy::retryDecision(
        1, false, false, captured,
        remotedesk::net::NetworkGenerationSnapshot {12, true}) ==
        SshNetworkRetryDecision::RetryCurrentNetwork);
    RDP_ASSERT(SshNetworkGenerationPolicy::retryDecision(
        1, false, false, captured,
        remotedesk::net::NetworkGenerationSnapshot {9, true}) ==
        SshNetworkRetryDecision::StopExhausted);
}

RDP_TEST_CASE(ssh_network_generation_retry_respects_cancel_deadline_and_budget) {
    const remotedesk::net::NetworkGenerationSnapshot captured {20, true};
    const remotedesk::net::NetworkGenerationSnapshot current {21, true};
    RDP_ASSERT(SshNetworkGenerationPolicy::retryDecision(
        1, true, false, captured, current) ==
        SshNetworkRetryDecision::StopCancelled);
    RDP_ASSERT(SshNetworkGenerationPolicy::retryDecision(
        1, false, true, captured, current) ==
        SshNetworkRetryDecision::StopDeadline);
    RDP_ASSERT(SshNetworkGenerationPolicy::retryDecision(
        SshNetworkGenerationPolicy::kMaxRouteAttempts,
        false, false, captured, current) ==
        SshNetworkRetryDecision::StopExhausted);
}

RDP_TEST_CASE(ssh_network_generation_policy_bounds_every_stage_to_original_deadline) {
    using Clock = SshNetworkGenerationPolicy::Clock;
    const auto startedAt = Clock::time_point(std::chrono::seconds(10));
    const auto routeDeadline =
        SshNetworkGenerationPolicy::initialRouteDeadline(startedAt);
    RDP_ASSERT(routeDeadline == startedAt + std::chrono::milliseconds(
        SshNetworkGenerationPolicy::kInitialRouteDeadlineMilliseconds));

    const auto earlyStage =
        SshNetworkGenerationPolicy::boundedStageDeadline(
            startedAt + std::chrono::seconds(1), routeDeadline,
            std::chrono::seconds(10));
    RDP_ASSERT(earlyStage == startedAt + std::chrono::seconds(11));

    const auto lateStage =
        SshNetworkGenerationPolicy::boundedStageDeadline(
            startedAt + std::chrono::seconds(25), routeDeadline,
            std::chrono::seconds(10));
    RDP_ASSERT(lateStage == routeDeadline);
    RDP_ASSERT(!SshNetworkGenerationPolicy::deadlineExpired(
        routeDeadline, routeDeadline - std::chrono::milliseconds(1)));
    RDP_ASSERT(SshNetworkGenerationPolicy::deadlineExpired(
        routeDeadline, routeDeadline));
}

RDP_TEST_CASE(ssh_auth_replay_policy_separates_route_and_target_one_shot_answers) {
    ConnectionConfig config;
    config.sshKeyboardInteractiveResponses = {"target-otp"};
    RDP_ASSERT(!SshAuthReplayPolicy::hasExplicitResponses(
        config, SshOneShotAuthScope::RouteOnly));
    RDP_ASSERT(SshAuthReplayPolicy::hasExplicitResponses(
        config, SshOneShotAuthScope::RouteAndTarget));

    config.sshKeyboardInteractiveResponses.clear();
    config.sshProxyKeyboardInteractiveResponses = {"proxy-otp"};
    RDP_ASSERT(SshAuthReplayPolicy::hasExplicitResponses(
        config, SshOneShotAuthScope::RouteOnly));

    config.sshProxyKeyboardInteractiveResponses.clear();
    config.sshJumpHopHandoffs.emplace_back();
    config.sshJumpHopHandoffs.back().keyboardInteractiveResponses = {"hop-otp"};
    RDP_ASSERT(SshAuthReplayPolicy::hasExplicitResponses(
        config, SshOneShotAuthScope::RouteOnly));
    RDP_ASSERT(SshAuthReplayPolicy::allowsAutomaticNewSession(false));
    RDP_ASSERT(!SshAuthReplayPolicy::allowsAutomaticNewSession(true));

    std::vector<std::string> consumed {"first-otp", "second-otp", "unused"};
    SshAuthReplayPolicy::clearConsumedResponses(consumed, 0, 2);
    RDP_ASSERT(consumed[0].empty());
    RDP_ASSERT(consumed[1].empty());
    RDP_ASSERT(consumed[2] == "unused");
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
