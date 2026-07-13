/**
 * napi_helpers.h — NAPI 参数验证辅助宏
 *
 * 每个 NAPI 函数入口处使用这些宏验证参数数量和类型，
 * 避免 JS 端传入错误类型导致未定义行为。
 *
 * 用法:
 *   NAPI_ASSERT_ARGC(env, argc, 2);
 *   NAPI_ASSERT_TYPE(env, args[0], napi_string, "arg 0: string");
 *   NAPI_ASSERT_TYPE(env, args[1], napi_number, "arg 1: number");
 */

#ifndef NAPI_HELPERS_H
#define NAPI_HELPERS_H

#include <napi/native_api.h>

// ============================================================
// 参数数量断言
// ============================================================
#define NAPI_ASSERT_ARGC(env, argc, expected)                         \
    do {                                                              \
        if ((argc) < (expected)) {                                    \
            napi_throw_type_error(env, nullptr,                       \
                "Wrong number of arguments, expected " #expected);    \
            return nullptr;                                           \
        }                                                             \
    } while (0)

// ============================================================
// 参数类型断言 (单个参数)
// ============================================================
#define NAPI_ASSERT_TYPE(env, value, expected_type, msg)                \
    do {                                                                \
        napi_valuetype __type;                                          \
        napi_typeof((env), (value), &__type);                           \
        if (__type != (expected_type)) {                                \
            napi_throw_type_error((env), nullptr,                       \
                "Wrong argument type: " msg " (expected "               \
                #expected_type ")");                                    \
            return nullptr;                                             \
        }                                                               \
    } while (0)

// ============================================================
// 条件断言 (通用)
// ============================================================
#define NAPI_ASSERT(env, condition, error_msg)                          \
    do {                                                                \
        if (!(condition)) {                                             \
            napi_throw_error((env), nullptr, (error_msg));              \
            return nullptr;                                             \
        }                                                               \
    } while (0)

#endif // NAPI_HELPERS_H
