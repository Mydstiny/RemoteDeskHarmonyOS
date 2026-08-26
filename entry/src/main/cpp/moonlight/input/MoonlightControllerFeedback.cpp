#include "moonlight/input/MoonlightControllerFeedback.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <mutex>
#include <new>
#include <optional>
#include <utility>

namespace remotedesk::moonlight {
namespace {

enum class LifecycleTarget : std::uint8_t {
    None = 0,
    Suspended,
    Idle,
    Cleaned,
};

std::uint64_t saturatingIncrement(std::uint64_t value) noexcept {
    return value == std::numeric_limits<std::uint64_t>::max() ? value : value + 1U;
}

bool knownMotionType(MoonlightControllerMotionType type) noexcept {
    return type == MoonlightControllerMotionType::Accelerometer ||
        type == MoonlightControllerMotionType::Gyroscope;
}

bool knownBatteryState(MoonlightControllerBatteryState state) noexcept {
    switch (state) {
        case MoonlightControllerBatteryState::Unknown:
        case MoonlightControllerBatteryState::NotPresent:
        case MoonlightControllerBatteryState::Discharging:
        case MoonlightControllerBatteryState::Charging:
        case MoonlightControllerBatteryState::NotCharging:
        case MoonlightControllerBatteryState::Full:
            return true;
    }
    return false;
}

bool sameContext(const MoonlightControllerFeedbackContext& left,
                 const MoonlightControllerFeedbackContext& right) noexcept {
    return left.identity == right.identity &&
        left.controllerNumber == right.controllerNumber &&
        left.deviceId == right.deviceId &&
        left.deviceGeneration == right.deviceGeneration &&
        left.operationGeneration == right.operationGeneration &&
        left.monotonicTimestampUs == right.monotonicTimestampUs;
}

bool sameCommand(const MoonlightControllerFeedbackCommand& left,
                 const MoonlightControllerFeedbackCommand& right) noexcept {
    return left.kind == right.kind && left.firstMotor == right.firstMotor &&
        left.secondMotor == right.secondMotor && left.red == right.red &&
        left.green == right.green && left.blue == right.blue &&
        left.adaptiveEventFlags == right.adaptiveEventFlags &&
        left.adaptiveLeftType == right.adaptiveLeftType &&
        left.adaptiveRightType == right.adaptiveRightType &&
        left.adaptiveLeft == right.adaptiveLeft &&
        left.adaptiveRight == right.adaptiveRight &&
        left.motionType == right.motionType &&
        left.motionReportRateHz == right.motionReportRateHz &&
        left.motionX == right.motionX && left.motionY == right.motionY &&
        left.motionZ == right.motionZ &&
        left.batteryState == right.batteryState &&
        left.batteryPercentage == right.batteryPercentage;
}

bool validEvidence(const MoonlightControllerFeedbackEvidence& evidence) noexcept {
    if ((evidence.officialApiMask & ~kMoonlightControllerFeedbackCapabilityMask) != 0U ||
        (evidence.physicalDeviceMask & ~kMoonlightControllerFeedbackCapabilityMask) != 0U ||
        (evidence.physicalDeviceMask & ~evidence.officialApiMask) != 0U ||
        (evidence.adaptiveTriggersPhysicalDevice &&
         !evidence.adaptiveTriggersOfficialApi)) {
        return false;
    }
    const bool hasPlatformClaim = evidence.officialApiMask != 0U ||
        evidence.adaptiveTriggersOfficialApi;
    const bool hasDeviceClaim = evidence.physicalDeviceMask != 0U ||
        evidence.adaptiveTriggersPhysicalDevice;
    return (!hasPlatformClaim || evidence.platformGeneration != 0U) &&
        (!hasDeviceClaim || evidence.deviceGeneration != 0U);
}

bool validLimits(const MoonlightControllerFeedbackLimits& limits) noexcept {
    return limits.maximumMotionReportRateHz > 0U &&
        limits.maximumMotionReportRateHz <= 1000U &&
        limits.batteryRefreshIntervalUs >= 1000000U &&
        limits.batteryRefreshIntervalUs <= 3600000000U &&
        std::isfinite(limits.maximumAccelerationMagnitude) &&
        std::isfinite(limits.maximumGyroscopeMagnitude) &&
        limits.maximumAccelerationMagnitude > 0.0F &&
        limits.maximumAccelerationMagnitude <= 1000.0F &&
        limits.maximumGyroscopeMagnitude > 0.0F &&
        limits.maximumGyroscopeMagnitude <= 10000.0F;
}

std::uint16_t capabilityFor(const MoonlightControllerFeedbackCommand& command) noexcept {
    switch (command.kind) {
        case MoonlightControllerFeedbackKind::Rumble:
            return kMoonlightControllerCapabilityRumble;
        case MoonlightControllerFeedbackKind::TriggerRumble:
            return kMoonlightControllerCapabilityTriggerRumble;
        case MoonlightControllerFeedbackKind::RgbLed:
            return kMoonlightControllerCapabilityRgbLed;
        case MoonlightControllerFeedbackKind::MotionReport:
        case MoonlightControllerFeedbackKind::MotionSample:
            return command.motionType == MoonlightControllerMotionType::Accelerometer
                ? kMoonlightControllerCapabilityAccelerometer
                : kMoonlightControllerCapabilityGyroscope;
        case MoonlightControllerFeedbackKind::Battery:
            return kMoonlightControllerCapabilityBattery;
        case MoonlightControllerFeedbackKind::AdaptiveTriggers:
        case MoonlightControllerFeedbackKind::Invalid:
            return 0U;
    }
    return 0U;
}

std::size_t motionIndex(MoonlightControllerMotionType type) noexcept {
    return type == MoonlightControllerMotionType::Accelerometer ? 0U : 1U;
}

class ProbeOperation final : public MoonlightInputOwnedOperation {
  public:
    void execute() noexcept override { executed = true; }
    bool executed = false;
};

class SubmitOperation final : public MoonlightInputOwnedOperation {
  public:
    SubmitOperation(MoonlightControllerFeedbackPort& valuePort,
                    const MoonlightControllerFeedbackContext& valueContext,
                    const MoonlightControllerFeedbackCommand& valueCommand) noexcept
        : port(valuePort), context(valueContext), command(valueCommand) {}

    void execute() noexcept override {
        if (executed) {
            return;
        }
        executed = true;
        status = port.submit(context, command);
    }

    MoonlightControllerFeedbackPort& port;
    const MoonlightControllerFeedbackContext& context;
    const MoonlightControllerFeedbackCommand& command;
    MoonlightControllerFeedbackPortStatus status =
        MoonlightControllerFeedbackPortStatus::Failed;
    bool executed = false;
};

MoonlightControllerFeedbackResult result(
    MoonlightControllerFeedbackStatus status,
    MoonlightControllerFeedbackPortStatus portStatus =
        MoonlightControllerFeedbackPortStatus::Failed,
    bool adjusted = false) noexcept {
    return {status, portStatus, adjusted};
}

} // namespace

MoonlightControllerFeedbackEvidence moonlightApi23ControllerFeedbackEvidence() noexcept {
    return {};
}

MoonlightControllerFeedbackCommand makeMoonlightRumbleCommand(
    std::uint16_t lowFrequency, std::uint16_t highFrequency) noexcept {
    MoonlightControllerFeedbackCommand command;
    command.kind = MoonlightControllerFeedbackKind::Rumble;
    command.firstMotor = lowFrequency;
    command.secondMotor = highFrequency;
    return command;
}

MoonlightControllerFeedbackCommand makeMoonlightTriggerRumbleCommand(
    std::uint16_t leftTrigger, std::uint16_t rightTrigger) noexcept {
    MoonlightControllerFeedbackCommand command;
    command.kind = MoonlightControllerFeedbackKind::TriggerRumble;
    command.firstMotor = leftTrigger;
    command.secondMotor = rightTrigger;
    return command;
}

MoonlightControllerFeedbackCommand makeMoonlightRgbLedCommand(
    std::uint8_t red, std::uint8_t green, std::uint8_t blue) noexcept {
    MoonlightControllerFeedbackCommand command;
    command.kind = MoonlightControllerFeedbackKind::RgbLed;
    command.red = red;
    command.green = green;
    command.blue = blue;
    return command;
}

MoonlightControllerFeedbackCommand makeMoonlightAdaptiveTriggerCommand(
    std::uint8_t eventFlags, std::uint8_t leftType, std::uint8_t rightType,
    const std::array<std::uint8_t, kMoonlightAdaptiveTriggerPayloadBytes>& left,
    const std::array<std::uint8_t, kMoonlightAdaptiveTriggerPayloadBytes>& right) noexcept {
    MoonlightControllerFeedbackCommand command;
    command.kind = MoonlightControllerFeedbackKind::AdaptiveTriggers;
    command.adaptiveEventFlags = eventFlags;
    command.adaptiveLeftType = leftType;
    command.adaptiveRightType = rightType;
    command.adaptiveLeft = left;
    command.adaptiveRight = right;
    return command;
}

MoonlightControllerFeedbackCommand makeMoonlightMotionReportCommand(
    MoonlightControllerMotionType type, std::uint16_t reportRateHz) noexcept {
    MoonlightControllerFeedbackCommand command;
    command.kind = MoonlightControllerFeedbackKind::MotionReport;
    command.motionType = type;
    command.motionReportRateHz = reportRateHz;
    return command;
}

MoonlightControllerFeedbackCommand makeMoonlightMotionSampleCommand(
    MoonlightControllerMotionType type, float x, float y, float z) noexcept {
    MoonlightControllerFeedbackCommand command;
    command.kind = MoonlightControllerFeedbackKind::MotionSample;
    command.motionType = type;
    command.motionX = x;
    command.motionY = y;
    command.motionZ = z;
    return command;
}

MoonlightControllerFeedbackCommand makeMoonlightBatteryCommand(
    MoonlightControllerBatteryState state, std::uint8_t percentage) noexcept {
    MoonlightControllerFeedbackCommand command;
    command.kind = MoonlightControllerFeedbackKind::Battery;
    command.batteryState = state;
    command.batteryPercentage = percentage;
    return command;
}

struct MoonlightControllerFeedback::Impl final {
    std::shared_ptr<MoonlightInputOwnerGate> ownerGate;
    std::shared_ptr<MoonlightControllerFeedbackPort> port;
    MoonlightControllerFeedbackLimits limits{};
    mutable std::mutex mutex;
    MoonlightControllerFeedbackSnapshot state{};
    std::optional<MoonlightControllerFeedbackCommand> lastCommand;
    std::optional<MoonlightControllerFeedbackContext> pendingContext;
    std::optional<MoonlightControllerFeedbackCommand> pendingCommand;
    LifecycleTarget pendingLifecycle = LifecycleTarget::None;
    std::optional<MoonlightControllerFeedbackContext> pendingLifecycleContext;
    std::array<std::uint64_t, 2U> lastMotionTimestampUs{};
    std::array<std::array<float, 3U>, 2U> lastMotion{};
    std::array<bool, 2U> hasMotion{};
    std::uint64_t lastBatteryTimestampUs = 0U;
    MoonlightControllerBatteryState lastBatteryState =
        MoonlightControllerBatteryState::Unknown;
    std::uint8_t lastBatteryPercentage = 0xFFU;
    bool hasBattery = false;
    bool rumbleActive = false;
    bool triggerRumbleActive = false;
    bool ledClaimed = false;
    bool adaptiveClaimed = false;

    bool ownerAvailable(const MoonlightInputIdentity& identity) noexcept {
        ProbeOperation operation;
        return ownerGate->withOwner(identity, operation) && operation.executed;
    }

    bool contextMatches(const MoonlightControllerFeedbackContext& context) const noexcept {
        return context.identity == state.identity &&
            context.controllerNumber == state.controllerNumber &&
            context.deviceId == state.deviceId &&
            context.deviceGeneration == state.deviceGeneration;
    }

    bool releaseRequired() const noexcept {
        return rumbleActive || triggerRumbleActive || ledClaimed || adaptiveClaimed ||
            state.accelerometerReportRateHz != 0U ||
            state.gyroscopeReportRateHz != 0U;
    }

    void refreshReleaseRequired() noexcept {
        state.releaseRequired = releaseRequired();
    }

    void clearEffects() noexcept {
        rumbleActive = false;
        triggerRumbleActive = false;
        ledClaimed = false;
        adaptiveClaimed = false;
        state.accelerometerReportRateHz = 0U;
        state.gyroscopeReportRateHz = 0U;
        hasMotion = {};
        lastMotionTimestampUs = {};
        refreshReleaseRequired();
    }

    void clearDevice() noexcept {
        clearEffects();
        state.controllerNumber = 0U;
        state.deviceId = 0U;
        state.deviceGeneration = 0U;
        state.advertisedCapabilityMask = 0U;
        state.adaptiveTriggersEnabled = false;
        hasBattery = false;
        lastBatteryTimestampUs = 0U;
        lastBatteryState = MoonlightControllerBatteryState::Unknown;
        lastBatteryPercentage = 0xFFU;
        pendingContext.reset();
        pendingCommand.reset();
        state.commandPending = false;
    }

    bool validCommand(const MoonlightControllerFeedbackCommand& command) const noexcept {
        switch (command.kind) {
            case MoonlightControllerFeedbackKind::Rumble:
                return sameCommand(command, makeMoonlightRumbleCommand(
                    command.firstMotor, command.secondMotor));
            case MoonlightControllerFeedbackKind::TriggerRumble:
                return sameCommand(command, makeMoonlightTriggerRumbleCommand(
                    command.firstMotor, command.secondMotor));
            case MoonlightControllerFeedbackKind::RgbLed:
                return sameCommand(command, makeMoonlightRgbLedCommand(
                    command.red, command.green, command.blue));
            case MoonlightControllerFeedbackKind::AdaptiveTriggers: {
                if ((command.adaptiveEventFlags &
                     ~(kMoonlightAdaptiveTriggerLeft |
                       kMoonlightAdaptiveTriggerRight)) != 0U) {
                    return false;
                }
                const std::array<std::uint8_t,
                                 kMoonlightAdaptiveTriggerPayloadBytes> empty{};
                if ((command.adaptiveEventFlags & kMoonlightAdaptiveTriggerLeft) == 0U &&
                    (command.adaptiveLeftType != 0U || command.adaptiveLeft != empty)) {
                    return false;
                }
                if ((command.adaptiveEventFlags & kMoonlightAdaptiveTriggerRight) == 0U &&
                    (command.adaptiveRightType != 0U || command.adaptiveRight != empty)) {
                    return false;
                }
                return sameCommand(command, makeMoonlightAdaptiveTriggerCommand(
                    command.adaptiveEventFlags, command.adaptiveLeftType,
                    command.adaptiveRightType, command.adaptiveLeft,
                    command.adaptiveRight));
            }
            case MoonlightControllerFeedbackKind::MotionReport:
                return knownMotionType(command.motionType) &&
                    sameCommand(command, makeMoonlightMotionReportCommand(
                        command.motionType, command.motionReportRateHz));
            case MoonlightControllerFeedbackKind::MotionSample: {
                if (!knownMotionType(command.motionType) ||
                    !std::isfinite(command.motionX) ||
                    !std::isfinite(command.motionY) ||
                    !std::isfinite(command.motionZ)) {
                    return false;
                }
                const float bound =
                    command.motionType == MoonlightControllerMotionType::Accelerometer
                    ? limits.maximumAccelerationMagnitude
                    : limits.maximumGyroscopeMagnitude;
                return std::fabs(command.motionX) <= bound &&
                    std::fabs(command.motionY) <= bound &&
                    std::fabs(command.motionZ) <= bound &&
                    sameCommand(command, makeMoonlightMotionSampleCommand(
                        command.motionType, command.motionX, command.motionY,
                        command.motionZ));
            }
            case MoonlightControllerFeedbackKind::Battery:
                return knownBatteryState(command.batteryState) &&
                    (command.batteryPercentage <= 100U ||
                     command.batteryPercentage == 0xFFU) &&
                    sameCommand(command, makeMoonlightBatteryCommand(
                        command.batteryState, command.batteryPercentage));
            case MoonlightControllerFeedbackKind::Invalid:
                return false;
        }
        return false;
    }

    void commit(const MoonlightControllerFeedbackContext& context,
                const MoonlightControllerFeedbackCommand& command) noexcept {
        state.lastOperationGeneration = context.operationGeneration;
        lastCommand = command;
    }

    void demote(const MoonlightControllerFeedbackCommand& command) noexcept {
        if (command.kind == MoonlightControllerFeedbackKind::AdaptiveTriggers) {
            state.adaptiveTriggersEnabled = false;
            adaptiveClaimed = false;
        } else {
            state.advertisedCapabilityMask = static_cast<std::uint16_t>(
                state.advertisedCapabilityMask & ~capabilityFor(command));
        }
        if (command.kind == MoonlightControllerFeedbackKind::MotionReport ||
            command.kind == MoonlightControllerFeedbackKind::MotionSample) {
            if (command.motionType == MoonlightControllerMotionType::Accelerometer) {
                state.accelerometerReportRateHz = 0U;
            } else {
                state.gyroscopeReportRateHz = 0U;
            }
        }
        refreshReleaseRequired();
    }

    void applyAccepted(const MoonlightControllerFeedbackContext& context,
                       const MoonlightControllerFeedbackCommand& command) noexcept {
        switch (command.kind) {
            case MoonlightControllerFeedbackKind::Rumble:
                rumbleActive = command.firstMotor != 0U || command.secondMotor != 0U;
                break;
            case MoonlightControllerFeedbackKind::TriggerRumble:
                triggerRumbleActive =
                    command.firstMotor != 0U || command.secondMotor != 0U;
                break;
            case MoonlightControllerFeedbackKind::RgbLed:
                ledClaimed = true;
                break;
            case MoonlightControllerFeedbackKind::AdaptiveTriggers:
                adaptiveClaimed = command.adaptiveEventFlags != 0U;
                break;
            case MoonlightControllerFeedbackKind::MotionReport:
                if (command.motionType == MoonlightControllerMotionType::Accelerometer) {
                    state.accelerometerReportRateHz = command.motionReportRateHz;
                } else {
                    state.gyroscopeReportRateHz = command.motionReportRateHz;
                }
                break;
            case MoonlightControllerFeedbackKind::MotionSample: {
                const auto index = motionIndex(command.motionType);
                lastMotion[index] = {command.motionX, command.motionY, command.motionZ};
                lastMotionTimestampUs[index] = context.monotonicTimestampUs;
                hasMotion[index] = true;
                break;
            }
            case MoonlightControllerFeedbackKind::Battery:
                lastBatteryTimestampUs = context.monotonicTimestampUs;
                lastBatteryState = command.batteryState;
                lastBatteryPercentage = command.batteryPercentage;
                hasBattery = true;
                break;
            case MoonlightControllerFeedbackKind::Invalid:
                break;
        }
        refreshReleaseRequired();
    }

    MoonlightControllerFeedbackResult transition(
        const MoonlightControllerFeedbackContext& context,
        LifecycleTarget target) noexcept {
        if (!context.valid()) {
            return result(MoonlightControllerFeedbackStatus::InvalidRequest);
        }
        std::lock_guard<std::mutex> lock(mutex);
        if (!state.matched || context.identity != state.identity) {
            return result(MoonlightControllerFeedbackStatus::StaleOwner);
        }
        if (state.state == MoonlightControllerFeedbackState::Cleaned) {
            return result(target == LifecycleTarget::Cleaned &&
                              context.operationGeneration ==
                                  state.lastOperationGeneration
                          ? MoonlightControllerFeedbackStatus::AlreadyApplied
                          : MoonlightControllerFeedbackStatus::InvalidState);
        }
        if (!contextMatches(context)) {
            return result(MoonlightControllerFeedbackStatus::StaleDevice);
        }
        if (pendingCommand.has_value()) {
            return result(MoonlightControllerFeedbackStatus::Backpressure,
                          MoonlightControllerFeedbackPortStatus::Backpressure);
        }
        if (pendingLifecycle != LifecycleTarget::None) {
            if (pendingLifecycle != target ||
                !pendingLifecycleContext.has_value() ||
                !sameContext(*pendingLifecycleContext, context)) {
                return result(MoonlightControllerFeedbackStatus::Backpressure,
                              MoonlightControllerFeedbackPortStatus::Backpressure);
            }
        } else {
            if (context.operationGeneration < state.lastOperationGeneration ||
                context.monotonicTimestampUs < lastTimestampUs) {
                return result(MoonlightControllerFeedbackStatus::StaleOperation);
            }
            if (context.operationGeneration == state.lastOperationGeneration) {
                const bool already =
                    (target == LifecycleTarget::Suspended &&
                     state.state == MoonlightControllerFeedbackState::Suspended) ||
                    (target == LifecycleTarget::Idle &&
                     state.state == MoonlightControllerFeedbackState::Idle);
                return result(already
                    ? MoonlightControllerFeedbackStatus::AlreadyApplied
                    : MoonlightControllerFeedbackStatus::StaleOperation);
            }
            pendingLifecycle = target;
            pendingLifecycleContext = context;
        }

        if (state.releaseRequired) {
            const auto portResult = port->releaseDevice(context);
            if (portResult != MoonlightControllerFeedbackPortStatus::Accepted) {
                state.state = MoonlightControllerFeedbackState::ReleasePending;
                if (portResult == MoonlightControllerFeedbackPortStatus::Backpressure) {
                    state.backpressureOperations =
                        saturatingIncrement(state.backpressureOperations);
                    return result(MoonlightControllerFeedbackStatus::Backpressure,
                                  portResult);
                }
                state.portFailures = saturatingIncrement(state.portFailures);
                return result(MoonlightControllerFeedbackStatus::PortFailure,
                              portResult);
            }
            state.releases = saturatingIncrement(state.releases);
        }

        clearEffects();
        state.lastOperationGeneration = context.operationGeneration;
        lastTimestampUs = context.monotonicTimestampUs;
        lastCommand.reset();
        pendingLifecycle = LifecycleTarget::None;
        pendingLifecycleContext.reset();
        if (target == LifecycleTarget::Suspended) {
            state.state = MoonlightControllerFeedbackState::Suspended;
        } else if (target == LifecycleTarget::Idle) {
            state.state = MoonlightControllerFeedbackState::Idle;
            clearDevice();
        } else {
            state.state = MoonlightControllerFeedbackState::Cleaned;
            clearDevice();
        }
        return result(MoonlightControllerFeedbackStatus::Applied,
                      MoonlightControllerFeedbackPortStatus::Accepted);
    }

    void destroy() noexcept {
        std::lock_guard<std::mutex> lock(mutex);
        if (state.releaseRequired && state.deviceId != 0U) {
            MoonlightControllerFeedbackContext context;
            context.identity = state.identity;
            context.controllerNumber = state.controllerNumber;
            context.deviceId = state.deviceId;
            context.deviceGeneration = state.deviceGeneration;
            context.operationGeneration = state.lastOperationGeneration ==
                    std::numeric_limits<std::uint64_t>::max()
                ? state.lastOperationGeneration
                : state.lastOperationGeneration + 1U;
            context.monotonicTimestampUs = lastTimestampUs ==
                    std::numeric_limits<std::uint64_t>::max()
                ? lastTimestampUs
                : lastTimestampUs + 1U;
            (void)port->releaseDevice(context);
        }
        clearEffects();
        state.state = MoonlightControllerFeedbackState::Cleaned;
    }

    std::uint64_t lastTimestampUs = 0U;
};

MoonlightControllerFeedback::MoonlightControllerFeedback(
    std::unique_ptr<Impl> impl) noexcept : impl_(std::move(impl)) {}

MoonlightControllerFeedback::~MoonlightControllerFeedback() {
    if (impl_ != nullptr) {
        impl_->destroy();
    }
}

std::shared_ptr<MoonlightControllerFeedback> MoonlightControllerFeedback::create(
    std::shared_ptr<MoonlightInputOwnerGate> ownerGate,
    std::shared_ptr<MoonlightControllerFeedbackPort> port,
    MoonlightControllerFeedbackLimits limits) noexcept {
    if (ownerGate == nullptr || port == nullptr || !validLimits(limits)) {
        return nullptr;
    }
    auto impl = std::unique_ptr<Impl>(new (std::nothrow) Impl());
    if (impl == nullptr) {
        return nullptr;
    }
    impl->ownerGate = std::move(ownerGate);
    impl->port = std::move(port);
    impl->limits = limits;
    auto* bridge = new (std::nothrow) MoonlightControllerFeedback(std::move(impl));
    return std::shared_ptr<MoonlightControllerFeedback>(bridge);
}

MoonlightControllerFeedbackResult MoonlightControllerFeedback::bind(
    const MoonlightControllerFeedbackContext& context,
    const MoonlightControllerFeedbackEvidence& evidence) noexcept {
    const bool hasPhysicalEvidence = evidence.physicalDeviceMask != 0U ||
        evidence.adaptiveTriggersPhysicalDevice;
    if (!context.valid() || !validEvidence(evidence) ||
        (hasPhysicalEvidence &&
         evidence.deviceGeneration != context.deviceGeneration)) {
        return result(MoonlightControllerFeedbackStatus::InvalidRequest);
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!impl_->ownerAvailable(context.identity)) {
        return result(MoonlightControllerFeedbackStatus::StaleOwner);
    }
    auto& state = impl_->state;
    if (state.state == MoonlightControllerFeedbackState::Cleaned) {
        return result(MoonlightControllerFeedbackStatus::InvalidState);
    }
    if (state.state != MoonlightControllerFeedbackState::Idle) {
        if (impl_->contextMatches(context) &&
            context.operationGeneration == state.lastOperationGeneration &&
            state.advertisedCapabilityMask == evidence.enabledMask() &&
            state.adaptiveTriggersEnabled == evidence.adaptiveTriggersEnabled()) {
            return result(MoonlightControllerFeedbackStatus::AlreadyApplied);
        }
        return result(MoonlightControllerFeedbackStatus::InvalidState);
    }
    if (state.matched && context.identity != state.identity) {
        return result(MoonlightControllerFeedbackStatus::StaleOwner);
    }
    if (state.matched && context.operationGeneration <= state.lastOperationGeneration) {
        return result(MoonlightControllerFeedbackStatus::StaleOperation);
    }
    state.matched = true;
    state.identity = context.identity;
    state.state = MoonlightControllerFeedbackState::Active;
    state.controllerNumber = context.controllerNumber;
    state.deviceId = context.deviceId;
    state.deviceGeneration = context.deviceGeneration;
    state.advertisedCapabilityMask = evidence.enabledMask();
    state.adaptiveTriggersEnabled = evidence.adaptiveTriggersEnabled();
    state.lastOperationGeneration = context.operationGeneration;
    impl_->lastTimestampUs = context.monotonicTimestampUs;
    impl_->lastCommand.reset();
    return result(MoonlightControllerFeedbackStatus::Applied,
                  MoonlightControllerFeedbackPortStatus::Accepted);
}

MoonlightControllerFeedbackResult MoonlightControllerFeedback::dispatch(
    const MoonlightControllerFeedbackContext& context,
    const MoonlightControllerFeedbackCommand& requestedCommand) noexcept {
    if (!context.valid()) {
        return result(MoonlightControllerFeedbackStatus::InvalidRequest);
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    auto& state = impl_->state;
    if (!state.matched || context.identity != state.identity) {
        return result(MoonlightControllerFeedbackStatus::StaleOwner);
    }
    if (state.state != MoonlightControllerFeedbackState::Active) {
        return result(MoonlightControllerFeedbackStatus::InvalidState);
    }
    if (!impl_->contextMatches(context)) {
        return result(MoonlightControllerFeedbackStatus::StaleDevice);
    }
    if (!impl_->validCommand(requestedCommand)) {
        return result(MoonlightControllerFeedbackStatus::InvalidRequest);
    }

    MoonlightControllerFeedbackCommand command = requestedCommand;
    bool adjusted = false;
    if (command.kind == MoonlightControllerFeedbackKind::MotionReport &&
        command.motionReportRateHz > impl_->limits.maximumMotionReportRateHz) {
        command.motionReportRateHz = impl_->limits.maximumMotionReportRateHz;
        adjusted = true;
    }

    if (impl_->pendingLifecycle != LifecycleTarget::None) {
        return result(MoonlightControllerFeedbackStatus::Backpressure,
                      MoonlightControllerFeedbackPortStatus::Backpressure);
    }
    if (impl_->pendingCommand.has_value()) {
        if (!impl_->pendingContext.has_value() ||
            !sameContext(*impl_->pendingContext, context) ||
            !sameCommand(*impl_->pendingCommand, command)) {
            return result(MoonlightControllerFeedbackStatus::Backpressure,
                          MoonlightControllerFeedbackPortStatus::Backpressure);
        }
    } else {
        if (context.operationGeneration < state.lastOperationGeneration ||
            context.monotonicTimestampUs < impl_->lastTimestampUs) {
            return result(MoonlightControllerFeedbackStatus::StaleOperation);
        }
        if (context.operationGeneration == state.lastOperationGeneration) {
            return result(impl_->lastCommand.has_value() &&
                                  sameCommand(*impl_->lastCommand, command)
                              ? MoonlightControllerFeedbackStatus::AlreadyApplied
                              : MoonlightControllerFeedbackStatus::StaleOperation,
                          MoonlightControllerFeedbackPortStatus::Accepted,
                          adjusted);
        }
    }

    const bool adaptive =
        command.kind == MoonlightControllerFeedbackKind::AdaptiveTriggers;
    const auto capability = capabilityFor(command);
    if ((adaptive && !state.adaptiveTriggersEnabled) ||
        (!adaptive &&
         (state.advertisedCapabilityMask & capability) == 0U)) {
        if (!impl_->ownerAvailable(context.identity)) {
            return result(MoonlightControllerFeedbackStatus::StaleOwner);
        }
        impl_->commit(context, command);
        impl_->lastTimestampUs = context.monotonicTimestampUs;
        state.unsupportedOperations =
            saturatingIncrement(state.unsupportedOperations);
        return result(MoonlightControllerFeedbackStatus::Unsupported,
                      MoonlightControllerFeedbackPortStatus::Unsupported,
                      adjusted);
    }

    if (command.kind == MoonlightControllerFeedbackKind::MotionSample) {
        const auto index = motionIndex(command.motionType);
        const auto reportRate =
            command.motionType == MoonlightControllerMotionType::Accelerometer
                ? state.accelerometerReportRateHz
                : state.gyroscopeReportRateHz;
        if (reportRate == 0U) {
            return result(MoonlightControllerFeedbackStatus::InvalidState);
        }
        const auto minimumIntervalUs = 1000000U / reportRate;
        const bool duplicate = impl_->hasMotion[index] &&
            impl_->lastMotion[index][0] == command.motionX &&
            impl_->lastMotion[index][1] == command.motionY &&
            impl_->lastMotion[index][2] == command.motionZ;
        const bool tooSoon = impl_->lastMotionTimestampUs[index] != 0U &&
            context.monotonicTimestampUs - impl_->lastMotionTimestampUs[index] <
                minimumIntervalUs;
        if (duplicate || tooSoon) {
            if (!impl_->ownerAvailable(context.identity)) {
                return result(MoonlightControllerFeedbackStatus::StaleOwner);
            }
            impl_->commit(context, command);
            impl_->lastTimestampUs = context.monotonicTimestampUs;
            state.localOnlyOperations =
                saturatingIncrement(state.localOnlyOperations);
            state.rateLimitedOperations =
                saturatingIncrement(state.rateLimitedOperations);
            return result(MoonlightControllerFeedbackStatus::RateLimited,
                          MoonlightControllerFeedbackPortStatus::Accepted,
                          adjusted);
        }
    }

    if (command.kind == MoonlightControllerFeedbackKind::Battery &&
        impl_->hasBattery && command.batteryState == impl_->lastBatteryState &&
        command.batteryPercentage == impl_->lastBatteryPercentage &&
        context.monotonicTimestampUs - impl_->lastBatteryTimestampUs <
            impl_->limits.batteryRefreshIntervalUs) {
        if (!impl_->ownerAvailable(context.identity)) {
            return result(MoonlightControllerFeedbackStatus::StaleOwner);
        }
        impl_->commit(context, command);
        impl_->lastTimestampUs = context.monotonicTimestampUs;
        state.localOnlyOperations = saturatingIncrement(state.localOnlyOperations);
        state.rateLimitedOperations =
            saturatingIncrement(state.rateLimitedOperations);
        return result(MoonlightControllerFeedbackStatus::RateLimited,
                      MoonlightControllerFeedbackPortStatus::Accepted,
                      adjusted);
    }

    SubmitOperation operation(*impl_->port, context, command);
    if (!impl_->ownerGate->withOwner(context.identity, operation) ||
        !operation.executed) {
        return result(MoonlightControllerFeedbackStatus::StaleOwner);
    }
    switch (operation.status) {
        case MoonlightControllerFeedbackPortStatus::Accepted:
            impl_->pendingContext.reset();
            impl_->pendingCommand.reset();
            state.commandPending = false;
            impl_->applyAccepted(context, command);
            impl_->commit(context, command);
            impl_->lastTimestampUs = context.monotonicTimestampUs;
            state.acceptedOperations =
                saturatingIncrement(state.acceptedOperations);
            return result(MoonlightControllerFeedbackStatus::Applied,
                          operation.status, adjusted);
        case MoonlightControllerFeedbackPortStatus::Backpressure:
            impl_->pendingContext = context;
            impl_->pendingCommand = command;
            state.commandPending = true;
            state.backpressureOperations =
                saturatingIncrement(state.backpressureOperations);
            return result(MoonlightControllerFeedbackStatus::Backpressure,
                          operation.status, adjusted);
        case MoonlightControllerFeedbackPortStatus::Unsupported:
            impl_->pendingContext.reset();
            impl_->pendingCommand.reset();
            state.commandPending = false;
            impl_->demote(command);
            impl_->commit(context, command);
            impl_->lastTimestampUs = context.monotonicTimestampUs;
            state.unsupportedOperations =
                saturatingIncrement(state.unsupportedOperations);
            return result(MoonlightControllerFeedbackStatus::Unsupported,
                          operation.status, adjusted);
        case MoonlightControllerFeedbackPortStatus::Failed:
            state.portFailures = saturatingIncrement(state.portFailures);
            return result(MoonlightControllerFeedbackStatus::PortFailure,
                          operation.status, adjusted);
    }
    return result(MoonlightControllerFeedbackStatus::PortFailure);
}

MoonlightControllerFeedbackResult MoonlightControllerFeedback::suspend(
    const MoonlightControllerFeedbackContext& context) noexcept {
    return impl_->transition(context, LifecycleTarget::Suspended);
}

MoonlightControllerFeedbackResult MoonlightControllerFeedback::resume(
    const MoonlightControllerFeedbackContext& context) noexcept {
    if (!context.valid()) {
        return result(MoonlightControllerFeedbackStatus::InvalidRequest);
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    auto& state = impl_->state;
    if (!state.matched || context.identity != state.identity) {
        return result(MoonlightControllerFeedbackStatus::StaleOwner);
    }
    if (state.state != MoonlightControllerFeedbackState::Suspended) {
        return result(MoonlightControllerFeedbackStatus::InvalidState);
    }
    if (!impl_->contextMatches(context)) {
        return result(MoonlightControllerFeedbackStatus::StaleDevice);
    }
    if (context.operationGeneration <= state.lastOperationGeneration ||
        context.monotonicTimestampUs < impl_->lastTimestampUs) {
        return result(MoonlightControllerFeedbackStatus::StaleOperation);
    }
    if (!impl_->ownerAvailable(context.identity)) {
        return result(MoonlightControllerFeedbackStatus::StaleOwner);
    }
    state.state = MoonlightControllerFeedbackState::Active;
    state.lastOperationGeneration = context.operationGeneration;
    impl_->lastTimestampUs = context.monotonicTimestampUs;
    impl_->lastCommand.reset();
    return result(MoonlightControllerFeedbackStatus::Applied,
                  MoonlightControllerFeedbackPortStatus::Accepted);
}

MoonlightControllerFeedbackResult MoonlightControllerFeedback::unbind(
    const MoonlightControllerFeedbackContext& context) noexcept {
    return impl_->transition(context, LifecycleTarget::Idle);
}

MoonlightControllerFeedbackResult MoonlightControllerFeedback::cleanup(
    const MoonlightControllerFeedbackContext& context) noexcept {
    return impl_->transition(context, LifecycleTarget::Cleaned);
}

MoonlightControllerFeedbackSnapshot MoonlightControllerFeedback::snapshot(
    const MoonlightInputIdentity& identity) const noexcept {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!identity.valid() || !impl_->state.matched ||
        impl_->state.identity != identity) {
        return {};
    }
    auto snapshot = impl_->state;
    snapshot.commandPending = impl_->pendingCommand.has_value();
    snapshot.releaseRequired = impl_->releaseRequired();
    return snapshot;
}

} // namespace remotedesk::moonlight
