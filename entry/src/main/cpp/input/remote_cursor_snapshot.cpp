/**
 * remote_cursor_snapshot.cpp — validated remote cursor snapshot storage
 */

#include "remote_cursor_snapshot.h"

#include <utility>

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
