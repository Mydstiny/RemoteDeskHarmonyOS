#ifndef RDP_VISUAL_COMMIT_POLICY_H
#define RDP_VISUAL_COMMIT_POLICY_H

#include <cstdint>

/**
 * Small deterministic policy for the first-frame/large-refresh visual fence.
 *
 * FreeRDP may deliver one page repaint as several EndPaint callbacks. The
 * protocol thread is allowed to keep copying those updates, while the
 * presentation worker waits for a short quiet period before exposing the
 * accumulated full frame. The maximum window keeps a continuously repainting
 * desktop from being held forever.
 */
struct RdpVisualCommitDecision {
    bool defer = false;
    int64_t retryAtUs = 0;
};

class RdpVisualCommitPolicy {
public:
    static constexpr int64_t kQuietPeriodUs = 40000;
    static constexpr int64_t kMaximumWindowUs = 160000;
    // A large refresh can continue immediately after the max-window commit.
    // Keep a short tail so the next strip reopens a full-frame burst instead
    // of leaking back into the steady-state dirty-rect path.
    static constexpr int64_t kBurstContinuationUs = 120000;

    static bool InBurstContinuation(int64_t nowUs, int64_t lastCommitUs) {
        return nowUs >= lastCommitUs &&
            nowUs - lastCommitUs < kBurstContinuationUs;
    }

    static RdpVisualCommitDecision Evaluate(int64_t nowUs, int64_t startedUs,
                                            int64_t lastUpdateUs) {
        if (nowUs < 0 || startedUs <= 0 || lastUpdateUs <= 0) {
            return {};
        }
        if (nowUs - startedUs >= kMaximumWindowUs ||
            nowUs - lastUpdateUs >= kQuietPeriodUs) {
            return {};
        }
        return {true, lastUpdateUs + kQuietPeriodUs};
    }
};

#endif // RDP_VISUAL_COMMIT_POLICY_H
