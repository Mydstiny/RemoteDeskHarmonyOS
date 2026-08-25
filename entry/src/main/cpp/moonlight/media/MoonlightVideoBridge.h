#ifndef REMOTEDESK_MOONLIGHT_VIDEO_BRIDGE_H
#define REMOTEDESK_MOONLIGHT_VIDEO_BRIDGE_H

#include "moonlight/core/MoonlightSessionOwner.h"
#include "moonlight/media/MoonlightStreamConfig.h"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <vector>

#if defined(__GNUC__) || defined(__clang__)
#define REMOTEDESK_MOONLIGHT_VIDEO_HIDDEN __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_VIDEO_HIDDEN
#endif

namespace remotedesk::moonlight {

enum class MoonlightVideoBufferType : std::uint8_t {
    PictureData,
    SequenceParameterSet,
    PictureParameterSet,
    VideoParameterSet,
};

enum class MoonlightVideoFrameType : std::uint8_t {
    Predicted,
    IdR,
};

struct REMOTEDESK_MOONLIGHT_VIDEO_HIDDEN MoonlightVideoFragmentView final {
    const std::uint8_t* data = nullptr;
    std::size_t length = 0U;
    MoonlightVideoBufferType type = MoonlightVideoBufferType::PictureData;
    const MoonlightVideoFragmentView* next = nullptr;
};

// Project-owned projection of common-c's DECODE_UNIT. The source fragment
// memory is borrowed only for submit(); the bridge never retains these pointers.
struct REMOTEDESK_MOONLIGHT_VIDEO_HIDDEN MoonlightVideoDecodeUnitView final {
    MoonlightSessionKey key {};
    MoonlightStreamCodecProfile profile {};
    std::int32_t frameNumber = 0;
    MoonlightVideoFrameType frameType = MoonlightVideoFrameType::Predicted;
    std::uint16_t hostProcessingLatencyDeciMs = 0U;
    std::uint64_t receiveTimeUs = 0U;
    std::uint64_t enqueueTimeUs = 0U;
    std::uint64_t presentationTimeUs = 0U;
    std::uint32_t rtpTimestamp = 0U;
    std::size_t fullLength = 0U;
    const MoonlightVideoFragmentView* bufferList = nullptr;
    bool hdrActive = false;
    std::uint8_t colorSpace = 0U;
};

struct REMOTEDESK_MOONLIGHT_VIDEO_HIDDEN MoonlightOwnedVideoFragment final {
    MoonlightVideoBufferType type = MoonlightVideoBufferType::PictureData;
    std::size_t offset = 0U;
    std::size_t length = 0U;
};

struct REMOTEDESK_MOONLIGHT_VIDEO_HIDDEN MoonlightOwnedVideoAccessUnit final {
    MoonlightSessionKey key {};
    MoonlightStreamCodecProfile profile {};
    std::int32_t frameNumber = 0;
    MoonlightVideoFrameType frameType = MoonlightVideoFrameType::Predicted;
    std::uint16_t hostProcessingLatencyDeciMs = 0U;
    std::uint64_t receiveTimeUs = 0U;
    std::uint64_t enqueueTimeUs = 0U;
    std::uint64_t presentationTimeUs = 0U;
    std::uint32_t rtpTimestamp = 0U;
    bool hdrActive = false;
    std::uint8_t colorSpace = 0U;
    // Prospective decoder configuration generation for this AU. The bridge
    // commits it only after the sink accepts the IDR that carries the change.
    std::uint64_t codecConfigurationGeneration = 0U;
    bool codecConfigurationChanged = false;
    std::vector<std::uint8_t> bytes;
    std::vector<MoonlightOwnedVideoFragment> fragments;
};

enum class MoonlightVideoSinkStatus : std::uint8_t {
    Accepted,
    AcceptedNeedsIdr,
    Backpressure,
    NeedIdr,
    Stale,
    Unsupported,
    Failed,
};

class REMOTEDESK_MOONLIGHT_VIDEO_HIDDEN MoonlightVideoDecoderSink {
public:
    virtual ~MoonlightVideoDecoderSink() = default;
    virtual bool available(const MoonlightStreamCodecProfile& profile) = 0;
    virtual MoonlightVideoSinkStatus submit(
        std::shared_ptr<const MoonlightOwnedVideoAccessUnit> accessUnit) = 0;
};

enum class MoonlightVideoStartStatus : std::uint8_t {
    Started,
    InvalidRequest,
    Busy,
    RuntimeProofRequired,
    InternalFailure,
};

enum class MoonlightVideoSubmitStatus : std::uint8_t {
    Accepted,
    Dropped,
    NeedIdr,
    Backpressure,
    Malformed,
    Stale,
    Unsupported,
    SinkFailure,
    RuntimeProofRequired,
    NoSurface,
};

enum class MoonlightVideoDropReason : std::uint8_t {
    None,
    WaitingForIdr,
    DuplicateOrReordered,
    Teardown,
    NoSurface,
};

enum class MoonlightVideoStopStatus : std::uint8_t {
    Stopped,
    AlreadyStopped,
    Stale,
    TimedOut,
};

struct REMOTEDESK_MOONLIGHT_VIDEO_HIDDEN MoonlightVideoLimits final {
    std::size_t maximumFragments = 256U;
    std::size_t maximumFragmentBytes = 4U * 1024U * 1024U;
    std::size_t maximumAccessUnitBytes = 16U * 1024U * 1024U;
    std::size_t maximumCodecConfigurationBytes = 1024U * 1024U;
};

struct REMOTEDESK_MOONLIGHT_VIDEO_HIDDEN MoonlightVideoStartResult final {
    MoonlightVideoStartStatus status = MoonlightVideoStartStatus::InvalidRequest;
    MoonlightSessionKey key {};
};

struct REMOTEDESK_MOONLIGHT_VIDEO_HIDDEN MoonlightVideoSubmitResult final {
    MoonlightVideoSubmitStatus status = MoonlightVideoSubmitStatus::Malformed;
    MoonlightVideoDropReason dropReason = MoonlightVideoDropReason::None;
    bool sinkCalled = false;
    bool requestIdr = false;
    std::size_t ownedBytes = 0U;
    std::size_t fragmentCount = 0U;
    std::uint64_t configurationGeneration = 0U;
};

struct REMOTEDESK_MOONLIGHT_VIDEO_HIDDEN MoonlightVideoCodecConfiguration final {
    MoonlightSessionKey key {};
    MoonlightStreamCodecProfile profile {};
    std::uint64_t generation = 0U;
    std::vector<std::uint8_t> vps;
    std::vector<std::uint8_t> sps;
    std::vector<std::uint8_t> pps;
};

struct REMOTEDESK_MOONLIGHT_VIDEO_HIDDEN MoonlightVideoSnapshot final {
    bool matched = false;
    MoonlightSessionKey key {};
    bool running = false;
    bool admissionOpen = false;
    bool firstFrameReady = false;
    bool waitingForIdr = false;
    bool idrRequestPending = false;
    std::uint64_t configurationGeneration = 0U;
    std::size_t vpsBytes = 0U;
    std::size_t spsBytes = 0U;
    std::size_t ppsBytes = 0U;
    std::size_t inFlightSubmissions = 0U;
    std::uint64_t acceptedFrames = 0U;
    std::uint64_t droppedFrames = 0U;
    std::uint64_t malformedFrames = 0U;
    std::uint64_t staleFrames = 0U;
    std::uint64_t backpressureFrames = 0U;
    std::optional<std::int32_t> lastAcceptedFrameNumber;
};

class REMOTEDESK_MOONLIGHT_VIDEO_HIDDEN MoonlightVideoBridge final {
private:
    struct Impl;

public:
    static MoonlightVideoBridge& process();

    // Hidden composition seam for protocol-owned lifecycle coordinators. The
    // returned bridge still owns every access-unit copy and never retains a
    // borrowed common-c fragment pointer.
    static std::unique_ptr<MoonlightVideoBridge> create(
        std::shared_ptr<MoonlightVideoDecoderSink> sink,
        MoonlightVideoLimits limits = {});

#if defined(RDP_NATIVE_CALLBACK_TESTING)
    static std::unique_ptr<MoonlightVideoBridge> createForTesting(
        std::shared_ptr<MoonlightVideoDecoderSink> sink,
        MoonlightVideoLimits limits = {});
#endif

    ~MoonlightVideoBridge();
    MoonlightVideoBridge(const MoonlightVideoBridge&) = delete;
    MoonlightVideoBridge& operator=(const MoonlightVideoBridge&) = delete;

    MoonlightVideoStartResult start(
        const MoonlightSessionKey& key,
        const MoonlightStreamCodecProfile& profile) noexcept;
    MoonlightVideoSubmitResult submit(
        const MoonlightVideoDecodeUnitView& decodeUnit) noexcept;
    MoonlightVideoStopStatus stop(
        const MoonlightSessionKey& key,
        std::chrono::milliseconds timeout = std::chrono::seconds(5)) noexcept;
    MoonlightVideoSnapshot snapshot(const MoonlightSessionKey& key) const noexcept;
    std::optional<MoonlightVideoCodecConfiguration> configuration(
        const MoonlightSessionKey& key) const noexcept;

private:
    explicit MoonlightVideoBridge(std::unique_ptr<Impl> impl);
    std::unique_ptr<Impl> impl_;
};

} // namespace remotedesk::moonlight

#undef REMOTEDESK_MOONLIGHT_VIDEO_HIDDEN

#endif // REMOTEDESK_MOONLIGHT_VIDEO_BRIDGE_H
