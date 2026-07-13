/**
 * video_perf_counters.h - shared video pipeline telemetry counters
 */

#ifndef VIDEO_PERF_COUNTERS_H
#define VIDEO_PERF_COUNTERS_H

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>

namespace Render {

enum class VideoPressureLevel {
    Normal = 0,
    Mild = 1,
    Moderate = 2,
    Severe = 3,
};

struct VideoPerfSnapshot {
    std::string source;
    uint64_t ingressFrames = 0;
    uint64_t decodeOk = 0;
    uint64_t decodeNotReady = 0;
    uint64_t decodeDrops = 0;
    uint64_t decodeMismatch = 0;
    uint64_t renderFrames = 0;
    uint64_t keyframes = 0;
    size_t decodeQueueMax = 0;
    int width = 0;
    int height = 0;
    uint64_t bytesTotal = 0;
    int64_t uploadMaxUs = 0;
    int64_t drawMaxUs = 0;
    int64_t swapMaxUs = 0;
    int64_t renderTotalMaxUs = 0;
};

class VideoPerfCounters {
public:
    void recordIngressFrame(const char* source, int width, int height, size_t bytes, bool keyframe);
    void recordDecodeResult(int ret, size_t queueDepth, uint64_t dropped, uint64_t waitDrops);
    void recordRenderCostUs(int64_t uploadUs, int64_t drawUs, int64_t swapUs, int64_t totalUs);
    VideoPerfSnapshot snapshotAndReset();

private:
    std::mutex mutex_;
    VideoPerfSnapshot current_;
};

VideoPressureLevel classifyVideoPressure(const VideoPerfSnapshot& snapshot);
const char* videoPressureName(VideoPressureLevel level);

} // namespace Render

#endif // VIDEO_PERF_COUNTERS_H
