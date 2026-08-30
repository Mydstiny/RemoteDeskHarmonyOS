#pragma once

#include <atomic>

/**
 * Generation-local gate for a FreeRDP instance that has been detached from
 * the public slot but cannot yet be freed because callbacks or transport
 * workers still own its raw context.
 */
class RdpPlatformRetirementGate final {
public:
    void markPending() noexcept {
        pending_.store(true, std::memory_order_release);
    }

    bool pending() const noexcept {
        return pending_.load(std::memory_order_acquire);
    }

    // A duplicate cleanup that observes an empty public instance slot may
    // release the generation owner only when no detached platform context is
    // still quarantined behind callback/worker fences.
    bool canReleaseAbsentInstanceOwner() const noexcept {
        return !pending();
    }

private:
    std::atomic<bool> pending_ {false};
};
