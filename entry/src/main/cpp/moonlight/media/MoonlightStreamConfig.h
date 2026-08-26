#ifndef REMOTEDESK_MOONLIGHT_STREAM_CONFIG_H
#define REMOTEDESK_MOONLIGHT_STREAM_CONFIG_H

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#if defined(__GNUC__) || defined(__clang__)
#define REMOTEDESK_MOONLIGHT_STREAM_CONFIG_HIDDEN __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_STREAM_CONFIG_HIDDEN
#endif

namespace remotedesk::moonlight {

// Project-owned values only. N2-01 deliberately does not expose or include
// moonlight-common-c wire types, N-API, ArkTS, media, audio, or input headers.
enum class MoonlightStreamCodecPreference : std::uint8_t {
    Auto,
    H264,
    Hevc,
    Av1,
};

enum class MoonlightStreamCodec : std::uint8_t {
    H264,
    Hevc,
    Av1,
};

enum class MoonlightStreamResolutionMode : std::uint8_t {
    Host,
    P720,
    P1080,
    P1440,
    P2160,
    Custom,
};

enum class MoonlightStreamBitDepth : std::uint8_t {
    Bit8,
    Bit10,
};

enum class MoonlightStreamChroma : std::uint8_t {
    Yuv420,
    Yuv444,
};

enum class MoonlightStreamLatencyMode : std::uint8_t {
    LowLatency,
    Balanced,
    Smooth,
};

enum class MoonlightStreamAudioLayout : std::uint8_t {
    Disabled,
    Stereo,
    Surround51,
    Surround71,
};

enum class MoonlightStreamEncryptionPolicy : std::uint8_t {
    Auto,
    Required,
    Compatible,
};

enum class MoonlightStreamMeteredPolicy : std::uint8_t {
    Ask,
    Allow,
    Deny,
};

enum class MoonlightStreamCapabilityStatus : std::uint8_t {
    Pending,
    Supported,
    Unsupported,
};

enum class MoonlightStreamCapabilitySource : std::uint8_t {
    Host,
    PlatformProbe,
    NetworkProbe,
    DisplayProbe,
};

enum class MoonlightStreamNetworkPath : std::uint8_t {
    Unknown,
    Local,
    Remote,
};

enum class MoonlightStreamAddressFamily : std::uint8_t {
    Unknown,
    Ipv4,
    Ipv6,
};

enum class MoonlightStreamMeteredState : std::uint8_t {
    Unknown,
    Unmetered,
    Metered,
};

enum class MoonlightStreamColorSpace : std::uint8_t {
    Rec709,
    Rec2020,
};

enum class MoonlightStreamColorRange : std::uint8_t {
    Limited,
    Full,
};

enum class MoonlightStreamResultStatus : std::uint8_t {
    InvalidRequest,
    CapabilityPending,
    ConfirmationRequired,
    OfferReady,
    Rejected,
};

enum class MoonlightStreamResultCode : std::uint8_t {
    None,
    InvalidIdentity,
    InvalidSettings,
    InvalidCapabilities,
    CapabilityPending,
    CapabilityStale,
    CapabilityUnsupported,
    HostModePending,
    NetworkPathPending,
    BitrateCapabilityPending,
    MeteredConfirmationRequired,
    MeteredNetworkDenied,
    MvpCodecUnavailable,
    NoCompatibleCodecProfile,
    DimensionUnsupported,
    OpusStereoUnavailable,
    AudioDisablePathPending,
    EncryptionRequiredUnavailable,
    AdjustmentOverflow,
    InternalFailure,
};

enum MoonlightStreamDataEncryption : std::uint32_t {
    MoonlightStreamEncryptNone = 0U,
    MoonlightStreamEncryptAudio = 1U << 0U,
    MoonlightStreamEncryptVideo = 1U << 1U,
};

struct MoonlightStreamCapabilityEvidence final {
    MoonlightStreamCapabilityStatus status = MoonlightStreamCapabilityStatus::Pending;
    MoonlightStreamCapabilitySource source = MoonlightStreamCapabilitySource::Host;
    std::string version;
    std::uint64_t generation = 0U;
    std::uint64_t expiresAtMonotonicMs = 0U;
};

struct MoonlightStreamDimensions final {
    std::int32_t width = 0;
    std::int32_t height = 0;
};

struct MoonlightStreamCodecProfile final {
    MoonlightStreamCodec codec = MoonlightStreamCodec::H264;
    MoonlightStreamBitDepth bitDepth = MoonlightStreamBitDepth::Bit8;
    MoonlightStreamChroma chroma = MoonlightStreamChroma::Yuv420;
};

// This is the exact stream-relevant projection of the ArkTS D1 settings. The
// resolver consumes d1Effective; requested and priorAdjustments are retained so
// a future UI can explain both D1 and runtime downgrades without persisting the
// runtime result back to the cloud row.
struct MoonlightStreamSettings final {
    std::uint32_t schemaVersion = 1U;
    MoonlightStreamCodecPreference codecPreference = MoonlightStreamCodecPreference::Auto;
    MoonlightStreamResolutionMode resolutionMode = MoonlightStreamResolutionMode::Host;
    std::int32_t customWidth = 1920;
    std::int32_t customHeight = 1080;
    std::int32_t fps = 60;
    std::int32_t bitrateKbps = 20000;
    bool hdr = false;
    bool yuv444 = false;
    MoonlightStreamLatencyMode latencyMode = MoonlightStreamLatencyMode::LowLatency;
    bool audioEnabled = true;
    MoonlightStreamAudioLayout audioLayout = MoonlightStreamAudioLayout::Stereo;
    bool playAudioOnHost = false;
    MoonlightStreamEncryptionPolicy encryptionPolicy = MoonlightStreamEncryptionPolicy::Auto;
    MoonlightStreamMeteredPolicy meteredPolicy = MoonlightStreamMeteredPolicy::Ask;
};

struct MoonlightStreamAdjustment final {
    std::string field;
    std::string code;
    std::string requested;
    std::string effective;
};

struct MoonlightRequestedStreamConfig final {
    MoonlightStreamSettings requested;
    MoonlightStreamSettings d1Effective;
    std::vector<MoonlightStreamAdjustment> priorAdjustments;
};

struct MoonlightStreamConfigIdentity final {
    std::uint64_t ownerToken = 0U;
    std::uint64_t sessionGeneration = 0U;
    std::string hostId;
    std::string serverUuid;
    std::uint64_t settingsRevision = 0U;
    std::uint64_t hostCapabilityGeneration = 0U;
    std::uint64_t platformProbeGeneration = 0U;
    std::uint64_t networkCapabilityGeneration = 0U;
    std::uint64_t displayCapabilityGeneration = 0U;
};

struct MoonlightHostStreamCapabilities final {
    MoonlightStreamCapabilityEvidence evidence;
    std::optional<MoonlightStreamDimensions> recommendedMode;
    std::int32_t maxWidth = 0;
    std::int32_t maxHeight = 0;
    std::int32_t maxFps = 0;
    std::int32_t maxEncoderBitrateKbps = 0;
    std::vector<MoonlightStreamCodecProfile> codecProfiles;
    bool hdr = false;
    bool yuv444 = false;
    bool rec709Limited = false;
    bool rec2020Limited = false;
    bool opusStereo = false;
    bool opusSurround51 = false;
    bool opusSurround71 = false;
    bool highQualitySurround = false;
    std::uint32_t encryptionStreams = MoonlightStreamEncryptNone;
};

struct MoonlightPlatformStreamCapabilities final {
    MoonlightStreamCapabilityEvidence evidence;
    std::int32_t maxWidth = 0;
    std::int32_t maxHeight = 0;
    std::int32_t maxFps = 0;
    std::int32_t maxDecodeBitrateKbps = 0;
    std::int32_t maxThermalBitrateKbps = 0;
    std::vector<MoonlightStreamCodecProfile> decoderProfiles;
    bool rendererYuv444 = false;
    bool opusStereoOutput = false;
    bool opusSurround51Output = false;
    bool opusSurround71Output = false;
    bool commonCOpusMultistream = false;
    bool audioDiscardPath = false;
    bool slowOpusDecoder = false;
    std::uint32_t commonCEncryptionStreams = MoonlightStreamEncryptNone;
};

struct MoonlightNetworkStreamCapabilities final {
    MoonlightStreamCapabilityEvidence evidence;
    MoonlightStreamNetworkPath path = MoonlightStreamNetworkPath::Unknown;
    MoonlightStreamAddressFamily addressFamily = MoonlightStreamAddressFamily::Unknown;
    bool vpnClassificationKnown = false;
    bool vpnOrTunnel = false;
    bool nat64ClassificationKnown = false;
    bool nat64 = false;
    bool mtuReceiptAvailable = false;
    std::int32_t safeVideoPacketSizeBytes = 1024;
    MoonlightStreamMeteredState metered = MoonlightStreamMeteredState::Unknown;
    bool userConfirmedMetered = false;
    std::int32_t maxBitrateKbps = 0;
};

struct MoonlightDisplayStreamCapabilities final {
    MoonlightStreamCapabilityEvidence evidence;
    std::int32_t maxWidth = 0;
    std::int32_t maxHeight = 0;
    std::int32_t maxFps = 0;
    std::optional<std::int32_t> refreshRateX100;
    bool hdr = false;
    bool surfaceHdr = false;
    bool pipHdr = false;
    bool yuv444 = false;
    bool rec709Limited = false;
    bool rec2020Limited = false;
};

struct MoonlightStreamCapabilitySnapshot final {
    MoonlightHostStreamCapabilities host;
    MoonlightPlatformStreamCapabilities platform;
    MoonlightNetworkStreamCapabilities network;
    MoonlightDisplayStreamCapabilities display;
};

struct MoonlightOfferedCodec final {
    MoonlightStreamCodec codec = MoonlightStreamCodec::H264;
    MoonlightStreamBitDepth bitDepth = MoonlightStreamBitDepth::Bit8;
    MoonlightStreamChroma chroma = MoonlightStreamChroma::Yuv420;
    bool preferred = false;
    bool supportsCurrentHdrIntent = false;
    bool supportsCurrentYuv444Intent = false;
};

struct MoonlightEffectiveStreamOffer final {
    MoonlightStreamDimensions dimensions;
    std::int32_t fps = 0;
    std::int32_t launchRefreshRate = 0;
    std::int32_t clientRefreshRateX100 = 0;
    std::int32_t configuredBitrateKbps = 0;
    std::int32_t estimatedEncoderBitrateKbps = 0;
    std::int32_t packetSizeBytes = 1024;
    MoonlightStreamNetworkPath networkPath = MoonlightStreamNetworkPath::Unknown;
    MoonlightStreamLatencyMode latencyMode = MoonlightStreamLatencyMode::LowLatency;
    std::vector<MoonlightOfferedCodec> offeredCodecs;
    std::optional<MoonlightOfferedCodec> selectedCodec;
    bool hdr = false;
    bool yuv444 = false;
    std::optional<MoonlightStreamColorSpace> colorSpace;
    std::optional<MoonlightStreamColorRange> colorRange;
    MoonlightStreamAudioLayout audioLayout = MoonlightStreamAudioLayout::Disabled;
    bool playAudioOnHost = false;
    bool highQualityAudioCandidate = false;
    MoonlightStreamEncryptionPolicy encryptionPolicy = MoonlightStreamEncryptionPolicy::Auto;
    std::uint32_t requiredEncryptionStreams = MoonlightStreamEncryptNone;
    std::uint32_t candidateEncryptionStreams = MoonlightStreamEncryptNone;
    bool remoteInputEncryptionRequired = true;
};

struct MoonlightLaunchProjection final {
    MoonlightStreamDimensions dimensions;
    std::int32_t fps = 0;
    bool hdr = false;
    MoonlightStreamAudioLayout audioLayout = MoonlightStreamAudioLayout::Disabled;
    bool playAudioOnHost = false;
    std::uint32_t controllerBitmap = 0U;
    bool persistGamepadsAfterDisconnect = false;
};

struct MoonlightStreamConfigResult final {
    MoonlightStreamResultStatus status = MoonlightStreamResultStatus::InvalidRequest;
    MoonlightStreamResultCode code = MoonlightStreamResultCode::InvalidSettings;
    MoonlightStreamConfigIdentity identity;
    std::optional<MoonlightEffectiveStreamOffer> offer;
    std::optional<MoonlightLaunchProjection> launchProjection;
    std::vector<MoonlightStreamAdjustment> adjustments;

    bool ready() const noexcept {
        return status == MoonlightStreamResultStatus::OfferReady && offer.has_value() &&
            launchProjection.has_value() && !offer->selectedCodec.has_value();
    }
};

REMOTEDESK_MOONLIGHT_STREAM_CONFIG_HIDDEN MoonlightStreamConfigResult
resolveMoonlightStreamConfig(
    const MoonlightRequestedStreamConfig& requested,
    const MoonlightStreamCapabilitySnapshot& capabilities,
    const MoonlightStreamConfigIdentity& identity,
    std::uint64_t nowMonotonicMs) noexcept;

// Stable, non-localized names and a length-framed canonical representation are
// provided for deterministic tests and diagnostics. They perform no I/O and do
// not include addresses, credentials, PINs, RI keys, RTSP URLs, or media data.
REMOTEDESK_MOONLIGHT_STREAM_CONFIG_HIDDEN const char* moonlightStreamResultStatusName(
    MoonlightStreamResultStatus status) noexcept;
REMOTEDESK_MOONLIGHT_STREAM_CONFIG_HIDDEN const char* moonlightStreamResultCodeName(
    MoonlightStreamResultCode code) noexcept;
REMOTEDESK_MOONLIGHT_STREAM_CONFIG_HIDDEN const char* moonlightStreamCodecName(
    MoonlightStreamCodec codec) noexcept;
REMOTEDESK_MOONLIGHT_STREAM_CONFIG_HIDDEN std::string moonlightStreamConfigCanonicalResult(
    const MoonlightStreamConfigResult& result);

} // namespace remotedesk::moonlight

#undef REMOTEDESK_MOONLIGHT_STREAM_CONFIG_HIDDEN

#endif // REMOTEDESK_MOONLIGHT_STREAM_CONFIG_H
