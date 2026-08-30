#include "rdp/rdp_network_retry_policy.h"
#include "test_runner.h"

RDP_TEST_CASE(rdp_network_retry_allows_only_one_new_available_generation) {
    const remotedesk::net::NetworkGenerationSnapshot captured {10, true};
    RDP_ASSERT(RdpNetworkRetryPolicy::canRetryCancelledAttempt(
        0, captured, remotedesk::net::NetworkGenerationSnapshot {11, true}));
    RDP_ASSERT(!RdpNetworkRetryPolicy::canRetryCancelledAttempt(
        1, captured, remotedesk::net::NetworkGenerationSnapshot {12, true}));
    RDP_ASSERT_EQ(RdpNetworkRetryPolicy::kMaximumAttempts, 2);
}

RDP_TEST_CASE(rdp_network_retry_rejects_unavailable_same_or_stale_network) {
    const remotedesk::net::NetworkGenerationSnapshot captured {10, true};
    RDP_ASSERT(!RdpNetworkRetryPolicy::canRetryCancelledAttempt(
        0, captured, remotedesk::net::NetworkGenerationSnapshot {11, false}));
    RDP_ASSERT(!RdpNetworkRetryPolicy::canRetryCancelledAttempt(
        0, captured, remotedesk::net::NetworkGenerationSnapshot {10, true}));
    RDP_ASSERT(!RdpNetworkRetryPolicy::canRetryCancelledAttempt(
        0, captured, remotedesk::net::NetworkGenerationSnapshot {9, true}));
}

RDP_TEST_CASE(rdp_network_retry_runner_retries_exactly_once) {
    const remotedesk::net::NetworkGenerationSnapshot snapshots[] = {
        {10, true}, {11, true}, {11, true}, {12, true},
    };
    size_t snapshotIndex = 0;
    int probeCalls = 0;
    int retryNotifications = 0;
    const int result = RdpNetworkRetryPolicy::runOnCurrentNetwork<int>(
        [&]() { return snapshots[snapshotIndex++]; },
        [&](const remotedesk::net::NetworkGenerationSnapshot&) {
            ++probeCalls;
            return -39;
        },
        [](int value) { return value == -39; },
        []() { return -100; },
        [&](const remotedesk::net::NetworkGenerationSnapshot&) {
            ++retryNotifications;
        });

    RDP_ASSERT_EQ(result, -39);
    RDP_ASSERT_EQ(probeCalls, 2);
    RDP_ASSERT_EQ(retryNotifications, 1);
    RDP_ASSERT_EQ(snapshotIndex, static_cast<size_t>(4));
}

RDP_TEST_CASE(rdp_network_retry_runner_never_probes_unavailable_network) {
    int probeCalls = 0;
    int retryNotifications = 0;
    const int result = RdpNetworkRetryPolicy::runOnCurrentNetwork<int>(
        []() {
            return remotedesk::net::NetworkGenerationSnapshot {20, false};
        },
        [&](const remotedesk::net::NetworkGenerationSnapshot&) {
            ++probeCalls;
            return -39;
        },
        [](int value) { return value == -39; },
        []() { return -100; },
        [&](const remotedesk::net::NetworkGenerationSnapshot&) {
            ++retryNotifications;
        });

    RDP_ASSERT_EQ(result, -100);
    RDP_ASSERT_EQ(probeCalls, 0);
    RDP_ASSERT_EQ(retryNotifications, 0);
}
