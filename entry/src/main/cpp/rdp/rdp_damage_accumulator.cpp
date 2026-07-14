#include "rdp_damage_accumulator.h"

#include <algorithm>
#include <cstring>
#include <new>

RdpDamageRect RdpDamageAccumulator::ClipRect(int frameWidth, int frameHeight,
                                             int x, int y, int width, int height) {
    RdpDamageRect result;
    if (frameWidth <= 0 || frameHeight <= 0 || width <= 0 || height <= 0) {
        return result;
    }

    const int64_t left = std::max<int64_t>(0, x);
    const int64_t top = std::max<int64_t>(0, y);
    const int64_t right = std::min<int64_t>(frameWidth,
        static_cast<int64_t>(x) + static_cast<int64_t>(width));
    const int64_t bottom = std::min<int64_t>(frameHeight,
        static_cast<int64_t>(y) + static_cast<int64_t>(height));
    if (right <= left || bottom <= top) {
        return result;
    }

    result.x = static_cast<int>(left);
    result.y = static_cast<int>(top);
    result.width = static_cast<int>(right - left);
    result.height = static_cast<int>(bottom - top);
    result.valid = true;
    return result;
}

RdpDamageRect RdpDamageAccumulator::UnionRect(const RdpDamageRect& left,
                                              const RdpDamageRect& right) {
    if (!left.valid) {
        return right;
    }
    if (!right.valid) {
        return left;
    }
    RdpDamageRect result;
    result.x = std::min(left.x, right.x);
    result.y = std::min(left.y, right.y);
    const int maxX = std::max(left.x + left.width, right.x + right.width);
    const int maxY = std::max(left.y + left.height, right.y + right.height);
    result.width = maxX - result.x;
    result.height = maxY - result.y;
    result.valid = result.width > 0 && result.height > 0;
    return result;
}

bool RdpDamageAccumulator::CoversFullThreshold(const RdpDamageRect& rect,
                                               int frameWidth, int frameHeight) {
    if (!rect.valid || frameWidth <= 0 || frameHeight <= 0) {
        return false;
    }
    const uint64_t damagePixels = static_cast<uint64_t>(rect.width) *
        static_cast<uint64_t>(rect.height);
    const uint64_t framePixels = static_cast<uint64_t>(frameWidth) *
        static_cast<uint64_t>(frameHeight);
    return damagePixels * 100U >= framePixels * kFullFrameThresholdPercent;
}

RdpDamageUpdateResult RdpDamageAccumulator::update(
    const uint8_t* data, size_t size, int width, int height, int sourceStride,
    int dirtyX, int dirtyY, int dirtyWidth, int dirtyHeight,
    uint64_t rendererGeneration, bool forceFullResync) {
    RdpDamageUpdateResult result;
    if (!data || width <= 0 || height <= 0 || sourceStride < width * 4 ||
        rendererGeneration == 0) {
        return result;
    }
    const size_t requiredSourceBytes =
        static_cast<size_t>(height - 1) * static_cast<size_t>(sourceStride) +
        static_cast<size_t>(width) * 4U;
    if (requiredSourceBytes > size) {
        return result;
    }

    const RdpDamageRect clipped = ClipRect(
        width, height, dirtyX, dirtyY, dirtyWidth, dirtyHeight);
    std::lock_guard<std::mutex> lock(mutex_);
    const bool geometryChanged = width_ != width || height_ != height ||
        stride_ != width * 4 || staging_.size() !=
            static_cast<size_t>(width) * static_cast<size_t>(height) * 4U;
    const bool generationChanged = rendererGeneration_ != rendererGeneration;
    const bool fullResync = forceFullResync || geometryChanged || generationChanged ||
        !clipped.valid;

    const int tightStride = width * 4;
    try {
        if (fullResync) {
            std::vector<uint8_t> replacement(
                static_cast<size_t>(tightStride) * static_cast<size_t>(height));
            for (int row = 0; row < height; ++row) {
                std::memcpy(replacement.data() +
                                static_cast<size_t>(row) * static_cast<size_t>(tightStride),
                            data + static_cast<size_t>(row) * static_cast<size_t>(sourceStride),
                            static_cast<size_t>(tightStride));
            }
            staging_.swap(replacement);
            width_ = width;
            height_ = height;
            stride_ = tightStride;
            rendererGeneration_ = rendererGeneration;
            pendingDamage_ = {0, 0, width, height, true};
            pendingFullFrame_ = true;
            result.copiedBytes = static_cast<uint64_t>(tightStride) *
                static_cast<uint64_t>(height);
        } else {
            const size_t rowBytes = static_cast<size_t>(clipped.width) * 4U;
            for (int row = 0; row < clipped.height; ++row) {
                const size_t sourceOffset =
                    static_cast<size_t>(clipped.y + row) * static_cast<size_t>(sourceStride) +
                    static_cast<size_t>(clipped.x) * 4U;
                const size_t destinationOffset =
                    static_cast<size_t>(clipped.y + row) * static_cast<size_t>(stride_) +
                    static_cast<size_t>(clipped.x) * 4U;
                std::memcpy(staging_.data() + destinationOffset, data + sourceOffset, rowBytes);
            }
            pendingDamage_ = UnionRect(pendingDamage_, clipped);
            result.copiedBytes = static_cast<uint64_t>(rowBytes) *
                static_cast<uint64_t>(clipped.height);
            if (CoversFullThreshold(pendingDamage_, width_, height_)) {
                pendingDamage_ = {0, 0, width_, height_, true};
                pendingFullFrame_ = true;
            }
        }
    } catch (const std::bad_alloc&) {
        result.allocationFailed = true;
        return result;
    } catch (...) {
        result.allocationFailed = true;
        return result;
    }

    result.accepted = true;
    result.fullResync = fullResync || pendingFullFrame_;
    return result;
}

bool RdpDamageAccumulator::requestFullSnapshot(uint64_t rendererGeneration) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (rendererGeneration == 0 || staging_.empty() || width_ <= 0 || height_ <= 0) {
        return false;
    }
    rendererGeneration_ = rendererGeneration;
    pendingDamage_ = {0, 0, width_, height_, true};
    pendingFullFrame_ = true;
    return true;
}

RdpDamageSnapshot RdpDamageAccumulator::takeSnapshot() {
    RdpDamageSnapshot snapshot;
    std::lock_guard<std::mutex> lock(mutex_);
    if (!pendingDamage_.valid || staging_.empty()) {
        return snapshot;
    }

    const bool fullFrame = pendingFullFrame_;
    const RdpDamageRect damage = fullFrame ?
        RdpDamageRect{0, 0, width_, height_, true} : pendingDamage_;
    const int snapshotStride = damage.width * 4;
    const size_t snapshotBytes = static_cast<size_t>(snapshotStride) *
        static_cast<size_t>(damage.height);
    if (snapshotBytes > snapshotAllocationLimit_) {
        return snapshot;
    }

    try {
        snapshot.pixels.resize(snapshotBytes);
    } catch (...) {
        return RdpDamageSnapshot();
    }
    for (int row = 0; row < damage.height; ++row) {
        const size_t sourceOffset =
            static_cast<size_t>(damage.y + row) * static_cast<size_t>(stride_) +
            static_cast<size_t>(damage.x) * 4U;
        std::memcpy(snapshot.pixels.data() +
                        static_cast<size_t>(row) * static_cast<size_t>(snapshotStride),
                    staging_.data() + sourceOffset,
                    static_cast<size_t>(snapshotStride));
    }

    snapshot.valid = true;
    snapshot.fullFrame = fullFrame;
    snapshot.width = width_;
    snapshot.height = height_;
    snapshot.stride = snapshotStride;
    snapshot.damage = damage;
    snapshot.rendererGeneration = rendererGeneration_;
    snapshot.snapshotCopiedBytes = snapshotBytes;
    pendingDamage_ = RdpDamageRect();
    pendingFullFrame_ = false;
    return snapshot;
}

void RdpDamageAccumulator::clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    staging_.clear();
    width_ = 0;
    height_ = 0;
    stride_ = 0;
    rendererGeneration_ = 0;
    pendingDamage_ = RdpDamageRect();
    pendingFullFrame_ = false;
}

bool RdpDamageAccumulator::hasPending() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return pendingDamage_.valid;
}

void RdpDamageAccumulator::setSnapshotAllocationLimitForTest(size_t limit) {
    std::lock_guard<std::mutex> lock(mutex_);
    snapshotAllocationLimit_ = limit;
}
