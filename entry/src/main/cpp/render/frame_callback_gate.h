/**
 * frame_callback_gate.h — thread-safe software-decoder frame callback gate.
 *
 * Clearing a callback is a lifecycle barrier: it prevents new invocations and
 * waits for an invocation that already captured the callback to finish.
 */

#ifndef FRAME_CALLBACK_GATE_H
#define FRAME_CALLBACK_GATE_H

#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <mutex>
#include <utility>

using SoftwareDecoderFrameCallback = std::function<int(const uint8_t* data, size_t size,
                                                       int width, int height, int stride)>;

class SoftwareDecoderFrameCallbackGate {
public:
    void Set(SoftwareDecoderFrameCallback callback) {
        std::unique_lock<std::mutex> lock(mutex_);
        callback_ = std::move(callback);
        if (!callback_) {
            callbackCv_.wait(lock, [this]() { return inFlight_ == 0; });
        }
    }

    void ClearAndWait() {
        Set(nullptr);
    }

    int Invoke(const uint8_t* data, size_t size, int width, int height, int stride) {
        SoftwareDecoderFrameCallback callback;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!callback_) {
                return 0;
            }
            callback = callback_;
            ++inFlight_;
        }

        int result = 0;
        try {
            result = callback(data, size, width, height, stride);
        } catch (...) {
            FinishInvocation();
            // Frame callbacks run on the software decoder worker. Do not let
            // a renderer-side exception escape the worker and terminate the
            // process; the caller will turn this into a render failure.
            return -1;
        }
        FinishInvocation();
        return result;
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
    SoftwareDecoderFrameCallback callback_;
    size_t inFlight_ = 0;
};

#endif // FRAME_CALLBACK_GATE_H
