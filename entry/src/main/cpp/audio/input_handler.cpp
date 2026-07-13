/**
 * input_handler.cpp — 统一输入处理器 Mock 实现 + NAPI 包装
 */

#include "input_handler.h"
#include <napi/native_api.h>
#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0012
#define LOG_TAG "INPUT"

InputHandler& InputHandler::instance() {
    static InputHandler handler;
    return handler;
}

void InputHandler::setActiveAdapter(std::shared_ptr<ProtocolAdapter> adapter) {
    activeAdapter_ = std::move(adapter);
}

void InputHandler::handleKeyEvent(uint32_t scancode, bool pressed, uint32_t keyCode, uint32_t modifiers) {
    OH_LOG_DEBUG(LOG_APP, "[Input] 键盘: scan=%{public}u, code=%{public}u, pressed=%{public}s",
                 scancode, keyCode, pressed ? "down" : "up");
    if (activeAdapter_) activeAdapter_->sendKey(scancode, pressed);
}

void InputHandler::handleMouseEvent(int x, int y, int button, bool pressed, int wheelDelta) {
    if (wheelDelta != 0) {
        if (activeAdapter_) activeAdapter_->sendMouseWheel(x, y, wheelDelta);
    } else {
        if (activeAdapter_) activeAdapter_->sendMouse(x, y, static_cast<MouseButton>(button), pressed);
    }
}

void InputHandler::handleTouchEvent(int pointerCount, const int* x, const int* y, int action) {
    if (pointerCount == 1) {
        handleMouseEvent(x[0], y[0], 0, action == 0, 0);  // 单指=左键
    } else if (pointerCount == 2) {
        handleMouseEvent(x[0], y[0], 2, action == 0, 0);  // 双指=右键
    }
}

// ============================================================
// NAPI 包装
// ============================================================

namespace {

napi_value NapiHandleKeyEvent(napi_env env, napi_callback_info info) {
    size_t argc = 4; napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t scancode, keyCode, modifiers; bool pressed;
    napi_get_value_int32(env, args[0], &scancode);
    napi_get_value_bool(env, args[1], &pressed);
    napi_get_value_int32(env, args[2], &keyCode);
    napi_get_value_int32(env, args[3], &modifiers);
    InputHandler::instance().handleKeyEvent(scancode, pressed, keyCode, modifiers);
    napi_value u; napi_get_undefined(env, &u); return u;
}

napi_value NapiHandleMouseEvent(napi_env env, napi_callback_info info) {
    size_t argc = 5; napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t x, y, button, wheelDelta; bool pressed;
    napi_get_value_int32(env, args[0], &x);
    napi_get_value_int32(env, args[1], &y);
    napi_get_value_int32(env, args[2], &button);
    napi_get_value_bool(env, args[3], &pressed);
    napi_get_value_int32(env, args[4], &wheelDelta);
    InputHandler::instance().handleMouseEvent(x, y, button, pressed, wheelDelta);
    napi_value u; napi_get_undefined(env, &u); return u;
}

napi_value NapiHandleTouchEvent(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    // 简易实现：记录触控事件
    OH_LOG_DEBUG(LOG_APP, "[Input] 触控事件已接收");
    napi_value u; napi_get_undefined(env, &u); return u;
}
}

napi_value InputHandlerNapi::Init(napi_env env, napi_value exports) {
    napi_value fn;
    napi_create_function(env, "handleKeyEvent", NAPI_AUTO_LENGTH, NapiHandleKeyEvent, nullptr, &fn);
    napi_set_named_property(env, exports, "handleKeyEvent", fn);
    napi_create_function(env, "handleMouseEvent", NAPI_AUTO_LENGTH, NapiHandleMouseEvent, nullptr, &fn);
    napi_set_named_property(env, exports, "handleMouseEvent", fn);
    napi_create_function(env, "handleTouchEvent", NAPI_AUTO_LENGTH, NapiHandleTouchEvent, nullptr, &fn);
    napi_set_named_property(env, exports, "handleTouchEvent", fn);
    return exports;
}
