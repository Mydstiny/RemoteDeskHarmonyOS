#include "moonlight/input/MoonlightGameControllerListener.h"
#include "test/test_runner.h"

#include <cstdint>

namespace {

using namespace remotedesk::moonlight;

class NoopSink final : public MoonlightGameControllerListener::Sink {
  public:
    void onPhysicalControllerConnected(
        std::uint64_t, std::uint64_t,
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
    listener.replayOnlineDevices();
    listener.stop();
    listener.stop();
}

} // namespace
