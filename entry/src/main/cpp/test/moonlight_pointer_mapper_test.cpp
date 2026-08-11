#include "moonlight/input/MoonlightPointerMapper.h"
#include "test/test_runner.h"

#include <cmath>
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

MoonlightInputIdentity pointerIdentity(std::uint64_t ownerToken = 83U,
                                       std::uint64_t inputGeneration = 4U) {
    return {{1201U, 31U, ownerToken}, inputGeneration};
}

MoonlightPointerEventContext pointerContext(
    const MoonlightInputIdentity& identity,
    std::uint64_t sequence,
    std::uint64_t timestampUs,
    MoonlightInputSource source = MoonlightInputSource::Mouse,
    std::uint64_t deviceId = 51U,
    std::uint64_t sourceGeneration = 1U) {
    return {identity, deviceId, source, sourceGeneration, sequence, timestampUs};
}

MoonlightPointerContentRect contentRect(
    double left = 100.0,
    double top = 50.0,
    double width = 800.0,
    double height = 450.0,
    std::uint16_t referenceWidth = 1920U,
    std::uint16_t referenceHeight = 1080U,
    std::uint64_t generation = 1U,
    std::uint8_t quarterTurns = 0U) {
    return {left, top, width, height, referenceWidth, referenceHeight,
            quarterTurns, generation};
}

class PointerOwnerGate final : public MoonlightInputOwnerGate {
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

    void reject() {
        std::lock_guard<std::mutex> lock(mutex_);
        available_ = false;
    }

  private:
    std::mutex mutex_;
    MoonlightInputIdentity accepted_{};
    bool available_ = false;
};

class PointerPort final : public MoonlightInputPort {
  public:
    MoonlightInputPortStatus send(const MoonlightInputEvent& event) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        events.push_back(event);
        if (scriptIndex < scripted.size()) {
            return scripted[scriptIndex++];
        }
        return status;
    }

    bool flushNeutral(const MoonlightInputFlushRequest&) noexcept override {
        return true;
    }

    MoonlightInputEvent eventAt(std::size_t index) const {
        std::lock_guard<std::mutex> lock(mutex_);
        RDP_ASSERT(index < events.size());
        return events[index];
    }

    std::size_t eventCount() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return events.size();
    }

    void setScript(std::vector<MoonlightInputPortStatus> values) {
        std::lock_guard<std::mutex> lock(mutex_);
        scripted = std::move(values);
        scriptIndex = 0U;
    }

    MoonlightInputPortStatus status = MoonlightInputPortStatus::Accepted;

  private:
    mutable std::mutex mutex_;
    std::vector<MoonlightInputPortStatus> scripted;
    std::size_t scriptIndex = 0U;
    std::vector<MoonlightInputEvent> events;
};

struct PointerFixture final {
    explicit PointerFixture(MoonlightPointerLimits limits = {}) {
        gate->accept(identity);
        bridge = MoonlightInputBridge::create(gate, port);
        RDP_ASSERT(bridge != nullptr);
        RDP_ASSERT_EQ(bridge->activate(identity, 1U).status,
                      MoonlightInputControlStatus::Applied);
        mapper = MoonlightPointerMapper::create(bridge, identity, limits);
        RDP_ASSERT(mapper != nullptr);
    }

    MoonlightInputIdentity identity = pointerIdentity();
    std::shared_ptr<PointerOwnerGate> gate = std::make_shared<PointerOwnerGate>();
    std::shared_ptr<PointerPort> port = std::make_shared<PointerPort>();
    std::shared_ptr<MoonlightInputBridge> bridge;
    std::shared_ptr<MoonlightPointerMapper> mapper;
};

RDP_TEST_CASE(moonlight_pointer_resolves_capture_constraint_and_raw_capabilities) {
    MoonlightPointerModeRequest request;
    request.mode = MoonlightPointerMode::Relative;
    request.requestedCapabilities = kMoonlightPointerKnownCapabilities;
    auto resolution = resolveMoonlightPointerMode(
        request, kMoonlightPointerCapabilityRawRelative);
    RDP_ASSERT_EQ(resolution.status, MoonlightPointerModeStatus::Degraded);
    RDP_ASSERT_EQ(resolution.enabledCapabilities,
                  kMoonlightPointerCapabilityRawRelative);
    RDP_ASSERT_EQ(resolution.missingCapabilities,
                  static_cast<std::uint8_t>(kMoonlightPointerCapabilityCapture |
                                            kMoonlightPointerCapabilityConstraint));

    request.requiredCapabilities = kMoonlightPointerCapabilityCapture;
    resolution = resolveMoonlightPointerMode(
        request, kMoonlightPointerCapabilityRawRelative);
    RDP_ASSERT_EQ(resolution.status, MoonlightPointerModeStatus::Unsupported);

    request.requiredCapabilities = 0U;
    request.allowFallback = false;
    resolution = resolveMoonlightPointerMode(request, 0U);
    RDP_ASSERT_EQ(resolution.status, MoonlightPointerModeStatus::Unsupported);

    request.mode = MoonlightPointerMode::Absolute;
    resolution = resolveMoonlightPointerMode(request, kMoonlightPointerKnownCapabilities);
    RDP_ASSERT_EQ(resolution.status, MoonlightPointerModeStatus::InvalidRequest);

    request = {};
    request.requiredCapabilities = kMoonlightPointerCapabilityCapture;
    RDP_ASSERT_EQ(resolveMoonlightPointerMode(request, 0U).status,
                  MoonlightPointerModeStatus::InvalidRequest);
    request.mode = MoonlightPointerMode::Relative;
    request.requestedCapabilities = kMoonlightPointerCapabilityConstraint;
    request.requiredCapabilities = 0U;
    RDP_ASSERT_EQ(resolveMoonlightPointerMode(request, 0U).status,
                  MoonlightPointerModeStatus::InvalidRequest);
    request.requestedCapabilities = kMoonlightPointerCapabilityCapture;
    RDP_ASSERT_EQ(resolveMoonlightPointerMode(
        request, kMoonlightPointerCapabilityConstraint).status,
        MoonlightPointerModeStatus::InvalidRequest);
}

RDP_TEST_CASE(moonlight_pointer_maps_fit_content_and_rejects_letterbox_bars) {
    const auto rect = contentRect();
    auto mapped = mapMoonlightAbsolutePointer(rect, 100.0, 50.0);
    RDP_ASSERT_EQ(mapped.status, MoonlightPointerMapStatus::Mapped);
    RDP_ASSERT_EQ(mapped.x, static_cast<std::int16_t>(0));
    RDP_ASSERT_EQ(mapped.y, static_cast<std::int16_t>(0));

    mapped = mapMoonlightAbsolutePointer(rect, 500.0, 275.0);
    RDP_ASSERT_EQ(mapped.status, MoonlightPointerMapStatus::Mapped);
    RDP_ASSERT_EQ(mapped.x, static_cast<std::int16_t>(960));
    RDP_ASSERT_EQ(mapped.y, static_cast<std::int16_t>(540));

    mapped = mapMoonlightAbsolutePointer(rect, 900.0, 500.0);
    RDP_ASSERT_EQ(mapped.x, static_cast<std::int16_t>(1919));
    RDP_ASSERT_EQ(mapped.y, static_cast<std::int16_t>(1079));
    RDP_ASSERT_EQ(mapMoonlightAbsolutePointer(rect, 99.99, 275.0).status,
                  MoonlightPointerMapStatus::OutsideContent);
    RDP_ASSERT_EQ(mapMoonlightAbsolutePointer(rect, 500.0, 500.01).status,
                  MoonlightPointerMapStatus::OutsideContent);
    const auto doubledDensity = contentRect(200.0, 100.0, 1600.0, 900.0);
    mapped = mapMoonlightAbsolutePointer(doubledDensity, 1000.0, 550.0);
    RDP_ASSERT_EQ(mapped.x, static_cast<std::int16_t>(960));
    RDP_ASSERT_EQ(mapped.y, static_cast<std::int16_t>(540));
}

RDP_TEST_CASE(moonlight_pointer_maps_fill_one_to_one_pan_and_rotation) {
    auto rect = contentRect(-100.0, 0.0, 1200.0, 800.0);
    auto mapped = mapMoonlightAbsolutePointer(rect, 0.0, 400.0);
    RDP_ASSERT_EQ(mapped.status, MoonlightPointerMapStatus::Mapped);
    RDP_ASSERT_EQ(mapped.x, static_cast<std::int16_t>(160));
    RDP_ASSERT_EQ(mapped.y, static_cast<std::int16_t>(540));

    rect = contentRect(-460.0, -180.0, 1920.0, 1080.0);
    mapped = mapMoonlightAbsolutePointer(rect, 500.0, 360.0);
    RDP_ASSERT_EQ(mapped.x, static_cast<std::int16_t>(960));
    RDP_ASSERT_EQ(mapped.y, static_cast<std::int16_t>(540));

    rect = contentRect(0.0, 0.0, 1080.0, 1920.0, 1920U, 1080U, 3U, 1U);
    mapped = mapMoonlightAbsolutePointer(rect, 0.0, 0.0);
    RDP_ASSERT_EQ(mapped.x, static_cast<std::int16_t>(0));
    RDP_ASSERT_EQ(mapped.y, static_cast<std::int16_t>(1079));
    mapped = mapMoonlightAbsolutePointer(rect, 1080.0, 1920.0);
    RDP_ASSERT_EQ(mapped.x, static_cast<std::int16_t>(1919));
    RDP_ASSERT_EQ(mapped.y, static_cast<std::int16_t>(0));
}

RDP_TEST_CASE(moonlight_pointer_rejects_invalid_or_unrepresentable_geometry) {
    auto rect = contentRect();
    rect.width = 0.0;
    RDP_ASSERT_EQ(mapMoonlightAbsolutePointer(rect, 0.0, 0.0).status,
                  MoonlightPointerMapStatus::InvalidRequest);
    rect = contentRect();
    rect.referenceWidth = 1U;
    RDP_ASSERT_EQ(mapMoonlightAbsolutePointer(rect, 0.0, 0.0).status,
                  MoonlightPointerMapStatus::InvalidRequest);
    rect = contentRect();
    rect.referenceHeight = 32768U;
    RDP_ASSERT_EQ(mapMoonlightAbsolutePointer(rect, 0.0, 0.0).status,
                  MoonlightPointerMapStatus::InvalidRequest);
    rect = contentRect();
    rect.clockwiseQuarterTurns = 4U;
    RDP_ASSERT_EQ(mapMoonlightAbsolutePointer(rect, 0.0, 0.0).status,
                  MoonlightPointerMapStatus::InvalidRequest);
    rect = contentRect();
    rect.left = std::numeric_limits<double>::infinity();
    RDP_ASSERT_EQ(mapMoonlightAbsolutePointer(rect, 0.0, 0.0).status,
                  MoonlightPointerMapStatus::InvalidRequest);
    rect = contentRect();
    RDP_ASSERT_EQ(mapMoonlightAbsolutePointer(
        rect, std::numeric_limits<double>::quiet_NaN(), 0.0).status,
        MoonlightPointerMapStatus::InvalidRequest);
}

RDP_TEST_CASE(moonlight_pointer_rejects_invalid_creation_context_and_source) {
    auto gate = std::make_shared<PointerOwnerGate>();
    auto port = std::make_shared<PointerPort>();
    const auto identity = pointerIdentity();
    gate->accept(identity);
    auto bridge = MoonlightInputBridge::create(gate, port);
    RDP_ASSERT(bridge != nullptr);
    RDP_ASSERT_EQ(bridge->activate(identity, 1U).status,
                  MoonlightInputControlStatus::Applied);
    MoonlightPointerLimits limits;
    limits.maximumPressedButtons = 0U;
    RDP_ASSERT(MoonlightPointerMapper::create(bridge, identity, limits) == nullptr);
    limits.maximumPressedButtons = kMoonlightMaximumPointerButtons + 1U;
    RDP_ASSERT(MoonlightPointerMapper::create(bridge, identity, limits) == nullptr);
    limits = {};
    limits.relativeSensitivity = 0.0;
    RDP_ASSERT(MoonlightPointerMapper::create(bridge, identity, limits) == nullptr);
    RDP_ASSERT(MoonlightPointerMapper::create(nullptr, identity) == nullptr);
    RDP_ASSERT(MoonlightPointerMapper::create(bridge, {}) == nullptr);

    PointerFixture fixture;
    auto context = pointerContext(fixture.identity, 1U, 100U,
                                  MoonlightInputSource::PhysicalKeyboard);
    RDP_ASSERT_EQ(fixture.mapper->relativeMotion(context, 1.0, 1.0).status,
                  MoonlightPointerStatus::InvalidRequest);
    context = pointerContext(pointerIdentity(84U), 1U, 100U);
    RDP_ASSERT_EQ(fixture.mapper->relativeMotion(context, 1.0, 1.0).status,
                  MoonlightPointerStatus::StaleOwner);
    context = pointerContext(fixture.identity,
                             std::numeric_limits<std::uint64_t>::max(), 100U);
    RDP_ASSERT_EQ(fixture.mapper->relativeMotion(context, 1.0, 1.0).status,
                  MoonlightPointerStatus::InvalidRequest);
}

RDP_TEST_CASE(moonlight_pointer_relative_motion_preserves_fractional_device_delta) {
    MoonlightPointerLimits limits;
    limits.relativeSensitivity = 1.0;
    PointerFixture fixture(limits);
    auto first = fixture.mapper->relativeMotion(
        pointerContext(fixture.identity, 1U, 100U), 0.4, 0.4);
    RDP_ASSERT_EQ(first.status, MoonlightPointerStatus::AppliedLocally);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(0));

    auto second = fixture.mapper->relativeMotion(
        pointerContext(fixture.identity, 2U, 110U), 0.7, -1.6);
    RDP_ASSERT_EQ(second.status, MoonlightPointerStatus::Applied);
    MoonlightRelativePointerWireCommand command;
    RDP_ASSERT(decodeMoonlightRelativePointerCommand(fixture.port->eventAt(0U), command));
    RDP_ASSERT_EQ(command.deltaX, static_cast<std::int16_t>(1));
    RDP_ASSERT_EQ(command.deltaY, static_cast<std::int16_t>(-1));
    const auto snapshot = fixture.mapper->snapshot(fixture.identity);
    RDP_ASSERT(std::fabs(snapshot.residualX - 0.1) < 0.000001);
    RDP_ASSERT(std::fabs(snapshot.residualY + 0.2) < 0.000001);
}

RDP_TEST_CASE(moonlight_pointer_relative_motion_rejects_nonfinite_and_overflow) {
    PointerFixture fixture;
    auto context = pointerContext(fixture.identity, 1U, 100U);
    RDP_ASSERT_EQ(fixture.mapper->relativeMotion(context, 0.0, 0.0).status,
                  MoonlightPointerStatus::AlreadyApplied);
    RDP_ASSERT_EQ(fixture.mapper->relativeMotion(
        context, std::numeric_limits<double>::infinity(), 1.0).status,
        MoonlightPointerStatus::InvalidRequest);
    RDP_ASSERT_EQ(fixture.mapper->relativeMotion(context, 40000.0, 1.0).status,
                  MoonlightPointerStatus::OutOfRange);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_pointer_absolute_geometry_is_generation_fenced) {
    PointerFixture fixture;
    auto context = pointerContext(fixture.identity, 1U, 100U);
    auto rect = contentRect();
    auto outside = fixture.mapper->absolutePosition(context, rect, 0.0, 0.0);
    RDP_ASSERT_EQ(outside.status, MoonlightPointerStatus::OutsideContent);
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).geometryGeneration,
                  static_cast<std::uint64_t>(1));

    rect.geometryGeneration = 2U;
    auto applied = fixture.mapper->absolutePosition(
        pointerContext(fixture.identity, 2U, 110U), rect, 500.0, 275.0);
    RDP_ASSERT_EQ(applied.status, MoonlightPointerStatus::Applied);
    MoonlightAbsolutePointerWireCommand command;
    RDP_ASSERT(decodeMoonlightAbsolutePointerCommand(fixture.port->eventAt(0U), command));
    RDP_ASSERT_EQ(command.x, static_cast<std::int16_t>(960));
    RDP_ASSERT_EQ(command.y, static_cast<std::int16_t>(540));

    auto stale = contentRect();
    RDP_ASSERT_EQ(fixture.mapper->absolutePosition(
        pointerContext(fixture.identity, 3U, 120U), stale, 500.0, 275.0).status,
        MoonlightPointerStatus::StaleGeometry);
    rect.left += 1.0;
    RDP_ASSERT_EQ(fixture.mapper->absolutePosition(
        pointerContext(fixture.identity, 4U, 130U), rect, 500.0, 275.0).status,
        MoonlightPointerStatus::InvalidRequest);
}

RDP_TEST_CASE(moonlight_pointer_maps_all_official_buttons) {
    PointerFixture fixture;
    const MoonlightPointerButton buttons[] = {
        MoonlightPointerButton::Left, MoonlightPointerButton::Middle,
        MoonlightPointerButton::Right, MoonlightPointerButton::X1,
        MoonlightPointerButton::X2,
    };
    for (std::size_t index = 0U; index < 5U; ++index) {
        RDP_ASSERT_EQ(fixture.mapper->button(
            pointerContext(fixture.identity, index + 1U, 100U + index),
            buttons[index], true).status, MoonlightPointerStatus::Applied);
        MoonlightPointerButtonWireCommand command;
        RDP_ASSERT(decodeMoonlightPointerButtonCommand(
            fixture.port->eventAt(index), command));
        RDP_ASSERT_EQ(command.action, kMoonlightPointerActionPress);
        RDP_ASSERT_EQ(command.button, buttons[index]);
    }
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).pressedButtons,
                  static_cast<std::size_t>(5));
}

RDP_TEST_CASE(moonlight_pointer_button_capacity_and_full_release_are_bounded) {
    MoonlightPointerLimits narrowLimits;
    narrowLimits.maximumPressedButtons = 1U;
    PointerFixture narrow(narrowLimits);
    RDP_ASSERT_EQ(narrow.mapper->button(
        pointerContext(narrow.identity, 1U, 100U),
        MoonlightPointerButton::Left, true).status,
        MoonlightPointerStatus::Applied);
    RDP_ASSERT_EQ(narrow.mapper->button(
        pointerContext(narrow.identity, 2U, 110U),
        MoonlightPointerButton::Right, true).status,
        MoonlightPointerStatus::ButtonCapacity);

    PointerFixture full;
    const MoonlightPointerButton buttons[] = {
        MoonlightPointerButton::Left, MoonlightPointerButton::Middle,
        MoonlightPointerButton::Right, MoonlightPointerButton::X1,
        MoonlightPointerButton::X2,
    };
    for (std::size_t index = 0U; index < 5U; ++index) {
        RDP_ASSERT_EQ(full.mapper->button(
            pointerContext(full.identity, index + 1U, 200U + index),
            buttons[index], true).status, MoonlightPointerStatus::Applied);
    }
    const auto released = full.mapper->releaseAll(
        pointerContext(full.identity, 6U, 210U));
    RDP_ASSERT_EQ(released.status, MoonlightPointerStatus::Applied);
    RDP_ASSERT_EQ(released.acceptedCommands, static_cast<std::size_t>(5));
    for (std::size_t index = 0U; index < 5U; ++index) {
        MoonlightPointerButtonWireCommand command;
        RDP_ASSERT(decodeMoonlightPointerButtonCommand(
            full.port->eventAt(5U + index), command));
        RDP_ASSERT_EQ(command.button, buttons[4U - index]);
        RDP_ASSERT_EQ(command.action, kMoonlightPointerActionRelease);
    }
    RDP_ASSERT_EQ(full.mapper->snapshot(full.identity).pressedButtons,
                  static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_pointer_button_state_is_device_exact) {
    PointerFixture fixture;
    auto context = pointerContext(fixture.identity, 1U, 100U);
    RDP_ASSERT_EQ(fixture.mapper->button(
        context, MoonlightPointerButton::Left, true).status,
        MoonlightPointerStatus::Applied);
    RDP_ASSERT_EQ(fixture.mapper->button(
        pointerContext(fixture.identity, 2U, 110U),
        MoonlightPointerButton::Left, true).status,
        MoonlightPointerStatus::Duplicate);
    RDP_ASSERT_EQ(fixture.mapper->button(
        pointerContext(fixture.identity, 1U, 120U,
                       MoonlightInputSource::Mouse, 52U),
        MoonlightPointerButton::Left, false).status,
        MoonlightPointerStatus::NotPressed);
    RDP_ASSERT_EQ(fixture.mapper->button(
        pointerContext(fixture.identity, 3U, 130U),
        MoonlightPointerButton::Left, false).status,
                  MoonlightPointerStatus::Applied);
}

RDP_TEST_CASE(moonlight_pointer_absolute_button_is_positioned_and_black_bar_safe) {
    PointerFixture fixture;
    const auto rect = contentRect();
    auto pressed = fixture.mapper->absoluteButton(
        pointerContext(fixture.identity, 1U, 100U), rect, 500.0, 275.0,
        MoonlightPointerButton::Left, true);
    RDP_ASSERT_EQ(pressed.status, MoonlightPointerStatus::Applied);
    RDP_ASSERT_EQ(pressed.acceptedCommands, static_cast<std::size_t>(2));
    MoonlightAbsolutePointerWireCommand position;
    MoonlightPointerButtonWireCommand button;
    RDP_ASSERT(decodeMoonlightAbsolutePointerCommand(fixture.port->eventAt(0U), position));
    RDP_ASSERT_EQ(position.x, static_cast<std::int16_t>(960));
    RDP_ASSERT(decodeMoonlightPointerButtonCommand(fixture.port->eventAt(1U), button));
    RDP_ASSERT_EQ(button.action, kMoonlightPointerActionPress);

    auto suppressed = fixture.mapper->absoluteButton(
        pointerContext(fixture.identity, 2U, 110U), rect, 20.0, 20.0,
        MoonlightPointerButton::Right, true);
    RDP_ASSERT_EQ(suppressed.status, MoonlightPointerStatus::OutsideContent);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(2));

    auto released = fixture.mapper->absoluteButton(
        pointerContext(fixture.identity, 3U, 120U), rect, 20.0, 20.0,
        MoonlightPointerButton::Left, false);
    RDP_ASSERT_EQ(released.status, MoonlightPointerStatus::Applied);
    RDP_ASSERT_EQ(released.acceptedCommands, static_cast<std::size_t>(1));
    RDP_ASSERT(decodeMoonlightPointerButtonCommand(fixture.port->eventAt(2U), button));
    RDP_ASSERT_EQ(button.action, kMoonlightPointerActionRelease);
    RDP_ASSERT_EQ(button.button, MoonlightPointerButton::Left);
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).pressedButtons,
                  static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_pointer_sends_exact_vertical_and_horizontal_high_res_scroll) {
    PointerFixture fixture;
    RDP_ASSERT_EQ(fixture.mapper->scroll(
        pointerContext(fixture.identity, 1U, 100U), false, 120).status,
        MoonlightPointerStatus::Applied);
    RDP_ASSERT_EQ(fixture.mapper->scroll(
        pointerContext(fixture.identity, 2U, 110U), true, -17).status,
        MoonlightPointerStatus::Applied);
    MoonlightPointerScrollWireCommand vertical;
    MoonlightPointerScrollWireCommand horizontal;
    RDP_ASSERT(decodeMoonlightPointerScrollCommand(fixture.port->eventAt(0U), vertical));
    RDP_ASSERT(decodeMoonlightPointerScrollCommand(fixture.port->eventAt(1U), horizontal));
    RDP_ASSERT(!vertical.horizontal);
    RDP_ASSERT_EQ(vertical.amount, static_cast<std::int16_t>(120));
    RDP_ASSERT(horizontal.horizontal);
    RDP_ASSERT_EQ(horizontal.amount, static_cast<std::int16_t>(-17));
    RDP_ASSERT_EQ(fixture.mapper->scroll(
        pointerContext(fixture.identity, 3U, 120U), false, 0).status,
        MoonlightPointerStatus::AlreadyApplied);
    RDP_ASSERT_EQ(fixture.mapper->scroll(
        pointerContext(fixture.identity, 3U, 120U), false, 40000).status,
        MoonlightPointerStatus::OutOfRange);
}

RDP_TEST_CASE(moonlight_pointer_backpressure_retries_exact_motion_without_state_drift) {
    PointerFixture fixture;
    fixture.port->setScript({MoonlightInputPortStatus::Backpressure,
                             MoonlightInputPortStatus::Accepted});
    auto blocked = fixture.mapper->relativeMotion(
        pointerContext(fixture.identity, 1U, 100U), 4.25, -2.75);
    RDP_ASSERT_EQ(blocked.status, MoonlightPointerStatus::Backpressure);
    auto snapshot = fixture.mapper->snapshot(fixture.identity);
    RDP_ASSERT(snapshot.pending);
    RDP_ASSERT(std::fabs(snapshot.residualX) < 0.000001);
    RDP_ASSERT(std::fabs(snapshot.residualY) < 0.000001);

    auto resumed = fixture.mapper->resumePending();
    RDP_ASSERT_EQ(resumed.status, MoonlightPointerStatus::Applied);
    const auto first = fixture.port->eventAt(0U);
    const auto second = fixture.port->eventAt(1U);
    RDP_ASSERT_EQ(first.sourceSequence, second.sourceSequence);
    RDP_ASSERT_EQ(first.payloadSize, second.payloadSize);
    for (std::size_t index = 0U; index < first.payload.size(); ++index) {
        RDP_ASSERT_EQ(first.payload[index], second.payload[index]);
    }
    snapshot = fixture.mapper->snapshot(fixture.identity);
    RDP_ASSERT(std::fabs(snapshot.residualX - 0.25) < 0.000001);
    RDP_ASSERT(std::fabs(snapshot.residualY + 0.75) < 0.000001);
}

RDP_TEST_CASE(moonlight_pointer_release_all_is_reverse_ordered_and_retryable) {
    PointerFixture fixture;
    RDP_ASSERT_EQ(fixture.mapper->button(
        pointerContext(fixture.identity, 1U, 100U),
        MoonlightPointerButton::Left, true).status, MoonlightPointerStatus::Applied);
    RDP_ASSERT_EQ(fixture.mapper->button(
        pointerContext(fixture.identity, 2U, 110U),
        MoonlightPointerButton::Right, true).status, MoonlightPointerStatus::Applied);
    RDP_ASSERT_EQ(fixture.mapper->button(
        pointerContext(fixture.identity, 3U, 120U),
        MoonlightPointerButton::Middle, true).status, MoonlightPointerStatus::Applied);
    fixture.port->setScript({MoonlightInputPortStatus::Accepted,
                             MoonlightInputPortStatus::Backpressure,
                             MoonlightInputPortStatus::Accepted,
                             MoonlightInputPortStatus::Accepted});
    auto partial = fixture.mapper->releaseAll(
        pointerContext(fixture.identity, 4U, 130U));
    RDP_ASSERT_EQ(partial.status, MoonlightPointerStatus::Backpressure);
    RDP_ASSERT_EQ(partial.acceptedCommands, static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).pressedButtons,
                  static_cast<std::size_t>(2));

    MoonlightPointerButtonWireCommand command;
    RDP_ASSERT(decodeMoonlightPointerButtonCommand(fixture.port->eventAt(3U), command));
    RDP_ASSERT_EQ(command.button, MoonlightPointerButton::Middle);
    RDP_ASSERT_EQ(command.action, kMoonlightPointerActionRelease);
    RDP_ASSERT_EQ(fixture.mapper->resumePending().status, MoonlightPointerStatus::Applied);
    RDP_ASSERT(decodeMoonlightPointerButtonCommand(fixture.port->eventAt(5U), command));
    RDP_ASSERT_EQ(command.button, MoonlightPointerButton::Right);
    RDP_ASSERT(decodeMoonlightPointerButtonCommand(fixture.port->eventAt(6U), command));
    RDP_ASSERT_EQ(command.button, MoonlightPointerButton::Left);
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).pressedButtons,
                  static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_pointer_can_cancel_only_a_fully_unsent_transaction) {
    PointerFixture fixture;
    fixture.port->status = MoonlightInputPortStatus::Backpressure;
    RDP_ASSERT_EQ(fixture.mapper->button(
        pointerContext(fixture.identity, 1U, 100U),
        MoonlightPointerButton::X1, true).status,
        MoonlightPointerStatus::Backpressure);
    RDP_ASSERT(!fixture.mapper->cancelPendingIfUnsent(pointerIdentity(99U)));
    RDP_ASSERT(fixture.mapper->cancelPendingIfUnsent(fixture.identity));
    auto snapshot = fixture.mapper->snapshot(fixture.identity);
    RDP_ASSERT(!snapshot.pending);
    RDP_ASSERT_EQ(snapshot.pressedButtons, static_cast<std::size_t>(0));
    fixture.port->status = MoonlightInputPortStatus::Accepted;
    RDP_ASSERT_EQ(fixture.mapper->button(
        pointerContext(fixture.identity, 2U, 110U),
        MoonlightPointerButton::X1, true).status,
        MoonlightPointerStatus::Applied);
}

RDP_TEST_CASE(moonlight_pointer_decoders_reject_malformed_bodies) {
    PointerFixture fixture;
    RDP_ASSERT_EQ(fixture.mapper->relativeMotion(
        pointerContext(fixture.identity, 1U, 100U), 3.0, -4.0).status,
        MoonlightPointerStatus::Applied);
    MoonlightInputEvent event = fixture.port->eventAt(0U);
    MoonlightRelativePointerWireCommand relative;
    RDP_ASSERT(decodeMoonlightRelativePointerCommand(event, relative));
    event.payloadSize = kMoonlightRelativePointerCommandBytes - 1U;
    RDP_ASSERT(!decodeMoonlightRelativePointerCommand(event, relative));
    event = fixture.port->eventAt(0U);
    event.payload[kMoonlightRelativePointerCommandBytes] = 1U;
    RDP_ASSERT(!decodeMoonlightRelativePointerCommand(event, relative));

    RDP_ASSERT_EQ(fixture.mapper->button(
        pointerContext(fixture.identity, 2U, 110U),
        MoonlightPointerButton::X2, true).status,
        MoonlightPointerStatus::Applied);
    MoonlightPointerButtonWireCommand button;
    event = fixture.port->eventAt(1U);
    RDP_ASSERT(decodeMoonlightPointerButtonCommand(event, button));
    event.payload[0] = 0U;
    RDP_ASSERT(!decodeMoonlightPointerButtonCommand(event, button));
    event = fixture.port->eventAt(1U);
    event.payload[1] = 6U;
    RDP_ASSERT(!decodeMoonlightPointerButtonCommand(event, button));

    RDP_ASSERT_EQ(fixture.mapper->scroll(
        pointerContext(fixture.identity, 3U, 120U), true, 1).status,
        MoonlightPointerStatus::Applied);
    MoonlightPointerScrollWireCommand scroll;
    event = fixture.port->eventAt(2U);
    RDP_ASSERT(decodeMoonlightPointerScrollCommand(event, scroll));
    event.kind = MoonlightInputCommandKind::VerticalScroll;
    event.payload[0] = 0U;
    event.payload[1] = 0U;
    RDP_ASSERT(!decodeMoonlightPointerScrollCommand(event, scroll));
}

RDP_TEST_CASE(moonlight_pointer_owner_loss_and_concurrent_duplicate_never_cross_route) {
    PointerFixture fixture;
    fixture.gate->reject();
    RDP_ASSERT_EQ(fixture.mapper->relativeMotion(
        pointerContext(fixture.identity, 1U, 100U), 1.0, 1.0).status,
        MoonlightPointerStatus::StaleOwner);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(0));
    RDP_ASSERT(fixture.mapper->cancelPendingIfUnsent(fixture.identity));
    fixture.gate->accept(fixture.identity);

    MoonlightPointerResult first;
    MoonlightPointerResult second;
    const auto context = pointerContext(fixture.identity, 2U, 110U);
    std::thread a([&]() {
        first = fixture.mapper->button(context, MoonlightPointerButton::Left, true);
    });
    std::thread b([&]() {
        second = fixture.mapper->button(context, MoonlightPointerButton::Left, true);
    });
    a.join();
    b.join();
    const bool validOrder =
        (first.status == MoonlightPointerStatus::Applied &&
         second.status == MoonlightPointerStatus::Duplicate) ||
        (second.status == MoonlightPointerStatus::Applied &&
         first.status == MoonlightPointerStatus::Duplicate);
    RDP_ASSERT(validOrder);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(1));
}

} // namespace
