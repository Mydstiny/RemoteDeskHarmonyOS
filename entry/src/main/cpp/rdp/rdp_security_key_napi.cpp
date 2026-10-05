// NAPI surface of the RDP security-key broker. Debug builds with the RDPEWA channel get the real implementation;
// Release keeps inert stubs (rdpSecurityKeyAvailable() === false) and links no FIDO code.
#include <napi/native_api.h>
#include <cmath>
#include <cstdint>
#include <cstring>

#if defined(REMOTEDESK_RDP_SECURITY_KEY)
#include "rdp_security_key_broker.h"
#include <algorithm>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#endif

namespace RdpSecurityKeyNapi {
namespace {
napi_value Undefined(napi_env env) {
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}
napi_value Boolean(napi_env env, bool value) {
    napi_value result = nullptr;
    return napi_get_boolean(env, value, &result) == napi_ok ? result : nullptr;
}
napi_value Number(napi_env env, uint32_t value) {
    napi_value result = nullptr;
    return napi_create_uint32(env, value, &result) == napi_ok ? result : nullptr;
}

#if defined(REMOTEDESK_RDP_SECURITY_KEY)
bool Integer(napi_env env, napi_value value, uint64_t& out, uint64_t max) {
    double candidate = 0;
    if (napi_get_value_double(env, value, &candidate) != napi_ok || !std::isfinite(candidate) ||
        candidate < 1 || candidate > double(max) || std::floor(candidate) != candidate) return false;
    out = static_cast<uint64_t>(candidate);
    return true;
}

// Serializes wake-ups against release: the broker may wake from any thread at any time.
struct WakeTarget {
    std::mutex mutex;
    napi_threadsafe_function function = nullptr;
    void Call() {
        std::lock_guard<std::mutex> lock(mutex);
        if (function != nullptr) napi_call_threadsafe_function(function, nullptr, napi_tsfn_nonblocking);
    }
    void Release() {
        std::lock_guard<std::mutex> lock(mutex);
        if (function != nullptr) napi_release_threadsafe_function(function, napi_tsfn_release);
        function = nullptr;
    }
};

// One ArkTS watcher per session. Watch IDs let a page that lost the watch to a newer page (independent-window
// handoff, page restore) stop without unwatching or cancelling the newer page's session.
struct Watcher {
    uint32_t id = 0;
    std::shared_ptr<WakeTarget> target;
};

std::mutex g_watchMutex;
std::map<uint64_t, Watcher> g_watches;
uint32_t g_lastWatchId = 0;

void CallJs(napi_env env, napi_value callback, void*, void*) {
    if (env == nullptr || callback == nullptr) return;
    napi_value undefined = Undefined(env);
    napi_call_function(env, undefined, callback, 0, nullptr, nullptr);
}

void Cleanup(void*) {
    std::map<uint64_t, Watcher> watches;
    {
        std::lock_guard<std::mutex> lock(g_watchMutex);
        watches.swap(g_watches);
        for (const auto& entry : watches) RdpSecurityKey::Unwatch(entry.first);
    }
    for (auto& entry : watches) entry.second.target->Release();
}

bool SessionArgument(napi_env env, napi_callback_info info, uint64_t& sessionId) {
    size_t argc = 1;
    napi_value arg = nullptr;
    return napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr) == napi_ok && argc == 1 &&
        Integer(env, arg, sessionId, 0x1fffffffffffffULL);
}
#endif

napi_value Available(napi_env env, napi_callback_info) {
#if defined(REMOTEDESK_RDP_SECURITY_KEY)
    return Boolean(env, true);
#else
    return Boolean(env, false);
#endif
}

// rdpSecurityKeyWatch(sessionId, onRequest): number. Wakes onRequest whenever the session has something for ArkTS,
// across reconnects. Returns the watch ID, or 0 when the session has no open broker.
napi_value Watch(napi_env env, napi_callback_info info) {
#if defined(REMOTEDESK_RDP_SECURITY_KEY)
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    uint64_t sessionId = 0;
    napi_valuetype type = napi_undefined;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 2 ||
        !Integer(env, args[0], sessionId, 0x1fffffffffffffULL) ||
        napi_typeof(env, args[1], &type) != napi_ok || type != napi_function) return Number(env, 0);
    if (!RdpSecurityKey::ForSession(sessionId)) return Number(env, 0);
    napi_value name = nullptr;
    napi_create_string_utf8(env, "rdpSecurityKeyWake", NAPI_AUTO_LENGTH, &name);
    auto target = std::make_shared<WakeTarget>();
    if (napi_create_threadsafe_function(env, args[1], nullptr, name, 0, 1, nullptr, nullptr, nullptr, CallJs,
                                        &target->function) != napi_ok) return Number(env, 0);
    uint32_t id = 0;
    std::shared_ptr<WakeTarget> previous;
    {
        std::lock_guard<std::mutex> lock(g_watchMutex);
        if (RdpSecurityKey::Watch(sessionId, [target]() { target->Call(); })) {
            if (++g_lastWatchId == 0) ++g_lastWatchId;
            id = g_lastWatchId;
            auto& slot = g_watches[sessionId];
            previous = slot.target;
            slot = Watcher{id, target};
        }
    }
    if (previous) previous->Release();
    if (id == 0) target->Release();
    return Number(env, id);
#else
    (void)info;
    return Number(env, 0);
#endif
}

// rdpSecurityKeyUnwatch(sessionId, watchId): boolean. True when that watch was still the session's watcher.
napi_value UnwatchNapi(napi_env env, napi_callback_info info) {
#if defined(REMOTEDESK_RDP_SECURITY_KEY)
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    uint64_t sessionId = 0;
    uint64_t watchId = 0;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 2 ||
        !Integer(env, args[0], sessionId, 0x1fffffffffffffULL) || !Integer(env, args[1], watchId, UINT32_MAX)) {
        return Boolean(env, false);
    }
    std::shared_ptr<WakeTarget> target;
    {
        std::lock_guard<std::mutex> lock(g_watchMutex);
        const auto found = g_watches.find(sessionId);
        if (found == g_watches.end() || found->second.id != watchId) return Boolean(env, false);
        target = found->second.target;
        g_watches.erase(found);
        RdpSecurityKey::Unwatch(sessionId);
    }
    target->Release();
    return Boolean(env, true);
#else
    (void)info;
    return Boolean(env, false);
#endif
}

// rdpSecurityKeyPoll(sessionId): the next request or notification, or null.
napi_value Poll(napi_env env, napi_callback_info info) {
    napi_value result = nullptr;
    napi_get_null(env, &result);
#if defined(REMOTEDESK_RDP_SECURITY_KEY)
    uint64_t sessionId = 0;
    if (!SessionArgument(env, info, sessionId)) return result;
    RdpSecurityKey::Request request;
    if (!RdpSecurityKey::Poll(sessionId, request)) return result;
    napi_value object = nullptr;
    if (napi_create_object(env, &object) != napi_ok) return result;
    const auto setUint = [&](const char* key, uint32_t value) {
        napi_value number = nullptr;
        napi_create_uint32(env, value, &number);
        napi_set_named_property(env, object, key, number);
    };
    setUint("id", request.id);
    setUint("kind", static_cast<uint32_t>(request.kind));
    setUint("operation", request.operation);
    setUint("timeoutMs", request.timeoutMs);
    napi_value retries = nullptr;
    napi_create_int32(env, request.retries, &retries);
    napi_set_named_property(env, object, "retries", retries);
    napi_value text = nullptr;
    napi_create_string_utf8(env, request.text.c_str(), request.text.size(), &text);
    napi_set_named_property(env, object, "text", text);
    void* data = nullptr;
    napi_value buffer = nullptr;
    napi_value report = nullptr;
    if (napi_create_arraybuffer(env, request.report.size(), &data, &buffer) == napi_ok && data != nullptr) {
        std::memcpy(data, request.report.data(), request.report.size());
        napi_create_typedarray(env, napi_uint8_array, request.report.size(), buffer, 0, &report);
        napi_set_named_property(env, object, "report", report);
    }
    return object;
#else
    (void)info;
    return result;
#endif
}

// rdpSecurityKeyRespond(sessionId, id, ok, report: Uint8Array | null, text: string | null): boolean
napi_value Respond(napi_env env, napi_callback_info info) {
#if defined(REMOTEDESK_RDP_SECURITY_KEY)
    size_t argc = 5;
    napi_value args[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    uint64_t sessionId = 0;
    uint64_t id = 0;
    bool ok = false;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 5 ||
        !Integer(env, args[0], sessionId, 0x1fffffffffffffULL) || !Integer(env, args[1], id, UINT32_MAX) ||
        napi_get_value_bool(env, args[2], &ok) != napi_ok) return Boolean(env, false);
    RdpSecurityKey::Reply reply;
    reply.ok = ok;
    bool isTyped = false;
    if (napi_is_typedarray(env, args[3], &isTyped) == napi_ok && isTyped) {
        napi_typedarray_type type = napi_int8_array;
        size_t length = 0;
        void* data = nullptr;
        if (napi_get_typedarray_info(env, args[3], &type, &length, &data, nullptr, nullptr) != napi_ok ||
            type != napi_uint8_array || length != reply.report.size() || data == nullptr) return Boolean(env, false);
        std::memcpy(reply.report.data(), data, reply.report.size());
    }
    napi_valuetype textType = napi_undefined;
    if (napi_typeof(env, args[4], &textType) == napi_ok && textType == napi_string) {
        size_t length = 0;
        if (napi_get_value_string_utf8(env, args[4], nullptr, 0, &length) != napi_ok ||
            length > RdpSecurityKey::kMaxPinBytes + 1) return Boolean(env, false);
        std::vector<char> buffer(length + 1, '\0');
        size_t copied = 0;
        if (napi_get_value_string_utf8(env, args[4], buffer.data(), buffer.size(), &copied) != napi_ok) {
            return Boolean(env, false);
        }
        reply.text.assign(buffer.data(), copied);
        std::fill(buffer.begin(), buffer.end(), '\0');
    }
    const bool accepted = RdpSecurityKey::Respond(sessionId, static_cast<uint32_t>(id), reply);
    std::fill(reply.text.begin(), reply.text.end(), '\0');
    return Boolean(env, accepted);
#else
    (void)info;
    return Boolean(env, false);
#endif
}

// rdpSecurityKeyCancel(sessionId): the local user cancelled the current request.
napi_value Cancel(napi_env env, napi_callback_info info) {
#if defined(REMOTEDESK_RDP_SECURITY_KEY)
    uint64_t sessionId = 0;
    if (SessionArgument(env, info, sessionId)) RdpSecurityKey::Cancel(sessionId);
#else
    (void)info;
#endif
    return Undefined(env);
}

// rdpSecurityKeyReleased(sessionId): ArkTS released the session's key on its own; the next request selects again.
napi_value Released(napi_env env, napi_callback_info info) {
#if defined(REMOTEDESK_RDP_SECURITY_KEY)
    uint64_t sessionId = 0;
    if (SessionArgument(env, info, sessionId)) RdpSecurityKey::Released(sessionId);
#else
    (void)info;
#endif
    return Undefined(env);
}
} // namespace

napi_value Init(napi_env env, napi_value exports) {
#if defined(REMOTEDESK_RDP_SECURITY_KEY)
    if (napi_add_env_cleanup_hook(env, Cleanup, nullptr) != napi_ok) return nullptr;
#endif
    const napi_property_descriptor properties[] = {
        {"rdpSecurityKeyAvailable", nullptr, Available, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rdpSecurityKeyWatch", nullptr, Watch, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rdpSecurityKeyUnwatch", nullptr, UnwatchNapi, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rdpSecurityKeyPoll", nullptr, Poll, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rdpSecurityKeyRespond", nullptr, Respond, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rdpSecurityKeyCancel", nullptr, Cancel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"rdpSecurityKeyReleased", nullptr, Released, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    if (napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties) != napi_ok) {
        return nullptr;
    }
    return exports;
}
} // namespace RdpSecurityKeyNapi
