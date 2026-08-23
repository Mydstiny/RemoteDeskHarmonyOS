#ifndef REMOTEDESK_MOONLIGHT_HOST_CONTROL_H
#define REMOTEDESK_MOONLIGHT_HOST_CONTROL_H

#include "moonlight/core/MoonlightHostApi.h"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#if defined(__GNUC__)
#define REMOTEDESK_MOONLIGHT_CONTROL_HIDDEN __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_CONTROL_HIDDEN
#endif

namespace remotedesk::moonlight {

enum class MoonlightHostControlOperation : std::uint8_t {
    Catalog = 0,
    Asset,
    Launch,
    Resume,
    Quit,
};

enum class MoonlightHostControlStage : std::uint8_t {
    Idle = 0,
    Preflight,
    Authorizing,
    ReadingCatalog,
    ReadingAsset,
    ReadingHostState,
    DispatchingAction,
    VerifyingPostcondition,
    Complete,
    Failed,
    Cancelled,
};

enum class MoonlightHostControlCode : std::uint8_t {
    Ok = 0,
    InvalidArgument,
    Busy,
    Unavailable,
    Unpaired,
    AppNotFound,
    InvalidCatalog,
    ResumeRequired,
    HostBusy,
    ConfirmationRequired,
    ActionRejected,
    OutcomeUnknown,
    Cancelled,
    Stale,
    DeadlineExceeded,
    TransportFailure,
    ProtocolFailure,
    ShuttingDown,
};

enum class MoonlightHostControlTruth : std::uint8_t {
    NotAttempted = 0,
    Confirmed,
    Failed,
    Unknown,
};

enum class MoonlightHostControlAccessCode : std::uint8_t {
    Ready = 0,
    Unavailable,
    Cancelled,
    Stale,
    DeadlineExceeded,
};

struct REMOTEDESK_MOONLIGHT_CONTROL_HIDDEN MoonlightHostControlOperationKey final {
    std::uint64_t requestId = 0;
    std::uint64_t generation = 0;
    std::uint64_t ownerToken = 0;

    constexpr bool valid() const noexcept {
        return requestId != 0 && generation != 0 && ownerToken != 0;
    }
};

REMOTEDESK_MOONLIGHT_CONTROL_HIDDEN constexpr bool operator==(
    const MoonlightHostControlOperationKey& left,
    const MoonlightHostControlOperationKey& right) noexcept {
    return left.requestId == right.requestId && left.generation == right.generation &&
           left.ownerToken == right.ownerToken;
}

struct REMOTEDESK_MOONLIGHT_CONTROL_HIDDEN MoonlightHostControlContext final {
    MoonlightHostControlOperationKey key {};
    std::string ownerScopeFingerprint;
    std::string hostId;
    std::string serverUuid;
    MoonlightHostEndpoint endpoint {};
    std::chrono::milliseconds timeout {MoonlightHostLimits::kDefaultTimeout};
};

struct REMOTEDESK_MOONLIGHT_CONTROL_HIDDEN MoonlightLaunchConfiguration final {
    std::uint32_t width = 1920;
    std::uint32_t height = 1080;
    std::uint32_t refreshRate = 60;
    bool additionalStates = true;
    bool sops = true;
    bool hdr = false;
    bool playAudioOnHost = false;
    std::uint32_t surroundAudioInfo = 196610;
    std::uint32_t remoteControllersBitmap = 0;
    std::uint32_t gamepadMask = 0;
    bool persistGamepads = false;
};

class REMOTEDESK_MOONLIGHT_CONTROL_HIDDEN MoonlightLaunchMaterial final {
public:
    MoonlightLaunchMaterial() noexcept = default;
    MoonlightLaunchMaterial(std::vector<std::uint8_t> riKey, std::int32_t riKeyId,
                            MoonlightLaunchConfiguration configuration) noexcept;
    ~MoonlightLaunchMaterial();

    MoonlightLaunchMaterial(const MoonlightLaunchMaterial&) = delete;
    MoonlightLaunchMaterial& operator=(const MoonlightLaunchMaterial&) = delete;
    MoonlightLaunchMaterial(MoonlightLaunchMaterial&& other) noexcept;
    MoonlightLaunchMaterial& operator=(MoonlightLaunchMaterial&& other) noexcept;

    bool valid() const noexcept;

private:
    friend class MoonlightHostControl;

    std::vector<std::uint8_t> riKey_;
    std::int32_t riKeyId_ = 0;
    MoonlightLaunchConfiguration configuration_ {};
};

struct REMOTEDESK_MOONLIGHT_CONTROL_HIDDEN MoonlightCatalogRequest final {
    MoonlightHostControlContext context {};
};

struct REMOTEDESK_MOONLIGHT_CONTROL_HIDDEN MoonlightAssetRequest final {
    MoonlightHostControlContext context {};
    std::uint32_t appId = 0;
    std::uint64_t catalogGeneration = 0;
};

struct REMOTEDESK_MOONLIGHT_CONTROL_HIDDEN MoonlightLaunchRequest final {
    MoonlightLaunchRequest() = default;
    MoonlightLaunchRequest(const MoonlightLaunchRequest&) = delete;
    MoonlightLaunchRequest& operator=(const MoonlightLaunchRequest&) = delete;
    MoonlightLaunchRequest(MoonlightLaunchRequest&&) noexcept = default;
    MoonlightLaunchRequest& operator=(MoonlightLaunchRequest&&) noexcept = default;

    MoonlightHostControlContext context {};
    std::uint32_t appId = 0;
    MoonlightLaunchMaterial material {};
};

struct REMOTEDESK_MOONLIGHT_CONTROL_HIDDEN MoonlightQuitRequest final {
    MoonlightHostControlContext context {};
    std::uint32_t expectedCurrentAppId = 0;
    bool userConfirmedTermination = false;
};

struct REMOTEDESK_MOONLIGHT_CONTROL_HIDDEN MoonlightHostControlDiagnostic final {
    MoonlightHostControlOperation operation = MoonlightHostControlOperation::Catalog;
    MoonlightHostControlStage stage = MoonlightHostControlStage::Idle;
    MoonlightHostControlCode code = MoonlightHostControlCode::InvalidArgument;
    MoonlightHostError hostError = MoonlightHostError::None;
    int httpStatus = 0;
    std::int32_t xmlStatus = 0;
    std::size_t transportAttempts = 0;
    std::size_t byteCount = 0;
    std::uint64_t generation = 0;
    std::uint64_t appIdFingerprint = 0;
};

struct REMOTEDESK_MOONLIGHT_CONTROL_HIDDEN MoonlightHostControlResult final {
    MoonlightHostControlResult() = default;
    ~MoonlightHostControlResult();
    MoonlightHostControlResult(const MoonlightHostControlResult&) = delete;
    MoonlightHostControlResult& operator=(const MoonlightHostControlResult&) = delete;
    MoonlightHostControlResult(MoonlightHostControlResult&& other) noexcept;
    MoonlightHostControlResult& operator=(MoonlightHostControlResult&& other) noexcept;

    MoonlightHostControlCode code = MoonlightHostControlCode::InvalidArgument;
    MoonlightHostControlStage terminalStage = MoonlightHostControlStage::Failed;
    MoonlightHostControlTruth preflightTruth = MoonlightHostControlTruth::NotAttempted;
    MoonlightHostControlTruth actionTruth = MoonlightHostControlTruth::NotAttempted;
    MoonlightHostControlTruth postconditionTruth = MoonlightHostControlTruth::NotAttempted;
    MoonlightHostError lastHostError = MoonlightHostError::None;
    int lastHttpStatus = 0;
    std::int32_t lastXmlStatus = 0;
    std::size_t transportAttempts = 0;
    std::size_t partialAppCount = 0;
    std::uint64_t generation = 0;
    std::uint64_t observedAtMs = 0;
    bool idempotent = false;
    bool mutationMayHaveBeenSent = false;
    std::vector<MoonlightAppEntry> apps;
    std::vector<std::uint8_t> asset;
    std::optional<std::string> rtspSessionUrl;
    // Native-only address selected by the successful launch action. It is
    // consumed by ProductRuntime and never projected through ArkTS.
    std::optional<std::string> sessionAddress;
    // Native-only authenticated launch snapshot used to build the subsequent
    // common-c lease. For Sunshine, /serverinfo can block while the RTSP
    // session is waiting for the client; the snapshot therefore comes from
    // the authenticated pre-launch read plus the accepted launch receipt and
    // is intentionally not projected through ArkTS.
    std::optional<MoonlightServerInfo> sessionServerInfo;
    std::vector<MoonlightHostControlStage> stageTrace;
    std::vector<MoonlightHostControlDiagnostic> diagnostics;

    bool ok() const noexcept { return code == MoonlightHostControlCode::Ok; }
};

class REMOTEDESK_MOONLIGHT_CONTROL_HIDDEN MoonlightHostControlAccessPort {
public:
    using CancellationProbe = std::function<bool()>;

    virtual ~MoonlightHostControlAccessPort() = default;
    virtual bool available() const noexcept = 0;
    // Proves that the exact owner/generation has a paired certificate pin,
    // client identity, and transport binding. It never returns secret bytes.
    virtual MoonlightHostControlAccessCode authorize(
        const MoonlightHostControlContext& context,
        std::chrono::steady_clock::time_point absoluteDeadline,
        const CancellationProbe& cancellationProbe) = 0;
    virtual void cancel(const MoonlightHostControlOperationKey& key) noexcept = 0;
};

class REMOTEDESK_MOONLIGHT_CONTROL_HIDDEN MoonlightHostControl final {
public:
    struct Impl;
    using MonotonicClock = std::function<std::chrono::steady_clock::time_point()>;
    using WallClock = std::function<std::uint64_t()>;

    MoonlightHostControl(std::shared_ptr<MoonlightHostApi> hostApi,
                         std::shared_ptr<MoonlightHostControlAccessPort> accessPort,
                         MonotonicClock monotonicClock = {}, WallClock wallClock = {});
    ~MoonlightHostControl();

    MoonlightHostControl(const MoonlightHostControl&) = delete;
    MoonlightHostControl& operator=(const MoonlightHostControl&) = delete;

    MoonlightHostControlResult catalog(MoonlightCatalogRequest request) noexcept;
    MoonlightHostControlResult asset(MoonlightAssetRequest request) noexcept;
    MoonlightHostControlResult launch(MoonlightLaunchRequest request) noexcept;
    MoonlightHostControlResult resume(MoonlightLaunchRequest request) noexcept;
    MoonlightHostControlResult quit(MoonlightQuitRequest request) noexcept;
    bool cancel(const MoonlightHostControlOperationKey& key) noexcept;

#if defined(RDP_NATIVE_CALLBACK_TESTING)
    static std::uint64_t secureCleanseCountForTesting() noexcept;
    static void resetSecureCleanseCountForTesting() noexcept;
#endif

private:
    MoonlightHostControlResult runLaunch(MoonlightHostControlOperation operation,
                                         MoonlightLaunchRequest request) noexcept;
    std::shared_ptr<Impl> impl_;
};

} // namespace remotedesk::moonlight

#undef REMOTEDESK_MOONLIGHT_CONTROL_HIDDEN

#endif // REMOTEDESK_MOONLIGHT_HOST_CONTROL_H
