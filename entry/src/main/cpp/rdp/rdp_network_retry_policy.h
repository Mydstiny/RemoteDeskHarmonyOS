#pragma once

#include "common/network_generation_fence.h"

#include <utility>

class RdpNetworkRetryPolicy final {
public:
    static constexpr int kMaximumAttempts = 2;

    static bool canRetryCancelledAttempt(
        int completedAttempt,
        const remotedesk::net::NetworkGenerationSnapshot& captured,
        const remotedesk::net::NetworkGenerationSnapshot& current) {
        return completedAttempt == 0 && current.available &&
            current.generation > captured.generation;
    }

    template <typename Result, typename SnapshotProvider,
              typename ProbeAttempt, typename IsNetworkCancelled,
              typename UnavailableResult, typename RetryObserver>
    static Result runOnCurrentNetwork(
        SnapshotProvider&& snapshotProvider, ProbeAttempt&& probeAttempt,
        IsNetworkCancelled&& isNetworkCancelled,
        UnavailableResult&& unavailableResult,
        RetryObserver&& retryObserver) {
        for (int attempt = 0; attempt < kMaximumAttempts; ++attempt) {
            const remotedesk::net::NetworkGenerationSnapshot captured =
                snapshotProvider();
            if (!captured.available) {
                return unavailableResult();
            }
            Result result = probeAttempt(captured);
            if (!isNetworkCancelled(result)) {
                return result;
            }
            const remotedesk::net::NetworkGenerationSnapshot current =
                snapshotProvider();
            if (!canRetryCancelledAttempt(attempt, captured, current)) {
                return result;
            }
            retryObserver(current);
        }
        return unavailableResult();
    }
};
