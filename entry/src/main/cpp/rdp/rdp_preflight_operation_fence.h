#ifndef RDP_PREFLIGHT_OPERATION_FENCE_H
#define RDP_PREFLIGHT_OPERATION_FENCE_H

#include <atomic>
#include <cstdint>

namespace remotedesk::rdp {

/**
 * Process-wide generation fence for asynchronous RDP route preflights.
 *
 * Account transitions invalidate every captured token and wait until active
 * workers have destroyed their request copy (including its plaintext
 * password) before opening the next account scope.
 */
class RdpPreflightOperationFence final {
public:
    using Token = uint64_t;
    using AdmissionSnapshotHook = void (*)(void*) noexcept;

    explicit RdpPreflightOperationFence(
        AdmissionSnapshotHook admissionSnapshotHook = nullptr,
        void* admissionSnapshotHookContext = nullptr) noexcept
        : admissionSnapshotHook_(admissionSnapshotHook),
          admissionSnapshotHookContext_(admissionSnapshotHookContext) {}

    Token begin() noexcept {
        const uint64_t capturedState = state_.load();
        if ((capturedState & kClosedMask) != 0) {
            return 0;
        }
        if (admissionSnapshotHook_ != nullptr) {
            admissionSnapshotHook_(admissionSnapshotHookContext_);
        }
        active_.fetch_add(1);
        // Admission and generation live in one atomic word. Never retry a
        // changed snapshot: a caller suspended before close must still be
        // rejected if it resumes only after reopen (the close/reopen ABA).
        if (state_.load() != capturedState) {
            end();
            return 0;
        }
        return capturedState >> kGenerationShift;
    }

    void end() noexcept {
        uint64_t active = active_.load(std::memory_order_acquire);
        while (active > 0 && !active_.compare_exchange_weak(
            active, active - 1, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
        }
    }

    uint64_t cancelAll() noexcept {
        state_.fetch_add(kGenerationIncrement);
        return active();
    }

    /** Close admission before invalidating old tokens for a scope transition. */
    uint64_t closeAndCancelAll() noexcept {
        uint64_t current = state_.load();
        while (!state_.compare_exchange_weak(
            current, ((current & ~kClosedMask) + kGenerationIncrement) |
                kClosedMask)) {
        }
        return active();
    }

    /** Reopen only after the whole account transition has committed or rolled back. */
    bool reopen() noexcept {
        state_.fetch_and(~kClosedMask);
        return admissionOpen();
    }

    bool shouldCancel(Token token) const noexcept {
        return token == 0 ||
            (state_.load() >> kGenerationShift) != token;
    }

    uint64_t active() const noexcept {
        return active_.load(std::memory_order_acquire);
    }

    bool admissionOpen() const noexcept {
        return (state_.load() & kClosedMask) == 0;
    }

private:
    static constexpr uint64_t kClosedMask = 1;
    static constexpr uint64_t kGenerationShift = 1;
    static constexpr uint64_t kGenerationIncrement = 1ULL << kGenerationShift;
    // Bits [63:1] are the generation; bit 0 is the closed-admission flag.
    // Generation starts at 1 so token 0 remains an unambiguous rejection.
    std::atomic<uint64_t> state_ {1ULL << kGenerationShift};
    std::atomic<uint64_t> active_ {0};
    AdmissionSnapshotHook admissionSnapshotHook_ {nullptr};
    void* admissionSnapshotHookContext_ {nullptr};
};

inline RdpPreflightOperationFence& ProcessRdpPreflightOperationFence() {
    static RdpPreflightOperationFence fence;
    return fence;
}

}  // namespace remotedesk::rdp

#endif  // RDP_PREFLIGHT_OPERATION_FENCE_H
