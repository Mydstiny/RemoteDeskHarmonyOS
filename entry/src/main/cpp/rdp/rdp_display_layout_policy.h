#ifndef RDP_DISPLAY_LAYOUT_POLICY_H
#define RDP_DISPLAY_LAYOUT_POLICY_H

#include "extensions/protocol_adapter.h"

namespace RdpDisplayLayoutPolicy {

constexpr int64_t kMinimumSendIntervalUs = 500000;
constexpr int64_t kInFlightTimeoutUs = 5000000;

inline bool IsScaleFactorValid(int value) {
    return value == 100 || value == 140 || value == 180;
}

inline bool IsOrientationValid(int value) {
    return value == 0 || value == 90 || value == 180 || value == 270;
}

inline bool IsPhysicalSizeValid(int widthMm, int heightMm) {
    if (widthMm == 0 && heightMm == 0) {
        return true;
    }
    return widthMm >= 10 && widthMm <= 10000 &&
        heightMm >= 10 && heightMm <= 10000;
}

inline bool IsWithinServerAreaCaps(const RdpDisplayLayoutRequest& request,
                                   uint32_t maxAreaFactorA,
                                   uint32_t maxAreaFactorB) {
    if (maxAreaFactorA == 0 || maxAreaFactorB == 0) {
        return false;
    }
    const uint64_t requestedArea = static_cast<uint64_t>(request.width) *
        static_cast<uint64_t>(request.height);
    const uint64_t maximumArea = static_cast<uint64_t>(maxAreaFactorA) *
        static_cast<uint64_t>(maxAreaFactorB);
    return requestedArea <= maximumArea;
}

inline bool HasInFlightTimedOut(bool inFlight, int64_t inFlightSinceUs, int64_t nowUs) {
    return inFlight && inFlightSinceUs > 0 && nowUs >= inFlightSinceUs &&
        nowUs - inFlightSinceUs >= kInFlightTimeoutUs;
}

inline bool IsSendDue(bool hasPending, bool inFlight, int64_t lastSendUs, int64_t nowUs) {
    if (!hasPending || inFlight) {
        return false;
    }
    return lastSendUs <= 0 || (nowUs >= lastSendUs &&
        nowUs - lastSendUs >= kMinimumSendIntervalUs);
}

inline RdpDisplayLayoutResult Validate(const RdpDisplayLayoutRequest& request) {
    if (request.width < 200 || request.width > 8192 ||
        request.height < 200 || request.height > 8192 ||
        (request.width % 2) != 0) {
        return {false, "invalid_geometry",
                "RDP display layout requires an even 200-8192 width and a 200-8192 height"};
    }
    if (!IsPhysicalSizeValid(request.physicalWidthMm, request.physicalHeightMm)) {
        return {false, "invalid_physical_size",
                "RDP display physical dimensions must both be unknown or within 10-10000 mm"};
    }
    if (!IsOrientationValid(request.orientation)) {
        return {false, "invalid_orientation", "RDP display orientation is unsupported"};
    }
    if (!IsScaleFactorValid(request.desktopScaleFactor) ||
        !IsScaleFactorValid(request.deviceScaleFactor)) {
        return {false, "invalid_scale", "RDP display scale must be 100, 140, or 180"};
    }
    return {true, "accepted", "RDP display layout queued"};
}

} // namespace RdpDisplayLayoutPolicy

#endif
