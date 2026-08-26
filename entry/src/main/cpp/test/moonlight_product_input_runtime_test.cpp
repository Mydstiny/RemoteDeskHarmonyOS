#include "moonlight/input/MoonlightCommonCInputPort.h"
#include "moonlight/input/MoonlightCommonCInputResult.h"
#include "moonlight/input/MoonlightProductInputRuntime.h"
#include "moonlight/runtime/MoonlightProductStreamingRuntime.h"
#include "render/video_perf_counters.h"
#include "test_runner.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <utility>

namespace {

std::atomic<int> gKeyboardWireResult{0};
std::atomic<int> gTouchWireResult{0};
std::atomic<int> gOtherWireResult{0};
std::atomic<std::uint32_t> gHostFeatureFlags{0U};
std::atomic<std::size_t> gKeyboardWireCalls{0U};
std::atomic<std::size_t> gTouchWireCalls{0U};
std::atomic<std::size_t> gOtherWireCalls{0U};

void resetCommonCWireStub() noexcept {
    gKeyboardWireResult.store(0);
    gTouchWireResult.store(0);
    gOtherWireResult.store(0);
    gHostFeatureFlags.store(0U);
    gKeyboardWireCalls.store(0U);
    gTouchWireCalls.store(0U);
    gOtherWireCalls.store(0U);
}

void setKeyboardWireResult(int result) noexcept {
    gKeyboardWireResult.store(result);
}

void setTouchWireResult(int result) noexcept {
    gTouchWireResult.store(result);
}

void setOtherWireResult(int result) noexcept {
    gOtherWireResult.store(result);
}

std::size_t keyboardWireCalls() noexcept {
    return gKeyboardWireCalls.load();
}

std::size_t touchWireCalls() noexcept {
    return gTouchWireCalls.load();
}

std::size_t otherWireCalls() noexcept {
    return gOtherWireCalls.load();
}

} // namespace

// The host target deliberately does not link common-c. These exact C ABI
// stubs let the tests compile the production CommonCInputPort translation unit
// and inject official LiSend* return codes without replacing the product
// factory or bypassing its wire-result conversion.
extern "C" {
int LiSendMouseMoveEvent(short, short) {
    gOtherWireCalls.fetch_add(1U);
    return gOtherWireResult.load();
}

int LiSendMousePositionEvent(short, short, short, short) {
    gOtherWireCalls.fetch_add(1U);
    return gOtherWireResult.load();
}

int LiSendTouchEvent(std::uint8_t, std::uint32_t, float, float, float,
                     float, float, std::uint16_t) {
    gTouchWireCalls.fetch_add(1U);
    return gTouchWireResult.load();
}

int LiSendMouseButtonEvent(char, int) {
    gOtherWireCalls.fetch_add(1U);
    return gOtherWireResult.load();
}

int LiSendKeyboardEvent2(short, char, char, char) {
    gKeyboardWireCalls.fetch_add(1U);
    return gKeyboardWireResult.load();
}

int LiSendUtf8TextEvent(const char*, unsigned int) {
    gOtherWireCalls.fetch_add(1U);
    return gOtherWireResult.load();
}

int LiSendMultiControllerEvent(short, short, int, unsigned char,
                               unsigned char, short, short, short, short) {
    gOtherWireCalls.fetch_add(1U);
    return gOtherWireResult.load();
}

int LiSendControllerArrivalEvent(std::uint8_t, std::uint16_t, std::uint8_t,
                                 std::uint32_t, std::uint16_t) {
    gOtherWireCalls.fetch_add(1U);
    return gOtherWireResult.load();
}

int LiSendHighResScrollEvent(short) {
    gOtherWireCalls.fetch_add(1U);
    return gOtherWireResult.load();
}

int LiSendHighResHScrollEvent(short) {
    gOtherWireCalls.fetch_add(1U);
    return gOtherWireResult.load();
}

std::uint32_t LiGetHostFeatureFlags(void) {
    return gHostFeatureFlags.load();
}
} // extern "C"

namespace {

using namespace remotedesk::moonlight;
using namespace std::chrono_literals;

class ProductInputFixture final {
  public:
    bool start(bool directTouch = false) {
        resetCommonCWireStub();
        if (directTouch) {
            gHostFeatureFlags.store(LI_FF_PEN_TOUCH_EVENTS);
        }

        MoonlightSessionOwner::Driver driver;
        driver.start = [](MoonlightSessionOwner::StartContext&) { return 0; };
        driver.interrupt = []() {};
        driver.stop = []() {};
        static std::atomic<std::uint64_t> nextSessionId{900000U};
        const auto started = MoonlightSessionOwner::process().start(
            nextSessionId.fetch_add(1U), 1U, std::move(driver));
        if (started.status != MoonlightStartStatus::Accepted ||
            !started.key.valid()) {
            return false;
        }
        key = started.key;
        ownerStarted = true;
        if (!MoonlightSessionOwner::process().waitForPhase(
                key, MoonlightSessionPhase::Running, 2s)) {
            return false;
        }
        const Render::DecoderSessionIdentity sharedIdentity{
            key.sessionId, key.generation, key.ownerToken};
        if (!Render::SharedSessionSinkOwnerLease().activate(sharedIdentity)) {
            return false;
        }
        sharedActivated = true;
        runtimeActivated = MoonlightProductInputRuntime::process().activate(key);
        return runtimeActivated;
    }

    bool seedHeldKey() {
        return MoonlightProductInputRuntime::process().sendKey(
            key, 2017U, true, true);
    }

    bool releaseHeldKey() {
        return MoonlightProductInputRuntime::process().sendKey(
            key, 2017U, false, true);
    }

    bool sendPointerButton(bool pressed) {
        MoonlightProductPointerRequest request;
        request.action = MoonlightProductPointerAction::Button;
        request.button = MoonlightPointerButton::Left;
        request.pressed = pressed;
        return MoonlightProductInputRuntime::process().sendPointer(key, request);
    }

    bool sendAbsolutePointerButton(double x, double y,
                                   MoonlightPointerButton button, bool pressed) {
        MoonlightProductPointerRequest request;
        request.action = MoonlightProductPointerAction::AbsoluteButton;
        request.x = x;
        request.y = y;
        request.contentLeft = 0.0;
        request.contentTop = 50.0;
        request.contentWidth = 1000.0;
        request.contentHeight = 500.0;
        request.referenceWidth = 1920U;
        request.referenceHeight = 1080U;
        request.geometryGeneration = 1U;
        request.button = button;
        request.pressed = pressed;
        return MoonlightProductInputRuntime::process().sendPointer(key, request);
    }

    bool sendDirectTouch(MoonlightTouchPhase phase) {
        MoonlightProductTouchRequest request;
        request.contactId = 1U;
        request.phase = phase;
        request.surface.content = {
            0.0, 0.0, 1280.0, 720.0, 1280U, 720U, 0U, 1U};
        request.surface.hitMapGeneration = 1U;
        request.sample = {640.0, 360.0, 0.5F, 0.02F, 0.01F,
                          kMoonlightTouchRotationUnknown};
        return MoonlightProductInputRuntime::process().sendTouch(key, request);
    }

    MoonlightProductInputSnapshot snapshot() {
        return MoonlightProductInputRuntime::process().snapshot(key);
    }

    void markRuntimeStopped() noexcept {
        runtimeActivated = false;
    }

    bool revokeSharedOwner() noexcept {
        if (!sharedActivated) {
            return false;
        }
        const Render::DecoderSessionIdentity sharedIdentity{
            key.sessionId, key.generation, key.ownerToken};
        const bool removed =
            Render::SharedSessionSinkOwnerLease().deactivateIfActive(sharedIdentity);
        sharedActivated = !removed;
        return removed;
    }

    bool finish() noexcept {
        bool clean = true;
        if (runtimeActivated) {
            (void)MoonlightProductInputRuntime::process().stop(key);
            runtimeActivated = false;
        }
        if (sharedActivated) {
            const Render::DecoderSessionIdentity sharedIdentity{
                key.sessionId, key.generation, key.ownerToken};
            clean = Render::SharedSessionSinkOwnerLease().deactivateIfActive(
                sharedIdentity) && clean;
            sharedActivated = false;
        }
        if (ownerStarted) {
            const auto stopped = MoonlightSessionOwner::process().stop(key, 2s);
            clean = (stopped == MoonlightStopStatus::Stopped ||
                     stopped == MoonlightStopStatus::AlreadyTerminal) && clean;
            ownerStarted = false;
        }
        return clean;
    }

    ~ProductInputFixture() {
        (void)finish();
    }

    MoonlightSessionKey key{};

  private:
    bool ownerStarted = false;
    bool sharedActivated = false;
    bool runtimeActivated = false;
};

void assertUnsafeTerminal(
    const MoonlightProductInputStopResult& stopped) {
    RDP_ASSERT(stopped.localCleanupComplete);
    RDP_ASSERT(!stopped.remoteNeutral);
    RDP_ASSERT(moonlightProductTerminalInputMayBeStuck(
        true, true, stopped.localCleanupComplete, stopped.remoteNeutral));
}

} // namespace

RDP_TEST_CASE(moonlight_common_c_input_port_maps_wire_and_flush_results) {
    resetCommonCWireStub();
    const auto port = createMoonlightCommonCInputPort();
    RDP_ASSERT(port != nullptr);

    MoonlightInputFlushRequest request;
    request.identity.key = {1U, 2U, 3U};
    request.identity.inputGeneration = 4U;
    request.reason = MoonlightInputSuspendReason::Stop;
    request.operationGeneration = 5U;
    request.monotonicTimestampUs = 6U;

    setTouchWireResult(LI_ERR_UNSUPPORTED);
    RDP_ASSERT(port->flushNeutral(request));
    RDP_ASSERT_EQ(touchWireCalls(), static_cast<std::size_t>(1));

    setTouchWireResult(-7001);
    RDP_ASSERT(!port->flushNeutral(request));
    RDP_ASSERT_EQ(touchWireCalls(), static_cast<std::size_t>(2));

    request.monotonicTimestampUs = 0U;
    RDP_ASSERT(!port->flushNeutral(request));
    RDP_ASSERT_EQ(touchWireCalls(), static_cast<std::size_t>(2));
}

RDP_TEST_CASE(moonlight_product_input_stop_proves_only_complete_remote_release) {
    ProductInputFixture fixture;
    RDP_ASSERT(fixture.start());
    RDP_ASSERT(fixture.seedHeldKey());
    const auto stopped = MoonlightProductInputRuntime::process().stop(fixture.key);
    fixture.markRuntimeStopped();
    RDP_ASSERT(stopped.localCleanupComplete);
    RDP_ASSERT(stopped.remoteNeutral);
    RDP_ASSERT(!moonlightProductTerminalInputMayBeStuck(
        true, true, stopped.localCleanupComplete, stopped.remoteNeutral));
    RDP_ASSERT_EQ(touchWireCalls(), static_cast<std::size_t>(1));
    RDP_ASSERT(fixture.finish());
}

RDP_TEST_CASE(moonlight_product_input_stop_keeps_permanent_backpressure_unsafe) {
    ProductInputFixture fixture;
    RDP_ASSERT(fixture.start());
    RDP_ASSERT(fixture.seedHeldKey());
    setKeyboardWireResult(LBQ_BOUND_EXCEEDED);
    const auto stopped = MoonlightProductInputRuntime::process().stop(fixture.key);
    fixture.markRuntimeStopped();
    assertUnsafeTerminal(stopped);
    RDP_ASSERT_EQ(touchWireCalls(), static_cast<std::size_t>(1));
    RDP_ASSERT(fixture.finish());
}

RDP_TEST_CASE(moonlight_product_input_stop_keeps_port_failure_unsafe) {
    ProductInputFixture fixture;
    RDP_ASSERT(fixture.start());
    RDP_ASSERT(fixture.seedHeldKey());
    setKeyboardWireResult(-7001);
    const auto stopped = MoonlightProductInputRuntime::process().stop(fixture.key);
    fixture.markRuntimeStopped();
    assertUnsafeTerminal(stopped);
    RDP_ASSERT_EQ(touchWireCalls(), static_cast<std::size_t>(1));
    RDP_ASSERT(fixture.finish());
}

RDP_TEST_CASE(moonlight_product_input_stop_keeps_local_only_boundary_unsafe) {
    ProductInputFixture fixture;
    RDP_ASSERT(fixture.start());
    RDP_ASSERT(fixture.seedHeldKey());
    RDP_ASSERT(fixture.revokeSharedOwner());
    const auto stopped = MoonlightProductInputRuntime::process().stop(fixture.key);
    fixture.markRuntimeStopped();
    assertUnsafeTerminal(stopped);
    RDP_ASSERT_EQ(touchWireCalls(), static_cast<std::size_t>(0));
    RDP_ASSERT(fixture.finish());
}

RDP_TEST_CASE(moonlight_product_input_stop_keeps_already_applied_ambiguous) {
    ProductInputFixture fixture;
    RDP_ASSERT(fixture.start());
    RDP_ASSERT(fixture.seedHeldKey());
    RDP_ASSERT(MoonlightProductInputRuntime::process().setSuspended(
        fixture.key, MoonlightInputFlushTrigger::ReconnectStarted, true));
    const auto stopped = MoonlightProductInputRuntime::process().stop(fixture.key);
    fixture.markRuntimeStopped();
    assertUnsafeTerminal(stopped);
    RDP_ASSERT_EQ(touchWireCalls(), static_cast<std::size_t>(1));
    RDP_ASSERT(fixture.finish());
}

RDP_TEST_CASE(moonlight_product_input_snapshot_retries_exact_keyboard_release) {
    ProductInputFixture fixture;
    RDP_ASSERT(fixture.start());
    RDP_ASSERT(fixture.seedHeldKey());
    setKeyboardWireResult(LBQ_BOUND_EXCEEDED);
    RDP_ASSERT(!fixture.releaseHeldKey());
    const std::size_t callsBeforeRetry = keyboardWireCalls();

    setKeyboardWireResult(0);
    const auto recovered = fixture.snapshot();
    RDP_ASSERT(recovered.matched);
    RDP_ASSERT(recovered.inputReady);
    RDP_ASSERT(!recovered.recoveryResetFailed);
    RDP_ASSERT_EQ(keyboardWireCalls(), callsBeforeRetry + 1U);
    RDP_ASSERT(!recovered.inputMayBeStuck);
    RDP_ASSERT(fixture.finish());
}

RDP_TEST_CASE(moonlight_product_input_snapshot_retries_exact_pointer_release) {
    ProductInputFixture fixture;
    RDP_ASSERT(fixture.start());
    RDP_ASSERT(fixture.sendPointerButton(true));
    setOtherWireResult(LBQ_BOUND_EXCEEDED);
    RDP_ASSERT(!fixture.sendPointerButton(false));
    const std::size_t callsBeforeRetry = otherWireCalls();

    setOtherWireResult(0);
    const auto recovered = fixture.snapshot();
    RDP_ASSERT(recovered.matched);
    RDP_ASSERT(recovered.inputReady);
    RDP_ASSERT_EQ(otherWireCalls(), callsBeforeRetry + 1U);
    RDP_ASSERT(!recovered.inputMayBeStuck);
    RDP_ASSERT(fixture.finish());
}

RDP_TEST_CASE(moonlight_product_input_absolute_button_is_atomic_and_bar_safe) {
    ProductInputFixture fixture;
    RDP_ASSERT(fixture.start());
    RDP_ASSERT(fixture.sendAbsolutePointerButton(
        500.0, 300.0, MoonlightPointerButton::Left, true));
    RDP_ASSERT_EQ(otherWireCalls(), static_cast<std::size_t>(2));

    RDP_ASSERT(fixture.sendAbsolutePointerButton(
        500.0, 10.0, MoonlightPointerButton::Right, true));
    RDP_ASSERT_EQ(otherWireCalls(), static_cast<std::size_t>(2));

    RDP_ASSERT(fixture.sendAbsolutePointerButton(
        500.0, 10.0, MoonlightPointerButton::Left, false));
    RDP_ASSERT_EQ(otherWireCalls(), static_cast<std::size_t>(3));
    RDP_ASSERT(fixture.finish());
}

RDP_TEST_CASE(moonlight_product_input_snapshot_retries_exact_direct_touch) {
    ProductInputFixture fixture;
    RDP_ASSERT(fixture.start(true));
    setTouchWireResult(LBQ_BOUND_EXCEEDED);
    RDP_ASSERT(!fixture.sendDirectTouch(MoonlightTouchPhase::Down));
    const std::size_t callsBeforeRetry = touchWireCalls();

    setTouchWireResult(0);
    const auto recovered = fixture.snapshot();
    RDP_ASSERT(recovered.matched);
    RDP_ASSERT(recovered.inputReady);
    RDP_ASSERT_EQ(touchWireCalls(), callsBeforeRetry + 1U);
    RDP_ASSERT(recovered.inputMayBeStuck);
    RDP_ASSERT(fixture.sendDirectTouch(MoonlightTouchPhase::Up));
    RDP_ASSERT(fixture.finish());
}

RDP_TEST_CASE(moonlight_product_input_permanent_backpressure_fails_closed) {
    ProductInputFixture fixture;
    RDP_ASSERT(fixture.start());
    RDP_ASSERT(fixture.seedHeldKey());
    setKeyboardWireResult(LBQ_BOUND_EXCEEDED);
    RDP_ASSERT(!fixture.releaseHeldKey());

    MoonlightProductInputSnapshot failed;
    for (std::size_t attempt = 0U; attempt < 16U; ++attempt) {
        failed = fixture.snapshot();
        if (failed.recoveryResetFailed) {
            break;
        }
    }
    RDP_ASSERT(failed.matched);
    RDP_ASSERT(failed.recoveryResetFailed);
    RDP_ASSERT(!failed.inputReady);
    RDP_ASSERT(failed.inputMayBeStuck);
    RDP_ASSERT(!fixture.seedHeldKey());

    const auto stopped = MoonlightProductInputRuntime::process().stop(fixture.key);
    fixture.markRuntimeStopped();
    assertUnsafeTerminal(stopped);
    RDP_ASSERT(fixture.finish());
}

RDP_TEST_CASE(moonlight_product_input_pending_collision_fails_closed) {
    ProductInputFixture fixture;
    RDP_ASSERT(fixture.start());
    setKeyboardWireResult(LBQ_BOUND_EXCEEDED);
    RDP_ASSERT(!fixture.seedHeldKey());
    RDP_ASSERT(!fixture.releaseHeldKey());

    const auto failed = fixture.snapshot();
    RDP_ASSERT(failed.matched);
    RDP_ASSERT(failed.recoveryResetFailed);
    RDP_ASSERT(!failed.inputReady);
    RDP_ASSERT(failed.inputMayBeStuck);
    RDP_ASSERT(fixture.finish());
}
