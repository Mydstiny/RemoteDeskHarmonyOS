#ifndef RDP_H264_CAPABILITY_GATE_H
#define RDP_H264_CAPABILITY_GATE_H

#include <cstdint>

enum class RdpH264GateReason {
    Ready = 0,
    GfxResetMatrixPending,
    Avc420LifecyclePending,
    Avc420CompositionPending,
    DeviceProfileUnsupported,
    PerformanceEvidenceMissing,
    PerformanceGainInsufficient,
    StabilityMatrixPending,
    Avc444LifecyclePending,
    Avc444CompositionPending,
    DirectTextureLifecyclePending,
    CrossSurfaceZeroCopyPending,
};

struct RdpH264CapabilityEvidence {
    bool gfxResetMatrixPassed = false;
    bool avc420LifecyclePassed = false;
    bool avc420CompositionSupported = false;
    bool deviceProfileSupported = false;
    int64_t gdiDamageP95Us = 0;
    int64_t hardwareP95Us = 0;
    bool stabilityMatrixPassed = false;
    bool avc444LifecyclePassed = false;
    bool avc444CompositionSupported = false;
    bool directTextureLifecyclePassed = false;
    bool crossSurfaceZeroCopyPassed = false;
};

struct RdpH264CapabilitySnapshot {
    bool avc420Enabled = false;
    bool avc444Enabled = false;
    bool directTextureEnabled = false;
    int performanceGainPermille = 0;
    RdpH264GateReason avc420Reason = RdpH264GateReason::GfxResetMatrixPending;
    RdpH264GateReason avc444Reason = RdpH264GateReason::Avc420LifecyclePending;
    RdpH264GateReason directTextureReason = RdpH264GateReason::Avc420LifecyclePending;
};

inline int RdpH264PerformanceGainPermille(int64_t baselineP95Us, int64_t candidateP95Us) {
    if (baselineP95Us <= 0 || candidateP95Us < 0 || candidateP95Us >= baselineP95Us) {
        return 0;
    }
    return static_cast<int>(((baselineP95Us - candidateP95Us) * 1000) / baselineP95Us);
}

inline RdpH264GateReason EvaluateAvc420Reason(const RdpH264CapabilityEvidence& evidence) {
    if (!evidence.gfxResetMatrixPassed) return RdpH264GateReason::GfxResetMatrixPending;
    if (!evidence.avc420LifecyclePassed) return RdpH264GateReason::Avc420LifecyclePending;
    if (!evidence.avc420CompositionSupported) return RdpH264GateReason::Avc420CompositionPending;
    if (!evidence.deviceProfileSupported) return RdpH264GateReason::DeviceProfileUnsupported;
    if (evidence.gdiDamageP95Us <= 0 || evidence.hardwareP95Us <= 0) {
        return RdpH264GateReason::PerformanceEvidenceMissing;
    }
    if (RdpH264PerformanceGainPermille(evidence.gdiDamageP95Us, evidence.hardwareP95Us) < 300) {
        return RdpH264GateReason::PerformanceGainInsufficient;
    }
    if (!evidence.stabilityMatrixPassed) return RdpH264GateReason::StabilityMatrixPending;
    return RdpH264GateReason::Ready;
}

inline RdpH264CapabilitySnapshot EvaluateRdpH264Capabilities(
    const RdpH264CapabilityEvidence& evidence) {
    RdpH264CapabilitySnapshot snapshot;
    snapshot.performanceGainPermille =
        RdpH264PerformanceGainPermille(evidence.gdiDamageP95Us, evidence.hardwareP95Us);
    snapshot.avc420Reason = EvaluateAvc420Reason(evidence);
    snapshot.avc420Enabled = snapshot.avc420Reason == RdpH264GateReason::Ready;

    if (!snapshot.avc420Enabled) {
        snapshot.avc444Reason = snapshot.avc420Reason;
        snapshot.directTextureReason = snapshot.avc420Reason;
        return snapshot;
    }
    if (!evidence.avc444LifecyclePassed) {
        snapshot.avc444Reason = RdpH264GateReason::Avc444LifecyclePending;
    } else if (!evidence.avc444CompositionSupported) {
        snapshot.avc444Reason = RdpH264GateReason::Avc444CompositionPending;
    } else {
        snapshot.avc444Reason = RdpH264GateReason::Ready;
        snapshot.avc444Enabled = true;
    }
    if (!evidence.directTextureLifecyclePassed) {
        snapshot.directTextureReason = RdpH264GateReason::DirectTextureLifecyclePending;
    } else if (!evidence.crossSurfaceZeroCopyPassed) {
        snapshot.directTextureReason = RdpH264GateReason::CrossSurfaceZeroCopyPending;
    } else {
        snapshot.directTextureReason = RdpH264GateReason::Ready;
        snapshot.directTextureEnabled = true;
    }
    return snapshot;
}

inline const char* RdpH264GateReasonName(RdpH264GateReason reason) {
    switch (reason) {
        case RdpH264GateReason::Ready: return "ready";
        case RdpH264GateReason::GfxResetMatrixPending: return "gfx-reset-matrix-pending";
        case RdpH264GateReason::Avc420LifecyclePending: return "avc420-lifecycle-pending";
        case RdpH264GateReason::Avc420CompositionPending: return "avc420-composition-pending";
        case RdpH264GateReason::DeviceProfileUnsupported: return "device-profile-unsupported";
        case RdpH264GateReason::PerformanceEvidenceMissing: return "performance-evidence-missing";
        case RdpH264GateReason::PerformanceGainInsufficient: return "performance-gain-insufficient";
        case RdpH264GateReason::StabilityMatrixPending: return "stability-matrix-pending";
        case RdpH264GateReason::Avc444LifecyclePending: return "avc444-lifecycle-pending";
        case RdpH264GateReason::Avc444CompositionPending: return "avc444-composition-pending";
        case RdpH264GateReason::DirectTextureLifecyclePending: return "direct-texture-lifecycle-pending";
        case RdpH264GateReason::CrossSurfaceZeroCopyPending: return "cross-surface-zero-copy-pending";
        default: return "unknown";
    }
}

#endif
