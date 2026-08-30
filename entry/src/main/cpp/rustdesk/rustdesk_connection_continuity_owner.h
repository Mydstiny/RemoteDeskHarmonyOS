/**
 * RustDesk connection continuity owner.
 *
 * This is the one native owner for post-connect transport loss.  It contains
 * policy only: transport callbacks feed it events, while the bridge owns the
 * actual quiesce/reconnect execution.  Keeping the clock and retry budget
 * here makes duplicate network notifications and non-retryable auth errors
 * deterministic in both production and tests.
 */
#ifndef RUSTDESK_CONNECTION_CONTINUITY_OWNER_H
#define RUSTDESK_CONNECTION_CONTINUITY_OWNER_H

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <mutex>

enum class RustDeskContinuityState {
    Idle,
    Connected,
    TransportLost,
    RetryPending,
    ReauthRequired,
    Terminal,
};

enum class RustDeskTransportErrorClass {
    None,
    Reset,
    Aborted,
    Timeout,
    BrokenPipe,
    NetworkDown,
    Unreachable,
    Auth,
    TwoFactor,
    Approval,
    License,
    Key,
    Protocol,
    Crypto,
    UserDisconnected,
    Unknown,
};

inline RustDeskTransportErrorClass RustDeskTransportErrorClassFromString(
    std::string_view value) {
    if (value == "reset") return RustDeskTransportErrorClass::Reset;
    if (value == "aborted") return RustDeskTransportErrorClass::Aborted;
    if (value == "timeout" || value == "timedout") return RustDeskTransportErrorClass::Timeout;
    if (value == "brokenpipe" || value == "broken_pipe") {
        return RustDeskTransportErrorClass::BrokenPipe;
    }
    if (value == "networkdown" || value == "network_down") {
        return RustDeskTransportErrorClass::NetworkDown;
    }
    if (value == "unreachable" || value == "networkunreachable") {
        return RustDeskTransportErrorClass::Unreachable;
    }
    if (value == "auth" || value == "authentication") return RustDeskTransportErrorClass::Auth;
    if (value == "2fa" || value == "two_factor") return RustDeskTransportErrorClass::TwoFactor;
    if (value == "approval") return RustDeskTransportErrorClass::Approval;
    if (value == "license") return RustDeskTransportErrorClass::License;
    if (value == "key") return RustDeskTransportErrorClass::Key;
    if (value == "protocol") return RustDeskTransportErrorClass::Protocol;
    if (value == "crypto") return RustDeskTransportErrorClass::Crypto;
    if (value == "user_disconnected" || value == "user") {
        return RustDeskTransportErrorClass::UserDisconnected;
    }
    if (value.empty() || value == "none" || value == "normal") {
        return RustDeskTransportErrorClass::None;
    }
    return RustDeskTransportErrorClass::Unknown;
}

inline const char* RustDeskTransportErrorClassName(RustDeskTransportErrorClass value) {
    switch (value) {
        case RustDeskTransportErrorClass::None: return "none";
        case RustDeskTransportErrorClass::Reset: return "reset";
        case RustDeskTransportErrorClass::Aborted: return "aborted";
        case RustDeskTransportErrorClass::Timeout: return "timeout";
        case RustDeskTransportErrorClass::BrokenPipe: return "brokenpipe";
        case RustDeskTransportErrorClass::NetworkDown: return "networkdown";
        case RustDeskTransportErrorClass::Unreachable: return "unreachable";
        case RustDeskTransportErrorClass::Auth: return "auth";
        case RustDeskTransportErrorClass::TwoFactor: return "2fa";
        case RustDeskTransportErrorClass::Approval: return "approval";
        case RustDeskTransportErrorClass::License: return "license";
        case RustDeskTransportErrorClass::Key: return "key";
        case RustDeskTransportErrorClass::Protocol: return "protocol";
        case RustDeskTransportErrorClass::Crypto: return "crypto";
        case RustDeskTransportErrorClass::UserDisconnected: return "user_disconnected";
        case RustDeskTransportErrorClass::Unknown: return "unknown";
    }
    return "unknown";
}

struct RustDeskTransportEvent {
    bool error = false;
    RustDeskTransportErrorClass errorClass = RustDeskTransportErrorClass::None;
    uint64_t networkGeneration = 0;
    bool userInitiated = false;
    bool networkAvailable = true;
    uint64_t monotonicMs = 0;
};

struct RustDeskContinuityAction {
    bool visibleTransportLost = false;
    bool fastQuiesce = false;
    bool cancelAttempt = false;
    bool startAttempt = false;
    bool terminal = false;
    uint32_t attempt = 0;
    uint64_t delayMs = 0;
};

class RustDeskConnectionContinuityOwner {
public:
    static constexpr uint32_t kMaxAttemptsPerWindow = 5;
    static constexpr uint64_t kAttemptWindowMs = 60'000;
    static constexpr uint64_t kQuiesceBudgetMs = 500;

    void begin(uint64_t sessionId, uint64_t sessionGeneration, uint64_t nowMs) {
        std::lock_guard<std::mutex> lock(mutex_);
        sessionId_ = sessionId;
        sessionGeneration_ = sessionGeneration;
        // Session generation and transport/network generation are separate
        // domains. The first structured transport event establishes the
        // latter; never compare a small FFI connect epoch to a session id.
        networkGeneration_ = 0;
        state_ = RustDeskContinuityState::Connected;
        networkAvailable_ = true;
        cancelled_ = false;
        attempts_ = 0;
        windowStartedMs_ = nowMs;
        nextRetryMs_ = 0;
        retryScheduled_ = false;
        attemptInFlight_ = false;
        fastQuiesced_ = false;
    }

    RustDeskContinuityAction onTransportEvent(const RustDeskTransportEvent& event) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (event.networkGeneration != 0 &&
            event.networkGeneration != networkGeneration_ &&
            event.networkGeneration < networkGeneration_) {
            return {};
        }
        if (event.networkGeneration != 0) {
            networkGeneration_ = event.networkGeneration;
        }
        networkAvailable_ = event.networkAvailable;
        if (!event.error && !event.userInitiated) {
            state_ = RustDeskContinuityState::Connected;
            retryScheduled_ = false;
            attemptInFlight_ = false;
            nextRetryMs_ = 0;
            fastQuiesced_ = false;
            return {};
        }

        RustDeskContinuityAction action;
        action.visibleTransportLost = true;
        action.fastQuiesce = true;
        fastQuiesced_ = true;
        const bool retryable = !event.userInitiated && IsRetryable(event.errorClass);
        if (!retryable) {
            state_ = (event.errorClass == RustDeskTransportErrorClass::Auth ||
                      event.errorClass == RustDeskTransportErrorClass::TwoFactor ||
                      event.errorClass == RustDeskTransportErrorClass::Approval)
                ? RustDeskContinuityState::ReauthRequired
                : RustDeskContinuityState::Terminal;
            cancelled_ = true;
            retryScheduled_ = false;
            attemptInFlight_ = false;
            action.terminal = true;
            return action;
        }
        state_ = RustDeskContinuityState::TransportLost;
        // Any transport event terminates the currently active attempt.  The
        // next retry must not be suppressed merely because the previous
        // attempt was still marked in flight when its socket failed.
        attemptInFlight_ = false;
        if (networkAvailable_) {
            action = scheduleFirstAttempt(event.monotonicMs, action);
        }
        return action;
    }

    RustDeskContinuityAction onNetworkChanged(bool available, uint64_t generation,
                                               uint64_t nowMs) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (generation != 0 && generation < networkGeneration_) {
            return {};
        }
        const bool generationChanged = generation != 0 &&
            networkGeneration_ != 0 && generation > networkGeneration_;
        if (generation != 0) {
            networkGeneration_ = generation;
        }
        const bool changed = networkAvailable_ != available;
        const bool invalidated = generationChanged || (changed && !available);
        networkAvailable_ = available;
        if (cancelled_) {
            return {};
        }

        if (invalidated) {
            RustDeskContinuityAction action;
            action.visibleTransportLost = true;
            action.fastQuiesce = true;
            action.cancelAttempt = true;
            fastQuiesced_ = true;
            state_ = RustDeskContinuityState::TransportLost;
            retryScheduled_ = false;
            attemptInFlight_ = false;
            nextRetryMs_ = 0;
            if (generationChanged) {
                // A new network generation owns a fresh resolver result and
                // retry window. Never charge it for candidates selected on
                // the retired network.
                attempts_ = 0;
                windowStartedMs_ = nowMs;
            }
            if (available) {
                action = scheduleFirstAttempt(nowMs, action);
            }
            return action;
        }

        if (!available ||
            (state_ != RustDeskContinuityState::TransportLost &&
             state_ != RustDeskContinuityState::RetryPending)) {
            return {};
        }
        if (!changed && (retryScheduled_ || attemptInFlight_)) {
            return {};
        }
        return scheduleFirstAttempt(nowMs, {});
    }

    RustDeskContinuityAction poll(uint64_t nowMs) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (cancelled_ || !retryScheduled_ || !networkAvailable_ ||
            nowMs < nextRetryMs_) {
            return {};
        }
        retryScheduled_ = false;
        attemptInFlight_ = true;
        state_ = RustDeskContinuityState::RetryPending;
        RustDeskContinuityAction action;
        action.startAttempt = true;
        action.attempt = attempts_;
        return action;
    }

    void recordAttemptResult(bool succeeded, uint64_t nowMs) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (succeeded) {
            state_ = RustDeskContinuityState::Connected;
            retryScheduled_ = false;
            nextRetryMs_ = 0;
            attempts_ = 0;
            attemptInFlight_ = false;
            fastQuiesced_ = false;
            return;
        }
        if (nowMs - windowStartedMs_ >= kAttemptWindowMs) {
            windowStartedMs_ = nowMs;
            attempts_ = 0;
        }
        attemptInFlight_ = false;
        if (attempts_ >= kMaxAttemptsPerWindow || cancelled_ || !networkAvailable_) {
            state_ = RustDeskContinuityState::TransportLost;
            retryScheduled_ = false;
            attemptInFlight_ = false;
            return;
        }
        static constexpr uint64_t kBaseDelaysMs[] = {1000, 2000, 5000, 10000};
        const size_t index = std::min<size_t>(attempts_ > 0 ? attempts_ - 1 : 0, 3);
        const int jitterPercent = static_cast<int>((sessionGeneration_ + attempts_ * 17) % 41) - 20;
        const uint64_t base = kBaseDelaysMs[index];
        const uint64_t delay = static_cast<uint64_t>(
            static_cast<int64_t>(base) * (100 + jitterPercent) / 100);
        ++attempts_;
        nextRetryMs_ = nowMs + delay;
        retryScheduled_ = true;
        state_ = RustDeskContinuityState::RetryPending;
    }

    void cancel() {
        std::lock_guard<std::mutex> lock(mutex_);
        cancelled_ = true;
        retryScheduled_ = false;
        attemptInFlight_ = false;
        nextRetryMs_ = 0;
        state_ = RustDeskContinuityState::Terminal;
    }

    RustDeskContinuityState state() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return state_;
    }
    uint64_t sessionGeneration() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return sessionGeneration_;
    }
    uint64_t networkGeneration() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return networkGeneration_;
    }
    uint32_t attempts() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return attempts_;
    }
    uint64_t nextRetryMs() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return nextRetryMs_;
    }
    bool networkAvailable() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return networkAvailable_;
    }
    bool fastQuiesced() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return fastQuiesced_;
    }

private:
    static bool IsRetryable(RustDeskTransportErrorClass errorClass) {
        switch (errorClass) {
            case RustDeskTransportErrorClass::Reset:
            case RustDeskTransportErrorClass::Aborted:
            case RustDeskTransportErrorClass::Timeout:
            case RustDeskTransportErrorClass::BrokenPipe:
            case RustDeskTransportErrorClass::NetworkDown:
            case RustDeskTransportErrorClass::Unreachable:
                return true;
            default:
                return false;
        }
    }

    RustDeskContinuityAction scheduleFirstAttempt(uint64_t nowMs,
                                                   RustDeskContinuityAction action) {
        if (cancelled_ || !networkAvailable_ || retryScheduled_ || attemptInFlight_) {
            return action;
        }
        if (nowMs - windowStartedMs_ >= kAttemptWindowMs) {
            windowStartedMs_ = nowMs;
            attempts_ = 0;
        }
        if (attempts_ >= kMaxAttemptsPerWindow) {
            return action;
        }
        ++attempts_;
        attemptInFlight_ = true;
        state_ = RustDeskContinuityState::RetryPending;
        action.startAttempt = true;
        action.attempt = attempts_;
        return action;
    }

    mutable std::mutex mutex_;
    uint64_t sessionId_ = 0;
    uint64_t sessionGeneration_ = 0;
    uint64_t networkGeneration_ = 0;
    uint64_t windowStartedMs_ = 0;
    uint64_t nextRetryMs_ = 0;
    RustDeskContinuityState state_ = RustDeskContinuityState::Idle;
    uint32_t attempts_ = 0;
    bool networkAvailable_ = true;
    bool cancelled_ = false;
    bool retryScheduled_ = false;
    bool attemptInFlight_ = false;
    bool fastQuiesced_ = false;
};

#endif // RUSTDESK_CONNECTION_CONTINUITY_OWNER_H
