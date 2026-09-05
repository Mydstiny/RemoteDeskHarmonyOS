#ifndef SSH_OPERATION_CONTROL_H
#define SSH_OPERATION_CONTROL_H

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>

enum class SshOperationCancelReason : std::uint8_t {
    None = 0,
    User = 1,
    Deadline = 2,
    NetworkChanged = 3,
};

/**
 * One cancellable SSH auxiliary operation. Cancellation is level-triggered:
 * binding a transport after cancellation immediately invokes the callback.
 */
class SshOperationControl final {
public:
    explicit SshOperationControl(std::uint64_t operationId)
        : operationId_(operationId) {}

    std::uint64_t operationId() const noexcept { return operationId_; }

    bool bindTransportCancel(std::function<void()> callback) {
        std::function<void()> invoke;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (finished_) { return false; }
            transportCancel_ = std::move(callback);
            transportCancelDelivered_ = false;
            if (cancelReason_.load(std::memory_order_acquire) !=
                SshOperationCancelReason::None) {
                invoke = transportCancel_;
                transportCancelDelivered_ = static_cast<bool>(invoke);
            }
        }
        if (invoke) { invoke(); }
        return true;
    }

    void clearTransportCancel() {
        std::lock_guard<std::mutex> lock(mutex_);
        transportCancel_ = nullptr;
        transportCancelDelivered_ = false;
    }

    bool cancel(SshOperationCancelReason reason) {
        if (reason == SshOperationCancelReason::None) { return false; }
        std::function<void()> callback;
        bool won = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (finished_) { return false; }
            SshOperationCancelReason expected = SshOperationCancelReason::None;
            won = cancelReason_.compare_exchange_strong(
                expected, reason, std::memory_order_acq_rel);
            if (won && !transportCancelDelivered_) {
                callback = transportCancel_;
                transportCancelDelivered_ = static_cast<bool>(callback);
            }
        }
        if (callback) { callback(); }
        condition_.notify_all();
        return won;
    }

    bool cancelled() const noexcept {
        return cancelReason_.load(std::memory_order_acquire) !=
            SshOperationCancelReason::None;
    }

    SshOperationCancelReason cancelReason() const noexcept {
        return cancelReason_.load(std::memory_order_acquire);
    }

    void finish() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            finished_ = true;
            transportCancel_ = nullptr;
            transportCancelDelivered_ = false;
        }
        condition_.notify_all();
    }

    /** Returns true only when the operation finished before cancellation/deadline. */
    bool waitUntilFinishedOrCancelled(
        std::chrono::steady_clock::time_point deadline) {
        std::unique_lock<std::mutex> lock(mutex_);
        const bool signalled = condition_.wait_until(lock, deadline, [this]() {
            return finished_ || cancelReason_.load(std::memory_order_acquire) !=
                SshOperationCancelReason::None;
        });
        return signalled && finished_;
    }

private:
    std::uint64_t operationId_ = 0;
    std::atomic<SshOperationCancelReason> cancelReason_ {
        SshOperationCancelReason::None};
    mutable std::mutex mutex_;
    std::condition_variable condition_;
    bool finished_ = false;
    std::function<void()> transportCancel_;
    bool transportCancelDelivered_ = false;
};

class SshOperationRegistry final {
public:
    static constexpr std::size_t kMaxPendingOperations = 32;

    bool insert(const std::shared_ptr<SshOperationControl>& control) {
        if (!control || control->operationId() == 0) { return false; }
        std::lock_guard<std::mutex> lock(mutex_);
        if (operations_.size() >= kMaxPendingOperations ||
            operations_.find(control->operationId()) != operations_.end()) {
            return false;
        }
        operations_.emplace(control->operationId(), control);
        return true;
    }

    bool cancel(std::uint64_t operationId, SshOperationCancelReason reason) {
        std::shared_ptr<SshOperationControl> control;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            const auto found = operations_.find(operationId);
            if (found == operations_.end()) { return false; }
            control = found->second;
        }
        return control->cancel(reason);
    }

    bool eraseIf(std::uint64_t operationId,
                 const std::shared_ptr<SshOperationControl>& expected) {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto found = operations_.find(operationId);
        if (found == operations_.end() || found->second != expected) { return false; }
        operations_.erase(found);
        return true;
    }

    std::size_t size() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return operations_.size();
    }

private:
    mutable std::mutex mutex_;
    std::map<std::uint64_t, std::shared_ptr<SshOperationControl>> operations_;
};

#endif // SSH_OPERATION_CONTROL_H
