/**
 * rdp_render_policy.h - small decisions for RDP GDI render path
 */

#ifndef RDP_RENDER_POLICY_H
#define RDP_RENDER_POLICY_H

namespace RdpRenderPolicy {

struct DirtyRect {
    int x = 0;
    int y = 0;
    int width = 0;
    int height = 0;
    bool valid = false;
};

inline bool ShouldRenderDirect(int renderedPaintCount, bool pumpQueueSucceeded) {
    return renderedPaintCount < 3 || !pumpQueueSucceeded;
}

inline DirtyRect NormalizeDirtyRect(int frameWidth, int frameHeight,
                                    int x, int y, int width, int height) {
    DirtyRect rect;
    if (frameWidth <= 0 || frameHeight <= 0 || x < 0 || y < 0 ||
        width <= 0 || height <= 0) {
        return rect;
    }
    if (x >= frameWidth || y >= frameHeight ||
        width > frameWidth - x || height > frameHeight - y) {
        return rect;
    }
    rect.x = x;
    rect.y = y;
    rect.width = width;
    rect.height = height;
    rect.valid = true;
    return rect;
}

inline bool ShouldUseDirtyRect(int renderedPaintCount, const DirtyRect& rect,
                               long long fullFrameBytes, bool requiresFullFrameResync = false,
                               bool dirtyUploadsEnabled = true) {
    if (!dirtyUploadsEnabled || requiresFullFrameResync || renderedPaintCount < 3 ||
        !rect.valid || fullFrameBytes <= 0) {
        return false;
    }
    const long long dirtyBytes =
        static_cast<long long>(rect.width) * static_cast<long long>(rect.height) * 4LL;
    return dirtyBytes > 0 && dirtyBytes * 100LL < fullFrameBytes * 70LL;
}

inline bool ShouldEscalatePumpSubmitToFullFrame(bool hasPendingFrame,
                                                bool pendingDirtyValid,
                                                bool incomingDirtyValid) {
    return hasPendingFrame && (pendingDirtyValid || incomingDirtyValid);
}

inline bool ShouldQueueTrailingFrameForSkippedPaint(bool shouldRender,
                                                    int renderedPaintCount) {
    return !shouldRender && renderedPaintCount >= 3;
}

inline long long TrailingFrameDelayUs(long long minRenderIntervalUs) {
    constexpr long long kMinimumTrailingDelayUs = 16667;
    return minRenderIntervalUs > kMinimumTrailingDelayUs ?
        minRenderIntervalUs : kMinimumTrailingDelayUs;
}

} // namespace RdpRenderPolicy

#endif // RDP_RENDER_POLICY_H
