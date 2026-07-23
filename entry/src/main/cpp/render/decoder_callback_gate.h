/**
 * decoder_callback_gate.h - thread-safe decoder callback lifecycle barrier.
 */

#ifndef DECODER_CALLBACK_GATE_H
#define DECODER_CALLBACK_GATE_H

#include <cstddef>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <utility>

/**
 * Set(nullptr) prevents new invocations and waits for callbacks which already
 * copied the function to finish before decoder-owned resources are destroyed.
 */
template <typename Callback>
class DecoderCallbackGate {
public:
    void Set(Callback callback) {
        std::unique_lock<std::mutex> lock(mutex_);
        callback_ = std::move(callback);
        if (!callback_) {
            callbackCv_.wait(lock, [this]() { return inFlight_ == 0; });
        }
    }

    void ClearAndWait() {
        Set(nullptr);
    }

    template <typename... Args>
    void Invoke(Args&&... args) {
        Callback callback;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!callback_) {
                return;
            }
            callback = callback_;
            ++inFlight_;
        }

        try {
            callback(std::forward<Args>(args)...);
        } catch (...) {
            // Decoder callbacks run on codec/render threads. Never allow an
            // exception to escape and terminate the process.
        }
        FinishInvocation();
    }

private:
    void FinishInvocation() {
        std::lock_guard<std::mutex> lock(mutex_);
        --inFlight_;
        if (inFlight_ == 0) {
            callbackCv_.notify_all();
        }
    }

    std::mutex mutex_;
    std::condition_variable callbackCv_;
    Callback callback_;
    size_t inFlight_ = 0;
};

#endif // DECODER_CALLBACK_GATE_H
