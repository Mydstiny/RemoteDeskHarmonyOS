#include "MoonlightStreamConfig.h"

#include <algorithm>
#include <array>
#include <limits>
#include <utility>

namespace remotedesk::moonlight {
namespace {

constexpr std::size_t kMaxPriorAdjustments = 64U;
constexpr std::size_t kMaxResultAdjustments = 96U;
constexpr std::size_t kMaxAdjustmentText = 128U;
constexpr std::size_t kMaxIdentityText = 128U;
constexpr std::size_t kMaxEvidenceVersion = 64U;
constexpr std::size_t kMaxCodecProfiles = 32U;
constexpr std::int32_t kMinimumWidth = 320;
constexpr std::int32_t kMaximumWidth = 7680;
constexpr std::int32_t kMinimumHeight = 240;
constexpr std::int32_t kMaximumHeight = 4320;
constexpr std::int32_t kMinimumFps = 30;
constexpr std::int32_t kMaximumFps = 240;
constexpr std::int32_t kMinimumBitrateKbps = 1000;
constexpr std::int32_t kMaximumBitrateKbps = 200000;
constexpr std::int32_t kH264MaximumDimension = 4096;
constexpr std::int32_t kConservativePacketSizeBytes = 1024;
constexpr std::int32_t kMaximumProvenPacketSizeBytes = 4096;
constexpr std::int32_t kHighQualityAudioThresholdKbps = 15000;
constexpr std::uint32_t kKnownEncryptionStreams =
    MoonlightStreamEncryptAudio | MoonlightStreamEncryptVideo;

enum class EvidenceDecision : std::uint8_t {
    Supported,
    Pending,
    Unsupported,
    Stale,
    Invalid,
};

bool isBoundedText(const std::string& value, std::size_t minimum, std::size_t maximum) {
    if (value.size() < minimum || value.size() > maximum) {
        return false;
    }
    return std::all_of(value.begin(), value.end(), [](unsigned char character) {
        return character >= 0x20U && character != 0x7fU;
    });
}

bool validCodecPreference(MoonlightStreamCodecPreference value) {
    switch (value) {
        case MoonlightStreamCodecPreference::Auto:
        case MoonlightStreamCodecPreference::H264:
        case MoonlightStreamCodecPreference::Hevc:
        case MoonlightStreamCodecPreference::Av1:
            return true;
    }
    return false;
}

bool validCodec(MoonlightStreamCodec value) {
    switch (value) {
        case MoonlightStreamCodec::H264:
        case MoonlightStreamCodec::Hevc:
        case MoonlightStreamCodec::Av1:
            return true;
    }
    return false;
}

bool validResolutionMode(MoonlightStreamResolutionMode value) {
    switch (value) {
        case MoonlightStreamResolutionMode::Host:
        case MoonlightStreamResolutionMode::P720:
        case MoonlightStreamResolutionMode::P1080:
        case MoonlightStreamResolutionMode::P1440:
        case MoonlightStreamResolutionMode::P2160:
        case MoonlightStreamResolutionMode::Custom:
            return true;
    }
    return false;
}

bool validBitDepth(MoonlightStreamBitDepth value) {
    return value == MoonlightStreamBitDepth::Bit8 || value == MoonlightStreamBitDepth::Bit10;
}

bool validChroma(MoonlightStreamChroma value) {
    return value == MoonlightStreamChroma::Yuv420 || value == MoonlightStreamChroma::Yuv444;
}

bool validLatencyMode(MoonlightStreamLatencyMode value) {
    switch (value) {
        case MoonlightStreamLatencyMode::LowLatency:
        case MoonlightStreamLatencyMode::Balanced:
        case MoonlightStreamLatencyMode::Smooth:
            return true;
    }
    return false;
}

bool validAudioLayout(MoonlightStreamAudioLayout value) {
    switch (value) {
        case MoonlightStreamAudioLayout::Disabled:
        case MoonlightStreamAudioLayout::Stereo:
        case MoonlightStreamAudioLayout::Surround51:
        case MoonlightStreamAudioLayout::Surround71:
            return true;
    }
    return false;
}

bool validEncryptionPolicy(MoonlightStreamEncryptionPolicy value) {
    switch (value) {
        case MoonlightStreamEncryptionPolicy::Auto:
        case MoonlightStreamEncryptionPolicy::Required:
        case MoonlightStreamEncryptionPolicy::Compatible:
            return true;
    }
    return false;
}

bool validMeteredPolicy(MoonlightStreamMeteredPolicy value) {
    switch (value) {
        case MoonlightStreamMeteredPolicy::Ask:
        case MoonlightStreamMeteredPolicy::Allow:
        case MoonlightStreamMeteredPolicy::Deny:
            return true;
    }
    return false;
}

bool validCapabilityStatus(MoonlightStreamCapabilityStatus value) {
    switch (value) {
        case MoonlightStreamCapabilityStatus::Pending:
        case MoonlightStreamCapabilityStatus::Supported:
        case MoonlightStreamCapabilityStatus::Unsupported:
            return true;
    }
    return false;
}

bool validCapabilitySource(MoonlightStreamCapabilitySource value) {
    switch (value) {
        case MoonlightStreamCapabilitySource::Host:
        case MoonlightStreamCapabilitySource::PlatformProbe:
        case MoonlightStreamCapabilitySource::NetworkProbe:
        case MoonlightStreamCapabilitySource::DisplayProbe:
            return true;
    }
    return false;
}

bool validNetworkPath(MoonlightStreamNetworkPath value) {
    switch (value) {
        case MoonlightStreamNetworkPath::Unknown:
        case MoonlightStreamNetworkPath::Local:
        case MoonlightStreamNetworkPath::Remote:
            return true;
    }
    return false;
}

bool validAddressFamily(MoonlightStreamAddressFamily value) {
    switch (value) {
        case MoonlightStreamAddressFamily::Unknown:
        case MoonlightStreamAddressFamily::Ipv4:
        case MoonlightStreamAddressFamily::Ipv6:
            return true;
    }
    return false;
}

bool validMeteredState(MoonlightStreamMeteredState value) {
    switch (value) {
        case MoonlightStreamMeteredState::Unknown:
        case MoonlightStreamMeteredState::Unmetered:
        case MoonlightStreamMeteredState::Metered:
            return true;
    }
    return false;
}

bool validSettings(const MoonlightStreamSettings& settings) {
    return settings.schemaVersion == 1U && validCodecPreference(settings.codecPreference) &&
        validResolutionMode(settings.resolutionMode) &&
        settings.customWidth >= kMinimumWidth && settings.customWidth <= kMaximumWidth &&
        settings.customHeight >= kMinimumHeight && settings.customHeight <= kMaximumHeight &&
        settings.fps >= kMinimumFps && settings.fps <= kMaximumFps &&
        settings.bitrateKbps >= kMinimumBitrateKbps &&
        settings.bitrateKbps <= kMaximumBitrateKbps &&
        validLatencyMode(settings.latencyMode) && validAudioLayout(settings.audioLayout) &&
        validEncryptionPolicy(settings.encryptionPolicy) &&
        validMeteredPolicy(settings.meteredPolicy) &&
        ((settings.audioEnabled && settings.audioLayout != MoonlightStreamAudioLayout::Disabled) ||
         (!settings.audioEnabled && settings.audioLayout == MoonlightStreamAudioLayout::Disabled));
}

bool validAdjustment(const MoonlightStreamAdjustment& adjustment) {
    return isBoundedText(adjustment.field, 1U, kMaxAdjustmentText) &&
        isBoundedText(adjustment.code, 1U, kMaxAdjustmentText) &&
        isBoundedText(adjustment.requested, 0U, kMaxAdjustmentText) &&
        isBoundedText(adjustment.effective, 0U, kMaxAdjustmentText);
}

bool validIdentity(const MoonlightStreamConfigIdentity& identity) {
    return identity.ownerToken != 0U && identity.sessionGeneration != 0U &&
        identity.settingsRevision != 0U && identity.hostCapabilityGeneration != 0U &&
        identity.platformProbeGeneration != 0U && identity.networkCapabilityGeneration != 0U &&
        identity.displayCapabilityGeneration != 0U &&
        isBoundedText(identity.hostId, 1U, kMaxIdentityText) &&
        isBoundedText(identity.serverUuid, 1U, kMaxIdentityText);
}

bool validProfile(const MoonlightStreamCodecProfile& profile) {
    if (!validCodec(profile.codec) || !validBitDepth(profile.bitDepth) ||
        !validChroma(profile.chroma)) {
        return false;
    }
    // H.264 10-bit is not an official common-c offer profile in the pinned tree.
    return profile.codec != MoonlightStreamCodec::H264 ||
        profile.bitDepth == MoonlightStreamBitDepth::Bit8;
}

bool sameProfile(
    const MoonlightStreamCodecProfile& left, const MoonlightStreamCodecProfile& right) {
    return left.codec == right.codec && left.bitDepth == right.bitDepth &&
        left.chroma == right.chroma;
}

bool validProfiles(const std::vector<MoonlightStreamCodecProfile>& profiles) {
    if (profiles.size() > kMaxCodecProfiles) {
        return false;
    }
    for (std::size_t index = 0U; index < profiles.size(); ++index) {
        if (!validProfile(profiles[index])) {
            return false;
        }
        for (std::size_t other = index + 1U; other < profiles.size(); ++other) {
            if (sameProfile(profiles[index], profiles[other])) {
                return false;
            }
        }
    }
    return true;
}

bool validEvidenceShape(const MoonlightStreamCapabilityEvidence& evidence) {
    return validCapabilityStatus(evidence.status) && validCapabilitySource(evidence.source) &&
        isBoundedText(evidence.version, 1U, kMaxEvidenceVersion) && evidence.generation != 0U &&
        evidence.expiresAtMonotonicMs != 0U;
}

EvidenceDecision decideEvidence(
    const MoonlightStreamCapabilityEvidence& evidence,
    MoonlightStreamCapabilitySource expectedSource, std::uint64_t expectedGeneration,
    std::uint64_t nowMonotonicMs) {
    if (!validEvidenceShape(evidence)) {
        return EvidenceDecision::Invalid;
    }
    if (evidence.source != expectedSource || evidence.generation != expectedGeneration ||
        evidence.expiresAtMonotonicMs <= nowMonotonicMs) {
        return EvidenceDecision::Stale;
    }
    switch (evidence.status) {
        case MoonlightStreamCapabilityStatus::Supported:
            return EvidenceDecision::Supported;
        case MoonlightStreamCapabilityStatus::Pending:
            return EvidenceDecision::Pending;
        case MoonlightStreamCapabilityStatus::Unsupported:
            return EvidenceDecision::Unsupported;
    }
    return EvidenceDecision::Invalid;
}

bool validCapabilityPayload(const MoonlightStreamCapabilitySnapshot& capabilities) {
    const auto& host = capabilities.host;
    const auto& platform = capabilities.platform;
    const auto& network = capabilities.network;
    const auto& display = capabilities.display;
    const auto boundedDimension = [](std::int32_t value, std::int32_t maximum) {
        return value >= 0 && value <= maximum;
    };
    if (!boundedDimension(host.maxWidth, 32768) || !boundedDimension(host.maxHeight, 32768) ||
        !boundedDimension(platform.maxWidth, 32768) ||
        !boundedDimension(platform.maxHeight, 32768) ||
        !boundedDimension(display.maxWidth, 32768) || !boundedDimension(display.maxHeight, 32768) ||
        !boundedDimension(host.maxFps, 1000) || !boundedDimension(platform.maxFps, 1000) ||
        !boundedDimension(display.maxFps, 1000) || host.maxEncoderBitrateKbps < 0 ||
        platform.maxDecodeBitrateKbps < 0 || platform.maxThermalBitrateKbps < 0 ||
        network.maxBitrateKbps < 0 || !validProfiles(host.codecProfiles) ||
        !validProfiles(platform.decoderProfiles) || !validNetworkPath(network.path) ||
        !validAddressFamily(network.addressFamily) || !validMeteredState(network.metered) ||
        network.safeVideoPacketSizeBytes < 0 ||
        (host.encryptionStreams & ~kKnownEncryptionStreams) != 0U ||
        (platform.commonCEncryptionStreams & ~kKnownEncryptionStreams) != 0U) {
        return false;
    }
    if (host.recommendedMode.has_value() &&
        (host.recommendedMode->width <= 0 || host.recommendedMode->width > 32768 ||
         host.recommendedMode->height <= 0 || host.recommendedMode->height > 32768)) {
        return false;
    }
    if (network.mtuReceiptAvailable &&
        (network.safeVideoPacketSizeBytes < kConservativePacketSizeBytes ||
         network.safeVideoPacketSizeBytes > kMaximumProvenPacketSizeBytes)) {
        return false;
    }
    if (display.refreshRateX100.has_value() &&
        (*display.refreshRateX100 <= 0 || *display.refreshRateX100 > 100000)) {
        return false;
    }
    return true;
}

MoonlightStreamConfigResult terminal(
    const MoonlightStreamConfigIdentity& identity, MoonlightStreamResultStatus status,
    MoonlightStreamResultCode code, std::vector<MoonlightStreamAdjustment> adjustments = {}) {
    MoonlightStreamConfigResult result;
    result.status = status;
    result.code = code;
    result.identity = identity;
    result.adjustments = std::move(adjustments);
    return result;
}

const char* codecPreferenceName(MoonlightStreamCodecPreference preference) {
    switch (preference) {
        case MoonlightStreamCodecPreference::Auto: return "auto";
        case MoonlightStreamCodecPreference::H264: return "h264";
        case MoonlightStreamCodecPreference::Hevc: return "hevc";
        case MoonlightStreamCodecPreference::Av1: return "av1";
    }
    return "unknown";
}

const char* audioLayoutName(MoonlightStreamAudioLayout layout) {
    switch (layout) {
        case MoonlightStreamAudioLayout::Disabled: return "disabled";
        case MoonlightStreamAudioLayout::Stereo: return "stereo";
        case MoonlightStreamAudioLayout::Surround51: return "surround51";
        case MoonlightStreamAudioLayout::Surround71: return "surround71";
    }
    return "unknown";
}

bool addAdjustment(
    std::vector<MoonlightStreamAdjustment>& adjustments, std::string field, std::string code,
    std::string requested, std::string effective) {
    if (adjustments.size() >= kMaxResultAdjustments) {
        return false;
    }
    MoonlightStreamAdjustment adjustment {
        std::move(field), std::move(code), std::move(requested), std::move(effective),
    };
    if (!validAdjustment(adjustment)) {
        return false;
    }
    adjustments.push_back(std::move(adjustment));
    return true;
}

std::vector<MoonlightStreamCodecProfile> intersectProfiles(
    const std::vector<MoonlightStreamCodecProfile>& host,
    const std::vector<MoonlightStreamCodecProfile>& platform) {
    std::vector<MoonlightStreamCodecProfile> result;
    for (const auto& candidate : host) {
        if (std::any_of(platform.begin(), platform.end(), [&](const auto& decoder) {
                return sameProfile(candidate, decoder);
            })) {
            result.push_back(candidate);
        }
    }
    return result;
}

bool hasCodec(
    const std::vector<MoonlightStreamCodecProfile>& profiles, MoonlightStreamCodec codec) {
    return std::any_of(profiles.begin(), profiles.end(), [&](const auto& profile) {
        return profile.codec == codec;
    });
}

bool profileSupportsIntent(
    const MoonlightStreamCodecProfile& profile, bool hdr, bool yuv444) {
    if (hdr) {
        if (profile.codec == MoonlightStreamCodec::H264 ||
            profile.bitDepth != MoonlightStreamBitDepth::Bit10) {
            return false;
        }
    } else if (profile.bitDepth != MoonlightStreamBitDepth::Bit8) {
        return false;
    }
    return profile.chroma ==
        (yuv444 ? MoonlightStreamChroma::Yuv444 : MoonlightStreamChroma::Yuv420);
}

MoonlightStreamCodec preferenceCodec(MoonlightStreamCodecPreference preference) {
    switch (preference) {
        case MoonlightStreamCodecPreference::H264: return MoonlightStreamCodec::H264;
        case MoonlightStreamCodecPreference::Hevc: return MoonlightStreamCodec::Hevc;
        case MoonlightStreamCodecPreference::Av1: return MoonlightStreamCodec::Av1;
        case MoonlightStreamCodecPreference::Auto: return MoonlightStreamCodec::H264;
    }
    return MoonlightStreamCodec::H264;
}

int codecPriority(MoonlightStreamCodec codec) {
    switch (codec) {
        case MoonlightStreamCodec::Av1: return 0;
        case MoonlightStreamCodec::Hevc: return 1;
        case MoonlightStreamCodec::H264: return 2;
    }
    return 3;
}

bool sameOffered(const MoonlightOfferedCodec& left, const MoonlightOfferedCodec& right) {
    return left.codec == right.codec && left.bitDepth == right.bitDepth &&
        left.chroma == right.chroma;
}

MoonlightOfferedCodec offeredFrom(
    const MoonlightStreamCodecProfile& profile, bool hdr, bool yuv444) {
    return {
        profile.codec,
        profile.bitDepth,
        profile.chroma,
        false,
        !hdr || (profile.codec != MoonlightStreamCodec::H264 &&
                 profile.bitDepth == MoonlightStreamBitDepth::Bit10),
        !yuv444 || profile.chroma == MoonlightStreamChroma::Yuv444,
    };
}

std::optional<MoonlightStreamCodecProfile> safeH264Fallback(
    const std::vector<MoonlightStreamCodecProfile>& profiles, bool preferYuv444) {
    const auto preferredChroma = preferYuv444
        ? MoonlightStreamChroma::Yuv444 : MoonlightStreamChroma::Yuv420;
    const auto exact = std::find_if(profiles.begin(), profiles.end(), [&](const auto& profile) {
        return profile.codec == MoonlightStreamCodec::H264 &&
            profile.bitDepth == MoonlightStreamBitDepth::Bit8 && profile.chroma == preferredChroma;
    });
    if (exact != profiles.end()) {
        return *exact;
    }
    const auto conservative = std::find_if(profiles.begin(), profiles.end(), [](const auto& profile) {
        return profile.codec == MoonlightStreamCodec::H264 &&
            profile.bitDepth == MoonlightStreamBitDepth::Bit8 &&
            profile.chroma == MoonlightStreamChroma::Yuv420;
    });
    if (conservative != profiles.end()) {
        return *conservative;
    }
    return std::nullopt;
}

std::optional<MoonlightStreamDimensions> requestedDimensions(
    const MoonlightStreamSettings& settings,
    const MoonlightHostStreamCapabilities& host) {
    switch (settings.resolutionMode) {
        case MoonlightStreamResolutionMode::Host:
            return host.recommendedMode;
        case MoonlightStreamResolutionMode::P720:
            return MoonlightStreamDimensions {1280, 720};
        case MoonlightStreamResolutionMode::P1080:
            return MoonlightStreamDimensions {1920, 1080};
        case MoonlightStreamResolutionMode::P1440:
            return MoonlightStreamDimensions {2560, 1440};
        case MoonlightStreamResolutionMode::P2160:
            return MoonlightStreamDimensions {3840, 2160};
        case MoonlightStreamResolutionMode::Custom:
            return MoonlightStreamDimensions {settings.customWidth, settings.customHeight};
    }
    return std::nullopt;
}

MoonlightStreamDimensions scaleToFit(
    MoonlightStreamDimensions dimensions, std::int32_t maxWidth, std::int32_t maxHeight) {
    if (dimensions.width <= maxWidth && dimensions.height <= maxHeight) {
        return dimensions;
    }
    const std::int64_t widthLimitedHeight =
        static_cast<std::int64_t>(dimensions.height) * maxWidth / dimensions.width;
    const std::int64_t heightLimitedWidth =
        static_cast<std::int64_t>(dimensions.width) * maxHeight / dimensions.height;
    if (widthLimitedHeight <= maxHeight) {
        dimensions.width = maxWidth;
        dimensions.height = static_cast<std::int32_t>(widthLimitedHeight);
    } else {
        dimensions.width = static_cast<std::int32_t>(heightLimitedWidth);
        dimensions.height = maxHeight;
    }
    return dimensions;
}

std::int32_t boundedMinimum(std::initializer_list<std::int32_t> values) {
    return *std::min_element(values.begin(), values.end());
}

MoonlightStreamConfigResult resolveImpl(
    const MoonlightRequestedStreamConfig& requested,
    const MoonlightStreamCapabilitySnapshot& capabilities,
    const MoonlightStreamConfigIdentity& identity,
    std::uint64_t nowMonotonicMs) {
    if (!validIdentity(identity)) {
        return terminal(identity, MoonlightStreamResultStatus::InvalidRequest,
                        MoonlightStreamResultCode::InvalidIdentity);
    }
    if (requested.priorAdjustments.size() > kMaxPriorAdjustments) {
        return terminal(identity, MoonlightStreamResultStatus::InvalidRequest,
                        MoonlightStreamResultCode::AdjustmentOverflow);
    }
    if (!validSettings(requested.requested) || !validSettings(requested.d1Effective) ||
        !std::all_of(requested.priorAdjustments.begin(), requested.priorAdjustments.end(),
                     validAdjustment)) {
        return terminal(identity, MoonlightStreamResultStatus::InvalidRequest,
                        MoonlightStreamResultCode::InvalidSettings);
    }

    std::vector<MoonlightStreamAdjustment> adjustments = requested.priorAdjustments;
    if (!validCapabilityPayload(capabilities)) {
        return terminal(identity, MoonlightStreamResultStatus::InvalidRequest,
                        MoonlightStreamResultCode::InvalidCapabilities, std::move(adjustments));
    }

    const std::array<EvidenceDecision, 4U> evidenceDecisions {
        decideEvidence(capabilities.host.evidence, MoonlightStreamCapabilitySource::Host,
                       identity.hostCapabilityGeneration, nowMonotonicMs),
        decideEvidence(capabilities.platform.evidence,
                       MoonlightStreamCapabilitySource::PlatformProbe,
                       identity.platformProbeGeneration, nowMonotonicMs),
        decideEvidence(capabilities.network.evidence,
                       MoonlightStreamCapabilitySource::NetworkProbe,
                       identity.networkCapabilityGeneration, nowMonotonicMs),
        decideEvidence(capabilities.display.evidence,
                       MoonlightStreamCapabilitySource::DisplayProbe,
                       identity.displayCapabilityGeneration, nowMonotonicMs),
    };
    if (std::find(evidenceDecisions.begin(), evidenceDecisions.end(), EvidenceDecision::Invalid) !=
        evidenceDecisions.end()) {
        return terminal(identity, MoonlightStreamResultStatus::InvalidRequest,
                        MoonlightStreamResultCode::InvalidCapabilities, std::move(adjustments));
    }
    if (std::find(evidenceDecisions.begin(), evidenceDecisions.end(), EvidenceDecision::Stale) !=
        evidenceDecisions.end()) {
        return terminal(identity, MoonlightStreamResultStatus::CapabilityPending,
                        MoonlightStreamResultCode::CapabilityStale, std::move(adjustments));
    }
    if (std::find(evidenceDecisions.begin(), evidenceDecisions.end(), EvidenceDecision::Pending) !=
        evidenceDecisions.end()) {
        return terminal(identity, MoonlightStreamResultStatus::CapabilityPending,
                        MoonlightStreamResultCode::CapabilityPending, std::move(adjustments));
    }
    if (std::find(evidenceDecisions.begin(), evidenceDecisions.end(), EvidenceDecision::Unsupported) !=
        evidenceDecisions.end()) {
        return terminal(identity, MoonlightStreamResultStatus::Rejected,
                        MoonlightStreamResultCode::CapabilityUnsupported, std::move(adjustments));
    }

    if (capabilities.network.path == MoonlightStreamNetworkPath::Unknown ||
        capabilities.network.addressFamily == MoonlightStreamAddressFamily::Unknown) {
        return terminal(identity, MoonlightStreamResultStatus::CapabilityPending,
                        MoonlightStreamResultCode::NetworkPathPending, std::move(adjustments));
    }
    if (capabilities.network.metered == MoonlightStreamMeteredState::Unknown) {
        return terminal(identity, MoonlightStreamResultStatus::CapabilityPending,
                        MoonlightStreamResultCode::CapabilityPending, std::move(adjustments));
    }
    if (capabilities.network.metered == MoonlightStreamMeteredState::Metered) {
        if (requested.d1Effective.meteredPolicy == MoonlightStreamMeteredPolicy::Deny) {
            return terminal(identity, MoonlightStreamResultStatus::Rejected,
                            MoonlightStreamResultCode::MeteredNetworkDenied,
                            std::move(adjustments));
        }
        if (requested.d1Effective.meteredPolicy == MoonlightStreamMeteredPolicy::Ask &&
            !capabilities.network.userConfirmedMetered) {
            return terminal(identity, MoonlightStreamResultStatus::ConfirmationRequired,
                            MoonlightStreamResultCode::MeteredConfirmationRequired,
                            std::move(adjustments));
        }
    }

    const auto profileIntersection = intersectProfiles(
        capabilities.host.codecProfiles, capabilities.platform.decoderProfiles);
    if (!hasCodec(profileIntersection, MoonlightStreamCodec::H264)) {
        return terminal(identity, MoonlightStreamResultStatus::Rejected,
                        MoonlightStreamResultCode::MvpCodecUnavailable, std::move(adjustments));
    }

    bool effectiveHdr = requested.d1Effective.hdr;
    bool effectiveYuv444 = requested.d1Effective.yuv444;
    if (requested.d1Effective.codecPreference == MoonlightStreamCodecPreference::H264 &&
        effectiveHdr) {
        effectiveHdr = false;
        if (!addAdjustment(adjustments, "video.hdr", "hdr_pipeline_unavailable", "true", "false")) {
            return terminal(identity, MoonlightStreamResultStatus::InvalidRequest,
                            MoonlightStreamResultCode::AdjustmentOverflow);
        }
    }

    const auto hasAdvancedHdrProfile = [&](bool requireYuv444) {
        return std::any_of(profileIntersection.begin(), profileIntersection.end(),
            [&](const auto& profile) {
                return profile.codec != MoonlightStreamCodec::H264 &&
                    profile.bitDepth == MoonlightStreamBitDepth::Bit10 &&
                    (!requireYuv444 || profile.chroma == MoonlightStreamChroma::Yuv444);
            });
    };
    const bool hdrPipeline = capabilities.host.hdr && capabilities.display.hdr &&
        capabilities.display.surfaceHdr && capabilities.display.pipHdr &&
        capabilities.host.rec2020Limited && capabilities.display.rec2020Limited &&
        hasAdvancedHdrProfile(effectiveYuv444);
    if (effectiveHdr && !hdrPipeline) {
        effectiveHdr = false;
        if (!addAdjustment(adjustments, "video.hdr", "hdr_pipeline_unavailable", "true", "false")) {
            return terminal(identity, MoonlightStreamResultStatus::InvalidRequest,
                            MoonlightStreamResultCode::AdjustmentOverflow);
        }
    }

    const bool yuvPipeline = capabilities.host.yuv444 && capabilities.platform.rendererYuv444 &&
        capabilities.display.yuv444 &&
        std::any_of(profileIntersection.begin(), profileIntersection.end(), [&](const auto& profile) {
            return profile.chroma == MoonlightStreamChroma::Yuv444 &&
                (!effectiveHdr || (profile.codec != MoonlightStreamCodec::H264 &&
                                   profile.bitDepth == MoonlightStreamBitDepth::Bit10));
        });
    if (effectiveYuv444 && !yuvPipeline) {
        effectiveYuv444 = false;
        if (!addAdjustment(adjustments, "video.yuv444", "yuv444_pipeline_unavailable",
                           "true", "false")) {
            return terminal(identity, MoonlightStreamResultStatus::InvalidRequest,
                            MoonlightStreamResultCode::AdjustmentOverflow);
        }
    }

    std::vector<MoonlightOfferedCodec> offeredCodecs;
    const auto forcedPreference = requested.d1Effective.codecPreference;
    const auto forcedCodec = preferenceCodec(forcedPreference);
    for (const auto& profile : profileIntersection) {
        if (!profileSupportsIntent(profile, effectiveHdr, effectiveYuv444)) {
            continue;
        }
        if (forcedPreference != MoonlightStreamCodecPreference::Auto && profile.codec != forcedCodec) {
            continue;
        }
        offeredCodecs.push_back(offeredFrom(profile, effectiveHdr, effectiveYuv444));
    }

    if (offeredCodecs.empty() && forcedPreference != MoonlightStreamCodecPreference::Auto) {
        if (!addAdjustment(adjustments, "video.codecPreference", "requested_codec_unavailable",
                           codecPreferenceName(forcedPreference), "h264")) {
            return terminal(identity, MoonlightStreamResultStatus::InvalidRequest,
                            MoonlightStreamResultCode::AdjustmentOverflow);
        }
        if (effectiveHdr) {
            effectiveHdr = false;
            if (!addAdjustment(adjustments, "video.hdr", "hdr_pipeline_unavailable",
                               "true", "false")) {
                return terminal(identity, MoonlightStreamResultStatus::InvalidRequest,
                                MoonlightStreamResultCode::AdjustmentOverflow);
            }
        }
        const auto fallback = safeH264Fallback(profileIntersection, effectiveYuv444);
        if (!fallback.has_value()) {
            return terminal(identity, MoonlightStreamResultStatus::Rejected,
                            MoonlightStreamResultCode::MvpCodecUnavailable,
                            std::move(adjustments));
        }
        if (effectiveYuv444 && fallback->chroma != MoonlightStreamChroma::Yuv444) {
            effectiveYuv444 = false;
            if (!addAdjustment(adjustments, "video.yuv444", "yuv444_pipeline_unavailable",
                               "true", "false")) {
                return terminal(identity, MoonlightStreamResultStatus::InvalidRequest,
                                MoonlightStreamResultCode::AdjustmentOverflow);
            }
        }
        offeredCodecs.push_back(offeredFrom(*fallback, effectiveHdr, effectiveYuv444));
    }

    const auto h264Fallback = safeH264Fallback(profileIntersection, effectiveYuv444);
    if (!h264Fallback.has_value()) {
        return terminal(identity, MoonlightStreamResultStatus::Rejected,
                        MoonlightStreamResultCode::MvpCodecUnavailable, std::move(adjustments));
    }
    MoonlightOfferedCodec fallbackOffer = offeredFrom(
        *h264Fallback, effectiveHdr, effectiveYuv444);
    if (std::none_of(offeredCodecs.begin(), offeredCodecs.end(), [&](const auto& offered) {
            return sameOffered(offered, fallbackOffer);
        })) {
        offeredCodecs.push_back(fallbackOffer);
    }
    if (offeredCodecs.empty()) {
        return terminal(identity, MoonlightStreamResultStatus::Rejected,
                        MoonlightStreamResultCode::NoCompatibleCodecProfile,
                        std::move(adjustments));
    }
    std::stable_sort(offeredCodecs.begin(), offeredCodecs.end(), [](const auto& left, const auto& right) {
        const auto leftPriority = codecPriority(left.codec);
        const auto rightPriority = codecPriority(right.codec);
        if (leftPriority != rightPriority) {
            return leftPriority < rightPriority;
        }
        if (left.bitDepth != right.bitDepth) {
            return left.bitDepth == MoonlightStreamBitDepth::Bit10;
        }
        return left.chroma == MoonlightStreamChroma::Yuv444 &&
            right.chroma != MoonlightStreamChroma::Yuv444;
    });
    offeredCodecs.front().preferred = true;

    const auto rawDimensions = requestedDimensions(requested.d1Effective, capabilities.host);
    if (!rawDimensions.has_value()) {
        return terminal(identity, MoonlightStreamResultStatus::CapabilityPending,
                        requested.d1Effective.resolutionMode == MoonlightStreamResolutionMode::Host
                            ? MoonlightStreamResultCode::HostModePending
                            : MoonlightStreamResultCode::CapabilityPending,
                        std::move(adjustments));
    }
    const auto runtimeMaxWidth = boundedMinimum({
        capabilities.host.maxWidth, capabilities.platform.maxWidth, capabilities.display.maxWidth});
    const auto runtimeMaxHeight = boundedMinimum({
        capabilities.host.maxHeight, capabilities.platform.maxHeight, capabilities.display.maxHeight});
    if (runtimeMaxWidth <= 0 || runtimeMaxHeight <= 0) {
        return terminal(identity, MoonlightStreamResultStatus::CapabilityPending,
                        MoonlightStreamResultCode::CapabilityPending, std::move(adjustments));
    }
    const bool onlyH264 = std::all_of(offeredCodecs.begin(), offeredCodecs.end(), [](const auto& item) {
        return item.codec == MoonlightStreamCodec::H264;
    });
    const auto effectiveMaxWidth = onlyH264
        ? std::min(runtimeMaxWidth, kH264MaximumDimension) : runtimeMaxWidth;
    const auto effectiveMaxHeight = onlyH264
        ? std::min(runtimeMaxHeight, kH264MaximumDimension) : runtimeMaxHeight;
    auto dimensions = scaleToFit(*rawDimensions, effectiveMaxWidth, effectiveMaxHeight);
    if (dimensions.width != rawDimensions->width || dimensions.height != rawDimensions->height) {
        const bool h264Limited = onlyH264 &&
            (runtimeMaxWidth > kH264MaximumDimension || runtimeMaxHeight > kH264MaximumDimension) &&
            (rawDimensions->width > kH264MaximumDimension ||
             rawDimensions->height > kH264MaximumDimension);
        if (!addAdjustment(adjustments, "video.dimensions",
                           h264Limited ? "h264_dimension_limit" : "runtime_dimension_limit",
                           std::to_string(rawDimensions->width) + "x" +
                               std::to_string(rawDimensions->height),
                           std::to_string(dimensions.width) + "x" +
                               std::to_string(dimensions.height))) {
            return terminal(identity, MoonlightStreamResultStatus::InvalidRequest,
                            MoonlightStreamResultCode::AdjustmentOverflow);
        }
    }
    const auto preAlignment = dimensions;
    dimensions.width -= dimensions.width % 2;
    dimensions.height -= dimensions.height % 2;
    if (dimensions.width != preAlignment.width || dimensions.height != preAlignment.height) {
        if (!addAdjustment(adjustments, "video.dimensions", "codec_chroma_alignment",
                           std::to_string(preAlignment.width) + "x" +
                               std::to_string(preAlignment.height),
                           std::to_string(dimensions.width) + "x" +
                               std::to_string(dimensions.height))) {
            return terminal(identity, MoonlightStreamResultStatus::InvalidRequest,
                            MoonlightStreamResultCode::AdjustmentOverflow);
        }
    }
    if (dimensions.width < kMinimumWidth || dimensions.height < kMinimumHeight) {
        return terminal(identity, MoonlightStreamResultStatus::Rejected,
                        MoonlightStreamResultCode::DimensionUnsupported,
                        std::move(adjustments));
    }

    const auto runtimeMaxFps = boundedMinimum({
        capabilities.host.maxFps, capabilities.platform.maxFps, capabilities.display.maxFps});
    if (runtimeMaxFps <= 0) {
        return terminal(identity, MoonlightStreamResultStatus::CapabilityPending,
                        MoonlightStreamResultCode::CapabilityPending, std::move(adjustments));
    }
    if (runtimeMaxFps < kMinimumFps) {
        return terminal(identity, MoonlightStreamResultStatus::Rejected,
                        MoonlightStreamResultCode::CapabilityUnsupported,
                        std::move(adjustments));
    }
    const auto effectiveFps = std::min(requested.d1Effective.fps, runtimeMaxFps);
    if (effectiveFps != requested.d1Effective.fps &&
        !addAdjustment(adjustments, "video.fps", "runtime_fps_limit",
                       std::to_string(requested.d1Effective.fps), std::to_string(effectiveFps))) {
        return terminal(identity, MoonlightStreamResultStatus::InvalidRequest,
                        MoonlightStreamResultCode::AdjustmentOverflow);
    }

    if (capabilities.host.maxEncoderBitrateKbps <= 0 ||
        capabilities.platform.maxDecodeBitrateKbps <= 0 ||
        capabilities.platform.maxThermalBitrateKbps <= 0 ||
        capabilities.network.maxBitrateKbps <= 0) {
        return terminal(identity, MoonlightStreamResultStatus::CapabilityPending,
                        MoonlightStreamResultCode::BitrateCapabilityPending,
                        std::move(adjustments));
    }
    const auto bitrateLimit = boundedMinimum({
        capabilities.host.maxEncoderBitrateKbps,
        capabilities.platform.maxDecodeBitrateKbps,
        capabilities.platform.maxThermalBitrateKbps,
        capabilities.network.maxBitrateKbps,
    });
    if (bitrateLimit < kMinimumBitrateKbps) {
        return terminal(identity, MoonlightStreamResultStatus::Rejected,
                        MoonlightStreamResultCode::CapabilityUnsupported,
                        std::move(adjustments));
    }
    const auto configuredBitrate = std::min(requested.d1Effective.bitrateKbps, bitrateLimit);
    if (configuredBitrate != requested.d1Effective.bitrateKbps &&
        !addAdjustment(adjustments, "video.bitrateKbps", "runtime_bitrate_limit",
                       std::to_string(requested.d1Effective.bitrateKbps),
                       std::to_string(configuredBitrate))) {
        return terminal(identity, MoonlightStreamResultStatus::InvalidRequest,
                        MoonlightStreamResultCode::AdjustmentOverflow);
    }
    const std::int64_t estimatedEncoder =
        static_cast<std::int64_t>(configuredBitrate) * 80LL / 100LL;
    if (estimatedEncoder > std::numeric_limits<std::int32_t>::max()) {
        return terminal(identity, MoonlightStreamResultStatus::InvalidRequest,
                        MoonlightStreamResultCode::InvalidSettings, std::move(adjustments));
    }

    MoonlightStreamAudioLayout effectiveAudio = requested.d1Effective.audioLayout;
    if (!requested.d1Effective.audioEnabled) {
        if (!capabilities.platform.audioDiscardPath) {
            return terminal(identity, MoonlightStreamResultStatus::CapabilityPending,
                            MoonlightStreamResultCode::AudioDisablePathPending,
                            std::move(adjustments));
        }
        effectiveAudio = MoonlightStreamAudioLayout::Disabled;
    } else {
        if (!capabilities.host.opusStereo || !capabilities.platform.opusStereoOutput) {
            return terminal(identity, MoonlightStreamResultStatus::Rejected,
                            MoonlightStreamResultCode::OpusStereoUnavailable,
                            std::move(adjustments));
        }
        bool requestedLayoutSupported = true;
        if (effectiveAudio == MoonlightStreamAudioLayout::Surround51) {
            requestedLayoutSupported = capabilities.host.opusSurround51 &&
                capabilities.platform.opusSurround51Output &&
                capabilities.platform.commonCOpusMultistream;
        } else if (effectiveAudio == MoonlightStreamAudioLayout::Surround71) {
            requestedLayoutSupported = capabilities.host.opusSurround71 &&
                capabilities.platform.opusSurround71Output &&
                capabilities.platform.commonCOpusMultistream;
        }
        if (!requestedLayoutSupported) {
            const auto prior = effectiveAudio;
            effectiveAudio = MoonlightStreamAudioLayout::Stereo;
            if (!addAdjustment(adjustments, "audio.channels",
                               "requested_audio_layout_unavailable",
                               audioLayoutName(prior), "stereo")) {
                return terminal(identity, MoonlightStreamResultStatus::InvalidRequest,
                                MoonlightStreamResultCode::AdjustmentOverflow);
            }
        }
    }

    const auto requiredDataStreams = static_cast<std::uint32_t>(
        MoonlightStreamEncryptVideo |
        (requested.d1Effective.audioEnabled ? MoonlightStreamEncryptAudio
                                            : MoonlightStreamEncryptNone));
    const auto candidateEncryptionStreams =
        capabilities.host.encryptionStreams & capabilities.platform.commonCEncryptionStreams &
        requiredDataStreams;
    std::uint32_t requiredEncryptionStreams = MoonlightStreamEncryptNone;
    if (requested.d1Effective.encryptionPolicy == MoonlightStreamEncryptionPolicy::Required) {
        if ((candidateEncryptionStreams & requiredDataStreams) != requiredDataStreams) {
            return terminal(identity, MoonlightStreamResultStatus::Rejected,
                            MoonlightStreamResultCode::EncryptionRequiredUnavailable,
                            std::move(adjustments));
        }
        requiredEncryptionStreams = requiredDataStreams;
    }

    std::int32_t packetSize = kConservativePacketSizeBytes;
    const bool provenLocalPacketPath =
        capabilities.network.path == MoonlightStreamNetworkPath::Local &&
        capabilities.network.metered == MoonlightStreamMeteredState::Unmetered &&
        capabilities.network.addressFamily != MoonlightStreamAddressFamily::Unknown &&
        capabilities.network.vpnClassificationKnown &&
        capabilities.network.nat64ClassificationKnown &&
        capabilities.network.mtuReceiptAvailable;
    if (provenLocalPacketPath) {
        packetSize = capabilities.network.safeVideoPacketSizeBytes;
        const auto alignedPacketSize = packetSize - packetSize % 16;
        if (alignedPacketSize < kConservativePacketSizeBytes) {
            packetSize = kConservativePacketSizeBytes;
        } else if (alignedPacketSize != packetSize) {
            if (!addAdjustment(adjustments, "network.packetSizeBytes",
                               "encryption_packet_alignment", std::to_string(packetSize),
                               std::to_string(alignedPacketSize))) {
                return terminal(identity, MoonlightStreamResultStatus::InvalidRequest,
                                MoonlightStreamResultCode::AdjustmentOverflow);
            }
            packetSize = alignedPacketSize;
        }
    }

    MoonlightEffectiveStreamOffer offer;
    offer.dimensions = dimensions;
    offer.fps = effectiveFps;
    offer.launchRefreshRate = effectiveFps;
    offer.clientRefreshRateX100 = capabilities.display.refreshRateX100.value_or(0);
    offer.configuredBitrateKbps = configuredBitrate;
    offer.estimatedEncoderBitrateKbps = static_cast<std::int32_t>(estimatedEncoder);
    offer.packetSizeBytes = packetSize;
    offer.networkPath = capabilities.network.path;
    offer.latencyMode = requested.d1Effective.latencyMode;
    offer.offeredCodecs = std::move(offeredCodecs);
    offer.selectedCodec.reset();
    offer.hdr = effectiveHdr;
    offer.yuv444 = effectiveYuv444;
    if (effectiveHdr) {
        offer.colorSpace = MoonlightStreamColorSpace::Rec2020;
        offer.colorRange = MoonlightStreamColorRange::Limited;
    } else if (capabilities.host.rec709Limited && capabilities.display.rec709Limited) {
        offer.colorSpace = MoonlightStreamColorSpace::Rec709;
        offer.colorRange = MoonlightStreamColorRange::Limited;
    }
    offer.audioLayout = effectiveAudio;
    offer.playAudioOnHost = requested.d1Effective.playAudioOnHost;
    offer.highQualityAudioCandidate =
        (effectiveAudio == MoonlightStreamAudioLayout::Surround51 ||
         effectiveAudio == MoonlightStreamAudioLayout::Surround71) &&
        configuredBitrate >= kHighQualityAudioThresholdKbps &&
        capabilities.host.highQualitySurround && !capabilities.platform.slowOpusDecoder &&
        capabilities.network.path == MoonlightStreamNetworkPath::Local;
    offer.encryptionPolicy = requested.d1Effective.encryptionPolicy;
    offer.requiredEncryptionStreams = requiredEncryptionStreams;
    offer.candidateEncryptionStreams = candidateEncryptionStreams;
    offer.remoteInputEncryptionRequired = true;

    MoonlightLaunchProjection launch;
    launch.dimensions = offer.dimensions;
    launch.fps = offer.launchRefreshRate;
    launch.hdr = offer.hdr;
    launch.audioLayout = offer.audioLayout;
    launch.playAudioOnHost = offer.playAudioOnHost;
    launch.controllerBitmap = 0U;
    launch.persistGamepadsAfterDisconnect = false;

    MoonlightStreamConfigResult result;
    result.status = MoonlightStreamResultStatus::OfferReady;
    result.code = MoonlightStreamResultCode::None;
    result.identity = identity;
    result.offer = std::move(offer);
    result.launchProjection = std::move(launch);
    result.adjustments = std::move(adjustments);
    return result;
}

void appendCanonical(std::string& destination, const std::string& value) {
    destination += std::to_string(value.size());
    destination.push_back(':');
    destination += value;
    destination.push_back('|');
}

template <typename Value>
void appendCanonicalNumber(std::string& destination, Value value) {
    appendCanonical(destination, std::to_string(static_cast<std::uint64_t>(value)));
}

void appendCanonicalBool(std::string& destination, bool value) {
    appendCanonical(destination, value ? "1" : "0");
}

void appendCanonicalOffered(std::string& destination, const MoonlightOfferedCodec& offered) {
    appendCanonicalNumber(destination, offered.codec);
    appendCanonicalNumber(destination, offered.bitDepth);
    appendCanonicalNumber(destination, offered.chroma);
    appendCanonicalBool(destination, offered.preferred);
    appendCanonicalBool(destination, offered.supportsCurrentHdrIntent);
    appendCanonicalBool(destination, offered.supportsCurrentYuv444Intent);
}

} // namespace

MoonlightStreamConfigResult resolveMoonlightStreamConfig(
    const MoonlightRequestedStreamConfig& requested,
    const MoonlightStreamCapabilitySnapshot& capabilities,
    const MoonlightStreamConfigIdentity& identity,
    std::uint64_t nowMonotonicMs) noexcept {
    try {
        return resolveImpl(requested, capabilities, identity, nowMonotonicMs);
    } catch (...) {
        return terminal(identity, MoonlightStreamResultStatus::Rejected,
                        MoonlightStreamResultCode::InternalFailure);
    }
}

const char* moonlightStreamResultStatusName(MoonlightStreamResultStatus status) noexcept {
    switch (status) {
        case MoonlightStreamResultStatus::InvalidRequest: return "invalid_request";
        case MoonlightStreamResultStatus::CapabilityPending: return "capability_pending";
        case MoonlightStreamResultStatus::ConfirmationRequired: return "confirmation_required";
        case MoonlightStreamResultStatus::OfferReady: return "offer_ready";
        case MoonlightStreamResultStatus::Rejected: return "rejected";
    }
    return "unknown";
}

const char* moonlightStreamResultCodeName(MoonlightStreamResultCode code) noexcept {
    switch (code) {
        case MoonlightStreamResultCode::None: return "none";
        case MoonlightStreamResultCode::InvalidIdentity: return "invalid_identity";
        case MoonlightStreamResultCode::InvalidSettings: return "invalid_settings";
        case MoonlightStreamResultCode::InvalidCapabilities: return "invalid_capabilities";
        case MoonlightStreamResultCode::CapabilityPending: return "capability_pending";
        case MoonlightStreamResultCode::CapabilityStale: return "capability_stale";
        case MoonlightStreamResultCode::CapabilityUnsupported: return "capability_unsupported";
        case MoonlightStreamResultCode::HostModePending: return "host_mode_pending";
        case MoonlightStreamResultCode::NetworkPathPending: return "network_path_pending";
        case MoonlightStreamResultCode::BitrateCapabilityPending:
            return "bitrate_capability_pending";
        case MoonlightStreamResultCode::MeteredConfirmationRequired:
            return "metered_confirmation_required";
        case MoonlightStreamResultCode::MeteredNetworkDenied: return "metered_network_denied";
        case MoonlightStreamResultCode::MvpCodecUnavailable: return "mvp_codec_unavailable";
        case MoonlightStreamResultCode::NoCompatibleCodecProfile:
            return "no_compatible_codec_profile";
        case MoonlightStreamResultCode::DimensionUnsupported: return "dimension_unsupported";
        case MoonlightStreamResultCode::OpusStereoUnavailable: return "opus_stereo_unavailable";
        case MoonlightStreamResultCode::AudioDisablePathPending:
            return "audio_disable_path_pending";
        case MoonlightStreamResultCode::EncryptionRequiredUnavailable:
            return "encryption_required_unavailable";
        case MoonlightStreamResultCode::AdjustmentOverflow: return "adjustment_overflow";
        case MoonlightStreamResultCode::InternalFailure: return "internal_failure";
    }
    return "unknown";
}

const char* moonlightStreamCodecName(MoonlightStreamCodec codec) noexcept {
    switch (codec) {
        case MoonlightStreamCodec::H264: return "h264";
        case MoonlightStreamCodec::Hevc: return "hevc";
        case MoonlightStreamCodec::Av1: return "av1";
    }
    return "unknown";
}

std::string moonlightStreamConfigCanonicalResult(const MoonlightStreamConfigResult& result) {
    std::string canonical;
    canonical.reserve(1024U);
    appendCanonical(canonical, moonlightStreamResultStatusName(result.status));
    appendCanonical(canonical, moonlightStreamResultCodeName(result.code));
    appendCanonicalNumber(canonical, result.identity.ownerToken);
    appendCanonicalNumber(canonical, result.identity.sessionGeneration);
    appendCanonical(canonical, result.identity.hostId);
    appendCanonical(canonical, result.identity.serverUuid);
    appendCanonicalNumber(canonical, result.identity.settingsRevision);
    appendCanonicalNumber(canonical, result.identity.hostCapabilityGeneration);
    appendCanonicalNumber(canonical, result.identity.platformProbeGeneration);
    appendCanonicalNumber(canonical, result.identity.networkCapabilityGeneration);
    appendCanonicalNumber(canonical, result.identity.displayCapabilityGeneration);
    appendCanonicalNumber(canonical, result.adjustments.size());
    for (const auto& adjustment : result.adjustments) {
        appendCanonical(canonical, adjustment.field);
        appendCanonical(canonical, adjustment.code);
        appendCanonical(canonical, adjustment.requested);
        appendCanonical(canonical, adjustment.effective);
    }
    appendCanonicalBool(canonical, result.offer.has_value());
    if (result.offer.has_value()) {
        const auto& offer = *result.offer;
        appendCanonicalNumber(canonical, offer.dimensions.width);
        appendCanonicalNumber(canonical, offer.dimensions.height);
        appendCanonicalNumber(canonical, offer.fps);
        appendCanonicalNumber(canonical, offer.launchRefreshRate);
        appendCanonicalNumber(canonical, offer.clientRefreshRateX100);
        appendCanonicalNumber(canonical, offer.configuredBitrateKbps);
        appendCanonicalNumber(canonical, offer.estimatedEncoderBitrateKbps);
        appendCanonicalNumber(canonical, offer.packetSizeBytes);
        appendCanonicalNumber(canonical, offer.networkPath);
        appendCanonicalNumber(canonical, offer.latencyMode);
        appendCanonicalNumber(canonical, offer.offeredCodecs.size());
        for (const auto& offered : offer.offeredCodecs) {
            appendCanonicalOffered(canonical, offered);
        }
        appendCanonicalBool(canonical, offer.selectedCodec.has_value());
        if (offer.selectedCodec.has_value()) {
            appendCanonicalOffered(canonical, *offer.selectedCodec);
        }
        appendCanonicalBool(canonical, offer.hdr);
        appendCanonicalBool(canonical, offer.yuv444);
        appendCanonicalBool(canonical, offer.colorSpace.has_value());
        if (offer.colorSpace.has_value()) {
            appendCanonicalNumber(canonical, *offer.colorSpace);
        }
        appendCanonicalBool(canonical, offer.colorRange.has_value());
        if (offer.colorRange.has_value()) {
            appendCanonicalNumber(canonical, *offer.colorRange);
        }
        appendCanonicalNumber(canonical, offer.audioLayout);
        appendCanonicalBool(canonical, offer.playAudioOnHost);
        appendCanonicalBool(canonical, offer.highQualityAudioCandidate);
        appendCanonicalNumber(canonical, offer.encryptionPolicy);
        appendCanonicalNumber(canonical, offer.requiredEncryptionStreams);
        appendCanonicalNumber(canonical, offer.candidateEncryptionStreams);
        appendCanonicalBool(canonical, offer.remoteInputEncryptionRequired);
    }
    appendCanonicalBool(canonical, result.launchProjection.has_value());
    if (result.launchProjection.has_value()) {
        const auto& launch = *result.launchProjection;
        appendCanonicalNumber(canonical, launch.dimensions.width);
        appendCanonicalNumber(canonical, launch.dimensions.height);
        appendCanonicalNumber(canonical, launch.fps);
        appendCanonicalBool(canonical, launch.hdr);
        appendCanonicalNumber(canonical, launch.audioLayout);
        appendCanonicalBool(canonical, launch.playAudioOnHost);
        appendCanonicalNumber(canonical, launch.controllerBitmap);
        appendCanonicalBool(canonical, launch.persistGamepadsAfterDisconnect);
    }
    return canonical;
}

} // namespace remotedesk::moonlight
