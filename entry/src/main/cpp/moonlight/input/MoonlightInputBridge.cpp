#include "moonlight/input/MoonlightInputBridge.h"

#include "render/video_perf_counters.h"

#include <algorithm>
#include <array>
#include <limits>
#include <mutex>
#include <utility>

namespace remotedesk::moonlight {
namespace {

Render::DecoderSessionIdentity decoderOwner(const MoonlightInputIdentity& identity) noexcept {
    return {identity.key.sessionId, identity.key.generation, identity.key.ownerToken};
}

std::uint64_t saturatingIncrement(std::uint64_t value) noexcept {
    return value == std::numeric_limits<std::uint64_t>::max() ? value : value + 1U;
}

MoonlightInputControlResult controlResult(MoonlightInputControlStatus status,
                                           const MoonlightInputIdentity& identity,
                                           std::uint64_t operationGeneration) noexcept {
    return {status, identity, operationGeneration};
}

bool knownSource(MoonlightInputSource source) noexcept {
    switch (source) {
        case MoonlightInputSource::PhysicalKeyboard:
        case MoonlightInputSource::OnScreenKeyboard:
        case MoonlightInputSource::Mouse:
        case MoonlightInputSource::Touchscreen:
        case MoonlightInputSource::Touchpad:
        case MoonlightInputSource::GameController:
        case MoonlightInputSource::VirtualController:
            return true;
        case MoonlightInputSource::Invalid:
            return false;
    }
    return false;
}

bool knownKind(MoonlightInputCommandKind kind) noexcept {
    switch (kind) {
        case MoonlightInputCommandKind::Keyboard:
        case MoonlightInputCommandKind::Text:
        case MoonlightInputCommandKind::RelativePointer:
        case MoonlightInputCommandKind::AbsolutePointer:
        case MoonlightInputCommandKind::PointerButton:
        case MoonlightInputCommandKind::VerticalScroll:
        case MoonlightInputCommandKind::HorizontalScroll:
        case MoonlightInputCommandKind::Touch:
        case MoonlightInputCommandKind::Controller:
            return true;
        case MoonlightInputCommandKind::Invalid:
            return false;
    }
    return false;
}

bool pointerKind(MoonlightInputCommandKind kind) noexcept {
    return kind == MoonlightInputCommandKind::RelativePointer ||
        kind == MoonlightInputCommandKind::AbsolutePointer ||
        kind == MoonlightInputCommandKind::PointerButton ||
        kind == MoonlightInputCommandKind::VerticalScroll ||
        kind == MoonlightInputCommandKind::HorizontalScroll;
}

bool sourceSupportsKind(MoonlightInputSource source,
                        MoonlightInputCommandKind kind) noexcept {
    switch (source) {
        case MoonlightInputSource::PhysicalKeyboard:
        case MoonlightInputSource::OnScreenKeyboard:
            return kind == MoonlightInputCommandKind::Keyboard ||
                kind == MoonlightInputCommandKind::Text;
        case MoonlightInputSource::Mouse:
            return pointerKind(kind);
        case MoonlightInputSource::Touchscreen:
            return kind == MoonlightInputCommandKind::Touch ||
                kind == MoonlightInputCommandKind::AbsolutePointer ||
                kind == MoonlightInputCommandKind::PointerButton;
        case MoonlightInputSource::Touchpad:
            return pointerKind(kind) || kind == MoonlightInputCommandKind::Touch;
        case MoonlightInputSource::GameController:
        case MoonlightInputSource::VirtualController:
            return kind == MoonlightInputCommandKind::Controller;
        case MoonlightInputSource::Invalid:
            return false;
    }
    return false;
}

class ProbeOperation final : public MoonlightInputOwnedOperation {
  public:
    void execute() noexcept override {
        if (!executed) {
            executed = true;
        }
    }

    bool executed = false;
};

class SendOperation final : public MoonlightInputOwnedOperation {
  public:
    SendOperation(MoonlightInputPort& valuePort,
                  const MoonlightInputEvent& valueEvent) noexcept
        : port(valuePort), event(valueEvent) {}

    void execute() noexcept override {
        if (executed) {
            return;
        }
        executed = true;
        result = port.send(event);
    }

    bool terminalRelease() const noexcept override {
        return event.lifecycleRelease;
    }

    MoonlightInputPort& port;
    const MoonlightInputEvent& event;
    MoonlightInputPortStatus result = MoonlightInputPortStatus::Failed;
    bool executed = false;
};

class FlushOperation final : public MoonlightInputOwnedOperation {
  public:
    FlushOperation(MoonlightInputPort& valuePort,
                   const MoonlightInputFlushRequest& valueRequest) noexcept
        : port(valuePort), request(valueRequest) {}

    void execute() noexcept override {
        if (executed) {
            return;
        }
        executed = true;
        result = port.flushNeutral(request);
    }

    bool terminalRelease() const noexcept override {
        return request.reason == MoonlightInputSuspendReason::Stop;
    }

    MoonlightInputPort& port;
    const MoonlightInputFlushRequest& request;
    bool result = false;
    bool executed = false;
};

class RecoveryResetOperation final : public MoonlightInputOwnedOperation {
  public:
    RecoveryResetOperation(
        MoonlightInputPort& valuePort,
        const MoonlightInputRecoveryResetRequest& valueRequest) noexcept
        : port(valuePort), request(valueRequest) {}

    void execute() noexcept override {
        if (executed) { return; }
        executed = true;
        result = port.resetRemoteState(request);
    }

    MoonlightInputPort& port;
    const MoonlightInputRecoveryResetRequest& request;
    MoonlightInputPortStatus result = MoonlightInputPortStatus::Failed;
    bool executed = false;
};

class ExactInputOwnerGate final : public MoonlightInputOwnerGate {
  public:
    ExactInputOwnerGate(MoonlightSessionOwner& valueSessionOwner,
                        Render::SessionSinkOwnerLease& valueSharedOwner) noexcept
        : sessionOwner_(valueSessionOwner), sharedOwner_(valueSharedOwner) {}

    bool withOwner(const MoonlightInputIdentity& identity,
                   MoonlightInputOwnedOperation& operation) noexcept override {
        if (!identity.valid()) {
            return false;
        }
        const auto snapshot = sessionOwner_.snapshot(identity.key);
        const bool normalOwner = snapshot.matched &&
            (snapshot.phase == MoonlightSessionPhase::Starting ||
             snapshot.phase == MoonlightSessionPhase::Running) &&
            !snapshot.cancellationRequested && snapshot.admissionOpen;
        const bool terminalOwner = snapshot.matched &&
            snapshot.phase == MoonlightSessionPhase::Stopping &&
            snapshot.cancellationRequested && !snapshot.admissionOpen &&
            operation.terminalRelease();
        if (!normalOwner && !terminalOwner) {
            return false;
        }
        // Cross-protocol lease comes first. A renderer/session transition can
        // then wait for this short input enqueue without a Moonlight callback
        // lease waiting back on the shared exclusive side.
        auto sharedLease = sharedOwner_.acquire(decoderOwner(identity));
        if (!sharedLease) {
            return false;
        }
        if (terminalOwner) {
            operation.execute();
            return true;
        }
        auto callbackLease = sessionOwner_.acquireCallback(identity.key);
        if (!callbackLease.valid()) {
            return false;
        }
        operation.execute();
        return true;
    }

  private:
    MoonlightSessionOwner& sessionOwner_;
    Render::SessionSinkOwnerLease& sharedOwner_;
};

struct SourceLane final {
    bool occupied = false;
    std::uint64_t deviceId = 0U;
    MoonlightInputSource source = MoonlightInputSource::Invalid;
    std::uint64_t sourceGeneration = 0U;
    std::uint64_t lastSequence = 0U;
    std::uint64_t lastTimestampUs = 0U;
};

} // namespace

struct MoonlightInputBridge::Impl final {
    Impl(std::shared_ptr<MoonlightInputOwnerGate> valueGate,
         std::shared_ptr<MoonlightInputPort> valuePort,
         MoonlightInputLimits valueLimits) noexcept
        : ownerGate(std::move(valueGate)), port(std::move(valuePort)), limits(valueLimits) {}

    bool ownerAvailable(const MoonlightInputIdentity& requested) noexcept {
        if (ownerGate == nullptr) {
            return false;
        }
        ProbeOperation operation;
        return ownerGate->withOwner(requested, operation) && operation.executed;
    }

    SourceLane* findLane(const MoonlightInputEvent& event) noexcept {
        for (std::size_t index = 0U; index < limits.sourceLaneCapacity; ++index) {
            SourceLane& lane = sourceLanes[index];
            if (lane.occupied && lane.deviceId == event.deviceId && lane.source == event.source) {
                return &lane;
            }
        }
        return nullptr;
    }

    SourceLane* freeLane() noexcept {
        for (std::size_t index = 0U; index < limits.sourceLaneCapacity; ++index) {
            if (!sourceLanes[index].occupied) {
                return &sourceLanes[index];
            }
        }
        return nullptr;
    }

    std::size_t occupiedLanes() const noexcept {
        std::size_t result = 0U;
        for (std::size_t index = 0U; index < limits.sourceLaneCapacity; ++index) {
            result += sourceLanes[index].occupied ? 1U : 0U;
        }
        return result;
    }

    void resetSessionCounters() noexcept {
        sourceLanes = {};
        lastBoundaryTimestampUs = 0U;
        latestEventTimestampUs = 0U;
        acceptedEvents = 0U;
        duplicateEvents = 0U;
        staleEvents = 0U;
        invalidEvents = 0U;
        ownerRejectedEvents = 0U;
        backpressureEvents = 0U;
        unsupportedEvents = 0U;
        portFailures = 0U;
        neutralFlushes = 0U;
        neutralFlushFailures = 0U;
        lastRecoveryResetGeneration = 0U;
        recoveryResets = 0U;
        recoveryResetBackpressure = 0U;
        recoveryResetFailures = 0U;
    }

    bool identityIsNewer(const MoonlightInputIdentity& requested) const noexcept {
        if (!highWaterIdentity.valid()) {
            return true;
        }
        if (requested.key.ownerToken > highWaterIdentity.key.ownerToken) {
            return true;
        }
        return requested.key.ownerToken == highWaterIdentity.key.ownerToken &&
            requested.key.sessionId == highWaterIdentity.key.sessionId &&
            requested.key.generation == highWaterIdentity.key.generation &&
            requested.inputGeneration > highWaterIdentity.inputGeneration;
    }

    mutable std::mutex mutex;
    std::shared_ptr<MoonlightInputOwnerGate> ownerGate;
    std::shared_ptr<MoonlightInputPort> port;
    MoonlightInputLimits limits{};
    std::array<SourceLane, kMoonlightMaximumInputSourceLanes> sourceLanes{};
    MoonlightInputIdentity identity{};
    MoonlightInputIdentity lastCleanedIdentity{};
    MoonlightInputIdentity highWaterIdentity{};
    MoonlightInputState state = MoonlightInputState::Idle;
    MoonlightInputSuspendReason suspendReason = MoonlightInputSuspendReason::None;
    std::uint64_t lastOperationGeneration = 0U;
    std::uint64_t lastBoundaryTimestampUs = 0U;
    std::uint64_t latestEventTimestampUs = 0U;
    std::uint64_t acceptedEvents = 0U;
    std::uint64_t duplicateEvents = 0U;
    std::uint64_t staleEvents = 0U;
    std::uint64_t invalidEvents = 0U;
    std::uint64_t ownerRejectedEvents = 0U;
    std::uint64_t backpressureEvents = 0U;
    std::uint64_t unsupportedEvents = 0U;
    std::uint64_t portFailures = 0U;
    std::uint64_t neutralFlushes = 0U;
    std::uint64_t neutralFlushFailures = 0U;
    std::uint64_t lastRecoveryResetGeneration = 0U;
    std::uint64_t recoveryResets = 0U;
    std::uint64_t recoveryResetBackpressure = 0U;
    std::uint64_t recoveryResetFailures = 0U;
};

MoonlightInputBridge::MoonlightInputBridge(std::unique_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}

MoonlightInputBridge::~MoonlightInputBridge() {
    if (impl_ == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if ((impl_->state == MoonlightInputState::Active ||
         impl_->state == MoonlightInputState::Suspended ||
         impl_->state == MoonlightInputState::ReleasePending) &&
        impl_->identity.valid() && impl_->port != nullptr && impl_->ownerGate != nullptr) {
        const std::uint64_t latest = std::max(impl_->latestEventTimestampUs,
                                              impl_->lastBoundaryTimestampUs);
        const std::uint64_t boundary = saturatingIncrement(latest);
        MoonlightInputFlushRequest request{impl_->identity,
                                           MoonlightInputSuspendReason::Stop,
                                           saturatingIncrement(impl_->lastOperationGeneration),
                                           boundary};
        FlushOperation operation(*impl_->port, request);
        (void)impl_->ownerGate->withOwner(impl_->identity, operation);
    }
    impl_->identity = {};
    impl_->sourceLanes = {};
    impl_->state = MoonlightInputState::Cleaned;
    impl_->suspendReason = MoonlightInputSuspendReason::None;
}

std::shared_ptr<MoonlightInputBridge> MoonlightInputBridge::create(
    std::shared_ptr<MoonlightInputOwnerGate> ownerGate,
    std::shared_ptr<MoonlightInputPort> port,
    MoonlightInputLimits limits) noexcept {
    if (ownerGate == nullptr || port == nullptr || limits.sourceLaneCapacity == 0U ||
        limits.sourceLaneCapacity > kMoonlightMaximumInputSourceLanes ||
        limits.maximumPayloadBytes == 0U ||
        limits.maximumPayloadBytes > kMoonlightMaximumInputPayloadBytes) {
        return nullptr;
    }
    try {
        return std::shared_ptr<MoonlightInputBridge>(new MoonlightInputBridge(
            std::make_unique<Impl>(std::move(ownerGate), std::move(port), limits)));
    } catch (...) {
        return nullptr;
    }
}

MoonlightInputControlResult MoonlightInputBridge::activate(
    const MoonlightInputIdentity& requested,
    std::uint64_t operationGeneration) noexcept {
    if (impl_ == nullptr || !requested.valid() || operationGeneration == 0U) {
        return controlResult(MoonlightInputControlStatus::InvalidRequest, requested,
                             operationGeneration);
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->identity == requested && impl_->state == MoonlightInputState::Active) {
        if (operationGeneration < impl_->lastOperationGeneration) {
            return controlResult(MoonlightInputControlStatus::Stale, requested,
                                 operationGeneration);
        }
        impl_->lastOperationGeneration = operationGeneration;
        return controlResult(MoonlightInputControlStatus::AlreadyApplied, requested,
                             operationGeneration);
    }
    if (impl_->state == MoonlightInputState::Active ||
        impl_->state == MoonlightInputState::Suspended ||
        impl_->state == MoonlightInputState::ReleasePending ||
        impl_->state == MoonlightInputState::Stopped) {
        return controlResult(MoonlightInputControlStatus::InvalidState, requested,
                             operationGeneration);
    }
    if (!impl_->identityIsNewer(requested)) {
        return controlResult(MoonlightInputControlStatus::Stale, requested,
                             operationGeneration);
    }
    if (!impl_->ownerAvailable(requested)) {
        return controlResult(MoonlightInputControlStatus::OwnerUnavailable, requested,
                             operationGeneration);
    }
    impl_->identity = requested;
    impl_->highWaterIdentity = requested;
    impl_->state = MoonlightInputState::Active;
    impl_->suspendReason = MoonlightInputSuspendReason::None;
    impl_->lastOperationGeneration = operationGeneration;
    impl_->resetSessionCounters();
    return controlResult(MoonlightInputControlStatus::Applied, requested,
                         operationGeneration);
}

MoonlightInputControlResult MoonlightInputBridge::resetRemoteState(
    const MoonlightInputRecoveryResetRequest& request) noexcept {
    if (impl_ == nullptr || !request.valid()) {
        return controlResult(MoonlightInputControlStatus::InvalidRequest,
                             request.identity, request.operationGeneration);
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->identity != request.identity) {
        return controlResult(MoonlightInputControlStatus::Stale,
                             request.identity, request.operationGeneration);
    }
    if (impl_->state != MoonlightInputState::Active) {
        return controlResult(MoonlightInputControlStatus::InvalidState,
                             request.identity, request.operationGeneration);
    }
    if (request.operationGeneration < impl_->lastOperationGeneration) {
        return controlResult(MoonlightInputControlStatus::Stale,
                             request.identity, request.operationGeneration);
    }
    if (impl_->lastRecoveryResetGeneration == request.operationGeneration) {
        return controlResult(MoonlightInputControlStatus::AlreadyApplied,
                             request.identity, request.operationGeneration);
    }
    if (impl_->ownerGate == nullptr || impl_->port == nullptr) {
        impl_->recoveryResetFailures =
            saturatingIncrement(impl_->recoveryResetFailures);
        return controlResult(MoonlightInputControlStatus::PortFailure,
                             request.identity, request.operationGeneration);
    }
    RecoveryResetOperation operation(*impl_->port, request);
    const bool owned = impl_->ownerGate->withOwner(request.identity, operation);
    if (!owned || !operation.executed) {
        return controlResult(MoonlightInputControlStatus::OwnerUnavailable,
                             request.identity, request.operationGeneration);
    }
    if (operation.result == MoonlightInputPortStatus::Accepted) {
        impl_->lastOperationGeneration = request.operationGeneration;
        impl_->lastRecoveryResetGeneration = request.operationGeneration;
        impl_->recoveryResets = saturatingIncrement(impl_->recoveryResets);
        return controlResult(MoonlightInputControlStatus::Applied,
                             request.identity, request.operationGeneration);
    }
    if (operation.result == MoonlightInputPortStatus::Backpressure) {
        impl_->recoveryResetBackpressure =
            saturatingIncrement(impl_->recoveryResetBackpressure);
    } else {
        impl_->recoveryResetFailures =
            saturatingIncrement(impl_->recoveryResetFailures);
    }
    return controlResult(MoonlightInputControlStatus::PortFailure,
                         request.identity, request.operationGeneration);
}

MoonlightInputDispatchStatus MoonlightInputBridge::dispatch(
    const MoonlightInputEvent& event) noexcept {
    if (impl_ == nullptr) {
        return MoonlightInputDispatchStatus::InvalidRequest;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    const bool validEnvelope = event.identity.valid() && event.deviceId != 0U &&
        knownSource(event.source) && event.sourceGeneration != 0U &&
        event.sourceSequence != 0U && event.monotonicTimestampUs != 0U &&
        knownKind(event.kind) && sourceSupportsKind(event.source, event.kind) &&
        event.commandVersion == 1U && event.payloadSize != 0U &&
        event.payloadSize <= impl_->limits.maximumPayloadBytes;
    bool zeroTail = validEnvelope;
    if (zeroTail) {
        for (std::size_t index = event.payloadSize; index < event.payload.size(); ++index) {
            if (event.payload[index] != 0U) {
                zeroTail = false;
                break;
            }
        }
    }
    if (!validEnvelope || !zeroTail) {
        impl_->invalidEvents = saturatingIncrement(impl_->invalidEvents);
        return MoonlightInputDispatchStatus::InvalidRequest;
    }
    if (impl_->identity != event.identity) {
        impl_->ownerRejectedEvents = saturatingIncrement(impl_->ownerRejectedEvents);
        return MoonlightInputDispatchStatus::StaleOwner;
    }
    const bool activeAdmission = impl_->state == MoonlightInputState::Active;
    const bool releaseAdmission =
        impl_->state == MoonlightInputState::ReleasePending &&
        event.lifecycleRelease &&
        event.monotonicTimestampUs <= impl_->lastBoundaryTimestampUs;
    if (!activeAdmission && !releaseAdmission) {
        return MoonlightInputDispatchStatus::InvalidState;
    }
    if (activeAdmission && event.monotonicTimestampUs <= impl_->lastBoundaryTimestampUs) {
        impl_->staleEvents = saturatingIncrement(impl_->staleEvents);
        return MoonlightInputDispatchStatus::StaleEvent;
    }

    SourceLane* lane = impl_->findLane(event);
    SourceLane* target = lane;
    if (lane != nullptr) {
        if (event.sourceGeneration < lane->sourceGeneration) {
            impl_->staleEvents = saturatingIncrement(impl_->staleEvents);
            return MoonlightInputDispatchStatus::StaleEvent;
        }
        if (event.sourceGeneration == lane->sourceGeneration) {
            if (event.sourceSequence == lane->lastSequence) {
                impl_->duplicateEvents = saturatingIncrement(impl_->duplicateEvents);
                return MoonlightInputDispatchStatus::Duplicate;
            }
            if (event.sourceSequence < lane->lastSequence ||
                event.monotonicTimestampUs < lane->lastTimestampUs) {
                impl_->staleEvents = saturatingIncrement(impl_->staleEvents);
                return MoonlightInputDispatchStatus::StaleEvent;
            }
        } else if (event.monotonicTimestampUs < lane->lastTimestampUs) {
            impl_->staleEvents = saturatingIncrement(impl_->staleEvents);
            return MoonlightInputDispatchStatus::StaleEvent;
        }
    } else {
        target = impl_->freeLane();
        if (target == nullptr) {
            impl_->backpressureEvents = saturatingIncrement(impl_->backpressureEvents);
            return MoonlightInputDispatchStatus::SourceCapacity;
        }
    }

    if (impl_->ownerGate == nullptr || impl_->port == nullptr) {
        impl_->portFailures = saturatingIncrement(impl_->portFailures);
        return MoonlightInputDispatchStatus::PortFailure;
    }
    SendOperation operation(*impl_->port, event);
    const bool owned = impl_->ownerGate->withOwner(event.identity, operation);
    if (!owned || !operation.executed) {
        impl_->ownerRejectedEvents = saturatingIncrement(impl_->ownerRejectedEvents);
        return MoonlightInputDispatchStatus::StaleOwner;
    }
    switch (operation.result) {
        case MoonlightInputPortStatus::Accepted:
            target->occupied = true;
            target->deviceId = event.deviceId;
            target->source = event.source;
            target->sourceGeneration = event.sourceGeneration;
            target->lastSequence = event.sourceSequence;
            target->lastTimestampUs = event.monotonicTimestampUs;
            impl_->latestEventTimestampUs =
                std::max(impl_->latestEventTimestampUs, event.monotonicTimestampUs);
            impl_->acceptedEvents = saturatingIncrement(impl_->acceptedEvents);
            return MoonlightInputDispatchStatus::Accepted;
        case MoonlightInputPortStatus::Backpressure:
            impl_->backpressureEvents = saturatingIncrement(impl_->backpressureEvents);
            return MoonlightInputDispatchStatus::Backpressure;
        case MoonlightInputPortStatus::Unsupported:
            impl_->unsupportedEvents = saturatingIncrement(impl_->unsupportedEvents);
            return MoonlightInputDispatchStatus::Unsupported;
        case MoonlightInputPortStatus::Failed:
            impl_->portFailures = saturatingIncrement(impl_->portFailures);
            return MoonlightInputDispatchStatus::PortFailure;
    }
    impl_->portFailures = saturatingIncrement(impl_->portFailures);
    return MoonlightInputDispatchStatus::PortFailure;
}

MoonlightInputControlResult MoonlightInputBridge::beginFlush(
    const MoonlightInputFlushRequest& request) noexcept {
    if (impl_ == nullptr || !request.identity.valid() ||
        request.reason == MoonlightInputSuspendReason::None ||
        request.operationGeneration == 0U || request.monotonicTimestampUs == 0U) {
        return controlResult(MoonlightInputControlStatus::InvalidRequest,
                             request.identity, request.operationGeneration);
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->identity != request.identity) {
        return controlResult(MoonlightInputControlStatus::Stale, request.identity,
                             request.operationGeneration);
    }
    const bool exactPrepared =
        impl_->state == MoonlightInputState::ReleasePending &&
        impl_->suspendReason == request.reason &&
        impl_->lastOperationGeneration == request.operationGeneration &&
        impl_->lastBoundaryTimestampUs == request.monotonicTimestampUs;
    if (exactPrepared) {
        return controlResult(MoonlightInputControlStatus::AlreadyApplied,
                             request.identity, request.operationGeneration);
    }
    const bool terminalUpgrade =
        impl_->state == MoonlightInputState::ReleasePending &&
        impl_->suspendReason == MoonlightInputSuspendReason::FocusLost &&
        request.reason == MoonlightInputSuspendReason::Stop;
    const bool terminalFromSuspended =
        impl_->state == MoonlightInputState::Suspended &&
        impl_->suspendReason == MoonlightInputSuspendReason::FocusLost &&
        request.reason == MoonlightInputSuspendReason::Stop;
    if (impl_->state != MoonlightInputState::Active && !terminalUpgrade &&
        !terminalFromSuspended) {
        return controlResult(MoonlightInputControlStatus::InvalidState,
                             request.identity, request.operationGeneration);
    }
    if (request.operationGeneration <= impl_->lastOperationGeneration ||
        request.monotonicTimestampUs < impl_->lastBoundaryTimestampUs ||
        request.monotonicTimestampUs < impl_->latestEventTimestampUs) {
        return controlResult(MoonlightInputControlStatus::Stale, request.identity,
                             request.operationGeneration);
    }
    impl_->state = MoonlightInputState::ReleasePending;
    impl_->suspendReason = request.reason;
    impl_->lastOperationGeneration = request.operationGeneration;
    impl_->lastBoundaryTimestampUs = request.monotonicTimestampUs;
    return controlResult(MoonlightInputControlStatus::Applied, request.identity,
                         request.operationGeneration);
}

MoonlightInputControlResult MoonlightInputBridge::focusLost(
    const MoonlightInputIdentity& requested,
    std::uint64_t operationGeneration,
    std::uint64_t monotonicTimestampUs) noexcept {
    if (impl_ == nullptr || !requested.valid() || operationGeneration == 0U ||
        monotonicTimestampUs == 0U) {
        return controlResult(MoonlightInputControlStatus::InvalidRequest, requested,
                             operationGeneration);
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->identity != requested) {
        return controlResult(MoonlightInputControlStatus::Stale, requested,
                             operationGeneration);
    }
    if (operationGeneration < impl_->lastOperationGeneration ||
        monotonicTimestampUs < impl_->lastBoundaryTimestampUs ||
        monotonicTimestampUs < impl_->latestEventTimestampUs) {
        return controlResult(MoonlightInputControlStatus::Stale, requested,
                             operationGeneration);
    }
    if (impl_->state == MoonlightInputState::Suspended &&
        impl_->suspendReason == MoonlightInputSuspendReason::FocusLost) {
        impl_->lastOperationGeneration = operationGeneration;
        impl_->lastBoundaryTimestampUs =
            std::max(impl_->lastBoundaryTimestampUs, monotonicTimestampUs);
        return controlResult(MoonlightInputControlStatus::AlreadyApplied, requested,
                             operationGeneration);
    }
    const bool prepared = impl_->state == MoonlightInputState::ReleasePending &&
        impl_->suspendReason == MoonlightInputSuspendReason::FocusLost;
    if (impl_->state != MoonlightInputState::Active && !prepared) {
        return controlResult(MoonlightInputControlStatus::InvalidState, requested,
                             operationGeneration);
    }
    if (operationGeneration == impl_->lastOperationGeneration && !prepared) {
        return controlResult(MoonlightInputControlStatus::Stale, requested,
                             operationGeneration);
    }
    impl_->state = MoonlightInputState::ReleasePending;
    impl_->suspendReason = MoonlightInputSuspendReason::FocusLost;
    impl_->lastOperationGeneration = operationGeneration;
    impl_->lastBoundaryTimestampUs =
        std::max(impl_->lastBoundaryTimestampUs, monotonicTimestampUs);
    const MoonlightInputFlushRequest request{requested,
                                             MoonlightInputSuspendReason::FocusLost,
                                             operationGeneration,
                                             monotonicTimestampUs};
    FlushOperation operation(*impl_->port, request);
    const bool owned = impl_->ownerGate->withOwner(requested, operation);
    if (!owned || !operation.executed) {
        impl_->neutralFlushFailures = saturatingIncrement(impl_->neutralFlushFailures);
        return controlResult(MoonlightInputControlStatus::OwnerUnavailable, requested,
                             operationGeneration);
    }
    if (!operation.result) {
        impl_->neutralFlushFailures = saturatingIncrement(impl_->neutralFlushFailures);
        return controlResult(MoonlightInputControlStatus::PortFailure, requested,
                             operationGeneration);
    }
    impl_->neutralFlushes = saturatingIncrement(impl_->neutralFlushes);
    impl_->state = MoonlightInputState::Suspended;
    return controlResult(MoonlightInputControlStatus::Applied, requested,
                         operationGeneration);
}

MoonlightInputControlResult MoonlightInputBridge::resume(
    const MoonlightInputIdentity& requested,
    std::uint64_t operationGeneration) noexcept {
    if (impl_ == nullptr || !requested.valid() || operationGeneration == 0U) {
        return controlResult(MoonlightInputControlStatus::InvalidRequest, requested,
                             operationGeneration);
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->identity != requested || operationGeneration < impl_->lastOperationGeneration) {
        return controlResult(MoonlightInputControlStatus::Stale, requested,
                             operationGeneration);
    }
    if (impl_->state == MoonlightInputState::Active) {
        impl_->lastOperationGeneration = operationGeneration;
        return controlResult(MoonlightInputControlStatus::AlreadyApplied, requested,
                             operationGeneration);
    }
    if (impl_->state != MoonlightInputState::Suspended ||
        impl_->suspendReason != MoonlightInputSuspendReason::FocusLost) {
        return controlResult(MoonlightInputControlStatus::InvalidState, requested,
                             operationGeneration);
    }
    if (operationGeneration == impl_->lastOperationGeneration) {
        return controlResult(MoonlightInputControlStatus::Stale, requested,
                             operationGeneration);
    }
    if (!impl_->ownerAvailable(requested)) {
        return controlResult(MoonlightInputControlStatus::OwnerUnavailable, requested,
                             operationGeneration);
    }
    impl_->state = MoonlightInputState::Active;
    impl_->suspendReason = MoonlightInputSuspendReason::None;
    impl_->lastOperationGeneration = operationGeneration;
    return controlResult(MoonlightInputControlStatus::Applied, requested,
                         operationGeneration);
}

MoonlightInputControlResult MoonlightInputBridge::stop(
    const MoonlightInputIdentity& requested,
    std::uint64_t operationGeneration,
    std::uint64_t monotonicTimestampUs) noexcept {
    if (impl_ == nullptr || !requested.valid() || operationGeneration == 0U ||
        monotonicTimestampUs == 0U) {
        return controlResult(MoonlightInputControlStatus::InvalidRequest, requested,
                             operationGeneration);
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->identity != requested || operationGeneration < impl_->lastOperationGeneration ||
        monotonicTimestampUs < impl_->lastBoundaryTimestampUs ||
        monotonicTimestampUs < impl_->latestEventTimestampUs) {
        return controlResult(MoonlightInputControlStatus::Stale, requested,
                             operationGeneration);
    }
    if (impl_->state == MoonlightInputState::Stopped) {
        impl_->lastOperationGeneration = operationGeneration;
        impl_->lastBoundaryTimestampUs =
            std::max(impl_->lastBoundaryTimestampUs, monotonicTimestampUs);
        return controlResult(MoonlightInputControlStatus::AlreadyApplied, requested,
                             operationGeneration);
    }
    const bool prepared = impl_->state == MoonlightInputState::ReleasePending &&
        impl_->suspendReason == MoonlightInputSuspendReason::Stop;
    if (impl_->state != MoonlightInputState::Active &&
        impl_->state != MoonlightInputState::Suspended &&
        !prepared) {
        return controlResult(MoonlightInputControlStatus::InvalidState, requested,
                             operationGeneration);
    }
    if (operationGeneration == impl_->lastOperationGeneration && !prepared) {
        return controlResult(MoonlightInputControlStatus::Stale, requested,
                             operationGeneration);
    }
    impl_->state = MoonlightInputState::ReleasePending;
    impl_->suspendReason = MoonlightInputSuspendReason::Stop;
    impl_->lastOperationGeneration = operationGeneration;
    impl_->lastBoundaryTimestampUs =
        std::max(impl_->lastBoundaryTimestampUs, monotonicTimestampUs);
    const MoonlightInputFlushRequest request{requested,
                                             MoonlightInputSuspendReason::Stop,
                                             operationGeneration,
                                             monotonicTimestampUs};
    FlushOperation operation(*impl_->port, request);
    const bool owned = impl_->ownerGate->withOwner(requested, operation);
    if (!owned || !operation.executed) {
        impl_->neutralFlushFailures = saturatingIncrement(impl_->neutralFlushFailures);
        return controlResult(MoonlightInputControlStatus::OwnerUnavailable, requested,
                             operationGeneration);
    }
    if (!operation.result) {
        impl_->neutralFlushFailures = saturatingIncrement(impl_->neutralFlushFailures);
        return controlResult(MoonlightInputControlStatus::PortFailure, requested,
                             operationGeneration);
    }
    impl_->neutralFlushes = saturatingIncrement(impl_->neutralFlushes);
    impl_->state = MoonlightInputState::Stopped;
    return controlResult(MoonlightInputControlStatus::Applied, requested,
                         operationGeneration);
}

MoonlightInputControlResult MoonlightInputBridge::stopLocally(
    const MoonlightInputIdentity& requested,
    std::uint64_t operationGeneration,
    std::uint64_t monotonicTimestampUs) noexcept {
    if (impl_ == nullptr || !requested.valid() || operationGeneration == 0U ||
        monotonicTimestampUs == 0U) {
        return controlResult(MoonlightInputControlStatus::InvalidRequest, requested,
                             operationGeneration);
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->identity != requested ||
        operationGeneration < impl_->lastOperationGeneration ||
        monotonicTimestampUs < impl_->lastBoundaryTimestampUs) {
        return controlResult(MoonlightInputControlStatus::Stale, requested,
                             operationGeneration);
    }
    if (impl_->state == MoonlightInputState::Stopped) {
        impl_->lastOperationGeneration = operationGeneration;
        impl_->lastBoundaryTimestampUs = monotonicTimestampUs;
        return controlResult(MoonlightInputControlStatus::AlreadyApplied, requested,
                             operationGeneration);
    }
    if (impl_->state != MoonlightInputState::Active &&
        impl_->state != MoonlightInputState::Suspended &&
        impl_->state != MoonlightInputState::ReleasePending) {
        return controlResult(MoonlightInputControlStatus::InvalidState, requested,
                             operationGeneration);
    }
    impl_->sourceLanes = {};
    impl_->state = MoonlightInputState::Stopped;
    impl_->suspendReason = MoonlightInputSuspendReason::Stop;
    impl_->lastOperationGeneration = operationGeneration;
    impl_->lastBoundaryTimestampUs = monotonicTimestampUs;
    return controlResult(MoonlightInputControlStatus::Applied, requested,
                         operationGeneration);
}

MoonlightInputControlResult MoonlightInputBridge::cleanup(
    const MoonlightInputIdentity& requested,
    std::uint64_t operationGeneration) noexcept {
    if (impl_ == nullptr || !requested.valid() || operationGeneration == 0U) {
        return controlResult(MoonlightInputControlStatus::InvalidRequest, requested,
                             operationGeneration);
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->identity != requested) {
        if (impl_->state == MoonlightInputState::Cleaned &&
            impl_->lastCleanedIdentity == requested) {
            if (operationGeneration < impl_->lastOperationGeneration) {
                return controlResult(MoonlightInputControlStatus::Stale, requested,
                                     operationGeneration);
            }
            impl_->lastOperationGeneration = operationGeneration;
            return controlResult(MoonlightInputControlStatus::AlreadyApplied, requested,
                                 operationGeneration);
        }
        return controlResult(MoonlightInputControlStatus::Stale, requested,
                             operationGeneration);
    }
    if (operationGeneration < impl_->lastOperationGeneration) {
        return controlResult(MoonlightInputControlStatus::Stale, requested,
                             operationGeneration);
    }
    if (impl_->state != MoonlightInputState::Stopped) {
        return controlResult(MoonlightInputControlStatus::InvalidState, requested,
                             operationGeneration);
    }
    if (operationGeneration == impl_->lastOperationGeneration) {
        return controlResult(MoonlightInputControlStatus::Stale, requested,
                             operationGeneration);
    }
    impl_->lastCleanedIdentity = impl_->identity;
    impl_->identity = {};
    impl_->sourceLanes = {};
    impl_->state = MoonlightInputState::Cleaned;
    impl_->suspendReason = MoonlightInputSuspendReason::None;
    impl_->lastOperationGeneration = operationGeneration;
    return controlResult(MoonlightInputControlStatus::Applied, requested,
                         operationGeneration);
}

MoonlightInputSnapshot MoonlightInputBridge::snapshot(
    const MoonlightInputIdentity& requested) const noexcept {
    MoonlightInputSnapshot result;
    if (impl_ == nullptr) {
        return result;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    result.matched = requested.valid() && impl_->identity == requested;
    result.identity = result.matched ? impl_->identity : MoonlightInputIdentity{};
    result.state = impl_->state;
    result.suspendReason = impl_->suspendReason;
    result.lastOperationGeneration = impl_->lastOperationGeneration;
    result.lastBoundaryTimestampUs = impl_->lastBoundaryTimestampUs;
    result.sourceLanes = impl_->occupiedLanes();
    result.acceptedEvents = impl_->acceptedEvents;
    result.duplicateEvents = impl_->duplicateEvents;
    result.staleEvents = impl_->staleEvents;
    result.invalidEvents = impl_->invalidEvents;
    result.ownerRejectedEvents = impl_->ownerRejectedEvents;
    result.backpressureEvents = impl_->backpressureEvents;
    result.unsupportedEvents = impl_->unsupportedEvents;
    result.portFailures = impl_->portFailures;
    result.neutralFlushes = impl_->neutralFlushes;
    result.neutralFlushFailures = impl_->neutralFlushFailures;
    result.recoveryResets = impl_->recoveryResets;
    result.recoveryResetBackpressure = impl_->recoveryResetBackpressure;
    result.recoveryResetFailures = impl_->recoveryResetFailures;
    return result;
}

std::shared_ptr<MoonlightInputOwnerGate> createMoonlightInputOwnerGate(
    MoonlightSessionOwner& sessionOwner,
    Render::SessionSinkOwnerLease& sharedOwner) noexcept {
    try {
        return std::make_shared<ExactInputOwnerGate>(sessionOwner, sharedOwner);
    } catch (...) {
        return nullptr;
    }
}

std::shared_ptr<MoonlightInputOwnerGate> createProcessMoonlightInputOwnerGate() noexcept {
    return createMoonlightInputOwnerGate(MoonlightSessionOwner::process(),
                                         Render::SharedSessionSinkOwnerLease());
}

} // namespace remotedesk::moonlight
