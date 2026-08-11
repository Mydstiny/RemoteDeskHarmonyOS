#include "moonlight/input/MoonlightControllerAggregator.h"
#include "test/test_runner.h"

#include <array>
#include <condition_variable>
#include <cstdint>
#include <limits>
#include <memory>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

namespace {

using namespace remotedesk::moonlight;

MoonlightInputIdentity aggregateIdentity(std::uint64_t owner = 127U,
                                         std::uint64_t inputGeneration = 17U) {
    return {{1901U, 59U, owner}, inputGeneration};
}

MoonlightControllerProfile physicalProfile() {
    return {MoonlightControllerType::Xbox,
            kMoonlightControllerApi23ButtonMask, true};
}

MoonlightControllerSourceContext physicalContext(
    const MoonlightInputIdentity& identity,
    std::uint64_t sequence,
    std::uint64_t timestamp,
    std::uint64_t sourceGeneration = 1U,
    std::uint64_t deviceId = 701U) {
    return {identity, MoonlightControllerSourceKind::Physical, deviceId,
            sourceGeneration, sequence, timestamp, 0U};
}

MoonlightControllerSourceContext virtualContext(
    const MoonlightInputIdentity& identity,
    std::uint64_t sequence,
    std::uint64_t timestamp,
    std::uint64_t layoutGeneration = 7U,
    std::uint64_t sourceGeneration = 2U,
    std::uint64_t deviceId = 801U) {
    return {identity, MoonlightControllerSourceKind::Virtual, deviceId,
            sourceGeneration, sequence, timestamp, layoutGeneration};
}

class AggregateOwnerGate final : public MoonlightInputOwnerGate {
  public:
    bool withOwner(const MoonlightInputIdentity& identity,
                   MoonlightInputOwnedOperation& operation) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!available_ || identity != identity_) {
            return false;
        }
        operation.execute();
        return true;
    }

    void accept(const MoonlightInputIdentity& identity) {
        std::lock_guard<std::mutex> lock(mutex_);
        identity_ = identity;
        available_ = true;
    }

  private:
    std::mutex mutex_;
    MoonlightInputIdentity identity_{};
    bool available_ = false;
};

class AggregatePort final : public MoonlightInputPort {
  public:
    MoonlightInputPortStatus send(const MoonlightInputEvent& event) noexcept override {
        std::unique_lock<std::mutex> lock(mutex_);
        events_.push_back(event);
        if (blockNext_) {
            blockNext_ = false;
            blocked_ = true;
            condition_.notify_all();
            condition_.wait(lock, [this]() { return released_; });
            released_ = false;
            blocked_ = false;
        }
        if (sendIndex_ < sendScript_.size()) {
            return sendScript_[sendIndex_++];
        }
        return MoonlightInputPortStatus::Accepted;
    }

    bool flushNeutral(const MoonlightInputFlushRequest& request) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        flushes_.push_back(request);
        if (flushIndex_ < flushScript_.size()) {
            return flushScript_[flushIndex_++];
        }
        return true;
    }

    void setSendScript(std::vector<MoonlightInputPortStatus> script) {
        std::lock_guard<std::mutex> lock(mutex_);
        sendScript_ = std::move(script);
        sendIndex_ = 0U;
    }

    void setFlushScript(std::vector<bool> script) {
        std::lock_guard<std::mutex> lock(mutex_);
        flushScript_ = std::move(script);
        flushIndex_ = 0U;
    }

    void blockNextSend() {
        std::lock_guard<std::mutex> lock(mutex_);
        blockNext_ = true;
        blocked_ = false;
        released_ = false;
    }

    void waitUntilBlocked() {
        std::unique_lock<std::mutex> lock(mutex_);
        condition_.wait(lock, [this]() { return blocked_; });
    }

    void releaseBlockedSend() {
        std::lock_guard<std::mutex> lock(mutex_);
        released_ = true;
        condition_.notify_all();
    }

    std::size_t eventCount() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return events_.size();
    }

    std::size_t flushCount() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return flushes_.size();
    }

    MoonlightInputEvent eventAt(std::size_t index) const {
        std::lock_guard<std::mutex> lock(mutex_);
        RDP_ASSERT(index < events_.size());
        return events_[index];
    }

  private:
    mutable std::mutex mutex_;
    std::condition_variable condition_;
    std::vector<MoonlightInputPortStatus> sendScript_;
    std::vector<bool> flushScript_;
    std::size_t sendIndex_ = 0U;
    std::size_t flushIndex_ = 0U;
    std::vector<MoonlightInputEvent> events_;
    std::vector<MoonlightInputFlushRequest> flushes_;
    bool blockNext_ = false;
    bool blocked_ = false;
    bool released_ = false;
};

struct AggregateFixture final {
    AggregateFixture() {
        gate->accept(identity);
        bridge = MoonlightInputBridge::create(gate, port);
        RDP_ASSERT(bridge != nullptr);
        RDP_ASSERT_EQ(bridge->activate(identity, 1U).status,
                      MoonlightInputControlStatus::Applied);
        keyboard = MoonlightKeyboardMapper::create(bridge, identity);
        pointer = MoonlightPointerMapper::create(bridge, identity);
        MoonlightTouchModeRequest touchRequest;
        touchRequest.requested = MoonlightTouchMode::Direct;
        touchRequest.directTouchAvailable = true;
        touch = MoonlightTouchMapper::create(bridge, identity, touchRequest);
        MoonlightControllerLimits limits;
        limits.api23InputAvailable = true;
        controller = MoonlightControllerMapper::create(bridge, identity, limits);
        RDP_ASSERT(keyboard != nullptr && pointer != nullptr && touch != nullptr &&
                   controller != nullptr);
        flush = MoonlightInputFlushPolicy::create(
            bridge, keyboard, pointer, touch, identity, controller);
        RDP_ASSERT(flush != nullptr);
        aggregator = MoonlightControllerAggregator::create(
            controller, flush, identity);
        RDP_ASSERT(aggregator != nullptr);
    }

    MoonlightVirtualControllerLayout installFallback(
        std::uint64_t generation = 7U) {
        RDP_ASSERT_EQ(aggregator->setEditing(identity, true, 2U).status,
                      MoonlightControllerAggregatorStatus::Applied);
        MoonlightVirtualControllerLayout corrupt;
        corrupt.version = 999U;
        corrupt.generation = generation;
        const auto result = aggregator->installLayout(identity, corrupt, {});
        RDP_ASSERT_EQ(result.status,
                      MoonlightVirtualControllerLayoutStatus::Fallback);
        RDP_ASSERT_EQ(result.layout.elementCount, static_cast<std::size_t>(14));
        RDP_ASSERT_EQ(aggregator->setEditing(identity, false, 3U).status,
                      MoonlightControllerAggregatorStatus::Applied);
        return result.layout;
    }

    std::uint16_t elementId(
        MoonlightVirtualControllerElementKind kind) const {
        const auto current = aggregator->snapshot(identity);
        RDP_ASSERT(current.layoutGeneration != 0U);
        MoonlightVirtualControllerLayout corrupt;
        corrupt.generation = current.layoutGeneration;
        const auto fallback = validateMoonlightVirtualControllerLayout(corrupt, {});
        for (std::size_t index = 0U; index < fallback.layout.elementCount; ++index) {
            if (fallback.layout.elements[index].kind == kind) {
                return fallback.layout.elements[index].id;
            }
        }
        RDP_ASSERT(false);
        return 0U;
    }

    MoonlightInputFlushContext flushContext(
        const MoonlightControllerSourceContext& active,
        std::uint64_t operation,
        std::uint64_t timestamp,
        std::uint64_t sequence) const {
        MoonlightInputFlushContext context;
        context.identity = identity;
        context.operationGeneration = operation;
        context.monotonicTimestampUs = timestamp;
        context.touch = {identity, 401U, MoonlightInputSource::Touchscreen,
                         1U, sequence, timestamp - 4U};
        context.pointer = {identity, 402U, MoonlightInputSource::Mouse,
                           1U, sequence, timestamp - 3U};
        context.keyboard = {identity, 403U,
                            MoonlightInputSource::PhysicalKeyboard,
                            1U, sequence, timestamp - 2U};
        context.controllerContextPresent = true;
        context.controller = {
            identity, active.deviceId,
            moonlightControllerInputSource(active.kind),
            active.sourceGeneration, sequence, timestamp - 1U};
        return context;
    }

    MoonlightControllerHandoffRequest physicalToVirtual(
        std::uint64_t oldSequence = 3U) const {
        const auto oldSource = physicalContext(
            identity, oldSequence, 300U, 1U, 701U);
        MoonlightControllerHandoffRequest request;
        request.target = virtualContext(identity, 1U, 400U);
        request.disconnectFlush = flushContext(oldSource, 10U, 350U, oldSequence);
        request.resumeOperationGeneration = 11U;
        request.terminalFlush = flushContext(oldSource, 12U, 450U,
                                             oldSequence + 1U);
        return request;
    }

    MoonlightInputIdentity identity = aggregateIdentity();
    std::shared_ptr<AggregateOwnerGate> gate =
        std::make_shared<AggregateOwnerGate>();
    std::shared_ptr<AggregatePort> port =
        std::make_shared<AggregatePort>();
    std::shared_ptr<MoonlightInputBridge> bridge;
    std::shared_ptr<MoonlightKeyboardMapper> keyboard;
    std::shared_ptr<MoonlightPointerMapper> pointer;
    std::shared_ptr<MoonlightTouchMapper> touch;
    std::shared_ptr<MoonlightControllerMapper> controller;
    std::shared_ptr<MoonlightInputFlushPolicy> flush;
    std::shared_ptr<MoonlightControllerAggregator> aggregator;
};

std::uint16_t findElement(const MoonlightVirtualControllerLayout& layout,
                          MoonlightVirtualControllerElementKind kind) {
    for (std::size_t index = 0U; index < layout.elementCount; ++index) {
        if (layout.elements[index].kind == kind) {
            return layout.elements[index].id;
        }
    }
    RDP_ASSERT(false);
    return 0U;
}

MoonlightVirtualControllerEvent virtualEvent(
    const MoonlightControllerSourceContext& context,
    std::uint16_t element,
    std::uint64_t pointer,
    MoonlightVirtualControllerPhase phase,
    double primary = 0.0,
    double secondary = 0.0) {
    return {context, element, pointer, phase, primary, secondary};
}

bool rectIntersects(const MoonlightControllerNormalizedRect& left,
                    const MoonlightControllerNormalizedRect& right) {
    return left.left < right.left + right.width &&
        right.left < left.left + left.width &&
        left.top < right.top + right.height &&
        right.top < left.top + left.height;
}

RDP_TEST_CASE(moonlight_controller_layout_accepts_and_clamps_normalized_geometry) {
    MoonlightVirtualControllerLayout corrupt;
    corrupt.version = 99U;
    corrupt.generation = 1U;
    auto fallback = validateMoonlightVirtualControllerLayout(corrupt, {});
    RDP_ASSERT_EQ(fallback.status,
                  MoonlightVirtualControllerLayoutStatus::Fallback);
    auto candidate = fallback.layout;
    candidate.generation = 2U;
    candidate.elements[0U].bounds.left = -0.01;
    const auto result = validateMoonlightVirtualControllerLayout(candidate, {});
    RDP_ASSERT_EQ(result.status,
                  MoonlightVirtualControllerLayoutStatus::Clamped);
    RDP_ASSERT_EQ(result.clampedElements, static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(result.layout.elements[0U].bounds.left, 0.0);
}

RDP_TEST_CASE(moonlight_controller_layout_corruption_falls_back_as_one_unit) {
    MoonlightVirtualControllerLayout corrupt;
    corrupt.version = kMoonlightVirtualControllerLayoutVersion;
    corrupt.generation = 9U;
    corrupt.elementCount = 2U;
    corrupt.elements[0U] = {1U, MoonlightVirtualControllerElementKind::FaceA,
                            {0.1, 0.1, 0.08, 0.08}};
    corrupt.elements[1U] = corrupt.elements[0U];
    const auto result = validateMoonlightVirtualControllerLayout(corrupt, {});
    RDP_ASSERT_EQ(result.status,
                  MoonlightVirtualControllerLayoutStatus::Fallback);
    RDP_ASSERT(result.fallbackUsed);
    RDP_ASSERT_EQ(result.layout.generation, static_cast<std::uint64_t>(9));
    RDP_ASSERT_EQ(result.layout.elementCount, static_cast<std::size_t>(14));
    RDP_ASSERT_EQ(result.layout.elements[0U].id, static_cast<std::uint16_t>(1));
}

RDP_TEST_CASE(moonlight_controller_layout_conflict_zone_uses_safe_relocated_fallback) {
    MoonlightVirtualControllerLayout corrupt;
    corrupt.version = 99U;
    corrupt.generation = 1U;
    auto baseline = validateMoonlightVirtualControllerLayout(corrupt, {});
    auto candidate = baseline.layout;
    candidate.generation = 2U;
    MoonlightControllerLayoutEnvironment environment;
    environment.conflictZoneCount = 1U;
    environment.conflictZones[0U] = candidate.elements[0U].bounds;
    const auto result = validateMoonlightVirtualControllerLayout(candidate, environment);
    RDP_ASSERT_EQ(result.status,
                  MoonlightVirtualControllerLayoutStatus::Fallback);
    for (std::size_t index = 0U; index < result.layout.elementCount; ++index) {
        RDP_ASSERT(!rectIntersects(result.layout.elements[index].bounds,
                                   environment.conflictZones[0U]));
    }
}

RDP_TEST_CASE(moonlight_controller_layout_invalid_environment_fails_closed) {
    MoonlightVirtualControllerLayout candidate;
    candidate.generation = 1U;
    MoonlightControllerLayoutEnvironment environment;
    environment.safeArea.leftInset = 0.4;
    const auto result = validateMoonlightVirtualControllerLayout(candidate, environment);
    RDP_ASSERT_EQ(result.status,
                  MoonlightVirtualControllerLayoutStatus::InvalidEnvironment);
    RDP_ASSERT_EQ(result.layout.elementCount, static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_controller_edit_mode_and_layout_install_are_zero_send) {
    AggregateFixture fixture;
    RDP_ASSERT_EQ(fixture.aggregator->setEditing(
        fixture.identity, true, 2U).status,
        MoonlightControllerAggregatorStatus::Applied);
    MoonlightVirtualControllerLayout corrupt;
    corrupt.version = 99U;
    corrupt.generation = 7U;
    const auto layout = fixture.aggregator->installLayout(
        fixture.identity, corrupt, {});
    RDP_ASSERT_EQ(layout.status,
                  MoonlightVirtualControllerLayoutStatus::Fallback);
    const auto event = virtualEvent(
        virtualContext(fixture.identity, 1U, 100U),
        findElement(layout.layout, MoonlightVirtualControllerElementKind::FaceA),
        1U, MoonlightVirtualControllerPhase::Begin);
    RDP_ASSERT_EQ(fixture.aggregator->ingestVirtual(event).status,
                  MoonlightControllerAggregatorStatus::Editing);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(0));
    RDP_ASSERT_EQ(fixture.port->flushCount(), static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_controller_virtual_semantics_emit_atomic_full_state) {
    AggregateFixture fixture;
    const auto layout = fixture.installFallback();
    RDP_ASSERT_EQ(fixture.aggregator->connectVirtual(
        virtualContext(fixture.identity, 1U, 100U)).status,
        MoonlightControllerAggregatorStatus::Applied);
    RDP_ASSERT_EQ(fixture.aggregator->ingestVirtual(virtualEvent(
        virtualContext(fixture.identity, 2U, 110U),
        findElement(layout, MoonlightVirtualControllerElementKind::FaceA),
        1U, MoonlightVirtualControllerPhase::Begin)).status,
        MoonlightControllerAggregatorStatus::Applied);
    RDP_ASSERT_EQ(fixture.aggregator->ingestVirtual(virtualEvent(
        virtualContext(fixture.identity, 3U, 120U),
        findElement(layout, MoonlightVirtualControllerElementKind::FaceB),
        2U, MoonlightVirtualControllerPhase::Begin)).status,
        MoonlightControllerAggregatorStatus::Applied);
    RDP_ASSERT_EQ(fixture.aggregator->ingestVirtual(virtualEvent(
        virtualContext(fixture.identity, 4U, 130U),
        findElement(layout, MoonlightVirtualControllerElementKind::LeftStick),
        3U, MoonlightVirtualControllerPhase::Begin, 0.5, -0.5)).status,
        MoonlightControllerAggregatorStatus::Applied);
    RDP_ASSERT_EQ(fixture.aggregator->ingestVirtual(virtualEvent(
        virtualContext(fixture.identity, 5U, 140U),
        findElement(layout, MoonlightVirtualControllerElementKind::RightTrigger),
        4U, MoonlightVirtualControllerPhase::Begin, 0.75, 0.0)).status,
        MoonlightControllerAggregatorStatus::Applied);
    RDP_ASSERT_EQ(fixture.aggregator->ingestVirtual(virtualEvent(
        virtualContext(fixture.identity, 6U, 150U),
        findElement(layout, MoonlightVirtualControllerElementKind::DpadCluster),
        5U, MoonlightVirtualControllerPhase::Begin, 1.0, -1.0)).status,
        MoonlightControllerAggregatorStatus::Applied);

    MoonlightControllerWireCommand command;
    RDP_ASSERT(decodeMoonlightControllerCommand(
        fixture.port->eventAt(fixture.port->eventCount() - 1U), command));
    RDP_ASSERT_EQ(command.state.buttonFlags,
                  kMoonlightControllerButtonA |
                      kMoonlightControllerButtonB |
                      kMoonlightControllerButtonRight |
                      kMoonlightControllerButtonUp);
    RDP_ASSERT_EQ(command.state.leftStickX, static_cast<std::int16_t>(16383));
    RDP_ASSERT_EQ(command.state.leftStickY, static_cast<std::int16_t>(16383));
    RDP_ASSERT_EQ(command.state.rightTrigger, static_cast<std::uint8_t>(191));
    const auto snapshot = fixture.aggregator->snapshot(fixture.identity);
    RDP_ASSERT_EQ(snapshot.activeContacts, static_cast<std::size_t>(5));
    RDP_ASSERT_EQ(snapshot.activeSource, MoonlightControllerSourceKind::Virtual);
}

RDP_TEST_CASE(moonlight_controller_virtual_cancel_releases_only_owned_contact) {
    AggregateFixture fixture;
    const auto layout = fixture.installFallback();
    RDP_ASSERT_EQ(fixture.aggregator->connectVirtual(
        virtualContext(fixture.identity, 1U, 100U)).status,
        MoonlightControllerAggregatorStatus::Applied);
    const auto a = findElement(layout, MoonlightVirtualControllerElementKind::FaceA);
    const auto b = findElement(layout, MoonlightVirtualControllerElementKind::FaceB);
    RDP_ASSERT_EQ(fixture.aggregator->ingestVirtual(virtualEvent(
        virtualContext(fixture.identity, 2U, 110U), a, 1U,
        MoonlightVirtualControllerPhase::Begin)).status,
        MoonlightControllerAggregatorStatus::Applied);
    RDP_ASSERT_EQ(fixture.aggregator->ingestVirtual(virtualEvent(
        virtualContext(fixture.identity, 3U, 120U), b, 2U,
        MoonlightVirtualControllerPhase::Begin)).status,
        MoonlightControllerAggregatorStatus::Applied);
    RDP_ASSERT_EQ(fixture.aggregator->ingestVirtual(virtualEvent(
        virtualContext(fixture.identity, 4U, 130U), a, 1U,
        MoonlightVirtualControllerPhase::Cancel)).status,
        MoonlightControllerAggregatorStatus::Applied);
    const auto snapshot = fixture.aggregator->snapshot(fixture.identity);
    RDP_ASSERT_EQ(snapshot.activeContacts, static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(snapshot.sample.buttonFlags, kMoonlightControllerButtonB);
}

RDP_TEST_CASE(moonlight_controller_physical_ingress_uses_same_mapper_full_state_path) {
    AggregateFixture fixture;
    RDP_ASSERT_EQ(fixture.aggregator->connectPhysical(
        physicalContext(fixture.identity, 1U, 100U), physicalProfile()).status,
        MoonlightControllerAggregatorStatus::Applied);
    MoonlightControllerSample sample;
    sample.buttonFlags = kMoonlightControllerButtonX;
    sample.leftStickX = -1.0;
    sample.leftTrigger = 0.5;
    RDP_ASSERT_EQ(fixture.aggregator->ingestPhysical(
        physicalContext(fixture.identity, 2U, 110U), sample).status,
        MoonlightControllerAggregatorStatus::Applied);
    const auto event = fixture.port->eventAt(1U);
    RDP_ASSERT_EQ(event.source, MoonlightInputSource::GameController);
    MoonlightControllerWireCommand command;
    RDP_ASSERT(decodeMoonlightControllerCommand(event, command));
    RDP_ASSERT_EQ(command.state.buttonFlags, kMoonlightControllerButtonX);
    RDP_ASSERT_EQ(command.state.leftStickX, static_cast<std::int16_t>(-32766));
}

RDP_TEST_CASE(moonlight_controller_backpressure_keeps_one_exact_pending_frame) {
    AggregateFixture fixture;
    const auto layout = fixture.installFallback();
    RDP_ASSERT_EQ(fixture.aggregator->connectVirtual(
        virtualContext(fixture.identity, 1U, 100U)).status,
        MoonlightControllerAggregatorStatus::Applied);
    fixture.port->setSendScript({MoonlightInputPortStatus::Backpressure,
                                 MoonlightInputPortStatus::Accepted});
    const auto event = virtualEvent(
        virtualContext(fixture.identity, 2U, 110U),
        findElement(layout, MoonlightVirtualControllerElementKind::FaceA),
        1U, MoonlightVirtualControllerPhase::Begin);
    RDP_ASSERT_EQ(fixture.aggregator->ingestVirtual(event).status,
                  MoonlightControllerAggregatorStatus::Pending);
    auto snapshot = fixture.aggregator->snapshot(fixture.identity);
    RDP_ASSERT(snapshot.pendingFrame);
    RDP_ASSERT_EQ(snapshot.activeContacts, static_cast<std::size_t>(0));
    const auto eventsBeforeOvertake = fixture.port->eventCount();
    auto overtaking = event;
    overtaking.context.sourceSequence = 3U;
    overtaking.context.monotonicTimestampUs = 120U;
    RDP_ASSERT_EQ(fixture.aggregator->ingestVirtual(overtaking).status,
                  MoonlightControllerAggregatorStatus::Pending);
    RDP_ASSERT_EQ(fixture.port->eventCount(), eventsBeforeOvertake);
    RDP_ASSERT_EQ(fixture.aggregator->ingestVirtual(event).status,
                  MoonlightControllerAggregatorStatus::Applied);
    snapshot = fixture.aggregator->snapshot(fixture.identity);
    RDP_ASSERT(!snapshot.pendingFrame);
    RDP_ASSERT_EQ(snapshot.activeContacts, static_cast<std::size_t>(1));
}

RDP_TEST_CASE(moonlight_controller_stale_layout_source_and_invalid_values_are_zero_send) {
    AggregateFixture fixture;
    const auto layout = fixture.installFallback();
    RDP_ASSERT_EQ(fixture.aggregator->connectVirtual(
        virtualContext(fixture.identity, 1U, 100U)).status,
        MoonlightControllerAggregatorStatus::Applied);
    const auto count = fixture.port->eventCount();
    auto staleLayout = virtualEvent(
        virtualContext(fixture.identity, 2U, 110U, 8U),
        findElement(layout, MoonlightVirtualControllerElementKind::LeftStick),
        1U, MoonlightVirtualControllerPhase::Begin, 0.5, 0.5);
    RDP_ASSERT_EQ(fixture.aggregator->ingestVirtual(staleLayout).status,
                  MoonlightControllerAggregatorStatus::StaleLayout);
    auto invalid = virtualEvent(
        virtualContext(fixture.identity, 2U, 110U),
        findElement(layout, MoonlightVirtualControllerElementKind::LeftStick),
        1U, MoonlightVirtualControllerPhase::Begin,
        std::numeric_limits<double>::infinity(), 0.0);
    RDP_ASSERT_EQ(fixture.aggregator->ingestVirtual(invalid).status,
                  MoonlightControllerAggregatorStatus::InvalidRequest);
    RDP_ASSERT_EQ(fixture.port->eventCount(), count);
}

RDP_TEST_CASE(moonlight_controller_source_handoff_removes_slot_before_new_arrival) {
    AggregateFixture fixture;
    fixture.installFallback();
    RDP_ASSERT_EQ(fixture.aggregator->connectPhysical(
        physicalContext(fixture.identity, 1U, 100U), physicalProfile()).status,
        MoonlightControllerAggregatorStatus::Applied);
    MoonlightControllerSample sample;
    sample.buttonFlags = kMoonlightControllerButtonA;
    RDP_ASSERT_EQ(fixture.aggregator->ingestPhysical(
        physicalContext(fixture.identity, 2U, 120U), sample).status,
        MoonlightControllerAggregatorStatus::Applied);
    const auto request = fixture.physicalToVirtual();
    RDP_ASSERT_EQ(fixture.aggregator->switchSource(request).status,
                  MoonlightControllerAggregatorStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(4));
    MoonlightControllerWireCommand removal;
    MoonlightControllerWireCommand arrival;
    RDP_ASSERT(decodeMoonlightControllerCommand(fixture.port->eventAt(2U), removal));
    RDP_ASSERT(decodeMoonlightControllerCommand(fixture.port->eventAt(3U), arrival));
    RDP_ASSERT_EQ(removal.activeGamepadMask, static_cast<std::uint16_t>(0));
    RDP_ASSERT_EQ(fixture.port->eventAt(2U).source,
                  MoonlightInputSource::GameController);
    RDP_ASSERT_EQ(arrival.operation,
                  MoonlightControllerCommandOperation::Arrival);
    RDP_ASSERT_EQ(fixture.port->eventAt(3U).source,
                  MoonlightInputSource::VirtualController);
    const auto snapshot = fixture.aggregator->snapshot(fixture.identity);
    RDP_ASSERT_EQ(snapshot.activeSource, MoonlightControllerSourceKind::Virtual);
    RDP_ASSERT_EQ(snapshot.sample.buttonFlags, static_cast<std::uint32_t>(0));
    RDP_ASSERT_EQ(snapshot.handoffs, static_cast<std::uint64_t>(1));
}

RDP_TEST_CASE(moonlight_controller_virtual_to_physical_handoff_is_also_remove_first) {
    AggregateFixture fixture;
    const auto layout = fixture.installFallback();
    const auto oldSource = virtualContext(fixture.identity, 1U, 100U);
    RDP_ASSERT_EQ(fixture.aggregator->connectVirtual(oldSource).status,
                  MoonlightControllerAggregatorStatus::Applied);
    RDP_ASSERT_EQ(fixture.aggregator->ingestVirtual(virtualEvent(
        virtualContext(fixture.identity, 2U, 120U),
        findElement(layout, MoonlightVirtualControllerElementKind::FaceX),
        1U, MoonlightVirtualControllerPhase::Begin)).status,
        MoonlightControllerAggregatorStatus::Applied);
    MoonlightControllerHandoffRequest request;
    request.target = physicalContext(fixture.identity, 1U, 400U, 3U, 901U);
    request.targetPhysicalProfile = physicalProfile();
    request.disconnectFlush = fixture.flushContext(
        oldSource, 10U, 350U, 3U);
    request.resumeOperationGeneration = 11U;
    request.terminalFlush = fixture.flushContext(
        oldSource, 12U, 450U, 4U);
    RDP_ASSERT_EQ(fixture.aggregator->switchSource(request).status,
                  MoonlightControllerAggregatorStatus::Applied);
    MoonlightControllerWireCommand removal;
    MoonlightControllerWireCommand arrival;
    RDP_ASSERT(decodeMoonlightControllerCommand(fixture.port->eventAt(2U), removal));
    RDP_ASSERT(decodeMoonlightControllerCommand(fixture.port->eventAt(3U), arrival));
    RDP_ASSERT_EQ(removal.activeGamepadMask, static_cast<std::uint16_t>(0));
    RDP_ASSERT_EQ(fixture.port->eventAt(2U).source,
                  MoonlightInputSource::VirtualController);
    RDP_ASSERT_EQ(fixture.port->eventAt(3U).source,
                  MoonlightInputSource::GameController);
    RDP_ASSERT_EQ(fixture.aggregator->snapshot(fixture.identity).activeSource,
                  MoonlightControllerSourceKind::Physical);
}

RDP_TEST_CASE(moonlight_controller_handoff_backpressure_retries_exact_removal) {
    AggregateFixture fixture;
    fixture.installFallback();
    RDP_ASSERT_EQ(fixture.aggregator->connectPhysical(
        physicalContext(fixture.identity, 1U, 100U), physicalProfile()).status,
        MoonlightControllerAggregatorStatus::Applied);
    fixture.port->setSendScript({MoonlightInputPortStatus::Backpressure,
                                 MoonlightInputPortStatus::Accepted,
                                 MoonlightInputPortStatus::Accepted});
    const auto request = fixture.physicalToVirtual(2U);
    RDP_ASSERT_EQ(fixture.aggregator->switchSource(request).status,
                  MoonlightControllerAggregatorStatus::Pending);
    RDP_ASSERT(fixture.controller->snapshot(fixture.identity).active);
    auto different = request;
    different.target.sourceGeneration = 3U;
    RDP_ASSERT_EQ(fixture.aggregator->switchSource(different).status,
                  MoonlightControllerAggregatorStatus::Pending);
    RDP_ASSERT_EQ(fixture.aggregator->switchSource(request).status,
                  MoonlightControllerAggregatorStatus::Applied);
    RDP_ASSERT_EQ(fixture.aggregator->snapshot(fixture.identity).activeSource,
                  MoonlightControllerSourceKind::Virtual);
}

RDP_TEST_CASE(moonlight_controller_failed_removal_terminates_without_new_source) {
    AggregateFixture fixture;
    fixture.installFallback();
    RDP_ASSERT_EQ(fixture.aggregator->connectPhysical(
        physicalContext(fixture.identity, 1U, 100U), physicalProfile()).status,
        MoonlightControllerAggregatorStatus::Applied);
    fixture.port->setSendScript({MoonlightInputPortStatus::Unsupported});
    const auto result = fixture.aggregator->switchSource(
        fixture.physicalToVirtual(2U));
    RDP_ASSERT_EQ(result.status,
                  MoonlightControllerAggregatorStatus::SessionTerminated);
    const auto snapshot = fixture.aggregator->snapshot(fixture.identity);
    RDP_ASSERT_EQ(snapshot.state, MoonlightControllerAggregatorState::Stopped);
    RDP_ASSERT_EQ(snapshot.activeSource, MoonlightControllerSourceKind::Invalid);
    RDP_ASSERT_EQ(snapshot.terminalStops, static_cast<std::uint64_t>(1));
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(2));
}

RDP_TEST_CASE(moonlight_controller_terminal_boundary_failure_uses_local_stop) {
    AggregateFixture fixture;
    fixture.installFallback();
    RDP_ASSERT_EQ(fixture.aggregator->connectPhysical(
        physicalContext(fixture.identity, 1U, 100U), physicalProfile()).status,
        MoonlightControllerAggregatorStatus::Applied);
    fixture.port->setSendScript({MoonlightInputPortStatus::Unsupported});
    fixture.port->setFlushScript({false});
    const auto result = fixture.aggregator->switchSource(
        fixture.physicalToVirtual(2U));
    RDP_ASSERT_EQ(result.status,
                  MoonlightControllerAggregatorStatus::SessionTerminated);
    RDP_ASSERT_EQ(result.flushStatus,
                  MoonlightInputFlushStatus::AppliedLocally);
    RDP_ASSERT_EQ(fixture.bridge->snapshot(fixture.identity).state,
                  MoonlightInputState::Stopped);
}

RDP_TEST_CASE(moonlight_controller_direct_second_source_cannot_bypass_handoff) {
    AggregateFixture fixture;
    fixture.installFallback();
    RDP_ASSERT_EQ(fixture.aggregator->connectPhysical(
        physicalContext(fixture.identity, 1U, 100U), physicalProfile()).status,
        MoonlightControllerAggregatorStatus::Applied);
    const auto count = fixture.port->eventCount();
    RDP_ASSERT_EQ(fixture.aggregator->connectVirtual(
        virtualContext(fixture.identity, 1U, 120U)).status,
        MoonlightControllerAggregatorStatus::InvalidState);
    RDP_ASSERT_EQ(fixture.port->eventCount(), count);
}

RDP_TEST_CASE(moonlight_controller_all_lifecycle_triggers_reuse_n3_07_release) {
    constexpr std::array<MoonlightInputFlushTrigger, 12U> triggers{{
        MoonlightInputFlushTrigger::OverlayOpened,
        MoonlightInputFlushTrigger::ControlModeChanged,
        MoonlightInputFlushTrigger::DisplayRotated,
        MoonlightInputFlushTrigger::FocusLost,
        MoonlightInputFlushTrigger::PipEntered,
        MoonlightInputFlushTrigger::Backgrounded,
        MoonlightInputFlushTrigger::ScreenLocked,
        MoonlightInputFlushTrigger::SurfaceDetached,
        MoonlightInputFlushTrigger::ReconnectStarted,
        MoonlightInputFlushTrigger::SessionStop,
        MoonlightInputFlushTrigger::InputGenerationChanged,
        MoonlightInputFlushTrigger::ControllerDisconnected,
    }};
    for (std::size_t index = 0U; index < triggers.size(); ++index) {
        AggregateFixture fixture;
        const auto layout = fixture.installFallback();
        const auto source = virtualContext(fixture.identity, 1U, 100U);
        RDP_ASSERT_EQ(fixture.aggregator->connectVirtual(source).status,
                      MoonlightControllerAggregatorStatus::Applied);
        RDP_ASSERT_EQ(fixture.aggregator->ingestVirtual(virtualEvent(
            virtualContext(fixture.identity, 2U, 110U),
            findElement(layout, MoonlightVirtualControllerElementKind::FaceA),
            1U, MoonlightVirtualControllerPhase::Begin)).status,
            MoonlightControllerAggregatorStatus::Applied);
        const auto context = fixture.flushContext(source, 10U, 300U, 3U);
        const auto result = fixture.aggregator->handleLifecycle(
            triggers[index], context);
        RDP_ASSERT(result.status == MoonlightControllerAggregatorStatus::Applied ||
                   result.status == MoonlightControllerAggregatorStatus::AppliedLocally);
        const auto snapshot = fixture.aggregator->snapshot(fixture.identity);
        if (moonlightInputFlushDisposition(triggers[index]) ==
            MoonlightInputFlushDisposition::Stop) {
            RDP_ASSERT_EQ(snapshot.state,
                          MoonlightControllerAggregatorState::Stopped);
        } else {
            RDP_ASSERT_EQ(snapshot.state,
                          MoonlightControllerAggregatorState::Suspended);
            RDP_ASSERT_EQ(snapshot.sample.buttonFlags,
                          static_cast<std::uint32_t>(0));
        }
    }
}

RDP_TEST_CASE(moonlight_controller_lifecycle_suspend_resumes_same_neutral_source) {
    AggregateFixture fixture;
    const auto layout = fixture.installFallback();
    const auto source = virtualContext(fixture.identity, 1U, 100U);
    RDP_ASSERT_EQ(fixture.aggregator->connectVirtual(source).status,
                  MoonlightControllerAggregatorStatus::Applied);
    RDP_ASSERT_EQ(fixture.aggregator->ingestVirtual(virtualEvent(
        virtualContext(fixture.identity, 2U, 110U),
        findElement(layout, MoonlightVirtualControllerElementKind::FaceY),
        1U, MoonlightVirtualControllerPhase::Begin)).status,
        MoonlightControllerAggregatorStatus::Applied);
    RDP_ASSERT_EQ(fixture.aggregator->handleLifecycle(
        MoonlightInputFlushTrigger::Backgrounded,
        fixture.flushContext(source, 10U, 300U, 3U)).status,
        MoonlightControllerAggregatorStatus::Applied);
    RDP_ASSERT_EQ(fixture.aggregator->resumeLifecycle(
        fixture.identity, 11U).status,
        MoonlightControllerAggregatorStatus::Applied);
    const auto snapshot = fixture.aggregator->snapshot(fixture.identity);
    RDP_ASSERT_EQ(snapshot.state, MoonlightControllerAggregatorState::Active);
    RDP_ASSERT_EQ(snapshot.activeSource, MoonlightControllerSourceKind::Virtual);
    RDP_ASSERT_EQ(snapshot.activeContacts, static_cast<std::size_t>(0));
    RDP_ASSERT_EQ(snapshot.sample.buttonFlags, static_cast<std::uint32_t>(0));
}

RDP_TEST_CASE(moonlight_controller_layout_swap_is_edit_only_and_generation_fenced) {
    AggregateFixture fixture;
    fixture.installFallback();
    RDP_ASSERT_EQ(fixture.aggregator->connectVirtual(
        virtualContext(fixture.identity, 1U, 100U)).status,
        MoonlightControllerAggregatorStatus::Applied);
    MoonlightVirtualControllerLayout candidate;
    candidate.generation = 8U;
    RDP_ASSERT_EQ(fixture.aggregator->installLayout(
        fixture.identity, candidate, {}).status,
        MoonlightVirtualControllerLayoutStatus::InvalidState);
    RDP_ASSERT_EQ(fixture.aggregator->setEditing(
        fixture.identity, true, 4U).status,
        MoonlightControllerAggregatorStatus::InvalidState);
}

RDP_TEST_CASE(moonlight_controller_concurrent_physical_frames_are_serialized) {
    AggregateFixture fixture;
    RDP_ASSERT_EQ(fixture.aggregator->connectPhysical(
        physicalContext(fixture.identity, 1U, 100U), physicalProfile()).status,
        MoonlightControllerAggregatorStatus::Applied);
    fixture.port->blockNextSend();
    MoonlightControllerSample firstSample;
    firstSample.buttonFlags = kMoonlightControllerButtonA;
    MoonlightControllerSample secondSample;
    secondSample.buttonFlags = kMoonlightControllerButtonB;
    MoonlightControllerAggregatorResult first;
    MoonlightControllerAggregatorResult second;
    std::thread firstThread([&]() {
        first = fixture.aggregator->ingestPhysical(
            physicalContext(fixture.identity, 2U, 110U), firstSample);
    });
    fixture.port->waitUntilBlocked();
    std::thread secondThread([&]() {
        second = fixture.aggregator->ingestPhysical(
            physicalContext(fixture.identity, 3U, 120U), secondSample);
    });
    fixture.port->releaseBlockedSend();
    firstThread.join();
    secondThread.join();
    RDP_ASSERT_EQ(first.status, MoonlightControllerAggregatorStatus::Applied);
    RDP_ASSERT_EQ(second.status, MoonlightControllerAggregatorStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->eventAt(1U).sourceSequence,
                  static_cast<std::uint64_t>(2));
    RDP_ASSERT_EQ(fixture.port->eventAt(2U).sourceSequence,
                  static_cast<std::uint64_t>(3));
    RDP_ASSERT_EQ(fixture.aggregator->snapshot(fixture.identity).sample.buttonFlags,
                  kMoonlightControllerButtonB);
}

} // namespace
