#include "moonlight/input/MoonlightControllerMapper.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <mutex>
#include <new>
#include <utility>

namespace remotedesk::moonlight {
namespace {

enum class ObserveStatus : std::uint8_t {
    Ready = 0,
    Duplicate,
    Stale,
    Capacity,
};

struct ObservedControllerLane final {
    bool occupied = false;
    bool retired = false;
    std::uint64_t deviceId = 0U;
    MoonlightInputSource source = MoonlightInputSource::Invalid;
    std::uint64_t sourceGeneration = 0U;
    std::uint64_t lastSequence = 0U;
    std::uint64_t lastTimestampUs = 0U;
};

struct ControllerState final {
    bool active = false;
    std::uint64_t deviceId = 0U;
    MoonlightInputSource source = MoonlightInputSource::Invalid;
    std::uint64_t sourceGeneration = 0U;
    MoonlightControllerProfile profile{};
    MoonlightControllerMappedState mapped{};
    std::array<ObservedControllerLane,
               kMoonlightMaximumObservedControllerLanes> lanes{};
    std::uint64_t arrivals = 0U;
    std::uint64_t stateFrames = 0U;
    std::uint64_t neutralFrames = 0U;
    std::uint64_t removals = 0U;
    std::uint64_t localOnlyUpdates = 0U;
    std::uint64_t rejectedEvents = 0U;
};

std::uint64_t saturatingIncrement(std::uint64_t value) noexcept {
    return value == std::numeric_limits<std::uint64_t>::max() ? value : value + 1U;
}

bool knownControllerType(MoonlightControllerType type) noexcept {
    switch (type) {
        case MoonlightControllerType::Unknown:
        case MoonlightControllerType::Xbox:
        case MoonlightControllerType::PlayStation:
        case MoonlightControllerType::Nintendo:
            return true;
    }
    return false;
}

bool validProfile(const MoonlightControllerProfile& profile) noexcept {
    return knownControllerType(profile.type) &&
        profile.supportedButtonFlags != 0U &&
        // Physical API 23 listeners advertise their conservative subset, but
        // virtual controls can also supply common-c Back/Select. The shared
        // wire mapper therefore validates the official standard protocol
        // mask instead of incorrectly imposing the platform input subset.
        (profile.supportedButtonFlags & ~kMoonlightControllerStandardButtonMask) == 0U;
}

bool validLimits(const MoonlightControllerLimits& limits) noexcept {
    return std::isfinite(limits.stickDeadzone) &&
        std::isfinite(limits.triggerDeadzone) &&
        limits.stickDeadzone >= 0.0 && limits.stickDeadzone < 1.0 &&
        limits.triggerDeadzone >= 0.0 && limits.triggerDeadzone < 1.0;
}

bool finiteUnit(double value) noexcept {
    return std::isfinite(value) && value >= -1.0 && value <= 1.0;
}

bool finiteTrigger(double value) noexcept {
    return std::isfinite(value) && value >= 0.0 && value <= 1.0;
}

bool sameProfile(const MoonlightControllerProfile& left,
                 const MoonlightControllerProfile& right) noexcept {
    return left.type == right.type &&
        left.supportedButtonFlags == right.supportedButtonFlags &&
        left.analogTriggers == right.analogTriggers;
}

bool sameMappedState(const MoonlightControllerMappedState& left,
                     const MoonlightControllerMappedState& right) noexcept {
    return left.buttonFlags == right.buttonFlags &&
        left.leftTrigger == right.leftTrigger &&
        left.rightTrigger == right.rightTrigger &&
        left.leftStickX == right.leftStickX &&
        left.leftStickY == right.leftStickY &&
        left.rightStickX == right.rightStickX &&
        left.rightStickY == right.rightStickY;
}

bool neutralState(const MoonlightControllerMappedState& state) noexcept {
    return sameMappedState(state, {});
}

std::size_t observedLaneCount(const ControllerState& state) noexcept {
    std::size_t count = 0U;
    for (const ObservedControllerLane& lane : state.lanes) {
        count += lane.occupied ? 1U : 0U;
    }
    return count;
}

ObserveStatus observe(ControllerState& state,
                      const MoonlightControllerEventContext& context) noexcept {
    ObservedControllerLane* freeLane = nullptr;
    ObservedControllerLane* reusableLane = nullptr;
    for (ObservedControllerLane& lane : state.lanes) {
        if (lane.occupied && lane.deviceId == context.deviceId &&
            lane.source == context.source &&
            lane.sourceGeneration == context.sourceGeneration) {
            if (lane.retired) {
                return ObserveStatus::Stale;
            }
            if (context.sourceSequence == lane.lastSequence) {
                return ObserveStatus::Duplicate;
            }
            if (context.sourceSequence < lane.lastSequence ||
                context.monotonicTimestampUs < lane.lastTimestampUs) {
                return ObserveStatus::Stale;
            }
            lane.lastSequence = context.sourceSequence;
            lane.lastTimestampUs = context.monotonicTimestampUs;
            return ObserveStatus::Ready;
        }
        if (lane.occupied && lane.retired &&
            lane.deviceId == context.deviceId &&
            lane.source == context.source) {
            if (context.sourceGeneration < lane.sourceGeneration) {
                return ObserveStatus::Stale;
            }
            if (context.sourceGeneration > lane.sourceGeneration) {
                reusableLane = &lane;
            }
        }
        if (!lane.occupied && freeLane == nullptr) {
            freeLane = &lane;
        }
    }
    if (reusableLane != nullptr) {
        *reusableLane = {true, false, context.deviceId, context.source,
                         context.sourceGeneration, context.sourceSequence,
                         context.monotonicTimestampUs};
        return ObserveStatus::Ready;
    }
    if (freeLane == nullptr) {
        return ObserveStatus::Capacity;
    }
    *freeLane = {true, false, context.deviceId, context.source,
                 context.sourceGeneration,
                 context.sourceSequence, context.monotonicTimestampUs};
    return ObserveStatus::Ready;
}

void retireObservedLane(ControllerState& state,
                        const MoonlightControllerEventContext& context) noexcept {
    for (ObservedControllerLane& lane : state.lanes) {
        if (lane.occupied && lane.deviceId == context.deviceId &&
            lane.source == context.source &&
            lane.sourceGeneration == context.sourceGeneration) {
            lane.retired = true;
            return;
        }
    }
}

MoonlightControllerStatus controllerStatus(
    MoonlightInputDispatchStatus status) noexcept {
    switch (status) {
        case MoonlightInputDispatchStatus::Accepted:
            return MoonlightControllerStatus::Applied;
        case MoonlightInputDispatchStatus::InvalidRequest:
            return MoonlightControllerStatus::InvalidRequest;
        case MoonlightInputDispatchStatus::InvalidState:
            return MoonlightControllerStatus::InvalidState;
        case MoonlightInputDispatchStatus::StaleOwner:
            return MoonlightControllerStatus::StaleOwner;
        case MoonlightInputDispatchStatus::StaleEvent:
            return MoonlightControllerStatus::StaleEvent;
        case MoonlightInputDispatchStatus::Duplicate:
            return MoonlightControllerStatus::Duplicate;
        case MoonlightInputDispatchStatus::SourceCapacity:
            return MoonlightControllerStatus::SourceCapacity;
        case MoonlightInputDispatchStatus::Backpressure:
            return MoonlightControllerStatus::Backpressure;
        case MoonlightInputDispatchStatus::Unsupported:
            return MoonlightControllerStatus::PortUnsupported;
        case MoonlightInputDispatchStatus::PortFailure:
            return MoonlightControllerStatus::PortFailure;
    }
    return MoonlightControllerStatus::PortFailure;
}

MoonlightControllerResult observeResult(ObserveStatus status) noexcept {
    switch (status) {
        case ObserveStatus::Ready:
            return {MoonlightControllerStatus::Applied,
                    MoonlightInputDispatchStatus::Accepted};
        case ObserveStatus::Duplicate:
            return {MoonlightControllerStatus::Duplicate,
                    MoonlightInputDispatchStatus::Duplicate};
        case ObserveStatus::Stale:
            return {MoonlightControllerStatus::StaleEvent,
                    MoonlightInputDispatchStatus::StaleEvent};
        case ObserveStatus::Capacity:
            return {MoonlightControllerStatus::SourceCapacity,
                    MoonlightInputDispatchStatus::SourceCapacity};
    }
    return {};
}

void writeUint16(
    std::array<std::uint8_t, kMoonlightMaximumInputPayloadBytes>& payload,
    std::size_t offset,
    std::uint16_t value) noexcept {
    payload[offset] = static_cast<std::uint8_t>(value & 0x00FFU);
    payload[offset + 1U] = static_cast<std::uint8_t>((value >> 8U) & 0x00FFU);
}

void writeUint32(
    std::array<std::uint8_t, kMoonlightMaximumInputPayloadBytes>& payload,
    std::size_t offset,
    std::uint32_t value) noexcept {
    for (std::size_t index = 0U; index < 4U; ++index) {
        payload[offset + index] = static_cast<std::uint8_t>(
            (value >> static_cast<unsigned int>(index * 8U)) & 0x000000FFU);
    }
}

void writeInt16(
    std::array<std::uint8_t, kMoonlightMaximumInputPayloadBytes>& payload,
    std::size_t offset,
    std::int16_t value) noexcept {
    writeUint16(payload, offset, static_cast<std::uint16_t>(value));
}

std::uint16_t readUint16(
    const std::array<std::uint8_t, kMoonlightMaximumInputPayloadBytes>& payload,
    std::size_t offset) noexcept {
    return static_cast<std::uint16_t>(payload[offset]) |
        static_cast<std::uint16_t>(
            static_cast<std::uint16_t>(payload[offset + 1U]) << 8U);
}

std::uint32_t readUint32(
    const std::array<std::uint8_t, kMoonlightMaximumInputPayloadBytes>& payload,
    std::size_t offset) noexcept {
    std::uint32_t value = 0U;
    for (std::size_t index = 0U; index < 4U; ++index) {
        value |= static_cast<std::uint32_t>(payload[offset + index]) <<
            static_cast<unsigned int>(index * 8U);
    }
    return value;
}

std::int16_t readInt16(
    const std::array<std::uint8_t, kMoonlightMaximumInputPayloadBytes>& payload,
    std::size_t offset) noexcept {
    const std::uint16_t value = readUint16(payload, offset);
    const std::int32_t signedValue = value <= 0x7FFFU
        ? static_cast<std::int32_t>(value)
        : static_cast<std::int32_t>(value) - 0x10000;
    return static_cast<std::int16_t>(signedValue);
}

bool zeroTail(const MoonlightInputEvent& event) noexcept {
    for (std::size_t index = event.payloadSize; index < event.payload.size(); ++index) {
        if (event.payload[index] != 0U) {
            return false;
        }
    }
    return true;
}

std::int16_t stickAxis(double value) noexcept {
    // Moonlight Android intentionally uses 0x7FFE and leaves host/game deadzone
    // handling intact instead of rescaling the surviving vector.
    return static_cast<std::int16_t>(value * 32766.0);
}

std::uint8_t triggerAxis(double value,
                         double deadzone,
                         bool analog) noexcept {
    if (value <= deadzone) {
        return 0U;
    }
    if (!analog) {
        return 0xFFU;
    }
    return static_cast<std::uint8_t>(value * 255.0);
}

MoonlightInputEvent controllerEvent(
    const MoonlightControllerEventContext& context,
    const MoonlightControllerWireCommand& command,
    bool lifecycleRelease) noexcept {
    MoonlightInputEvent event;
    event.identity = context.identity;
    event.deviceId = context.deviceId;
    event.source = context.source;
    event.sourceGeneration = context.sourceGeneration;
    event.sourceSequence = context.sourceSequence;
    event.monotonicTimestampUs = context.monotonicTimestampUs;
    event.kind = MoonlightInputCommandKind::Controller;
    event.lifecycleRelease = lifecycleRelease;
    event.commandVersion = 1U;
    event.payloadSize = kMoonlightControllerCommandBytes;
    event.payload[0] = static_cast<std::uint8_t>(command.operation);
    event.payload[1] = command.controllerNumber;
    writeUint16(event.payload, 2U, command.activeGamepadMask);
    writeUint32(event.payload, 4U, command.state.buttonFlags);
    event.payload[8] = command.state.leftTrigger;
    event.payload[9] = command.state.rightTrigger;
    writeInt16(event.payload, 10U, command.state.leftStickX);
    writeInt16(event.payload, 12U, command.state.leftStickY);
    writeInt16(event.payload, 14U, command.state.rightStickX);
    writeInt16(event.payload, 16U, command.state.rightStickY);
    event.payload[18] = static_cast<std::uint8_t>(command.type);
    // byte 19 and bytes 26..27 are reserved and remain zero.
    writeUint16(event.payload, 20U, command.capabilities);
    writeUint32(event.payload, 22U, command.supportedButtonFlags);
    return event;
}

MoonlightControllerWireCommand arrivalCommand(
    const MoonlightControllerProfile& profile) noexcept {
    MoonlightControllerWireCommand command;
    command.operation = MoonlightControllerCommandOperation::Arrival;
    command.controllerNumber = 0U;
    command.activeGamepadMask = kMoonlightProductControllerBitmap;
    command.type = profile.type;
    command.capabilities = profile.analogTriggers
        ? kMoonlightControllerCapabilityAnalogTriggers
        : 0U;
    command.supportedButtonFlags = profile.supportedButtonFlags;
    return command;
}

MoonlightControllerWireCommand stateCommand(
    const MoonlightControllerMappedState& state,
    bool active) noexcept {
    MoonlightControllerWireCommand command;
    command.operation = MoonlightControllerCommandOperation::State;
    command.controllerNumber = 0U;
    command.activeGamepadMask = active ? kMoonlightProductControllerBitmap : 0U;
    command.state = state;
    return command;
}

} // namespace

bool mapMoonlightControllerSample(
    const MoonlightControllerSample& sample,
    const MoonlightControllerProfile& profile,
    const MoonlightControllerLimits& limits,
    MoonlightControllerMappedState& mapped) noexcept {
    if (!validProfile(profile) || !validLimits(limits) ||
        (sample.buttonFlags & ~profile.supportedButtonFlags) != 0U ||
        !finiteUnit(sample.leftStickX) || !finiteUnit(sample.leftStickY) ||
        !finiteUnit(sample.rightStickX) || !finiteUnit(sample.rightStickY) ||
        !finiteTrigger(sample.leftTrigger) ||
        !finiteTrigger(sample.rightTrigger) ||
        !finiteUnit(sample.hatX) || !finiteUnit(sample.hatY)) {
        mapped = {};
        return false;
    }

    mapped = {};
    mapped.buttonFlags = sample.buttonFlags;
    if (sample.hasHatAxes) {
        mapped.buttonFlags &= ~kMoonlightControllerDpadMask;
        if (sample.hatX < -0.5) {
            mapped.buttonFlags |= kMoonlightControllerButtonLeft;
        } else if (sample.hatX > 0.5) {
            mapped.buttonFlags |= kMoonlightControllerButtonRight;
        }
        if (sample.hatY < -0.5) {
            mapped.buttonFlags |= kMoonlightControllerButtonUp;
        } else if (sample.hatY > 0.5) {
            mapped.buttonFlags |= kMoonlightControllerButtonDown;
        }
        mapped.buttonFlags &= profile.supportedButtonFlags;
    }

    double leftX = sample.leftStickX;
    double leftY = sample.leftStickY;
    if (std::hypot(leftX, leftY) <= limits.stickDeadzone) {
        leftX = 0.0;
        leftY = 0.0;
    }
    double rightX = sample.rightStickX;
    double rightY = sample.rightStickY;
    if (std::hypot(rightX, rightY) <= limits.stickDeadzone) {
        rightX = 0.0;
        rightY = 0.0;
    }

    mapped.leftStickX = stickAxis(leftX);
    mapped.leftStickY = stickAxis(-leftY);
    mapped.rightStickX = stickAxis(rightX);
    mapped.rightStickY = stickAxis(-rightY);
    mapped.leftTrigger = triggerAxis(sample.leftTrigger,
                                     limits.triggerDeadzone,
                                     profile.analogTriggers);
    mapped.rightTrigger = triggerAxis(sample.rightTrigger,
                                      limits.triggerDeadzone,
                                      profile.analogTriggers);
    return true;
}

bool decodeMoonlightControllerCommand(
    const MoonlightInputEvent& event,
    MoonlightControllerWireCommand& command) noexcept {
    command = {};
    if (!event.identity.valid() || event.deviceId == 0U ||
        (event.source != MoonlightInputSource::GameController &&
         event.source != MoonlightInputSource::VirtualController) ||
        event.sourceGeneration == 0U || event.sourceSequence == 0U ||
        event.monotonicTimestampUs == 0U ||
        event.kind != MoonlightInputCommandKind::Controller ||
        event.commandVersion != 1U ||
        event.payloadSize != kMoonlightControllerCommandBytes ||
        event.payload[19] != 0U || event.payload[26] != 0U ||
        event.payload[27] != 0U || !zeroTail(event)) {
        return false;
    }

    command.operation = static_cast<MoonlightControllerCommandOperation>(
        event.payload[0]);
    command.controllerNumber = event.payload[1];
    command.activeGamepadMask = readUint16(event.payload, 2U);
    command.state.buttonFlags = readUint32(event.payload, 4U);
    command.state.leftTrigger = event.payload[8];
    command.state.rightTrigger = event.payload[9];
    command.state.leftStickX = readInt16(event.payload, 10U);
    command.state.leftStickY = readInt16(event.payload, 12U);
    command.state.rightStickX = readInt16(event.payload, 14U);
    command.state.rightStickY = readInt16(event.payload, 16U);
    command.type = static_cast<MoonlightControllerType>(event.payload[18]);
    command.capabilities = readUint16(event.payload, 20U);
    command.supportedButtonFlags = readUint32(event.payload, 22U);

    if (command.controllerNumber != 0U ||
        (command.activeGamepadMask != 0U &&
         command.activeGamepadMask != kMoonlightProductControllerBitmap) ||
        (command.state.buttonFlags & ~kMoonlightControllerStandardButtonMask) != 0U) {
        command = {};
        return false;
    }

    switch (command.operation) {
        case MoonlightControllerCommandOperation::Arrival: {
            const MoonlightControllerProfile profile{
                command.type, command.supportedButtonFlags,
                (command.capabilities &
                 kMoonlightControllerCapabilityAnalogTriggers) != 0U};
            if (command.activeGamepadMask != kMoonlightProductControllerBitmap ||
                !neutralState(command.state) || !validProfile(profile) ||
                (command.capabilities &
                 ~kMoonlightControllerCapabilityAnalogTriggers) != 0U) {
                command = {};
                return false;
            }
            return true;
        }
        case MoonlightControllerCommandOperation::State:
            if (command.type != MoonlightControllerType::Unknown ||
                command.capabilities != 0U ||
                command.supportedButtonFlags != 0U ||
                (command.activeGamepadMask == 0U &&
                 !neutralState(command.state))) {
                command = {};
                return false;
            }
            return true;
    }
    command = {};
    return false;
}

struct MoonlightControllerMapper::Impl final {
    Impl(std::shared_ptr<MoonlightInputBridge> inputBridge,
         MoonlightInputIdentity inputIdentity,
         MoonlightControllerLimits inputLimits) noexcept
        : bridge(std::move(inputBridge)), identity(inputIdentity), limits(inputLimits) {}

    MoonlightControllerResult reject(MoonlightControllerStatus status,
                                     MoonlightInputDispatchStatus dispatchStatus =
                                         MoonlightInputDispatchStatus::InvalidRequest) noexcept {
        state.rejectedEvents = saturatingIncrement(state.rejectedEvents);
        return {status, dispatchStatus};
    }

    MoonlightControllerResult dispatch(
        const MoonlightControllerEventContext& context,
        const MoonlightControllerWireCommand& command,
        ControllerState&& candidate,
        bool lifecycleRelease = false) noexcept {
        const MoonlightInputDispatchStatus dispatchStatus =
            bridge->dispatch(controllerEvent(context, command, lifecycleRelease));
        if (dispatchStatus == MoonlightInputDispatchStatus::Accepted) {
            state = std::move(candidate);
            return {MoonlightControllerStatus::Applied, dispatchStatus};
        }
        return reject(controllerStatus(dispatchStatus), dispatchStatus);
    }

    mutable std::mutex mutex;
    std::shared_ptr<MoonlightInputBridge> bridge;
    MoonlightInputIdentity identity{};
    MoonlightControllerLimits limits{};
    ControllerState state{};
};

MoonlightControllerMapper::MoonlightControllerMapper(
    std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

MoonlightControllerMapper::~MoonlightControllerMapper() = default;

std::shared_ptr<MoonlightControllerMapper> MoonlightControllerMapper::create(
    std::shared_ptr<MoonlightInputBridge> bridge,
    const MoonlightInputIdentity& identity,
    MoonlightControllerLimits limits) noexcept {
    if (!bridge || !identity.valid() || !limits.api23InputAvailable ||
        !validLimits(limits)) {
        return nullptr;
    }
    std::unique_ptr<Impl> impl(new (std::nothrow)
        Impl(std::move(bridge), identity, limits));
    if (!impl) {
        return nullptr;
    }
    return std::shared_ptr<MoonlightControllerMapper>(
        new (std::nothrow) MoonlightControllerMapper(std::move(impl)));
}

MoonlightControllerResult MoonlightControllerMapper::connect(
    const MoonlightControllerEventContext& context,
    const MoonlightControllerProfile& profile) noexcept {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!context.valid() || !validProfile(profile)) {
        return impl_->reject(MoonlightControllerStatus::InvalidRequest);
    }
    if (context.identity != impl_->identity) {
        return impl_->reject(MoonlightControllerStatus::StaleOwner,
                             MoonlightInputDispatchStatus::StaleOwner);
    }
    if (impl_->state.active) {
        if (impl_->state.deviceId != context.deviceId ||
            impl_->state.source != context.source) {
            return impl_->reject(MoonlightControllerStatus::SlotCapacity,
                                 MoonlightInputDispatchStatus::SourceCapacity);
        }
        if (impl_->state.sourceGeneration != context.sourceGeneration ||
            !sameProfile(impl_->state.profile, profile)) {
            return impl_->reject(MoonlightControllerStatus::FlushRequired,
                                 MoonlightInputDispatchStatus::InvalidState);
        }
        ControllerState candidate = impl_->state;
        const ObserveStatus observed = observe(candidate, context);
        if (observed != ObserveStatus::Ready) {
            const MoonlightControllerResult result = observeResult(observed);
            return impl_->reject(result.status, result.dispatchStatus);
        }
        candidate.localOnlyUpdates = saturatingIncrement(
            candidate.localOnlyUpdates);
        impl_->state = std::move(candidate);
        return {MoonlightControllerStatus::AlreadyApplied,
                MoonlightInputDispatchStatus::Accepted};
    }

    ControllerState candidate = impl_->state;
    const ObserveStatus observed = observe(candidate, context);
    if (observed != ObserveStatus::Ready) {
        const MoonlightControllerResult result = observeResult(observed);
        return impl_->reject(result.status, result.dispatchStatus);
    }
    candidate.active = true;
    candidate.deviceId = context.deviceId;
    candidate.source = context.source;
    candidate.sourceGeneration = context.sourceGeneration;
    candidate.profile = profile;
    candidate.mapped = {};
    candidate.arrivals = saturatingIncrement(candidate.arrivals);
    return impl_->dispatch(context, arrivalCommand(profile), std::move(candidate));
}

MoonlightControllerResult MoonlightControllerMapper::update(
    const MoonlightControllerEventContext& context,
    const MoonlightControllerSample& sample) noexcept {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!context.valid()) {
        return impl_->reject(MoonlightControllerStatus::InvalidRequest);
    }
    if (context.identity != impl_->identity) {
        return impl_->reject(MoonlightControllerStatus::StaleOwner,
                             MoonlightInputDispatchStatus::StaleOwner);
    }
    if (!impl_->state.active || impl_->state.deviceId != context.deviceId ||
        impl_->state.source != context.source) {
        return impl_->reject(MoonlightControllerStatus::NotActive,
                             MoonlightInputDispatchStatus::InvalidState);
    }
    if (impl_->state.sourceGeneration != context.sourceGeneration) {
        return impl_->reject(MoonlightControllerStatus::FlushRequired,
                             MoonlightInputDispatchStatus::InvalidState);
    }

    MoonlightControllerMappedState mapped;
    if (!mapMoonlightControllerSample(sample, impl_->state.profile,
                                      impl_->limits, mapped)) {
        return impl_->reject(MoonlightControllerStatus::InvalidRequest);
    }
    ControllerState candidate = impl_->state;
    const ObserveStatus observed = observe(candidate, context);
    if (observed != ObserveStatus::Ready) {
        const MoonlightControllerResult result = observeResult(observed);
        return impl_->reject(result.status, result.dispatchStatus);
    }
    if (sameMappedState(mapped, impl_->state.mapped)) {
        candidate.localOnlyUpdates = saturatingIncrement(
            candidate.localOnlyUpdates);
        impl_->state = std::move(candidate);
        return {MoonlightControllerStatus::AppliedLocally,
                MoonlightInputDispatchStatus::Accepted};
    }
    candidate.mapped = mapped;
    candidate.stateFrames = saturatingIncrement(candidate.stateFrames);
    if (neutralState(mapped)) {
        candidate.neutralFrames = saturatingIncrement(candidate.neutralFrames);
    }
    return impl_->dispatch(context, stateCommand(mapped, true),
                           std::move(candidate));
}

MoonlightControllerResult MoonlightControllerMapper::neutralize(
    const MoonlightControllerEventContext& context) noexcept {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!context.valid()) {
        return impl_->reject(MoonlightControllerStatus::InvalidRequest);
    }
    if (context.identity != impl_->identity) {
        return impl_->reject(MoonlightControllerStatus::StaleOwner,
                             MoonlightInputDispatchStatus::StaleOwner);
    }
    if (!impl_->state.active || impl_->state.deviceId != context.deviceId ||
        impl_->state.source != context.source) {
        return impl_->reject(MoonlightControllerStatus::NotActive,
                             MoonlightInputDispatchStatus::InvalidState);
    }
    if (impl_->state.sourceGeneration != context.sourceGeneration) {
        return impl_->reject(MoonlightControllerStatus::FlushRequired,
                             MoonlightInputDispatchStatus::InvalidState);
    }
    ControllerState candidate = impl_->state;
    const ObserveStatus observed = observe(candidate, context);
    if (observed != ObserveStatus::Ready) {
        const MoonlightControllerResult result = observeResult(observed);
        return impl_->reject(result.status, result.dispatchStatus);
    }
    if (neutralState(impl_->state.mapped)) {
        candidate.localOnlyUpdates = saturatingIncrement(
            candidate.localOnlyUpdates);
        impl_->state = std::move(candidate);
        return {MoonlightControllerStatus::AlreadyApplied,
                MoonlightInputDispatchStatus::Accepted};
    }
    candidate.mapped = {};
    candidate.stateFrames = saturatingIncrement(candidate.stateFrames);
    candidate.neutralFrames = saturatingIncrement(candidate.neutralFrames);
    return impl_->dispatch(context, stateCommand({}, true),
                           std::move(candidate), true);
}

MoonlightControllerResult MoonlightControllerMapper::disconnect(
    const MoonlightControllerEventContext& context) noexcept {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!context.valid()) {
        return impl_->reject(MoonlightControllerStatus::InvalidRequest);
    }
    if (context.identity != impl_->identity) {
        return impl_->reject(MoonlightControllerStatus::StaleOwner,
                             MoonlightInputDispatchStatus::StaleOwner);
    }
    if (!impl_->state.active || impl_->state.deviceId != context.deviceId ||
        impl_->state.source != context.source) {
        return impl_->reject(MoonlightControllerStatus::NotActive,
                             MoonlightInputDispatchStatus::InvalidState);
    }
    if (impl_->state.sourceGeneration != context.sourceGeneration) {
        return impl_->reject(MoonlightControllerStatus::FlushRequired,
                             MoonlightInputDispatchStatus::InvalidState);
    }
    ControllerState candidate = impl_->state;
    const ObserveStatus observed = observe(candidate, context);
    if (observed != ObserveStatus::Ready) {
        const MoonlightControllerResult result = observeResult(observed);
        return impl_->reject(result.status, result.dispatchStatus);
    }
    candidate.active = false;
    candidate.deviceId = 0U;
    candidate.source = MoonlightInputSource::Invalid;
    candidate.sourceGeneration = 0U;
    candidate.profile = {};
    candidate.mapped = {};
    candidate.stateFrames = saturatingIncrement(candidate.stateFrames);
    candidate.neutralFrames = saturatingIncrement(candidate.neutralFrames);
    candidate.removals = saturatingIncrement(candidate.removals);
    retireObservedLane(candidate, context);
    return impl_->dispatch(context, stateCommand({}, false),
                           std::move(candidate), true);
}

bool MoonlightControllerMapper::discardLocalState(
    const MoonlightInputIdentity& identity) noexcept {
    if (impl_ == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (identity != impl_->identity) {
        return false;
    }
    const std::uint64_t localOnlyUpdates =
        saturatingIncrement(impl_->state.localOnlyUpdates);
    impl_->state = {};
    impl_->state.localOnlyUpdates = localOnlyUpdates;
    return true;
}

MoonlightControllerSnapshot MoonlightControllerMapper::snapshot(
    const MoonlightInputIdentity& identity) const noexcept {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    MoonlightControllerSnapshot snapshot;
    snapshot.identity = impl_->identity;
    if (identity != impl_->identity) {
        return snapshot;
    }
    snapshot.matched = true;
    snapshot.active = impl_->state.active;
    snapshot.controllerNumber = 0U;
    snapshot.deviceId = impl_->state.deviceId;
    snapshot.source = impl_->state.source;
    snapshot.sourceGeneration = impl_->state.sourceGeneration;
    snapshot.profile = impl_->state.profile;
    snapshot.state = impl_->state.mapped;
    snapshot.observedLanes = observedLaneCount(impl_->state);
    snapshot.arrivals = impl_->state.arrivals;
    snapshot.stateFrames = impl_->state.stateFrames;
    snapshot.neutralFrames = impl_->state.neutralFrames;
    snapshot.removals = impl_->state.removals;
    snapshot.localOnlyUpdates = impl_->state.localOnlyUpdates;
    snapshot.rejectedEvents = impl_->state.rejectedEvents;
    return snapshot;
}

} // namespace remotedesk::moonlight
