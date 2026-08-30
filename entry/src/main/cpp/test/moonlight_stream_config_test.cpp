#include "moonlight/media/MoonlightStreamConfig.h"
#include "moonlight/input/MoonlightProductInputRuntime.h"
#include "moonlight/runtime/MoonlightProductStreamingRuntime.h"
#include "test_runner.h"

#include <algorithm>
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

namespace {

using namespace remotedesk::moonlight;

constexpr std::uint64_t NOW_MS = 1000U;
constexpr std::uint64_t EXPIRY_MS = 20000U;

MoonlightStreamCapabilityEvidence evidence(
    MoonlightStreamCapabilitySource source, std::uint64_t generation,
    MoonlightStreamCapabilityStatus status = MoonlightStreamCapabilityStatus::Supported) {
    return {status, source, "proof-v1", generation, EXPIRY_MS};
}

MoonlightStreamCodecProfile profile(
    MoonlightStreamCodec codec, MoonlightStreamBitDepth bitDepth,
    MoonlightStreamChroma chroma) {
    return {codec, bitDepth, chroma};
}

std::vector<MoonlightStreamCodecProfile> allProfiles() {
    return {
        profile(MoonlightStreamCodec::H264, MoonlightStreamBitDepth::Bit8,
                MoonlightStreamChroma::Yuv420),
        profile(MoonlightStreamCodec::H264, MoonlightStreamBitDepth::Bit8,
                MoonlightStreamChroma::Yuv444),
        profile(MoonlightStreamCodec::Hevc, MoonlightStreamBitDepth::Bit8,
                MoonlightStreamChroma::Yuv420),
        profile(MoonlightStreamCodec::Hevc, MoonlightStreamBitDepth::Bit10,
                MoonlightStreamChroma::Yuv420),
        profile(MoonlightStreamCodec::Hevc, MoonlightStreamBitDepth::Bit8,
                MoonlightStreamChroma::Yuv444),
        profile(MoonlightStreamCodec::Hevc, MoonlightStreamBitDepth::Bit10,
                MoonlightStreamChroma::Yuv444),
        profile(MoonlightStreamCodec::Av1, MoonlightStreamBitDepth::Bit8,
                MoonlightStreamChroma::Yuv420),
        profile(MoonlightStreamCodec::Av1, MoonlightStreamBitDepth::Bit10,
                MoonlightStreamChroma::Yuv420),
        profile(MoonlightStreamCodec::Av1, MoonlightStreamBitDepth::Bit8,
                MoonlightStreamChroma::Yuv444),
        profile(MoonlightStreamCodec::Av1, MoonlightStreamBitDepth::Bit10,
                MoonlightStreamChroma::Yuv444),
    };
}

MoonlightStreamConfigIdentity readyIdentity() {
    return {
        101U, 201U, "host-a", "SERVER-A", 301U,
        11U, 12U, 13U, 14U,
    };
}

MoonlightRequestedStreamConfig readyRequest() {
    MoonlightRequestedStreamConfig request;
    request.requested = MoonlightStreamSettings {};
    request.d1Effective = request.requested;
    return request;
}

MoonlightStreamCapabilitySnapshot readyCapabilities() {
    MoonlightStreamCapabilitySnapshot capabilities;
    capabilities.host.evidence = evidence(MoonlightStreamCapabilitySource::Host, 11U);
    capabilities.host.recommendedMode = MoonlightStreamDimensions {1920, 1080};
    capabilities.host.maxWidth = 7680;
    capabilities.host.maxHeight = 4320;
    capabilities.host.maxFps = 240;
    capabilities.host.maxEncoderBitrateKbps = 200000;
    capabilities.host.codecProfiles = allProfiles();
    capabilities.host.hdr = true;
    capabilities.host.yuv444 = true;
    capabilities.host.rec709Limited = true;
    capabilities.host.rec2020Limited = true;
    capabilities.host.opusStereo = true;
    capabilities.host.opusSurround51 = true;
    capabilities.host.opusSurround71 = true;
    capabilities.host.highQualitySurround = true;
    capabilities.host.encryptionStreams = MoonlightStreamEncryptAudio |
        MoonlightStreamEncryptVideo;

    capabilities.platform.evidence = evidence(
        MoonlightStreamCapabilitySource::PlatformProbe, 12U);
    capabilities.platform.maxWidth = 7680;
    capabilities.platform.maxHeight = 4320;
    capabilities.platform.maxFps = 240;
    capabilities.platform.maxDecodeBitrateKbps = 200000;
    capabilities.platform.maxThermalBitrateKbps = 150000;
    capabilities.platform.decoderProfiles = allProfiles();
    capabilities.platform.rendererYuv444 = true;
    capabilities.platform.opusStereoOutput = true;
    capabilities.platform.opusSurround51Output = true;
    capabilities.platform.opusSurround71Output = true;
    capabilities.platform.commonCOpusMultistream = true;
    capabilities.platform.audioDiscardPath = true;
    capabilities.platform.slowOpusDecoder = false;
    capabilities.platform.commonCEncryptionStreams = MoonlightStreamEncryptAudio |
        MoonlightStreamEncryptVideo;

    capabilities.network.evidence = evidence(
        MoonlightStreamCapabilitySource::NetworkProbe, 13U);
    capabilities.network.path = MoonlightStreamNetworkPath::Local;
    capabilities.network.addressFamily = MoonlightStreamAddressFamily::Ipv4;
    capabilities.network.vpnClassificationKnown = true;
    capabilities.network.nat64ClassificationKnown = true;
    capabilities.network.mtuReceiptAvailable = true;
    capabilities.network.safeVideoPacketSizeBytes = 1440;
    capabilities.network.metered = MoonlightStreamMeteredState::Unmetered;
    capabilities.network.maxBitrateKbps = 100000;

    capabilities.display.evidence = evidence(
        MoonlightStreamCapabilitySource::DisplayProbe, 14U);
    capabilities.display.maxWidth = 7680;
    capabilities.display.maxHeight = 4320;
    capabilities.display.maxFps = 240;
    capabilities.display.refreshRateX100 = 5994;
    capabilities.display.hdr = true;
    capabilities.display.surfaceHdr = true;
    capabilities.display.pipHdr = true;
    capabilities.display.yuv444 = true;
    capabilities.display.rec709Limited = true;
    capabilities.display.rec2020Limited = true;
    return capabilities;
}

bool hasAdjustment(const MoonlightStreamConfigResult& result, const std::string& code) {
    return std::any_of(result.adjustments.begin(), result.adjustments.end(),
        [&](const MoonlightStreamAdjustment& adjustment) {
            return adjustment.code == code;
        });
}

bool hasOffer(
    const MoonlightStreamConfigResult& result, MoonlightStreamCodec codec,
    MoonlightStreamBitDepth depth, MoonlightStreamChroma chroma) {
    if (!result.offer.has_value()) {
        return false;
    }
    return std::any_of(result.offer->offeredCodecs.begin(), result.offer->offeredCodecs.end(),
        [&](const MoonlightOfferedCodec& offered) {
            return offered.codec == codec && offered.bitDepth == depth && offered.chroma == chroma;
        });
}

void keepOnlyCodec(
    std::vector<MoonlightStreamCodecProfile>& profiles, MoonlightStreamCodec codec) {
    profiles.erase(std::remove_if(profiles.begin(), profiles.end(),
        [&](const MoonlightStreamCodecProfile& item) { return item.codec != codec; }), profiles.end());
}

void removeCodec(
    std::vector<MoonlightStreamCodecProfile>& profiles, MoonlightStreamCodec codec) {
    profiles.erase(std::remove_if(profiles.begin(), profiles.end(),
        [&](const MoonlightStreamCodecProfile& item) { return item.codec == codec; }), profiles.end());
}

} // namespace

RDP_TEST_CASE(moonlight_stream_config_builds_deterministic_host_offer) {
    const auto result = resolveMoonlightStreamConfig(
        readyRequest(), readyCapabilities(), readyIdentity(), NOW_MS);
    RDP_ASSERT(result.ready());
    RDP_ASSERT_EQ(result.status, MoonlightStreamResultStatus::OfferReady);
    RDP_ASSERT_EQ(result.code, MoonlightStreamResultCode::None);
    RDP_ASSERT_EQ(result.offer->dimensions.width, 1920);
    RDP_ASSERT_EQ(result.offer->dimensions.height, 1080);
    RDP_ASSERT_EQ(result.offer->fps, 60);
    RDP_ASSERT_EQ(result.offer->launchRefreshRate, 60);
    RDP_ASSERT_EQ(result.offer->clientRefreshRateX100, 5994);
    RDP_ASSERT_EQ(result.offer->configuredBitrateKbps, 20000);
    RDP_ASSERT_EQ(result.offer->estimatedEncoderBitrateKbps, 16000);
    RDP_ASSERT_EQ(result.offer->packetSizeBytes, 1440);
    RDP_ASSERT(!result.offer->selectedCodec.has_value());
    RDP_ASSERT(hasOffer(result, MoonlightStreamCodec::H264,
        MoonlightStreamBitDepth::Bit8, MoonlightStreamChroma::Yuv420));
    RDP_ASSERT(result.launchProjection.has_value());
    RDP_ASSERT_EQ(result.launchProjection->dimensions.width, result.offer->dimensions.width);
    RDP_ASSERT_EQ(result.launchProjection->dimensions.height, result.offer->dimensions.height);
    RDP_ASSERT_EQ(result.launchProjection->fps, result.offer->fps);
    RDP_ASSERT_EQ(result.launchProjection->audioLayout, result.offer->audioLayout);
    RDP_ASSERT_EQ(result.launchProjection->controllerBitmap, 0U);
    RDP_ASSERT(!result.launchProjection->persistGamepadsAfterDisconnect);
}

RDP_TEST_CASE(moonlight_product_terminal_input_requires_positive_teardown_proof) {
    RDP_ASSERT(moonlightProductRemoteInputReleaseProven(
        MoonlightInputFlushStatus::Applied, true, true));
    RDP_ASSERT(!moonlightProductRemoteInputReleaseProven(
        MoonlightInputFlushStatus::Applied, false, true));
    RDP_ASSERT(!moonlightProductRemoteInputReleaseProven(
        MoonlightInputFlushStatus::Applied, true, false));
    RDP_ASSERT(!moonlightProductRemoteInputReleaseProven(
        MoonlightInputFlushStatus::AppliedLocally, true, false));
    RDP_ASSERT(!moonlightProductRemoteInputReleaseProven(
        MoonlightInputFlushStatus::AlreadyApplied, true, true));
    RDP_ASSERT(!moonlightProductRemoteInputReleaseProven(
        MoonlightInputFlushStatus::BoundaryFailure, true, false));
    RDP_ASSERT(!moonlightProductTerminalInputMayBeStuck(
        false, false, false, false));
    RDP_ASSERT(!moonlightProductTerminalInputMayBeStuck(
        false, true, true, false));
    RDP_ASSERT(!moonlightProductTerminalInputMayBeStuck(
        true, true, true, true));
    RDP_ASSERT(moonlightProductTerminalInputMayBeStuck(
        true, false, false, false));
    // A successful stopLocally() retires process state but does not prove the
    // Sunshine input state was neutralized after permanent port failure.
    RDP_ASSERT(moonlightProductTerminalInputMayBeStuck(
        true, true, true, false));
    RDP_ASSERT(moonlightProductTerminalInputMayBeStuck(
        true, true, false, true));
}

RDP_TEST_CASE(moonlight_product_first_frame_accepts_exact_renderer_evidence) {
    RDP_ASSERT(moonlightProductStopReachedTerminal(
        MoonlightStopStatus::Stopped));
    RDP_ASSERT(moonlightProductStopReachedTerminal(
        MoonlightStopStatus::AlreadyTerminal));
    RDP_ASSERT(moonlightProductStopReachedTerminal(
        MoonlightStopStatus::DriverFailure));
    RDP_ASSERT(!moonlightProductStopReachedTerminal(
        MoonlightStopStatus::TimedOut));
    RDP_ASSERT(moonlightProductFirstFrameProven(
        true, false, 0U, 0U, 0U, 0U));
    RDP_ASSERT(moonlightProductFirstFrameProven(
        false, true, 1U, 1U, 1U, 1U));
    RDP_ASSERT(!moonlightProductFirstFrameProven(
        false, true, 1200U, 1200U, 1199U, 0U));
    RDP_ASSERT(moonlightProductVideoReady(false, true));
    RDP_ASSERT(moonlightProductVideoReady(true, false));
    RDP_ASSERT(!moonlightProductVideoReady(false, false));
    RDP_ASSERT(!moonlightProductSessionFirstFrameReady(false, false));
    RDP_ASSERT(moonlightProductSessionFirstFrameReady(false, true));
    RDP_ASSERT(moonlightProductSessionFirstFrameReady(true, false));
    RDP_ASSERT_EQ(moonlightProductPresentedFrameProgress(
        true, 1200U, 1200U, 1199U, 0U), 0U);
    RDP_ASSERT_EQ(moonlightProductPresentedFrameProgress(
        true, 1200U, 1200U, 1199U, 1199U), 1199U);
    RDP_ASSERT(!moonlightProductFirstFrameProven(
        false, false, 1200U, 1200U, 1199U, 1199U));
    RDP_ASSERT(!moonlightProductFirstFrameProven(
        false, true, 0U, 1U, 1U, 1U));
    RDP_ASSERT(!moonlightProductFirstFrameProven(
        false, true, 1U, 0U, 1U, 1U));
    RDP_ASSERT(!moonlightProductFirstFrameProven(
        false, true, 1U, 1U, 0U, 1U));
}

RDP_TEST_CASE(moonlight_stream_config_maps_all_fixed_resolution_presets) {
    const std::vector<std::pair<MoonlightStreamResolutionMode, MoonlightStreamDimensions>> cases {
        {MoonlightStreamResolutionMode::P720, {1280, 720}},
        {MoonlightStreamResolutionMode::P1080, {1920, 1080}},
        {MoonlightStreamResolutionMode::P1440, {2560, 1440}},
        {MoonlightStreamResolutionMode::P2160, {3840, 2160}},
    };
    for (const auto& item : cases) {
        auto request = readyRequest();
        request.requested.resolutionMode = item.first;
        request.d1Effective.resolutionMode = item.first;
        const auto result = resolveMoonlightStreamConfig(
            request, readyCapabilities(), readyIdentity(), NOW_MS);
        RDP_ASSERT(result.ready());
        RDP_ASSERT_EQ(result.offer->dimensions.width, item.second.width);
        RDP_ASSERT_EQ(result.offer->dimensions.height, item.second.height);
    }
}

RDP_TEST_CASE(moonlight_stream_config_rejects_host_guess_when_recommendation_missing) {
    auto capabilities = readyCapabilities();
    capabilities.host.recommendedMode.reset();
    const auto result = resolveMoonlightStreamConfig(
        readyRequest(), capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT_EQ(result.status, MoonlightStreamResultStatus::CapabilityPending);
    RDP_ASSERT_EQ(result.code, MoonlightStreamResultCode::HostModePending);
    RDP_ASSERT(!result.offer.has_value());
}

RDP_TEST_CASE(moonlight_stream_config_aligns_custom_dimensions_and_records_adjustment) {
    auto request = readyRequest();
    request.requested.resolutionMode = MoonlightStreamResolutionMode::Custom;
    request.d1Effective.resolutionMode = MoonlightStreamResolutionMode::Custom;
    request.requested.customWidth = request.d1Effective.customWidth = 1919;
    request.requested.customHeight = request.d1Effective.customHeight = 1079;
    const auto result = resolveMoonlightStreamConfig(
        request, readyCapabilities(), readyIdentity(), NOW_MS);
    RDP_ASSERT(result.ready());
    RDP_ASSERT_EQ(result.offer->dimensions.width, 1918);
    RDP_ASSERT_EQ(result.offer->dimensions.height, 1078);
    RDP_ASSERT(hasAdjustment(result, "codec_chroma_alignment"));
}

RDP_TEST_CASE(moonlight_stream_config_scales_4k_to_proven_runtime_bounds) {
    auto request = readyRequest();
    request.requested.resolutionMode = MoonlightStreamResolutionMode::P2160;
    request.d1Effective.resolutionMode = MoonlightStreamResolutionMode::P2160;
    auto capabilities = readyCapabilities();
    capabilities.host.maxWidth = capabilities.platform.maxWidth = capabilities.display.maxWidth = 1920;
    capabilities.host.maxHeight = capabilities.platform.maxHeight = capabilities.display.maxHeight = 1080;
    const auto result = resolveMoonlightStreamConfig(
        request, capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT(result.ready());
    RDP_ASSERT_EQ(result.offer->dimensions.width, 1920);
    RDP_ASSERT_EQ(result.offer->dimensions.height, 1080);
    RDP_ASSERT(hasAdjustment(result, "runtime_dimension_limit"));
}

RDP_TEST_CASE(moonlight_stream_config_caps_h264_only_dimensions_at_4096) {
    auto request = readyRequest();
    request.requested.resolutionMode = MoonlightStreamResolutionMode::Custom;
    request.d1Effective.resolutionMode = MoonlightStreamResolutionMode::Custom;
    request.requested.customWidth = request.d1Effective.customWidth = 7680;
    request.requested.customHeight = request.d1Effective.customHeight = 4320;
    auto capabilities = readyCapabilities();
    keepOnlyCodec(capabilities.host.codecProfiles, MoonlightStreamCodec::H264);
    keepOnlyCodec(capabilities.platform.decoderProfiles, MoonlightStreamCodec::H264);
    const auto result = resolveMoonlightStreamConfig(
        request, capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT(result.ready());
    RDP_ASSERT_EQ(result.offer->dimensions.width, 4096);
    RDP_ASSERT_EQ(result.offer->dimensions.height, 2304);
    RDP_ASSERT(hasAdjustment(result, "h264_dimension_limit"));
}

RDP_TEST_CASE(moonlight_stream_config_rejects_invalid_identity_and_settings) {
    auto identity = readyIdentity();
    identity.ownerToken = 0U;
    auto result = resolveMoonlightStreamConfig(
        readyRequest(), readyCapabilities(), identity, NOW_MS);
    RDP_ASSERT_EQ(result.status, MoonlightStreamResultStatus::InvalidRequest);
    RDP_ASSERT_EQ(result.code, MoonlightStreamResultCode::InvalidIdentity);

    auto request = readyRequest();
    request.d1Effective.bitrateKbps = 0;
    result = resolveMoonlightStreamConfig(
        request, readyCapabilities(), readyIdentity(), NOW_MS);
    RDP_ASSERT_EQ(result.status, MoonlightStreamResultStatus::InvalidRequest);
    RDP_ASSERT_EQ(result.code, MoonlightStreamResultCode::InvalidSettings);
}

RDP_TEST_CASE(moonlight_stream_config_rejects_unknown_enum_values) {
    auto request = readyRequest();
    request.d1Effective.codecPreference = static_cast<MoonlightStreamCodecPreference>(255U);
    const auto result = resolveMoonlightStreamConfig(
        request, readyCapabilities(), readyIdentity(), NOW_MS);
    RDP_ASSERT_EQ(result.status, MoonlightStreamResultStatus::InvalidRequest);
    RDP_ASSERT_EQ(result.code, MoonlightStreamResultCode::InvalidSettings);
}

RDP_TEST_CASE(moonlight_stream_config_requires_fresh_exact_capability_generations) {
    auto identity = readyIdentity();
    identity.hostCapabilityGeneration++;
    auto result = resolveMoonlightStreamConfig(
        readyRequest(), readyCapabilities(), identity, NOW_MS);
    RDP_ASSERT_EQ(result.status, MoonlightStreamResultStatus::CapabilityPending);
    RDP_ASSERT_EQ(result.code, MoonlightStreamResultCode::CapabilityStale);

    auto capabilities = readyCapabilities();
    capabilities.display.evidence.expiresAtMonotonicMs = NOW_MS;
    result = resolveMoonlightStreamConfig(
        readyRequest(), capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT_EQ(result.status, MoonlightStreamResultStatus::CapabilityPending);
    RDP_ASSERT_EQ(result.code, MoonlightStreamResultCode::CapabilityStale);
}

RDP_TEST_CASE(moonlight_stream_config_propagates_pending_and_unsupported_evidence) {
    auto capabilities = readyCapabilities();
    capabilities.platform.evidence.status = MoonlightStreamCapabilityStatus::Pending;
    auto result = resolveMoonlightStreamConfig(
        readyRequest(), capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT_EQ(result.status, MoonlightStreamResultStatus::CapabilityPending);
    RDP_ASSERT_EQ(result.code, MoonlightStreamResultCode::CapabilityPending);

    capabilities = readyCapabilities();
    capabilities.host.evidence.status = MoonlightStreamCapabilityStatus::Unsupported;
    result = resolveMoonlightStreamConfig(
        readyRequest(), capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT_EQ(result.status, MoonlightStreamResultStatus::Rejected);
    RDP_ASSERT_EQ(result.code, MoonlightStreamResultCode::CapabilityUnsupported);
}

RDP_TEST_CASE(moonlight_stream_config_requires_h264_mvp_on_both_sides) {
    auto capabilities = readyCapabilities();
    removeCodec(capabilities.platform.decoderProfiles, MoonlightStreamCodec::H264);
    const auto result = resolveMoonlightStreamConfig(
        readyRequest(), capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT_EQ(result.status, MoonlightStreamResultStatus::Rejected);
    RDP_ASSERT_EQ(result.code, MoonlightStreamResultCode::MvpCodecUnavailable);
}

RDP_TEST_CASE(moonlight_stream_config_falls_back_for_forced_unavailable_codec) {
    auto request = readyRequest();
    request.requested.codecPreference = request.d1Effective.codecPreference =
        MoonlightStreamCodecPreference::Av1;
    auto capabilities = readyCapabilities();
    removeCodec(capabilities.host.codecProfiles, MoonlightStreamCodec::Av1);
    const auto result = resolveMoonlightStreamConfig(
        request, capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT(result.ready());
    RDP_ASSERT(hasAdjustment(result, "requested_codec_unavailable"));
    RDP_ASSERT_EQ(result.offer->offeredCodecs.front().codec, MoonlightStreamCodec::H264);
}

RDP_TEST_CASE(moonlight_stream_config_auto_offer_is_proven_and_priority_ordered) {
    const auto result = resolveMoonlightStreamConfig(
        readyRequest(), readyCapabilities(), readyIdentity(), NOW_MS);
    RDP_ASSERT(result.ready());
    RDP_ASSERT(!result.offer->offeredCodecs.empty());
    RDP_ASSERT_EQ(result.offer->offeredCodecs.front().codec, MoonlightStreamCodec::Av1);
    RDP_ASSERT(result.offer->offeredCodecs.front().preferred);
    RDP_ASSERT(hasOffer(result, MoonlightStreamCodec::Hevc,
        MoonlightStreamBitDepth::Bit8, MoonlightStreamChroma::Yuv420));
    RDP_ASSERT(hasOffer(result, MoonlightStreamCodec::H264,
        MoonlightStreamBitDepth::Bit8, MoonlightStreamChroma::Yuv420));
}

RDP_TEST_CASE(moonlight_stream_config_keeps_proven_hdr_intent_and_profile) {
    auto request = readyRequest();
    request.requested.hdr = request.d1Effective.hdr = true;
    const auto result = resolveMoonlightStreamConfig(
        request, readyCapabilities(), readyIdentity(), NOW_MS);
    RDP_ASSERT(result.ready());
    RDP_ASSERT(result.offer->hdr);
    RDP_ASSERT_EQ(result.offer->colorSpace.value(), MoonlightStreamColorSpace::Rec2020);
    RDP_ASSERT_EQ(result.offer->colorRange.value(), MoonlightStreamColorRange::Limited);
    RDP_ASSERT(hasOffer(result, MoonlightStreamCodec::Hevc,
        MoonlightStreamBitDepth::Bit10, MoonlightStreamChroma::Yuv420));
    RDP_ASSERT(hasOffer(result, MoonlightStreamCodec::H264,
        MoonlightStreamBitDepth::Bit8, MoonlightStreamChroma::Yuv420));
}

RDP_TEST_CASE(moonlight_stream_config_downgrades_unproven_hdr_explicitly) {
    auto request = readyRequest();
    request.requested.hdr = request.d1Effective.hdr = true;
    auto capabilities = readyCapabilities();
    capabilities.display.surfaceHdr = false;
    const auto result = resolveMoonlightStreamConfig(
        request, capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT(result.ready());
    RDP_ASSERT(!result.offer->hdr);
    RDP_ASSERT(hasAdjustment(result, "hdr_pipeline_unavailable"));
}

RDP_TEST_CASE(moonlight_stream_config_intersects_yuv444_per_profile) {
    auto request = readyRequest();
    request.requested.yuv444 = request.d1Effective.yuv444 = true;
    const auto result = resolveMoonlightStreamConfig(
        request, readyCapabilities(), readyIdentity(), NOW_MS);
    RDP_ASSERT(result.ready());
    RDP_ASSERT(result.offer->yuv444);
    RDP_ASSERT(hasOffer(result, MoonlightStreamCodec::H264,
        MoonlightStreamBitDepth::Bit8, MoonlightStreamChroma::Yuv444));
    RDP_ASSERT(!hasOffer(result, MoonlightStreamCodec::H264,
        MoonlightStreamBitDepth::Bit8, MoonlightStreamChroma::Yuv420));
}

RDP_TEST_CASE(moonlight_stream_config_downgrades_unproven_yuv444_explicitly) {
    auto request = readyRequest();
    request.requested.yuv444 = request.d1Effective.yuv444 = true;
    auto capabilities = readyCapabilities();
    capabilities.platform.rendererYuv444 = false;
    const auto result = resolveMoonlightStreamConfig(
        request, capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT(result.ready());
    RDP_ASSERT(!result.offer->yuv444);
    RDP_ASSERT(hasAdjustment(result, "yuv444_pipeline_unavailable"));
}

RDP_TEST_CASE(moonlight_stream_config_keeps_fps_launch_and_display_refresh_distinct) {
    auto request = readyRequest();
    request.requested.fps = request.d1Effective.fps = 120;
    auto capabilities = readyCapabilities();
    capabilities.display.maxFps = 90;
    capabilities.display.refreshRateX100.reset();
    const auto result = resolveMoonlightStreamConfig(
        request, capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT(result.ready());
    RDP_ASSERT_EQ(result.offer->fps, 90);
    RDP_ASSERT_EQ(result.offer->launchRefreshRate, 90);
    RDP_ASSERT_EQ(result.offer->clientRefreshRateX100, 0);
    RDP_ASSERT(hasAdjustment(result, "runtime_fps_limit"));
}

RDP_TEST_CASE(moonlight_stream_config_caps_bitrate_and_projects_fec_once) {
    auto request = readyRequest();
    request.requested.bitrateKbps = request.d1Effective.bitrateKbps = 200000;
    auto capabilities = readyCapabilities();
    capabilities.host.maxEncoderBitrateKbps = 120000;
    capabilities.platform.maxDecodeBitrateKbps = 110000;
    capabilities.platform.maxThermalBitrateKbps = 90000;
    capabilities.network.maxBitrateKbps = 80000;
    const auto result = resolveMoonlightStreamConfig(
        request, capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT(result.ready());
    RDP_ASSERT_EQ(result.offer->configuredBitrateKbps, 80000);
    RDP_ASSERT_EQ(result.offer->estimatedEncoderBitrateKbps, 64000);
    RDP_ASSERT(hasAdjustment(result, "runtime_bitrate_limit"));
}

RDP_TEST_CASE(moonlight_stream_config_waits_for_all_bitrate_limits) {
    auto capabilities = readyCapabilities();
    capabilities.platform.maxThermalBitrateKbps = 0;
    const auto result = resolveMoonlightStreamConfig(
        readyRequest(), capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT_EQ(result.status, MoonlightStreamResultStatus::CapabilityPending);
    RDP_ASSERT_EQ(result.code, MoonlightStreamResultCode::BitrateCapabilityPending);
}

RDP_TEST_CASE(moonlight_stream_config_uses_1024_for_remote_or_unproven_packet_path) {
    auto capabilities = readyCapabilities();
    capabilities.network.path = MoonlightStreamNetworkPath::Remote;
    const auto remote = resolveMoonlightStreamConfig(
        readyRequest(), capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT(remote.ready());
    RDP_ASSERT_EQ(remote.offer->packetSizeBytes, 1024);

    capabilities = readyCapabilities();
    capabilities.network.mtuReceiptAvailable = false;
    const auto noReceipt = resolveMoonlightStreamConfig(
        readyRequest(), capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT(noReceipt.ready());
    RDP_ASSERT_EQ(noReceipt.offer->packetSizeBytes, 1024);
}

RDP_TEST_CASE(moonlight_stream_config_requires_resolved_network_path) {
    auto capabilities = readyCapabilities();
    capabilities.network.path = MoonlightStreamNetworkPath::Unknown;
    const auto result = resolveMoonlightStreamConfig(
        readyRequest(), capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT_EQ(result.status, MoonlightStreamResultStatus::CapabilityPending);
    RDP_ASSERT_EQ(result.code, MoonlightStreamResultCode::NetworkPathPending);
}

RDP_TEST_CASE(moonlight_stream_config_accepts_proven_ipv6_local_packet_path) {
    auto capabilities = readyCapabilities();
    capabilities.network.addressFamily = MoonlightStreamAddressFamily::Ipv6;
    capabilities.network.nat64 = true;
    capabilities.network.safeVideoPacketSizeBytes = 1280;
    const auto result = resolveMoonlightStreamConfig(
        readyRequest(), capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT(result.ready());
    RDP_ASSERT_EQ(result.offer->packetSizeBytes, 1280);
}

RDP_TEST_CASE(moonlight_stream_config_requires_metered_confirmation_or_rejects_deny) {
    auto capabilities = readyCapabilities();
    capabilities.network.path = MoonlightStreamNetworkPath::Remote;
    capabilities.network.metered = MoonlightStreamMeteredState::Metered;
    auto request = readyRequest();
    auto result = resolveMoonlightStreamConfig(
        request, capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT_EQ(result.status, MoonlightStreamResultStatus::ConfirmationRequired);
    RDP_ASSERT_EQ(result.code, MoonlightStreamResultCode::MeteredConfirmationRequired);

    request.requested.meteredPolicy = request.d1Effective.meteredPolicy =
        MoonlightStreamMeteredPolicy::Deny;
    result = resolveMoonlightStreamConfig(
        request, capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT_EQ(result.status, MoonlightStreamResultStatus::Rejected);
    RDP_ASSERT_EQ(result.code, MoonlightStreamResultCode::MeteredNetworkDenied);

    request.requested.meteredPolicy = request.d1Effective.meteredPolicy =
        MoonlightStreamMeteredPolicy::Allow;
    result = resolveMoonlightStreamConfig(
        request, capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT(result.ready());
}

RDP_TEST_CASE(moonlight_stream_config_requires_proven_audio_discard_path) {
    auto request = readyRequest();
    request.requested.audioEnabled = request.d1Effective.audioEnabled = false;
    request.requested.audioLayout = request.d1Effective.audioLayout =
        MoonlightStreamAudioLayout::Disabled;
    auto capabilities = readyCapabilities();
    capabilities.platform.audioDiscardPath = false;
    auto result = resolveMoonlightStreamConfig(
        request, capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT_EQ(result.status, MoonlightStreamResultStatus::CapabilityPending);
    RDP_ASSERT_EQ(result.code, MoonlightStreamResultCode::AudioDisablePathPending);

    capabilities.platform.audioDiscardPath = true;
    result = resolveMoonlightStreamConfig(
        request, capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT(result.ready());
    RDP_ASSERT_EQ(result.offer->audioLayout, MoonlightStreamAudioLayout::Disabled);
}

RDP_TEST_CASE(moonlight_stream_config_requires_opus_stereo_mvp) {
    auto capabilities = readyCapabilities();
    capabilities.platform.opusStereoOutput = false;
    const auto result = resolveMoonlightStreamConfig(
        readyRequest(), capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT_EQ(result.status, MoonlightStreamResultStatus::Rejected);
    RDP_ASSERT_EQ(result.code, MoonlightStreamResultCode::OpusStereoUnavailable);
}

RDP_TEST_CASE(moonlight_stream_config_falls_back_surround_and_marks_adjustment) {
    auto request = readyRequest();
    request.requested.audioLayout = request.d1Effective.audioLayout =
        MoonlightStreamAudioLayout::Surround71;
    auto capabilities = readyCapabilities();
    capabilities.platform.opusSurround71Output = false;
    const auto result = resolveMoonlightStreamConfig(
        request, capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT(result.ready());
    RDP_ASSERT_EQ(result.offer->audioLayout, MoonlightStreamAudioLayout::Stereo);
    RDP_ASSERT(hasAdjustment(result, "requested_audio_layout_unavailable"));
}

RDP_TEST_CASE(moonlight_stream_config_projects_high_quality_surround_candidate) {
    auto request = readyRequest();
    request.requested.audioLayout = request.d1Effective.audioLayout =
        MoonlightStreamAudioLayout::Surround51;
    request.requested.bitrateKbps = request.d1Effective.bitrateKbps = 15000;
    auto result = resolveMoonlightStreamConfig(
        request, readyCapabilities(), readyIdentity(), NOW_MS);
    RDP_ASSERT(result.ready());
    RDP_ASSERT(result.offer->highQualityAudioCandidate);

    auto capabilities = readyCapabilities();
    capabilities.network.path = MoonlightStreamNetworkPath::Remote;
    result = resolveMoonlightStreamConfig(
        request, capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT(result.ready());
    RDP_ASSERT(!result.offer->highQualityAudioCandidate);
}

RDP_TEST_CASE(moonlight_stream_config_enforces_required_stream_encryption) {
    auto request = readyRequest();
    request.requested.encryptionPolicy = request.d1Effective.encryptionPolicy =
        MoonlightStreamEncryptionPolicy::Required;
    auto capabilities = readyCapabilities();
    capabilities.host.encryptionStreams = MoonlightStreamEncryptAudio;
    auto result = resolveMoonlightStreamConfig(
        request, capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT_EQ(result.status, MoonlightStreamResultStatus::Rejected);
    RDP_ASSERT_EQ(result.code, MoonlightStreamResultCode::EncryptionRequiredUnavailable);

    capabilities.host.encryptionStreams = MoonlightStreamEncryptAudio |
        MoonlightStreamEncryptVideo;
    result = resolveMoonlightStreamConfig(
        request, capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT(result.ready());
    RDP_ASSERT_EQ(result.offer->requiredEncryptionStreams,
        static_cast<std::uint32_t>(MoonlightStreamEncryptAudio | MoonlightStreamEncryptVideo));
    RDP_ASSERT(result.offer->remoteInputEncryptionRequired);
}

RDP_TEST_CASE(moonlight_stream_config_compatible_encryption_is_candidate_not_fact) {
    auto request = readyRequest();
    request.requested.encryptionPolicy = request.d1Effective.encryptionPolicy =
        MoonlightStreamEncryptionPolicy::Compatible;
    auto capabilities = readyCapabilities();
    capabilities.host.encryptionStreams = MoonlightStreamEncryptVideo;
    const auto result = resolveMoonlightStreamConfig(
        request, capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT(result.ready());
    RDP_ASSERT_EQ(result.offer->requiredEncryptionStreams, 0U);
    RDP_ASSERT_EQ(result.offer->candidateEncryptionStreams,
        static_cast<std::uint32_t>(MoonlightStreamEncryptVideo));
    RDP_ASSERT(result.offer->remoteInputEncryptionRequired);
}

RDP_TEST_CASE(moonlight_product_streaming_policy_rejects_unproven_modes) {
    RDP_ASSERT(moonlightProductStreamingPolicyAllows(
        MoonlightStreamLatencyMode::LowLatency,
        MoonlightStreamEncryptionPolicy::Auto));
    RDP_ASSERT(moonlightProductStreamingPolicyAllows(
        MoonlightStreamLatencyMode::LowLatency,
        MoonlightStreamEncryptionPolicy::Compatible));
    RDP_ASSERT(!moonlightProductStreamingPolicyAllows(
        MoonlightStreamLatencyMode::LowLatency,
        MoonlightStreamEncryptionPolicy::Required));
    RDP_ASSERT(!moonlightProductStreamingPolicyAllows(
        MoonlightStreamLatencyMode::Balanced,
        MoonlightStreamEncryptionPolicy::Auto));
    RDP_ASSERT(!moonlightProductStreamingPolicyAllows(
        MoonlightStreamLatencyMode::Smooth,
        MoonlightStreamEncryptionPolicy::Compatible));

    RDP_ASSERT(moonlightProductAudioContractAllows(
        true, MoonlightStreamAudioLayout::Stereo));
    RDP_ASSERT(moonlightProductAudioContractAllows(
        false, MoonlightStreamAudioLayout::Surround71));
    RDP_ASSERT(!moonlightProductAudioContractAllows(
        true, MoonlightStreamAudioLayout::Surround51));
    RDP_ASSERT(!moonlightProductAudioContractAllows(
        true, MoonlightStreamAudioLayout::Stereo, 393279U));
}

RDP_TEST_CASE(moonlight_product_streaming_maps_dual_stack_winner_to_common_c) {
    MoonlightProductLaunchStage stage;
    stage.key = {91U, 92U, 93U};
    stage.address = "2001:db8::44";
    stage.serverInfo.appVersion = "7.1.0";
    stage.serverInfo.gfeVersion = "3.27";

    MoonlightCommonCRequest common;
    RDP_ASSERT(moonlightProductPopulateCommonCServer(
        common.server, stage,
        profile(MoonlightStreamCodec::H264, MoonlightStreamBitDepth::Bit8,
                MoonlightStreamChroma::Yuv420)));
    RDP_ASSERT(common.server.address == "2001:db8::44");
    RDP_ASSERT(common.server.authenticated);
    RDP_ASSERT_EQ(common.server.hostCapabilityGeneration, 92U);
    RDP_ASSERT_EQ(common.server.codecProfiles.size(), static_cast<std::size_t>(1));
}

RDP_TEST_CASE(moonlight_stream_config_carries_prior_adjustments_without_rewriting_them) {
    auto request = readyRequest();
    request.priorAdjustments.push_back({
        "video.codecPreference", "auto_selected_from_capability_intersection", "auto", "h264"});
    const auto result = resolveMoonlightStreamConfig(
        request, readyCapabilities(), readyIdentity(), NOW_MS);
    RDP_ASSERT(result.ready());
    RDP_ASSERT(result.adjustments.front().field == "video.codecPreference");
    RDP_ASSERT(result.adjustments.front().code ==
        "auto_selected_from_capability_intersection");
}

RDP_TEST_CASE(moonlight_stream_config_rejects_unbounded_prior_adjustments) {
    auto request = readyRequest();
    for (std::size_t index = 0U; index < 65U; ++index) {
        request.priorAdjustments.push_back({"video.fps", "prior", "60", "60"});
    }
    const auto result = resolveMoonlightStreamConfig(
        request, readyCapabilities(), readyIdentity(), NOW_MS);
    RDP_ASSERT_EQ(result.status, MoonlightStreamResultStatus::InvalidRequest);
    RDP_ASSERT_EQ(result.code, MoonlightStreamResultCode::AdjustmentOverflow);
}

RDP_TEST_CASE(moonlight_stream_config_canonical_result_is_repeatable_and_generation_bound) {
    const auto first = resolveMoonlightStreamConfig(
        readyRequest(), readyCapabilities(), readyIdentity(), NOW_MS);
    const auto second = resolveMoonlightStreamConfig(
        readyRequest(), readyCapabilities(), readyIdentity(), NOW_MS);
    RDP_ASSERT(first.ready());
    RDP_ASSERT(moonlightStreamConfigCanonicalResult(first) ==
        moonlightStreamConfigCanonicalResult(second));

    auto identity = readyIdentity();
    identity.settingsRevision++;
    const auto changed = resolveMoonlightStreamConfig(
        readyRequest(), readyCapabilities(), identity, NOW_MS);
    RDP_ASSERT(changed.ready());
    RDP_ASSERT(moonlightStreamConfigCanonicalResult(first) !=
        moonlightStreamConfigCanonicalResult(changed));
}

RDP_TEST_CASE(moonlight_stream_config_deterministic_property_corpus_preserves_invariants) {
    for (std::int32_t index = 0; index < 256; ++index) {
        auto request = readyRequest();
        request.requested.resolutionMode = request.d1Effective.resolutionMode =
            MoonlightStreamResolutionMode::Custom;
        request.requested.customWidth = request.d1Effective.customWidth = 320 + index * 17;
        request.requested.customHeight = request.d1Effective.customHeight = 240 + index * 11;
        request.requested.fps = request.d1Effective.fps = 30 + index % 211;
        request.requested.bitrateKbps = request.d1Effective.bitrateKbps =
            1000 + (index * 733) % 199001;
        request.requested.codecPreference = request.d1Effective.codecPreference =
            static_cast<MoonlightStreamCodecPreference>(index % 4);
        request.requested.hdr = request.d1Effective.hdr = index % 5 == 0;
        request.requested.yuv444 = request.d1Effective.yuv444 = index % 7 == 0;

        auto capabilities = readyCapabilities();
        capabilities.network.path = index % 2 == 0
            ? MoonlightStreamNetworkPath::Local : MoonlightStreamNetworkPath::Remote;
        capabilities.network.safeVideoPacketSizeBytes = 1024 + (index % 32) * 16;
        const auto first = resolveMoonlightStreamConfig(
            request, capabilities, readyIdentity(), NOW_MS);
        const auto second = resolveMoonlightStreamConfig(
            request, capabilities, readyIdentity(), NOW_MS);
        RDP_ASSERT(first.ready());
        RDP_ASSERT(moonlightStreamConfigCanonicalResult(first) ==
            moonlightStreamConfigCanonicalResult(second));
        RDP_ASSERT(first.offer->dimensions.width >= 320);
        RDP_ASSERT(first.offer->dimensions.height >= 240);
        RDP_ASSERT(first.offer->dimensions.width % 2 == 0);
        RDP_ASSERT(first.offer->dimensions.height % 2 == 0);
        RDP_ASSERT(first.offer->configuredBitrateKbps >= 1000);
        RDP_ASSERT(first.offer->estimatedEncoderBitrateKbps <=
            first.offer->configuredBitrateKbps);
        RDP_ASSERT(!first.offer->selectedCodec.has_value());
        RDP_ASSERT(first.launchProjection->controllerBitmap == 0U);
    }
}

RDP_TEST_CASE(moonlight_stream_config_malformed_boundary_corpus_fails_closed) {
    auto request = readyRequest();
    request.d1Effective.bitrateKbps = std::numeric_limits<std::int32_t>::max();
    auto result = resolveMoonlightStreamConfig(
        request, readyCapabilities(), readyIdentity(), NOW_MS);
    RDP_ASSERT_EQ(result.status, MoonlightStreamResultStatus::InvalidRequest);

    auto capabilities = readyCapabilities();
    capabilities.host.codecProfiles.push_back(capabilities.host.codecProfiles.front());
    result = resolveMoonlightStreamConfig(
        readyRequest(), capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT_EQ(result.code, MoonlightStreamResultCode::InvalidCapabilities);

    capabilities = readyCapabilities();
    capabilities.network.safeVideoPacketSizeBytes = std::numeric_limits<std::int32_t>::max();
    result = resolveMoonlightStreamConfig(
        readyRequest(), capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT_EQ(result.code, MoonlightStreamResultCode::InvalidCapabilities);

    capabilities = readyCapabilities();
    capabilities.network.safeVideoPacketSizeBytes = 1451;
    result = resolveMoonlightStreamConfig(
        readyRequest(), capabilities, readyIdentity(), NOW_MS);
    RDP_ASSERT(result.ready());
    RDP_ASSERT_EQ(result.offer->packetSizeBytes, 1440);
    RDP_ASSERT(hasAdjustment(result, "encryption_packet_alignment"));
}

RDP_TEST_CASE(moonlight_stream_config_stable_names_never_claim_negotiation) {
    RDP_ASSERT(std::string(moonlightStreamResultStatusName(
        MoonlightStreamResultStatus::OfferReady)) == "offer_ready");
    RDP_ASSERT(std::string(moonlightStreamResultCodeName(
        MoonlightStreamResultCode::MvpCodecUnavailable)) == "mvp_codec_unavailable");
    RDP_ASSERT(std::string(moonlightStreamCodecName(MoonlightStreamCodec::Hevc)) == "hevc");
}
