#ifndef RDP_GL_UPLOAD_GATE_H
#define RDP_GL_UPLOAD_GATE_H

#include "rdp_presentation_metrics.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <mutex>

enum class RdpGlUploadDecision : int32_t {
    InsufficientSamples = 0,
    KeepDirectUpload = 1,
    PboExperimentEligible = 2,
    PboRetained = 3,
};

struct RdpGlUploadGateSnapshot {
    RdpGlUploadDecision decision = RdpGlUploadDecision::InsufficientSamples;
    size_t pendingSamples = 0;
    uint64_t evaluatedSamples = 0;
    int64_t uploadSwapP95Us = 0;
    int64_t workerP95Us = 0;
    int uploadSwapSharePermille = 0;
    bool pboExperimentActive = false;
    bool pboRetained = false;
};

class RdpGlUploadGate {
public:
    static constexpr size_t kDecisionSamples = 120;
    static constexpr int kExperimentThresholdPermille = 600;

    void reset();
    void recordPresent(const RdpPresentMetrics& present);
    /** Claim the one-shot PBO experiment after a direct-upload baseline. */
    bool beginPboExperiment();
    /** Finish the one-shot experiment and publish its retained/fallback state. */
    void finishPboExperiment(bool retained, int64_t experimentWorkerP95Us);
    RdpGlUploadGateSnapshot snapshot() const;
    bool canRunPboExperiment(bool gles3Capable, bool pixelUnpackBufferCapable) const;

    static bool ShouldRetainPbo(int64_t baselineWorkerP95Us,
                                int64_t experimentWorkerP95Us,
                                bool glErrorObserved,
                                bool memoryControlled,
                                bool visualMatrixPassed);
    static const char* DecisionName(RdpGlUploadDecision decision);

private:
    mutable std::mutex mutex_;
    std::array<int64_t, kDecisionSamples> uploadSwapSamples_ {};
    std::array<int64_t, kDecisionSamples> workerSamples_ {};
    size_t sampleCount_ = 0;
    RdpGlUploadGateSnapshot snapshot_;
};

#endif // RDP_GL_UPLOAD_GATE_H
