#include "moonlight/input/MoonlightInputFlushPolicy.h"
#include "test/test_runner.h"

#include <array>
#include <cstdint>
#include <memory>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

namespace {

using namespace remotedesk::moonlight;

MoonlightInputIdentity flushIdentity(std::uint64_t owner = 117U,
                                     std::uint64_t inputGeneration = 13U) {
    return {{1701U, 53U, owner}, inputGeneration};
}

MoonlightTouchSurface flushSurface() {
    MoonlightTouchSurface surface;
    surface.content = {0.0, 0.0, 1280.0, 720.0, 1280U, 720U, 0U, 1U};
    surface.hitMapGeneration = 1U;
    return surface;
}

MoonlightTouchSample flushTouchSample() {
    return {640.0, 360.0, 0.5F, 0.02F, 0.01F,
            kMoonlightTouchRotationUnknown};
}

MoonlightControllerProfile flushControllerProfile() {
    return {MoonlightControllerType::Xbox,
            kMoonlightControllerApi23ButtonMask, true};
}

class FlushOwnerGate final : public MoonlightInputOwnerGate {
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

    void revoke() {
        std::lock_guard<std::mutex> lock(mutex_);
        available_ = false;
    }

  private:
    std::mutex mutex_;
    MoonlightInputIdentity identity_{};
    bool available_ = false;
};

class FlushPort final : public MoonlightInputPort {
  public:
    MoonlightInputPortStatus send(const MoonlightInputEvent& event) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        events_.push_back(event);
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

    MoonlightInputFlushRequest flushAt(std::size_t index) const {
        std::lock_guard<std::mutex> lock(mutex_);
        RDP_ASSERT(index < flushes_.size());
        return flushes_[index];
    }

  private:
    mutable std::mutex mutex_;
    std::vector<MoonlightInputPortStatus> sendScript_;
    std::vector<bool> flushScript_;
    std::size_t sendIndex_ = 0U;
    std::size_t flushIndex_ = 0U;
    std::vector<MoonlightInputEvent> events_;
    std::vector<MoonlightInputFlushRequest> flushes_;
};

struct FlushFixture final {
    explicit FlushFixture(bool includeController = true)
        : controllerEnabled(includeController) {
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
        RDP_ASSERT(keyboard != nullptr && pointer != nullptr && touch != nullptr);
        if (controllerEnabled) {
            MoonlightControllerLimits limits;
            limits.api23InputAvailable = true;
            controller = MoonlightControllerMapper::create(bridge, identity, limits);
            RDP_ASSERT(controller != nullptr);
        }
        policy = MoonlightInputFlushPolicy::create(
            bridge, keyboard, pointer, touch, identity, controller);
        RDP_ASSERT(policy != nullptr);
    }

    MoonlightKeyboardEventContext keyboardContext(
        std::uint64_t sequence, std::uint64_t timestamp) const {
        return {identity, 41U, MoonlightInputSource::PhysicalKeyboard,
                1U, sequence, timestamp};
    }

    MoonlightPointerEventContext pointerContext(
        std::uint64_t sequence, std::uint64_t timestamp) const {
        return {identity, 42U, MoonlightInputSource::Mouse,
                1U, sequence, timestamp};
    }

    MoonlightTouchEventContext touchContext(
        std::uint64_t sequence, std::uint64_t timestamp) const {
        return {identity, 43U, MoonlightInputSource::Touchscreen,
                1U, sequence, timestamp};
    }

    MoonlightControllerEventContext controllerContext(
        std::uint64_t sequence, std::uint64_t timestamp) const {
        return {identity, 44U, MoonlightInputSource::GameController,
                1U, sequence, timestamp};
    }

    MoonlightInputFlushContext context(
        std::uint64_t operation = 100U,
        std::uint64_t timestamp = 1000U,
        std::uint64_t sequence = 10U) const {
        MoonlightInputFlushContext result;
        result.identity = identity;
        result.operationGeneration = operation;
        result.monotonicTimestampUs = timestamp;
        result.touch = touchContext(sequence, timestamp - 4U);
        result.pointer = pointerContext(sequence, timestamp - 3U);
        result.keyboard = keyboardContext(sequence, timestamp - 2U);
        result.controllerContextPresent = controllerEnabled;
        if (controllerEnabled) {
            result.controller = controllerContext(sequence, timestamp - 1U);
        }
        return result;
    }

    void seedKeyboard() {
        RDP_ASSERT_EQ(keyboard->physicalKey(
            keyboardContext(1U, 100U), 2017U, true, true).status,
            MoonlightKeyboardStatus::Applied);
    }

    void seedPointer() {
        RDP_ASSERT_EQ(pointer->button(
            pointerContext(1U, 110U), MoonlightPointerButton::Left, true).status,
            MoonlightPointerStatus::Applied);
    }

    void seedTouch() {
        RDP_ASSERT_EQ(touch->process(
            touchContext(1U, 120U), flushSurface(), 9001U,
            MoonlightTouchPhase::Down, flushTouchSample()).status,
            MoonlightTouchStatus::Applied);
    }

    void seedController() {
        RDP_ASSERT(controller != nullptr);
        RDP_ASSERT_EQ(controller->connect(
            controllerContext(1U, 130U), flushControllerProfile()).status,
            MoonlightControllerStatus::Applied);
        MoonlightControllerSample sample;
        sample.buttonFlags = kMoonlightControllerButtonA;
        sample.leftStickX = 0.5;
        RDP_ASSERT_EQ(controller->update(
            controllerContext(2U, 140U), sample).status,
            MoonlightControllerStatus::Applied);
    }

    void seedAll() {
        seedKeyboard();
        seedPointer();
        seedTouch();
        if (controllerEnabled) {
            seedController();
        }
    }

    MoonlightInputIdentity identity = flushIdentity();
    bool controllerEnabled = true;
    std::shared_ptr<FlushOwnerGate> gate = std::make_shared<FlushOwnerGate>();
    std::shared_ptr<FlushPort> port = std::make_shared<FlushPort>();
    std::shared_ptr<MoonlightInputBridge> bridge;
    std::shared_ptr<MoonlightKeyboardMapper> keyboard;
    std::shared_ptr<MoonlightPointerMapper> pointer;
    std::shared_ptr<MoonlightTouchMapper> touch;
    std::shared_ptr<MoonlightControllerMapper> controller;
    std::shared_ptr<MoonlightInputFlushPolicy> policy;
};

RDP_TEST_CASE(moonlight_input_flush_trigger_dispositions_are_exhaustive) {
    const std::array<MoonlightInputFlushTrigger, 9U> suspendTriggers{
        MoonlightInputFlushTrigger::OverlayOpened,
        MoonlightInputFlushTrigger::ControlModeChanged,
        MoonlightInputFlushTrigger::DisplayRotated,
        MoonlightInputFlushTrigger::FocusLost,
        MoonlightInputFlushTrigger::PipEntered,
        MoonlightInputFlushTrigger::Backgrounded,
        MoonlightInputFlushTrigger::ScreenLocked,
        MoonlightInputFlushTrigger::SurfaceDetached,
        MoonlightInputFlushTrigger::ControllerDisconnected,
    };
    for (const auto trigger : suspendTriggers) {
        RDP_ASSERT_EQ(moonlightInputFlushDisposition(trigger),
                      MoonlightInputFlushDisposition::Suspend);
    }
    const std::array<MoonlightInputFlushTrigger, 3U> stopTriggers{
        MoonlightInputFlushTrigger::ReconnectStarted,
        MoonlightInputFlushTrigger::SessionStop,
        MoonlightInputFlushTrigger::InputGenerationChanged,
    };
    for (const auto trigger : stopTriggers) {
        RDP_ASSERT_EQ(moonlightInputFlushDisposition(trigger),
                      MoonlightInputFlushDisposition::Stop);
    }
    RDP_ASSERT_EQ(moonlightInputFlushDisposition(
                      MoonlightInputFlushTrigger::Invalid),
                  MoonlightInputFlushDisposition::Invalid);
}

RDP_TEST_CASE(moonlight_input_flush_creation_reuses_exact_existing_components) {
    FlushFixture fixture;
    RDP_ASSERT(MoonlightInputFlushPolicy::create(
        nullptr, fixture.keyboard, fixture.pointer, fixture.touch,
        fixture.identity, fixture.controller) == nullptr);
    RDP_ASSERT(MoonlightInputFlushPolicy::create(
        fixture.bridge, nullptr, fixture.pointer, fixture.touch,
        fixture.identity, fixture.controller) == nullptr);
    RDP_ASSERT(MoonlightInputFlushPolicy::create(
        fixture.bridge, fixture.keyboard, fixture.pointer, fixture.touch,
        flushIdentity(999U), fixture.controller) == nullptr);
}

RDP_TEST_CASE(moonlight_input_flush_rejects_invalid_and_stale_contexts) {
    FlushFixture fixture;
    auto invalid = fixture.context();
    invalid.operationGeneration = 0U;
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::FocusLost, invalid).status,
        MoonlightInputFlushStatus::InvalidRequest);
    invalid = fixture.context();
    invalid.touch.identity = flushIdentity(999U);
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::FocusLost, invalid).status,
        MoonlightInputFlushStatus::InvalidRequest);
    auto stale = fixture.context();
    stale.identity = flushIdentity(999U);
    stale.touch.identity = stale.identity;
    stale.pointer.identity = stale.identity;
    stale.keyboard.identity = stale.identity;
    stale.controller.identity = stale.identity;
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::FocusLost, stale).status,
        MoonlightInputFlushStatus::StaleOwner);
}

RDP_TEST_CASE(moonlight_input_flush_orders_touch_pointer_keyboard_controller_then_boundary) {
    FlushFixture fixture;
    fixture.seedAll();
    const auto before = fixture.port->eventCount();
    const auto result = fixture.policy->flush(
        MoonlightInputFlushTrigger::FocusLost, fixture.context());
    RDP_ASSERT_EQ(result.status, MoonlightInputFlushStatus::Applied);
    RDP_ASSERT(result.localReleased && result.boundaryApplied);
    RDP_ASSERT_EQ(fixture.port->eventCount(), before + 4U);
    RDP_ASSERT_EQ(fixture.port->eventAt(before).kind,
                  MoonlightInputCommandKind::Touch);
    RDP_ASSERT_EQ(fixture.port->eventAt(before + 1U).kind,
                  MoonlightInputCommandKind::PointerButton);
    RDP_ASSERT_EQ(fixture.port->eventAt(before + 2U).kind,
                  MoonlightInputCommandKind::Keyboard);
    RDP_ASSERT_EQ(fixture.port->eventAt(before + 3U).kind,
                  MoonlightInputCommandKind::Controller);
    RDP_ASSERT_EQ(fixture.port->flushCount(), static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(fixture.port->flushAt(0U).reason,
                  MoonlightInputSuspendReason::FocusLost);
    RDP_ASSERT_EQ(fixture.touch->snapshot(fixture.identity).activeDirectContacts,
                  static_cast<std::size_t>(0));
    RDP_ASSERT_EQ(fixture.pointer->snapshot(fixture.identity).pressedButtons,
                  static_cast<std::size_t>(0));
    RDP_ASSERT_EQ(fixture.keyboard->snapshot(fixture.identity).
                      pressedNonModifierKeys,
                  static_cast<std::size_t>(0));
    RDP_ASSERT_EQ(fixture.controller->snapshot(fixture.identity).
                      state.buttonFlags,
                  static_cast<std::uint32_t>(0));
}

RDP_TEST_CASE(moonlight_input_flush_all_suspend_triggers_close_admission) {
    const std::array<MoonlightInputFlushTrigger, 8U> triggers{
        MoonlightInputFlushTrigger::OverlayOpened,
        MoonlightInputFlushTrigger::ControlModeChanged,
        MoonlightInputFlushTrigger::DisplayRotated,
        MoonlightInputFlushTrigger::FocusLost,
        MoonlightInputFlushTrigger::PipEntered,
        MoonlightInputFlushTrigger::Backgrounded,
        MoonlightInputFlushTrigger::ScreenLocked,
        MoonlightInputFlushTrigger::SurfaceDetached,
    };
    for (const auto trigger : triggers) {
        FlushFixture fixture(false);
        fixture.seedKeyboard();
        RDP_ASSERT_EQ(fixture.policy->flush(trigger, fixture.context()).status,
                      MoonlightInputFlushStatus::Applied);
        const auto snapshot = fixture.policy->snapshot(fixture.identity);
        RDP_ASSERT_EQ(snapshot.state, MoonlightInputFlushState::Suspended);
        RDP_ASSERT(!snapshot.admissionOpen);
        RDP_ASSERT(snapshot.localReleased && snapshot.boundaryApplied);
    }
}

RDP_TEST_CASE(moonlight_input_flush_terminal_triggers_stop_old_generation) {
    const std::array<MoonlightInputFlushTrigger, 3U> triggers{
        MoonlightInputFlushTrigger::ReconnectStarted,
        MoonlightInputFlushTrigger::SessionStop,
        MoonlightInputFlushTrigger::InputGenerationChanged,
    };
    for (const auto trigger : triggers) {
        FlushFixture fixture(false);
        fixture.seedPointer();
        RDP_ASSERT_EQ(fixture.policy->flush(trigger, fixture.context()).status,
                      MoonlightInputFlushStatus::Applied);
        RDP_ASSERT_EQ(fixture.policy->snapshot(fixture.identity).state,
                      MoonlightInputFlushState::Stopped);
        RDP_ASSERT_EQ(fixture.bridge->snapshot(fixture.identity).state,
                      MoonlightInputState::Stopped);
        RDP_ASSERT_EQ(fixture.port->flushAt(0U).reason,
                      MoonlightInputSuspendReason::Stop);
    }
}

RDP_TEST_CASE(moonlight_input_flush_suspend_resume_opens_only_new_generation) {
    FlushFixture fixture(false);
    fixture.seedKeyboard();
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::OverlayOpened, fixture.context()).status,
        MoonlightInputFlushStatus::Applied);
    RDP_ASSERT_EQ(fixture.policy->resume(fixture.identity, 100U).status,
                  MoonlightInputFlushStatus::StaleOperation);
    RDP_ASSERT_EQ(fixture.policy->resume(fixture.identity, 101U).status,
                  MoonlightInputFlushStatus::Applied);
    RDP_ASSERT(fixture.policy->snapshot(fixture.identity).admissionOpen);
    RDP_ASSERT_EQ(fixture.bridge->snapshot(fixture.identity).state,
                  MoonlightInputState::Active);
    RDP_ASSERT_EQ(fixture.keyboard->physicalKey(
        fixture.keyboardContext(11U, 1100U), 2017U, true, true).status,
        MoonlightKeyboardStatus::Applied);
}

RDP_TEST_CASE(moonlight_input_flush_suspended_session_still_applies_native_stop) {
    FlushFixture fixture(false);
    fixture.seedKeyboard();
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::Backgrounded, fixture.context()).status,
        MoonlightInputFlushStatus::Applied);
    RDP_ASSERT_EQ(fixture.bridge->snapshot(fixture.identity).state,
                  MoonlightInputState::Suspended);

    const auto result = fixture.policy->flush(
        MoonlightInputFlushTrigger::SessionStop,
        fixture.context(101U, 1100U, 11U));
    RDP_ASSERT_EQ(result.status, MoonlightInputFlushStatus::Applied);
    RDP_ASSERT(result.localReleased && result.boundaryApplied);
    RDP_ASSERT_EQ(fixture.bridge->snapshot(fixture.identity).state,
                  MoonlightInputState::Stopped);
    RDP_ASSERT_EQ(fixture.port->flushCount(), static_cast<std::size_t>(2));
    RDP_ASSERT_EQ(fixture.port->flushAt(1U).reason,
                  MoonlightInputSuspendReason::Stop);
}

RDP_TEST_CASE(moonlight_input_flush_stale_stop_never_discards_mapper_state) {
    FlushFixture fixture(false);
    fixture.seedKeyboard();
    RDP_ASSERT_EQ(fixture.bridge->activate(fixture.identity, 200U).status,
                  MoonlightInputControlStatus::AlreadyApplied);
    const auto before = fixture.port->eventCount();

    const auto result = fixture.policy->flush(
        MoonlightInputFlushTrigger::SessionStop, fixture.context());
    RDP_ASSERT_EQ(result.status, MoonlightInputFlushStatus::BoundaryFailure);
    RDP_ASSERT(!result.localReleased && !result.boundaryApplied);
    RDP_ASSERT_EQ(fixture.keyboard->snapshot(fixture.identity).
                      pressedNonModifierKeys,
                  static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(fixture.bridge->snapshot(fixture.identity).state,
                  MoonlightInputState::Active);
    RDP_ASSERT_EQ(fixture.port->eventCount(), before);
    RDP_ASSERT_EQ(fixture.port->flushCount(), static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_input_flush_exact_request_is_idempotent) {
    FlushFixture fixture(false);
    fixture.seedTouch();
    const auto context = fixture.context();
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::FocusLost, context).status,
        MoonlightInputFlushStatus::Applied);
    const auto events = fixture.port->eventCount();
    const auto flushes = fixture.port->flushCount();
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::FocusLost, context).status,
        MoonlightInputFlushStatus::AlreadyApplied);
    RDP_ASSERT_EQ(fixture.port->eventCount(), events);
    RDP_ASSERT_EQ(fixture.port->flushCount(), flushes);
}

RDP_TEST_CASE(moonlight_input_flush_touch_backpressure_retries_exact_cancel) {
    FlushFixture fixture(false);
    fixture.seedTouch();
    fixture.port->setSendScript({MoonlightInputPortStatus::Backpressure,
                                 MoonlightInputPortStatus::Accepted});
    const auto context = fixture.context();
    auto result = fixture.policy->flush(
        MoonlightInputFlushTrigger::FocusLost, context);
    RDP_ASSERT_EQ(result.status, MoonlightInputFlushStatus::Pending);
    RDP_ASSERT_EQ(result.stage, MoonlightInputFlushStage::Touch);
    result = fixture.policy->flush(
        MoonlightInputFlushTrigger::FocusLost, context);
    RDP_ASSERT_EQ(result.status, MoonlightInputFlushStatus::Applied);
    RDP_ASSERT_EQ(fixture.touch->snapshot(fixture.identity).activeDirectContacts,
                  static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_input_flush_pointer_backpressure_retries_exact_release) {
    FlushFixture fixture(false);
    fixture.seedPointer();
    fixture.port->setSendScript({MoonlightInputPortStatus::Backpressure,
                                 MoonlightInputPortStatus::Accepted});
    const auto context = fixture.context();
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::FocusLost, context).stage,
        MoonlightInputFlushStage::Pointer);
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::FocusLost, context).status,
        MoonlightInputFlushStatus::Applied);
    RDP_ASSERT_EQ(fixture.pointer->snapshot(fixture.identity).pressedButtons,
                  static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_input_flush_keyboard_backpressure_retries_exact_release) {
    FlushFixture fixture(false);
    fixture.seedKeyboard();
    fixture.port->setSendScript({MoonlightInputPortStatus::Backpressure,
                                 MoonlightInputPortStatus::Accepted});
    const auto context = fixture.context();
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::FocusLost, context).stage,
        MoonlightInputFlushStage::Keyboard);
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::FocusLost, context).status,
        MoonlightInputFlushStatus::Applied);
    RDP_ASSERT_EQ(fixture.keyboard->snapshot(fixture.identity).
                      pressedNonModifierKeys,
                  static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_input_flush_controller_backpressure_retries_exact_neutral) {
    FlushFixture fixture;
    fixture.seedController();
    fixture.port->setSendScript({MoonlightInputPortStatus::Backpressure,
                                 MoonlightInputPortStatus::Accepted});
    const auto context = fixture.context();
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::FocusLost, context).stage,
        MoonlightInputFlushStage::Controller);
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::FocusLost, context).status,
        MoonlightInputFlushStatus::Applied);
    RDP_ASSERT_EQ(fixture.controller->snapshot(fixture.identity).
                      state.buttonFlags,
                  static_cast<std::uint32_t>(0));
}

RDP_TEST_CASE(moonlight_input_flush_different_request_cannot_overtake_pending) {
    FlushFixture fixture(false);
    fixture.seedKeyboard();
    fixture.port->setSendScript({MoonlightInputPortStatus::Backpressure,
                                 MoonlightInputPortStatus::Accepted});
    const auto exact = fixture.context();
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::FocusLost, exact).status,
        MoonlightInputFlushStatus::Pending);
    const auto before = fixture.port->eventCount();
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::Backgrounded,
        fixture.context(101U, 1100U, 11U)).status,
        MoonlightInputFlushStatus::Pending);
    RDP_ASSERT_EQ(fixture.port->eventCount(), before);
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::FocusLost, exact).status,
        MoonlightInputFlushStatus::Applied);
}

RDP_TEST_CASE(moonlight_input_flush_stop_boundary_failure_keeps_local_release_terminal) {
    FlushFixture fixture;
    fixture.seedAll();
    fixture.port->setFlushScript({false});
    const auto result = fixture.policy->flush(
        MoonlightInputFlushTrigger::SessionStop, fixture.context());
    RDP_ASSERT_EQ(result.status, MoonlightInputFlushStatus::AppliedLocally);
    RDP_ASSERT(result.localReleased && !result.boundaryApplied);
    const auto snapshot = fixture.policy->snapshot(fixture.identity);
    RDP_ASSERT_EQ(snapshot.state, MoonlightInputFlushState::Stopped);
    RDP_ASSERT(!snapshot.admissionOpen);
    RDP_ASSERT_EQ(snapshot.localOnlyStops, static_cast<std::uint64_t>(1));
    RDP_ASSERT_EQ(fixture.keyboard->snapshot(fixture.identity).
                      pressedNonModifierKeys,
                  static_cast<std::size_t>(0));
    RDP_ASSERT_EQ(fixture.pointer->snapshot(fixture.identity).pressedButtons,
                  static_cast<std::size_t>(0));
    RDP_ASSERT_EQ(fixture.touch->snapshot(fixture.identity).activeDirectContacts,
                  static_cast<std::size_t>(0));
    RDP_ASSERT_EQ(fixture.policy->resume(fixture.identity, 101U).status,
                  MoonlightInputFlushStatus::InvalidState);
}

RDP_TEST_CASE(moonlight_input_flush_suspend_boundary_retry_never_replays_mappers) {
    FlushFixture fixture(false);
    fixture.seedKeyboard();
    fixture.port->setFlushScript({false, true});
    const auto result = fixture.policy->flush(
        MoonlightInputFlushTrigger::FocusLost, fixture.context());
    RDP_ASSERT_EQ(result.status, MoonlightInputFlushStatus::BoundaryFailure);
    const auto eventCount = fixture.port->eventCount();
    RDP_ASSERT_EQ(fixture.policy->retryBoundary(
        fixture.identity, 100U, 1010U).status,
        MoonlightInputFlushStatus::StaleOperation);
    RDP_ASSERT_EQ(fixture.policy->retryBoundary(
        fixture.identity, 101U, 1010U).status,
        MoonlightInputFlushStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->eventCount(), eventCount);
    RDP_ASSERT_EQ(fixture.port->flushCount(), static_cast<std::size_t>(2));
    RDP_ASSERT_EQ(fixture.policy->snapshot(fixture.identity).state,
                  MoonlightInputFlushState::Suspended);
}

RDP_TEST_CASE(moonlight_input_flush_stop_escalates_failed_suspend_without_replay) {
    FlushFixture fixture(false);
    fixture.seedKeyboard();
    fixture.port->setFlushScript({false, true});
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::FocusLost, fixture.context()).status,
        MoonlightInputFlushStatus::BoundaryFailure);
    const auto events = fixture.port->eventCount();
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::SessionStop,
        fixture.context(101U, 1100U, 11U)).status,
        MoonlightInputFlushStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->eventCount(), events);
    RDP_ASSERT_EQ(fixture.port->flushCount(), static_cast<std::size_t>(2));
    RDP_ASSERT_EQ(fixture.policy->snapshot(fixture.identity).state,
                  MoonlightInputFlushState::Stopped);
}

RDP_TEST_CASE(moonlight_input_flush_controller_disconnect_clears_active_mask) {
    FlushFixture fixture;
    fixture.seedController();
    const auto before = fixture.port->eventCount();
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::ControllerDisconnected,
        fixture.context()).status,
        MoonlightInputFlushStatus::Applied);
    MoonlightControllerWireCommand command;
    RDP_ASSERT(decodeMoonlightControllerCommand(
        fixture.port->eventAt(before), command));
    RDP_ASSERT_EQ(command.activeGamepadMask, static_cast<std::uint16_t>(0));
    RDP_ASSERT(!fixture.controller->snapshot(fixture.identity).active);
}

RDP_TEST_CASE(moonlight_input_flush_optional_controller_is_safe_noop) {
    FlushFixture fixture(false);
    fixture.seedPointer();
    const auto result = fixture.policy->flush(
        MoonlightInputFlushTrigger::PipEntered, fixture.context());
    RDP_ASSERT_EQ(result.status, MoonlightInputFlushStatus::Applied);
    RDP_ASSERT_EQ(fixture.policy->snapshot(fixture.identity).state,
                  MoonlightInputFlushState::Suspended);
}

RDP_TEST_CASE(moonlight_input_flush_concurrent_same_request_is_serial_and_idempotent) {
    FlushFixture fixture(false);
    fixture.seedKeyboard();
    const auto context = fixture.context();
    MoonlightInputFlushStatus first = MoonlightInputFlushStatus::InvalidState;
    MoonlightInputFlushStatus second = MoonlightInputFlushStatus::InvalidState;
    std::thread one([&]() {
        first = fixture.policy->flush(
            MoonlightInputFlushTrigger::Backgrounded, context).status;
    });
    std::thread two([&]() {
        second = fixture.policy->flush(
            MoonlightInputFlushTrigger::Backgrounded, context).status;
    });
    one.join();
    two.join();
    const bool valid =
        (first == MoonlightInputFlushStatus::Applied &&
         second == MoonlightInputFlushStatus::AlreadyApplied) ||
        (second == MoonlightInputFlushStatus::Applied &&
         first == MoonlightInputFlushStatus::AlreadyApplied);
    RDP_ASSERT(valid);
    RDP_ASSERT_EQ(fixture.port->flushCount(), static_cast<std::size_t>(1));
}

RDP_TEST_CASE(moonlight_input_flush_closes_real_admission_while_mapper_release_is_pending) {
    FlushFixture fixture(false);
    fixture.seedKeyboard();
    fixture.port->setSendScript({MoonlightInputPortStatus::Backpressure});
    const auto context = fixture.context();
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::FocusLost, context).status,
        MoonlightInputFlushStatus::Pending);
    RDP_ASSERT_EQ(fixture.bridge->snapshot(fixture.identity).state,
                  MoonlightInputState::ReleasePending);

    MoonlightPointerStatus intruder = MoonlightPointerStatus::Applied;
    std::thread input([&]() {
        intruder = fixture.pointer->button(
            fixture.pointerContext(11U, 1100U),
            MoonlightPointerButton::Left, true).status;
    });
    input.join();
    RDP_ASSERT_EQ(intruder, MoonlightPointerStatus::InvalidState);
    RDP_ASSERT_EQ(fixture.pointer->snapshot(fixture.identity).pressedButtons,
                  static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_input_flush_terminal_discards_every_permanent_component_failure) {
    for (std::size_t failedStage = 0U; failedStage < 4U; ++failedStage) {
        FlushFixture fixture;
        fixture.seedAll();
        std::vector<MoonlightInputPortStatus> script(
            failedStage, MoonlightInputPortStatus::Accepted);
        script.push_back(MoonlightInputPortStatus::Unsupported);
        fixture.port->setSendScript(std::move(script));
        const auto result = fixture.policy->flush(
            MoonlightInputFlushTrigger::SessionStop, fixture.context());
        RDP_ASSERT_EQ(result.status, MoonlightInputFlushStatus::Applied);
        RDP_ASSERT(result.localReleased && result.boundaryApplied);
        RDP_ASSERT_EQ(fixture.policy->snapshot(fixture.identity).state,
                      MoonlightInputFlushState::Stopped);
        RDP_ASSERT_EQ(fixture.bridge->snapshot(fixture.identity).state,
                      MoonlightInputState::Stopped);
        RDP_ASSERT_EQ(fixture.touch->snapshot(fixture.identity).
                          activeDirectContacts,
                      static_cast<std::size_t>(0));
        RDP_ASSERT_EQ(fixture.pointer->snapshot(fixture.identity).pressedButtons,
                      static_cast<std::size_t>(0));
        RDP_ASSERT_EQ(fixture.keyboard->snapshot(fixture.identity).
                          pressedNonModifierKeys,
                      static_cast<std::size_t>(0));
        RDP_ASSERT(!fixture.controller->snapshot(fixture.identity).active);
    }
}

RDP_TEST_CASE(moonlight_input_flush_terminal_owner_loss_is_local_terminal) {
    FlushFixture fixture;
    fixture.seedAll();
    fixture.gate->revoke();
    const auto result = fixture.policy->flush(
        MoonlightInputFlushTrigger::SessionStop, fixture.context());
    RDP_ASSERT_EQ(result.status, MoonlightInputFlushStatus::AppliedLocally);
    RDP_ASSERT(result.localReleased && !result.boundaryApplied);
    RDP_ASSERT_EQ(fixture.policy->snapshot(fixture.identity).state,
                  MoonlightInputFlushState::Stopped);
    RDP_ASSERT_EQ(fixture.bridge->snapshot(fixture.identity).state,
                  MoonlightInputState::Stopped);
    RDP_ASSERT_EQ(fixture.touch->snapshot(fixture.identity).activeDirectContacts,
                  static_cast<std::size_t>(0));
    RDP_ASSERT_EQ(fixture.pointer->snapshot(fixture.identity).pressedButtons,
                  static_cast<std::size_t>(0));
    RDP_ASSERT_EQ(fixture.keyboard->snapshot(fixture.identity).
                      pressedNonModifierKeys,
                  static_cast<std::size_t>(0));
    RDP_ASSERT(!fixture.controller->snapshot(fixture.identity).active);
}

RDP_TEST_CASE(moonlight_input_flush_stop_escalates_component_pending_to_local_release) {
    FlushFixture fixture(false);
    fixture.seedKeyboard();
    fixture.port->setSendScript({MoonlightInputPortStatus::Backpressure,
                                 MoonlightInputPortStatus::Backpressure});
    const auto suspendContext = fixture.context();
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::FocusLost, suspendContext).status,
        MoonlightInputFlushStatus::Pending);
    const auto pendingRelease = fixture.port->eventAt(
        fixture.port->eventCount() - 1U);
    const auto stopContext = fixture.context(101U, 1100U, 11U);
    const auto result = fixture.policy->flush(
        MoonlightInputFlushTrigger::SessionStop,
        stopContext);
    RDP_ASSERT_EQ(result.status, MoonlightInputFlushStatus::Applied);
    RDP_ASSERT(result.localReleased && result.boundaryApplied);
    RDP_ASSERT_EQ(fixture.policy->snapshot(fixture.identity).state,
                  MoonlightInputFlushState::Stopped);
    const auto keyboard = fixture.keyboard->snapshot(fixture.identity);
    RDP_ASSERT(!keyboard.pending);
    RDP_ASSERT_EQ(keyboard.pressedNonModifierKeys, static_cast<std::size_t>(0));
    RDP_ASSERT_EQ(fixture.bridge->snapshot(fixture.identity).state,
                  MoonlightInputState::Stopped);
    const auto resumedRelease = fixture.port->eventAt(
        fixture.port->eventCount() - 1U);
    RDP_ASSERT_EQ(resumedRelease.sourceSequence,
                  pendingRelease.sourceSequence);
    RDP_ASSERT_EQ(resumedRelease.monotonicTimestampUs,
                  suspendContext.keyboard.monotonicTimestampUs);
    const auto eventsBeforeReplay = fixture.port->eventCount();
    const auto flushesBeforeReplay = fixture.port->flushCount();
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::SessionStop, stopContext).status,
        MoonlightInputFlushStatus::AlreadyApplied);
    RDP_ASSERT_EQ(fixture.port->eventCount(), eventsBeforeReplay);
    RDP_ASSERT_EQ(fixture.port->flushCount(), flushesBeforeReplay);
}

RDP_TEST_CASE(moonlight_input_flush_local_terminal_escalation_replays_exact_stop) {
    FlushFixture fixture(false);
    fixture.seedKeyboard();
    fixture.port->setSendScript({MoonlightInputPortStatus::Backpressure,
                                 MoonlightInputPortStatus::Accepted});
    fixture.port->setFlushScript({false});
    const auto suspendContext = fixture.context();
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::FocusLost, suspendContext).status,
        MoonlightInputFlushStatus::Pending);
    const auto pendingRelease = fixture.port->eventAt(
        fixture.port->eventCount() - 1U);
    const auto stopContext = fixture.context(101U, 1100U, 11U);
    const auto result = fixture.policy->flush(
        MoonlightInputFlushTrigger::SessionStop, stopContext);
    RDP_ASSERT_EQ(result.status, MoonlightInputFlushStatus::AppliedLocally);
    RDP_ASSERT(result.localReleased && !result.boundaryApplied);
    const auto resumedRelease = fixture.port->eventAt(
        fixture.port->eventCount() - 1U);
    RDP_ASSERT_EQ(resumedRelease.sourceSequence,
                  pendingRelease.sourceSequence);
    RDP_ASSERT_EQ(resumedRelease.monotonicTimestampUs,
                  suspendContext.keyboard.monotonicTimestampUs);
    const auto eventsBeforeReplay = fixture.port->eventCount();
    const auto flushesBeforeReplay = fixture.port->flushCount();
    RDP_ASSERT_EQ(fixture.policy->flush(
        MoonlightInputFlushTrigger::SessionStop, stopContext).status,
        MoonlightInputFlushStatus::AlreadyApplied);
    RDP_ASSERT_EQ(fixture.port->eventCount(), eventsBeforeReplay);
    RDP_ASSERT_EQ(fixture.port->flushCount(), flushesBeforeReplay);
    RDP_ASSERT_EQ(flushesBeforeReplay, static_cast<std::size_t>(1));
}

} // namespace
