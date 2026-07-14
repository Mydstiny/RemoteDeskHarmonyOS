#include "rdp_gl_upload_gate.h"

#include <algorithm>

namespace {

constexpr size_t P95Index(size_t sampleCount) {
    return (sampleCount * 95 + 99) / 100 - 1;
}

} // namespace

void RdpGlUploadGate::reset() {
    std::lock_guard<std::mutex> lock(mutex_);
    uploadSwapSamples_.fill(0);
    workerSamples_.fill(0);
    sampleCount_ = 0;
    snapshot_ = RdpGlUploadGateSnapshot();
}

void RdpGlUploadGate::recordPresent(const RdpPresentMetrics& present) {
    if (!present.presented()) {
        return;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    const int64_t uploadUs = std::max<int64_t>(0, present.uploadUs);
    const int64_t drawUs = std::max<int64_t>(0, present.drawUs);
    const int64_t swapUs = std::max<int64_t>(0, present.swapUs);
    uploadSwapSamples_[sampleCount_] = uploadUs + swapUs;
    workerSamples_[sampleCount_] = uploadUs + drawUs + swapUs;
    ++sampleCount_;
    snapshot_.pendingSamples = sampleCount_;
    if (sampleCount_ < kDecisionSamples) {
        return;
    }

    std::array<int64_t, kDecisionSamples> sortedUploadSwap = uploadSwapSamples_;
    std::array<int64_t, kDecisionSamples> sortedWorker = workerSamples_;
    std::sort(sortedUploadSwap.begin(), sortedUploadSwap.end());
    std::sort(sortedWorker.begin(), sortedWorker.end());
    snapshot_.uploadSwapP95Us = sortedUploadSwap[P95Index(kDecisionSamples)];
    snapshot_.workerP95Us = sortedWorker[P95Index(kDecisionSamples)];
    snapshot_.uploadSwapSharePermille = snapshot_.workerP95Us > 0 ?
        static_cast<int>(snapshot_.uploadSwapP95Us * 1000 / snapshot_.workerP95Us) : 0;
    snapshot_.decision =
        snapshot_.uploadSwapSharePermille >= kExperimentThresholdPermille ?
        RdpGlUploadDecision::PboExperimentEligible :
        RdpGlUploadDecision::KeepDirectUpload;
    snapshot_.evaluatedSamples += kDecisionSamples;
    sampleCount_ = 0;
    snapshot_.pendingSamples = 0;
}

RdpGlUploadGateSnapshot RdpGlUploadGate::snapshot() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return snapshot_;
}

bool RdpGlUploadGate::canRunPboExperiment(bool gles3Capable,
                                          bool pixelUnpackBufferCapable) const {
    std::lock_guard<std::mutex> lock(mutex_);
    return snapshot_.decision == RdpGlUploadDecision::PboExperimentEligible &&
        gles3Capable && pixelUnpackBufferCapable;
}

bool RdpGlUploadGate::ShouldRetainPbo(int64_t baselineWorkerP95Us,
                                      int64_t experimentWorkerP95Us,
                                      bool glErrorObserved,
                                      bool memoryControlled,
                                      bool visualMatrixPassed) {
    if (baselineWorkerP95Us <= 0 || experimentWorkerP95Us < 0 ||
        glErrorObserved || !memoryControlled || !visualMatrixPassed) {
        return false;
    }
    return experimentWorkerP95Us * 100 <= baselineWorkerP95Us * 85;
}

const char* RdpGlUploadGate::DecisionName(RdpGlUploadDecision decision) {
    switch (decision) {
        case RdpGlUploadDecision::KeepDirectUpload:
            return "direct";
        case RdpGlUploadDecision::PboExperimentEligible:
            return "pbo-eligible";
        case RdpGlUploadDecision::InsufficientSamples:
        default:
            return "insufficient";
    }
}
