#ifndef RUSTDESK_DISPLAY_SWITCH_GATE_H
#define RUSTDESK_DISPLAY_SWITCH_GATE_H

#include <cstdint>
#include <mutex>

struct RustDeskDisplaySwitchGateSnapshot {
    uint64_t generation = 0;
    uint64_t readyGeneration = 0;
    int pendingDisplay = -1;
    int confirmedDisplay = -1;
    bool inputBlocked = false;
};

struct RustDeskDisplaySwitchGateDecision {
    bool acceptFrame = false;
    bool publishDisplay = false;
    int display = -1;
};

/**
 * Serializes a local single-canvas display selection against asynchronous
 * display snapshots and interleaved video frames.
 *
 * The owner must provide external synchronization. A pending selection is
 * committed only after the latest target has both acknowledged its display
 * snapshot and produced a keyframe. Frames from stale generations never
 * become active or release the input barrier.
 */
class RustDeskDisplaySwitchGate {
public:
    void reset() {
        generation_ = 0;
        readyGeneration_ = 0;
        pendingDisplay_ = -1;
        confirmedDisplay_ = -1;
        acknowledgementSeen_ = false;
    }

    uint64_t begin(int display) {
        generation_ = generation_ == UINT64_MAX ? 1 : generation_ + 1;
        pendingDisplay_ = display;
        acknowledgementSeen_ = false;
        return generation_;
    }

    void reject(uint64_t generation) {
        if (generation != generation_ || pendingDisplay_ < 0) {
            return;
        }
        pendingDisplay_ = -1;
        acknowledgementSeen_ = false;
    }

    RustDeskDisplaySwitchGateDecision observeDisplay(int display) {
        RustDeskDisplaySwitchGateDecision decision;
        if (display < 0) {
            return decision;
        }
        if (pendingDisplay_ >= 0) {
            if (display == pendingDisplay_) {
                acknowledgementSeen_ = true;
            }
            return decision;
        }
        confirmedDisplay_ = display;
        decision.publishDisplay = true;
        decision.display = display;
        return decision;
    }

    RustDeskDisplaySwitchGateDecision observeFrame(int display, bool keyFrame) {
        RustDeskDisplaySwitchGateDecision decision;
        if (display < 0) {
            return decision;
        }
        if (pendingDisplay_ >= 0) {
            if (display != pendingDisplay_ || !acknowledgementSeen_ || !keyFrame) {
                return decision;
            }
            confirmedDisplay_ = pendingDisplay_;
            pendingDisplay_ = -1;
            acknowledgementSeen_ = false;
            readyGeneration_ = generation_;
            decision.acceptFrame = true;
            decision.publishDisplay = true;
            decision.display = confirmedDisplay_;
            return decision;
        }
        if (confirmedDisplay_ < 0) {
            confirmedDisplay_ = display;
            decision.publishDisplay = true;
            decision.display = display;
        }
        decision.acceptFrame = display == confirmedDisplay_;
        return decision;
    }

    RustDeskDisplaySwitchGateSnapshot snapshot() const {
        RustDeskDisplaySwitchGateSnapshot result;
        result.generation = generation_;
        result.readyGeneration = readyGeneration_;
        result.pendingDisplay = pendingDisplay_;
        result.confirmedDisplay = confirmedDisplay_;
        result.inputBlocked = pendingDisplay_ >= 0;
        return result;
    }

private:
    uint64_t generation_ = 0;
    uint64_t readyGeneration_ = 0;
    int pendingDisplay_ = -1;
    int confirmedDisplay_ = -1;
    bool acknowledgementSeen_ = false;
};

/**
 * Owns the dispatch boundary around RustDeskDisplaySwitchGate.
 *
 * A Lease protects one short gate observation. External callbacks must be
 * invoked only after that lease is released and must perform their own owner
 * or generation validation before writing a sink. This lock is deliberately
 * independent from RustDeskBridge::Impl::mutex: video delivery may
 * synchronously report decoder pressure back to the bridge.
 */
class RustDeskDisplaySwitchCoordinator {
public:
    class Lease {
    public:
        Lease(Lease&&) = default;
        Lease& operator=(Lease&&) = default;
        Lease(const Lease&) = delete;
        Lease& operator=(const Lease&) = delete;

        uint64_t begin(int display) {
            return gate_->begin(display);
        }

        void reject(uint64_t generation) {
            gate_->reject(generation);
        }

        void reset() {
            gate_->reset();
        }

        RustDeskDisplaySwitchGateDecision observeDisplay(int display) {
            return gate_->observeDisplay(display);
        }

        RustDeskDisplaySwitchGateDecision observeFrame(int display, bool keyFrame) {
            return gate_->observeFrame(display, keyFrame);
        }

        RustDeskDisplaySwitchGateSnapshot snapshot() const {
            return gate_->snapshot();
        }

    private:
        friend class RustDeskDisplaySwitchCoordinator;

        Lease(std::mutex& dispatchMutex, RustDeskDisplaySwitchGate& gate)
            : lock_(dispatchMutex), gate_(&gate) {}

        std::unique_lock<std::mutex> lock_;
        RustDeskDisplaySwitchGate* gate_ = nullptr;
    };

    Lease acquire() {
        return Lease(dispatchMutex_, gate_);
    }

    RustDeskDisplaySwitchGateSnapshot snapshot() {
        auto lease = acquire();
        return lease.snapshot();
    }

    void reset() {
        auto lease = acquire();
        lease.reset();
    }

private:
    std::mutex dispatchMutex_;
    RustDeskDisplaySwitchGate gate_;
};

#endif // RUSTDESK_DISPLAY_SWITCH_GATE_H
