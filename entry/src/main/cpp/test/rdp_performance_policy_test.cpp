/**
 * rdp_performance_policy_test.cpp - RDP graphics and LAN performance policy tests
 */

#include "test_runner.h"
#include "rdp/rdp_performance_policy.h"

RDP_TEST_CASE(rdp_performance_policy_prefers_gfx_h264_when_available) {
    RdpPerformancePolicy::Settings settings =
        RdpPerformancePolicy::RecommendedLanSettings(true, true);
    RDP_ASSERT(settings.networkAutoDetect);
    RDP_ASSERT_EQ(settings.connectionType, 6U);
    RDP_ASSERT(settings.supportGraphicsPipeline);
    RDP_ASSERT(settings.supportDynamicChannels);
    RDP_ASSERT(settings.remoteFxCodec);
    RDP_ASSERT(settings.gfxH264);
    RDP_ASSERT_EQ(settings.frameAcknowledge, 2U);
    RDP_ASSERT_EQ(RdpPerformancePolicy::SelectGraphicsMode(true, true),
                  RdpPerformancePolicy::GraphicsMode::GfxH264);
}

RDP_TEST_CASE(rdp_performance_policy_falls_back_when_h264_missing) {
    RdpPerformancePolicy::Settings settings =
        RdpPerformancePolicy::RecommendedLanSettings(true, false);
    RDP_ASSERT(settings.supportGraphicsPipeline);
    RDP_ASSERT(settings.supportDynamicChannels);
    RDP_ASSERT(settings.remoteFxCodec);
    RDP_ASSERT(!settings.gfxH264);
    RDP_ASSERT_EQ(RdpPerformancePolicy::SelectGraphicsMode(true, false),
                  RdpPerformancePolicy::GraphicsMode::Gfx);
}

RDP_TEST_CASE(rdp_performance_policy_keeps_gdi_fallback_when_gfx_missing) {
    RdpPerformancePolicy::Settings settings =
        RdpPerformancePolicy::RecommendedLanSettings(false, false);
    RDP_ASSERT(settings.networkAutoDetect);
    RDP_ASSERT_EQ(settings.connectionType, 6U);
    RDP_ASSERT(!settings.supportGraphicsPipeline);
    RDP_ASSERT(settings.supportDynamicChannels);
    RDP_ASSERT(!settings.remoteFxCodec);
    RDP_ASSERT(!settings.gfxH264);
    RDP_ASSERT_EQ(RdpPerformancePolicy::SelectGraphicsMode(false, false),
                  RdpPerformancePolicy::GraphicsMode::GdiFallback);
}

RDP_TEST_CASE(rdp_performance_policy_requires_gfx_consumer_before_advertising_gfx) {
    RdpPerformancePolicy::Settings settings =
        RdpPerformancePolicy::RecommendedLanSettings(true, true, false);
    RDP_ASSERT(!settings.supportGraphicsPipeline);
    RDP_ASSERT(settings.supportDynamicChannels);
    RDP_ASSERT(!settings.remoteFxCodec);
    RDP_ASSERT(!settings.gfxH264);
    RDP_ASSERT_EQ(RdpPerformancePolicy::SelectGraphicsMode(true, true, false),
                  RdpPerformancePolicy::GraphicsMode::GdiFallback);
}

RDP_TEST_CASE(rdp_performance_policy_keeps_gdi_when_gfx_reset_path_is_not_safe) {
    RdpPerformancePolicy::Settings settings =
        RdpPerformancePolicy::RecommendedLanSettings(true, true, true, false);
    RDP_ASSERT(!settings.supportGraphicsPipeline);
    RDP_ASSERT(settings.supportDynamicChannels);
    RDP_ASSERT(!settings.remoteFxCodec);
    RDP_ASSERT(!settings.gfxH264);
    RDP_ASSERT_EQ(RdpPerformancePolicy::SelectGraphicsMode(true, true, true, false),
                  RdpPerformancePolicy::GraphicsMode::GdiFallback);
}

RDP_TEST_CASE(rdp_performance_policy_keeps_gfx_but_blocks_unproven_h264_path) {
    RdpPerformancePolicy::Settings settings =
        RdpPerformancePolicy::RecommendedLanSettings(true, true, true, true, false);
    RDP_ASSERT(settings.supportGraphicsPipeline);
    RDP_ASSERT(settings.remoteFxCodec);
    RDP_ASSERT(!settings.gfxH264);
    RDP_ASSERT_EQ(RdpPerformancePolicy::SelectGraphicsMode(true, true, true, true, false),
                  RdpPerformancePolicy::GraphicsMode::Gfx);
}
