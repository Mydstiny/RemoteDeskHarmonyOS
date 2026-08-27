/**
 * vnc_adapter.cpp - VNC protocol adapter
 *
 * VNC 协议：默认端口 5900+N (display N)，支持 bounded ZRLE、Raw、
 * CopyRect、Cursor 和 DesktopSize；Tight/ContinuousUpdates 未启用。
 */

#include "vnc_adapter.h"
#include "common/safe_log.h"
#include "extensions/extension_registry.h"
#include <hilog/log.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <future>
#include <utility>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0008
#define LOG_TAG "VNC_ADAPTER"

namespace {

std::atomic<uint64_t> g_nextVncCursorGeneration {1};

} // namespace

// The RFB engine may outlive VncAdapter after a bounded stop transfers it to
// the deferred owner. Engine callbacks therefore retain only this state
// object, never the adapter/Impl address.
struct VncCallbackState {
    std::atomic<bool> active {true};
    std::atomic<uint64_t> serial {0};
    mutable std::mutex mutex;
    VideoFrameCallback videoCallback;
    AudioDataCallback audioCallback;
    ConnectionStateCallback stateCallback;
    ConnectionState state = ConnectionState::DISCONNECTED;
    std::weak_ptr<VncRfbEngine> activeEngine;
    Render::DecoderSessionIdentity owner;
    RemoteCursorStore cursorStore;
    size_t callbackInFlight = 0;
    std::condition_variable callbackCv;

    void invalidate() {
        active.store(false, std::memory_order_release);
        serial.fetch_add(1, std::memory_order_acq_rel);
        std::lock_guard<std::mutex> lock(mutex);
        activeEngine.reset();
        videoCallback = nullptr;
        audioCallback = nullptr;
        stateCallback = nullptr;
    }

    bool beginCallback(uint64_t expectedSerial,
                       const std::shared_ptr<VncRfbEngine>& expectedEngine) {
        std::lock_guard<std::mutex> lock(mutex);
        if (!active.load(std::memory_order_relaxed) ||
            (expectedSerial != 0 &&
             serial.load(std::memory_order_relaxed) != expectedSerial)) {
            return false;
        }
        const auto activeEngineValue = activeEngine.lock();
        if (expectedEngine && (!activeEngineValue || activeEngineValue != expectedEngine)) {
            return false;
        }
        ++callbackInFlight;
        return true;
    }

    void endCallback() {
        std::lock_guard<std::mutex> lock(mutex);
        if (callbackInFlight > 0) {
            --callbackInFlight;
        }
        if (callbackInFlight == 0) {
            callbackCv.notify_all();
        }
    }

    bool dispatchVideo(const VideoFrame& frame,
                       const Render::DecoderSessionIdentity& capturedOwner,
                       uint64_t expectedSerial = 0,
                       const std::shared_ptr<VncRfbEngine>& expectedEngine = nullptr) {
        if (!active.load(std::memory_order_acquire)) return false;
        // Acquire the shared owner lease before taking the callback snapshot.
        // S1->S2 activation therefore cannot complete between validation and
        // the actual external sink call.
        auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(capturedOwner);
        if (!ownerLease) return false;
        if (!beginCallback(expectedSerial, expectedEngine)) {
            return false;
        }
        VideoFrameCallback callback;
        {
            std::lock_guard<std::mutex> lock(mutex);
            callback = videoCallback;
        }
        if (callback) callback(frame);
        endCallback();
        return static_cast<bool>(callback);
    }

    void applyProtocolCursor(
        uint64_t generation, const VncCursorProtocol::DecodedCursor& cursor) {
        if (!cursor.visible) {
            cursorStore.setVisibleIfGeneration(generation, false);
            return;
        }
        if (cursorStore.setShapeIfGeneration(
                generation, cursor.shapeId, cursor.width, cursor.height,
                cursor.hotX, cursor.hotY, cursor.rgba)) {
            cursorStore.setVisibleIfGeneration(generation, true);
        }
    }

    void updatePredictedCursorPosition(uint64_t generation, int x, int y) {
        // Local input predicts position only. Protocol visibility is
        // authoritative: a hidden Cursor update must remain hidden until the
        // server sends a new visible shape.
        cursorStore.setPositionIfGeneration(generation, x, y);
    }
};

struct VncAdapter::Impl {
    ConnectionConfig config;
    ConnectionState state = ConnectionState::DISCONNECTED;
    VideoFrameCallback videoCallback;
    AudioDataCallback audioCallback;
    ConnectionStateCallback stateCallback;
    std::shared_ptr<VncRfbEngine> engine;
    std::shared_ptr<StartingSlot> startingSlot;
#ifdef RDP_NATIVE_CALLBACK_TESTING
    std::function<int(VncRfbEngine&)> engineStartHook;
#endif
    std::mutex mutex;
    uint64_t sessionId = 0;
    uint64_t cursorGeneration = 0;
    Render::DecoderSessionIdentity owner;
    RemoteCursorStore cursorStore;
    std::shared_ptr<VncCallbackState> callbackState =
        std::make_shared<VncCallbackState>();
};

struct VncAdapter::StartingSlot {
    enum class State : uint8_t {
        StartingNotWritable,
        ActiveWritable,
    };

    uint64_t serial = 0;
    std::shared_ptr<VncRfbEngine> engine;
    std::shared_ptr<VncCallbackState> callbackState;
    std::atomic<bool> cancelled {false};
    std::atomic<bool> startFinished {false};
    std::atomic<State> state {State::StartingNotWritable};
};

VncAdapter::VncAdapter() : impl_(std::make_unique<Impl>()) {
    OH_LOG_INFO(LOG_APP, "[VNC] VncAdapter 已创建");
}
VncAdapter::~VncAdapter() {
    if (impl_ && impl_->callbackState) {
        impl_->callbackState->invalidate();
    }
    disconnect();
    OH_LOG_INFO(LOG_APP, "[VNC] VncAdapter 已销毁");
}

std::string VncAdapter::protocolName() { return "VNC"; }
int VncAdapter::defaultPort() { return 5900; }
std::string VncAdapter::protocolVersion() { return "RFB 3.3/3.7/3.8"; }

void VncAdapter::setSessionIdentity(uint64_t sessionId) {
    const uint64_t generation =
        g_nextVncCursorGeneration.fetch_add(1, std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->sessionId = sessionId;
    impl_->cursorGeneration = generation;
    impl_->callbackState->cursorStore.reset(sessionId, "vnc", generation);
    impl_->callbackState->cursorStore.setFallbackShape();
    impl_->callbackState->cursorStore.setVisible(true);
}

void VncAdapter::setSessionOwner(const Render::DecoderSessionIdentity& owner) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->owner = owner;
    impl_->callbackState->owner = owner;
}

RemoteCursorSnapshot VncAdapter::getRemoteCursorSnapshot(bool includePixels) {
    RemoteCursorSnapshot snapshot = impl_->callbackState->cursorStore.snapshot(includePixels);
    std::shared_ptr<VncRfbEngine> engine;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        engine = impl_->engine;
    }
    // Fail visible before the asynchronous RFB banner is available. Once the
    // handshake classifies the peer, modern no-Cursor servers transition to
    // framebuffer ownership while legacy macOS-style peers keep bootstrap.
    snapshot.legacyVncCursorBootstrap = engine == nullptr ||
        engine->keepsLocalCursorDuringBootstrap();
    return snapshot;
}

int VncAdapter::connect(const ConnectionConfig& cfg) {
    const uint64_t connectionSerial = connectionSerial_.fetch_add(
        1, std::memory_order_acq_rel) + 1;
    auto callbackState = impl_->callbackState;
    callbackState->active.store(true, std::memory_order_release);
    callbackState->serial.store(connectionSerial, std::memory_order_release);
    std::shared_ptr<VncRfbEngine> previousEngine;
    std::shared_ptr<VncRfbEngine> previousStartingEngine;
    ConnectionStateCallback disconnectedCallback;
    {
        std::lock_guard<std::mutex> lifecycleLock(lifecycleMutex_);
        previousEngine = detachEngineLocked(disconnectedCallback);
        if (impl_->startingSlot) {
            impl_->startingSlot->cancelled.store(true, std::memory_order_release);
            if (impl_->startingSlot->startFinished.load(std::memory_order_acquire)) {
                previousStartingEngine = impl_->startingSlot->engine;
                impl_->startingSlot.reset();
            }
        }
    }
    auto stopEngine = [](const std::shared_ptr<VncRfbEngine>& engine) {
        if (!engine) return;
        if (engine->isWorkerThread() ||
            !engine->stopWithin(std::chrono::milliseconds(500))) {
            VncRfbEngine::deferStopAndJoin(engine);
        }
    };
    stopEngine(previousEngine);
    stopEngine(previousStartingEngine);
    if (disconnectedCallback) {
        disconnectedCallback(ConnectionState::DISCONNECTED, "VNC 已断开");
    }

    uint64_t cursorGeneration = 0;
    ConnectionStateCallback connectingCallback;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->config = cfg;
        impl_->state = ConnectionState::CONNECTING;
        if (impl_->cursorGeneration == 0) {
            impl_->cursorGeneration =
                g_nextVncCursorGeneration.fetch_add(1, std::memory_order_relaxed);
            callbackState->cursorStore.reset(impl_->sessionId, "vnc", impl_->cursorGeneration);
            callbackState->cursorStore.setFallbackShape();
        }
        cursorGeneration = impl_->cursorGeneration;
        callbackState->cursorStore.setVisible(true);
        connectingCallback = impl_->stateCallback;
    }
    Render::DecoderSessionIdentity capturedOwner;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        capturedOwner = impl_->owner;
    }

    const auto slot = std::make_shared<StartingSlot>();
    slot->serial = connectionSerial;
    slot->callbackState = callbackState;
    auto frameCallback = [callbackState, slot, capturedOwner](const VideoFrame& frame) {
        if (!callbackState->dispatchVideo(frame, capturedOwner, slot->serial, slot->engine)) {
            slot->cancelled.store(true, std::memory_order_release);
        }
    };
    auto stateCallback = [callbackState, slot, capturedOwner](ConnectionState state,
                                                const std::string& message) {
        auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(capturedOwner);
        if (!ownerLease || !callbackState->beginCallback(slot->serial, slot->engine)) {
            return;
        }
        ConnectionStateCallback callback;
        {
            std::lock_guard<std::mutex> lock(callbackState->mutex);
            callbackState->state = state;
            callback = callbackState->stateCallback;
        }
        if (callback) callback(state, message);
        callbackState->endCallback();
    };
    auto cursorCallback = [callbackState, slot, cursorGeneration, capturedOwner](
        const VncCursorProtocol::DecodedCursor& cursor) {
        auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(capturedOwner);
        if (!ownerLease || !callbackState->beginCallback(slot->serial, slot->engine)) {
            return;
        }
        if (cursorGeneration == 0) {
            callbackState->endCallback();
            return;
        }
        callbackState->applyProtocolCursor(cursorGeneration, cursor);
        callbackState->endCallback();
    };
    slot->engine = std::make_shared<VncRfbEngine>(
        cfg, std::move(frameCallback), std::move(stateCallback),
        std::move(cursorCallback));
    {
        std::lock_guard<std::mutex> lifecycleLock(lifecycleMutex_);
        if (connectionSerial_.load(std::memory_order_acquire) != connectionSerial) {
            slot->cancelled.store(true, std::memory_order_release);
        } else {
            if (impl_->startingSlot) {
                impl_->startingSlot->cancelled.store(true, std::memory_order_release);
            }
            impl_->startingSlot = slot;
        }
    }
    if (slot->cancelled.load(std::memory_order_acquire)) {
        stopEngine(slot->engine);
        return -16;
    }

    int result = -12;
#ifdef RDP_NATIVE_CALLBACK_TESTING
    std::function<int(VncRfbEngine&)> startHook;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        startHook = impl_->engineStartHook;
    }
    result = startHook ? startHook(*slot->engine) : slot->engine->start();
#else
    result = slot->engine->start();
#endif
    slot->startFinished.store(true, std::memory_order_release);

    bool install = false;
    std::shared_ptr<VncRfbEngine> staleEngine;
    {
        std::lock_guard<std::mutex> lifecycleLock(lifecycleMutex_);
        if (impl_->startingSlot == slot) {
            impl_->startingSlot.reset();
            if (result == 0 &&
                connectionSerial_.load(std::memory_order_acquire) == connectionSerial &&
                !slot->cancelled.load(std::memory_order_acquire)) {
                std::lock_guard<std::mutex> lock(impl_->mutex);
                if (!impl_->engine) {
                    impl_->engine = slot->engine;
                    {
                        std::lock_guard<std::mutex> stateLock(callbackState->mutex);
                        callbackState->activeEngine = slot->engine;
                    }
                    slot->state.store(StartingSlot::State::ActiveWritable,
                                      std::memory_order_release);
                    install = true;
                }
            }
            if (!install) {
                staleEngine = slot->engine;
            }
        } else if (result == 0) {
            staleEngine = slot->engine;
        }
    }
    if (staleEngine) {
        stopEngine(staleEngine);
    }
    if (!install) {
        return result == 0 ? -16 : result;
    }
    if (connectingCallback) {
        connectingCallback(ConnectionState::CONNECTING, "VNC 正在连接");
    }
    return result;
}

void VncAdapter::disconnect() {
    const uint64_t serial = connectionSerial_.fetch_add(1, std::memory_order_acq_rel) + 1;
    impl_->callbackState->serial.store(serial, std::memory_order_release);
    std::shared_ptr<VncRfbEngine> engine;
    std::shared_ptr<VncRfbEngine> startingEngine;
    ConnectionStateCallback callback;
    {
        std::lock_guard<std::mutex> lifecycleLock(lifecycleMutex_);
        engine = detachEngineLocked(callback);
        if (impl_->startingSlot) {
            impl_->startingSlot->cancelled.store(true, std::memory_order_release);
            if (impl_->startingSlot->startFinished.load(std::memory_order_acquire)) {
                startingEngine = impl_->startingSlot->engine;
                impl_->startingSlot.reset();
            }
        }
    }
    {
        std::lock_guard<std::mutex> stateLock(impl_->callbackState->mutex);
        impl_->callbackState->activeEngine.reset();
        impl_->callbackState->state = ConnectionState::DISCONNECTED;
    }
    auto stopEngine = [](const std::shared_ptr<VncRfbEngine>& target) {
        if (!target) return;
        if (target->isWorkerThread() ||
            !target->stopWithin(std::chrono::milliseconds(500))) {
            VncRfbEngine::deferStopAndJoin(target);
        }
    };
    stopEngine(engine);
    stopEngine(startingEngine);
    if (callback) {
        callback(ConnectionState::DISCONNECTED, "VNC 已断开");
    }
}

std::shared_ptr<VncRfbEngine> VncAdapter::detachEngineLocked(
    ConnectionStateCallback& callback) {
    std::shared_ptr<VncRfbEngine> engine;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        engine = std::move(impl_->engine);
        impl_->state = ConnectionState::DISCONNECTED;
        if (impl_->cursorGeneration != 0) {
            impl_->callbackState->cursorStore.setVisibleIfGeneration(
                impl_->cursorGeneration, false);
        }
        callback = impl_->stateCallback;
    }
    return engine;
}

std::shared_ptr<VncRfbEngine> VncAdapter::detachStartingEngineLocked() {
    if (!impl_->startingSlot) {
        return nullptr;
    }
    impl_->startingSlot->cancelled.store(true, std::memory_order_release);
    if (!impl_->startingSlot->startFinished.load(std::memory_order_acquire)) {
        return nullptr;
    }
    const auto engine = impl_->startingSlot->engine;
    impl_->startingSlot.reset();
    return engine;
}

bool VncAdapter::acceptsStartingSlot(const std::shared_ptr<StartingSlot>& slot) {
    if (!slot || slot->cancelled.load(std::memory_order_acquire)) {
        return false;
    }
    std::lock_guard<std::mutex> lifecycleLock(lifecycleMutex_);
    if (connectionSerial_.load(std::memory_order_acquire) != slot->serial) {
        return false;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->startingSlot == slot) {
        return slot->state.load(std::memory_order_acquire) ==
            StartingSlot::State::ActiveWritable;
    }
    return impl_->engine && impl_->engine == slot->engine &&
        slot->state.load(std::memory_order_acquire) ==
            StartingSlot::State::ActiveWritable;
}

ConnectionState VncAdapter::getState() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->engine) return impl_->engine->state();
    return impl_->state;
}

void VncAdapter::sendKey(uint32_t scancode, bool pressed) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->engine) impl_->engine->sendKey(scancode, pressed);
}
void VncAdapter::sendMouse(int x, int y, MouseButton button, bool pressed) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->engine) {
        impl_->engine->sendMouse(x, y, button, pressed);
        if (!impl_->config.vncViewOnly &&
            impl_->engine->state() == ConnectionState::CONNECTED &&
            impl_->cursorGeneration != 0) {
            impl_->callbackState->updatePredictedCursorPosition(
                impl_->cursorGeneration, x, y);
        }
    }
}
void VncAdapter::sendMouseWheel(int x, int y, int delta) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->engine) {
        impl_->engine->sendMouseWheel(x, y, delta);
        if (!impl_->config.vncViewOnly &&
            impl_->engine->state() == ConnectionState::CONNECTED &&
            impl_->cursorGeneration != 0) {
            impl_->callbackState->updatePredictedCursorPosition(
                impl_->cursorGeneration, x, y);
        }
    }
}
void VncAdapter::sendText(const std::string& text) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->engine) impl_->engine->sendText(text);
}

void VncAdapter::sendClipboardData(const uint8_t* data, uint32_t len) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->engine) impl_->engine->sendClipboard(data, len);
}

bool VncAdapter::supportsCodec(CodecType codec) {
    return codec == CodecType::RAW_BGRA;
}
std::vector<CodecType> VncAdapter::supportedCodecs() {
    return {CodecType::RAW_BGRA};
}
void VncAdapter::setVideoCallback(VideoFrameCallback cb) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->videoCallback = cb;
    std::lock_guard<std::mutex> stateLock(impl_->callbackState->mutex);
    impl_->callbackState->videoCallback = std::move(cb);
}

void VncAdapter::dispatchVideoFrame(
    const VideoFrame& frame, const Render::DecoderSessionIdentity& capturedOwner) {
    (void)impl_->callbackState->dispatchVideo(frame, capturedOwner);
}

#ifdef RDP_NATIVE_CALLBACK_TESTING
void VncAdapter::InvokeVideoCallbackForTesting(const VideoFrame& frame) {
    Render::DecoderSessionIdentity owner;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        owner = impl_->owner;
    }
    dispatchVideoFrame(frame, owner);
}

bool VncAdapter::InvokeEngineVideoCallbackForTesting(
    const VideoFrame& frame, const Render::DecoderSessionIdentity& capturedOwner) {
    auto callbackState = impl_->callbackState;
    VncRfbEngine engine(
        ConnectionConfig {},
        [callbackState, capturedOwner](const VideoFrame& emitted) {
            callbackState->dispatchVideo(emitted, capturedOwner);
        },
        nullptr, nullptr);
    return engine.invokeFrameCallbackForTesting(frame);
}

bool VncAdapter::InvokeLateFrameAfterCallbackStateInvalidationForTesting(
    const VideoFrame& frame, const Render::DecoderSessionIdentity& capturedOwner) {
    auto state = impl_->callbackState;
    auto writes = std::make_shared<std::atomic<int>>(0);
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->videoCallback = [writes](const VideoFrame&) {
            writes->fetch_add(1, std::memory_order_relaxed);
        };
    }
    auto engine = std::make_shared<VncRfbEngine>(
        ConnectionConfig {},
        [state, capturedOwner](const VideoFrame& emitted) {
            (void)state->dispatchVideo(emitted, capturedOwner);
        },
        nullptr, nullptr);
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->activeEngine = engine;
    }
    // This is the same invalidation performed before adapter destruction. The
    // engine then injects a late production frame entry while retaining only
    // the independent callback state.
    state->invalidate();
    (void)engine->invokeFrameCallbackForTesting(frame);
    return writes->load(std::memory_order_acquire) == 0;
}

bool VncAdapter::StartSelfStoppingEngineForTesting() {
    auto callbackRequested = std::make_shared<std::promise<void>>();
    std::future<void> request = callbackRequested->get_future();
    auto callbackCompleted = std::make_shared<std::promise<void>>();
    std::future<void> completion = callbackCompleted->get_future();
    auto releaseCallback = std::make_shared<std::atomic<bool>>(false);
    auto reentrantDisconnectCalled = std::make_shared<std::atomic<bool>>(false);
    auto releaseMutex = std::make_shared<std::mutex>();
    auto releaseCv = std::make_shared<std::condition_variable>();
    Render::DecoderSessionIdentity owner;
    VncRfbEngine* raw = nullptr;
    {
        std::lock_guard<std::mutex> lifecycleLock(lifecycleMutex_);
        std::lock_guard<std::mutex> lock(impl_->mutex);
        owner = impl_->owner;
        if (impl_->engine) return false;
        auto callbackState = impl_->callbackState;
        auto engine = std::make_shared<VncRfbEngine>(
            ConnectionConfig {},
            [callbackState, owner](const VideoFrame& frame) {
                callbackState->dispatchVideo(frame, owner);
            },
            nullptr, nullptr);
        raw = engine.get();
        impl_->engine = std::move(engine);
    }
    // Keep the lifecycle lock out of the production-engine start boundary.
    // The callback intentionally disconnects immediately, so this is also a
    // deterministic regression for the old lock -> engine callback cycle.
    if (raw->startWorkerForTesting(
            [this, callbackRequested, callbackCompleted, releaseCallback,
             reentrantDisconnectCalled, releaseMutex, releaseCv]() {
                callbackRequested->set_value();
                reentrantDisconnectCalled->store(true, std::memory_order_release);
                // Exercise the production worker -> adapter disconnect edge;
                // VncAdapter::disconnect must move the engine to the owned
                // reaper without trying to join this worker inline.
                this->disconnect();
                std::unique_lock<std::mutex> lock(*releaseMutex);
                releaseCv->wait_for(lock, std::chrono::seconds(1), [&]() {
                    return releaseCallback->load(std::memory_order_acquire);
                });
                callbackCompleted->set_value();
            }) != 0) {
        std::shared_ptr<VncRfbEngine> failedEngine;
        {
            std::lock_guard<std::mutex> lifecycleLock(lifecycleMutex_);
            std::lock_guard<std::mutex> lock(impl_->mutex);
            if (impl_->engine.get() == raw) {
                failedEngine = impl_->engine;
                impl_->engine.reset();
            }
        }
        if (failedEngine) {
            failedEngine->stop();
        }
        return false;
    }
    // The worker callback is a production-engine callback but deliberately
    // does not retain `this`. The caller races the real two-phase detach with
    // that callback, then a bounded releaser lets the worker finish. This
    // proves the lifecycle mutex is not held across stop/join without making
    // the test depend on an unbounded wait or a dangling adapter pointer.
    const bool callbackStarted =
        request.wait_for(std::chrono::seconds(1)) == std::future_status::ready;
    std::thread releaser([releaseCallback, releaseMutex, releaseCv]() {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        releaseCallback->store(true, std::memory_order_release);
        std::lock_guard<std::mutex> lock(*releaseMutex);
        releaseCv->notify_all();
    });
    disconnect();
    releaser.join();
    const bool callbackFinished =
        completion.wait_for(std::chrono::seconds(1)) == std::future_status::ready;
    return callbackStarted && callbackFinished &&
        reentrantDisconnectCalled->load(std::memory_order_acquire);
}

void VncAdapter::SetEngineStartHookForTesting(
    std::function<int(VncRfbEngine&)> hook) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->engineStartHook = std::move(hook);
}

void VncAdapter::InvokeProtocolCursorCallbackForTesting(
    const VncCursorProtocol::DecodedCursor& cursor) {
    uint64_t generation = 0;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        generation = impl_->cursorGeneration;
    }
    impl_->callbackState->applyProtocolCursor(generation, cursor);
}

void VncAdapter::UpdatePredictedCursorPositionForTesting(int x, int y) {
    uint64_t generation = 0;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        generation = impl_->cursorGeneration;
    }
    impl_->callbackState->updatePredictedCursorPosition(generation, x, y);
}
#endif

void VncAdapter::setAudioCallback(AudioDataCallback cb) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->audioCallback = cb;
    std::lock_guard<std::mutex> stateLock(impl_->callbackState->mutex);
    impl_->callbackState->audioCallback = std::move(cb);
}
void VncAdapter::setConnectionStateCallback(ConnectionStateCallback cb) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->stateCallback = cb;
    std::lock_guard<std::mutex> stateLock(impl_->callbackState->mutex);
    impl_->callbackState->stateCallback = std::move(cb);
}
void VncAdapter::requestFrameRefresh() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->engine) impl_->engine->requestFrameRefresh();
}
std::string VncAdapter::getClipboardText() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->engine ? impl_->engine->clipboardText() : "";
}
bool VncAdapter::isClipboardReceiveReady() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->engine && impl_->engine->clipboardReady();
}
bool VncAdapter::supportsNatTraversal() { return false; }
bool VncAdapter::supportsFileTransfer() { return false; }

void registerVncAdapter() {
    ExtensionSystem::instance().protocols.registerExt("protocol", "vnc", std::shared_ptr<VncAdapter>(new VncAdapter()));
    OH_LOG_INFO(LOG_APP, "[VNC] VNC 适配器已注册到扩展系统");
}
