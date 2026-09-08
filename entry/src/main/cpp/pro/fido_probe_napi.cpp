#include <napi/native_api.h>
#include <cmath>
#include <cstdint>
#include <cstring>

#if defined(REMOTEDESK_DEBUG_FIDO_PROBE)
#include "fido_probe_transport.h"
#include <memory>
#include <mutex>
#endif

namespace ProFidoNapi {
namespace {
napi_value Number(napi_env env, uint32_t number) {
    napi_value result = nullptr;
    return napi_create_uint32(env, number, &result) == napi_ok ? result : nullptr;
}
napi_value Boolean(napi_env env, bool boolean) {
    napi_value result = nullptr;
    return napi_get_boolean(env, boolean, &result) == napi_ok ? result : nullptr;
}
#if defined(REMOTEDESK_DEBUG_FIDO_PROBE)
bool Uint(napi_env env, napi_value value, uint32_t& number) {
    double candidate = 0;
    if (napi_get_value_double(env, value, &candidate) != napi_ok || !std::isfinite(candidate) ||
        candidate < 1 || candidate > UINT32_MAX || std::floor(candidate) != candidate) return false;
    number = static_cast<uint32_t>(candidate);
    return true;
}

std::mutex registryMutex;
std::unique_ptr<ProFido::ProbeTransport> active;
napi_env activeEnv = nullptr;
uint32_t activeId = 0;
uint32_t lastId = 0;

void Cleanup(void* raw) {
    std::unique_ptr<ProFido::ProbeTransport> owned;
    {
        std::lock_guard<std::mutex> lock(registryMutex);
        if (activeEnv == raw) {
            owned = std::move(active);
            activeEnv = nullptr;
            activeId = 0;
        }
    }
    // Cancellation wakes the native condition variable; the worker no longer
    // depends on an ArkTS callback before joining and freeing library state.
    owned.reset();
}
#endif

napi_value Available(napi_env env, napi_callback_info) {
#if defined(REMOTEDESK_DEBUG_FIDO_PROBE)
    return Boolean(env, true);
#else
    return Boolean(env, false);
#endif
}

napi_value Start(napi_env env, napi_callback_info) {
#if defined(REMOTEDESK_DEBUG_FIDO_PROBE)
    std::unique_ptr<ProFido::ProbeTransport> retired;
    uint32_t id = 0;
    try {
        std::lock_guard<std::mutex> lock(registryMutex);
        if ((active && !active->Finished()) || lastId == UINT32_MAX) return Number(env, 0);
        retired = std::move(active);
        active = std::make_unique<ProFido::ProbeTransport>();
        activeEnv = env;
        activeId = ++lastId;
        id = activeId;
    } catch (...) { return Number(env, 0); }
    return Number(env, id);
#else
    return Number(env, 0);
#endif
}

napi_value Poll(napi_env env, napi_callback_info info) {
    uint32_t status = 4, requestId = 0, timeout = 0;
    bool write = false;
    uint8_t report[64]{};
#if defined(REMOTEDESK_DEBUG_FIDO_PROBE)
    size_t argc = 1;
    napi_value argument = nullptr;
    uint32_t id = 0;
    if (napi_get_cb_info(env, info, &argc, &argument, nullptr, nullptr) == napi_ok &&
        argc == 1 && Uint(env, argument, id)) {
        std::lock_guard<std::mutex> lock(registryMutex);
        if (active && activeEnv == env && activeId == id) {
            const auto snapshot = active->Poll();
            status = static_cast<uint32_t>(snapshot.status);
            requestId = snapshot.request.id;
            timeout = snapshot.request.timeoutMs;
            write = snapshot.request.write;
            std::memcpy(report, snapshot.request.report.data(), sizeof(report));
        }
    }
#else
    (void)info;
#endif
    napi_value result = nullptr, buffer = nullptr, data = nullptr;
    void* target = nullptr;
    const size_t length = requestId == 0 ? 0 : sizeof(report);
    if (napi_create_object(env, &result) != napi_ok ||
        napi_create_arraybuffer(env, length, &target, &buffer) != napi_ok) return nullptr;
    if (length != 0) std::memcpy(target, report, length);
    if (napi_create_typedarray(env, napi_uint8_array, length, buffer, 0, &data) != napi_ok ||
        napi_set_named_property(env, result, "status", Number(env, status)) != napi_ok ||
        napi_set_named_property(env, result, "requestId", Number(env, requestId)) != napi_ok ||
        napi_set_named_property(env, result, "timeoutMs", Number(env, timeout)) != napi_ok ||
        napi_set_named_property(env, result, "write", Boolean(env, write)) != napi_ok ||
        napi_set_named_property(env, result, "data", data) != napi_ok) return nullptr;
    return result;
}

napi_value Reply(napi_env env, napi_callback_info info) {
    bool accepted = false;
#if defined(REMOTEDESK_DEBUG_FIDO_PROBE)
    size_t argc = 4;
    napi_value args[4]{};
    uint32_t id = 0, requestId = 0;
    bool success = false;
    napi_typedarray_type type;
    size_t length = 0, offset = 0;
    void* bytes = nullptr;
    napi_value buffer = nullptr;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) == napi_ok && argc == 4 &&
        Uint(env, args[0], id) && Uint(env, args[1], requestId) &&
        napi_get_value_bool(env, args[3], &success) == napi_ok &&
        napi_get_typedarray_info(env, args[2], &type, &length, &bytes, &buffer, &offset) == napi_ok &&
        type == napi_uint8_array && (length == 64 || (!success && length == 0))) {
        std::lock_guard<std::mutex> lock(registryMutex);
        if (active && activeEnv == env && activeId == id) {
            accepted = active->Reply(requestId, static_cast<const uint8_t*>(bytes), length, success);
        }
    }
#else
    (void)info;
#endif
    return Boolean(env, accepted);
}

napi_value Cancel(napi_env env, napi_callback_info info) {
#if defined(REMOTEDESK_DEBUG_FIDO_PROBE)
    size_t argc = 1;
    napi_value argument = nullptr;
    uint32_t id = 0;
    if (napi_get_cb_info(env, info, &argc, &argument, nullptr, nullptr) == napi_ok &&
        argc == 1 && Uint(env, argument, id)) {
        std::lock_guard<std::mutex> lock(registryMutex);
        if (active && activeEnv == env && activeId == id) active->Cancel();
    }
#else
    (void)info;
#endif
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}
} // namespace

napi_value Init(napi_env env, napi_value exports) {
#if defined(REMOTEDESK_DEBUG_FIDO_PROBE)
    // Never expose a worker start entry point without an environment teardown hook.
    if (napi_add_env_cleanup_hook(env, Cleanup, env) != napi_ok) return nullptr;
#endif
    const napi_property_descriptor properties[] = {
        {"proFidoProbeAvailable", nullptr, Available, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"proFidoProbeStart", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"proFidoProbePoll", nullptr, Poll, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"proFidoProbeReply", nullptr, Reply, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"proFidoProbeCancel", nullptr, Cancel, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    if (napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties) != napi_ok) return nullptr;
    return exports;
}
} // namespace ProFidoNapi
