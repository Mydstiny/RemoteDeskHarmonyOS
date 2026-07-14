#include "test_runner.h"
#include "rdp/rdp_gl_upload_gate.h"

namespace {

RdpPresentMetrics PresentWithCosts(int64_t uploadUs, int64_t drawUs, int64_t swapUs) {
    RdpPresentMetrics present;
    present.result = RdpPresentResult::Presented;
    present.uploadUs = uploadUs;
    present.drawUs = drawUs;
    present.swapUs = swapUs;
    return present;
}

void RecordWindow(RdpGlUploadGate& gate, int64_t uploadUs,
                  int64_t drawUs, int64_t swapUs) {
    for (size_t i = 0; i < RdpGlUploadGate::kDecisionSamples; ++i) {
        gate.recordPresent(PresentWithCosts(uploadUs, drawUs, swapUs));
    }
}

} // namespace

RDP_TEST_CASE(rdp_gl_upload_gate_requires_full_successful_sample_window) {
    RdpGlUploadGate gate;
    RdpPresentMetrics rejected;
    rejected.result = RdpPresentResult::SurfaceDetached;
    for (int i = 0; i < 200; ++i) {
        gate.recordPresent(rejected);
    }
    for (size_t i = 0; i + 1 < RdpGlUploadGate::kDecisionSamples; ++i) {
        gate.recordPresent(PresentWithCosts(5000, 2000, 2000));
    }
    const RdpGlUploadGateSnapshot snapshot = gate.snapshot();
    RDP_ASSERT(snapshot.decision == RdpGlUploadDecision::InsufficientSamples);
    RDP_ASSERT_EQ(snapshot.pendingSamples, RdpGlUploadGate::kDecisionSamples - 1);
}

RDP_TEST_CASE(rdp_gl_upload_gate_keeps_direct_upload_below_sixty_percent) {
    RdpGlUploadGate gate;
    RecordWindow(gate, 4000, 5000, 1000);
    const RdpGlUploadGateSnapshot snapshot = gate.snapshot();
    RDP_ASSERT(snapshot.decision == RdpGlUploadDecision::KeepDirectUpload);
    RDP_ASSERT_EQ(snapshot.uploadSwapP95Us, static_cast<int64_t>(5000));
    RDP_ASSERT_EQ(snapshot.workerP95Us, static_cast<int64_t>(10000));
    RDP_ASSERT_EQ(snapshot.uploadSwapSharePermille, 500);
}

RDP_TEST_CASE(rdp_gl_upload_gate_allows_capability_checked_pbo_experiment) {
    RdpGlUploadGate gate;
    RecordWindow(gate, 4000, 4000, 2000);
    const RdpGlUploadGateSnapshot snapshot = gate.snapshot();
    RDP_ASSERT(snapshot.decision == RdpGlUploadDecision::PboExperimentEligible);
    RDP_ASSERT_EQ(snapshot.uploadSwapSharePermille, 600);
    RDP_ASSERT(gate.canRunPboExperiment(true, true));
    RDP_ASSERT(!gate.canRunPboExperiment(false, true));
    RDP_ASSERT(!gate.canRunPboExperiment(true, false));
}

RDP_TEST_CASE(rdp_gl_upload_gate_retains_pbo_only_after_safe_fifteen_percent_gain) {
    RDP_ASSERT(RdpGlUploadGate::ShouldRetainPbo(
        20000, 17000, false, true, true));
    RDP_ASSERT(!RdpGlUploadGate::ShouldRetainPbo(
        20000, 17001, false, true, true));
    RDP_ASSERT(!RdpGlUploadGate::ShouldRetainPbo(
        20000, 16000, true, true, true));
    RDP_ASSERT(!RdpGlUploadGate::ShouldRetainPbo(
        20000, 16000, false, false, true));
    RDP_ASSERT(!RdpGlUploadGate::ShouldRetainPbo(
        20000, 16000, false, true, false));
}
