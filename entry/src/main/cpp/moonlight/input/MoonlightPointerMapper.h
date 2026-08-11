#ifndef REMOTEDESK_MOONLIGHT_POINTER_MAPPER_H
#define REMOTEDESK_MOONLIGHT_POINTER_MAPPER_H

#include "moonlight/input/MoonlightInputBridge.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>

#if defined(__GNUC__) || defined(__clang__)
#define REMOTEDESK_MOONLIGHT_POINTER_HIDDEN __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_POINTER_HIDDEN
#endif

namespace remotedesk::moonlight {

constexpr std::uint8_t kMoonlightPointerActionPress = 0x07U;
constexpr std::uint8_t kMoonlightPointerActionRelease = 0x08U;
constexpr std::uint8_t kMoonlightPointerCapabilityCapture = 0x01U;
constexpr std::uint8_t kMoonlightPointerCapabilityConstraint = 0x02U;
constexpr std::uint8_t kMoonlightPointerCapabilityRawRelative = 0x04U;
constexpr std::uint8_t kMoonlightPointerKnownCapabilities =
    kMoonlightPointerCapabilityCapture |
    kMoonlightPointerCapabilityConstraint |
    kMoonlightPointerCapabilityRawRelative;
constexpr std::size_t kMoonlightRelativePointerCommandBytes = 4U;
constexpr std::size_t kMoonlightAbsolutePointerCommandBytes = 8U;
constexpr std::size_t kMoonlightPointerButtonCommandBytes = 2U;
constexpr std::size_t kMoonlightPointerScrollCommandBytes = 2U;
constexpr std::size_t kMoonlightMaximumPointerButtons = 5U;
constexpr std::size_t kMoonlightMaximumPointerTransactionCommands = 5U;
constexpr std::size_t kMoonlightPointerSequenceStride = 8U;

enum class MoonlightPointerMode : std::uint8_t {
    Absolute = 0,
    Relative,
};

enum class MoonlightPointerModeStatus : std::uint8_t {
    Ready = 0,
    Degraded,
    Unsupported,
    InvalidRequest,
};

enum class MoonlightPointerButton : std::uint8_t {
    Left = 1,
    Middle = 2,
    Right = 3,
    X1 = 4,
    X2 = 5,
};

enum class MoonlightPointerMapStatus : std::uint8_t {
    Mapped = 0,
    OutsideContent,
    InvalidRequest,
};

enum class MoonlightPointerStatus : std::uint8_t {
    Applied = 0,
    AppliedLocally,
    AlreadyApplied,
    OutsideContent,
    InvalidRequest,
    InvalidState,
    StaleOwner,
    StaleEvent,
    StaleGeometry,
    Duplicate,
    NotPressed,
    ButtonCapacity,
    OutOfRange,
    SourceCapacity,
    Backpressure,
    PortUnsupported,
    PortFailure,
    Pending,
};

struct REMOTEDESK_MOONLIGHT_POINTER_HIDDEN MoonlightPointerModeRequest final {
    MoonlightPointerMode mode = MoonlightPointerMode::Absolute;
    std::uint8_t requestedCapabilities = 0U;
    std::uint8_t requiredCapabilities = 0U;
    bool allowFallback = true;
};

struct REMOTEDESK_MOONLIGHT_POINTER_HIDDEN MoonlightPointerModeResolution final {
    MoonlightPointerModeStatus status = MoonlightPointerModeStatus::InvalidRequest;
    MoonlightPointerMode mode = MoonlightPointerMode::Absolute;
    std::uint8_t enabledCapabilities = 0U;
    std::uint8_t missingCapabilities = 0U;
};

struct REMOTEDESK_MOONLIGHT_POINTER_HIDDEN MoonlightPointerEventContext final {
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

// pointX/pointY and this rectangle are all physical surface pixels. The
// rectangle may extend outside the surface for fill, one-to-one, zoom, or pan.
// referenceWidth/referenceHeight are the unrotated remote plane accepted by
// LiSendMousePositionEvent() and must fit its signed-short contract.
struct REMOTEDESK_MOONLIGHT_POINTER_HIDDEN MoonlightPointerContentRect final {
    double left = 0.0;
    double top = 0.0;
    double width = 0.0;
    double height = 0.0;
    std::uint16_t referenceWidth = 0U;
    std::uint16_t referenceHeight = 0U;
    std::uint8_t clockwiseQuarterTurns = 0U;
    std::uint64_t geometryGeneration = 0U;
};

struct REMOTEDESK_MOONLIGHT_POINTER_HIDDEN MoonlightAbsolutePointerMapping final {
    MoonlightPointerMapStatus status = MoonlightPointerMapStatus::InvalidRequest;
    std::int16_t x = 0;
    std::int16_t y = 0;
    std::uint16_t referenceWidth = 0U;
    std::uint16_t referenceHeight = 0U;
};

// Shared physical-content transform used by absolute pointer and direct-touch
// mapping. Coordinates are normalized to the unrotated video plane accepted by
// LiSendTouchEvent(); black bars remain OutsideContent and are never clamped.
struct REMOTEDESK_MOONLIGHT_POINTER_HIDDEN MoonlightNormalizedPointerMapping final {
    MoonlightPointerMapStatus status = MoonlightPointerMapStatus::InvalidRequest;
    double x = 0.0;
    double y = 0.0;
};

struct REMOTEDESK_MOONLIGHT_POINTER_HIDDEN MoonlightRelativePointerWireCommand final {
    std::int16_t deltaX = 0;
    std::int16_t deltaY = 0;
};

struct REMOTEDESK_MOONLIGHT_POINTER_HIDDEN MoonlightAbsolutePointerWireCommand final {
    std::int16_t x = 0;
    std::int16_t y = 0;
    std::uint16_t referenceWidth = 0U;
    std::uint16_t referenceHeight = 0U;
};

struct REMOTEDESK_MOONLIGHT_POINTER_HIDDEN MoonlightPointerButtonWireCommand final {
    std::uint8_t action = 0U;
    MoonlightPointerButton button = MoonlightPointerButton::Left;
};

struct REMOTEDESK_MOONLIGHT_POINTER_HIDDEN MoonlightPointerScrollWireCommand final {
    bool horizontal = false;
    std::int16_t amount = 0;
};

struct REMOTEDESK_MOONLIGHT_POINTER_HIDDEN MoonlightPointerLimits final {
    std::size_t maximumPressedButtons = kMoonlightMaximumPointerButtons;
    double relativeSensitivity = 1.0;
};

struct REMOTEDESK_MOONLIGHT_POINTER_HIDDEN MoonlightPointerResult final {
    MoonlightPointerStatus status = MoonlightPointerStatus::InvalidRequest;
    MoonlightInputDispatchStatus dispatchStatus = MoonlightInputDispatchStatus::InvalidRequest;
    std::size_t acceptedCommands = 0U;
    std::size_t pendingCommands = 0U;
};

struct REMOTEDESK_MOONLIGHT_POINTER_HIDDEN MoonlightPointerSnapshot final {
    bool matched = false;
    MoonlightInputIdentity identity{};
    std::size_t pressedButtons = 0U;
    double residualX = 0.0;
    double residualY = 0.0;
    std::uint64_t geometryGeneration = 0U;
    bool pending = false;
    std::size_t pendingCommands = 0U;
    std::size_t acceptedPendingCommands = 0U;
    std::uint64_t appliedTransactions = 0U;
    std::uint64_t localOnlyUpdates = 0U;
    std::uint64_t outsideContentEvents = 0U;
    std::uint64_t partialTransactions = 0U;
    std::uint64_t invalidRequests = 0U;
    std::uint64_t staleGeometryEvents = 0U;
    std::uint64_t duplicateEvents = 0U;
};

REMOTEDESK_MOONLIGHT_POINTER_HIDDEN MoonlightPointerModeResolution
resolveMoonlightPointerMode(const MoonlightPointerModeRequest& request,
                            std::uint8_t availableCapabilities) noexcept;

REMOTEDESK_MOONLIGHT_POINTER_HIDDEN MoonlightAbsolutePointerMapping
mapMoonlightAbsolutePointer(const MoonlightPointerContentRect& content,
                            double pointX,
                            double pointY) noexcept;
REMOTEDESK_MOONLIGHT_POINTER_HIDDEN MoonlightNormalizedPointerMapping
mapMoonlightNormalizedPointer(const MoonlightPointerContentRect& content,
                              double pointX,
                              double pointY) noexcept;

REMOTEDESK_MOONLIGHT_POINTER_HIDDEN bool decodeMoonlightRelativePointerCommand(
    const MoonlightInputEvent& event,
    MoonlightRelativePointerWireCommand& command) noexcept;
REMOTEDESK_MOONLIGHT_POINTER_HIDDEN bool decodeMoonlightAbsolutePointerCommand(
    const MoonlightInputEvent& event,
    MoonlightAbsolutePointerWireCommand& command) noexcept;
REMOTEDESK_MOONLIGHT_POINTER_HIDDEN bool decodeMoonlightPointerButtonCommand(
    const MoonlightInputEvent& event,
    MoonlightPointerButtonWireCommand& command) noexcept;
REMOTEDESK_MOONLIGHT_POINTER_HIDDEN bool decodeMoonlightPointerScrollCommand(
    const MoonlightInputEvent& event,
    MoonlightPointerScrollWireCommand& command) noexcept;

class REMOTEDESK_MOONLIGHT_POINTER_HIDDEN MoonlightPointerMapper final {
  private:
    struct Impl;
    explicit MoonlightPointerMapper(std::unique_ptr<Impl> impl) noexcept;

  public:
    ~MoonlightPointerMapper();
    MoonlightPointerMapper(const MoonlightPointerMapper&) = delete;
    MoonlightPointerMapper& operator=(const MoonlightPointerMapper&) = delete;

    static std::shared_ptr<MoonlightPointerMapper> create(
        std::shared_ptr<MoonlightInputBridge> bridge,
        const MoonlightInputIdentity& identity,
        MoonlightPointerLimits limits = {}) noexcept;

    MoonlightPointerResult relativeMotion(const MoonlightPointerEventContext& context,
                                           double deltaX,
                                           double deltaY) noexcept;
    MoonlightPointerResult absolutePosition(
        const MoonlightPointerEventContext& context,
        const MoonlightPointerContentRect& content,
        double pointX,
        double pointY) noexcept;
    // Relative-mode buttons do not depend on a surface position.
    MoonlightPointerResult button(const MoonlightPointerEventContext& context,
                                   MoonlightPointerButton button,
                                   bool pressed) noexcept;
    // Absolute-mode callers must use this operation so cursor positioning and
    // button state form one ordered transaction. Presses outside the content
    // rectangle are suppressed; releases remain deliverable to prevent a
    // remotely stuck button after the pointer leaves the video.
    MoonlightPointerResult absoluteButton(
        const MoonlightPointerEventContext& context,
        const MoonlightPointerContentRect& content,
        double pointX,
        double pointY,
        MoonlightPointerButton button,
        bool pressed) noexcept;
    MoonlightPointerResult scroll(const MoonlightPointerEventContext& context,
                                   bool horizontal,
                                   std::int32_t highResolutionAmount) noexcept;
    // Atomic synthetic click used by touchpad gesture recognition. State is
    // committed after each accepted command so a retry sends only the suffix.
    MoonlightPointerResult click(const MoonlightPointerEventContext& context,
                                  MoonlightPointerButton button) noexcept;
    // Emits horizontal then vertical high-resolution wheel commands in one
    // bounded transaction. Zero axes are omitted.
    MoonlightPointerResult scroll2D(const MoonlightPointerEventContext& context,
                                     std::int32_t horizontalAmount,
                                     std::int32_t verticalAmount) noexcept;
    MoonlightPointerResult releaseAll(const MoonlightPointerEventContext& context) noexcept;

    MoonlightPointerResult resumePending() noexcept;
    bool cancelPendingIfUnsent(const MoonlightInputIdentity& identity) noexcept;
    bool discardLocalState(const MoonlightInputIdentity& identity) noexcept;
    MoonlightPointerSnapshot snapshot(const MoonlightInputIdentity& identity) const noexcept;

  private:
    std::unique_ptr<Impl> impl_;
};

} // namespace remotedesk::moonlight

#undef REMOTEDESK_MOONLIGHT_POINTER_HIDDEN

#endif // REMOTEDESK_MOONLIGHT_POINTER_MAPPER_H
