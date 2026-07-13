/**
 * rdp_frame_pump.cpp - latest-frame render worker for FreeRDP GDI frames
 */

#include "rdp_frame_pump.h"
#include "rdp_render_policy.h"
#include "render/gl_renderer.h"

#include <cstring>
#include <exception>
#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0004
#define LOG_TAG "RDP_FRAME_PUMP"

RdpFramePump::RdpFramePump() = default;

RdpFramePump::~RdpFramePump() {
    stop();
}

bool RdpFramePump::start() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (running_) {
        return true;
    }
    running_ = true;
    try {
        worker_ = std::thread(&RdpFramePump::loop, this);
    } catch (const std::exception& e) {
        running_ = false;
        OH_LOG_ERROR(LOG_APP, "[RDP-PUMP] start failed: %{public}s", e.what());
        return false;
    } catch (...) {
        running_ = false;
        OH_LOG_ERROR(LOG_APP, "[RDP-PUMP] start failed: unknown exception");
        return false;
    }
    return true;
}

void RdpFramePump::stop() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        running_ = false;
        hasFrame_ = false;
        frame_.clear();
    }
    cv_.notify_all();
    if (worker_.joinable()) {
        worker_.join();
    }
}

bool RdpFramePump::submitLatest(const uint8_t* data, size_t size, int width, int height, int stride,
                                int dirtyX, int dirtyY, int dirtyWidth, int dirtyHeight, bool dirtyValid) {
    if (!data || size == 0 || width <= 0 || height <= 0 || stride <= 0) {
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!running_) {
            return false;
        }
        if (hasFrame_) {
            replaced_++;
        }
        const size_t dirtyStride = dirtyWidth > 0 ? static_cast<size_t>(dirtyWidth) * 4U : 0U;
        const size_t dirtyLastOffset = dirtyValid && dirtyHeight > 0 ?
            (static_cast<size_t>(dirtyY + dirtyHeight - 1) * static_cast<size_t>(stride) +
             static_cast<size_t>(dirtyX) * 4U + dirtyStride) :
            0U;
        const bool escalateToFullFrame =
            RdpRenderPolicy::ShouldEscalatePumpSubmitToFullFrame(hasFrame_, dirtyValid_, dirtyValid);
        const bool dirtyInBounds = !escalateToFullFrame && dirtyValid &&
            dirtyX >= 0 && dirtyY >= 0 && dirtyWidth > 0 && dirtyHeight > 0 &&
            dirtyX < width && dirtyY < height &&
            dirtyWidth <= width - dirtyX && dirtyHeight <= height - dirtyY &&
            dirtyLastOffset <= size;
        try {
            if (dirtyInBounds) {
                const size_t dirtySize = dirtyStride * static_cast<size_t>(dirtyHeight);
                frame_.resize(dirtySize);
                for (int row = 0; row < dirtyHeight; ++row) {
                    const uint8_t* src = data +
                        static_cast<size_t>(dirtyY + row) * static_cast<size_t>(stride) +
                        static_cast<size_t>(dirtyX) * 4U;
                    std::memcpy(frame_.data() + static_cast<size_t>(row) * dirtyStride,
                                src, dirtyStride);
                }
                stride_ = static_cast<int>(dirtyStride);
            } else {
                frame_.resize(size);
                std::memcpy(frame_.data(), data, size);
                stride_ = stride;
            }
        } catch (const std::exception& e) {
            OH_LOG_WARN(LOG_APP, "[RDP-PUMP] submit failed: %{public}s", e.what());
            return false;
        } catch (...) {
            OH_LOG_WARN(LOG_APP, "[RDP-PUMP] submit failed: unknown exception");
            return false;
        }
        width_ = width;
        height_ = height;
        dirtyX_ = dirtyX;
        dirtyY_ = dirtyY;
        dirtyWidth_ = dirtyWidth;
        dirtyHeight_ = dirtyHeight;
        dirtyValid_ = dirtyInBounds;
        hasFrame_ = true;
        submitted_++;
    }
    cv_.notify_one();
    return true;
}

void RdpFramePump::loop() {
    OH_LOG_INFO(LOG_APP, "[RDP-PUMP] render worker started");
    while (true) {
        std::vector<uint8_t> frame;
        int width = 0;
        int height = 0;
        int stride = 0;
        int dirtyX = 0;
        int dirtyY = 0;
        int dirtyWidth = 0;
        int dirtyHeight = 0;
        bool dirtyValid = false;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            cv_.wait(lock, [this]() { return !running_ || hasFrame_; });
            if (!running_) {
                break;
            }
            frame.swap(frame_);
            width = width_;
            height = height_;
            stride = stride_;
            dirtyX = dirtyX_;
            dirtyY = dirtyY_;
            dirtyWidth = dirtyWidth_;
            dirtyHeight = dirtyHeight_;
            dirtyValid = dirtyValid_;
            hasFrame_ = false;
        }

        int ret = 0;
        try {
            ret = dirtyValid ?
                RendererNapi::RenderRawBgraRectActive(frame.data(), frame.size(), width, height, stride,
                                                      dirtyX, dirtyY, dirtyWidth, dirtyHeight) :
                RendererNapi::RenderRawBgraActive(frame.data(), frame.size(), width, height, stride);
        } catch (const std::exception& e) {
            ret = -98;
            OH_LOG_ERROR(LOG_APP, "[RDP-PUMP] render exception: %{public}s", e.what());
        } catch (...) {
            ret = -99;
            OH_LOG_ERROR(LOG_APP, "[RDP-PUMP] render exception: unknown");
        }
        const uint64_t count = rendered_.fetch_add(1) + 1;
        if (count <= 5 || count % 120 == 0 || ret != 0) {
            OH_LOG_INFO(LOG_APP,
                "[RDP-PUMP] rendered=%{public}llu submitted=%{public}llu replaced=%{public}llu ret=%{public}d size=%{public}dx%{public}d",
                static_cast<unsigned long long>(count),
                static_cast<unsigned long long>(submitted_.load()),
                static_cast<unsigned long long>(replaced_.load()),
                ret, width, height);
        }
    }
    OH_LOG_INFO(LOG_APP, "[RDP-PUMP] render worker stopped");
}

uint64_t RdpFramePump::submitted() const {
    return submitted_.load();
}

uint64_t RdpFramePump::rendered() const {
    return rendered_.load();
}

uint64_t RdpFramePump::replaced() const {
    return replaced_.load();
}

bool RdpFramePump::isRunning() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return running_;
}
