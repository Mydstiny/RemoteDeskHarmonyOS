/**
 * rdp_shutdown_state.h - RDP teardown state and lock-order contract
 */

#ifndef RDP_SHUTDOWN_STATE_H
#define RDP_SHUTDOWN_STATE_H

#include <array>
#include <atomic>
#include <cstdint>

namespace RdpShutdown {

enum class Phase : std::uint8_t {
    Running = 0,
    Quiescing,
    TransportDisconnecting,
    Releasing,
    Complete,
};

enum class Action : std::uint8_t {
    RejectNewWork = 0,
    JoinInputWorker,
    JoinPresentationWorker,
    JoinEventWorker,
    JoinDriveWorker,
    JoinConnectWorker,
    DisconnectTransport,
    ReleaseInstance,
};

constexpr std::array<Action, 8> OrderedActions() {
    return {
        Action::RejectNewWork,
        Action::JoinInputWorker,
        Action::JoinPresentationWorker,
        Action::JoinConnectWorker,
        Action::JoinEventWorker,
        Action::JoinDriveWorker,
        Action::DisconnectTransport,
        Action::ReleaseInstance,
    };
}

constexpr bool RequiresInstanceMutexReleased(Action action) {
    return action != Action::RejectNewWork;
}

constexpr bool CanRun(Action action, bool instanceMutexHeld) {
    return !RequiresInstanceMutexReleased(action) || !instanceMutexHeld;
}

constexpr bool IsForwardTransition(Phase from, Phase to) {
    return (from == Phase::Running && to == Phase::Quiescing) ||
        (from == Phase::Quiescing && to == Phase::TransportDisconnecting) ||
        (from == Phase::TransportDisconnecting && to == Phase::Releasing) ||
        (from == Phase::Releasing && to == Phase::Complete);
}

class State {
public:
    Phase phase() const {
        return phase_.load(std::memory_order_acquire);
    }

    bool requestDisconnect() {
        Phase expected = Phase::Running;
        return phase_.compare_exchange_strong(expected, Phase::Quiescing,
                                              std::memory_order_acq_rel,
                                              std::memory_order_acquire);
    }

    bool advance(Phase expected, Phase next) {
        if (!IsForwardTransition(expected, next)) {
            return false;
        }
        return phase_.compare_exchange_strong(expected, next,
                                              std::memory_order_acq_rel,
                                              std::memory_order_acquire);
    }

    void reset() {
        phase_.store(Phase::Running, std::memory_order_release);
    }

private:
    std::atomic<Phase> phase_ {Phase::Running};
};

} // namespace RdpShutdown

#endif // RDP_SHUTDOWN_STATE_H
