#include "moonlight/input/MoonlightControllerMapper.h"
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

MoonlightInputIdentity controllerIdentity(std::uint64_t ownerToken = 107U,
                                           std::uint64_t inputGeneration = 9U) {
    return {{1501U, 47U, ownerToken}, inputGeneration};
}

MoonlightControllerEventContext controllerContext(
    const MoonlightInputIdentity& identity,
    std::uint64_t sequence,
    std::uint64_t timestampUs,
    std::uint64_t deviceId = 71U,
    std::uint64_t sourceGeneration = 1U) {
    return {identity, deviceId, MoonlightInputSource::GameController,
            sourceGeneration, sequence, timestampUs};
}

MoonlightControllerProfile xboxProfile(bool analogTriggers = true) {
    return {MoonlightControllerType::Xbox,
            kMoonlightControllerApi23ButtonMask, analogTriggers};
}

class ControllerOwnerGate final : public MoonlightInputOwnerGate {
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

    void setAvailable(bool available) {
        std::lock_guard<std::mutex> lock(mutex_);
        available_ = available;
    }

  private:
    std::mutex mutex_;
    MoonlightInputIdentity accepted_{};
    bool available_ = false;
};

class ControllerPort final : public MoonlightInputPort {
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

struct ControllerFixture final {
    explicit ControllerFixture(MoonlightControllerLimits requestedLimits = {}) {
        requestedLimits.api23InputAvailable = true;
        limits = requestedLimits;
        gate->accept(identity);
        bridge = MoonlightInputBridge::create(gate, port);
        RDP_ASSERT(bridge != nullptr);
        RDP_ASSERT_EQ(bridge->activate(identity, 1U).status,
                      MoonlightInputControlStatus::Applied);
        mapper = MoonlightControllerMapper::create(bridge, identity, limits);
        RDP_ASSERT(mapper != nullptr);
    }

    MoonlightInputIdentity identity = controllerIdentity();
    MoonlightControllerLimits limits{};
    std::shared_ptr<ControllerOwnerGate> gate =
        std::make_shared<ControllerOwnerGate>();
    std::shared_ptr<ControllerPort> port =
        std::make_shared<ControllerPort>();
    std::shared_ptr<MoonlightInputBridge> bridge;
    std::shared_ptr<MoonlightControllerMapper> mapper;
};

RDP_TEST_CASE(moonlight_controller_creation_is_api23_fail_closed) {
    const auto identity = controllerIdentity();
    auto gate = std::make_shared<ControllerOwnerGate>();
    auto port = std::make_shared<ControllerPort>();
    gate->accept(identity);
    auto bridge = MoonlightInputBridge::create(gate, port);
    RDP_ASSERT(bridge != nullptr);
    RDP_ASSERT(MoonlightControllerMapper::create(bridge, identity) == nullptr);

    MoonlightControllerLimits limits;
    limits.api23InputAvailable = true;
    limits.stickDeadzone = 1.0;
    RDP_ASSERT(MoonlightControllerMapper::create(bridge, identity, limits) == nullptr);
    limits.stickDeadzone = 0.07;
    limits.triggerDeadzone = std::numeric_limits<double>::quiet_NaN();
    RDP_ASSERT(MoonlightControllerMapper::create(bridge, identity, limits) == nullptr);
}

RDP_TEST_CASE(moonlight_controller_official_flags_and_arrival_projection_are_exact) {
    RDP_ASSERT_EQ(kMoonlightControllerButtonA, static_cast<std::uint32_t>(0x1000));
    RDP_ASSERT_EQ(kMoonlightControllerButtonSpecial,
                  static_cast<std::uint32_t>(0x0400));
    RDP_ASSERT_EQ(kMoonlightMaximumPhysicalControllerSlots,
                  static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(kMoonlightProductControllerBitmap,
                  static_cast<std::uint32_t>(1));
    RDP_ASSERT(kMoonlightProductPersistGamepad);

    ControllerFixture fixture;
    const auto profile = xboxProfile();
    RDP_ASSERT_EQ(fixture.mapper->connect(
        controllerContext(fixture.identity, 1U, 100U), profile).status,
        MoonlightControllerStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(1));

    MoonlightControllerWireCommand command;
    RDP_ASSERT(decodeMoonlightControllerCommand(fixture.port->eventAt(0U), command));
    RDP_ASSERT_EQ(command.operation,
                  MoonlightControllerCommandOperation::Arrival);
    RDP_ASSERT_EQ(command.controllerNumber, static_cast<std::uint8_t>(0));
    RDP_ASSERT_EQ(command.activeGamepadMask, static_cast<std::uint16_t>(1));
    RDP_ASSERT_EQ(command.type, MoonlightControllerType::Xbox);
    RDP_ASSERT_EQ(command.capabilities,
                  kMoonlightControllerCapabilityAnalogTriggers);
    RDP_ASSERT_EQ(command.supportedButtonFlags,
                  kMoonlightControllerApi23ButtonMask);
    RDP_ASSERT_EQ(command.state.buttonFlags, static_cast<std::uint32_t>(0));
}

RDP_TEST_CASE(moonlight_controller_two_profiles_hotplug_reuse_stable_slot_zero) {
    ControllerFixture fixture;
    RDP_ASSERT_EQ(fixture.mapper->connect(
        controllerContext(fixture.identity, 1U, 100U), xboxProfile()).status,
        MoonlightControllerStatus::Applied);
    RDP_ASSERT_EQ(fixture.mapper->disconnect(
        controllerContext(fixture.identity, 2U, 110U)).status,
        MoonlightControllerStatus::Applied);

    MoonlightControllerProfile nintendo{
        MoonlightControllerType::Nintendo,
        kMoonlightControllerApi23ButtonMask, false};
    RDP_ASSERT_EQ(fixture.mapper->connect(
        controllerContext(fixture.identity, 1U, 120U, 72U), nintendo).status,
        MoonlightControllerStatus::Applied);
    const auto snapshot = fixture.mapper->snapshot(fixture.identity);
    RDP_ASSERT(snapshot.active);
    RDP_ASSERT_EQ(snapshot.controllerNumber, static_cast<std::uint8_t>(0));
    RDP_ASSERT_EQ(snapshot.deviceId, static_cast<std::uint64_t>(72));
    RDP_ASSERT_EQ(snapshot.profile.type, MoonlightControllerType::Nintendo);

    MoonlightControllerWireCommand removal;
    RDP_ASSERT(decodeMoonlightControllerCommand(fixture.port->eventAt(1U), removal));
    RDP_ASSERT_EQ(removal.operation, MoonlightControllerCommandOperation::State);
    RDP_ASSERT_EQ(removal.activeGamepadMask, static_cast<std::uint16_t>(0));
    RDP_ASSERT_EQ(removal.state.buttonFlags, static_cast<std::uint32_t>(0));
}

RDP_TEST_CASE(moonlight_controller_retired_lane_reuses_generation_and_rejects_old_replay) {
    ControllerFixture fixture;
    for (std::uint64_t generation = 1U; generation <= 20U; ++generation) {
        const std::uint64_t timestamp = generation * 100U;
        RDP_ASSERT_EQ(fixture.mapper->connect(controllerContext(
            fixture.identity, 1U, timestamp, 71U, generation),
            xboxProfile()).status, MoonlightControllerStatus::Applied);
        RDP_ASSERT_EQ(fixture.mapper->disconnect(controllerContext(
            fixture.identity, 2U, timestamp + 10U, 71U, generation)).status,
            MoonlightControllerStatus::Applied);
    }
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).observedLanes,
                  static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(fixture.mapper->connect(controllerContext(
        fixture.identity, 3U, 5000U, 71U, 1U), xboxProfile()).status,
        MoonlightControllerStatus::StaleEvent);
    RDP_ASSERT_EQ(fixture.mapper->connect(controllerContext(
        fixture.identity, 1U, 5100U, 71U, 21U), xboxProfile()).status,
        MoonlightControllerStatus::Applied);
}

RDP_TEST_CASE(moonlight_controller_unproven_multiplayer_rejects_second_device) {
    ControllerFixture fixture;
    RDP_ASSERT_EQ(fixture.mapper->connect(
        controllerContext(fixture.identity, 1U, 100U), xboxProfile()).status,
        MoonlightControllerStatus::Applied);
    const auto result = fixture.mapper->connect(
        controllerContext(fixture.identity, 1U, 110U, 72U), xboxProfile());
    RDP_ASSERT_EQ(result.status, MoonlightControllerStatus::SlotCapacity);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).deviceId,
                  static_cast<std::uint64_t>(71));
}

RDP_TEST_CASE(moonlight_controller_radial_deadzone_preserves_range_and_inverts_y) {
    MoonlightControllerLimits limits;
    limits.api23InputAvailable = true;
    limits.stickDeadzone = 0.07;
    limits.triggerDeadzone = 0.13;
    MoonlightControllerMappedState mapped;
    auto profile = xboxProfile();
    MoonlightControllerSample sample;
    sample.leftStickX = 0.04;
    sample.leftStickY = 0.04;
    sample.rightStickX = 0.08;
    sample.rightStickY = -0.5;
    RDP_ASSERT(mapMoonlightControllerSample(sample, profile, limits, mapped));
    RDP_ASSERT_EQ(mapped.leftStickX, static_cast<std::int16_t>(0));
    RDP_ASSERT_EQ(mapped.leftStickY, static_cast<std::int16_t>(0));
    RDP_ASSERT_EQ(mapped.rightStickX, static_cast<std::int16_t>(2621));
    RDP_ASSERT_EQ(mapped.rightStickY, static_cast<std::int16_t>(16383));

    sample.leftStickX = 1.0;
    sample.leftStickY = 1.0;
    RDP_ASSERT(mapMoonlightControllerSample(sample, profile, limits, mapped));
    RDP_ASSERT_EQ(mapped.leftStickX, static_cast<std::int16_t>(32766));
    RDP_ASSERT_EQ(mapped.leftStickY, static_cast<std::int16_t>(-32766));
}

RDP_TEST_CASE(moonlight_controller_trigger_deadzone_respects_advertised_capability) {
    MoonlightControllerLimits limits;
    limits.api23InputAvailable = true;
    MoonlightControllerSample sample;
    sample.leftTrigger = 0.13;
    sample.rightTrigger = 0.5;
    MoonlightControllerMappedState mapped;
    auto profile = xboxProfile(true);
    RDP_ASSERT(mapMoonlightControllerSample(sample, profile, limits, mapped));
    RDP_ASSERT_EQ(mapped.leftTrigger, static_cast<std::uint8_t>(0));
    RDP_ASSERT_EQ(mapped.rightTrigger, static_cast<std::uint8_t>(127));

    profile.analogTriggers = false;
    RDP_ASSERT(mapMoonlightControllerSample(sample, profile, limits, mapped));
    RDP_ASSERT_EQ(mapped.leftTrigger, static_cast<std::uint8_t>(0));
    RDP_ASSERT_EQ(mapped.rightTrigger, static_cast<std::uint8_t>(255));
}

RDP_TEST_CASE(moonlight_controller_hat_axes_replace_dpad_snapshot_at_half_threshold) {
    MoonlightControllerLimits limits;
    limits.api23InputAvailable = true;
    MoonlightControllerSample sample;
    sample.buttonFlags = kMoonlightControllerButtonA |
        kMoonlightControllerButtonRight;
    sample.hasHatAxes = true;
    sample.hatX = -0.75;
    sample.hatY = 0.75;
    MoonlightControllerMappedState mapped;
    RDP_ASSERT(mapMoonlightControllerSample(sample, xboxProfile(), limits, mapped));
    RDP_ASSERT_EQ(mapped.buttonFlags,
                  kMoonlightControllerButtonA |
                      kMoonlightControllerButtonLeft |
                      kMoonlightControllerButtonDown);

    sample.hatX = -0.5;
    sample.hatY = 0.5;
    RDP_ASSERT(mapMoonlightControllerSample(sample, xboxProfile(), limits, mapped));
    RDP_ASSERT_EQ(mapped.buttonFlags, kMoonlightControllerButtonA);
}

RDP_TEST_CASE(moonlight_controller_full_snapshot_is_atomic_and_noise_is_local_only) {
    ControllerFixture fixture;
    RDP_ASSERT_EQ(fixture.mapper->connect(
        controllerContext(fixture.identity, 1U, 100U), xboxProfile()).status,
        MoonlightControllerStatus::Applied);
    MoonlightControllerSample sample;
    sample.buttonFlags = kMoonlightControllerButtonA |
        kMoonlightControllerButtonLeftShoulder;
    sample.leftStickX = 0.5;
    sample.rightTrigger = 1.0;
    RDP_ASSERT_EQ(fixture.mapper->update(
        controllerContext(fixture.identity, 2U, 110U), sample).status,
        MoonlightControllerStatus::Applied);

    MoonlightControllerWireCommand command;
    RDP_ASSERT(decodeMoonlightControllerCommand(fixture.port->eventAt(1U), command));
    RDP_ASSERT_EQ(command.operation, MoonlightControllerCommandOperation::State);
    RDP_ASSERT_EQ(command.activeGamepadMask, static_cast<std::uint16_t>(1));
    RDP_ASSERT_EQ(command.state.buttonFlags, sample.buttonFlags);
    RDP_ASSERT_EQ(command.state.leftStickX, static_cast<std::int16_t>(16383));
    RDP_ASSERT_EQ(command.state.rightTrigger, static_cast<std::uint8_t>(255));

    sample.leftStickX = 0.50001;
    RDP_ASSERT_EQ(fixture.mapper->update(
        controllerContext(fixture.identity, 3U, 120U), sample).status,
        MoonlightControllerStatus::AppliedLocally);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(2));
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).localOnlyUpdates,
                  static_cast<std::uint64_t>(1));
}

RDP_TEST_CASE(moonlight_controller_background_neutral_keeps_slot_then_resumes) {
    ControllerFixture fixture;
    RDP_ASSERT_EQ(fixture.mapper->connect(
        controllerContext(fixture.identity, 1U, 100U), xboxProfile()).status,
        MoonlightControllerStatus::Applied);
    MoonlightControllerSample sample;
    sample.buttonFlags = kMoonlightControllerButtonB;
    sample.leftTrigger = 1.0;
    RDP_ASSERT_EQ(fixture.mapper->update(
        controllerContext(fixture.identity, 2U, 110U), sample).status,
        MoonlightControllerStatus::Applied);
    RDP_ASSERT_EQ(fixture.mapper->neutralize(
        controllerContext(fixture.identity, 3U, 120U)).status,
        MoonlightControllerStatus::Applied);

    MoonlightControllerWireCommand neutral;
    RDP_ASSERT(decodeMoonlightControllerCommand(fixture.port->eventAt(2U), neutral));
    RDP_ASSERT_EQ(neutral.activeGamepadMask, static_cast<std::uint16_t>(1));
    RDP_ASSERT_EQ(neutral.state.buttonFlags, static_cast<std::uint32_t>(0));
    RDP_ASSERT(fixture.mapper->snapshot(fixture.identity).active);

    RDP_ASSERT_EQ(fixture.mapper->update(
        controllerContext(fixture.identity, 4U, 130U), sample).status,
        MoonlightControllerStatus::Applied);
}

RDP_TEST_CASE(moonlight_controller_bluetooth_disconnect_retries_without_early_release) {
    ControllerFixture fixture;
    RDP_ASSERT_EQ(fixture.mapper->connect(
        controllerContext(fixture.identity, 1U, 100U), xboxProfile()).status,
        MoonlightControllerStatus::Applied);
    fixture.port->setScript({MoonlightInputPortStatus::Backpressure,
                             MoonlightInputPortStatus::Accepted});
    const auto context = controllerContext(fixture.identity, 2U, 110U);
    RDP_ASSERT_EQ(fixture.mapper->disconnect(context).status,
                  MoonlightControllerStatus::Backpressure);
    RDP_ASSERT(fixture.mapper->snapshot(fixture.identity).active);
    RDP_ASSERT_EQ(fixture.mapper->disconnect(context).status,
                  MoonlightControllerStatus::Applied);
    const auto snapshot = fixture.mapper->snapshot(fixture.identity);
    RDP_ASSERT(!snapshot.active);
    RDP_ASSERT_EQ(snapshot.removals, static_cast<std::uint64_t>(1));

    MoonlightControllerWireCommand first;
    MoonlightControllerWireCommand retry;
    RDP_ASSERT(decodeMoonlightControllerCommand(fixture.port->eventAt(1U), first));
    RDP_ASSERT(decodeMoonlightControllerCommand(fixture.port->eventAt(2U), retry));
    RDP_ASSERT_EQ(first.activeGamepadMask, static_cast<std::uint16_t>(0));
    RDP_ASSERT_EQ(retry.activeGamepadMask, static_cast<std::uint16_t>(0));
}

RDP_TEST_CASE(moonlight_controller_duplicate_stale_and_generation_change_fail_closed) {
    ControllerFixture fixture;
    RDP_ASSERT_EQ(fixture.mapper->connect(
        controllerContext(fixture.identity, 2U, 200U), xboxProfile()).status,
        MoonlightControllerStatus::Applied);
    MoonlightControllerSample sample;
    sample.buttonFlags = kMoonlightControllerButtonX;
    RDP_ASSERT_EQ(fixture.mapper->update(
        controllerContext(fixture.identity, 3U, 210U), sample).status,
        MoonlightControllerStatus::Applied);
    RDP_ASSERT_EQ(fixture.mapper->update(
        controllerContext(fixture.identity, 3U, 210U), sample).status,
        MoonlightControllerStatus::Duplicate);
    RDP_ASSERT_EQ(fixture.mapper->update(
        controllerContext(fixture.identity, 1U, 220U), sample).status,
        MoonlightControllerStatus::StaleEvent);
    RDP_ASSERT_EQ(fixture.mapper->update(
        controllerContext(fixture.identity, 4U, 230U, 71U, 2U), sample).status,
        MoonlightControllerStatus::FlushRequired);
    RDP_ASSERT_EQ(fixture.port->eventCount(), static_cast<std::size_t>(2));
}

RDP_TEST_CASE(moonlight_controller_non_controller_source_owner_and_device_are_rejected) {
    ControllerFixture fixture;
    auto context = controllerContext(fixture.identity, 1U, 100U);
    context.source = MoonlightInputSource::Touchscreen;
    RDP_ASSERT_EQ(fixture.mapper->connect(context, xboxProfile()).status,
                  MoonlightControllerStatus::InvalidRequest);
    context = controllerContext(controllerIdentity(999U), 1U, 100U);
    RDP_ASSERT_EQ(fixture.mapper->connect(context, xboxProfile()).status,
                  MoonlightControllerStatus::StaleOwner);

    RDP_ASSERT_EQ(fixture.mapper->connect(
        controllerContext(fixture.identity, 1U, 100U), xboxProfile()).status,
        MoonlightControllerStatus::Applied);
    MoonlightControllerSample sample;
    RDP_ASSERT_EQ(fixture.mapper->update(
        controllerContext(fixture.identity, 1U, 110U, 72U), sample).status,
        MoonlightControllerStatus::NotActive);
}

RDP_TEST_CASE(moonlight_controller_owner_rejection_does_not_commit_candidate) {
    ControllerFixture fixture;
    fixture.gate->setAvailable(false);
    RDP_ASSERT_EQ(fixture.mapper->connect(
        controllerContext(fixture.identity, 1U, 100U), xboxProfile()).status,
        MoonlightControllerStatus::StaleOwner);
    RDP_ASSERT(!fixture.mapper->snapshot(fixture.identity).active);
    fixture.gate->setAvailable(true);
    RDP_ASSERT_EQ(fixture.mapper->connect(
        controllerContext(fixture.identity, 1U, 100U), xboxProfile()).status,
        MoonlightControllerStatus::Applied);
}

RDP_TEST_CASE(moonlight_controller_profile_and_sample_capabilities_are_strict) {
    ControllerFixture fixture;
    auto profile = xboxProfile();
    profile.supportedButtonFlags |= 0x0800U;
    RDP_ASSERT_EQ(fixture.mapper->connect(
        controllerContext(fixture.identity, 1U, 100U), profile).status,
        MoonlightControllerStatus::InvalidRequest);

    profile = xboxProfile();
    RDP_ASSERT_EQ(fixture.mapper->connect(
        controllerContext(fixture.identity, 1U, 100U), profile).status,
        MoonlightControllerStatus::Applied);
    MoonlightControllerSample sample;
    sample.buttonFlags = kMoonlightControllerButtonSpecial;
    RDP_ASSERT_EQ(fixture.mapper->update(
        controllerContext(fixture.identity, 2U, 110U), sample).status,
        MoonlightControllerStatus::Applied);
    sample = {};
    sample.buttonFlags = kMoonlightControllerButtonBack;
    RDP_ASSERT_EQ(fixture.mapper->update(
        controllerContext(fixture.identity, 3U, 120U), sample).status,
        MoonlightControllerStatus::InvalidRequest);
    sample = {};
    sample.leftStickX = std::numeric_limits<double>::infinity();
    RDP_ASSERT_EQ(fixture.mapper->update(
        controllerContext(fixture.identity, 3U, 120U), sample).status,
        MoonlightControllerStatus::InvalidRequest);
    sample = {};
    sample.hasHatAxes = false;
    sample.hatX = std::numeric_limits<double>::quiet_NaN();
    RDP_ASSERT_EQ(fixture.mapper->update(
        controllerContext(fixture.identity, 3U, 120U), sample).status,
        MoonlightControllerStatus::InvalidRequest);
}

RDP_TEST_CASE(moonlight_controller_decoder_rejects_reserved_and_non_neutral_removal) {
    ControllerFixture fixture;
    RDP_ASSERT_EQ(fixture.mapper->connect(
        controllerContext(fixture.identity, 1U, 100U), xboxProfile()).status,
        MoonlightControllerStatus::Applied);
    MoonlightInputEvent event = fixture.port->eventAt(0U);
    MoonlightControllerWireCommand command;
    event.payload[19] = 1U;
    RDP_ASSERT(!decodeMoonlightControllerCommand(event, command));
    event = fixture.port->eventAt(0U);
    event.payload[0] = static_cast<std::uint8_t>(
        MoonlightControllerCommandOperation::State);
    event.payload[2] = 0U;
    event.payload[3] = 0U;
    event.payload[4] = 1U;
    event.payload[18] = 0U;
    event.payload[20] = 0U;
    event.payload[21] = 0U;
    event.payload[22] = 0U;
    event.payload[23] = 0U;
    event.payload[24] = 0U;
    event.payload[25] = 0U;
    RDP_ASSERT(!decodeMoonlightControllerCommand(event, command));
}

RDP_TEST_CASE(moonlight_controller_disconnect_is_neutral_even_after_non_neutral_state) {
    ControllerFixture fixture;
    RDP_ASSERT_EQ(fixture.mapper->connect(
        controllerContext(fixture.identity, 1U, 100U), xboxProfile()).status,
        MoonlightControllerStatus::Applied);
    MoonlightControllerSample sample;
    sample.buttonFlags = kMoonlightControllerButtonY |
        kMoonlightControllerButtonRight;
    sample.leftStickX = -1.0;
    sample.rightTrigger = 1.0;
    RDP_ASSERT_EQ(fixture.mapper->update(
        controllerContext(fixture.identity, 2U, 110U), sample).status,
        MoonlightControllerStatus::Applied);
    RDP_ASSERT_EQ(fixture.mapper->disconnect(
        controllerContext(fixture.identity, 3U, 120U)).status,
        MoonlightControllerStatus::Applied);

    MoonlightControllerWireCommand removal;
    RDP_ASSERT(decodeMoonlightControllerCommand(fixture.port->eventAt(2U), removal));
    RDP_ASSERT_EQ(removal.activeGamepadMask, static_cast<std::uint16_t>(0));
    RDP_ASSERT_EQ(removal.state.buttonFlags, static_cast<std::uint32_t>(0));
    RDP_ASSERT_EQ(removal.state.leftStickX, static_cast<std::int16_t>(0));
    RDP_ASSERT_EQ(removal.state.rightTrigger, static_cast<std::uint8_t>(0));
}

} // namespace
