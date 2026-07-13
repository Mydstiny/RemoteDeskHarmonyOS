/**
 * napi_init.cpp — NAPI 模块入口
 *
 * 鸿蒙 NAPI 模块注册入口，初始化所有 Native 子系统。
 * 通过 NAPI_MODULE 宏将 rdpnapi 模块暴露给 ArkTS 层。
 *
 * 架构：
 *   每个子系统 (Renderer, Decoder, Audio, Input, Security, ExtensionLoader)
 *   都有独立的 *Napi 类，通过静态 Init() 方法注册 NAPI 函数。
 *
 * ArkTS 侧调用方式：
 *   import rdpnapi from 'librdpnapi.so';
 *   rdpnapi.listProtocols();
 *   rdpnapi.initRenderer(...);
 */

#include <napi/native_api.h>
#include <hilog/log.h>
#include "terminal/terminal_core_napi.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0000
#define LOG_TAG "RDP_NAPI"

// 前向声明各子系统 NAPI 初始化函数
namespace RendererNapi {
    napi_value Init(napi_env env, napi_value exports);
}
namespace DecoderNapi {
    napi_value Init(napi_env env, napi_value exports);
}
namespace AudioPlayerNapi {
    napi_value Init(napi_env env, napi_value exports);
}
namespace AudioCapturerNapi {
    napi_value Init(napi_env env, napi_value exports);
}
namespace InputHandlerNapi {
    napi_value Init(napi_env env, napi_value exports);
}
namespace ClipboardBridgeNapi {
    napi_value Init(napi_env env, napi_value exports);
}
namespace ExtensionLoaderNapi {
    napi_value Init(napi_env env, napi_value exports);
}
namespace SecurityNapi {
    napi_value Init(napi_env env, napi_value exports);
}

// ============================================================
// Helper: 导出常量
// ============================================================

/**
 * 设置导出的整型属性
 */
static void SetIntProperty(napi_env env, napi_value obj,
                           const char* name, int32_t value) {
    napi_value napiValue;
    napi_create_int32(env, value, &napiValue);
    napi_set_named_property(env, obj, name, napiValue);
}

/**
 * 设置导出的字符串属性
 */
static void SetStringProperty(napi_env env, napi_value obj,
                              const char* name, const char* value) {
    napi_value napiValue;
    napi_create_string_utf8(env, value, NAPI_AUTO_LENGTH, &napiValue);
    napi_set_named_property(env, obj, name, napiValue);
}

/**
 * 导出 SDK 版本信息
 */
static napi_value InitVersionInfo(napi_env env, napi_value exports) {
    napi_value versionObj;
    napi_create_object(env, &versionObj);

    SetStringProperty(env, versionObj, "moduleName", "rdpnapi");
    SetStringProperty(env, versionObj, "version", "1.0.0");
    SetIntProperty(env, versionObj, "apiVersion", 20);
#ifdef NDEBUG
    SetStringProperty(env, versionObj, "buildType", "release");
#else
    SetStringProperty(env, versionObj, "buildType", "debug");
#endif

    napi_set_named_property(env, exports, "VERSION", versionObj);

    OH_LOG_INFO(LOG_APP, "[NAPI] rdpnapi 模块已加载, 版本 1.0.0");
    return exports;
}

// ============================================================
// NAPI 模块入口
// ============================================================

/**
 * 主初始化函数 — 注册所有子系统的 NAPI 方法
 */
static napi_value Init(napi_env env, napi_value exports) {
    OH_LOG_INFO(LOG_APP, "[NAPI] 初始化 rdpnapi 模块...");

    // 导出版本信息
    InitVersionInfo(env, exports);

    // ---- 初始化各子系统 NAPI ----
    // 每个子系统的 Init() 会向 exports 添加自己的 NAPI 方法

    // 扩展加载器 (协议列表、连接管理)
    ExtensionLoaderNapi::Init(env, exports);
    OH_LOG_INFO(LOG_APP, "[NAPI] ExtensionLoader 已注册");

    // 渲染管线
    RendererNapi::Init(env, exports);
    OH_LOG_INFO(LOG_APP, "[NAPI] Renderer 已注册");

    DecoderNapi::Init(env, exports);
    OH_LOG_INFO(LOG_APP, "[NAPI] Decoder 已注册");

    // 音频管线
    AudioPlayerNapi::Init(env, exports);
    OH_LOG_INFO(LOG_APP, "[NAPI] AudioPlayer 已注册");

    AudioCapturerNapi::Init(env, exports);
    OH_LOG_INFO(LOG_APP, "[NAPI] AudioCapturer 已注册");

    // 输入处理
    InputHandlerNapi::Init(env, exports);
    OH_LOG_INFO(LOG_APP, "[NAPI] InputHandler 已注册");

    // 剪贴板桥接
    ClipboardBridgeNapi::Init(env, exports);
    OH_LOG_INFO(LOG_APP, "[NAPI] ClipboardBridge 已注册");

    // 安全管理
    SecurityNapi::Init(env, exports);
    OH_LOG_INFO(LOG_APP, "[NAPI] Security 已注册");

    // 终端核心 (Rust terminal_core bridge)
    TerminalCoreNapi::Init(env, exports);
    OH_LOG_INFO(LOG_APP, "[NAPI] TerminalCore 已注册");

    OH_LOG_INFO(LOG_APP, "[NAPI] rdpnapi 模块初始化完成");
    return exports;
}

// NAPI 模块声明 — 此宏定义了 napi_module_register() 函数
NAPI_MODULE(rdpnapi, Init)
