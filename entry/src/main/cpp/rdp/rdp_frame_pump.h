/**
 * rdp_frame_pump.h - latest-frame render worker for FreeRDP GDI frames
 */

#ifndef RDP_FRAME_PUMP_H
#define RDP_FRAME_PUMP_H

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <thread>
#include <vector>

class RdpFramePump {
public:
    RdpFramePump();
    ~RdpFramePump();

    bool start();
    void stop();
    bool submitLatest(const uint8_t* data, size_t size, int width, int height, int stride,
                      int dirtyX, int dirtyY, int dirtyWidth, int dirtyHeight, bool dirtyValid);
    bool isRunning() const;

    uint64_t submitted() const;
    uint64_t rendered() const;
    uint64_t replaced() const;

private:
    void loop();

    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::thread worker_;
    bool running_ = false;
    bool hasFrame_ = false;
    std::vector<uint8_t> frame_;
    int width_ = 0;
    int height_ = 0;
    int stride_ = 0;
    int dirtyX_ = 0;
    int dirtyY_ = 0;
    int dirtyWidth_ = 0;
    int dirtyHeight_ = 0;
    bool dirtyValid_ = false;
    std::atomic<uint64_t> submitted_ {0};
    std::atomic<uint64_t> rendered_ {0};
    std::atomic<uint64_t> replaced_ {0};
};

#endif // RDP_FRAME_PUMP_H
