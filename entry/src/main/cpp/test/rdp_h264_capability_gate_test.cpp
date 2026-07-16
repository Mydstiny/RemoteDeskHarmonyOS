#include "test_runner.h"
#include "rdp/rdp_h264_capability_gate.h"

RDP_TEST_CASE(rdp_h264_gate_requires_every_avc420_production_requirement) {
    RdpH264CapabilityEvidence evidence;
    evidence.gfxResetMatrixPassed = true;
    evidence.avc420LifecyclePassed = true;
    evidence.avc420CompositionSupported = true;
    evidence.deviceProfileSupported = true;
    evidence.gdiDamageP95Us = 10000;
    evidence.hardwareP95Us = 7000;

    RdpH264CapabilitySnapshot snapshot = EvaluateRdpH264Capabilities(evidence);
    RDP_ASSERT(!snapshot.avc420Enabled);
    RDP_ASSERT_EQ(snapshot.avc420Reason, RdpH264GateReason::StabilityMatrixPending);

    evidence.stabilityMatrixPassed = true;
    snapshot = EvaluateRdpH264Capabilities(evidence);
    RDP_ASSERT(snapshot.avc420Enabled);
    RDP_ASSERT_EQ(snapshot.performanceGainPermille, 300);
}

RDP_TEST_CASE(rdp_h264_gate_rejects_less_than_thirty_percent_p95_gain) {
    RdpH264CapabilityEvidence evidence;
    evidence.gfxResetMatrixPassed = true;
    evidence.avc420LifecyclePassed = true;
    evidence.avc420CompositionSupported = true;
    evidence.deviceProfileSupported = true;
    evidence.gdiDamageP95Us = 10000;
    evidence.hardwareP95Us = 7001;
    evidence.stabilityMatrixPassed = true;

    const RdpH264CapabilitySnapshot snapshot = EvaluateRdpH264Capabilities(evidence);
    RDP_ASSERT(!snapshot.avc420Enabled);
    RDP_ASSERT_EQ(snapshot.avc420Reason, RdpH264GateReason::PerformanceGainInsufficient);
}

RDP_TEST_CASE(rdp_h264_gate_keeps_avc444_and_direct_texture_independent) {
    RdpH264CapabilityEvidence evidence;
    evidence.gfxResetMatrixPassed = true;
    evidence.avc420LifecyclePassed = true;
    evidence.avc420CompositionSupported = true;
    evidence.deviceProfileSupported = true;
    evidence.gdiDamageP95Us = 10000;
    evidence.hardwareP95Us = 6000;
    evidence.stabilityMatrixPassed = true;

    RdpH264CapabilitySnapshot snapshot = EvaluateRdpH264Capabilities(evidence);
    RDP_ASSERT(snapshot.avc420Enabled);
    RDP_ASSERT(!snapshot.avc444Enabled);
    RDP_ASSERT(!snapshot.directTextureEnabled);

    evidence.avc444LifecyclePassed = true;
    evidence.avc444CompositionSupported = true;
    snapshot = EvaluateRdpH264Capabilities(evidence);
    RDP_ASSERT(snapshot.avc444Enabled);
    RDP_ASSERT(!snapshot.directTextureEnabled);

    evidence.directTextureLifecyclePassed = true;
    evidence.crossSurfaceZeroCopyPassed = true;
    snapshot = EvaluateRdpH264Capabilities(evidence);
    RDP_ASSERT(snapshot.directTextureEnabled);
}
