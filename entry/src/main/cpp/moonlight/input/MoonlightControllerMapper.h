#ifndef REMOTEDESK_MOONLIGHT_CONTROLLER_MAPPER_H
#define REMOTEDESK_MOONLIGHT_CONTROLLER_MAPPER_H

#include "moonlight/input/MoonlightInputBridge.h"

#include <cstddef>
#include <cstdint>
#include <memory>

#if defined(__GNUC__) || defined(__clang__)
#define REMOTEDESK_MOONLIGHT_CONTROLLER_HIDDEN __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_CONTROLLER_HIDDEN
#endif

namespace remotedesk::moonlight {

// Official moonlight-common-c controller flags. Keeping the values here makes
// the project-owned command body a direct argument projection for
// LiSendMultiControllerEvent()/LiSendControllerArrivalEvent().
constexpr std::uint32_t kMoonlightControllerButtonUp = 0x0001U;
constexpr std::uint32_t kMoonlightControllerButtonDown = 0x0002U;
constexpr std::uint32_t kMoonlightControllerButtonLeft = 0x0004U;
constexpr std::uint32_t kMoonlightControllerButtonRight = 0x0008U;
constexpr std::uint32_t kMoonlightControllerButtonPlay = 0x0010U;
constexpr std::uint32_t kMoonlightControllerButtonBack = 0x0020U;
constexpr std::uint32_t kMoonlightControllerButtonLeftStick = 0x0040U;
constexpr std::uint32_t kMoonlightControllerButtonRightStick = 0x0080U;
constexpr std::uint32_t kMoonlightControllerButtonLeftShoulder = 0x0100U;
constexpr std::uint32_t kMoonlightControllerButtonRightShoulder = 0x0200U;
constexpr std::uint32_t kMoonlightControllerButtonSpecial = 0x0400U;
constexpr std::uint32_t kMoonlightControllerButtonA = 0x1000U;
constexpr std::uint32_t kMoonlightControllerButtonB = 0x2000U;
constexpr std::uint32_t kMoonlightControllerButtonX = 0x4000U;
constexpr std::uint32_t kMoonlightControllerButtonY = 0x8000U;

constexpr std::uint32_t kMoonlightControllerDpadMask =
    kMoonlightControllerButtonUp | kMoonlightControllerButtonDown |
    kMoonlightControllerButtonLeft | kMoonlightControllerButtonRight;
constexpr std::uint32_t kMoonlightControllerStandardButtonMask =
    kMoonlightControllerDpadMask | kMoonlightControllerButtonPlay |
    kMoonlightControllerButtonBack | kMoonlightControllerButtonLeftStick |
    kMoonlightControllerButtonRightStick |
    kMoonlightControllerButtonLeftShoulder |
    kMoonlightControllerButtonRightShoulder |
    kMoonlightControllerButtonSpecial | kMoonlightControllerButtonA |
    kMoonlightControllerButtonB | kMoonlightControllerButtonX |
    kMoonlightControllerButtonY;

// API 23 exposes Menu and Home but no separately named Select/Back capability.
// Home is forwarded as the standard Guide/Special button; HarmonyOS system
// navigation remains available independently of the game-controller stream.
constexpr std::uint32_t kMoonlightControllerApi23ButtonMask =
    kMoonlightControllerDpadMask | kMoonlightControllerButtonPlay |
    kMoonlightControllerButtonSpecial |
    kMoonlightControllerButtonLeftStick |
    kMoonlightControllerButtonRightStick |
    kMoonlightControllerButtonLeftShoulder |
    kMoonlightControllerButtonRightShoulder | kMoonlightControllerButtonA |
    kMoonlightControllerButtonB | kMoonlightControllerButtonX |
    kMoonlightControllerButtonY;

constexpr std::size_t kMoonlightControllerCommandBytes = 28U;
constexpr std::size_t kMoonlightMaximumPhysicalControllerSlots = 1U;
constexpr std::uint32_t kMoonlightProductControllerBitmap = 0x00000001U;
constexpr bool kMoonlightProductPersistGamepad = true;
constexpr std::size_t kMoonlightMaximumObservedControllerLanes = 8U;
constexpr double kMoonlightDefaultControllerStickDeadzone = 0.07;
constexpr double kMoonlightDefaultControllerTriggerDeadzone = 0.13;

enum class MoonlightControllerCommandOperation : std::uint8_t {
    Arrival = 1,
    State = 2,
};

// Values match LI_CTYPE_* in the pinned moonlight-common-c revision.
enum class MoonlightControllerType : std::uint8_t {
    Unknown = 0,
    Xbox = 1,
    PlayStation = 2,
    Nintendo = 3,
};

constexpr std::uint16_t kMoonlightControllerCapabilityAnalogTriggers = 0x0001U;

enum class MoonlightControllerStatus : std::uint8_t {
    Applied = 0,
    AppliedLocally,
    AlreadyApplied,
    InvalidRequest,
    InvalidState,
    StaleOwner,
    StaleEvent,
    Duplicate,
    NotActive,
    SlotCapacity,
    FlushRequired,
    SourceCapacity,
    Backpressure,
    PortUnsupported,
    PortFailure,
};

struct REMOTEDESK_MOONLIGHT_CONTROLLER_HIDDEN MoonlightControllerEventContext final {
    MoonlightInputIdentity identity{};
    std::uint64_t deviceId = 0U;
    MoonlightInputSource source = MoonlightInputSource::Invalid;
    std::uint64_t sourceGeneration = 0U;
    std::uint64_t sourceSequence = 0U;
    std::uint64_t monotonicTimestampUs = 0U;

    constexpr bool valid() const noexcept {
        return identity.valid() && deviceId != 0U &&
            (source == MoonlightInputSource::GameController ||
             source == MoonlightInputSource::VirtualController) &&
            sourceGeneration != 0U && sourceSequence != 0U &&
            monotonicTimestampUs != 0U;
    }
};

struct REMOTEDESK_MOONLIGHT_CONTROLLER_HIDDEN MoonlightControllerProfile final {
    MoonlightControllerType type = MoonlightControllerType::Unknown;
    // Populated only from the current device enumeration. Zero is the
    // fail-closed/default value and cannot be connected.
    std::uint32_t supportedButtonFlags = 0U;
    bool analogTriggers = false;
};

// Values use the API 23 input coordinate convention: sticks and hat are in
// [-1, 1], with positive Y pointing down; triggers are in [0, 1]. The mapper
// performs the common-c/XInput Y inversion and fixed-width conversion.
struct REMOTEDESK_MOONLIGHT_CONTROLLER_HIDDEN MoonlightControllerSample final {
    std::uint32_t buttonFlags = 0U;
    double leftStickX = 0.0;
    double leftStickY = 0.0;
    double rightStickX = 0.0;
    double rightStickY = 0.0;
    double leftTrigger = 0.0;
    double rightTrigger = 0.0;
    bool hasHatAxes = false;
    double hatX = 0.0;
    double hatY = 0.0;
};

struct REMOTEDESK_MOONLIGHT_CONTROLLER_HIDDEN MoonlightControllerMappedState final {
    std::uint32_t buttonFlags = 0U;
    std::uint8_t leftTrigger = 0U;
    std::uint8_t rightTrigger = 0U;
    std::int16_t leftStickX = 0;
    std::int16_t leftStickY = 0;
    std::int16_t rightStickX = 0;
    std::int16_t rightStickY = 0;
};

struct REMOTEDESK_MOONLIGHT_CONTROLLER_HIDDEN MoonlightControllerWireCommand final {
    MoonlightControllerCommandOperation operation =
        MoonlightControllerCommandOperation::State;
    std::uint8_t controllerNumber = 0U;
    std::uint16_t activeGamepadMask = 0U;
    MoonlightControllerMappedState state{};
    MoonlightControllerType type = MoonlightControllerType::Unknown;
    std::uint16_t capabilities = 0U;
    std::uint32_t supportedButtonFlags = 0U;
};

struct REMOTEDESK_MOONLIGHT_CONTROLLER_HIDDEN MoonlightControllerLimits final {
    // Header/link visibility is not a runtime device receipt. Product wiring
    // must leave this false until its signed-HAP capability probe succeeds.
    bool api23InputAvailable = false;
    double stickDeadzone = kMoonlightDefaultControllerStickDeadzone;
    double triggerDeadzone = kMoonlightDefaultControllerTriggerDeadzone;
};

struct REMOTEDESK_MOONLIGHT_CONTROLLER_HIDDEN MoonlightControllerResult final {
    MoonlightControllerStatus status = MoonlightControllerStatus::InvalidRequest;
    MoonlightInputDispatchStatus dispatchStatus =
        MoonlightInputDispatchStatus::InvalidRequest;
};

struct REMOTEDESK_MOONLIGHT_CONTROLLER_HIDDEN MoonlightControllerSnapshot final {
    bool matched = false;
    MoonlightInputIdentity identity{};
    bool active = false;
    std::uint8_t controllerNumber = 0U;
    std::uint64_t deviceId = 0U;
    MoonlightInputSource source = MoonlightInputSource::Invalid;
    std::uint64_t sourceGeneration = 0U;
    MoonlightControllerProfile profile{};
    MoonlightControllerMappedState state{};
    std::size_t observedLanes = 0U;
    std::uint64_t arrivals = 0U;
    std::uint64_t stateFrames = 0U;
    std::uint64_t neutralFrames = 0U;
    std::uint64_t removals = 0U;
    std::uint64_t localOnlyUpdates = 0U;
    std::uint64_t rejectedEvents = 0U;
};

REMOTEDESK_MOONLIGHT_CONTROLLER_HIDDEN bool mapMoonlightControllerSample(
    const MoonlightControllerSample& sample,
    const MoonlightControllerProfile& profile,
    const MoonlightControllerLimits& limits,
    MoonlightControllerMappedState& mapped) noexcept;

REMOTEDESK_MOONLIGHT_CONTROLLER_HIDDEN bool decodeMoonlightControllerCommand(
    const MoonlightInputEvent& event,
    MoonlightControllerWireCommand& command) noexcept;

class REMOTEDESK_MOONLIGHT_CONTROLLER_HIDDEN MoonlightControllerMapper final {
  private:
    struct Impl;
    explicit MoonlightControllerMapper(std::unique_ptr<Impl> impl) noexcept;

  public:
    ~MoonlightControllerMapper();
    MoonlightControllerMapper(const MoonlightControllerMapper&) = delete;
    MoonlightControllerMapper& operator=(const MoonlightControllerMapper&) = delete;

    static std::shared_ptr<MoonlightControllerMapper> create(
        std::shared_ptr<MoonlightInputBridge> bridge,
        const MoonlightInputIdentity& identity,
        MoonlightControllerLimits limits = {}) noexcept;

    MoonlightControllerResult connect(
        const MoonlightControllerEventContext& context,
        const MoonlightControllerProfile& profile) noexcept;
    MoonlightControllerResult update(
        const MoonlightControllerEventContext& context,
        const MoonlightControllerSample& sample) noexcept;
    // Sends an all-neutral frame while retaining the stable slot. This is the
    // primitive used for background/overlay safety; N3-07 owns global ordering.
    MoonlightControllerResult neutralize(
        const MoonlightControllerEventContext& context) noexcept;
    // Sends a neutral removal frame (active mask cleared) and releases slot 0
    // only after the bridge accepts it.
    MoonlightControllerResult disconnect(
        const MoonlightControllerEventContext& context) noexcept;
    bool discardLocalState(const MoonlightInputIdentity& identity) noexcept;

    MoonlightControllerSnapshot snapshot(
        const MoonlightInputIdentity& identity) const noexcept;

  private:
    std::unique_ptr<Impl> impl_;
};

} // namespace remotedesk::moonlight

#undef REMOTEDESK_MOONLIGHT_CONTROLLER_HIDDEN

#endif // REMOTEDESK_MOONLIGHT_CONTROLLER_MAPPER_H
