#ifndef RUSTDESK_PHONE_GEOMETRY_GATE_H
#define RUSTDESK_PHONE_GEOMETRY_GATE_H
#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <mutex>

// Opt-in input barrier only; it never changes renderer transforms or frame routing.
// Display notification, encoded geometry, successful texture presentation and
// ArkTS coordinate adoption must agree before phone input resumes.
class RustDeskPhoneGeometryGate {
public:
    void reset(bool enabled) {
        std::lock_guard<std::mutex> lock(mutex_);
        enabled_ = enabled;
        epoch_ = 0; display_ = -1; width_ = height_ = 0;
        frameDisplay_ = -1; frameWidth_ = frameHeight_ = 0;
        presented_ = committed_ = false;
    }
    bool observeDisplay(int display, uint32_t epoch, int width, int height) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!enabled_ || display < 0 || epoch == 0 || width <= 0 || height <= 0) return false;
        if (display_ == display && epoch_ == epoch && width_ == width && height_ == height) return false;
        display_ = display; epoch_ = epoch; width_ = width; height_ = height;
        presented_ = committed_ = false;
        return true;
    }
    bool observeFrame(int display, int width, int height) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!enabled_ || width <= 0 || height <= 0 || display < 0) return false;
        if (frameDisplay_ == display && frameWidth_ == width && frameHeight_ == height) return false;
        frameDisplay_ = display; frameWidth_ = width; frameHeight_ = height;
        presented_ = committed_ = false;
        return true;
    }
    uint32_t epochForFrame(int display, int width, int height) const {
        std::lock_guard<std::mutex> lock(mutex_);
        return enabled_ && display == display_ && width == width_ && height == height_ &&
            frameDisplay_ == display && frameWidth_ == width && frameHeight_ == height ? epoch_ : 0;
    }
    void observePresented(uint32_t frameEpoch, int display, int encodedWidth, int encodedHeight,
                          int textureWidth, int textureHeight) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!enabled_ || frameEpoch == 0 || frameEpoch != epoch_ ||
            display != display_ || encodedWidth != width_ || encodedHeight != height_ ||
            textureWidth <= 0 || textureHeight <= 0 ||
            frameDisplay_ != display_ || frameWidth_ != width_ || frameHeight_ != height_) return;
        // Software decoding can downsample by an integer ratio. Allow one
        // output-pixel rounding error within the SAME actual frame identity.
        const int64_t cross = int64_t(textureWidth) * height_ - int64_t(textureHeight) * width_;
        if (std::abs(cross) <= std::max(width_, height_)) presented_ = true;
    }
    bool commit(uint32_t epoch) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!enabled_ || epoch == 0 || epoch != epoch_ || !presented_) return false;
        committed_ = true;
        return true;
    }
    bool allowed() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return !enabled_ || committed_;
    }
private:
    mutable std::mutex mutex_;
    bool enabled_ = false, presented_ = false, committed_ = false;
    uint32_t epoch_ = 0;
    int display_ = -1, width_ = 0, height_ = 0;
    int frameDisplay_ = -1, frameWidth_ = 0, frameHeight_ = 0;
};
#endif
