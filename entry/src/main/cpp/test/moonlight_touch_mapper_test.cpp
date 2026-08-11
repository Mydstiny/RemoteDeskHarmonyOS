#include "moonlight/input/MoonlightTouchMapper.h"
#include "test/test_runner.h"

#include <cmath>
#include <cstdint>
#include <limits>
#include <memory>
#include <mutex>
#include <utility>
#include <vector>

namespace {

using namespace remotedesk::moonlight;

MoonlightInputIdentity touchIdentity(std::uint64_t ownerToken = 93U,
                                     std::uint64_t inputGeneration = 5U) {
    return {{1301U, 41U, ownerToken}, inputGeneration};
}

MoonlightTouchEventContext touchContext(
    const MoonlightInputIdentity& identity,
    std::uint64_t sequence,
    std::uint64_t timestampUs,
    MoonlightInputSource source = MoonlightInputSource::Touchscreen,
    std::uint64_t deviceId = 61U,
    std::uint64_t sourceGeneration = 1U) {
    return {identity, deviceId, source, sourceGeneration, sequence, timestampUs};
}

MoonlightTouchSurface touchSurface(std::uint64_t geometryGeneration = 1U,
                                   std::uint64_t hitMapGeneration = 1U,
                                   std::uint8_t quarterTurns = 0U) {
    MoonlightTouchSurface surface;
    surface.content = {100.0, 50.0, 800.0, 450.0, 1920U, 1080U,
                       quarterTurns, geometryGeneration};
    surface.hitMapGeneration = hitMapGeneration;
    return surface;
}

MoonlightTouchSample touchSample(double x = 500.0,
                                 double y = 275.0,
                                 float pressure = 0.5F,
                                 float major = 0.02F,
                                 float minor = 0.01F,
                                 std::uint16_t rotation =
                                     kMoonlightTouchRotationUnknown) {
    return {x, y, pressure, major, minor, rotation};
}

class TouchOwnerGate final : public MoonlightInputOwnerGate {
  public:
    bool withOwner(const MoonlightInputIdentity& identity,
                   MoonlightInputOwnedOperation& operation) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!available_ || identity != accepted_) {
            return false;
        }
        operation.execute();
        return true;
    }

    void accept(const MoonlightInputIdentity& identity) {
        std::lock_guard<std::mutex> lock(mutex_);
        accepted_ = identity;
        available_ = true;
    }

  private:
    std::mutex mutex_;
    MoonlightInputIdentity accepted_{};
    bool available_ = false;
};

class TouchPort final : public MoonlightInputPort {
  public:
    MoonlightInputPortStatus send(const MoonlightInputEvent& event) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        events_.push_back(event);
        if (scriptIndex_ < script_.size()) {
            return script_[scriptIndex_++];
        }
        return status;
    }

    bool flushNeutral(const MoonlightInputFlushRequest&) noexcept override {
        return true;
    }

    void setScript(std::vector<MoonlightInputPortStatus> script) {
        std::lock_guard<std::mutex> lock(mutex_);
        script_ = std::move(script);
        scriptIndex_ = 0U;
    }

    MoonlightInputEvent eventAt(std::size_t index) const {
        std::lock_guard<std::mutex> lock(mutex_);
        RDP_ASSERT(index < events_.size());
        return events_[index];
    }

    std::size_t eventCount() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return events_.size();
    }

    MoonlightInputPortStatus status = MoonlightInputPortStatus::Accepted;

  private:
    mutable std::mutex mutex_;
    std::vector<MoonlightInputPortStatus> script_;
    std::size_t scriptIndex_ = 0U;
    std::vector<MoonlightInputEvent> events_;
};

struct TouchFixture final {
    explicit TouchFixture(MoonlightTouchMode requested = MoonlightTouchMode::Direct,
                          bool directAvailable = true,
                          MoonlightTouchLimits limits = {}) {
        gate->accept(identity);
        bridge = MoonlightInputBridge::create(gate, port);
        RDP_ASSERT(bridge != nullptr);
        RDP_ASSERT_EQ(bridge->activate(identity, 1U).status,
                      MoonlightInputControlStatus::Applied);
        MoonlightTouchModeRequest request;
        request.requested = requested;
        request.directTouchAvailable = directAvailable;
        mapper = MoonlightTouchMapper::create(bridge, identity, request, limits);
        RDP_ASSERT(mapper != nullptr);
    }

    MoonlightInputIdentity identity = touchIdentity();
    std::shared_ptr<TouchOwnerGate> gate = std::make_shared<TouchOwnerGate>();
    std::shared_ptr<TouchPort> port = std::make_shared<TouchPort>();
    std::shared_ptr<MoonlightInputBridge> bridge;
    std::shared_ptr<MoonlightTouchMapper> mapper;
};

RDP_TEST_CASE(moonlight_touch_mode_resolution_is_explicit_and_fail_closed) {
    MoonlightTouchModeRequest request;
    request.requested = MoonlightTouchMode::Direct;
    request.directTouchAvailable = true;
    auto resolved = resolveMoonlightTouchMode(request);
    RDP_ASSERT_EQ(resolved.status, MoonlightTouchModeStatus::Ready);
    RDP_ASSERT_EQ(resolved.effective, MoonlightTouchMode::Direct);

    request.directTouchAvailable = false;
    resolved = resolveMoonlightTouchMode(request);
    RDP_ASSERT_EQ(resolved.status, MoonlightTouchModeStatus::Degraded);
    RDP_ASSERT_EQ(resolved.effective, MoonlightTouchMode::Touchpad);

    request.allowTouchpadFallback = false;
    RDP_ASSERT_EQ(resolveMoonlightTouchMode(request).status,
                  MoonlightTouchModeStatus::Unsupported);
    request = {};
    request.requested = static_cast<MoonlightTouchMode>(99U);
    RDP_ASSERT_EQ(resolveMoonlightTouchMode(request).status,
                  MoonlightTouchModeStatus::InvalidRequest);
}

RDP_TEST_CASE(moonlight_touch_direct_multitouch_keeps_stable_wire_ids) {
    TouchFixture fixture;
    const auto surface = touchSurface();
    auto result = fixture.mapper->process(
        touchContext(fixture.identity, 1U, 100U), surface, 7001U,
        MoonlightTouchPhase::Down, touchSample());
    RDP_ASSERT_EQ(result.status, MoonlightTouchStatus::Applied);
    result = fixture.mapper->process(
        touchContext(fixture.identity, 2U, 110U), surface, 7002U,
        MoonlightTouchPhase::Down, touchSample(300.0, 150.0));
    RDP_ASSERT_EQ(result.status, MoonlightTouchStatus::Applied);
    result = fixture.mapper->process(
        touchContext(fixture.identity, 3U, 120U), surface, 7001U,
        MoonlightTouchPhase::Move, touchSample(600.0, 300.0));
    RDP_ASSERT_EQ(result.status, MoonlightTouchStatus::Applied);

    MoonlightTouchWireCommand first;
    MoonlightTouchWireCommand second;
    MoonlightTouchWireCommand moved;
    RDP_ASSERT(decodeMoonlightTouchCommand(fixture.port->eventAt(0U), first));
    RDP_ASSERT(decodeMoonlightTouchCommand(fixture.port->eventAt(1U), second));
    RDP_ASSERT(decodeMoonlightTouchCommand(fixture.port->eventAt(2U), moved));
    RDP_ASSERT_EQ(first.eventType, kMoonlightTouchEventDown);
    RDP_ASSERT_EQ(second.eventType, kMoonlightTouchEventDown);
    RDP_ASSERT(first.pointerId != 0U);
    RDP_ASSERT(second.pointerId != 0U);
    RDP_ASSERT(first.pointerId != second.pointerId);
    RDP_ASSERT_EQ(moved.pointerId, first.pointerId);
    RDP_ASSERT_EQ(moved.eventType, kMoonlightTouchEventMove);
    RDP_ASSERT(std::fabs(moved.x - 0.625F) < 0.00001F);
    RDP_ASSERT(std::fabs(moved.y - (250.0F / 450.0F)) < 0.00001F);
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).activeDirectContacts,
                  static_cast<std::size_t>(2));
}

RDP_TEST_CASE(moonlight_touch_overlay_and_letterbox_own_down_lifetime) {
    TouchFixture fixture;
    auto surface = touchSurface();
    surface.exclusionCount = 1U;
    surface.exclusions[0] = {450.0, 225.0, 100.0, 100.0};
    auto result = fixture.mapper->process(
        touchContext(fixture.identity, 1U, 100U), surface, 1U,
        MoonlightTouchPhase::Down, touchSample());
    RDP_ASSERT_EQ(result.status, MoonlightTouchStatus::OverlayConsumed);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(0));
    result = fixture.mapper->process(
        touchContext(fixture.identity, 2U, 110U), surface, 1U,
        MoonlightTouchPhase::Move, touchSample(700.0, 300.0));
    RDP_ASSERT_EQ(result.status, MoonlightTouchStatus::OverlayConsumed);
    result = fixture.mapper->process(
        touchContext(fixture.identity, 3U, 120U), surface, 1U,
        MoonlightTouchPhase::Up, touchSample(700.0, 300.0));
    RDP_ASSERT_EQ(result.status, MoonlightTouchStatus::AppliedLocally);

    result = fixture.mapper->process(
        touchContext(fixture.identity, 4U, 130U), surface, 2U,
        MoonlightTouchPhase::Down, touchSample(50.0, 275.0));
    RDP_ASSERT_EQ(result.status, MoonlightTouchStatus::OutsideContent);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(0));
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).suppressedDirectContacts,
                  static_cast<std::size_t>(1));
}

RDP_TEST_CASE(moonlight_touch_entering_overlay_cancels_without_reentry) {
    TouchFixture fixture;
    auto surface = touchSurface();
    surface.exclusionCount = 1U;
    surface.exclusions[0] = {700.0, 200.0, 150.0, 150.0};
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 1U, 100U), surface, 1U,
        MoonlightTouchPhase::Down, touchSample(300.0, 150.0)).status,
        MoonlightTouchStatus::Applied);
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 2U, 110U), surface, 1U,
        MoonlightTouchPhase::Move, touchSample(750.0, 250.0)).status,
        MoonlightTouchStatus::OverlayConsumed);
    MoonlightTouchWireCommand cancelled;
    RDP_ASSERT(decodeMoonlightTouchCommand(fixture.port->eventAt(1U), cancelled));
    RDP_ASSERT_EQ(cancelled.eventType, kMoonlightTouchEventCancel);
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 3U, 120U), surface, 1U,
        MoonlightTouchPhase::Move, touchSample(300.0, 150.0)).status,
        MoonlightTouchStatus::OverlayConsumed);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(2));
}

RDP_TEST_CASE(moonlight_touch_geometry_or_hit_map_change_requires_flush) {
    TouchFixture fixture;
    auto surface = touchSurface();
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 1U, 100U), surface, 1U,
        MoonlightTouchPhase::Down, touchSample()).status,
        MoonlightTouchStatus::Applied);
    auto newer = touchSurface(2U, 1U);
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 2U, 110U), newer, 1U,
        MoonlightTouchPhase::Move, touchSample()).status,
        MoonlightTouchStatus::FlushRequired);
    newer = touchSurface(1U, 2U);
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 3U, 120U), newer, 1U,
        MoonlightTouchPhase::Move, touchSample()).status,
        MoonlightTouchStatus::FlushRequired);
    RDP_ASSERT_EQ(fixture.mapper->cancelAll(
        touchContext(fixture.identity, 4U, 130U)).status,
        MoonlightTouchStatus::Applied);
    newer = touchSurface(2U, 2U);
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 5U, 140U), newer, 2U,
        MoonlightTouchPhase::Down, touchSample()).status,
        MoonlightTouchStatus::Applied);
}

RDP_TEST_CASE(moonlight_touch_rotation_pressure_and_area_match_official_body) {
    TouchFixture fixture;
    auto surface = touchSurface(3U, 2U, 1U);
    surface.content = {0.0, 0.0, 1080.0, 1920.0, 1920U, 1080U, 1U, 3U};
    auto sample = touchSample(0.0, 0.0, 0.75F, 0.04F, 0.02F, 90U);
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 1U, 100U), surface, 1U,
        MoonlightTouchPhase::Down, sample).status,
        MoonlightTouchStatus::Applied);
    MoonlightTouchWireCommand command;
    RDP_ASSERT(decodeMoonlightTouchCommand(fixture.port->eventAt(0U), command));
    RDP_ASSERT(std::fabs(command.x - 0.0F) < 0.00001F);
    RDP_ASSERT(std::fabs(command.y - 1.0F) < 0.00001F);
    RDP_ASSERT(std::fabs(command.pressureOrDistance - 0.75F) < 0.00001F);
    RDP_ASSERT(std::fabs(command.contactAreaMajor - 0.04F) < 0.00001F);
    RDP_ASSERT(std::fabs(command.contactAreaMinor - 0.02F) < 0.00001F);
    RDP_ASSERT_EQ(command.rotation, static_cast<std::uint16_t>(0U));
}

RDP_TEST_CASE(moonlight_touch_rejects_invalid_sample_surface_and_context) {
    TouchFixture fixture;
    auto surface = touchSurface();
    auto sample = touchSample();
    sample.pressure = 1.1F;
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 1U, 100U), surface, 1U,
        MoonlightTouchPhase::Down, sample).status,
        MoonlightTouchStatus::InvalidRequest);
    sample = touchSample();
    sample.contactAreaMinor = 0.5F;
    sample.contactAreaMajor = 0.25F;
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 2U, 110U), surface, 1U,
        MoonlightTouchPhase::Down, sample).status,
        MoonlightTouchStatus::InvalidRequest);
    sample = touchSample();
    sample.rotation = 360U;
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 3U, 120U), surface, 1U,
        MoonlightTouchPhase::Down, sample).status,
        MoonlightTouchStatus::InvalidRequest);
    surface.exclusionCount = kMoonlightMaximumTouchExclusionRegions + 1U;
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 4U, 130U), surface, 1U,
        MoonlightTouchPhase::Down, touchSample()).status,
        MoonlightTouchStatus::InvalidRequest);
    auto context = touchContext(touchIdentity(94U), 5U, 140U);
    RDP_ASSERT_EQ(fixture.mapper->process(
        context, touchSurface(), 1U, MoonlightTouchPhase::Down,
        touchSample()).status, MoonlightTouchStatus::StaleOwner);
}

RDP_TEST_CASE(moonlight_touch_capacity_duplicate_and_device_ownership_are_exact) {
    MoonlightTouchLimits limits;
    limits.maximumDirectContacts = 1U;
    TouchFixture fixture(MoonlightTouchMode::Direct, true, limits);
    const auto surface = touchSurface();
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 1U, 100U), surface, 1U,
        MoonlightTouchPhase::Down, touchSample()).status,
        MoonlightTouchStatus::Applied);
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 2U, 110U), surface, 1U,
        MoonlightTouchPhase::Down, touchSample()).status,
        MoonlightTouchStatus::Duplicate);
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 3U, 120U), surface, 2U,
        MoonlightTouchPhase::Down, touchSample(300.0, 150.0)).status,
        MoonlightTouchStatus::ContactCapacity);
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 1U, 130U,
                     MoonlightInputSource::Touchscreen, 62U),
        surface, 1U, MoonlightTouchPhase::Up, touchSample()).status,
        MoonlightTouchStatus::NotActive);
}

RDP_TEST_CASE(moonlight_touch_cancel_all_and_mode_switch_flush_direct_contacts) {
    TouchFixture fixture;
    const auto surface = touchSurface();
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 1U, 100U), surface, 1U,
        MoonlightTouchPhase::Down, touchSample()).status,
        MoonlightTouchStatus::Applied);
    auto switched = fixture.mapper->switchMode(
        touchContext(fixture.identity, 2U, 110U), MoonlightTouchMode::Touchpad);
    RDP_ASSERT_EQ(switched.status, MoonlightTouchStatus::Applied);
    MoonlightTouchWireCommand command;
    RDP_ASSERT(decodeMoonlightTouchCommand(fixture.port->eventAt(1U), command));
    RDP_ASSERT_EQ(command.eventType, kMoonlightTouchEventCancelAll);
    const auto snapshot = fixture.mapper->snapshot(fixture.identity);
    RDP_ASSERT_EQ(snapshot.mode, MoonlightTouchMode::Touchpad);
    RDP_ASSERT_EQ(snapshot.activeDirectContacts, static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_touch_backpressure_retries_without_early_state_commit) {
    TouchFixture fixture;
    fixture.port->setScript({MoonlightInputPortStatus::Backpressure,
                             MoonlightInputPortStatus::Accepted});
    auto result = fixture.mapper->process(
        touchContext(fixture.identity, 1U, 100U), touchSurface(), 1U,
        MoonlightTouchPhase::Down, touchSample());
    RDP_ASSERT_EQ(result.status, MoonlightTouchStatus::Backpressure);
    auto snapshot = fixture.mapper->snapshot(fixture.identity);
    RDP_ASSERT(snapshot.pending);
    RDP_ASSERT_EQ(snapshot.activeDirectContacts, static_cast<std::size_t>(0));
    result = fixture.mapper->resumePending();
    RDP_ASSERT_EQ(result.status, MoonlightTouchStatus::Applied);
    snapshot = fixture.mapper->snapshot(fixture.identity);
    RDP_ASSERT(!snapshot.pending);
    RDP_ASSERT_EQ(snapshot.activeDirectContacts, static_cast<std::size_t>(1));

    TouchFixture cancelled;
    cancelled.port->status = MoonlightInputPortStatus::Backpressure;
    RDP_ASSERT_EQ(cancelled.mapper->process(
        touchContext(cancelled.identity, 1U, 100U), touchSurface(), 1U,
        MoonlightTouchPhase::Down, touchSample()).status,
        MoonlightTouchStatus::Backpressure);
    RDP_ASSERT(cancelled.mapper->cancelPendingIfUnsent(cancelled.identity));
    RDP_ASSERT(!cancelled.mapper->snapshot(cancelled.identity).pending);
}

RDP_TEST_CASE(moonlight_touch_local_events_are_sequence_and_generation_fenced) {
    TouchFixture fixture(MoonlightTouchMode::Touchpad, false);
    const auto surface = touchSurface();
    const auto first = touchContext(fixture.identity, 1U, 100000U,
                                    MoonlightInputSource::Touchpad);
    RDP_ASSERT_EQ(fixture.mapper->process(
        first, surface, 1U, MoonlightTouchPhase::Down,
        touchSample(300.0, 200.0)).status, MoonlightTouchStatus::AppliedLocally);
    RDP_ASSERT_EQ(fixture.mapper->process(
        first, surface, 1U, MoonlightTouchPhase::Down,
        touchSample(300.0, 200.0)).status, MoonlightTouchStatus::Duplicate);
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 1U, 200000U,
                     MoonlightInputSource::Touchpad, 61U, 2U),
        surface, 1U, MoonlightTouchPhase::Move,
        touchSample(310.0, 200.0)).status, MoonlightTouchStatus::FlushRequired);
    RDP_ASSERT_EQ(fixture.mapper->cancelAll(
        touchContext(fixture.identity, 1U, 210000U,
                     MoonlightInputSource::Touchpad, 61U, 2U)).status,
        MoonlightTouchStatus::AppliedLocally);
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 2U, 220000U,
                     MoonlightInputSource::Touchpad, 61U, 2U),
        surface, 2U, MoonlightTouchPhase::Down,
        touchSample(320.0, 200.0)).status, MoonlightTouchStatus::AppliedLocally);
}

RDP_TEST_CASE(moonlight_touchpad_partial_click_retry_sends_only_release_suffix) {
    TouchFixture fixture(MoonlightTouchMode::Touchpad, false);
    fixture.port->setScript({MoonlightInputPortStatus::Accepted,
                             MoonlightInputPortStatus::Backpressure,
                             MoonlightInputPortStatus::Accepted});
    const auto surface = touchSurface();
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 1U, 100000U, MoonlightInputSource::Touchpad),
        surface, 1U, MoonlightTouchPhase::Down,
        touchSample(300.0, 200.0)).status, MoonlightTouchStatus::AppliedLocally);
    auto result = fixture.mapper->process(
        touchContext(fixture.identity, 2U, 200000U, MoonlightInputSource::Touchpad),
        surface, 1U, MoonlightTouchPhase::Up, touchSample(300.0, 200.0));
    RDP_ASSERT_EQ(result.status, MoonlightTouchStatus::Backpressure);
    RDP_ASSERT_EQ(result.acceptedCommands, static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(result.pendingCommands, static_cast<std::size_t>(1));
    RDP_ASSERT(!fixture.mapper->cancelPendingIfUnsent(fixture.identity));
    result = fixture.mapper->resumePending();
    RDP_ASSERT_EQ(result.status, MoonlightTouchStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(3));
    MoonlightPointerButtonWireCommand first;
    MoonlightPointerButtonWireCommand second;
    MoonlightPointerButtonWireCommand retry;
    RDP_ASSERT(decodeMoonlightPointerButtonCommand(fixture.port->eventAt(0U), first));
    RDP_ASSERT(decodeMoonlightPointerButtonCommand(fixture.port->eventAt(1U), second));
    RDP_ASSERT(decodeMoonlightPointerButtonCommand(fixture.port->eventAt(2U), retry));
    RDP_ASSERT_EQ(first.action, kMoonlightPointerActionPress);
    RDP_ASSERT_EQ(second.action, kMoonlightPointerActionRelease);
    RDP_ASSERT_EQ(retry.action, kMoonlightPointerActionRelease);
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).activeTouchpadContacts,
                  static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_touchpad_one_finger_move_and_tap_reuse_pointer_mapper) {
    TouchFixture fixture(MoonlightTouchMode::Touchpad, false);
    const auto surface = touchSurface();
    auto down = touchContext(fixture.identity, 1U, 100000U,
                             MoonlightInputSource::Touchpad);
    RDP_ASSERT_EQ(fixture.mapper->process(
        down, surface, 1U, MoonlightTouchPhase::Down,
        touchSample(300.0, 200.0)).status, MoonlightTouchStatus::AppliedLocally);
    auto moved = touchContext(fixture.identity, 2U, 120000U,
                              MoonlightInputSource::Touchpad);
    RDP_ASSERT_EQ(fixture.mapper->process(
        moved, surface, 1U, MoonlightTouchPhase::Move,
        touchSample(312.0, 206.0)).status, MoonlightTouchStatus::Applied);
    MoonlightRelativePointerWireCommand motion;
    RDP_ASSERT(decodeMoonlightRelativePointerCommand(
        fixture.port->eventAt(0U), motion));
    RDP_ASSERT_EQ(motion.deltaX, static_cast<std::int16_t>(12));
    RDP_ASSERT_EQ(motion.deltaY, static_cast<std::int16_t>(6));

    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 3U, 130000U, MoonlightInputSource::Touchpad),
        surface, 1U, MoonlightTouchPhase::Up,
        touchSample(312.0, 206.0)).status, MoonlightTouchStatus::AppliedLocally);
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 4U, 200000U, MoonlightInputSource::Touchpad),
        surface, 2U, MoonlightTouchPhase::Down,
        touchSample(400.0, 250.0)).status, MoonlightTouchStatus::AppliedLocally);
    auto tapped = fixture.mapper->process(
        touchContext(fixture.identity, 5U, 300000U, MoonlightInputSource::Touchpad),
        surface, 2U, MoonlightTouchPhase::Up, touchSample(400.0, 250.0));
    RDP_ASSERT_EQ(tapped.status, MoonlightTouchStatus::Applied);
    MoonlightPointerButtonWireCommand press;
    MoonlightPointerButtonWireCommand release;
    RDP_ASSERT(decodeMoonlightPointerButtonCommand(fixture.port->eventAt(1U), press));
    RDP_ASSERT(decodeMoonlightPointerButtonCommand(fixture.port->eventAt(2U), release));
    RDP_ASSERT_EQ(press.button, MoonlightPointerButton::Left);
    RDP_ASSERT_EQ(press.action, kMoonlightPointerActionPress);
    RDP_ASSERT_EQ(release.action, kMoonlightPointerActionRelease);
}

RDP_TEST_CASE(moonlight_touchpad_two_finger_scroll_and_tap_are_distinct) {
    TouchFixture scrollFixture(MoonlightTouchMode::Touchpad, false);
    const auto surface = touchSurface();
    RDP_ASSERT_EQ(scrollFixture.mapper->process(
        touchContext(scrollFixture.identity, 1U, 100000U, MoonlightInputSource::Touchpad),
        surface, 1U, MoonlightTouchPhase::Down,
        touchSample(300.0, 200.0)).status, MoonlightTouchStatus::AppliedLocally);
    RDP_ASSERT_EQ(scrollFixture.mapper->process(
        touchContext(scrollFixture.identity, 2U, 110000U, MoonlightInputSource::Touchpad),
        surface, 2U, MoonlightTouchPhase::Down,
        touchSample(500.0, 200.0)).status, MoonlightTouchStatus::AppliedLocally);
    RDP_ASSERT_EQ(scrollFixture.mapper->process(
        touchContext(scrollFixture.identity, 3U, 120000U, MoonlightInputSource::Touchpad),
        surface, 1U, MoonlightTouchPhase::Move,
        touchSample(300.0, 210.0)).status, MoonlightTouchStatus::Applied);
    MoonlightPointerScrollWireCommand scroll;
    RDP_ASSERT(decodeMoonlightPointerScrollCommand(
        scrollFixture.port->eventAt(0U), scroll));
    RDP_ASSERT(!scroll.horizontal);
    RDP_ASSERT_EQ(scroll.amount, static_cast<std::int16_t>(15));

    TouchFixture tapFixture(MoonlightTouchMode::Touchpad, false);
    RDP_ASSERT_EQ(tapFixture.mapper->process(
        touchContext(tapFixture.identity, 1U, 100000U, MoonlightInputSource::Touchpad),
        surface, 1U, MoonlightTouchPhase::Down, touchSample()).status,
        MoonlightTouchStatus::AppliedLocally);
    RDP_ASSERT_EQ(tapFixture.mapper->process(
        touchContext(tapFixture.identity, 2U, 110000U, MoonlightInputSource::Touchpad),
        surface, 2U, MoonlightTouchPhase::Down,
        touchSample(520.0, 275.0)).status, MoonlightTouchStatus::AppliedLocally);
    RDP_ASSERT_EQ(tapFixture.mapper->process(
        touchContext(tapFixture.identity, 3U, 150000U, MoonlightInputSource::Touchpad),
        surface, 1U, MoonlightTouchPhase::Up, touchSample()).status,
        MoonlightTouchStatus::AppliedLocally);
    RDP_ASSERT_EQ(tapFixture.mapper->process(
        touchContext(tapFixture.identity, 4U, 160000U, MoonlightInputSource::Touchpad),
        surface, 2U, MoonlightTouchPhase::Up,
        touchSample(520.0, 275.0)).status, MoonlightTouchStatus::Applied);
    MoonlightPointerButtonWireCommand right;
    RDP_ASSERT(decodeMoonlightPointerButtonCommand(tapFixture.port->eventAt(0U), right));
    RDP_ASSERT_EQ(right.button, MoonlightPointerButton::Right);
}

RDP_TEST_CASE(moonlight_touchpad_long_press_drag_cancel_releases_button) {
    TouchFixture fixture(MoonlightTouchMode::Touchpad, false);
    const auto surface = touchSurface();
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 1U, 100000U, MoonlightInputSource::Touchpad),
        surface, 1U, MoonlightTouchPhase::Down,
        touchSample(300.0, 200.0)).status, MoonlightTouchStatus::AppliedLocally);
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 2U, 800000U, MoonlightInputSource::Touchpad),
        surface, 1U, MoonlightTouchPhase::Move,
        touchSample(301.0, 200.0)).status, MoonlightTouchStatus::Applied);
    MoonlightPointerButtonWireCommand button;
    RDP_ASSERT(decodeMoonlightPointerButtonCommand(fixture.port->eventAt(0U), button));
    RDP_ASSERT_EQ(button.action, kMoonlightPointerActionPress);
    RDP_ASSERT(fixture.mapper->snapshot(fixture.identity).touchpadDragButtonDown);
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 3U, 810000U, MoonlightInputSource::Touchpad),
        surface, 1U, MoonlightTouchPhase::Move,
        touchSample(311.0, 204.0)).status, MoonlightTouchStatus::Applied);
    MoonlightRelativePointerWireCommand move;
    RDP_ASSERT(decodeMoonlightRelativePointerCommand(fixture.port->eventAt(1U), move));
    RDP_ASSERT_EQ(move.deltaX, static_cast<std::int16_t>(10));
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 4U, 820000U, MoonlightInputSource::Touchpad),
        surface, 1U, MoonlightTouchPhase::Cancel,
        touchSample()).status, MoonlightTouchStatus::Applied);
    RDP_ASSERT(decodeMoonlightPointerButtonCommand(fixture.port->eventAt(2U), button));
    RDP_ASSERT_EQ(button.action, kMoonlightPointerActionRelease);
    RDP_ASSERT(!fixture.mapper->snapshot(fixture.identity).touchpadDragButtonDown);
}

RDP_TEST_CASE(moonlight_touchpad_three_finger_tap_is_local_toolbar_action) {
    TouchFixture fixture(MoonlightTouchMode::Touchpad, false);
    const auto surface = touchSurface();
    for (std::uint64_t id = 1U; id <= 3U; ++id) {
        RDP_ASSERT_EQ(fixture.mapper->process(
            touchContext(fixture.identity, id, 100000U + id * 1000U,
                         MoonlightInputSource::Touchpad),
            surface, id, MoonlightTouchPhase::Down,
            touchSample(300.0 + static_cast<double>(id) * 20.0, 200.0)).status,
            MoonlightTouchStatus::AppliedLocally);
    }
    MoonlightTouchResult result;
    for (std::uint64_t id = 1U; id <= 3U; ++id) {
        result = fixture.mapper->process(
            touchContext(fixture.identity, 3U + id, 150000U + id * 1000U,
                         MoonlightInputSource::Touchpad),
            surface, id, MoonlightTouchPhase::Up,
            touchSample(300.0 + static_cast<double>(id) * 20.0, 200.0));
    }
    RDP_ASSERT_EQ(result.status, MoonlightTouchStatus::AppliedLocally);
    RDP_ASSERT_EQ(result.localAction, MoonlightTouchLocalAction::ToggleToolbar);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_touchpad_overlay_cancels_drag_and_suppresses_reentry) {
    TouchFixture fixture(MoonlightTouchMode::Touchpad, false);
    auto surface = touchSurface();
    surface.exclusionCount = 1U;
    surface.exclusions[0] = {700.0, 200.0, 150.0, 150.0};
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 1U, 100000U, MoonlightInputSource::Touchpad),
        surface, 1U, MoonlightTouchPhase::Down,
        touchSample(300.0, 200.0)).status, MoonlightTouchStatus::AppliedLocally);
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 2U, 800000U, MoonlightInputSource::Touchpad),
        surface, 1U, MoonlightTouchPhase::Move,
        touchSample(301.0, 200.0)).status, MoonlightTouchStatus::Applied);
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 3U, 810000U, MoonlightInputSource::Touchpad),
        surface, 1U, MoonlightTouchPhase::Move,
        touchSample(750.0, 250.0)).status, MoonlightTouchStatus::OverlayConsumed);
    MoonlightPointerButtonWireCommand release;
    RDP_ASSERT(decodeMoonlightPointerButtonCommand(fixture.port->eventAt(1U), release));
    RDP_ASSERT_EQ(release.action, kMoonlightPointerActionRelease);
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 4U, 820000U, MoonlightInputSource::Touchpad),
        surface, 1U, MoonlightTouchPhase::Move,
        touchSample(300.0, 200.0)).status, MoonlightTouchStatus::OverlayConsumed);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(2));
}

RDP_TEST_CASE(moonlight_touchpad_overlay_contact_is_not_a_remote_gesture_finger) {
    TouchFixture fixture(MoonlightTouchMode::Touchpad, false);
    auto surface = touchSurface();
    surface.exclusionCount = 1U;
    surface.exclusions[0] = {700.0, 200.0, 150.0, 150.0};
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 1U, 100000U, MoonlightInputSource::Touchpad),
        surface, 1U, MoonlightTouchPhase::Down,
        touchSample(750.0, 250.0)).status, MoonlightTouchStatus::OverlayConsumed);
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 2U, 110000U, MoonlightInputSource::Touchpad),
        surface, 2U, MoonlightTouchPhase::Down,
        touchSample(300.0, 200.0)).status, MoonlightTouchStatus::AppliedLocally);
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 3U, 150000U, MoonlightInputSource::Touchpad),
        surface, 2U, MoonlightTouchPhase::Up,
        touchSample(300.0, 200.0)).status, MoonlightTouchStatus::Applied);

    MoonlightPointerButtonWireCommand press;
    MoonlightPointerButtonWireCommand release;
    RDP_ASSERT(decodeMoonlightPointerButtonCommand(fixture.port->eventAt(0U), press));
    RDP_ASSERT(decodeMoonlightPointerButtonCommand(fixture.port->eventAt(1U), release));
    RDP_ASSERT_EQ(press.button, MoonlightPointerButton::Left);
    RDP_ASSERT_EQ(press.action, kMoonlightPointerActionPress);
    RDP_ASSERT_EQ(release.action, kMoonlightPointerActionRelease);
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).activeTouchpadContacts,
                  static_cast<std::size_t>(1));

    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 4U, 160000U, MoonlightInputSource::Touchpad),
        surface, 1U, MoonlightTouchPhase::Up,
        touchSample(750.0, 250.0)).status, MoonlightTouchStatus::AppliedLocally);
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).activeTouchpadContacts,
                  static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_touch_mode_switch_releases_touchpad_drag_first) {
    TouchFixture fixture(MoonlightTouchMode::Touchpad, true);
    const auto surface = touchSurface();
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 1U, 100000U, MoonlightInputSource::Touchpad),
        surface, 1U, MoonlightTouchPhase::Down,
        touchSample(300.0, 200.0)).status, MoonlightTouchStatus::AppliedLocally);
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 2U, 800000U, MoonlightInputSource::Touchpad),
        surface, 1U, MoonlightTouchPhase::Move,
        touchSample(301.0, 200.0)).status, MoonlightTouchStatus::Applied);
    RDP_ASSERT_EQ(fixture.mapper->switchMode(
        touchContext(fixture.identity, 3U, 810000U, MoonlightInputSource::Touchpad),
        MoonlightTouchMode::Direct).status, MoonlightTouchStatus::Applied);
    MoonlightPointerButtonWireCommand release;
    RDP_ASSERT(decodeMoonlightPointerButtonCommand(fixture.port->eventAt(1U), release));
    RDP_ASSERT_EQ(release.action, kMoonlightPointerActionRelease);
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).mode,
                  MoonlightTouchMode::Direct);
}

RDP_TEST_CASE(moonlight_touch_creation_and_mode_sources_are_validated) {
    auto gate = std::make_shared<TouchOwnerGate>();
    auto port = std::make_shared<TouchPort>();
    const auto identity = touchIdentity();
    gate->accept(identity);
    auto bridge = MoonlightInputBridge::create(gate, port);
    RDP_ASSERT(bridge != nullptr);
    RDP_ASSERT_EQ(bridge->activate(identity, 1U).status,
                  MoonlightInputControlStatus::Applied);
    MoonlightTouchModeRequest unsupported;
    unsupported.requested = MoonlightTouchMode::Direct;
    unsupported.allowTouchpadFallback = false;
    RDP_ASSERT(MoonlightTouchMapper::create(bridge, identity, unsupported) == nullptr);
    MoonlightTouchLimits limits;
    limits.maximumDirectContacts = 0U;
    MoonlightTouchModeRequest touchpad;
    RDP_ASSERT(MoonlightTouchMapper::create(bridge, identity, touchpad, limits) == nullptr);
    RDP_ASSERT(MoonlightTouchMapper::create(nullptr, identity, touchpad) == nullptr);

    TouchFixture fixture;
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 1U, 100U, MoonlightInputSource::Touchpad),
        touchSurface(), 1U, MoonlightTouchPhase::Down, touchSample()).status,
        MoonlightTouchStatus::InvalidRequest);
}

RDP_TEST_CASE(moonlight_touch_decoder_rejects_malformed_or_non_touch_events) {
    TouchFixture fixture;
    RDP_ASSERT_EQ(fixture.mapper->process(
        touchContext(fixture.identity, 1U, 100U), touchSurface(), 1U,
        MoonlightTouchPhase::Down, touchSample()).status,
        MoonlightTouchStatus::Applied);
    MoonlightInputEvent event = fixture.port->eventAt(0U);
    MoonlightTouchWireCommand command;
    RDP_ASSERT(decodeMoonlightTouchCommand(event, command));
    event.payloadSize = kMoonlightTouchCommandBytes - 1U;
    RDP_ASSERT(!decodeMoonlightTouchCommand(event, command));
    event = fixture.port->eventAt(0U);
    event.payload[1] = 1U;
    RDP_ASSERT(!decodeMoonlightTouchCommand(event, command));
    event = fixture.port->eventAt(0U);
    event.payload[0] = kMoonlightTouchEventHover;
    RDP_ASSERT(!decodeMoonlightTouchCommand(event, command));
    event = fixture.port->eventAt(0U);
    event.kind = MoonlightInputCommandKind::Controller;
    RDP_ASSERT(!decodeMoonlightTouchCommand(event, command));
}

} // namespace
