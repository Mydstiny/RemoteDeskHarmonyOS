#include "rdp_background_frame_cache.h"

bool ShouldCaptureRdpBackgroundFrame(bool enabled, uint64_t nowMs, uint64_t lastCaptureMs,
                                     uint32_t intervalMs, int width, int height, int stride,
                                     size_t size) {
    if (!enabled || intervalMs == 0 || width <= 0 || height <= 0 || stride <= 0 || size == 0) {
        return false;
    }
    if (nowMs < intervalMs) {
        return false;
    }
    if (lastCaptureMs > 0 && nowMs - lastCaptureMs < intervalMs) {
        return false;
    }
    return true;
}

bool RdpBackgroundFrameCache::capture(const uint8_t* data, size_t size, int width, int height,
                                      int stride, uint64_t capturedAtMs) {
    if (data == nullptr || width <= 0 || height <= 0 || stride <= 0 || size == 0) {
        return false;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    latest_.valid = true;
    latest_.data.assign(data, data + size);
    latest_.width = width;
    latest_.height = height;
    latest_.stride = stride;
    latest_.capturedAtMs = capturedAtMs;
    return true;
}

RdpBackgroundFrameSnapshot RdpBackgroundFrameCache::snapshot() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return latest_;
}

void RdpBackgroundFrameCache::clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    latest_ = RdpBackgroundFrameSnapshot {};
}

uint64_t RdpBackgroundFrameCache::lastCaptureMs() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return latest_.capturedAtMs;
}
