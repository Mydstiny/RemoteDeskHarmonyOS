/**
 * remote_cursor_snapshot.cpp — validated remote cursor snapshot storage
 */

#include "remote_cursor_snapshot.h"

#include <array>
#include <utility>

namespace {

constexpr int kDefaultCursorSize = 16;
constexpr uint64_t kDefaultCursorShapeId = 0x72656D6F74656466ULL;

std::vector<uint8_t> defaultCursorRgba() {
    // Small black-outline/white-fill arrow. The hotspot is its top-left tip.
    static constexpr std::array<const char*, kDefaultCursorSize> kRows = {
        "b...............",
        "bb..............",
        "bwb.............",
        "bwwb............",
        "bwwwb...........",
        "bwwwwb..........",
        "bwwwwwb.........",
        "bwwwwwwb........",
        "bwwwwwwwb.......",
        "bwwwwwwwwb......",
        "bwwwwwwwwwb.....",
        "bwwwwwwwwwwb....",
        "bwwwwwwwwwwwb...",
        "bwwwwwwwwwwwwb..",
        "bwwwwwwwwwwwwwb.",
        "bbbbbbbbbbbbbbbb"
    };
    std::vector<uint8_t> rgba(static_cast<size_t>(kDefaultCursorSize) *
                              static_cast<size_t>(kDefaultCursorSize) * 4U, 0);
    for (int y = 0; y < kDefaultCursorSize; ++y) {
        for (int x = 0; x < kDefaultCursorSize; ++x) {
            const char pixel = kRows[static_cast<size_t>(y)][x];
            if (pixel == '.') {
                continue;
            }
            const size_t offset = (static_cast<size_t>(y) * kDefaultCursorSize +
                                   static_cast<size_t>(x)) * 4U;
            if (pixel == 'b') {
                rgba[offset] = 0;
                rgba[offset + 1] = 0;
                rgba[offset + 2] = 0;
            } else {
                rgba[offset] = 255;
                rgba[offset + 1] = 255;
                rgba[offset + 2] = 255;
            }
            rgba[offset + 3] = 255;
        }
    }
    return rgba;
}

} // namespace

void RemoteCursorStore::reset(uint64_t sessionId, const std::string& protocol) {
    std::lock_guard<std::mutex> lock(mutex_);
    state_ = RemoteCursorSnapshot{};
    state_.sessionId = sessionId;
    state_.protocol = protocol;
}

bool RemoteCursorStore::setShape(uint64_t shapeId, int width, int height, int hotX, int hotY,
                                 const std::vector<uint8_t>& rgba) {
    if (width <= 0 || height <= 0 || width > kRemoteCursorMaxDimension ||
        height > kRemoteCursorMaxDimension || hotX < 0 || hotY < 0 || hotX >= width ||
        hotY >= height) {
        return false;
    }

    const size_t pixelBytes = static_cast<size_t>(width) * static_cast<size_t>(height) * 4U;
    if (pixelBytes > kRemoteCursorMaxBytes || rgba.size() != pixelBytes) {
        return false;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    if (state_.shapeId == shapeId && state_.width == width && state_.height == height &&
        state_.hotX == hotX && state_.hotY == hotY && state_.rgba == rgba) {
        return true;
    }

    state_.shapeId = shapeId;
    state_.width = width;
    state_.height = height;
    state_.hotX = hotX;
    state_.hotY = hotY;
    state_.rgba = rgba;
    state_.shapeRevision += 1;
    return true;
}

bool RemoteCursorStore::setDefaultShape() {
    return setShape(kDefaultCursorShapeId, kDefaultCursorSize, kDefaultCursorSize, 0, 0,
                    defaultCursorRgba());
}

void RemoteCursorStore::setPosition(int x, int y) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (state_.x == x && state_.y == y) {
        return;
    }
    state_.x = x;
    state_.y = y;
    state_.positionRevision += 1;
}

void RemoteCursorStore::setVisible(bool visible) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (state_.visible == visible) {
        return;
    }
    state_.visible = visible;
    state_.positionRevision += 1;
}

RemoteCursorSnapshot RemoteCursorStore::snapshot(bool includePixels) const {
    std::lock_guard<std::mutex> lock(mutex_);
    RemoteCursorSnapshot result = state_;
    if (!includePixels) {
        result.rgba.clear();
    }
    return result;
}
