use super::cell::{DEFAULT_BG, DEFAULT_FG};
use super::ffi::{
    terminal_core_create, terminal_core_destroy, terminal_core_free_snapshot,
    terminal_core_snapshot, terminal_core_write,
};
use super::Terminal;

fn screen_text(term: &Terminal) -> Vec<String> {
    let snap = term.snapshot();
    snap.cells
        .chunks(snap.cols)
        .map(|row| row.iter().map(|cell| cell.ch).collect::<String>())
        .collect()
}

#[test]
fn writes_plain_text_in_order() {
    let mut term = Terminal::new(8, 3);
    term.write(b"hello");

    let rows = screen_text(&term);
    assert_eq!(&rows[0][..5], "hello");
    assert_eq!(term.snapshot().cursor_x, 5);
}

#[test]
fn newline_and_carriage_return_move_cursor() {
    let mut term = Terminal::new(8, 3);
    term.write(b"abc\rZ\nx");

    let rows = screen_text(&term);
    assert_eq!(&rows[0][..3], "Zbc");
    assert_eq!(&rows[1][1..2], "x");
}

#[test]
fn backspace_does_not_underflow() {
    let mut term = Terminal::new(8, 3);
    term.write(b"\x08\x08ab\x08Z");

    let rows = screen_text(&term);
    assert_eq!(&rows[0][..2], "aZ");
    assert_eq!(term.snapshot().cursor_x, 2);
}

#[test]
fn cursor_left_crosses_soft_wrapped_line_boundary() {
    let mut term = Terminal::new(4, 3);
    term.write(b"abcde");
    assert_eq!(term.snapshot().cursor_x, 1);
    assert_eq!(term.snapshot().cursor_y, 1);

    term.write(b"\x1b[D\x1b[D");

    let snap = term.snapshot();
    assert_eq!(snap.cursor_x, 3);
    assert_eq!(snap.cursor_y, 0);
}

#[test]
fn cursor_right_crosses_soft_wrapped_line_boundary() {
    let mut term = Terminal::new(4, 3);
    term.write(b"abcde");
    term.write(b"\x1b[D\x1b[D");

    term.write(b"\x1b[C");

    let snap = term.snapshot();
    assert_eq!(snap.cursor_x, 0);
    assert_eq!(snap.cursor_y, 1);
}

#[test]
fn backspace_does_not_cross_soft_wrapped_line_boundary() {
    let mut term = Terminal::new(4, 3);
    term.write(b"abcde");

    term.write(b"\x08\x08");

    let snap = term.snapshot();
    assert_eq!(snap.cursor_x, 0);
    assert_eq!(snap.cursor_y, 1);
}

#[test]
fn cursor_left_does_not_cross_hard_newline_boundary() {
    let mut term = Terminal::new(4, 3);
    term.write(b"abc\r\nd");

    term.write(b"\x1b[D\x1b[D");

    let snap = term.snapshot();
    assert_eq!(snap.cursor_x, 0);
    assert_eq!(snap.cursor_y, 1);
}

#[test]
fn clear_line_from_cursor_breaks_soft_wrap_boundary() {
    let mut term = Terminal::new(4, 3);
    term.write(b"abcde");

    term.write(b"\x1b[1;3H\x1b[K");
    term.write(b"\x1b[2;1H\x1b[D");

    let snap = term.snapshot();
    assert_eq!(snap.cursor_x, 0);
    assert_eq!(snap.cursor_y, 1);
}

#[test]
fn clear_screen_from_cursor_breaks_soft_wrap_boundary() {
    let mut term = Terminal::new(4, 3);
    term.write(b"abcde");

    term.write(b"\x1b[1;3H\x1b[J");
    term.write(b"\x1b[2;1H\x1b[D");

    let snap = term.snapshot();
    assert_eq!(snap.cursor_x, 0);
    assert_eq!(snap.cursor_y, 1);
}

#[test]
fn clear_screen_to_cursor_breaks_soft_wrap_boundary() {
    let mut term = Terminal::new(4, 3);
    term.write(b"abcde");

    term.write(b"\x1b[2;1H\x1b[1J");
    term.write(b"\x1b[D");

    let snap = term.snapshot();
    assert_eq!(snap.cursor_x, 0);
    assert_eq!(snap.cursor_y, 1);
}

#[test]
fn delete_chars_breaks_soft_wrap_boundary() {
    let mut term = Terminal::new(4, 3);
    term.write(b"abcde");

    term.write(b"\x1b[1;3H\x1b[P");
    term.write(b"\x1b[2;1H\x1b[D");

    let snap = term.snapshot();
    assert_eq!(snap.cursor_x, 0);
    assert_eq!(snap.cursor_y, 1);
}

#[test]
fn clear_screen_resets_visible_cells() {
    let mut term = Terminal::new(8, 3);
    term.write(b"abc\nxyz\x1b[2J");

    let rows = screen_text(&term);
    assert!(rows.iter().all(|row| row.trim().is_empty()));
    let snap = term.snapshot();
    assert_eq!(snap.cursor_x, 0);
    assert_eq!(snap.cursor_y, 0);
    assert_eq!(snap.screen_top, 0);
    assert_eq!(snap.view_top, 0);
}

#[test]
fn sgr_color_applies_and_resets() {
    let mut term = Terminal::new(8, 2);
    term.write(b"\x1b[1;31mR\x1b[0mN");

    let snap = term.snapshot();
    assert_ne!(snap.cells[0].fg, DEFAULT_FG);
    assert_eq!(snap.cells[0].bg, DEFAULT_BG);
    assert!(snap.cells[0].bold);
    assert_eq!(snap.cells[1].fg, DEFAULT_FG);
    assert!(!snap.cells[1].bold);
}

#[test]
fn clear_line_modes_work() {
    let mut term = Terminal::new(8, 3);
    term.write(b"abcdefgh\r\nijklmnop\r\nqrstuvwx");

    term.write(b"\x1b[2;4H\x1b[K");
    let rows = screen_text(&term);
    assert_eq!(&rows[1], "ijk     ");

    term.write(b"\x1b[3;5H\x1b[1K");
    let rows = screen_text(&term);
    assert_eq!(&rows[2], "     vwx");
}

#[test]
fn clear_screen_partial_modes_work() {
    let mut term = Terminal::new(8, 3);
    term.write(b"abcdefgh\r\nijklmnop\r\nqrstuvwx");

    term.write(b"\x1b[2;4H\x1b[J");
    let rows = screen_text(&term);
    assert_eq!(&rows[0], "abcdefgh");
    assert_eq!(&rows[1], "ijk     ");
    assert_eq!(&rows[2], "        ");

    term.write(b"ABCDEFGH\r\nIJKLMNOP\r\nQRSTUVWX");
    term.write(b"\x1b[2;4H\x1b[1J");
    let rows = screen_text(&term);
    assert_eq!(&rows[0], "        ");
    assert_eq!(&rows[1], "    MNOP");
    assert_eq!(&rows[2], "QRSTUVWX");
}

#[test]
fn cursor_visibility_private_mode_updates_snapshot() {
    let mut term = Terminal::new(8, 2);
    term.write(b"\x1b[?25l");
    assert!(!term.snapshot().cursor_visible);

    term.write(b"\x1b[?25h");
    assert!(term.snapshot().cursor_visible);
}

#[test]
fn writing_past_bottom_scrolls_active_screen() {
    let mut term = Terminal::new(4, 2);
    term.write(b"1\r\n2\r\n3");

    let rows = screen_text(&term);
    assert_eq!(&rows[0][..1], "2");
    assert_eq!(&rows[1][..1], "3");
    assert_eq!(term.snapshot().screen_top, 1);
}

#[test]
fn primary_full_screen_scroll_preserves_scrollback() {
    let mut term = Terminal::new(4, 2);
    term.write(b"1\r\n2\r\n3");

    let at_bottom = term.snapshot();
    assert_eq!(at_bottom.screen_top, 1);
    assert_eq!(at_bottom.view_top, at_bottom.screen_top);

    term.scroll_view(-1);
    let rows = screen_text(&term);
    assert_eq!(&rows[0][..1], "1");
    assert_eq!(&rows[1][..1], "2");
    assert!(!term.snapshot().is_at_bottom);
}

#[test]
fn user_scroll_changes_view_not_cursor_or_screen() {
    let mut term = Terminal::new(4, 2);
    term.write(b"1\r\n2\r\n3");
    let before = term.snapshot();

    term.scroll_view(-1);
    let after = term.snapshot();

    assert_eq!(after.screen_top, before.screen_top);
    assert_eq!(after.cursor_x, before.cursor_x);
    assert_eq!(after.cursor_y, before.cursor_y);
    assert_eq!(after.view_top, before.view_top.saturating_sub(1));
    assert!(!after.is_at_bottom);
}

#[test]
fn new_output_follows_only_when_at_bottom() {
    let mut term = Terminal::new(4, 2);
    term.write(b"1\r\n2\r\n3");
    term.scroll_view(-1);
    let parked = term.snapshot().view_top;

    term.write(b"\r\n4");
    assert_eq!(term.snapshot().view_top, parked);
    let parked_rows = screen_text(&term);
    assert_eq!(&parked_rows[0][..1], "1");
    assert_eq!(&parked_rows[1][..1], "2");

    term.scroll_to_bottom();
    term.write(b"\r\n5");
    let snap = term.snapshot();
    assert_eq!(snap.view_top, snap.screen_top);
}

#[test]
fn cursor_move_marks_old_and_new_rows_dirty() {
    let mut term = Terminal::new(6, 3);
    term.write(b"row0\r\nrow1");
    term.dirty_snapshot();

    term.write(b"\x1b[1;1H");
    let dirty = term.dirty_snapshot().dirty_rows;

    assert!(dirty.contains(&0));
    assert!(dirty.contains(&1));
}

#[test]
fn cursor_wrap_move_marks_old_and_new_rows_dirty() {
    let mut term = Terminal::new(4, 3);
    term.write(b"abcde");
    term.dirty_snapshot();

    term.write(b"\x1b[D\x1b[D");
    let dirty = term.dirty_snapshot().dirty_rows;

    assert!(dirty.contains(&0));
    assert!(dirty.contains(&1));
}

#[test]
fn full_screen_scroll_marks_all_visible_rows_dirty() {
    let mut term = Terminal::new(4, 2);
    term.write(b"1\r\n2");
    term.dirty_snapshot();

    term.write(b"\r\n3");
    let dirty = term.dirty_snapshot().dirty_rows;

    assert_eq!(dirty, vec![0, 1]);
}

#[test]
fn resize_clamps_cursor_and_preserves_bottom_following() {
    let mut term = Terminal::new(8, 3);
    term.write(b"abcdef\nline2\nline3");
    term.resize(4, 2);

    let snap = term.snapshot();
    assert_eq!(snap.cols, 4);
    assert_eq!(snap.rows, 2);
    assert!(snap.cursor_x < 4);
    assert!(snap.cursor_y < 2);
    assert_eq!(snap.view_top, snap.screen_top);
}

#[test]
fn scrollback_trim_keeps_snapshot_bounded_and_at_bottom() {
    let mut term = Terminal::new(8, 2);
    for i in 0..3105 {
        let line = format!("{i:04}\r\n");
        term.write(line.as_bytes());
    }

    let snap = term.snapshot();
    assert_eq!(snap.cells.len(), snap.cols * snap.rows);
    assert_eq!(snap.view_top, snap.screen_top);
    assert!(snap.screen_top <= 2998);
}

#[test]
fn ffi_snapshot_roundtrip_exposes_cells_and_metadata() {
    unsafe {
        let handle = terminal_core_create(8, 2);
        assert!(!handle.is_null());

        terminal_core_write(handle, b"ok".as_ptr(), 2);
        let snapshot = terminal_core_snapshot(handle);
        assert!(!snapshot.is_null());

        assert_eq!((*snapshot).cols, 8);
        assert_eq!((*snapshot).rows, 2);
        assert_eq!((*snapshot).cells_len, 16);
        assert!(!(*snapshot).cells_ptr.is_null());
        assert_eq!((*(*snapshot).cells_ptr).ch, 'o' as u32);

        terminal_core_free_snapshot(snapshot);
        terminal_core_destroy(handle);
    }
}

// ── 备用屏 (Alternate Screen) ──────────────────────────────────────────

#[test]
fn alt_screen_enter_leave_restores_main() {
    let mut term = Terminal::new(8, 3);
    // 主屏写入内容
    term.write(b"main");
    let main_rows = screen_text(&term);
    assert_eq!(&main_rows[0][..4], "main");

    // 进入备用屏 (?1049h 风格: enter + clear)
    term.write(b"\x1b[?1049h");
    assert!(term.snapshot().screen_top == 0);
    // 备用屏应为空
    let alt_rows = screen_text(&term);
    assert!(alt_rows.iter().all(|r| r.trim().is_empty()));

    // 在备用屏写内容
    term.write(b"nano");
    let alt_rows2 = screen_text(&term);
    assert_eq!(&alt_rows2[0][..4], "nano");

    // 退出备用屏
    term.write(b"\x1b[?1049l");
    let restored = screen_text(&term);
    assert_eq!(&restored[0][..4], "main");
    // nano 内容不应出现
    for row in &restored {
        assert!(!row.contains("nano"));
    }
}

#[test]
fn alt_screen_has_independent_cursor() {
    let mut term = Terminal::new(8, 3);
    // 主屏光标在 (3, 0)
    term.write(b"abc");
    assert_eq!(term.snapshot().cursor_x, 3);

    // 进入备用屏
    term.write(b"\x1b[?1049h");
    let snap = term.snapshot();
    assert_eq!(snap.cursor_x, 0);
    assert_eq!(snap.cursor_y, 0);

    // 备用屏移动光标
    term.write(b"xy");
    assert_eq!(term.snapshot().cursor_x, 2);

    // 退出
    term.write(b"\x1b[?1049l");
    // 主屏光标恢复
    assert_eq!(term.snapshot().cursor_x, 3);
}

#[test]
fn alt_screen_independent_buffer() {
    let mut term = Terminal::new(8, 3);
    term.write(b"MAIN");
    let main_snap = term.snapshot();

    // 进入备用屏
    term.write(b"\x1b[?1049h");
    // 备用屏写不同内容
    term.write(b"ALT");
    let alt_snap = term.snapshot();
    assert_ne!(alt_snap.cells[0].ch, main_snap.cells[0].ch);

    // 退出
    term.write(b"\x1b[?1049l");
    let restore_snap = term.snapshot();
    assert_eq!(restore_snap.cells[0].ch, main_snap.cells[0].ch);
    assert_eq!(restore_snap.cells[1].ch, main_snap.cells[1].ch);
}

#[test]
fn alt_screen_csi_47_enter_leave() {
    let mut term = Terminal::new(8, 3);
    term.write(b"hello");
    // ?47h 进入 (不清屏)
    term.write(b"\x1b[?47h");
    term.write(b"world");
    // ?47l 退出
    term.write(b"\x1b[?47l");
    let rows = screen_text(&term);
    assert_eq!(&rows[0][..5], "hello");
}

#[test]
fn alt_screen_scroll_does_not_extend_main_scrollback() {
    let mut term = Terminal::new(4, 2);
    term.write(b"1\r\n2\r\n3");
    let main = term.snapshot();
    assert_eq!(main.screen_top, 1);

    term.write(b"\x1b[?1049h");
    term.write(b"a\r\nb\r\nc\r\nd");
    assert_eq!(term.snapshot().screen_top, 0);

    term.write(b"\x1b[?1049l");
    let restored = term.snapshot();
    assert_eq!(restored.screen_top, main.screen_top);
    assert_eq!(restored.view_top, main.view_top);
    let rows = screen_text(&term);
    assert_eq!(&rows[0][..1], "2");
    assert_eq!(&rows[1][..1], "3");
}

// ── 光标保存/恢复 ──────────────────────────────────────────────────────

#[test]
fn save_restore_cursor_esc_7_8() {
    let mut term = Terminal::new(8, 3);
    term.write(b"abcdef");
    // 保存光标+属性 (在 'f' 后面, col=6)
    term.write(b"\x1b7");
    // 移动光标
    term.write(b"\x1b[1;1H");
    assert_eq!(term.snapshot().cursor_x, 0);
    // 恢复
    term.write(b"\x1b8");
    assert_eq!(term.snapshot().cursor_x, 6);
}

#[test]
fn save_restore_cursor_csi_s_u() {
    let mut term = Terminal::new(8, 3);
    term.write(b"abcd");
    // CSI s 保存位置
    term.write(b"\x1b[s");
    // 移动
    term.write(b"\x1b[3;1H");
    assert_eq!(term.snapshot().cursor_y, 2);
    // CSI u 恢复
    term.write(b"\x1b[u");
    let snap = term.snapshot();
    assert_eq!(snap.cursor_x, 4);
    assert_eq!(snap.cursor_y, 0);
}

#[test]
fn esc_7_8_preserves_attrs() {
    let mut term = Terminal::new(8, 2);
    // 设置红色粗体
    term.write(b"\x1b[1;31mR");
    term.write(b"\x1b7");
    // 重置属性
    term.write(b"\x1b[0mN");
    let snap_after_reset = term.snapshot();
    assert!(!snap_after_reset.cells[1].bold);

    // 恢复
    term.write(b"\x1b8");
    term.write(b"X");
    let snap = term.snapshot();
    // 恢复后写的字符应该有粗体属性
    assert!(snap.cells[1].bold);
    assert_ne!(snap.cells[1].fg, DEFAULT_FG);
}

// ── 滚动区域 ──────────────────────────────────────────────────────────

#[test]
fn scroll_region_only_scrolls_selected_rows() {
    let mut term = Terminal::new(6, 5);
    // 填满 5 行
    term.write(b"row0\r\nrow1\r\nrow2\r\nrow3\r\nrow4");
    // 设置滚动区域: 第2行到第4行 (1-indexed)
    term.write(b"\x1b[2;4r");
    // 光标移到第4行, 再换行触发区域滚动
    term.write(b"\x1b[4;1H");
    term.write(b"\r\n");
    term.write(b"NEW");

    let rows = screen_text(&term);
    // 第1行 (row0) 应该不受影响
    assert_eq!(&rows[0][..4], "row0");
    // 原来第3行 (row2) 滚到第2行
    assert_eq!(&rows[1][..4], "row2");
    // 原来的第4行 (row3) 滚到第3行
    assert_eq!(&rows[2][..4], "row3");
    // 原来的第4行应该滚上来了, 第4行是 NEW
    assert_eq!(&rows[3][..3], "NEW");
    // 第5行 (row4) 在区域外, 不受影响
    assert_eq!(&rows[4][..4], "row4");
}

#[test]
fn partial_scroll_region_does_not_create_main_scrollback() {
    let mut term = Terminal::new(6, 5);
    term.write(b"row0\r\nrow1\r\nrow2\r\nrow3\r\nrow4");
    term.write(b"\x1b[2;4r");
    term.write(b"\x1b[4;1H\r\n");

    let snap = term.snapshot();
    assert_eq!(snap.screen_top, 0);
    assert_eq!(snap.view_top, 0);
}

#[test]
fn scroll_region_reset_to_full_screen() {
    let mut term = Terminal::new(6, 5);
    // 设置区域
    term.write(b"\x1b[2;4r");
    // 重置
    term.write(b"\x1b[r");
    // 验证: 光标移到顶行, 换行应该全屏滚动
    term.write(b"row0\r\nrow1\r\nrow2\r\nrow3\r\nrow4\r\nrow5");
    let snap = term.snapshot();
    assert_eq!(snap.screen_top, 1); // 全屏滚了一行
}

// ── 光标绝对定位 ──────────────────────────────────────────────────────

#[test]
fn cursor_absolute_column_csi_G() {
    let mut term = Terminal::new(10, 3);
    term.write(b"abcdefghij");
    // 设置光标到第5列 (0-indexed: 4)
    term.write(b"\x1b[5G");
    assert_eq!(term.snapshot().cursor_x, 4);
    term.write(b"X");
    let rows = screen_text(&term);
    assert_eq!(&rows[0][..6], "abcdXf");
}

#[test]
fn cursor_absolute_row_csi_d() {
    let mut term = Terminal::new(8, 3);
    term.write(b"line0\r\nline1\r\nline2");
    // 移到第2行
    term.write(b"\x1b[2d");
    assert_eq!(term.snapshot().cursor_y, 1);
    term.write(b"X");
    let rows = screen_text(&term);
    assert_eq!(&rows[1][..6], "line1X");
}

// ── 字符编辑 ──────────────────────────────────────────────────────────

#[test]
fn insert_chars_shifts_right() {
    let mut term = Terminal::new(8, 2);
    term.write(b"abcdefgh");
    // 光标移到第3列 (0-indexed: 2)
    term.write(b"\x1b[3G");
    // 插入 2 个字符
    term.write(b"\x1b[2@");
    term.write(b"XY");

    let rows = screen_text(&term);
    assert_eq!(&rows[0][..8], "abXYcdef");
}

#[test]
fn delete_chars_shifts_left() {
    let mut term = Terminal::new(8, 2);
    term.write(b"abcdefgh");
    // 光标移到第3列
    term.write(b"\x1b[3G");
    // 删除 2 个字符
    term.write(b"\x1b[2P");

    let rows = screen_text(&term);
    assert_eq!(&rows[0][..6], "abefgh");
    // 尾部补空白
    assert!(rows[0][6..].trim().is_empty());
}

#[test]
fn erase_chars_replaces_with_blanks() {
    let mut term = Terminal::new(8, 2);
    term.write(b"abcdefgh");
    // 光标移到第3列
    term.write(b"\x1b[3G");
    // 擦除 3 个字符
    term.write(b"\x1b[3X");

    let rows = screen_text(&term);
    assert_eq!(&rows[0][..2], "ab");
    assert_eq!(&rows[0][5..8], "fgh");
    assert!(rows[0][2..5].trim().is_empty());
}

// ── 行编辑 ────────────────────────────────────────────────────────────

#[test]
fn insert_lines_in_scroll_region() {
    let mut term = Terminal::new(6, 5);
    term.write(b"row0\r\nrow1\r\nrow2\r\nrow3\r\nrow4");
    // 设置滚动区域: 全屏 (默认)
    // 光标移到第3行
    term.write(b"\x1b[3;1H");
    // 插入 1 行
    term.write(b"\x1b[1L");

    let rows = screen_text(&term);
    // 第3行应为空白
    assert!(rows[2].trim().is_empty());
    // 原来的第3行 (row2) 下移到第4行
    assert_eq!(&rows[3][..4], "row2");
}

#[test]
fn delete_lines_in_scroll_region() {
    let mut term = Terminal::new(6, 5);
    term.write(b"row0\r\nrow1\r\nrow2\r\nrow3\r\nrow4");
    // 光标移到第3行
    term.write(b"\x1b[3;1H");
    // 删除 1 行
    term.write(b"\x1b[1M");

    let rows = screen_text(&term);
    // 原来的第4行 (row3) 上移到第3行
    assert_eq!(&rows[2][..4], "row3");
    // 第5行应为空白
    assert!(rows[4].trim().is_empty());
}

// ── SGR: 256 色 + 真彩色 ───────────────────────────────────────────────

#[test]
fn sgr_256_color_fg_bg() {
    let mut term = Terminal::new(4, 2);
    // 前景色: 256色索引 196 (红色), 背景色: 256色索引 21 (蓝色)
    term.write(b"\x1b[38;5;196;48;5;21mX");

    let snap = term.snapshot();
    // 前景应为红色 (196 → RGB(255,0,0))
    let fg = snap.cells[0].fg;
    assert_eq!((fg >> 16) & 0xFF, 0xFF); // R=255
    assert_eq!((fg >> 8) & 0xFF, 0); // G=0
    assert_eq!(fg & 0xFF, 0); // B=0

    // 背景应为蓝色 (21 → RGB(0,0,255))
    let bg = snap.cells[0].bg;
    assert_eq!((bg >> 16) & 0xFF, 0); // R=0
    assert_eq!((bg >> 8) & 0xFF, 0); // G=0
    assert_eq!(bg & 0xFF, 0xFF); // B=255
}

#[test]
fn sgr_truecolor_fg_bg() {
    let mut term = Terminal::new(4, 2);
    // 前景色: RGB(255, 128, 0), 背景色: RGB(64, 224, 208)
    term.write(b"\x1b[38;2;255;128;0;48;2;64;224;208mT");

    let snap = term.snapshot();
    let fg = snap.cells[0].fg;
    assert_eq!((fg >> 16) & 0xFF, 255);
    assert_eq!((fg >> 8) & 0xFF, 128);
    assert_eq!(fg & 0xFF, 0);

    let bg = snap.cells[0].bg;
    assert_eq!((bg >> 16) & 0xFF, 64);
    assert_eq!((bg >> 8) & 0xFF, 224);
    assert_eq!(bg & 0xFF, 208);
}

#[test]
fn sgr_truecolor_partial_params_are_safe() {
    let mut term = Terminal::new(4, 2);
    // 不完整的序列 — 不应 panic
    term.write(b"\x1b[38;2;255mX"); // 只有 R, 缺 G B
    term.write(b"\x1b[48;2mY"); // 没有颜色分量
                                // 只验证不崩溃
    assert_eq!(term.snapshot().cols, 4);
}

// ── 私有模式安全处理 ──────────────────────────────────────────────────

#[test]
fn unknown_private_modes_dont_print_garbage() {
    let mut term = Terminal::new(4, 2);
    // 未知私有模式 set/reset
    term.write(b"\x1b[?9999h");
    term.write(b"\x1b[?9999l");
    term.write(b"\x1b[?1000h"); // 鼠标追踪 ON
    term.write(b"\x1b[?2004h"); // bracketed paste ON

    // 屏幕应为空白 (没有垃圾字符)
    let rows = screen_text(&term);
    assert!(rows.iter().all(|r| r.trim().is_empty()));
}

// ── Resize 兼容性 ─────────────────────────────────────────────────────

#[test]
fn resize_during_alt_screen_stays_bounded() {
    let mut term = Terminal::new(8, 3);
    term.write(b"\x1b[?1049h");
    term.write(b"hello world");
    // 改变尺寸
    term.resize(4, 2);

    let snap = term.snapshot();
    assert_eq!(snap.cols, 4);
    assert_eq!(snap.rows, 2);
    assert!(snap.cursor_x < 4);
    assert!(snap.cursor_y < 2);
}

// ── 反向索引 ──────────────────────────────────────────────────────────

#[test]
fn reverse_index_moves_cursor_up() {
    let mut term = Terminal::new(6, 3);
    term.write(b"row0\r\nrow1\r\nrow2");
    // 光标移到底行
    term.write(b"\x1b[3;1H");
    assert_eq!(term.snapshot().cursor_y, 2);

    // 反向索引 (ESC M)
    term.write(b"\x1bM");
    assert_eq!(term.snapshot().cursor_y, 1);
}
