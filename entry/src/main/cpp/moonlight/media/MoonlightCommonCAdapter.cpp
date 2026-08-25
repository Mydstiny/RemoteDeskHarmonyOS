#include "moonlight/media/MoonlightCommonCAdapter.h"

// This is the only project translation unit allowed to see common-c's public C
// structs, callback signatures, numeric masks, and Li* entry points.
#include "moonlight/upstream/moonlight-common-c/src/Limelight.h"

#if !defined(RDP_TESTS_ONLY)
#include <hilog/log.h>
#endif

#if !defined(RDP_TESTS_ONLY)
extern "C" {
extern STREAM_CONFIGURATION StreamConfig;
}
#endif

#include <algorithm>
#include <atomic>
#include <cstdarg>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <type_traits>
#include <utility>

#if !defined(RDP_TESTS_ONLY)
#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0042
#define LOG_TAG "MOON_COMMON_C"
#endif

namespace remotedesk::moonlight {
namespace {

constexpr std::size_t kRemoteInputBytes = 16U;
constexpr std::size_t kMaximumEvents = 64U;
constexpr std::size_t kMaximumCodecProfiles = 16U;
constexpr std::size_t kMaximumAddressLength = 255U;
constexpr std::size_t kMaximumVersionLength = 64U;
constexpr std::size_t kMaximumRtspUrlLength = 2048U;
// AudioStream.c receives at most MAX_PACKET_SIZE (1400) bytes and uses the
// exact null+zero callback shape for one packet-loss-concealment request.
constexpr std::size_t kMaximumAudioPayloadBytes = 1400U;
// A 1080p H.264 IDR can arrive as well over 64 common-c LENTRY nodes when
// the upstream packet size is small. Keep the per-fragment and total-AU byte
// limits below, but allow enough nodes for a complete key frame.
constexpr std::size_t kMaximumVideoFragments = 256U;
constexpr std::size_t kMaximumVideoFragmentBytes = 4U * 1024U * 1024U;
constexpr std::size_t kMaximumVideoAccessUnitBytes = 16U * 1024U * 1024U;
constexpr std::size_t kMaximumVideoConfigurationBytes = 1024U * 1024U;
constexpr std::uint64_t kMaximumDeadlineWindowMs = 10U * 60U * 1000U;
constexpr std::int32_t kMinimumWidth = 320;
constexpr std::int32_t kMaximumWidth = 7680;
constexpr std::int32_t kMinimumHeight = 240;
constexpr std::int32_t kMaximumHeight = 4320;
constexpr std::int32_t kMinimumFps = 30;
constexpr std::int32_t kMaximumFps = 240;
constexpr std::int32_t kMinimumBitrateKbps = 1000;
constexpr std::int32_t kMaximumBitrateKbps = 200000;
constexpr std::int32_t kMaximumPacketSizeBytes = 4096;
constexpr std::uint32_t kKnownEncryptionStreams =
    MoonlightStreamEncryptAudio | MoonlightStreamEncryptVideo;

static_assert(sizeof(int) >= sizeof(std::int32_t));
static_assert(sizeof(STREAM_CONFIGURATION::remoteInputAesKey) == kRemoteInputBytes);
static_assert(sizeof(STREAM_CONFIGURATION::remoteInputAesIv) == kRemoteInputBytes);
static_assert(STAGE_PLATFORM_INIT == 1 && STAGE_INPUT_STREAM_START == 11 &&
              STAGE_MAX == 12);
static_assert(AUDIO_CONFIGURATION_MAX_CHANNEL_COUNT == 8);
static_assert(ENCFLG_AUDIO == static_cast<int>(MoonlightStreamEncryptAudio));
static_assert(ENCFLG_VIDEO == static_cast<int>(MoonlightStreamEncryptVideo));
static_assert(VIDEO_FORMAT_H264 == 0x0001 &&
              VIDEO_FORMAT_H264_HIGH8_444 == 0x0004 &&
              VIDEO_FORMAT_H265 == 0x0100 &&
              VIDEO_FORMAT_H265_MAIN10 == 0x0200 &&
              VIDEO_FORMAT_H265_REXT8_444 == 0x0400 &&
              VIDEO_FORMAT_H265_REXT10_444 == 0x0800 &&
              VIDEO_FORMAT_AV1_MAIN8 == 0x1000 &&
              VIDEO_FORMAT_AV1_MAIN10 == 0x2000 &&
              VIDEO_FORMAT_AV1_HIGH8_444 == 0x4000 &&
              VIDEO_FORMAT_AV1_HIGH10_444 == 0x8000);
static_assert(SCM_H264 == 0x00000001 && SCM_HEVC == 0x00000100 &&
              SCM_HEVC_MAIN10 == 0x00000200 && SCM_AV1_MAIN8 == 0x00010000 &&
              SCM_AV1_MAIN10 == 0x00020000 &&
              SCM_H264_HIGH8_444 == 0x00040000 &&
              SCM_HEVC_REXT8_444 == 0x00080000 &&
              SCM_HEVC_REXT10_444 == 0x00100000 &&
              SCM_AV1_HIGH8_444 == 0x00200000 &&
              SCM_AV1_HIGH10_444 == 0x00400000);
static_assert(BUFFER_TYPE_PICDATA == 0 && BUFFER_TYPE_SPS == 1 &&
              BUFFER_TYPE_PPS == 2 && BUFFER_TYPE_VPS == 3);
static_assert(FRAME_TYPE_PFRAME == 0 && FRAME_TYPE_IDR == 1);
static_assert(COLORSPACE_REC_601 == 0 && COLORSPACE_REC_709 == 1 &&
              COLORSPACE_REC_2020 == 2);
static_assert(DR_OK == 0 && DR_NEED_IDR == -1);
static_assert(static_cast<int>(MoonlightVideoBufferType::PictureData) ==
              BUFFER_TYPE_PICDATA);
static_assert(static_cast<int>(MoonlightVideoBufferType::SequenceParameterSet) ==
              BUFFER_TYPE_SPS);
static_assert(static_cast<int>(MoonlightVideoBufferType::PictureParameterSet) ==
              BUFFER_TYPE_PPS);
static_assert(static_cast<int>(MoonlightVideoBufferType::VideoParameterSet) ==
              BUFFER_TYPE_VPS);
static_assert(static_cast<int>(MoonlightVideoFrameType::Predicted) ==
              FRAME_TYPE_PFRAME);
static_assert(static_cast<int>(MoonlightVideoFrameType::IdR) == FRAME_TYPE_IDR);

struct ProjectedCommonCVideoUnit final {
    MoonlightVideoDecodeUnitView view;
    std::array<MoonlightVideoFragmentView, kMaximumVideoFragments> fragments {};
    std::array<const LENTRY*, kMaximumVideoFragments> sourceEntries {};
};

bool projectCommonCVideoUnit(PDECODE_UNIT source,
                             const MoonlightSessionKey& key,
                             const MoonlightStreamCodecProfile& profile,
                             ProjectedCommonCVideoUnit& projected) noexcept {
    projected = {};
    if (source == nullptr || !key.valid() || source->frameNumber < 0 ||
        (source->frameType != FRAME_TYPE_PFRAME &&
         source->frameType != FRAME_TYPE_IDR) ||
        source->fullLength <= 0 ||
        static_cast<std::size_t>(source->fullLength) >
            kMaximumVideoAccessUnitBytes ||
        source->bufferList == nullptr ||
        source->receiveTimeUs > source->enqueueTimeUs ||
        source->colorspace > COLORSPACE_REC_2020) {
        return false;
    }

    std::size_t fragmentCount = 0U;
    std::size_t totalLength = 0U;
    std::size_t configurationLength = 0U;
    for (const LENTRY* entry = source->bufferList; entry != nullptr;
         entry = entry->next) {
        if (fragmentCount == kMaximumVideoFragments ||
            std::find(projected.sourceEntries.begin(),
                      projected.sourceEntries.begin() +
                          static_cast<std::ptrdiff_t>(fragmentCount),
                      entry) != projected.sourceEntries.begin() +
                                   static_cast<std::ptrdiff_t>(fragmentCount) ||
            entry->data == nullptr || entry->length <= 0) {
            return false;
        }
        const auto length = static_cast<std::size_t>(entry->length);
        if (length > kMaximumVideoFragmentBytes ||
            length > kMaximumVideoAccessUnitBytes - totalLength ||
            (entry->bufferType != BUFFER_TYPE_PICDATA &&
             entry->bufferType != BUFFER_TYPE_SPS &&
             entry->bufferType != BUFFER_TYPE_PPS &&
             entry->bufferType != BUFFER_TYPE_VPS)) {
            return false;
        }
        if (entry->bufferType != BUFFER_TYPE_PICDATA) {
            if (length > kMaximumVideoConfigurationBytes - configurationLength) {
                return false;
            }
            configurationLength += length;
        }
        projected.sourceEntries[fragmentCount] = entry;
        projected.fragments[fragmentCount] = {
            reinterpret_cast<const std::uint8_t*>(entry->data), length,
            static_cast<MoonlightVideoBufferType>(entry->bufferType), nullptr};
        if (fragmentCount != 0U) {
            projected.fragments[fragmentCount - 1U].next =
                &projected.fragments[fragmentCount];
        }
        totalLength += length;
        ++fragmentCount;
    }
    if (fragmentCount == 0U ||
        totalLength != static_cast<std::size_t>(source->fullLength)) {
        return false;
    }

    projected.view.key = key;
    projected.view.profile = profile;
    projected.view.frameNumber = source->frameNumber;
    projected.view.frameType =
        static_cast<MoonlightVideoFrameType>(source->frameType);
    projected.view.hostProcessingLatencyDeciMs =
        source->frameHostProcessingLatency;
    projected.view.receiveTimeUs = source->receiveTimeUs;
    projected.view.enqueueTimeUs = source->enqueueTimeUs;
    projected.view.presentationTimeUs = source->presentationTimeUs;
    projected.view.rtpTimestamp = source->rtpTimestamp;
    projected.view.fullLength = totalLength;
    projected.view.bufferList = &projected.fragments[0];
    projected.view.hdrActive = source->hdrActive;
    projected.view.colorSpace = source->colorspace;
    return true;
}

void secureWipe(void* pointer, std::size_t length) noexcept {
    auto* bytes = static_cast<volatile std::uint8_t*>(pointer);
    while (length != 0U) {
        *bytes++ = 0U;
        --length;
    }
}

void clearRemoteInputSecrets(void* key, std::size_t keySize,
                             void* iv, std::size_t ivSize) noexcept {
    secureWipe(key, keySize);
    secureWipe(iv, ivSize);
}

#if !defined(RDP_TESTS_ONLY)
void clearCommonCGlobalRemoteInputSecrets() noexcept {
    clearRemoteInputSecrets(
        ::StreamConfig.remoteInputAesKey,
        sizeof(::StreamConfig.remoteInputAesKey),
        ::StreamConfig.remoteInputAesIv,
        sizeof(::StreamConfig.remoteInputAesIv));
}
#endif

void secureWipeString(std::string& value) noexcept {
    if (!value.empty()) {
        secureWipe(value.data(), value.size());
    }
    value.clear();
}

bool boundedPrintable(const std::string& value, std::size_t minimum,
                      std::size_t maximum) noexcept {
    if (value.size() < minimum || value.size() > maximum) {
        return false;
    }
    return std::all_of(value.begin(), value.end(), [](unsigned char character) {
        return character >= 0x21U && character <= 0x7eU;
    });
}

bool validAddress(const std::string& value) noexcept {
    if (!boundedPrintable(value, 1U, kMaximumAddressLength)) {
        return false;
    }
    return value.find('/') == std::string::npos &&
        value.find('@') == std::string::npos &&
        value.find('?') == std::string::npos &&
        value.find('#') == std::string::npos &&
        value.find('\\') == std::string::npos;
}

bool validVersion(const std::string& value, std::size_t minimumComponents,
                  std::size_t maximumComponents) noexcept {
    if (!boundedPrintable(value, 1U, kMaximumVersionLength)) {
        return false;
    }
    std::size_t componentCount = 0U;
    std::size_t componentLength = 0U;
    bool componentHasSign = false;
    for (const unsigned char character : value) {
        if (character == '.') {
            if (componentLength == 0U || componentHasSign) {
                return false;
            }
            ++componentCount;
            componentLength = 0U;
            componentHasSign = false;
        } else if (character == '-' && componentLength == 0U &&
                   !componentHasSign) {
            // Sunshine identifies itself to common-c with the canonical
            // appversion value "7.1.431.-1". common-c parses this quad as
            // signed integers, so preserve that interoperable shape while
            // retaining strict component and digit bounds.
            componentHasSign = true;
        } else if (character >= '0' && character <= '9') {
            ++componentLength;
            if (componentLength > 6U) {
                return false;
            }
        } else {
            return false;
        }
    }
    if (componentLength == 0U) {
        return false;
    }
    ++componentCount;
    return componentCount >= minimumComponents && componentCount <= maximumComponents;
}

bool decimalPort(const std::string& value) noexcept {
    if (value.empty() || value.size() > 5U) {
        return false;
    }
    std::uint32_t port = 0U;
    for (const unsigned char character : value) {
        if (character < '0' || character > '9') {
            return false;
        }
        port = port * 10U + static_cast<std::uint32_t>(character - '0');
    }
    return port >= 1U && port <= 65535U;
}

bool validRtspUrl(const std::string& value) noexcept {
    constexpr const char* plainPrefix = "rtsp://";
    constexpr const char* encryptedPrefix = "rtspenc://";
    constexpr std::size_t plainPrefixLength = 7U;
    constexpr std::size_t encryptedPrefixLength = 10U;
    const std::size_t prefixLength =
        value.compare(0U, encryptedPrefixLength, encryptedPrefix) == 0
            ? encryptedPrefixLength
            : value.compare(0U, plainPrefixLength, plainPrefix) == 0
                  ? plainPrefixLength
                  : 0U;
    if (prefixLength == 0U || value.size() <= prefixLength ||
        value.size() > kMaximumRtspUrlLength ||
        !boundedPrintable(value, prefixLength + 1U, kMaximumRtspUrlLength) ||
        value.find('\\') != std::string::npos ||
        value.find('#') != std::string::npos) {
        return false;
    }
    const auto authorityEnd = value.find('/', prefixLength);
    const auto authority = value.substr(
        prefixLength, authorityEnd == std::string::npos
                          ? std::string::npos
                          : authorityEnd - prefixLength);
    if (authority.empty() || authority.find('@') != std::string::npos ||
        authority.find('?') != std::string::npos ||
        authority.find('#') != std::string::npos) {
        return false;
    }
    if (authority.front() == '[') {
        const auto close = authority.find(']');
        if (close == std::string::npos || close == 1U) {
            return false;
        }
        if (close + 1U == authority.size()) {
            return true;
        }
        return authority[close + 1U] == ':' &&
            decimalPort(authority.substr(close + 2U));
    }
    const auto firstColon = authority.find(':');
    if (firstColon == std::string::npos) {
        return true;
    }
    return firstColon != 0U && firstColon == authority.rfind(':') &&
        decimalPort(authority.substr(firstColon + 1U));
}

bool sameProfile(const MoonlightStreamCodecProfile& left,
                 const MoonlightStreamCodecProfile& right) noexcept {
    return left.codec == right.codec && left.bitDepth == right.bitDepth &&
        left.chroma == right.chroma;
}

std::int32_t videoFormatForProfile(
    const MoonlightStreamCodecProfile& profile) noexcept {
    switch (profile.codec) {
        case MoonlightStreamCodec::H264:
            if (profile.bitDepth != MoonlightStreamBitDepth::Bit8) {
                return 0;
            }
            return profile.chroma == MoonlightStreamChroma::Yuv420
                       ? VIDEO_FORMAT_H264
                       : VIDEO_FORMAT_H264_HIGH8_444;
        case MoonlightStreamCodec::Hevc:
            if (profile.chroma == MoonlightStreamChroma::Yuv420) {
                return profile.bitDepth == MoonlightStreamBitDepth::Bit8
                           ? VIDEO_FORMAT_H265
                           : VIDEO_FORMAT_H265_MAIN10;
            }
            return profile.bitDepth == MoonlightStreamBitDepth::Bit8
                       ? VIDEO_FORMAT_H265_REXT8_444
                       : VIDEO_FORMAT_H265_REXT10_444;
        case MoonlightStreamCodec::Av1:
            if (profile.chroma == MoonlightStreamChroma::Yuv420) {
                return profile.bitDepth == MoonlightStreamBitDepth::Bit8
                           ? VIDEO_FORMAT_AV1_MAIN8
                           : VIDEO_FORMAT_AV1_MAIN10;
            }
            return profile.bitDepth == MoonlightStreamBitDepth::Bit8
                       ? VIDEO_FORMAT_AV1_HIGH8_444
                       : VIDEO_FORMAT_AV1_HIGH10_444;
    }
    return 0;
}

std::optional<MoonlightStreamCodecProfile> profileForVideoFormat(
    std::int32_t format) noexcept {
    switch (format) {
        case VIDEO_FORMAT_H264:
            return MoonlightStreamCodecProfile {MoonlightStreamCodec::H264,
                MoonlightStreamBitDepth::Bit8, MoonlightStreamChroma::Yuv420};
        case VIDEO_FORMAT_H264_HIGH8_444:
            return MoonlightStreamCodecProfile {MoonlightStreamCodec::H264,
                MoonlightStreamBitDepth::Bit8, MoonlightStreamChroma::Yuv444};
        case VIDEO_FORMAT_H265:
            return MoonlightStreamCodecProfile {MoonlightStreamCodec::Hevc,
                MoonlightStreamBitDepth::Bit8, MoonlightStreamChroma::Yuv420};
        case VIDEO_FORMAT_H265_MAIN10:
            return MoonlightStreamCodecProfile {MoonlightStreamCodec::Hevc,
                MoonlightStreamBitDepth::Bit10, MoonlightStreamChroma::Yuv420};
        case VIDEO_FORMAT_H265_REXT8_444:
            return MoonlightStreamCodecProfile {MoonlightStreamCodec::Hevc,
                MoonlightStreamBitDepth::Bit8, MoonlightStreamChroma::Yuv444};
        case VIDEO_FORMAT_H265_REXT10_444:
            return MoonlightStreamCodecProfile {MoonlightStreamCodec::Hevc,
                MoonlightStreamBitDepth::Bit10, MoonlightStreamChroma::Yuv444};
        case VIDEO_FORMAT_AV1_MAIN8:
            return MoonlightStreamCodecProfile {MoonlightStreamCodec::Av1,
                MoonlightStreamBitDepth::Bit8, MoonlightStreamChroma::Yuv420};
        case VIDEO_FORMAT_AV1_MAIN10:
            return MoonlightStreamCodecProfile {MoonlightStreamCodec::Av1,
                MoonlightStreamBitDepth::Bit10, MoonlightStreamChroma::Yuv420};
        case VIDEO_FORMAT_AV1_HIGH8_444:
            return MoonlightStreamCodecProfile {MoonlightStreamCodec::Av1,
                MoonlightStreamBitDepth::Bit8, MoonlightStreamChroma::Yuv444};
        case VIDEO_FORMAT_AV1_HIGH10_444:
            return MoonlightStreamCodecProfile {MoonlightStreamCodec::Av1,
                MoonlightStreamBitDepth::Bit10, MoonlightStreamChroma::Yuv444};
        default:
            return std::nullopt;
    }
}

std::int32_t serverCodecForProfile(
    const MoonlightStreamCodecProfile& profile) noexcept {
    switch (videoFormatForProfile(profile)) {
        case VIDEO_FORMAT_H264: return SCM_H264;
        case VIDEO_FORMAT_H264_HIGH8_444: return SCM_H264_HIGH8_444;
        case VIDEO_FORMAT_H265: return SCM_HEVC;
        case VIDEO_FORMAT_H265_MAIN10: return SCM_HEVC_MAIN10;
        case VIDEO_FORMAT_H265_REXT8_444: return SCM_HEVC_REXT8_444;
        case VIDEO_FORMAT_H265_REXT10_444: return SCM_HEVC_REXT10_444;
        case VIDEO_FORMAT_AV1_MAIN8: return SCM_AV1_MAIN8;
        case VIDEO_FORMAT_AV1_MAIN10: return SCM_AV1_MAIN10;
        case VIDEO_FORMAT_AV1_HIGH8_444: return SCM_AV1_HIGH8_444;
        case VIDEO_FORMAT_AV1_HIGH10_444: return SCM_AV1_HIGH10_444;
        default: return 0;
    }
}

std::int32_t audioConfigurationForLayout(
    MoonlightStreamAudioLayout layout) noexcept {
    switch (layout) {
        case MoonlightStreamAudioLayout::Disabled:
        case MoonlightStreamAudioLayout::Stereo:
            return AUDIO_CONFIGURATION_STEREO;
        case MoonlightStreamAudioLayout::Surround51:
            return AUDIO_CONFIGURATION_51_SURROUND;
        case MoonlightStreamAudioLayout::Surround71:
            return AUDIO_CONFIGURATION_71_SURROUND;
    }
    return 0;
}

bool validNetworkPath(MoonlightStreamNetworkPath path) noexcept {
    return path == MoonlightStreamNetworkPath::Local ||
        path == MoonlightStreamNetworkPath::Remote;
}

bool validLatencyMode(MoonlightStreamLatencyMode mode) noexcept {
    return mode == MoonlightStreamLatencyMode::LowLatency ||
        mode == MoonlightStreamLatencyMode::Balanced ||
        mode == MoonlightStreamLatencyMode::Smooth;
}

bool validAudioLayout(MoonlightStreamAudioLayout layout) noexcept {
    return layout == MoonlightStreamAudioLayout::Disabled ||
        layout == MoonlightStreamAudioLayout::Stereo ||
        layout == MoonlightStreamAudioLayout::Surround51 ||
        layout == MoonlightStreamAudioLayout::Surround71;
}

bool validEncryptionPolicy(MoonlightStreamEncryptionPolicy policy) noexcept {
    return policy == MoonlightStreamEncryptionPolicy::Auto ||
        policy == MoonlightStreamEncryptionPolicy::Required ||
        policy == MoonlightStreamEncryptionPolicy::Compatible;
}

bool validColorSpace(MoonlightStreamColorSpace colorSpace) noexcept {
    return colorSpace == MoonlightStreamColorSpace::Rec709 ||
        colorSpace == MoonlightStreamColorSpace::Rec2020;
}

bool validColorRange(MoonlightStreamColorRange colorRange) noexcept {
    return colorRange == MoonlightStreamColorRange::Limited ||
        colorRange == MoonlightStreamColorRange::Full;
}

bool validProfile(const MoonlightStreamCodecProfile& profile) noexcept {
    return videoFormatForProfile(profile) != 0;
}

bool validCanonicalOffer(const MoonlightStreamConfigResult& result,
                         bool deferredRuntimeProof) noexcept {
    if (!result.ready()) {
        return false;
    }
    const auto& identity = result.identity;
    const auto& offer = *result.offer;
    const auto& launch = *result.launchProjection;
    if (identity.ownerToken == 0U || identity.sessionGeneration == 0U ||
        identity.settingsRevision == 0U ||
        identity.hostCapabilityGeneration == 0U ||
        (!deferredRuntimeProof &&
         (identity.platformProbeGeneration == 0U ||
          identity.networkCapabilityGeneration == 0U ||
          identity.displayCapabilityGeneration == 0U)) ||
        (deferredRuntimeProof &&
         (identity.platformProbeGeneration != 0U ||
          identity.networkCapabilityGeneration != 0U ||
          identity.displayCapabilityGeneration != 0U)) ||
        !boundedPrintable(identity.hostId, 1U, 128U) ||
        !boundedPrintable(identity.serverUuid, 1U, 128U) ||
        offer.dimensions.width < kMinimumWidth ||
        offer.dimensions.width > kMaximumWidth ||
        offer.dimensions.height < kMinimumHeight ||
        offer.dimensions.height > kMaximumHeight ||
        (offer.dimensions.width % 2) != 0 ||
        (offer.dimensions.height % 2) != 0 ||
        offer.fps < kMinimumFps || offer.fps > kMaximumFps ||
        offer.launchRefreshRate != offer.fps ||
        offer.clientRefreshRateX100 < 0 ||
        offer.clientRefreshRateX100 > kMaximumFps * 100 ||
        (deferredRuntimeProof && offer.clientRefreshRateX100 != 0) ||
        offer.configuredBitrateKbps < kMinimumBitrateKbps ||
        offer.configuredBitrateKbps > kMaximumBitrateKbps ||
        offer.estimatedEncoderBitrateKbps <= 0 ||
        offer.estimatedEncoderBitrateKbps > offer.configuredBitrateKbps ||
        offer.packetSizeBytes <= 0 ||
        offer.packetSizeBytes > kMaximumPacketSizeBytes ||
        (offer.packetSizeBytes % 16) != 0 ||
        (deferredRuntimeProof
             ? offer.networkPath != MoonlightStreamNetworkPath::Unknown
             : !validNetworkPath(offer.networkPath)) ||
        !validLatencyMode(offer.latencyMode) ||
        offer.offeredCodecs.empty() ||
        offer.offeredCodecs.size() > kMaximumCodecProfiles ||
        offer.selectedCodec.has_value() || !offer.colorSpace.has_value() ||
        !offer.colorRange.has_value() || !validColorSpace(*offer.colorSpace) ||
        !validColorRange(*offer.colorRange) || !validAudioLayout(offer.audioLayout) ||
        !validEncryptionPolicy(offer.encryptionPolicy) ||
        (offer.requiredEncryptionStreams & ~kKnownEncryptionStreams) != 0U ||
        (offer.candidateEncryptionStreams & ~kKnownEncryptionStreams) != 0U ||
        (offer.requiredEncryptionStreams & offer.candidateEncryptionStreams) !=
            offer.requiredEncryptionStreams ||
        !offer.remoteInputEncryptionRequired ||
        (offer.encryptionPolicy == MoonlightStreamEncryptionPolicy::Required &&
         offer.requiredEncryptionStreams == MoonlightStreamEncryptNone) ||
        (offer.encryptionPolicy != MoonlightStreamEncryptionPolicy::Required &&
         offer.requiredEncryptionStreams != MoonlightStreamEncryptNone) ||
        (offer.highQualityAudioCandidate &&
         (offer.networkPath != MoonlightStreamNetworkPath::Local ||
          offer.configuredBitrateKbps < 15000 ||
          (offer.audioLayout != MoonlightStreamAudioLayout::Surround51 &&
           offer.audioLayout != MoonlightStreamAudioLayout::Surround71))) ||
        launch.dimensions.width != offer.dimensions.width ||
        launch.dimensions.height != offer.dimensions.height ||
        launch.fps != offer.launchRefreshRate || launch.hdr != offer.hdr ||
        launch.audioLayout != offer.audioLayout ||
        launch.playAudioOnHost != offer.playAudioOnHost ||
        launch.controllerBitmap != 0U || launch.persistGamepadsAfterDisconnect) {
        return false;
    }
    if ((offer.hdr &&
         (*offer.colorSpace != MoonlightStreamColorSpace::Rec2020 ||
          *offer.colorRange != MoonlightStreamColorRange::Limited)) ||
        (!offer.hdr &&
         (*offer.colorSpace != MoonlightStreamColorSpace::Rec709 ||
          *offer.colorRange != MoonlightStreamColorRange::Limited))) {
        return false;
    }

    std::int32_t videoMask = 0;
    std::size_t preferredCount = 0U;
    for (std::size_t index = 0U; index < offer.offeredCodecs.size(); ++index) {
        const auto& candidate = offer.offeredCodecs[index];
        const MoonlightStreamCodecProfile profile {
            candidate.codec, candidate.bitDepth, candidate.chroma};
        const auto bit = videoFormatForProfile(profile);
        const bool hdrCandidate = !offer.hdr ||
            (candidate.codec != MoonlightStreamCodec::H264 &&
             candidate.bitDepth == MoonlightStreamBitDepth::Bit10);
        const bool yuv444Candidate = !offer.yuv444 ||
            candidate.chroma == MoonlightStreamChroma::Yuv444;
        if (bit == 0 || (videoMask & bit) != 0 ||
            (!offer.hdr && candidate.bitDepth != MoonlightStreamBitDepth::Bit8) ||
            (offer.hdr && candidate.codec != MoonlightStreamCodec::H264 &&
             candidate.bitDepth != MoonlightStreamBitDepth::Bit10) ||
            (!offer.yuv444 && candidate.chroma != MoonlightStreamChroma::Yuv420) ||
            (offer.yuv444 && candidate.codec != MoonlightStreamCodec::H264 &&
             candidate.chroma != MoonlightStreamChroma::Yuv444) ||
            candidate.supportsCurrentHdrIntent != hdrCandidate ||
            candidate.supportsCurrentYuv444Intent != yuv444Candidate) {
            return false;
        }
        videoMask |= bit;
        if (candidate.preferred) {
            ++preferredCount;
            if (index != 0U) {
                return false;
            }
        }
    }
    return preferredCount == 1U;
}

std::array<std::uint8_t, kRemoteInputBytes> remoteInputIv(
    std::int32_t keyId) noexcept {
    std::array<std::uint8_t, kRemoteInputBytes> result {};
    const auto bits = static_cast<std::uint32_t>(keyId);
    result[0] = static_cast<std::uint8_t>((bits >> 24U) & 0xffU);
    result[1] = static_cast<std::uint8_t>((bits >> 16U) & 0xffU);
    result[2] = static_cast<std::uint8_t>((bits >> 8U) & 0xffU);
    result[3] = static_cast<std::uint8_t>(bits & 0xffU);
    return result;
}

MoonlightCommonCStage stageFromRaw(std::int32_t stage) noexcept {
    switch (stage) {
        case STAGE_PLATFORM_INIT: return MoonlightCommonCStage::PlatformInit;
        case STAGE_NAME_RESOLUTION: return MoonlightCommonCStage::NameResolution;
        case STAGE_AUDIO_STREAM_INIT: return MoonlightCommonCStage::AudioStreamInit;
        case STAGE_RTSP_HANDSHAKE: return MoonlightCommonCStage::RtspHandshake;
        case STAGE_CONTROL_STREAM_INIT: return MoonlightCommonCStage::ControlStreamInit;
        case STAGE_VIDEO_STREAM_INIT: return MoonlightCommonCStage::VideoStreamInit;
        case STAGE_INPUT_STREAM_INIT: return MoonlightCommonCStage::InputStreamInit;
        case STAGE_CONTROL_STREAM_START: return MoonlightCommonCStage::ControlStreamStart;
        case STAGE_VIDEO_STREAM_START: return MoonlightCommonCStage::VideoStreamStart;
        case STAGE_AUDIO_STREAM_START: return MoonlightCommonCStage::AudioStreamStart;
        case STAGE_INPUT_STREAM_START: return MoonlightCommonCStage::InputStreamStart;
        default: return MoonlightCommonCStage::None;
    }
}

std::size_t stageOrdinal(MoonlightCommonCStage stage) noexcept {
    switch (stage) {
        case MoonlightCommonCStage::PlatformInit: return 1U;
        case MoonlightCommonCStage::NameResolution: return 2U;
        case MoonlightCommonCStage::AudioStreamInit: return 3U;
        case MoonlightCommonCStage::RtspHandshake: return 4U;
        case MoonlightCommonCStage::ControlStreamInit: return 5U;
        case MoonlightCommonCStage::VideoStreamInit: return 6U;
        case MoonlightCommonCStage::InputStreamInit: return 7U;
        case MoonlightCommonCStage::ControlStreamStart: return 8U;
        case MoonlightCommonCStage::VideoStreamStart: return 9U;
        case MoonlightCommonCStage::AudioStreamStart: return 10U;
        case MoonlightCommonCStage::InputStreamStart: return 11U;
        case MoonlightCommonCStage::None: return 0U;
    }
    return 0U;
}

std::int32_t boundedError(std::int32_t error) noexcept {
    constexpr std::int32_t bound = 1000000;
    return std::max(-bound, std::min(error, bound));
}

struct WireProjection final {
    std::string address;
    std::string appVersion;
    std::optional<std::string> gfeVersion;
    std::string rtspSessionUrl;
    std::int32_t serverCodecModeSupport = 0;
    std::int32_t width = 0;
    std::int32_t height = 0;
    std::int32_t fps = 0;
    std::int32_t bitrate = 0;
    std::int32_t packetSize = 0;
    std::int32_t streamingRemotely = 0;
    std::int32_t audioConfiguration = 0;
    std::int32_t supportedVideoFormats = 0;
    std::int32_t clientRefreshRateX100 = 0;
    std::int32_t colorSpace = 0;
    std::int32_t colorRange = 0;
    std::int32_t encryptionFlags = 0;
    std::array<std::uint8_t, kRemoteInputBytes> remoteInputKey {};
    std::array<std::uint8_t, kRemoteInputBytes> remoteInputIv {};

    void cleanse() noexcept {
        secureWipeString(address);
        secureWipeString(appVersion);
        if (gfeVersion.has_value()) {
            secureWipeString(*gfeVersion);
            gfeVersion.reset();
        }
        secureWipeString(rtspSessionUrl);
        secureWipe(remoteInputKey.data(), remoteInputKey.size());
        secureWipe(remoteInputIv.data(), remoteInputIv.size());
        serverCodecModeSupport = 0;
        width = height = fps = bitrate = packetSize = streamingRemotely = 0;
        audioConfiguration = supportedVideoFormats = clientRefreshRateX100 = 0;
        colorSpace = colorRange = encryptionFlags = 0;
    }
};

class DriverPort {
public:
    virtual ~DriverPort() = default;
    virtual int start(const WireProjection& wire) = 0;
    virtual void interrupt() = 0;
    virtual void stop() = 0;
    // Request a decoder refresh without returning DR_NEED_IDR from the video
    // callback. The latter makes common-c hard-gate all predicted frames,
    // which is only appropriate when the decoder cannot accept them.
    virtual void requestIdr() noexcept {}
};

class NullMediaPort final : public MoonlightCommonCMediaPort {
public:
    bool videoReady() const noexcept override { return false; }
    bool audioReady(MoonlightStreamAudioLayout) const noexcept override { return false; }
    bool setupVideo(const MoonlightCommonCVideoSelection&) noexcept override { return false; }
    void startVideo() noexcept override {}
    void stopVideo() noexcept override {}
    void cleanupVideo() noexcept override {}
    MoonlightVideoSubmitResult submitVideoPayload(
        const MoonlightVideoDecodeUnitView& decodeUnit) noexcept override {
        return MoonlightVideoBridge::process().submit(decodeUnit);
    }
    bool setupAudio(const MoonlightCommonCAudioSelection&) noexcept override { return false; }
    void startAudio() noexcept override {}
    void stopAudio() noexcept override {}
    void cleanupAudio() noexcept override {}
    void submitAudioPayload(const std::uint8_t*, std::size_t) noexcept override {}
};

#if defined(RDP_NATIVE_CALLBACK_TESTING)
class TestDriverPort final : public DriverPort {
public:
    explicit TestDriverPort(MoonlightCommonCTestDriver driver)
        : driver_(std::move(driver)) {}
    int start(const WireProjection&) override { return driver_.start(); }
    void interrupt() override { driver_.interrupt(); }
    void stop() override { driver_.stop(); }

private:
    MoonlightCommonCTestDriver driver_;
};
#endif

class Invocation;
class AdapterRuntime;

struct RouterSlot final {
    std::mutex mutex;
    std::weak_ptr<Invocation> invocation;
    MoonlightSessionKey key {};
    std::uint64_t ownerTokenHighWater = 0U;
    std::atomic<std::size_t> staleCallbacks {0U};
};

RouterSlot& routerSlot() {
    static RouterSlot slot;
    return slot;
}

class Invocation final : public std::enable_shared_from_this<Invocation> {
public:
    Invocation(AdapterRuntime* runtime, MoonlightSessionOwner* owner,
               std::shared_ptr<DriverPort> driver,
               std::shared_ptr<MoonlightCommonCMediaPort> media,
               MoonlightCommonCRequest request) noexcept;

    int runStart(MoonlightSessionOwner::StartContext& context);
    void runInterrupt();
    void runStop();
    void noteUserCancel() noexcept;
    void acceptKey(const MoonlightSessionKey& key) noexcept;
    void finalizeBeforeDriverStart() noexcept;

    bool onStageStarting(std::int32_t rawStage) noexcept;
    bool onStageComplete(std::int32_t rawStage) noexcept;
    bool onStageFailed(std::int32_t rawStage, std::int32_t errorCode) noexcept;
    bool onConnectionStarted() noexcept;
    bool onConnectionTerminated(std::int32_t errorCode) noexcept;
    bool onConnectionStatus(std::int32_t rawStatus) noexcept;
    bool onHdrMode(bool enabled) noexcept;
    bool onLogNotice() noexcept;
    int onVideoSetup(std::int32_t rawVideoFormat, std::int32_t width,
                     std::int32_t height, std::int32_t redrawRate) noexcept;
    bool onVideoStart() noexcept;
    bool onVideoStop() noexcept;
    bool onVideoCleanup() noexcept;
    int onVideoPayload(const MoonlightVideoDecodeUnitView& decodeUnit) noexcept;
    int onCommonCVideoPayload(PDECODE_UNIT decodeUnit) noexcept;
    int onAudioInit(std::int32_t rawAudioConfiguration,
                    const MoonlightCommonCOpusConfig& opus) noexcept;
    bool onAudioStart() noexcept;
    bool onAudioStop() noexcept;
    bool onAudioCleanup() noexcept;
    bool onAudioPayload(const std::uint8_t* bytes,
                        std::size_t byteCount) noexcept;

    MoonlightSessionKey key() const noexcept;
    MoonlightCommonCSnapshot snapshot() const noexcept;
    std::vector<MoonlightCommonCEvent> drainEvents() noexcept;
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    MoonlightCommonCTestWireSnapshot testWireSnapshot() const noexcept;
    bool testFinalizing() const noexcept;
#endif

private:
    class CallbackLease final {
    public:
        CallbackLease() noexcept = default;
        CallbackLease(Invocation* invocation,
                      MoonlightSessionOwner::AdmissionLease ownerLease) noexcept
            : invocation_(invocation), ownerLease_(std::move(ownerLease)),
              counted_(invocation != nullptr) {}
        ~CallbackLease() { reset(); }

        CallbackLease(const CallbackLease&) = delete;
        CallbackLease& operator=(const CallbackLease&) = delete;
        CallbackLease(CallbackLease&& other) noexcept
            : invocation_(other.invocation_),
              ownerLease_(std::move(other.ownerLease_)),
              counted_(other.counted_) {
            other.invocation_ = nullptr;
            other.counted_ = false;
        }
        CallbackLease& operator=(CallbackLease&& other) noexcept {
            if (this != &other) {
                reset();
                invocation_ = other.invocation_;
                ownerLease_ = std::move(other.ownerLease_);
                counted_ = other.counted_;
                other.invocation_ = nullptr;
                other.counted_ = false;
            }
            return *this;
        }

        bool valid() const noexcept { return counted_; }
        void reset() noexcept {
            if (!counted_) {
                ownerLease_.reset();
                return;
            }
            ownerLease_.reset();
            auto* invocation = invocation_;
            invocation_ = nullptr;
            counted_ = false;
            invocation->releaseCallback();
        }

    private:
        Invocation* invocation_ = nullptr;
        MoonlightSessionOwner::AdmissionLease ownerLease_;
        bool counted_ = false;
    };

    bool installRouter() noexcept;
    void retireRouter() noexcept;
    CallbackLease acquireCallback() noexcept;
    CallbackLease acquireLifecycleCallback() noexcept;
    void releaseCallback() noexcept;
    void protocolFailure(MoonlightCommonCCode code,
                         std::int32_t rawError = 0) noexcept;
    void maybeEmitNegotiatedLocked() noexcept;
    void pushEventLocked(MoonlightCommonCEvent event) noexcept;
    void finalize(bool driverException = false) noexcept;
    void runTerminalInputTeardown() noexcept;
    void notifyTerminalComplete() noexcept;
    void cleanseLocked() noexcept;
    bool lifecycleCallbackAllowedLocked() const noexcept;
    bool bindVideoIdentityLocked(MoonlightVideoDecodeUnitView& decodeUnit) noexcept;
    int requestVideoIdrOnceLocked() noexcept;
    int mapVideoSubmitResultLocked(
        const MoonlightVideoDecodeUnitView& decodeUnit,
        const MoonlightVideoSubmitResult& result) noexcept;

    AdapterRuntime* const runtime_;
    MoonlightSessionOwner* const owner_;
    const std::shared_ptr<DriverPort> driver_;
    const std::shared_ptr<MoonlightCommonCMediaPort> media_;
    MoonlightCommonCRequest request_;
    mutable std::mutex mutex_;
    std::condition_variable callbackCv_;
    MoonlightSessionKey key_ {};
    WireProjection wire_;
    MoonlightSessionOwner::StartContext* startContext_ = nullptr;
    MoonlightCommonCStage activeStage_ = MoonlightCommonCStage::None;
    MoonlightCommonCStage lastCompletedStage_ = MoonlightCommonCStage::None;
    MoonlightCommonCStage pendingStage_ = MoonlightCommonCStage::None;
    MoonlightCommonCCode pendingCode_ = MoonlightCommonCCode::None;
    std::int32_t pendingRawError_ = 0;
    bool firstStageFenceSeen_ = false;
    bool protocolViolation_ = false;
    bool transportReady_ = false;
    bool terminal_ = false;
    bool terminalEmitted_ = false;
    bool finalizing_ = false;
    bool secretsCleared_ = false;
    bool routerInstalled_ = false;
    bool nativeCallActive_ = false;
    bool negotiatedEmitted_ = false;
    bool videoSetupActive_ = false;
    bool videoStartActive_ = false;
    bool videoStarted_ = false;
    bool videoStopped_ = false;
    bool videoCleaned_ = false;
    bool videoIdrRequestPending_ = false;
    bool audioSetupActive_ = false;
    bool audioStartActive_ = false;
    bool audioStarted_ = false;
    bool audioStopped_ = false;
    bool audioCleaned_ = false;
    bool mediaBound_ = false;
    bool mediaReleased_ = false;
    bool terminalInputTeardownDone_ = false;
    bool terminalCompletionNotified_ = false;
    std::uint64_t nextSequence_ = 1U;
    std::size_t droppedEvents_ = 0U;
    std::size_t staleBaseline_ = 0U;
    std::size_t inFlightCallbacks_ = 0U;
    std::optional<MoonlightCommonCVideoSelection> video_;
    std::optional<MoonlightCommonCAudioSelection> audio_;
    std::deque<MoonlightCommonCEvent> events_;
};

std::shared_ptr<Invocation> routedInvocation() noexcept {
    auto& slot = routerSlot();
    std::lock_guard<std::mutex> lock(slot.mutex);
    auto invocation = slot.invocation.lock();
    if (invocation == nullptr || !slot.key.valid()) {
        slot.staleCallbacks.fetch_add(1U, std::memory_order_relaxed);
        return nullptr;
    }
    return invocation;
}

bool routeStageStarting(std::int32_t stage) noexcept {
    const auto invocation = routedInvocation();
    return invocation != nullptr && invocation->onStageStarting(stage);
}
bool routeStageComplete(std::int32_t stage) noexcept {
    const auto invocation = routedInvocation();
    return invocation != nullptr && invocation->onStageComplete(stage);
}
bool routeStageFailed(std::int32_t stage, std::int32_t error) noexcept {
    const auto invocation = routedInvocation();
    return invocation != nullptr && invocation->onStageFailed(stage, error);
}
bool routeConnectionStarted() noexcept {
    const auto invocation = routedInvocation();
    return invocation != nullptr && invocation->onConnectionStarted();
}
bool routeConnectionTerminated(std::int32_t error) noexcept {
    const auto invocation = routedInvocation();
    return invocation != nullptr && invocation->onConnectionTerminated(error);
}
bool routeConnectionStatus(std::int32_t status) noexcept {
    const auto invocation = routedInvocation();
    return invocation != nullptr && invocation->onConnectionStatus(status);
}
bool routeHdrMode(bool enabled) noexcept {
    const auto invocation = routedInvocation();
    return invocation != nullptr && invocation->onHdrMode(enabled);
}
bool routeLogNotice() noexcept {
    const auto invocation = routedInvocation();
    return invocation != nullptr && invocation->onLogNotice();
}
int routeVideoSetup(std::int32_t format, std::int32_t width,
                    std::int32_t height, std::int32_t redrawRate) noexcept {
    const auto invocation = routedInvocation();
    return invocation == nullptr ? -1
                                 : invocation->onVideoSetup(format, width, height,
                                                            redrawRate);
}
bool routeVideoStart() noexcept {
    const auto invocation = routedInvocation();
    return invocation != nullptr && invocation->onVideoStart();
}
bool routeVideoStop() noexcept {
    const auto invocation = routedInvocation();
    return invocation != nullptr && invocation->onVideoStop();
}
bool routeVideoCleanup() noexcept {
    const auto invocation = routedInvocation();
    return invocation != nullptr && invocation->onVideoCleanup();
}
#if defined(RDP_NATIVE_CALLBACK_TESTING)
int routeVideoPayload(const MoonlightVideoDecodeUnitView& decodeUnit) noexcept {
    const auto invocation = routedInvocation();
    return invocation == nullptr ? DR_NEED_IDR
                                 : invocation->onVideoPayload(decodeUnit);
}
#endif
#if !defined(RDP_TESTS_ONLY)
int routeCommonCVideoPayload(PDECODE_UNIT decodeUnit) noexcept {
    const auto invocation = routedInvocation();
    return invocation == nullptr ? DR_NEED_IDR
                                 : invocation->onCommonCVideoPayload(decodeUnit);
}
#endif
int routeAudioInit(std::int32_t configuration,
                   const MoonlightCommonCOpusConfig& opus) noexcept {
    const auto invocation = routedInvocation();
    return invocation == nullptr ? -1 : invocation->onAudioInit(configuration, opus);
}
bool routeAudioStart() noexcept {
    const auto invocation = routedInvocation();
    return invocation != nullptr && invocation->onAudioStart();
}
bool routeAudioStop() noexcept {
    const auto invocation = routedInvocation();
    return invocation != nullptr && invocation->onAudioStop();
}
bool routeAudioCleanup() noexcept {
    const auto invocation = routedInvocation();
    return invocation != nullptr && invocation->onAudioCleanup();
}
bool routeAudioPayload(const std::uint8_t* bytes, std::size_t count) noexcept {
    const auto invocation = routedInvocation();
    return invocation != nullptr && invocation->onAudioPayload(bytes, count);
}

void routeRawAudioPayload(const std::uint8_t* bytes, std::int32_t count) noexcept {
    if (bytes == nullptr && count == 0) {
        (void)routeAudioPayload(nullptr, 0U);
    } else if (bytes != nullptr && count > 0) {
        (void)routeAudioPayload(bytes, static_cast<std::size_t>(count));
    }
}

#if !defined(RDP_TESTS_ONLY)
void commonStageStarting(int stage) { (void)routeStageStarting(stage); }
void commonStageComplete(int stage) { (void)routeStageComplete(stage); }
void commonStageFailed(int stage, int error) { (void)routeStageFailed(stage, error); }
void commonConnectionStarted() { (void)routeConnectionStarted(); }
void commonConnectionTerminated(int error) { (void)routeConnectionTerminated(error); }
void commonLogMessage(const char* format, ...) {
    if (format != nullptr) {
        char message[1024] {};
        va_list arguments;
        va_start(arguments, format);
        const int written = std::vsnprintf(
            message, sizeof(message), format, arguments);
        va_end(arguments);
        if (written > 0) {
            std::size_t length = std::min<std::size_t>(
                static_cast<std::size_t>(written), sizeof(message) - 1U);
            while (length != 0U &&
                   (message[length - 1U] == '\n' ||
                    message[length - 1U] == '\r')) {
                message[--length] = '\0';
            }
            if (length != 0U) {
                OH_LOG_INFO(LOG_APP, "%{public}s", message);
            }
        }
    }
    (void)routeLogNotice();
}
void commonRumble(unsigned short, unsigned short, unsigned short) {}
void commonConnectionStatus(int status) { (void)routeConnectionStatus(status); }
void commonHdrMode(bool enabled) { (void)routeHdrMode(enabled); }
void commonRumbleTriggers(std::uint16_t, std::uint16_t, std::uint16_t) {}
void commonMotionState(std::uint16_t, std::uint8_t, std::uint16_t) {}
void commonControllerLed(std::uint16_t, std::uint8_t, std::uint8_t, std::uint8_t) {}
void commonAdaptiveTriggers(std::uint16_t, std::uint8_t, std::uint8_t, std::uint8_t,
                            std::uint8_t*, std::uint8_t*) {}
int commonVideoSetup(int format, int width, int height, int redrawRate, void*, int) {
    return routeVideoSetup(format, width, height, redrawRate);
}
void commonVideoStart() { (void)routeVideoStart(); }
void commonVideoStop() { (void)routeVideoStop(); }
void commonVideoCleanup() { (void)routeVideoCleanup(); }
int commonVideoPayload(PDECODE_UNIT decodeUnit) {
    return routeCommonCVideoPayload(decodeUnit);
}
int commonAudioInit(int configuration, const POPUS_MULTISTREAM_CONFIGURATION opus,
                    void*, int) {
    if (opus == nullptr) {
        return -1;
    }
    MoonlightCommonCOpusConfig mapped;
    mapped.sampleRate = opus->sampleRate;
    mapped.channelCount = opus->channelCount;
    mapped.streams = opus->streams;
    mapped.coupledStreams = opus->coupledStreams;
    mapped.samplesPerFrame = opus->samplesPerFrame;
    std::copy(std::begin(opus->mapping), std::end(opus->mapping), mapped.mapping.begin());
    return routeAudioInit(configuration, mapped);
}
void commonAudioStart() { (void)routeAudioStart(); }
void commonAudioStop() { (void)routeAudioStop(); }
void commonAudioCleanup() { (void)routeAudioCleanup(); }
void commonAudioPayload(char* bytes, int count) {
    routeRawAudioPayload(reinterpret_cast<const std::uint8_t*>(bytes), count);
}

class ProductDriverPort final : public DriverPort {
public:
    int start(const WireProjection& wire) override {
        SERVER_INFORMATION server;
        STREAM_CONFIGURATION stream;
        CONNECTION_LISTENER_CALLBACKS connectionCallbacks;
        DECODER_RENDERER_CALLBACKS videoCallbacks;
        AUDIO_RENDERER_CALLBACKS audioCallbacks;
        LiInitializeServerInformation(&server);
        LiInitializeStreamConfiguration(&stream);
        LiInitializeConnectionCallbacks(&connectionCallbacks);
        LiInitializeVideoCallbacks(&videoCallbacks);
        LiInitializeAudioCallbacks(&audioCallbacks);

        server.address = wire.address.c_str();
        server.serverInfoAppVersion = wire.appVersion.c_str();
        server.serverInfoGfeVersion = wire.gfeVersion.has_value()
                                          ? wire.gfeVersion->c_str()
                                          : nullptr;
        server.rtspSessionUrl = wire.rtspSessionUrl.c_str();
        server.serverCodecModeSupport = wire.serverCodecModeSupport;
        stream.width = wire.width;
        stream.height = wire.height;
        stream.fps = wire.fps;
        stream.bitrate = wire.bitrate;
        stream.packetSize = wire.packetSize;
        stream.streamingRemotely = wire.streamingRemotely;
        stream.audioConfiguration = wire.audioConfiguration;
        stream.supportedVideoFormats = wire.supportedVideoFormats;
        stream.clientRefreshRateX100 = wire.clientRefreshRateX100;
        stream.colorSpace = wire.colorSpace;
        stream.colorRange = wire.colorRange;
        stream.encryptionFlags = wire.encryptionFlags;
        std::memcpy(stream.remoteInputAesKey, wire.remoteInputKey.data(),
                    wire.remoteInputKey.size());
        std::memcpy(stream.remoteInputAesIv, wire.remoteInputIv.data(),
                    wire.remoteInputIv.size());

        connectionCallbacks.stageStarting = commonStageStarting;
        connectionCallbacks.stageComplete = commonStageComplete;
        connectionCallbacks.stageFailed = commonStageFailed;
        connectionCallbacks.connectionStarted = commonConnectionStarted;
        connectionCallbacks.connectionTerminated = commonConnectionTerminated;
        connectionCallbacks.logMessage = commonLogMessage;
        connectionCallbacks.rumble = commonRumble;
        connectionCallbacks.connectionStatusUpdate = commonConnectionStatus;
        connectionCallbacks.setHdrMode = commonHdrMode;
        connectionCallbacks.rumbleTriggers = commonRumbleTriggers;
        connectionCallbacks.setMotionEventState = commonMotionState;
        connectionCallbacks.setControllerLED = commonControllerLed;
        connectionCallbacks.setAdaptiveTriggers = commonAdaptiveTriggers;
        videoCallbacks.setup = commonVideoSetup;
        videoCallbacks.start = commonVideoStart;
        videoCallbacks.stop = commonVideoStop;
        videoCallbacks.cleanup = commonVideoCleanup;
        videoCallbacks.submitDecodeUnit = commonVideoPayload;
        videoCallbacks.capabilities = 0;
        audioCallbacks.init = commonAudioInit;
        audioCallbacks.start = commonAudioStart;
        audioCallbacks.stop = commonAudioStop;
        audioCallbacks.cleanup = commonAudioCleanup;
        audioCallbacks.decodeAndPlaySample = commonAudioPayload;
        audioCallbacks.capabilities = 0;

        const int result = LiStartConnection(
            &server, &stream, &connectionCallbacks, &videoCallbacks,
            &audioCallbacks, nullptr, 0, nullptr, 0);
        if (result != 0) {
            // A failed LiStartConnection() has already completed its internal
            // LiStopConnection() unwind, so no common-c worker can still read
            // the process-global remote input material.
            clearCommonCGlobalRemoteInputSecrets();
        }
        secureWipe(&stream, sizeof(stream));
        secureWipe(&server, sizeof(server));
        secureWipe(&connectionCallbacks, sizeof(connectionCallbacks));
        secureWipe(&videoCallbacks, sizeof(videoCallbacks));
        secureWipe(&audioCallbacks, sizeof(audioCallbacks));
        return result;
    }
    void interrupt() override { LiInterruptConnection(); }
    void requestIdr() noexcept override { LiRequestIdrFrame(); }
    void stop() override {
        LiStopConnection();
        // LiStopConnection() joins/stops every stream before returning.
        clearCommonCGlobalRemoteInputSecrets();
    }
};
#endif

class AdapterRuntime final {
public:
    AdapterRuntime(MoonlightSessionOwner& owner,
                   std::shared_ptr<DriverPort> driver,
                   std::shared_ptr<MoonlightCommonCMediaPort> media,
                   std::function<std::uint64_t()> clock,
                   bool manualClock)
        : owner_(&owner), driver_(std::move(driver)), media_(std::move(media)),
          clock_(std::move(clock)), manualClock_(manualClock),
          scheduler_([this]() { schedulerLoop(); }) {}

    ~AdapterRuntime() { shutdown(); }

    MoonlightCommonCStartResult start(
        MoonlightCommonCRequest request,
        std::shared_ptr<MoonlightCommonCMediaPort> mediaOverride = nullptr) noexcept;
    MoonlightStopStatus requestStop(const MoonlightSessionKey& key) noexcept;
    MoonlightStopStatus stop(const MoonlightSessionKey& key,
                             std::chrono::milliseconds timeout) noexcept;
    MoonlightCommonCSnapshot snapshot(const MoonlightSessionKey& key) const noexcept;
    std::vector<MoonlightCommonCEvent> drainEvents(
        const MoonlightSessionKey& key) noexcept;
    void armDeadline(const MoonlightSessionKey& key, std::uint64_t overall,
                     std::uint64_t stage) noexcept;
    bool bindActiveKey(const std::shared_ptr<Invocation>& invocation,
                       const MoonlightSessionKey& key) noexcept;
    void clearDeadline(const MoonlightSessionKey& key) noexcept;
    bool deadlineFired(const MoonlightSessionKey& key) const noexcept;
    void complete(const std::shared_ptr<Invocation>& invocation) noexcept;
    void notifyClock() noexcept { schedulerCv_.notify_all(); }
    void shutdown() noexcept;

private:
    void schedulerLoop() noexcept;
    std::shared_ptr<Invocation> findInvocationLocked(
        const MoonlightSessionKey& key) const noexcept;

    MoonlightSessionOwner* const owner_;
    const std::shared_ptr<DriverPort> driver_;
    const std::shared_ptr<MoonlightCommonCMediaPort> media_;
    const std::function<std::uint64_t()> clock_;
    const bool manualClock_;
    mutable std::mutex mutex_;
    std::condition_variable schedulerCv_;
    bool shuttingDown_ = false;
    std::shared_ptr<Invocation> active_;
    std::shared_ptr<Invocation> last_;
    MoonlightSessionKey activeKey_ {};
    MoonlightSessionKey lastKey_ {};
    MoonlightSessionKey deadlineKey_ {};
    MoonlightSessionKey deadlineFiredKey_ {};
    std::uint64_t overallDeadline_ = 0U;
    std::uint64_t stageDeadline_ = 0U;
    std::thread scheduler_;
};

std::uint64_t steadyMonotonicMs() noexcept {
    return static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
}

bool validDeadlines(const MoonlightCommonCDeadlineSet& deadlines,
                    std::uint64_t now) noexcept {
    if (deadlines.overallMonotonicMs <= now ||
        deadlines.overallMonotonicMs - now > kMaximumDeadlineWindowMs) {
        return false;
    }
    return std::all_of(deadlines.stageMonotonicMs.begin(),
                       deadlines.stageMonotonicMs.end(),
                       [&](std::uint64_t deadline) {
        return deadline > now && deadline <= deadlines.overallMonotonicMs;
    });
}

bool validOpus(const MoonlightCommonCOpusConfig& opus,
               std::int32_t expectedChannels) noexcept {
    if (opus.sampleRate != 48000 || opus.channelCount != expectedChannels ||
        opus.channelCount < 1 || opus.channelCount > 8 || opus.streams < 1 ||
        opus.streams > opus.channelCount || opus.coupledStreams < 0 ||
        opus.coupledStreams > opus.streams ||
        opus.streams + opus.coupledStreams != opus.channelCount ||
        opus.samplesPerFrame < 120 || opus.samplesPerFrame > 5760 ||
        (opus.samplesPerFrame % 120) != 0) {
        return false;
    }
    std::array<bool, 8U> seen {};
    for (std::int32_t index = 0; index < opus.channelCount; ++index) {
        const auto mapped = opus.mapping[static_cast<std::size_t>(index)];
        if (mapped >= static_cast<std::uint8_t>(opus.channelCount) || seen[mapped]) {
            return false;
        }
        seen[mapped] = true;
    }
    for (std::size_t index = static_cast<std::size_t>(opus.channelCount);
         index < opus.mapping.size(); ++index) {
        if (opus.mapping[index] != 0U) {
            return false;
        }
    }
    return true;
}

} // namespace

struct MoonlightCommonCAdapterAccess final {
    static void cleanse(MoonlightRtspLaunchLease& lease) noexcept {
        secureWipe(lease.remoteInputKey_.data(), lease.remoteInputKey_.size());
        secureWipeString(lease.rtspSessionUrl_);
        secureWipeString(lease.hostId_);
        secureWipeString(lease.serverUuid_);
        lease.remoteInputKeyId_ = 0;
        lease.accountOwnerToken_ = 0U;
        lease.sessionGeneration_ = 0U;
        lease.hostCapabilityGeneration_ = 0U;
        lease.settingsRevision_ = 0U;
        lease.boundSessionOwnerToken_ = 0U;
        lease.consumed_ = true;
    }

    static bool matches(const MoonlightRtspLaunchLease& lease,
                        const MoonlightCommonCRequest& request) noexcept {
        const auto& identity = request.streamConfig.identity;
        return lease.valid() && lease.accountOwnerToken_ == request.accountOwnerToken &&
            lease.sessionGeneration_ == request.generation &&
            lease.hostId_ == identity.hostId &&
            lease.serverUuid_ == identity.serverUuid &&
            lease.hostCapabilityGeneration_ == identity.hostCapabilityGeneration &&
            lease.settingsRevision_ == identity.settingsRevision;
    }

    static bool bindAndProject(MoonlightRtspLaunchLease& lease,
                               const MoonlightSessionKey& key,
                               WireProjection& wire) noexcept {
        if (!lease.valid() || !key.valid() || lease.consumed_ ||
            lease.boundSessionOwnerToken_ != 0U ||
            lease.sessionGeneration_ != key.generation) {
            return false;
        }
        lease.boundSessionOwnerToken_ = key.ownerToken;
        lease.consumed_ = true;
        wire.rtspSessionUrl = lease.rtspSessionUrl_;
        wire.remoteInputKey = lease.remoteInputKey_;
        wire.remoteInputIv = remoteInputIv(lease.remoteInputKeyId_);
        return true;
    }
};

MoonlightRtspLaunchLease::MoonlightRtspLaunchLease(
    std::array<std::uint8_t, 16U> remoteInputKey,
    std::int32_t remoteInputKeyId,
    std::string rtspSessionUrl,
    std::uint64_t accountOwnerToken,
    std::uint64_t sessionGeneration,
    std::string hostId,
    std::string serverUuid,
    std::uint64_t hostCapabilityGeneration,
    std::uint64_t settingsRevision) noexcept
    : remoteInputKey_(remoteInputKey), remoteInputKeyId_(remoteInputKeyId),
      rtspSessionUrl_(std::move(rtspSessionUrl)),
      accountOwnerToken_(accountOwnerToken),
      sessionGeneration_(sessionGeneration), hostId_(std::move(hostId)),
      serverUuid_(std::move(serverUuid)),
      hostCapabilityGeneration_(hostCapabilityGeneration),
      settingsRevision_(settingsRevision) {}

MoonlightRtspLaunchLease::~MoonlightRtspLaunchLease() {
    MoonlightCommonCAdapterAccess::cleanse(*this);
}

MoonlightRtspLaunchLease::MoonlightRtspLaunchLease(
    MoonlightRtspLaunchLease&& other) noexcept
    : remoteInputKey_(other.remoteInputKey_),
      remoteInputKeyId_(other.remoteInputKeyId_),
      rtspSessionUrl_(std::move(other.rtspSessionUrl_)),
      accountOwnerToken_(other.accountOwnerToken_),
      sessionGeneration_(other.sessionGeneration_), hostId_(std::move(other.hostId_)),
      serverUuid_(std::move(other.serverUuid_)),
      hostCapabilityGeneration_(other.hostCapabilityGeneration_),
      settingsRevision_(other.settingsRevision_),
      boundSessionOwnerToken_(other.boundSessionOwnerToken_),
      consumed_(other.consumed_) {
    MoonlightCommonCAdapterAccess::cleanse(other);
}

MoonlightRtspLaunchLease& MoonlightRtspLaunchLease::operator=(
    MoonlightRtspLaunchLease&& other) noexcept {
    if (this != &other) {
        MoonlightCommonCAdapterAccess::cleanse(*this);
        remoteInputKey_ = other.remoteInputKey_;
        remoteInputKeyId_ = other.remoteInputKeyId_;
        rtspSessionUrl_ = std::move(other.rtspSessionUrl_);
        accountOwnerToken_ = other.accountOwnerToken_;
        sessionGeneration_ = other.sessionGeneration_;
        hostId_ = std::move(other.hostId_);
        serverUuid_ = std::move(other.serverUuid_);
        hostCapabilityGeneration_ = other.hostCapabilityGeneration_;
        settingsRevision_ = other.settingsRevision_;
        boundSessionOwnerToken_ = other.boundSessionOwnerToken_;
        consumed_ = other.consumed_;
        MoonlightCommonCAdapterAccess::cleanse(other);
    }
    return *this;
}

bool MoonlightRtspLaunchLease::valid() const noexcept {
    return !consumed_ && accountOwnerToken_ != 0U && sessionGeneration_ != 0U &&
        hostCapabilityGeneration_ != 0U && settingsRevision_ != 0U &&
        !hostId_.empty() && !serverUuid_.empty() && validRtspUrl(rtspSessionUrl_);
}

namespace {

Invocation::Invocation(AdapterRuntime* runtime, MoonlightSessionOwner* owner,
                       std::shared_ptr<DriverPort> driver,
                       std::shared_ptr<MoonlightCommonCMediaPort> media,
                       MoonlightCommonCRequest request) noexcept
    : runtime_(runtime), owner_(owner), driver_(std::move(driver)),
      media_(std::move(media)), request_(std::move(request)),
      staleBaseline_(routerSlot().staleCallbacks.load(std::memory_order_relaxed)) {}

MoonlightSessionKey Invocation::key() const noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return key_;
}

bool Invocation::installRouter() noexcept {
    MoonlightSessionKey installKey;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (routerInstalled_ || !key_.valid()) {
            return false;
        }
        installKey = key_;
    }
    auto& slot = routerSlot();
    {
        std::lock_guard<std::mutex> lock(slot.mutex);
        if (!slot.invocation.expired() ||
            installKey.ownerToken <= slot.ownerTokenHighWater) {
            return false;
        }
        slot.key = installKey;
        slot.invocation = shared_from_this();
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        routerInstalled_ = true;
    }
    return true;
}

void Invocation::retireRouter() noexcept {
    MoonlightSessionKey retireKey;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!routerInstalled_) {
            return;
        }
        routerInstalled_ = false;
        retireKey = key_;
    }
    auto& slot = routerSlot();
    std::lock_guard<std::mutex> lock(slot.mutex);
    const auto current = slot.invocation.lock();
    if (current.get() == this && slot.key == retireKey) {
        slot.ownerTokenHighWater = std::max(
            slot.ownerTokenHighWater, retireKey.ownerToken);
        slot.invocation.reset();
        slot.key = {};
    }
}

void Invocation::pushEventLocked(MoonlightCommonCEvent event) noexcept {
    event.key = key_;
    event.sequence = nextSequence_++;
    if (events_.size() == kMaximumEvents) {
        events_.pop_front();
        ++droppedEvents_;
    }
    events_.push_back(std::move(event));
}

Invocation::CallbackLease Invocation::acquireCallback() noexcept {
    const auto currentKey = key();
    auto ownerLease = owner_ == nullptr
                          ? MoonlightSessionOwner::AdmissionLease {}
                          : owner_->acquireCallback(currentKey);
    if (!ownerLease.valid()) {
        return {};
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (finalizing_ || terminal_) {
            return {};
        }
        ++inFlightCallbacks_;
    }
    return CallbackLease(this, std::move(ownerLease));
}

Invocation::CallbackLease Invocation::acquireLifecycleCallback() noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    if (finalizing_ || !lifecycleCallbackAllowedLocked()) {
        return {};
    }
    ++inFlightCallbacks_;
    return CallbackLease(this, MoonlightSessionOwner::AdmissionLease {});
}

void Invocation::releaseCallback() noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    if (inFlightCallbacks_ != 0U) {
        --inFlightCallbacks_;
    }
    callbackCv_.notify_all();
}

int Invocation::runStart(MoonlightSessionOwner::StartContext& context) {
    const auto startKey = context.key();
    acceptKey(startKey);
    if (!runtime_->bindActiveKey(shared_from_this(), startKey)) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            pendingCode_ = MoonlightCommonCCode::Busy;
        }
        finalize();
        return -1;
    }
    bool mediaBound = false;
    bool mediaReady = false;
    try {
        mediaBound = media_ != nullptr && media_->bindSession(startKey);
        mediaReady = mediaBound && media_->videoReady() &&
            media_->audioReady(request_.streamConfig.offer->audioLayout);
    } catch (...) {
        mediaReady = false;
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        mediaBound_ = mediaBound;
        if (!mediaReady) {
            pendingCode_ = MoonlightCommonCCode::RuntimeProofRequired;
        }
    }
    if (!mediaReady) {
        finalize();
        return -1;
    }
    bool leaseBound = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        startContext_ = &context;
        wire_.address = request_.server.address;
        wire_.appVersion = request_.server.appVersion;
        wire_.gfeVersion = request_.server.gfeVersion;
        const auto& offer = *request_.streamConfig.offer;
        wire_.width = offer.dimensions.width;
        wire_.height = offer.dimensions.height;
        wire_.fps = offer.fps;
        wire_.bitrate = offer.configuredBitrateKbps;
        wire_.packetSize = offer.packetSizeBytes;
        switch (offer.networkPath) {
            case MoonlightStreamNetworkPath::Local:
                wire_.streamingRemotely = STREAM_CFG_LOCAL;
                break;
            case MoonlightStreamNetworkPath::Remote:
                wire_.streamingRemotely = STREAM_CFG_REMOTE;
                break;
            case MoonlightStreamNetworkPath::Unknown:
                wire_.streamingRemotely = STREAM_CFG_AUTO;
                break;
        }
        wire_.audioConfiguration = audioConfigurationForLayout(offer.audioLayout);
        for (const auto& offered : offer.offeredCodecs) {
            const MoonlightStreamCodecProfile profile {
                offered.codec, offered.bitDepth, offered.chroma};
            wire_.supportedVideoFormats |= videoFormatForProfile(profile);
        }
        for (const auto& serverProfile : request_.server.codecProfiles) {
            wire_.serverCodecModeSupport |= serverCodecForProfile(serverProfile);
        }
        wire_.clientRefreshRateX100 = offer.clientRefreshRateX100;
        wire_.colorSpace = *offer.colorSpace == MoonlightStreamColorSpace::Rec2020
                               ? COLORSPACE_REC_2020
                               : COLORSPACE_REC_709;
        wire_.colorRange = *offer.colorRange == MoonlightStreamColorRange::Full
                               ? COLOR_RANGE_FULL
                               : COLOR_RANGE_LIMITED;
        wire_.encryptionFlags = static_cast<std::int32_t>(
            offer.candidateEncryptionStreams &
            (MoonlightStreamEncryptAudio | MoonlightStreamEncryptVideo));
        leaseBound = MoonlightCommonCAdapterAccess::bindAndProject(
            request_.launchLease, key_, wire_);
        if (!leaseBound) {
            pendingCode_ = MoonlightCommonCCode::InvalidRequest;
            startContext_ = nullptr;
            nativeCallActive_ = false;
        } else {
            MoonlightCommonCEvent event;
            event.type = MoonlightCommonCEventType::Starting;
            pushEventLocked(std::move(event));
            nativeCallActive_ = true;
        }
    }
    if (!leaseBound) {
        // A validated lease can fail here only if ownership changed between
        // admission and the exact StartContext binding. Fail closed without
        // entering common-c or leaving the runtime active.
        finalize();
        return -1;
    }

    if (!installRouter()) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            pendingCode_ = MoonlightCommonCCode::Busy;
            startContext_ = nullptr;
            nativeCallActive_ = false;
        }
        finalize();
        return -1;
    }
    runtime_->armDeadline(startKey, request_.deadlines.overallMonotonicMs, 0U);

    int result = -1;
    try {
        result = driver_->start(wire_);
    } catch (...) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            startContext_ = nullptr;
            nativeCallActive_ = false;
            pendingCode_ = MoonlightCommonCCode::DriverException;
        }
        finalize(true);
        throw;
    }

    {
        std::lock_guard<std::mutex> lock(mutex_);
        startContext_ = nullptr;
        nativeCallActive_ = false;
        const bool missingSuccessProof = result == 0 &&
            (!transportReady_ || !negotiatedEmitted_);
        if (missingSuccessProof) {
            result = -1;
            protocolViolation_ = true;
            pendingCode_ = MoonlightCommonCCode::ProtocolViolation;
            pendingStage_ = activeStage_;
        }
        if (result != 0 && pendingCode_ == MoonlightCommonCCode::None) {
            pendingCode_ = MoonlightCommonCCode::CommonCStartFailed;
            pendingRawError_ = boundedError(result);
        }
    }
    if (result != 0) {
        finalize();
    }
    return result;
}

void Invocation::runInterrupt() {
    try {
        driver_->interrupt();
    } catch (...) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            pendingCode_ = MoonlightCommonCCode::DriverException;
        }
        throw;
    }
}

void Invocation::runStop() {
    runTerminalInputTeardown();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        nativeCallActive_ = true;
    }
    try {
        driver_->stop();
    } catch (...) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            nativeCallActive_ = false;
            pendingCode_ = MoonlightCommonCCode::DriverException;
        }
        finalize(true);
        throw;
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        nativeCallActive_ = false;
    }
    finalize();
}

void Invocation::runTerminalInputTeardown() noexcept {
    std::function<void(const MoonlightSessionKey&)> callback;
    MoonlightSessionKey callbackKey;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (terminalInputTeardownDone_) {
            return;
        }
        terminalInputTeardownDone_ = true;
        callback = std::move(request_.terminalInputTeardown);
        callbackKey = key_;
    }
    if (callback && callbackKey.valid()) {
        try {
            callback(callbackKey);
        } catch (...) {
            // Teardown is best effort but must never abort owner completion.
        }
    }
}

void Invocation::notifyTerminalComplete() noexcept {
    std::function<void(const MoonlightSessionKey&)> callback;
    MoonlightSessionKey callbackKey;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (terminalCompletionNotified_) {
            return;
        }
        terminalCompletionNotified_ = true;
        callback = std::move(request_.terminalComplete);
        callbackKey = key_;
    }
    if (callback && callbackKey.valid()) {
        try {
            callback(callbackKey);
        } catch (...) {
            // Product state cleanup cannot be allowed to escape this worker.
        }
    }
}

void Invocation::noteUserCancel() noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!terminalEmitted_ &&
        (pendingCode_ == MoonlightCommonCCode::None ||
         pendingCode_ == MoonlightCommonCCode::CommonCStartFailed)) {
        // LiStartConnection() can return its generic failure concurrently with
        // an accepted owner stop while finalization is still draining media
        // callbacks. Make that race order-independent: an explicit stop owns
        // the generic start-failure terminal reason, while specific protocol,
        // negotiation, media, deadline, and driver failures remain intact.
        pendingCode_ = MoonlightCommonCCode::Cancelled;
    }
}

void Invocation::acceptKey(const MoonlightSessionKey& key) noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!key_.valid() || key_ == key) {
        key_ = key;
    } else {
        protocolViolation_ = true;
        pendingCode_ = MoonlightCommonCCode::ProtocolViolation;
    }
}

void Invocation::finalizeBeforeDriverStart() noexcept {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (terminal_ || nativeCallActive_ || routerInstalled_) {
            return;
        }
        if (pendingCode_ == MoonlightCommonCCode::None) {
            pendingCode_ = MoonlightCommonCCode::Cancelled;
        }
    }
    finalize();
}

void Invocation::protocolFailure(MoonlightCommonCCode code,
                                 std::int32_t rawError) noexcept {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        protocolViolation_ = protocolViolation_ ||
            code == MoonlightCommonCCode::ProtocolViolation;
        if (pendingCode_ == MoonlightCommonCCode::None ||
            pendingCode_ == MoonlightCommonCCode::Cancelled) {
            pendingCode_ = code;
            pendingRawError_ = boundedError(rawError);
            pendingStage_ = activeStage_;
        }
    }
    (void)owner_->requestStop(key());
}

bool Invocation::onStageStarting(std::int32_t rawStage) noexcept {
    const auto stage = stageFromRaw(rawStage);
    MoonlightSessionOwner::StartContext* context = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stage == MoonlightCommonCStage::PlatformInit &&
            !firstStageFenceSeen_ && activeStage_ == MoonlightCommonCStage::None &&
            lastCompletedStage_ == MoonlightCommonCStage::None) {
            firstStageFenceSeen_ = true;
            context = startContext_;
        }
    }
    if (context != nullptr) {
        (void)context->markInterruptible();
    }

    auto lease = acquireCallback();
    if (!lease.valid()) {
        return false;
    }
    bool valid = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        valid = stage != MoonlightCommonCStage::None &&
            activeStage_ == MoonlightCommonCStage::None &&
            stageOrdinal(stage) == stageOrdinal(lastCompletedStage_) + 1U &&
            startContext_ != nullptr;
        if (valid) {
            activeStage_ = stage;
            MoonlightCommonCEvent event;
            event.type = MoonlightCommonCEventType::StageStarting;
            event.stage = stage;
            pushEventLocked(std::move(event));
        }
    }
    if (!valid) {
        protocolFailure(MoonlightCommonCCode::ProtocolViolation, rawStage);
        return false;
    }
    const auto ordinal = stageOrdinal(stage);
    runtime_->armDeadline(key(), request_.deadlines.overallMonotonicMs,
                          request_.deadlines.stageMonotonicMs[ordinal - 1U]);
    return true;
}

bool Invocation::onStageComplete(std::int32_t rawStage) noexcept {
    auto lease = acquireCallback();
    if (!lease.valid()) {
        return false;
    }
    const auto stage = stageFromRaw(rawStage);
    bool valid = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        valid = stage != MoonlightCommonCStage::None && activeStage_ == stage &&
            (stage != MoonlightCommonCStage::VideoStreamStart || videoStarted_) &&
            (stage != MoonlightCommonCStage::AudioStreamStart || audioStarted_);
        if (valid) {
            activeStage_ = MoonlightCommonCStage::None;
            lastCompletedStage_ = stage;
            MoonlightCommonCEvent event;
            event.type = MoonlightCommonCEventType::StageComplete;
            event.stage = stage;
            pushEventLocked(std::move(event));
        }
    }
    if (!valid) {
        protocolFailure(MoonlightCommonCCode::ProtocolViolation, rawStage);
        return false;
    }
    runtime_->armDeadline(key(), request_.deadlines.overallMonotonicMs, 0U);
    return true;
}

bool Invocation::onStageFailed(std::int32_t rawStage,
                               std::int32_t errorCode) noexcept {
    auto lease = acquireCallback();
    if (!lease.valid()) {
        return false;
    }
    const auto stage = stageFromRaw(rawStage);
    bool valid = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        valid = stage != MoonlightCommonCStage::None && activeStage_ == stage;
        if (valid) {
            pendingCode_ = MoonlightCommonCCode::StageFailed;
            pendingRawError_ = boundedError(errorCode);
            pendingStage_ = stage;
        }
    }
    if (!valid) {
        lease.reset();
        protocolFailure(MoonlightCommonCCode::ProtocolViolation, rawStage);
        return false;
    }
    runtime_->clearDeadline(key());
    lease.reset();
    (void)owner_->requestStop(key());
    return true;
}

bool Invocation::onConnectionStarted() noexcept {
    auto lease = acquireCallback();
    if (!lease.valid()) {
        return false;
    }
    bool valid = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        valid = activeStage_ == MoonlightCommonCStage::None &&
            lastCompletedStage_ == MoonlightCommonCStage::InputStreamStart &&
            negotiatedEmitted_ && videoStarted_ && audioStarted_;
        if (valid) {
            transportReady_ = true;
            MoonlightCommonCEvent event;
            event.type = MoonlightCommonCEventType::TransportReady;
            pushEventLocked(std::move(event));
        }
    }
    if (!valid) {
        protocolFailure(MoonlightCommonCCode::ProtocolViolation);
        return false;
    }
    // The configured deadlines bound connection establishment only. Once
    // common-c proves the full transport is running, retaining the overall
    // startup deadline would terminate every healthy long-lived stream when
    // that deadline expires.
    runtime_->clearDeadline(key());
    return true;
}

bool Invocation::onConnectionTerminated(std::int32_t errorCode) noexcept {
    auto lease = acquireCallback();
    if (!lease.valid()) {
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (pendingCode_ == MoonlightCommonCCode::None) {
            pendingCode_ = MoonlightCommonCCode::ConnectionTerminated;
            pendingRawError_ = boundedError(errorCode);
        }
    }
    lease.reset();
    (void)owner_->requestStop(key());
    return true;
}

bool Invocation::onConnectionStatus(std::int32_t rawStatus) noexcept {
    auto lease = acquireCallback();
    if (!lease.valid() || (rawStatus != CONN_STATUS_OKAY && rawStatus != CONN_STATUS_POOR)) {
        return false;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (!transportReady_) {
        return false;
    }
    MoonlightCommonCEvent event;
    event.type = MoonlightCommonCEventType::ConnectionQuality;
    event.connectionQuality = rawStatus == CONN_STATUS_OKAY
                                  ? MoonlightCommonCConnectionQuality::Okay
                                  : MoonlightCommonCConnectionQuality::Poor;
    pushEventLocked(std::move(event));
    return true;
}

bool Invocation::onHdrMode(bool enabled) noexcept {
    auto lease = acquireCallback();
    if (!lease.valid()) {
        return false;
    }
    bool valid = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        valid = video_.has_value() && enabled == request_.streamConfig.offer->hdr;
        if (valid) {
            MoonlightCommonCEvent event;
            event.type = MoonlightCommonCEventType::HdrMode;
            event.hdrEnabled = enabled;
            pushEventLocked(std::move(event));
        }
    }
    if (!valid) {
        lease.reset();
        protocolFailure(MoonlightCommonCCode::VideoNegotiationRejected);
        return false;
    }
    return true;
}

bool Invocation::onLogNotice() noexcept {
    auto lease = acquireCallback();
    if (!lease.valid()) {
        return false;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    MoonlightCommonCEvent event;
    event.type = MoonlightCommonCEventType::UpstreamNotice;
    pushEventLocked(std::move(event));
    return true;
}

void Invocation::maybeEmitNegotiatedLocked() noexcept {
    if (negotiatedEmitted_ || !video_.has_value() || !audio_.has_value()) {
        return;
    }
    negotiatedEmitted_ = true;
    MoonlightCommonCEvent event;
    event.type = MoonlightCommonCEventType::Negotiated;
    event.video = video_;
    event.audio = audio_;
    pushEventLocked(std::move(event));
}

int Invocation::onVideoSetup(std::int32_t rawVideoFormat, std::int32_t width,
                             std::int32_t height,
                             std::int32_t redrawRate) noexcept {
    auto lease = acquireCallback();
    if (!lease.valid()) {
        return -1;
    }
    const auto profile = profileForVideoFormat(rawVideoFormat);
    bool offered = false;
    const auto& offer = *request_.streamConfig.offer;
    if (profile.has_value() && (rawVideoFormat & (rawVideoFormat - 1)) == 0) {
        for (const auto& candidate : offer.offeredCodecs) {
            const MoonlightStreamCodecProfile offeredProfile {
                candidate.codec, candidate.bitDepth, candidate.chroma};
            if (sameProfile(*profile, offeredProfile) &&
                candidate.supportsCurrentHdrIntent &&
                candidate.supportsCurrentYuv444Intent) {
                offered = true;
                break;
            }
        }
    }
    if (!offered || width != offer.dimensions.width ||
        height != offer.dimensions.height || redrawRate <= 0 ||
        redrawRate > offer.fps || !media_->videoReady()) {
        lease.reset();
        protocolFailure(MoonlightCommonCCode::VideoNegotiationRejected,
                        rawVideoFormat);
        return -1;
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (activeStage_ != MoonlightCommonCStage::VideoStreamStart ||
            video_.has_value() || videoSetupActive_) {
            offered = false;
        } else {
            videoSetupActive_ = true;
        }
    }
    if (!offered) {
        lease.reset();
        protocolFailure(MoonlightCommonCCode::ProtocolViolation);
        return -1;
    }
    MoonlightCommonCVideoSelection selection {*profile, width, height, redrawRate};
    if (!media_->setupVideo(selection)) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            videoSetupActive_ = false;
        }
        lease.reset();
        protocolFailure(MoonlightCommonCCode::MediaPortRejected);
        return -1;
    }
    bool committed = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        videoSetupActive_ = false;
        committed = !finalizing_ && !terminal_ && !video_.has_value();
        if (committed) {
            video_ = selection;
            maybeEmitNegotiatedLocked();
        }
    }
    if (!committed) {
        media_->cleanupVideo();
        return -1;
    }
    return 0;
}

bool Invocation::onVideoStart() noexcept {
    auto lease = acquireCallback();
    if (!lease.valid()) { return false; }
    bool valid = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        valid = activeStage_ == MoonlightCommonCStage::VideoStreamStart &&
            video_.has_value() && !videoStartActive_ && !videoStarted_ &&
            !videoStopped_ && !videoCleaned_;
        if (valid) {
            videoStartActive_ = true;
        }
    }
    if (!valid) {
        lease.reset();
        protocolFailure(MoonlightCommonCCode::ProtocolViolation);
        return false;
    }
    media_->startVideo();
    const bool live = media_->videoLive();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        videoStartActive_ = false;
        valid = live && !finalizing_ && !terminal_ && !videoStopped_ &&
            !videoCleaned_;
        if (valid) {
            videoStarted_ = true;
            videoIdrRequestPending_ = false;
        }
        callbackCv_.notify_all();
    }
    if (!valid) {
        lease.reset();
        protocolFailure(MoonlightCommonCCode::MediaPortRejected);
    }
    return valid;
}

bool Invocation::lifecycleCallbackAllowedLocked() const noexcept {
    return nativeCallActive_ && !terminal_ && routerInstalled_;
}

bool Invocation::onVideoStop() noexcept {
    auto lease = acquireLifecycleCallback();
    if (!lease.valid()) { return false; }
    bool valid = false;
    {
        std::unique_lock<std::mutex> lock(mutex_);
        callbackCv_.wait(lock, [&]() {
            return !videoStartActive_ || finalizing_ || terminal_;
        });
        valid = videoStarted_ && !videoStopped_ && !videoCleaned_;
        if (valid) {
            videoStopped_ = true;
            videoStarted_ = false;
        }
    }
    if (!valid) { return false; }
    media_->stopVideo();
    return true;
}

bool Invocation::onVideoCleanup() noexcept {
    auto lease = acquireLifecycleCallback();
    if (!lease.valid()) { return false; }
    bool valid = false;
    {
        std::unique_lock<std::mutex> lock(mutex_);
        callbackCv_.wait(lock, [&]() {
            return !videoStartActive_ || finalizing_ || terminal_;
        });
        valid = video_.has_value() && !videoCleaned_;
        if (valid) {
            videoCleaned_ = true;
            videoStarted_ = false;
        }
    }
    if (!valid) { return false; }
    media_->cleanupVideo();
    return true;
}

bool Invocation::bindVideoIdentityLocked(
    MoonlightVideoDecodeUnitView& decodeUnit) noexcept {
    if (!videoStarted_ || videoStopped_ || videoCleaned_ || !video_.has_value()) {
        return false;
    }
    decodeUnit.key = key_;
    decodeUnit.profile = video_->profile;
    return true;
}

int Invocation::requestVideoIdrOnceLocked() noexcept {
    if (videoIdrRequestPending_) {
        return DR_OK;
    }
    videoIdrRequestPending_ = true;
    return DR_NEED_IDR;
}

int Invocation::mapVideoSubmitResultLocked(
    const MoonlightVideoDecodeUnitView& decodeUnit,
    const MoonlightVideoSubmitResult& result) noexcept {
    if (result.status == MoonlightVideoSubmitStatus::Accepted &&
        decodeUnit.frameType == MoonlightVideoFrameType::IdR) {
        videoIdrRequestPending_ = false;
    }
    if (!result.requestIdr) {
        return DR_OK;
    }
    if (result.status == MoonlightVideoSubmitStatus::Accepted ||
        result.status == MoonlightVideoSubmitStatus::Backpressure) {
        // The decoder either accepted the current frame after a latency soft
        // drop, or was momentarily busy. Keep common-c's depacketizer open and
        // request the IDR through its asynchronous control-stream API. Using
        // DR_NEED_IDR here caused common-c to discard every later P-frame and
        // freeze high-motion streams until the host eventually sent an IDR.
        if (!videoIdrRequestPending_) {
            videoIdrRequestPending_ = true;
#if !defined(RDP_TESTS_ONLY)
            OH_LOG_WARN(LOG_APP,
                        "soft video pressure: request IDR out of band and keep P-frame admission open");
#endif
            driver_->requestIdr();
        }
        return DR_OK;
    }
    return requestVideoIdrOnceLocked();
}

int Invocation::onVideoPayload(
    const MoonlightVideoDecodeUnitView& decodeUnit) noexcept {
    auto lease = acquireCallback();
    if (!lease.valid()) { return DR_NEED_IDR; }
    auto exact = decodeUnit;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!bindVideoIdentityLocked(exact)) {
            return requestVideoIdrOnceLocked();
        }
    }
    const auto result = media_->submitVideoPayload(exact);
    std::lock_guard<std::mutex> lock(mutex_);
    return mapVideoSubmitResultLocked(exact, result);
}

int Invocation::onCommonCVideoPayload(PDECODE_UNIT decodeUnit) noexcept {
    auto lease = acquireCallback();
    if (!lease.valid()) { return DR_NEED_IDR; }

    MoonlightSessionKey exactKey;
    MoonlightStreamCodecProfile exactProfile;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        MoonlightVideoDecodeUnitView identity;
        if (!bindVideoIdentityLocked(identity)) {
            return requestVideoIdrOnceLocked();
        }
        exactKey = identity.key;
        exactProfile = identity.profile;
    }

    ProjectedCommonCVideoUnit projected;
    if (!projectCommonCVideoUnit(decodeUnit, exactKey, exactProfile, projected)) {
        std::lock_guard<std::mutex> lock(mutex_);
        return requestVideoIdrOnceLocked();
    }
    const auto result = media_->submitVideoPayload(projected.view);
    std::lock_guard<std::mutex> lock(mutex_);
    return mapVideoSubmitResultLocked(projected.view, result);
}

int Invocation::onAudioInit(std::int32_t rawAudioConfiguration,
                            const MoonlightCommonCOpusConfig& opus) noexcept {
    auto lease = acquireCallback();
    if (!lease.valid()) { return -1; }
    const auto layout = request_.streamConfig.offer->audioLayout;
    const auto expectedConfiguration = audioConfigurationForLayout(layout);
    const auto expectedChannels = CHANNEL_COUNT_FROM_AUDIO_CONFIGURATION(
        expectedConfiguration);
    if (rawAudioConfiguration != expectedConfiguration ||
        !validOpus(opus, expectedChannels) || !media_->audioReady(layout)) {
        lease.reset();
        protocolFailure(MoonlightCommonCCode::AudioNegotiationRejected,
                        rawAudioConfiguration);
        return -1;
    }
    MoonlightCommonCAudioSelection selection {layout, opus};
    bool valid = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        valid = activeStage_ == MoonlightCommonCStage::AudioStreamStart &&
            !audio_.has_value() && !audioSetupActive_;
        if (valid) {
            audioSetupActive_ = true;
        }
    }
    if (!valid) {
        lease.reset();
        protocolFailure(MoonlightCommonCCode::ProtocolViolation);
        return -1;
    }
    if (!media_->setupAudio(selection)) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            audioSetupActive_ = false;
        }
        lease.reset();
        protocolFailure(MoonlightCommonCCode::MediaPortRejected);
        return -1;
    }
    bool committed = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        audioSetupActive_ = false;
        committed = !finalizing_ && !terminal_ && !audio_.has_value();
        if (committed) {
            audio_ = selection;
            maybeEmitNegotiatedLocked();
        }
    }
    if (!committed) {
        media_->cleanupAudio();
        return -1;
    }
    return 0;
}

bool Invocation::onAudioStart() noexcept {
    auto lease = acquireCallback();
    if (!lease.valid()) { return false; }
    bool valid = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        valid = activeStage_ == MoonlightCommonCStage::AudioStreamStart &&
            audio_.has_value() && !audioStartActive_ && !audioStarted_ &&
            !audioStopped_ && !audioCleaned_;
        if (valid) {
            audioStartActive_ = true;
        }
    }
    if (!valid) {
        lease.reset();
        protocolFailure(MoonlightCommonCCode::ProtocolViolation);
        return false;
    }
    media_->startAudio();
    const bool live = media_->audioLive();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        audioStartActive_ = false;
        valid = live && !finalizing_ && !terminal_ && !audioStopped_ &&
            !audioCleaned_;
        if (valid) {
            audioStarted_ = true;
        }
        callbackCv_.notify_all();
    }
    if (!valid) {
        lease.reset();
        protocolFailure(MoonlightCommonCCode::MediaPortRejected);
    }
    return valid;
}

bool Invocation::onAudioStop() noexcept {
    auto lease = acquireLifecycleCallback();
    if (!lease.valid()) { return false; }
    bool valid = false;
    {
        std::unique_lock<std::mutex> lock(mutex_);
        callbackCv_.wait(lock, [&]() {
            return !audioStartActive_ || finalizing_ || terminal_;
        });
        valid = audioStarted_ && !audioStopped_ && !audioCleaned_;
        if (valid) {
            audioStopped_ = true;
            audioStarted_ = false;
        }
    }
    if (!valid) { return false; }
    media_->stopAudio();
    return true;
}

bool Invocation::onAudioCleanup() noexcept {
    auto lease = acquireLifecycleCallback();
    if (!lease.valid()) { return false; }
    bool valid = false;
    {
        std::unique_lock<std::mutex> lock(mutex_);
        callbackCv_.wait(lock, [&]() {
            return !audioStartActive_ || finalizing_ || terminal_;
        });
        valid = audio_.has_value() && !audioCleaned_;
        if (valid) {
            audioCleaned_ = true;
            audioStarted_ = false;
        }
    }
    if (!valid) { return false; }
    media_->cleanupAudio();
    return true;
}

bool Invocation::onAudioPayload(const std::uint8_t* bytes,
                                std::size_t byteCount) noexcept {
    auto lease = acquireCallback();
    const bool plc = bytes == nullptr && byteCount == 0U;
    const bool packet = bytes != nullptr && byteCount > 0U &&
        byteCount <= kMaximumAudioPayloadBytes;
    if (!lease.valid() || (!plc && !packet)) {
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!audioStarted_ || audioStopped_ || audioCleaned_) {
            return false;
        }
    }
    media_->submitAudioPayload(bytes, byteCount);
    return true;
}

void Invocation::cleanseLocked() noexcept {
    if (secretsCleared_) { return; }
    wire_.cleanse();
    MoonlightCommonCAdapterAccess::cleanse(request_.launchLease);
    secureWipeString(request_.server.address);
    secureWipeString(request_.server.appVersion);
    if (request_.server.gfeVersion.has_value()) {
        secureWipeString(*request_.server.gfeVersion);
        request_.server.gfeVersion.reset();
    }
    secretsCleared_ = true;
}

void Invocation::finalize(bool driverException) noexcept {
    runtime_->clearDeadline(key());
    runTerminalInputTeardown();
    {
        std::unique_lock<std::mutex> lock(mutex_);
        if (terminalEmitted_) {
            cleanseLocked();
            return;
        }
        if (finalizing_) {
            callbackCv_.wait(lock, [&]() { return terminalEmitted_; });
            return;
        }
        finalizing_ = true;
        callbackCv_.wait(lock, [&]() { return inFlightCallbacks_ == 0U; });
    }
    retireRouter();
    bool releaseMedia = false;
    MoonlightSessionKey releaseKey;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        releaseMedia = mediaBound_ && !mediaReleased_;
        if (releaseMedia) {
            mediaReleased_ = true;
            releaseKey = key_;
        }
    }
    if (releaseMedia) {
        try {
            media_->releaseSession(releaseKey);
        } catch (...) {
            // Teardown remains fail-closed; no exception may cross the native
            // owner completion boundary.
        }
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        videoStarted_ = false;
        audioStarted_ = false;
        terminal_ = true;
        terminalEmitted_ = true;
        MoonlightCommonCCode code = pendingCode_;
        if (runtime_->deadlineFired(key_)) {
            code = MoonlightCommonCCode::DeadlineExceeded;
        } else if (driverException) {
            code = MoonlightCommonCCode::DriverException;
        } else if (code == MoonlightCommonCCode::None) {
            code = MoonlightCommonCCode::Cancelled;
        }
        pendingCode_ = code;
        MoonlightCommonCEvent event;
        event.code = code;
        event.stage = pendingStage_;
        event.boundedRawError = pendingRawError_;
        if (code == MoonlightCommonCCode::DeadlineExceeded) {
            event.type = MoonlightCommonCEventType::Timeout;
        } else if (code == MoonlightCommonCCode::ConnectionTerminated) {
            event.type = MoonlightCommonCEventType::Terminated;
        } else if (code == MoonlightCommonCCode::Cancelled) {
            event.type = MoonlightCommonCEventType::Cancelled;
        } else {
            event.type = MoonlightCommonCEventType::Failed;
        }
        pushEventLocked(std::move(event));
        cleanseLocked();
        finalizing_ = false;
        callbackCv_.notify_all();
    }
    notifyTerminalComplete();
    runtime_->complete(shared_from_this());
}

MoonlightCommonCSnapshot Invocation::snapshot() const noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    MoonlightCommonCSnapshot result;
    result.matched = key_.valid();
    result.key = key_;
    result.terminalCode = pendingCode_;
    result.activeStage = activeStage_;
    result.lastCompletedStage = lastCompletedStage_;
    result.protocolViolation = protocolViolation_;
    result.transportReady = transportReady_;
    result.videoReady = !terminal_ && mediaBound_ && !mediaReleased_ &&
        videoStarted_ && media_ != nullptr && media_->videoLive();
    result.audioReady = !terminal_ && mediaBound_ && !mediaReleased_ &&
        audioStarted_ && media_ != nullptr && media_->audioLive();
    result.firstFrameReady = mediaBound_ && !mediaReleased_ &&
        media_ != nullptr && media_->firstFrameReady();
    result.terminal = terminal_;
    result.secretsCleared = secretsCleared_;
    result.lastSequence = nextSequence_ == 0U ? 0U : nextSequence_ - 1U;
    result.droppedEvents = droppedEvents_;
    const auto staleNow = routerSlot().staleCallbacks.load(
        std::memory_order_relaxed);
    result.staleCallbacks = staleNow >= staleBaseline_
                                ? staleNow - staleBaseline_
                                : 0U;
    result.video = video_;
    result.audio = audio_;
    return result;
}

std::vector<MoonlightCommonCEvent> Invocation::drainEvents() noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    std::vector<MoonlightCommonCEvent> result;
    result.reserve(events_.size());
    while (!events_.empty()) {
        result.push_back(std::move(events_.front()));
        events_.pop_front();
    }
    return result;
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
MoonlightCommonCTestWireSnapshot Invocation::testWireSnapshot() const noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    MoonlightCommonCTestWireSnapshot result;
    result.valid = key_.valid() && !secretsCleared_;
    result.address = wire_.address;
    result.appVersion = wire_.appVersion;
    result.gfeVersion = wire_.gfeVersion;
    result.rtspSessionUrl = wire_.rtspSessionUrl;
    result.serverCodecModeSupport = wire_.serverCodecModeSupport;
    result.width = wire_.width;
    result.height = wire_.height;
    result.fps = wire_.fps;
    result.bitrate = wire_.bitrate;
    result.packetSize = wire_.packetSize;
    result.streamingRemotely = wire_.streamingRemotely;
    result.audioConfiguration = wire_.audioConfiguration;
    result.supportedVideoFormats = wire_.supportedVideoFormats;
    result.clientRefreshRateX100 = wire_.clientRefreshRateX100;
    result.colorSpace = wire_.colorSpace;
    result.colorRange = wire_.colorRange;
    result.encryptionFlags = wire_.encryptionFlags;
    result.remoteInputKey = wire_.remoteInputKey;
    result.remoteInputIv = wire_.remoteInputIv;
    return result;
}

bool Invocation::testFinalizing() const noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return finalizing_;
}
#endif

std::shared_ptr<Invocation> AdapterRuntime::findInvocationLocked(
    const MoonlightSessionKey& key) const noexcept {
    if (active_ != nullptr && activeKey_ == key) { return active_; }
    if (last_ != nullptr && lastKey_ == key) { return last_; }
    return nullptr;
}

MoonlightCommonCStartResult AdapterRuntime::start(
    MoonlightCommonCRequest request,
    std::shared_ptr<MoonlightCommonCMediaPort> mediaOverride) noexcept {
    try {
        const std::shared_ptr<MoonlightCommonCMediaPort> media =
            mediaOverride != nullptr ? std::move(mediaOverride) : media_;
        if (media == nullptr) {
            return {MoonlightCommonCStartStatus::RuntimeProofRequired,
                    MoonlightCommonCCode::RuntimeProofRequired, {}};
        }
        const auto now = clock_();
        const auto& identity = request.streamConfig.identity;
        if (request.sessionId == 0U || request.generation == 0U ||
            request.accountOwnerToken == 0U ||
            !validCanonicalOffer(request.streamConfig,
                                 request.deferRuntimeCapabilityProof) ||
            identity.ownerToken != request.accountOwnerToken ||
            identity.sessionGeneration != request.generation ||
            !request.server.authenticated ||
            request.server.hostCapabilityGeneration == 0U ||
            request.server.hostCapabilityGeneration != identity.hostCapabilityGeneration ||
            !validAddress(request.server.address) ||
            !validVersion(request.server.appVersion, 4U, 4U) ||
            (request.server.gfeVersion.has_value() &&
             !validVersion(*request.server.gfeVersion, 1U, 4U)) ||
            request.server.codecProfiles.empty() ||
            request.server.codecProfiles.size() > kMaximumCodecProfiles ||
            !MoonlightCommonCAdapterAccess::matches(request.launchLease, request) ||
            !validDeadlines(request.deadlines, now)) {
            return {MoonlightCommonCStartStatus::InvalidRequest,
                    MoonlightCommonCCode::InvalidRequest, {}};
        }
        std::int32_t serverCodecMask = 0;
        for (const auto& profile : request.server.codecProfiles) {
            const auto bit = serverCodecForProfile(profile);
            if (!validProfile(profile) || bit == 0 ||
                (serverCodecMask & bit) != 0) {
                return {MoonlightCommonCStartStatus::InvalidRequest,
                        MoonlightCommonCCode::InvalidRequest, {}};
            }
            serverCodecMask |= bit;
        }
        std::int32_t videoMask = 0;
        for (const auto& offered : request.streamConfig.offer->offeredCodecs) {
            const MoonlightStreamCodecProfile profile {
                offered.codec, offered.bitDepth, offered.chroma};
            const auto bit = videoFormatForProfile(profile);
            const bool serverSupports = std::any_of(
                request.server.codecProfiles.begin(),
                request.server.codecProfiles.end(),
                [&](const auto& serverProfile) {
                    return sameProfile(profile, serverProfile);
                });
            if (bit == 0 || (videoMask & bit) != 0 || !serverSupports) {
                return {MoonlightCommonCStartStatus::InvalidRequest,
                        MoonlightCommonCCode::InvalidRequest, {}};
            }
            videoMask |= bit;
        }
        if (videoMask == 0 || serverCodecMask == 0 ||
            audioConfigurationForLayout(request.streamConfig.offer->audioLayout) == 0) {
            return {MoonlightCommonCStartStatus::InvalidRequest,
                    MoonlightCommonCCode::InvalidRequest, {}};
        }
        const auto sessionId = request.sessionId;
        const auto generation = request.generation;
        auto invocation = std::make_shared<Invocation>(
            this, owner_, driver_, std::move(media), std::move(request));
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (shuttingDown_ || active_ != nullptr) {
                return {MoonlightCommonCStartStatus::Busy,
                        MoonlightCommonCCode::Busy, {}};
            }
            active_ = invocation;
            activeKey_ = {};
        }
        MoonlightSessionOwner::Driver ownerDriver {
            [invocation](MoonlightSessionOwner::StartContext& context) {
                return invocation->runStart(context);
            },
            [invocation]() { invocation->runInterrupt(); },
            [invocation]() { invocation->runStop(); },
        };
        const auto accepted = owner_->start(
            sessionId, generation, std::move(ownerDriver));
        if (accepted.status != MoonlightStartStatus::Accepted) {
            std::lock_guard<std::mutex> lock(mutex_);
            if (active_ == invocation) { active_.reset(); }
            return {accepted.status == MoonlightStartStatus::Busy
                        ? MoonlightCommonCStartStatus::Busy
                        : MoonlightCommonCStartStatus::InternalFailure,
                    accepted.status == MoonlightStartStatus::Busy
                        ? MoonlightCommonCCode::Busy
                        : MoonlightCommonCCode::StaleOwner,
                    {}};
        }
        invocation->acceptKey(accepted.key);
        (void)bindActiveKey(invocation, accepted.key);
        return {MoonlightCommonCStartStatus::Accepted,
                MoonlightCommonCCode::None, accepted.key};
    } catch (...) {
        return {MoonlightCommonCStartStatus::InternalFailure,
                MoonlightCommonCCode::DriverException, {}};
    }
}

MoonlightStopStatus AdapterRuntime::requestStop(
    const MoonlightSessionKey& key) noexcept {
    std::shared_ptr<Invocation> invocation;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        invocation = findInvocationLocked(key);
    }
    if (invocation != nullptr) { invocation->noteUserCancel(); }
    const auto status = owner_->requestStop(key);
    if (status == MoonlightStopStatus::StopRequested && invocation != nullptr) {
        const auto ownerSnapshot = owner_->snapshot(key);
        if (ownerSnapshot.matched && !ownerSnapshot.startInvoked &&
            (ownerSnapshot.phase == MoonlightSessionPhase::Stopping ||
             ownerSnapshot.phase == MoonlightSessionPhase::Stopped)) {
            invocation->finalizeBeforeDriverStart();
        }
    }
    return status;
}

MoonlightStopStatus AdapterRuntime::stop(const MoonlightSessionKey& key,
                                         std::chrono::milliseconds timeout) noexcept {
    std::shared_ptr<Invocation> invocation;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        invocation = findInvocationLocked(key);
    }
    if (invocation != nullptr) { invocation->noteUserCancel(); }
    try {
        const auto status = owner_->stop(key, timeout);
        if (invocation != nullptr) {
            const auto ownerSnapshot = owner_->snapshot(key);
            if (ownerSnapshot.matched && !ownerSnapshot.startInvoked &&
                (ownerSnapshot.phase == MoonlightSessionPhase::Stopped ||
                 ownerSnapshot.phase == MoonlightSessionPhase::Failed)) {
                invocation->finalizeBeforeDriverStart();
            }
        }
        return status;
    } catch (...) {
        return MoonlightStopStatus::DriverFailure;
    }
}

MoonlightCommonCSnapshot AdapterRuntime::snapshot(
    const MoonlightSessionKey& key) const noexcept {
    std::shared_ptr<Invocation> invocation;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        invocation = findInvocationLocked(key);
    }
    return invocation == nullptr ? MoonlightCommonCSnapshot {}
                                 : invocation->snapshot();
}

std::vector<MoonlightCommonCEvent> AdapterRuntime::drainEvents(
    const MoonlightSessionKey& key) noexcept {
    std::shared_ptr<Invocation> invocation;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        invocation = findInvocationLocked(key);
    }
    return invocation == nullptr ? std::vector<MoonlightCommonCEvent> {}
                                 : invocation->drainEvents();
}

bool AdapterRuntime::bindActiveKey(
    const std::shared_ptr<Invocation>& invocation,
    const MoonlightSessionKey& key) noexcept {
    if (invocation == nullptr || !key.valid()) {
        return false;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (active_ == invocation &&
        (!activeKey_.valid() || activeKey_ == key)) {
        activeKey_ = key;
        return true;
    }
    return last_ == invocation && lastKey_ == key;
}

void AdapterRuntime::armDeadline(const MoonlightSessionKey& key,
                                 std::uint64_t overall,
                                 std::uint64_t stage) noexcept {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (active_ == nullptr || activeKey_ != key ||
            deadlineFiredKey_ == key) {
            return;
        }
        deadlineKey_ = key;
        overallDeadline_ = overall;
        stageDeadline_ = stage;
    }
    schedulerCv_.notify_all();
}

void AdapterRuntime::clearDeadline(const MoonlightSessionKey& key) noexcept {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (deadlineKey_ == key) {
            deadlineKey_ = {};
            overallDeadline_ = 0U;
            stageDeadline_ = 0U;
        }
    }
    schedulerCv_.notify_all();
}

bool AdapterRuntime::deadlineFired(const MoonlightSessionKey& key) const noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return deadlineFiredKey_ == key;
}

void AdapterRuntime::complete(const std::shared_ptr<Invocation>& invocation) noexcept {
    const auto invocationKey = invocation->key();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (active_ == invocation) {
            last_ = invocation;
            lastKey_ = invocationKey;
            active_.reset();
            activeKey_ = {};
        }
        if (deadlineKey_ == invocationKey) {
            deadlineKey_ = {};
            overallDeadline_ = 0U;
            stageDeadline_ = 0U;
        }
    }
    schedulerCv_.notify_all();
}

void AdapterRuntime::schedulerLoop() noexcept {
    for (;;) {
        MoonlightSessionKey fireKey;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            schedulerCv_.wait(lock, [&]() {
                return shuttingDown_ || deadlineKey_.valid();
            });
            if (shuttingDown_) { return; }
            const auto now = clock_();
            const auto target = stageDeadline_ == 0U
                                    ? overallDeadline_
                                    : std::min(overallDeadline_, stageDeadline_);
            if (target <= now) {
                fireKey = deadlineKey_;
                deadlineFiredKey_ = fireKey;
                deadlineKey_ = {};
                overallDeadline_ = 0U;
                stageDeadline_ = 0U;
            } else if (manualClock_) {
                schedulerCv_.wait(lock);
            } else {
                schedulerCv_.wait_for(lock, std::chrono::milliseconds(target - now));
            }
        }
        if (fireKey.valid()) {
            // The scheduler owns no invocation reference and never calls common-c.
            (void)owner_->requestStop(fireKey);
        }
    }
}

void AdapterRuntime::shutdown() noexcept {
    MoonlightSessionKey activeKey;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (shuttingDown_) { return; }
        if (active_ != nullptr) { activeKey = activeKey_; }
    }
    if (activeKey.valid()) {
        MoonlightStopStatus status = MoonlightStopStatus::TimedOut;
        while (status == MoonlightStopStatus::TimedOut) {
            // Destruction is an ownership fence, not a detach point. Keep
            // waiting in bounded condition-variable slices until the exact
            // common-c invocation and all owner leases have drained.
            status = stop(activeKey, std::chrono::seconds(5));
        }
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        shuttingDown_ = true;
        deadlineKey_ = {};
    }
    schedulerCv_.notify_all();
    if (scheduler_.joinable()) { scheduler_.join(); }
}

} // namespace

struct MoonlightCommonCAdapter::Impl final {
    explicit Impl(std::unique_ptr<AdapterRuntime> value) : runtime(std::move(value)) {}
    std::unique_ptr<AdapterRuntime> runtime;
};

MoonlightCommonCAdapter::MoonlightCommonCAdapter(std::unique_ptr<Impl> impl)
    : impl_(std::move(impl)) {}

MoonlightCommonCAdapter::~MoonlightCommonCAdapter() = default;

MoonlightCommonCAdapter& MoonlightCommonCAdapter::process() {
#if defined(RDP_TESTS_ONLY)
    static MoonlightCommonCTestDriver rejected {
        []() { return -1; }, []() {}, []() {}};
    static MoonlightCommonCAdapter adapter(std::make_unique<Impl>(
        std::make_unique<AdapterRuntime>(
            MoonlightSessionOwner::process(),
            std::make_shared<TestDriverPort>(std::move(rejected)),
            std::make_shared<NullMediaPort>(), steadyMonotonicMs, false)));
#else
    static MoonlightCommonCAdapter adapter(std::make_unique<Impl>(
        std::make_unique<AdapterRuntime>(
            MoonlightSessionOwner::process(),
            std::make_shared<ProductDriverPort>(),
            std::make_shared<NullMediaPort>(), steadyMonotonicMs, false)));
#endif
    return adapter;
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
std::unique_ptr<MoonlightCommonCAdapter>
MoonlightCommonCAdapter::createForTesting(
    MoonlightSessionOwner& owner, MoonlightCommonCTestDriver driver,
    std::shared_ptr<MoonlightCommonCMediaPort> mediaPort,
    std::function<std::uint64_t()> monotonicClock) {
    if (!driver.valid() || mediaPort == nullptr || !monotonicClock) {
        return nullptr;
    }
    auto& slot = routerSlot();
    {
        std::lock_guard<std::mutex> lock(slot.mutex);
        if (slot.invocation.expired()) {
            slot.key = {};
            slot.ownerTokenHighWater = 0U;
            slot.staleCallbacks.store(0U, std::memory_order_relaxed);
        }
    }
    return std::unique_ptr<MoonlightCommonCAdapter>(
        new MoonlightCommonCAdapter(std::make_unique<Impl>(
            std::make_unique<AdapterRuntime>(
                owner, std::make_shared<TestDriverPort>(std::move(driver)),
                std::move(mediaPort), std::move(monotonicClock), true))));
}

void MoonlightCommonCAdapter::notifyClockForTesting() noexcept {
    impl_->runtime->notifyClock();
}
#endif

MoonlightCommonCStartResult MoonlightCommonCAdapter::start(
    MoonlightCommonCRequest request) noexcept {
    return impl_->runtime->start(std::move(request));
}

MoonlightCommonCStartResult MoonlightCommonCAdapter::startWithMedia(
    MoonlightCommonCRequest request,
    std::shared_ptr<MoonlightCommonCMediaPort> mediaPort) noexcept {
    if (mediaPort == nullptr) {
        return {MoonlightCommonCStartStatus::RuntimeProofRequired,
                MoonlightCommonCCode::RuntimeProofRequired, {}};
    }
    return impl_->runtime->start(std::move(request), std::move(mediaPort));
}

MoonlightStopStatus MoonlightCommonCAdapter::requestStop(
    const MoonlightSessionKey& key) noexcept {
    return impl_->runtime->requestStop(key);
}

MoonlightStopStatus MoonlightCommonCAdapter::stop(
    const MoonlightSessionKey& key, std::chrono::milliseconds timeout) noexcept {
    return impl_->runtime->stop(key, timeout);
}

MoonlightCommonCSnapshot MoonlightCommonCAdapter::snapshot(
    const MoonlightSessionKey& key) const noexcept {
    return impl_->runtime->snapshot(key);
}

std::vector<MoonlightCommonCEvent> MoonlightCommonCAdapter::drainEvents(
    const MoonlightSessionKey& key) noexcept {
    return impl_->runtime->drainEvents(key);
}

int MoonlightCommonCAdapter::productionLinkSmoke() noexcept {
#if defined(RDP_TESTS_ONLY)
    return 0;
#else
    return (&LiInitializeServerInformation != nullptr &&
            &LiInitializeStreamConfiguration != nullptr &&
            &LiInitializeConnectionCallbacks != nullptr &&
            &LiInitializeVideoCallbacks != nullptr &&
            &LiInitializeAudioCallbacks != nullptr &&
            &LiStartConnection != nullptr && &LiInterruptConnection != nullptr &&
            &LiStopConnection != nullptr)
               ? 0
               : 1;
#endif
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
bool MoonlightCommonCTestHarness::stageStarting(std::int32_t stage) noexcept {
    return routeStageStarting(stage);
}
bool MoonlightCommonCTestHarness::stageComplete(std::int32_t stage) noexcept {
    return routeStageComplete(stage);
}
bool MoonlightCommonCTestHarness::stageFailed(std::int32_t stage,
                                              std::int32_t error) noexcept {
    return routeStageFailed(stage, error);
}
bool MoonlightCommonCTestHarness::connectionStarted() noexcept {
    return routeConnectionStarted();
}
bool MoonlightCommonCTestHarness::connectionTerminated(std::int32_t error) noexcept {
    return routeConnectionTerminated(error);
}
bool MoonlightCommonCTestHarness::connectionStatus(std::int32_t status) noexcept {
    return routeConnectionStatus(status);
}
bool MoonlightCommonCTestHarness::hdrMode(bool enabled) noexcept {
    return routeHdrMode(enabled);
}
bool MoonlightCommonCTestHarness::logNotice() noexcept { return routeLogNotice(); }
int MoonlightCommonCTestHarness::videoSetup(std::int32_t format, std::int32_t width,
                                            std::int32_t height,
                                            std::int32_t redrawRate) noexcept {
    return routeVideoSetup(format, width, height, redrawRate);
}
bool MoonlightCommonCTestHarness::videoStart() noexcept { return routeVideoStart(); }
bool MoonlightCommonCTestHarness::videoStop() noexcept { return routeVideoStop(); }
bool MoonlightCommonCTestHarness::videoCleanup() noexcept { return routeVideoCleanup(); }
int MoonlightCommonCTestHarness::videoPayload(
    const MoonlightVideoDecodeUnitView& decodeUnit) noexcept {
    return routeVideoPayload(decodeUnit);
}
int MoonlightCommonCTestHarness::audioInit(
    std::int32_t configuration, const MoonlightCommonCOpusConfig& opus) noexcept {
    return routeAudioInit(configuration, opus);
}
bool MoonlightCommonCTestHarness::audioStart() noexcept { return routeAudioStart(); }
bool MoonlightCommonCTestHarness::audioStop() noexcept { return routeAudioStop(); }
bool MoonlightCommonCTestHarness::audioCleanup() noexcept { return routeAudioCleanup(); }
bool MoonlightCommonCTestHarness::audioPayload(const std::uint8_t* bytes,
                                               std::size_t count) noexcept {
    return routeAudioPayload(bytes, count);
}
void MoonlightCommonCTestHarness::audioPayloadRaw(
    const std::uint8_t* bytes, std::int32_t count) noexcept {
    routeRawAudioPayload(bytes, count);
}
bool MoonlightCommonCTestHarness::finalizing() noexcept {
    const auto invocation = routedInvocation();
    return invocation != nullptr && invocation->testFinalizing();
}
std::optional<MoonlightCommonCTestWireSnapshot>
MoonlightCommonCTestHarness::wireSnapshot() noexcept {
    const auto invocation = routedInvocation();
    return invocation == nullptr
               ? std::optional<MoonlightCommonCTestWireSnapshot> {}
               : invocation->testWireSnapshot();
}
std::int32_t MoonlightCommonCTestHarness::videoFormatForProfile(
    const MoonlightStreamCodecProfile& profile) noexcept {
    return remotedesk::moonlight::videoFormatForProfile(profile);
}
std::array<std::uint8_t, 16U> MoonlightCommonCTestHarness::remoteInputIv(
    std::int32_t keyId) noexcept {
    return remotedesk::moonlight::remoteInputIv(keyId);
}
void MoonlightCommonCTestHarness::clearRemoteInputSecrets(
    std::array<std::uint8_t, 16U>& key,
    std::array<std::uint8_t, 16U>& iv) noexcept {
    remotedesk::moonlight::clearRemoteInputSecrets(
        key.data(), key.size(), iv.data(), iv.size());
}
std::size_t MoonlightCommonCTestHarness::staleCallbackCount() noexcept {
    return routerSlot().staleCallbacks.load(std::memory_order_relaxed);
}
#endif

} // namespace remotedesk::moonlight
