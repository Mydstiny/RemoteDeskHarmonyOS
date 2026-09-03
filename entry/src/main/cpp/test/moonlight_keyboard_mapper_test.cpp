#include "moonlight/input/MoonlightKeyboardMapper.h"
#include "test/test_runner.h"

#include <array>
#include <condition_variable>
#include <cstdint>
#include <limits>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace {

using namespace remotedesk::moonlight;

MoonlightInputIdentity keyboardIdentity(std::uint64_t ownerToken = 71U,
                                        std::uint64_t inputGeneration = 3U) {
    return {{1001U, 23U, ownerToken}, inputGeneration};
}

MoonlightKeyboardEventContext keyboardContext(
    const MoonlightInputIdentity& identity,
    std::uint64_t sequence,
    std::uint64_t timestampUs,
    MoonlightInputSource source = MoonlightInputSource::PhysicalKeyboard,
    std::uint64_t deviceId = 41U,
    std::uint64_t sourceGeneration = 1U) {
    return {identity, deviceId, source, sourceGeneration, sequence, timestampUs};
}

class KeyboardOwnerGate final : public MoonlightInputOwnerGate {
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

class KeyboardPort final : public MoonlightInputPort {
  public:
    MoonlightInputPortStatus send(const MoonlightInputEvent& event) noexcept override {
        std::unique_lock<std::mutex> lock(mutex_);
        entered_ = true;
        cv_.notify_all();
        cv_.wait(lock, [&]() { return !blocked_; });
        events.push_back(event);
        if (scriptIndex < scripted.size()) {
            return scripted[scriptIndex++];
        }
        return status;
    }

    bool flushNeutral(const MoonlightInputFlushRequest&) noexcept override {
        return true;
    }

    void block() {
        std::lock_guard<std::mutex> lock(mutex_);
        blocked_ = true;
        entered_ = false;
    }

    void waitUntilEntered() {
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait(lock, [&]() { return entered_; });
    }

    void release() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            blocked_ = false;
        }
        cv_.notify_all();
    }

    MoonlightInputPortStatus status = MoonlightInputPortStatus::Accepted;
    std::vector<MoonlightInputPortStatus> scripted;
    std::size_t scriptIndex = 0U;
    std::vector<MoonlightInputEvent> events;

  private:
    std::mutex mutex_;
    std::condition_variable cv_;
    bool blocked_ = false;
    bool entered_ = false;
};

struct KeyboardFixture final {
    explicit KeyboardFixture(MoonlightKeyboardLimits limits = {}) {
        gate->accept(identity);
        bridge = MoonlightInputBridge::create(gate, port);
        RDP_ASSERT(bridge != nullptr);
        RDP_ASSERT_EQ(bridge->activate(identity, 1U).status,
                      MoonlightInputControlStatus::Applied);
        mapper = MoonlightKeyboardMapper::create(bridge, identity, limits);
        RDP_ASSERT(mapper != nullptr);
    }

    MoonlightKeyboardWireCommand commandAt(std::size_t index) const {
        MoonlightKeyboardWireCommand command;
        RDP_ASSERT(index < port->events.size());
        RDP_ASSERT(decodeMoonlightKeyboardCommand(port->events[index], command));
        return command;
    }

    MoonlightInputIdentity identity = keyboardIdentity();
    std::shared_ptr<KeyboardOwnerGate> gate = std::make_shared<KeyboardOwnerGate>();
    std::shared_ptr<KeyboardPort> port = std::make_shared<KeyboardPort>();
    std::shared_ptr<MoonlightInputBridge> bridge;
    std::shared_ptr<MoonlightKeyboardMapper> mapper;
};

RDP_TEST_CASE(moonlight_keyboard_maps_harmony_namespace_to_official_prefixed_vk) {
    const auto a = mapHarmonyKeyCodeToMoonlight(2017U);
    RDP_ASSERT(a.supported);
    RDP_ASSERT_EQ(a.protocolKeyCode, static_cast<std::uint16_t>(0x8041U));
    RDP_ASSERT(!a.modifier);
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToMoonlight(2000U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x8030U));
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToMoonlight(2012U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x8026U));
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToMoonlight(2043U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x80BCU));
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToMoonlight(2080U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x8013U));
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToMoonlight(2103U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x8060U));
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToMoonlight(2827U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x8087U));
    const auto rightControl = mapHarmonyKeyCodeToMoonlight(2073U);
    RDP_ASSERT(rightControl.supported && rightControl.modifier && rightControl.rightSide);
    RDP_ASSERT_EQ(rightControl.modifierKind, MoonlightKeyboardModifier::Control);
    RDP_ASSERT_EQ(rightControl.protocolKeyCode, static_cast<std::uint16_t>(0x80A3U));
    RDP_ASSERT(mapHarmonyKeyCodeToMoonlight(1U).supported == false);
    RDP_ASSERT(mapHarmonyKeyCodeToMoonlight(0xFFFFFFFFU).supported == false);
}

RDP_TEST_CASE(moonlight_keyboard_maps_harmony_consumer_keys_to_windows_vk) {
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToMoonlight(10U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x80B3U));
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToMoonlight(12U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x80B0U));
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToMoonlight(13U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x80B1U));
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToMoonlight(16U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x80AFU));
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToMoonlight(17U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x80AEU));
}

RDP_TEST_CASE(moonlight_keyboard_catalog_covers_the_complete_standard_physical_keyboard) {
    for (std::uint32_t keyCode = 48U; keyCode <= 57U; ++keyCode) {
        RDP_ASSERT(mapHarmonyKeyCodeToMoonlight(keyCode).supported);
    }
    for (std::uint32_t keyCode = 65U; keyCode <= 90U; ++keyCode) {
        RDP_ASSERT(mapHarmonyKeyCodeToMoonlight(keyCode).supported);
    }
    for (std::uint32_t keyCode = 2000U; keyCode <= 2009U; ++keyCode) {
        RDP_ASSERT(mapHarmonyKeyCodeToMoonlight(keyCode).supported);
    }
    for (std::uint32_t keyCode = 2017U; keyCode <= 2042U; ++keyCode) {
        RDP_ASSERT(mapHarmonyKeyCodeToMoonlight(keyCode).supported);
    }
    for (std::uint32_t keyCode = 2090U; keyCode <= 2101U; ++keyCode) {
        RDP_ASSERT(mapHarmonyKeyCodeToMoonlight(keyCode).supported);
    }
    for (std::uint32_t keyCode = 2816U; keyCode <= 2827U; ++keyCode) {
        RDP_ASSERT(mapHarmonyKeyCodeToMoonlight(keyCode).supported);
    }
    for (std::uint32_t keyCode = 2103U; keyCode <= 2117U; ++keyCode) {
        RDP_ASSERT(mapHarmonyKeyCodeToMoonlight(keyCode).supported);
    }
    constexpr std::array<std::uint32_t, 50U> fixedKeys{{
        2012U, 2013U, 2014U, 2015U,
        2043U, 2044U, 2045U, 2046U, 2047U, 2048U, 2049U, 2050U,
        2054U, 2055U, 2056U, 2057U, 2058U, 2059U, 2060U, 2061U,
        2062U, 2063U, 2064U, 2065U, 2066U, 2067U, 2068U, 2069U,
        2070U, 2071U, 2072U, 2073U, 2074U, 2075U, 2076U, 2077U,
        2079U, 2080U, 2081U, 2082U, 2083U, 2102U, 2119U, 2120U,
        186U, 187U, 188U, 189U, 190U, 191U,
    }};
    for (const auto keyCode : fixedKeys) {
        RDP_ASSERT(mapHarmonyKeyCodeToMoonlight(keyCode).supported);
    }
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToMoonlight(2076U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x805BU));
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToMoonlight(2077U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x805CU));
    RDP_ASSERT_EQ(mapHarmonyKeyCodeToMoonlight(2079U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x802CU));
}

RDP_TEST_CASE(moonlight_keyboard_rejects_invalid_limits_context_and_source) {
    auto gate = std::make_shared<KeyboardOwnerGate>();
    auto port = std::make_shared<KeyboardPort>();
    const auto identity = keyboardIdentity();
    gate->accept(identity);
    auto bridge = MoonlightInputBridge::create(gate, port);
    RDP_ASSERT(bridge != nullptr);
    RDP_ASSERT_EQ(bridge->activate(identity, 1U).status,
                  MoonlightInputControlStatus::Applied);
    MoonlightKeyboardLimits limits;
    limits.maximumPressedNonModifierKeys = 0U;
    RDP_ASSERT(MoonlightKeyboardMapper::create(bridge, identity, limits) == nullptr);
    limits.maximumPressedNonModifierKeys = kMoonlightMaximumPressedNonModifierKeys + 1U;
    RDP_ASSERT(MoonlightKeyboardMapper::create(bridge, identity, limits) == nullptr);
    limits = {};
    limits.maximumTextBytes = 0U;
    RDP_ASSERT(MoonlightKeyboardMapper::create(bridge, identity, limits) == nullptr);
    RDP_ASSERT(MoonlightKeyboardMapper::create(nullptr, identity) == nullptr);
    RDP_ASSERT(MoonlightKeyboardMapper::create(bridge, {}) == nullptr);

    KeyboardFixture fixture;
    auto invalid = keyboardContext(fixture.identity, 1U, 100U);
    invalid.deviceId = 0U;
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(invalid, 2017U, true, false).status,
                  MoonlightKeyboardStatus::InvalidRequest);
    invalid = keyboardContext(fixture.identity,
                              std::numeric_limits<std::uint64_t>::max(), 100U);
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(invalid, 2017U, true, false).status,
                  MoonlightKeyboardStatus::InvalidRequest);
    auto wrongSource = keyboardContext(fixture.identity, 1U, 100U,
                                       MoonlightInputSource::OnScreenKeyboard);
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(wrongSource, 2017U, true, false).status,
                  MoonlightKeyboardStatus::InvalidRequest);
    auto physical = keyboardContext(fixture.identity, 1U, 100U);
    RDP_ASSERT_EQ(fixture.mapper->virtualKeyTap(physical, 2017U).status,
                  MoonlightKeyboardStatus::InvalidRequest);
    ++physical.identity.inputGeneration;
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(physical, 2017U, true, false).status,
                  MoonlightKeyboardStatus::StaleOwner);
    RDP_ASSERT_EQ(fixture.port->events.size(), static_cast<std::size_t>(0U));
}

RDP_TEST_CASE(moonlight_keyboard_physical_key_is_exact_and_transactional) {
    KeyboardFixture fixture;
    auto down = keyboardContext(fixture.identity, 1U, 100U);
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(down, 2017U, true, false).status,
                  MoonlightKeyboardStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->events.size(), static_cast<std::size_t>(1U));
    const auto first = fixture.commandAt(0U);
    RDP_ASSERT_EQ(first.protocolKeyCode, static_cast<std::uint16_t>(0x8041U));
    RDP_ASSERT_EQ(first.action, kMoonlightKeyboardActionDown);
    RDP_ASSERT_EQ(first.modifiers, static_cast<std::uint8_t>(0U));
    RDP_ASSERT_EQ(first.flags, kMoonlightKeyboardFlagNonNormalized);
    RDP_ASSERT_EQ(fixture.port->events[0].sourceSequence, static_cast<std::uint64_t>(1U));
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).pressedNonModifierKeys,
                  static_cast<std::size_t>(1U));

    RDP_ASSERT_EQ(fixture.mapper->physicalKey(
                      keyboardContext(fixture.identity, 2U, 101U), 2017U, true, false).status,
                  MoonlightKeyboardStatus::Duplicate);
    RDP_ASSERT_EQ(fixture.port->events.size(), static_cast<std::size_t>(1U));

    auto wrongDeviceUp = keyboardContext(fixture.identity, 3U, 102U);
    wrongDeviceUp.deviceId = 42U;
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(
                      wrongDeviceUp, 2017U, false, false).status,
                  MoonlightKeyboardStatus::NotPressed);
    RDP_ASSERT_EQ(fixture.port->events.size(), static_cast<std::size_t>(1U));

    auto up = keyboardContext(fixture.identity, 3U, 102U);
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(up, 2017U, false, true).status,
                  MoonlightKeyboardStatus::Applied);
    const auto second = fixture.commandAt(1U);
    RDP_ASSERT_EQ(second.action, kMoonlightKeyboardActionUp);
    RDP_ASSERT_EQ(second.flags, kMoonlightKeyboardFlagNonNormalized);
    RDP_ASSERT_EQ(fixture.port->events[1].sourceSequence, static_cast<std::uint64_t>(65U));
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).pressedNonModifierKeys,
                  static_cast<std::size_t>(0U));
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(
                      keyboardContext(fixture.identity, 4U, 103U), 2017U, false, false).status,
                  MoonlightKeyboardStatus::NotPressed);
}

RDP_TEST_CASE(moonlight_keyboard_tracks_left_right_modifiers_like_official_client) {
    KeyboardFixture fixture;
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(
                      keyboardContext(fixture.identity, 1U, 100U), 2072U, true, true).status,
                  MoonlightKeyboardStatus::Applied);
    RDP_ASSERT_EQ(fixture.commandAt(0U).modifiers, static_cast<std::uint8_t>(0x02U));
    RDP_ASSERT_EQ(fixture.commandAt(0U).flags, static_cast<std::uint8_t>(0U));
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(
                      keyboardContext(fixture.identity, 2U, 101U), 2048U, true, false).status,
                  MoonlightKeyboardStatus::Applied);
    RDP_ASSERT_EQ(fixture.commandAt(1U).modifiers, static_cast<std::uint8_t>(0x03U));
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(
                      keyboardContext(fixture.identity, 3U, 102U), 2017U, true, false).status,
                  MoonlightKeyboardStatus::Applied);
    RDP_ASSERT_EQ(fixture.commandAt(2U).modifiers, static_cast<std::uint8_t>(0x03U));
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(
                      keyboardContext(fixture.identity, 4U, 103U), 2017U, false, false).status,
                  MoonlightKeyboardStatus::Applied);
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(
                      keyboardContext(fixture.identity, 5U, 104U), 2072U, false, true).status,
                  MoonlightKeyboardStatus::Applied);
    RDP_ASSERT_EQ(fixture.commandAt(4U).modifiers, static_cast<std::uint8_t>(0x01U));
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(
                      keyboardContext(fixture.identity, 6U, 105U), 2048U, false, false).status,
                  MoonlightKeyboardStatus::Applied);
    RDP_ASSERT_EQ(fixture.commandAt(5U).modifiers, static_cast<std::uint8_t>(0U));
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).remoteModifierMask,
                  static_cast<std::uint8_t>(0U));
}

RDP_TEST_CASE(moonlight_keyboard_forwards_windows_system_key_chords_in_order) {
    KeyboardFixture fixture;
    std::uint64_t sequence = 1U;
    std::uint64_t timestampUs = 100U;
    const auto send = [&](std::uint32_t keyCode, bool pressed) {
        const auto result = fixture.mapper->physicalKey(
            keyboardContext(fixture.identity, sequence++, timestampUs++),
            keyCode, pressed, true);
        RDP_ASSERT_EQ(result.status, MoonlightKeyboardStatus::Applied);
    };

    send(2076U, true);  // Win down
    send(2034U, true);  // R down
    send(2034U, false); // R up
    send(2076U, false); // Win up
    send(2045U, true);  // Alt down
    send(2049U, true);  // Tab down
    send(2049U, false); // Tab up
    send(2045U, false); // Alt up
    send(2072U, true);  // Ctrl down
    send(2070U, true);  // Escape down
    send(2070U, false); // Escape up
    send(2072U, false); // Ctrl up

    RDP_ASSERT_EQ(fixture.port->events.size(), static_cast<std::size_t>(12U));
    RDP_ASSERT_EQ(fixture.commandAt(0U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x805BU));
    RDP_ASSERT_EQ(fixture.commandAt(1U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x8052U));
    RDP_ASSERT_EQ(fixture.commandAt(1U).modifiers, static_cast<std::uint8_t>(0x08U));
    RDP_ASSERT_EQ(fixture.commandAt(5U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x8009U));
    RDP_ASSERT_EQ(fixture.commandAt(5U).modifiers, static_cast<std::uint8_t>(0x04U));
    RDP_ASSERT_EQ(fixture.commandAt(9U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x801BU));
    RDP_ASSERT_EQ(fixture.commandAt(9U).modifiers, static_cast<std::uint8_t>(0x02U));
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).remoteModifierMask,
                  static_cast<std::uint8_t>(0U));
}

RDP_TEST_CASE(moonlight_keyboard_once_latch_is_one_atomic_ordered_transaction) {
    KeyboardFixture fixture;
    auto onscreen = keyboardContext(fixture.identity, 1U, 200U,
                                    MoonlightInputSource::OnScreenKeyboard, 51U);
    RDP_ASSERT_EQ(fixture.mapper->setModifierLatch(
                      onscreen, MoonlightKeyboardModifier::Shift,
                      MoonlightKeyboardLatch::Once).status,
                  MoonlightKeyboardStatus::AppliedLocally);
    RDP_ASSERT_EQ(fixture.port->events.size(), static_cast<std::size_t>(0U));
    RDP_ASSERT_EQ(fixture.mapper->virtualKeyTap(onscreen, 2019U).status,
                  MoonlightKeyboardStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->events.size(), static_cast<std::size_t>(4U));
    RDP_ASSERT_EQ(fixture.commandAt(0U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x80A0U));
    RDP_ASSERT_EQ(fixture.commandAt(0U).action, kMoonlightKeyboardActionDown);
    RDP_ASSERT_EQ(fixture.commandAt(0U).modifiers, static_cast<std::uint8_t>(0x01U));
    RDP_ASSERT_EQ(fixture.commandAt(1U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x8043U));
    RDP_ASSERT_EQ(fixture.commandAt(1U).action, kMoonlightKeyboardActionDown);
    RDP_ASSERT_EQ(fixture.commandAt(2U).action, kMoonlightKeyboardActionUp);
    RDP_ASSERT_EQ(fixture.commandAt(3U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x80A0U));
    RDP_ASSERT_EQ(fixture.commandAt(3U).action, kMoonlightKeyboardActionUp);
    RDP_ASSERT_EQ(fixture.commandAt(3U).modifiers, static_cast<std::uint8_t>(0U));
    for (std::size_t index = 0U; index < 4U; ++index) {
        RDP_ASSERT_EQ(fixture.port->events[index].sourceSequence,
                      static_cast<std::uint64_t>(index + 1U));
    }
    const auto snapshot = fixture.mapper->snapshot(fixture.identity);
    RDP_ASSERT_EQ(snapshot.latches[0], MoonlightKeyboardLatch::Off);
    RDP_ASSERT_EQ(snapshot.remoteModifierMask, static_cast<std::uint8_t>(0U));
}

RDP_TEST_CASE(moonlight_keyboard_locked_modifier_coexists_with_physical_key) {
    KeyboardFixture fixture;
    auto onscreen = keyboardContext(fixture.identity, 1U, 200U,
                                    MoonlightInputSource::OnScreenKeyboard, 51U);
    RDP_ASSERT_EQ(fixture.mapper->setModifierLatch(
                      onscreen, MoonlightKeyboardModifier::Control,
                      MoonlightKeyboardLatch::Locked).status,
                  MoonlightKeyboardStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->events.size(), static_cast<std::size_t>(1U));
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(
                      keyboardContext(fixture.identity, 1U, 201U), 2072U, true, false).status,
                  MoonlightKeyboardStatus::AppliedLocally);
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(
                      keyboardContext(fixture.identity, 2U, 202U), 2072U, false, false).status,
                  MoonlightKeyboardStatus::AppliedLocally);
    RDP_ASSERT_EQ(fixture.port->events.size(), static_cast<std::size_t>(1U));
    onscreen.sourceSequence = 2U;
    onscreen.monotonicTimestampUs = 203U;
    RDP_ASSERT_EQ(fixture.mapper->setModifierLatch(
                      onscreen, MoonlightKeyboardModifier::Control,
                      MoonlightKeyboardLatch::Off).status,
                  MoonlightKeyboardStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->events.size(), static_cast<std::size_t>(2U));
    RDP_ASSERT_EQ(fixture.commandAt(1U).action, kMoonlightKeyboardActionUp);
    RDP_ASSERT_EQ(fixture.commandAt(1U).modifiers, static_cast<std::uint8_t>(0U));
}

RDP_TEST_CASE(moonlight_keyboard_backpressure_retries_exact_event_without_state_drift) {
    KeyboardFixture fixture;
    fixture.port->status = MoonlightInputPortStatus::Backpressure;
    const auto context = keyboardContext(fixture.identity, 1U, 100U);
    const auto blocked = fixture.mapper->physicalKey(context, 2039U, true, false);
    RDP_ASSERT_EQ(blocked.status, MoonlightKeyboardStatus::Backpressure);
    RDP_ASSERT_EQ(blocked.pendingCommands, static_cast<std::size_t>(1U));
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).pressedNonModifierKeys,
                  static_cast<std::size_t>(0U));
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(
                      keyboardContext(fixture.identity, 2U, 101U), 2017U, true, false).status,
                  MoonlightKeyboardStatus::Pending);
    fixture.port->status = MoonlightInputPortStatus::Accepted;
    const auto resumed = fixture.mapper->resumePending();
    RDP_ASSERT_EQ(resumed.status, MoonlightKeyboardStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->events.size(), static_cast<std::size_t>(2U));
    RDP_ASSERT_EQ(fixture.port->events[0].sourceSequence,
                  fixture.port->events[1].sourceSequence);
    RDP_ASSERT(fixture.port->events[0].payload == fixture.port->events[1].payload);
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).pressedNonModifierKeys,
                  static_cast<std::size_t>(1U));
}

RDP_TEST_CASE(moonlight_keyboard_partial_transaction_resumes_only_unaccepted_suffix) {
    KeyboardFixture fixture;
    auto onscreen = keyboardContext(fixture.identity, 1U, 200U,
                                    MoonlightInputSource::OnScreenKeyboard, 51U);
    RDP_ASSERT_EQ(fixture.mapper->setModifierLatch(
                      onscreen, MoonlightKeyboardModifier::Alt,
                      MoonlightKeyboardLatch::Once).status,
                  MoonlightKeyboardStatus::AppliedLocally);
    fixture.port->scripted = {
        MoonlightInputPortStatus::Accepted,
        MoonlightInputPortStatus::Backpressure,
        MoonlightInputPortStatus::Accepted,
        MoonlightInputPortStatus::Accepted,
        MoonlightInputPortStatus::Accepted,
    };
    const auto partial = fixture.mapper->virtualKeyTap(onscreen, 2042U);
    RDP_ASSERT_EQ(partial.status, MoonlightKeyboardStatus::Backpressure);
    RDP_ASSERT_EQ(partial.acceptedCommands, static_cast<std::size_t>(1U));
    RDP_ASSERT_EQ(partial.pendingCommands, static_cast<std::size_t>(3U));
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).remoteModifierMask,
                  static_cast<std::uint8_t>(0x04U));
    const auto completed = fixture.mapper->resumePending();
    RDP_ASSERT_EQ(completed.status, MoonlightKeyboardStatus::Applied);
    RDP_ASSERT_EQ(completed.acceptedCommands, static_cast<std::size_t>(4U));
    RDP_ASSERT_EQ(fixture.port->events.size(), static_cast<std::size_t>(5U));
    RDP_ASSERT_EQ(fixture.port->events[1].sourceSequence,
                  fixture.port->events[2].sourceSequence);
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).remoteModifierMask,
                  static_cast<std::uint8_t>(0U));
}

RDP_TEST_CASE(moonlight_keyboard_text_is_strict_utf8_and_never_synthesizes_keys) {
    KeyboardFixture fixture;
    const std::uint8_t valid[] = {0xE4U, 0xB8U, 0xADU, 0xF0U, 0x9FU, 0x99U, 0x82U};
    auto onscreen = keyboardContext(fixture.identity, 1U, 200U,
                                    MoonlightInputSource::OnScreenKeyboard, 51U);
    RDP_ASSERT(validateMoonlightUtf8Text(valid, sizeof(valid)));
    RDP_ASSERT_EQ(fixture.mapper->commitText(onscreen, valid, sizeof(valid)).status,
                  MoonlightKeyboardStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->events.size(), static_cast<std::size_t>(1U));
    RDP_ASSERT_EQ(fixture.port->events[0].kind, MoonlightInputCommandKind::Text);
    RDP_ASSERT_EQ(fixture.port->events[0].payloadSize, sizeof(valid));
    for (std::size_t index = 0U; index < sizeof(valid); ++index) {
        RDP_ASSERT_EQ(fixture.port->events[0].payload[index], valid[index]);
    }
    const std::uint8_t overlong[] = {0xC0U, 0xAFU};
    const std::uint8_t surrogate[] = {0xEDU, 0xA0U, 0x80U};
    const std::uint8_t truncated[] = {0xF0U, 0x9FU, 0x99U};
    const std::uint8_t nul[] = {0x00U};
    RDP_ASSERT(!validateMoonlightUtf8Text(overlong, sizeof(overlong)));
    RDP_ASSERT(!validateMoonlightUtf8Text(surrogate, sizeof(surrogate)));
    RDP_ASSERT(!validateMoonlightUtf8Text(truncated, sizeof(truncated)));
    RDP_ASSERT(!validateMoonlightUtf8Text(nul, sizeof(nul)));
    auto physical = keyboardContext(fixture.identity, 2U, 201U);
    RDP_ASSERT_EQ(fixture.mapper->commitText(physical, valid, sizeof(valid)).status,
                  MoonlightKeyboardStatus::InvalidRequest);
}

RDP_TEST_CASE(moonlight_keyboard_forwards_physical_escape_to_the_remote_host) {
    KeyboardFixture fixture;
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(
                      keyboardContext(fixture.identity, 1U, 100U), 2070U, true, false).status,
                  MoonlightKeyboardStatus::Applied);
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(
                      keyboardContext(fixture.identity, 2U, 101U), 2070U, false, false).status,
                  MoonlightKeyboardStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->events.size(), static_cast<std::size_t>(2U));
    RDP_ASSERT_EQ(fixture.commandAt(0U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x801BU));
    RDP_ASSERT_EQ(fixture.commandAt(0U).action, kMoonlightKeyboardActionDown);
    RDP_ASSERT_EQ(fixture.commandAt(1U).action, kMoonlightKeyboardActionUp);
    auto onscreen = keyboardContext(fixture.identity, 1U, 102U,
                                    MoonlightInputSource::OnScreenKeyboard, 51U);
    RDP_ASSERT_EQ(fixture.mapper->virtualKeyTap(onscreen, 2070U).status,
                  MoonlightKeyboardStatus::Applied);
    RDP_ASSERT_EQ(fixture.port->events.size(), static_cast<std::size_t>(4U));
    RDP_ASSERT_EQ(fixture.commandAt(2U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x801BU));
    RDP_ASSERT_EQ(fixture.commandAt(2U).action, kMoonlightKeyboardActionDown);
    RDP_ASSERT_EQ(fixture.commandAt(3U).action, kMoonlightKeyboardActionUp);
    RDP_ASSERT_EQ(fixture.mapper->snapshot(fixture.identity).localEscapeEvents,
                  static_cast<std::uint64_t>(0U));
}

RDP_TEST_CASE(moonlight_keyboard_release_all_is_reverse_ordered_and_retryable) {
    KeyboardFixture fixture;
    auto physical = keyboardContext(fixture.identity, 1U, 100U);
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(physical, 2039U, true, false).status,
                  MoonlightKeyboardStatus::Applied); // W
    physical.sourceSequence = 2U;
    physical.monotonicTimestampUs = 101U;
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(physical, 2017U, true, false).status,
                  MoonlightKeyboardStatus::Applied); // A
    physical.sourceSequence = 3U;
    physical.monotonicTimestampUs = 102U;
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(physical, 2072U, true, false).status,
                  MoonlightKeyboardStatus::Applied); // Ctrl
    auto onscreen = keyboardContext(fixture.identity, 1U, 103U,
                                    MoonlightInputSource::OnScreenKeyboard, 51U);
    RDP_ASSERT_EQ(fixture.mapper->setModifierLatch(
                      onscreen, MoonlightKeyboardModifier::Shift,
                      MoonlightKeyboardLatch::Locked).status,
                  MoonlightKeyboardStatus::Applied);
    fixture.port->scripted = {
        MoonlightInputPortStatus::Accepted,
        MoonlightInputPortStatus::Backpressure,
        MoonlightInputPortStatus::Accepted,
        MoonlightInputPortStatus::Accepted,
        MoonlightInputPortStatus::Accepted,
    };
    fixture.port->scriptIndex = 0U;
    onscreen.sourceSequence = 2U;
    onscreen.monotonicTimestampUs = 104U;
    const auto partial = fixture.mapper->releaseAll(onscreen);
    RDP_ASSERT_EQ(partial.status, MoonlightKeyboardStatus::Backpressure);
    RDP_ASSERT_EQ(partial.acceptedCommands, static_cast<std::size_t>(1U));
    RDP_ASSERT_EQ(partial.pendingCommands, static_cast<std::size_t>(3U));
    const std::size_t releaseStart = 4U;
    RDP_ASSERT_EQ(fixture.commandAt(releaseStart).protocolKeyCode,
                  static_cast<std::uint16_t>(0x8041U));
    RDP_ASSERT_EQ(fixture.commandAt(releaseStart).action, kMoonlightKeyboardActionUp);
    RDP_ASSERT_EQ(fixture.mapper->resumePending().status, MoonlightKeyboardStatus::Applied);
    RDP_ASSERT_EQ(fixture.commandAt(releaseStart + 2U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x8057U));
    RDP_ASSERT_EQ(fixture.commandAt(releaseStart + 3U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x80A2U));
    RDP_ASSERT_EQ(fixture.commandAt(releaseStart + 4U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x80A0U));
    const auto snapshot = fixture.mapper->snapshot(fixture.identity);
    RDP_ASSERT_EQ(snapshot.pressedNonModifierKeys, static_cast<std::size_t>(0U));
    RDP_ASSERT_EQ(snapshot.remoteModifierMask, static_cast<std::uint8_t>(0U));
    RDP_ASSERT_EQ(fixture.mapper->releaseAll(
                      keyboardContext(fixture.identity, 3U, 105U,
                                      MoonlightInputSource::OnScreenKeyboard, 51U)).status,
                  MoonlightKeyboardStatus::AlreadyApplied);
}

RDP_TEST_CASE(moonlight_keyboard_pressed_key_capacity_fails_closed) {
    MoonlightKeyboardLimits limits;
    limits.maximumPressedNonModifierKeys = 2U;
    KeyboardFixture fixture(limits);
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(
                      keyboardContext(fixture.identity, 1U, 100U), 2017U, true, false).status,
                  MoonlightKeyboardStatus::Applied);
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(
                      keyboardContext(fixture.identity, 2U, 101U), 2018U, true, false).status,
                  MoonlightKeyboardStatus::Applied);
    RDP_ASSERT_EQ(fixture.mapper->physicalKey(
                      keyboardContext(fixture.identity, 3U, 102U), 2019U, true, false).status,
                  MoonlightKeyboardStatus::KeyCapacity);
    RDP_ASSERT_EQ(fixture.port->events.size(), static_cast<std::size_t>(2U));
}

RDP_TEST_CASE(moonlight_keyboard_full_release_covers_all_sixteen_bounded_keys) {
    KeyboardFixture fixture;
    for (std::uint32_t offset = 0U; offset < 8U; ++offset) {
        RDP_ASSERT_EQ(fixture.mapper->physicalKey(
                          keyboardContext(fixture.identity, offset + 1U, 100U + offset),
                          2017U + offset, true, false).status,
                      MoonlightKeyboardStatus::Applied);
    }
    constexpr std::array<std::uint32_t, 8U> modifiers{{
        2047U, 2048U, 2072U, 2073U, 2045U, 2046U, 2076U, 2077U,
    }};
    for (std::size_t index = 0U; index < modifiers.size(); ++index) {
        RDP_ASSERT_EQ(fixture.mapper->physicalKey(
                          keyboardContext(fixture.identity, index + 9U, 108U + index),
                          modifiers[index], true, false).status,
                      MoonlightKeyboardStatus::Applied);
    }
    const auto released = fixture.mapper->releaseAll(
        keyboardContext(fixture.identity, 1U, 200U,
                        MoonlightInputSource::OnScreenKeyboard, 51U));
    RDP_ASSERT_EQ(released.status, MoonlightKeyboardStatus::Applied);
    RDP_ASSERT_EQ(released.acceptedCommands,
                  kMoonlightMaximumKeyboardTransactionCommands);
    RDP_ASSERT_EQ(fixture.port->events.size(), static_cast<std::size_t>(32U));
    RDP_ASSERT_EQ(fixture.commandAt(16U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x8048U));
    RDP_ASSERT_EQ(fixture.commandAt(23U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x8041U));
    RDP_ASSERT_EQ(fixture.commandAt(24U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x805CU));
    RDP_ASSERT_EQ(fixture.commandAt(31U).protocolKeyCode,
                  static_cast<std::uint16_t>(0x80A0U));
    const auto snapshot = fixture.mapper->snapshot(fixture.identity);
    RDP_ASSERT_EQ(snapshot.pressedNonModifierKeys, static_cast<std::size_t>(0U));
    RDP_ASSERT_EQ(snapshot.remoteModifierMask, static_cast<std::uint8_t>(0U));
}

RDP_TEST_CASE(moonlight_keyboard_decoder_rejects_malformed_bodies) {
    MoonlightInputEvent event;
    event.identity = keyboardIdentity();
    event.deviceId = 1U;
    event.source = MoonlightInputSource::PhysicalKeyboard;
    event.sourceGeneration = 1U;
    event.sourceSequence = 1U;
    event.monotonicTimestampUs = 1U;
    event.kind = MoonlightInputCommandKind::Keyboard;
    event.commandVersion = 1U;
    event.payloadSize = kMoonlightKeyboardCommandBytes;
    event.payload[0] = kMoonlightKeyboardActionDown;
    event.payload[1] = 0x41U;
    event.payload[2] = 0x80U;
    MoonlightKeyboardWireCommand command;
    RDP_ASSERT(decodeMoonlightKeyboardCommand(event, command));
    event.payloadSize = kMoonlightKeyboardCommandBytes - 1U;
    RDP_ASSERT(!decodeMoonlightKeyboardCommand(event, command));
    event.payloadSize = kMoonlightKeyboardCommandBytes;
    event.payload[0] = 0xFFU;
    RDP_ASSERT(!decodeMoonlightKeyboardCommand(event, command));
    event.payload[0] = kMoonlightKeyboardActionDown;
    event.payload[2] = 0x70U;
    RDP_ASSERT(!decodeMoonlightKeyboardCommand(event, command));
    event.payload[2] = 0x80U;
    event.payload[3] = 0x10U;
    RDP_ASSERT(!decodeMoonlightKeyboardCommand(event, command));
    event.payload[3] = 0U;
    event.payload[4] = 0x02U;
    RDP_ASSERT(!decodeMoonlightKeyboardCommand(event, command));
    event.payload[4] = 0U;
    event.kind = MoonlightInputCommandKind::Text;
    RDP_ASSERT(!decodeMoonlightKeyboardCommand(event, command));
}

RDP_TEST_CASE(moonlight_keyboard_owner_loss_and_concurrent_duplicate_never_cross_route) {
    KeyboardFixture fixture;
    fixture.gate->reject();
    const auto stale = fixture.mapper->physicalKey(
        keyboardContext(fixture.identity, 1U, 100U), 2017U, true, false);
    RDP_ASSERT_EQ(stale.status, MoonlightKeyboardStatus::StaleOwner);
    RDP_ASSERT_EQ(stale.pendingCommands, static_cast<std::size_t>(1U));
    RDP_ASSERT(fixture.mapper->cancelPendingIfUnsent(fixture.identity));
    RDP_ASSERT_EQ(fixture.port->events.size(), static_cast<std::size_t>(0U));

    fixture.gate->accept(fixture.identity);
    fixture.port->block();
    MoonlightKeyboardResult first;
    MoonlightKeyboardResult second;
    const auto context = keyboardContext(fixture.identity, 2U, 101U);
    std::thread one([&]() {
        first = fixture.mapper->physicalKey(context, 2018U, true, false);
    });
    fixture.port->waitUntilEntered();
    std::thread two([&]() {
        second = fixture.mapper->physicalKey(context, 2018U, true, false);
    });
    fixture.port->release();
    one.join();
    two.join();
    RDP_ASSERT_EQ(first.status, MoonlightKeyboardStatus::Applied);
    RDP_ASSERT_EQ(second.status, MoonlightKeyboardStatus::Duplicate);
    RDP_ASSERT_EQ(fixture.port->events.size(), static_cast<std::size_t>(1U));
}

} // namespace
