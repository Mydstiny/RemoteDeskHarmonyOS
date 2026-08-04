use std::ptr;
use std::slice;

use super::snapshot::{SnapshotCell, TerminalSnapshot};
#[cfg(not(feature = "alacritty_terminal"))]
use super::Terminal;
#[cfg(feature = "alacritty_terminal")]
use super::{AlacrittyTerminal, AlacrittyTerminalConfig};

#[cfg(feature = "alacritty_terminal")]
pub type TerminalHandle = AlacrittyTerminal;

#[cfg(not(feature = "alacritty_terminal"))]
pub type TerminalHandle = Terminal;

#[repr(C)]
pub struct FfiSnapshotCell {
    pub ch: u32,
    pub fg: u32,
    pub bg: u32,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub inverse: bool,
    pub wide: bool,
    pub wide_continuation: bool,
}

#[repr(C)]
pub struct FfiTerminalSnapshot {
    pub cols: usize,
    pub rows: usize,
    pub cursor_x: usize,
    pub cursor_y: usize,
    pub cursor_visible: bool,
    pub bracketed_paste: bool,
    pub mouse_tracking: u16,
    pub sgr_mouse: bool,
    pub application_cursor_keys: bool,
    pub application_keypad: bool,
    pub auto_wrap: bool,
    pub view_top: usize,
    pub screen_top: usize,
    pub is_at_bottom: bool,
    pub dirty_rows_ptr: *mut usize,
    pub dirty_rows_len: usize,
    pub cells_ptr: *mut FfiSnapshotCell,
    pub cells_len: usize,
}

#[no_mangle]
pub extern "C" fn terminal_core_create(cols: usize, rows: usize) -> *mut TerminalHandle {
    #[cfg(feature = "alacritty_terminal")]
    let terminal = AlacrittyTerminal::new(cols, rows, AlacrittyTerminalConfig::default());

    #[cfg(not(feature = "alacritty_terminal"))]
    let terminal = Terminal::new(cols, rows);

    Box::into_raw(Box::new(terminal))
}

#[no_mangle]
pub unsafe extern "C" fn terminal_core_destroy(handle: *mut TerminalHandle) {
    if !handle.is_null() {
        let _ = Box::from_raw(handle);
    }
}

#[no_mangle]
pub unsafe extern "C" fn terminal_core_write(
    handle: *mut TerminalHandle,
    data: *const u8,
    len: usize,
) {
    if handle.is_null() || data.is_null() {
        return;
    }
    let bytes = slice::from_raw_parts(data, len);
    (*handle).write(bytes);
}

#[no_mangle]
pub unsafe extern "C" fn terminal_core_resize(
    handle: *mut TerminalHandle,
    cols: usize,
    rows: usize,
) {
    if !handle.is_null() {
        (*handle).resize(cols, rows);
    }
}

#[no_mangle]
pub unsafe extern "C" fn terminal_core_scroll_view(
    handle: *mut TerminalHandle,
    delta_lines: isize,
) {
    if !handle.is_null() {
        (*handle).scroll_view(delta_lines);
    }
}

#[no_mangle]
pub unsafe extern "C" fn terminal_core_scroll_to_bottom(handle: *mut TerminalHandle) {
    if !handle.is_null() {
        (*handle).scroll_to_bottom();
    }
}

/// Applies the user-configured default foreground color to the active core.
///
/// ANSI/SGR colors remain authoritative for explicitly colored cells. The
/// adapter resolves only the terminal's default foreground through this value.
#[no_mangle]
pub unsafe extern "C" fn terminal_core_set_default_foreground(
    handle: *mut TerminalHandle,
    foreground: u32,
) {
    if handle.is_null() {
        return;
    }

    #[cfg(feature = "alacritty_terminal")]
    (*handle).set_default_foreground(foreground);

    #[cfg(not(feature = "alacritty_terminal"))]
    let _ = foreground;
}

#[no_mangle]
pub unsafe extern "C" fn terminal_core_snapshot(
    handle: *const TerminalHandle,
) -> *mut FfiTerminalSnapshot {
    if handle.is_null() {
        return ptr::null_mut();
    }
    snapshot_to_ffi((*handle).snapshot())
}

#[no_mangle]
pub unsafe extern "C" fn terminal_core_dirty_snapshot(
    handle: *mut TerminalHandle,
) -> *mut FfiTerminalSnapshot {
    if handle.is_null() {
        return ptr::null_mut();
    }
    snapshot_to_ffi((*handle).dirty_snapshot())
}

#[no_mangle]
pub unsafe extern "C" fn terminal_core_free_snapshot(snapshot: *mut FfiTerminalSnapshot) {
    if snapshot.is_null() {
        return;
    }
    let snapshot = Box::from_raw(snapshot);
    if !snapshot.cells_ptr.is_null() && snapshot.cells_len > 0 {
        let _ = Vec::from_raw_parts(snapshot.cells_ptr, snapshot.cells_len, snapshot.cells_len);
    }
    if !snapshot.dirty_rows_ptr.is_null() && snapshot.dirty_rows_len > 0 {
        let _ = Vec::from_raw_parts(
            snapshot.dirty_rows_ptr,
            snapshot.dirty_rows_len,
            snapshot.dirty_rows_len,
        );
    }
}

fn snapshot_to_ffi(snapshot: TerminalSnapshot) -> *mut FfiTerminalSnapshot {
    let (cells_ptr, cells_len) = leak_cells(snapshot.cells);
    let (dirty_rows_ptr, dirty_rows_len) = leak_usize_vec(snapshot.dirty_rows);
    Box::into_raw(Box::new(FfiTerminalSnapshot {
        cols: snapshot.cols,
        rows: snapshot.rows,
        cursor_x: snapshot.cursor_x,
        cursor_y: snapshot.cursor_y,
        cursor_visible: snapshot.cursor_visible,
        bracketed_paste: snapshot.bracketed_paste,
        mouse_tracking: snapshot.mouse_tracking,
        sgr_mouse: snapshot.sgr_mouse,
        application_cursor_keys: snapshot.application_cursor_keys,
        application_keypad: snapshot.application_keypad,
        auto_wrap: snapshot.auto_wrap,
        view_top: snapshot.view_top,
        screen_top: snapshot.screen_top,
        is_at_bottom: snapshot.is_at_bottom,
        dirty_rows_ptr,
        dirty_rows_len,
        cells_ptr,
        cells_len,
    }))
}

fn leak_cells(cells: Vec<SnapshotCell>) -> (*mut FfiSnapshotCell, usize) {
    let ffi_cells: Vec<FfiSnapshotCell> = cells
        .into_iter()
        .map(|cell| FfiSnapshotCell {
            ch: cell.ch as u32,
            fg: cell.fg,
            bg: cell.bg,
            bold: cell.bold,
            italic: cell.italic,
            underline: cell.underline,
            inverse: cell.inverse,
            wide: cell.wide,
            wide_continuation: cell.wide_continuation,
        })
        .collect();
    leak_vec(ffi_cells)
}

fn leak_usize_vec(values: Vec<usize>) -> (*mut usize, usize) {
    leak_vec(values)
}

fn leak_vec<T>(values: Vec<T>) -> (*mut T, usize) {
    let mut values = values.into_boxed_slice();
    let ptr = values.as_mut_ptr();
    let len = values.len();
    std::mem::forget(values);
    (ptr, len)
}
