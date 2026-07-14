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
    std::vector<uint8_t> pixels;
    int width = 0;
    int height = 0;
    int stride = 0;
    RdpDamageRect damage;
    uint64_t rendererGeneration = 0;
    uint64_t snapshotCopiedBytes = 0;
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
    void clear();
    bool hasPending() const;
    void setSnapshotAllocationLimitForTest(size_t limit);

private:
    static RdpDamageRect UnionRect(const RdpDamageRect& left,
                                   const RdpDamageRect& right);
    static bool CoversFullThreshold(const RdpDamageRect& rect,
                                    int frameWidth, int frameHeight);

    mutable std::mutex mutex_;
    std::vector<uint8_t> staging_;
    int width_ = 0;
    int height_ = 0;
    int stride_ = 0;
    uint64_t rendererGeneration_ = 0;
    RdpDamageRect pendingDamage_;
    bool pendingFullFrame_ = false;
    size_t snapshotAllocationLimit_ = std::numeric_limits<size_t>::max();
};

#endif // RDP_DAMAGE_ACCUMULATOR_H
