#ifndef RDP_BACKGROUND_FRAME_CACHE_H
#define RDP_BACKGROUND_FRAME_CACHE_H

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <vector>

struct RdpBackgroundFrameSnapshot {
    bool valid {false};
    std::vector<uint8_t> data;
    int width {0};
    int height {0};
    int stride {0};
    uint64_t capturedAtMs {0};
};

bool ShouldCaptureRdpBackgroundFrame(bool enabled, uint64_t nowMs, uint64_t lastCaptureMs,
                                     uint32_t intervalMs, int width, int height, int stride,
                                     size_t size);

class RdpBackgroundFrameCache {
public:
    bool capture(const uint8_t* data, size_t size, int width, int height, int stride,
                 uint64_t capturedAtMs);
    RdpBackgroundFrameSnapshot snapshot() const;
    void clear();
    uint64_t lastCaptureMs() const;

private:
    mutable std::mutex mutex_;
    RdpBackgroundFrameSnapshot latest_;
};

#endif // RDP_BACKGROUND_FRAME_CACHE_H
