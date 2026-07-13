/**
 * perf_stats.h — 远程桌面性能计量
 *
 * 轻量帧计数器, 用于监控渲染/解码管线的实时帧率和丢帧。
 * 零分配 (编译期确定容量), 线程安全 (atomic)。
 *
 * 目标指标:
 *   RDP 帧延迟 < 30ms, RustDesk < 50ms
 *   首帧 RDP < 500ms, RustDesk < 800ms
 *   CPU RDP < 15%, RustDesk < 20%
 */

#ifndef PERF_STATS_H
#define PERF_STATS_H

#include <atomic>
#include <chrono>
#include <cstdint>
#include <string>

namespace Perf {

// ---- 帧统计 (单实例, 线程安全) ----
struct FrameStats {
    std::atomic<uint64_t> frameCount{0};
    std::atomic<uint64_t> totalTimeUs{0};
    std::atomic<uint64_t> droppedFrames{0};
    std::atomic<uint64_t> lastFrameTimeUs{0};
    std::atomic<uint64_t> firstFrameTimeUs{0};

    /** 记录一帧 */
    void recordFrame(uint64_t timestampUs) {
        if (firstFrameTimeUs.load() == 0) {
            firstFrameTimeUs.store(timestampUs);
        }
        uint64_t prev = lastFrameTimeUs.exchange(timestampUs);
        if (prev > 0 && timestampUs > prev) {
            totalTimeUs.fetch_add(timestampUs - prev);
        }
        frameCount.fetch_add(1);
    }

    void recordDrop() { droppedFrames.fetch_add(1); }

    /** 平均帧率 (fps × 100, 避免浮点) */
    uint32_t avgFpsX100() const {
        uint64_t total = totalTimeUs.load();
        uint64_t count = frameCount.load();
        if (total == 0 || count < 2) { return 0; }
        return static_cast<uint32_t>((count - 1) * 100000000ULL / total);
    }

    /** 首帧延迟 (微秒) */
    uint64_t firstFrameLatencyUs() const {
        uint64_t first = firstFrameTimeUs.load();
        return first > 0 ? first : 0;
    }

    void reset() {
        frameCount.store(0);
        totalTimeUs.store(0);
        droppedFrames.store(0);
        lastFrameTimeUs.store(0);
        firstFrameTimeUs.store(0);
    }
};

// ---- 全局性能追踪器 (单例) ----
class PerfTracker {
public:
    static PerfTracker& instance() {
        static PerfTracker tracker;
        return tracker;
    }

    FrameStats videoStats;   // 视频帧
    FrameStats decodeStats;  // 解码帧
    FrameStats renderStats;  // 渲染帧

    void reset() {
        videoStats.reset();
        decodeStats.reset();
        renderStats.reset();
    }
};

// 便捷宏 — 在解码/渲染回调中调用
#define RDP_PERF_RECORD_VIDEO(tsUs)  Perf::PerfTracker::instance().videoStats.recordFrame(tsUs)
#define RDP_PERF_RECORD_DECODE(tsUs) Perf::PerfTracker::instance().decodeStats.recordFrame(tsUs)
#define RDP_PERF_RECORD_RENDER(tsUs) Perf::PerfTracker::instance().renderStats.recordFrame(tsUs)
#define RDP_PERF_DROP_VIDEO()        Perf::PerfTracker::instance().videoStats.recordDrop()

} // namespace Perf

#endif // PERF_STATS_H
