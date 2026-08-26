#include "moonlight/input/MoonlightInputBridge.h"
#include "render/video_perf_counters.h"
#include "test/test_runner.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace {

using namespace remotedesk::moonlight;
using namespace std::chrono_literals;

MoonlightInputIdentity inputIdentity(std::uint64_t ownerToken = 61U,
                                     std::uint64_t inputGeneration = 2U) {
    return {{901U, 17U, ownerToken}, inputGeneration};
}

MoonlightInputEvent inputEvent(const MoonlightInputIdentity& identity,
                               std::uint64_t sequence = 1U,
                               std::uint64_t timestampUs = 100U,
                               std::uint64_t deviceId = 11U,
                               MoonlightInputSource source = MoonlightInputSource::PhysicalKeyboard,
                               MoonlightInputCommandKind kind = MoonlightInputCommandKind::Keyboard,
                               std::uint64_t sourceGeneration = 1U) {
    MoonlightInputEvent event;
    event.identity = identity;
    event.deviceId = deviceId;
    event.source = source;
    event.sourceGeneration = sourceGeneration;
    event.sourceSequence = sequence;
    event.monotonicTimestampUs = timestampUs;
    event.kind = kind;
    event.commandVersion = 1U;
    event.payloadSize = 2U;
    event.payload[0] = 0x2aU;
    event.payload[1] = 0x01U;
    return event;
}

class FakeInputOwnerGate final : public MoonlightInputOwnerGate {
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

class FakeInputPort final : public MoonlightInputPort {
  public:
    MoonlightInputPortStatus send(const MoonlightInputEvent& event) noexcept override {
        std::unique_lock<std::mutex> lock(mutex_);
        sendEntered_ = true;
        cv_.notify_all();
        cv_.wait(lock, [&]() { return !blockSend_; });
        ++sendCalls_;
        events_.push_back(event);
        return sendStatus_;
    }

    bool flushNeutral(const MoonlightInputFlushRequest& request) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        ++flushCalls_;
        flushes_.push_back(request);
        return flushResult_;
    }

    MoonlightInputPortStatus resetRemoteState(
        const MoonlightInputRecoveryResetRequest& request) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        ++resetCalls_;
        resets_.push_back(request);
        return resetStatus_;
    }

    void blockSend() {
        std::lock_guard<std::mutex> lock(mutex_);
        blockSend_ = true;
        sendEntered_ = false;
    }

    void waitForSend() {
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait(lock, [&]() { return sendEntered_; });
    }

    void releaseSend() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            blockSend_ = false;
        }
        cv_.notify_all();
    }

    MoonlightInputPortStatus sendStatus_ = MoonlightInputPortStatus::Accepted;
    MoonlightInputPortStatus resetStatus_ = MoonlightInputPortStatus::Accepted;
    bool flushResult_ = true;
    std::size_t sendCalls_ = 0U;
    std::size_t flushCalls_ = 0U;
    std::size_t resetCalls_ = 0U;
    std::vector<MoonlightInputEvent> events_;
    std::vector<MoonlightInputFlushRequest> flushes_;
    std::vector<MoonlightInputRecoveryResetRequest> resets_;

  private:
    std::mutex mutex_;
    std::condition_variable cv_;
    bool blockSend_ = false;
    bool sendEntered_ = false;
};

class CountingOwnedOperation final : public MoonlightInputOwnedOperation {
  public:
    void execute() noexcept override { ++calls; }
    std::size_t calls = 0U;
};

struct InputFixture final {
    explicit InputFixture(MoonlightInputLimits limits = {}) {
        gate->accept(identity);
        bridge = MoonlightInputBridge::create(gate, port, limits);
        RDP_ASSERT(bridge != nullptr);
        RDP_ASSERT_EQ(bridge->activate(identity, 1U).status,
                      MoonlightInputControlStatus::Applied);
    }

    MoonlightInputIdentity identity = inputIdentity();
    std::shared_ptr<FakeInputOwnerGate> gate = std::make_shared<FakeInputOwnerGate>();
    std::shared_ptr<FakeInputPort> port = std::make_shared<FakeInputPort>();
    std::shared_ptr<MoonlightInputBridge> bridge;
};

MoonlightSessionOwner::Driver immediateDriver() {
    return {
        [](MoonlightSessionOwner::StartContext& context) {
            return context.markInterruptible() ? 0 : -1;
        },
        []() {},
        []() {},
    };
}

RDP_TEST_CASE(moonlight_input_bridge_rejects_invalid_limits_identity_and_event) {
    auto gate = std::make_shared<FakeInputOwnerGate>();
    auto port = std::make_shared<FakeInputPort>();
    MoonlightInputLimits limits;
    limits.sourceLaneCapacity = 0U;
    RDP_ASSERT(MoonlightInputBridge::create(gate, port, limits) == nullptr);
    limits.sourceLaneCapacity = kMoonlightMaximumInputSourceLanes + 1U;
    RDP_ASSERT(MoonlightInputBridge::create(gate, port, limits) == nullptr);
    limits = {};
    limits.maximumPayloadBytes = 0U;
    RDP_ASSERT(MoonlightInputBridge::create(gate, port, limits) == nullptr);
    RDP_ASSERT(MoonlightInputBridge::create(nullptr, port) == nullptr);

    auto bridge = MoonlightInputBridge::create(gate, port);
    RDP_ASSERT(bridge != nullptr);
    RDP_ASSERT_EQ(bridge->activate({}, 1U).status,
                  MoonlightInputControlStatus::InvalidRequest);
    const auto identity = inputIdentity();
    gate->accept(identity);
    RDP_ASSERT_EQ(bridge->activate(identity, 1U).status,
                  MoonlightInputControlStatus::Applied);
    auto event = inputEvent(identity);
    event.payloadSize = 0U;
    RDP_ASSERT_EQ(bridge->dispatch(event), MoonlightInputDispatchStatus::InvalidRequest);
    event = inputEvent(identity);
    event.commandVersion = 0U;
    RDP_ASSERT_EQ(bridge->dispatch(event), MoonlightInputDispatchStatus::InvalidRequest);
    event = inputEvent(identity);
    event.source = MoonlightInputSource::Invalid;
    RDP_ASSERT_EQ(bridge->dispatch(event), MoonlightInputDispatchStatus::InvalidRequest);
    event = inputEvent(identity);
    event.kind = MoonlightInputCommandKind::Invalid;
    RDP_ASSERT_EQ(bridge->dispatch(event), MoonlightInputDispatchStatus::InvalidRequest);
    event = inputEvent(identity);
    event.payloadSize = kMoonlightMaximumInputPayloadBytes;
    event.payload[kMoonlightMaximumInputPayloadBytes - 1U] = 1U;
    limits = {};
    limits.maximumPayloadBytes = 8U;
    auto narrow = MoonlightInputBridge::create(gate, port, limits);
    RDP_ASSERT(narrow != nullptr);
    RDP_ASSERT_EQ(narrow->activate(identity, 1U).status,
                  MoonlightInputControlStatus::Applied);
    RDP_ASSERT_EQ(narrow->dispatch(event), MoonlightInputDispatchStatus::InvalidRequest);
    event = inputEvent(identity);
    event.payload[7] = 1U;
    RDP_ASSERT_EQ(bridge->dispatch(event), MoonlightInputDispatchStatus::InvalidRequest);
    event = inputEvent(identity);
    event.source = MoonlightInputSource::GameController;
    RDP_ASSERT_EQ(bridge->dispatch(event), MoonlightInputDispatchStatus::InvalidRequest);
    RDP_ASSERT_EQ(port->sendCalls_, static_cast<std::size_t>(0U));
}

RDP_TEST_CASE(moonlight_input_bridge_forwards_exact_metadata_and_bounded_payload) {
    InputFixture fixture;
    const auto event = inputEvent(fixture.identity, 7U, 900U, 77U,
                                  MoonlightInputSource::Mouse,
                                  MoonlightInputCommandKind::RelativePointer, 4U);
    RDP_ASSERT_EQ(fixture.bridge->dispatch(event), MoonlightInputDispatchStatus::Accepted);
    RDP_ASSERT_EQ(fixture.port->events_.size(), static_cast<std::size_t>(1U));
    const auto& forwarded = fixture.port->events_[0];
    RDP_ASSERT(forwarded.identity == fixture.identity);
    RDP_ASSERT_EQ(forwarded.deviceId, static_cast<std::uint64_t>(77U));
    RDP_ASSERT_EQ(forwarded.sourceGeneration, static_cast<std::uint64_t>(4U));
    RDP_ASSERT_EQ(forwarded.sourceSequence, static_cast<std::uint64_t>(7U));
    RDP_ASSERT_EQ(forwarded.monotonicTimestampUs, static_cast<std::uint64_t>(900U));
    RDP_ASSERT_EQ(forwarded.payload[0], static_cast<std::uint8_t>(0x2aU));
}

RDP_TEST_CASE(moonlight_input_bridge_rejects_stale_session_input_owner_and_source) {
    InputFixture fixture;
    auto staleOwner = inputEvent(fixture.identity);
    ++staleOwner.identity.key.ownerToken;
    RDP_ASSERT_EQ(fixture.bridge->dispatch(staleOwner),
                  MoonlightInputDispatchStatus::StaleOwner);
    auto staleInput = inputEvent(fixture.identity);
    ++staleInput.identity.inputGeneration;
    RDP_ASSERT_EQ(fixture.bridge->dispatch(staleInput),
                  MoonlightInputDispatchStatus::StaleOwner);
    RDP_ASSERT_EQ(fixture.bridge->dispatch(inputEvent(fixture.identity, 2U, 200U)),
                  MoonlightInputDispatchStatus::Accepted);
    RDP_ASSERT_EQ(fixture.bridge->dispatch(inputEvent(fixture.identity, 1U, 201U)),
                  MoonlightInputDispatchStatus::StaleEvent);
    RDP_ASSERT_EQ(fixture.bridge->dispatch(inputEvent(fixture.identity, 2U, 202U)),
                  MoonlightInputDispatchStatus::Duplicate);
}

RDP_TEST_CASE(moonlight_input_bridge_retries_uncommitted_backpressure_and_port_results) {
    InputFixture fixture;
    const auto event = inputEvent(fixture.identity);
    fixture.port->sendStatus_ = MoonlightInputPortStatus::Backpressure;
    RDP_ASSERT_EQ(fixture.bridge->dispatch(event), MoonlightInputDispatchStatus::Backpressure);
    fixture.port->sendStatus_ = MoonlightInputPortStatus::Unsupported;
    RDP_ASSERT_EQ(fixture.bridge->dispatch(event), MoonlightInputDispatchStatus::Unsupported);
    fixture.port->sendStatus_ = MoonlightInputPortStatus::Failed;
    RDP_ASSERT_EQ(fixture.bridge->dispatch(event), MoonlightInputDispatchStatus::PortFailure);
    fixture.port->sendStatus_ = MoonlightInputPortStatus::Accepted;
    RDP_ASSERT_EQ(fixture.bridge->dispatch(event), MoonlightInputDispatchStatus::Accepted);
    RDP_ASSERT_EQ(fixture.bridge->dispatch(event), MoonlightInputDispatchStatus::Duplicate);
    const auto snapshot = fixture.bridge->snapshot(fixture.identity);
    RDP_ASSERT_EQ(snapshot.acceptedEvents, static_cast<std::uint64_t>(1U));
    RDP_ASSERT_EQ(snapshot.backpressureEvents, static_cast<std::uint64_t>(1U));
    RDP_ASSERT_EQ(snapshot.unsupportedEvents, static_cast<std::uint64_t>(1U));
    RDP_ASSERT_EQ(snapshot.portFailures, static_cast<std::uint64_t>(1U));
    RDP_ASSERT_EQ(snapshot.duplicateEvents, static_cast<std::uint64_t>(1U));
}

RDP_TEST_CASE(moonlight_input_bridge_recovery_reset_is_exact_retryable_and_owner_scoped) {
    InputFixture fixture;
    MoonlightInputRecoveryResetRequest request;
    request.identity = fixture.identity;
    request.operationGeneration = 2U;
    request.monotonicTimestampUs = 100U;
    request.activeGamepadMask = 1U;
    request.controllerSlots = 1U;

    fixture.port->resetStatus_ = MoonlightInputPortStatus::Backpressure;
    RDP_ASSERT_EQ(fixture.bridge->resetRemoteState(request).status,
                  MoonlightInputControlStatus::PortFailure);
    auto snapshot = fixture.bridge->snapshot(fixture.identity);
    RDP_ASSERT_EQ(snapshot.recoveryResetBackpressure,
                  static_cast<std::uint64_t>(1U));
    RDP_ASSERT_EQ(snapshot.recoveryResets, static_cast<std::uint64_t>(0U));

    fixture.port->resetStatus_ = MoonlightInputPortStatus::Accepted;
    RDP_ASSERT_EQ(fixture.bridge->resetRemoteState(request).status,
                  MoonlightInputControlStatus::Applied);
    RDP_ASSERT_EQ(fixture.bridge->resetRemoteState(request).status,
                  MoonlightInputControlStatus::AlreadyApplied);
    snapshot = fixture.bridge->snapshot(fixture.identity);
    RDP_ASSERT_EQ(snapshot.recoveryResets, static_cast<std::uint64_t>(1U));
    RDP_ASSERT_EQ(fixture.port->resetCalls_, static_cast<std::size_t>(2U));
    RDP_ASSERT(fixture.port->resets_[0].identity == fixture.identity);
    RDP_ASSERT_EQ(fixture.port->resets_[0].activeGamepadMask,
                  static_cast<std::uint16_t>(1U));

    auto stale = request;
    ++stale.identity.inputGeneration;
    stale.operationGeneration = 3U;
    RDP_ASSERT_EQ(fixture.bridge->resetRemoteState(stale).status,
                  MoonlightInputControlStatus::Stale);
    RDP_ASSERT_EQ(fixture.port->resetCalls_, static_cast<std::size_t>(2U));
}

RDP_TEST_CASE(moonlight_input_bridge_tracks_independent_lanes_and_source_generation) {
    InputFixture fixture;
    RDP_ASSERT_EQ(fixture.bridge->dispatch(inputEvent(fixture.identity, 5U, 100U, 1U)),
                  MoonlightInputDispatchStatus::Accepted);
    RDP_ASSERT_EQ(fixture.bridge->dispatch(inputEvent(
                      fixture.identity, 1U, 100U, 2U, MoonlightInputSource::Touchscreen,
                      MoonlightInputCommandKind::Touch)),
                  MoonlightInputDispatchStatus::Accepted);
    RDP_ASSERT_EQ(fixture.bridge->dispatch(inputEvent(fixture.identity, 1U, 101U, 1U,
                                                      MoonlightInputSource::PhysicalKeyboard,
                                                      MoonlightInputCommandKind::Keyboard, 2U)),
                  MoonlightInputDispatchStatus::Accepted);
    RDP_ASSERT_EQ(fixture.bridge->dispatch(inputEvent(fixture.identity, 2U, 99U, 1U,
                                                      MoonlightInputSource::PhysicalKeyboard,
                                                      MoonlightInputCommandKind::Keyboard, 1U)),
                  MoonlightInputDispatchStatus::StaleEvent);
    RDP_ASSERT_EQ(fixture.bridge->dispatch(inputEvent(fixture.identity, 1U, 100U, 1U,
                                                      MoonlightInputSource::PhysicalKeyboard,
                                                      MoonlightInputCommandKind::Keyboard, 3U)),
                  MoonlightInputDispatchStatus::StaleEvent);
    RDP_ASSERT_EQ(fixture.bridge->snapshot(fixture.identity).sourceLanes,
                  static_cast<std::size_t>(2U));
}

RDP_TEST_CASE(moonlight_input_bridge_fails_closed_at_fixed_source_capacity) {
    MoonlightInputLimits limits;
    limits.sourceLaneCapacity = 2U;
    InputFixture fixture(limits);
    RDP_ASSERT_EQ(fixture.bridge->dispatch(inputEvent(fixture.identity, 1U, 100U, 1U)),
                  MoonlightInputDispatchStatus::Accepted);
    RDP_ASSERT_EQ(fixture.bridge->dispatch(inputEvent(
                      fixture.identity, 1U, 100U, 2U, MoonlightInputSource::Mouse,
                      MoonlightInputCommandKind::RelativePointer)),
                  MoonlightInputDispatchStatus::Accepted);
    RDP_ASSERT_EQ(fixture.bridge->dispatch(inputEvent(
                      fixture.identity, 1U, 100U, 3U, MoonlightInputSource::Touchscreen,
                      MoonlightInputCommandKind::Touch)),
                  MoonlightInputDispatchStatus::SourceCapacity);
    RDP_ASSERT_EQ(fixture.port->sendCalls_, static_cast<std::size_t>(2U));
}

RDP_TEST_CASE(moonlight_input_bridge_focus_loss_flushes_freezes_and_resumes) {
    InputFixture fixture;
    RDP_ASSERT_EQ(fixture.bridge->dispatch(inputEvent(fixture.identity, 1U, 100U)),
                  MoonlightInputDispatchStatus::Accepted);
    RDP_ASSERT_EQ(fixture.bridge->focusLost(fixture.identity, 2U, 200U).status,
                  MoonlightInputControlStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->flushCalls_, static_cast<std::size_t>(1U));
    RDP_ASSERT_EQ(fixture.port->flushes_[0].reason, MoonlightInputSuspendReason::FocusLost);
    RDP_ASSERT_EQ(fixture.bridge->focusLost(fixture.identity, 3U, 200U).status,
                  MoonlightInputControlStatus::AlreadyApplied);
    RDP_ASSERT_EQ(fixture.bridge->dispatch(inputEvent(fixture.identity, 2U, 201U)),
                  MoonlightInputDispatchStatus::InvalidState);
    RDP_ASSERT_EQ(fixture.bridge->resume(fixture.identity, 4U).status,
                  MoonlightInputControlStatus::Applied);
    RDP_ASSERT_EQ(fixture.bridge->dispatch(inputEvent(fixture.identity, 2U, 199U)),
                  MoonlightInputDispatchStatus::StaleEvent);
    RDP_ASSERT_EQ(fixture.bridge->dispatch(inputEvent(fixture.identity, 2U, 201U)),
                  MoonlightInputDispatchStatus::Accepted);
}

RDP_TEST_CASE(moonlight_input_bridge_failed_focus_release_stays_frozen_until_retry) {
    InputFixture fixture;
    fixture.port->flushResult_ = false;
    RDP_ASSERT_EQ(fixture.bridge->focusLost(fixture.identity, 2U, 200U).status,
                  MoonlightInputControlStatus::PortFailure);
    RDP_ASSERT_EQ(fixture.bridge->snapshot(fixture.identity).state,
                  MoonlightInputState::ReleasePending);
    RDP_ASSERT_EQ(fixture.bridge->resume(fixture.identity, 3U).status,
                  MoonlightInputControlStatus::InvalidState);
    fixture.port->flushResult_ = true;
    RDP_ASSERT_EQ(fixture.bridge->focusLost(fixture.identity, 4U, 201U).status,
                  MoonlightInputControlStatus::Applied);
    RDP_ASSERT_EQ(fixture.bridge->resume(fixture.identity, 5U).status,
                  MoonlightInputControlStatus::Applied);
}

RDP_TEST_CASE(moonlight_input_bridge_stop_cleanup_and_higher_generation_reuse_are_exact) {
    InputFixture fixture;
    auto stale = fixture.identity;
    ++stale.key.generation;
    RDP_ASSERT_EQ(fixture.bridge->stop(stale, 2U, 200U).status,
                  MoonlightInputControlStatus::Stale);
    RDP_ASSERT_EQ(fixture.bridge->cleanup(fixture.identity, 2U).status,
                  MoonlightInputControlStatus::InvalidState);
    RDP_ASSERT_EQ(fixture.bridge->stop(fixture.identity, 2U, 200U).status,
                  MoonlightInputControlStatus::Applied);
    RDP_ASSERT_EQ(fixture.bridge->dispatch(inputEvent(fixture.identity, 2U, 201U)),
                  MoonlightInputDispatchStatus::InvalidState);
    RDP_ASSERT_EQ(fixture.bridge->stop(fixture.identity, 3U, 201U).status,
                  MoonlightInputControlStatus::AlreadyApplied);
    RDP_ASSERT_EQ(fixture.bridge->cleanup(fixture.identity, 4U).status,
                  MoonlightInputControlStatus::Applied);
    RDP_ASSERT_EQ(fixture.bridge->cleanup(fixture.identity, 4U).status,
                  MoonlightInputControlStatus::AlreadyApplied);
    RDP_ASSERT_EQ(fixture.bridge->activate(fixture.identity, 5U).status,
                  MoonlightInputControlStatus::Stale);
    auto next = fixture.identity;
    ++next.inputGeneration;
    fixture.gate->accept(next);
    RDP_ASSERT_EQ(fixture.bridge->activate(next, 1U).status,
                  MoonlightInputControlStatus::Applied);
}

RDP_TEST_CASE(moonlight_input_bridge_owner_loss_never_crosses_protocol_route) {
    InputFixture fixture;
    fixture.gate->reject();
    RDP_ASSERT_EQ(fixture.bridge->dispatch(inputEvent(fixture.identity)),
                  MoonlightInputDispatchStatus::StaleOwner);
    RDP_ASSERT_EQ(fixture.port->sendCalls_, static_cast<std::size_t>(0U));
    RDP_ASSERT_EQ(fixture.bridge->focusLost(fixture.identity, 2U, 200U).status,
                  MoonlightInputControlStatus::OwnerUnavailable);
    RDP_ASSERT_EQ(fixture.port->flushCalls_, static_cast<std::size_t>(0U));
}

RDP_TEST_CASE(moonlight_input_bridge_process_gate_combines_session_and_protocol_owner) {
    auto owner = MoonlightSessionOwner::createForTesting();
    const auto started = owner->start(902U, 19U, immediateDriver());
    RDP_ASSERT_EQ(started.status, MoonlightStartStatus::Accepted);
    RDP_ASSERT(owner->waitForPhase(started.key, MoonlightSessionPhase::Running, 1s));
    Render::SessionSinkOwnerLease sharedOwner;
    const Render::DecoderSessionIdentity sharedIdentity{
        started.key.sessionId, started.key.generation, started.key.ownerToken};
    RDP_ASSERT(sharedOwner.activate(sharedIdentity));
    auto gate = createMoonlightInputOwnerGate(*owner, sharedOwner);
    auto port = std::make_shared<FakeInputPort>();
    const MoonlightInputIdentity identity{started.key, 1U};
    auto bridge = MoonlightInputBridge::create(gate, port);
    RDP_ASSERT(bridge != nullptr);
    RDP_ASSERT_EQ(bridge->activate(identity, 1U).status,
                  MoonlightInputControlStatus::Applied);
    RDP_ASSERT_EQ(bridge->dispatch(inputEvent(identity, 1U, 100U)),
                  MoonlightInputDispatchStatus::Accepted);

    const Render::DecoderSessionIdentity otherProtocol{990U, 1U, 990U};
    RDP_ASSERT(sharedOwner.activate(otherProtocol));
    RDP_ASSERT_EQ(bridge->dispatch(inputEvent(identity, 2U, 101U)),
                  MoonlightInputDispatchStatus::StaleOwner);
    RDP_ASSERT_EQ(port->sendCalls_, static_cast<std::size_t>(1U));

    RDP_ASSERT(sharedOwner.activate(sharedIdentity));
    RDP_ASSERT_EQ(bridge->stop(identity, 2U, 200U).status,
                  MoonlightInputControlStatus::Applied);
    RDP_ASSERT_EQ(owner->stop(started.key, 1s), MoonlightStopStatus::Stopped);
    CountingOwnedOperation afterStop;
    RDP_ASSERT(!gate->withOwner(identity, afterStop));
    RDP_ASSERT_EQ(afterStop.calls, static_cast<std::size_t>(0U));
}

RDP_TEST_CASE(moonlight_input_bridge_serializes_duplicate_dispatch_and_stop) {
    InputFixture fixture;
    const auto event = inputEvent(fixture.identity);
    fixture.port->blockSend();
    MoonlightInputDispatchStatus first = MoonlightInputDispatchStatus::PortFailure;
    MoonlightInputDispatchStatus second = MoonlightInputDispatchStatus::PortFailure;
    MoonlightInputControlResult stopped;
    std::thread sender([&]() { first = fixture.bridge->dispatch(event); });
    fixture.port->waitForSend();
    std::thread duplicate([&]() { second = fixture.bridge->dispatch(event); });
    std::thread stopper([&]() { stopped = fixture.bridge->stop(fixture.identity, 2U, 200U); });
    fixture.port->releaseSend();
    sender.join();
    duplicate.join();
    stopper.join();
    RDP_ASSERT_EQ(first, MoonlightInputDispatchStatus::Accepted);
    // Both waiters are serialized behind the accepted send. If stop obtains
    // the bridge mutex first, the duplicate observes the stopped state;
    // otherwise it observes the committed source sequence as a duplicate.
    RDP_ASSERT(second == MoonlightInputDispatchStatus::Duplicate ||
               second == MoonlightInputDispatchStatus::InvalidState);
    RDP_ASSERT_EQ(stopped.status, MoonlightInputControlStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->sendCalls_, static_cast<std::size_t>(1U));
    RDP_ASSERT_EQ(fixture.port->flushCalls_, static_cast<std::size_t>(1U));
}

} // namespace
