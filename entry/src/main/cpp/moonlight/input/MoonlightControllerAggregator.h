#ifndef REMOTEDESK_MOONLIGHT_CONTROLLER_AGGREGATOR_H
#define REMOTEDESK_MOONLIGHT_CONTROLLER_AGGREGATOR_H

#include "moonlight/input/MoonlightInputFlushPolicy.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>

#if defined(__GNUC__) || defined(__clang__)
#define REMOTEDESK_MOONLIGHT_CONTROLLER_AGGREGATOR_HIDDEN \
    __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_CONTROLLER_AGGREGATOR_HIDDEN
#endif

namespace remotedesk::moonlight {

constexpr std::uint32_t kMoonlightVirtualControllerLayoutVersion = 1U;
// A split four-button dpad plus every standard Moonlight control needs 19
// elements. Keep the bound fixed and small while allowing that complete form.
constexpr std::size_t kMoonlightMaximumVirtualControllerElements = 20U;
constexpr std::size_t kMoonlightMaximumControllerConflictZones = 8U;
constexpr std::size_t kMoonlightMaximumVirtualControllerContacts = 10U;
constexpr double kMoonlightMinimumControllerTouchTarget = 0.08;
constexpr double kMoonlightMinimumControllerStickTarget = 0.14;

enum class MoonlightControllerSourceKind : std::uint8_t {
    Invalid = 0,
    Physical,
    Virtual,
};

enum class MoonlightVirtualControllerElementKind : std::uint8_t {
    Invalid = 0,
    FaceA,
    FaceB,
    FaceX,
    FaceY,
    DpadCluster,
    DpadUp,
    DpadDown,
    DpadLeft,
    DpadRight,
    LeftStick,
    RightStick,
    LeftTrigger,
    RightTrigger,
    LeftShoulder,
    RightShoulder,
    LeftStickClick,
    RightStickClick,
    Menu,
    Back,
    Special,
};

enum class MoonlightVirtualControllerPhase : std::uint8_t {
    Invalid = 0,
    Begin,
    Change,
    End,
    Cancel,
};

enum class MoonlightVirtualControllerLayoutStatus : std::uint8_t {
    Accepted = 0,
    Clamped,
    Fallback,
    InvalidEnvironment,
    Unavailable,
    InvalidState,
    StaleOwner,
    StaleGeneration,
};

enum class MoonlightControllerAggregatorStatus : std::uint8_t {
    Applied = 0,
    AppliedLocally,
    AlreadyApplied,
    Pending,
    Editing,
    InvalidRequest,
    InvalidState,
    StaleOwner,
    StaleSource,
    StaleLayout,
    Duplicate,
    Backpressure,
    PortUnsupported,
    PortFailure,
    SessionTerminated,
};

enum class MoonlightControllerAggregatorState : std::uint8_t {
    Idle = 0,
    Editing,
    Connecting,
    Active,
    LifecyclePending,
    Suspended,
    HandoffRemoving,
    HandoffBoundaryPending,
    HandoffResuming,
    HandoffConnecting,
    Terminating,
    Stopped,
};

struct REMOTEDESK_MOONLIGHT_CONTROLLER_AGGREGATOR_HIDDEN
MoonlightControllerNormalizedRect final {
    double left = 0.0;
    double top = 0.0;
    double width = 0.0;
    double height = 0.0;
};

struct REMOTEDESK_MOONLIGHT_CONTROLLER_AGGREGATOR_HIDDEN
MoonlightControllerSafeArea final {
    double leftInset = 0.0;
    double topInset = 0.0;
    double rightInset = 0.0;
    double bottomInset = 0.0;
};

struct REMOTEDESK_MOONLIGHT_CONTROLLER_AGGREGATOR_HIDDEN
MoonlightControllerLayoutEnvironment final {
    MoonlightControllerSafeArea safeArea{};
    std::size_t conflictZoneCount = 0U;
    std::array<MoonlightControllerNormalizedRect,
               kMoonlightMaximumControllerConflictZones> conflictZones{};
};

struct REMOTEDESK_MOONLIGHT_CONTROLLER_AGGREGATOR_HIDDEN
MoonlightVirtualControllerElement final {
    std::uint16_t id = 0U;
    MoonlightVirtualControllerElementKind kind =
        MoonlightVirtualControllerElementKind::Invalid;
    MoonlightControllerNormalizedRect bounds{};
};

struct REMOTEDESK_MOONLIGHT_CONTROLLER_AGGREGATOR_HIDDEN
MoonlightVirtualControllerLayout final {
    std::uint32_t version = kMoonlightVirtualControllerLayoutVersion;
    std::uint64_t generation = 0U;
    std::size_t elementCount = 0U;
    std::array<MoonlightVirtualControllerElement,
               kMoonlightMaximumVirtualControllerElements> elements{};
};

struct REMOTEDESK_MOONLIGHT_CONTROLLER_AGGREGATOR_HIDDEN
MoonlightVirtualControllerLayoutResult final {
    MoonlightVirtualControllerLayoutStatus status =
        MoonlightVirtualControllerLayoutStatus::Unavailable;
    MoonlightVirtualControllerLayout layout{};
    std::size_t clampedElements = 0U;
    bool fallbackUsed = false;
};

struct REMOTEDESK_MOONLIGHT_CONTROLLER_AGGREGATOR_HIDDEN
MoonlightControllerSourceContext final {
    MoonlightInputIdentity identity{};
    MoonlightControllerSourceKind kind = MoonlightControllerSourceKind::Invalid;
    std::uint64_t deviceId = 0U;
    std::uint64_t sourceGeneration = 0U;
    std::uint64_t sourceSequence = 0U;
    std::uint64_t monotonicTimestampUs = 0U;
    // Physical events use zero. Virtual events must match the installed
    // validated layout generation exactly.
    std::uint64_t layoutGeneration = 0U;

    constexpr bool valid() const noexcept {
        return identity.valid() && kind != MoonlightControllerSourceKind::Invalid &&
            deviceId != 0U && sourceGeneration != 0U &&
            sourceSequence != 0U && monotonicTimestampUs != 0U &&
            ((kind == MoonlightControllerSourceKind::Physical &&
              layoutGeneration == 0U) ||
             (kind == MoonlightControllerSourceKind::Virtual &&
              layoutGeneration != 0U));
    }
};

struct REMOTEDESK_MOONLIGHT_CONTROLLER_AGGREGATOR_HIDDEN
MoonlightVirtualControllerEvent final {
    MoonlightControllerSourceContext context{};
    std::uint16_t elementId = 0U;
    std::uint64_t pointerId = 0U;
    MoonlightVirtualControllerPhase phase =
        MoonlightVirtualControllerPhase::Invalid;
    // Already-normalized semantic values. Buttons require zero/zero, sticks
    // and dpad use [-1, 1], and triggers use primary in [0, 1].
    double primary = 0.0;
    double secondary = 0.0;
};

struct REMOTEDESK_MOONLIGHT_CONTROLLER_AGGREGATOR_HIDDEN
MoonlightControllerHandoffRequest final {
    MoonlightControllerSourceContext target{};
    // Used only for a physical target. Virtual profiles are derived from the
    // validated layout so a UI caller cannot advertise wire capabilities.
    MoonlightControllerProfile targetPhysicalProfile{};
    MoonlightInputFlushContext disconnectFlush{};
    // Reserved only for retrying a failed suspend boundary. It must be newer
    // than disconnectFlush and older than resumeOperationGeneration.
    std::uint64_t boundaryRetryOperationGeneration = 0U;
    std::uint64_t boundaryRetryTimestampUs = 0U;
    std::uint64_t resumeOperationGeneration = 0U;
    // Exact terminal escalation supplied by the single input owner. It must
    // be newer than both disconnect and resume generations.
    MoonlightInputFlushContext terminalFlush{};
};

struct REMOTEDESK_MOONLIGHT_CONTROLLER_AGGREGATOR_HIDDEN
MoonlightControllerAggregatorResult final {
    MoonlightControllerAggregatorStatus status =
        MoonlightControllerAggregatorStatus::InvalidRequest;
    MoonlightControllerStatus controllerStatus =
        MoonlightControllerStatus::InvalidRequest;
    MoonlightInputFlushStatus flushStatus =
        MoonlightInputFlushStatus::InvalidRequest;
    bool retryable = false;
    bool remoteReleaseComplete = false;
    bool boundaryApplied = false;
};

struct REMOTEDESK_MOONLIGHT_CONTROLLER_AGGREGATOR_HIDDEN
MoonlightControllerAggregatorSnapshot final {
    bool matched = false;
    MoonlightInputIdentity identity{};
    MoonlightControllerAggregatorState state =
        MoonlightControllerAggregatorState::Idle;
    MoonlightControllerSourceKind activeSource =
        MoonlightControllerSourceKind::Invalid;
    std::uint64_t deviceId = 0U;
    std::uint64_t sourceGeneration = 0U;
    std::uint64_t layoutGeneration = 0U;
    std::uint64_t lastControlGeneration = 0U;
    MoonlightControllerSample sample{};
    std::size_t activeContacts = 0U;
    bool pendingFrame = false;
    std::uint64_t acceptedFrames = 0U;
    std::uint64_t localOnlyFrames = 0U;
    std::uint64_t lifecycleFlushes = 0U;
    std::uint64_t handoffs = 0U;
    std::uint64_t terminalStops = 0U;
    std::uint64_t rejectedEvents = 0U;
};

REMOTEDESK_MOONLIGHT_CONTROLLER_AGGREGATOR_HIDDEN
MoonlightVirtualControllerLayoutResult validateMoonlightVirtualControllerLayout(
    const MoonlightVirtualControllerLayout& candidate,
    const MoonlightControllerLayoutEnvironment& environment) noexcept;

REMOTEDESK_MOONLIGHT_CONTROLLER_AGGREGATOR_HIDDEN
MoonlightInputSource moonlightControllerInputSource(
    MoonlightControllerSourceKind kind) noexcept;

class REMOTEDESK_MOONLIGHT_CONTROLLER_AGGREGATOR_HIDDEN
MoonlightControllerAggregator final {
  private:
    struct Impl;
    explicit MoonlightControllerAggregator(std::unique_ptr<Impl> impl) noexcept;

  public:
    ~MoonlightControllerAggregator();
    MoonlightControllerAggregator(const MoonlightControllerAggregator&) = delete;
    MoonlightControllerAggregator& operator=(
        const MoonlightControllerAggregator&) = delete;

    static std::shared_ptr<MoonlightControllerAggregator> create(
        std::shared_ptr<MoonlightControllerMapper> mapper,
        std::shared_ptr<MoonlightInputFlushPolicy> flushPolicy,
        const MoonlightInputIdentity& identity) noexcept;

    MoonlightControllerAggregatorResult setEditing(
        const MoonlightInputIdentity& identity,
        bool editing,
        std::uint64_t controlGeneration) noexcept;

    MoonlightVirtualControllerLayoutResult installLayout(
        const MoonlightInputIdentity& identity,
        const MoonlightVirtualControllerLayout& candidate,
        const MoonlightControllerLayoutEnvironment& environment) noexcept;

    MoonlightControllerAggregatorResult connectPhysical(
        const MoonlightControllerSourceContext& context,
        const MoonlightControllerProfile& profile) noexcept;
    MoonlightControllerAggregatorResult connectVirtual(
        const MoonlightControllerSourceContext& context) noexcept;

    MoonlightControllerAggregatorResult ingestPhysical(
        const MoonlightControllerSourceContext& context,
        const MoonlightControllerSample& sample) noexcept;
    MoonlightControllerAggregatorResult ingestVirtual(
        const MoonlightVirtualControllerEvent& event) noexcept;

    MoonlightControllerAggregatorResult handleLifecycle(
        MoonlightInputFlushTrigger trigger,
        const MoonlightInputFlushContext& context) noexcept;
    MoonlightControllerAggregatorResult retryLifecycleBoundary(
        const MoonlightInputIdentity& identity,
        std::uint64_t operationGeneration,
        std::uint64_t monotonicTimestampUs) noexcept;
    MoonlightControllerAggregatorResult resumeLifecycle(
        const MoonlightInputIdentity& identity,
        std::uint64_t operationGeneration) noexcept;

    MoonlightControllerAggregatorResult switchSource(
        const MoonlightControllerHandoffRequest& request) noexcept;

    MoonlightControllerAggregatorSnapshot snapshot(
        const MoonlightInputIdentity& identity) const noexcept;

  private:
    std::unique_ptr<Impl> impl_;
};

} // namespace remotedesk::moonlight

#undef REMOTEDESK_MOONLIGHT_CONTROLLER_AGGREGATOR_HIDDEN

#endif // REMOTEDESK_MOONLIGHT_CONTROLLER_AGGREGATOR_H
