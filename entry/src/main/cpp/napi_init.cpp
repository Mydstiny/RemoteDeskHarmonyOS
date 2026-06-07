#include <napi/native_api.h>
#include "extensions/extension_registry.h"

// NAPI 桥接层初始化 — Phase 3/5 桩代码
// 各 Init() 函数将在 Phase 5 填充完整的 NAPI 绑定逻辑
namespace ProtocolBridgeNapi {
napi_value Init(napi_env env, napi_value exports) {
    // Phase 3 实现：注册 ProtocolAdapter 的 NAPI 绑定
    return exports;
}
}

namespace RendererNapi {
napi_value Init(napi_env env, napi_value exports) {
    // Phase 5 实现：暴露 gl_renderer / hw_decoder 到 ArkTS
    return exports;
}
}

namespace AudioNapi {
napi_value Init(napi_env env, napi_value exports) {
    // Phase 5 实现：暴露 AudioPlayer 播放控制到 ArkTS
    return exports;
}
}

namespace SecurityNapi {
napi_value Init(napi_env env, napi_value exports) {
    // Phase 5 实现：暴露 HostLocker / crypto_utils 到 ArkTS
    return exports;
}
}

namespace ExtensionLoaderNapi {
napi_value Init(napi_env env, napi_value exports) {
    // Phase 5 实现：暴露 ExtensionSystem 动态加载接口到 ArkTS
    return exports;
}
}

static napi_value Init(napi_env env, napi_value exports) {
    ExtensionSystem::instance();
    ProtocolBridgeNapi::Init(env, exports);
    RendererNapi::Init(env, exports);
    AudioNapi::Init(env, exports);
    SecurityNapi::Init(env, exports);
    ExtensionLoaderNapi::Init(env, exports);
    return exports;
}

NAPI_MODULE(rdpnapi, Init)
