/**
 * clipboard_bridge.cpp — 系统剪贴板桥接
 *
 * R5: 基础实现。完整 OH_Pasteboard+UDMF 集成 TODO (需要 udmf.h 头文件支持)。
 */

#include "clipboard_bridge.h"
#include <napi/native_api.h>
#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0013
#define LOG_TAG "CLIPBOARD"

// ============================================================
// ClipboardBridge 实现
// ============================================================

ClipboardBridge& ClipboardBridge::instance() {
    static ClipboardBridge bridge;
    return bridge;
}

ClipboardBridge::ClipboardBridge() {
    OH_LOG_INFO(LOG_APP, "[Clipboard] ClipboardBridge created");
}

ClipboardBridge::~ClipboardBridge() {
    stopMonitoring();
}

std::string ClipboardBridge::getText() {
    // TODO: OH_Pasteboard_GetData + UDMF 文本提取
    // OH_UdmfData* data = OH_Pasteboard_GetData(pasteboard_, &status);
    // OH_UdmfData_GetRecord(data, 0) → OH_UdmfRecord_GetType → OH_UdmfText_GetText
    std::lock_guard<std::mutex> lk(mutex_);
    return cachedText_;
}

void ClipboardBridge::setText(const std::string& text) {
    // TODO: OH_Pasteboard_SetData + UDMF 文本创建
    // OH_UdmfData* data = OH_UdmfData_Create();
    // OH_UdmfText* textObj = OH_UdmfText_Create(text.c_str());
    // OH_UdmfData_AddRecord(data, textObj);
    // OH_Pasteboard_SetData(pasteboard_, data);
    {
        std::lock_guard<std::mutex> lk(mutex_);
        cachedText_ = text;
    }
    OH_LOG_DEBUG(LOG_APP, "[Clipboard] setText: %{public}zu chars (cached)", text.size());
}

void ClipboardBridge::startMonitoring(ClipboardChangeCallback callback) {
    // TODO: OH_Pasteboard 系统级监听 (需系统权限或 observer API)
    monitoring_ = true;
    OH_LOG_INFO(LOG_APP, "[Clipboard] ✓ Monitoring started (callback-based)");
}

void ClipboardBridge::stopMonitoring() {
    monitoring_ = false;
}

// ============================================================
// NAPI 包装
// ============================================================

namespace {

napi_value NapiGetClipboardText(napi_env env, napi_callback_info info) {
    std::string text = ClipboardBridge::instance().getText();
    napi_value result;
    napi_create_string_utf8(env, text.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

napi_value NapiSetClipboardText(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char text[4096] = {0};
    napi_get_value_string_utf8(env, args[0], text, sizeof(text), nullptr);
    ClipboardBridge::instance().setText(text);
    napi_value u; napi_get_undefined(env, &u); return u;
}

napi_value NapiStartClipboardMonitor(napi_env env, napi_callback_info info) {
    ClipboardBridge::instance().startMonitoring(nullptr);
    napi_value u; napi_get_undefined(env, &u); return u;
}

napi_value NapiStopClipboardMonitor(napi_env env, napi_callback_info info) {
    ClipboardBridge::instance().stopMonitoring();
    napi_value u; napi_get_undefined(env, &u); return u;
}
}

napi_value ClipboardBridgeNapi::Init(napi_env env, napi_value exports) {
    napi_value fn;
    napi_create_function(env, "getClipboardText", NAPI_AUTO_LENGTH, NapiGetClipboardText, nullptr, &fn);
    napi_set_named_property(env, exports, "getClipboardText", fn);
    napi_create_function(env, "setClipboardText", NAPI_AUTO_LENGTH, NapiSetClipboardText, nullptr, &fn);
    napi_set_named_property(env, exports, "setClipboardText", fn);
    napi_create_function(env, "startClipboardMonitor", NAPI_AUTO_LENGTH, NapiStartClipboardMonitor, nullptr, &fn);
    napi_set_named_property(env, exports, "startClipboardMonitor", fn);
    napi_create_function(env, "stopClipboardMonitor", NAPI_AUTO_LENGTH, NapiStopClipboardMonitor, nullptr, &fn);
    napi_set_named_property(env, exports, "stopClipboardMonitor", fn);
    return exports;
}
