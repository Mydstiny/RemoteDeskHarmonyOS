#ifndef RDP_DAMAGE_ACCUMULATOR_H
#define RDP_DAMAGE_ACCUMULATOR_H

#include <cstddef>
#include <cstdint>
#include <limits>
#include <mutex>
#include <vector>

struct RdpDamageRect {
    int x = 0;
    int y = 0;
    int width = 0;
    int height = 0;
    bool valid = false;
};

struct RdpDamageUpdateResult {
    bool accepted = false;
    bool fullResync = false;
    bool allocationFailed = false;
    uint64_t copiedBytes = 0;
};

struct RdpDamageSnapshot {
    bool valid = false;
    bool fullFrame = false;
    bool deferred = false;
    int64_t retryAtUs = 0;
    std::vector<uint8_t> pixels;
    int width = 0;
    int height = 0;
    int stride = 0;
    RdpDamageRect damage;
    uint64_t rendererGeneration = 0;
    uint64_t snapshotCopiedBytes = 0;
    bool fromRetainedFrame = false;
    bool retainOnRecycle = false;
    // Internal version of the accumulator state at snapshot selection.  It
    // lets the producer recycle a full-frame buffer only when no newer GDI
    // update has arrived while the renderer was consuming it.
    uint64_t sourceVersion = 0;
};

class RdpDamageAccumulator {
public:
    static constexpr uint64_t kFullFrameThresholdPercent = 70;

    static RdpDamageRect ClipRect(int frameWidth, int frameHeight,
                                  int x, int y, int width, int height);

    RdpDamageUpdateResult update(const uint8_t* data, size_t size,
                                 int width, int height, int sourceStride,
                                 int dirtyX, int dirtyY, int dirtyWidth, int dirtyHeight,
                                 uint64_t rendererGeneration, bool forceFullResync);
    bool requestFullSnapshot(uint64_t rendererGeneration);
    RdpDamageSnapshot takeSnapshot();
    // Return a consumed snapshot's storage to the accumulator.  Full-frame
    // snapshots are recycled only when the backing frame is still current;
    // stale storage is discarded instead of being exposed to a later frame.
    void recycleSnapshot(RdpDamageSnapshot&& snapshot);
    void clear();
    bool hasPending() const;
    void setSnapshotAllocationLimitForTest(size_t limit);

private:
    static RdpDamageRect UnionRect(const RdpDamageRect& left,
                                   const RdpDamageRect& right);
    static bool CoversFullThreshold(const RdpDamageRect& rect,
                                    int frameWidth, int frameHeight);
    static bool LooksLikeBroadRefresh(const RdpDamageRect& rect,
                                      int frameWidth, int frameHeight);
    static bool LooksLikeRefreshContinuation(const RdpDamageRect& rect,
                                             int frameWidth, int frameHeight);

    mutable std::mutex mutex_;
    std::vector<uint8_t> staging_;
    // A bootstrap full-frame buffer lets the first snapshot hand ownership to
    // the render worker without blocking the producer. After that handoff,
    // the worker-retained frame is kept only as a recovery source; normal
    // dirty/full updates never mirror every row into a second buffer.
    std::vector<uint8_t> fullFrameSpare_;
    std::vector<uint8_t> retainedFrame_;
    std::vector<uint8_t> dirtySnapshotScratch_;
    int width_ = 0;
    int height_ = 0;
    int stride_ = 0;
    uint64_t rendererGeneration_ = 0;
    RdpDamageRect pendingDamage_;
    bool pendingFullFrame_ = false;
    bool fullFrameSpareSynchronized_ = false;
    bool bootstrapSpareAvailable_ = true;
    bool stagingNeedsFullResync_ = false;
    // A buffer can remain allocated after its ownership has moved to the
    // renderer.  Keep validity separate from capacity so a retained-only
    // redraw never presents stale spare-buffer bytes as a new desktop frame.
    bool stagingHasCurrentFrame_ = false;
    uint64_t stagingVersion_ = 0;
    uint64_t retainedFrameVersion_ = 0;
    bool preferRetainedRefresh_ = false;
    bool visualCommitActive_ = false;
    bool visualCommitBurstDetected_ = false;
    bool visualCommitContinuation_ = false;
    int64_t visualCommitStartedUs_ = 0;
    int64_t visualCommitLastUpdateUs_ = 0;
    int64_t visualCommitLastCommitUs_ = 0;
    size_t snapshotAllocationLimit_ = std::numeric_limits<size_t>::max();
};

#endif // RDP_DAMAGE_ACCUMULATOR_H
