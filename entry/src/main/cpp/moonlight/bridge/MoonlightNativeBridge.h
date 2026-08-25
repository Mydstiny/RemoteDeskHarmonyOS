#ifndef REMOTEDESK_MOONLIGHT_NATIVE_BRIDGE_H
#define REMOTEDESK_MOONLIGHT_NATIVE_BRIDGE_H

#include "moonlight/core/MoonlightHostApi.h"

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#if defined(__GNUC__)
#define REMOTEDESK_MOONLIGHT_BRIDGE_HIDDEN __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_BRIDGE_HIDDEN
#endif

namespace remotedesk::moonlight {

enum class MoonlightBridgeOperation : std::uint8_t {
    Pair = 0,
    Catalog,
    Asset,
    Launch,
    Resume,
    Quit,
    Unpair,
    DeleteIdentity,
};

enum class MoonlightBridgeCode : std::uint8_t {
    Ok = 0,
    InvalidArgument,
    Busy,
    RuntimeProofRequired,
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
    RepairRequired,
    ShuttingDown,
};

enum class MoonlightBridgeTruth : std::uint8_t {
    NotAttempted = 0,
    Confirmed,
    Failed,
    Unknown,
};

enum class MoonlightBridgeTerminalStage : std::uint8_t {
    Complete = 0,
    Failed,
    Cancelled,
};

struct REMOTEDESK_MOONLIGHT_BRIDGE_HIDDEN MoonlightBridgeRequestKey final {
    std::uint64_t requestId = 0;
    std::uint64_t generation = 0;
    std::uint64_t ownerToken = 0;

    constexpr bool valid() const noexcept {
        return requestId != 0U && generation != 0U && ownerToken != 0U;
    }
};

REMOTEDESK_MOONLIGHT_BRIDGE_HIDDEN constexpr bool operator==(
    const MoonlightBridgeRequestKey& left,
    const MoonlightBridgeRequestKey& right) noexcept {
    return left.requestId == right.requestId && left.generation == right.generation &&
           left.ownerToken == right.ownerToken;
}

REMOTEDESK_MOONLIGHT_BRIDGE_HIDDEN constexpr bool operator!=(
    const MoonlightBridgeRequestKey& left,
    const MoonlightBridgeRequestKey& right) noexcept {
    return !(left == right);
}

struct REMOTEDESK_MOONLIGHT_BRIDGE_HIDDEN MoonlightBridgeLaunchConfiguration final {
    enum class VideoCodec : std::uint8_t { H264, Hevc, Av1 };
    enum class ResolutionPolicy : std::uint8_t { Exact, HostCapability };
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
    VideoCodec videoCodec = VideoCodec::H264;
    ResolutionPolicy resolutionPolicy = ResolutionPolicy::Exact;
};

struct REMOTEDESK_MOONLIGHT_BRIDGE_HIDDEN MoonlightBridgeRequest final {
    MoonlightBridgeRequest() = default;
    ~MoonlightBridgeRequest();
    MoonlightBridgeRequest(const MoonlightBridgeRequest&) = delete;
    MoonlightBridgeRequest& operator=(const MoonlightBridgeRequest&) = delete;
    MoonlightBridgeRequest(MoonlightBridgeRequest&& other) noexcept;
    MoonlightBridgeRequest& operator=(MoonlightBridgeRequest&& other) noexcept;

    MoonlightBridgeOperation operation = MoonlightBridgeOperation::Catalog;
    MoonlightBridgeRequestKey key {};
    std::string ownerScopeFingerprint;
    std::string installationId;
    std::string hostId;
    std::string serverUuid;
    // Optional durable local trust projection. It is the lowercase SHA-256
    // of the paired server leaf certificate, never certificate/private-key
    // material. Product Host Control uses it to rehydrate exact pinning after
    // an app restart; an in-process pairing may leave it empty.
    std::string pinnedCertificateSha256;
    MoonlightHostEndpoint endpoint {};
    std::chrono::milliseconds timeout {MoonlightHostLimits::kDefaultTimeout};
    std::uint32_t appId = 0;
    std::uint64_t catalogGeneration = 0;
    std::uint32_t expectedCurrentAppId = 0;
    bool userConfirmedTermination = false;
    bool allowLegacySha1 = false;
    std::vector<std::uint8_t> pin;
    std::vector<std::uint8_t> riKey;
    std::int32_t riKeyId = 0;
    MoonlightBridgeLaunchConfiguration launchConfiguration {};
};

struct REMOTEDESK_MOONLIGHT_BRIDGE_HIDDEN MoonlightBridgeApp final {
    std::uint32_t id = 0;
    std::string title;
    std::optional<bool> hdrSupported;
};

struct REMOTEDESK_MOONLIGHT_BRIDGE_HIDDEN MoonlightBridgeDiagnostic final {
    std::string stage;
    std::string code;
    int httpStatus = 0;
    std::int32_t xmlStatus = 0;
    std::size_t transportAttempts = 0;
    std::size_t byteCount = 0;
    std::uint64_t appIdFingerprint = 0;
};

struct REMOTEDESK_MOONLIGHT_BRIDGE_HIDDEN MoonlightBridgeResult final {
    MoonlightBridgeResult() = default;
    ~MoonlightBridgeResult();
    MoonlightBridgeResult(const MoonlightBridgeResult&) = delete;
    MoonlightBridgeResult& operator=(const MoonlightBridgeResult&) = delete;
    MoonlightBridgeResult(MoonlightBridgeResult&& other) noexcept;
    MoonlightBridgeResult& operator=(MoonlightBridgeResult&& other) noexcept;

    MoonlightBridgeOperation operation = MoonlightBridgeOperation::Catalog;
    MoonlightBridgeRequestKey key {};
    MoonlightBridgeCode code = MoonlightBridgeCode::InvalidArgument;
    MoonlightBridgeTerminalStage terminalStage = MoonlightBridgeTerminalStage::Failed;
    MoonlightBridgeTruth preflightTruth = MoonlightBridgeTruth::NotAttempted;
    MoonlightBridgeTruth actionTruth = MoonlightBridgeTruth::NotAttempted;
    MoonlightBridgeTruth postconditionTruth = MoonlightBridgeTruth::NotAttempted;
    std::size_t partialAppCount = 0;
    std::uint64_t observedAtMs = 0;
    bool idempotent = false;
    bool mutationMayHaveBeenSent = false;
    // DeleteIdentity exposes counts only. Native aliases, certificates and
    // secure-store references never cross the bridge boundary.
    std::size_t identityExistingCount = 0;
    std::size_t identityDeletedCount = 0;
    std::size_t identityRemainingCount = 0;
    std::vector<MoonlightBridgeApp> apps;
    std::vector<std::uint8_t> asset;
    // Public trust metadata returned by a successful pair operation.
    std::string certificateSha256;
    std::optional<std::string> rtspSessionUrl;
    std::vector<MoonlightBridgeDiagnostic> diagnostics;

    bool ok() const noexcept { return code == MoonlightBridgeCode::Ok; }
};

struct REMOTEDESK_MOONLIGHT_BRIDGE_HIDDEN MoonlightBridgeEvent final {
    std::uint64_t sequence = 0;
    std::uint64_t monotonicTimestampMs = 0;
    MoonlightBridgeOperation operation = MoonlightBridgeOperation::Catalog;
    MoonlightBridgeRequestKey key {};
    MoonlightBridgeCode code = MoonlightBridgeCode::InvalidArgument;
    MoonlightBridgeTerminalStage terminalStage = MoonlightBridgeTerminalStage::Failed;
};

struct REMOTEDESK_MOONLIGHT_BRIDGE_HIDDEN MoonlightBridgeCapabilities final {
    bool bridgeCompiled = true;
    bool identityReady = false;
    bool identityDeletionReady = false;
    bool transportReady = false;
    bool trustReady = false;
    bool commitReady = false;
    bool pairingReady = false;
    bool hostControlReady = false;
    std::string blocker = "runtime_proof_required";
};

class REMOTEDESK_MOONLIGHT_BRIDGE_HIDDEN MoonlightNativeRuntimePort {
public:
    using CancellationProbe = std::function<bool()>;

    virtual ~MoonlightNativeRuntimePort() = default;
    virtual MoonlightBridgeCapabilities capabilities() const noexcept = 0;
    virtual MoonlightBridgeResult execute(
        MoonlightBridgeRequest request,
        const CancellationProbe& cancellationProbe) = 0;
    virtual void cancel(const MoonlightBridgeRequestKey& key) noexcept = 0;
};

class REMOTEDESK_MOONLIGHT_BRIDGE_HIDDEN MoonlightUnavailableRuntimePort final
    : public MoonlightNativeRuntimePort {
public:
    MoonlightBridgeCapabilities capabilities() const noexcept override;
    MoonlightBridgeResult execute(
        MoonlightBridgeRequest request,
        const CancellationProbe& cancellationProbe) override;
    void cancel(const MoonlightBridgeRequestKey& key) noexcept override;
};

class REMOTEDESK_MOONLIGHT_BRIDGE_HIDDEN MoonlightNativeBridge final {
public:
    struct Impl;
    using MonotonicClock = std::function<std::chrono::steady_clock::time_point()>;

    explicit MoonlightNativeBridge(
        std::shared_ptr<MoonlightNativeRuntimePort> runtimePort,
        MonotonicClock monotonicClock = {});
    ~MoonlightNativeBridge();

    MoonlightNativeBridge(const MoonlightNativeBridge&) = delete;
    MoonlightNativeBridge& operator=(const MoonlightNativeBridge&) = delete;

    MoonlightBridgeCapabilities capabilities() const noexcept;
    MoonlightBridgeResult execute(
        MoonlightBridgeRequest request,
        MoonlightNativeRuntimePort::CancellationProbe externalCancellation = {}) noexcept;
    bool cancel(const MoonlightBridgeRequestKey& key) noexcept;
    std::size_t cancelOwner(std::uint64_t ownerToken) noexcept;
    std::vector<MoonlightBridgeEvent> pollEvents(
        std::uint64_t ownerToken, std::uint64_t afterSequence,
        std::size_t limit = 64U) const noexcept;
    void shutdown() noexcept;

#if defined(RDP_NATIVE_CALLBACK_TESTING)
    static std::uint64_t secureCleanseCountForTesting() noexcept;
    static void resetSecureCleanseCountForTesting() noexcept;
#endif

private:
    std::shared_ptr<Impl> impl_;
};

REMOTEDESK_MOONLIGHT_BRIDGE_HIDDEN const char* moonlightBridgeOperationName(
    MoonlightBridgeOperation operation) noexcept;
REMOTEDESK_MOONLIGHT_BRIDGE_HIDDEN const char* moonlightBridgeCodeName(
    MoonlightBridgeCode code) noexcept;
REMOTEDESK_MOONLIGHT_BRIDGE_HIDDEN const char* moonlightBridgeTruthName(
    MoonlightBridgeTruth truth) noexcept;
REMOTEDESK_MOONLIGHT_BRIDGE_HIDDEN const char* moonlightBridgeTerminalStageName(
    MoonlightBridgeTerminalStage stage) noexcept;

} // namespace remotedesk::moonlight

#undef REMOTEDESK_MOONLIGHT_BRIDGE_HIDDEN

#endif // REMOTEDESK_MOONLIGHT_NATIVE_BRIDGE_H
