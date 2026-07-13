use unicode_width::UnicodeWidthChar;
use vte::Parser;

use super::cell::{xterm_256_color, Cell, CellAttrs, DEFAULT_BG, DEFAULT_FG};
use super::grid::{blank_row, resize_row, Row};
use super::parser::TerminalPerformer;
use super::snapshot::{SnapshotCell, TerminalSnapshot};

const MAX_SCROLLBACK: usize = 3000;

/// 保存的光标状态 — 用于 DECSC/DECRC (ESC 7/8) 和 SCOSC/SCORC (CSI s/u)
#[derive(Clone, Debug)]
struct SavedCursor {
    x: usize,
    y: usize,
    attrs: CellAttrs,
}

pub struct Terminal {
    cols: usize,
    rows: usize,
    cursor_x: usize,
    cursor_y: usize,
    screen_top: usize,
    view_top: usize,
    buffer: Vec<Row>,
    wrapped_rows: Vec<bool>,
    dirty_rows: Vec<usize>,
    attrs: CellAttrs,
    cursor_visible: bool,
    parser: Parser,

    // 备用屏 (alternate screen)
    alt_active: bool,
    /// 保存的主屏 buffer (进入备用屏时暂存)
    main_buffer: Vec<Row>,
    main_wrapped_rows: Vec<bool>,
    main_screen_top: usize,
    main_view_top: usize,
    main_cursor_x: usize,
    main_cursor_y: usize,
    main_attrs: CellAttrs,

    // 光标保存 (DECSC/DECRC + SCOSC/SCORC)
    saved_cursor: Option<SavedCursor>,

    // 滚动区域 (CSI r), 0-indexed, 含两端
    scroll_top: usize,
    scroll_bottom: usize,
}

impl Terminal {
    pub fn new(cols: usize, rows: usize) -> Self {
        let cols = cols.max(1);
        let rows = rows.max(1);
        let attrs = CellAttrs::default();
        Self {
            cols,
            rows,
            cursor_x: 0,
            cursor_y: 0,
            screen_top: 0,
            view_top: 0,
            buffer: (0..rows).map(|_| blank_row(cols, attrs)).collect(),
            wrapped_rows: vec![false; rows],
            dirty_rows: (0..rows).collect(),
            attrs,
            cursor_visible: true,
            parser: Parser::new(),

            alt_active: false,
            main_buffer: Vec::new(),
            main_wrapped_rows: Vec::new(),
            main_screen_top: 0,
            main_view_top: 0,
            main_cursor_x: 0,
            main_cursor_y: 0,
            main_attrs: CellAttrs::default(),

            saved_cursor: None,

            scroll_top: 0,
            scroll_bottom: rows.saturating_sub(1),
        }
    }

    pub fn cols(&self) -> usize {
        self.cols
    }

    pub fn rows(&self) -> usize {
        self.rows
    }

    pub fn write(&mut self, bytes: &[u8]) {
        let was_at_bottom = self.is_at_bottom();
        let mut parser = std::mem::replace(&mut self.parser, Parser::new());
        {
            let mut performer = TerminalPerformer::new(self);
            parser.advance(&mut performer, bytes);
        }
        self.parser = parser;
        if was_at_bottom {
            self.scroll_to_bottom();
        }
    }

    pub fn resize(&mut self, cols: usize, rows: usize) {
        let was_at_bottom = self.is_at_bottom();
        self.cols = cols.max(1);
        self.rows = rows.max(1);

        // 调整当前活动 buffer
        for row in &mut self.buffer {
            resize_row(row, self.cols, self.attrs);
        }
        self.wrapped_rows.resize(self.buffer.len(), false);
        for wrapped in &mut self.wrapped_rows {
            *wrapped = false;
        }
        // 如果备用屏激活, 也调整保存的主屏 buffer
        if self.alt_active {
            for row in &mut self.main_buffer {
                resize_row(row, self.cols, self.attrs);
            }
            self.main_wrapped_rows.resize(self.main_buffer.len(), false);
            for wrapped in &mut self.main_wrapped_rows {
                *wrapped = false;
            }
        }
        self.ensure_abs_row(self.screen_top + self.rows.saturating_sub(1));

        self.cursor_x = self.cursor_x.min(self.cols.saturating_sub(1));
        self.cursor_y = self.cursor_y.min(self.rows.saturating_sub(1));
        self.screen_top = self.screen_top.min(self.max_screen_top());
        self.view_top = if was_at_bottom {
            self.screen_top
        } else {
            self.view_top.min(self.screen_top)
        };

        // 重置滚动区域为全屏
        self.scroll_bottom = self.rows.saturating_sub(1);

        self.mark_all_dirty();
    }

    pub fn scroll_view(&mut self, delta_lines: isize) {
        if delta_lines == 0 {
            return;
        }
        let next = if delta_lines > 0 {
            self.view_top.saturating_add(delta_lines as usize)
        } else {
            self.view_top.saturating_sub(delta_lines.unsigned_abs())
        };
        let clamped = next.min(self.screen_top);
        if clamped != self.view_top {
            self.view_top = clamped;
            self.mark_all_dirty();
        }
    }

    pub fn scroll_to_bottom(&mut self) {
        if self.view_top != self.screen_top {
            self.view_top = self.screen_top;
            self.mark_all_dirty();
        }
    }

    pub fn snapshot(&self) -> TerminalSnapshot {
        self.make_snapshot(None)
    }

    pub fn dirty_snapshot(&mut self) -> TerminalSnapshot {
        let dirty = self.dirty_rows.clone();
        let snapshot = self.make_snapshot(Some(dirty));
        self.dirty_rows.clear();
        snapshot
    }

    pub fn is_at_bottom(&self) -> bool {
        self.view_top >= self.screen_top
    }

    pub(crate) fn print_char(&mut self, ch: char) {
        let width = UnicodeWidthChar::width(ch).unwrap_or(1).max(1);
        if self.cursor_x >= self.cols {
            self.mark_current_row_wrapped();
            self.cursor_x = 0;
            self.line_feed();
        }

        let abs_row = self.screen_top + self.cursor_y;
        self.ensure_abs_row(abs_row);
        self.buffer[abs_row][self.cursor_x] = Cell {
            ch,
            attrs: self.attrs,
            wide: width > 1,
            wide_continuation: false,
        };

        if width > 1 && self.cursor_x + 1 < self.cols {
            self.buffer[abs_row][self.cursor_x + 1] = Cell {
                ch: ' ',
                attrs: self.attrs,
                wide: false,
                wide_continuation: true,
            };
        }

        self.mark_dirty(self.cursor_y);
        self.cursor_x = (self.cursor_x + width).min(self.cols);
    }

    pub(crate) fn execute_byte(&mut self, byte: u8) {
        match byte {
            b'\n' => self.line_feed(),
            b'\r' => self.carriage_return(),
            0x08 => self.backspace(),
            b'\t' => self.tab(),
            _ => {}
        }
    }

    pub(crate) fn line_feed(&mut self) {
        if self.cursor_y >= self.scroll_bottom {
            self.scroll_region();
        } else {
            let old_y = self.cursor_y;
            self.cursor_y += 1;
            self.mark_cursor_moved(old_y);
        }
    }

    /// 反向索引 (RI, ESC M): 光标上移一行; 到达 scroll_top 时区域下滚
    pub(crate) fn reverse_index(&mut self) {
        if self.cursor_y <= self.scroll_top {
            self.scroll_region_down();
        } else {
            let old_y = self.cursor_y;
            self.cursor_y = self.cursor_y.saturating_sub(1);
            self.mark_cursor_moved(old_y);
        }
    }

    pub(crate) fn carriage_return(&mut self) {
        let old_y = self.cursor_y;
        self.cursor_x = 0;
        self.mark_cursor_moved(old_y);
    }

    pub(crate) fn backspace(&mut self) {
        let old_y = self.cursor_y;
        self.cursor_x = self.cursor_x.saturating_sub(1);
        self.mark_cursor_moved(old_y);
    }

    pub(crate) fn tab(&mut self) {
        let old_y = self.cursor_y;
        let next = ((self.cursor_x / 8) + 1) * 8;
        self.cursor_x = next.min(self.cols.saturating_sub(1));
        self.mark_cursor_moved(old_y);
    }

    pub(crate) fn move_cursor(&mut self, dx: isize, dy: isize) {
        let old_y = self.cursor_y;
        if dy == 0 && dx != 0 {
            self.move_cursor_horizontal(dx);
            self.mark_cursor_moved(old_y);
            return;
        }
        self.cursor_x = signed_clamp(self.cursor_x, dx, 0, self.cols.saturating_sub(1));
        self.cursor_y = signed_clamp(self.cursor_y, dy, 0, self.rows.saturating_sub(1));
        self.mark_cursor_moved(old_y);
    }

    pub(crate) fn set_cursor(&mut self, x: usize, y: usize) {
        let old_y = self.cursor_y;
        self.cursor_x = x.min(self.cols.saturating_sub(1));
        self.cursor_y = y.min(self.rows.saturating_sub(1));
        self.mark_cursor_moved(old_y);
    }

    pub(crate) fn clear_screen(&mut self) {
        self.buffer = (0..self.rows)
            .map(|_| blank_row(self.cols, self.attrs))
            .collect();
        self.wrapped_rows = vec![false; self.rows];
        self.screen_top = 0;
        self.view_top = 0;
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.scroll_top = 0;
        self.scroll_bottom = self.rows.saturating_sub(1);
        self.mark_all_dirty();
    }

    pub(crate) fn clear_screen_from_cursor(&mut self) {
        let start_abs = self.screen_top + self.cursor_y;
        self.ensure_abs_row(self.screen_top + self.rows.saturating_sub(1));
        for row in self.cursor_y..self.rows {
            let abs_row = self.screen_top + row;
            let start_col = if abs_row == start_abs {
                self.cursor_x
            } else {
                0
            };
            for col in start_col..self.cols {
                self.buffer[abs_row][col] = Cell::blank(self.attrs);
            }
            self.wrapped_rows[abs_row] = false;
            self.mark_dirty(row);
        }
    }

    pub(crate) fn clear_screen_to_cursor(&mut self) {
        self.ensure_abs_row(self.screen_top + self.rows.saturating_sub(1));
        for row in 0..=self.cursor_y.min(self.rows.saturating_sub(1)) {
            let abs_row = self.screen_top + row;
            let end_col = if row == self.cursor_y {
                self.cursor_x.min(self.cols.saturating_sub(1))
            } else {
                self.cols.saturating_sub(1)
            };
            for col in 0..=end_col {
                self.buffer[abs_row][col] = Cell::blank(self.attrs);
            }
            self.wrapped_rows[abs_row] = false;
            self.mark_dirty(row);
        }
    }

    pub(crate) fn clear_line_from_cursor(&mut self) {
        let abs_row = self.screen_top + self.cursor_y;
        self.ensure_abs_row(abs_row);
        for col in self.cursor_x..self.cols {
            self.buffer[abs_row][col] = Cell::blank(self.attrs);
        }
        self.wrapped_rows[abs_row] = false;
        self.mark_dirty(self.cursor_y);
    }

    pub(crate) fn clear_line_to_cursor(&mut self) {
        let abs_row = self.screen_top + self.cursor_y;
        self.ensure_abs_row(abs_row);
        let end_col = self.cursor_x.min(self.cols.saturating_sub(1));
        for col in 0..=end_col {
            self.buffer[abs_row][col] = Cell::blank(self.attrs);
        }
        self.wrapped_rows[abs_row] = false;
        self.mark_dirty(self.cursor_y);
    }

    pub(crate) fn clear_line(&mut self) {
        let abs_row = self.screen_top + self.cursor_y;
        self.ensure_abs_row(abs_row);
        self.buffer[abs_row] = blank_row(self.cols, self.attrs);
        self.wrapped_rows[abs_row] = false;
        self.mark_dirty(self.cursor_y);
    }

    // ── 备用屏 (Alternate Screen) ──────────────────────────────────────

    /// 进入备用屏
    pub(crate) fn enter_alt_screen(&mut self, clear: bool) {
        if self.alt_active {
            return;
        }
        // 保存主屏状态
        self.main_buffer = std::mem::take(&mut self.buffer);
        self.main_wrapped_rows = std::mem::take(&mut self.wrapped_rows);
        self.main_screen_top = self.screen_top;
        self.main_view_top = self.view_top;
        self.main_cursor_x = self.cursor_x;
        self.main_cursor_y = self.cursor_y;
        self.main_attrs = self.attrs;

        // 切换到备用屏
        self.buffer = (0..self.rows)
            .map(|_| blank_row(self.cols, self.attrs))
            .collect();
        self.wrapped_rows = vec![false; self.rows];
        self.screen_top = 0;
        self.view_top = 0;
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.scroll_top = 0;
        self.scroll_bottom = self.rows.saturating_sub(1);
        self.dirty_rows = (0..self.rows).collect();
        self.alt_active = true;

        if clear {
            self.clear_screen();
        }
    }

    /// 退出备用屏
    pub(crate) fn leave_alt_screen(&mut self, clear_alt: bool) {
        if !self.alt_active {
            return;
        }
        if clear_alt {
            // 清空备用屏 buffer (释放内存)
            self.buffer.clear();
        }
        // 恢复主屏状态
        self.buffer = std::mem::take(&mut self.main_buffer);
        self.wrapped_rows = std::mem::take(&mut self.main_wrapped_rows);
        self.screen_top = self.main_screen_top;
        self.view_top = self.main_view_top;
        self.cursor_x = self.main_cursor_x;
        self.cursor_y = self.main_cursor_y;
        self.attrs = self.main_attrs;
        self.scroll_top = 0;
        self.scroll_bottom = self.rows.saturating_sub(1);
        self.alt_active = false;

        // 确保 buffer 有足够的行
        while self.buffer.len() <= self.screen_top + self.rows.saturating_sub(1) {
            self.buffer.push(blank_row(self.cols, self.attrs));
            self.wrapped_rows.push(false);
        }
        // 确保每行宽度匹配
        for row in &mut self.buffer {
            resize_row(row, self.cols, self.attrs);
        }
        self.wrapped_rows.resize(self.buffer.len(), false);
        self.cursor_x = self.cursor_x.min(self.cols.saturating_sub(1));
        self.cursor_y = self.cursor_y.min(self.rows.saturating_sub(1));
        self.screen_top = self.screen_top.min(self.max_screen_top());
        self.view_top = self.view_top.min(self.screen_top);

        self.mark_all_dirty();
    }

    pub(crate) fn is_alt_active(&self) -> bool {
        self.alt_active
    }

    // ── 光标保存/恢复 ──────────────────────────────────────────────────

    /// DECSC (ESC 7): 保存光标位置和属性
    pub(crate) fn save_cursor_full(&mut self) {
        self.saved_cursor = Some(SavedCursor {
            x: self.cursor_x,
            y: self.cursor_y,
            attrs: self.attrs,
        });
    }

    /// DECRC (ESC 8): 恢复光标位置和属性
    pub(crate) fn restore_cursor_full(&mut self) {
        if let Some(ref saved) = self.saved_cursor {
            let old_y = self.cursor_y;
            self.cursor_x = saved.x.min(self.cols.saturating_sub(1));
            self.cursor_y = saved.y.min(self.rows.saturating_sub(1));
            self.attrs = saved.attrs;
            self.mark_cursor_moved(old_y);
        }
    }

    /// SCOSC (CSI s): 仅保存光标位置
    pub(crate) fn save_cursor_pos(&mut self) {
        if self.saved_cursor.is_none() {
            self.saved_cursor = Some(SavedCursor {
                x: 0,
                y: 0,
                attrs: CellAttrs::default(),
            });
        }
        if let Some(ref mut saved) = self.saved_cursor {
            saved.x = self.cursor_x;
            saved.y = self.cursor_y;
            // CSI s 不保存 attrs
        }
    }

    /// SCORC (CSI u): 仅恢复光标位置
    pub(crate) fn restore_cursor_pos(&mut self) {
        if let Some(ref saved) = self.saved_cursor {
            let old_y = self.cursor_y;
            self.cursor_x = saved.x.min(self.cols.saturating_sub(1));
            self.cursor_y = saved.y.min(self.rows.saturating_sub(1));
            // CSI u 不恢复 attrs
            self.mark_cursor_moved(old_y);
        }
    }

    // ── 滚动区域 ──────────────────────────────────────────────────────

    /// 设置滚动区域 (CSI r): 参数为 1-indexed, 转为 0-indexed
    pub(crate) fn set_scroll_region(&mut self, top: Option<usize>, bottom: Option<usize>) {
        let old_y = self.cursor_y;
        match (top, bottom) {
            (None, None) => {
                // CSI r — 重置为全屏
                self.scroll_top = 0;
                self.scroll_bottom = self.rows.saturating_sub(1);
            }
            (Some(t), None) => {
                // 只有 top 参数 — 设置 top, bottom 保持或重置
                self.scroll_top = t.saturating_sub(1).min(self.rows.saturating_sub(1));
                self.scroll_bottom = self.rows.saturating_sub(1);
            }
            (Some(t), Some(b)) => {
                let top_idx = t.saturating_sub(1).min(self.rows.saturating_sub(1));
                let bot_idx = b.saturating_sub(1).min(self.rows.saturating_sub(1));
                if top_idx < bot_idx {
                    self.scroll_top = top_idx;
                    self.scroll_bottom = bot_idx;
                }
            }
            (None, Some(_)) => {
                // 无效组合, 忽略
            }
        }
        // 光标移到左上角
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.mark_cursor_moved(old_y);
    }

    // ── 光标绝对定位 ──────────────────────────────────────────────────

    /// CHA (CSI G): 光标水平绝对定位 (1-indexed → 0-indexed)
    pub(crate) fn cursor_absolute_col(&mut self, col: usize) {
        let old_y = self.cursor_y;
        self.cursor_x = col.saturating_sub(1).min(self.cols.saturating_sub(1));
        self.mark_cursor_moved(old_y);
    }

    /// VPA (CSI d): 光标垂直绝对定位 (1-indexed → 0-indexed)
    pub(crate) fn cursor_absolute_row(&mut self, row: usize) {
        let old_y = self.cursor_y;
        self.cursor_y = row.saturating_sub(1).min(self.rows.saturating_sub(1));
        self.mark_cursor_moved(old_y);
    }

    /// CNL (CSI E): 光标下移 N 行并回到行首
    pub(crate) fn cursor_next_line(&mut self, n: usize) {
        let old_y = self.cursor_y;
        self.cursor_y = (self.cursor_y + n).min(self.rows.saturating_sub(1));
        self.cursor_x = 0;
        self.mark_cursor_moved(old_y);
    }

    /// CPL (CSI F): 光标上移 N 行并回到行首
    pub(crate) fn cursor_prev_line(&mut self, n: usize) {
        let old_y = self.cursor_y;
        self.cursor_y = self.cursor_y.saturating_sub(n);
        self.cursor_x = 0;
        self.mark_cursor_moved(old_y);
    }

    // ── 字符/行编辑 ────────────────────────────────────────────────────

    /// ICH (CSI @): 在光标处插入 N 个空白字符, 右侧字符右移
    pub(crate) fn insert_chars(&mut self, n: usize) {
        let n = n.max(1);
        let abs_row = self.screen_top + self.cursor_y;
        self.ensure_abs_row(abs_row);
        let row = &mut self.buffer[abs_row];

        let shift = n.min(self.cols.saturating_sub(self.cursor_x));
        if shift > 0 {
            // 从右往左移动字符
            for i in (self.cursor_x..self.cols.saturating_sub(shift)).rev() {
                row[i + shift] = row[i].clone();
            }
            // 插入空白
            for i in self.cursor_x..self.cursor_x + shift {
                row[i] = Cell::blank(self.attrs);
            }
            self.wrapped_rows[abs_row] = false;
            self.mark_dirty(self.cursor_y);
        }
    }

    /// DCH (CSI P): 删除光标处 N 个字符, 右侧字符左移
    pub(crate) fn delete_chars(&mut self, n: usize) {
        let n = n.max(1);
        let abs_row = self.screen_top + self.cursor_y;
        self.ensure_abs_row(abs_row);
        let row = &mut self.buffer[abs_row];

        let del = n.min(self.cols.saturating_sub(self.cursor_x));
        if del > 0 {
            // 左移
            for i in self.cursor_x..self.cols.saturating_sub(del) {
                row[i] = row[i + del].clone();
            }
            // 尾部补空白
            for i in self.cols.saturating_sub(del)..self.cols {
                row[i] = Cell::blank(self.attrs);
            }
            self.wrapped_rows[abs_row] = false;
            self.mark_dirty(self.cursor_y);
        }
    }

    /// ECH (CSI X): 光标处 N 个字符替换为空白 (不位移)
    pub(crate) fn erase_chars(&mut self, n: usize) {
        let n = n.max(1);
        let abs_row = self.screen_top + self.cursor_y;
        self.ensure_abs_row(abs_row);
        let row = &mut self.buffer[abs_row];

        let end = (self.cursor_x + n).min(self.cols);
        for i in self.cursor_x..end {
            row[i] = Cell::blank(self.attrs);
        }
        self.wrapped_rows[abs_row] = false;
        self.mark_dirty(self.cursor_y);
    }

    /// IL (CSI L): 在光标行插入 N 行 (滚动区域内), 下方行下移
    pub(crate) fn insert_lines(&mut self, n: usize) {
        let n = n.max(1).min(self.rows.saturating_sub(self.cursor_y));
        if n == 0 {
            return;
        }
        // 只在滚动区域内操作
        let region_top = self.screen_top + self.scroll_top;
        let region_bottom = self.screen_top + self.scroll_bottom;
        self.ensure_abs_row(region_bottom);

        // 从底部开始向下移
        for _ in 0..n {
            let insert_abs = self.screen_top + self.cursor_y;
            // 将 [cursor_y, scroll_bottom-1] 范围内的行下移一行
            for row in (self.cursor_y..self.scroll_bottom).rev() {
                let src_abs = self.screen_top + row;
                let dst_abs = self.screen_top + row + 1;
                let src_row = self.buffer[src_abs].clone();
                self.buffer[dst_abs] = src_row;
                self.wrapped_rows[dst_abs] = self.wrapped_rows[src_abs];
            }
            // 插入行变空白
            self.buffer[insert_abs] = blank_row(self.cols, self.attrs);
            self.wrapped_rows[insert_abs] = false;
        }

        self.mark_all_dirty();
    }

    /// DL (CSI M): 删除光标行 N 行 (滚动区域内), 下方行上移
    pub(crate) fn delete_lines(&mut self, n: usize) {
        let n = n.max(1).min(self.rows.saturating_sub(self.cursor_y));
        if n == 0 {
            return;
        }
        let region_bottom = self.screen_top + self.scroll_bottom;
        self.ensure_abs_row(region_bottom);

        for _ in 0..n {
            // 将 [cursor_y+1, scroll_bottom] 范围内的行上移一行
            for row in self.cursor_y..self.scroll_bottom {
                let src_abs = self.screen_top + row + 1;
                let dst_abs = self.screen_top + row;
                let src_row = self.buffer[src_abs].clone();
                self.buffer[dst_abs] = src_row;
                self.wrapped_rows[dst_abs] = self.wrapped_rows[src_abs];
            }
            // 底部补空白
            let bot_abs = self.screen_top + self.scroll_bottom;
            self.buffer[bot_abs] = blank_row(self.cols, self.attrs);
            self.wrapped_rows[bot_abs] = false;
        }

        self.mark_all_dirty();
    }

    pub(crate) fn set_cursor_visible(&mut self, visible: bool) {
        if self.cursor_visible != visible {
            self.cursor_visible = visible;
            self.mark_dirty(self.cursor_y);
        }
    }

    pub(crate) fn set_sgr(&mut self, params: &[u16]) {
        if params.is_empty() {
            self.attrs = CellAttrs::default();
            return;
        }

        let mut iter = params.iter().copied();
        while let Some(param) = iter.next() {
            match param {
                0 => self.attrs = CellAttrs::default(),
                1 => self.attrs.bold = true,
                3 => self.attrs.italic = true,
                4 => self.attrs.underline = true,
                7 => self.attrs.inverse = true,
                22 => self.attrs.bold = false,
                23 => self.attrs.italic = false,
                24 => self.attrs.underline = false,
                27 => self.attrs.inverse = false,
                30..=37 => self.attrs.fg = ansi_color((param - 30) as usize, false),
                39 => self.attrs.fg = DEFAULT_FG,
                40..=47 => self.attrs.bg = ansi_color((param - 40) as usize, false),
                49 => self.attrs.bg = DEFAULT_BG,
                90..=97 => self.attrs.fg = ansi_color((param - 90) as usize, true),
                100..=107 => self.attrs.bg = ansi_color((param - 100) as usize, true),
                // 前景色扩展: 38
                38 => match iter.next() {
                    Some(5) => {
                        // 256 色: 38;5;N
                        if let Some(idx) = iter.next() {
                            self.attrs.fg = xterm_256_color(idx);
                        }
                    }
                    Some(2) => {
                        // 真彩色: 38;2;R;G;B
                        if let (Some(r), Some(g), Some(b)) = (iter.next(), iter.next(), iter.next())
                        {
                            self.attrs.fg =
                                (0xFF << 24) | ((r as u32) << 16) | ((g as u32) << 8) | (b as u32);
                        }
                    }
                    _ => {}
                },
                // 背景色扩展: 48
                48 => match iter.next() {
                    Some(5) => {
                        // 256 色: 48;5;N
                        if let Some(idx) = iter.next() {
                            self.attrs.bg = xterm_256_color(idx);
                        }
                    }
                    Some(2) => {
                        // 真彩色: 48;2;R;G;B
                        if let (Some(r), Some(g), Some(b)) = (iter.next(), iter.next(), iter.next())
                        {
                            self.attrs.bg =
                                (0xFF << 24) | ((r as u32) << 16) | ((g as u32) << 8) | (b as u32);
                        }
                    }
                    _ => {}
                },
                _ => {}
            }
        }
    }

    /// 滚动区域内向上滚一行 (line_feed 触发)
    fn scroll_region(&mut self) {
        if !self.alt_active && self.scroll_top == 0 && self.scroll_bottom == self.rows.saturating_sub(1) {
            let was_at_bottom = self.is_at_bottom();
            self.screen_top = self.screen_top.saturating_add(1);
            if was_at_bottom {
                self.view_top = self.screen_top;
            } else {
                self.view_top = self.view_top.min(self.screen_top);
            }
            let abs_bottom = self.screen_top + self.rows.saturating_sub(1);
            self.ensure_abs_row(abs_bottom);
            self.buffer[abs_bottom] = blank_row(self.cols, self.attrs);
            self.wrapped_rows[abs_bottom] = false;
            self.trim_scrollback();
            self.mark_all_dirty();
            return;
        }

        let abs_bottom = self.screen_top + self.scroll_bottom;
        self.ensure_abs_row(abs_bottom);

        // 将 [scroll_top, scroll_bottom-1] 范围内的行向上移一行
        // scroll_top 行被 scroll_top+1 覆盖, 依此类推
        for row in self.scroll_top..self.scroll_bottom {
            let src_abs = self.screen_top + row + 1;
            let dst_abs = self.screen_top + row;
            let src_row = self.buffer[src_abs].clone();
            self.buffer[dst_abs] = src_row;
            self.wrapped_rows[dst_abs] = self.wrapped_rows[src_abs];
        }
        // 区域最底部插入空白行
        self.buffer[abs_bottom] = blank_row(self.cols, self.attrs);
        self.wrapped_rows[abs_bottom] = false;

        self.mark_all_dirty();
    }

    /// 滚动区域内向下滚一行 (reverse_index 触发)
    fn scroll_region_down(&mut self) {
        let abs_bottom = self.screen_top + self.scroll_bottom;
        self.ensure_abs_row(abs_bottom);

        // 将 [scroll_top, scroll_bottom-1] 范围内的行向下移一行 (从底部开始)
        for row in (self.scroll_top..self.scroll_bottom).rev() {
            let src_abs = self.screen_top + row;
            let dst_abs = self.screen_top + row + 1;
            let src_row = self.buffer[src_abs].clone();
            self.buffer[dst_abs] = src_row;
            self.wrapped_rows[dst_abs] = self.wrapped_rows[src_abs];
        }
        // 区域顶部插入空白行
        let abs_top = self.screen_top + self.scroll_top;
        self.buffer[abs_top] = blank_row(self.cols, self.attrs);
        self.wrapped_rows[abs_top] = false;

        self.mark_all_dirty();
    }

    fn make_snapshot(&self, dirty_override: Option<Vec<usize>>) -> TerminalSnapshot {
        let mut cells = Vec::with_capacity(self.cols * self.rows);
        for row in 0..self.rows {
            let abs_row = self.view_top + row;
            if let Some(source) = self.buffer.get(abs_row) {
                for cell in source.iter().take(self.cols) {
                    cells.push(SnapshotCell {
                        ch: cell.ch,
                        fg: cell.attrs.fg,
                        bg: cell.attrs.bg,
                        bold: cell.attrs.bold,
                        italic: cell.attrs.italic,
                        underline: cell.attrs.underline,
                        inverse: cell.attrs.inverse,
                        wide: cell.wide,
                        wide_continuation: cell.wide_continuation,
                    });
                }
            } else {
                for _ in 0..self.cols {
                    cells.push(SnapshotCell::blank(self.attrs));
                }
            }
        }

        TerminalSnapshot {
            cols: self.cols,
            rows: self.rows,
            cursor_x: self.cursor_x.min(self.cols.saturating_sub(1)),
            cursor_y: self.cursor_y.min(self.rows.saturating_sub(1)),
            cursor_visible: self.cursor_visible,
            view_top: self.view_top,
            screen_top: self.screen_top,
            is_at_bottom: self.is_at_bottom(),
            dirty_rows: dirty_override.unwrap_or_else(|| self.dirty_rows.clone()),
            cells,
        }
    }

    fn ensure_abs_row(&mut self, abs_row: usize) {
        while self.buffer.len() <= abs_row {
            self.buffer.push(blank_row(self.cols, self.attrs));
            self.wrapped_rows.push(false);
        }
    }

    fn trim_scrollback(&mut self) {
        while self.buffer.len() > MAX_SCROLLBACK {
            self.buffer.remove(0);
            self.wrapped_rows.remove(0);
            self.screen_top = self.screen_top.saturating_sub(1);
            self.view_top = self.view_top.saturating_sub(1);
        }
    }

    fn max_screen_top(&self) -> usize {
        self.buffer.len().saturating_sub(self.rows)
    }

    fn mark_dirty(&mut self, row: usize) {
        if row < self.rows && !self.dirty_rows.contains(&row) {
            self.dirty_rows.push(row);
        }
    }

    fn mark_all_dirty(&mut self) {
        self.dirty_rows = (0..self.rows).collect();
    }

    fn mark_cursor_moved(&mut self, old_y: usize) {
        self.mark_dirty(old_y);
        self.mark_dirty(self.cursor_y);
    }

    fn mark_current_row_wrapped(&mut self) {
        let abs_row = self.screen_top + self.cursor_y;
        self.ensure_abs_row(abs_row);
        self.wrapped_rows[abs_row] = true;
    }

    fn can_reverse_wrap_cursor(&self) -> bool {
        if self.alt_active || self.cursor_y == 0 {
            return false;
        }
        if self.scroll_top != 0 || self.scroll_bottom != self.rows.saturating_sub(1) {
            return false;
        }
        let prev_abs = self.screen_top + self.cursor_y - 1;
        self.wrapped_rows.get(prev_abs).copied().unwrap_or(false)
    }

    fn can_forward_wrap_cursor(&self) -> bool {
        if self.alt_active || self.cursor_y >= self.rows.saturating_sub(1) {
            return false;
        }
        if self.scroll_top != 0 || self.scroll_bottom != self.rows.saturating_sub(1) {
            return false;
        }
        let abs_row = self.screen_top + self.cursor_y;
        self.wrapped_rows.get(abs_row).copied().unwrap_or(false)
    }

    fn move_cursor_horizontal(&mut self, dx: isize) {
        if dx < 0 {
            for _ in 0..dx.unsigned_abs() {
                if self.cursor_x > 0 {
                    self.cursor_x -= 1;
                } else if self.can_reverse_wrap_cursor() {
                    self.cursor_y -= 1;
                    self.cursor_x = self.cols.saturating_sub(1);
                } else {
                    break;
                }
            }
            return;
        }

        for _ in 0..(dx as usize) {
            if self.cursor_x < self.cols.saturating_sub(1) {
                self.cursor_x += 1;
            } else if self.can_forward_wrap_cursor() {
                self.cursor_y += 1;
                self.cursor_x = 0;
            } else {
                break;
            }
        }
    }
}

fn signed_clamp(base: usize, delta: isize, min: usize, max: usize) -> usize {
    let next = if delta >= 0 {
        base.saturating_add(delta as usize)
    } else {
        base.saturating_sub(delta.unsigned_abs())
    };
    next.clamp(min, max)
}

fn ansi_color(index: usize, bright: bool) -> u32 {
    const NORMAL: [u32; 8] = [
        0xFF1F2328, 0xFFFF5F57, 0xFF5AF78E, 0xFFF3F99D, 0xFF57C7FF, 0xFFFF6AC1, 0xFF9AEDFE,
        0xFFE8EAED,
    ];
    const BRIGHT: [u32; 8] = [
        0xFF6E7681, 0xFFFF7B72, 0xFF7EE787, 0xFFFFD866, 0xFF79C0FF, 0xFFD2A8FF, 0xFFA5F3FC,
        0xFFFFFFFF,
    ];
    if bright {
        BRIGHT[index.min(7)]
    } else {
        NORMAL[index.min(7)]
    }
}
