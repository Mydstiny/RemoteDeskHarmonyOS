/**
 * terminal_core_napi.h — Rust terminal_core 的 C ABI 声明 + NAPI 初始化
 *
 * 声明来自 rustdesk_ffi/src/terminal_core/ffi.rs 的 extern "C" 函数。
 * C++ NAPI 包装层 (terminal_core_napi.cpp) 调用这些函数,
 * 将终端核心能力暴露给 ArkTS 层。
 */
#ifndef TERMINAL_CORE_NAPI_H
#define TERMINAL_CORE_NAPI_H

#include <napi/native_api.h>
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---- C 兼容数据结构 (与 Rust #[repr(C)] 布局一致) ----

typedef struct {
    uint32_t ch;               // char 的 Unicode code point
    uint32_t fg;               // RGBA 前景色
    uint32_t bg;               // RGBA 背景色
    bool bold;
    bool italic;
    bool underline;
    bool inverse;
    bool wide;
    bool wide_continuation;
} FfiSnapshotCell;

typedef struct {
    size_t cols;
    size_t rows;
    size_t cursor_x;
    size_t cursor_y;
    bool cursor_visible;
    size_t view_top;
    size_t screen_top;
    bool is_at_bottom;
    size_t* dirty_rows_ptr;       // heap-allocated usize array
    size_t dirty_rows_len;
    FfiSnapshotCell* cells_ptr;   // heap-allocated cell array
    size_t cells_len;
} FfiTerminalSnapshot;

// ---- Rust extern "C" 函数 ----

/** 创建终端实例，返回不透明句柄 (堆分配) */
void* terminal_core_create(size_t cols, size_t rows);

/** 销毁终端实例 */
void terminal_core_destroy(void* handle);

/** 写入原始字节到终端 (ANSI/VT 解析) */
void terminal_core_write(void* handle, const uint8_t* data, size_t len);

/** 调整终端尺寸 */
void terminal_core_resize(void* handle, size_t cols, size_t rows);

/** 用户滚动视口 (delta > 0 向上翻，< 0 向下翻) */
void terminal_core_scroll_view(void* handle, int64_t delta_lines);

/** 跳到底部 (跟随最新输出) */
void terminal_core_scroll_to_bottom(void* handle);

/** 获取完整快照 (堆分配, 调用者负责 terminal_core_free_snapshot) */
FfiTerminalSnapshot* terminal_core_snapshot(const void* handle);

/** 获取脏行快照并清空脏标记 */
FfiTerminalSnapshot* terminal_core_dirty_snapshot(void* handle);

/** 释放快照内存 */
void terminal_core_free_snapshot(FfiTerminalSnapshot* snapshot);

#ifdef __cplusplus
}
#endif

// ---- NAPI 命名空间 ----

namespace TerminalCoreNapi {
    napi_value Init(napi_env env, napi_value exports);
}

#endif // TERMINAL_CORE_NAPI_H
