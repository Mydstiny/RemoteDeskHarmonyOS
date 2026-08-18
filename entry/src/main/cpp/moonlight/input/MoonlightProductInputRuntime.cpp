#include "moonlight/input/MoonlightProductInputRuntime.h"

#include "moonlight/input/MoonlightCommonCInputPort.h"
#include "moonlight/input/MoonlightControllerAggregator.h"
#include "moonlight/input/MoonlightGameControllerListener.h"
#include "moonlight/input/MoonlightInputFlushPolicy.h"
#include "moonlight/input/MoonlightKeyboardMapper.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <utility>

namespace remotedesk::moonlight {
namespace {

constexpr std::uint64_t kPhysicalKeyboardDevice = 0x4d4c4b01U;
constexpr std::uint64_t kVirtualKeyboardDevice = 0x4d4c4b02U;
constexpr std::uint64_t kPointerDevice = 0x4d4c5001U;
constexpr std::uint64_t kTouchDevice = 0x4d4c5401U;
constexpr std::uint64_t kVirtualControllerDevice = 0x4d4c4701U;

std::uint64_t monotonicUs() noexcept {
    const auto value = std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    return value <= 0 ? 1U : static_cast<std::uint64_t>(value);
}

std::uint64_t next(std::uint64_t& value) noexcept {
    if (value == std::numeric_limits<std::uint64_t>::max()) {
        return value;
    }
    return ++value;
}

bool keyboardApplied(MoonlightKeyboardStatus status) noexcept {
    return status == MoonlightKeyboardStatus::Applied ||
        status == MoonlightKeyboardStatus::AppliedLocally ||
        status == MoonlightKeyboardStatus::AlreadyApplied ||
        status == MoonlightKeyboardStatus::LocalEscape;
}

bool pointerApplied(MoonlightPointerStatus status) noexcept {
    return status == MoonlightPointerStatus::Applied ||
        status == MoonlightPointerStatus::AppliedLocally ||
        status == MoonlightPointerStatus::AlreadyApplied ||
        status == MoonlightPointerStatus::OutsideContent;
}

bool touchApplied(MoonlightTouchStatus status) noexcept {
    return status == MoonlightTouchStatus::Applied ||
        status == MoonlightTouchStatus::AppliedLocally ||
        status == MoonlightTouchStatus::AlreadyApplied ||
        status == MoonlightTouchStatus::OutsideContent ||
        status == MoonlightTouchStatus::OverlayConsumed;
}

bool controllerApplied(MoonlightControllerAggregatorStatus status) noexcept {
    return status == MoonlightControllerAggregatorStatus::Applied ||
        status == MoonlightControllerAggregatorStatus::AppliedLocally ||
        status == MoonlightControllerAggregatorStatus::AlreadyApplied;
}

bool controllerRetryable(
    const MoonlightControllerAggregatorResult& result) noexcept {
    return result.retryable ||
        result.status == MoonlightControllerAggregatorStatus::Pending ||
        result.status == MoonlightControllerAggregatorStatus::Backpressure;
}

MoonlightVirtualControllerElementKind virtualElementKind(
    MoonlightProductVirtualControllerElement value) noexcept {
    switch (value) {
        case MoonlightProductVirtualControllerElement::FaceA:
            return MoonlightVirtualControllerElementKind::FaceA;
        case MoonlightProductVirtualControllerElement::FaceB:
            return MoonlightVirtualControllerElementKind::FaceB;
        case MoonlightProductVirtualControllerElement::FaceX:
            return MoonlightVirtualControllerElementKind::FaceX;
        case MoonlightProductVirtualControllerElement::FaceY:
            return MoonlightVirtualControllerElementKind::FaceY;
        case MoonlightProductVirtualControllerElement::Dpad:
            return MoonlightVirtualControllerElementKind::DpadCluster;
        case MoonlightProductVirtualControllerElement::LeftStick:
            return MoonlightVirtualControllerElementKind::LeftStick;
        case MoonlightProductVirtualControllerElement::RightStick:
            return MoonlightVirtualControllerElementKind::RightStick;
        case MoonlightProductVirtualControllerElement::LeftTrigger:
            return MoonlightVirtualControllerElementKind::LeftTrigger;
        case MoonlightProductVirtualControllerElement::RightTrigger:
            return MoonlightVirtualControllerElementKind::RightTrigger;
        case MoonlightProductVirtualControllerElement::LeftShoulder:
            return MoonlightVirtualControllerElementKind::LeftShoulder;
        case MoonlightProductVirtualControllerElement::RightShoulder:
            return MoonlightVirtualControllerElementKind::RightShoulder;
        case MoonlightProductVirtualControllerElement::LeftStickClick:
            return MoonlightVirtualControllerElementKind::LeftStickClick;
        case MoonlightProductVirtualControllerElement::RightStickClick:
            return MoonlightVirtualControllerElementKind::RightStickClick;
        case MoonlightProductVirtualControllerElement::Menu:
            return MoonlightVirtualControllerElementKind::Menu;
        case MoonlightProductVirtualControllerElement::Invalid:
            return MoonlightVirtualControllerElementKind::Invalid;
    }
    return MoonlightVirtualControllerElementKind::Invalid;
}

MoonlightVirtualControllerPhase virtualPhase(
    MoonlightProductVirtualControllerPhase value) noexcept {
    switch (value) {
        case MoonlightProductVirtualControllerPhase::Begin:
            return MoonlightVirtualControllerPhase::Begin;
        case MoonlightProductVirtualControllerPhase::Change:
            return MoonlightVirtualControllerPhase::Change;
        case MoonlightProductVirtualControllerPhase::End:
            return MoonlightVirtualControllerPhase::End;
        case MoonlightProductVirtualControllerPhase::Cancel:
            return MoonlightVirtualControllerPhase::Cancel;
        case MoonlightProductVirtualControllerPhase::Invalid:
            return MoonlightVirtualControllerPhase::Invalid;
    }
    return MoonlightVirtualControllerPhase::Invalid;
}

std::uint16_t virtualElementId(
    const MoonlightVirtualControllerLayout& layout,
    MoonlightVirtualControllerElementKind kind) noexcept {
    for (std::size_t index = 0U; index < layout.elementCount; ++index) {
        if (layout.elements[index].kind == kind) {
            return layout.elements[index].id;
        }
    }
    return 0U;
}

} // namespace

struct MoonlightProductInputRuntime::State final
    : public MoonlightGameControllerListener::Sink {
    struct PendingPhysicalConnect final {
        MoonlightControllerSourceContext context{};
        MoonlightControllerProfile profile{};
        std::uint64_t listenerGeneration = 0U;
        std::optional<MoonlightControllerHandoffRequest> handoff;
        bool submitted = false;
    };
    struct PendingPhysicalDisconnect final {
        std::uint64_t deviceId = 0U;
        std::uint64_t listenerGeneration = 0U;
        std::uint64_t sourceSequence = 0U;
        std::uint64_t monotonicTimestampUs = 0U;
    };
    struct PendingPhysicalFrame final {
        MoonlightControllerSourceContext context{};
        MoonlightControllerSample sample{};
        std::uint64_t listenerGeneration = 0U;
    };
    struct PendingPhysicalStandby final {
        std::uint64_t deviceId = 0U;
        std::uint64_t listenerGeneration = 0U;
        std::uint64_t arrivalSequence = 0U;
        std::uint64_t arrivalTimestampUs = 0U;
        std::uint64_t latestSampleSequence = 0U;
        std::uint64_t latestSampleTimestampUs = 0U;
        MoonlightControllerProfile profile{};
        MoonlightControllerSample sample{};
        bool samplePresent = false;
    };
    enum class LifecycleClear : std::uint8_t { None, Physical, Virtual };
    struct PendingLifecycle final {
        MoonlightInputFlushTrigger trigger = MoonlightInputFlushTrigger::Invalid;
        MoonlightInputFlushContext flush{};
        MoonlightInputIdentity identity{};
        std::uint64_t resumeGeneration = 0U;
        LifecycleClear clear = LifecycleClear::None;
        bool flushApplied = false;
        bool resumeAfter = false;
    };

    std::mutex mutex;
    std::mutex controllerLane;
    bool active = false;
    bool activating = false;
    bool stopping = false;
    bool controllerReady = false;
    bool physicalControllerReady = false;
    bool directTouch = false;
    MoonlightSessionKey key{};
    MoonlightInputIdentity identity{};
    std::uint64_t operationGeneration = 0U;
    std::uint64_t keyboardSequence = 0U;
    std::uint64_t textSequence = 0U;
    std::uint64_t pointerSequence = 0U;
    std::uint64_t touchSequence = 0U;
    std::uint64_t acceptedEvents = 0U;
    std::uint64_t rejectedEvents = 0U;
    std::uint64_t controllerSourceGeneration = 0U;
    std::uint64_t physicalDeviceId = 0U;
    std::uint64_t physicalListenerGeneration = 0U;
    std::uint64_t physicalSourceGeneration = 0U;
    bool virtualEnabled = false;
    bool virtualEditing = false;
    std::uint64_t virtualSourceGeneration = 0U;
    std::uint64_t virtualSourceSequence = 0U;
    MoonlightVirtualControllerLayout virtualLayout{};
    std::optional<PendingPhysicalConnect> pendingPhysicalConnect;
    std::optional<PendingPhysicalDisconnect> pendingPhysicalDisconnect;
    std::optional<PendingPhysicalFrame> pendingPhysicalFrame;
    std::optional<PendingPhysicalStandby> pendingPhysicalStandby;
    std::optional<MoonlightControllerSourceContext> pendingVirtualConnect;
    std::optional<MoonlightVirtualControllerEvent> pendingVirtual;
    std::optional<PendingLifecycle> pendingLifecycle;
    MoonlightControllerSourceContext controllerContext{};
    std::shared_ptr<MoonlightInputBridge> bridge;
    std::shared_ptr<MoonlightKeyboardMapper> keyboard;
    std::shared_ptr<MoonlightPointerMapper> pointer;
    std::shared_ptr<MoonlightTouchMapper> touch;
    std::shared_ptr<MoonlightControllerMapper> controller;
    std::shared_ptr<MoonlightInputFlushPolicy> flushPolicy;
    std::shared_ptr<MoonlightControllerAggregator> aggregator;
    std::shared_ptr<MoonlightGameControllerListener> listener;

    MoonlightKeyboardEventContext keyboardContext(
        bool text, std::uint64_t timestamp = 0U) noexcept {
        auto& sequence = text ? textSequence : keyboardSequence;
        return {identity, text ? kVirtualKeyboardDevice : kPhysicalKeyboardDevice,
                text ? MoonlightInputSource::OnScreenKeyboard :
                       MoonlightInputSource::PhysicalKeyboard,
                identity.inputGeneration, next(sequence),
                timestamp == 0U ? monotonicUs() : timestamp};
    }

    MoonlightPointerEventContext pointerContext(
        std::uint64_t timestamp = 0U) noexcept {
        return {identity, kPointerDevice, MoonlightInputSource::Mouse,
                identity.inputGeneration, next(pointerSequence),
                timestamp == 0U ? monotonicUs() : timestamp};
    }

    MoonlightTouchEventContext touchContext(
        std::uint64_t timestamp = 0U) noexcept {
        return {identity, kTouchDevice,
                directTouch ? MoonlightInputSource::Touchscreen :
                              MoonlightInputSource::Touchpad,
                identity.inputGeneration, next(touchSequence),
                timestamp == 0U ? monotonicUs() : timestamp};
    }

    MoonlightInputFlushContext flushContext(
        bool includeController, std::uint64_t timestamp = 0U) noexcept {
        const std::uint64_t boundary = timestamp == 0U ? monotonicUs() : timestamp;
        MoonlightInputFlushContext context;
        context.identity = identity;
        context.operationGeneration = next(operationGeneration);
        context.monotonicTimestampUs = boundary;
        context.touch = touchContext(boundary);
        context.pointer = pointerContext(boundary);
        context.keyboard = keyboardContext(false, boundary);
        context.controllerContextPresent = includeController && controllerContext.valid();
        if (context.controllerContextPresent) {
            context.controller = {identity, controllerContext.deviceId,
                moonlightControllerInputSource(controllerContext.kind),
                controllerContext.sourceGeneration,
                controllerContext.sourceSequence, boundary};
        }
        return context;
    }

    void record(bool accepted) noexcept {
        std::lock_guard<std::mutex> lock(mutex);
        if (accepted) {
            (void)next(acceptedEvents);
        } else {
            (void)next(rejectedEvents);
        }
    }

    // mutex must be held. The listener exposes one active physical device and
    // may promote one already-online standby while the old source is still
    // draining through common-c backpressure.
    void retainPhysicalStandby(
        std::uint64_t deviceId, std::uint64_t listenerGeneration,
        std::uint64_t sourceSequence, std::uint64_t timestamp,
        const MoonlightControllerProfile& profile) noexcept {
        if (!pendingPhysicalStandby.has_value() ||
            pendingPhysicalStandby->deviceId != deviceId ||
            pendingPhysicalStandby->listenerGeneration != listenerGeneration) {
            pendingPhysicalStandby = PendingPhysicalStandby{
                deviceId, listenerGeneration, sourceSequence, timestamp,
                0U, 0U, profile, {}, false};
            return;
        }
        pendingPhysicalStandby->profile = profile;
    }

    // controllerLane must be held. Every retry uses the exact object retained
    // after common-c backpressure; a newer source event never overtakes it.
    bool retryControllerOperation() noexcept {
        std::shared_ptr<MoonlightControllerAggregator> target;
        std::optional<PendingPhysicalConnect> physicalConnect;
        std::optional<PendingPhysicalFrame> physicalFrame;
        std::optional<MoonlightControllerSourceContext> virtualConnect;
        std::optional<MoonlightVirtualControllerEvent> virtualFrame;
        std::optional<PendingLifecycle> lifecycle;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (!active || aggregator == nullptr) {
                return false;
            }
            target = aggregator;
            physicalConnect = pendingPhysicalConnect;
            lifecycle = pendingLifecycle;
            physicalFrame = pendingPhysicalFrame;
            virtualConnect = pendingVirtualConnect;
            virtualFrame = pendingVirtual;
        }

        // The aggregator retains one exact pending arrival. If a virtual
        // arrival already owns it, complete that retry before the one-shot
        // physical ONLINE edge retained below. This prevents both sources
        // from returning Pending forever.
        if (virtualConnect.has_value()) {
            const auto result = target->connectVirtual(*virtualConnect);
            if (!controllerApplied(result.status)) {
                if (!controllerRetryable(result)) {
                    std::lock_guard<std::mutex> lock(mutex);
                    pendingVirtualConnect.reset();
                    virtualSourceGeneration = 0U;
                    virtualSourceSequence = 0U;
                }
                return false;
            }
            {
                std::lock_guard<std::mutex> lock(mutex);
                if (!active || identity != virtualConnect->identity) {
                    return false;
                }
                controllerContext = *virtualConnect;
                pendingVirtualConnect.reset();
            }
        }

        if (physicalConnect.has_value()) {
            // When ONLINE arrived while virtual connect was pending, promote
            // the retained physical context to an exact remove-first handoff
            // after virtual connect becomes active.
            if (!physicalConnect->handoff.has_value()) {
                const auto snapshot = target->snapshot(identity);
                if (snapshot.activeSource ==
                    MoonlightControllerSourceKind::Virtual) {
                    std::lock_guard<std::mutex> lock(mutex);
                    if (!pendingPhysicalConnect.has_value() ||
                        controllerContext.kind !=
                            MoonlightControllerSourceKind::Virtual ||
                        !controllerContext.valid()) {
                        return false;
                    }
                    const auto timestamp = std::max(
                        physicalConnect->context.monotonicTimestampUs,
                        monotonicUs());
                    MoonlightControllerHandoffRequest request;
                    request.target = physicalConnect->context;
                    request.target.monotonicTimestampUs = timestamp;
                    request.targetPhysicalProfile = physicalConnect->profile;
                    request.disconnectFlush = flushContext(true, timestamp);
                    request.boundaryRetryOperationGeneration =
                        next(operationGeneration);
                    request.boundaryRetryTimestampUs = timestamp;
                    request.resumeOperationGeneration = next(operationGeneration);
                    request.terminalFlush = flushContext(true, timestamp);
                    pendingPhysicalConnect->context = request.target;
                    pendingPhysicalConnect->handoff = request;
                    physicalConnect = pendingPhysicalConnect;
                } else if (snapshot.activeSource !=
                           MoonlightControllerSourceKind::Invalid) {
                    std::lock_guard<std::mutex> lock(mutex);
                    pendingPhysicalConnect.reset();
                    pendingPhysicalDisconnect.reset();
                    return false;
                }
            }
            const auto result = physicalConnect->handoff.has_value()
                ? target->switchSource(*physicalConnect->handoff)
                : target->connectPhysical(
                      physicalConnect->context, physicalConnect->profile);
            if (!controllerApplied(result.status)) {
                std::lock_guard<std::mutex> lock(mutex);
                if (controllerRetryable(result)) {
                    // The aggregator normalizes mapper backpressure to its
                    // retryable Pending status. Once this exact call has been
                    // made, it may own pendingConnect/handoff state and must
                    // not be cancelled locally by a following OFFLINE edge.
                    if (pendingPhysicalConnect.has_value()) {
                        pendingPhysicalConnect->submitted = true;
                    }
                } else {
                    pendingPhysicalConnect.reset();
                    pendingPhysicalDisconnect.reset();
                }
                return false;
            }
            bool releaseImmediately = false;
            bool drainRetainedFrame = false;
            {
                std::lock_guard<std::mutex> lock(mutex);
                if (!active || identity != physicalConnect->context.identity) {
                    return false;
                }
                physicalDeviceId = physicalConnect->context.deviceId;
                physicalListenerGeneration = physicalConnect->listenerGeneration;
                physicalSourceGeneration =
                    physicalConnect->context.sourceGeneration;
                controllerContext = physicalConnect->context;
                pendingPhysicalConnect.reset();
                pendingVirtualConnect.reset();
                pendingVirtual.reset();
                if (pendingPhysicalDisconnect.has_value() &&
                    pendingPhysicalDisconnect->deviceId == physicalDeviceId &&
                    pendingPhysicalDisconnect->listenerGeneration ==
                        physicalListenerGeneration) {
                    const auto disconnect = *pendingPhysicalDisconnect;
                    controllerContext.sourceSequence = disconnect.sourceSequence;
                    controllerContext.monotonicTimestampUs =
                        disconnect.monotonicTimestampUs;
                    const auto flush = flushContext(
                        true, disconnect.monotonicTimestampUs);
                    const auto resumeGeneration = next(operationGeneration);
                    pendingLifecycle = PendingLifecycle{
                        MoonlightInputFlushTrigger::ControllerDisconnected,
                        flush, identity, resumeGeneration,
                        LifecycleClear::Physical, false, true};
                    pendingPhysicalDisconnect.reset();
                    releaseImmediately = true;
                }
                drainRetainedFrame = pendingPhysicalFrame.has_value();
            }
            return releaseImmediately || drainRetainedFrame
                ? retryControllerOperation() : true;
        }

        if (lifecycle.has_value()) {
            bool flushed = lifecycle->flushApplied;
            if (!flushed) {
                const auto result = target->handleLifecycle(
                    lifecycle->trigger, lifecycle->flush);
                if (!controllerApplied(result.status)) {
                    if (!controllerRetryable(result)) {
                        std::lock_guard<std::mutex> lock(mutex);
                        pendingLifecycle.reset();
                    }
                    return false;
                }
                flushed = true;
            }
            if (lifecycle->resumeAfter) {
                const auto resumed = target->resumeLifecycle(
                    lifecycle->identity, lifecycle->resumeGeneration);
                if (!controllerApplied(resumed.status)) {
                    std::lock_guard<std::mutex> lock(mutex);
                    if (pendingLifecycle.has_value() &&
                        controllerRetryable(resumed)) {
                        pendingLifecycle->flushApplied = flushed;
                    } else {
                        pendingLifecycle.reset();
                    }
                    return false;
                }
            }
            bool promoteStandby = false;
            {
                std::lock_guard<std::mutex> lock(mutex);
                if (!active || identity != lifecycle->identity) {
                    return false;
                }
                if (lifecycle->clear == LifecycleClear::Physical) {
                    physicalDeviceId = 0U;
                    physicalListenerGeneration = 0U;
                    physicalSourceGeneration = 0U;
                    controllerContext = {};
                    pendingPhysicalDisconnect.reset();
                    pendingPhysicalFrame.reset();
                    if (pendingPhysicalStandby.has_value()) {
                        const auto standby = *pendingPhysicalStandby;
                        const std::uint64_t mappedGeneration =
                            next(controllerSourceGeneration);
                        const std::uint64_t timestamp = std::max(
                            standby.arrivalTimestampUs, monotonicUs());
                        const MoonlightControllerSourceContext context = {
                            identity, MoonlightControllerSourceKind::Physical,
                            standby.deviceId, mappedGeneration,
                            standby.arrivalSequence, timestamp, 0U};
                        pendingPhysicalConnect = PendingPhysicalConnect{
                            context, standby.profile,
                            standby.listenerGeneration, std::nullopt};
                        if (standby.samplePresent &&
                            standby.latestSampleSequence >
                                standby.arrivalSequence) {
                            MoonlightControllerSourceContext frameContext =
                                context;
                            frameContext.sourceSequence =
                                standby.latestSampleSequence;
                            frameContext.monotonicTimestampUs = std::max(
                                timestamp, standby.latestSampleTimestampUs);
                            pendingPhysicalFrame = PendingPhysicalFrame{
                                frameContext, standby.sample,
                                standby.listenerGeneration};
                        }
                        pendingPhysicalStandby.reset();
                        promoteStandby = true;
                    }
                } else if (lifecycle->clear == LifecycleClear::Virtual) {
                    virtualSourceGeneration = 0U;
                    virtualSourceSequence = 0U;
                    controllerContext = {};
                    pendingVirtualConnect.reset();
                    pendingVirtual.reset();
                }
                pendingLifecycle.reset();
            }
            return promoteStandby ? retryControllerOperation() : true;
        }

        if (physicalFrame.has_value()) {
            const auto result = target->ingestPhysical(
                physicalFrame->context, physicalFrame->sample);
            if (!controllerApplied(result.status)) {
                if (!controllerRetryable(result)) {
                    std::lock_guard<std::mutex> lock(mutex);
                    pendingPhysicalFrame.reset();
                }
                return false;
            }
            std::lock_guard<std::mutex> lock(mutex);
            if (!active || identity != physicalFrame->context.identity ||
                physicalListenerGeneration != physicalFrame->listenerGeneration) {
                return false;
            }
            controllerContext = physicalFrame->context;
            pendingPhysicalFrame.reset();
            return true;
        }

        if (virtualFrame.has_value()) {
            const auto result = target->ingestVirtual(*virtualFrame);
            if (!controllerApplied(result.status)) {
                if (!controllerRetryable(result)) {
                    std::lock_guard<std::mutex> lock(mutex);
                    pendingVirtual.reset();
                }
                return false;
            }
            std::lock_guard<std::mutex> lock(mutex);
            if (!active || identity != virtualFrame->context.identity) {
                return false;
            }
            controllerContext = virtualFrame->context;
            pendingVirtual.reset();
            return true;
        }
        return true;
    }

    void onPhysicalControllerConnected(
        std::uint64_t deviceId, std::uint64_t sourceGeneration,
        std::uint64_t sourceSequence, std::uint64_t monotonicTimestampUs,
        const MoonlightControllerProfile& profile) noexcept override {
        std::lock_guard<std::mutex> lane(controllerLane);
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (!active || stopping || aggregator == nullptr) { return; }
            // A listener ONLINE edge is one-shot. Retain its exact target
            // before retrying older virtual backpressure so it cannot vanish
            // after the listener has advanced the device sequence.
            if (pendingPhysicalConnect.has_value()) {
                if (pendingPhysicalConnect->context.deviceId == deviceId &&
                    pendingPhysicalConnect->listenerGeneration ==
                        sourceGeneration) {
                    return;
                }
                retainPhysicalStandby(
                    deviceId, sourceGeneration, sourceSequence,
                    monotonicTimestampUs, profile);
            } else if (physicalDeviceId != 0U ||
                       (pendingLifecycle.has_value() &&
                        pendingLifecycle->clear == LifecycleClear::Physical)) {
                retainPhysicalStandby(
                    deviceId, sourceGeneration, sourceSequence,
                    monotonicTimestampUs, profile);
            } else {
                const auto snapshot = aggregator->snapshot(identity);
                if (!snapshot.matched) {
                    return;
                }
                if (snapshot.activeSource ==
                    MoonlightControllerSourceKind::Physical) {
                    retainPhysicalStandby(
                        deviceId, sourceGeneration, sourceSequence,
                        monotonicTimestampUs, profile);
                } else {
                    const std::uint64_t mappedGeneration =
                        next(controllerSourceGeneration);
                    const std::uint64_t timestamp = std::max(
                        monotonicTimestampUs, monotonicUs());
                    const MoonlightControllerSourceContext context = {
                        identity, MoonlightControllerSourceKind::Physical,
                        deviceId, mappedGeneration, sourceSequence,
                        timestamp, 0U};
                    std::optional<MoonlightControllerHandoffRequest> handoff;
                    if (snapshot.activeSource ==
                            MoonlightControllerSourceKind::Virtual &&
                        controllerContext.valid()) {
                        MoonlightControllerHandoffRequest request;
                        request.target = context;
                        request.targetPhysicalProfile = profile;
                        request.disconnectFlush = flushContext(true, timestamp);
                        request.boundaryRetryOperationGeneration =
                            next(operationGeneration);
                        request.boundaryRetryTimestampUs = timestamp;
                        request.resumeOperationGeneration =
                            next(operationGeneration);
                        request.terminalFlush = flushContext(true, timestamp);
                        handoff = request;
                    } else if (snapshot.activeSource !=
                               MoonlightControllerSourceKind::Invalid) {
                        return;
                    }
                    pendingPhysicalConnect = PendingPhysicalConnect{
                        context, profile, sourceGeneration, handoff};
                }
            }
        }
        const bool accepted = retryControllerOperation();
        record(accepted);
    }

    void onPhysicalControllerSample(
        std::uint64_t deviceId, std::uint64_t sourceGeneration,
        std::uint64_t sourceSequence, std::uint64_t monotonicTimestampUs,
        const MoonlightControllerSample& sample) noexcept override {
        std::lock_guard<std::mutex> lane(controllerLane);
        const bool drained = retryControllerOperation();
        bool retainedStandby = false;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (active && !stopping && pendingPhysicalStandby.has_value() &&
                pendingPhysicalStandby->deviceId == deviceId &&
                pendingPhysicalStandby->listenerGeneration == sourceGeneration) {
                pendingPhysicalStandby->latestSampleSequence = std::max(
                    pendingPhysicalStandby->latestSampleSequence,
                    sourceSequence);
                pendingPhysicalStandby->latestSampleTimestampUs = std::max(
                    pendingPhysicalStandby->latestSampleTimestampUs,
                    monotonicTimestampUs);
                pendingPhysicalStandby->sample = sample;
                pendingPhysicalStandby->samplePresent = true;
                retainedStandby = true;
            }
        }
        if (retainedStandby) {
            record(true);
            return;
        }
        if (!drained) {
            record(false);
            return;
        }
        std::shared_ptr<MoonlightControllerAggregator> target;
        MoonlightControllerSourceContext context;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (!active || stopping || aggregator == nullptr ||
                physicalDeviceId != deviceId ||
                physicalListenerGeneration != sourceGeneration ||
                physicalSourceGeneration == 0U) { return; }
            context = {identity, MoonlightControllerSourceKind::Physical,
                       deviceId, physicalSourceGeneration, sourceSequence,
                       monotonicTimestampUs, 0U};
            target = aggregator;
        }
        const auto result = target->ingestPhysical(context, sample);
        const bool accepted = controllerApplied(result.status);
        if (accepted) {
            std::lock_guard<std::mutex> lock(mutex);
            if (active && physicalDeviceId == deviceId &&
                physicalListenerGeneration == sourceGeneration) {
                controllerContext = context;
            }
        } else if (result.status == MoonlightControllerAggregatorStatus::Pending ||
                   result.status == MoonlightControllerAggregatorStatus::Backpressure ||
                   result.retryable) {
            std::lock_guard<std::mutex> lock(mutex);
            if (active && !stopping && physicalDeviceId == deviceId &&
                physicalListenerGeneration == sourceGeneration) {
                pendingPhysicalFrame = PendingPhysicalFrame{
                    context, sample, sourceGeneration};
            }
        }
        record(accepted);
    }

    void onPhysicalControllerDisconnected(
        std::uint64_t deviceId, std::uint64_t sourceGeneration,
        std::uint64_t sourceSequence,
        std::uint64_t monotonicTimestampUs) noexcept override {
        std::lock_guard<std::mutex> lane(controllerLane);
        bool cancelledBeforeSubmission = false;
        bool cancelledStandby = false;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (!active || stopping || aggregator == nullptr) { return; }
            if (pendingPhysicalStandby.has_value() &&
                pendingPhysicalStandby->deviceId == deviceId &&
                pendingPhysicalStandby->listenerGeneration == sourceGeneration) {
                pendingPhysicalStandby.reset();
                cancelledStandby = true;
            } else if (pendingPhysicalConnect.has_value() &&
                pendingPhysicalConnect->context.deviceId == deviceId &&
                pendingPhysicalConnect->listenerGeneration == sourceGeneration) {
                if (!pendingPhysicalConnect->submitted) {
                    // The ONLINE edge never reached the aggregator; removing
                    // the retained intent is the exact neutral outcome.
                    pendingPhysicalConnect.reset();
                    pendingPhysicalFrame.reset();
                    cancelledBeforeSubmission = true;
                } else {
                    // The aggregator owns a partial arrival/handoff. Retain
                    // OFFLINE and apply it immediately after that exact retry
                    // commits so a disconnected device cannot become active.
                    pendingPhysicalDisconnect = PendingPhysicalDisconnect{
                        deviceId, sourceGeneration, sourceSequence,
                        monotonicTimestampUs};
                }
            } else {
                if (physicalDeviceId != deviceId ||
                    physicalListenerGeneration != sourceGeneration ||
                    physicalSourceGeneration == 0U) { return; }
                controllerContext = {
                    identity, MoonlightControllerSourceKind::Physical,
                    deviceId, physicalSourceGeneration, sourceSequence,
                    monotonicTimestampUs, 0U};
                const auto flush = flushContext(true, monotonicTimestampUs);
                const auto resumeGeneration = next(operationGeneration);
                pendingLifecycle = PendingLifecycle{
                    MoonlightInputFlushTrigger::ControllerDisconnected, flush,
                    identity, resumeGeneration, LifecycleClear::Physical,
                    false, true};
            }
        }
        if (cancelledStandby) {
            record(true);
            return;
        }
        if (cancelledBeforeSubmission) {
            record(true);
            return;
        }
        const bool accepted = retryControllerOperation();
        record(accepted);
    }
};

MoonlightProductInputRuntime& MoonlightProductInputRuntime::process() noexcept {
    static MoonlightProductInputRuntime runtime;
    return runtime;
}

MoonlightProductInputRuntime::State& MoonlightProductInputRuntime::state() noexcept {
    static State value;
    return value;
}

bool MoonlightProductInputRuntime::activate(const MoonlightSessionKey& key) noexcept {
    if (!key.valid()) { return false; }
    auto& value = state();
    {
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.active && value.key == key) { return true; }
        if (value.active || value.activating) { return false; }
        value.activating = true;
    }

    const MoonlightInputIdentity identity{key, key.generation};
    auto port = createMoonlightCommonCInputPort();
    auto bridge = MoonlightInputBridge::create(
        createProcessMoonlightInputOwnerGate(), port);
    if (bridge == nullptr ||
        bridge->activate(identity, 1U).status != MoonlightInputControlStatus::Applied) {
        std::lock_guard<std::mutex> lock(value.mutex);
        value.activating = false;
        return false;
    }
    auto keyboard = MoonlightKeyboardMapper::create(bridge, identity);
    auto pointer = MoonlightPointerMapper::create(bridge, identity);
    const bool directTouch = moonlightCommonCDirectTouchAvailable();
    MoonlightTouchModeRequest touchMode;
    touchMode.requested = directTouch ? MoonlightTouchMode::Direct :
                                       MoonlightTouchMode::Touchpad;
    touchMode.directTouchAvailable = directTouch;
    touchMode.allowTouchpadFallback = true;
    auto touch = MoonlightTouchMapper::create(bridge, identity, touchMode);
    MoonlightControllerLimits controllerLimits;
    controllerLimits.api23InputAvailable = true;
    auto controller = MoonlightControllerMapper::create(
        bridge, identity, controllerLimits);
    auto flushPolicy = MoonlightInputFlushPolicy::create(
        bridge, keyboard, pointer, touch, identity, controller);
    auto aggregator = MoonlightControllerAggregator::create(
        controller, flushPolicy, identity);
    if (keyboard == nullptr || pointer == nullptr || touch == nullptr ||
        controller == nullptr || flushPolicy == nullptr || aggregator == nullptr) {
        (void)bridge->stopLocally(identity, 2U, monotonicUs());
        (void)bridge->cleanup(identity, 3U);
        std::lock_guard<std::mutex> lock(value.mutex);
        value.activating = false;
        return false;
    }

    // Install the native-owned fallback layout while the aggregator is still
    // idle. ArkTS sends only semantic element events; it never owns element
    // IDs, full-state aggregation, slot masks, or wire encoding.
    MoonlightVirtualControllerLayout fallbackCandidate;
    fallbackCandidate.version = 0U;
    fallbackCandidate.generation = 1U;
    const auto editingStarted = aggregator->setEditing(identity, true, 1U);
    const auto fallback = aggregator->installLayout(
        identity, fallbackCandidate, MoonlightControllerLayoutEnvironment{});
    const auto editingStopped = aggregator->setEditing(identity, false, 2U);
    if (!controllerApplied(editingStarted.status) ||
        (fallback.status != MoonlightVirtualControllerLayoutStatus::Fallback &&
         fallback.status != MoonlightVirtualControllerLayoutStatus::Accepted &&
         fallback.status != MoonlightVirtualControllerLayoutStatus::Clamped) ||
        !controllerApplied(editingStopped.status)) {
        (void)bridge->stopLocally(identity, 2U, monotonicUs());
        (void)bridge->cleanup(identity, 3U);
        std::lock_guard<std::mutex> lock(value.mutex);
        value.activating = false;
        return false;
    }

    std::shared_ptr<MoonlightGameControllerListener> listener;
    try {
        listener = std::make_shared<MoonlightGameControllerListener>(value);
    } catch (...) {
        listener.reset();
    }
    bool installAccepted = false;
    {
        std::lock_guard<std::mutex> lock(value.mutex);
        installAccepted = value.activating && !value.active;
        if (installAccepted) {
            value.key = key;
            value.identity = identity;
            value.operationGeneration = 2U;
            value.keyboardSequence = 0U;
            value.textSequence = 0U;
            value.pointerSequence = 0U;
            value.touchSequence = 0U;
            value.acceptedEvents = 0U;
            value.rejectedEvents = 0U;
            value.controllerSourceGeneration = 0U;
            value.physicalDeviceId = 0U;
            value.physicalListenerGeneration = 0U;
            value.physicalSourceGeneration = 0U;
            value.virtualEnabled = false;
            value.virtualEditing = false;
            value.virtualSourceGeneration = 0U;
            value.virtualSourceSequence = 0U;
            value.virtualLayout = fallback.layout;
            value.pendingVirtual.reset();
            value.pendingPhysicalConnect.reset();
            value.pendingPhysicalDisconnect.reset();
            value.pendingPhysicalFrame.reset();
            value.pendingPhysicalStandby.reset();
            value.pendingVirtualConnect.reset();
            value.pendingLifecycle.reset();
            value.controllerContext = {};
            value.directTouch = directTouch;
            value.bridge = bridge;
            value.keyboard = std::move(keyboard);
            value.pointer = std::move(pointer);
            value.touch = std::move(touch);
            value.controller = std::move(controller);
            value.flushPolicy = std::move(flushPolicy);
            value.aggregator = std::move(aggregator);
            value.listener = listener;
            value.controllerReady = true;
            value.physicalControllerReady = false;
            value.stopping = false;
            value.active = true;
        }
        value.activating = false;
    }
    if (!installAccepted) {
        (void)bridge->stopLocally(identity, 2U, monotonicUs());
        (void)bridge->cleanup(identity, 3U);
        return false;
    }
    const bool physicalListenerReady = listener != nullptr && listener->start();
    {
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.active && value.key == key && value.listener == listener) {
            // The virtual semantic ingress remains available even on devices
            // without GameControllerKit hardware. This flag means at least one
            // native controller path is ready, not that a device is connected.
            value.physicalControllerReady = physicalListenerReady;
            value.controllerReady = value.virtualLayout.generation != 0U ||
                value.physicalControllerReady;
        }
    }
    return true;
}

bool MoonlightProductInputRuntime::stop(const MoonlightSessionKey& key) noexcept {
    auto& value = state();
    std::shared_ptr<MoonlightGameControllerListener> listener;
    std::shared_ptr<MoonlightControllerAggregator> aggregator;
    std::shared_ptr<MoonlightInputBridge> bridge;
    MoonlightInputFlushContext flush;
    MoonlightInputIdentity identity;
    std::uint64_t cleanupGeneration = 0U;
    {
        std::lock_guard<std::mutex> lock(value.mutex);
        if (!value.active || value.key != key) { return false; }
        value.stopping = true;
        value.controllerReady = false;
        value.physicalControllerReady = false;
        listener = value.listener;
    }
    // Do not hold controllerLane while draining listener callbacks: an
    // already-admitted physical callback may need that lane to return.
    if (listener != nullptr) { listener->stop(); }

    std::lock_guard<std::mutex> lane(value.controllerLane);
    // Give an exact queued controller operation a bounded chance to drain
    // before the stronger terminal boundary supersedes it.
    for (std::size_t attempt = 0U; attempt < 4U; ++attempt) {
        if (value.retryControllerOperation()) { break; }
    }
    {
        std::lock_guard<std::mutex> lock(value.mutex);
        if (!value.active || value.key != key) { return false; }
        aggregator = value.aggregator;
        bridge = value.bridge;
        identity = value.identity;
        flush = value.flushContext(value.controllerContext.valid());
        cleanupGeneration = next(value.operationGeneration);
        value.pendingPhysicalConnect.reset();
        value.pendingPhysicalDisconnect.reset();
        value.pendingPhysicalFrame.reset();
        value.pendingVirtualConnect.reset();
        value.pendingVirtual.reset();
        value.pendingLifecycle.reset();
    }
    bool stopped = false;
    if (aggregator != nullptr) {
        for (std::size_t attempt = 0U; attempt < 32U && !stopped; ++attempt) {
            const auto result = aggregator->handleLifecycle(
                MoonlightInputFlushTrigger::SessionStop, flush);
            stopped = controllerApplied(result.status) ||
                result.status ==
                    MoonlightControllerAggregatorStatus::SessionTerminated;
            if (!result.retryable &&
                result.status != MoonlightControllerAggregatorStatus::Pending &&
                result.status != MoonlightControllerAggregatorStatus::Backpressure) {
                break;
            }
        }
    }
    if (!stopped && bridge != nullptr) {
        const auto status = bridge->stopLocally(
            identity, flush.operationGeneration, flush.monotonicTimestampUs).status;
        stopped = status == MoonlightInputControlStatus::Applied ||
            status == MoonlightInputControlStatus::AlreadyApplied;
    }
    if (bridge != nullptr) {
        (void)bridge->cleanup(identity, cleanupGeneration);
    }
    {
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.key == key) {
            value.active = false;
            value.key = {};
            value.identity = {};
            value.listener.reset();
            value.aggregator.reset();
            value.flushPolicy.reset();
            value.controller.reset();
            value.touch.reset();
            value.pointer.reset();
            value.keyboard.reset();
            value.bridge.reset();
            value.controllerContext = {};
            value.controllerSourceGeneration = 0U;
            value.physicalDeviceId = 0U;
            value.physicalListenerGeneration = 0U;
            value.physicalSourceGeneration = 0U;
            value.virtualEnabled = false;
            value.virtualEditing = false;
            value.virtualSourceGeneration = 0U;
            value.virtualSourceSequence = 0U;
            value.virtualLayout = {};
            value.physicalControllerReady = false;
            value.pendingPhysicalConnect.reset();
            value.pendingPhysicalDisconnect.reset();
            value.pendingPhysicalFrame.reset();
            value.pendingPhysicalStandby.reset();
            value.pendingVirtualConnect.reset();
            value.pendingVirtual.reset();
            value.pendingLifecycle.reset();
            value.stopping = false;
        }
    }
    return stopped;
}

MoonlightProductInputSnapshot MoonlightProductInputRuntime::snapshot(
    const MoonlightSessionKey& key) noexcept {
    auto& value = state();
    std::lock_guard<std::mutex> lane(value.controllerLane);
    {
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.active && !value.stopping && value.key == key) {
            // Drop the state lock before the exact common-c retry below.
        } else {
            return {};
        }
    }
    (void)value.retryControllerOperation();
    std::lock_guard<std::mutex> lock(value.mutex);
    MoonlightProductInputSnapshot result;
    result.matched = value.active && value.key == key;
    if (!result.matched) { return result; }
    result.inputReady = value.bridge != nullptr;
    result.controllerReady = value.controllerReady;
    result.physicalControllerReady = value.physicalControllerReady;
    result.inputGeneration = value.identity.inputGeneration;
    result.acceptedEvents = value.acceptedEvents;
    result.rejectedEvents = value.rejectedEvents;
    return result;
}

bool MoonlightProductInputRuntime::sendKey(
    const MoonlightSessionKey& key, std::uint32_t harmonyKeyCode,
    bool pressed, bool normalizedToUsLayout) noexcept {
    auto& value = state();
    std::shared_ptr<MoonlightKeyboardMapper> mapper;
    MoonlightKeyboardEventContext context;
    {
        std::lock_guard<std::mutex> lock(value.mutex);
        if (!value.active || value.key != key || value.keyboard == nullptr) { return false; }
        mapper = value.keyboard;
        context = value.keyboardContext(false);
    }
    const bool accepted = keyboardApplied(
        mapper->physicalKey(context, harmonyKeyCode, pressed,
                            normalizedToUsLayout).status);
    value.record(accepted);
    return accepted;
}

bool MoonlightProductInputRuntime::sendText(
    const MoonlightSessionKey& key, const std::uint8_t* text,
    std::size_t size) noexcept {
    auto& value = state();
    std::shared_ptr<MoonlightKeyboardMapper> mapper;
    MoonlightKeyboardEventContext context;
    {
        std::lock_guard<std::mutex> lock(value.mutex);
        if (!value.active || value.key != key || value.keyboard == nullptr) { return false; }
        mapper = value.keyboard;
        context = value.keyboardContext(true);
    }
    const bool accepted = keyboardApplied(mapper->commitText(context, text, size).status);
    value.record(accepted);
    return accepted;
}

bool MoonlightProductInputRuntime::sendPointer(
    const MoonlightSessionKey& key,
    const MoonlightProductPointerRequest& request) noexcept {
    auto& value = state();
    std::shared_ptr<MoonlightPointerMapper> mapper;
    MoonlightPointerEventContext context;
    {
        std::lock_guard<std::mutex> lock(value.mutex);
        if (!value.active || value.key != key || value.pointer == nullptr) { return false; }
        mapper = value.pointer;
        context = value.pointerContext();
    }
    MoonlightPointerResult result;
    if (request.action == MoonlightProductPointerAction::Relative) {
        result = mapper->relativeMotion(context, request.x, request.y);
    } else if (request.action == MoonlightProductPointerAction::Button) {
        result = mapper->button(context, request.button, request.pressed);
    } else if (request.action == MoonlightProductPointerAction::Scroll) {
        result = mapper->scroll(context, request.horizontal, request.scrollAmount);
    } else if (request.action == MoonlightProductPointerAction::Absolute) {
        MoonlightPointerContentRect content;
        content.left = request.contentLeft;
        content.top = request.contentTop;
        content.width = request.contentWidth;
        content.height = request.contentHeight;
        content.referenceWidth = request.referenceWidth;
        content.referenceHeight = request.referenceHeight;
        content.geometryGeneration = request.geometryGeneration;
        result = mapper->absolutePosition(context, content, request.x, request.y);
    } else {
        return false;
    }
    const bool accepted = pointerApplied(result.status);
    value.record(accepted);
    return accepted;
}

bool MoonlightProductInputRuntime::sendTouch(
    const MoonlightSessionKey& key,
    const MoonlightProductTouchRequest& request) noexcept {
    auto& value = state();
    std::shared_ptr<MoonlightTouchMapper> mapper;
    MoonlightTouchEventContext context;
    {
        std::lock_guard<std::mutex> lock(value.mutex);
        if (!value.active || value.key != key || value.touch == nullptr) { return false; }
        mapper = value.touch;
        context = value.touchContext();
    }
    const bool accepted = touchApplied(mapper->process(
        context, request.surface, request.contactId,
        request.phase, request.sample).status);
    value.record(accepted);
    return accepted;
}

bool MoonlightProductInputRuntime::setSuspended(
    const MoonlightSessionKey& key, MoonlightInputFlushTrigger trigger,
    bool suspended) noexcept {
    if (trigger == MoonlightInputFlushTrigger::Invalid ||
        trigger == MoonlightInputFlushTrigger::SessionStop) {
        return false;
    }
    auto& value = state();
    std::lock_guard<std::mutex> lane(value.controllerLane);
    if (!value.retryControllerOperation()) {
        value.record(false);
        return false;
    }
    std::shared_ptr<MoonlightControllerAggregator> target;
    MoonlightInputFlushContext flush;
    MoonlightInputIdentity identity;
    std::uint64_t resumeGeneration = 0U;
    {
        std::lock_guard<std::mutex> lock(value.mutex);
        if (!value.active || value.stopping || value.key != key ||
            value.aggregator == nullptr) {
            return false;
        }
        target = value.aggregator;
        identity = value.identity;
        if (suspended) {
            flush = value.flushContext(value.controllerContext.valid());
            value.pendingLifecycle = State::PendingLifecycle{
                trigger, flush, identity, 0U, State::LifecycleClear::None,
                false, false};
        } else {
            resumeGeneration = next(value.operationGeneration);
            value.pendingLifecycle = State::PendingLifecycle{
                MoonlightInputFlushTrigger::Invalid, {}, identity,
                resumeGeneration, State::LifecycleClear::None, true, true};
        }
    }
    (void)target;
    const bool accepted = value.retryControllerOperation();
    value.record(accepted);
    return accepted;
}

bool MoonlightProductInputRuntime::setTouchMode(
    const MoonlightSessionKey& key, bool direct) noexcept {
    auto& value = state();
    std::shared_ptr<MoonlightTouchMapper> target;
    MoonlightTouchEventContext context;
    {
        std::lock_guard<std::mutex> lock(value.mutex);
        if (!value.active || value.key != key || value.touch == nullptr) {
            return false;
        }
        target = value.touch;
        context = value.touchContext();
    }
    const bool accepted = touchApplied(target->switchMode(
        context, direct ? MoonlightTouchMode::Direct :
                          MoonlightTouchMode::Touchpad).status);
    if (accepted) {
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.active && value.key == key && value.touch == target) {
            value.directTouch = direct;
        }
    }
    value.record(accepted);
    return accepted;
}

bool MoonlightProductInputRuntime::setVirtualControllerMode(
    const MoonlightSessionKey& key, bool enabled, bool editing) noexcept {
    auto& value = state();
    std::lock_guard<std::mutex> lane(value.controllerLane);
    if (!value.retryControllerOperation()) {
        value.record(false);
        return false;
    }
    std::shared_ptr<MoonlightControllerAggregator> target;
    MoonlightInputIdentity identity;
    MoonlightInputFlushContext disconnect;
    bool disconnectVirtual = false;
    bool currentEditing = false;
    {
        std::lock_guard<std::mutex> lock(value.mutex);
        if (!value.active || value.stopping || value.key != key ||
            value.aggregator == nullptr ||
            value.virtualLayout.generation == 0U) {
            return false;
        }
        target = value.aggregator;
        identity = value.identity;
        currentEditing = value.virtualEditing;
        disconnectVirtual = value.controllerContext.valid() &&
            value.controllerContext.kind == MoonlightControllerSourceKind::Virtual &&
            (!enabled || editing);
        if (disconnectVirtual) {
            disconnect = value.flushContext(true);
            const auto resumeGeneration = next(value.operationGeneration);
            value.pendingLifecycle = State::PendingLifecycle{
                MoonlightInputFlushTrigger::ControllerDisconnected,
                disconnect, identity, resumeGeneration,
                State::LifecycleClear::Virtual, false, true};
        }
    }

    if (disconnectVirtual) {
        if (!value.retryControllerOperation()) {
            value.record(false);
            return false;
        }
    }

    if (currentEditing != editing) {
        std::uint64_t controlGeneration = 0U;
        {
            std::lock_guard<std::mutex> lock(value.mutex);
            controlGeneration = next(value.operationGeneration);
        }
        if (!controllerApplied(
            target->setEditing(identity, editing, controlGeneration).status)) {
            value.record(false);
            return false;
        }
    }
    {
        std::lock_guard<std::mutex> lock(value.mutex);
        if (!value.active || value.stopping || value.identity != identity) {
            return false;
        }
        value.virtualEnabled = enabled && !editing;
        value.virtualEditing = editing;
    }
    value.record(true);
    return true;
}

bool MoonlightProductInputRuntime::sendVirtualController(
    const MoonlightSessionKey& key,
    const MoonlightProductVirtualControllerRequest& request) noexcept {
    const auto kind = virtualElementKind(request.element);
    const auto phase = virtualPhase(request.phase);
    if (kind == MoonlightVirtualControllerElementKind::Invalid ||
        phase == MoonlightVirtualControllerPhase::Invalid ||
        request.pointerId == 0U || !std::isfinite(request.primary) ||
        !std::isfinite(request.secondary)) {
        return false;
    }
    auto& value = state();
    std::lock_guard<std::mutex> lane(value.controllerLane);
    if (!value.retryControllerOperation()) {
        value.record(false);
        return false;
    }
    std::shared_ptr<MoonlightControllerAggregator> target;
    MoonlightInputIdentity identity;
    MoonlightVirtualControllerLayout layout;
    {
        std::lock_guard<std::mutex> lock(value.mutex);
        if (!value.active || value.stopping || value.key != key ||
            !value.virtualEnabled || value.virtualEditing ||
            value.aggregator == nullptr ||
            value.virtualLayout.generation == 0U) {
            return false;
        }
        target = value.aggregator;
        identity = value.identity;
        layout = value.virtualLayout;
    }

    auto snapshot = target->snapshot(identity);
    if (!snapshot.matched) { return false; }
    if (snapshot.activeSource == MoonlightControllerSourceKind::Physical) {
        // Physical ownership has priority. The UI can remain visible but it
        // cannot create a second controller slot or overwrite the source.
        value.record(false);
        return false;
    }
    if (snapshot.activeSource == MoonlightControllerSourceKind::Invalid) {
        MoonlightControllerSourceContext connect;
        {
            std::lock_guard<std::mutex> lock(value.mutex);
            const std::uint64_t sourceGeneration =
                next(value.controllerSourceGeneration);
            value.virtualSourceGeneration = sourceGeneration;
            value.virtualSourceSequence = 1U;
            connect = {identity, MoonlightControllerSourceKind::Virtual,
                       kVirtualControllerDevice, sourceGeneration, 1U,
                       monotonicUs(), layout.generation};
        }
        const auto connected = target->connectVirtual(connect);
        if (!controllerApplied(connected.status)) {
            {
                std::lock_guard<std::mutex> lock(value.mutex);
                if (value.identity == identity &&
                    value.virtualSourceGeneration == connect.sourceGeneration) {
                    if (connected.status ==
                            MoonlightControllerAggregatorStatus::Pending ||
                        connected.status ==
                            MoonlightControllerAggregatorStatus::Backpressure ||
                        connected.retryable) {
                        value.pendingVirtualConnect = connect;
                    } else {
                        value.virtualSourceGeneration = 0U;
                        value.virtualSourceSequence = 0U;
                    }
                }
            }
            value.record(false);
            return false;
        }
        {
            std::lock_guard<std::mutex> lock(value.mutex);
            if (value.identity == identity) { value.controllerContext = connect; }
        }
        snapshot = target->snapshot(identity);
    }
    if (snapshot.activeSource != MoonlightControllerSourceKind::Virtual) {
        value.record(false);
        return false;
    }

    const std::uint16_t elementId = virtualElementId(layout, kind);
    if (elementId == 0U) { return false; }
    MoonlightVirtualControllerEvent event;
    {
        std::lock_guard<std::mutex> lock(value.mutex);
        if (!value.active || value.identity != identity ||
            value.virtualSourceGeneration == 0U) {
            return false;
        }
        const std::uint64_t sequence = next(value.virtualSourceSequence);
        event.context = {identity, MoonlightControllerSourceKind::Virtual,
                         kVirtualControllerDevice,
                         value.virtualSourceGeneration, sequence,
                         monotonicUs(), layout.generation};
        event.elementId = elementId;
        event.pointerId = request.pointerId;
        event.phase = phase;
        event.primary = request.primary;
        event.secondary = request.secondary;
    }
    const auto sent = target->ingestVirtual(event);
    const bool accepted = controllerApplied(sent.status);
    {
        std::lock_guard<std::mutex> lock(value.mutex);
        if (value.active && value.identity == identity) {
            if (accepted) {
                value.controllerContext = event.context;
                value.pendingVirtual.reset();
            } else if (sent.status == MoonlightControllerAggregatorStatus::Pending ||
                       sent.status == MoonlightControllerAggregatorStatus::Backpressure ||
                       sent.retryable) {
                value.pendingVirtual = event;
            }
        }
    }
    value.record(accepted);
    return accepted;
}

} // namespace remotedesk::moonlight
