/**
 * rdp_performance_policy.h - RDP transport and graphics performance settings
 */

#ifndef RDP_PERFORMANCE_POLICY_H
#define RDP_PERFORMANCE_POLICY_H

#include <cstdint>

namespace RdpPerformancePolicy {

enum class GraphicsMode {
    GdiFallback = 0,
    Gfx = 1,
    GfxH264 = 2,
};

struct Settings {
    bool networkAutoDetect = true;
    std::uint32_t connectionType = 6;
    bool supportGraphicsPipeline = true;
    bool supportDynamicChannels = true;
    bool remoteFxCodec = true;
    bool gfxH264 = true;
    bool nsCodec = false;
    bool nsCodecAllowSubsampling = true;
    bool nsCodecAllowDynamicColorFidelity = true;
    std::uint32_t nsCodecColorLossLevel = 3;
    std::uint32_t frameAcknowledge = 2;
};

inline Settings RecommendedLanSettings(bool gfxAvailable,
                                       bool h264Available,
                                       bool gfxConsumerAvailable = true,
                                       bool gfxResetPathSafe = true,
                                       bool h264PathSafe = true) {
    const bool effectiveGfxAvailable = gfxAvailable && gfxConsumerAvailable && gfxResetPathSafe;
    Settings settings;
    settings.supportGraphicsPipeline = effectiveGfxAvailable;
    settings.remoteFxCodec = effectiveGfxAvailable;
    settings.gfxH264 = effectiveGfxAvailable && h264Available && h264PathSafe;
    return settings;
}

inline GraphicsMode SelectGraphicsMode(bool gfxAvailable,
                                       bool h264Available,
                                       bool gfxConsumerAvailable = true,
                                       bool gfxResetPathSafe = true,
                                       bool h264PathSafe = true) {
    const bool effectiveGfxAvailable = gfxAvailable && gfxConsumerAvailable && gfxResetPathSafe;
    if (effectiveGfxAvailable && h264Available && h264PathSafe) {
        return GraphicsMode::GfxH264;
    }
    if (effectiveGfxAvailable) {
        return GraphicsMode::Gfx;
    }
    return GraphicsMode::GdiFallback;
}

inline const char* GraphicsModeName(GraphicsMode mode) {
    switch (mode) {
        case GraphicsMode::GfxH264:
            return "gfx-h264";
        case GraphicsMode::Gfx:
            return "gfx";
        case GraphicsMode::GdiFallback:
        default:
            return "gdi";
    }
}

} // namespace RdpPerformancePolicy

#endif // RDP_PERFORMANCE_POLICY_H
