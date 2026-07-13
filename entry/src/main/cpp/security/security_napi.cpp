/**
 * security_napi.cpp — 安全模块 NAPI 桥接
 *
 * 将 HUKS 主机锁功能暴露给 ArkTS 层。
 */

#include "host_locker.h"
#include "extensions/data_provider.h"
#include "../napi_helpers.h"
#include <napi/native_api.h>
#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0022
#define LOG_TAG "SEC_NAPI"

namespace SecurityNapi {
    napi_value Init(napi_env env, napi_value exports);
}

namespace {

napi_value NapiSetLock(napi_env env, napi_callback_info info) {
    size_t argc = 3; napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NAPI_ASSERT_ARGC(env, argc, 3);
    NAPI_ASSERT_TYPE(env, args[0], napi_string, "hostId");
    NAPI_ASSERT_TYPE(env, args[1], napi_number, "lockType");
    NAPI_ASSERT_TYPE(env, args[2], napi_string, "credential");

    char hostId[1024] = {0}, credential[512] = {0};
    int32_t lockType;
    size_t hostIdLen = 0, credLen = 0;
    napi_get_value_string_utf8(env, args[0], hostId, sizeof(hostId), &hostIdLen);
    napi_get_value_int32(env, args[1], &lockType);
    napi_get_value_string_utf8(env, args[2], credential, sizeof(credential), &credLen);
    if (hostIdLen >= sizeof(hostId)) {
        OH_LOG_WARN(LOG_APP, "[SEC_NAPI] setLock hostId truncated: %{public}zu chars", hostIdLen);
    }
    if (credLen >= sizeof(credential)) {
        OH_LOG_WARN(LOG_APP, "[SEC_NAPI] setLock credential truncated: %{public}zu chars", credLen);
    }

    bool result = HostLocker::instance().setLock(
        hostId, static_cast<LockType>(lockType), credential);

    napi_value retVal;
    napi_get_boolean(env, result, &retVal);
    return retVal;
}

napi_value NapiVerifyLock(napi_env env, napi_callback_info info) {
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NAPI_ASSERT_ARGC(env, argc, 2);
    NAPI_ASSERT_TYPE(env, args[0], napi_string, "hostId");
    NAPI_ASSERT_TYPE(env, args[1], napi_string, "credential");

    char hostId[1024] = {0}, credential[512] = {0};
    size_t hostIdLen = 0, credLen = 0;
    napi_get_value_string_utf8(env, args[0], hostId, sizeof(hostId), &hostIdLen);
    napi_get_value_string_utf8(env, args[1], credential, sizeof(credential), &credLen);
    if (hostIdLen >= sizeof(hostId)) {
        OH_LOG_WARN(LOG_APP, "[SEC_NAPI] verifyLock hostId truncated: %{public}zu chars", hostIdLen);
    }
    if (credLen >= sizeof(credential)) {
        OH_LOG_WARN(LOG_APP, "[SEC_NAPI] verifyLock credential truncated: %{public}zu chars", credLen);
    }

    bool result = HostLocker::instance().verifyLock(hostId, credential);

    napi_value retVal;
    napi_get_boolean(env, result, &retVal);
    return retVal;
}

napi_value NapiRemoveLock(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NAPI_ASSERT_ARGC(env, argc, 1);
    NAPI_ASSERT_TYPE(env, args[0], napi_string, "hostId");

    char hostId[1024] = {0};
    size_t hostIdLen = 0;
    napi_get_value_string_utf8(env, args[0], hostId, sizeof(hostId), &hostIdLen);
    if (hostIdLen >= sizeof(hostId)) {
        OH_LOG_WARN(LOG_APP, "[SEC_NAPI] removeLock hostId truncated: %{public}zu chars", hostIdLen);
    }

    bool result = HostLocker::instance().removeLock(hostId);

    napi_value retVal;
    napi_get_boolean(env, result, &retVal);
    return retVal;
}

napi_value NapiIsLocked(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NAPI_ASSERT_ARGC(env, argc, 1);
    NAPI_ASSERT_TYPE(env, args[0], napi_string, "hostId");

    char hostId[1024] = {0};
    size_t hostIdLen = 0;
    napi_get_value_string_utf8(env, args[0], hostId, sizeof(hostId), &hostIdLen);
    if (hostIdLen >= sizeof(hostId)) {
        OH_LOG_WARN(LOG_APP, "[SEC_NAPI] isLocked hostId truncated: %{public}zu chars", hostIdLen);
    }

    bool result = HostLocker::instance().isLocked(hostId);

    napi_value retVal;
    napi_get_boolean(env, result, &retVal);
    return retVal;
}

napi_value NapiGetLockType(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    NAPI_ASSERT_ARGC(env, argc, 1);
    NAPI_ASSERT_TYPE(env, args[0], napi_string, "hostId");

    char hostId[1024] = {0};
    size_t hostIdLen = 0;
    napi_get_value_string_utf8(env, args[0], hostId, sizeof(hostId), &hostIdLen);
    if (hostIdLen >= sizeof(hostId)) {
        OH_LOG_WARN(LOG_APP, "[SEC_NAPI] getLockType hostId truncated: %{public}zu chars", hostIdLen);
    }

    int type = static_cast<int>(HostLocker::instance().getLockType(hostId));

    napi_value retVal;
    napi_create_int32(env, type, &retVal);
    return retVal;
}
}

napi_value SecurityNapi::Init(napi_env env, napi_value exports) {
    // 确保 HUKS 已初始化
    HostLocker::instance().initialize();

    napi_value fn;
    napi_create_function(env, "setLock", NAPI_AUTO_LENGTH, NapiSetLock, nullptr, &fn);
    napi_set_named_property(env, exports, "setLock", fn);
    napi_create_function(env, "verifyLock", NAPI_AUTO_LENGTH, NapiVerifyLock, nullptr, &fn);
    napi_set_named_property(env, exports, "verifyLock", fn);
    napi_create_function(env, "removeLock", NAPI_AUTO_LENGTH, NapiRemoveLock, nullptr, &fn);
    napi_set_named_property(env, exports, "removeLock", fn);
    napi_create_function(env, "isLocked", NAPI_AUTO_LENGTH, NapiIsLocked, nullptr, &fn);
    napi_set_named_property(env, exports, "isLocked", fn);
    napi_create_function(env, "getLockType", NAPI_AUTO_LENGTH, NapiGetLockType, nullptr, &fn);
    napi_set_named_property(env, exports, "getLockType", fn);

    return exports;
}
