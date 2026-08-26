#include "moonlight/input/MoonlightGameControllerListener.h"
#include "test/test_runner.h"

#include <cstdint>

namespace {

using namespace remotedesk::moonlight;

class NoopSink final : public MoonlightGameControllerListener::Sink {
  public:
    void onPhysicalControllerConnected(
        std::uint64_t, std::uint64_t, std::uint64_t, std::uint64_t,
        const MoonlightControllerProfile&) noexcept override {}
    void onPhysicalControllerSample(
        std::uint64_t, std::uint64_t, std::uint64_t, std::uint64_t,
        const MoonlightControllerSample&) noexcept override {}
    void onPhysicalControllerDisconnected(
        std::uint64_t, std::uint64_t, std::uint64_t,
        std::uint64_t) noexcept override {}
};

RDP_TEST_CASE(moonlight_game_controller_listener_stable_device_id_is_bounded) {
    RDP_ASSERT_EQ(MoonlightGameControllerListener::stableDeviceIdForTesting(nullptr), 0U);
    RDP_ASSERT_EQ(MoonlightGameControllerListener::stableDeviceIdForTesting(""), 0U);
    const auto first = MoonlightGameControllerListener::stableDeviceIdForTesting(
        "gamepad-001");
    RDP_ASSERT(first != 0U);
    RDP_ASSERT_EQ(first,
                  MoonlightGameControllerListener::stableDeviceIdForTesting(
                      "gamepad-001"));
    RDP_ASSERT(first != MoonlightGameControllerListener::stableDeviceIdForTesting(
        "gamepad-002"));
}

RDP_TEST_CASE(moonlight_game_controller_listener_ignores_text_after_bound) {
    char first[257] = {};
    char second[257] = {};
    for (std::size_t index = 0U; index < 256U; ++index) {
        first[index] = 'a';
        second[index] = 'a';
    }
    first[256] = 'x';
    second[256] = 'y';
    RDP_ASSERT_EQ(MoonlightGameControllerListener::stableDeviceIdForTesting(first),
                  MoonlightGameControllerListener::stableDeviceIdForTesting(second));
}

RDP_TEST_CASE(moonlight_game_controller_listener_host_is_fail_closed) {
    NoopSink sink;
    MoonlightGameControllerListener listener(sink);
    RDP_ASSERT(!listener.start());
    RDP_ASSERT(!listener.started());
    RDP_ASSERT_EQ(listener.onlineDeviceCount(), 0U);
    listener.stop();
    listener.stop();
}

RDP_TEST_CASE(moonlight_game_controller_listener_maps_registered_controls_without_names) {
    MoonlightControllerSample sample;
    sample.hasHatAxes = true;
    sample.hatX = 1.0;
    sample.hatY = -1.0;

    RDP_ASSERT(applyMoonlightGameControllerButtonInput(
        MoonlightGameControllerButtonInput::FaceA, true, sample));
    RDP_ASSERT((sample.buttonFlags & kMoonlightControllerButtonA) != 0U);
    RDP_ASSERT(sample.hasHatAxes);

    RDP_ASSERT(applyMoonlightGameControllerButtonInput(
        MoonlightGameControllerButtonInput::DpadLeft, true, sample));
    RDP_ASSERT((sample.buttonFlags & kMoonlightControllerButtonLeft) != 0U);
    RDP_ASSERT(!sample.hasHatAxes);

    RDP_ASSERT(applyMoonlightGameControllerButtonInput(
        MoonlightGameControllerButtonInput::Menu, true, sample));
    RDP_ASSERT((sample.buttonFlags & kMoonlightControllerButtonPlay) != 0U);
    RDP_ASSERT(applyMoonlightGameControllerButtonInput(
        MoonlightGameControllerButtonInput::LeftShoulder, true, sample));
    RDP_ASSERT((sample.buttonFlags &
                kMoonlightControllerButtonLeftShoulder) != 0U);
    RDP_ASSERT(applyMoonlightGameControllerButtonInput(
        MoonlightGameControllerButtonInput::LeftStick, true, sample));
    RDP_ASSERT((sample.buttonFlags & kMoonlightControllerButtonLeftStick) != 0U);
    RDP_ASSERT(applyMoonlightGameControllerButtonInput(
        MoonlightGameControllerButtonInput::Home, true, sample));
    RDP_ASSERT((sample.buttonFlags & kMoonlightControllerButtonSpecial) != 0U);

    RDP_ASSERT(applyMoonlightGameControllerButtonInput(
        MoonlightGameControllerButtonInput::FaceA, false, sample));
    RDP_ASSERT((sample.buttonFlags & kMoonlightControllerButtonA) == 0U);
}

RDP_TEST_CASE(moonlight_game_controller_listener_button_mapping_preserves_axis_triggers) {
    MoonlightControllerSample sample;
    sample.leftTrigger = 0.4;
    sample.rightTrigger = 0.7;
    RDP_ASSERT(applyMoonlightGameControllerButtonInput(
        MoonlightGameControllerButtonInput::FaceB, true, sample));
    RDP_ASSERT_EQ(sample.leftTrigger, 0.4);
    RDP_ASSERT_EQ(sample.rightTrigger, 0.7);
}

RDP_TEST_CASE(moonlight_game_controller_listener_maps_digital_trigger_fallback) {
    MoonlightControllerSample sample;
    RDP_ASSERT(applyMoonlightGameControllerButtonInput(
        MoonlightGameControllerButtonInput::LeftTrigger, true, sample));
    RDP_ASSERT_EQ(sample.leftTrigger, 1.0);
    RDP_ASSERT_EQ(sample.rightTrigger, 0.0);
    RDP_ASSERT(applyMoonlightGameControllerButtonInput(
        MoonlightGameControllerButtonInput::RightTrigger, true, sample));
    RDP_ASSERT_EQ(sample.rightTrigger, 1.0);
    RDP_ASSERT(applyMoonlightGameControllerButtonInput(
        MoonlightGameControllerButtonInput::LeftTrigger, false, sample));
    RDP_ASSERT_EQ(sample.leftTrigger, 0.0);
    RDP_ASSERT_EQ(sample.rightTrigger, 1.0);
}

} // namespace
