/**
 * clipboard_bridge.h — 剪贴板桥接
 *
 * 本地 ↔ 远程剪贴板同步。
 * 使用 HarmonyOS pasteboard API 读写系统剪贴板。
 */

#include <napi/native_api.h>
#ifndef CLIPBOARD_BRIDGE_H
#define CLIPBOARD_BRIDGE_H

#include <functional>
#include <mutex>
#include <string>

using ClipboardChangeCallback = std::function<void(const std::string& text)>;

class ClipboardBridge {
public:
    static ClipboardBridge& instance();

    std::string getText();
    void setText(const std::string& text);
    void startMonitoring(ClipboardChangeCallback callback);
    void stopMonitoring();
    bool isMonitoring() const { return monitoring_; }

private:
    ClipboardBridge();
    ~ClipboardBridge();
    bool monitoring_ = false;
    std::string cachedText_;
    mutable std::mutex mutex_;
};

namespace ClipboardBridgeNapi {
    napi_value Init(napi_env env, napi_value exports);
}

#endif // CLIPBOARD_BRIDGE_H
