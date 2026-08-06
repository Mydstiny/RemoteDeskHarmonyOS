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

bool RdpDamageAccumulator::LooksLikeBroadRefresh(const RdpDamageRect& rect,
                                                 int frameWidth, int frameHeight) {
    if (!rect.valid || frameWidth <= 0 || frameHeight <= 0) {
        return false;
    }
    // Browser/document refreshes may arrive as medium-width horizontal bands,
    // not only as full-width strips. The live device trace showed widths from
    // roughly 20% to 70% of the desktop. Keep small cursor updates dirty-only,
    // while a large band/area opens the visual commit fence.
    const bool horizontalBand = static_cast<int64_t>(rect.width) * 100 >=
        static_cast<int64_t>(frameWidth) * 20 &&
        static_cast<int64_t>(rect.height) * 100 <=
            static_cast<int64_t>(frameHeight) * 30 &&
        (rect.height >= 2 || static_cast<int64_t>(rect.width) * 100 >=
            static_cast<int64_t>(frameWidth) * 75);
    const bool verticalBand = static_cast<int64_t>(rect.height) * 100 >=
        static_cast<int64_t>(frameHeight) * 20 &&
        static_cast<int64_t>(rect.width) * 100 <=
            static_cast<int64_t>(frameWidth) * 30 &&
        (rect.width >= 2 || static_cast<int64_t>(rect.height) * 100 >=
            static_cast<int64_t>(frameHeight) * 75);
    const uint64_t damagePixels = static_cast<uint64_t>(rect.width) *
        static_cast<uint64_t>(rect.height);
    const uint64_t framePixels = static_cast<uint64_t>(frameWidth) *
        static_cast<uint64_t>(frameHeight);
    const bool largeArea = damagePixels * 100U >= framePixels * 25U;
    return horizontalBand || verticalBand || largeArea;
}

bool RdpDamageAccumulator::LooksLikeRefreshContinuation(const RdpDamageRect& rect,
                                                        int frameWidth, int frameHeight) {
    if (!rect.valid || frameWidth <= 0 || frameHeight <= 0) {
        return false;
    }

    // Once a visual refresh fence is already active, the remaining RDP GDI
    // updates can be narrower than the first band. Treat a meaningful strip
    // as part of that same episode, but leave tiny cursor/toolbar updates on
    // the low-latency dirty path. The absolute minimums keep the rule useful
    // on small test frames without classifying a 1x1 cursor as a repaint.
    const int64_t minimumHorizontalLength = std::max<int64_t>(8, frameWidth * 8LL / 100LL);
    const int64_t minimumVerticalLength = std::max<int64_t>(8, frameHeight * 8LL / 100LL);
    const int64_t minimumHorizontalThickness = 2;
    const int64_t minimumVerticalThickness = 2;
    const bool horizontalStrip = static_cast<int64_t>(rect.width) >= minimumHorizontalLength &&
        static_cast<int64_t>(rect.height) >= minimumHorizontalThickness &&
        static_cast<int64_t>(rect.height) * 100 <= static_cast<int64_t>(frameHeight) * 12;
    const bool verticalStrip = static_cast<int64_t>(rect.height) >= minimumVerticalLength &&
        static_cast<int64_t>(rect.width) >= minimumVerticalThickness &&
        static_cast<int64_t>(rect.width) * 100 <= static_cast<int64_t>(frameWidth) * 12;
    return horizontalStrip || verticalStrip;
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
    const size_t frameBytes = static_cast<size_t>(width) *
        static_cast<size_t>(height) * 4U;
    const bool dimensionsChanged = width_ != width || height_ != height ||
        stride_ != width * 4;
    const bool generationChanged = rendererGeneration_ != rendererGeneration;

    // A retained-only redraw already contains a complete, current desktop
    // frame. Promote that buffer back to producer staging before applying the
    // next GDI dirty rectangle. This keeps recovery from turning the first
    // post-refresh cursor/window update into another 1920x1080 copy/upload.
    if (!forceFullResync && !dimensionsChanged && !generationChanged && clipped.valid &&
        stagingNeedsFullResync_ && !stagingHasCurrentFrame_ &&
        retainedFrame_.size() == frameBytes && retainedFrameVersion_ != 0) {
        staging_.swap(retainedFrame_);
        stagingHasCurrentFrame_ = true;
        stagingNeedsFullResync_ = false;
        stagingVersion_ = retainedFrameVersion_;
        retainedFrameVersion_ = 0;
        fullFrameSpareSynchronized_ = !fullFrameSpare_.empty();
    }

    const bool geometryChanged = dimensionsChanged || staging_.size() != frameBytes;
    const bool fullResync = forceFullResync || geometryChanged || generationChanged ||
        !clipped.valid || stagingNeedsFullResync_ || !stagingHasCurrentFrame_;

    const int tightStride = width * 4;
    try {
        if (fullResync) {
            // Reuse the producer buffer whenever the geometry is stable.  The
            // old implementation allocated a replacement while EndPaint held
            // the callback lease, which amplified allocator and mutex stalls.
            staging_.resize(frameBytes);
            for (int row = 0; row < height; ++row) {
                std::memcpy(staging_.data() +
                                static_cast<size_t>(row) * static_cast<size_t>(tightStride),
                            data + static_cast<size_t>(row) * static_cast<size_t>(sourceStride),
                            static_cast<size_t>(tightStride));
            }
            // Allocate the producer spare and the retained/recovery slot once,
            // but do not mirror the source frame into either one.  The old
            // path copied the entire 1920x1080 surface twice while EndPaint
            // held the FreeRDP callback lease.  These buffers only need valid
            // capacity; ownership handoff and recycle below fill them without
            // another full-frame memcpy.
            if (fullFrameSpare_.size() != frameBytes) {
                fullFrameSpare_.resize(frameBytes);
            }
            if (retainedFrame_.size() != frameBytes) {
                retainedFrame_.resize(frameBytes);
                retainedFrameVersion_ = 0;
            }
            fullFrameSpareSynchronized_ = !fullFrameSpare_.empty();
            bootstrapSpareAvailable_ = false;
            width_ = width;
            height_ = height;
            stride_ = tightStride;
            rendererGeneration_ = rendererGeneration;
            ++stagingVersion_;
            stagingNeedsFullResync_ = false;
            stagingHasCurrentFrame_ = true;
            pendingDamage_ = {0, 0, width, height, true};
            pendingFullFrame_ = true;
            // A full resync establishes the visible canvas immediately. Do
            // not hold it behind a quiet-period fence: the frame pump already
            // owns the latest frame and can replace stale work safely.
            visualCommitActive_ = false;
            visualCommitBurstDetected_ = false;
            visualCommitContinuation_ = false;
            visualCommitStartedUs_ = 0;
            visualCommitLastUpdateUs_ = 0;
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
            ++stagingVersion_;
            stagingHasCurrentFrame_ = true;
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
    if (rendererGeneration == 0 ||
        ((!stagingHasCurrentFrame_ || staging_.empty()) && retainedFrame_.empty()) ||
        width_ <= 0 || height_ <= 0) {
        return false;
    }
    rendererGeneration_ = rendererGeneration;
    pendingDamage_ = {0, 0, width_, height_, true};
    pendingFullFrame_ = true;
    preferRetainedRefresh_ = true;
    visualCommitActive_ = false;
    visualCommitBurstDetected_ = false;
    visualCommitContinuation_ = false;
    visualCommitStartedUs_ = 0;
    visualCommitLastUpdateUs_ = 0;
    visualCommitLastCommitUs_ = 0;
    return true;
}

RdpDamageSnapshot RdpDamageAccumulator::takeSnapshot() {
    RdpDamageSnapshot snapshot;
    std::lock_guard<std::mutex> lock(mutex_);
    if (!pendingDamage_.valid ||
        ((!stagingHasCurrentFrame_ || staging_.empty()) &&
         (!pendingFullFrame_ || retainedFrame_.empty()))) {
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

    uint64_t sourceVersion = stagingVersion_;
    try {
        if (fullFrame) {
            // Move the immutable full frame out of the producer path.  A
            // reusable spare keeps a writable buffer available for the next
            // GDI callback; the retained slot gives the renderer a third
            // ownership state so a fast producer never falls back to a full
            // mirror copy.
            if (stagingHasCurrentFrame_ && !staging_.empty()) {
                if (fullFrameSpare_.empty() && retainedFrame_.empty()) {
                    snapshot.deferred = true;
                    return snapshot;
                }
                snapshot.pixels.swap(staging_);
                sourceVersion = stagingVersion_;
                if (!fullFrameSpare_.empty()) {
                    staging_.swap(fullFrameSpare_);
                } else {
                    staging_.swap(retainedFrame_);
                }
                stagingHasCurrentFrame_ = false;
            } else if (!retainedFrame_.empty()) {
                snapshot.pixels.swap(retainedFrame_);
                sourceVersion = retainedFrameVersion_;
                retainedFrameVersion_ = 0;
                stagingHasCurrentFrame_ = false;
                snapshot.fromRetainedFrame = true;
            }
            fullFrameSpareSynchronized_ = !fullFrameSpare_.empty();
            stagingNeedsFullResync_ = false;
        } else {
            // Dirty rectangles remain a bounded copy, but use a reusable
            // scratch buffer instead of allocating a vector for every cursor
            // update.
            dirtySnapshotScratch_.resize(snapshotBytes);
            snapshot.pixels.swap(dirtySnapshotScratch_);
            for (int row = 0; row < damage.height; ++row) {
                const size_t sourceOffset =
                    static_cast<size_t>(damage.y + row) * static_cast<size_t>(stride_) +
                    static_cast<size_t>(damage.x) * 4U;
                std::memcpy(snapshot.pixels.data() +
                                static_cast<size_t>(row) * static_cast<size_t>(snapshotStride),
                            staging_.data() + sourceOffset,
                            static_cast<size_t>(snapshotStride));
            }
        }
    } catch (...) {
        return RdpDamageSnapshot();
    }

    snapshot.valid = true;
    snapshot.fullFrame = fullFrame;
    snapshot.width = width_;
    snapshot.height = height_;
    snapshot.stride = snapshotStride;
    snapshot.damage = damage;
    snapshot.rendererGeneration = rendererGeneration_;
    // Full snapshots transfer ownership of an already staged buffer; only a
    // dirty snapshot performs a CPU copy at this point.
    snapshot.snapshotCopiedBytes = fullFrame ? 0 : snapshotBytes;
    snapshot.sourceVersion = sourceVersion;
    snapshot.retainOnRecycle = fullFrame && preferRetainedRefresh_;
    pendingDamage_ = RdpDamageRect();
    pendingFullFrame_ = false;
    preferRetainedRefresh_ = false;
    visualCommitActive_ = false;
    visualCommitBurstDetected_ = false;
    visualCommitContinuation_ = false;
    visualCommitStartedUs_ = 0;
    visualCommitLastUpdateUs_ = 0;
    return snapshot;
}

void RdpDamageAccumulator::recycleSnapshot(RdpDamageSnapshot&& snapshot) {
    if (!snapshot.valid || snapshot.pixels.empty()) {
        return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (!snapshot.fullFrame) {
        dirtySnapshotScratch_.swap(snapshot.pixels);
        return;
    }

    const size_t frameBytes = static_cast<size_t>(width_) *
        static_cast<size_t>(height_) * 4U;
    if (snapshot.rendererGeneration != rendererGeneration_ ||
        snapshot.pixels.size() != frameBytes) {
        return;
    }

    // Keep three ownership states in rotation without copying: the producer
    // staging buffer, the renderer-owned snapshot and the spare/recovery
    // buffers.  If no producer update arrived while the renderer consumed
    // the frame, put that exact buffer back into staging so the next dirty
    // callback can update only its changed rows.  If a newer update did
    // arrive, leave its staging buffer untouched and use the consumed frame
    // as retained/spare storage instead.
    const bool producerAdvanced = stagingHasCurrentFrame_ &&
        stagingVersion_ != snapshot.sourceVersion;
    if (!producerAdvanced && snapshot.retainOnRecycle) {
        retainedFrame_.swap(snapshot.pixels);
        retainedFrameVersion_ = snapshot.sourceVersion;
        if (!snapshot.pixels.empty()) {
            fullFrameSpare_.swap(snapshot.pixels);
        }
        stagingHasCurrentFrame_ = false;
        stagingNeedsFullResync_ = true;
    } else if (!producerAdvanced && !snapshot.fromRetainedFrame && !staging_.empty()) {
        staging_.swap(snapshot.pixels);
        stagingHasCurrentFrame_ = true;
        if (!snapshot.pixels.empty()) {
            fullFrameSpare_.swap(snapshot.pixels);
        }
    } else {
        retainedFrame_.swap(snapshot.pixels);
        retainedFrameVersion_ = snapshot.sourceVersion;
        if (!snapshot.pixels.empty()) {
            fullFrameSpare_.swap(snapshot.pixels);
        }
        if (!producerAdvanced && snapshot.fromRetainedFrame) {
            stagingHasCurrentFrame_ = false;
            stagingNeedsFullResync_ = true;
        }
    }
    fullFrameSpareSynchronized_ = !fullFrameSpare_.empty();
}

void RdpDamageAccumulator::clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    staging_.clear();
    fullFrameSpare_.clear();
    retainedFrame_.clear();
    dirtySnapshotScratch_.clear();
    width_ = 0;
    height_ = 0;
    stride_ = 0;
    rendererGeneration_ = 0;
    pendingDamage_ = RdpDamageRect();
    pendingFullFrame_ = false;
    fullFrameSpareSynchronized_ = false;
    bootstrapSpareAvailable_ = true;
    stagingNeedsFullResync_ = false;
    stagingHasCurrentFrame_ = false;
    stagingVersion_ = 0;
    retainedFrameVersion_ = 0;
    preferRetainedRefresh_ = false;
    visualCommitActive_ = false;
    visualCommitBurstDetected_ = false;
    visualCommitContinuation_ = false;
    visualCommitStartedUs_ = 0;
    visualCommitLastUpdateUs_ = 0;
    visualCommitLastCommitUs_ = 0;
}

bool RdpDamageAccumulator::hasPending() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return pendingDamage_.valid;
}

void RdpDamageAccumulator::setSnapshotAllocationLimitForTest(size_t limit) {
    std::lock_guard<std::mutex> lock(mutex_);
    snapshotAllocationLimit_ = limit;
}
