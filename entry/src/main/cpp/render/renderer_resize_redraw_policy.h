#pragma once

#include <utility>

namespace Render {

inline bool CommitRendererResizeGeometry(
    int& currentWidth, int& currentHeight, int width, int height) noexcept {
    if (width <= 0 || height <= 0 ||
        (currentWidth == width && currentHeight == height)) {
        return false;
    }
    currentWidth = width;
    currentHeight = height;
    return true;
}

/**
 * Runs redraw only after the geometry commit callback has returned. The
 * renderer uses the commit callback to hold its lifecycle lock, so this
 * ordering keeps decoder/session wake callbacks outside that lock.
 */
template <typename CommitCallback, typename RedrawCallback>
inline bool CommitRendererResizeAndRedraw(
    CommitCallback&& commit, RedrawCallback&& redraw) {
    if (!std::forward<CommitCallback>(commit)()) {
        return false;
    }
    std::forward<RedrawCallback>(redraw)();
    return true;
}

} // namespace Render
