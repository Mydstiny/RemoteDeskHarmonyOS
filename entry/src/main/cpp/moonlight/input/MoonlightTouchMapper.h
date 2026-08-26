#ifndef REMOTEDESK_MOONLIGHT_TOUCH_MAPPER_H
#define REMOTEDESK_MOONLIGHT_TOUCH_MAPPER_H

#include "moonlight/input/MoonlightPointerMapper.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>

#if defined(__GNUC__) || defined(__clang__)
#define REMOTEDESK_MOONLIGHT_TOUCH_HIDDEN __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_TOUCH_HIDDEN
#endif

namespace remotedesk::moonlight {

constexpr std::uint8_t kMoonlightTouchEventHover = 0x00U;
constexpr std::uint8_t kMoonlightTouchEventDown = 0x01U;
constexpr std::uint8_t kMoonlightTouchEventUp = 0x02U;
constexpr std::uint8_t kMoonlightTouchEventMove = 0x03U;
constexpr std::uint8_t kMoonlightTouchEventCancel = 0x04U;
constexpr std::uint8_t kMoonlightTouchEventButtonOnly = 0x05U;
constexpr std::uint8_t kMoonlightTouchEventHoverLeave = 0x06U;
constexpr std::uint8_t kMoonlightTouchEventCancelAll = 0x07U;
constexpr std::uint16_t kMoonlightTouchRotationUnknown = 0xFFFFU;
constexpr std::size_t kMoonlightTouchCommandBytes = 28U;
constexpr std::size_t kMoonlightMaximumTouchContacts = 10U;
constexpr std::size_t kMoonlightMaximumTouchpadContacts = 3U;
constexpr std::size_t kMoonlightMaximumTouchExclusionRegions = 8U;

enum class MoonlightTouchMode : std::uint8_t {
    Direct = 0,
    Touchpad,
};

enum class MoonlightTouchModeStatus : std::uint8_t {
    Ready = 0,
    Degraded,
    Unsupported,
    InvalidRequest,
};

enum class MoonlightTouchPhase : std::uint8_t {
    Down = 0,
    Move,
    Up,
    Cancel,
};

enum class MoonlightTouchLocalAction : std::uint8_t {
    None = 0,
    ToggleToolbar,
};

enum class MoonlightTouchStatus : std::uint8_t {
    Applied = 0,
    AppliedLocally,
    AlreadyApplied,
    OutsideContent,
    OverlayConsumed,
    Unsupported,
    InvalidRequest,
    InvalidState,
    StaleOwner,
    StaleEvent,
    StaleGeometry,
    Duplicate,
    NotActive,
    ContactCapacity,
    OutOfRange,
    SourceCapacity,
    Backpressure,
    PortUnsupported,
    PortFailure,
    Pending,
    FlushRequired,
};

struct REMOTEDESK_MOONLIGHT_TOUCH_HIDDEN MoonlightTouchModeRequest final {
    MoonlightTouchMode requested = MoonlightTouchMode::Touchpad;
    bool directTouchAvailable = false;
    bool allowTouchpadFallback = true;
};

struct REMOTEDESK_MOONLIGHT_TOUCH_HIDDEN MoonlightTouchModeResolution final {
    MoonlightTouchModeStatus status = MoonlightTouchModeStatus::InvalidRequest;
    MoonlightTouchMode effective = MoonlightTouchMode::Touchpad;
};

struct REMOTEDESK_MOONLIGHT_TOUCH_HIDDEN MoonlightTouchEventContext final {
    MoonlightInputIdentity identity{};
    std::uint64_t deviceId = 0U;
    MoonlightInputSource source = MoonlightInputSource::Invalid;
    std::uint64_t sourceGeneration = 0U;
    std::uint64_t sourceSequence = 0U;
    std::uint64_t monotonicTimestampUs = 0U;

    constexpr bool valid() const noexcept {
        return identity.valid() && deviceId != 0U && sourceGeneration != 0U &&
            sourceSequence != 0U && monotonicTimestampUs != 0U;
    }
};

// Regions use the same physical surface-pixel coordinate system as content.
// A down inside an exclusion belongs to local L3/L4 UI for its whole lifetime.
struct REMOTEDESK_MOONLIGHT_TOUCH_HIDDEN MoonlightTouchExclusionRegion final {
    double left = 0.0;
    double top = 0.0;
    double width = 0.0;
    double height = 0.0;
};

struct REMOTEDESK_MOONLIGHT_TOUCH_HIDDEN MoonlightTouchSurface final {
    MoonlightPointerContentRect content{};
    std::uint64_t hitMapGeneration = 0U;
    std::size_t exclusionCount = 0U;
    std::array<MoonlightTouchExclusionRegion,
               kMoonlightMaximumTouchExclusionRegions> exclusions{};
};

// Contact axes are already normalized to the unrotated video plane (0..1),
// while pointX/pointY remain physical surface pixels. A value of zero means
// pressure or contact area is unavailable, matching LiSendTouchEvent().
struct REMOTEDESK_MOONLIGHT_TOUCH_HIDDEN MoonlightTouchSample final {
    double pointX = 0.0;
    double pointY = 0.0;
    float pressure = 0.0F;
    float contactAreaMajor = 0.0F;
    float contactAreaMinor = 0.0F;
    std::uint16_t rotation = kMoonlightTouchRotationUnknown;
};

struct REMOTEDESK_MOONLIGHT_TOUCH_HIDDEN MoonlightTouchpadSettings final {
    double motionDeadZonePixels = 4.0;
    double tapTravelPixels = 20.0;
    std::uint64_t tapMaximumDurationUs = 250000U;
    double longPressTravelPixels = 20.0;
    std::uint64_t longPressDurationUs = 650000U;
    double scrollScale = 3.0;
};

struct REMOTEDESK_MOONLIGHT_TOUCH_HIDDEN MoonlightTouchLimits final {
    std::size_t maximumDirectContacts = kMoonlightMaximumTouchContacts;
    std::size_t maximumTouchpadContacts = kMoonlightMaximumTouchpadContacts;
    MoonlightTouchpadSettings touchpad{};
};

struct REMOTEDESK_MOONLIGHT_TOUCH_HIDDEN MoonlightTouchWireCommand final {
    std::uint8_t eventType = 0U;
    std::uint16_t rotation = kMoonlightTouchRotationUnknown;
    std::uint32_t pointerId = 0U;
    float x = 0.0F;
    float y = 0.0F;
    float pressureOrDistance = 0.0F;
    float contactAreaMajor = 0.0F;
    float contactAreaMinor = 0.0F;
};

struct REMOTEDESK_MOONLIGHT_TOUCH_HIDDEN MoonlightTouchResult final {
    MoonlightTouchStatus status = MoonlightTouchStatus::InvalidRequest;
    MoonlightInputDispatchStatus dispatchStatus = MoonlightInputDispatchStatus::InvalidRequest;
    MoonlightTouchLocalAction localAction = MoonlightTouchLocalAction::None;
    std::size_t acceptedCommands = 0U;
    std::size_t pendingCommands = 0U;
};

struct REMOTEDESK_MOONLIGHT_TOUCH_HIDDEN MoonlightTouchSnapshot final {
    bool matched = false;
    MoonlightInputIdentity identity{};
    MoonlightTouchMode mode = MoonlightTouchMode::Touchpad;
    std::size_t activeDirectContacts = 0U;
    std::size_t suppressedDirectContacts = 0U;
    std::size_t activeTouchpadContacts = 0U;
    bool touchpadDragButtonDown = false;
    std::uint64_t geometryGeneration = 0U;
    std::uint64_t hitMapGeneration = 0U;
    bool pending = false;
    std::size_t pendingCommands = 0U;
    std::uint64_t appliedTransactions = 0U;
    std::uint64_t localOnlyUpdates = 0U;
    std::uint64_t overlayConsumedEvents = 0U;
    std::uint64_t outsideContentEvents = 0U;
    std::uint64_t cancelledContacts = 0U;
    std::uint64_t invalidRequests = 0U;
    std::uint64_t staleGeometryEvents = 0U;
};

REMOTEDESK_MOONLIGHT_TOUCH_HIDDEN MoonlightTouchModeResolution
resolveMoonlightTouchMode(const MoonlightTouchModeRequest& request) noexcept;

REMOTEDESK_MOONLIGHT_TOUCH_HIDDEN bool decodeMoonlightTouchCommand(
    const MoonlightInputEvent& event,
    MoonlightTouchWireCommand& command) noexcept;

class REMOTEDESK_MOONLIGHT_TOUCH_HIDDEN MoonlightTouchMapper final {
  private:
    struct Impl;
    explicit MoonlightTouchMapper(std::unique_ptr<Impl> impl) noexcept;

  public:
    ~MoonlightTouchMapper();
    MoonlightTouchMapper(const MoonlightTouchMapper&) = delete;
    MoonlightTouchMapper& operator=(const MoonlightTouchMapper&) = delete;

    static std::shared_ptr<MoonlightTouchMapper> create(
        std::shared_ptr<MoonlightInputBridge> bridge,
        const MoonlightInputIdentity& identity,
        const MoonlightTouchModeRequest& modeRequest,
        MoonlightTouchLimits limits = {},
        MoonlightPointerLimits pointerLimits = {}) noexcept;

    MoonlightTouchResult process(const MoonlightTouchEventContext& context,
                                  const MoonlightTouchSurface& surface,
                                  std::uint64_t localContactId,
                                  MoonlightTouchPhase phase,
                                  const MoonlightTouchSample& sample) noexcept;
    MoonlightTouchResult cancelAll(const MoonlightTouchEventContext& context) noexcept;
    MoonlightTouchResult switchMode(const MoonlightTouchEventContext& context,
                                     MoonlightTouchMode mode) noexcept;

    MoonlightTouchResult resumePending() noexcept;
    bool cancelPendingIfUnsent(const MoonlightInputIdentity& identity) noexcept;
    bool discardLocalState(const MoonlightInputIdentity& identity) noexcept;
    MoonlightTouchSnapshot snapshot(const MoonlightInputIdentity& identity) const noexcept;

  private:
    std::unique_ptr<Impl> impl_;
};

} // namespace remotedesk::moonlight

#endif // REMOTEDESK_MOONLIGHT_TOUCH_MAPPER_H
