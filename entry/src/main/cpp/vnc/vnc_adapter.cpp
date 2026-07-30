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
#include <utility>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0008
#define LOG_TAG "VNC_ADAPTER"

namespace {

std::atomic<uint64_t> g_nextVncCursorGeneration {1};

} // namespace

struct VncAdapter::Impl {
    ConnectionConfig config;
    ConnectionState state = ConnectionState::DISCONNECTED;
    VideoFrameCallback videoCallback;
    AudioDataCallback audioCallback;
    ConnectionStateCallback stateCallback;
    std::unique_ptr<VncRfbEngine> engine;
    std::mutex mutex;
    uint64_t sessionId = 0;
    uint64_t cursorGeneration = 0;
    RemoteCursorStore cursorStore;
};

VncAdapter::VncAdapter() : impl_(std::make_unique<Impl>()) {
    OH_LOG_INFO(LOG_APP, "[VNC] VncAdapter 已创建");
}
VncAdapter::~VncAdapter() {
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
    impl_->cursorStore.reset(sessionId, "vnc", generation);
    impl_->cursorStore.setFallbackShape();
    impl_->cursorStore.setVisible(true);
}

RemoteCursorSnapshot VncAdapter::getRemoteCursorSnapshot(bool includePixels) {
    return impl_->cursorStore.snapshot(includePixels);
}

int VncAdapter::connect(const ConnectionConfig& cfg) {
    std::lock_guard<std::mutex> lifecycleLock(lifecycleMutex_);
    disconnectLocked();
    uint64_t cursorGeneration = 0;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->config = cfg;
        impl_->state = ConnectionState::CONNECTING;
        if (impl_->cursorGeneration == 0) {
            impl_->cursorGeneration =
                g_nextVncCursorGeneration.fetch_add(1, std::memory_order_relaxed);
            impl_->cursorStore.reset(impl_->sessionId, "vnc", impl_->cursorGeneration);
            impl_->cursorStore.setFallbackShape();
        }
        cursorGeneration = impl_->cursorGeneration;
        impl_->cursorStore.setVisible(true);
    }
    ConnectionStateCallback connectingCallback;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        connectingCallback = impl_->stateCallback;
    }
    if (connectingCallback) connectingCallback(ConnectionState::CONNECTING, "VNC 正在连接");
    auto frameCallback = [this](const VideoFrame& frame) {
        VideoFrameCallback callback;
        {
            std::lock_guard<std::mutex> lock(impl_->mutex);
            callback = impl_->videoCallback;
        }
        if (callback) callback(frame);
    };
    auto stateCallback = [this](ConnectionState state, const std::string& message) {
        ConnectionStateCallback callback;
        {
            std::lock_guard<std::mutex> lock(impl_->mutex);
            impl_->state = state;
            callback = impl_->stateCallback;
        }
        if (callback) callback(state, message);
    };
    auto cursorCallback = [this, cursorGeneration](
        const VncCursorProtocol::DecodedCursor& cursor) {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (cursorGeneration == 0 || impl_->cursorGeneration != cursorGeneration) {
            return;
        }
        if (!cursor.visible) {
            impl_->cursorStore.setVisibleIfGeneration(cursorGeneration, false);
            return;
        }
        if (impl_->cursorStore.setShapeIfGeneration(
                cursorGeneration, cursor.shapeId, cursor.width, cursor.height,
                cursor.hotX, cursor.hotY, cursor.rgba)) {
            impl_->cursorStore.setVisibleIfGeneration(cursorGeneration, true);
        }
    };
    auto engine = std::make_unique<VncRfbEngine>(
        cfg, std::move(frameCallback), std::move(stateCallback),
        std::move(cursorCallback));
    VncRfbEngine* engineAddress = engine.get();
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->engine = std::move(engine);
    }
    // Keep lifecycleMutex_ held while start() runs.  A callback may report an
    // early error, but a concurrent disconnect cannot move the engine out from
    // under this start operation.
    const int result = engineAddress->start();
    if (result != 0) {
        std::unique_ptr<VncRfbEngine> failedEngine;
        {
            std::lock_guard<std::mutex> lock(impl_->mutex);
            impl_->state = ConnectionState::ERROR;
            if (impl_->engine.get() == engineAddress) failedEngine = std::move(impl_->engine);
        }
        if (failedEngine) failedEngine->stop();
        return result;
    }
    return 0;
}

void VncAdapter::disconnect() {
    std::lock_guard<std::mutex> lifecycleLock(lifecycleMutex_);
    disconnectLocked();
}

void VncAdapter::disconnectLocked() {
    std::unique_ptr<VncRfbEngine> engine;
    ConnectionStateCallback callback;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        engine = std::move(impl_->engine);
        impl_->state = ConnectionState::DISCONNECTED;
        if (impl_->cursorGeneration != 0) {
            impl_->cursorStore.setVisibleIfGeneration(
                impl_->cursorGeneration, false);
        }
        callback = impl_->stateCallback;
    }
    if (engine) engine->stop();
    if (callback) callback(ConnectionState::DISCONNECTED, "VNC 已断开");
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
            impl_->cursorStore.setPositionIfGeneration(
                impl_->cursorGeneration, x, y);
            impl_->cursorStore.setVisibleIfGeneration(
                impl_->cursorGeneration, true);
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
            impl_->cursorStore.setPositionIfGeneration(
                impl_->cursorGeneration, x, y);
            impl_->cursorStore.setVisibleIfGeneration(
                impl_->cursorGeneration, true);
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
    impl_->videoCallback = std::move(cb);
}
void VncAdapter::setAudioCallback(AudioDataCallback cb) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->audioCallback = std::move(cb);
}
void VncAdapter::setConnectionStateCallback(ConnectionStateCallback cb) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->stateCallback = std::move(cb);
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
