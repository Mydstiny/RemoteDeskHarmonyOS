#pragma once

#include <cstdint>

/**
 * RDP 多显示器 (Pro, plan 2026-10-09 §4 D0/D1): the monitors this client declares to Windows — 2 to 4 side by side,
 * primary first — and the downgrade to 1920 × 1080 per monitor when the whole desktop would be wider than 8192 or
 * larger than two 4K screens. Mirrors entry/src/main/ets/services/RdpMultiMonitorPolicy.ets.
 */
struct RdpMultimonLayout {
    int count = 1;
    int monitorWidth = 0;
    int monitorHeight = 0;
    int desktopWidth = 0;
    int desktopHeight = 0;
    bool downgraded = false;
};

namespace RdpMultimonPolicy {

constexpr int kMaxCount = 4;
constexpr int kMaxDesktopWidth = 8192;
constexpr int64_t kMaxPixels = static_cast<int64_t>(3840) * 2160 * 2;
constexpr int kFallbackWidth = 1920;
constexpr int kFallbackHeight = 1080;

inline int Even(int value) { return value < 2 ? 2 : (value / 2) * 2; }

inline RdpMultimonLayout Resolve(bool enabled, int requestedCount, int width, int height) {
    RdpMultimonLayout layout;
    const int w = width >= 200 ? Even(width) : kFallbackWidth;
    const int h = height >= 200 ? Even(height) : kFallbackHeight;
    const int count = !enabled || requestedCount < 2 ? 1 : (requestedCount > kMaxCount ? kMaxCount : requestedCount);
    layout.count = count;
    layout.monitorWidth = w;
    layout.monitorHeight = h;
    if (count < 2) {
        layout.desktopWidth = w;
        layout.desktopHeight = h;
        return layout;
    }
    const bool fits = static_cast<int64_t>(count) * w <= kMaxDesktopWidth &&
        static_cast<int64_t>(count) * w * h <= kMaxPixels;
    if (!fits) {
        layout.monitorWidth = kFallbackWidth;
        layout.monitorHeight = kFallbackHeight;
        layout.downgraded = true;
    }
    layout.desktopWidth = count * layout.monitorWidth;
    layout.desktopHeight = layout.monitorHeight;
    return layout;
}

}  // namespace RdpMultimonPolicy
