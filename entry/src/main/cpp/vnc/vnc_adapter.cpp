/**
 * vnc_adapter.cpp — VNC 协议适配器 Mock 实现
 *
 * VNC 协议：默认端口 5900+N (display N)，支持 Tight/ZRLE 编码。
 * 当前为 Mock 实现。
 */

#include "vnc_adapter.h"
#include "common/safe_log.h"
#include "extensions/extension_registry.h"
#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0008
#define LOG_TAG "VNC_ADAPTER"

struct VncAdapter::Impl {
    ConnectionConfig config;
    ConnectionState state = ConnectionState::DISCONNECTED;
    VideoFrameCallback videoCallback;
    AudioDataCallback audioCallback;
    ConnectionStateCallback stateCallback;
};

VncAdapter::VncAdapter() : impl_(std::make_unique<Impl>()) {
    OH_LOG_INFO(LOG_APP, "[VNC] VncAdapter 已创建");
}
VncAdapter::~VncAdapter() {
    if (impl_->state == ConnectionState::CONNECTED) disconnect();
    OH_LOG_INFO(LOG_APP, "[VNC] VncAdapter 已销毁");
}

std::string VncAdapter::protocolName() { return "VNC"; }
int VncAdapter::defaultPort() { return 5900; }
std::string VncAdapter::protocolVersion() { return "unsupported"; }

int VncAdapter::connect(const ConnectionConfig& cfg) {
    OH_LOG_WARN(LOG_APP, "[VNC] connect rejected: protocol is not supported");
    impl_->config = cfg;
    impl_->state = ConnectionState::DISCONNECTED;
    if (impl_->stateCallback) impl_->stateCallback(ConnectionState::DISCONNECTED, "VNC is not supported");
    return -95;
}

void VncAdapter::disconnect() {
    impl_->state = ConnectionState::DISCONNECTED;
    if (impl_->stateCallback) impl_->stateCallback(ConnectionState::DISCONNECTED, "已断开");
}

ConnectionState VncAdapter::getState() { return impl_->state; }

void VncAdapter::sendKey(uint32_t scancode, bool pressed) {
    OH_LOG_DEBUG(LOG_APP, "[VNC] 按键: sc=%{public}u pressed=%{public}s", scancode, pressed ? "t" : "f");
}
void VncAdapter::sendMouse(int x, int y, MouseButton button, bool pressed) {
    OH_LOG_DEBUG(LOG_APP, "[VNC] 鼠标: (%{public}d,%{public}d) btn=%{public}d", x, y, (int)button);
}
void VncAdapter::sendMouseWheel(int x, int y, int delta) {
    OH_LOG_DEBUG(LOG_APP, "[VNC] 滚轮: delta=%{public}d", delta);
}
void VncAdapter::sendText(const std::string& text) {
    OH_LOG_DEBUG(LOG_APP, "[VNC] 文本输入: %{public}s", SafeLog::MaskSecretLenOnly(text).c_str());
}

bool VncAdapter::supportsCodec(CodecType codec) {
    (void)codec;
    return false;
}
std::vector<CodecType> VncAdapter::supportedCodecs() {
    return {};
}
void VncAdapter::setVideoCallback(VideoFrameCallback cb) { impl_->videoCallback = std::move(cb); }
void VncAdapter::setAudioCallback(AudioDataCallback cb) { impl_->audioCallback = std::move(cb); }
void VncAdapter::setConnectionStateCallback(ConnectionStateCallback cb) { impl_->stateCallback = std::move(cb); }
bool VncAdapter::supportsNatTraversal() { return false; }
bool VncAdapter::supportsFileTransfer() { return false; }

void registerVncAdapter() {
    ExtensionSystem::instance().protocols.registerExt("protocol", "vnc", std::shared_ptr<VncAdapter>(new VncAdapter()));
    OH_LOG_INFO(LOG_APP, "[VNC] VNC 适配器已注册到扩展系统");
}
