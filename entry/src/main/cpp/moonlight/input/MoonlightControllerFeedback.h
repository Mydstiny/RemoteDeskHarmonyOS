#ifndef REMOTEDESK_MOONLIGHT_CONTROLLER_FEEDBACK_H
#define REMOTEDESK_MOONLIGHT_CONTROLLER_FEEDBACK_H

#include "moonlight/input/MoonlightControllerMapper.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>

#if defined(__GNUC__) || defined(__clang__)
#define REMOTEDESK_MOONLIGHT_FEEDBACK_HIDDEN __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_FEEDBACK_HIDDEN
#endif

namespace remotedesk::moonlight {

// Exact LI_CCAP_* values from the pinned moonlight-common-c revision. Analog
// triggers remain owned by N3-05; touchpads are not feedback capabilities.
constexpr std::uint16_t kMoonlightControllerCapabilityRumble = 0x0002U;
constexpr std::uint16_t kMoonlightControllerCapabilityTriggerRumble = 0x0004U;
constexpr std::uint16_t kMoonlightControllerCapabilityAccelerometer = 0x0010U;
constexpr std::uint16_t kMoonlightControllerCapabilityGyroscope = 0x0020U;
constexpr std::uint16_t kMoonlightControllerCapabilityBattery = 0x0040U;
constexpr std::uint16_t kMoonlightControllerCapabilityRgbLed = 0x0080U;
constexpr std::uint16_t kMoonlightControllerFeedbackCapabilityMask =
    kMoonlightControllerCapabilityRumble |
    kMoonlightControllerCapabilityTriggerRumble |
    kMoonlightControllerCapabilityAccelerometer |
    kMoonlightControllerCapabilityGyroscope |
    kMoonlightControllerCapabilityBattery |
    kMoonlightControllerCapabilityRgbLed;

constexpr std::size_t kMoonlightAdaptiveTriggerPayloadBytes = 10U;
constexpr std::uint8_t kMoonlightAdaptiveTriggerRight = 0x04U;
constexpr std::uint8_t kMoonlightAdaptiveTriggerLeft = 0x08U;
constexpr std::uint16_t kMoonlightMaximumMotionReportRateHz = 200U;
constexpr std::uint64_t kMoonlightBatteryRefreshIntervalUs = 120000000U;

enum class MoonlightControllerFeedbackKind : std::uint8_t {
    Invalid = 0,
    Rumble,
    TriggerRumble,
    RgbLed,
    AdaptiveTriggers,
    MotionReport,
    MotionSample,
    Battery,
};

enum class MoonlightControllerMotionType : std::uint8_t {
    Accelerometer = 1,
    Gyroscope = 2,
};

enum class MoonlightControllerBatteryState : std::uint8_t {
    Unknown = 0,
    NotPresent = 1,
    Discharging = 2,
    Charging = 3,
    NotCharging = 4,
    Full = 5,
};

enum class MoonlightControllerFeedbackState : std::uint8_t {
    Idle = 0,
    Active,
    Suspended,
    ReleasePending,
    Cleaned,
};

enum class MoonlightControllerFeedbackPortStatus : std::uint8_t {
    Accepted = 0,
    Backpressure,
    Unsupported,
    Failed,
};

enum class MoonlightControllerFeedbackStatus : std::uint8_t {
    Applied = 0,
    AppliedLocally,
    AlreadyApplied,
    Unsupported,
    RateLimited,
    InvalidRequest,
    InvalidState,
    StaleOwner,
    StaleDevice,
    StaleOperation,
    Backpressure,
    PortFailure,
};

// A capability can be advertised only when both an official platform API and
// the exact physical device have independent evidence. Generation zero is an
// unproven receipt. Adaptive triggers have no LI_CCAP bit and are tracked
// separately to prevent accidental advertisement.
struct REMOTEDESK_MOONLIGHT_FEEDBACK_HIDDEN
MoonlightControllerFeedbackEvidence final {
    std::uint16_t officialApiMask = 0U;
    std::uint16_t physicalDeviceMask = 0U;
    bool adaptiveTriggersOfficialApi = false;
    bool adaptiveTriggersPhysicalDevice = false;
    std::uint64_t platformGeneration = 0U;
    std::uint64_t deviceGeneration = 0U;

    constexpr std::uint16_t enabledMask() const noexcept {
        return static_cast<std::uint16_t>(officialApiMask & physicalDeviceMask);
    }
    constexpr bool adaptiveTriggersEnabled() const noexcept {
        return adaptiveTriggersOfficialApi && adaptiveTriggersPhysicalDevice;
    }
};

// API 23 GameControllerKit currently exposes only enumeration and input
// monitors. This product receipt must remain all-zero until an official output
// or telemetry API and real-device evidence are both available.
REMOTEDESK_MOONLIGHT_FEEDBACK_HIDDEN
MoonlightControllerFeedbackEvidence moonlightApi23ControllerFeedbackEvidence() noexcept;

struct REMOTEDESK_MOONLIGHT_FEEDBACK_HIDDEN
MoonlightControllerFeedbackContext final {
    MoonlightInputIdentity identity{};
    std::uint8_t controllerNumber = 0U;
    std::uint64_t deviceId = 0U;
    std::uint64_t deviceGeneration = 0U;
    std::uint64_t operationGeneration = 0U;
    std::uint64_t monotonicTimestampUs = 0U;

    constexpr bool valid() const noexcept {
        return identity.valid() &&
            controllerNumber < kMoonlightMaximumPhysicalControllerSlots &&
            deviceId != 0U && deviceGeneration != 0U &&
            operationGeneration != 0U && monotonicTimestampUs != 0U;
    }
};

struct REMOTEDESK_MOONLIGHT_FEEDBACK_HIDDEN
MoonlightControllerFeedbackCommand final {
    MoonlightControllerFeedbackKind kind = MoonlightControllerFeedbackKind::Invalid;
    std::uint16_t firstMotor = 0U;
    std::uint16_t secondMotor = 0U;
    std::uint8_t red = 0U;
    std::uint8_t green = 0U;
    std::uint8_t blue = 0U;
    std::uint8_t adaptiveEventFlags = 0U;
    std::uint8_t adaptiveLeftType = 0U;
    std::uint8_t adaptiveRightType = 0U;
    std::array<std::uint8_t, kMoonlightAdaptiveTriggerPayloadBytes> adaptiveLeft{};
    std::array<std::uint8_t, kMoonlightAdaptiveTriggerPayloadBytes> adaptiveRight{};
    MoonlightControllerMotionType motionType =
        MoonlightControllerMotionType::Accelerometer;
    std::uint16_t motionReportRateHz = 0U;
    float motionX = 0.0F;
    float motionY = 0.0F;
    float motionZ = 0.0F;
    MoonlightControllerBatteryState batteryState =
        MoonlightControllerBatteryState::Unknown;
    std::uint8_t batteryPercentage = 0xFFU;
};

REMOTEDESK_MOONLIGHT_FEEDBACK_HIDDEN MoonlightControllerFeedbackCommand
makeMoonlightRumbleCommand(std::uint16_t lowFrequency,
                           std::uint16_t highFrequency) noexcept;
REMOTEDESK_MOONLIGHT_FEEDBACK_HIDDEN MoonlightControllerFeedbackCommand
makeMoonlightTriggerRumbleCommand(std::uint16_t leftTrigger,
                                  std::uint16_t rightTrigger) noexcept;
REMOTEDESK_MOONLIGHT_FEEDBACK_HIDDEN MoonlightControllerFeedbackCommand
makeMoonlightRgbLedCommand(std::uint8_t red, std::uint8_t green,
                           std::uint8_t blue) noexcept;
REMOTEDESK_MOONLIGHT_FEEDBACK_HIDDEN MoonlightControllerFeedbackCommand
makeMoonlightAdaptiveTriggerCommand(
    std::uint8_t eventFlags, std::uint8_t leftType, std::uint8_t rightType,
    const std::array<std::uint8_t, kMoonlightAdaptiveTriggerPayloadBytes>& left,
    const std::array<std::uint8_t, kMoonlightAdaptiveTriggerPayloadBytes>& right) noexcept;
REMOTEDESK_MOONLIGHT_FEEDBACK_HIDDEN MoonlightControllerFeedbackCommand
makeMoonlightMotionReportCommand(MoonlightControllerMotionType type,
                                 std::uint16_t reportRateHz) noexcept;
REMOTEDESK_MOONLIGHT_FEEDBACK_HIDDEN MoonlightControllerFeedbackCommand
makeMoonlightMotionSampleCommand(MoonlightControllerMotionType type,
                                 float x, float y, float z) noexcept;
REMOTEDESK_MOONLIGHT_FEEDBACK_HIDDEN MoonlightControllerFeedbackCommand
makeMoonlightBatteryCommand(MoonlightControllerBatteryState state,
                            std::uint8_t percentage) noexcept;

class REMOTEDESK_MOONLIGHT_FEEDBACK_HIDDEN MoonlightControllerFeedbackPort {
  public:
    virtual ~MoonlightControllerFeedbackPort() = default;
    virtual MoonlightControllerFeedbackPortStatus submit(
        const MoonlightControllerFeedbackContext& context,
        const MoonlightControllerFeedbackCommand& command) noexcept = 0;
    // Releases local haptics, sensor registrations, LED ownership and adaptive
    // effects. It must not send remote input and is safe during owner teardown.
    virtual MoonlightControllerFeedbackPortStatus releaseDevice(
        const MoonlightControllerFeedbackContext& context) noexcept = 0;
};

struct REMOTEDESK_MOONLIGHT_FEEDBACK_HIDDEN
MoonlightControllerFeedbackLimits final {
    std::uint16_t maximumMotionReportRateHz =
        kMoonlightMaximumMotionReportRateHz;
    std::uint64_t batteryRefreshIntervalUs =
        kMoonlightBatteryRefreshIntervalUs;
    float maximumAccelerationMagnitude = 200.0F;
    float maximumGyroscopeMagnitude = 4000.0F;
};

struct REMOTEDESK_MOONLIGHT_FEEDBACK_HIDDEN
MoonlightControllerFeedbackResult final {
    MoonlightControllerFeedbackStatus status =
        MoonlightControllerFeedbackStatus::InvalidRequest;
    MoonlightControllerFeedbackPortStatus portStatus =
        MoonlightControllerFeedbackPortStatus::Failed;
    bool adjusted = false;
};

struct REMOTEDESK_MOONLIGHT_FEEDBACK_HIDDEN
MoonlightControllerFeedbackSnapshot final {
    bool matched = false;
    MoonlightInputIdentity identity{};
    MoonlightControllerFeedbackState state =
        MoonlightControllerFeedbackState::Idle;
    std::uint8_t controllerNumber = 0U;
    std::uint64_t deviceId = 0U;
    std::uint64_t deviceGeneration = 0U;
    std::uint16_t advertisedCapabilityMask = 0U;
    bool adaptiveTriggersEnabled = false;
    std::uint16_t accelerometerReportRateHz = 0U;
    std::uint16_t gyroscopeReportRateHz = 0U;
    std::uint64_t lastOperationGeneration = 0U;
    std::uint64_t acceptedOperations = 0U;
    std::uint64_t localOnlyOperations = 0U;
    std::uint64_t unsupportedOperations = 0U;
    std::uint64_t rateLimitedOperations = 0U;
    std::uint64_t backpressureOperations = 0U;
    std::uint64_t portFailures = 0U;
    std::uint64_t releases = 0U;
    bool releaseRequired = false;
    bool commandPending = false;
};

class REMOTEDESK_MOONLIGHT_FEEDBACK_HIDDEN
MoonlightControllerFeedback final {
  private:
    struct Impl;
    explicit MoonlightControllerFeedback(std::unique_ptr<Impl> impl) noexcept;

  public:
    ~MoonlightControllerFeedback();
    MoonlightControllerFeedback(const MoonlightControllerFeedback&) = delete;
    MoonlightControllerFeedback& operator=(const MoonlightControllerFeedback&) = delete;

    static std::shared_ptr<MoonlightControllerFeedback> create(
        std::shared_ptr<MoonlightInputOwnerGate> ownerGate,
        std::shared_ptr<MoonlightControllerFeedbackPort> port,
        MoonlightControllerFeedbackLimits limits = {}) noexcept;

    MoonlightControllerFeedbackResult bind(
        const MoonlightControllerFeedbackContext& context,
        const MoonlightControllerFeedbackEvidence& evidence) noexcept;
    MoonlightControllerFeedbackResult dispatch(
        const MoonlightControllerFeedbackContext& context,
        const MoonlightControllerFeedbackCommand& command) noexcept;
    MoonlightControllerFeedbackResult suspend(
        const MoonlightControllerFeedbackContext& context) noexcept;
    MoonlightControllerFeedbackResult resume(
        const MoonlightControllerFeedbackContext& context) noexcept;
    MoonlightControllerFeedbackResult unbind(
        const MoonlightControllerFeedbackContext& context) noexcept;
    MoonlightControllerFeedbackResult cleanup(
        const MoonlightControllerFeedbackContext& context) noexcept;

    MoonlightControllerFeedbackSnapshot snapshot(
        const MoonlightInputIdentity& identity) const noexcept;

  private:
    std::unique_ptr<Impl> impl_;
};

} // namespace remotedesk::moonlight

#undef REMOTEDESK_MOONLIGHT_FEEDBACK_HIDDEN

#endif // REMOTEDESK_MOONLIGHT_CONTROLLER_FEEDBACK_H
