/**
 * input_handler.h — 统一输入处理器
 *
 * 将鸿蒙键盘/鼠标/触控事件统一映射到 ProtocolAdapter 接口。
 * 触控手势映射: 单指=左键, 双指=右键, 捏合=Ctrl+滚轮
 */

#include <napi/native_api.h>
#ifndef INPUT_HANDLER_H
#define INPUT_HANDLER_H

#include "extensions/protocol_adapter.h"
#include <cstdint>
#include <memory>

class InputHandler {
public:
    static InputHandler& instance();

    /** 设置当前活跃的协议适配器 (会话切换时调用) */
    void setActiveAdapter(std::shared_ptr<ProtocolAdapter> adapter);

    /** 键盘事件 */
    void handleKeyEvent(uint32_t scancode, bool pressed, uint32_t keyCode, uint32_t modifiers);

    /** 鼠标事件 */
    void handleMouseEvent(int x, int y, int button, bool pressed, int wheelDelta);

    /** 触控事件 (多点触控手势识别) */
    void handleTouchEvent(int pointerCount, const int* x, const int* y, int action);

private:
    InputHandler() = default;
    std::shared_ptr<ProtocolAdapter> activeAdapter_;
};

namespace InputHandlerNapi {
    napi_value Init(napi_env env, napi_value exports);
}

#endif // INPUT_HANDLER_H
