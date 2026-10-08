/**
 * NAPI: resolveLocalHostName(name: string, timeoutMs: number):
 *   Promise<{ addresses: string[]; method: string }>
 * Resolves a computer name or "<name>.local" on the local network (mDNS,
 * LLMNR, NetBIOS) on a worker thread; never rejects (empty on failure).
 */

#include "local_name_resolver.h"

#include <hilog/log.h>
#include <napi/native_api.h>

#include <algorithm>
#include <chrono>
#include <string>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0005
#define LOG_TAG "LOCAL_NAME"

namespace {

struct ResolveWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string name;
    int timeoutMs = 1500;
    remotedesk::net::LocalNameResolution result;
};

void Execute(napi_env, void* data) {
    auto* work = static_cast<ResolveWork*>(data);
    work->result = remotedesk::net::ResolveLocalHostName(work->name, std::chrono::milliseconds(work->timeoutMs));
}

void Complete(napi_env env, napi_status, void* data) {
    auto* work = static_cast<ResolveWork*>(data);
    OH_LOG_INFO(LOG_APP, "[LocalName] resolved method=%{public}s count=%{public}zu",
                work->result.method.empty() ? "none" : work->result.method.c_str(),
                work->result.addresses.size());
    napi_value object;
    napi_create_object(env, &object);
    napi_value addresses;
    napi_create_array_with_length(env, work->result.addresses.size(), &addresses);
    for (size_t index = 0; index < work->result.addresses.size(); ++index) {
        napi_value text;
        napi_create_string_utf8(env, work->result.addresses[index].c_str(), NAPI_AUTO_LENGTH, &text);
        napi_set_element(env, addresses, static_cast<uint32_t>(index), text);
    }
    napi_set_named_property(env, object, "addresses", addresses);
    napi_value method;
    napi_create_string_utf8(env, work->result.method.c_str(), NAPI_AUTO_LENGTH, &method);
    napi_set_named_property(env, object, "method", method);
    napi_resolve_deferred(env, work->deferred, object);
    napi_delete_async_work(env, work->work);
    delete work;
}

napi_value ResolveLocalHostNameNapi(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto* work = new ResolveWork();
    if (argc >= 1) {
        char buffer[256] = {};
        size_t length = 0;
        if (napi_get_value_string_utf8(env, args[0], buffer, sizeof(buffer), &length) == napi_ok) {
            work->name.assign(buffer, length);
        }
    }
    if (argc >= 2) {
        int32_t timeout = 1500;
        if (napi_get_value_int32(env, args[1], &timeout) == napi_ok) {
            work->timeoutMs = std::clamp(timeout, 200, 5000);
        }
    }
    napi_value promise;
    napi_create_promise(env, &work->deferred, &promise);
    napi_value resource;
    napi_create_string_utf8(env, "resolveLocalHostName", NAPI_AUTO_LENGTH, &resource);
    if (napi_create_async_work(env, nullptr, resource, Execute, Complete, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        napi_value empty;
        napi_create_object(env, &empty);
        napi_resolve_deferred(env, work->deferred, empty);
        if (work->work != nullptr) { napi_delete_async_work(env, work->work); }
        delete work;
    }
    return promise;
}

} // namespace

namespace LocalNameResolverNapi {
void Init(napi_env env, napi_value exports) {
    napi_value fn;
    napi_create_function(env, "resolveLocalHostName", NAPI_AUTO_LENGTH, ResolveLocalHostNameNapi, nullptr, &fn);
    napi_set_named_property(env, exports, "resolveLocalHostName", fn);
}
} // namespace LocalNameResolverNapi
