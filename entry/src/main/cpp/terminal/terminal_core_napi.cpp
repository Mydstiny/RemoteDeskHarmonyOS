/**
 * terminal_core_napi.cpp — Rust terminal_core 的 NAPI 桥接实现
 *
 * 将 Rust C ABI (terminal_core_napi.h) 的 9 个函数包装为 NAPI 方法,
 * 注册到 librdpnapi.so, 供 ArkTS TerminalCoreBridge 调用。
 *
 * 注册的方法 (全部驼峰, 与 rdpnapi.d.ts 一致):
 *   terminalCoreCreate, terminalCoreDestroy, terminalCoreWrite,
 *   terminalCoreResize, terminalCoreScrollView, terminalCoreScrollToBottom,
 *   terminalCoreSnapshot, terminalCoreDirtySnapshot
 *
 * 参考: extension_loader_napi.cpp 的 NAPI 注册模式 + napi_helpers.h 的参数验证宏
 */
#include "terminal/terminal_core_napi.h"
#include "napi_helpers.h"
#include <napi/native_api.h>
#include <hilog/log.h>
#include <cstdint>
#include <cstring>
#include <vector>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0002
#define LOG_TAG "TERMINAL_CORE"

// ============================================================
// Helper: 编码单个 Unicode code point 为 UTF-8 (1-3 字节, BMP)
// ============================================================

static int putUtf8(uint32_t cp, char* buf) {
    if (cp < 0x80) {
        buf[0] = static_cast<char>(cp);
        buf[1] = '\0';
        return 1;
    } else if (cp < 0x800) {
        buf[0] = static_cast<char>(0xC0 | (cp >> 6));
        buf[1] = static_cast<char>(0x80 | (cp & 0x3F));
        buf[2] = '\0';
        return 2;
    } else if (cp < 0x10000) {
        // BMP (U+0000..U+FFFF)
        buf[0] = static_cast<char>(0xE0 | (cp >> 12));
        buf[1] = static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = static_cast<char>(0x80 | (cp & 0x3F));
        buf[3] = '\0';
        return 3;
    } else if (cp <= 0x10FFFF) {
        // Supplementary Plane (U+10000..U+10FFFF) — emoji, CJK 扩展等
        buf[0] = static_cast<char>(0xF0 | (cp >> 18));
        buf[1] = static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
        buf[2] = static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
        buf[3] = static_cast<char>(0x80 | (cp & 0x3F));
        buf[4] = '\0';
        return 4;
    } else {
        // 无效 code point → U+FFFD (replacement character)
        buf[0] = static_cast<char>(0xEF);
        buf[1] = static_cast<char>(0xBF);
        buf[2] = static_cast<char>(0xBD);
        buf[3] = '\0';
        return 3;
    }
}

// ============================================================
// Helper: NAPI object property setter (减少重复)
// ============================================================

static void setIntProp(napi_env env, napi_value obj, const char* name, int64_t val) {
    napi_value v;
    napi_create_int64(env, val, &v);
    napi_set_named_property(env, obj, name, v);
}

static void setBoolProp(napi_env env, napi_value obj, const char* name, bool val) {
    napi_value v;
    napi_get_boolean(env, val, &v);
    napi_set_named_property(env, obj, name, v);
}

static void setStrProp(napi_env env, napi_value obj, const char* name, const char* val) {
    napi_value v;
    napi_create_string_utf8(env, val, NAPI_AUTO_LENGTH, &v);
    napi_set_named_property(env, obj, name, v);
}

// ============================================================
// Helper: 将 FfiTerminalSnapshot 转换为 JS object
// ============================================================

static napi_value buildJsSnapshot(napi_env env, FfiTerminalSnapshot* snap) {
    napi_value obj;
    napi_create_object(env, &obj);

    setIntProp(env, obj, "cols", static_cast<int64_t>(snap->cols));
    setIntProp(env, obj, "rows", static_cast<int64_t>(snap->rows));
    setIntProp(env, obj, "cursorX", static_cast<int64_t>(snap->cursor_x));
    setIntProp(env, obj, "cursorY", static_cast<int64_t>(snap->cursor_y));
    setBoolProp(env, obj, "cursorVisible", snap->cursor_visible);
    setIntProp(env, obj, "viewTop", static_cast<int64_t>(snap->view_top));
    setIntProp(env, obj, "screenTop", static_cast<int64_t>(snap->screen_top));
    setBoolProp(env, obj, "isAtBottom", snap->is_at_bottom);

    // ---- cells: TerminalCoreCell[] ----
    napi_value cells;
    napi_create_array_with_length(env, snap->cells_len, &cells);
    for (size_t i = 0; i < snap->cells_len; ++i) {
        const FfiSnapshotCell& src = snap->cells_ptr[i];
        napi_value cellObj;
        napi_create_object(env, &cellObj);

        // ch: u32 code point → 1-char JS string (UTF-8 encoded)
        char chBuf[5] = {0};
        putUtf8(src.ch, chBuf);
        setStrProp(env, cellObj, "ch", chBuf);

        setIntProp(env, cellObj, "fg", static_cast<int64_t>(src.fg));
        setIntProp(env, cellObj, "bg", static_cast<int64_t>(src.bg));
        setBoolProp(env, cellObj, "bold", src.bold);
        setBoolProp(env, cellObj, "italic", src.italic);
        setBoolProp(env, cellObj, "underline", src.underline);
        setBoolProp(env, cellObj, "inverse", src.inverse);
        setBoolProp(env, cellObj, "wide", src.wide);
        setBoolProp(env, cellObj, "wideContinuation", src.wide_continuation);

        napi_set_element(env, cells, i, cellObj);
    }
    napi_set_named_property(env, obj, "cells", cells);

    // ---- dirtyRows: number[] ----
    napi_value dirtyRows;
    napi_create_array_with_length(env, snap->dirty_rows_len, &dirtyRows);
    for (size_t i = 0; i < snap->dirty_rows_len; ++i) {
        napi_value rowNum;
        napi_create_uint32(env, static_cast<uint32_t>(snap->dirty_rows_ptr[i]), &rowNum);
        napi_set_element(env, dirtyRows, i, rowNum);
    }
    napi_set_named_property(env, obj, "dirtyRows", dirtyRows);

    return obj;
}

// ============================================================
// 内部辅助: 从 NAPI args[0] 读取 int64 handle → void*
// ============================================================

static void* getHandle(napi_env env, napi_value arg) {
    int64_t val = 0;
    if (napi_get_value_int64(env, arg, &val) != napi_ok) {
        return nullptr;
    }
    return reinterpret_cast<void*>(val);
}

// ============================================================
// NAPI 导出函数
// ============================================================

/**
 * terminalCoreCreate(cols: number, rows: number): number
 */
static napi_value NapiTerminalCoreCreate(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    NAPI_ASSERT_ARGC(env, argc, 2);
    NAPI_ASSERT_TYPE(env, args[0], napi_number, "cols");
    NAPI_ASSERT_TYPE(env, args[1], napi_number, "rows");

    int64_t cols = 0, rows = 0;
    napi_get_value_int64(env, args[0], &cols);
    napi_get_value_int64(env, args[1], &rows);

    if (cols < 1) cols = 1;
    if (rows < 1) rows = 1;

    void* handle = terminal_core_create(static_cast<size_t>(cols), static_cast<size_t>(rows));
    if (!handle) {
        napi_value err;
        napi_create_int64(env, -1, &err);
        return err;
    }

    OH_LOG_INFO(LOG_APP, "[TerminalCore] create: handle=%{public}p cols=%{public}zu rows=%{public}zu",
                handle, static_cast<size_t>(cols), static_cast<size_t>(rows));

    napi_value result;
    napi_create_int64(env, reinterpret_cast<int64_t>(handle), &result);
    return result;
}

/**
 * terminalCoreDestroy(handle: number): void
 */
static napi_value NapiTerminalCoreDestroy(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    NAPI_ASSERT_ARGC(env, argc, 1);
    NAPI_ASSERT_TYPE(env, args[0], napi_number, "handle");

    void* handle = getHandle(env, args[0]);
    if (handle) {
        terminal_core_destroy(handle);
        OH_LOG_INFO(LOG_APP, "[TerminalCore] destroy: handle=%{public}p", handle);
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/**
 * terminalCoreWrite(handle: number, data: string): void
 */
static napi_value NapiTerminalCoreWrite(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    NAPI_ASSERT_ARGC(env, argc, 2);
    NAPI_ASSERT_TYPE(env, args[0], napi_number, "handle");
    NAPI_ASSERT_TYPE(env, args[1], napi_string, "data");

    void* handle = getHandle(env, args[0]);
    if (!handle) {
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    // 获取字符串长度 → 堆分配 buffer (避免 64KB 栈溢出)
    size_t bufSize = 0;
    napi_get_value_string_utf8(env, args[1], nullptr, 0, &bufSize);
    if (bufSize == 0) {
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    // +1 for null terminator (though we don't need it for terminal_core_write)
    std::vector<uint8_t> buf(bufSize + 1);
    size_t copied = 0;
    napi_get_value_string_utf8(env, args[1], reinterpret_cast<char*>(buf.data()), bufSize + 1, &copied);

    terminal_core_write(handle, buf.data(), copied);

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/**
 * terminalCoreResize(handle: number, cols: number, rows: number): void
 */
static napi_value NapiTerminalCoreResize(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    NAPI_ASSERT_ARGC(env, argc, 3);
    NAPI_ASSERT_TYPE(env, args[0], napi_number, "handle");
    NAPI_ASSERT_TYPE(env, args[1], napi_number, "cols");
    NAPI_ASSERT_TYPE(env, args[2], napi_number, "rows");

    void* handle = getHandle(env, args[0]);
    if (!handle) {
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    int64_t cols = 0, rows = 0;
    napi_get_value_int64(env, args[1], &cols);
    napi_get_value_int64(env, args[2], &rows);

    terminal_core_resize(handle, static_cast<size_t>(cols > 0 ? cols : 1),
                         static_cast<size_t>(rows > 0 ? rows : 1));

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/**
 * terminalCoreScrollView(handle: number, deltaLines: number): void
 */
static napi_value NapiTerminalCoreScrollView(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    NAPI_ASSERT_ARGC(env, argc, 2);
    NAPI_ASSERT_TYPE(env, args[0], napi_number, "handle");
    NAPI_ASSERT_TYPE(env, args[1], napi_number, "deltaLines");

    void* handle = getHandle(env, args[0]);
    if (!handle) {
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    int64_t delta = 0;
    napi_get_value_int64(env, args[1], &delta);

    terminal_core_scroll_view(handle, static_cast<int64_t>(delta));

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/**
 * terminalCoreScrollToBottom(handle: number): void
 */
static napi_value NapiTerminalCoreScrollToBottom(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    NAPI_ASSERT_ARGC(env, argc, 1);
    NAPI_ASSERT_TYPE(env, args[0], napi_number, "handle");

    void* handle = getHandle(env, args[0]);
    if (handle) {
        terminal_core_scroll_to_bottom(handle);
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/**
 * terminalCoreSnapshot(handle: number): TerminalCoreSnapshot
 */
static napi_value NapiTerminalCoreSnapshot(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    NAPI_ASSERT_ARGC(env, argc, 1);
    NAPI_ASSERT_TYPE(env, args[0], napi_number, "handle");

    void* handle = getHandle(env, args[0]);
    if (!handle) {
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    FfiTerminalSnapshot* snap = terminal_core_snapshot(handle);
    if (!snap) {
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    napi_value result = buildJsSnapshot(env, snap);
    terminal_core_free_snapshot(snap);
    return result;
}

/**
 * terminalCoreDirtySnapshot(handle: number): TerminalCoreSnapshot
 */
static napi_value NapiTerminalCoreDirtySnapshot(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    NAPI_ASSERT_ARGC(env, argc, 1);
    NAPI_ASSERT_TYPE(env, args[0], napi_number, "handle");

    void* handle = getHandle(env, args[0]);
    if (!handle) {
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    FfiTerminalSnapshot* snap = terminal_core_dirty_snapshot(handle);
    if (!snap) {
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    napi_value result = buildJsSnapshot(env, snap);
    terminal_core_free_snapshot(snap);
    return result;
}

// ============================================================
// TerminalCoreNapi::Init — 向 exports 注册所有方法
// ============================================================

napi_value TerminalCoreNapi::Init(napi_env env, napi_value exports) {
    napi_value fn;

    napi_create_function(env, "terminalCoreCreate", NAPI_AUTO_LENGTH,
                         NapiTerminalCoreCreate, nullptr, &fn);
    napi_set_named_property(env, exports, "terminalCoreCreate", fn);

    napi_create_function(env, "terminalCoreDestroy", NAPI_AUTO_LENGTH,
                         NapiTerminalCoreDestroy, nullptr, &fn);
    napi_set_named_property(env, exports, "terminalCoreDestroy", fn);

    napi_create_function(env, "terminalCoreWrite", NAPI_AUTO_LENGTH,
                         NapiTerminalCoreWrite, nullptr, &fn);
    napi_set_named_property(env, exports, "terminalCoreWrite", fn);

    napi_create_function(env, "terminalCoreResize", NAPI_AUTO_LENGTH,
                         NapiTerminalCoreResize, nullptr, &fn);
    napi_set_named_property(env, exports, "terminalCoreResize", fn);

    napi_create_function(env, "terminalCoreScrollView", NAPI_AUTO_LENGTH,
                         NapiTerminalCoreScrollView, nullptr, &fn);
    napi_set_named_property(env, exports, "terminalCoreScrollView", fn);

    napi_create_function(env, "terminalCoreScrollToBottom", NAPI_AUTO_LENGTH,
                         NapiTerminalCoreScrollToBottom, nullptr, &fn);
    napi_set_named_property(env, exports, "terminalCoreScrollToBottom", fn);

    napi_create_function(env, "terminalCoreSnapshot", NAPI_AUTO_LENGTH,
                         NapiTerminalCoreSnapshot, nullptr, &fn);
    napi_set_named_property(env, exports, "terminalCoreSnapshot", fn);

    napi_create_function(env, "terminalCoreDirtySnapshot", NAPI_AUTO_LENGTH,
                         NapiTerminalCoreDirtySnapshot, nullptr, &fn);
    napi_set_named_property(env, exports, "terminalCoreDirtySnapshot", fn);

    OH_LOG_INFO(LOG_APP, "[TerminalCore] NAPI 方法已注册: 8 个 terminalCore* 函数");
    return exports;
}
