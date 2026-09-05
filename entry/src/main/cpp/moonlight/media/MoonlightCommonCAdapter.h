#ifndef REMOTEDESK_MOONLIGHT_COMMON_C_ADAPTER_H
#define REMOTEDESK_MOONLIGHT_COMMON_C_ADAPTER_H

#include "moonlight/core/MoonlightSessionOwner.h"
#include "moonlight/media/MoonlightStreamConfig.h"
#include "moonlight/media/MoonlightVideoBridge.h"

#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#if defined(__GNUC__) || defined(__clang__)
#define REMOTEDESK_MOONLIGHT_COMMON_C_HIDDEN __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_COMMON_C_HIDDEN
#endif

namespace remotedesk::moonlight {

enum class MoonlightCommonCStage : std::uint8_t {
    None,
    PlatformInit,
    NameResolution,
    AudioStreamInit,
    RtspHandshake,
    ControlStreamInit,
    VideoStreamInit,
    InputStreamInit,
    ControlStreamStart,
    VideoStreamStart,
    AudioStreamStart,
    InputStreamStart,
};

enum class MoonlightCommonCStartStatus : std::uint8_t {
    Accepted,
    InvalidRequest,
    Busy,
    NetworkChanged,
    RuntimeProofRequired,
    InternalFailure,
};

enum class MoonlightCommonCCode : std::uint8_t {
    None,
    InvalidRequest,
    Busy,
    RuntimeProofRequired,
    CommonCStartFailed,
    StageFailed,
    ProtocolViolation,
    VideoNegotiationRejected,
    AudioNegotiationRejected,
    MediaPortRejected,
    Cancelled,
    NetworkChanged,
    DeadlineExceeded,
    ConnectionTerminated,
    DriverException,
    StaleOwner,
};

enum class MoonlightCommonCEventType : std::uint8_t {
    Starting,
    StageStarting,
    StageComplete,
    Negotiated,
    TransportReady,
    ConnectionQuality,
    HdrMode,
    Cancelled,
    Timeout,
    Terminated,
    Failed,
    UpstreamNotice,
};

enum class MoonlightCommonCConnectionQuality : std::uint8_t {
    Unknown,
    Okay,
    Poor,
};

struct REMOTEDESK_MOONLIGHT_COMMON_C_HIDDEN MoonlightCommonCOpusConfig final {
    std::int32_t sampleRate = 0;
    std::int32_t channelCount = 0;
    std::int32_t streams = 0;
    std::int32_t coupledStreams = 0;
    std::int32_t samplesPerFrame = 0;
    std::array<std::uint8_t, 8U> mapping {};
};

struct REMOTEDESK_MOONLIGHT_COMMON_C_HIDDEN MoonlightCommonCVideoSelection final {
    MoonlightStreamCodecProfile profile {};
    std::int32_t width = 0;
    std::int32_t height = 0;
    std::int32_t redrawRate = 0;
};

struct REMOTEDESK_MOONLIGHT_COMMON_C_HIDDEN MoonlightCommonCAudioSelection final {
    MoonlightStreamAudioLayout layout = MoonlightStreamAudioLayout::Disabled;
    MoonlightCommonCOpusConfig opus {};
};

class REMOTEDESK_MOONLIGHT_COMMON_C_HIDDEN MoonlightCommonCMediaPort {
public:
    virtual ~MoonlightCommonCMediaPort() = default;

    // Product media resources are bound only after MoonlightSessionOwner has
    // admitted the exact native session key. Test/dormant ports can keep the
    // defaults; production ports use this seam to activate the shared sink
    // owner and create their decoder binding without publishing a second
    // renderer/audio owner.
    virtual bool bindSession(const MoonlightSessionKey& key) noexcept {
        return key.valid();
    }
    virtual void releaseSession(const MoonlightSessionKey& /*key*/) noexcept {}
    virtual bool firstFrameReady() const noexcept { return false; }
    virtual bool videoLive() const noexcept { return false; }
    virtual bool audioLive() const noexcept { return false; }
    virtual bool videoReady() const noexcept = 0;
    virtual bool audioReady(MoonlightStreamAudioLayout layout) const noexcept = 0;
    virtual bool setupVideo(const MoonlightCommonCVideoSelection& selection) noexcept = 0;
    virtual void startVideo() noexcept = 0;
    virtual void stopVideo() noexcept = 0;
    virtual void cleanupVideo() noexcept = 0;
    // Synchronous borrowed-view boundary. Implementations must copy any bytes
    // they retain before returning from this call.
    virtual MoonlightVideoSubmitResult submitVideoPayload(
        const MoonlightVideoDecodeUnitView& decodeUnit) noexcept = 0;
    virtual bool setupAudio(const MoonlightCommonCAudioSelection& selection) noexcept = 0;
    virtual void startAudio() noexcept = 0;
    virtual void stopAudio() noexcept = 0;
    virtual void cleanupAudio() noexcept = 0;
    virtual void submitAudioPayload(const std::uint8_t* bytes,
                                    std::size_t byteCount) noexcept = 0;
};

struct REMOTEDESK_MOONLIGHT_COMMON_C_HIDDEN MoonlightCommonCServerEvidence final {
    std::string address;
    std::string appVersion;
    std::optional<std::string> gfeVersion;
    bool authenticated = false;
    std::uint64_t hostCapabilityGeneration = 0U;
    std::vector<MoonlightStreamCodecProfile> codecProfiles;
};

struct REMOTEDESK_MOONLIGHT_COMMON_C_HIDDEN MoonlightCommonCDeadlineSet final {
    std::uint64_t overallMonotonicMs = 0U;
    std::array<std::uint64_t, 11U> stageMonotonicMs {};
};

struct MoonlightCommonCAdapterAccess;

class REMOTEDESK_MOONLIGHT_COMMON_C_HIDDEN MoonlightRtspLaunchLease final {
public:
    MoonlightRtspLaunchLease() noexcept = default;
    MoonlightRtspLaunchLease(
        std::array<std::uint8_t, 16U> remoteInputKey,
        std::int32_t remoteInputKeyId,
        std::string rtspSessionUrl,
        std::uint64_t accountOwnerToken,
        std::uint64_t sessionGeneration,
        std::string hostId,
        std::string serverUuid,
        std::uint64_t hostCapabilityGeneration,
        std::uint64_t settingsRevision) noexcept;
    ~MoonlightRtspLaunchLease();

    MoonlightRtspLaunchLease(const MoonlightRtspLaunchLease&) = delete;
    MoonlightRtspLaunchLease& operator=(const MoonlightRtspLaunchLease&) = delete;
    MoonlightRtspLaunchLease(MoonlightRtspLaunchLease&& other) noexcept;
    MoonlightRtspLaunchLease& operator=(MoonlightRtspLaunchLease&& other) noexcept;

    bool valid() const noexcept;

private:
    friend struct MoonlightCommonCAdapterAccess;

    std::array<std::uint8_t, 16U> remoteInputKey_ {};
    std::int32_t remoteInputKeyId_ = 0;
    std::string rtspSessionUrl_;
    std::uint64_t accountOwnerToken_ = 0U;
    std::uint64_t sessionGeneration_ = 0U;
    std::string hostId_;
    std::string serverUuid_;
    std::uint64_t hostCapabilityGeneration_ = 0U;
    std::uint64_t settingsRevision_ = 0U;
    std::uint64_t boundSessionOwnerToken_ = 0U;
    bool consumed_ = false;
};

struct REMOTEDESK_MOONLIGHT_COMMON_C_HIDDEN MoonlightCommonCRequest final {
    MoonlightCommonCRequest() = default;
    MoonlightCommonCRequest(const MoonlightCommonCRequest&) = delete;
    MoonlightCommonCRequest& operator=(const MoonlightCommonCRequest&) = delete;
    MoonlightCommonCRequest(MoonlightCommonCRequest&&) noexcept = default;
    MoonlightCommonCRequest& operator=(MoonlightCommonCRequest&&) noexcept = default;

    std::uint64_t sessionId = 0U;
    std::uint64_t generation = 0U;
    std::uint64_t accountOwnerToken = 0U;
    // Exact process default-network generation that produced the authenticated
    // control-plane winner. Common-c may not start or remain active after it
    // changes.
    std::uint64_t networkGeneration = 0U;
    // Product sessions may defer platform/display proof to bindSession() and
    // network classification to common-c's resolved-address STREAM_CFG_AUTO
    // path. In this mode the corresponding capability generations must remain
    // zero and the offer must not claim a known network path or refresh rate.
    bool deferRuntimeCapabilityProof = false;
    MoonlightStreamConfigResult streamConfig;
    MoonlightCommonCServerEvidence server;
    MoonlightRtspLaunchLease launchLease;
    MoonlightCommonCDeadlineSet deadlines;
    // Executed by the invocation's terminal worker before common-c stop and
    // media release. Hooks must be noexcept in behavior and identity-fenced.
    std::function<void(const MoonlightSessionKey&)> terminalInputTeardown;
    std::function<void(const MoonlightSessionKey&)> terminalComplete;
};

struct REMOTEDESK_MOONLIGHT_COMMON_C_HIDDEN MoonlightCommonCStartResult final {
    MoonlightCommonCStartStatus status = MoonlightCommonCStartStatus::InvalidRequest;
    MoonlightCommonCCode code = MoonlightCommonCCode::InvalidRequest;
    MoonlightSessionKey key {};
};

struct REMOTEDESK_MOONLIGHT_COMMON_C_HIDDEN MoonlightCommonCEvent final {
    MoonlightSessionKey key {};
    std::uint64_t sequence = 0U;
    MoonlightCommonCEventType type = MoonlightCommonCEventType::Failed;
    MoonlightCommonCCode code = MoonlightCommonCCode::None;
    MoonlightCommonCStage stage = MoonlightCommonCStage::None;
    std::int32_t boundedRawError = 0;
    MoonlightCommonCConnectionQuality connectionQuality =
        MoonlightCommonCConnectionQuality::Unknown;
    std::optional<bool> hdrEnabled;
    std::optional<MoonlightCommonCVideoSelection> video;
    std::optional<MoonlightCommonCAudioSelection> audio;
};

struct REMOTEDESK_MOONLIGHT_COMMON_C_HIDDEN MoonlightCommonCSnapshot final {
    bool matched = false;
    MoonlightSessionKey key {};
    MoonlightCommonCCode terminalCode = MoonlightCommonCCode::None;
    MoonlightCommonCStage activeStage = MoonlightCommonCStage::None;
    MoonlightCommonCStage lastCompletedStage = MoonlightCommonCStage::None;
    bool protocolViolation = false;
    bool transportReady = false;
    bool videoReady = false;
    bool audioReady = false;
    bool firstFrameReady = false;
    bool terminal = false;
    bool secretsCleared = false;
    std::uint64_t lastSequence = 0U;
    std::size_t droppedEvents = 0U;
    std::size_t staleCallbacks = 0U;
    std::optional<MoonlightCommonCVideoSelection> video;
    std::optional<MoonlightCommonCAudioSelection> audio;
};

#if defined(RDP_NATIVE_CALLBACK_TESTING)
struct REMOTEDESK_MOONLIGHT_COMMON_C_HIDDEN MoonlightCommonCTestDriver final {
    std::function<int()> start;
    std::function<void()> interrupt;
    std::function<void()> stop;

    bool valid() const noexcept {
        return static_cast<bool>(start) && static_cast<bool>(interrupt) &&
            static_cast<bool>(stop);
    }
};

struct REMOTEDESK_MOONLIGHT_COMMON_C_HIDDEN MoonlightCommonCTestWireSnapshot final {
    bool valid = false;
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
    std::array<std::uint8_t, 16U> remoteInputKey {};
    std::array<std::uint8_t, 16U> remoteInputIv {};
};

class REMOTEDESK_MOONLIGHT_COMMON_C_HIDDEN MoonlightCommonCTestHarness final {
public:
    static bool stageStarting(std::int32_t rawStage) noexcept;
    static bool stageComplete(std::int32_t rawStage) noexcept;
    static bool stageFailed(std::int32_t rawStage, std::int32_t errorCode) noexcept;
    static bool connectionStarted() noexcept;
    static bool connectionTerminated(std::int32_t errorCode) noexcept;
    static bool connectionStatus(std::int32_t rawStatus) noexcept;
    static bool hdrMode(bool enabled) noexcept;
    static bool logNotice() noexcept;
    static int videoSetup(std::int32_t rawVideoFormat, std::int32_t width,
                          std::int32_t height, std::int32_t redrawRate) noexcept;
    static bool videoStart() noexcept;
    static bool videoStop() noexcept;
    static bool videoCleanup() noexcept;
    static int videoPayload(const MoonlightVideoDecodeUnitView& decodeUnit) noexcept;
    static int audioInit(std::int32_t rawAudioConfiguration,
                         const MoonlightCommonCOpusConfig& opus) noexcept;
    static bool audioStart() noexcept;
    static bool audioStop() noexcept;
    static bool audioCleanup() noexcept;
    static bool audioPayload(const std::uint8_t* bytes,
                             std::size_t byteCount) noexcept;
    static void audioPayloadRaw(const std::uint8_t* bytes,
                                std::int32_t byteCount) noexcept;
    static bool finalizing() noexcept;
    static std::optional<MoonlightCommonCTestWireSnapshot> wireSnapshot() noexcept;
    static std::int32_t videoFormatForProfile(
        const MoonlightStreamCodecProfile& profile) noexcept;
    static std::array<std::uint8_t, 16U> remoteInputIv(
        std::int32_t remoteInputKeyId) noexcept;
    static void clearRemoteInputSecrets(
        std::array<std::uint8_t, 16U>& key,
        std::array<std::uint8_t, 16U>& iv) noexcept;
    static std::size_t staleCallbackCount() noexcept;
};
#endif

class REMOTEDESK_MOONLIGHT_COMMON_C_HIDDEN MoonlightCommonCAdapter final {
private:
    struct Impl;

public:
    static MoonlightCommonCAdapter& process();

#if defined(RDP_NATIVE_CALLBACK_TESTING)
    static std::unique_ptr<MoonlightCommonCAdapter> createForTesting(
        MoonlightSessionOwner& owner,
        MoonlightCommonCTestDriver driver,
        std::shared_ptr<MoonlightCommonCMediaPort> mediaPort,
        std::function<std::uint64_t()> monotonicClock);
    void notifyClockForTesting() noexcept;
#endif

    ~MoonlightCommonCAdapter();
    MoonlightCommonCAdapter(const MoonlightCommonCAdapter&) = delete;
    MoonlightCommonCAdapter& operator=(const MoonlightCommonCAdapter&) = delete;

    MoonlightCommonCStartResult start(MoonlightCommonCRequest request) noexcept;
    MoonlightCommonCStartResult startWithMedia(
        MoonlightCommonCRequest request,
        std::shared_ptr<MoonlightCommonCMediaPort> mediaPort) noexcept;
    MoonlightStopStatus requestStop(const MoonlightSessionKey& key) noexcept;
    MoonlightStopStatus stop(
        const MoonlightSessionKey& key,
        std::chrono::milliseconds timeout = std::chrono::seconds(5)) noexcept;
    MoonlightCommonCSnapshot snapshot(const MoonlightSessionKey& key) const noexcept;
    std::vector<MoonlightCommonCEvent> drainEvents(
        const MoonlightSessionKey& key) noexcept;

    // Referenced only by an EXCLUDE_FROM_ALL executable to force the product
    // archive to resolve the official common-c entry points at link time.
    static int productionLinkSmoke() noexcept;

private:
    explicit MoonlightCommonCAdapter(std::unique_ptr<Impl> impl);
    std::unique_ptr<Impl> impl_;
};

} // namespace remotedesk::moonlight

#undef REMOTEDESK_MOONLIGHT_COMMON_C_HIDDEN

#endif // REMOTEDESK_MOONLIGHT_COMMON_C_ADAPTER_H
