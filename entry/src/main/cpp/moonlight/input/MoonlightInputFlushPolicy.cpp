#include "moonlight/input/MoonlightInputFlushPolicy.h"

#include <algorithm>
#include <limits>
#include <mutex>
#include <new>
#include <optional>
#include <utility>

namespace remotedesk::moonlight {
namespace {

std::uint64_t saturatingIncrement(std::uint64_t value) noexcept {
    return value == std::numeric_limits<std::uint64_t>::max() ? value : value + 1U;
}

bool terminalDisposition(MoonlightInputFlushDisposition disposition) noexcept {
    return disposition == MoonlightInputFlushDisposition::Stop;
}

bool sameKeyboardContext(const MoonlightKeyboardEventContext& left,
                         const MoonlightKeyboardEventContext& right) noexcept {
    return left.identity == right.identity && left.deviceId == right.deviceId &&
        left.source == right.source &&
        left.sourceGeneration == right.sourceGeneration &&
        left.sourceSequence == right.sourceSequence &&
        left.monotonicTimestampUs == right.monotonicTimestampUs;
}

bool samePointerContext(const MoonlightPointerEventContext& left,
                        const MoonlightPointerEventContext& right) noexcept {
    return left.identity == right.identity && left.deviceId == right.deviceId &&
        left.source == right.source &&
        left.sourceGeneration == right.sourceGeneration &&
        left.sourceSequence == right.sourceSequence &&
        left.monotonicTimestampUs == right.monotonicTimestampUs;
}

bool sameTouchContext(const MoonlightTouchEventContext& left,
                      const MoonlightTouchEventContext& right) noexcept {
    return left.identity == right.identity && left.deviceId == right.deviceId &&
        left.source == right.source &&
        left.sourceGeneration == right.sourceGeneration &&
        left.sourceSequence == right.sourceSequence &&
        left.monotonicTimestampUs == right.monotonicTimestampUs;
}

bool sameControllerContext(const MoonlightControllerEventContext& left,
                           const MoonlightControllerEventContext& right) noexcept {
    return left.identity == right.identity && left.deviceId == right.deviceId &&
        left.source == right.source &&
        left.sourceGeneration == right.sourceGeneration &&
        left.sourceSequence == right.sourceSequence &&
        left.monotonicTimestampUs == right.monotonicTimestampUs;
}

bool sameContext(const MoonlightInputFlushContext& left,
                 const MoonlightInputFlushContext& right) noexcept {
    return left.identity == right.identity &&
        left.operationGeneration == right.operationGeneration &&
        left.monotonicTimestampUs == right.monotonicTimestampUs &&
        sameTouchContext(left.touch, right.touch) &&
        samePointerContext(left.pointer, right.pointer) &&
        sameKeyboardContext(left.keyboard, right.keyboard) &&
        left.controllerContextPresent == right.controllerContextPresent &&
        (!left.controllerContextPresent ||
         sameControllerContext(left.controller, right.controller));
}

MoonlightInputFlushResult makeResult(
    MoonlightInputFlushStatus status,
    MoonlightInputFlushStage stage,
    MoonlightInputDispatchStatus dispatchStatus,
    bool localReleased,
    bool boundaryApplied,
    bool retryable = false,
    bool remoteReleaseComplete = false) noexcept {
    return {status, stage, dispatchStatus, localReleased, boundaryApplied,
            retryable, remoteReleaseComplete};
}

bool keyboardSuccess(MoonlightKeyboardStatus status) noexcept {
    return status == MoonlightKeyboardStatus::Applied ||
        status == MoonlightKeyboardStatus::AppliedLocally ||
        status == MoonlightKeyboardStatus::AlreadyApplied;
}

bool pointerSuccess(MoonlightPointerStatus status) noexcept {
    return status == MoonlightPointerStatus::Applied ||
        status == MoonlightPointerStatus::AppliedLocally ||
        status == MoonlightPointerStatus::AlreadyApplied;
}

bool touchSuccess(MoonlightTouchStatus status) noexcept {
    return status == MoonlightTouchStatus::Applied ||
        status == MoonlightTouchStatus::AppliedLocally ||
        status == MoonlightTouchStatus::AlreadyApplied;
}

bool controllerSuccess(MoonlightControllerStatus status) noexcept {
    return status == MoonlightControllerStatus::Applied ||
        status == MoonlightControllerStatus::AppliedLocally ||
        status == MoonlightControllerStatus::AlreadyApplied ||
        status == MoonlightControllerStatus::NotActive;
}

bool retryableDispatch(MoonlightInputDispatchStatus status) noexcept {
    return status == MoonlightInputDispatchStatus::Backpressure ||
        status == MoonlightInputDispatchStatus::PortFailure;
}

MoonlightInputSuspendReason bridgeReason(
    MoonlightInputFlushDisposition disposition) noexcept {
    return terminalDisposition(disposition) ? MoonlightInputSuspendReason::Stop :
        MoonlightInputSuspendReason::FocusLost;
}

bool controlSuccess(MoonlightInputControlStatus status) noexcept {
    return status == MoonlightInputControlStatus::Applied ||
        status == MoonlightInputControlStatus::AlreadyApplied;
}

MoonlightInputDispatchStatus controlDispatch(
    MoonlightInputControlStatus status) noexcept {
    switch (status) {
        case MoonlightInputControlStatus::Applied:
        case MoonlightInputControlStatus::AlreadyApplied:
            return MoonlightInputDispatchStatus::Accepted;
        case MoonlightInputControlStatus::InvalidRequest:
            return MoonlightInputDispatchStatus::InvalidRequest;
        case MoonlightInputControlStatus::InvalidState:
            return MoonlightInputDispatchStatus::InvalidState;
        case MoonlightInputControlStatus::Stale:
            return MoonlightInputDispatchStatus::StaleEvent;
        case MoonlightInputControlStatus::OwnerUnavailable:
            return MoonlightInputDispatchStatus::StaleOwner;
        case MoonlightInputControlStatus::PortFailure:
            return MoonlightInputDispatchStatus::PortFailure;
    }
    return MoonlightInputDispatchStatus::PortFailure;
}

} // namespace

MoonlightInputFlushDisposition moonlightInputFlushDisposition(
    MoonlightInputFlushTrigger trigger) noexcept {
    switch (trigger) {
        case MoonlightInputFlushTrigger::OverlayOpened:
        case MoonlightInputFlushTrigger::ControlModeChanged:
        case MoonlightInputFlushTrigger::DisplayRotated:
        case MoonlightInputFlushTrigger::FocusLost:
        case MoonlightInputFlushTrigger::PipEntered:
        case MoonlightInputFlushTrigger::Backgrounded:
        case MoonlightInputFlushTrigger::ScreenLocked:
        case MoonlightInputFlushTrigger::SurfaceDetached:
        case MoonlightInputFlushTrigger::ControllerDisconnected:
            return MoonlightInputFlushDisposition::Suspend;
        case MoonlightInputFlushTrigger::ReconnectStarted:
        case MoonlightInputFlushTrigger::SessionStop:
        case MoonlightInputFlushTrigger::InputGenerationChanged:
            return MoonlightInputFlushDisposition::Stop;
        case MoonlightInputFlushTrigger::Invalid:
            return MoonlightInputFlushDisposition::Invalid;
    }
    return MoonlightInputFlushDisposition::Invalid;
}

struct MoonlightInputFlushPolicy::Impl final {
    std::shared_ptr<MoonlightInputBridge> bridge;
    std::shared_ptr<MoonlightKeyboardMapper> keyboard;
    std::shared_ptr<MoonlightPointerMapper> pointer;
    std::shared_ptr<MoonlightTouchMapper> touch;
    std::shared_ptr<MoonlightControllerMapper> controller;
    mutable std::mutex mutex;
    MoonlightInputFlushSnapshot state{};
    std::optional<MoonlightInputFlushContext> request;
    // Mapper pending suffixes keep using request. A newer terminal escalation
    // has a distinct exact replay key that must not rewrite that old context.
    std::optional<MoonlightInputFlushContext> completionRequest;
    std::optional<MoonlightInputFlushContext> lastCompletedRequest;

    bool validContext(const MoonlightInputFlushContext& context) const noexcept {
        if (!context.identity.valid() || context.operationGeneration == 0U ||
            context.monotonicTimestampUs == 0U || !context.touch.valid() ||
            !context.pointer.valid() || !context.keyboard.valid() ||
            context.touch.identity != context.identity ||
            context.pointer.identity != context.identity ||
            context.keyboard.identity != context.identity ||
            context.touch.monotonicTimestampUs > context.monotonicTimestampUs ||
            context.pointer.monotonicTimestampUs > context.monotonicTimestampUs ||
            context.keyboard.monotonicTimestampUs > context.monotonicTimestampUs) {
            return false;
        }
        if (context.controllerContextPresent) {
            if (controller == nullptr || !context.controller.valid() ||
                context.controller.identity != context.identity ||
                context.controller.monotonicTimestampUs >
                    context.monotonicTimestampUs) {
                return false;
            }
        }
        if (controller != nullptr) {
            const auto snapshot = controller->snapshot(context.identity);
            if (!snapshot.matched ||
                (snapshot.active &&
                 (!context.controllerContextPresent ||
                  snapshot.deviceId != context.controller.deviceId ||
                  snapshot.sourceGeneration !=
                      context.controller.sourceGeneration))) {
                return false;
            }
        }
        return true;
    }

    MoonlightInputFlushResult rejected(MoonlightInputFlushStatus status) noexcept {
        state.rejectedRequests = saturatingIncrement(state.rejectedRequests);
        return makeResult(status, state.stage,
                          MoonlightInputDispatchStatus::InvalidRequest,
                          state.localReleased, state.boundaryApplied, false,
                          state.remoteReleaseComplete);
    }

    MoonlightInputFlushResult pending(
        MoonlightInputDispatchStatus dispatchStatus) noexcept {
        state.pendingRetries = saturatingIncrement(state.pendingRetries);
        return makeResult(MoonlightInputFlushStatus::Pending, state.stage,
                          dispatchStatus, state.localReleased,
                          state.boundaryApplied, true,
                          state.remoteReleaseComplete);
    }

    MoonlightInputFlushResult componentFailure(
        MoonlightInputDispatchStatus dispatchStatus) noexcept {
        return makeResult(MoonlightInputFlushStatus::ComponentFailure, state.stage,
                          dispatchStatus, state.localReleased,
                          state.boundaryApplied, retryableDispatch(dispatchStatus),
                          state.remoteReleaseComplete);
    }

    bool discardLocalState(const MoonlightInputIdentity& identity) noexcept {
        // Once any mapper state is discarded without its exact release being
        // accepted, the final bridge boundary cannot prove the remote state
        // neutral. Preserve this independently from local cleanup success.
        state.remoteReleaseComplete = false;
        bool discarded = touch->discardLocalState(identity);
        discarded = pointer->discardLocalState(identity) && discarded;
        discarded = keyboard->discardLocalState(identity) && discarded;
        if (controller != nullptr) {
            discarded = controller->discardLocalState(identity) && discarded;
        }
        state.localReleased = discarded;
        return discarded;
    }

    MoonlightInputControlResult beginFlushBoundary(
        const MoonlightInputIdentity& identity,
        MoonlightInputFlushDisposition disposition,
        std::uint64_t operationGeneration,
        std::uint64_t timestampUs) noexcept {
        return bridge->beginFlush({identity, bridgeReason(disposition),
                                   operationGeneration, timestampUs});
    }

    MoonlightInputFlushResult drive() noexcept {
        if (!request.has_value()) {
            return rejected(MoonlightInputFlushStatus::InvalidState);
        }
        const auto& context = *request;
        for (;;) {
            switch (state.stage) {
                case MoonlightInputFlushStage::Touch: {
                    const auto snapshot = touch->snapshot(context.identity);
                    const auto result = snapshot.pending
                        ? touch->resumePending()
                        : touch->cancelAll(context.touch);
                    if (!touchSuccess(result.status)) {
                        if (terminalDisposition(state.lastDisposition)) {
                            if (!discardLocalState(context.identity)) {
                                return componentFailure(result.dispatchStatus);
                            }
                            state.stage = MoonlightInputFlushStage::Boundary;
                            break;
                        }
                        return retryableDispatch(result.dispatchStatus) ||
                                result.status == MoonlightTouchStatus::Pending
                            ? pending(result.dispatchStatus)
                            : componentFailure(result.dispatchStatus);
                    }
                    state.stage = MoonlightInputFlushStage::Pointer;
                    break;
                }
                case MoonlightInputFlushStage::Pointer: {
                    const auto snapshot = pointer->snapshot(context.identity);
                    const auto result = snapshot.pending
                        ? pointer->resumePending()
                        : pointer->releaseAll(context.pointer);
                    if (!pointerSuccess(result.status)) {
                        if (terminalDisposition(state.lastDisposition)) {
                            if (!discardLocalState(context.identity)) {
                                return componentFailure(result.dispatchStatus);
                            }
                            state.stage = MoonlightInputFlushStage::Boundary;
                            break;
                        }
                        return retryableDispatch(result.dispatchStatus) ||
                                result.status == MoonlightPointerStatus::Pending
                            ? pending(result.dispatchStatus)
                            : componentFailure(result.dispatchStatus);
                    }
                    state.stage = MoonlightInputFlushStage::Keyboard;
                    break;
                }
                case MoonlightInputFlushStage::Keyboard: {
                    const auto snapshot = keyboard->snapshot(context.identity);
                    const auto result = snapshot.pending
                        ? keyboard->resumePending()
                        : keyboard->releaseAll(context.keyboard);
                    if (!keyboardSuccess(result.status)) {
                        if (terminalDisposition(state.lastDisposition)) {
                            if (!discardLocalState(context.identity)) {
                                return componentFailure(result.dispatchStatus);
                            }
                            state.stage = MoonlightInputFlushStage::Boundary;
                            break;
                        }
                        return retryableDispatch(result.dispatchStatus) ||
                                result.status == MoonlightKeyboardStatus::Pending
                            ? pending(result.dispatchStatus)
                            : componentFailure(result.dispatchStatus);
                    }
                    state.stage = MoonlightInputFlushStage::Controller;
                    break;
                }
                case MoonlightInputFlushStage::Controller: {
                    if (controller != nullptr) {
                        const auto snapshot = controller->snapshot(context.identity);
                        if (snapshot.active) {
                            const auto result =
                                state.lastTrigger ==
                                        MoonlightInputFlushTrigger::ControllerDisconnected
                                    ? controller->disconnect(context.controller)
                                    : controller->neutralize(context.controller);
                            if (!controllerSuccess(result.status)) {
                                if (terminalDisposition(state.lastDisposition)) {
                                    if (!discardLocalState(context.identity)) {
                                        return componentFailure(result.dispatchStatus);
                                    }
                                    state.stage = MoonlightInputFlushStage::Boundary;
                                    break;
                                }
                                return retryableDispatch(result.dispatchStatus)
                                    ? pending(result.dispatchStatus)
                                    : componentFailure(result.dispatchStatus);
                            }
                        }
                    }
                    state.localReleased = true;
                    state.stage = MoonlightInputFlushStage::Boundary;
                    break;
                }
                case MoonlightInputFlushStage::Boundary: {
                    const auto control = terminalDisposition(state.lastDisposition)
                        ? bridge->stop(context.identity,
                                       state.lastOperationGeneration,
                                       state.lastTimestampUs)
                        : bridge->focusLost(context.identity,
                                            state.lastOperationGeneration,
                                            state.lastTimestampUs);
                    if (controlSuccess(control.status)) {
                        state.boundaryApplied = true;
                        state.stage = MoonlightInputFlushStage::Complete;
                        state.state = terminalDisposition(state.lastDisposition)
                            ? MoonlightInputFlushState::Stopped
                            : MoonlightInputFlushState::Suspended;
                        state.completedFlushes =
                            saturatingIncrement(state.completedFlushes);
                        lastCompletedRequest = completionRequest.has_value()
                            ? completionRequest : request;
                        completionRequest.reset();
                        request.reset();
                        return makeResult(MoonlightInputFlushStatus::Applied,
                                          state.stage,
                                          MoonlightInputDispatchStatus::Accepted,
                                          true, true, false,
                                          state.remoteReleaseComplete);
                    }
                    state.boundaryFailures =
                        saturatingIncrement(state.boundaryFailures);
                    if (terminalDisposition(state.lastDisposition)) {
                        (void)discardLocalState(context.identity);
                        const auto localStop = bridge->stopLocally(
                            context.identity, state.lastOperationGeneration,
                            state.lastTimestampUs);
                        if (!controlSuccess(localStop.status)) {
                            return makeResult(
                                MoonlightInputFlushStatus::BoundaryFailure,
                                state.stage, controlDispatch(localStop.status),
                                state.localReleased, false, false,
                                state.remoteReleaseComplete);
                        }
                        state.boundaryApplied = false;
                        state.stage = MoonlightInputFlushStage::Complete;
                        state.state = MoonlightInputFlushState::Stopped;
                        state.localOnlyStops =
                            saturatingIncrement(state.localOnlyStops);
                        state.completedFlushes =
                            saturatingIncrement(state.completedFlushes);
                        lastCompletedRequest = completionRequest.has_value()
                            ? completionRequest : request;
                        completionRequest.reset();
                        request.reset();
                        return makeResult(MoonlightInputFlushStatus::AppliedLocally,
                                          state.stage,
                                          controlDispatch(control.status),
                                          true, false, false,
                                          state.remoteReleaseComplete);
                    }
                    state.state = MoonlightInputFlushState::BoundaryPending;
                    return makeResult(MoonlightInputFlushStatus::BoundaryFailure,
                                      state.stage,
                                      controlDispatch(control.status),
                                      true, false, true,
                                      state.remoteReleaseComplete);
                }
                case MoonlightInputFlushStage::None:
                case MoonlightInputFlushStage::Complete:
                    return rejected(MoonlightInputFlushStatus::InvalidState);
            }
        }
    }
};

MoonlightInputFlushPolicy::MoonlightInputFlushPolicy(
    std::unique_ptr<Impl> impl) noexcept : impl_(std::move(impl)) {}

MoonlightInputFlushPolicy::~MoonlightInputFlushPolicy() = default;

std::shared_ptr<MoonlightInputFlushPolicy> MoonlightInputFlushPolicy::create(
    std::shared_ptr<MoonlightInputBridge> bridge,
    std::shared_ptr<MoonlightKeyboardMapper> keyboard,
    std::shared_ptr<MoonlightPointerMapper> pointer,
    std::shared_ptr<MoonlightTouchMapper> touch,
    const MoonlightInputIdentity& identity,
    std::shared_ptr<MoonlightControllerMapper> controller) noexcept {
    if (bridge == nullptr || keyboard == nullptr || pointer == nullptr ||
        touch == nullptr || !identity.valid()) {
        return nullptr;
    }
    const auto bridgeSnapshot = bridge->snapshot(identity);
    const auto keyboardSnapshot = keyboard->snapshot(identity);
    const auto pointerSnapshot = pointer->snapshot(identity);
    const auto touchSnapshot = touch->snapshot(identity);
    if (!bridgeSnapshot.matched ||
        bridgeSnapshot.state != MoonlightInputState::Active ||
        !keyboardSnapshot.matched || !pointerSnapshot.matched ||
        !touchSnapshot.matched ||
        (controller != nullptr && !controller->snapshot(identity).matched)) {
        return nullptr;
    }
    std::unique_ptr<Impl> impl(new (std::nothrow) Impl());
    if (impl == nullptr) {
        return nullptr;
    }
    impl->bridge = std::move(bridge);
    impl->keyboard = std::move(keyboard);
    impl->pointer = std::move(pointer);
    impl->touch = std::move(touch);
    impl->controller = std::move(controller);
    impl->state.matched = true;
    impl->state.identity = identity;
    return std::shared_ptr<MoonlightInputFlushPolicy>(
        new (std::nothrow) MoonlightInputFlushPolicy(std::move(impl)));
}

MoonlightInputFlushResult MoonlightInputFlushPolicy::flush(
    MoonlightInputFlushTrigger trigger,
    const MoonlightInputFlushContext& context) noexcept {
    const auto disposition = moonlightInputFlushDisposition(trigger);
    if (impl_ == nullptr || disposition == MoonlightInputFlushDisposition::Invalid) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->state.matched && context.identity != impl_->state.identity) {
        return impl_->rejected(MoonlightInputFlushStatus::StaleOwner);
    }
    if (!impl_->validContext(context)) {
        return impl_->rejected(MoonlightInputFlushStatus::InvalidRequest);
    }
    if (impl_->request.has_value()) {
        if (terminalDisposition(disposition) &&
            !terminalDisposition(impl_->state.lastDisposition) &&
            context.operationGeneration >
                impl_->state.lastOperationGeneration &&
            context.monotonicTimestampUs >= impl_->state.lastTimestampUs) {
            const auto begin = impl_->beginFlushBoundary(
                context.identity, disposition, context.operationGeneration,
                context.monotonicTimestampUs);
            if (!controlSuccess(begin.status)) {
                return makeResult(MoonlightInputFlushStatus::BoundaryFailure,
                                  impl_->state.stage,
                                  controlDispatch(begin.status),
                                  impl_->state.localReleased,
                                  impl_->state.boundaryApplied, false,
                                  impl_->state.remoteReleaseComplete);
            }
            impl_->state.state = MoonlightInputFlushState::Flushing;
            impl_->state.lastTrigger = trigger;
            impl_->state.lastDisposition = disposition;
            impl_->state.lastOperationGeneration = context.operationGeneration;
            impl_->state.lastTimestampUs = context.monotonicTimestampUs;
            impl_->completionRequest = context;
            return impl_->drive();
        }
        if (trigger != impl_->state.lastTrigger ||
            !sameContext(context, *impl_->request)) {
            return impl_->pending(MoonlightInputDispatchStatus::Backpressure);
        }
        if (impl_->state.state == MoonlightInputFlushState::BoundaryPending) {
            return makeResult(MoonlightInputFlushStatus::BoundaryFailure,
                              impl_->state.stage,
                              MoonlightInputDispatchStatus::PortFailure,
                              true, false, true,
                              impl_->state.remoteReleaseComplete);
        }
        return impl_->drive();
    }
    if (impl_->lastCompletedRequest.has_value() &&
        trigger == impl_->state.lastTrigger &&
        sameContext(context, *impl_->lastCompletedRequest)) {
        return makeResult(MoonlightInputFlushStatus::AlreadyApplied,
                          MoonlightInputFlushStage::Complete,
                          MoonlightInputDispatchStatus::Accepted,
                          impl_->state.localReleased,
                          impl_->state.boundaryApplied, false,
                          impl_->state.remoteReleaseComplete);
    }
    if (impl_->state.state == MoonlightInputFlushState::Stopped) {
        return impl_->rejected(MoonlightInputFlushStatus::InvalidState);
    }
    if (impl_->state.matched &&
        (context.operationGeneration <= impl_->state.lastOperationGeneration ||
         context.monotonicTimestampUs < impl_->state.lastTimestampUs)) {
        return impl_->rejected(MoonlightInputFlushStatus::StaleOperation);
    }
    const auto begin = impl_->beginFlushBoundary(
        context.identity, disposition, context.operationGeneration,
        context.monotonicTimestampUs);
    if (!controlSuccess(begin.status)) {
        const auto bridgeSnapshot = impl_->bridge->snapshot(context.identity);
        const bool bridgeAlreadyStopped =
            bridgeSnapshot.matched &&
            bridgeSnapshot.state == MoonlightInputState::Stopped &&
            context.operationGeneration >=
                bridgeSnapshot.lastOperationGeneration &&
            context.monotonicTimestampUs >=
                bridgeSnapshot.lastBoundaryTimestampUs;
        if (terminalDisposition(disposition) && bridgeAlreadyStopped &&
            impl_->discardLocalState(context.identity)) {
            const auto localStop = impl_->bridge->stopLocally(
                context.identity, context.operationGeneration,
                context.monotonicTimestampUs);
            if (controlSuccess(localStop.status)) {
                impl_->state.state = MoonlightInputFlushState::Stopped;
                impl_->state.stage = MoonlightInputFlushStage::Complete;
                impl_->state.lastTrigger = trigger;
                impl_->state.lastDisposition = disposition;
                impl_->state.lastOperationGeneration = context.operationGeneration;
                impl_->state.lastTimestampUs = context.monotonicTimestampUs;
                impl_->state.admissionOpen = false;
                impl_->state.localOnlyStops =
                    saturatingIncrement(impl_->state.localOnlyStops);
                impl_->state.completedFlushes =
                    saturatingIncrement(impl_->state.completedFlushes);
                impl_->lastCompletedRequest = context;
                return makeResult(MoonlightInputFlushStatus::AppliedLocally,
                                  impl_->state.stage,
                                  controlDispatch(begin.status), true, false,
                                  false, impl_->state.remoteReleaseComplete);
            }
        }
        return makeResult(MoonlightInputFlushStatus::BoundaryFailure,
                          impl_->state.stage, controlDispatch(begin.status),
                          impl_->state.localReleased,
                          impl_->state.boundaryApplied, false,
                          impl_->state.remoteReleaseComplete);
    }
    impl_->state.matched = true;
    impl_->state.identity = context.identity;
    impl_->state.state = MoonlightInputFlushState::Flushing;
    impl_->state.stage = MoonlightInputFlushStage::Touch;
    impl_->state.lastTrigger = trigger;
    impl_->state.lastDisposition = disposition;
    impl_->state.lastOperationGeneration = context.operationGeneration;
    impl_->state.lastTimestampUs = context.monotonicTimestampUs;
    impl_->state.admissionOpen = false;
    impl_->state.localReleased = false;
    impl_->state.boundaryApplied = false;
    impl_->state.remoteReleaseComplete = true;
    impl_->completionRequest.reset();
    impl_->request = context;
    return impl_->drive();
}

MoonlightInputFlushResult MoonlightInputFlushPolicy::retryBoundary(
    const MoonlightInputIdentity& identity,
    std::uint64_t operationGeneration,
    std::uint64_t monotonicTimestampUs) noexcept {
    if (impl_ == nullptr || !identity.valid() || operationGeneration == 0U ||
        monotonicTimestampUs == 0U) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!impl_->state.matched || identity != impl_->state.identity) {
        return impl_->rejected(MoonlightInputFlushStatus::StaleOwner);
    }
    if (impl_->state.state != MoonlightInputFlushState::BoundaryPending ||
        !impl_->request.has_value() ||
        impl_->state.lastDisposition != MoonlightInputFlushDisposition::Suspend) {
        return impl_->rejected(MoonlightInputFlushStatus::InvalidState);
    }
    if (operationGeneration <= impl_->state.lastOperationGeneration ||
        monotonicTimestampUs < impl_->state.lastTimestampUs) {
        return impl_->rejected(MoonlightInputFlushStatus::StaleOperation);
    }
    impl_->request->operationGeneration = operationGeneration;
    impl_->request->monotonicTimestampUs = monotonicTimestampUs;
    impl_->state.lastOperationGeneration = operationGeneration;
    impl_->state.lastTimestampUs = monotonicTimestampUs;
    impl_->state.state = MoonlightInputFlushState::Flushing;
    return impl_->drive();
}

MoonlightInputFlushResult MoonlightInputFlushPolicy::resume(
    const MoonlightInputIdentity& identity,
    std::uint64_t operationGeneration) noexcept {
    if (impl_ == nullptr || !identity.valid() || operationGeneration == 0U) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!impl_->state.matched || identity != impl_->state.identity) {
        return impl_->rejected(MoonlightInputFlushStatus::StaleOwner);
    }
    if (impl_->state.state != MoonlightInputFlushState::Suspended) {
        return impl_->rejected(MoonlightInputFlushStatus::InvalidState);
    }
    if (operationGeneration <= impl_->state.lastOperationGeneration) {
        return impl_->rejected(MoonlightInputFlushStatus::StaleOperation);
    }
    const auto control = impl_->bridge->resume(identity, operationGeneration);
    if (control.status != MoonlightInputControlStatus::Applied &&
        control.status != MoonlightInputControlStatus::AlreadyApplied) {
        impl_->state.boundaryFailures =
            saturatingIncrement(impl_->state.boundaryFailures);
        return makeResult(MoonlightInputFlushStatus::BoundaryFailure,
                          MoonlightInputFlushStage::Boundary,
                          controlDispatch(control.status),
                          true, true, true,
                          impl_->state.remoteReleaseComplete);
    }
    impl_->state.state = MoonlightInputFlushState::Active;
    impl_->state.stage = MoonlightInputFlushStage::None;
    impl_->state.lastOperationGeneration = operationGeneration;
    impl_->state.admissionOpen = true;
    impl_->state.localReleased = false;
    return makeResult(MoonlightInputFlushStatus::Applied,
                      MoonlightInputFlushStage::Complete,
                      MoonlightInputDispatchStatus::Accepted,
                      true, true, false,
                      impl_->state.remoteReleaseComplete);
}

MoonlightInputFlushSnapshot MoonlightInputFlushPolicy::snapshot(
    const MoonlightInputIdentity& identity) const noexcept {
    if (impl_ == nullptr) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!identity.valid() || !impl_->state.matched ||
        identity != impl_->state.identity) {
        return {};
    }
    return impl_->state;
}

} // namespace remotedesk::moonlight
