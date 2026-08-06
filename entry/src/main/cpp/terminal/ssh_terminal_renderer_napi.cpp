#include "terminal/ssh_terminal_renderer.h"

#include <napi/native_api.h>

#include <cstdint>
#include <memory>
#include <string>

namespace {
SshTerminalRenderer* GetRenderer(napi_env env, napi_value value) {
    int64_t handle = 0;
    if (value == nullptr || napi_get_value_int64(env, value, &handle) != napi_ok || handle == 0) {
        return nullptr;
    }
    return reinterpret_cast<SshTerminalRenderer*>(handle);
}

bool ReadString(napi_env env, napi_value value, std::string& output) {
    size_t length = 0;
    if (value == nullptr || napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
        return false;
    }
    output.assign(length, '\0');
    return napi_get_value_string_utf8(env, value, output.data(), length + 1, &length) == napi_ok;
}

bool ReadNumber(napi_env env, napi_value value, double& output) {
    return value != nullptr && napi_get_value_double(env, value, &output) == napi_ok;
}

bool ReadBool(napi_env env, napi_value value, bool& output) {
    return value != nullptr && napi_get_value_bool(env, value, &output) == napi_ok;
}

void SetHandleResult(napi_env env, int64_t handle, napi_value* result) {
    napi_create_int64(env, handle, result);
}

napi_value NapiCreate(napi_env env, napi_callback_info info) {
    constexpr size_t kArgCount = 13;
    size_t argc = kArgCount;
    napi_value args[kArgCount] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < kArgCount) {
        napi_value result; SetHandleResult(env, 0, &result); return result;
    }
    std::string surfaceId;
    double values[11] = {};
    bool bottomAlign = false;
    if (!ReadString(env, args[0], surfaceId) || !ReadBool(env, args[12], bottomAlign)) {
        napi_value result; SetHandleResult(env, 0, &result); return result;
    }
    for (size_t index = 1; index <= 11; ++index) {
        if (!ReadNumber(env, args[index], values[index - 1])) {
            napi_value result; SetHandleResult(env, 0, &result); return result;
        }
    }
    auto renderer = std::make_unique<SshTerminalRenderer>();
    const int rc = renderer->Init(surfaceId,
        static_cast<int>(values[0]), static_cast<int>(values[1]),
        static_cast<size_t>(std::max(1.0, values[2])),
        static_cast<size_t>(std::max(1.0, values[3])),
        static_cast<float>(values[4]), static_cast<float>(values[5]),
        static_cast<float>(values[6]), static_cast<uint32_t>(values[7]),
        static_cast<uint32_t>(values[8]), static_cast<float>(values[9]),
        static_cast<float>(values[10]), bottomAlign);
    if (rc != 0) {
        // Preserve only the fatal GPU-flush classification across the NAPI
        // boundary. Other surface setup failures remain retryable and are
        // represented as handle 0 for the bounded ArkTS retry path.
        napi_value result;
        SetHandleResult(env, rc == SshTerminalRenderer::kSurfaceFlushFailure ? rc : 0, &result);
        return result;
    }
    const int64_t handle = reinterpret_cast<int64_t>(renderer.release());
    napi_value result; SetHandleResult(env, handle, &result); return result;
}

napi_value NapiDestroy(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc > 0) {
        delete GetRenderer(env, args[0]);
    }
    napi_value undefined; napi_get_undefined(env, &undefined); return undefined;
}

napi_value NapiBindSurface(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4) { return nullptr; }
    SshTerminalRenderer* renderer = GetRenderer(env, args[0]);
    std::string surfaceId; double width = 0; double height = 0;
    int status = 1;
    if (renderer != nullptr && ReadString(env, args[1], surfaceId) &&
        ReadNumber(env, args[2], width) && ReadNumber(env, args[3], height)) {
        status = renderer->RebindSurface(surfaceId, static_cast<int>(width),
                                          static_cast<int>(height));
    }
    // 0 = success, 1 = bounded retryable surface failure, negative = the
    // latched GPU-flush failure. Keep the native detail private to ArkTS.
    const int exposedStatus = status == SshTerminalRenderer::kSurfaceFlushFailure
        ? status : (status == 0 ? 0 : 1);
    napi_value result;
    napi_create_int32(env, exposedStatus, &result);
    return result;
}

napi_value NapiDetachSurface(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc > 0) {
        SshTerminalRenderer* renderer = GetRenderer(env, args[0]);
        if (renderer != nullptr) {
            renderer->DetachSurface();
        }
    }
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value NapiHasSurfaceFlushFailure(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    SshTerminalRenderer* renderer = argc > 0 ? GetRenderer(env, args[0]) : nullptr;
    const bool failed = renderer != nullptr && renderer->HasSurfaceFlushFailure();
    napi_value result;
    napi_get_boolean(env, failed, &result);
    return result;
}

napi_value NapiWriteBytes(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) { return nullptr; }
    SshTerminalRenderer* renderer = GetRenderer(env, args[0]);
    void* data = nullptr; size_t length = 0;
    if (renderer != nullptr && napi_get_arraybuffer_info(env, args[1], &data, &length) == napi_ok) {
        renderer->WriteBytes(static_cast<const uint8_t*>(data), length);
    }
    napi_value undefined; napi_get_undefined(env, &undefined); return undefined;
}

napi_value NapiRefresh(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool ok = false;
    if (argc > 0) {
        SshTerminalRenderer* renderer = GetRenderer(env, args[0]);
        if (renderer != nullptr) { ok = renderer->Refresh(); }
    }
    napi_value result; napi_get_boolean(env, ok, &result); return result;
}

napi_value NapiResize(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 6) { return nullptr; }
    SshTerminalRenderer* renderer = GetRenderer(env, args[0]);
    double values[5] = {};
    bool valid = renderer != nullptr;
    for (size_t index = 1; index < 6; ++index) {
        valid = valid && ReadNumber(env, args[index], values[index - 1]);
    }
    if (valid) {
        renderer->Resize(static_cast<size_t>(std::max(1.0, values[0])),
                         static_cast<size_t>(std::max(1.0, values[1])),
                         static_cast<float>(values[2]), static_cast<float>(values[3]),
                         static_cast<float>(values[4]));
    }
    napi_value undefined; napi_get_undefined(env, &undefined); return undefined;
}

napi_value NapiAppearance(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4) { return nullptr; }
    SshTerminalRenderer* renderer = GetRenderer(env, args[0]);
    double fontSize = 0; double foreground = 0; double background = 0;
    if (renderer != nullptr && ReadNumber(env, args[1], fontSize) &&
        ReadNumber(env, args[2], foreground) && ReadNumber(env, args[3], background)) {
        renderer->SetAppearance(static_cast<float>(fontSize), static_cast<uint32_t>(foreground),
                                static_cast<uint32_t>(background));
    }
    napi_value undefined; napi_get_undefined(env, &undefined); return undefined;
}

napi_value NapiViewport(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4) { return nullptr; }
    SshTerminalRenderer* renderer = GetRenderer(env, args[0]);
    double viewport = 0; double visible = 0; bool bottom = false;
    if (renderer != nullptr && ReadNumber(env, args[1], viewport) && ReadNumber(env, args[2], visible) &&
        ReadBool(env, args[3], bottom)) {
        renderer->SetViewport(static_cast<float>(viewport), static_cast<float>(visible), bottom);
    }
    napi_value undefined; napi_get_undefined(env, &undefined); return undefined;
}

napi_value NapiScroll(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) { return nullptr; }
    SshTerminalRenderer* renderer = GetRenderer(env, args[0]);
    int64_t lines = 0;
    if (renderer != nullptr && napi_get_value_int64(env, args[1], &lines) == napi_ok) {
        renderer->ScrollView(lines);
    }
    napi_value undefined; napi_get_undefined(env, &undefined); return undefined;
}

napi_value NapiScrollToBottom(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc > 0) {
        SshTerminalRenderer* renderer = GetRenderer(env, args[0]);
        if (renderer != nullptr) { renderer->ScrollToBottom(); }
    }
    napi_value undefined; napi_get_undefined(env, &undefined); return undefined;
}

napi_value NapiContent(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const std::string content = argc > 0 && GetRenderer(env, args[0]) != nullptr
        ? GetRenderer(env, args[0])->Content() : std::string();
    napi_value result; napi_create_string_utf8(env, content.c_str(), content.size(), &result); return result;
}

napi_value NapiMode(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    SshTerminalRenderer::Mode mode {};
    if (argc > 0 && GetRenderer(env, args[0]) != nullptr) {
        mode = GetRenderer(env, args[0])->CurrentMode();
    }
    napi_value result;
    napi_create_object(env, &result);
    auto setBool = [env, result](const char* name, bool value) {
        napi_value v; napi_get_boolean(env, value, &v); napi_set_named_property(env, result, name, v);
    };
    setBool("bracketedPaste", mode.bracketedPaste);
    napi_value mouse; napi_create_uint32(env, mode.mouseTracking, &mouse);
    napi_set_named_property(env, result, "mouseTracking", mouse);
    setBool("sgrMouse", mode.sgrMouse);
    setBool("applicationCursorKeys", mode.applicationCursorKeys);
    setBool("applicationKeypad", mode.applicationKeypad);
    setBool("autoWrap", mode.autoWrap);
    return result;
}
}

namespace SshTerminalRendererNapi {
napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor properties[] = {
        { "sshTerminalRendererCreate", nullptr, NapiCreate, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sshTerminalRendererDestroy", nullptr, NapiDestroy, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sshTerminalRendererBindSurface", nullptr, NapiBindSurface, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sshTerminalRendererDetachSurface", nullptr, NapiDetachSurface, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sshTerminalRendererHasSurfaceFlushFailure", nullptr, NapiHasSurfaceFlushFailure, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sshTerminalRendererWriteBytes", nullptr, NapiWriteBytes, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sshTerminalRendererRefresh", nullptr, NapiRefresh, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sshTerminalRendererResize", nullptr, NapiResize, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sshTerminalRendererSetAppearance", nullptr, NapiAppearance, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sshTerminalRendererSetViewport", nullptr, NapiViewport, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sshTerminalRendererScrollView", nullptr, NapiScroll, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sshTerminalRendererScrollToBottom", nullptr, NapiScrollToBottom, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sshTerminalRendererContent", nullptr, NapiContent, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sshTerminalRendererMode", nullptr, NapiMode, nullptr, nullptr, nullptr, napi_default, nullptr }
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
    return exports;
}
}
